#!/usr/bin/env bash
# singbox-manager v3.6.7 - transactional core and independent protocol adapters
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
SBM_VERSION=3.6.7
SHORTCUT=/usr/local/bin/sbm
# Used by service.sh bundled below; tests redirect them.
# shellcheck disable=SC2034
BBR_CONF=/etc/sysctl.d/90-singbox-manager-bbr.conf
# shellcheck disable=SC2034
CC_AVAILABLE=/proc/sys/net/ipv4/tcp_available_congestion_control
TMP=''; TX=''; CANDIDATE=''; ACTION_ID=manual
# Shared with transactions.sh bundled below.
# shellcheck disable=SC2034
POLICY=0
#!/usr/bin/env bash
# Stable management core: runtime. Bundled by tools/build.py.
# SagerNet APT signing key (Project S <contact@sagernet.org>). Cross-checked on
# 2026-10-20: identical key from sing-box.app and deb.sagernet.org, and the same
# full fingerprint in several independent public deployment projects.
SAGERNET_KEY_FPR=2C317FBD5D886B4E89BAE8DA6D9152172A2B2F0C
sagernet_key_check() {
    # Exactly one primary key whose full fingerprint equals the pinned value.
    local listing pubs fpr
    listing=$(gpg --batch --with-colons --show-keys "$1" 2>/dev/null) || return 1
    pubs=$(awk -F: '$1=="pub"' <<<"$listing" | wc -l)
    fpr=$(awk -F: '$1=="fpr" {print $10; exit}' <<<"$listing")
    (( pubs == 1 )) && [[ $fpr == "$SAGERNET_KEY_FPR" ]]
}
repo_setup() {
    curl --proto '=https' --tlsv1.2 -fsSL --retry 2 --max-time 45 https://sing-box.app/gpg.key -o "$TMP/sagernet.asc"
    sagernet_key_check "$TMP/sagernet.asc" || die "SagerNet APT 公钥指纹与固定值 ${SAGERNET_KEY_FPR} 不符（或包含多把主密钥），未写入 APT 源。若官方已更换密钥，请从官方渠道独立核实后升级管理器。"
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
            rc=1
            audit_record rollback failed "${TX##*/}" || true
            say "回滚未完成；保留恢复标记和备份 ${TX}，下次运行可恢复。" >&2
        fi
    fi
    if (( POLICY )) && grep -qx '# singbox-manager temporary policy' /usr/sbin/policy-rc.d 2>/dev/null; then rm -f /usr/sbin/policy-rc.d; fi
    if [[ $ACTION_ID != audit ]]; then
        if (( rc==78 || rc==130 )) || [[ ${MENU_CANCELLED:-0} == 1 && $rc == 0 ]]; then audit_record action-finish cancelled || true
        elif (( rc==0 )); then audit_record action-finish ok || say '警告：操作已完成，但审计日志未能写入。' >&2
        else audit_record action-finish failed || true; fi
    fi
    [[ -z $TMP ]] || rm -rf -- "$TMP"
    # Preserve successful audit/cleanup, then tell the main menu to skip its
    # result pause. CLI returns stay zero; an external error 77 stays an error.
    if (( rc==78 )) || [[ $rc == 0 && ${MENU_CANCELLED:-0} == 1 ]]; then
        if [[ ${MENU_ACTIVE:-0} == 1 ]]; then rc=77; else rc=0; fi
    elif (( rc==0 )) && [[ ${MENU_RELOAD:-0} == 1 && ${MENU_ACTIVE:-0} == 1 ]]; then
        rc=76
    elif (( rc==0 )) && [[ ${MENU_ACTIVE:-0} == 1 && ${MENU_RETURN_REQUESTED:-0} == 1 ]]; then
        rc=77
    elif (( rc==77 )); then
        rc=1
    fi
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
    if [[ -f /etc/apt/keyrings/sagernet.asc ]]; then
        if sagernet_key_check /etc/apt/keyrings/sagernet.asc; then say "APT 公钥：指纹与固定值一致（${SAGERNET_KEY_FPR}）"
        else say 'APT 公钥：指纹与固定值不符 ⚠ 请从官方渠道核实 /etc/apt/keyrings/sagernet.asc'; fi
    fi
    say 'sing-box 正在监听：'
    ss -Hlntup | awk '/"sing-box"/ {print "  " $1 " " $5}' || true
    engine logsummary
    if [[ -f $CONF/manager.json ]]; then
        say '本机 TLS 证书握手测试：'
        engine probe "$CONF/manager.json"
    fi
    say '提示：完整日志用菜单 13；本机检查不能替代外网客户端实测，UDP 节点需客户端实际连接。'
}
bbr_original_restore() {
    # Restores the runtime values recorded before this manager enabled BBR.
    local saved=$1 cc qdisc failed=0
    cc=$(sed -n 's/^tcp_congestion_control=\([a-z0-9_]\{1,32\}\)$/\1/p' "$saved")
    qdisc=$(sed -n 's/^default_qdisc=\([a-z0-9_]\{1,32\}\)$/\1/p' "$saved")
    [[ -n $cc && -n $qdisc ]] || return 1
    grep -qw -- "$cc" "$CC_AVAILABLE" || return 1
    sysctl -w "net.ipv4.tcp_congestion_control=$cc" >/dev/null || failed=1
    sysctl -w "net.core.default_qdisc=$qdisc" >/dev/null || failed=1
    (( failed == 0 )) || return 1
    [[ $(sysctl -n net.ipv4.tcp_congestion_control) == "$cc" && $(sysctl -n net.core.default_qdisc) == "$qdisc" ]]
}
bbr_action() {
    local f=$BBR_CONF saved=$STATE/bbr-original.conf cc qdisc
    [[ ! -L $saved && ! -L $f ]] || die 'BBR 配置或原设置记录为符号链接，请人工核查。'
    if [[ ! -f $f && -e $saved ]]; then
        [[ -f $saved ]] || die "BBR 原设置记录不是普通文件：$saved"
        confirm '发现上次未完成的 BBR 恢复；先重试恢复记录的两项原设置' || return 0
        if bbr_original_restore "$saved"; then
            rm -f "$saved"; say '原拥塞算法与队列设置已恢复并读回确认。'
        else die "未能完全恢复 BBR 原设置；记录保留在 $saved，可再次用菜单 27 重试，或人工核查。"; fi
        return 0
    fi
    cc=$(sysctl -n net.ipv4.tcp_congestion_control)
    if [[ -f $f ]]; then
        say "当前拥塞控制：${cc}（由本脚本开启）。"
        if [[ -f $saved && ! -L $saved ]]; then
            confirm '关闭本脚本开启的 BBR，恢复开启前的拥塞算法与队列规则' || return 0
        else
            confirm '关闭本脚本开启的 BBR（旧版开启时未记录原设置，将恢复为 cubic 并重新加载系统 sysctl 配置）' || return 0
        fi
        rm -f "$f"
        if [[ -f $saved && ! -L $saved ]]; then
            if bbr_original_restore "$saved"; then rm -f "$saved"
            else
                if sysctl -w net.ipv4.tcp_congestion_control=cubic >/dev/null; then
                    say '警告：原设置未完全恢复，已回退为 cubic。' >&2
                else say '警告：原设置恢复与 cubic 回退均未完成。' >&2; fi
                die "恢复记录保留在 $saved；菜单 27 将重试恢复，不会覆盖该记录。"
            fi
        else
            sysctl --system >/dev/null 2>&1 || true
            sysctl -w net.ipv4.tcp_congestion_control=cubic >/dev/null
        fi
        say "已关闭：当前 $(sysctl -n net.ipv4.tcp_congestion_control) / $(sysctl -n net.core.default_qdisc)"
        return 0
    fi
    if [[ $cc == bbr ]]; then say '系统已在使用 BBR（不是本脚本设置的），无需操作。'; return 0; fi
    qdisc=$(sysctl -n net.core.default_qdisc)
    say "当前拥塞控制：${cc}；队列规则：${qdisc}。"
    say 'BBR 可改善 TCP 节点（AnyTLS/Trojan/VLESS/Reality/VMess/Naive/Shadowsocks）在高延迟、丢包线路上的速度；Hysteria2/TUIC 自带拥塞控制，不受影响。'
    say '注意：这是整机 TCP 参数，会同时影响本机其他 TCP 服务；关闭时恢复当前记录的设置。'
    confirm "写入 $f 开启 BBR + fq（立即生效，重启后保持，可随时在此关闭）" || return 0
    grep -qw bbr "$CC_AVAILABLE" || modprobe tcp_bbr 2>/dev/null || true
    grep -qw bbr "$CC_AVAILABLE" || die '内核不支持 BBR（部分 OpenVZ/LXC 容器无法修改），未做改动。'
    [[ $cc =~ ^[a-z0-9_]{1,32}$ && $qdisc =~ ^[a-z0-9_]{1,32}$ ]] || die '无法识别当前拥塞控制设置，未做改动。'
    [[ ! -L $saved ]] || die "原设置记录为符号链接，请人工核查：$saved"
    printf '# Runtime values before singbox-manager enabled BBR\ntcp_congestion_control=%s\ndefault_qdisc=%s\n' "$cc" "$qdisc" >"$saved"
    chmod 600 "$saved"
    printf '# Managed by singbox-manager.sh\nnet.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr\n' >"$f"
    if ! sysctl -p "$f" >/dev/null; then
        rm -f "$f"
        if bbr_original_restore "$saved"; then
            rm -f "$saved"; die '系统拒绝修改该参数（可能是容器环境），已撤销并读回确认原设置。'
        else die "系统拒绝修改参数，且未能完全恢复原设置。恢复记录保留在 $saved；再次运行菜单 27 可重试。"; fi
    fi
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
        menu_read_choice choice '升级方式: ' '^[0-4]$' || return 0
        case $choice in 1) mode=local;; 2) mode=github;; 3) mode=rollback;; 4) mode=configure;; 0) menu_back; return 0;; *) die '升级方式无效。';; esac
    fi
    if [[ $mode == configure ]]; then engine manager-update configure "$STATE"; return; fi
    if [[ $mode == rollback ]]; then
        engine manager-update list "$STATE"
        read_field backup '选择要回退的脚本备份完整目录（空行或 /cancel 取消）: '
        [[ -n $backup ]] || cancel_action
        engine manager-update rollback-stage "$STATE" "$backup" /root "$SHORTCUT" "$TMP"
        operation=install-rollback
        say '提示：旧备份可能没有发布签名；回退可能丢失新版安全修复。仅使用本机已校验备份。'
    elif [[ $mode == local ]]; then
        if [[ -z $path ]]; then read_field path '已上传的新版脚本路径 [/root/singbox-manager.sh]（/cancel 取消）: '; fi
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
    say '请重新运行 sbm 使用新版。'
    # Consumed by cleanup only after a successful installation.
    # shellcheck disable=SC2034
    MENU_RELOAD=1
}

