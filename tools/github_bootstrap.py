"""Small first-stage loader pasted once on the new server; never puts tokens in argv."""
import base64
import getpass
import hashlib
import json
import os
import pathlib
import re
import sys
import urllib.error
import urllib.request

API='https://api.github.com/repos/xlp567/singbox-manager'
LIMIT=2*1024*1024


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self,*args,**kwargs):raise ValueError('拒绝跳转，未转发令牌')


def read(path,token):
    if not re.fullmatch(r'/commits/main|/contents/install\.py\?ref=[a-f0-9]{40}',path):raise ValueError('非官方安装路径')
    headers={'Accept':'application/vnd.github+json','X-GitHub-Api-Version':'2022-11-28','User-Agent':'singbox-manager-bootstrap'}
    if token:headers['Authorization']='Bearer '+token
    try:
        with urllib.request.build_opener(NoRedirect).open(urllib.request.Request(API+path,headers=headers),timeout=20) as response:data=response.read(LIMIT+1)
    except urllib.error.HTTPError as error:raise ValueError('GitHub HTTP '+str(error.code)+'；请确认令牌的仓库授权和 Contents: Read-only 权限') from None
    except (urllib.error.URLError,TimeoutError):raise ValueError('无法连接 GitHub，请稍后重试') from None
    if len(data)>LIMIT:raise ValueError('安装响应过大')
    value=json.loads(data)
    if not isinstance(value,dict):raise ValueError('GitHub 安装响应格式异常')
    return value


def launch():
    if sys.platform!='linux' or os.geteuid()!=0:raise ValueError('请先在新 Debian/Ubuntu 服务器执行 sudo -i，切换到 root')
    if pathlib.Path('/root/singbox-manager.sh').exists() or pathlib.Path('/usr/local/bin/sbm').exists():raise ValueError('已有管理器，请使用 sbm 菜单 30 → 2')
    with open('/dev/tty','r+') as terminal:token=getpass.getpass('GitHub 只读令牌（隐藏输入，公开仓库可留空）: ',stream=terminal).strip()
    if token and not re.fullmatch(r'[A-Za-z0-9_]{10,255}',token):raise ValueError('令牌格式无效')
    commit=read('/commits/main',token).get('sha','')
    if not re.fullmatch(r'[a-f0-9]{40}',commit):raise ValueError('提交标识无效')
    item=read('/contents/install.py?ref='+commit,token)
    if item.get('type')!='file' or item.get('encoding')!='base64' or not isinstance(item.get('size'),int) or not 0<=item['size']<=LIMIT:raise ValueError('安装器格式异常')
    data=base64.b64decode(''.join(item['content'].split()),validate=True)
    if len(data)!=item['size'] or hashlib.sha1(b'blob '+str(len(data)).encode()+b'\0'+data).hexdigest()!=item.get('sha'):raise ValueError('安装器内容摘要不符')
    exec(compile(data,'<verified GitHub installer>','exec'),{'__name__':'__main__','BOOTSTRAP_TOKEN':token,'BOOTSTRAP_COMMIT':commit})


if __name__=='__main__':
    try:launch()
    except KeyboardInterrupt:print('\n已取消。',file=sys.stderr);raise SystemExit(130)
    except (ValueError,OSError,KeyError,TypeError) as error:print('安装未开始：'+str(error),file=sys.stderr);raise SystemExit(1)
