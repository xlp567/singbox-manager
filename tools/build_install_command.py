#!/usr/bin/env python3
"""Build the copy-once bootstrap command from its tested source."""
import pathlib

ROOT=pathlib.Path(__file__).resolve().parents[1]
def build():
    loader=(ROOT/'tools/github_bootstrap.py').read_text()
    command='''#!/usr/bin/env bash
# 请在新 Debian/Ubuntu 服务器的 root SSH 终端整段粘贴
(
set -e
[ "$(id -u)" -eq 0 ] || { echo '请先 sudo -i 切换到 root'; exit 1; }
# shellcheck disable=SC1091
. /etc/os-release
[ "$ID" = debian ] || [ "$ID" = ubuntu ] || { echo '仅支持 Debian/Ubuntu'; exit 1; }
if ! command -v python3 >/dev/null 2>&1 || ! command -v flock >/dev/null 2>&1 || [ ! -s /etc/ssl/certs/ca-certificates.crt ]; then
    apt-get update
    apt-get install -y python3 ca-certificates util-linux
fi
python3 - <<'SBM_GITHUB_BOOTSTRAP'
'''+loader+'''SBM_GITHUB_BOOTSTRAP
)
'''
    (ROOT/'新服务器一键安装命令.txt').write_text(command)
    return command

if __name__=='__main__':
    build();print('Built private GitHub first-install command')
