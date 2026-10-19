#!/usr/bin/env bash
# singbox-manager public bootstrap; the installed manager owns runtime changes.
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
if ! command -v python3 >/dev/null 2>&1 || ! command -v flock >/dev/null 2>&1 || [[ ! -s /etc/ssl/certs/ca-certificates.crt ]]; then
    apt-get update
    apt-get install -y python3 ca-certificates util-linux
fi
echo '正在从 GitHub 下载并校验管理器（公开仓库，无需令牌）……'
python3 - <<'SBM_PUBLIC_BOOTSTRAP'
"""Anonymous GitHub bootstrap. Bundled into install.sh; no credential prompt."""
import base64
import hashlib
import json
import re
import sys
import urllib.error
import urllib.request

API='https://api.github.com/repos/xlp567/singbox-manager'
LIMIT=2*1024*1024


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self,*args,**kwargs):raise ValueError('安装接口返回跳转，已停止')


def read(path):
    if not re.fullmatch(r'/commits/main|/contents/install\.py\?ref=[a-f0-9]{40}',path):raise ValueError('安装路径无效')
    headers={'Accept':'application/vnd.github+json','User-Agent':'singbox-manager-public-install','X-GitHub-Api-Version':'2022-11-28'}
    try:
        with urllib.request.build_opener(NoRedirect).open(urllib.request.Request(API+path,headers=headers),timeout=25) as response:data=response.read(LIMIT+1)
    except urllib.error.HTTPError as error:raise ValueError('GitHub HTTP '+str(error.code)+'；请确认仓库已公开，或稍后重试') from None
    except (urllib.error.URLError,TimeoutError):raise ValueError('无法连接 GitHub，请稍后重试') from None
    if len(data)>LIMIT:raise ValueError('安装响应过大')
    value=json.loads(data)
    if not isinstance(value,dict):raise ValueError('安装响应格式异常')
    return value


def launch():
    commit=read('/commits/main').get('sha','')
    if not re.fullmatch(r'[a-f0-9]{40}',commit):raise ValueError('GitHub 提交标识无效')
    item=read('/contents/install.py?ref='+commit)
    if item.get('type')!='file' or item.get('encoding')!='base64' or not isinstance(item.get('size'),int) or not 0<=item['size']<=LIMIT:raise ValueError('安装文件格式异常')
    data=base64.b64decode(''.join(item['content'].split()),validate=True)
    if len(data)!=item['size'] or hashlib.sha1(b'blob '+str(len(data)).encode()+b'\0'+data).hexdigest()!=item.get('sha'):raise ValueError('安装文件内容摘要不符')
    exec(compile(data,'<verified public GitHub installer>','exec'),{'__name__':'__main__','BOOTSTRAP_TOKEN':'','BOOTSTRAP_COMMIT':commit})


if __name__=='__main__':
    try:launch()
    except KeyboardInterrupt:print('\n已取消。',file=sys.stderr);raise SystemExit(130)
    except (ValueError,OSError,KeyError,TypeError) as error:print('安装未开始：'+str(error),file=sys.stderr);raise SystemExit(1)
SBM_PUBLIC_BOOTSTRAP
