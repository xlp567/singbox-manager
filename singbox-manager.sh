#!/usr/bin/env bash
# singbox-manager v3.5.6 - transactional core and independent protocol adapters
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
SBM_VERSION=3.5.6
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
    fetch_versions full
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
    engine snapshot-space "$BACKUPS" "$STATE/runtime-objects" "$CONF" "$EXPORTS" "$(active_binary || true)"
}
snapshot() {
    disk_guard
    local dest binary kind=${1:-manual}
    dest=$(mktemp -d "$BACKUPS/$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")
    [[ ! -d $CONF ]] || cp -a "$CONF" "$dest/config-dir"
    [[ ! -f $DROP ]] || cp -a "$DROP" "$dest/manager-override"
    [[ ! -d $EXPORTS ]] || cp -a "$EXPORTS" "$dest/exports"
    [[ ! -d $STATE/protocols ]] || cp -a "$STATE/protocols" "$dest/protocols"
    [[ ! -f $STATE/client-info.txt ]] || cp -a "$STATE/client-info.txt" "$dest/legacy-info"
    if binary=$(active_binary); then
        engine runtime-backup "$binary" "$dest" "$STATE/runtime-objects"
        "$binary" version >"$dest/version.txt"
    fi
    systemctl is-active --quiet sing-box && touch "$dest/was-active"
    systemctl is-enabled --quiet sing-box 2>/dev/null && touch "$dest/was-enabled"
    engine snapshot-kind "$dest" "$kind"
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
    snapshot automatic
    audit_record transaction-begin started "${SNAP##*/}"
    engine pending-write "$STATE/pending" "$SNAP"
    TX=$SNAP
}
commit_transaction() {
    local snapshot_id=${TX##*/}
    engine pending-clear "$STATE/pending"
    TX=''
    audit_record transaction-commit ok "$snapshot_id" || say '警告：变更已提交，但审计日志未能写入。' >&2
    engine prune-automatic "$BACKUPS" "$STATE/runtime-objects" "$STATE/pending" || say '警告：变更已提交，但自动备份清理未完成。可用菜单 24 清理。' >&2
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
service_stopped() {
    local observed_state pid
    for _ in 1 2 3 4 5; do
        sleep 2
        observed_state=$(systemctl show sing-box -p ActiveState --value) || return 1
        pid=$(systemctl show sing-box -p MainPID --value) || return 1
        [[ $observed_state == inactive && $pid == 0 ]] || return 1
    done
}
service_action() {
    local command=$1 binary
    case $command in start|stop|restart) ;; *) die '未知服务操作。';; esac
    managed_unit_check
    # A broken configuration or missing runtime must not prevent a safe stop.
    if [[ $command != stop ]]; then
        binary=$(active_binary) || die '尚未安装。'
        if [[ -f $CONF/manager.json ]]; then engine compatibility "$CONF/manager.json" "$binary"; fi
        "$binary" check -c "$CONF/config.json"
    fi
    begin_transaction
    systemctl "$command" sing-box || die '服务操作失败，自动恢复之前状态。'
    if [[ $command == stop ]]; then
        service_stopped || die '服务未稳定停止，自动恢复之前状态。'
    else
        health || die '服务未稳定运行，自动恢复之前状态。'
    fi
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
    local mode=${1:-menu} path=${2:-} checksum choice backup operation=install
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
        operation=install-rollback
        say '提示：旧备份可能没有发布签名；回退可能丢失新版安全修复。仅使用本机已校验备份。'
    elif [[ $mode == local ]]; then
        if [[ -z $path ]]; then read -r -p '已上传的新版脚本路径 [/root/singbox-manager.sh]: ' path || return 0; fi
        path=${path:-/root/singbox-manager.sh}
        [[ ${path%/*} == /root && $path == *.sh && ! -L $path ]] || die '请将新版 .sh 普通文件通过 SSH/SCP 上传到 /root。'
        checksum=${path%.sh}.sha256
        [[ -f $path && -f $checksum && ! -L $checksum ]] || die "请同时上传脚本与校验文件：$path 和 $checksum"
        cp -- "$path" "$TMP/singbox-manager.sh"
        cp -- "$checksum" "$TMP/singbox-manager.sha256"
        local manifest=${path%.sh}.SHA256SUMS
        [[ -f $manifest && -f $manifest.sig && ! -L $manifest && ! -L $manifest.sig ]] || die '请同时上传对应的 .SHA256SUMS 和 .SHA256SUMS.sig 签名清单。'
        cp -- "$manifest" "$TMP/SHA256SUMS"
        cp -- "$manifest.sig" "$TMP/SHA256SUMS.sig"
    elif [[ $mode == github ]]; then
        engine manager-update fetch "$STATE" "$TMP" "$SBM_VERSION" >"$TMP/update-origin.json"
        say 'GitHub 正式 Release、源与固定提交：'
        engine get "$TMP/update-origin.json" tag
        engine get "$TMP/update-origin.json" repository
        engine get "$TMP/update-origin.json" commit
    else die '脚本升级方式无效。'; fi
    [[ $mode == rollback ]] || engine manager-update verify-release "$TMP"
    engine manager-update verify "$TMP/singbox-manager.sh" "$TMP/singbox-manager.sha256" >"$TMP/update-info.json"
    say "目标管理脚本版本：$(engine get "$TMP/update-info.json" version)"
    say "SHA-256：$(engine get "$TMP/update-info.json" sha256)"
    say '安装位置：/root/singbox-manager.sh、/usr/local/bin/sbm'
    confirm '备份当前管理脚本并安装以上版本' || return 0
    engine manager-update "$operation" "$TMP/singbox-manager.sh" "$TMP/singbox-manager.sha256" "$STATE" /root "$SHORTCUT"
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
        engine audit-append "$STATE/audit.jsonl" "$1" "$ACTION_ID" "$2" "${3:-}" || {
            say '警告：审计记录未写入；操作继续，原审计文件保留。可用 sbm audit 检查、sbm audit repair 隔离修复。' >&2
        }
    fi
    return 0
}
setup_tmp() {
    TMP=$(mktemp -d "$STATE/tmp.XXXXXX")
    emit_engine >"$TMP/engine.pyz"
}
security_action() {
    local mode=${1:-menu} choice
    require_managed
    if [[ $mode == menu ]]; then
        engine security-status "$CONF/manager.json" "$CONF/config.json"
        say '1  应用 / 刷新出口安全策略（先备份，sing-box 会短暂重启）'
        say '0  返回'
        read -r -p '选择: ' choice || return 0
        [[ $choice == 1 ]] || return 0
        mode=apply
    fi
    if [[ $mode == status ]]; then engine security-status "$CONF/manager.json" "$CONF/config.json" "${2:-}";return;fi
    [[ $mode == apply ]] || die '出口安全操作无效。'
    [[ ! -e $STATE/draft.json && ! -L $STATE/draft.json ]] || die '有未提交草稿；请先用菜单 22 继续、归档或清理，再应用安全策略。'
    say '将禁止代理访问本机、内网、链路本地和元数据地址；节点凭据保持不变。'
    prepare_model
    apply_draft "$(active_binary)"
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
    for c in python3 curl gpg openssl ss dig ssh-keygen; do command -v "$c" >/dev/null || missing=1; done
    if (( missing )); then
        say '安装必要的系统依赖……'
        apt-get update
        apt-get install -y python3 curl ca-certificates gnupg openssl iproute2 dnsutils util-linux openssh-client
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
    engine runtime-gc "$STATE/runtime-objects"
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
  audit       校验本地审计链，可加 --json；repair 确认后隔离损坏文件并开新链
  security    出口安全：status [--json] / apply（备份后应用，重启 sing-box）
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
        16) service_action stop;;
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
        31) security_action;;
        audit-repair) confirm '保留损坏审计原件，开新链并记录旧链最后有效哈希（不改服务）' && engine audit-repair "$STATE/audit.jsonl";;
        security) security_action "${2:-menu}" "${3:-}";;
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
    if [[ ${1:-} == audit && ${2:-} == repair ]]; then
        (( $#==2 )) || die '审计修复不支持额外参数。'
        require_host cli
        action audit-repair
        return
    fi
    if [[ ${1:-} == security ]]; then
        case ${2:-menu} in
            menu|apply) (( $#<=2 )) || die '出口安全参数过多。';;
            status) (( $#<=3 )) || die '参数过多。'; [[ -z ${3:-} || ${3:-} == --json ]] || die '仅支持 --json。';;
            *) die '出口安全操作无效。';;
        esac
        require_host cli
        [[ ! -f $STATE/pending ]] || die '请先恢复未完成事务。'
        action security "${2:-menu}" "${3:-}"
        return
    fi
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
            profile-create) (( $#<=3 )) || die '参数过多。'; [[ -z ${3:-} || ${3:-} =~ ^[a-z][a-z0-9_-]{0,40}$ ]] || die '协议标识无效。';;
            official-discover) (( $#<=3 )) || die '参数过多。'; [[ -z ${3:-} || ${3:-} == --json ]] || die '仅支持 --json 选项。';;
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
                (( $#<=1 )) || die '参数过多。'; [[ -z ${1:-} || ${1:-} == --json ]] || die '仅支持 --json 选项。'
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
31 出口安全：状态 / 阻止本机与内网 / 刷新地址
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
