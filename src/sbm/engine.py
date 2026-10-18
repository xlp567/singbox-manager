#!/usr/bin/env python3
"""Stable offline management engine. Protocol behavior lives in adapters."""
import base64, copy, datetime, getpass, hashlib, ipaddress, json, os, pathlib, re
import secrets, socket, subprocess, sys, tarfile, urllib.parse, urllib.request, uuid
from .protocols import ADAPTERS, get as protocol
from .protocols.base import METHODS
from .adapter_engine import PROTOCOL_ENGINE
from .core import audit
from .core.storage import save, sync_directory, backup_inventory, backup_seal, backup_verify, pending_write, pending_clear, backup_complete, runtime_identity, runtime_copy_libraries, RUNTIME_LIBRARIES
from .runtime import Runtime
KINDS = [(a.kind, a.label, a.default_port) for a in ADAPTERS.values()]
TLS_KINDS = {a.kind for a in ADAPTERS.values() if a.tls}
CTX = sys.modules[__name__]

def fail(s): raise ValueError(s)
def load(p): return json.loads(pathlib.Path(p).read_text())






def prompt(label, default=None):
    x=input(label + (f' [{default}]' if default is not None else '') + ': ').strip()
    return x if x else (str(default) if default is not None else '')
TRIES = 5
def ask(label, parse, default=None):
    """Re-prompt on invalid input instead of discarding everything typed so far."""
    for i in range(TRIES):
        s=prompt(label,default)
        try: return parse(s)
        except ValueError as e:
            print('  输入无效：'+str(e)+('；请重新输入' if i<TRIES-1 else ''))
    fail('连续多次输入无效，已取消本次编辑')

def choose(label,opts,default=1):
    print(label)
    for i,s in enumerate(opts,1): print(f'  {i}) {s}')
    return ask('选择',lambda s: number(s,1,len(opts)),default)-1

def check_password(s,method=None):
    if '\n' in s or '\r' in s: fail('密码不能包含换行')
    if method and method.startswith('2022-'):
        size=16 if method=='2022-blake3-aes-128-gcm' else 32
        try: valid=len(base64.b64decode(s,validate=True))==size
        except Exception: valid=False
        if not valid: fail(f'此 Shadowsocks 2022 方法要求 {size} 字节随机密钥的 Base64 编码；可留空生成')
    elif len(s)<12: fail('密码至少 12 个字符')
    return s

def password(label,old=None,method=None,rotate=False):
    def generate():
        size=16 if method=='2022-blake3-aes-128-gcm' else 32
        return base64.b64encode(secrets.token_bytes(size)).decode() if method and method.startswith('2022-') else secrets.token_urlsafe(32)
    if rotate: return generate()
    desc='留空保留；输入 ! 生成新密码' if old else '留空自动生成'
    for i in range(TRIES):
        s=getpass.getpass(f'{label}（{desc}）: ')
        if not s and old: return old
        if not s or s=='!': return generate()
        try: return check_password(s,method)
        except ValueError as e:
            print('  输入无效：'+str(e)+('；请重新输入' if i<TRIES-1 else ''))
    fail('连续多次输入无效，已取消本次编辑')

def system_listeners():
    """{(net,port): process names} of current listeners; empty when ss is unavailable."""
    try: out=subprocess.run(['ss','-H','-lntup'],text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=10,check=True).stdout
    except (OSError,subprocess.SubprocessError) as e: fail('无法检查监听端口：'+str(e))
    found={}
    for line in out.splitlines():
        f=line.split()
        if len(f)<5 or f[0] not in ('tcp','udp'): continue
        try: p=int(f[4].rsplit(':',1)[1])
        except (IndexError,ValueError): continue
        found.setdefault((f[0],p),set()).update(re.findall(r'\("([^"]+)"',line) or ['未知进程'])
    return {k:','.join(sorted(v)) for k,v in found.items()}

def challenge_port(m):
    return (80 if m['acme']['challenge']=='http' else 443) if m.get('acme') else None

def port_parser(m,kind,node_id,listeners):
    nets=set(networks({'kind':kind}))
    tls_active=kind in TLS_KINDS or any(o['enabled'] and o['kind'] in TLS_KINDS and o['id']!=node_id for o in m['nodes'])
    def parse(s):
        p=number(s)
        for o in m['nodes']:
            shared=nets & set(networks(o))
            if o['id']!=node_id and o['enabled'] and o['port']==p and shared:
                fail(f'与节点「{o["name"]}」的 {"/".join(sorted(shared))} 端口冲突')
        if tls_active and 'tcp' in nets and p==challenge_port(m):
            fail(f'TCP/{p} 是 ACME 验证端口；可换端口，或用菜单 8 更换验证方式')
        for net in sorted(nets):
            who=listeners.get((net,p))
            if who and who != 'sing-box': fail(f'{net}/{p} 已被 {who} 占用')
        return p
    return parse

def suggest_port(parse,base):
    for p in range(base,min(base+2000,65536)):
        try: return parse(str(p))
        except ValueError: pass
    return base

def hostname(s,domain_only=False):
    try:
        ipaddress.ip_address(s)
        if domain_only: fail('这里需要域名，不能填写 IP')
        return s
    except ValueError:
        if domain_only and re.fullmatch(r'[0-9.]+',s): fail('这里需要域名')
    s=s.lower()
    if len(s)>253 or '.' not in s or not all(re.fullmatch(r'[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?',v) for v in s.split('.')):
        fail('主机名无效；不带协议/路径，国际域名先转为 punycode')
    return s

