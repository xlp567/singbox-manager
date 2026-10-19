#!/usr/bin/env python3
"""Signed formal-Release installer; existing managers use menu 30."""
import base64
import fcntl
import getpass
import hashlib
import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
"""Pinned release signatures and static inspection; never executes a candidate."""
import hashlib
import json
import os
import pathlib
import re
import subprocess
import tempfile
import urllib.error
import urllib.parse
import urllib.request

PUBLIC_KEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAW8DuzbY0y6ySdV3EfX0XtEe7NogBEQ4GTbFfgadED/ singbox-manager-release'
SIGNER='singbox-manager-release'
NAMESPACE='singbox-manager-release'
TRUST_LIMIT=2*1024*1024


def version_tuple(value):
    if not re.fullmatch(r'\d+\.\d+(?:\.\d+)?',value):raise ValueError('正式版本号无效')
    return tuple(map(int,(value+'.0').split('.')[:3]))


def static_script_info(data):
    if not data.startswith(b'#!/usr/bin/env bash\n# singbox-manager v'):raise ValueError('不是本项目管理脚本')
    text=data.decode('utf8')
    rows=re.findall(r'^SBM_VERSION=(\d+\.\d+(?:\.\d+)?)$',text,re.M)
    if len(rows)!=1 or len(re.findall(r'^SBM_VERSION=',text,re.M))!=1:raise ValueError('管理脚本静态版本标识无效')
    return {'version':rows[0],'sha256':hashlib.sha256(data).hexdigest(),'bytes':len(data)}


def verify_signature(manifest,signature):
    if len(manifest)>65536 or len(signature)>16384:raise ValueError('签名或校验清单过大')
    with tempfile.TemporaryDirectory(prefix='sbm-signature-') as folder:
        root=pathlib.Path(folder);allowed=root/'allowed_signers';sig=root/'manifest.sig'
        allowed.write_text(SIGNER+' '+PUBLIC_KEY+'\n');sig.write_bytes(signature)
        try:
            result=subprocess.run(['ssh-keygen','-Y','verify','-f',str(allowed),'-I',SIGNER,'-n',NAMESPACE,'-s',str(sig)],
                input=manifest,capture_output=True,timeout=15,env={'PATH':os.defpath,'LC_ALL':'C'})
        except FileNotFoundError:raise ValueError('缺少签名验证工具 ssh-keygen；请安装 openssh-client') from None
        if result.returncode:raise ValueError('发布签名验证失败，未执行候选程序')


def parse_manifest(data,tag=None):
    lines=data.decode('ascii').splitlines()
    if not lines or not re.fullmatch(r'# singbox-manager release v\d+\.\d+\.\d+',lines[0]):raise ValueError('发布校验清单头无效')
    signed_tag=lines[0].rsplit(' ',1)[1]
    if tag and signed_tag!=tag:raise ValueError('签名清单与正式 Release 标签不一致')
    files={}
    for line in lines[1:]:
        match=re.fullmatch(r'([a-f0-9]{64})  ([A-Za-z0-9][A-Za-z0-9_.-]{0,120})',line)
        if not match or match[2] in files:raise ValueError('发布校验清单格式无效')
        files[match[2]]=match[1]
    return signed_tag,files


def verify_directory(directory,required=('singbox-manager.sh','singbox-manager.sha256'),tag=None):
    directory=pathlib.Path(directory)
    def read(name,limit):
        p=directory/name
        if p.is_symlink() or not p.is_file() or p.stat().st_size>limit:raise ValueError('缺少普通签名发布文件：'+name)
        return p.read_bytes()
    manifest=read('SHA256SUMS',65536);signature=read('SHA256SUMS.sig',16384)
    verify_signature(manifest,signature);signed_tag,files=parse_manifest(manifest,tag)
    for name in required:
        if name not in files or hashlib.sha256(read(name,TRUST_LIMIT)).hexdigest()!=files[name]:raise ValueError('签名发布文件摘要不符：'+name)
    if 'singbox-manager.sh' in required:
        info=static_script_info(read('singbox-manager.sh',TRUST_LIMIT))
        if 'v'+info['version']!=signed_tag:raise ValueError('管理器静态版本与签名标签不符')
    return signed_tag


class ReleaseAssetRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self,req,fp,code,msg,headers,newurl):
        target=urllib.parse.urlsplit(newurl)
        if target.scheme!='https' or target.username or target.password or not target.hostname or not target.hostname.endswith('.githubusercontent.com'):
            raise ValueError('发布附件跳转到非 GitHub 文件主机，已拒绝')
        # Never forward repository credentials to the redirected asset host.
        return urllib.request.Request(newurl,headers={'User-Agent':'singbox-manager-release'})


