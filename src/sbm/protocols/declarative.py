"""Data-only adapters for future sing-box protocols; no eval, exec or Python plugins."""
import copy
import hashlib
import json
import pathlib
import re
import urllib.parse
import math
from .base import Adapter

TOKEN=re.compile(r'\$\{([a-z][a-z0-9_]*)\}')
COMMON={'id','name','server','port'}
TYPES={'string','password','uuid','integer','number','hostname','enum','boolean','json'}


def references(value):
    if isinstance(value,str):return set(TOKEN.findall(value))
    if isinstance(value,list):return set().union(*(references(x) for x in value))
    if isinstance(value,dict):return set().union(*(references(x) for x in value.values()))
    return set()


def render(value,values):
    if isinstance(value,str):
        match=TOKEN.fullmatch(value)
        if match:return copy.deepcopy(values[match[1]])
        return TOKEN.sub(lambda m:str(values[m[1]]),value)
    if isinstance(value,list):return [render(x,values) for x in value]
    if isinstance(value,dict):return {k:render(v,values) for k,v in value.items()}
    return value


def validate_definition(data):
    if not isinstance(data,dict) or data.get('format')!=1:raise ValueError('协议模板格式必须为 1')
    allowed={'format','kind','label','module_version','minimum_runtime','default_port','networks','tls',
             'server_tags','fields','server_template','client_template','uri_template','origin'}
    if set(data)-allowed:raise ValueError('协议模板有未知元数据字段')
    if 'origin' in data:
        origin=data['origin']
        if not isinstance(origin,dict) or set(origin)!={'runtime_version','runtime_identity','schema_sha256'} or not re.fullmatch(r'\d+\.\d+\.\d+(?:-[A-Za-z0-9.-]+)?',str(origin.get('runtime_version',''))) or any(not re.fullmatch(r'[a-f0-9]{64}',str(origin.get(k,''))) for k in ['runtime_identity','schema_sha256']):
            raise ValueError('官方 Schema 来源信息无效')
    if not re.fullmatch(r'custom-[a-z0-9][a-z0-9_-]{0,24}',data.get('kind','')):raise ValueError('自定义标识必须以 custom- 开头')
    if not isinstance(data.get('label'),str) or not 1<=len(data['label'])<=80:raise ValueError('模块名称无效')
    for key in ['module_version','minimum_runtime']:
        if not re.fullmatch(r'\d+\.\d+\.\d+(?:-[A-Za-z0-9.-]+)?',data.get(key,'')):raise ValueError('模块 / 最低运行版本无效')
    if type(data.get('default_port')) is not int or not 1<=data['default_port']<=65535:raise ValueError('默认端口无效')
    if not isinstance(data.get('networks'),list) or not data['networks'] or set(data['networks'])-{'tcp','udp'}:raise ValueError('传输类型无效')
    if type(data.get('tls')) is not bool:raise ValueError('共享 TLS 标记必须为布尔值')
    tags=data.get('server_tags',[])
    if not isinstance(tags,list) or any(not isinstance(t,str) or not re.fullmatch(r'with_[a-z0-9_]+',t) for t in tags):raise ValueError('构建能力声明无效')
    fields=data.get('fields',[]);names=set();private=set()
    if not isinstance(fields,list) or len(fields)>64:raise ValueError('参数表单必须为数组，最多 64 项')
    for field in fields:
        if not isinstance(field,dict) or set(field)-{'key','label','type','required','default','example','minimum','maximum','options','export','min_length','max_length'}:raise ValueError('参数描述无效')
        key=field.get('key','')
        if not re.fullmatch(r'[a-z][a-z0-9_]{0,31}',key) or key in names or key in COMMON:raise ValueError('参数标识重复、保留或无效')
        names.add(key)
        if field.get('type') not in TYPES:raise ValueError('参数类型无效')
        if not isinstance(field.get('label'),str) or not field['label']:raise ValueError('参数中文名称无效')
        if field['type']=='enum' and (not isinstance(field.get('options'),list) or not field['options'] or any(type(x) not in (str,int,bool) for x in field['options'])):raise ValueError('枚举选项无效')
        if 'export' in field and type(field['export']) is not bool:raise ValueError('参数 export 必须为布尔值')
        if 'required' in field and type(field['required']) is not bool:raise ValueError('参数 required 必须为布尔值')
        if field.get('export') is False or 'private_key' in key:private.add(key)
        if field['type']=='password' and ('default' in field or 'example' in field):raise ValueError('密码字段留给自动生成，不在模块里保存默认密码')
        if field['type']=='integer':
            lo,hi=field.get('minimum',1),field.get('maximum',65535)
            if type(lo) is not int or type(hi) is not int or lo>hi:raise ValueError('整数参数范围无效')
        if field['type']=='number':
            lo,hi=field.get('minimum',-1e15),field.get('maximum',1e15)
            if any(type(v) not in (int,float) or not math.isfinite(v) for v in [lo,hi]) or lo>hi:raise ValueError('数值参数范围无效')
        for key in ['min_length','max_length']:
            if key in field and (type(field[key]) is not int or not 0<=field[key]<=1048576):raise ValueError('文本长度限制无效')
    for key in ['server_template','client_template']:
        value=data.get(key)
        if not isinstance(value,dict) or not re.fullmatch(r'[a-z][a-z0-9_-]{0,40}',value.get('type','')):raise ValueError('服务端 / 客户端模板需要有效 type')
        reserved={'tag','listen','listen_port'} if key=='server_template' else {'tag','server','server_port'}
        if set(value)&reserved:raise ValueError('地址、端口及标签由管理器统一填写，请从模板删除这些字段')
        if 'tls' in value and not isinstance(value['tls'],dict):raise ValueError('TLS 模板必须是对象')
    uri=data.get('uri_template','')
    if not isinstance(uri,str) or len(uri)>4096 or any(c in uri for c in '\r\n'):raise ValueError('URI 模板无效')
    all_refs=references(data['server_template'])|references(data['client_template'])|references(uri)
    if all_refs-(names|COMMON):raise ValueError('模板引用了未声明的参数')
    if (references(data['client_template'])|references(uri))&private:raise ValueError('客户端模板不能引用私有服务端字段')
    return data