def number(s,lo=1,hi=65535):
    if not s.isdigit() or not lo<=int(s)<=hi: fail(f'数值必须在 {lo}–{hi}')
    return int(s)

def email(s):
    if not re.fullmatch(r'[^\s@]+@[^\s@]+\.[^\s@]+',s): fail('邮箱格式无效')
    return s

def node_name(s):
    if not s or len(s)>80: fail('名称长度要求 1–80')
    return s

def uuid_value(s,old=''):
    if not s and old: return old
    if not s or s=='!': return str(uuid.uuid4())
    try: return str(uuid.UUID(s))
    except ValueError: fail('UUID 格式无效；留空或输入 ! 自动生成')

def ws_path(s):
    if not s.startswith('/') or any(c.isspace() for c in s) or '?' in s or '#' in s: fail('路径须以 / 开头，不含空格、?、#')
    return s

def acme_prompt(m,force=False):
    if m.get('acme') and not force: return
    old=m.get('acme') or {}
    d=ask('证书域名（所有普通 TLS 节点共用）',lambda s: hostname(s,True),old.get('domain'))
    e=ask('ACME 邮箱',email,old.get('email'))
    ca=['letsencrypt','zerossl'][choose('证书 CA',['Let\'s Encrypt 正式环境','ZeroSSL（通过邮箱获取 EAB）'],1 if old.get('provider')!='zerossl' else 2)]
    used={n['port'] for n in m['nodes'] if n['enabled'] and 'tcp' in networks(n)}
    for _ in range(TRIES):
        ch=['http','tls'][choose('域名验证方式（该端口须长期公网直达 VPS）',['HTTP-01 / TCP 80','TLS-ALPN-01 / TCP 443'],1 if old.get('challenge')!='tls' else 2)]
        if (80 if ch=='http' else 443) not in used: break
        print(f'  TCP/{80 if ch=="http" else 443} 已被现有节点使用，请选另一种验证方式或先修改该节点端口。')
    else: fail('ACME 验证端口与现有节点冲突')
    key=['p256','rsa2048'][choose('证书密钥',['p256','rsa2048'],1 if old.get('key_type')!='rsa2048' else 2)]
    m['acme']={'domain':d,'email':e,'provider':ca,'challenge':ch,'key_type':key}
    for n in m['nodes']:
        if n['kind'] in TLS_KINDS: n['server']=d

def keypair(binary):
    text=subprocess.check_output([binary,'generate','reality-keypair'],text=True)
    a=re.search(r'PrivateKey:\s*(\S+)',text); b=re.search(r'PublicKey:\s*(\S+)',text)
    if not a or not b: fail('无法解析 Reality 密钥输出；未修改原配置')
    return a[1],b[1]

def new_model(): return {'schema':2,'listen':'0.0.0.0','log_level':'info','acme':None,'nodes':[]}

def node_prompt(m,binary,old=None):
    n=copy.deepcopy(old) if old else {}
    if not old:
        idx=choose('添加节点类型', [x[1] for x in KINDS]+['从官方核心自动发现新协议（自动生成参数表单）'])
        if idx==len(KINDS):
            from .official_schema import create
            kind=create(binary,CTX);adapter=protocol(kind);default=adapter.default_port
            if not any(x[0]==kind for x in KINDS):KINDS.append((kind,adapter.label,default))
            if adapter.tls:TLS_KINDS.add(kind)
        else:kind,_,default=KINDS[idx]
        n={'id':'node-'+secrets.token_hex(4),'kind':kind,'enabled':True}
    else:
        kind=n['kind']; default=n['port']; print('修改类型：'+kind+'（切换协议请另加节点）')
    n['name']=ask('节点名称',node_name,n.get('name',kind+'-'+n['id'][-4:]))
    # Certificate settings first, so the port check knows the ACME challenge port.
    if kind in TLS_KINDS: acme_prompt(m)
    parse=port_parser(m,kind,n['id'],system_listeners())
    if not old:
        default=suggest_port(parse,default)
    n['port']=ask('监听端口（已自动避开占用端口）' if not old else '监听端口',parse,default)
    if kind in TLS_KINDS:
        n['server']=m['acme']['domain']
    else:
        n['server']=ask('客户端连接的 VPS 公网 IP 或域名',hostname,n.get('server',m.get('acme',{}).get('domain') if m.get('acme') else None))
    if protocol(kind).username: n['username']=prompt('用户名 / 日志标识',n.get('username','user'))
    protocol(kind).prompt(n, CTX, binary)
    return n

def list_nodes(m):
    if not m['nodes']: print('还没有节点。')
    for i,n in enumerate(m['nodes'],1):
        print(f"{i:>2}) {'启用' if n['enabled'] else '停用'} | {n['name']} | {n['kind']} | {n['server']}:{n['port']} | {n['id']}")

def pick(m):
    list_nodes(m)
    if not m['nodes']: fail('没有节点')
    return number(prompt('节点序号'),1,len(m['nodes']))-1

def networks(n):
    return list(protocol(n['kind']).networks)