def asset_bytes(url,token=''):
    if not re.fullmatch(r'https://api\.github\.com/repos/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/releases/assets/\d+',url):raise ValueError('发布附件地址无效')
    headers={'Accept':'application/octet-stream','User-Agent':'singbox-manager-release','X-GitHub-Api-Version':'2022-11-28'}
    if token:headers['Authorization']='Bearer '+token
    try:
        with urllib.request.build_opener(ReleaseAssetRedirect).open(urllib.request.Request(url,headers=headers),timeout=30) as response:
            data=response.read(TRUST_LIMIT+1)
    except urllib.error.HTTPError as error:raise ValueError('发布附件读取失败（HTTP '+str(error.code)+'）') from None
    except urllib.error.URLError:raise ValueError('无法下载正式发布附件') from None
    if len(data)>TRUST_LIMIT:raise ValueError('发布附件超过大小限制')
    return data


def download_release(api,destination,required,json_request,asset_request=asset_bytes,token='',current_version='',release=None):
    release=release or json_request(api+'/releases/latest',token)
    tag=release.get('tag_name','')
    if release.get('draft') is not False or release.get('prerelease') is not False or not re.fullmatch(r'v\d+\.\d+\.\d+',tag):
        raise ValueError('最新正式 Release 元数据无效；不回退 main 或测试版')
    if current_version and version_tuple(tag[1:])<version_tuple(current_version):raise ValueError('正式 Release 比当前管理器更旧，拒绝自动降级')
    assets=release.get('assets',[]);names={}
    if not isinstance(assets,list):raise ValueError('发布附件清单无效')
    for item in assets:
        if not isinstance(item,dict) or item.get('name') in names:raise ValueError('发布附件名称重复或无效')
        names[item.get('name')]=item
    destination=pathlib.Path(destination)
    for name in ['SHA256SUMS','SHA256SUMS.sig',*required]:
        item=names.get(name)
        if not item or type(item.get('id')) is not int or type(item.get('size')) is not int or not 0<item['size']<=TRUST_LIMIT:
            raise ValueError('最新正式 Release 缺少签名附件：'+name)
        data=asset_request(api+'/releases/assets/'+str(item['id']),token)
        if len(data)!=item['size']:raise ValueError('发布附件长度不符')
        p=destination/name
        if p.is_symlink():raise ValueError('发布附件目标不得为符号链接')
        p.write_bytes(data);p.chmod(0o600)
        if name=='SHA256SUMS.sig':
            verify_signature((destination/'SHA256SUMS').read_bytes(),data)
            parse_manifest((destination/'SHA256SUMS').read_bytes(),tag)
    verify_directory(destination,required,tag)
    reference=json_request(api+'/git/ref/tags/'+tag,token).get('object',{})
    if reference.get('type')=='tag':reference=json_request(api+'/git/tags/'+reference.get('sha',''),token).get('object',{})
    commit=reference.get('sha','')
    if reference.get('type')!='commit' or not re.fullmatch(r'[a-f0-9]{40}',commit):raise ValueError('正式 Release 标签提交无效')
    return {'tag':tag,'commit':commit,'signature_verified':True}


REPOSITORY='xlp567/singbox-manager'
CHANNEL='stable'
API='https://api.github.com/repos/'+REPOSITORY
LIMIT=2*1024*1024


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self,*args,**kwargs):
        raise ValueError('GitHub 返回跳转，已停止，令牌不会发送到其他地址')


def request(path,token):
    if not re.fullmatch(r'/releases/latest|/git/ref/tags/v\d+\.\d+\.\d+|/git/tags/[a-f0-9]{40}',path):
        raise ValueError('拒绝非本仓库安装地址')
    headers={'Accept':'application/vnd.github+json','User-Agent':'singbox-manager-install',
             'X-GitHub-Api-Version':'2022-11-28'}
    if token:headers['Authorization']='Bearer '+token
    for attempt in range(2):
        try:
            with urllib.request.build_opener(NoRedirect).open(urllib.request.Request(API+path,headers=headers),timeout=20) as response:
                data=response.read(LIMIT+1)
            if len(data)>LIMIT:raise ValueError('GitHub 安装响应过大')
            value=json.loads(data)
            if not isinstance(value,dict):raise ValueError('GitHub 安装响应格式异常')
            return value
        except urllib.error.HTTPError as error:
            if error.code in {500,502,503,504} and not attempt:time.sleep(.25);continue
            raise ValueError('GitHub 安装读取失败（HTTP '+str(error.code)+'）；请确认令牌仅授权本仓库 Contents: Read-only') from None
        except (urllib.error.URLError,TimeoutError):
            if not attempt:time.sleep(.25);continue
            raise ValueError('无法连接 GitHub，安装未完成') from None


