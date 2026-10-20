"""Signed formal-Release bootstrap; execution follows verification and consent."""
import json
import pathlib
import re
import sys
import tempfile
import urllib.error
import urllib.request
import uuid
from sbm.core.release_trust import download_release,asset_bytes,bounded_read,require_python

API='https://api.github.com/repos/xlp567/singbox-manager'
LIMIT=2*1024*1024


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self,*args,**kwargs):raise ValueError('安装接口返回跳转，已停止')


def read(path,token=''):
    if not re.fullmatch(r'/releases/latest|/git/ref/tags/v\d+\.\d+\.\d+|/git/tags/[a-f0-9]{40}',path):raise ValueError('安装路径无效')
    headers={'Accept':'application/vnd.github+json','User-Agent':'singbox-manager-public-install','X-GitHub-Api-Version':'2022-11-28','Cache-Control':'no-cache'}
    if token:headers['Authorization']='Bearer '+token
    try:
        with urllib.request.build_opener(NoRedirect).open(urllib.request.Request(API+path+'?sbm='+uuid.uuid4().hex,headers=headers),timeout=25) as response:data=bounded_read(response,LIMIT)
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
    require_python()
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
