"""Generate data-only parameter forms from the selected official runtime's Schema.

No remote code, web scraping, JSON input or guessed protocol implementation. The
Schema describes structure, not wire semantics; official checks remain mandatory.
"""
import copy
import hashlib
import json
import re
from .runtime import Runtime
from .core.storage import runtime_identity

MANAGED_SERVER={'tag','listen','listen_port'}
MANAGED_CLIENT={'tag','server','server_port'}
INFRA={'bind_interface','routing_mark','reuse_addr','netns','disable_tcp_keep_alive',
       'tcp_keep_alive','tcp_keep_alive_interval','tcp_fast_open','tcp_multi_path',
       'udp_fragment','udp_timeout','detour','connect_timeout','inet4_bind_address',
       'inet6_bind_address','bind_address_no_port','protect_path','domain_resolver',
       'network_strategy','network_type','fallback_network_type','fallback_delay',
       'set_system_proxy'}
LABELS={'users':'用户认证','username':'用户名','name':'日志名称','password':'认证密码',
        'psk':'预共享密钥','userkey':'用户密钥','uuid':'UUID','version':'协议版本',
        'method':'加密方式','flow':'流控','network':'传输网络','tls':'TLS',
        'transport':'传输设置','obfs':'混淆','obfs_mode':'混淆模式','mode':'运行模式',
        'server_name':'服务器名称','path':'路径','host':'主机名','token':'令牌'}


def label(key):return LABELS[key.lower()]+' ('+key+')' if key.lower() in LABELS else key


def secret(key):
    return any(x in key.lower() for x in ('password','psk','userkey','private_key','token','secret'))


def module_kind(kind):
    slug='auto-'+kind
    if len(slug)>25:slug='auto-'+kind[:13]+'-'+hashlib.sha256(kind.encode()).hexdigest()[:6]
    return 'custom-'+slug


class Schema:
    def __init__(self,data):self.data=data

    def resolve(self,node,depth=0):
        if depth>20 or not isinstance(node,dict):raise ValueError('Schema 引用过深或结构不支持')
        if '$ref' not in node:return node
        ref=node['$ref']
        if not isinstance(ref,str) or not re.fullmatch(r'#/\$defs/[A-Za-z0-9_-]+',ref):
            raise ValueError('只允许当前官方 Schema 内部引用')
        name=ref.split('/')[-1]
        if name not in self.data.get('$defs',{}):raise ValueError('Schema 引用缺失')
        result=dict(self.resolve(self.data['$defs'][name],depth+1))
        result.update({k:v for k,v in node.items() if k!='$ref'})
        return result

    def variants(self,node,depth=0):
        node=self.resolve(node)
        if depth>20:raise ValueError('Schema 分支过深')
        if 'oneOf' in node:
            return [v for item in node['oneOf'] for v in self.variants(item,depth+1)]
        return [node]

    def protocols(self,side):
        prop=self.data.get('properties',{}).get(side,{})
        items=prop.get('items')
        if not items:raise ValueError('Schema 未提供入站 / 出站清单')
        result={}
        for node in self.variants(items):
            kind=node.get('properties',{}).get('type',{}).get('const')
            if isinstance(kind,str) and re.fullmatch(r'[a-z][a-z0-9_-]{0,40}',kind):
                result.setdefault(kind,[]).append(node)
        return result

    def catalog(self):
        ins=self.protocols('inbounds');outs=self.protocols('outbounds');rows=[]
        for kind,nodes in sorted(ins.items()):
            listener=all({'listen','listen_port'}<=set(n.get('properties',{})) for n in nodes)
            paired=kind in outs and all({'server','server_port'}<=set(n.get('properties',{})) for n in outs[kind])
            reason='' if listener and paired else ('不是独立端口监听节点' if not listener else '缺少对应的远程客户端出站')
            rows.append({'protocol':kind,'available':listener and paired,'reason':reason,
                         'server_variants':len(nodes),'client_variants':len(outs.get(kind,[])),
                         'documentation':'https://sing-box.sagernet.org/configuration/inbound/'+kind+'/'})
        return rows


def discover(binary):
    runtime=Runtime(binary);before=runtime_identity(runtime.binary);data=runtime.schema()
    after=runtime_identity(runtime.binary)
    if before!=after:raise ValueError('读取 Schema 时运行程序发生变化，请重新扫描')
    schema=Schema(data)
    digest=hashlib.sha256(json.dumps(data,sort_keys=True,separators=(',',':')).encode()).hexdigest()
    return schema,{'runtime_version':runtime.version,'runtime_identity':before,'schema_sha256':digest}


def _constants(node):
    return {k:v['const'] for k,v in node.get('properties',{}).items() if 'const' in v and k!='type'}