def file_content(item):
    if not isinstance(item,dict) or item.get('type')!='file' or item.get('encoding')!='base64':
        raise ValueError('GitHub 安装文件格式异常')
    size=item.get('size')
    if not isinstance(size,int) or not 0<=size<=LIMIT:raise ValueError('GitHub 安装文件过大')
    try:data=base64.b64decode(''.join(item['content'].split()),validate=True)
    except (ValueError,KeyError,AttributeError):raise ValueError('GitHub 安装文件编码无效') from None
    if len(data)!=size:raise ValueError('GitHub 安装文件长度不符')
    blob=hashlib.sha1(b'blob '+str(len(data)).encode()+b'\0'+data).hexdigest()
    if blob!=item.get('sha'):raise ValueError('GitHub 安装文件内容摘要不符')
    return data


def atomic(path,data,mode=0o600):
    path=pathlib.Path(path)
    if path.is_symlink():raise ValueError('安装目标不能是符号链接')
    fd,name=tempfile.mkstemp(prefix='.sbm-install-',dir=path.parent)
    try:
        with os.fdopen(fd,'wb') as out:
            out.write(data);out.flush();os.fsync(out.fileno());os.fchmod(out.fileno(),mode)
        os.replace(name,path)
        fd=os.open(path.parent,os.O_RDONLY)
        try:os.fsync(fd)
        finally:os.close(fd)
    finally:pathlib.Path(name).unlink(missing_ok=True)


def engine(stage,*args):
    result=subprocess.run([sys.executable,str(pathlib.Path(stage)/'engine.pyz'),*map(str,args)],capture_output=True,text=True,timeout=45)
    if result.returncode:raise ValueError(result.stderr.strip() or '安装校验未通过')
    return json.loads(result.stdout) if result.stdout.strip() else None


def prepare(stage,token,release=None):
    if release is not None and not isinstance(release,dict):raise ValueError('仅支持正式 Release，不接受分支或提交标识')
    stage=pathlib.Path(stage)
    origin=download_release(API,stage,('singbox-manager.sh','singbox-manager.sha256'),
        lambda url,t:request(url[len(API):],t),asset_bytes,token,release=release)
    data=(stage/'singbox-manager.sh').read_bytes()
    match=re.fullmatch(r'([a-f0-9]{64})\s+singbox-manager\.sh\s*',(stage/'singbox-manager.sha256').read_text())
    if not match or hashlib.sha256(data).hexdigest()!=match[1]:raise ValueError('管理脚本 SHA-256 不匹配，未执行任何下载的代码')
    if not data.startswith(b'#!/usr/bin/env bash\n# singbox-manager v'):raise ValueError('下载内容不是本项目管理脚本')
    # Decode data without sourcing Bash or importing the downloaded engine.
    bundle=re.search(rb"^emit_engine\(\) \{\n    base64 -d <<'SBM_BUNDLE'\n([A-Za-z0-9+/=\s]+)\nSBM_BUNDLE$",data,re.M)
    if not bundle:raise ValueError('管理脚本缺少内嵌引擎')
    atomic(stage/'engine.pyz',base64.b64decode(re.sub(rb'\s+',b'',bundle[1]),validate=True))
    return dict(static_script_info(data),**origin)


def guard(paths):
    for path in paths:
        p=pathlib.Path(path)
        if any(parent.is_symlink() for parent in [p,*p.parents]):raise ValueError('安装路径包含符号链接，请人工核查：'+str(p))


