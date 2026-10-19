#!/usr/bin/env bash
# singbox-manager v3.5.3 — Debian / Ubuntu, Bash >=4, systemd
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
SBM_VERSION=3.5.3
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
    rm -f -- "$TMP/catalog.json" "$TMP/selected.json"
    if ! engine fetch-releases "$TMP/releases.json" "$TMP/release-query.json" "${1:-full}"; then
        engine release-query-status "$STATE" failed || true
        say '本次查询未成功，无法判断是否有新版本；当前运行程序、配置和服务保持原状。' >&2
        return 1
    fi
    if ! engine releases "$TMP/releases.json" "$TMP/catalog.json" "$arch" "$TMP/release-query.json"; then
        engine release-query-status "$STATE" failed || true
        return 1
    fi
    # Cached only for the dashboard hint; selecting a version always uses this fresh query.
    engine release-query-status "$STATE" success "$TMP/catalog.json" || true
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
        11) dependencies; fetch_versions summary; engine catalog "$TMP/catalog.json" "$(current_version)";;
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
AAAAAAAAAIABqqMAAHNibS9wcm90b2NvbHMvYmFzZS5weVBLAQIUAxQAAAAIAAAAIVwKqZasXRAA
ANwxAAAcAAAAAAAAAAAAAACAAaipAABzYm0vcHJvdG9jb2xzL2RlY2xhcmF0aXZlLnB5UEsBAhQD
FAAAAAgAAAAhXKb35M7MAgAA6gYAABoAAAAAAAAAAAAAAIABP7oAAHNibS9wcm90b2NvbHMvaHlz
dGVyaWEyLnB5UEsBAhQDFAAAAAgAAAAhXN6Up2pFAgAAJQQAABYAAAAAAAAAAAAAAIABQ70AAHNi
bS9wcm90b2NvbHMvbmFpdmUucHlQSwECFAMUAAAACAAAACFcnFWuvZEFAAAQDwAAGAAAAAAAAAAA
AAAAgAG8vwAAc2JtL3Byb3RvY29scy9yZWFsaXR5LnB5UEsBAhQDFAAAAAgAAAAhXCJcV+8OAwAA
QwcAABwAAAAAAAAAAAAAAIABg8UAAHNibS9wcm90b2NvbHMvc2hhZG93c29ja3MucHlQSwECFAMU
AAAACAAAACFcghrSYIIAAACpAAAAFwAAAAAAAAAAAAAAgAHLyAAAc2JtL3Byb3RvY29scy90cm9q
YW4ucHlQSwECFAMUAAAACAAAACFc9AhgJnACAACfBQAAFQAAAAAAAAAAAAAAgAGCyQAAc2JtL3By
b3RvY29scy90dWljLnB5UEsBAhQDFAAAAAgAAAAhXEkysaTlAAAAXAEAABYAAAAAAAAAAAAAAIAB
JcwAAHNibS9wcm90b2NvbHMvdmxlc3MucHlQSwECFAMUAAAACAAAACFcnABCb14CAABvBQAAFgAA
AAAAAAAAAAAAgAE+zQAAc2JtL3Byb3RvY29scy92bWVzcy5weVBLAQIUAxQAAAAIAAAAIVxGBQqm
HgUAAFQKAAAOAAAAAAAAAAAAAACAAdDPAABzYm0vcnVudGltZS5weVBLBQYAAAAAGwAbAAoHAAAa
1QAAAAA=
SBM_BUNDLE
}
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
