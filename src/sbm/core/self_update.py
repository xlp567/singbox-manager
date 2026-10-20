"""Manager-only updates. Never modifies sing-box configuration or controls services."""
import base64
import getpass
import hashlib
import http.client
import json
import os
import pathlib
import re
import subprocess
import tempfile
import urllib.error
import urllib.parse
import urllib.request
import uuid
from .storage import save,sync_directory,file_digest
from .release_trust import retrying,static_script_info,download_release,verify_directory,asset_bytes,bounded_read,version_tuple

DEFAULT_REPOSITORY='xlp567/singbox-manager'
LIMIT=2*1024*1024


def regular(path):
    p=pathlib.Path(path)
    if p.is_symlink() or not p.is_file() or p.stat().st_size>LIMIT:
        raise ValueError('脚本 / 校验文件不是普通文件或超出大小限制')
    return p


def verify(script,checksum):
    p=regular(script);s=regular(checksum).read_text()
    match=re.fullmatch(r'\s*([a-fA-F0-9]{64})\s+\*?[^/\r\n]+\s*',s)
    if not match or file_digest(p)!=match[1].lower():raise ValueError('管理脚本 SHA-256 校验失败，未安装')
    data=p.read_bytes()
    if not data.startswith(b'#!/usr/bin/env bash\n# singbox-manager v'):
        raise ValueError('不是本项目发布的管理脚本')
    info=static_script_info(data)
    check=subprocess.run(['bash','--noprofile','--norc','-n',str(p)],capture_output=True,timeout=15,
                         env={'PATH':os.defpath,'LC_ALL':'C'})
    if check.returncode:raise ValueError('管理脚本 Bash 语法检查失败')
    return info


def atomic_bytes(path,data,mode=0o700):
    p=pathlib.Path(path)
    if p.is_symlink():raise ValueError('升级目标不得为符号链接')
    fd,name=tempfile.mkstemp(prefix='.'+p.name+'.sbm-',dir=p.parent)
    try:
        with os.fdopen(fd,'wb') as f:f.write(data);f.flush();os.fsync(f.fileno());os.fchmod(f.fileno(),mode)
        os.replace(name,p);sync_directory(p.parent)
    finally:
        if os.path.exists(name):os.unlink(name)


def targets(root,shortcut):return [str(pathlib.Path(root)/'singbox-manager.sh'),str(pathlib.Path(shortcut))]


def sidecar(root):return pathlib.Path(root)/'singbox-manager.sha256'


def sidecar_bytes(digest):return (digest+'  singbox-manager.sh\n').encode()


def check_version(candidate,current):
    if version_tuple(candidate)<version_tuple(current):
        raise ValueError('候选管理器比当前版本更旧，拒绝降级；需要回退时请使用菜单 30 → 3 的本机备份')


def backup_root(state):
    p=pathlib.Path(state)/'manager-backups'
    if p.is_symlink():raise ValueError('管理脚本备份目录不得为符号链接')
    p.mkdir(parents=True,exist_ok=True);os.chmod(p,0o700);return p


def restore(state,backup,root,shortcut):
    base=backup_root(state);p=pathlib.Path(backup)
    if p.is_symlink() or p.parent.resolve()!=base.resolve():raise ValueError('脚本备份路径异常')
    m=json.loads(regular(p/'manifest.json').read_text())
    if m.get('targets')!=targets(root,shortcut):raise ValueError('备份目标与本机不匹配')
    rows=m['files']
    if not isinstance(rows,list) or len(rows)!=2:raise ValueError('脚本备份清单损坏')
    for row in rows:
        if row.get('file') not in {'0.sh','1.sh'}:raise ValueError('脚本备份文件名无效')
        if row['exists'] and file_digest(regular(p/row['file']))!=row['sha256']:raise ValueError('旧脚本备份摘要不符，保留恢复标记')
    side=m.get('sidecar')
    if side is not None:
        if not isinstance(side,dict) or side.get('file')!='sidecar.sha256':raise ValueError('校验文件备份清单损坏')
        if side['exists'] and file_digest(regular(p/side['file']))!=side['sha256']:raise ValueError('旧校验文件备份摘要不符，保留恢复标记')
    for target,row in zip(m['targets'],rows):
        if row['exists']:atomic_bytes(target,(p/row['file']).read_bytes())
        elif pathlib.Path(target).is_symlink():raise ValueError('恢复目标为符号链接')
        else:pathlib.Path(target).unlink(missing_ok=True);sync_directory(pathlib.Path(target).parent)
    # Backups made before v3.5.8 have no sidecar entry; leave the current file untouched.
    if side is not None:
        target=sidecar(root)
        if side['exists']:atomic_bytes(target,(p/side['file']).read_bytes(),0o600)
        elif target.is_symlink():raise ValueError('恢复目标为符号链接')
        else:target.unlink(missing_ok=True);sync_directory(target.parent)


