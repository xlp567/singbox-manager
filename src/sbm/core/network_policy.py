"""Public Internet egress only; shared by every server protocol adapter."""
import ipaddress
import json
import os
import pathlib
import subprocess

POLICY='public-only-v1'
# Explicit coverage complements the runtime's ip_is_private implementation.
NON_PUBLIC=(
    '0.0.0.0/8','10.0.0.0/8','100.64.0.0/10','127.0.0.0/8',
    '169.254.0.0/16','172.16.0.0/12','192.168.0.0/16','198.18.0.0/15',
    '224.0.0.0/4','240.0.0.0/4','::/96','::1/128','::ffff:0:0/96',
    'fc00::/7','fe80::/10','ff00::/8',
    # Translation/tunnel ranges can hide an embedded private IPv4 destination.
    '64:ff9b::/96','64:ff9b:1::/48','2002::/16','2001::/32',
)


def validate(model):
    state=model.get('security')
    if state is None:return
    if not isinstance(state,dict) or set(state)!={'policy','local_addresses'} or state['policy']!=POLICY:
        raise ValueError('出口安全策略无效，不能关闭默认保护')
    addresses=state['local_addresses']
    if not isinstance(addresses,list) or len(addresses)>512:raise ValueError('本机地址快照无效')
    for address in addresses:
        if not isinstance(address,str):raise ValueError('本机地址快照无效')
        ipaddress.ip_address(address)


def collect_local():
    result=subprocess.run(['ip','-j','address','show'],check=True,capture_output=True,text=True,timeout=10)
    data=json.loads(result.stdout)
    if not isinstance(data,list) or not data:raise ValueError('无法读取本机接口地址，未应用安全策略')
    addresses=set()
    for interface in data:
        for item in interface.get('addr_info',[]):
            if item.get('family') in {'inet','inet6'}:addresses.add(str(ipaddress.ip_address(item['local'])))
    if not addresses:raise ValueError('本机接口地址为空，未应用安全策略')
    return addresses


def stamp(model,addresses):
    model['security']={'policy':POLICY,'local_addresses':sorted({str(ipaddress.ip_address(a)) for a in addresses})}


def route(model):
    validate(model)
    own=set(model.get('security',{}).get('local_addresses',[]));domains=set()
    for node in model['nodes']:
        try:own.add(str(ipaddress.ip_address(node['server'])))
        except ValueError:domains.add(node['server'].lower().rstrip('.'))
    cidrs=list(NON_PUBLIC)
    for address in sorted(own):
        ip=ipaddress.ip_address(address)
        cidrs.append(str(ip)+('/32' if ip.version==4 else '/128'))
    blocked={'ip_is_private':True,'ip_cidr':cidrs,'action':'reject'}
    names={'domain_suffix':['localhost','local','localdomain','home.arpa','internal'],'action':'reject'}
    if domains:names['domain']=sorted(domains)
    # Resolve once inside the router; both literal and resolved destinations are
    # checked before direct dialing, which reuses the resolved address list.
    return {'rules':[dict(blocked),names,{'action':'resolve','server':'system','disable_optimistic_cache':True},dict(blocked),
                     {'ip_cidr':['0.0.0.0/0','::/0'],'action':'route','outbound':'direct'},
                     {'action':'reject'}],'final':'direct'}


def matches(model,config,compiled):
    if compiled==config:return True
    if 'security' in model:return False
    # Only the exact historical unrestricted template is recognized, never
    # arbitrary user rules or a partially removed new policy.
    legacy=dict(compiled);legacy.pop('dns',None);legacy['route']={'final':'direct'}
    return legacy==config


def status(model,config,compiled):
    current=compiled==config and model.get('security',{}).get('policy')==POLICY
    return {'policy':POLICY,'applied':current,'legacy_recognized':not current and matches(model,config,compiled),
            'local_address_count':len(model.get('security',{}).get('local_addresses',[])),
            'requires_apply':not current,'scope':'proxy egress only; does not change SSH, firewall, 3X-UI or Xray'}


# Public-address discovery for the node DNS check. Several HTTPS sources are tried
# per family; global interface addresses and operator-confirmed addresses
# (NAT / floating IP) are combined with whatever the sources report.
PUBLIC_IP_SOURCES={4:('https://api.ipify.org','https://ipv4.icanhazip.com','https://checkip.amazonaws.com'),
                   6:('https://api6.ipify.org','https://ipv6.icanhazip.com')}
CONFIRMED_LIMIT=64


def is_public(address):
    # is_global alone also accepts multicast on supported Python versions.
    return (address.is_global and not address.is_multicast and not address.is_unspecified
            and not address.is_loopback and not address.is_link_local and not address.is_reserved
            and not getattr(address,'is_site_local',False))


def detect_public(family,sources=None,runner=subprocess.check_output):
    for url in (sources or PUBLIC_IP_SOURCES[family]):
        try:
            text=runner(['curl','-'+str(family),'--proto','=https','-fsS','--connect-timeout','5','--max-time','10',url],
                        stderr=subprocess.DEVNULL,text=True,timeout=20).strip()
            address=ipaddress.ip_address(text)
        except (subprocess.CalledProcessError,subprocess.TimeoutExpired,OSError,ValueError):continue
        if address.version==family and is_public(address):return address,url
    return None,None


def confirmed_path(state=None):
    state=state or os.environ.get('SBM_STATE','')
    return pathlib.Path(state)/'public-addresses.json' if state else None


def confirmed_load(state=None):
    path=confirmed_path(state)
    if path is None or not path.exists():return []
    if path.is_symlink() or not path.is_file():raise ValueError('已确认公网地址文件不得为符号链接')
    data=json.loads(path.read_text())
    rows=data.get('addresses') if isinstance(data,dict) and data.get('format')==1 else None
    if not isinstance(rows,list) or len(rows)>CONFIRMED_LIMIT:raise ValueError('已确认公网地址文件无效')
    return sorted({_global(row) for row in rows},key=lambda a:(a.version,int(a)))


def _global(value):
    try:address=ipaddress.ip_address(str(value).strip())
    except ValueError:raise ValueError('不是有效 IP 地址：'+str(value)) from None
    if not is_public(address):raise ValueError('只能确认公网单播地址，拒绝组播 / 私网 / 回环 / 未指定 / 保留地址：'+str(address))
    return address


def confirmed_command(state,op,value=''):
    from .storage import save
    current=confirmed_load(state)
    if op=='show':
        print('已确认的本机公网地址：'+(', '.join(map(str,current)) if current else '无'))
        print('用途：NAT / 浮动 IP 等出口地址与入口地址不同的主机；只用于节点地址核对，不修改节点或服务。');return
    if op=='add':current=sorted(set(current)|{_global(value)},key=lambda a:(a.version,int(a)))
    elif op=='remove':
        target=_global(value)
        if target not in current:raise ValueError('该地址不在已确认列表中：'+str(target))
        current=[a for a in current if a!=target]
    elif op!='clear':raise ValueError('公网地址操作无效（show / add / remove / clear）')
    else:current=[]
    if len(current)>CONFIRMED_LIMIT:raise ValueError('已确认公网地址过多')
    save(confirmed_path(state),{'format':1,'addresses':[str(a) for a in current]})
    print('已保存：'+(', '.join(map(str,current)) if current else '列表已清空'))
