#!/usr/bin/env bash
# singbox-manager v3.5.7 - transactional core and independent protocol adapters
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
SBM_VERSION=3.5.7
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
HQCZBwAA2/QAAAAA
SBM_BUNDLE
}
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