def validation(m):
    if m.get('schema')!=2: fail('不支持的管理数据格式')
    if not isinstance(m.get('nodes'),list): fail('节点列表无效')
    if m.get('log_level','info') not in {'trace','debug','info','warn','error','fatal','panic'}: fail('日志等级无效')
    if m.get('acme'):
        a=m['acme']; hostname(a['domain'],True); email(a['email'])
        if a['provider'] not in {'letsencrypt','zerossl'} or a['challenge'] not in {'http','tls'} or a['key_type'] not in {'p256','rsa2048'}:
            fail('ACME 设置无效')
    ids=set(); ports=set()
    for n in m['nodes']:
        protocol(n['kind'])
        if not re.fullmatch(r'[a-zA-Z0-9_-]{1,64}',n['id']) or n['id'] in ids: fail('节点标识重复或无效')
        ids.add(n['id']); number(str(n['port'])); hostname(n['server']); node_name(n['name'])
        if type(n['port']) is not int: fail('节点端口必须为整数')
        PROTOCOL_ENGINE.validate_node(n, CTX)
        if not isinstance(n['enabled'],bool): fail('节点状态无效')
        if n['kind'] in TLS_KINDS:
            if not m.get('acme') or n['server']!=m['acme']['domain']: fail('TLS 节点证书域名不一致')
        if n['enabled']:
            for net in networks(n):
                p=(net,n['port'])
                if p in ports: fail(f'节点端口冲突：{net}/{n["port"]}')
                ports.add(p)
    if any(n['enabled'] and n['kind'] in TLS_KINDS for n in m['nodes']):
        cp=80 if m['acme']['challenge']=='http' else 443
        if ('tcp',cp) in ports: fail(f'ACME 挑战端口 TCP/{cp} 与节点冲突；可修改节点端口或更换 ACME 验证方式')
    if m['listen'] not in {'0.0.0.0','::'}: fail('监听地址不支持')

def compile_config(m):
    return PROTOCOL_ENGINE.compile(m,validation)

def client_node(n):
    return PROTOCOL_ENGINE.outbound(n)

def uri(n):
    return PROTOCOL_ENGINE.uri(n)

def export(m,dest):
    dest=pathlib.Path(dest); dest.mkdir(parents=True,exist_ok=True)
    lines=['sing-box 客户端连接资料（含密码；请私密保存）',
        '状态“启用”仅表示配置启用，不代表外网连接已验证。',
        '各客户端 URI 支持不同；导入失败按字段手工填写。客户端需要支持对应协议。',
        '单独 username 通常是日志标签；Naive 的 username 是认证字段。不要拼接为 username:password。']
    outs=[]; links=[]
    for n in m['nodes']:
        lines+=['',f'===== {n["name"]} / {n["kind"]} / {"启用" if n["enabled"] else "停用"} =====',
                '节点 ID: '+n['id'],f'服务器: {n["server"]}',f'端口: {n["port"]}',f'传输: {" + ".join(networks(n)).upper()}']
        for key,title in [('username','用户名'),('password','密码'),('uuid','UUID'),('method','加密方法'),('obfs','Salamander 混淆密码'),('path','WebSocket 路径'),('public_key','Reality 公钥'),('short_id','Reality short ID')]:
            if key in n: lines.append(title+': '+n[key])
        if n['kind'] in TLS_KINDS: lines += ['TLS: 开启；跳过证书验证: 否','SNI: '+n['server']]
        lines += protocol(n['kind']).summary(n)
        if n['enabled']:
            link=uri(n)
            if link:lines+=['参考导入链接:',link];links.append(link)
            else:lines+=['此模块未设置导入 URI，请使用客户端 JSON 或按字段手动填写。']
            outs.append(client_node(n))
        else: lines+=['此节点已停用，不加入导入链接与客户端配置。']
    for name,text in [('client-info.txt','\n'.join(lines)+'\n'),('links.txt','\n'.join(links)+'\n')]:
        (dest/name).write_text(text); os.chmod(dest/name,0o600)
    save(dest/'client-outbounds.json',{'outbounds':outs})

def ports(m):
    validation(m); result=set()
    for n in m['nodes']:
        if n['enabled']: result.update((p,n['port']) for p in networks(n))
    if any(n['enabled'] and n['kind'] in TLS_KINDS for n in m['nodes']): result.add(('tcp',80 if m['acme']['challenge']=='http' else 443))
    return sorted(result)

def preflight(m):
    listeners=system_listeners(); busy=[]
    for net,p in ports(m):
        who=listeners.get((net,p))
        if who and who != 'sing-box': busy.append(f'{net}/{p} ← {who}')
    if busy: fail('以下端口被其他进程占用，提交后无法监听；请先停用占用程序或修改节点端口：'+'；'.join(busy))
    print('端口预检通过（sing-box 自身占用的端口会在切换时释放）。')

def verify_dns(m):
    names={n['server'] for n in m['nodes'] if n['enabled']}
    if not names: return
    public=set()
    for family,url in [(socket.AF_INET,'https://api.ipify.org'),(socket.AF_INET6,'https://api6.ipify.org')]:
        try:
            s=subprocess.check_output(['curl','-4' if family==socket.AF_INET else '-6','-fsS','--connect-timeout','5','--max-time','10',url],stderr=subprocess.DEVNULL,text=True).strip()
            public.add(ipaddress.ip_address(s))
        except (subprocess.CalledProcessError,ValueError): pass
    if not public: fail('无法检测本机公网 IP；请检查网络后重试')
    print('检测到公网 IP：'+', '.join(map(str,sorted(public,key=str))))
    has6=False
    for name in sorted(names):
        try: addresses={ipaddress.ip_address(name)}
        except ValueError:
            addresses=set()
            for typ in ['A','AAAA']:
                s=subprocess.check_output(['dig','+time=3','+tries=1','+short',typ,name],text=True)
                for line in s.splitlines():
                    try: addresses.add(ipaddress.ip_address(line.strip()))
                    except ValueError: pass
        print(name+' => '+(', '.join(map(str,sorted(addresses,key=str))) or '无解析'))
        if not addresses or not addresses.issubset(public): fail('节点地址未全部匹配本机公网 IP；检查 A/AAAA、CDN、多 IP/NAT。脚本不会跳过')
        has6 |= any(x.version==6 for x in addresses)
    for n in m['nodes']:
        if n['enabled']: protocol(n['kind']).netcheck(n, CTX)
    m['listen']='::' if has6 else '0.0.0.0' 
    if has6:
        if subprocess.check_output(['sysctl','-n','net.ipv6.bindv6only'],text=True).strip()!='0': fail('bindv6only 必须为 0，才能使用双栈监听')