class DeclarativeAdapter(Adapter):
    username=False
    source='declarative'
    def __init__(self,data):
        self.definition=copy.deepcopy(validate_definition(data))
        for key in ['kind','label','module_version','minimum_runtime','default_port','tls']:
            setattr(self,key,self.definition[key])
        self.networks=tuple(data['networks']);self.server_tags=tuple(data.get('server_tags',[]))
        if 'origin' in data:self.source='official-schema'
        self.digest=hashlib.sha256(json.dumps(self.definition,sort_keys=True,separators=(',',':')).encode()).hexdigest()

    def _check(self,field,value,ctx):
        t=field['type']
        if t=='integer':
            if type(value) is not int or not field.get('minimum',1)<=value<=field.get('maximum',65535):ctx.fail('整数参数超出范围')
        elif t=='number':
            if type(value) not in (int,float) or not math.isfinite(value) or not field.get('minimum',-1e15)<=value<=field.get('maximum',1e15):ctx.fail('数值参数超出范围')
        elif t=='enum':
            if not any(type(value) is type(v) and value==v for v in field['options']):ctx.fail('枚举参数无效')
        elif t=='boolean':
            if type(value) is not bool:ctx.fail('布尔参数无效')
        elif t=='json':
            if not isinstance(value,(list,dict)):ctx.fail('JSON 参数必须为对象或数组')
        else:
            if not isinstance(value,str) or any(c in value for c in '\r\n\x00'):ctx.fail('文本参数无效')
            if field.get('required',True) and not value:ctx.fail('必填参数不能为空')
            if not field.get('min_length',0)<=len(value)<=field.get('max_length',1048576):ctx.fail('文本长度超出范围')
            if t=='uuid':ctx.uuid_value(value)
            elif t=='hostname':ctx.hostname(value)
            elif t=='enum' and value not in field['options']:ctx.fail('枚举参数无效')
            elif t=='password':ctx.check_password(value)
        return value

    def prompt(self,n,ctx,binary):
        values=n.setdefault('parameters',{})
        for f in self.definition.get('fields',[]):
            key=f['key'];old=values.get(key,f.get('default'));t=f['type']
            if t=='password':value=ctx.password(f['label'],old)
            elif t=='uuid':value=ctx.ask(f['label'],lambda s:ctx.uuid_value(s,old or ''),old)
            elif t=='enum':
                choices=f['options'];value=choices[ctx.choose(f['label'],choices,choices.index(old)+1 if old in choices else 1)]
            elif t=='boolean':value=ctx.choose(f['label'],['否','是'],2 if old else 1)==1
            else:
                def parse(s):
                    try:value=int(s) if t=='integer' else (float(s) if t=='number' else (json.loads(s) if t=='json' else s))
                    except ValueError:ctx.fail('请输入有效数值或参数')
                    return self._check(f,value,ctx)
                value=ctx.ask(f['label'],parse,old)
            values[key]=value
        n['module_digest']=self.digest

    def validate(self,n,ctx):
        if n.get('module_digest')!=self.digest:ctx.fail('协议模板已变化，拒绝覆盖原节点；请恢复模板或重新创建节点')
        values=n.get('parameters',{})
        if not isinstance(values,dict) or set(values)!={f['key'] for f in self.definition.get('fields',[])}:ctx.fail('自定义协议参数缺失或多余')
        for f in self.definition.get('fields',[]):self._check(f,values[f['key']],ctx)

    def values(self,n):
        return dict(n.get('parameters',{}),id=n['id'],name=n['name'],server=n['server'],port=n['port'])

    def inbound(self,n,model):
        x=render(self.definition['server_template'],self.values(n))
        x.update(tag=n['id'],listen=model['listen'],listen_port=n['port'])
        if self.tls:
            tls=x.setdefault('tls',{});tls.update(enabled=True,server_name=model['acme']['domain'],certificate_provider='acme-main')
        return x

    def outbound(self,n):
        x=render(self.definition['client_template'],self.values(n))
        x.update(tag=n['id'],server=n['server'],server_port=n['port'])
        if self.tls:
            tls=x.setdefault('tls',{});tls.update(enabled=True,server_name=n['server'],insecure=False)
        return x

    def uri(self,n):
        values=self.values(n)
        values={k:urllib.parse.quote(str(v),safe='') for k,v in values.items()}
        host=n['server'];values['server']='['+host+']' if ':' in host else host
        return render(self.definition.get('uri_template',''),values)

    def summary(self,n):
        lines=['自定义模块：'+self.label+' / '+self.module_version]
        for f in self.definition.get('fields',[]):
            if f.get('export',True) and 'private_key' not in f['key']:lines.append(f['label']+': '+str(n['parameters'][f['key']]))
        return lines

    def rotate(self,n,ctx,binary):
        changed=False
        for f in self.definition.get('fields',[]):
            if f['type']=='password':n['parameters'][f['key']]=ctx.password('',rotate=True);changed=True
            elif f['type']=='uuid':n['parameters'][f['key']]=str(ctx.uuid.uuid4());changed=True
        if not changed:ctx.fail('该模块未声明可轮换的密码或 UUID 参数')

    def sample(self,ctx,binary):
        n=super().sample(ctx,binary);values={}
        for f in self.definition.get('fields',[]):
            t=f['type']
            if t=='password':value=ctx.password('',rotate=True)
            elif t=='uuid':value=str(ctx.uuid.uuid4())
            else:value=f.get('example',f.get('default',{'integer':max(0,f.get('minimum',1)),'number':max(0,f.get('minimum',0)),'hostname':'module.example.com','boolean':False,'string':'module-test','json':{},'enum':(f.get('options') or [''])[0]}.get(t,'')))
            values[f['key']]=value
        n.update(parameters=values,module_digest=self.digest)
        return n


def load_directory(path):
    root=pathlib.Path(path)
    if root.is_symlink():raise ValueError('协议模块目录不得为符号链接')
    result=[];errors={}
    if not root.exists():return result,errors
    for file in sorted(root.glob('*.json')):
        try:
            if file.is_symlink() or file.stat().st_size>262144:raise ValueError()
            adapter=DeclarativeAdapter(json.loads(file.read_text()))
            if file.name!=adapter.kind+'.json':raise ValueError()
            result.append(adapter)
        except (ValueError,TypeError,KeyError,OSError):errors[file.stem]='模板损坏或格式无效，已停止加载'
    return result,errors
