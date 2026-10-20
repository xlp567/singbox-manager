#!/usr/bin/env bash
# singbox-manager v3.5.9 - transactional core and independent protocol adapters
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
SBM_VERSION=3.5.9
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
        # systemctl stop keeps a crashed unit in failed; with no main PID it is stopped.
        [[ ($observed_state == inactive || $observed_state == failed) && $pid == 0 ]] || return 1
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
    [[ $mode == rollback ]] || engine manager-update check-version "$(engine get "$TMP/update-info.json" version)" "$SBM_VERSION"
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
ZS5weVBLBQYAAAAAHQAdAJkHAABd+QAAAAA=
SBM_BUNDLE
}
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
