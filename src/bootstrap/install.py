#!/usr/bin/env python3
"""Signed formal-Release installer; existing managers use menu 30."""
import base64
import fcntl
import hashlib
import http.client
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
import uuid
from sbm.core.release_trust import retrying,download_release,verify_directory,static_script_info,asset_bytes,bounded_read,require_python,require_supported_os

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
             'X-GitHub-Api-Version':'2022-11-28','Cache-Control':'no-cache'}
    if token:headers['Authorization']='Bearer '+token
    def attempt():
        with urllib.request.build_opener(NoRedirect).open(urllib.request.Request(API+path+'?sbm='+uuid.uuid4().hex,headers=headers),timeout=20) as response:
            return bounded_read(response,LIMIT)
    try:data=retrying(attempt)
    except urllib.error.HTTPError as error:
        raise ValueError('GitHub 安装读取失败（HTTP '+str(error.code)+'）；公开仓库请稍后重试，私有仓库请检查 Contents:read 权限') from None
    except (urllib.error.URLError,OSError,http.client.HTTPException):
        raise ValueError('无法连接 GitHub（已重试），安装未完成') from None
    if len(data)>LIMIT:raise ValueError('GitHub 安装响应过大')
    try:value=json.loads(data)
    except ValueError:raise ValueError('GitHub 安装响应不完整或格式无效，安装未完成') from None
    if not isinstance(value,dict):raise ValueError('GitHub 安装响应格式异常')
    return value


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
    require_python()
    if sys.platform!='linux' or os.geteuid()!=0:raise ValueError('请在新 Debian/Ubuntu 服务器上以 root 执行；可先 sudo -i')
    release=pathlib.Path('/etc/os-release').read_text()
    fields=dict(line.split('=',1) for line in release.splitlines() if '=' in line and not line.startswith('#'))
    require_supported_os(fields.get('ID','').strip('"\''),fields.get('VERSION_ID','').strip('"\''))
    if not pathlib.Path('/run/systemd/system').is_dir():raise ValueError('需要 Debian/Ubuntu 及运行中的 systemd')
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