def import_v1(path):
    c=load(path); m=new_model()
    expected={'log','certificate_providers','inbounds','outbounds','route'}
    if set(c)-expected or c.get('outbounds')!=[{'type':'direct','tag':'direct'}] or c.get('route')!={'final':'direct'}: fail('不是可识别的旧脚本配置；保留原配置，不自动接管自定义规则')
    providers=c.get('certificate_providers',[])
    if len(providers)!=1 or providers[0].get('type')!='acme': fail('旧配置证书结构无法安全迁移')
    a=providers[0]
    if len(a['domain'])!=1 or a.get('dns01_challenge') or a.get('alternative_http_port') or a.get('alternative_tls_port'): fail('旧 ACME 配置超出迁移范围')
    if bool(a.get('disable_http_challenge'))==bool(a.get('disable_tls_alpn_challenge')): fail('旧挑战模式不能安全迁移')
    m['acme']={'domain':a['domain'][0],'email':a['email'],'provider':a['provider'],'challenge':'tls' if a.get('disable_http_challenge') else 'http','key_type':a.get('key_type','p256')}
    for x in c['inbounds']:
        k=x['type']
        if k not in {'anytls','hysteria2'} or len(x.get('users',[]))!=1: fail('旧配置含不支持的节点，停止迁移')
        n={'id':x['tag'],'name':x['tag'],'kind':k,'enabled':True,'port':x['listen_port'],'server':a['domain'][0],
           'username':x['users'][0]['name'],'password':x['users'][0]['password']}
        if k=='hysteria2': n.update({'obfs':x['obfs']['password'],'bbr':x.get('bbr_profile','standard')})
        m['nodes'].append(n); m['listen']=x['listen']
    # Exact round trip rejects hand-added routing, users, TLS and other unknown fields.
    if compile_config(m)!=c: fail('旧配置有自定义字段或不同默认值；拒绝覆盖，请人工迁移')
    return m

def releases(source,out,arch):
    data=load(source)
    if not isinstance(data,list): fail('GitHub API 返回错误，可能触发限流')
    rows=[]
    for r in data:
        tag=r.get('tag_name','')
        if r.get('draft') or not re.fullmatch(r'v\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?',tag): continue
        ver=tag[1:]; nums=tuple(map(int,ver.split('-')[0].split('.')))
        if nums<(1,14,0): continue
        filename=f'sing-box-{ver}-linux-{arch}.tar.gz'
        a=next((a for a in r.get('assets',[]) if a.get('name')==filename),None)
        if not a: continue
        url=a.get('browser_download_url',''); digest=a.get('digest') or ''
        if not url.startswith('https://github.com/SagerNet/sing-box/releases/download/'+tag+'/'): continue
        if not re.fullmatch(r'sha256:[0-9a-f]{64}',digest): continue
        rows.append({'version':ver,'preview':r.get('prerelease',False),'published':r.get('published_at',''),
                     'url':url,'sha256':digest[7:],'asset':filename,'member':f'sing-box-{ver}-linux-{arch}/sing-box'})
    if not rows: fail('未找到本架构带官方 SHA-256 的可用版本；不安装未验证文件')
    # GitHub /latest is not the same as the most recently published prerelease.
    rows.sort(key=lambda r:r['published'],reverse=True)
    stable=max((r for r in rows if not r['preview'] and '-' not in r['version']), key=lambda r:tuple(map(int,r['version'].split('.'))), default=None)
    if not stable: fail('此次查询未找到稳定版；停止，避免误将测试版作为稳定版')
    save(out,{'stable':stable,'latest':rows[0],'all':rows})

def vkey(v):
    """Semver-ish ordering: 1.15.0-alpha.10 > 1.15.0-alpha.9, and 1.15.0 > any 1.15.0-*."""
    base,_,pre=v.partition('-')
    nums=tuple(int(x) for x in base.split('.'))
    if not pre: return nums+((1,),)
    return nums+((0,)+tuple((0,int(x)) if x.isdigit() else (1,x) for x in pre.split('.')),)

def compare_note(v,current):
    if not current: return ''
    try: a,b=vkey(v),vkey(current)
    except ValueError: return ''
    return '（与当前相同）' if a==b else ('（比当前新，可升级）' if a>b else '（比当前旧，选择即降级）')

def version_summary(r,current):
    s=r['stable']; l=r['latest']
    print('官方版本（本次实时查询）：')
    print('当前运行版本：'+(current or '未安装 / 无法读取'))
    print(f"最新稳定版：{s['version']} / {s['published'][:10]}{compare_note(s['version'],current)}")
    print(f"最新发布版：{l['version']} / {'测试版' if l['preview'] else '稳定版'} / {l['published'][:10]}{compare_note(l['version'],current)}")
    if current:
        try: newer=vkey(s['version'])>vkey(current)
        except ValueError: newer=None
        if newer: print('结论：有新的稳定版，建议升级。')
        elif newer is False: print('结论：当前已是最新稳定版（或更新），通常无需升级。')

