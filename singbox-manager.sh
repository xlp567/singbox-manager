#!/usr/bin/env bash
# singbox-manager v3.5.1 — Debian / Ubuntu, Bash >=4, systemd
# Single-file distribution: Bash service/transaction layer + bundled modular Python config engine.
# Official APT provides the base service; verified official release binaries are staged
# independently so changing runtime versions can be rolled back without downgrading dpkg.
set -uo pipefail
umask 077
export LC_ALL=C.UTF-8
CONF=/etc/sing-box
STATE=/var/lib/singbox-manager
BACKUPS=$STATE/backups
RUNTIME=/opt/singbox-manager
BIN=$RUNTIME/current/sing-box
DROP=/etc/systemd/system/sing-box.service.d/90-singbox-manager.conf
EXPORTS=$STATE/exports
DATA=/var/lib/sing-box
# Not VERSION: sourcing /etc/os-release in require_host would overwrite it.
SBM_VERSION=3.5.1
SHORTCUT=/usr/local/bin/sbm
TMP=''; TX=''; CANDIDATE=''; ACTION_ID=manual
# Shared with transactions.sh bundled below.
# shellcheck disable=SC2034
POLICY=0
#!/usr/bin/env bash
# Stable management core: runtime. Bundled by tools/build.py.
repo_setup() {
    curl --proto '=https' --tlsv1.2 -fsSL --retry 2 --max-time 45 https://sing-box.app/gpg.key -o "$TMP/sagernet.asc"
    gpg --batch --show-keys "$TMP/sagernet.asc" >/dev/null
    install -d -m 755 /etc/apt/keyrings
    install -m 644 "$TMP/sagernet.asc" /etc/apt/keyrings/sagernet.asc
    cat >/etc/apt/sources.list.d/sagernet.sources <<'REPO'
Types: deb
URIs: https://deb.sagernet.org/
Suites: *
Components: *
Enabled: yes
Signed-By: /etc/apt/keyrings/sagernet.asc
REPO
    chmod 644 /etc/apt/sources.list.d/sagernet.sources
}
base_install() {
    managed_unit_check
    if [[ -x /usr/bin/sing-box ]]; then
        dpkg-query -W -f='${Status}' sing-box 2>/dev/null | grep -qx 'install ok installed' || die '发现非 APT 安装；请人工迁移，避免覆盖。'
        return
    fi
    [[ ! -e /usr/sbin/policy-rc.d ]] || die '已有 policy-rc.d，请管理员先安装官方 APT sing-box 包。'
    repo_setup
    apt-get update
    local selected='' v
    while read -r v; do
        [[ $v =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9]+)?$ ]] || continue
        if [[ -z $selected ]] || dpkg --compare-versions "$v" gt "$selected"; then selected=$v; fi
    done < <(apt-cache madison sing-box | awk '$5 ~ /^https:\/\/deb\.sagernet\.org/ {print $3}')
    [[ -n $selected ]] || die '官方 APT 仓库没有本架构可用的稳定包。'
    # Keep package scripts from starting an unconfigured daemon. Do not overwrite a policy.
    (set -o noclobber; printf '#!/bin/sh\n# singbox-manager temporary policy\nexit 101\n' >/usr/sbin/policy-rc.d)
    POLICY=1
    chmod 755 /usr/sbin/policy-rc.d
    apt-get install -y "sing-box=$selected"
    rm -f /usr/sbin/policy-rc.d
    # Consumed by transactions.sh during exit recovery.
    # shellcheck disable=SC2034
    POLICY=0
    # A cancelled first deployment must not leave a default daemon enabled at boot.
    systemctl disable --now sing-box
}
fetch_versions() {
    local arch
    arch=$(dpkg --print-architecture)
    case $arch in amd64|arm64|386|s390x|riscv64|loong64) ;; armhf) arch=armv7;; armel) arch=armv6;; *) die "暂不支持架构 ${arch}；不猜测二进制型号。";; esac
    say '实时查询 SagerNet 官方 GitHub 发布版本（网络失败不会改动现有程序）……'
    curl --proto '=https' --tlsv1.2 -fsSL --retry 2 --connect-timeout 10 --max-time 60 \
        -H 'Accept: application/vnd.github+json' 'https://api.github.com/repos/SagerNet/sing-box/releases?per_page=100' -o "$TMP/releases.json"
    engine releases "$TMP/releases.json" "$TMP/catalog.json" "$arch"
    # Cached only for the dashboard hint; selecting a version always uses this fresh query.
    printf '%s %s\n' "$(engine get "$TMP/catalog.json" stable.version)" "$(date -u +%F)" >"$STATE/latest-stable" || true
}
current_version() {
    local b
    b=$(active_binary 2>/dev/null) || return 0
    "$b" version 2>/dev/null | awk 'NR==1 {print $3}'
}
stage_version() {
    # $1=skip-same: picking the version already running is a no-op (CANDIDATE stays empty).
    local current
    CANDIDATE=''
    disk_guard
    fetch_versions
    current=$(current_version) || current=""
    engine select-release "$TMP/catalog.json" "$TMP/selected.json" "$current"
    stage_selected "${1:-}"
}
stage_selected() {
    # selected.json comes exclusively from the freshly verified official catalog.
    local url version expected dest actual current
    CANDIDATE=''
    current=$(current_version) || current=""
    url=$(engine get "$TMP/selected.json" url)
    version=$(engine get "$TMP/selected.json" version)
    expected=$(engine get "$TMP/selected.json" sha256)
    if [[ ${1:-} == skip-same && $version == "$current" ]]; then
        say "当前已在运行 ${version}，与所选版本相同，无需升级；未下载、未重启服务。"
        return 0
    fi
    say "下载并验证官方版本 ${version}……"
    curl --proto '=https' --tlsv1.2 -fL --retry 2 --connect-timeout 10 --max-time 300 "$url" -o "$TMP/release.tar.gz"
    engine extract "$TMP/selected.json" "$TMP/release.tar.gz" "$TMP/sing-box" "$TMP/companions"
    actual=$("$TMP/sing-box" version | head -n 1)
    [[ $actual == "sing-box version $version" ]] || die '二进制自报版本与选择不符。'
    dest="$RUNTIME/releases/$version-${expected:0:12}"
    install -d -m 700 "$dest"
    install -m 755 "$TMP/sing-box" "$dest/sing-box"
    engine runtime-copy-libs "$TMP/sing-box" "$dest" "$TMP/companions"
    install -m 600 "$TMP/selected.json" "$dest/release.json"
    # Consumed by the controller after staging.
    # shellcheck disable=SC2034
    CANDIDATE=$dest/sing-box
    say "已准备 ${version}；尚未切换运行中的版本。"
}
active_binary() {
    if [[ -f $DROP ]] && grep -q '^ExecStart=/usr/bin/sing-box ' "$DROP" && [[ -x /usr/bin/sing-box ]]; then
        printf '%s' /usr/bin/sing-box; return
    fi
    if [[ -x $BIN ]]; then printf '%s' "$BIN"; elif [[ -x /usr/bin/sing-box ]]; then printf '%s' /usr/bin/sing-box; else return 1; fi
}
#!/usr/bin/env bash
# Stable management core: transactions. Bundled by tools/build.py.
atomic_link() {
    python3 - "$1" "$2" <<'PY'
import os,sys
src,dst=sys.argv[1:]; tmp=dst+'.new'
if os.path.lexists(tmp): os.unlink(tmp)
os.symlink(src,tmp); os.replace(tmp,dst)
PY
}
disk_guard() {
    local p available
    for p in "$STATE" "$RUNTIME"; do
        available=$(df -Pk "$p" | awk 'NR==2 {print $4}')
        [[ $available =~ ^[0-9]+$ ]] || die "无法检查 $p 可用空间。"
        (( available >= 524288 )) || die "${p} 所在磁盘剩余不足 512 MiB，请先整理空间。"
    done
}
snapshot() {
    disk_guard
    local dest binary
    dest=$(mktemp -d "$BACKUPS/$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")
    [[ ! -d $CONF ]] || cp -a "$CONF" "$dest/config-dir"
    [[ ! -f $DROP ]] || cp -a "$DROP" "$dest/manager-override"
    [[ ! -d $EXPORTS ]] || cp -a "$EXPORTS" "$dest/exports"
    [[ ! -d $STATE/protocols ]] || cp -a "$STATE/protocols" "$dest/protocols"
    [[ ! -f $STATE/client-info.txt ]] || cp -a "$STATE/client-info.txt" "$dest/legacy-info"
    if binary=$(active_binary); then
        cp -L "$binary" "$dest/runtime.bin"
        engine runtime-copy-libs "$binary" "$dest/runtime-libs"
        "$binary" version >"$dest/version.txt"
    fi
    systemctl is-active --quiet sing-box && touch "$dest/was-active"
    systemctl is-enabled --quiet sing-box 2>/dev/null && touch "$dest/was-enabled"
    engine backup-seal "$dest"
    engine backup-complete "$dest"
    SNAP=$dest
    audit_record snapshot ok "${dest##*/}"
    say "备份已保存：$dest"
}
restore_files() {
    local src=$1 digest dest
    [[ -f $src/.complete ]] || return 1
    engine backup-verify "$src" || return 1
    if [[ -f $src/runtime.bin ]]; then
        digest=$(engine runtime-id "$src/runtime.bin" "$src/runtime-libs") || return 1
        dest="$RUNTIME/releases/restored-$digest"
        install -d -m 700 "$dest" || return 1
        install -m 755 "$src/runtime.bin" "$dest/sing-box" || return 1
        engine runtime-copy-libs "$src/runtime.bin" "$dest" "$src/runtime-libs" || return 1
        atomic_link "$dest" "$RUNTIME/current" || return 1
    else
        rm -f "$RUNTIME/current" || return 1
    fi
    rm -rf -- "$CONF" "$EXPORTS" || return 1
    [[ ! -d $src/config-dir ]] || cp -a "$src/config-dir" "$CONF" || return 1
    [[ ! -d $src/exports ]] || cp -a "$src/exports" "$EXPORTS" || return 1
    rm -rf -- "$STATE/protocols" || return 1
    [[ ! -d $src/protocols ]] || cp -a "$src/protocols" "$STATE/protocols" || return 1
    if [[ -f $src/manager-override ]]; then
        install -D -m 600 "$src/manager-override" "$DROP" || return 1
        if [[ -f $src/runtime.bin ]]; then
            python3 - "$DROP" "$BIN" <<'PY_FIX_UNIT' || return 1
import pathlib,sys
p=pathlib.Path(sys.argv[1])
s=p.read_text().replace('ExecStart=/usr/bin/sing-box ', 'ExecStart='+sys.argv[2]+' ')
p.write_text(s)
PY_FIX_UNIT
        fi
    else
        rm -f "$DROP" || return 1
    fi
    if [[ -f $src/legacy-info ]]; then
        cp -a "$src/legacy-info" "$STATE/client-info.txt" || return 1
    elif [[ -f $src/client-info.txt ]]; then
        cp -a "$src/client-info.txt" "$STATE/client-info.txt" || return 1
    else
        rm -f "$STATE/client-info.txt" || return 1
    fi
    systemctl daemon-reload || return 1
}
restore_service() {
    local src=$1
    if [[ -f $src/was-enabled ]]; then systemctl enable sing-box || return 1; else systemctl disable sing-box || return 1; fi
    if [[ -f $src/was-active ]]; then systemctl restart sing-box || return 1; else systemctl stop sing-box || return 1; fi
}
cleanup() {
    local rc=$?
    trap - EXIT INT TERM
    set +e
    if [[ -n $TX ]]; then
        say '操作失败/中断，回滚程序、配置、客户端资料及原服务状态……' >&2
        systemctl stop sing-box
        if restore_files "$TX" && restore_service "$TX" && { [[ ! -f $TX/was-active ]] || health; }; then
            rm -f "$STATE/pending"
            audit_record rollback ok "${TX##*/}" || say '警告：恢复成功，但审计日志未能写入。' >&2
            say '回滚完成。' >&2
        else
            audit_record rollback failed "${TX##*/}" || true
            say "回滚未完成；保留恢复标记和备份 ${TX}，下次运行可恢复。" >&2
        fi
    fi
    if (( POLICY )) && grep -qx '# singbox-manager temporary policy' /usr/sbin/policy-rc.d 2>/dev/null; then rm -f /usr/sbin/policy-rc.d; fi
    if [[ $ACTION_ID != audit ]]; then
        if (( rc==0 )); then audit_record action-finish ok || say '警告：操作已完成，但审计日志未能写入。' >&2
        else audit_record action-finish failed || true; fi
    fi
    [[ -z $TMP ]] || rm -rf -- "$TMP"
    exit "$rc"
}
begin_transaction() {
    snapshot
    audit_record transaction-begin started "${SNAP##*/}"
    engine pending-write "$STATE/pending" "$SNAP"
    TX=$SNAP
}
commit_transaction() {
    local snapshot_id=${TX##*/}
    engine pending-clear "$STATE/pending"
    TX=''
    audit_record transaction-commit ok "$snapshot_id" || say '警告：变更已提交，但审计日志未能写入。' >&2
}
recover_pending() {
    if [[ -f /usr/sbin/policy-rc.d ]] && grep -qx '# singbox-manager temporary policy' /usr/sbin/policy-rc.d; then
        say '发现上次安装中断遗留的本脚本临时策略，正在清理。'
        rm -f /usr/sbin/policy-rc.d
    fi
    [[ -f $STATE/pending ]] || return 0
    local src
    src=$(cat "$STATE/pending")
    [[ $src == "$BACKUPS/"* && $src != *'/../'* && -f $src/.complete ]] || die '未完成事务标记异常，请人工检查。'
    setup_tmp
    trap cleanup EXIT
    engine backup-verify "$src" || die '事务备份校验失败；保持原服务，等待人工核查。'
    confirm "上次操作异常中断。先恢复备份 $src 才能继续" || die '恢复前暂不执行其他修改。'
    audit_record recovery-start started "${src##*/}" || true
    systemctl stop sing-box || return 1
    restore_files "$src" || return 1
    restore_service "$src" || return 1
    if [[ -f $src/was-active ]]; then health || return 1; fi
    engine pending-clear "$STATE/pending" || return 1
    audit_record recovery-finish ok "${src##*/}" || say '警告：恢复成功，但审计日志未能写入。' >&2
    say '上次操作已恢复。'
}
#!/usr/bin/env bash
# Stable management core: service. Bundled by tools/build.py.
managed_unit_check() {
    local f
    [[ ! -e /etc/systemd/system/sing-box.service ]] || die '发现自定义主单元，不能安全接管。请人工审查。'
    for f in /etc/systemd/system/sing-box.service.d/*.conf /run/systemd/system/sing-box.service.d/*.conf; do
        [[ -e $f ]] || continue
        if [[ $f != "$DROP" ]] || ! grep -qx '# Managed by singbox-manager.sh' "$f"; then
            die "发现未知服务覆盖项 ${f}，停止接管。"
        fi
    done
}
write_override() {
    install -d -m 755 "$(dirname "$DROP")"
    cat >"$DROP" <<UNIT
# Managed by singbox-manager.sh
[Service]
User=root
Group=root
ExecStart=
ExecStart=$BIN -D $DATA -c $CONF/config.json run
Restart=on-failure
RestartSec=5
UMask=0077
UNIT
    chmod 600 "$DROP"
    systemctl daemon-reload
}
port_free() {
    local net=$1 p=$2 found
    if [[ $net == tcp ]]; then found=$(ss -H -lntp "sport = :$p"); else found=$(ss -H -lnup "sport = :$p"); fi
    [[ -z $found ]] || die "$net/$p 被其他进程占用：$found"
}
health() {
    local before now
    before=$(systemctl show sing-box -p MainPID --value)
    [[ $before =~ ^[1-9][0-9]*$ ]] || return 1
    for _ in 1 2 3 4 5; do
        sleep 2
        systemctl is-active --quiet sing-box || return 1
        now=$(systemctl show sing-box -p MainPID --value)
        [[ $before == "$now" ]] || return 1
    done
}
firewall_info() {
    say '需要在云安全组与本机防火墙放行以下入站端口：'
    engine ports "$TMP/model.json"
    say 'ACME 的 TCP 80/443 必须长期可达以自动续期。还需放行出站 DNS/HTTPS。'
    if command -v ufw >/dev/null; then ufw status verbose || true; fi
    if command -v firewall-cmd >/dev/null; then firewall-cmd --list-all || true; fi
    say '脚本不自动变更防火墙、SSH 或系统网络参数。'
}
service_action() {
    local command=$1 binary
    binary=$(active_binary) || die '尚未安装。'
    managed_unit_check
    if [[ -f $CONF/manager.json ]]; then engine compatibility "$CONF/manager.json" "$binary"; fi
    "$binary" check -c "$CONF/config.json"
    begin_transaction
    systemctl "$command" sing-box
    health || die '服务未稳定运行，自动恢复之前状态。'
    commit_transaction
}
diagnostics() {
    local b
    b=$(active_binary) || die '尚未安装。'
    engine dashboard "$CONF" "$STATE" "$(current_version)"
    say '---------------------- 检查 ----------------------'
    if "$b" check -c "$CONF/config.json"; then say '配置检查：通过'; else say '配置检查：失败 ⚠（见上方错误）'; fi
    say 'sing-box 正在监听：'
    ss -Hlntup | awk '/"sing-box"/ {print "  " $1 " " $5}' || true
    engine logsummary
    if [[ -f $CONF/manager.json ]]; then
        say '本机 TLS 证书握手测试：'
        engine probe "$CONF/manager.json"
    fi
    say '提示：完整日志用菜单 13；本机检查不能替代外网客户端实测，UDP 节点需客户端实际连接。'
}
bbr_action() {
    local f=/etc/sysctl.d/90-singbox-manager-bbr.conf cc
    cc=$(sysctl -n net.ipv4.tcp_congestion_control)
    if [[ -f $f ]]; then
        say "当前拥塞控制：${cc}（由本脚本开启）。"
        confirm '关闭本脚本开启的 BBR，恢复为 cubic' || return 0
        rm -f "$f"
        sysctl -w net.ipv4.tcp_congestion_control=cubic >/dev/null
        sysctl --system >/dev/null 2>&1 || true
        say "已关闭：当前 $(sysctl -n net.ipv4.tcp_congestion_control) / $(sysctl -n net.core.default_qdisc)"
        return 0
    fi
    if [[ $cc == bbr ]]; then say '系统已在使用 BBR（不是本脚本设置的），无需操作。'; return 0; fi
    grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control || modprobe tcp_bbr 2>/dev/null || true
    grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control || die '内核不支持 BBR（部分 OpenVZ/LXC 容器无法修改），未做改动。'
    say "当前拥塞控制：${cc}。"
    say 'BBR 可改善 TCP 节点（AnyTLS/Trojan/VLESS/Reality/VMess/Naive/Shadowsocks）在高延迟、丢包线路上的速度；Hysteria2/TUIC 自带拥塞控制，不受影响。'
    confirm "写入 $f 开启 BBR + fq（立即生效，重启后保持，可随时在此关闭）" || return 0
    printf '# Managed by singbox-manager.sh\nnet.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr\n' >"$f"
    if ! sysctl -p "$f" >/dev/null; then rm -f "$f"; die '系统拒绝修改该参数（可能是容器环境），已撤销。'; fi
    say "已开启：$(sysctl -n net.ipv4.tcp_congestion_control) / $(sysctl -n net.core.default_qdisc)"
}
uninstall_action() {
    confirm '停用服务并卸载 APT sing-box（保留节点、证书、客户端资料、版本和备份）' || return 0
    snapshot
    systemctl disable --now sing-box || true
    apt-get remove -y sing-box
    rm -f "$DROP" /etc/apt/preferences.d/singbox-manager
    systemctl daemon-reload
    say '软件包已卸载。管理数据及运行版本文件保留，便于重装/回退；服务已停用。'
}
#!/usr/bin/env bash
# Management-script updates; deliberately independent of sing-box runtime changes.
manager_update_action() {
    local mode=${1:-menu} path=${2:-} checksum choice backup
    if [[ $mode == menu ]]; then
        say '管理脚本升级（只替换管理器，不重启 sing-box）'
        say '1  安装 SSH/SCP 上传到 /root 的新版脚本'
        say '2  从 GitHub 拉取并安装'
        say '3  回退到之前的管理脚本'
        say '4  配置 GitHub 仓库 / 私有仓库只读令牌'
        say '0  返回'
        read -r -p '升级方式: ' choice || return 0
        case $choice in 1) mode=local;; 2) mode=github;; 3) mode=rollback;; 4) mode=configure;; 0) return 0;; *) die '升级方式无效。';; esac
    fi
    if [[ $mode == configure ]]; then engine manager-update configure "$STATE"; return; fi
    if [[ $mode == rollback ]]; then
        engine manager-update list "$STATE"
        read -r -p '选择要回退的脚本备份完整目录（空行取消）: ' backup || return 0
        [[ -n $backup ]] || return 0
        engine manager-update rollback-stage "$STATE" "$backup" /root "$SHORTCUT" "$TMP"
    elif [[ $mode == local ]]; then
        if [[ -z $path ]]; then read -r -p '已上传的新版脚本路径 [/root/singbox-manager.sh]: ' path || return 0; fi
        path=${path:-/root/singbox-manager.sh}
        [[ ${path%/*} == /root && $path == *.sh && ! -L $path ]] || die '请将新版 .sh 普通文件通过 SSH/SCP 上传到 /root。'
        checksum=${path%.sh}.sha256
        [[ -f $path && -f $checksum && ! -L $checksum ]] || die "请同时上传脚本与校验文件：$path 和 $checksum"
        cp -- "$path" "$TMP/singbox-manager.sh"
        cp -- "$checksum" "$TMP/singbox-manager.sha256"
    elif [[ $mode == github ]]; then
        engine manager-update fetch "$STATE" "$TMP" >"$TMP/update-origin.json"
        say 'GitHub 源与固定提交：'
        engine get "$TMP/update-origin.json" repository
        engine get "$TMP/update-origin.json" commit
    else die '脚本升级方式无效。'; fi
    engine manager-update verify "$TMP/singbox-manager.sh" "$TMP/singbox-manager.sha256" >"$TMP/update-info.json"
    say "目标管理脚本版本：$(engine get "$TMP/update-info.json" version)"
    say "SHA-256：$(engine get "$TMP/update-info.json" sha256)"
    say '安装位置：/root/singbox-manager.sh、/usr/local/bin/sbm'
    confirm '备份当前管理脚本并安装以上版本' || return 0
    engine manager-update install "$TMP/singbox-manager.sh" "$TMP/singbox-manager.sha256" "$STATE" /root "$SHORTCUT"
    ACTION_ID=self-update audit_record action-finish ok || say '警告：脚本已安装，但审计未能写入。' >&2
    say "管理脚本安装完成；旧脚本备份：$STATE/manager-backups/"
    say '请退出当前菜单，再运行 sbm 使用新版。'
}

say() { printf '%s\n' "$*"; }
die() { say "错误：$*" >&2; exit 1; }
confirm() {
    local answer
    while true; do
        read -r -p "$*（输入 yes 确认 / no 取消，不区分大小写）: " answer || return 1
        case $answer in
            [Yy]|[Yy][Ee][Ss]) return 0;;
            ''|[Nn]|[Nn][Oo]) say '已取消，未提交本次变更。'; return 1;;
            *) say '无法识别，请输入 yes 或 no。';;
        esac
    done
}
engine() { SBM_PROTOCOL_DIR="$STATE/protocols" python3 "$TMP/engine.pyz" "$@"; }
audit_record() {
    if [[ -n $TMP && -f $TMP/engine.pyz ]] && command -v python3 >/dev/null; then
        engine audit-append "$STATE/audit.jsonl" "$1" "$ACTION_ID" "$2" "${3:-}"
    fi
}
setup_tmp() {
    TMP=$(mktemp -d "$STATE/tmp.XXXXXX")
    emit_engine >"$TMP/engine.pyz"
}
require_host() {
    (( BASH_VERSINFO[0] >= 4 )) || die '需要 Bash 4+，请在 Debian/Ubuntu VPS 上执行。'
    [[ $(uname -s) == Linux && -r /etc/os-release ]] || die '仅支持 Linux Debian/Ubuntu。'
    (( EUID == 0 )) || die '请运行 sudo bash singbox-manager.sh。'
    # shellcheck disable=SC1091
    . /etc/os-release
    [[ ${ID:-} == debian || ${ID:-} == ubuntu ]] || die '仅支持 Debian/Ubuntu。'
    [[ -d /run/systemd/system ]] || die '需要正在运行的 systemd。'
    if [[ ${1:-interactive} == interactive ]]; then
        [[ -t 0 ]] || die '需要交互式终端，请先下载脚本，不要用 curl 管道执行。'
    fi
    command -v flock >/dev/null || die '请先安装 util-linux。'
    local p
    for p in "$CONF" "$CONF/config.json" "$CONF/manager.json" "$STATE" "$STATE/protocols" "$STATE/manager-backups" "$STATE/update-source.json" "$STATE/github-token" "$BACKUPS" "$RUNTIME" "$DROP"; do
        [[ ! -L $p ]] || die "管理目录/文件为符号链接，请先人工核查：$p"
    done
    install -d -m 700 "$STATE" "$BACKUPS" "$RUNTIME" "$RUNTIME/releases"
    exec 9>"$STATE/manager.lock"
    flock -n 9 || die '已有另一个管理脚本运行。'
    # Holding the lock means any leftover work directory is from an interrupted run.
    find "$STATE" -mindepth 1 -maxdepth 1 -type d -name 'tmp.*' -exec rm -rf -- {} + 2>/dev/null || true
    [[ ${1:-interactive} != interactive ]] || say "系统：${PRETTY_NAME}；架构：$(dpkg --print-architecture)"
}
dependencies() {
    local c missing=0
    for c in python3 curl gpg openssl ss dig; do command -v "$c" >/dev/null || missing=1; done
    if (( missing )); then
        say '安装必要的系统依赖……'
        apt-get update
        apt-get install -y python3 curl ca-certificates gnupg openssl iproute2 dnsutils util-linux
    fi
}
pristine_package_config() {
    local expected actual extra
    [[ -f $CONF/config.json && ! -L $CONF/config.json ]] || return 1
    if systemctl is-active --quiet sing-box; then say '阻挡原因：sing-box 服务正在运行，不能作为未使用的默认配置接管。' >&2; return 1; fi
    expected=$(dpkg-query -W -f='${Conffiles}\n' sing-box 2>/dev/null | awk -v path="$CONF/config.json" '$1==path && NF==2 {print $2}') || return 1
    [[ $expected =~ ^[[:xdigit:]]{32}$ ]] || { say '阻挡原因：dpkg 未提供可核对的默认配置摘要。' >&2; return 1; }
    actual=$(md5sum "$CONF/config.json" | awk '{print $1}') || return 1
    [[ $actual == "$expected" ]] || { say '阻挡原因：当前 config.json 与 dpkg 的默认配置摘要不一致。' >&2; return 1; }
    extra=$(find "$CONF" -mindepth 1 -maxdepth 1 ! -name config.json -print -quit) || return 1
    [[ -z $extra ]] || { say "阻挡原因：配置目录还包含额外文件：$extra" >&2; return 1; }
}
prepare_model() {
    managed_unit_check
    if [[ -f $CONF/manager.json ]]; then
        engine verify-generated "$CONF/manager.json" "$CONF/config.json"
        cp "$CONF/manager.json" "$TMP/model.json"
    elif [[ -f $DROP && -f $CONF/config.json ]]; then
        say '检测到旧版脚本配置，先验证能否无损迁移。'
        engine migrate "$CONF/config.json" "$TMP/model.json"
        say '旧节点、端口及密码已保留到临时草稿；尚未写入。'
    elif [[ -f $CONF/config.json ]]; then
        # Compare against dpkg's installed conffile reference, never guess from JSON shape.
        if pristine_package_config; then
            say '已核对为未修改且未运行的 APT 默认配置，可继续初始化。'
            engine new "$TMP/model.json"
        else die '没有自动覆盖现有配置。若要重新搭建，请选菜单 23：先备份现状，再重新初始化。'; fi
    else
        engine new "$TMP/model.json"
    fi
}
apply_draft() {
    local candidate=$1 mode=${2:-preserve} net p
    engine draft-save "$TMP/model.json" "$STATE/draft.json" "$CONF" "$mode"
    say '本次草稿已保存；若取消或检查失败，可用菜单 22 继续。'
    engine compatibility "$TMP/model.json" "$candidate"
    engine netcheck "$TMP/model.json"
    engine compile-checked "$TMP/model.json" "$candidate" "$TMP/config.json"
    engine export "$TMP/model.json" "$TMP/exports"
    engine preflight "$TMP/model.json"
    firewall_info
    if ! confirm '已核对节点/防火墙并同意所选 ACME CA 条款；应用此次变更（服务短暂重启）'; then
        say '节点尚未部署；草稿和凭据已保存，选择菜单 22 可继续。'
        return 0
    fi
    # A human/another tool may edit files while the final confirmation is open.
    # Recheck the saved base before stopping any service.
    engine draft-load "$STATE/draft.json" "$CONF" "$TMP/checked-model.json"
    begin_transaction
    systemctl stop sing-box
    engine ports "$TMP/model.json" >"$TMP/ports"
    while read -r net p; do port_free "$net" "$p"; done <"$TMP/ports"
    # Promote candidate into an immutable directory before switching the symlink.
    local digest dest
    digest=$(engine runtime-id "$candidate")
    dest="$RUNTIME/releases/runtime-$digest"
    install -d -m 700 "$dest"
    if [[ ! -f $dest/sing-box ]] || ! cmp -s "$candidate" "$dest/sing-box"; then
        install -m 755 "$candidate" "$dest/sing-box"
    fi
    engine runtime-copy-libs "$candidate" "$dest"
    atomic_link "$dest" "$RUNTIME/current"
    install -d -m 700 "$CONF" "$DATA/acme"
    install -m 600 "$TMP/model.json" "$CONF/manager.json"
    install -m 600 "$TMP/config.json" "$CONF/config.json"
    write_override
    "$BIN" check -c "$CONF/config.json"
    systemctl restart sing-box
    health || die '服务启动不稳定，自动回滚。'
    local pid found
    pid=$(systemctl show sing-box -p MainPID --value)
    engine nodeports "$TMP/model.json" >"$TMP/nodeports"
    while read -r net p; do
        if [[ $net == tcp ]]; then found=$(ss -H -lntp "sport = :$p"); else found=$(ss -H -lnup "sport = :$p"); fi
        [[ $found == *"pid=$pid,"* ]] || die "节点 $net/$p 未由 sing-box 正常监听，自动回滚。"
    done <"$TMP/nodeports"
    if [[ $mode == start ]]; then systemctl enable sing-box; else
        # Editing stopped nodes does not silently leave the whole service running.
        [[ -f $TX/was-active ]] || systemctl stop sing-box
    fi
    rm -rf "$EXPORTS"
    cp -a "$TMP/exports" "$EXPORTS"
    install -m 600 "$EXPORTS/client-info.txt" "$STATE/client-info.txt"
    commit_transaction
    rm -f "$STATE/draft.json"
    say '变更已保存；证书签发和公网连通性请用“诊断”及客户端复测。'
    cat "$EXPORTS/client-info.txt"
    show_qr
    say "客户端资料目录：$EXPORTS"
}
initialize() {
    confirm '初始化/安装服务并添加节点（已有节点将保留）' || return 0
    dependencies
    stage_version
    base_install
    prepare_model
    engine add "$TMP/model.json" "$CANDIDATE"
    apply_draft "$CANDIDATE" start
}
reinitialize() {
    managed_unit_check
    say '此入口会先备份当前配置和运行程序，再创建全新的节点草稿。'
    say '现有配置不会自动合并；只有最后确认提交后才切换服务，旧节点将由新节点替代。'
    confirm '备份现状并开始重新初始化' || return 0
    dependencies
    snapshot
    say "现状备份完成：${SNAP}；填写期间保留现有文件及服务状态。"
    stage_version
    base_install
    engine new "$TMP/model.json"
    engine add "$TMP/model.json" "$CANDIDATE"
    apply_draft "$CANDIDATE" start
}
resume_draft() {
    [[ -f $STATE/draft.json ]] || die '没有已保存草稿。旧 v2 取消时会删除临时草稿，需要重新输入一次。'
    dependencies
    managed_unit_check
    engine draft-load "$STATE/draft.json" "$CONF" "$TMP/model.json"
    local mode
    mode=$(engine get "$STATE/draft.json" mode)
    engine list "$TMP/model.json"
    local more
    read -r -p '提交前先往草稿里补加节点吗？y/N: ' more || more=''
    confirm '继续处理以上已保存草稿（当前文件未发生变化）' || return 0
    stage_version
    base_install
    if [[ $more == [Yy] ]]; then engine add "$TMP/model.json" "$CANDIDATE"; fi
    apply_draft "$CANDIDATE" "$mode"
}
draft_discard_action() {
    [[ -f $STATE/draft.json ]] || { say '没有未提交草稿。'; return 0; }
    local expected archived
    expected=$(engine draft-fingerprint "$STATE/draft.json")
    engine draft-summary "$STATE/draft.json"
    say '只清理未提交的草稿；线上配置、节点、端口和服务保持原状。'
    confirm '将这份草稿移入私有归档，并清除草稿提醒' || return 0
    archived=$(engine draft-discard "$STATE/draft.json" "$STATE/discarded-drafts" "$expected")
    audit_record draft-discard ok || say '警告：草稿已归档，但审计记录未能写入。' >&2
    say "草稿已清理，归档保存在：$archived"
}
draft_action() {
    local choice
    engine draft-summary "$STATE/draft.json"
    say '1  继续编辑 / 提交草稿'
    say '2  查看草稿节点'
    say '3  放弃并清理草稿（先归档）'
    say '4  彻底删除当前草稿（不再归档）'
    say '5  彻底清空已归档草稿（释放空间）'
    say '0  返回'
    read -r -p '草稿操作 [1]: ' choice || return 0
    case ${choice:-1} in
        1) resume_draft;;
        2) engine draft-summary "$STATE/draft.json";;
        3) draft_discard_action;;
        4) draft_purge_action;;
        5) draft_archives_purge_action;;
        0) return 0;;
        *) die '草稿操作序号无效。';;
    esac
}
permanent_delete_confirm() {
    local answer
    read -r -p '此操作无法从草稿归档恢复；输入 DELETE 永久删除，其他输入取消: ' answer || return 1
    [[ $answer == DELETE ]] || { say '已取消永久删除。'; return 1; }
}
draft_purge_action() {
    [[ -f $STATE/draft.json ]] || { say '没有未提交草稿。'; return 0; }
    local expected
    expected=$(engine draft-fingerprint "$STATE/draft.json")
    engine draft-summary "$STATE/draft.json"
    say "将永久删除：$STATE/draft.json"
    permanent_delete_confirm || return 0
    engine draft-purge "$STATE/draft.json" "$expected"
    ACTION_ID=draft-purge audit_record action-finish ok || say '警告：草稿已永久删除，但审计未能写入。' >&2
    say '当前草稿已彻底删除；未产生归档文件。'
}
draft_archives_purge_action() {
    engine draft-archive-plan "$STATE/discarded-drafts" "$TMP/draft-delete-plan.json"
    [[ $(engine get "$TMP/draft-delete-plan.json" count) != 0 ]] || return 0
    permanent_delete_confirm || return 0
    engine draft-archives-purge "$STATE/discarded-drafts" "$TMP/draft-delete-plan.json"
    ACTION_ID=draft-archives-purge audit_record action-finish ok || say '警告：草稿归档已清空，但审计未能写入。' >&2
    say '以上已归档草稿已彻底删除。'
}
paths_action() {
    local unit script
    unit=$(systemctl show sing-box -p FragmentPath --value 2>/dev/null) || unit=''
    script=$(readlink -f "${BASH_SOURCE[0]}")
    engine paths "$CONF" "$STATE" "$RUNTIME" "$DROP" "$EXPORTS" "$DATA" "$SHORTCUT" "$script" "$unit" "${1:-}"
}
protocol_action() {
    local choice path kind
    engine protocols --text
    engine profile errors
    say '1  从官方核心自动发现协议并生成表单（无需 JSON）'
    say '2  导入协议模块 JSON'
    say '3  自定义模块配置检查'
    say '4  归档移除自定义模块'
    say '5  高级：手工 JSON 模板向导'
    say '6  扫描当前核心的全部官方协议'
    say '0  返回'
    read -r -p '模块操作: ' choice || return 0
    case $choice in
        1) engine official create "$(active_binary)";;
        2) read -r -p '协议模板 JSON 路径: ' path; engine profile import "$path" "$(active_binary)";;
        3) read -r -p '模块标识（例如 custom-newproto，all 检查全部）: ' kind; engine module-test "$(active_binary)" "$kind";;
        4) read -r -p '待移除模块标识: ' kind; engine profile delete "$kind" "$CONF" "$STATE";;
        5) engine profile create "$(active_binary)";;
        6) engine official list "$(active_binary)";;
        0) return 0;;
        *) die '模块操作序号无效。';;
    esac
}
list_action() {
    if [[ -f $CONF/manager.json || -f $DROP ]]; then
        prepare_model
        engine list "$TMP/model.json"
    else
        say '现有 sing-box 配置尚未由本脚本接管，所以没有可列出的托管节点；线上服务不受影响。'
        say '接管方法：菜单 23 先备份，再按原端口和密码重新填写全部节点。'
    fi
    if [[ -f $STATE/draft.json ]]; then
        python3 -c 'import json,sys; json.dump(json.load(open(sys.argv[1]))["model"],open(sys.argv[2],"w"))' "$STATE/draft.json" "$TMP/draft-model.json"
        say '—— 未提交草稿中的节点（菜单 22 可补加节点后提交）——'
        engine list "$TMP/draft-model.json"
    fi
}
edit_nodes() {
    local operation=$1 binary
    binary=$(active_binary) || die '请先初始化安装。'
    require_managed
    prepare_model
    engine "$operation" "$TMP/model.json" "$binary"
    apply_draft "$binary"
}
change_version() {
    require_managed
    prepare_model
    stage_version skip-same
    [[ -n $CANDIDATE ]] || return 0
    apply_draft "$CANDIDATE"
}
restore_action() {
    local dirs=() d n chosen checker
    for d in "$BACKUPS"/*; do [[ ! -f $d/.complete || ! -f $d/config-dir/config.json ]] || dirs+=("$d"); done
    (( ${#dirs[@]} )) || die '没有可恢复的配置快照。'
    for n in "${!dirs[@]}"; do say "$((n+1))) ${dirs[n]##*/}"; done
    read -r -p '恢复序号: ' n
    [[ $n =~ ^[1-9][0-9]{0,5}$ ]] || die '无效序号。'
    (( n<=${#dirs[@]} )) || die '无效序号。'
    chosen=${dirs[n-1]}
    checker=$chosen/runtime.bin
    engine backup-verify "$chosen"
    if [[ ! -f $checker ]]; then
        say '此旧版备份没有运行二进制，仅恢复配置；将使用现有 APT 程序。'
        checker=/usr/bin/sing-box
        [[ -x $checker ]] || die '缺少旧版备份所需的 APT 运行程序。'
    fi
    chmod u+x "$checker"
    if [[ -f $chosen/config-dir/manager.json ]]; then engine compatibility "$chosen/config-dir/manager.json" "$checker"; fi
    "$checker" check -c "$chosen/config-dir/config.json"
    confirm "恢复配置、运行版本及当时启停状态：${chosen##*/}" || return 0
    begin_transaction
    systemctl stop sing-box
    restore_files "$chosen"
    restore_service "$chosen"
    if [[ -f $chosen/was-active ]]; then health || die '恢复后的服务不稳定。'; fi
    commit_transaction
    say '恢复完成；ACME 缓存不回退，以避免重复签发和丢失续期结果。'
}
export_action() {
    require_managed
    prepare_model
    engine export "$TMP/model.json" "$TMP/exports"
    install -d -m 700 "$EXPORTS"
    cp "$TMP/exports/"* "$EXPORTS/"
    chmod 600 "$EXPORTS/"*
    install -m 600 "$EXPORTS/client-info.txt" "$STATE/client-info.txt"
    cat "$EXPORTS/client-info.txt"
    show_qr
    say "已保存摘要、导入链接及 sing-box 客户端出站配置片段：$EXPORTS"
}
require_managed() {
    [[ -f $CONF/manager.json || -f $DROP ]] && return 0
    [[ -f $CONF/config.json ]] || die '尚未部署节点，请先用菜单 1 初始化安装。'
    if [[ -f $STATE/draft.json ]]; then
        die '现有配置尚未由本脚本接管。你有未提交草稿：用菜单 22 补全节点并提交，或用菜单 23 重新接管。'
    fi
    die '现有配置尚未由本脚本接管，暂不能使用此功能。请先用菜单 23 接管（会先备份，再按原端口和密码重新填写节点）。'
}
show_qr() {
    [[ -s $EXPORTS/links.txt ]] || return 0
    if ! command -v qrencode >/dev/null; then
        say '提示：安装 qrencode（apt-get install -y qrencode）后，导出时会同时显示导入二维码。'
        return 0
    fi
    local link i=0
    while IFS= read -r link; do
        [[ -n $link ]] || continue
        i=$((i+1))
        say "── 二维码 ${i}：${link%%://*} ──"
        qrencode -t ANSIUTF8 -m 1 "$link" || true
    done <"$EXPORTS/links.txt"
    say '二维码含明文凭据，请勿截图外传。'
}
prune_action() {
    local keep pending='' d n=0 current all=() old=() stale=()
    [[ ! -f $STATE/pending ]] || pending=$(cat "$STATE/pending")
    say '当前占用：'
    du -sh "$BACKUPS" "$RUNTIME/releases" 2>/dev/null || true
    read -r -p '保留最近几份备份 [5]: ' keep
    keep=${keep:-5}
    [[ $keep =~ ^[1-9][0-9]{0,2}$ ]] || die '保留份数需为 1–999。'
    mapfile -t all < <(find "$BACKUPS" -mindepth 1 -maxdepth 1 -type d -name '20*' | sort -r)
    for d in "${all[@]}"; do
        n=$((n+1))
        if (( n > keep )) && [[ $d != "$pending" ]]; then old+=("$d"); fi
    done
    # The live runtime is whatever "current" resolves to; every other staged release is recoverable from backups.
    current=$(readlink -f "$RUNTIME/current" 2>/dev/null || true)
    for d in "$RUNTIME/releases"/*; do
        [[ -d $d && $d != "$current" ]] || continue
        stale+=("$d")
    done
    if (( ${#old[@]} + ${#stale[@]} == 0 )); then say '没有需要清理的内容。'; return 0; fi
    (( ${#old[@]} == 0 )) || { say "将删除 ${#old[@]} 份旧备份："; du -sh "${old[@]}"; }
    (( ${#stale[@]} == 0 )) || { say "将删除 ${#stale[@]} 个未在运行的版本目录："; du -sh "${stale[@]}"; }
    say '当前运行版本、未完成事务备份和最近的备份不会删除。删除后无法再恢复到这些旧快照。'
    confirm '确认删除以上旧数据' || return 0
    for d in "${old[@]}" "${stale[@]}"; do
        case $d in
            "$BACKUPS"/?*|"$RUNTIME/releases"/?*) rm -rf -- "$d";;
            *) die "拒绝删除异常路径：$d";;
        esac
    done
    say '清理完成。'
    df -h "$STATE" | awk 'NR==2 {print "剩余空间：" $4}'
}
install_shortcut() {
    local self
    self=$(readlink -f "${BASH_SOURCE[0]}")
    [[ -f $self ]] || die '无法定位脚本文件；请先把脚本保存到磁盘再执行。'
    if [[ $self == "$SHORTCUT" ]]; then say '当前运行的就是快捷命令本身；用新版脚本执行本项即可更新。'; return 0; fi
    if [[ -e $SHORTCUT ]] && ! grep -q '^# singbox-manager v' "$SHORTCUT"; then
        die "$SHORTCUT 已存在且不是本脚本，未覆盖。"
    fi
    install -m 700 "$self" "$SHORTCUT"
    say "已安装：之后可直接运行 sudo sbm 打开菜单，或 sudo sbm help 查看命令。上传新版脚本后再执行一次本项即可同步。"
}
status_line() {
    local state ver='' nodes='-' b extra=''
    state=$(systemctl is-active sing-box 2>/dev/null) || true
    case $state in active) state='运行中';; inactive) state='已停止';; failed) state='失败';; '') state='未知';; esac
    if b=$(active_binary 2>/dev/null); then ver=$("$b" version 2>/dev/null | awk 'NR==1 {print $3}'); else ver='未安装'; fi
    if [[ -f $CONF/manager.json ]] && command -v python3 >/dev/null; then
        nodes=$(python3 -c 'import json,sys; n=json.load(open(sys.argv[1]))["nodes"]; print("%d/%d" % (sum(x["enabled"] for x in n), len(n)))' "$CONF/manager.json" 2>/dev/null) || nodes='?'
    fi
    [[ ! -f $STATE/draft.json ]] || extra='｜有未提交草稿（22）'
    [[ ! -f $STATE/pending ]] || extra+='｜有未完成事务'
    say "服务：${state}｜运行版本：${ver:-未知}｜启用/全部节点：${nodes}${extra}"
}
usage() {
    cat <<USAGE
singbox-manager v$SBM_VERSION
用法：sudo bash singbox-manager.sh [命令]      （安装快捷命令后可用：sudo sbm [命令]）
  （无参数）  打开交互菜单
  status      服务器与 sing-box 概况（资源、流量、节点、连接、证书）
  versions    对比当前运行版本与官方最新版本
  list        列出节点
  export      重新导出并显示客户端资料（含二维码，需 qrencode）
  check       综合诊断
  backup      立即完整备份
  restart     检查配置后重启服务
  log         实时日志（Ctrl+C 退出）
  prune       清理旧备份与未运行的版本（交互确认）
  shortcut    安装 / 更新快捷命令 $SHORTCUT
  upgrade     选择 / 升级官方运行版本（与菜单 10 相同）
  node        节点操作：list / add / edit / toggle / delete / rotate / acme
  draft       草稿菜单；list / resume / discard（归档）/ purge（永久删除当前草稿）
              purge-archives（永久清空已归档草稿）
  paths       显示运行文件、配置、草稿、备份、证书和日志位置，可加 --json
  self-update 管理脚本升级菜单；local [/root/脚本.sh] / github / rollback / configure
  service     服务操作：status / start / stop / restart
  protocols   列出协议模块与版本要求，可加 --json
  protocol    协议菜单；discover [--json] / create [协议名]（官方自动表单）
              advanced（手工模板）/ import 文件 / test 标识 / delete 标识
  compat      检查现有节点与实际运行程序的兼容性，可加 --json
  validate    统一编译并执行官方配置检查（只读），可加 --json
  module-test [all|协议] [--json]，离线模块配置自检
  runtime     查看实际运行程序的版本和构建能力，可加 --json
  audit       校验本地审计链，可加 --json
  version     显示脚本版本
  help        显示本帮助
USAGE
}
action() (
    set -Eeuo pipefail
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    setup_tmp
    ACTION_ID=$1
    if [[ -f $STATE/manager-update-pending.json ]]; then
        engine manager-update recover "$STATE" /root "$SHORTCUT"
        say '管理脚本中断恢复已完成，请重新运行 sbm。'
        exit 76
    fi
    if [[ $1 != audit ]]; then audit_record action-start started; fi
    case $1 in
        1) initialize;;
        2) list_action;;
        3) edit_nodes add;; 4) edit_nodes edit;; 5) edit_nodes toggle;;
        6) edit_nodes delete;; 7) edit_nodes rotate;;
        8) edit_nodes acme;; 9) export_action;;
        10) change_version;;
        11) dependencies; fetch_versions; engine catalog "$TMP/catalog.json" "$(current_version)";;
        12) diagnostics;;
        13) say 'Ctrl+C 返回菜单。日志可能包含访问地址；UDP 不能据此精确统计在线人数。'; journalctl -u sing-box -n 30 -f -o cat;;
        14) engine connections "$CONF";;
        15) service_action start;;
        17) service_action restart;;
        16) systemctl stop sing-box;;
        18) snapshot; say '快照含明文凭据和运行二进制，请私密保存。';;
        19) restore_action;; 20) edit_nodes loglevel;;
        21) uninstall_action;;
        22) draft_action;;
        23) reinitialize;;
        24) prune_action;;
        25) install_shortcut;;
        26|dash) engine dashboard "$CONF" "$STATE" "$(current_version)";;
        27) bbr_action;;
        28) protocol_action;;
        29|paths) paths_action "${2:-}";;
        30) manager_update_action;;
        self-update) manager_update_action "${2:-menu}" "${3:-}";;
        protocols) if [[ ${2:-} == --json ]]; then engine protocols --json; else engine protocols --text; fi;;
        compat) require_managed; prepare_model; engine compatibility "$TMP/model.json" "$(active_binary)" "${2:-}";;
        validate) require_managed; prepare_model; engine compile-checked "$TMP/model.json" "$(active_binary)" "$TMP/validate.json" "${2:-}";;
        module-test) engine module-test "$(active_binary)" "${2:-all}" "${3:-}";;
        runtime) engine runtime-info "$(active_binary)" "${2:-}";;
        audit) engine audit-verify "$STATE/audit.jsonl" "${2:-}";;
        draft-list) engine draft-summary "$STATE/draft.json";;
        draft-resume) resume_draft;;
        draft-discard) draft_discard_action;;
        draft-purge) draft_purge_action;;
        draft-archives-purge) draft_archives_purge_action;;
        profile-create) engine official create "$(active_binary)" "${2:-}";;
        profile-advanced) engine profile create "$(active_binary)";;
        official-discover) engine official list "$(active_binary)" "${2:-}";;
        profile-import) engine profile import "$2" "$(active_binary)";;
        profile-delete) engine profile delete "$2" "$CONF" "$STATE";;
        *) say '无效选择。';;
    esac
)
resolve_action() {
    case $1 in
        status) say 26;; versions) say 11;; list) say 2;; export) say 9;; check) say 12;;
        backup) say 18;; restart) say 17;; log) say 13;; prune) say 24;; shortcut) say 25;;
        upgrade) say 10;; start) say 15;; stop) say 16;;
        add) say 3;; edit) say 4;; toggle) say 5;; delete) say 6;; rotate) say 7;; acme) say 8;;
        protocols|compat|validate|module-test|runtime|audit|paths) say "$1";;
        *) return 1;;
    esac
}
main() {
    local resolved
    if [[ ${1:-} == self-update ]]; then
        case ${2:-menu} in
            local) (( $#<=3 )) || die '本地脚本升级参数过多。';;
            menu|github|rollback|configure) (( $#<=2 )) || die '脚本升级参数过多。';;
            *) die '脚本升级方式无效。';;
        esac
        require_host cli
        [[ ! -f $STATE/pending ]] || die '存在未完成配置事务；请先恢复。'
        action self-update "${2:-menu}" "${3:-}"
        return
    fi
    if [[ ${1:-} == protocol ]]; then
        case ${2:-menu} in
            menu) resolved=28;; create) resolved=profile-create;;
            discover) resolved=official-discover;; advanced) resolved=profile-advanced;;
            list) resolved=protocols;; test) resolved=module-test;;
            import) resolved=profile-import;; delete) resolved=profile-delete;;
            *) die '模块子命令无效。';;
        esac
        case $resolved in
            profile-import|profile-delete) (( $#==3 )) || die '请提供文件路径或模块标识。';;
            module-test) (( $#==2 || $#==3 )) || die '测试参数无效。';;
            profile-create) (( $#<=3 )) && [[ -z ${3:-} || ${3:-} =~ ^[a-z][a-z0-9_-]{0,40}$ ]] || die '协议标识无效。';;
            official-discover) (( $#<=3 )) && [[ -z ${3:-} || ${3:-} == --json ]] || die '仅支持 --json 选项。';;
            *) (( $#<=2 )) || die '模块操作参数过多。';;
        esac
        local argument=${3:-}
        [[ $resolved != module-test || -n $argument ]] || argument=all
        require_host cli
        [[ ! -f $STATE/pending ]] || die '存在未完成事务；请先恢复。'
        if [[ $resolved =~ ^(profile-import|profile-delete|module-test|official-discover)$ || ( $resolved == profile-create && -n $argument ) ]]; then action "$resolved" "$argument"; else action "$resolved"; fi
        return
    fi
    if [[ ${1:-} == draft ]]; then
        case ${2:-menu} in
            menu) resolved=22;;
            list) resolved=draft-list;;
            resume) resolved=draft-resume;;
            discard|clear) resolved=draft-discard;;
            purge|delete) resolved=draft-purge;;
            purge-archives) resolved=draft-archives-purge;;
            *) die '草稿子命令无效：可用 list / resume / discard / purge / purge-archives。';;
        esac
        (( $#<=2 )) || die '草稿命令不支持额外参数。'
        require_host cli
        [[ ! -f $STATE/pending ]] || die '存在未完成事务；请先打开菜单恢复，暂不清理草稿。'
        action "$resolved"
        return
    fi
    if [[ ${1:-} == node || ${1:-} == service ]]; then
        case "$1:${2:-}" in
            node:list|node:add|node:edit|node:toggle|node:delete|node:rotate|node:acme|service:status|service:start|service:stop|service:restart)
                resolved=$(resolve_action "$2"); shift 2;;
            *) usage >&2; die '节点 / 服务子命令无效。';;
        esac
        (( $#==0 )) || die '此操作不支持额外参数；节点输入和变更仍按交互确认执行。'
        require_host cli
        [[ ! -f $STATE/pending ]] || die '存在未完成事务；请先打开菜单恢复。'
        action "$resolved"
        return
    fi
    case ${1:-menu} in
        menu) ;;
        help|-h|--help) usage; return 0;;
        version|-v|--version) say "singbox-manager v$SBM_VERSION"; return 0;;
        status|versions|list|export|check|backup|restart|log|prune|shortcut|upgrade|protocols|compat|validate|module-test|runtime|audit|paths)
            resolved=$(resolve_action "$1")
            shift
            if [[ $resolved == module-test ]]; then
                (( $#<=2 )) || die '模块测试参数过多。'
                if [[ ${1:-} == --json ]]; then (( $#==1 )) || die '无效参数。'; set -- all --json; fi
                [[ -z ${1:-} || ${1:-} == all || ${1:-} =~ ^[a-z][a-z0-9_-]*$ ]] || die '模块标识无效。'
                [[ -z ${2:-} || ${2:-} == --json ]] || die '无效模块测试选项。'
            elif [[ $resolved =~ ^(protocols|compat|validate|runtime|audit|paths)$ ]]; then
                (( $#<=1 )) && [[ -z ${1:-} || ${1:-} == --json ]] || die '仅支持 --json 选项。'
            else (( $#==0 )) || die '此命令不支持额外参数。'; fi
            require_host cli
            [[ ! -f $STATE/pending ]] || die '存在未完成事务；请先不带参数运行脚本，在菜单中完成恢复。'
            action "$resolved" "$@"
            return;;
        *) usage >&2; die "未知命令：$1";;
    esac
    require_host
    # Recovery is deliberately before the menu; errors must not silently continue.
    recover_pending || die '未完成事务尚未恢复。'
    action dash || { local dash_rc=$?; (( dash_rc!=76 )) || return 0; }
    trap ':' INT
    local n rc
    while true; do
        say ''
        say "============= sing-box 多节点管理 v$SBM_VERSION ============="
        status_line
        cat <<'MENU'
---------------------- 节点 ----------------------
1  初始化 / 安装并添加节点
2  列出节点          3  继续添加节点
4  修改节点          5  单节点启用 / 停用
6  删除节点          7  重置节点凭据
8  修改共用证书      9  导出 / 查看客户端资料（含二维码）
---------------------- 版本 ----------------------
10 选择 / 升级运行版本（对比当前与官方最新）
11 检查是否有新版本  12 综合诊断 / CPU / 内存 / 证书
---------------------- 服务 ----------------------
13 实时日志          14 连接快照
15 启动服务          16 停止服务
17 重启服务          20 修改日志等级
---------------------- 维护 ----------------------
18 完整配置与运行版本备份
19 恢复备份 / 回退版本
21 卸载（保留数据）
22 草稿管理：继续 / 查看 / 归档 / 彻底删除
23 先备份，再重新初始化（处理未完成安装/外部配置）
24 清理旧备份 / 旧运行版本
25 安装快捷命令 sbm
26 服务器概况        27 开启 / 关闭 BBR
28 官方协议自动发现 / 参数表单 / 模块管理
29 文件目录：运行程序 / 配置 / 草稿 / 备份 / 日志
30 管理脚本升级：SSH 上传 / GitHub 拉取 / 回退
0  退出
MENU
        say '扩展命令：protocols / compat / validate / module-test / runtime / audit（菜单序号保持不变）'
        read -r -p '请选择: ' n || break
        [[ $n != 0 ]] || break
        action "$n"
        rc=$?
        if [[ $n == 30 || $rc == 76 ]]; then return 0; fi
        if (( rc!=0 && rc!=130 )); then say "操作未完成（退出码 ${rc}）；请查看上方原因。"; fi
    done
}
emit_engine() {
    base64 -d <<'SBM_BUNDLE'
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
SBM_BUNDLE
}
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