def recover(state,root,shortcut):
    pending=pathlib.Path(state)/'manager-update-pending.json'
    if pending.is_symlink():raise ValueError('脚本升级恢复标记不得为符号链接')
    if pending.exists():
        item=json.loads(regular(pending).read_text());restore(state,item['backup'],root,shortcut)
        pending.unlink();sync_directory(state)
        print('已恢复上次中断前的管理脚本；请退出后重新运行 sbm。')
        return True
    return False


def install(script,checksum,state,root,shortcut,trusted_rollback=False):
    if not trusted_rollback:verify_directory(pathlib.Path(script).parent)
    info=verify(script,checksum);data=regular(script).read_bytes();dest=targets(root,shortcut)
    if hashlib.sha256(data).hexdigest()!=info['sha256']:raise ValueError('检查期间候选脚本变化，拒绝安装')
    side=sidecar(root);expected=sidecar_bytes(info['sha256'])
    if side.is_symlink():raise ValueError('升级目标不得为符号链接')
    for p in dest:
        if pathlib.Path(p).is_symlink():raise ValueError('升级目标不得为符号链接')
        if not trusted_rollback and pathlib.Path(p).exists():
            check_version(info['version'],static_script_info(regular(p).read_bytes())['version'])
    if all(pathlib.Path(p).is_file() and file_digest(p)==info['sha256'] for p in dest):
        # The root sidecar is metadata only; refresh a stale copy without a script backup.
        if not side.is_file() or regular(side).read_bytes()!=expected:atomic_bytes(side,expected,0o600)
        return dict(info,changed=False)
    pending=pathlib.Path(state)/'manager-update-pending.json'
    if pending.exists():raise ValueError('存在未完成的脚本升级，请先恢复')
    import datetime
    backup=backup_root(state)/(datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')+'-'+uuid.uuid4().hex[:8])
    backup.mkdir(mode=0o700);rows=[]
    for i,target in enumerate(dest):
        p=pathlib.Path(target);row={'file':str(i)+'.sh','exists':p.exists()}
        if row['exists']:
            regular(p);atomic_bytes(backup/row['file'],p.read_bytes());row['sha256']=file_digest(backup/row['file'])
        rows.append(row)
    side_row={'file':'sidecar.sha256','exists':side.exists()}
    if side_row['exists']:
        atomic_bytes(backup/side_row['file'],regular(side).read_bytes(),0o600);side_row['sha256']=file_digest(backup/side_row['file'])
    save(backup/'manifest.json',{'targets':dest,'files':rows,'sidecar':side_row,'installed_version':info['version']})
    save(pending,{'backup':str(backup)})
    try:
        # Install the command entry first so a subsequent invocation can recover.
        for p in reversed(dest):atomic_bytes(p,data)
        for p in dest:
            if file_digest(p)!=info['sha256']:raise ValueError('安装后脚本摘要不符')
            verify(p,checksum)
        atomic_bytes(side,expected,0o600)
        if regular(side).read_bytes()!=expected:raise ValueError('安装后校验文件不符')
        pending.unlink();sync_directory(state)
    except BaseException:
        restore(state,backup,root,shortcut)
        pending.unlink();sync_directory(state)
        raise
    return dict(info,changed=True,backup=str(backup))


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self,req,fp,code,msg,headers,newurl):
        raise ValueError('GitHub API 返回重定向，拒绝向其他地址发送访问凭据')


class GitHubReadError(ValueError):
    def __init__(self,status):
        self.status=status
        super().__init__('GitHub 读取失败（HTTP '+str(status)+'）；公开仓库请稍后重试，私有仓库可配置 Contents:read 令牌')


def request_json(url,token=''):
    if not url.startswith('https://api.github.com/repos/'):raise ValueError('只允许 GitHub 官方仓库 API')
    headers={'Accept':'application/vnd.github+json','User-Agent':'singbox-manager','X-GitHub-Api-Version':'2022-11-28','Cache-Control':'no-cache'}
    url+=('&' if '?' in url else '?')+'sbm='+uuid.uuid4().hex
    if token:headers['Authorization']='Bearer '+token
    def attempt():
        with urllib.request.build_opener(NoRedirect).open(urllib.request.Request(url,headers=headers),timeout=30) as r:
            return bounded_read(r,LIMIT)
    try:data=retrying(attempt)
    except urllib.error.HTTPError as ex:
        raise GitHubReadError(ex.code) from None
    except (urllib.error.URLError,OSError,http.client.HTTPException):
        raise ValueError('无法连接 GitHub（已重试），未修改管理脚本') from None
    if len(data)>LIMIT:raise ValueError('GitHub 响应超过大小限制')
    return json.loads(data)