def install(stage,token,origin,root='/root',shortcut='/usr/local/bin/sbm',state='/var/lib/singbox-manager'):
    root=pathlib.Path(root);shortcut=pathlib.Path(shortcut);state=pathlib.Path(state)
    managed=[root/'singbox-manager.sh',shortcut,root/'singbox-manager.sha256',state/'update-source.json',state/'github-token',state/'install-origin.json']
    guard([root,shortcut.parent,state,*managed,state/'manager-backups',state/'manager.lock',state/'pending',state/'manager-update-pending.json'])
    if not root.is_dir() or not shortcut.parent.is_dir():raise ValueError('安装目标目录不存在')
    # First-install entry never replaces a previous manager or its credentials.
    if any(p.exists() for p in managed):raise ValueError('已有管理器或安装设置；请使用现有 sbm 菜单 30 升级')
    state.mkdir(mode=0o700,parents=False,exist_ok=True)
    if state.stat().st_uid!=os.geteuid() or state.stat().st_mode&0o077:raise ValueError('管理状态目录必须归当前管理员所有，权限 700')
    fd=os.open(state/'manager.lock',os.O_CREAT|os.O_RDWR|os.O_NOFOLLOW,0o600)
    try:
        try:fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
        except BlockingIOError:raise ValueError('已有管理脚本运行，请退出后重试') from None
        if any(p.exists() for p in managed):raise ValueError('等待期间出现已有管理器，请使用菜单 30 升级')
        if (state/'pending').exists() or (state/'manager-update-pending.json').exists():raise ValueError('存在未完成事务，请先用原管理器恢复')
        verify_directory(stage)
        report=engine(stage,'manager-update','install',pathlib.Path(stage)/'singbox-manager.sh',pathlib.Path(stage)/'singbox-manager.sha256',state,root,shortcut)
        metadata=[root/'singbox-manager.sha256',state/'update-source.json',state/'github-token',state/'install-origin.json']
        try:
            atomic(metadata[0],(pathlib.Path(stage)/'singbox-manager.sha256').read_bytes())
            atomic(metadata[1],(json.dumps({'repository':REPOSITORY,'channel':CHANNEL})+'\n').encode())
            if token:atomic(metadata[2],token.encode())
            receipt=dict(repository=REPOSITORY,channel=CHANNEL,tag=origin['tag'],commit=origin['commit'],version=report['version'],sha256=report['sha256'],signature_verified=True)
            atomic(metadata[3],(json.dumps(receipt)+'\n').encode())
        except BaseException:
            # The shared updater restores both script targets; no runtime/service call occurs.
            atomic(state/'manager-update-pending.json',(json.dumps({'backup':report['backup']})+'\n').encode())
            engine(stage,'manager-update','restore',state,report['backup'],root,shortcut)
            for p in metadata:p.unlink(missing_ok=True)
            (state/'manager-update-pending.json').unlink(missing_ok=True)
            raise
        return receipt
    finally:os.close(fd)


def host_check():
    if sys.platform!='linux' or os.geteuid()!=0:raise ValueError('请在新 Debian/Ubuntu 服务器上以 root 执行；可先 sudo -i')
    release=pathlib.Path('/etc/os-release').read_text()
    identity=next((line.split('=',1)[1].strip('"') for line in release.splitlines() if line.startswith('ID=')),'')
    if identity not in {'debian','ubuntu'} or not pathlib.Path('/run/systemd/system').is_dir():raise ValueError('需要 Debian/Ubuntu 及运行中的 systemd')
    result=subprocess.run(['bash','-c','(( BASH_VERSINFO[0]>=4 ))'],capture_output=True)
    if result.returncode:raise ValueError('需要 Bash 4 或更新版本')


def main(token=None,release=None,confirmed=False):
    host_check()
    if pathlib.Path('/root/singbox-manager.sh').exists() or pathlib.Path('/usr/local/bin/sbm').exists():
        raise ValueError('本机已有管理器；请执行 sbm self-update github 或菜单 30 → 2')
    if token is None:token=''
    if token and not re.fullmatch(r'[A-Za-z0-9_]{10,255}',token):raise ValueError('GitHub 令牌格式无效')
    with tempfile.TemporaryDirectory(prefix='sbm-install-') as stage:
        info=prepare(stage,token,release)
        print('已验证签名：正式 Release '+info['tag']+'；仓库 '+REPOSITORY+'；提交 '+info['commit'])
        print('安装 /root/singbox-manager.sh 和快捷命令 sbm，并保存此仓库的后续升级设置。')
        answer='yes' if confirmed else ''
        if not confirmed:
            with open('/dev/tty','r+') as terminal:
                terminal.write('输入 yes 安装，其他输入取消: ');terminal.flush();answer=terminal.readline().strip().lower()
        if answer!='yes':print('已取消安装。');return
        result=install(stage,token,info)
    print('安装完成：singbox-manager v'+result['version']+'。后续升级使用菜单 30 → 2。')
    print('正在打开菜单；选择 1 初始化 / 安装并添加节点。')
    try:
        with open('/dev/tty') as terminal:result=subprocess.run(['/usr/local/bin/sbm'],stdin=terminal)
        if result.returncode:print('管理器已安装；需要时重新输入 sbm 打开菜单。')
    except (OSError,KeyboardInterrupt):print('\n管理器已安装；输入 sbm 可重新打开菜单。')


def run(token=None,release=None,confirmed=False):
    os.umask(0o077)
    try:main(token,release,confirmed)
    except KeyboardInterrupt:print('\n已取消。',file=sys.stderr);raise SystemExit(130)
    except (ValueError,OSError,subprocess.SubprocessError) as error:
        print('安装未完成：'+str(error),file=sys.stderr);raise SystemExit(1)


if __name__=='__main__':run(globals().get('BOOTSTRAP_TOKEN'),globals().get('BOOTSTRAP_RELEASE'),globals().get('BOOTSTRAP_CONFIRMED',False))
