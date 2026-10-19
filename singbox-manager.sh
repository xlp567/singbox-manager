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
AACAAVHFAABzYm0vcHJvdG9jb2xzL2RlY2xhcmF0aXZlLnB5UEsBAhQDFAAAAAgAAAAhXKb35M7M
AgAA6gYAABoAAAAAAAAAAAAAAIAB6NUAAHNibS9wcm90b2NvbHMvaHlzdGVyaWEyLnB5UEsBAhQD
FAAAAAgAAAAhXN6Up2pFAgAAJQQAABYAAAAAAAAAAAAAAIAB7NgAAHNibS9wcm90b2NvbHMvbmFp
dmUucHlQSwECFAMUAAAACAAAACFcnFWuvZEFAAAQDwAAGAAAAAAAAAAAAAAAgAFl2wAAc2JtL3By
b3RvY29scy9yZWFsaXR5LnB5UEsBAhQDFAAAAAgAAAAhXCJcV+8OAwAAQwcAABwAAAAAAAAAAAAA
AIABLOEAAHNibS9wcm90b2NvbHMvc2hhZG93c29ja3MucHlQSwECFAMUAAAACAAAACFcghrSYIIA
AACpAAAAFwAAAAAAAAAAAAAAgAF05AAAc2JtL3Byb3RvY29scy90cm9qYW4ucHlQSwECFAMUAAAA
CAAAACFc9AhgJnACAACfBQAAFQAAAAAAAAAAAAAAgAEr5QAAc2JtL3Byb3RvY29scy90dWljLnB5
UEsBAhQDFAAAAAgAAAAhXEkysaTlAAAAXAEAABYAAAAAAAAAAAAAAIABzucAAHNibS9wcm90b2Nv
bHMvdmxlc3MucHlQSwECFAMUAAAACAAAACFcnABCb14CAABvBQAAFgAAAAAAAAAAAAAAgAHn6AAA
c2JtL3Byb3RvY29scy92bWVzcy5weVBLAQIUAxQAAAAIAAAAIVxGBQqmHgUAAFQKAAAOAAAAAAAA
AAAAAACAAXnrAABzYm0vcnVudGltZS5weVBLBQYAAAAAHQAdAJkHAADD8AAAAAA=
SBM_BUNDLE
}
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
