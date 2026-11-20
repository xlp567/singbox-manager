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
ssh "${options[@]}" -n -p "$port" "$target" 'test "$(id -u)" = 0 && test "$(uname -s)" = Linux && test -x /usr/local/bin/sbm && test ! -L /usr/local/bin/sbm' || {
    printf '%s\n' '需要已安装的 sbm；新服务器请使用正式 Release 的安装入口。' >&2
    exit 1
}
nonce=$(python3 -c 'import secrets;print(secrets.token_hex(8))')
candidate=/root/singbox-manager-upload-$nonce.sh
checksum=/root/singbox-manager-upload-$nonce.sha256
manifest=/root/singbox-manager-upload-$nonce.SHA256SUMS
signature=$manifest.sig
version=$(sed -n 's/^SBM_VERSION=//p' "$PROJECT/singbox-manager.sh")
release=$PROJECT/dist/release-v$version
[[ -f $release/SHA256SUMS && -f $release/SHA256SUMS.sig ]] || { printf '%s\n' '请先准备已签名的正式发布包。' >&2; exit 1; }
PYTHONPATH="$PROJECT/src" python3 - "$release" "$PROJECT/singbox-manager.sh" <<'PY_SIGN'
import hashlib,pathlib,sys
from sbm.core.release_trust import verify_directory
release=pathlib.Path(sys.argv[1]);verify_directory(release)
if (release/'singbox-manager.sh').read_bytes()!=pathlib.Path(sys.argv[2]).read_bytes():raise SystemExit('本地管理器与签名发布包不一致，未执行远端候选脚本')
PY_SIGN
printf '已验证待上传的签名管理器 v%s，SHA-256：%s\n' "$version" "$expected"
while true; do
    printf '%s' '确认上传并安装此版本（yes / no）: ' >&2
    if ! IFS= read -r answer; then printf '%s\n' '输入结束，已取消。'; exit 0; fi
    case $answer in
        [Yy]|[Yy][Ee][Ss]) break;;
        ''|[Nn]|[Nn][Oo]|/cancel) printf '%s\n' '已取消。'; exit 0;;
        *) printf '%s\n' '请输入 yes 或 no。' >&2;;
    esac
done
scp "${options[@]}" -P "$port" "$PROJECT/singbox-manager.sh" "$target:$candidate"
scp "${options[@]}" -P "$port" "$PROJECT/singbox-manager.sha256" "$target:$checksum"
scp "${options[@]}" -P "$port" "$release/SHA256SUMS" "$target:$manifest"
scp "${options[@]}" -P "$port" "$release/SHA256SUMS.sig" "$target:$signature"
# Bind the local consent to the uploaded bytes. The installed verifier still
# checks the signature, version and pending state before applying the update.
ssh "${options[@]}" -n -p "$port" "$target" "echo '$expected  $candidate' | sha256sum -c -"
ssh "${options[@]}" -T -p "$port" "$target" "/usr/local/bin/sbm self-update local $candidate" <<<yes | tee "$session/result"
outcome=$(python3 - "$session/result" "$version" "$expected" <<'PY_RESULT'
import json
import pathlib
import sys

receipts = []
for line in pathlib.Path(sys.argv[1]).read_text().splitlines():
    try:
        row = json.loads(line)
    except ValueError:
        continue
    if isinstance(row, dict) and 'changed' in row:
        receipts.append(row)
if len(receipts) != 1:
    raise SystemExit('没有唯一的安装回执，无法确认结果；已保留上传文件。')
row = receipts[0]
if (type(row['changed']) is not bool or row.get('sha256') != sys.argv[3]
        or row.get('version') != sys.argv[2]):
    raise SystemExit('安装回执与已确认版本或摘要不符；已保留上传文件。')
print('installed' if row['changed'] else 'identical')
PY_RESULT
)
ssh "${options[@]}" -n -p "$port" "$target" "echo '$expected  /root/singbox-manager.sh' | sha256sum -c - && echo '$expected  /usr/local/bin/sbm' | sha256sum -c -"
ssh "${options[@]}" -n -p "$port" "$target" "rm -f -- $candidate $checksum $manifest $signature"
if [[ $outcome == identical ]]; then
    printf '%s\n' '已确认，两个已安装脚本的内容已一致。'
else
    printf '%s\n' 'SSH 上传与管理脚本升级成功；两个安装副本均通过摘要核对。'
fi
