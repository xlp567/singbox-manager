#!/usr/bin/env python3
"""Build a literal one-line entry with hidden input and an authenticated loader."""
import pathlib
import shlex

ROOT=pathlib.Path(__file__).resolve().parents[1]
def first_stage():
    # Only program text enters argv. The token is read at runtime and stays in memory.
    return (
        'import base64 as b,getpass as g,hashlib as h,json as j,re,sys,urllib.request as u;'
        't=g.getpass("GitHub 只读令牌（隐藏输入）: ").strip();'
        're.fullmatch("[A-Za-z0-9_]{10,255}",t) or sys.exit("令牌格式无效");'
        'o=u.build_opener(type("N",(u.HTTPRedirectHandler,),{"redirect_request":lambda *a,**k:None})());'
        'q=lambda p:j.loads(o.open(u.Request("https://api.github.com/repos/xlp567/singbox-manager"+p,'
        'headers={"Accept":"application/vnd.github+json","Authorization":"Bearer "+t}),timeout=20).read(2097153));'
        'c=q("/commits/main").get("sha","");re.fullmatch("[a-f0-9]{40}",c) or sys.exit("提交标识无效");'
        'p=q("/contents/install.py?ref="+c);'
        'd=b.b64decode("".join(p["content"].split()),validate=True);'
        '(p.get("type")=="file" and p.get("encoding")=="base64" and len(d)==p.get("size")<=2097152 and '
        'h.sha1(b"blob "+str(len(d)).encode()+b"\\0"+d).hexdigest()==p.get("sha")) or sys.exit("下载校验失败");'
        'exec(compile(d,"<GitHub installer>","exec"),{"__name__":"__main__","BOOTSTRAP_TOKEN":t,"BOOTSTRAP_COMMIT":c})'
    )


def private_command():
    prefix='(set -e; [ "$(id -u)" -eq 0 ] && [ -t 0 ] || { echo "请用 root SSH 交互终端执行"; exit 1; }; '
    deps='if ! command -v python3 >/dev/null 2>&1 || ! command -v flock >/dev/null 2>&1 || [ ! -s /etc/ssl/certs/ca-certificates.crt ]; then apt-get update; apt-get install -y python3 ca-certificates util-linux; fi; '
    command=prefix+deps+'python3 -c '+shlex.quote(first_stage())+')'
    return command+'\n'


def build():
    loader=(ROOT/'tools/public_bootstrap.py').read_text()
    installer='''#!/usr/bin/env bash
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
'''+loader+'''SBM_PUBLIC_BOOTSTRAP
'''
    (ROOT/'install.sh').write_text(installer);(ROOT/'install.sh').chmod(0o755)
    command='bash <(curl -fsSL https://raw.githubusercontent.com/xlp567/singbox-manager/main/install.sh)\n'
    (ROOT/'新服务器一键安装命令.txt').write_text(command)
    return command

if __name__=='__main__':
    build();print('Built short public GitHub installation command')