def select_pair(schema,kind,ctx):
    ins=schema.protocols('inbounds')[kind];outs=schema.protocols('outbounds')[kind]
    # Match discriminators such as Snell version 6 before offering a runnable pair.
    pairs=[(a,b) for a in ins for b in outs if not any(
        k in _constants(b) and _constants(b)[k]!=v for k,v in _constants(a).items())]
    if not pairs:raise ValueError('官方 Schema 中没有可直接配对的协议版本；需专用适配，未生成模板')
    if len(pairs)==1:return pairs[0]
    names=[', '.join(k+'='+str(v) for k,v in _constants(a).items()) or '配置分支 '+str(i+1) for i,(a,b) in enumerate(pairs)]
    return pairs[ctx.choose('选择服务端 / 客户端共同支持的协议版本',names)]


class FormBuilder:
    def __init__(self,schema,ctx,advanced=True):
        self.schema=schema;self.ctx=ctx;self.advanced=advanced;self.fields=[];self.leaves={};self.shared=[]

    def field(self,node,path,side):
        key=path[-1];canonical=key.lower();typ=node.get('type','string');private='private_key' in canonical
        # Reuse only unambiguous identically named compatible parameters, never private keys.
        matches=self.leaves.get(canonical,[]) if side=='client' and not private else []
        matches=[f for f,n in matches if n==node]
        if len(matches)>1:
            matches=[matches[self.ctx.choose('选择客户端 '+'.'.join(path)+' 对应的服务端用户',[f['label'] for f in matches])]]
        if len(matches)==1 and matches[0].get('export',True):
            self.shared.append(('.'.join(path),matches[0]['key']))
            return '${'+matches[0]['key']+'}'
        if len(self.fields)>=64:raise ValueError('表单参数超过 64 项，请缩小可选字段范围')
        fkey='p'+str(len(self.fields)+1)+'_'+re.sub('[^a-z0-9_]','_',key.lower())[:22]
        f={'key':fkey,'label':('服务端 ' if side=='server' else '客户端 ')+'.'.join(label(x) for x in path),'required':True}
        if 'enum' in node:
            f.update(type='enum',options=node['enum'])
        elif typ=='integer':
            f.update(type='integer',minimum=node.get('minimum',-2147483648),maximum=node.get('maximum',2147483647))
        elif typ=='number':
            f.update(type='number',minimum=node.get('minimum',-1e15),maximum=node.get('maximum',1e15))
        elif typ=='boolean':f['type']='boolean'
        elif typ=='string':f['type']='password' if secret(key) else ('uuid' if canonical=='uuid' else 'string')
        else:raise ValueError('此字段无法生成安全表单：'+'.'.join(path))
        if private:f['export']=False
        for a,b in [('minLength','min_length'),('maxLength','max_length')]:
            if a in node:f[b]=node[a]
        # Passwords stay per-node and are never saved as profile defaults.
        if f['type'] not in {'password','uuid'}:
            if 'default' in node:f['default']=node['default']
            elif typ=='string' and 'enum' not in node:f['default']='user' if canonical in {'username','name'} else 'module-test'
        self.fields.append(f)
        if side=='server':self.leaves.setdefault(canonical,[]).append((f,node))
        return '${'+fkey+'}'

    def build(self,node,path,side,depth=0):
        if depth>12:raise ValueError('表单嵌套超过 12 层，请缩小字段范围')
        node=self.schema.resolve(node)
        if any(k in node for k in ('allOf','if','then','else','not','dependentSchemas')):
            raise ValueError('此字段需要专用语义适配：'+'.'.join(path))
        variants=node.get('oneOf',node.get('anyOf'))
        if variants:
            options=[self.schema.resolve(x) for x in variants]
            names=[str(x.get('const',x.get('type','对象分支')))+(' '+str(_constants(x)) if _constants(x) else '') for x in options]
            idx=self.ctx.choose('选择 '+'.'.join(path)+' 的参数结构',names) if self.advanced else 0
            return self.build(options[idx],path,side,depth+1)
        if 'const' in node:return node['const']
        typ=node.get('type','object' if 'properties' in node else None)
        if typ=='array':
            count=max(1,node.get('minItems',1))
            if count>8:raise ValueError('数组条目数超过安全表单上限')
            if self.advanced:count=self.ctx.ask('配置 '+'.'.join(path)+' 的条目数',lambda s:self.ctx.number(s,max(1,node.get('minItems',1)),min(8,node.get('maxItems',8))),count)
            return [self.build(node.get('items',{}),path+[str(i+1)],side,depth+1) for i in range(count)]
        if typ=='object':
            props=node.get('properties',{})
            if not props:raise ValueError('开放字典暂无固定字段，无法安全自动生成：'+'.'.join(path))
            required=set(node.get('required',[]))
            reserved=(MANAGED_SERVER if side=='server' else MANAGED_CLIENT) if not path else set()
            constants={k:v['const'] for k,v in props.items() if 'const' in v}
            keys=[k for k in props if k not in reserved and k not in constants and (path or k!='tls')]
            suggested=[k for k in keys if k in required or k not in INFRA and (
                k.lower() in {'users','username','password','psk','uuid','method','userkey'} or
                side=='client' and k.lower() in self.leaves)]
            if self.advanced:
                print(('服务端' if side=='server' else '客户端')+' '+('.'.join(path) or '协议参数')+'：选择要填写的字段；空行采用推荐，0 不选可选项。')
                for i,k in enumerate(keys,1):print(f'  {i}) {label(k)}'+(' [必填]' if k in required else '')+(' [推荐]' if k in suggested else ''))
            def parse(s):
                if s=='0':return [k for k in keys if k in required]
                indices=[self.ctx.number(x.strip(),1,len(keys))-1 for x in s.split(',')]
                return [k for i,k in enumerate(keys) if i in indices or k in required]
            selected=self.ctx.ask('字段序号（用逗号分隔）',parse,','.join(str(keys.index(k)+1) for k in suggested) or '0') if keys and self.advanced else suggested
            out={k:v for k,v in constants.items() if k not in reserved}
            for k in selected:out[k]=self.build(props[k],path+[k],side,depth+1)
            return out
        return self.field(node,path,side)