say() { printf '%s\n' "$*"; }
die() { say "错误：$*" >&2; exit 1; }
menu_clear() {
    # Clear the visible page only; keep terminal scrollback for earlier output.
    if [[ -t 1 && -n ${TERM:-} && ${TERM:-} != dumb ]]; then
        printf '\033[2J\033[H'
    fi
}
cancel_action() {
    say '已取消，未提交本次变更。'
    exit 78
}
read_field() {
    local destination=$1 prompt=$2 field_value
    read -r -p "$prompt" field_value || cancel_action
    [[ ! $field_value =~ ^[[:space:]]*/cancel[[:space:]]*$ ]] || cancel_action
    printf -v "$destination" '%s' "$field_value"
}
menu_wait_return() {
    local return_answer result=0
    # Handle interruption in the reading shell, including a prior main-menu INT.
    trap 'trap "MENU_INTERRUPTED=1" INT; return 0' INT
    say ''
    say '0  返回主菜单'
    while true; do
        if ! read -r -p '请输入 0 返回: ' return_answer; then result=1; break; fi
        [[ $return_answer != 0 && $return_answer != /cancel ]] || break
        say '当前为结果页，请输入 0 返回主菜单。'
    done
    trap 'MENU_INTERRUPTED=1' INT
    return "$result"
}
menu_read_choice() {
    local destination=$1 prompt=$2 pattern=$3 default=${4:-} answer
    while true; do
        read_field answer "$prompt"
        answer=${answer:-$default}
        if [[ $answer =~ $pattern ]]; then
            printf -v "$destination" '%s' "$answer"
            return 0
        fi
        say '无效选择，请重新输入。'
    done
}
menu_back() {
    # Navigation is a successful action, not an operation result to pause on.
    MENU_RETURN_REQUESTED=1
}
confirm() {
    local answer
    while true; do
        if ! read -r -p "$*（输入 yes 确认 / no 取消，不区分大小写）: " answer; then
            MENU_CANCELLED=1; say '输入结束，已取消。'; return 1
        fi
        case $answer in
            [Yy]|[Yy][Ee][Ss]) return 0;;
            ''|/cancel|[Nn]|[Nn][Oo]) MENU_CANCELLED=1; say '已取消，未提交本次变更。'; return 1;;
            *) say '无法识别，请输入 yes 或 no。';;
        esac
    done
}
engine() { SBM_PROTOCOL_DIR="$STATE/protocols" SBM_STATE="$STATE" python3 "$TMP/engine.pyz" "$@"; }
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
    local mode=${1:-menu} choice kind='' operation='' address='' port='' domain='' default_ip='' default_port='' changed
    require_managed
    if [[ $mode == menu ]]; then
        engine security-status "$CONF/manager.json" "$CONF/config.json"
        say '1  应用 / 刷新保护（保留管理例外）'
        say '2  允许通过节点 SSH 管理本机    3  允许访问本机 3X-UI 面板'
        say '4  撤销 SSH 例外               5  撤销 3X-UI 面板例外'
        say '6  撤销全部管理例外'
        say '0  返回'
        menu_read_choice choice '选择: ' '^[0-6]$' || return 0
        case $choice in
            1) mode=apply;;
            2|3)
                kind=ssh; [[ $choice != 3 ]] || kind=panel
                operation=allow;mode=management
                read -r _ _ default_ip default_port _ <<<"${SSH_CONNECTION:-}"
                [[ $kind == ssh ]] || default_port=''
                read_field address "本机网卡公网 IP${default_ip:+ [$default_ip]}（/cancel 取消）: "
                address=${address:-$default_ip}; [[ -n $address ]] || cancel_action
                read_field port "服务 TCP 端口${default_port:+ [$default_port]}（/cancel 取消）: "
                port=${port:-$default_port}; [[ -n $port ]] || cancel_action
                if [[ $kind == panel ]]; then
                    read_field domain '面板完整域名（HTTPS 可填写；直接用 IP 则留空；/cancel 取消）: '
                fi
                ;;
            4|5|6)
                case $choice in 4) kind=ssh;; 5) kind=panel;; 6) kind=all;; esac
                operation=revoke;mode=management;;
            0) menu_back; return 0;;
        esac
    fi
    if [[ $mode == status ]]; then engine security-status "$CONF/manager.json" "$CONF/config.json" "${2:-}";return;fi
    if [[ $mode == public-ip ]]; then
        case ${2:-show} in
            show) engine public-ip "$STATE" show;;
            add|remove) [[ -n ${3:-} ]] || die '请提供公网 IP。'
                local verb=加入; [[ $2 == add ]] || verb=移出
                confirm "将 ${3} ${verb}已确认公网地址（只用于节点地址核对，不改节点、不重启服务）" || return 0
                engine public-ip "$STATE" "$2" "$3";;
            clear) confirm '清空已确认公网地址' || return 0; engine public-ip "$STATE" clear;;
            *) die '公网地址操作无效（show / add / remove / clear）。';;
        esac
        return
    fi
    if [[ $mode == ssh || $mode == panel || $mode == all ]]; then
        kind=$mode;operation=${2:-};address=${3:-};port=${4:-};domain=${5:-};mode=management
    fi
    [[ $mode == apply || $mode == management ]] || die '出口安全操作无效。'
    [[ ! -e $STATE/draft.json && ! -L $STATE/draft.json ]] || die '有未提交草稿；请先用菜单 22 继续、归档或清理，再应用安全策略。'
    prepare_model
    if [[ $mode == management ]]; then
        changed=$(engine security-management "$TMP/model.json" "$kind" "$operation" "$address" "$port" "$domain") || return 1
        if [[ $changed == unchanged ]]; then say '管理例外没有变化。';return 0;fi
        say '本次修改只应用于 sing-box 出口；生效前会备份并确认，sing-box 将短暂重启。'
        if [[ $operation == allow ]]; then
            say "将放行本机 $address TCP/$port${domain:+（仅额外匹配域名 $domain）}。所有使用这些节点的客户端都能连接此端口，仍须通过服务自身登录验证。"
        else say '将撤销所选管理例外，恢复对这些本机端口的拦截。';fi
    else say '刷新本机、内网、链路本地和元数据地址保护；现有管理例外及节点凭据保持不变。';fi
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
    engine security-management-check "$TMP/model.json"
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
    read_field more '提交前先往草稿里补加节点吗？y/N（/cancel 取消）: '
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
    menu_read_choice choice '草稿操作 [1]: ' '^[0-5]$' 1 || return 0
    case ${choice:-1} in
        1) resume_draft;;
        2) engine draft-summary "$STATE/draft.json";;
        3) draft_discard_action;;
        4) draft_purge_action;;
        5) draft_archives_purge_action;;
        0) menu_back; return 0;;
        *) die '草稿操作序号无效。';;
    esac
}
permanent_delete_confirm() {
    local answer
    read_field answer '此操作无法从草稿归档恢复；输入 DELETE 永久删除，其他输入取消: '
    [[ $answer == DELETE ]] || { MENU_CANCELLED=1; say '已取消永久删除。'; return 1; }
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
    menu_read_choice choice '模块操作: ' '^[0-6]$' || return 0
    case $choice in
        1) engine official create "$(active_binary)";;
        2) read_field path '协议模板 JSON 路径（空行或 /cancel 取消）: '; [[ -n $path ]] || cancel_action; engine profile import "$path" "$(active_binary)";;
        3) read_field kind '模块标识（all 检查全部；空行或 /cancel 取消）: '; [[ -n $kind ]] || cancel_action; engine module-test "$(active_binary)" "$kind";;
        4) read_field kind '待移除模块标识（空行或 /cancel 取消）: '; [[ -n $kind ]] || cancel_action; engine profile delete "$kind" "$CONF" "$STATE";;
        5) engine profile create "$(active_binary)";;
        6) engine official list "$(active_binary)";;
        0) menu_back; return 0;;
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
    say '0  返回（空行或 /cancel 也取消）'
    while true; do
        read_field n '恢复序号: '
        [[ -n $n && $n != 0 ]] || cancel_action
        if [[ $n =~ ^[1-9][0-9]{0,5}$ ]] && (( n<=${#dirs[@]} )); then break; fi
        say '无效序号，请重新输入。'
    done
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
    while true; do
        read_field keep '保留最近几份备份 [5]（0 或 /cancel 返回）: '
        keep=${keep:-5}
        [[ $keep != 0 ]] || cancel_action
        [[ $keep =~ ^[1-9][0-9]{0,2}$ ]] && break
        say '保留份数需为 1–999，请重新输入。'
    done
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
              ssh allow <公网IP> <端口> / ssh revoke
              panel allow <公网IP> <端口> [完整域名] / panel revoke / all revoke
              public-ip show|add|remove|clear：确认 NAT / 浮动 IP 的本机公网地址
  version     显示脚本版本
  help        显示本帮助
USAGE
}
action() (
    set -Eeuo pipefail
    # Consumed by cleanup() in the bundled transactions.sh module.
    # shellcheck disable=SC2034
    MENU_RETURN_REQUESTED=0 MENU_CANCELLED=0 MENU_RELOAD=0
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
        audit-repair) confirm '保留损坏审计原件，开新链并记录旧链最后有效哈希（不改服务）' || return 0; engine audit-repair "$STATE/audit.jsonl";;
        security) shift; security_action "$@";;
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
    local resolved MENU_ACTIVE=0 MENU_INTERRUPTED=0
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
            ssh|panel|all)
                case ${3:-} in
                    allow)
                        if [[ $2 == ssh ]]; then (( $#==5 )) || die '用法：sbm security ssh allow <公网IP> <端口>'
                        elif [[ $2 == panel ]]; then (( $#==5 || $#==6 )) || die '用法：sbm security panel allow <公网IP> <端口> [完整域名]'
                        else die 'all 仅支持 revoke。';fi;;
                    revoke) (( $#==3 )) || die '撤销操作不接受额外参数。';;
                    *) die '管理例外仅支持 allow / revoke。';;
                esac;;
            public-ip)
                case ${3:-show} in
                    show|clear) (( $#<=3 )) || die '参数过多。';;
                    add|remove) (( $#==4 )) || die '用法：sbm security public-ip add|remove <公网IP>';;
                    *) die '公网地址操作无效（show / add / remove / clear）。';;
                esac;;
            *) die '出口安全操作无效。';;
        esac
        require_host cli
        [[ ! -f $STATE/pending ]] || die '请先恢复未完成事务。'
        action security "${@:2}"
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
    # Consumed by cleanup() in the bundled transactions.sh module.
    # shellcheck disable=SC2034
    MENU_ACTIVE=1
    trap 'MENU_INTERRUPTED=1' INT
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
        say '返回：选择页输入 0；表单输入 /cancel 或 Ctrl+C 取消；空行保留提示中的默认值。'
        while true; do
            MENU_INTERRUPTED=0
            if ! read -r -p '请选择: ' n; then
                [[ $MENU_INTERRUPTED == 1 ]] && continue
                return 0
            fi
            [[ $n =~ ^([0-9]|[12][0-9]|3[01])$ ]] && break
            say '无效选择，请输入 0–31。'
        done
        [[ $n != 0 ]] || break
        menu_clear
        action "$n"
        rc=$?
        # cleanup emits 77 only for an explicit, successful submenu return.
        if (( rc==77 )); then menu_clear; continue; fi
        if (( rc==76 )); then return 0; fi
        if (( rc!=0 && rc!=130 )); then say "操作未完成（退出码 ${rc}）；请查看上方原因。"; fi
        # Ctrl+C already explicitly requests a return (notably for live logs).
        if (( rc!=130 )); then menu_wait_return || return 0; fi
        menu_clear
    done
}
emit_engine() {
    base64 -d <<'SBM_BUNDLE'
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
AAAA
SBM_BUNDLE
}
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
