"""Pinned release signatures and static inspection; never executes a candidate."""
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
import urllib.parse
import urllib.request
import uuid

PUBLIC_KEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAW8DuzbY0y6ySdV3EfX0XtEe7NogBEQ4GTbFfgadED/ singbox-manager-release'
SIGNER='singbox-manager-release'
NAMESPACE='singbox-manager-release'
TRUST_LIMIT=2*1024*1024
RETRY_STATUS=frozenset({408,429,500,502,503,504})
RETRY_DELAYS=(0.5,1.5)


def retrying(operation,delays=RETRY_DELAYS):
    """Shared GitHub retry: transient transport / 408 / 429 / 5xx only.
    Permission, redirect, size, format and signature failures are never retried."""
    for delay in (*delays,None):
        try:return operation()
        except urllib.error.HTTPError as error:
            if error.code not in RETRY_STATUS or delay is None:raise
        except (urllib.error.URLError,OSError,http.client.HTTPException):
            if delay is None:raise
        time.sleep(delay)


def require_python():
    if sys.version_info < (3,8):
        raise ValueError('需要 Python 3.8+；最低支持 Debian 11+ / Ubuntu 20.04+，请升级系统或 Python')


def require_supported_os(identity,version):
    minimum={'debian':(11,0),'ubuntu':(20,4)}
    if identity not in minimum or not re.fullmatch(r'\d+(?:\.\d+)*',version):
        raise ValueError('仅支持 Debian 11+ / Ubuntu 20.04+；无法识别系统版本')
    parts=tuple(map(int,(version+'.0').split('.')[:2]))
    if parts<minimum[identity]:
        raise ValueError('最低支持 Debian 11+ / Ubuntu 20.04+；请先升级系统，未开始安装')


def bounded_read(response,limit=TRUST_LIMIT):
    chunks=[];total=0
    while total<=limit:
        chunk=response.read(min(65536,limit+1-total))
        if not chunk:break
        chunks.append(chunk);total+=len(chunk)
    if total>limit:raise ValueError('发布响应超过大小限制')
    return b''.join(chunks)


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
    require_python()
    if len(manifest)>65536 or len(signature)>16384:raise ValueError('签名或校验清单过大')
    with tempfile.TemporaryDirectory(prefix='sbm-signature-') as folder:
        root=pathlib.Path(folder);allowed=root/'allowed_signers';sig=root/'manifest.sig'
        allowed.write_text(SIGNER+' '+PUBLIC_KEY+'\n');sig.write_bytes(signature)
        try:
            result=subprocess.run(['ssh-keygen','-Y','verify','-f',str(allowed),'-I',SIGNER,'-n',NAMESPACE,'-s',str(sig)],
                input=manifest,capture_output=True,timeout=15,env={'PATH':os.defpath,'LC_ALL':'C'})
        except FileNotFoundError:raise ValueError('缺少签名验证工具 ssh-keygen；请安装 openssh-client') from None
        if result.returncode:
            diagnostic=result.stderr+result.stdout
            if re.search(rb'(?:unknown|illegal|invalid|unrecognized) option[^\r\n]*\bY\b',diagnostic,re.I):
                raise ValueError('ssh-keygen 不支持 -Y 签名验证；需要 OpenSSH 8.1+，请升级 openssh-client（Debian 11+ / Ubuntu 20.04+）')
            raise ValueError('发布签名验证失败，未执行候选程序')


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
    api=bool(re.fullmatch(r'https://api\.github\.com/repos/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/releases/assets/\d+',url))
    browser=bool(re.fullmatch(r'https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/releases/download/v\d+\.\d+\.\d+/[A-Za-z0-9_.-]+',url))
    if not api and not browser:raise ValueError('发布附件地址无效')
    headers={'Accept':'application/octet-stream','User-Agent':'singbox-manager-release','X-GitHub-Api-Version':'2022-11-28','Cache-Control':'no-cache'}
    if api:
        url+='?download=1&sbm='+uuid.uuid4().hex
        if token:headers['Authorization']='Bearer '+token
    def attempt():
        with urllib.request.build_opener(ReleaseAssetRedirect).open(urllib.request.Request(url,headers=headers),timeout=30) as response:
            if 'application/json' in response.headers.get('Content-Type',''):raise ValueError('发布附件返回了元数据，拒绝作为程序使用')
            return bounded_read(response)
    try:data=retrying(attempt)
    except urllib.error.HTTPError as error:raise ValueError('发布附件读取失败（HTTP '+str(error.code)+'）') from None
    except (urllib.error.URLError,OSError,http.client.HTTPException):raise ValueError('无法下载正式发布附件（已重试）') from None
    if len(data)>TRUST_LIMIT:raise ValueError('发布附件超过大小限制')
    return data


def download_release(api,destination,required,json_request,asset_request=asset_bytes,token='',current_version='',release=None):
    repository=re.fullmatch(r'https://api\.github\.com/repos/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)',api)
    if not repository:raise ValueError('正式发布仓库地址无效')
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
        # Public downloads use the version-bound official download URL. Old
        # asset-ID API responses can remain cached after assets are replaced.
        # Private repositories still use authenticated API content requests.
        url=(api+'/releases/assets/'+str(item['id'])) if token else ('https://github.com/'+repository[1]+'/releases/download/'+tag+'/'+name)
        data=asset_request(url,token)
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
