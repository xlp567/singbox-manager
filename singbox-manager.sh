#!/usr/bin/env bash
# singbox-manager v3.5.8 - transactional core and independent protocol adapters
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
SBM_VERSION=3.5.8
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
bWUucHlQSwUGAAAAAB0AHQCZBwAAQfgAAAAA
SBM_BUNDLE
}
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