def select_release(p,out,current=''):
    r=load(p); s=r['stable']; l=r['latest']
    version_summary(r,current)
    ch=choose('安装版本',['最新稳定版（推荐）','最新发布版（可能是 alpha / beta）','从本次查询的其他版本中选择'])
    if ch==0: x=s
    elif ch==1: x=l
    else:
        idx=choose('版本列表',[f"{v['version']} ({'测试' if v['preview'] else '稳定'}){'（当前运行）' if v['version']==current else ''}" for v in r['all']]); x=r['all'][idx]
    if x['preview'] and x['version']!=current and prompt('测试版可能有不兼容改动，输入 PREVIEW 确认')!='PREVIEW': fail('未选择测试版')
    save(out,x)

def extract_release(meta,archive,dest,companions=None):
    r=load(meta); actual=hashlib.sha256(pathlib.Path(archive).read_bytes()).hexdigest()
    if actual!=r['sha256']: fail('下载 SHA-256 与官方发布元数据不符')
    with tarfile.open(archive,'r:gz') as t:
        members=[m for m in t.getmembers() if m.name==r['member']]
        if len(members)!=1 or not members[0].isfile(): fail('官方压缩包内二进制结构异常')
        f=t.extractfile(members[0]); pathlib.Path(dest).write_bytes(f.read())
        if companions:
            directory=pathlib.Path(companions); directory.mkdir(parents=True,exist_ok=True)
            for name in RUNTIME_LIBRARIES:
                expected=str(pathlib.PurePosixPath(r['member']).parent/name)
                hits=[m for m in t.getmembers() if m.name==expected]
                if not hits:continue
                if len(hits)!=1 or not hits[0].isfile() or hits[0].size>256*1024*1024:fail('官方运行库结构异常')
                target=directory/name; target.write_bytes(t.extractfile(hits[0]).read());os.chmod(target,0o600)
    os.chmod(dest,0o755)

def probe(m):
    for n in m['nodes']:
        if not n['enabled'] or n['kind'] not in TLS_KINDS: continue
        if 'tcp' not in networks(n):
            print(n['name']+': UDP/QUIC，请使用外网客户端测试。'); continue
        args=['openssl','s_client','-connect',f'127.0.0.1:{n["port"]}','-servername',n['server'],
              '-verify_hostname',n['server'],'-verify_return_error','-CApath','/etc/ssl/certs']
        if n['kind']=='naive': args+=['-alpn','h2']
        try:
            r=subprocess.run(args,input='',text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=10)
            print(n['name']+(': 本机 TLS 证书验证通过（不代表公网可达）' if r.returncode==0 else ': 证书/握手未就绪，检查签发日志及验证端口'))
        except subprocess.TimeoutExpired: print(n['name']+': 本机 TLS 测试超时')

def human(n):
    for unit in ['B','KiB','MiB','GiB','TiB']:
        if n<1024 or unit=='TiB': return (f'{n:.0f} {unit}' if unit=='B' else f'{n:.1f} {unit}')
        n/=1024

def duration(sec):
    sec=int(sec); d,sec=divmod(sec,86400); h,sec=divmod(sec,3600); mi=sec//60
    return f'{d} 天 {h} 小时' if d else (f'{h} 小时 {mi} 分' if h else f'{mi} 分钟')

def read(path,default=''):
    try: return pathlib.Path(path).read_text()
    except OSError: return default

def run_text(args,timeout=5):
    try: return subprocess.run(args,text=True,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,timeout=timeout).stdout
    except (OSError,subprocess.SubprocessError): return ''

def cpu_percent(interval=0.4):
    def sample():
        f=[int(x) for x in read('/proc/stat').split('\n',1)[0].split()[1:]]
        return sum(f), f[3]+(f[4] if len(f)>4 else 0)
    try:
        t1,i1=sample(); import time; time.sleep(interval); t2,i2=sample()
        return 100.0*(1-(i2-i1)/max(t2-t1,1))
    except (ValueError,IndexError): return None

def meminfo():
    m={}
    for line in read('/proc/meminfo').splitlines():
        k,_,v=line.partition(':')
        try: m[k]=int(v.split()[0])*1024
        except (ValueError,IndexError): pass
    return m

def default_iface():
    for line in read('/proc/net/route').splitlines()[1:]:
        f=line.split()
        if len(f)>2 and f[1]=='00000000': return f[0]
    return None

def iface_bytes(name):
    for line in read('/proc/net/dev').splitlines():
        k,_,v=line.partition(':')
        if k.strip()==name:
            f=v.split(); return int(f[0]),int(f[8])
    return None

def service_inbounds(conf_dir):
    """[(label, kind, port, nets)] of what the live config listens on, managed or not."""
    mj=pathlib.Path(conf_dir)/'manager.json'
    if mj.exists():
        m=load(mj)
        return [(n['name'],n['kind'],n['port'],networks(n),n['enabled']) for n in m['nodes']],True
    try: c=load(pathlib.Path(conf_dir)/'config.json')
    except (OSError,ValueError): return [],False
    rows=[]
    for x in c.get('inbounds',[]):
        k=x.get('type','?'); p=x.get('listen_port')
        if not isinstance(p,int): continue
        nets=['udp'] if k in {'hysteria2','tuic','hysteria'} else (['tcp','udp'] if k=='shadowsocks' else ['tcp'])
        rows.append((x.get('tag',k),k,p,nets,True))
    return rows,False

