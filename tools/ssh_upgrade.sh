#!/usr/bin/env bash
# Run on the local computer. Uploads a verified manager to /root and invokes its installer.
# SSH handles passwords / keys normally; this script never stores login credentials.
set -Eeuo pipefail
PROJECT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
target=${1:-}
port=${2:-22}
[[ $# -ge 1 && $# -le 2 && $target =~ ^root@[A-Za-z0-9._-]+$ && $port =~ ^[0-9]{1,5}$ ]] || {
    printf '%s\n' '用法：bash tools/ssh_upgrade.sh root@服务器地址 [SSH端口]' >&2; exit 1;
}
(( 10#$port>=1 && 10#$port<=65535 )) || { printf '%s\n' 'SSH 端口无效。' >&2; exit 1; }
for command in python3 ssh scp; do command -v "$command" >/dev/null || { printf '缺少命令：%s\n' "$command" >&2; exit 1; }; done
expected=$(python3 - "$PROJECT" <<'PY'
import hashlib,pathlib,re,sys
p=pathlib.Path(sys.argv[1]);s=(p/'singbox-manager.sha256').read_text()
m=re.fullmatch(r'([a-f0-9]{64})\s+singbox-manager.sh\s*',s)
if not m or hashlib.sha256((p/'singbox-manager.sh').read_bytes()).hexdigest()!=m[1]:raise SystemExit('本地脚本校验失败，未上传')
print(m[1])
PY
)
session=$(mktemp -d "${TMPDIR:-/tmp}/sbm-ssh-upload.XXXXXX")
chmod 700 "$session"
control=${SBM_SSH_CONTROL:-$session/control}
options=(-o StrictHostKeyChecking=yes -o ControlMaster=auto -o ControlPersist=60 -o "ControlPath=$control" -o ConnectTimeout=15)
cleanup_upload() {
    if [[ -z ${SBM_SSH_CONTROL:-} ]]; then ssh "${options[@]}" -p "$port" -O exit "$target" >/dev/null 2>&1 || true; fi
    rm -rf -- "$session"
}
trap cleanup_upload EXIT
printf '目标：%s，SSH 端口 %s\n本地脚本 SHA-256：%s\n' "$target" "$port" "$expected"
ssh "${options[@]}" -n -p "$port" "$target" 'test "$(id -u)" = 0 && test "$(uname -s)" = Linux && test -d /root'
nonce=$(python3 -c 'import secrets;print(secrets.token_hex(8))')
candidate=/root/singbox-manager-upload-$nonce.sh
checksum=/root/singbox-manager-upload-$nonce.sha256
scp "${options[@]}" -P "$port" "$PROJECT/singbox-manager.sh" "$target:$candidate"
scp "${options[@]}" -P "$port" "$PROJECT/singbox-manager.sha256" "$target:$checksum"
# Nonce is generated locally and consists only of hexadecimal characters.
ssh "${options[@]}" -tt -p "$port" "$target" "bash $candidate self-update local $candidate"
actual=$(ssh "${options[@]}" -n -p "$port" "$target" 'sha256sum /usr/local/bin/sbm' | awk '{print $1}')
[[ $actual == "$expected" ]] || { printf '%s\n' '未安装所上传版本（可能已取消）；保留候选文件供核查。' >&2; exit 1; }
ssh "${options[@]}" -n -p "$port" "$target" "rm -f -- $candidate $checksum"
printf '%s\n' 'SSH 上传与管理脚本升级成功；远端摘要一致。'