def source(state):
    p=pathlib.Path(state)/'update-source.json'
    value=json.loads(regular(p).read_text()) if p.exists() else {'repository':DEFAULT_REPOSITORY,'channel':'stable'}
    if set(value) not in ({'repository','branch'},{'repository','channel'}) or not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+',str(value['repository'])):
        raise ValueError('GitHub 升级源配置无效')
    if 'channel' in value and value['channel']!='stable':raise ValueError('仅支持正式 Release 稳定渠道')
    return {'repository':value['repository'],'channel':'stable'}


def rollback_stage(state,backup,root,shortcut,destination):
    p=pathlib.Path(backup)
    if p.is_symlink() or p.parent.resolve()!=backup_root(state).resolve():raise ValueError('脚本备份路径异常')
    m=json.loads(regular(p/'manifest.json').read_text())
    if m.get('targets')!=targets(root,shortcut):raise ValueError('脚本备份目标不匹配')
    rows=m['files']
    if len(rows)!=2:raise ValueError('脚本备份清单损坏')
    # The installed shortcut is authoritative when an uploaded /root file already differs.
    index=1 if rows[1].get('exists') else 0;row=rows[index]
    if row.get('file')!=str(index)+'.sh' or not row.get('exists'):raise ValueError('此备份没有可恢复的管理脚本')
    script=regular(p/row['file'])
    if file_digest(script)!=row['sha256']:raise ValueError('备份脚本摘要校验失败')
    dest=pathlib.Path(destination)
    atomic_bytes(dest/'singbox-manager.sh',script.read_bytes(),0o600)
    atomic_bytes(dest/'singbox-manager.sha256',(row['sha256']+'  singbox-manager.sh\n').encode(),0o600)


def fetch(state,destination,current_version=''):
    config=source(state);token_file=pathlib.Path(state)/'github-token';token=''
    api='https://api.github.com/repos/'+config['repository']
    latest=api+'/releases/latest'
    try:release=request_json(latest)
    except GitHubReadError as error:
        if error.status not in {401,403,404} or not token_file.exists():raise
        regular(token_file)
        if token_file.stat().st_mode&0o077:raise ValueError('GitHub 令牌权限必须为 600 或更严格')
        token=token_file.read_text().strip()
        if not re.fullmatch(r'[A-Za-z0-9_]{10,255}',token):raise ValueError('GitHub 令牌格式无效')
        release=request_json(latest,token)
    dest=pathlib.Path(destination)
    origin=download_release(api,dest,('singbox-manager.sh','singbox-manager.sha256'),request_json,
                            asset_bytes,token,current_version,release)
    report=verify(dest/'singbox-manager.sh',dest/'singbox-manager.sha256')
    report.update(repository=config['repository'],**origin)
    return report


def command(args):
    op=args[0]
    if op=='verify':print(json.dumps(verify(*args[1:]),ensure_ascii=False));return
    if op=='check-version':return check_version(*args[1:])
    if op=='install':print(json.dumps(install(*args[1:]),ensure_ascii=False));return
    if op=='install-rollback':print(json.dumps(install(*args[1:],trusted_rollback=True),ensure_ascii=False));return
    if op=='verify-release':print(verify_directory(args[1]));return
    if op=='fetch':print(json.dumps(fetch(*args[1:]),ensure_ascii=False));return
    if op=='recover':return recover(*args[1:])
    if op=='restore':return restore(*args[1:])
    if op=='rollback-stage':return rollback_stage(*args[1:])
    if op=='list':
        for p in sorted(backup_root(args[1]).iterdir(),reverse=True):
            if p.is_symlink() or not p.is_dir():continue
            m=p/'manifest.json'
            if m.is_file() and not m.is_symlink():
                item=json.loads(regular(m).read_text())
                print(str(p)+' | 安装的版本 '+str(item.get('installed_version','未知'))+'；内含安装前脚本')
        return
    if op=='configure':
        state=args[1];old=source(state)
        repository=input('GitHub 仓库 owner/repo ['+old['repository']+']: ').strip() or old['repository']
        print('升级渠道：最新正式 Release（固定 stable；不跟踪分支）')
        value={'repository':repository,'channel':'stable'}
        if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+',repository):raise ValueError('仓库格式无效')
        token=getpass.getpass('私有仓库只读令牌（仅所选仓库 Contents:read；留空保留已有令牌）: ').strip()
        if token and not re.fullmatch(r'[A-Za-z0-9_]{10,255}',token):raise ValueError('令牌格式无效')
        save(pathlib.Path(state)/'update-source.json',value)
        if token:atomic_bytes(pathlib.Path(state)/'github-token',token.encode(),0o600)
        print('GitHub 升级源已保存；令牌只保存在本机私有文件，不写入日志或配置导出。');return
    raise ValueError('管理脚本升级操作无效')