def established(ports):
    """{port: [peer ip,...]} for established inbound TCP connections to sing-box node ports."""
    out=run_text(['ss','-Htnp','state','established']); res={p:[] for p in ports}
    for line in out.splitlines():
        if 'sing-box' not in line: continue
        f=line.split()
        if len(f)<4: continue
        try: lp=int(f[2].rsplit(':',1)[1])
        except (IndexError,ValueError): continue
        if lp in res: res[lp].append(f[3].rsplit(':',1)[0].strip('[]').replace('::ffff:',''))
    return res

def cert_status(domain):
    hits=sorted(pathlib.Path('/var/lib/sing-box/acme/certificates').glob(f'*/{domain}/{domain}.crt'))
    if not hits: return '未找到缓存证书（首次签发需等待几分钟，或检查 ACME 验证端口）'
    s=run_text(['openssl','x509','-noout','-enddate','-in',str(hits[-1])]).strip()
    try:
        end=datetime.datetime.strptime(s.split('=',1)[1],'%b %d %H:%M:%S %Y %Z').replace(tzinfo=datetime.timezone.utc)
    except (IndexError,ValueError): return '无法解析证书到期时间'
    days=(end-datetime.datetime.now(datetime.timezone.utc)).days
    warn='  ⚠ 少于 15 天，请检查自动续期' if days<15 else ''
    return f'剩余 {days} 天（{end:%Y-%m-%d} 到期）{warn}'

def dashboard(conf_dir,state_dir,current):
    import unicodedata
    def W(k,v):
        width=sum(2 if unicodedata.east_asian_width(ch) in 'WF' else 1 for ch in k)
        print(k+' '*max(1,10-width)+v)
    os_name=next((l.split('=',1)[1].strip('"') for l in read('/etc/os-release').splitlines() if l.startswith('PRETTY_NAME=')),'Linux')
    u=os.uname(); up=float(read('/proc/uptime','0').split()[0] or 0); load1=os.getloadavg(); cores=os.cpu_count() or 1
    print('==================== 服务器概况 ====================')
    W('主机',f'{socket.gethostname()} ｜ {os_name} ｜ 内核 {u.release} ｜ {u.machine}')
    W('运行',f'{duration(up)} ｜ 负载 {load1[0]:.2f} {load1[1]:.2f} {load1[2]:.2f}（{cores} 核）')
    c=cpu_percent(); W('CPU',f'{c:.0f}%' if c is not None else '无法读取')
    m=meminfo(); tot=m.get('MemTotal',0); used=tot-m.get('MemAvailable',0); st=m.get('SwapTotal',0); su=st-m.get('SwapFree',0)
    W('内存',f'{human(used)} / {human(tot)}（{100*used/max(tot,1):.0f}%）｜ Swap {human(su)} / {human(st)}'+('  ⚠ 内存紧张' if tot and used/tot>0.9 else ''))
    import shutil; d=shutil.disk_usage('/')
    W('磁盘 /',f'{human(d.used)} / {human(d.total)}（{100*d.used/d.total:.0f}%），剩余 {human(d.free)}'+('  ⚠ 空间不足' if d.free<1<<30 else ''))
    ifc=default_iface()
    if ifc:
        b=iface_bytes(ifc); addrs=[l.split()[3] for l in run_text(['ip','-o','addr','show','dev',ifc,'scope','global']).splitlines() if len(l.split())>3]
        if b: W('流量',f'{ifc} ↓ {human(b[0])}  ↑ {human(b[1])}（开机以来）')
        if addrs: W('地址',' '.join(a.split('/')[0] for a in addrs))
    cc=read('/proc/sys/net/ipv4/tcp_congestion_control').strip() or '?'; q=read('/proc/sys/net/core/default_qdisc').strip() or '?'
    W('TCP',f'拥塞控制 {cc} ｜ 队列 {q}'+('' if cc=='bbr' else '  （可用菜单 27 开启 BBR）'))
    ntp=run_text(['timedatectl','show','-p','NTPSynchronized','--value']).strip()
    W('时间',{'yes':'已同步','no':'未同步 ⚠ 会导致 TLS / Reality 连接失败'}.get(ntp,'无法确认'))
    print('---------------------- sing-box ----------------------')
    prop=dict(l.split('=',1) for l in run_text(['systemctl','show','sing-box','-p','ActiveState','-p','MainPID','-p','NRestarts','-p','UnitFileState']).splitlines() if '=' in l)
    state={'active':'运行中','inactive':'已停止','failed':'失败 ⚠','activating':'启动中'}.get(prop.get('ActiveState',''),prop.get('ActiveState','未安装') or '未安装')
    pid=prop.get('MainPID','0'); extra=''
    if pid.isdigit() and pid!='0':
        try:
            stat=read(f'/proc/{pid}/stat').rsplit(')',1)[1].split(); tck=os.sysconf('SC_CLK_TCK')
            rss=next((int(l.split()[1])*1024 for l in read(f'/proc/{pid}/status').splitlines() if l.startswith('VmRSS:')),0)
            extra=f'，已运行 {duration(up-int(stat[19])/tck)} ｜ 内存 {human(rss)} ｜ CPU 累计 {(int(stat[11])+int(stat[12]))/tck:.0f} 秒'
        except (IndexError,ValueError): pass
    W('状态',state+extra+f" ｜ 重启 {prop.get('NRestarts','?')} 次 ｜ 开机自启 {'是' if prop.get('UnitFileState')=='enabled' else '否'}")
    cache=read(pathlib.Path(state_dir)/'latest-stable').split()
    vline=current or '未安装'
    if cache and current:
        try: vline+=f'（最新稳定版 {cache[0]}，'+('可升级' if vkey(cache[0])>vkey(current) else '已是最新')+f'｜查询于 {cache[1] if len(cache)>1 else "?"}）'
        except ValueError: pass
    elif current: vline+='（菜单 11 可查询最新版本）'
    W('版本',vline)
    rows,managed=service_inbounds(conf_dir)
    if not rows: W('节点','暂无')
    else:
        on=[r for r in rows if r[4]]
        W('节点',f"启用 {len(on)} / 共 {len(rows)}"+('' if managed else '  （现有配置尚未由脚本接管：菜单 23 接管）'))
        conns=established([r[2] for r in on if 'tcp' in r[3]])
        for label,kind,port,nets,en in rows:
            if not en: tail='停用'
            elif 'tcp' in nets:
                ips=conns.get(port,[]); tail=f'TCP 连接 {len(ips)} 条 / {len(set(ips))} 个 IP'
            else: tail='UDP/QUIC（连接数无法统计）'
            print(f"          · {label} | {kind} | {'+'.join(nets).upper()}/{port} | {tail}")
    domains=set()
    if managed:
        a=load(pathlib.Path(conf_dir)/'manager.json').get('acme')
        if a: domains.add(a['domain'])
    else:
        try:
            for p in load(pathlib.Path(conf_dir)/'config.json').get('certificate_providers',[]): domains.update(p.get('domain',[]))
        except (OSError,ValueError): pass
    for dmn in sorted(domains): W('证书',f'{dmn} {cert_status(dmn)}')
    try: listeners=system_listeners()
    except ValueError: listeners={}
    others=sorted({n for (net,p),n in listeners.items()}-{'sing-box','sshd','systemd-resolve','exim4','chronyd','systemd-timesyncd','未知进程'})
    if others: W('其他',f"本机还有其他程序在监听：{', '.join(others)}（新增节点时会自动避开它们的端口）")
    flags=[]
    if (pathlib.Path(state_dir)/'draft.json').exists(): flags.append('有未提交草稿（菜单 22）')
    if (pathlib.Path(state_dir)/'pending').exists(): flags.append('有未完成事务 ⚠')
    if flags: W('提醒','；'.join(flags))