def create(binary,ctx,kind=None):
    schema,origin=discover(binary);rows=schema.catalog()
    from .protocols import ADAPTERS
    builtins={a.inbound_type or a.kind for a in ADAPTERS.values() if a.source=='built-in'}
    candidates=[r for r in rows if r['available'] and r['protocol'] not in builtins and module_kind(r['protocol']) not in ADAPTERS]
    print('已读取官方核心 '+origin['runtime_version']+' 的协议清单；地址、端口、标签由管理器统一填写。')
    if not kind:
        if not candidates:raise ValueError('当前核心没有可新增的独立协议；可先用菜单 10 升级官方核心后重新扫描')
        kind=candidates[ctx.choose('选择官方协议（原有九种协议仍在节点菜单）',[r['protocol'] for r in candidates])]['protocol']
    if not any(r['protocol']==kind and r['available'] for r in rows):raise ValueError('当前核心不支持创建此独立协议节点')
    server,client=select_pair(schema,kind,ctx)
    tls='tls' in server.get('properties',{}) and 'tls' in client.get('properties',{})
    if tls:tls=ctx.choose('此模块的证书方式',['使用管理器共用 ACME TLS','不启用 TLS（仅适用于允许明文的协议）'])==0
    nets=[['tcp'],['udp'],['tcp','udp']][ctx.choose('按官方说明选择此协议服务端监听方式',['TCP','UDP / QUIC','TCP + UDP'])]
    print('官方参数说明：https://sing-box.sagernet.org/configuration/inbound/'+kind+'/')
    advanced=ctx.choose('参数表单',['推荐参数（直接填写认证等常用参数）','自选字段（按官方 Schema 选择更多参数，无需 JSON）'])==1
    builder=FormBuilder(schema,ctx,advanced)
    st=builder.build(server,[],'server');ct=builder.build(client,[],'client')
    if not builder.fields:raise ValueError('此协议没有生成认证参数；需要专用适配，未安装模块')
    from .protocols.declarative import references
    credentials={f['key'] for f in builder.fields if f['type'] in {'password','uuid'} and f.get('export',True)}
    if not (references(st)&references(ct)&credentials):
        raise ValueError('未找到两端共用的认证参数，不能自动生成公开节点；请选择认证字段或使用专用适配')
    for path,key in builder.shared:print('自动配对：客户端 '+path+' 共用服务端参数 '+key)
    data={'format':1,'kind':module_kind(kind),'label':kind+'（官方自动表单）','module_version':'1.0.0',
          'minimum_runtime':origin['runtime_version'],'default_port':17443,'networks':nets,'tls':tls,
          'server_tags':[],'fields':builder.fields,'server_template':st,'client_template':ct,'uri_template':'','origin':origin}
    from .profile_manager import install
    install(data,binary,ctx)
    return data['kind']


def command(args,ctx):
    if args[0]=='create':return create(args[1],ctx,args[2] if len(args)>2 else None)
    if args[0]=='list':
        schema,origin=discover(args[1]);report={'origin':origin,'protocols':schema.catalog()}
        if '--json' in args:print(json.dumps(report,ensure_ascii=False))
        else:
            print('来源：当前官方核心 '+origin['runtime_version']+'，Schema SHA-256 '+origin['schema_sha256'])
            for r in report['protocols']:print(r['protocol']+' | '+('可生成参数表单' if r['available'] else r['reason']))
        return
    raise ValueError('官方协议命令无效')
