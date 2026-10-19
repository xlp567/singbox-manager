#!/usr/bin/env bash
# singbox-manager v3.5.4 — Debian / Ubuntu, Bash >=4, systemd
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
SBM_VERSION=3.5.4
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
SBM_BUNDLE
}
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