def connections(conf_dir):
    rows,_=service_inbounds(conf_dir)
    on=[r for r in rows if r[4]]
    if not on: print('没有启用的节点。'); return
    conns=established([r[2] for r in on if 'tcp' in r[3]]); total=[]
    for label,kind,port,nets,_ in on:
        if 'tcp' not in nets: print(f'{label} | {kind} | UDP/{port} | QUIC/UDP 无连接状态，无法统计'); continue
        ips=conns.get(port,[]); total+=ips
        top=', '.join(f'{ip}×{ips.count(ip)}' for ip in sorted(set(ips),key=lambda x:-ips.count(x))[:5])
        print(f'{label} | {kind} | TCP/{port} | {len(ips)} 条连接，{len(set(ips))} 个来源 IP'+(f' | {top}' if top else ''))
    print(f'合计 TCP：{len(total)} 条，{len(set(total))} 个来源 IP。连接数不等于在线人数；UDP 节点需看客户端。')

def log_summary(since='1 hour ago'):
    out=run_text(['journalctl','-u','sing-box','--since',since,'--no-pager','-o','cat'],timeout=15).splitlines()
    clean=[re.sub(r'\x1b\[[0-9;]*m','',l) for l in out]
    inbound=sum('inbound connection from' in l for l in clean)
    tls=[l for l in clean if 'TLS handshake' in l]
    other=[l for l in clean if ('ERROR' in l or 'WARN' in l or 'FATAL' in l) and 'TLS handshake' not in l]
    print(f'最近 1 小时日志：入站连接 {inbound} 次；TLS 握手失败 {len(tls)} 次（需结合客户端连接时间排查，也可能是扫描探测）；其他警告/错误 {len(other)} 条。')
    for l in other[-8:]: print('  '+l[:220])
    if not other: print('  没有需要关注的其他错误。')

def draft_fingerprint(conf):
    conf=pathlib.Path(conf)
    return {name:hashlib.sha256((conf/name).read_bytes()).hexdigest() if (conf/name).exists() else None
            for name in ['config.json','manager.json']}

