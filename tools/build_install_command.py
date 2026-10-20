#!/usr/bin/env python3
"""Build public/private bootstraps with the same pinned release verifier."""
import base64
import pathlib
import re
import shlex

ROOT=pathlib.Path(__file__).resolve().parents[1]


def inline_trust(source):
    trust=(ROOT/'src/sbm/core/release_trust.py').read_text()
    public=(ROOT/'RELEASE_SIGNING.pub').read_text().strip()
    if 'PUBLIC_KEY='+repr(public) not in trust:raise ValueError('固定公钥与 RELEASE_SIGNING.pub 不一致')
    return re.sub(r'^from sbm\.core\.release_trust import [^\n]+$',lambda match:trust,source,flags=re.M)


def embedded_loader():return inline_trust((ROOT/'tools/public_bootstrap.py').read_text())


def first_stage():
    loader=embedded_loader().split("if __name__=='__main__':",1)[0]
    loader+='\nimport getpass\ntoken=getpass.getpass("GitHub 只读令牌（隐藏输入）: ").strip()\n'
    loader+='if not re.fullmatch(r"[A-Za-z0-9_]{10,255}",token):raise ValueError("令牌格式无效")\nlaunch(token)\n'
    payload=base64.b64encode(loader.encode()).decode()
    return 'import base64;exec(compile(base64.b64decode('+repr(payload)+'),"<bundled signed bootstrap>","exec"))'


def private_command():
    prefix='(set -e; [ "$(id -u)" -eq 0 ] && [ -t 0 ] || { echo "请用 root SSH 交互终端执行"; exit 1; }; '
    deps='if ! command -v python3 >/dev/null 2>&1 || ! command -v flock >/dev/null 2>&1 || ! command -v ssh-keygen >/dev/null 2>&1 || [ ! -s /etc/ssl/certs/ca-certificates.crt ]; then apt-get update; apt-get install -y python3 ca-certificates util-linux openssh-client; fi; '
    return prefix+deps+'python3 -c '+shlex.quote(first_stage())+')\n'


def build():
    loader=embedded_loader()
    (ROOT/'install.py').write_text(inline_trust((ROOT/'src/bootstrap/install.py').read_text()))
    installer='''#!/usr/bin/env bash
# singbox-manager signed Release bootstrap; runtime changes remain separate.
set -Eeuo pipefail
umask 077
(( EUID == 0 )) || { echo '请先 sudo -i，切换到 root'; exit 1; }
[[ -t 0 ]] || { echo '请在 SSH 交互终端执行，使用 bash <(curl -fsSL URL)'; exit 1; }
[[ $(uname -s) == Linux ]] || { echo '需要 Debian/Ubuntu Linux'; exit 1; }
# shellcheck disable=SC1091
. /etc/os-release
[[ $ID == debian || $ID == ubuntu ]] || { echo '仅支持 Debian/Ubuntu'; exit 1; }
IFS=. read -r os_major os_minor _ <<<"${VERSION_ID:-}"
[[ $os_major =~ ^[0-9]+$ && ${os_minor:-0} =~ ^[0-9]+$ ]] || { echo '无法识别系统版本；最低支持 Debian 11+ / Ubuntu 20.04+'; exit 1; }
if [[ $ID == debian ]]; then
    (( 10#$os_major >= 11 )) || { echo '最低支持 Debian 11+ / Ubuntu 20.04+；请先升级系统'; exit 1; }
else
    (( 10#$os_major > 20 || (10#$os_major == 20 && 10#${os_minor:-0} >= 4) )) || { echo '最低支持 Debian 11+ / Ubuntu 20.04+；请先升级系统'; exit 1; }
fi
[[ -d /run/systemd/system ]] || { echo '需要运行中的 systemd'; exit 1; }
[[ ! -e /root/singbox-manager.sh && ! -e /usr/local/bin/sbm ]] || { echo '已有管理器，请使用 sbm 菜单 30 → 2'; exit 1; }
if ! command -v python3 >/dev/null 2>&1 || ! command -v flock >/dev/null 2>&1 || ! command -v ssh-keygen >/dev/null 2>&1 || [[ ! -s /etc/ssl/certs/ca-certificates.crt ]]; then
    apt-get update
    apt-get install -y python3 ca-certificates util-linux openssh-client
fi
python3 -c 'import sys; sys.version_info >= (3,8) or sys.exit("需要 Python 3.8+；最低支持 Debian 11+ / Ubuntu 20.04+")'
echo '正在验证最新正式 Release 的签名（公开仓库，无需令牌）……'
python3 - <<'SBM_PUBLIC_BOOTSTRAP'
'''+loader+'''SBM_PUBLIC_BOOTSTRAP
'''
    (ROOT/'install.sh').write_text(installer);(ROOT/'install.sh').chmod(0o755)
    command='bash <(curl -fsSL https://github.com/xlp567/singbox-manager/releases/latest/download/install.sh)\n'
    (ROOT/'新服务器一键安装命令.txt').write_text(command)
    return command


if __name__=='__main__':build();print('Built signed formal-Release bootstraps')
