"""Public Internet egress with optional, exact local management endpoints."""
import ipaddress
import json
import os
import pathlib
import re
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
_DENIED_NETWORKS=tuple(map(ipaddress.ip_network,NON_PUBLIC))
_LOCAL_SUFFIXES=('localhost','local','localdomain','home.arpa','internal')
_OWNERS={'ssh':{'sshd','sshd-session','sshd-listener'},'panel':{'x-ui'}}


def _management_ip(value):
    if not isinstance(value,str) or '%' in value:
        raise ValueError('管理例外须填写本机网卡的公网 IPv4 或 IPv6 地址')
    try: address=ipaddress.ip_address(value)
    except ValueError: raise ValueError('管理例外须填写本机网卡的公网 IPv4 或 IPv6 地址') from None
    if not is_public(address) or any(address in net for net in _DENIED_NETWORKS):
        raise ValueError('管理例外不接受回环、私网、链路本地或其他非公网地址')
    return address


def _panel_domain(value):
    if not isinstance(value,str): raise ValueError('面板域名无效')
    value=value.strip().lower()
    if value.endswith('.'): value=value[:-1]
    label=r'[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?'
    if (len(value)>253 or not re.fullmatch(r'(?:'+label+r'\.)+'+label,value)
            or value.rsplit('.',1)[-1].isdigit()
            or any(value==suffix or value.endswith('.'+suffix) for suffix in _LOCAL_SUFFIXES)):
        raise ValueError('面板域名须是一个完整公网域名，不接受通配符、URL 或本地域名')
    return value


def validate(model):
    state=model.get('security')
    if state is None:return
    if (not isinstance(state,dict) or set(state) not in
            ({'policy','local_addresses'},{'policy','local_addresses','management'}) or state['policy']!=POLICY):
        raise ValueError('出口安全策略无效，不能关闭默认保护')
    addresses=state['local_addresses']
    if not isinstance(addresses,list) or len(addresses)>512:raise ValueError('本机地址快照无效')
    local=set()
    for address in addresses:
        if not isinstance(address,str):raise ValueError('本机地址快照无效')
        local.add(ipaddress.ip_address(address))
    if 'management' not in state:return
    management=state['management']
    if not isinstance(management,dict) or not management or set(management)-_OWNERS.keys():
        raise ValueError('管理例外无效')
    seen=set()
    for kind,endpoint in management.items():
        keys={'address','port'}
        if not isinstance(endpoint,dict) or not (set(endpoint)==keys or kind=='panel' and set(endpoint)==keys|{'domain'}):
            raise ValueError('管理例外无效')
        address=_management_ip(endpoint['address']);port=endpoint['port']
        if address not in local or type(port) is not int or not 1<=port<=65535 or (address,port) in seen:
            raise ValueError('管理例外须为本机快照中不重复的 IP 和有效端口')
        if 'domain' in endpoint and endpoint['domain']!=_panel_domain(endpoint['domain']):
            raise ValueError('面板域名格式无效')
        seen.add((address,port))


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
    management=model.get('security',{}).get('management')
    model['security']={'policy':POLICY,'local_addresses':sorted({str(ipaddress.ip_address(a)) for a in addresses})}
    if management:model['security']['management']=management


def _listener_is(kind,address,port):
    matches=[]
    for family in ([4,6] if address.version==4 else [6]):
        result=subprocess.run(['ss','-'+str(family),'-H','-ltnpe','sport = :'+str(port)],
                              check=True,capture_output=True,text=True,timeout=10)
        for line in result.stdout.splitlines():
            fields=line.split(maxsplit=5)
            if len(fields)<5 or fields[0]!='LISTEN':continue
            host,_,listen_port=fields[3].rpartition(':')
            if listen_port!=str(port):continue
            host=host.strip('[]').split('%',1)[0]
            if host in ('*','0.0.0.0','::'):
                bound=family==address.version or (family==6 and 'v6only:0' in line.split())
            else:
                try: bound=ipaddress.ip_address(host)==address
                except ValueError: bound=False
            if bound:matches.append(set(re.findall(r'\("([^"]+)",pid=',line)))
    return bool(matches) and all(owners&_OWNERS[kind] and owners<=_OWNERS[kind]|{'systemd'} for owners in matches)


def _verify_endpoint(kind,endpoint,local):
    address=_management_ip(endpoint['address'])
    if str(address) not in local:
        raise ValueError('管理例外的公网 IP 不在本机网卡上；请修改或撤销该例外')
    if not _listener_is(kind,address,endpoint['port']):
        service='SSH' if kind=='ssh' else '3X-UI (x-ui)'
        raise ValueError('无法确认 '+service+' 正在该 IP 和 TCP 端口监听；请核对、修改或撤销例外')


def verify_management(model,local):
    for kind,endpoint in model.get('security',{}).get('management',{}).items():
        _verify_endpoint(kind,endpoint,local)


def configure_management(model,kind,operation,address='',port='',domain=''):
    validate(model)
    state=model.get('security') or {'policy':POLICY,'local_addresses':[]}
    management=dict(state.get('management',{}))
    if operation=='revoke':
        if kind not in (*_OWNERS,'all') or address or port or domain:raise ValueError('无效的管理例外撤销参数')
        if not management or (kind!='all' and kind not in management):return False
        if kind=='all':management.clear()
        else:del management[kind]
    else:
        if operation!='allow' or kind not in _OWNERS or (domain and kind!='panel') or not re.fullmatch(r'[0-9]{1,5}',port) or not 1<=int(port)<=65535:
            raise ValueError('请提供有效的管理类型、公网 IP 和 TCP 端口')
        endpoint={'address':str(_management_ip(address.strip())),'port':int(port)}
        if domain:endpoint['domain']=_panel_domain(domain)
        _verify_endpoint(kind,endpoint,collect_local())
        if management.get(kind)==endpoint:return False
        management[kind]=endpoint
    addresses=set(state['local_addresses'])|{item['address'] for item in management.values()}
    updated={'policy':POLICY,'local_addresses':sorted(addresses)}
    if management:updated['management']=management
    validate({'security':updated})
    model['security']=updated
    return True


def _management_rules(model):
    rules=[]
    for kind,endpoint in sorted(model.get('security',{}).get('management',{}).items()):
        address=ipaddress.ip_address(endpoint['address'])
        base={'network':'tcp','port':[endpoint['port']],'action':'route','outbound':'direct'}
        rules.append(dict(base,ip_cidr=[f'{address}/{address.max_prefixlen}']))
        if kind=='panel' and 'domain' in endpoint:
            # Never follow DNS for an allowed name. Preserve the client's TLS
            # session while pinning the dial to the verified local endpoint.
            rules.append(dict(base,domain=[endpoint['domain']],override_address=str(address)))
    return rules


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
    names={'domain_suffix':list(_LOCAL_SUFFIXES),'action':'reject'}
    if domains:names['domain']=sorted(domains)
    # Resolve once inside the router; both literal and resolved destinations are
    # checked before direct dialing, which reuses the resolved address list.
    return {'rules':[*_management_rules(model),dict(blocked),names,{'action':'resolve','server':'system','disable_optimistic_cache':True},dict(blocked),
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
            'management':model.get('security',{}).get('management',{}) if current else {},
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