def main():
    cmd=sys.argv[1]; args=sys.argv[2:]
    if cmd=='backup-seal': return backup_seal(*args)
    if cmd=='backup-complete': return backup_complete(*args)
    if cmd=='runtime-id': print(runtime_identity(*args)); return
    if cmd=='runtime-copy-libs': return runtime_copy_libraries(*args)
    if cmd=='runtime-info':
        info=Runtime(args[0]).info()
        if '--json' in args: print(json.dumps(info))
        else: print('sing-box '+info['version']+' | 构建能力：'+', '.join(info['tags']))
        return
    if cmd=='backup-verify': return backup_verify(*args)
    if cmd=='pending-write': return pending_write(*args)
    if cmd=='pending-clear': return pending_clear(*args)
    if cmd=='audit-append': return audit.append(*args)
    if cmd=='audit-verify':
        report=audit.verify(args[0])
        if '--json' in args: print(json.dumps(report))
        else: print(f"审计链：通过 | {report['entries']} 条记录 | {report['last_hash']}")
        return
    if cmd in {'compatibility','module-test','compile-checked'}:
        if cmd=='compatibility':
            report=PROTOCOL_ENGINE.compatibility(load(args[0]),args[1],validation)
            passed=report['compatible']
        elif cmd=='module-test':
            report=PROTOCOL_ENGINE.module_tests(args[0],CTX,args[1] if len(args)>1 and not args[1].startswith('--') else 'all')
            passed=report['passed']
        else:
            report=PROTOCOL_ENGINE.compiler.checked(load(args[0]),args[1],args[2],validation,save,PROTOCOL_ENGINE.compatibility)
            passed=report['passed']
        if '--json' in args: print(json.dumps(report,ensure_ascii=False))
        else:
            print('运行版本：'+report['runtime']['version'])
            for row in report.get('nodes',report.get('modules',[])):
                ok=row['result']=='PASS' if cmd=='module-test' else row.get('compatible',True)
                detail='；'.join(row.get('issues',[])) or row.get('reason','')
                print(row['protocol']+': '+('通过' if ok else '失败')+(' | '+detail if detail else '')+('（已停用，不阻止当前部署）' if row.get('enabled') is False else ''))
            if cmd=='module-test': print('以上为离线配置检查；没有启动监听或验证公网传输。')
            if cmd=='compile-checked': print('统一编译 / 官方配置检查：'+('通过' if passed else '失败'))
        if not passed: sys.exit(1)
        return
    if cmd=='draft-save':
        m=load(args[0]); validation(m)
        save(args[1],{'model':m,'base':draft_fingerprint(args[2]),'mode':args[3]})
        return
    if cmd=='draft-load':
        d=load(args[0])
        if d['base']!=draft_fingerprint(args[1]): fail('保存草稿后当前配置已变化，拒绝覆盖。请重新编辑，或先人工核查草稿')
        if d.get('mode') not in {'start','preserve'}: fail('草稿启动模式无效')
        validation(d['model']); save(args[2],d['model']); return
    if cmd=='catalog':
        version_summary(load(args[0]),args[1] if len(args)>1 else '')
        print('来源：SagerNet/sing-box 官方 GitHub；查询失败时不使用旧缓存。'); return
    if cmd=='releases': return releases(*args)
    if cmd=='select-release': return select_release(*args)
    if cmd=='extract': return extract_release(*args)
    if cmd=='new': save(args[0],new_model()); return
    if cmd=='profile':
        from .profile_manager import command
        return command(args,CTX)
    if cmd=='official':
        from .official_schema import command
        return command(args,CTX)
    if cmd=='protocols':
        rows=PROTOCOL_ENGINE.catalog()
        if '--text' not in args: print(json.dumps(rows,ensure_ascii=False))
        else:
            for r in rows: print(f"{r['kind']:<12} {r['label']} | 模块 {r['module_version']} | API {r['api']} | 模板最低 {r['minimum_runtime']} | {'+'.join(r['networks'])}")
        return
    if cmd=='migrate': save(args[1],import_v1(args[0])); return
    if cmd=='dashboard': return dashboard(*args)
    if cmd=='connections': return connections(*args)
    if cmd=='logsummary': return log_summary()
    if cmd=='get':
        v=load(args[0])
        for k in args[1].split('.'): v=v[k]
        print(v); return
    m=load(args[0]); validation(m)
    if cmd=='list': return list_nodes(m)
    if cmd=='probe': return probe(m)
    if cmd=='compile': save(args[1],compile_config(m)); return
    if cmd=='export': return export(m,args[1])
    if cmd in {'ports','nodeports'}:
        entries=ports(m) if cmd=='ports' else sorted({(net,n['port']) for n in m['nodes'] if n['enabled'] for net in networks(n)})
        for net,p in entries: print(net,p)
        return
    if cmd=='netcheck': verify_dns(m); save(args[0],m); return
    if cmd=='preflight': return preflight(m)
    if cmd=='count':
        print(f"{sum(n['enabled'] for n in m['nodes'])}/{len(m['nodes'])}"); return
    if cmd=='verify-generated':
        if compile_config(m)!=load(args[1]): fail('检测到 config.json 在脚本外被修改。为保护自定义配置，暂停改动；请先备份并处理差异')
        return
    if cmd=='acme': acme_prompt(m,True)
    elif cmd=='loglevel': m['log_level']=['info','warn','debug'][choose('日志等级（debug 可能包含访问详情）',['info','warn','debug'])]
    elif cmd=='add':
        before=len(m['nodes'])
        while True:
            m['nodes'].append(node_prompt(m,args[1]))
            try: validation(m)
            except ValueError as e:
                m['nodes'].pop(); print('该节点未加入草稿：'+str(e)+'；已添加的其他节点保留。')
            if prompt('继续添加其他节点？y/N','N').lower()!='y': break
        if len(m['nodes'])==before: fail('本次没有新增节点')
    elif cmd=='edit':
        i=pick(m); m['nodes'][i]=node_prompt(m,args[1],m['nodes'][i])
    elif cmd=='toggle':
        i=pick(m); m['nodes'][i]['enabled']=not m['nodes'][i]['enabled']
    elif cmd=='delete':
        i=pick(m)
        if prompt('输入 DELETE 删除此节点')!='DELETE': fail('取消删除')
        del m['nodes'][i]
    elif cmd=='rotate':
        n=m['nodes'][pick(m)]
        if prompt('旧客户端凭据将失效；输入 ROTATE 确认')!='ROTATE': fail('取消重置')
        protocol(n['kind']).rotate(n, CTX, args[1])
    else: fail('未知操作 '+cmd)
    validation(m); save(args[0],m)

def run():
    try: main()
    except (ValueError,KeyError,TypeError,AttributeError,IndexError,OSError,EOFError,subprocess.SubprocessError) as e:
        print('错误：'+str(e),file=sys.stderr); sys.exit(1)
    except KeyboardInterrupt: print('\n已取消，未提交的编辑已丢弃。',file=sys.stderr); sys.exit(130)
