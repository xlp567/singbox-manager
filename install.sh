#!/usr/bin/env bash
# singbox-manager signed Release bootstrap; runtime changes remain separate.
set -Eeuo pipefail
umask 077
(( EUID == 0 )) || { echo '请先 sudo -i，切换到 root'; exit 1; }
[[ -t 0 ]] || { echo '请在 SSH 交互终端执行，使用 bash <(curl -fsSL URL)'; exit 1; }
[[ $(uname -s) == Linux ]] || { echo '需要 Debian/Ubuntu Linux'; exit 1; }
# shellcheck disable=SC1091
. /etc/os-release
[[ $ID == debian || $ID == ubuntu ]] || { echo '仅支持 Debian/Ubuntu'; exit 1; }
[[ -d /run/systemd/system ]] || { echo '需要运行中的 systemd'; exit 1; }
[[ ! -e /root/singbox-manager.sh && ! -e /usr/local/bin/sbm ]] || { echo '已有管理器，请使用 sbm 菜单 30 → 2'; exit 1; }
if ! command -v python3 >/dev/null 2>&1 || ! command -v flock >/dev/null 2>&1 || ! command -v ssh-keygen >/dev/null 2>&1 || [[ ! -s /etc/ssl/certs/ca-certificates.crt ]]; then
    apt-get update
    apt-get install -y python3 ca-certificates util-linux openssh-client
fi
echo '正在验证最新正式 Release 的签名（公开仓库，无需令牌）……'
python3 - <<'SBM_PUBLIC_BOOTSTRAP'
"""Signed formal-Release bootstrap; execution follows verification and consent."""
import json
import pathlib
import re
import sys
import tempfile
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


API='https://api.github.com/repos/xlp567/singbox-manager'
LIMIT=2*1024*1024


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self,*args,**kwargs):raise ValueError('安装接口返回跳转，已停止')


def read(path,token=''):
    if not re.fullmatch(r'/releases/latest|/git/ref/tags/v\d+\.\d+\.\d+|/git/tags/[a-f0-9]{40}',path):raise ValueError('安装路径无效')
    headers={'Accept':'application/vnd.github+json','User-Agent':'singbox-manager-public-install','X-GitHub-Api-Version':'2022-11-28'}
    if token:headers['Authorization']='Bearer '+token
    try:
        with urllib.request.build_opener(NoRedirect).open(urllib.request.Request(API+path,headers=headers),timeout=25) as response:data=response.read(LIMIT+1)
    except urllib.error.HTTPError as error:raise ValueError('GitHub HTTP '+str(error.code)+'；请确认仓库访问权限，或稍后重试') from None
    except (urllib.error.URLError,TimeoutError):raise ValueError('无法连接 GitHub，请稍后重试') from None
    if len(data)>LIMIT:raise ValueError('安装响应过大')
    value=json.loads(data)
    if not isinstance(value,dict):raise ValueError('安装响应格式异常')
    return value


def consent(tag):
    print('正式 Release '+tag+' 的安装器签名已通过固定公钥验证。')
    print('将安装管理器并打开菜单；不创建节点，不重启已有代理服务。')
    with open('/dev/tty','r+') as terminal:
        terminal.write('输入 yes 安装并运行已验证的安装器，其他输入取消: ');terminal.flush()
        return terminal.readline().strip().lower()=='yes'


def launch(token=''):
    with tempfile.TemporaryDirectory(prefix='sbm-bootstrap-') as folder:
        release=read('/releases/latest',token)
        origin=download_release(API,folder,('install.py',),lambda url,t:read(url[len(API):],t),asset_bytes,token,release=release)
        if not consent(origin['tag']):print('已取消，未执行下载的代码。');return
        data=(pathlib.Path(folder)/'install.py').read_bytes()
        exec(compile(data,'<signed formal Release installer>','exec'),
             {'__name__':'__main__','BOOTSTRAP_TOKEN':token,'BOOTSTRAP_RELEASE':release,'BOOTSTRAP_CONFIRMED':True})


if __name__=='__main__':
    try:launch()
    except KeyboardInterrupt:print('\n已取消。',file=sys.stderr);raise SystemExit(130)
    except (ValueError,OSError,KeyError,TypeError) as error:print('安装未开始：'+str(error),file=sys.stderr);raise SystemExit(1)
SBM_PUBLIC_BOOTSTRAP
