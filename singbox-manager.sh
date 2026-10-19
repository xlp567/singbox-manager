#!/usr/bin/env bash
# singbox-manager v3.5.2 — Debian / Ubuntu, Bash >=4, systemd
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
SBM_VERSION=3.5.2
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
