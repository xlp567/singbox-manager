"""Public Internet egress only; shared by every server protocol adapter."""
import ipaddress
import json
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
