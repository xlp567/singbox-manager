#!/usr/bin/env bash
# singbox-manager v3.6.8 - transactional core and independent protocol adapters
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
SBM_VERSION=3.6.8
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
        say '5  检查管理器更新（仅检查）'
        say '0  返回'
        menu_read_choice choice '升级方式: ' '^[0-5]$' || return 0
        case $choice in 1) mode=local;; 2) mode=github;; 3) mode=rollback;; 4) mode=configure;; 5) mode=check;; 0) menu_back; return 0;; *) die '升级方式无效。';; esac
    fi
    if [[ $mode == check ]]; then engine manager-update check "$STATE" "$TMP" "$SBM_VERSION" /root "$SHORTCUT"; return; fi
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
verify_snapshots() {
    local dir count=0 failed=0
    for dir in "$BACKUPS"/*; do
        [[ -d $dir && ! -L $dir && -f $dir/.complete ]] || continue
        count=$((count+1))
        if [[ -L $dir/.complete || -L $dir/manifest.json ]]; then
            say "${dir##*/}：备份标记或清单异常"; failed=1
        elif [[ ! -e $dir/manifest.json && ! -s $dir/.complete ]]; then
            say "${dir##*/}：旧格式无摘要，无法验证完整性"
        elif [[ -f $dir/manifest.json ]] && engine backup-verify "$dir"; then
            say "${dir##*/}：文件清单与摘要一致"
        else
            say "${dir##*/}：校验失败"; failed=1
        fi
    done
    (( count > 0 )) || say '没有已完成的快照。'
    return "$failed"
}
restore_action() {
    local dirs=() d n chosen checker
    for d in "$BACKUPS"/*; do [[ ! -f $d/.complete || ! -f $d/config-dir/config.json ]] || dirs+=("$d"); done
    say 'v  仅校验备份（检查全部已完成快照）' 
    for n in "${!dirs[@]}"; do say "$((n+1))) ${dirs[n]##*/}"; done
    say '0  返回（空行或 /cancel 也取消）'
    while true; do
        read_field n '恢复序号（v 仅校验）: '
        if [[ $n == v || $n == V ]]; then verify_snapshots; return; fi
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
    engine manager-update shortcut "$STATE" "$TMP" "$SBM_VERSION" /root "$SHORTCUT"
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
  self-update 管理脚本升级菜单；local [/root/脚本.sh] / github / check / rollback / configure
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
            menu|github|rollback|configure|check) (( $#<=2 )) || die '脚本升级参数过多。';;
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
19 恢复备份 / 回退版本 / 仅校验备份
21 卸载（保留数据）
22 草稿管理：继续 / 查看 / 归档 / 彻底删除
23 先备份，再重新初始化（处理未完成安装/外部配置）
24 清理旧备份 / 旧运行版本
25 校验 / 修复快捷命令 sbm
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
UEsDBBQAAAAIAAAAIVznxWTxJQAAACUAAAALAAAAX19tYWluX18ucHlLK8rPVShOytVLzSspqizI
z8wrUcjMLcgvKlEoKs3jAmINTS4AUEsDBBQAAAAIAAAAIVyKX4y3MwAAADEAAAAPAAAAc2JtL19f
aW5pdF9fLnB5U1JSKs7MS0/Kr9DNTcxLTE8tUigz1jNQSM7PS8tMLy1KLMnMz1NIzUvPzEvVU1JS
4gIAUEsDBBQAAAAIAAAAIVzgjF5lwwUAADAPAAAVAAAAc2JtL2FkYXB0ZXJfZW5naW5lLnB5lVdb
ixxFFH6fX1HsS3WT3lYC+jBri8tmleCSXbLBl2EYarprdivbN6uqd3fYLHgl8RJQRAWTCMELEjQa
UNC4mj/jTOYtf8FTl+7pnktI+mG6uqrOV+fynXNqVlZWtsiQcnTeR9spRTnPZBZmMcpZTmMGM2Kf
cBqh/hAlNC08tLF1EZE0QtlgoNeTLCpiisJ9Gh4If2VlpcWSPOMS5UTux6xffkqa5AMW09aAZwny
y4MEsuvrF9Z3rmxe3vXQHpV2U5glOYjwcs9Glg7YXsGJZFm6YRftXl6kkiW03HrZfHrokHIBu3sH
dNhqtcKYCIF27OGb6R6Y0G4heCI6QL0eS5ns9RxB44Fr5tWjPitlgoVaaBGfRCSXlLutCtLO6GXv
gKWR2+ZUFjxVZjp6Yro5JJLE2d7s8VagE7HQiATEVy8vJn0aw4d+eyRnMIbfnrXZM7EpP2GxOeFV
JzSeBJyQFEnPelSJNWe8lMqjjB+IIGZCOsQvv11PxgL2w+8SbEE5HN6TZK8Srk25nsgKHqojzcBF
g4wjglha8cM/JHFBheN2p36DKRYRSXtpFlHjajXyQnnstuuBcdR0Byvn4a7rl3JOtbsWCxNYgwZ+
AweX2+dD0yBIOXBmpKbYWSH7WZFGU1UrVjxF20pKC1RgBWfPh6MEDETDWKBzn8VMDusm91lK+HCR
5ZXv9EZ3DZV0sZnnGFG1kB2JoNOtJFVIUxVSLdnBSheBu+0GY0jQtKBSfw0xIYAAdUT1sEE91R2r
jW/n3Ffqi3OMdttzdDWnQDrlFFyOxz/dHd95NPnx3fGD95Bg6d5qPztGrwYIn5tHa4Bx+nbBoISC
QbN0v+ac4CMm93skTCg+VTbo5EE0FlB5Yb/bxEpAKzg7KDFXSzMV3Kw77Ob2jCWPzx6Ofvt8/O0H
o78fTt7/Z/TxrSdn3+Bz2EPYv5qx1BFQP2nkWHF3RgUVzRLrBLMItyE28Op6uKzpuG3rE6Yp6cfU
7CnH3SWlQT14xpMKabb44JKsMSynmbSR8rB5Y2vvqTubpCe4Qi3dxtJB5rhNSBLHDu/Up7qaslxR
VlmvfMtr9rjzBllOt9V2D4swywEYm9Cvqk4YQ+asIRLKgsRTOukmCuomhKWiIg4+nSaqLeCSCilM
ntoMheKl20uAQX9c47PNIFtu56qoq6zRgkbSUK/TSD7dpabZ9syJrqhd9X3/ClWdGXZeAKNCmfGh
k3M6YMcBFv1k1Vi2ql2wil1EBJJRMy3zwN4p/B14OzJqMrNqFaXJ80kNGgYnC3ja7IuadY2Z0zkk
yYfz8OrRRS2AcEBXPOrpL8ddvrODde53Qa0oU3EHnpizfXpMgChUtRMMqQSLcbX4WmNxaUIpUw9Z
RDkIxlQKmoZ8mEuAC/ch2jTdU7zclzKHKaiMPTnUTM3Pv/Qynje6prUt2kEHKprWxFEMtFToLpTk
VN3MgqpXThtOo9co19nmogr3YqjsqJmhgQFvTi4UBbqrojGHsDia9jC/yHWv41QUsQzw6+sXt7DH
KRFwrcKTR59N7n76+KMb49s/j298VS+t//15c/Th2ej+X3ixISrblp+sXCHIIXXyF2zx8K/Cidir
3zes92bctvg49ZTXCBOI6lLRjGvnxe5yhLpaYcxoKq1aJ7iEg9rXKcfd0+VQOgy2JerUV6G0xVl/
z5rudnAOV3hVd58OahRbDlpX/JlBTfwBDu+s7+5i3QnmLdD/jxYoYWqrIc/cOfQ4pLlEzluqMG9y
nnHvTTo0g+1d89aOL/qQ1CEVwt+thnp5wSXGKv50+sLVZnTn68n1e+Pv3hl9/2Dy+w9Pzm6Nb9+b
/PvF6PrD8R+fTH79cnT9l/HN+wtIXL8OwPh5mq51edlwK9+Wzm003UVNtuyr5V/RsP7HzP4jXYNs
R6r10RRKOQJIyclgwEJ13zG11PZp6LKtncvbV7Y3trd6m5feuHhpM2j+UYQ6/j9QSwMEFAAAAAgA
AAAhXMvAkaCeAgAAdQYAAA8AAABzYm0vY29tcGlsZXIucHl9VEuPmzAQvvMr3FwMEkvuSJx676Ha
W4QsA0NixdjINmnRav97xzYhkM3WF9vz+OY9h8Ph/QLECnWWQFo9jEJyJ7Q63rgUXXiSRk+q42Ym
9sINdKSZUdIA4aojo9FOt1oS3vHRgbHF4XBIeqMHUphJOTEAEcOojSO/43dhBoSFo8D90ebKRi1F
OydJ0kpuLfmpVS/Okwle/Ay+gSkTgqeDnjAmlHCMpRZkny/2s8j3x5OLhVwtd7Jqx1ghKg+6A5kv
IcMG405Kg0S20vXkqg8q9ZmWeMENJC2DSHEGl3oGi9ScCtVrmuXUx24dH0ZavpsJPj0nZNbS8lTn
K3Q4FA2szA/q5hFoSTthoHWI6fj58f38otwp6/2yYG5YkS2C1C2XK4CdrYMBAdAZgxZRYl+KIlCX
4D9XK6LH2s+pOlFQvJHQ0To0wzbjnnsVCllZ4aQlvTZEEaFIADtRhZdFZrnznVcLm7cD0HrHQ1dO
tAXjRC9arAnD3ruJzkdYV48Qg+Y9Qv95G7hQSOl0eJQnfrq/6+fUhexBzyfpWEwfUxzxyo0OInHH
Wcy+NjOawWkxRymaox+kt0b/PS5eAKrIoB1fr+zdwwhi6wfNXGFmMShkrB9vX1ifdnZxbmTthUsJ
6hzFHr/6R0W9AH0V4gKAhWFcjuq/ICiELbKCfFPIfR2xQ7bdUYbarf1eF3wcQXXpdw2zSKYqTmb2
GDwDbjLK90KymeULtFfotrPcCIUbK0fXHL78AlnHO7f8Brmff6Q3Qgo3b7rQgF9J1Y6d7jDXNfGk
g3kLC4sFd7Anf2kF25l5iEVsCc9p856lW59Dgu6r6mlLZTvVb3xYlm4afc+KQN+ayLDncNn6Kn2J
586oXnkeJv61VSIs8TvuuWpROvkHUEsDBBQAAAAIAAAAIVwIOA3GQAAAAEIAAAAUAAAAc2JtL2Nv
cmUvX19pbml0X18ucHkNybENgDAMBMCeKazvYRkmCOFBlmI7SizmJ801B+DMcjWKFS8vjZ57jUHp
Q01TP05Rv9m58JR41kRGjTYPANsPUEsDBBQAAAAIAAAAIVxCR4B6VhIAANU4AAARAAAAc2JtL2Nv
cmUvYXVkaXQucHm9W21z29aV/q5fAdvjARlBKOWo3ixZZNaJ6TQT1/LY6ksiazgQcSmiAgHuBSiZ
djWTzMSOM7Wd7rp2ndTpJjtt08kmctrdNl4rcf+MSMmf+hd6zn0B7gVASvZ0yg/iJXBfzj33vDzn
3KOjR4++SolHwsR3g7kOJcQIorYbGO7A8xOj3XX90DZOk4S0k9hoR5QO+okfhZYRRonRp/6GH5A1
4hmUbFI/8cM1++jRozN+rx/RxPDchCR+j8jf7ShMyOUk8Fflk047TAL5Y+2K35ftrht3lX5+JFs/
jaNQtqNYtvpuonan6ZIJ6fU7QKP8PRj43kyHRj3DjpOIumvEkKRAr5bnr5E4seJh2IY2hV1HdDgz
c+b15tnTF52rZieiPTcxLTMm/z4gYZtAE3cYJ26vD22yAayEb7eNXIIGJfEgYANCtx93I2z2Kdnw
o0EMTdymuTXT/FHz3BLOz8fNwXQ0m2au44c+9IOlqBvG4uEqWfPD3LN21Ov5OJBGQbDqttdNa8YQ
HyClHW0QOkxnTx+k8ytEetTtJHOeH7dd6iEpKBBzlPRdn2Y/owSOGDZwzDjV75PQiw2Y0O8MjSgM
hkbSJUZ7QCnwxIjJWg++LSOOQA5ieJC4w9hYjQahRzzbuEjcAORIdIthRpcSJhLsZGIj8MN16LA6
ZLLRYJNHgQesZz37dBDiazKMQs94o9k837rYfO0HyFd75sLi0qmlZgt+XHi9edH5bq1Wk89eeXMJ
npx4Yb52YoH9mdHGOidqM2ebr5169c1W4bloO9RcPjX3ljt3pTb3ry17bmX2kr0MzZWrL20t8cbJ
rbfmlt25jnh6yV67Ys7MzHikY3CJq9Bos1pnZ0VJMqChVAA77ronvnuygmJve4NeP8auVgwS21on
w9hZogNixXAs1AVZjZ0KHI5l1s1q1Qb5jDxSgVaXXBbrVGHZf8v00BbNnhuCKlBGUQssAHC6gjpl
kcvtYBD7G4QtJEgEFX+DkD47gtjtMZuxbvghrGa4bRrFMeyiH7htgmdpRB1NEoKIGwmcye8w1bX9
uBUPe3jElWqdun5MjMWLTUojWjFH25/ub386vvfe7s5fdh/dGj351e6jx3tf/H70wddP7zwZ3/6d
WWVzJXRY73hOFNsRiGIlTijbQnXWtJE+04I3i60Lp3984Wes9eqF5qkl3jy3eGbx7NnFH1u16GSt
xqeDnZN+IskQRP3IDQZE0DX+1Sfj/7072n5/dO0P4/fvjL55m1P69JfvcGLNqsEszbkoJCmFqT4y
02d3kLRKx7P4z7OLr77Rav4E+ZJy3iABrKy8v/j9ajoLkN9pd3uRh3Mo1ONn6JPAY79Awd0gUBY/
ZjQv9wO/DTZ+ELLTcwNQTEoC4sagbC4/UtCuNvWZxYfj7YJqJ6Bj4ojBFq7bh9jOD89VG0BmO4hi
Aq+qQvBbG27gey1KOoSiJa2kLV0RKn7sh2AstC6W57eTquGGaDESZaiDRhrsBRozpjnQCNw4aTFL
CwY6TKhPYjBZhvLBecqWWeZzrVggTHw1SuzOIAjACbS7FWEArEL/amF2YH/pRpbXJ00OVkVajJML
W6alDqki8w1UOWO5bJ8lBCTDvrYxyQiYy49hokRQUOzwci07MmbcUbWI27OSKCBgdYhzBoRHnpp0
bo5ZM184udAAYz8IE6fWgPnb3Yg6qA0NZvZdOuS/+hT8UMinYZPwBeyYkPWKEGjcMNgHgnvmrzNp
ZkvMOvPpA03RhJ1BwIIT2OimNv2kWzEvhWa1qNg678DaOsz4BpHrxRWcoVo2tXq4YKCZfB40dwcV
NHaunqhzgPGzqyk2aDHoZW5ZL5a8E04S3mrTyc/ClCHo9ROEe1HYkodgbm3Za4T5IPYtUU7V4vMU
9lvoiIdy9UVrYateIAiQgcFgAtoQGGj0XIEO0EqDoRGUNQyfA0Q/HIABYq6FQwIOQgsTi3FOSkxh
r9XCGKCdycoRZ94AeUqHcthWPeLouAb74NkWTJVY4cADxk+qEGLQsqqnDaEUKC7prGVkF1juOAtF
ZuMnVS0Yslx22itS39Cjl04B68neaByQBainzEKU8kP2PpAhMHPMJQ2YzcVfHMSy3NkKVycQqHnr
hIVClfZIQffKEYedY/omhdTwRraL7DmYOI0QxzlRnINJo6MtKnR1pezccqaB9TyccVAp4vK5kskn
h+G4fWQnmxUYOsH18dMSDpD/SN3gIanAbeS8E6Pkko22Mbhki9BwTkHCAIRNi5GWusVDruaGw0rJ
iro/5DNP9YXKxg+9NvOTgmqdV9xTcuFkklfe63u1g1aK3Q3iMbvVj/oVHgMWJFGJC444bEQq7EIa
pJ7w4HHaogLKVrKX1htkyBtLsF/WqhY8pvTvdYHErvKtmnXmqDMsVWe6ODevIpC6VA7LXKXROglb
6DlFVx18FQjvCMgP6H7viy+Mq3yMsf/pzfGt/xp9/MHfvrk5/vl/7u18vLfz2d7Ol6PrH46u/a4A
tvGT2V5koIoq072w+Cm3lQkb4bbarPNv3feWGdq6bKlOl9tenBa/tySyknEvD1kElHKThFAwNoBZ
IAwHuWSxUggRV3WWmoeLMpU9Y9CIcR1TmD6KDpsPQkdY2QZoTz0fxIZZHVXzBB1Wny/N3EAfQzbU
6ko1dQt9LYxLQSNgNa/FfTmPKTn/xCaFcSm4FNFJumD+UxoSm6UwOIpLeQJxnqkIcTFgG339p9FX
74y+vC8iyu0/8/gRA7m7N4QKckIdhTPf0deWVPOO2pYlsdkrzqGS4LFIy943j0e//eP4xj2Iccf3
H44/3H769kc8kPzbNx+ZszoVVUmGkraq8HXBXsi+whyuHIqA8X/c3//9O7A6xNYTV9SQNfKfpWhE
xM2WB2EHmMlyD3645piDpPMSKKcbw4ls1uHgEtBHGUn4kX0RNC9ce32xAq9tlBUQHS0Cr4gQ3Gou
nuGNH4Y+ZjaE2TrU3lisvv9wZ/TBvbK95WwHHi8jVAmDMq6mj5j/Ff0UUJf1VB4+m2DuPrrNZXN/
+6vRt3cPOBSp34wUqXZdHxOcQ1XlLC3sstSwK8vsLCI2d1n+aY71N1LjlaFCNjQ2PBL4q8xHsPyb
TP9yPeIGDSI/wS9oJdCpDb09vmgjIGtueyh+QLQXOghn+KY2u7BDofcZ8xg6UDnA4kEYWSYGupoj
fx/8YfTk873bDxV/i4Nt1/MqZZw9vEWYbBUOJaDTEltian5czNpOROcinHBkh3rGcXR0jVVQsHV1
0lJzpXm2Y8bGi/ZJuwaIxBM4EMCelx64cZ6SmNANAqFVD5jkr/qBnwy5cfCT2EBHkpsRJAqgE0Ca
TT/0IFo2VgeJEQKuoWAnYLIE4j8Xjb4xCNm2PWPN7RubYETksmUxuMIhKX4vO2XZ2zxbhByWsOiw
CsutNyCT3Ue/5AYc+nDl3fvo3fGja3u/uL7/5P/37t6cqMVM1oR5nOQzFaHk+5t15qV+zToFmyXD
S/lCIJjUhx1GpPBHyq7JWqbscPzg89F7j/duf4Xqdvv66IM/cXHeffSlWdVBmNyGWZctvFrBbaeA
ui4aliksWiulxszOcSIaY47Gx74sAcQOGvAd+25l3QZh1pG/3MoZ0hZnIj8O3tYTlbrFzbM8fVAW
kZe8FDhxRcIo4TB1eNh1xMWXfd4VUEgYT1S+CYl81d6ryoP2jVyGPcR5E+AXAWqJHHx7Z/T+rYJC
/Hr/4dfjd/579Fvxav/P747vfTj6xe3R9VvjTz59+vnNXOwjuMkyIgwU8iuO1IlYqVMVKUYrczWW
LjvwoDS/gZ+CMHG+WEXJ4etPkRjB0SwVXnIJIS8fFs+dfVO/c6jqcAoT+h4b20EoxZFTPuHJVlES
7iIhq98RNHJYi3fSmS244EwT8gNOR4ouj6dW0oMqGCPl4EpAk/XCC4IGJXBIlSFwQw3IRIHX0nRw
nZA+Bw8NfJcCnaxjueahbJf3kQrIr19SaKjCEmYfAzgqXL36Pd3FFCGL46ikyagax4ptTUc52PH5
Uc4BjqWBs5fBoINciOBEORA5ou94ulsr4YcUBJaOlULJRF07fMCceH3MksZSKfMXz4wqkXIOyaaB
hIor5SRiOAWFkcHeDMPirb4jqxjstBFGm5X0B/65ArPZg6RdhcCUdvBJxTz+5vHecW/p+PeP/+D4
xbfM6qw5Z85i+YGNfxYq7FZ2uf7SSiHsRDvQwohWj21nGTnQgrC+WnJN0gCSXEc844FUegXMr1A8
C8shIoqKIQsj7N56jO1KH2Jv/7KDC6nLImFzpuX5VEXAk4JB3XptrmaBn2ZFssDxNfhzBlEn0oJL
OqZp9YBmB0db+DRa/akDM1g95KtTYzP2XfRsdf5lY+kJwRNxc8YKIsoOeL1uhd1AdrCsg4WZbLEI
As1Gdn+qPrdq0YJ6kwq9xIV2JeWg8DXV8gtWNCuxrfrUdGC1Dm8GIQsOsof8QLW6k0qB4fLOQyR6
6wK5I9/SpG+9JCOgJbTKjG+WACuY7a30qJlmppa11DzLKg/VdYgw/hU3Jk3WhCEZo8QWBD/AaU1m
QYMZP24ros2sGqe+oNTj1OfVipz6MymvH0d8SpAAkWWt6zdCCp6QNT75HrLkp25G62pJTd1US3/q
ZbdB6uyF2yw5ovQGL001bkn2LPO88oqjJJKf3wqAxXxuI8BtQAfY0s0hGHwklDdf31JW0DLLLmwb
fFhBr8XjEs3W3+SrJEp1O0PS/yTNPmYsgfNCx9QFyy1ibH4NmkZm3oC6q8HQeKV5ZvFCE29JWPYP
fS8lPYySbWUuUIDVQJTmwGuIt2OYOwB316XRYK2rluhYMqzmvpuVctnptTv4cMQfpTlqyZGAWyF5
J8GwCj6Uen0gE7ir50uLiAUV0OJaZnGlsqQ2oZfQr99YSivLKbPB+g2JzM4Wb5Xwumpu5eq8tVDb
MsWK0zPJDHPtPv757s5fxjfuje/c2v32wfiT9/YfXteSySyTjoSnd5omy1wTrKhj5qHjwgnirzbe
Dwa87YcJYddp8Kvkhk4sv7dzZ/ybB/n1JIfS2D2/XfWCDrY8X8M9y1GlgR1bbfTX/9m79lnJHp8p
DK3WW/yI9dh0yknnjjkNDp5xmgMFphAC82sObQhqWopwJ6rDoUNjcYv19OMPn+7cH9349Wjn8fje
VwDjJ0XNppoZxahUqSabEnOWFLydOn++ee705OI3pq0MSTq5gHRWCSoKZTbTY9LmT3R4dsy4wPKA
zMrx6sF2l4C5EkaHUIM5BxozQYoGCS8L8T3SdimzbHoaEOnBekRGM0IQQUTmFQCft2AlB3uwDkxw
OlEQRJsyYxuLeF701VYQWAYR67koOYOWmZcHsmWzAibFNLIMK7ytC1p4HVy1IWtd9Kvhg0P2sruJ
lx29whVN3VQexP4Vkg5iJbDFSocpYVfjoL1Mx3yZdKUzZNAOP1kOllmQfPpDR3/zKvorsGb2H4QH
dfZIdMhNTgoFhe1JIaAwQgoITM2aCgWLgHxLda5FIyRDbZ2lWFEw6ONeKpxs50Te5uWNqTJ0ImBU
TotHmmhXLjaboNDnTqei8MwwToplHsflxVUFagLQ5bqohqvEDkqIoabgMuia4cdcKFdSssrLbg6b
g5W1zYiLZOUOL5dhhTuT6p5LcMZft8ER7H/9cPTkXc31lrhXmYvmpGrvsrRa4dVkL6ihvOdPAvM1
DX4N+/S9W+Dqdh+Be/sjvyIBXwgOb3TtxkSfx4RU3hqA8IZrJCtEAWmIWSSWLxVnuTBR63sYD6nn
ZEvzsfmbbYvgzmPHFHC6PGF7eMdY6gGyUltWha9dOOrpV90iPG96dwqL8Vrny/twtqPtm+O7/4c3
Xt8CIPxs7/0b2h0QO+nxJ49G278xkU5BwfLUqxeRbM3qf9JFYL6nD97mmqAUb/8TM3T4cWm7i1co
uTSdqttpJZzI12X85RZYpm7EVFNyN1xCC5Vs5fkbvQhtUhYHP8eyC1tRYCuOxnCDKFxDdMX/XYPv
A0yVv4YmsWEEwFCaVQMoM2JNLw9B2dAA/2sBN5YBN48EBP89DN6zcJWZA/BFHrrtDMWJNGjO0DTE
tY5kv+RddgIqN1nSUlwr6qrCZsnBEG1mu7eOJVAs/1iL/kVFw0yLWb0lTyezsgM2H1gIZsDT3Jc2
5XfEY147pa+th8P6uFyCIk0HW/I9+58K5g7FE+EGp2XQ0jnLwqcJ/+Ilf2K4mkMTCogoGg5eWCdo
Q4mkktCqlS+drfO6WP0OV+cHnyHHo+xUs1uarZm/A1BLAwQUAAAACAAAACFcoooxSMkAAABaAQAA
FwAAAHNibS9jb3JlL2ludGVyYWN0aW9uLnB5VY89bsMwDIV3nYLQEntJ9hYZgqIn6AECWnqChaiS
QUtOcvsotoI2nPjz8T1Sa/0zssCS4WgQAmefIg2pRMty/6SIBUImRVdmEL+wuuCS/NLV57F2HftQ
BHuttVLKBJ5n+nqR3ffNYHrq9h+KalTqRBbBDxDOeLdOQoiWkiMfc52b7BfUfCq5yVs4MiPM5bwt
dguHgqbtHa3lfs7ip66n45F2hw3cbcgzhH195+/Efp0IcpG4CTQjAdvz6t4FHhCaTSPfzvhP9eoB
UEsDBBQAAAAIAAAAIVwxCvpnigUAAD4KAAAVAAAAc2JtL2NvcmUvbG9jYXRpb25zLnB5dVZNU9tW
FN3zK17ZyG4tk2a6coZF0+m0mzadTHeZDCNLD1CQJfVJImEymYE0BmwwJgnfcZo4ccBNQNA0CWBj
+DN6kljlL/TqPRnbNfEGWb7n3K9z72VwcPAmlhTR0LUppOqTWLcNMoWMUZSTdGkME9G4q2MFaYYs
2aqhW2n0K57EBBFAWWhU1TCSDd0GnJUeHBwcUHOmQWxkSva4pmYHBgYUPNohToDtaMqyJRuniKPb
ag6nFGKYKXwvglkpRbKllDUOz7JjpyyZqKadcnTVTmYGEHzk4Zg5/Rv8ZXTJa1bvS0afvEZ638bu
kteU3veRxyTjjl5bw7cSAm09pYVS4FaD5dnw0ZZf2RXiUJKphHDzxo3fUfDMpa3VXhNhiBiGPWSp
+ljWuCfGBUxb40IEo2fv/NIhfdzymjXhIkX2i7vhrx2HZ8thdTGoL9BGWUiRIUF2CIGqMT4RCIGF
hRl/2mHGuMI8xMCj6kYz135h2q8U6OF772ghbLW6EcyWYA1LFrb6PPiVEi1Wg3f71P3rfDN/ni8F
LVdIyUAPhVfH0ncsQ2cuwuLD4OExr4e/euCX3M8n83T5HZ3bY88FhmqXJIb1OuPs7RRkFnjlrV9e
9hq1sFQI6md9lNaQoBBp1L6cEBL2V07pyZ8cTVtP/OprDlItWSIKVkQGt3iD3EV/9QOtzXnNFrPK
SvKEY/ZXhbqv/PnDqCr7J3SuEX585K9t9sUWK5oVZ+4tdbe84wIaQtFzsU5L5dB1/XqVPl9nvkxi
2IZsaJd4O3wf7DTPN2vdmK5cJCKPq5OQSjdFQvAaC9A6f+YVrZX8l3Ohe8D9YF0BPV2SUzV0q/76
G3rGA5IcReV11eLqRAbhWYsWX3pHS2HLDVu75ysz/zdOw6aY6O/t1kqw3YydrEGFP9FyERpO36zT
gxm6t+G7H9udZyW7fv0moksvQvcUNAFlo6d5ngskwq2gP1nYTkQdU3VJS0eC7HPL9UgfbwRVN3Rr
wdYjmt8NWo9p5YA+n+YFcbKaKouSohBswQx0JM2VwIcljnn/OPynymDxNhGN7B0s2/1d49Plv3gT
7r8Kip/8aV4oDTaTZYt/OJhMdTx5R0V/txrU/wWVRECGAuEHtQbIymvmg5W611jyN07Zm0I3FSy7
rIa/kHm7P+25i3sDP7OQeioeJ8pmV0gplxPyVUeXZmn5fdektG9FZ2KAj5uW5oLGTp8M2wDHhPWL
xViVl4/xT6r9s5NFMVNjmRHEQMtwiIw7lYxtg50ZWHhe8yltPKXlt+F+E5ZuUFhk0DHVHneyom1M
4C86O99eg45QtxC+zncpTtWh3JoWq+7ycL//4ZcfUbg/4x1vR3PyYRt2xUVVYVTkHGahWlOWjXMK
ijW6WQ+3Z4Nna1xpAruKyduMWh1F0QXMsPuUlsyoWokOgXfU5Hu6DWXnkp80YtyFi8ZpRg2CdAkO
7qSkORhuMj94mYvwzd7DyMzgjBp3h++D2rJYEzIML0RmQsayScJMpgR8T7VgAjJmmj8lkg8uKCF0
M61aI9ZUTlP1iUQSQRAdQyTpCnyFyTO0SZxIfjVspqUsfHFs+JYB17cEWyJj2BZuDzN/HdvkhZMo
yXZZ4DnOHNsO0dF9FixEFxmlBAuTSVXGI5oxNiIbOZChImSEO6Ai2CGyrSHRQe17i0QdfXvlChJF
3RDNSK5CT6uRIMPZ1B0TGMJyhZZW0dWrn0+2/IMj7zhP519GO5ufaHZ/YIv5R/ng7wZsdL6/21ft
WRv+XQQHG7ih6zt8vuiTRXjuPdm9UYAI4NJIZGpEUQksIxAnnHLWHpCsnTPTXwvJbwTYJN0zfD49
DbfLX//E/UEQ3tGev7bnuwvB6iat1OF/hWgEymv0dP1im9DlpbZ9QXgw8B9QSwMEFAAAAAgAAAAh
XJAMaNVQFQAA7zkAABoAAABzYm0vY29yZS9uZXR3b3JrX3BvbGljeS5webU7f3PURpb/+1M0UHsa
BVnYjnHCEO1WFpyK64hxYZPN1ezclDzTYytoJJ2kMXYcV7HZsPlJyCZAsgSy4ZbsskmAvdu7DQES
Psx6Zuy/8hXuvdfdUmtmbEyqzlRhqdX9+vX7/V4/79+/f6696Ht1NhOkPA54yvhSzJOEnfXSZRZG
qRcGrm8xvurWU+aHdddnLTdwl3iLBzA5aEShF6SJvX///hGvFYVxyrzIbTQQiBp4NQkD9Rxmo5Gb
LvveonqNuXpK2otRHNYRwMjcyRMzx/7NMSLCcjQM/LXRlQlj5ABLvGBpdDFcZXHYTnnCXHb6+BxL
YBWgzBbXmJcmrOnFCe5UPwMnw8U2WxlnPm+mLF3mrOHFvJ4isJBmtIN6GAQwxBsWjDHfBaLI5QkL
m8wNmNtoeSlMyLaqh22/wdSRDwCRwmgRlrAQlsbeCsBgDZ6kXuAiNRNAYYLJfRLG3fpyBioNCa36
MocdGwBLW2ez5xF3WNj0ltoxjbEkddcSIF09XAq81wCpdpB6PgEJ+GoqZsct+OBGEZx+pDZ3avrl
mZOn52tDKTuOlJ1ejWDEw9UrPAZWw0Mr8onjCcGOcZsWNxLgdc1LauqYnpomMB6ZPTlbmzv9S9jI
KY0w+DHGbPp36FnDMsaLL2P21CS9jo/h+8Qz+VexdnzqiD1xWM6ZwjnPTNjjU+J9At+P4Puz2oQj
z9rj8v2wAjMxMSkhT8KUickx7a1cPnRkin6PA8hn6akJP+Wx8hh9ESCa9bExmPoMfG/yZ/GRcG42
aVghfIAtxG6Q+ESMQ2kbOO4zGFkCaa2DJC17DY4SxVuLvNEAHikyzsytTBZYL3admgRcjiwqHNXr
OAxMIqoTY2MTiMqUeMbxp4EsI+ZI7fj07Mz08drs9MKvTp7613knbQOjSi03KmXKagMrQf/PhvEZ
K+ebCYtPnDz2/Ina/OkXXph5ZXreKRlkBpbDJIWN6Fn9boQt1wvgbTlscduNIxeePbIsMAlAnfzV
7PSpeWfdSJJlo0y/GjAFf41KJVCvvpekPOCxsWEZkQukw/mro23P2NgYGRlp8Car5Zao5kWlFddv
c7NMxPKaLAjBFIGVAB0J6lx8tZI0NlExjZ8ZzAsYDYoV+BO7XsLZyzg4HcdhXDJ6d270Pvzd5g/v
dW5e2b7xoHPj687v/tC99k332v3e97/vXLjRu/pm5/w38Cy41n37Cj5Msc61v3Wun4MzI9w0Xisr
C+EUKC4fJe40ma/WeZRqWJT/P/BizThssdkw4EV61YQ9KEnEiFhusKbekWjoJZowjL/htV+4zL3S
c/Pehe4HX3YuftL57PPeB3f/ee43vb/8BjCGh+2Pf9j69i6cB9AF1Dvn/7H54Mr29c/FkQq0jXna
joPM/krJIImpCXncs2AMI/T29f/sXn/U+eMfOx9e6H7yRffy23JfWubQ/zYsBvkzbT88y+OSqTYS
H8FHJuhNS4ZtwBbaukp5dLxKk313kftObFTc0dfGRo9US78oy8fR6vqYNTW+ob6YvzAU+JLP1dl+
PnH4aeQUHi3mdrPt+y03rS+XYgNAGQcJ/sHY+LVtHpRvliZy6gcgCJzjBFxAihhb42YFsLS9pOEt
wdDAAhQOcSYnaTeb3moORT/5QfHRJMmRE1F4isbF3FV4dF6A0Hc/vbt579zmva86d97vXv4fKRv0
9ceH72fStX3u6vb5C71v/gxydfrUCVQFIVhialGMCHEpRPDsNcAel1phg/sSMxCalDs0Yi9xIFHC
6+3YS9eMjO00BSSMtKssAGc86xM+mms1vHpKmpYARBoyhZQGBWqX1o0oBOVcU/ZWmQ+egJXc5aNl
5JbS2BA74S4VtaQqt2MlERZY/XHC7ozpvHW/c/FPnTvvdM7f6t2+0rv8pVAVwYat337fOf/37U9u
bz/4dOvOzc1H17vv3pTkynB0JEL9qFd30NpshoWOgo6E6pANmz8/PD5RHkRV2EhhQTqPvu6d/0tB
q2l7B9kg3lFaNdOXgc+psSNqwqQ8MQYZFjbAKQ11Fso2ZxKns1dxkuipS18+R9FaW7UTmfMpuZDi
FC0HkGKbj5ij0s/bZ/haUtqzPyiQIeE86OPDGS9oWCrjwCPmW9peyluFrXBriDMkqUADMLUwNnZh
m4JcPGgJcVCfTMdBuEwi4zgyMgEj2GBDJr6+bsiQaEND7QkpoamJ0xfxqO0q2Tmr5lE8qJN/oXNX
9XMreZaCIpI6OFK6FvESTjfReImvqaLD+HMOfnrOmTp8+OnDOJrJuVwSEM+e5Jhgwzfv3Zf6QJqw
ee82GIztty50bl6ACAZCFtb56P3utXeAHL2v74KR0YiCgi/Ji7tnkoHMyM8vZ1T3OcWgYHDGY1lU
iAW+eNh5eHGAUUgCUtwidUzpUuqh70PaVyOaK3GFaW0flDJLe23Ir0oVw4tAbEdfhf9yKU6Ww7NG
1aIM0VmIIXCpuxGoOK9BFhy1UzGWQu4nnyBNgy/O+JjAEfyZ62A+DrGK20hKYm8IYBowy9zBCOCi
3MziRxwZZtqAHH+/vHX3QefiFcFWcsF/EsYOvEH32led+5d6l27pvmLQFRTUnvKHplvnyGTaOKM2
fQbNxy/ZNOGWEVrNC5qhYVX6OQsnxFViYtNteT54b4SxDskKTyln4emUsVHOcCKegkEfbpARmnRd
IEZmgY65y9jJFeg0An3o/fX+YyhVDHm5CnqBW61IBCtW7gfL/cZ/WOxirW+YYkjzCWIzml7Jp1ad
LNAoy2BhwGmXExB63iit70gx1xSRoFvwqhvmhiJdjkd5AIOi53LyFxX9q9yx5iUl8hoFZVQUgfgY
hK1SzSRNiAKFQZVJa6qqGUt7hceYnTrOJOM+sLEypUvVTipMOjsKwS/QQUA34f1FHPTTIOKo0VTz
clhZzCIMq1ZBXgd/frL+q6P6IOF40IL+2xT146eCK6U1HvcbiYPfxCzw96v04Bw2+5ULAzGxwHyO
XIV4qYyBETZOzMwvTM8a5XoYpF7Q5oXFWFSwapbgX408mVz7dNWOIzdOPSyIlIyyMbhrvmifk5Fy
530c/E+mbkalapjyYMbPKOkZq/ZvgPNJOIyngG+ybEQlIqOPWvizGLYhQhBMd5w+MSL/qb5Nkccy
VqawBlceI2emEdosnhSlb3A3qjCILYfqG+JuZmgMLB9ScxDAXnBhu35C0KeyVCDbjSLwpRQnYeoJ
6ub6PiSevy7tL1X+fX/1oLnfiryGY1h4KGUdpQ1bDEO/JCGZRAdcHJ4F5U3+RYaRFVThKn0UH55z
Cl8gykrWgPethrFBwi1miQhRQFaGAcjvNddqyveXCiGlRWZMsvIJIq4874vzsokeXO01ANZrNgzi
oM61W3pJZ/Peuz8+/Gzr7rebj+50L32HeexHN7cvndu6+6VYbxQcz85WsD841KQ34fGKV+eOMT//
ooGQZJyL9Tph+IynXxk9PcNKWIozjV1OJoKB3o07kPMxMG4C8kGDdW+Ds7sFWMvwji0cm2Miuut9
9vvOh9+IU3a/uNe5+x0k7X3Hzc4qs3TB0pxN0gPqzByePezVD9LgQIKxJ1nKwj5RtOeDaNKqMOKi
oK9Y5BgG+Sr8LcJTeJKb95UlHleVQFOzB49dqW70BwqYB4lqxFCSZMKWYQ9yEvOV8Aw3CukxHjGr
LzwlVReCWt8X2Kl8BO9L6IooZuLMO0SYkApcfbOQLpFcdC6+0b38t2J+MJiqEpvADeHuZFJ07LQc
VmbOrGgAc4XA9WUtAa373I216hiZaWCHBlNYq5FBI67TUKAGQb5KMhVukm50BkGeDP19Kg81d6gB
VrByuD5uHd4wZLaWZ3UoujQmU7vHJUGomRc/3PzhM5mVKVb0/utB5/P3QF1zE1bUbY0zSku0BL2M
1rPP2Co/Jsurpimz+HKGcyGfl0IzmNj1ZX7il7lXTe7L2QrypQkAqgguBC+rlg6XoX6ByKYPyYJ2
KoqZr6+LnCPzQoVcSEOLCppguASl2hFajsYThPB5IjEsNJfwdg7ICwZrPTdLauXGTkmG/K7HChjQ
Drn5ids+HFCv0dKIHtgP2H55uJ/kAjQfsOuVzo6hAv4sugkHLsgLNwhn03qkilTlSr+DroK1rKN1
gIl03Q1T4RfFYTAkrrG14hYRQAVmZMZxPwuQq3uN2Kk0jXWJ08Yh9WRDQF+LYt70ViF+38A8dojZ
0+pdw2ovReNxgM1y0C1gAVo0dnx2XuR8ASMTx8G2uS1usznYH6IDLi6/fQ8pnrCFE/N90NQ1+dll
z+cs8oLAC5bkRb7rq9tz0mYPgIvClkLNLtq14RSSvrYyaEOqFl6Gx16DKwY7erxXjGoJuhRV4pd0
9u0GcEDc/FN6totHhxiWLMDuIjpQ6K8A244KnPvrKAFAyuKeioGvIJI5xzCFgF13r3TgKtRT4Fac
lzrIpg+kEBINAlhcpy7K7FimX7YhIaF8YpqZpCXtEnpYKV6qMGCsKaQXDddFxaZsIu2TpS50WvNg
ycALcyoPRQMJv0ENARLNRR8bRtCOFhogjDIl3YZUNEhycRtdefmruaai8GONWtCpJi7FjDIdvv9e
bCcYmdtLygROc3qSQPKzKVsSTvEk9EHVwoAKagn2IFBLB4ppfBQSsnQZsk94Bt1BNY/Fgkahh4W5
MZcAZbMKW+TAINVSQwoJymmhrtaXAUgbxFNspOApXuJ5hXJKqyCoKghYyTpGRKYNv57EGB5gL+XR
H2klYo5BCTW8UJNPuuwlWPBG5HCQ5sGbm4penwQbi2wJ7mTAMzMUY+8OQAyDrGVHJ9JRhiHYaB0/
Y2uSrKmHzSaPecNW7NNsQlkSoGJog8BJcnyaeVk36ChAnad2coSWsGlCTE2LZMNa14WIuID1J6GT
ZZlDw0jDS9xFn9ew+6sFzPHqtTqeVEj3Rh/o4ZUqeZLilkJugX9ND/tBNF6pW3tIH7ywLQ9hibTJ
wu4jMPgNqefYoARAgVFk7ccZYB1hpxY2aBEzaXWZJXBoyXS8hQYZoRXIi0XwZiCeGRN2t7IyVjL3
Of3XooMRnjqCyJ4y1I+q8YqU2aqzk2MgWAV3ksF0BEUkuWRxY1dieU2mRtTqsh5OyTn5qTMPoaY9
jimZYkiGiE5BYEMaxh464HYAwgZmHrvqcl55etuaxQIMFCQoN1700tiN1xgYjVhykGrFVAAE0QId
5a0QjUjAzzLBHsFLny+59bV+4otROwrB1TQCcJN4M6+Gc46sDwqmxgUJusgDDNAfI69A2BjT6X4+
kHXdm+A5jhA3SaAF0YJH0Q/IvyAQ6KnvM6Fkou9xVPY94j6YhukG3MJRCQ5NnN7TSY5cWXkwzyvc
YougPKIbEtVHdUTi93YgbZ9gAJBSpBho6+TRCYM9yVFm4PrTE2xfhJgOPKoASSafNjLK6gmSGGJR
LRcso9yPxu5KU7RmxfAKFLQNgWkZq9s/ISrrA60lF+UnSkNIpeWBsNYpDy+ClPWNvm1i/h9tkOWk
Rv2fBXKA6a+HEVh1I4rD1TXV+Isu8CgEFVy4q/oyNiyy+fkXLZQqfhbUz2KiBgjbvxK7a2S/DzDR
SDyq3Dp4EeofXaPAjTpSMQDFJIAExmbzqPNgIF5cWJibB0/cjuvSP4O1oPbXiKtLmaNsyQ8XYXJ+
G5jRV1SGqYASxqNay2t2P3aAlWafX2CHWNMPQf5BbWbmTNoJOA++ACZTv/NZcPqUsSC6CqGYYxJm
j4hYtDYzV5s/efrUsel5Z32yXDKW0zRKyocOuZEHEafXXLPDeAlbIOW4F61M2mAIg2X3NQgrYUPt
I1ECRt2W+1oYuGcT+j7cqU4VN5vaabepvt0gcT92cvaFmVMvTR+vnZh5aWbBmZqU5muw30/5WPgi
Ke76GMGAUwqZW0fTANai7UNU4CbYU82SdhRRqMnm1sDLBkxGzomtq3RWzNEAy+KW9iUHPORjO0gi
XqfcrkCfIVOzHuxh37zgjCjmDPsqU9HhO4A+umme9UGgn9QSiJVrsgtWuG5V9W3wFOtGksBCji0p
VQ56IAuNOI/1a0MSCHmXpxWv27FP1VMlkzA0II4VsYNezceUrnAQuhgUu5YqBhgCf9j95Chgk4bw
xSGxwinNZB5/jcogZVTeK8LYYRpvuas0Rp3chgWAd7nDTNIGpNL6sY9Pvzx7+sSJIReXE2Omqv8V
WbJb6QXBDGSmJW2/Y2DFeGNOvFG2amlfF8Te06sRGLyGdXJezMhT2yG3isOuiuV9MkrPEEUr3uIj
yXR9Ifmg9lztCgHNWg3/bkIUBkmICn2JovUQ3UJi82DFi8NAOJH5X75Um194fmEaGFTsIpB/hmHP
ZWDNQ+qPAvL2B2wZMfLmRnI2Q7HDtpJB7HATZ9gRsksEHFI9k6o6jWM2X4VQEm9eJL6Vqr4EVTZZ
a6FOl8zCOvjQBJ9eGtaC1/n2v8W9lN5P3L3y1uaDf+C12w+fYBvGN3/uXPx2++Mfuh+ovov+5hna
B7LARg0FTpWG4/AsRP8wNW9EEWEAue7+thrRbIYiki8BjYcwBcO+cY3S8tR9vTm4W7EFEkfMn/eZ
/CcjQqGtSdJdtXRI643biBYOeKBOAth2wzrD1xzfbS02XOaWS67SBQvL6q6ZmUYFRO/MRmO1q1aj
kRILshuBEU2/tcrT4GGxG/jTu+LKgq4mZEfSVWH7BNg9N8UPo+bFr7Z++32BoBcudz+6nbc+vfdR
78H13oM3YRAiEdHqDg+i+R0eute+6r7/VufOVXjefHS9d/kPfUgW2z6H9r3nKgaeHwJHqYpWGIl2
7/wWkU5qY5KGf+Cj/vLKXeF9OcugXmv3fngxjA1puZOJYuR0Llu9q2/K/j5NyOhEJcNihv1q6AX0
dyhwQEvuahZiXFF8A4k0tGKj3KZ36db2uUsATkR33f+903n3FrK3d/sd2ZMsu6o+6JzXm6wudD58
H1DbvPcAUPvx4WfAPYC1ef+DrXff6L3xndQFuoAWPcziDlp8pQbyC513b/zz3BuGebTY4E1EAaZk
mYqqw2ExVh3w9fWiAuxBb0jQfbWBSH81uqduDKbDKYLVnZOYoC4TJSJD5Hjr7pc5ka7dyo3E259s
3bi1ee92Jo4CosYUdeCKm7d2KS6ie9zniCVV/TD7HIOuTo1hOqUbpo8vbH5/TbWVv41iBxwHQsP/
ghrwQJB+fPiOoeiV8IwNud9AI6k48VPt5Najtzo3r6peZVCb0lDvZq0rY14etzRXUK6QQpsDhKrK
C7Fcj8AUdG5/+hNURnAMIHTvne/99T6qz/8BUEsDBBQAAAAIAAAAIVxFLyFMcgoAABcZAAAZAAAA
c2JtL2NvcmUvcmVsZWFzZV9mZXRjaC5wea1YbZMTxxH+fr9iApXMKrfak2SOEJ2V1KWMbVIJIcXZ
lcrlSrXSjnRrVrvrmdk7ZIoqjI19vPmIMeBg7JjEjkniAH7DOD7gx4TViU/8hXTP7K52JQHOiz5I
q9mZnu6nu5/umR07djzLmVg1SSuIfIc5JIxantsmB+0u4/uZJJx5zBaMvBwx7jKxQPyA9FzOAy5I
wEnbbq/Cqo7teS27fcjasWPHjNsLAy6JY0sm3R5L/78kAj99Dm256rmt9K+IWiEP2kyIdESyXthx
vWyxEtThQY9YQgYctCPpWnuNzcz8bPHg3gZdlTIU9bk5O3StritXo5bVDnpznIWBmEtNmhOu3y23
gsNziW2CzhxYfG5v8+C+3+5tVCszv9j3y31LjV0/rFZq+mtmZqbt2UKQXwMI/b1ovPGi7UVMPZbq
MwQ+DuuQZtP1XdlsGoJ5HZOD8MCHH8n7jWdtTzCTAyZNz+25Ug8ka/EjopBxo2RlMvTy0gLKsrQQ
9Z0MjCSNHjNFn2US/MIfpVkrcrpMNub35PdHqQ6zHc/1WQPxtnqBH8jAd9tGaVYv0XuLIOLgrMby
yky2AWcQIUJq+ejenGi3oxz+vQad80BXISmxfQciSRIDX4BLbS7FOnjMoD8FGJoh+Apc8QP1S0tq
up4Zeq40KIwtl6srliscFxxtlHK74YfbLsRszl10cPrt7W/ff/D+B/H1dwcXv4k3fx/ffm3wx4+H
N/40/PpGfPd1WsokcNazAS6/2yiAUh4HJW9gtubpan3K7lc+HXx6VW+tN42//nx49268cXNw6daD
S1/ev33qwR/O5XTAvYJINnqub1RrZiZ+NAPhyvLEWmKYDjbvP+Ny1oYU6RshZx33cIOKVq+chHoZ
07hfRkQFkU4RtFbg9BtJZloH4NeQTmmO4rCFyUsLs23ehQig7Yh71KTll/GrDFksA3hqqExUQ9IT
a1Wrpp4FaOpL/bgarJcZokPNglz9gRntwPfBknKCBKyaVyt79mE1Rk0huZG8LaVvEAzhvpK8Valc
esQGOJ0zx+WoaEXJBkkhboVr0W4ldp27kpW1Ct8/gpY124HDjj5C8edh2mK7zUJZJ3YI8dq2pRv4
c2u+k5DSrELT1FNfEIyXF7uAS50gMwExgWY+ktVjNvhN+TlXPh+1youhW36RcQE71EmtUquVq9Vy
bQ81kRFn0ZsrBSFAIHXeGBGuxSPfQF+abTuUEWdNjUFjiUfMlOxw+pTEY/I7Wy0VxLLDaHCOyK0l
PXHv4RAC0pmSE0k2vPVxvPnn4b0P4GF46wRkA00YE7ctEcX5+wOfFbYDwpCRaHBgDgc2gR/uhkZR
JUhKPY24PjlCd1WeAtx21X5Mj05RRqNJNEsMb3w9+Oz4YOPi8JO/AFFAYg6+evXh1sbzS0sHCJ3V
Umfpw62TD7fOwOTta2fjc289ePPs8MYFmud4ZcJ0pYAMa5UKrU94WNN+Ywyed+L3PiCF/UeiRiyo
eDKTXwH5hEGVIXRw6cPBFxc0ylowSSxePLAPLHtm/0EyR/R7fFCOAPvopHrj0BWqXB7w+Qrm1Hyl
pr6fUt+76FHsGjjWs4j7mEZq8ry52/yRWd1j1vaY8zVzft6c3310ArnCMhCDBUSxkyuamPcAAIyq
EVQEiqmQTSSDnygemIL1I4IyPn82/uc7gyt/i6+fGVwAcj49vHMH4+HWieG9N+OPPolvbkJUxBtZ
sE5Y9FhbMAmhPbIbSASWF9iOUHQDQmyniUkHFW1afuXaDvMFqEGwW9KDPD6/wBQdQ4MrJwcXNsjP
D/5qP52WXPn6bgF7Md8xMibJV0g0Fls8e9QCQH8wtfx3wCm2xEolERpu+11m1MYqtuIlLTVpeHQ/
Udw3B8XIVKxlqpJMOhiCBoNEvdU9FMkpA4+PL/BP1zSuE3LVROExFhoVqzZfgsYLEehg22VoAjV7
TNoIkNkDLzVoJ/I8mhgNauGg0k3linppUhH1elDCM4Yaedug2yc3sItQzcPg2tV4axOT+sJG0jPs
JPvZGuMEyvwaIzaB4r/mBpCLImojH8MO4DURBj7IBauhstotD2Z2JKySq65QLX4fWnnXE9ZM6jjf
7qmAXh6zaqVe6BRwWsmKfIDxkNFzBVayZnAox4Btz4Ua10g6U6O0AG0KDiyvLAilSgMDcWHd5tjm
YHOZzEAxqlleACWxsYHq2ws9JlkyPCJc5uihmTSicgGrNtNKWBipUxrNKi20dMo7YAio57eZoUWY
HiiheMb2+8b4FNNx2/AWgeMq1tWaR2enbkPjjUvDq9cGH26BU+Ot4/Ht24VmNAWhFQReooV+/V0y
IUM5b1mSDxluY1Ge+iAlAFpQU0eg5saNcw+3LmNF4oaSWcKq+F58E0roBW3h9rUv4uuXMXgVESWG
FXyTuD/vm/Sc8Dh/6GUJ4kk1mHitxUm728QIpSXs7NTs/GuHQxbQiWFIoaRtpk88Xkw1dopHv4vL
pjgoOy9l0fAkl2Wq3L99fvuda4lCj/VdadwjhcpQyLJx/VJWK6iYdiNIM0AvKC0Xl4+CMEdz8Uef
Db/8WGmJYUWtlwI4DaWmQqz969jx+M75+OTZ4b1zw6tn9Nr47TPDU8e3j39z/977gzOv3r99Nt58
F5aD2ffv3EMsLn2yvXU+/se7U7q3lEwXScLFxGfMESTwvT6wJCM6MAnyBQk94FccdH2HIexgd2ow
/AtBW6mZdIK54ByUpvLT2eWDPkem6KnObURnSc1oJJVEgVuEGsEf32gUODn3FUuzMmVUl81qdUpp
nmydgnXxBDrVsYWPY83M9HxGif8hu8KK/4lbM2MUjhb0XZg7Suw0hZXT8OXIZfUJz2LFW2hBI3fo
v+5aJvn3rTfizc+T8FYG3f/2RLx5Mb576cFr1+KNN8YzOafATvIMcyJ9DGWkBVFsd01sDzowF3Z5
UgAruOWqLXGhjuYe410ggSN8jF1NCkTJx6vf0TR8teC6Xr2s/y2PVq+sNPTYVDKpT4Ci71QAiO2r
14fXP8oIDwvQub8PvjoN+Qx/ty+/PrhybHDxZnLlc/m4YoQbehU09Q+OnRyc/msSFXhVyGXjCE02
ttegHUKlaD1TxaTjTqcTYTCao3KO1quVSvE0TzGbaR2/ofHTHTetJxmV/DdpajXN7B+TAs1U+xBz
mjbskd64WtmDH6wb2R/8egVI2IpkuwRnpgAc1cNjkvYQXqSmvSumoaEdZa1hEyrgQFJaUFOyvlZj
leKmWnc9lHTD+jCIhRjwCIAe1D2ICXFoe0FXVZeEaXgQyOLNk1qkRav9wSNJI0vrmSjgwnTQ/D8C
AaE3bYtRno4f3QqaJ+aVpp/lFIJo7hzVlUTfyOn7NVOZOpq8kyxhX+6xrt3uA7X7SIfEcUXo2f0y
lqSFpJUHTYntrdt9QSLBBPT/HbzWJ4kyViYShTRQ/2Wqk42uLNM1fX9EV2YpobNKieU8nivLEL7w
8ne5K8DkLh6OT80oRGTT+3hbBj233Wz1wbpsdn6waH6ihYmKWUydn42SWQl2VypJx+SN+QMPKMyh
9e8MJRbSJxyotk/dGhx7NTtQ/RtQSwMEFAAAAAgAAAAhXJwwRE/bEAAAWCoAABkAAABzYm0vY29y
ZS9yZWxlYXNlX3RydXN0LnB5pVr/c9RGlv/df4WArWuJ0cgzxmbJgEg5YILr+OK1TTasPTulGfV4
FDTSrKQBDHGVU7sEOOJADkiWQPaSWhJSuSxwl1xgDST/jDW2f8q/sO91t77OGLvqpsozUuv169fv
vf68L/Lu3bunLMehpuRRmxo+lXxrwTGCrkd9yXBMyQ+MwGpIluN3aCOwXOeg5NDz1JPoRdroBkgl
NYDQMo2Aart37x6y2h3XC6SW4bdsqx7fBkFHa9gWdYJo6D3fdaJr14+uOkaQnufR6Mrv1jue26B+
TOovxpcBbXealh0TB1Y7vu56NjDUqOe5Xm6sY3h+ns6jf+pSP5ay27XMoaGpM2+dmDxS+/eJszrx
/VaRmiNjY+U3pHH4HNl36pJxpGz/4ehk+dTsxBiOTY7//sDR7qX62dLi/sUZ8519E813S+8GE/S3
p9yFtyZ+N/r2bP1Yc8EwJ44Og8qdhbp7sdg2HGOBekVhCjI0M/n2qYlpWHErglPjJydmpsaPTLyG
Znb6zMxs7cTkyclZfWRvuTQyyr6Gpidmp8/WZmbHZ8/M6E3PvUQdnwby5dHSAXV05A11rFSCvxH4
2wd/o0uKmHF04sT42RldLmljalkbU4aGhkzaBEMF3iLIILsd6hnoKapJbWPR19PTlMqQBB/wk5mW
4YHbvW0Fx7t1PrsiBZ7h+Ogj/IoZYFgCifB75A34Hrt4UXIde1FjfKao17Z8HxcDFqblgY+qoM9L
VJWartc2Au7EkU9LTcOyuW/DDXdkXNqiJvNd5AnzJCY5OL0k7+WbUE+5DhXC4welhYldz5Hi/cpK
/JhebNBO1vO047OzUxN4JRm+xIYSdvixmnxUa7gmyOYGuH7aSFIimC+hPBXPsMB9c4vKmVXPTJ9g
i6qnZ/hv6iBykdgsEF/pE+d1i+EB03yb0o7MyBI3+FMXzFDrLAYtVAlnCszgsGqgbrRVzXKarnRI
kvepB1KrsgWkdwy7S5moMtl8sLzxzQfSFOMl7dMOFH59eb/3YHnt1ce9O096H30gHaV1y3CkcrkA
vnGm3nWCrjRS0kqjQPnRxpNn4crV9dVH6z+8WH/xX71rnwpWJC+t3+2gr1Gz5vqyZYJurGBRFeIK
EduWY7W7bf0yMdmipCKXy2pJUUmXrQv3IyV1VFmKdhzxiWwpGKAZccSjWrNr2+CjjZbskXmzIL9Z
mdfgV9lLcmsPVs/aiys7UMP93mdf9n64u/Hkw/Daf3NNrF+/1nvwPeH+ChgY+HrQ7dhUbhsd2XIC
VRbLF4hWIormd2wrkIlGlLnKSFVRoh2yqYfEvuai/VZfJ/OOrXcfrXflWtqAYNLeg+/Cl8vhoxvh
4+sbf78SG7Ludh0TzOdRw5ThfHdcADPVttpWoKcAUKiz0eo653x9rnowcAPD1kts9EILAojERg7p
bGqyETZDjxhrbBnYt7x/bGzffr5OoVxkc5UEBkBFaGk2uVKHSeeyDH3N6HSoY8rsTuHSFHSbOmIk
UjR7cJjL1K/T8OYn4fM/h7dXwtU7Gz9d2fjlavjwUfj05ua9W+G1n4SZIT4bep0Q7T3XEux9/mRP
OjhLbGtGO1Akjm++BJMAciVqePaiNHH6GCYDAVBJbpMZGED/IERnr2k0qGQFgieA3KTTcNvgVgGd
RnLfTYKEAghKjQCzB9NzQQmm1HAhD2EpBs6NIwEHeo+2DXAzZ0FfoJCRBF5iZALqWghahEM0o27B
cuDAA2jFkzSxSRs2hiJdPNNglkyOuE4AqxdPCOaEKGgIyGoYR0GrEiCGJ9QGkxAyxGEYMyXgBwdJ
jpizyagqyKecBo3HVT/wFBajohHN8k1rAY6b4IqCRm4gB4sdKse6UBCbYRU2Px49XFIQYuRIDiRC
L0RGjJJ7ePS4D2HSASJrQRl9SI0XYo65I4H4TqIVxTERdmUxFBmLkxzFCA5I59HNkyAyGDcZaMbg
+SaAJ581AH3+8ffw5U0Of+HNZ4iMd6+RjCh5IMTZA2BwH8Igl5inyDW/4VmdgMU2pqis1DiiASUA
5gUraMl1smfXcNf3huuWM0yd81Id8uV5Z08+GZTOk0EbWXu+0vvrE9jF5lf/XL//eP3xV+u3Ptz4
y+cJrAf0YqCzVcGzIKOQSTdoHoj26l7wdVSk5ZiGbYMa/zjz1snaOxPTM5OnT+lyv1KV3xAVWYL5
tZMxLiFSIS9ll15Gp2P3W7JNc8AZA/aV3sjmF/d6yx9wY/W+vAoBbJC9LhPhMaSCksyVqirxW8bI
2H5SETWIxu+5VbQWvQgHDDJ8GUJ3fRFKGFJBudnTpcQLreZiLU4cwSEcqwmT1HhI2Def8KRVE01S
DrM4EWkoYXG4vH/fgdFBevjHz+GtFchYel9+tfndR73nV8KVuxzYxfbRi+KyR5ulWK0Y3uJRlgO7
3qLc8WjTugiFQb1djFcsAlgBujZdG+ArdfJdN9BF5aVNwa/MKZSDYEb3AoAZUgwTccf0gjB6EC7E
o2ivGgyRmLGYoF3wrIDW0PwyL2oKRCKFpKoqkHnIypCdIGWGSWkqk3lnElUA964d6El5qHldR55j
Zdo5urhAHUDv4ln44kbFuyZB4JWFdOAHxUmicsHgGibEhRXc+pwYZFGqamZpZmqn0w302D0aRgfl
rbndAMdnvS5VMVeGe708psJJhwRyanz2OKm4PhzNJmpdJSeO1MZPnCAVcoQs9ZURx8DCp9zgGOY4
zD8GOczL1fDpJ9xtwGE2nnwQPvs6vPJMStQgciqWOGHV4uAjDvTgFVABtpNgI5yY61bjRw1RJKt6
0zIWHNcH9NMFpR+A13iF5A72nS8r4Pz7kEwgetcJIAxkIo57wXnfsm26YNjvWw6ArmW+33XAld0F
B6o5iJ8uK1Lm/jjvzTvVvfP1s/N1oiYCIKpM5kqYJKalNZUoREIU5Zlo8ayU1h2oStQep0FPMzPH
pQNaOVNS5BT468trr0tmrxNl6PVS8RwuY7+H/7Px49c85+1df7Tx1Ufh8r3N5evr394IV2/GmS9r
YdQi/+MhOjAW9FTBalsO9bOxwPAblhWFNPY8QS4MV2xoi0qlP0ZFvaPzUdxgX0RlXACRB0UwvuE0
vIUPf8wAPAMZs4abiRhpnojBElHLyly5GifIxkJc6fM5u3T42hpZ2Yprzz/mGYE0LXYAcQYIwC/W
ni9vXP1RSIIQ6+uXl+L+AMqDJR2Xq1xJlTxMS3pOZfKcUWyWim9UL+8fXVIkSZ4bL/7BKF7CoeSy
phWrl0tqeaS0pHDl9ZUSjCHahV3MjVRRCibejlTc+/Il7Daj5Xh/cxHLqs6vhHZFnE00qzLybKA0
47ATX6kiMpq6nG9OQUAGFO4fZFFbybtvzDEboeLhKI1v8trFMdqi8kvBQUePyYeRIK3XDqTcNX+x
DQo/JyuR07NR3Ckf6mDyBikD/NSwv7RlMcaBuHfv8eby59zXhBk+vbr24qdfX35OCihAonyh3w4r
KkXc40+jQ62zfZGZ4+Ogn5kzJ2eIyvIJFi95fOwjYWFYZekFZ7aTjOZg3sh6Dl3iOUChxKcB94N+
GBm8kvFafCg6IIwnajOXmCV2S9fqmVRtl86dFKmqWx7rtKp7n/wVAByO8vr33+TUDmINcskt9gAJ
vT4gx+caH+TZmU2kdUHOkwLOnYtz1uouPdH5lvlweO/bdDIMsCVQLEIr2GI2K06YwjmFwtL3I4gb
930aTIteqZztebOGYPTsOOCpDSlgJXW8+JOaIJd9ajfxmKvNjopxRW37C2pUGjv0AnBP90wND6pl
Pd161+CGI7qgTmuL02t+o0XbdJdOsDD1CbqPeNL1qcfcKxnqwE4vuJ4ZnWIx3IIcIaIcMKxRx+Rl
GdGg9G5168i6wVsAGpTAJJdZbIW1m/f+Ap638eyHjVffh9eebn7xt6jBzX1y7fmL3oNViOnhs//t
3fjP9RdfpFB4j3SKNaThSF0wPCygO65vIWRJDVA9NtcM24fyXQpaNDYGFPgGmlTCzWh5VMnZd1oY
jms7MhVkpGdgv8XxBUwFK1u+SliKcg62oIAq5BO456ijk0hLRsfS665ry7koyAxYGR6G5/NCz/Oo
3WG20+FsICz03Qsx/GG2vD/MUgx0Gq7COpZ/1HvtyulFd7ycCcmp7RrmcDa9yU9IyyKiNWyUZSV4
LcTbMkxz1wkfPA2/WM4E6MRI4w0sB8BARgfOTIO9dBh2wQWCoo/ttDYE1R0ZUiXvFrlfFsc7VvGd
qIAmI6WRkWK5XBw5ADRHDDh5RWyEea4NDx232MAhEne4YX/JuYDdF3TyZqQtvfxvUHnqpIAv0DT8
GpUZomeOODpORexwjox3oYb2rEtsZ6Sqk7egToATQQqMMAYiI8DCN5BTp5KVwzlvr3ct26xhok49
eRD8KRo+zINgdEjSJ0T8KnEtt6/ECumos9j37iRjI3zTKaKLaCAP7DXOLnYo6zRu4yQbv9wJ7/9t
bfXD8Mqfe3ef9lYeY5XA4GTt1YO156u8RFh79cv6nW/zlQfHhYH9ctE4ggKbNYvjZq1QtyLamzt6
tbXNDp68CG9+GlU413A+GBmr7OQVmFIgrHDKVab/77dcA7qC7AXJ2vMbG69e8XogLSvIB2i9eXVl
48ndQQKJXg9rHx1Ohf7tVLBVo76/JRodqZo4vzKcO9UEF7Uc/qI1SlpUdLQoOqscpcWdnsLsGK/V
RtfzQEU1kY7gkFgjnYAngShf12yD6PI2GAtVDszMQGay1pbtW67FtRe3w9XbA/Ay2kBUlIJXptWC
yiuQBN1tAzQSEK4TcQKg/hDP+QGFgRrmCexwRtJmKEzPaGIXRfTajxk2XzlD1AEsEwjcTzmg0M6X
05h0b/Nurffp01xFG2MEV9KvL+9Dvgjwsbm8LGGDXsIm4//dAOeG5DLZXc4zWBjLtuZBGqx8lUPZ
4dzErbvwSc395E746nZ4fSVOdnv3f+x99igGtY2r34X/8e3mvZX11aj7yVOArJX4GFHnqspBtFZc
sQvXSr1+4aRQJfrBdmArCue0h2HNYwEkIqJzTtmKJ7sWUqqmBdFGEvO4uMyhFOTBhN0uMbi1sv7o
KaBQ+JC1hfMlPOMxl+de1XFExM0YL3J1dPKgv6Sby1SdffXl3gh5Ug0QXFFn4jBJssVupB7UHmbt
+PooEdoyiRKfDHyP1E+CtXc/EV6WDiHVHKeoHkq/9t0ueR94cDIdVREJ+or3PdJUtw5xPsZoX4LS
gSXo4gAUWaiV3GbTakD+HhNKELM06bRtpngxZypOHpXGpybjXMHH/68Sb9MkloBBxt8MqCd8j/0r
C8CmbTSoqaUl86zzAG4JpFrAC2xt20xGA5ItrCkgRwGOuKIoeCSBlL6Wzu30PHCKLJyHba56sF9V
UeLEjr/2k3PZN4sPpJAA/Vy5muYbp9uQ9RkL8CSvc5acZIJbUoRkPC0Oy7v0tGtsc9I27/4Srn6T
Karx09FTB2WbHtI2K6zffwyVO8Lwz59htvb9N+HNZ5u3f+59/HV6wcybELaPg5DTtNquKZfc/aVS
9lSBQLqeP6BZx+9rAaXP/nD6pCuZZpTKFs+wyvWFdsoobhv1tw0HpTMxuUebEDoBTfUBoRzcCryn
OQzUPnca4QscMdz6e7AGUS8vpUK3YCfCO+bdCmgPppLKtmuJdXJM/JbB0oPXrg2uj/+RssXU14q3
Syd8NtkiW4hbzKOlJcjsGO1Ooi/rIfVu3lpbfTj4/SrTCmo1EqDCf7GDKzypxuxpUZNU8I3X0tC/
AFBLAwQUAAAACAAAACFcZCCD2IIVAABWQAAAFwAAAHNibS9jb3JlL3NlbGZfdXBkYXRlLnB51Ttr
c9RWlt/5FYIUkRqrZUMgZNqrmXKyyZIqMkkRMrUzxtsld6ttLd1Sj6Q2ENZVZiYOeBfHMLzBTGAD
EyYJdjahwDEm/i+7Vrv9ib+w59xzr6SrVredbL6sq6BbV/d13s/es2fPe5ZrTdh+0XPrZ5RWs2qF
dmAov7WnbF9peFWn5tiBEjjuRHHcO61UPLfmTLR8K3Q8V/F8HAh9rw5TbH/KqcDaPXv27HIaTc8P
lXErsF8/uKvmew3FcNzQ9q0KW8jf+7ZVLTtusxXqSmXSrpwsVyy3YtfF+gk7bFpBIB4nrWCy7ozH
j2HYNCp1x3ZDMfSvgeeK7168rmmF6XW+Lb4FrfGm78Gl46mh3WjWnHo8o+XXYaVh+77nZ8aalh9k
5/n2H1t2EF+n1XKqHPog9HzAs4A8sKZsPTjjVspVx7cr8PKMjufC4wRuQIt8u24DCsuh3wrCBGmh
fwbooQchUKFSDiq+0wwBjTVPr3qn3LoHSOUrdaCiUzuTOgTQaYfl8TNAZX3ca7lVGydbVZwZAGnK
YasJ4O/6x7ffGfno6PHysbc/eP/Dd4+/f+z3pnq63jz0+uFBZAbghWKDOEfddfTd9949bh7Yt3/o
wEH2365du6p2DW460apbvob4L5R2KfDXNDkxjA/gk96wF05NaRpOUA7ONOqOe1IrIHO5XkijiBoa
ahoItlaAj3LgfGz/mh1Om+OfbzmBrfzOqrfst5Fomtr55HZ78RtlUGnfu7/11cX29fMbz59urMy3
by63by1tzdymkfaF652ns9H51ejBl9G3C1u3LkUXnqp0OUB5y3eVJoeLkKoR4nXGuEGrEUMowKb3
heEgHomnGozzQ/s0QMJWNaywMgnzjFqrXmcPmq+eCPZpo1axNlJ8Z6j4q7Gzrx+cLpwIBk7s+83o
vwye8E+4YwMwRdWDGIWIMLYaUZXiJ61Z2G2yF6P7x4y6d8r2tUKpG1ebS/c3L33KMfbhkZHigUOv
c7xFD/6r8+Thy7WL7cWvoqW5zhezHDmgMSyzSRAxvtKk6+BrpJkfBqccIPm4+sruwVbgD4477qDt
TqGSmDzhvqJk2EqZUgv9yMopuPjN1v0fNu8sRQuXo5U/b97+JA0CvyGKhtktLRpejWYwwpiJOjD8
lquNqng1VVeLRdeDF4hP/uRX8IsLqA+BvQtjesVqAovYZa8VgjYzj/stWw+dhg3P5v5DegxH1x9g
wDyrfjBy/Iha8gID2AtlQlePvlUeOXpULalvqdMxPtk1DeLGile1t6Pgm3B/pbP8uP39tfYXM+3P
HxIRZa5GVHDGtkKvATgiKrJ7IIp0MAO2OeQdHhr6yVKcc8No/vzm6pdAsva980DE6McbGyurm9/8
LVp4tnXlx/Zn4nq1qu5aDdsUKtlonAzwu9b07Zpz2lQNdaBp4JQB1QjGG0VVBzUHnAiKGUwCbQKq
MmEi5D8wC0at6jVtV4MD1FPjakGxAqVWqhmnfCe0iSmGa0at3gomtcIwzkdFrcEQ3ML1tAINViYB
L6lRhqZCfBhM8e1m3arYGt5Rb4IikPS9Jt+05rhWvZ66LeAS9kDcGvZpJwgDtk8BuaTlMuyyZ046
EDCwloHme16oB5NgKCqtENBPNB5lfJqmGc4rDKoZoTOA3wt61+R4v8IYPy5wqnYFNBrbRpyyswMs
0CmqvA3nONJV8Xb8eUBVsrrBQI2hFgybSYEmcEAuBDdkGrgSVQfdGb3S8hmeS4JHJVuXTCz8Q+aF
tC5fDUUzt7Zm5kjqoluP2stXoxdXorn5zbkLIIHtO0/aN75Epfkff9l8fnfr1jyw/su1O1uLM52/
nYvu/HVrZqZ942ln+dnGi/XNq486C4vR/DXltSHlvz/9i/KaAvoMd1kEowQ26oUqIB23KidbzTLi
WEPFZucLJr0aVDnairQsUHcsq2ltQldAVfviWj+5bYKgApNrxNwB6ULGwWXvJHti8kPi09RJrwxn
TCzc2KkB8QHEU4EmnjiUOKaY8RwDGF9TUQwDVTI9DrANoAA8Sg2X6EodLsG8CJBYNlRQdpvKge29
B4K9vTIL1GnPfx7dXRBKCjZzwIk6reOt4Cso9FYD/NyQzixI8tx9KV2pOhW6EzwlkKjsZjX1LNt8
GuUS54RnmmwZTSS1oBYKsCnbe9zz6iXJ1vQHqLP0LSPmZ+1z/xk9mE908sUftmbnZTOB0MR+HXqz
NrGXTkylZxQPW4r+v9nNq8MZNqUZffxAoSlBowZefQokfreJeyfPObwrAfpsOfrxk2jtT9HKCger
YWKwYKC3DFpTeKpMVoir8LUqeWrxDRuEf65zVbhNL/XbrS+EFDFMf0bS3YVywLWZEYGE3zij4bDE
XTAwKnhiTAGlJnmACYhsHmOysQJcnT1ytTyWc2NQYJIQXL4JqgtuDKIPim1j/e7mtVvEPwAScBSH
AVW7yRHF1XwinTggmPa3nmv3kxKcq8dSgk9pMdltit2FaYnlJJmaLyg5oKYihJ4inwJhR+imiQm+
6bk/wnMuskO0I4MQM+qcTz52mlpjNGbWMb1bL0mcU5K8QL5Xhm0kbz9Bi11H8U2LNi0vbGdnZP2T
Z1Vo+8Au5W7PHaKGE6CnkNiZrMeVtzbthL0CLjMzkWBcgEPHbUCnrUy9Zhwy3lAmIWYH7hFOC2h6
8C6HwZbgeDhpK9xfYHygtNzQa4FHUjW2Z3q6iik5Vb15rReBJEaTKARG9nUwsjKdaOEvSBm+4Q5p
wWcL7AvLUvHAB+OWJc+kgONehW37+zmUxiryuaTJY+vCB7eBm6s8Fqukxayf55PanXvsaTGD2CXX
5NAK2dAMyyYW12I0iqzJBDiNl/gEcTYnQBfGCUvJdN9xQTdGz74j+DZW/r39zf2Nlcft64/RgZVD
aXBawUsFdxUzJJc+2zo/377+bWf9Uuf+RQWCr/+Z+VOKHbjLgHRPuxDvWMAmnNJMvdfr2SSKnkN5
naW/ME/l1euIBJNtlLjzKFDZOaVs5isT0VBuRhJ+libokdsZZlmOTGZHkrHhKpCshx8gLsoTmNxS
UahpTNqnuc0A44B36G8cWBzfXvx868YTij04py7cjC5ejyMNKUPDTLGkXIbt001Ai1015QhMPl4y
179YWI/+HNolxJdkheScwrY2Y6cH9mESZrWzx3aLLv7JsSXhiT+BROYkl2L5zhjL1LIYvygIOdDz
rGfWtWgWzAyfyEhN3fwV5TjYJSR5bLXAADXs0ELeUzDnPwzSWQN1M6lYCookmDGveYblSrxWiIMM
KB5yGlmUCtZIMrSxkMAbGfbdpmA72YQxD0+8ytoqrjvQAWRoB5m03AngXFICv6xRiGmfw26Pb0aL
j1jy82L7wiVQj2kTAYIH6jGavUC6VBgEytjjuZgM5DER4jEnKhrUxDwj/uJ6p5JR/O9j8BuMVljB
/LdfwxFN3fv7vY291eN7j+x9b++Hf1ALA2pRHcDSg4H/HdSYihktvcH5jROSgvRUam+YRR2jY0lc
q5M2k6PaDIdlQjnuVOFe5lnyRUqYTnIKmKTDZCr3YkrNGNnTvV1ROZaNJWpYYh8CKO2f6nI6ml0n
kRYzLUzdi1OsBwgxrCYyBwbdiTItp8HLxh8JiEw2ZCi5Mi33ADMPrmQ+B663gHHZGU6W9IM5uzGH
D7xZMSMTDOtn4yiihGyg86RLiWVX4iivJDbWVW7lQeUKpVfKqM7p1KlcCuEY7uow1uHZgemchO4r
yrt0ALnfXqOBupL55aAx/QDUk4carDUeYGHORVae8ipUvKxYrvA3E60WK1IfC6CBXeX8LmfG9aRy
0MekcXpnyzDbmniy3eBkkYJJR34pk4Z/3FlpJn5KPif1VbBObWcqu89FM5U1+aI/wS21T1dsMDVv
WoH9NvsKdEol57ZPO/1cX5jBlnZVu80NS2Ny5Z1iS4xcKnUrCCCkO2bTAZpcDTaOHD/+gXh3BDi0
bvtcg1LMQ2/KfLoW2PUaCPkf9RoQFvSz3ggm9EkgCjCk7tqnYPe+Kel/csIjrXFl5IN3lc76VUwy
n5+Plm5Hly4n7uGly9Hs043n16PFb6O7M9HC5a2Zc52l9a0bS9H5x+35JTWBi7Y7BufT/slRKSDK
4PQ4YblMl0fsttI5Bhw1aNSkj+RVq4nFSCPeQdy/s/w8Wrguyo4XEImKOoCo59sPqC/X5iAuiWa/
idZmNp5fiVavgBHefDRPAUpn+RoAvPnlufbiHL2NFpa3Zuc3Xywpb3luiNnpEjK7svH8webcRTWJ
Qhkhyqj0kJZ66J20XVNV5ZAD3qQLmyr2IwSlwUGr6RgTMNIaN0AlDfp20wsG1VyfYuGraBbwvsKR
rERLN9vXf6DLIgG5GHHig8kZqaBYgNEBs1R3SJMNTrlVfuAA6Wn1owAcnpEJgJDZJ7ler6v/XKTz
iiNNp/g7oZnVA0MHDhT37y8eeAPmvGWBUim+Re0d8NL1ihUcUsmQAfADpqa+qiI21N+oqP5gjGUC
8BmoA2Gh2e2ICAwynJY4ZKPqSAv8Td/5mEEE9kp904bQzAeKs4kxo1kh1gDDtHvOynoZkRtvOfVq
Gct8wFyJZBYMVvnLTD7GBQ9JLVDNPwtxFfe1IVYo9LM+CVMX6U4KzddZT0Jir3jsSG0bGodA0njp
NhOmLhiD4Hn26ayoZ+XRPm2gligorGcEE0vpnTVp64+OHWWL9Pc/pM9UDw2dK9RuXw3TvnGv/f21
zvpfIcri9wEJjZ59J6RujvoENtaX2ld/kCvymWsCJ2AxhhlU3svRU6NFV+aj1audp7Od9fM5XRqI
ak6PVJ4lMdUcI8nG252EUSU4+9eetC9cb99bi9YWEPBrF3YEHC9wei2/Yu+kRsfDE1qQik6m8Ha5
iSM5ZUSVE+FtkhyeVZnycdDkqaXulh5dRevm2ijfcI/xupBudFPtUGNnFygh7yqatJ2ujvuWW5lU
p/XMuNhzOu7hyfS1jI4U/2AVPx4q/qpsFMcGBjPP1FXBzh5N7zxW2InZ4ym71Uuk6YliSYIuvh1C
xM5g8TU/Tbwcw7ICISSHSTaez7avLrcvnms//gKYQjlGzVbK5qPvwc62V+5tnbsiF89kQuSAlksJ
bo14sqIM4xP9vB8d3U/HtVLi+8sU2rKR6v/DslumhJ1X5uxZc6MkShzKKOIcTKVYZLYw/TNlK6cm
bRfYSWk1ET6YOshSL6weYNURpDPgWdZqYFh4VQCru+Z+HvgG2JwlFaxIjIdYOM0msAVjAiGZkvFu
5piyKTzcjgUwWzLOyyw+fsBLTd/dB48JfCWe+8/tqaKskJlfVRT3S4c+PGe6fb2Rs04q9kk3oImm
M0y2SrydZn42RYqA8G1ut4tO9+pZLtnRLhT3axJkO2hbEeeQnNds1I4k3ilgRPeKiKDBDdVBEZho
ZLiUU1OuKdmaYeY2sbRcvr0hh7HIpqnDwsMlmJuOuY03O0BnykqMLa5jA3FowrIBdZC3oQaDNBrn
2wCArpJvxkhMjWLP48AJQ/5UdVxc2K7LgdQ+sC7FqNSNkwpK828JOyNs8JFyKNg7U4oJaLXkVWS8
Mua6MR8jDSY5YRS+CKt69uDQfv3g0Gvw7+C0kNeEeJmUZCoYJsFLZkoRfWqDpF8Wk32vDnlDhw/3
9nwoFGrf/TO6VuuzW/efb6ysKsCmCjpBd55srDwEVyiFSeKc1HkpzY1JSqepdeXhe/sDY2f3D+kH
Dh2aVinoylNU8k1TfplUgepJNr5xihWZB8BXCBMzUcbuOmrDkbg1T3FKXkDc1UFMl7UzO9BcYFAm
HNfMNnNrwK1MM+haribrpZgKehoLfXpRUfRT7eEMT1n1o/PLCPcGE9yiaNZbyfZVnOmtDHKDtUSt
mHmaRt+3j5AktyixLaRmQL4daVWFeVC6qNPrrDCiK5kKM+2imJJCpqW82sAKp7U9vNFPtP69XLs9
dZZvPf1y7U57caZ9/dvNxz9Gl+aJRYAhYNJZOgA7MibUsek9tGndq1h1neslODy/E1HPjIutMiUl
UdpdWCZvmAXpfOtf01E8UCcYsAaMvdTswqQqUytMU1qSZu6tr29urH5GC2MYBaMzu4+NeqmaAgoV
aj3JcctSgIEAkgFLJUGhflcxg/ZHOuW13WBLckFUFZOwCH1cHJAcXwZXHJGm7i6S/7wxNVM6r+05
izeaRpryy8D26ubaKrgqqiAsp8XGyoONFd44H80tp/K6M53zTxi6+aGjQ9RNlHoECoin/WOcDN0b
0sGopkXGmG+e5LWaluOXBbZ/klSQuAETmNLPOuR2X2VQye0ozv1xQE7NVBySLpKiAuZX69uHm7Lz
MeRUlcu01opsAdW2MizWVbLnbSppBsprnElbuD7FYNFz1KsinAtsD4DXv27PP4suv2B2UFiaSxf7
wdxHtTG3ylSnVGVA3KBX20JMpXTrAt5caKPYud+WXsS4YDE7yw8JCK4v5W63ngCJun5PIqURjVeM
2TiZIvtHyqvKkHf48GGczOqiPYpzvO0q3lBWvCnagG4F+Ags+pEKF/97K9HyD8Sn1D3D7RZVsTTY
X2TQvaaJT6AJBNAwYqrMwqki5SXZu31s/v5SEoqxFYK740VZjdBjHdl3tUTgsQC+2mo0A40b/mSZ
brsB/g7GCiqOw0v0orm7+/LFuCooASG6LHrchkfiOdcRTUU/4z58aVFkW3aye3djEut02/GZhL0i
96jEiV2NS3TcWP4eTJJzLksS/jMQwUuiKRahlrwexOBFudR0KtL1ms4xVWRKJ1kl57h6LMb2fTWR
x7jsGgD32lUtnagSODOc0Pax0QGdYFbRJRp1VWn7/PiQLS/hD10dt2VLCxtmV+oqu3Ej08nDfqLX
w3jEy3r0CjZy8mLpP+IC+k3agKr8m8Kt4u1PSLny+hluT3FOd31eB//uq83PH6oFVl+7E306G136
WmjreSkHRCalW7T5b4TtFK2YqTE5VYa9elXOVqS2i/3+5MfBqZCPFcYgLrJ9lolQRtUB2EwODgbA
8ihqHHwiLbvmZFw53kxGqVvw59IerQjssMJxZzVauq1QghaQAwaq8+zzDrhhFz5tX11+uTaXwgwl
7uXMb/K9Z+qdY/LnpM2T3fPCZkJej3iZovj0b7A1/uNrg39qqlxJ/aqz/JxCcEAMZsTnZrZm+Fu5
vAqI2rx2a/Pvq9S0jsEGbkNL7wzScUq0cL39FOKjOaRdbuaA3TGWof9bDqFv8oCaUXZYpNGpSNJ1
0VLXjyn7p+Dorl25wQyfZosc6F2s340e30RuZDABZWiEdauxUI3Rjboz8KcD4CZ+eiuafdi+8TBa
vwHxAlVKouW16Pwqc0XSdmGbH4XRRa7Mb7xYjPH4v1BLAwQUAAAACAAAACFcVc5KqqcPAABZLwAA
EwAAAHNibS9jb3JlL3N0b3JhZ2UucHm1Gmlz3FTyu3+Fkq3wJCzLk5PsDNqtANlaiiMUJNSCmZqS
R288whpJJWmcTFKuAoosSZFsuJJwBEjYcCzLJoGlyIGBH7OZsf0pf2G73yE9STO2uabK49E7uvv1
3f20ffv2R/qxM+9TLUnD2FmgpjbvtBf7keYFKV2IvXSgOYGrpbETJE479cJA6znxIo0Ta/v27VNe
LwrjVOs6Sdf35k3txSQMTC1MTC1yUj6UDOAp6fZTzzc110lp6vUATb/vuaYWUwmCxnEQmlpKe1HH
82EBLpuaevrIk4cffeJg6/FHH3r6wNOPHnzG1gmAbcdhQFMrCYmpPLoD+F0c8X1iTB04cvhQ66ED
Dz925Kln7J21qakpl3a0uB8gjhY/sD7vBU48MF2apPALT2pGYegb9SkNPnDYQwHVvF6vnzJ+RbG3
BIfR2mE00CIaa663AFsbWhI4UdIN0wQOlzpeoOHx2JauE7ua7wWLnHcIliO1BbOsp+C/IMSwYpqE
/hLVjYZCU3GpMmE0kNriNKOf4fE6Gj5YXtJKBj2kQTfqHcfzdbL20xtrV86MLrx29/vvhtdvr319
ZfWDa8Mfzt+9dXb448W7t+6sfvXZ8NzN9bd/HP3jU8LBMVi9RdeL9V7oUrsWPlCrmfSYl6StcNE+
HPep0fBcCgxOB7ZktByQJ2ykTrxAUxuhzcpJSS6f2xrBG5EKoIIwleAYiYkuhIofVDjQ/LIQpB7i
KfG3HsW04x2ziRXOv0jb6Qwx4fSMdMPIgcWDHDJ+uN5bqCQITSpZhnSWCOZYMEOMRphY7S6wVJ+w
wmScNgo4JHsRSQsOALs8mkxGNQNrElKE4eXmkElpEgkTIW6z5V4hqeFVkNEPo0sfr1/8tiC1c2+u
vvPx8Ny7wzMXSoRwY2wl1PFzAoyGGG6HvcinKVWmCruBfTGNfKetrDC56I1GMgjaLRAaSC+MB4px
4KcD3PL9kvRQDSWYXHWETONeGtMKJYLQJRp7HWAhRy0VscpiNl/mb3FwEnOrZjB68921z14GYwAz
EGxVPUQZ4mYGzAB0wlhLwn7cBt8XaHNjCb6/fA6JwEtpjCiMZs5XJMhWqdILwJBNHJ8VOD1q28VZ
6idUK6CZJdPK+qIpgjowz8EXMNeeL6DH2jRKtUPPHIxjOKSTYAgK44oGsFGLhadtNvtnHfzbIwef
rceOl9ANrV3Fm5s2PpqC5iR1Ut2Afy0Uw30ghgceMER8koGktegFrh6HYWriL+G7gDJ8Ys4NJHOC
9Jyg7/gQ/Zx+GvaAt22yXLDD1a+/H370+uji5dH5U0I9EgfiS8HvIRpjlnA1nkEMFsZ0Yp4goAoA
ltR3mgTHSR2/TdKOKcRBtxUkpM4ExVQ8AEtZNkqRdqGtKyF1QrxqxLQXLlHXrv0ekUuEAwYys2gI
1P040GqZxmdeQmPxG9FLVc71A0Bl6wrkaQABkRRm+eZ2CJwI+rna/EF7GPwOpFNaN/Qhz+pSyK8C
SMRizQ/bi5A5hZoDyZmz4AULKl2J5tNOqgGnYq0Thz1YxfILzNviuB+hbVkqrTG1On3fBxG2Qczk
BRnI5g7MPO/MHK/N/LHVnGZRTRDN7Knk7bLZTEzT9s5G5VSCyyWUc85MB9A0T+zbs1xFVAGCJpTY
cxGTCCakCkPjBT+c18n9xGAKggxmFmewbJVJuCCSpkoaA8wWAuv1SDHCAFfb9s4cJVu7JS5wgxoT
YxpCvcRSYRMRGAVtZbaqc4tLWM5pRjRwQd7mIqWRrWavQv3QSktJI99uNHh2XrIrDk7kbnGYAnlg
YHwpREzHbaX0GOdB7EU6Y6qYrXI2n8g1nvtlwhBkZ7LnmuMtCsn/jSxKzuQymSWWTBMwBEnyq/qF
7stWtlV8Xlmd2UzOD8AsR3LPVMFSSQmhBHJshG/5oeMmOoOhyKCSmOEGC8KrLj2wgRqK0shnmEOG
ccX587ptEIG6ZssUX20Y6EPAWxSpKwjQciJUHZ1BmFN3N3PzNSohVX/W8fuUhVVThNcSY3IMCRRH
+iId2L7Tm3cdUI2jdfibqzXNmIJvS6ioJopRAVWqZRaUKoM5B4fS0XKMerOgW6DciunadmYJVan9
Qntn0bNRDnfjHUAW3pMI89WC/QM9HW8B8jGsHRNTVImECFth273jPHQr9lN1C2xBxS2j+Y0PfmIV
N9DMdCT9OJo7S6QgR82XJP1ewaHimtyZMgA/13WLTAVA0jHZghU5MaTFbE1AqQsawjjDOWhMswfB
R/HEQM0SlH7YDn0whcJ42/cA4IwXdEIrPQbWNr3//p21XXvYF/e+Qr64y66xurslcNc2q8K5KHOR
RZvU/jmDVaRlFk8j34HxnBmzLKCOkwJOoCAqXRUkrbw/E0xFgdiRZieV9Uae7qisUQ+gihSzK0WI
zE5hQiHfpUv2+GhXXFTnmKZtBS2DidEpZ7lcVSFIoue273rJYqufQCrGNcOwOuALHlRgq4qxSUq6
+q87UANDYrr23X/vrXywdv3m8OSp1Xe+WDt3aXj2vLZrjza6dXL1jb/nWWqViuzQjA5OgkA7uvTV
6KsrIs0voDo1OnN6eO2j9fdOji7cGH7y0ej8jdHZa3dXbqxeu3hv5fQmtDBHhUrQ4t0t1eF0bdH1
s5Kus2vvPqGrR720q1V9kBVCJIFSbx7MHkqtTi4O1Mt2tx8somJiUqDzUFDvsKioZyw2zHn0gF2r
H2EbUWebOFLhfbpWlx4TlErikT89miAHjbrGajYtj0/ZlPDJrB4yITOWNUrJlI2GlvZg0MJjtpJ+
p+MdQ4fHfkwTCyaJwgd2aBgzydHKuVkK4PZ7kQ7ozI5Jg6QfQ0aYtD3P/osDKmtCUAezsHcB1o51
NAbm6OSFQOmYdKyO30+6OiyA8rKD0UiHMRBYEEq7zVtKQEct3Fer8dVZowSGI2Ns9irsMitIS9O5
LnRcGyCy02KQZTMmjBxqPf3IoScff46Dx1RIodMVHQbReWGE+mFC2QzHKLopXrAEZGQBdlIOzKMv
KEPS91P7xHKWKbDgg5kG5XW0EoPU6El9m1EPrPEhkViirTTkQAseEGazitvrgK6JClnJO5fr2ria
qBjYiokXp3oOgDftEwRXkDqTkuOy5ZGxnOdZfjFyFiFNMEz54QY62R5/qV1q4wxT/UzU0PEs4MST
esGoTYJ9ElKPSp0T7T6N9U7G8YiHohL0TI1JHfPLnwMXYomm9lWGb/wbvO3oneujMy+vvv8qd/68
2XJv5X0yDRgLXooTUtRw1u9UlHtiY6akc4WuDKtVSX280SyPNXE2VSRFtC43tzQ2J+mxcahMntpx
yWaqLXhRsnIIuRGpliNqTrmXpYqTy1eog3Zbe4kU0xI8aCI4rtwZ3nhzeO3M6Py3o5c+h0AHIe/e
ypnR62+tfv8hxMrRxc9Hl1eGK+dGL38yvHpW8bVRjHUFgQWrp0+JzvY3V0aXTufQWP8VQirA0ZZ2
WXu04cmV4bXbowu3M4D/e+kVYqKg7GSQAL0ujWMlyWMawhmr1ogZ8yp1IvKmWBxug+IQTFeOMp2A
wY1cKTN3VaOzE12+sv7lmeHVr9e+/TTnkuSMaGTw5kKLxydUE1OWNhOCKEaHBuuslwIpsQJ6VI2f
uEZ4qmoAlSFRYptmsbHxM4MinRAVKQuLjc1iojx926dOrIbE8YeOrD7rMek9L0lwX3Zbthmi8g3I
Fu2TsVEvm5axKVPRgBg7c25OZOZ4n6I2fkslgslvqQa4yX4yDKg4yJZuQ3kFLLEVFytwWXWpPPMW
FYem1hs8sthqkitQsunsPk1tZk0so9S6Lu8s4fIN0gC1chjeeXuj7nUGIHOiGX1ZrwaxmYWc3ch9
BXribIus6/m6QiJdTCCyVDXR5/hiMwPSNBMK7HTgpImtQxZkkjqkVRYN2hA/QUWqOfnGF5bqBfyv
1hN+zfLrlQRVZPLNOz6I2zS+KWFGPek+bUvqwyn/PXRnQtooLuPxLEWsYuPkC3kocUeXX9syERkh
mai22QJ4NlIvX6VFpnqXKj+5G2eTwpFzLXNjp5NCZOlBnjDYzDNnV01j2Xv29OoXP23lVqnSVTtB
+Aip84qOBGAU8DTX5D/BBsAYSL22LMyPly7ZLp6bylS4aNWTgZmkHbI7IIF2OSu/8mvYUhc6KqQW
DQbZ5m1fzIN90pwT6ApXKez2EQIZZM0BRE22Aqw2gdBUKbWVshWNAC2Ara/cuJaBmq7X3hggfth1
MdZvAc988Bmc0ejSl8M3IUeHhMWYq++vNaubCLFeDL1AbyPyMHb1tvEne/culmTyR8ipdj0gLjn+
THhpxOgvXDnjh10qKFSwxjyjYvXjTxkJu3c1qzsKJLRBCR0/6Pf4JQPDRFozZAwB7EK4AA47nbZA
jr8JvhgU40s2ccrMGG8E8EH2/9kxdz7IFjxo79u7d/dejggd7rj6TOqBjDgnOKvrLPBkbVV5Pcxo
qOO3SWiA70G5sJTTJ58ZKajqy2oqnCMTit20IevgOsbXjblveIwO+I/DcE7+60AKVcF8PxWPRwIP
I5O4lijhkyUs138wrBy9XTOFVSnuvFTS5X7H9ZK2A7rD8mEnbnexnQABAnv67M5hozRRrC9OKUAm
uCtUFrFqshsbvnVm+MNboyv/3PpduRIxRLuR1T2g06Nzb9y9c5UDzjcV3dQ2Wx5Zhosr19auXRVv
BXGabn7DXwbKawzWgeTdyfXXzo4u3Bh9/OnqpdcFEnnKTWNu/taF2KK+QAX+BUoQ+Uqilf0IwqN6
9oBfx8ESrH7aZgVmB0d0suO5Hb0d7uEdf93xxI5nnhd0iRgqcM3qRKgBdWfINEM3TeAXvvto4dce
naVH4Jea04TXzFl9IiuRLPI1JkQ7XM+rJR5Ey52drebtgurqi1JZJaJoPLo4GZFVvY/6MMa1fgua
PlmPxyteHon/8+7w0hejUxfWbl4f/vjqcOWV4a1bv60G3rh19/bJ4anL6+9dlW89yuJtAxapvJAW
m9fc+UXipMpNuWoU7z805aHkpdwEu966URfv/wpRudIpzW7pjUqY3lRocqj0GkhuEy+4J/YvH4bv
fcvPz2Rvh+xffkF0tyLxaki1Nznh4Fwt1j/8aP2TV0G8vBWXi/T07fXXznGRss5cZFUDOON6ObTx
hZCIecdLTUIcmZSgLRcsptBzRPNhdTKmaixpw9DGXzYxyfwgxbwOL/U6cxxpk4mnk7+SkrX72L/l
cYqXCGvM8JrgUQLBTmkShSSwYKC4tpgVOu207/j25totNU0i2WbzrWPsryC+ihVKYeVxACS79rl8
f20j+8nKLcY0jn9OMK1Z5y0R4C4TcNPITHu8kYxtcSjCleBFojL1f1BLAwQUAAAACAAAACFcu2g0
m8VBAAAMsQAADQAAAHNibS9lbmdpbmUucHnVfWl3G8e14Hf9ijZzPA2YDXCRrDiQ236KrLxo4sga
SU7eezAGpwk0yQ6xBQ1QlBGcQy+UqJX0pt2WZGuLbZFyvEgmtZwz808SNgh+8l+Yu1RVVzdASs7L
l4GPRaC71lu37l63fvHcUNOvD415lSG3Mm3UjjYmq5Xt2wYGBg41nLGSa1THx0texTXKTsWZcMtu
pWG4lQl4kjYO1KuNaqFaMsbcSWfaq9aNkjft+oZXMZyiU2u4dT8NDW0br1fLRrpQrbtprwJPnULD
q1YMr1yr1hvGHqdScEslt2gZhUm3MJUv0APLqLtOMe9Vas3GNlF0zPHdnTugXLV21DKKTsNteGXX
MibcRs3xfcuYdPzJkjdmGV7NKRbrLj77k1+tWEYVvtWcBr+tu7JF3y3U3Qa886uFKbcBf5tjtXq1
QDX9o/BPw6mPeyXopFkvQeV0zan74a+6++em60O9ZtMrionWBFh8OcPdr+0+cHjvwUM0UMPxDVki
XiGNE5S1fr/38G/feO2QKCMAmmfYyzIHDr5x+I09b7ye37v/3/ft36tBWpZwmkWv0ed5xW0cqdan
8rVqySsc1ZfIb1TrsNKyoO9MuwiKSiFf9OpuAd4C7MecwlSzBqszDQihP/Fdp6R+TLt1bxze1dxK
0atM5I/UvYYb/iyUXKeuCheq5VrJxff1ZgXXNe8VoXGvcTR8ggufB7jXnbrnwuIcfHP/4X2/35t/
fd+vD+4+uG+vhJYoL+dwkH9u+92+/a8dMmwjm3DSU14FMM5Jl5wxRDYnXXTHnWapkccaSWMcsNlB
TJaLl552SrDUiWRu2+HXD+VlUy1uaYvyhjcOrTdKfnvbnsP/AVUArdLlarFZcv1sPl9xYF753LZt
0L8x7nilhJ/MGHXHA0z4Azaxt16v1uEhFShVnWKihgXcRrNeIeRO40M/IbA7fQD+QpE0bZ+GO9NI
JJPb+IMtALKVa42EmLaYtL2/WnGTmW0GfGbscONxMWPQSIybRrYlSrdzJk5K/DI836hUGwY2Ybgl
GLZpJqGKmTHMJGBT3aslktSyGPMMVp7hogl4nxANJZ/W6LbDuMQAwRdpJo4/JachNmWf2QD9Oeim
eNIGEp0KrItXNGh68K/fgMkCkTOKnl9w6oiXhgt4C3QQvzaO1twiEAdYmTrRMmwT19rDta47lQk3
QaMS3eHHtyMwlrNT7xv1o2r9aOC4uPKlO1NwYaThyiO9cMPG8VOrAxlNmIbRffxRMHezc/5a55P5
nx5eMgcRmm5yMGH+9PByd/n+xvEznXP3uBQtmfcyDTY1omDKPRPemd0nn62v3g1uXOp8fT3a9Ong
/t+ChXOdH+Y7V76Gt+sPz3UffwArQgtRmKxWYRY83WoNyKlciBEBFh4xFUiGILSIVbiVZhl4QsNN
UFWoIooDyhktr500Wn7bTG6LzHw4aXSffBxc/swYMnhgogSOx3dLLrGYBO1BbWkABPTIsG3DHDbl
PlMsKBEuhFggGNyYW+eGrBGr5FZomMkIRiMmmhuzJzqn/mpaqne18qkRCSdkb8ipgPQWE75VdoHb
FnV0hQGab1VMhItvAIzMt+r8IyPWKFg+tn7tnbUHZ7rvPQpOzwWLX3XOfN69flpMH+pzo4YDRIm/
wh506g3/iAd0wRwdHh1NmTq2em+79sjOsKZtc6GxkjPlbk85rp8aGX0pNVEom4w120ejqEwbykbI
MH9Oj+3cUXQL1SIgtkUvYXHtw3VYiaRtY39xbN9LfwBksrHfONCRvmpIC+iVgMO42bl7wzg06RSr
R5B1+waO2eic+7Hz7SfdW+90vnkX0Aa6ahvB3fPdk+9uXFroXFkB6G18eHP90vvGr2moBiAygBN2
S7CwvP7JxfW/rqx/fLUzvyjA6Zagb5yZn3x5ZDS6Bt3j3wb3PjBGRo21B19CJ+tf3zIjWOELgivX
W+yPEi+4vvgWCAAII5q2WBusOuFWeGf8q9ZLjCxcJ7fC68RiULpRnXIr+bGjDWBc2FEymRYrmXxm
1OJOoy2CtOQ7425i+6hCU56yIoThVMXs/YJt8oqsPfkUviBFI5pkPGfwGgFp45Ug0gZwFUSNa3WP
fxmcvCNW89nIti5+JoRMmRZ/AeNatIDtnx7Ot3B48OXyEBcWJOinhyeQ5yXjiOsTxGCAarbwvbcQ
DM+HxXzO3AwoceaxCT35/5uZgHTUcMsg5MEfmL2fCBl5KwFSq0XyGfIIktINlJ/8NnLwQrNeR/VE
Vd1luMCGjxpHJl3YjT7KFM2KMw3DQ81GsXMCabXZsEPZHwXIRNb0fdMyU7/Ff0qVRrNm5iwUqIiW
WX6jGKt0YN+BvfjYrdd7HqP8icVHhi1aNqaHaW5km7ZYiTcO0VJZWguH1Fd6leRlFIBGsH77SeeL
2c7Vm+uXPwgWv17/ajlY+EJbQ8lzm5Wi3WqrzUB6HewHGEHar5W8Bj7wdWIzbuMjfpmI4DUSxfHk
yy8i1o5nh3OEw9BWwmwUagCwZrEGXAY0NZC8K003ir81m/h7dkcuXee2zYwJnD87kutB3sS+StGd
YZCEiNyvaZpf2ncbgu8mEjgwq5YEloxCcLpZQ06UAB1nHER2p1RK1M23EgOJ7P8eyA0mB0wLJ5vE
GWXNzpUv16/e7D65vH7nlJmL0PXWFAzWTP+p6gFfAGQEsWE6yRrDlDWNQOCRgK5TBmi2JfOHDkF7
c0nBSJQFlEWbiZeGicBmTadQds1c1lTlzRwQhclGoybI+Y4d25kYI2lKcHlBdJGXCKYDfeRJuKwn
yhbpOhUg46BSWWp7iBHAnvJthJBQCf1Ey8QKZgb/bQvkAf0lj3r7tGuTvgOzDNUgJCyVo4lq1nQr
uLWKZo5JXpZbykWLi1cevHjOFsMi8FWxHMAAn/kS6sxDWUwOMbNmC8lMk537NBGldf6kU3eLNs7Y
+B9GZM5VjWwLFO8Zohh3zxwR2LhKNXrAnUQ7VmRx3Fx7cBbEkfV3f/zH7OlWNTuA9Gsg1/7H7BkU
S1oDQwMRzOLWksm2wbs6OPa39S/fMSN7MVwbGgDtQAQDzROf1Gx7E/SLDe7wngNDrVrb6FxYNnbv
+f1eY+PL093ldyRBQSkJxE3583Rn/tz6x3e6C1eCM58YLxmdy9/BW64CkljwcMGMLg4MiIRZnhoO
LzaMI5NVW+En4TeT/N7FgZI0Nfz7HAjzPmhrqbHqjKkExBbUbNNsgN90P//KaEFZ+HHmGozZ7BH0
a/p2JHwT/Kg5MeH6bBZIsJ6J4pMYOM6qFsoU+MYqeywJD44ODw9bO198cfvOpDbPPuofEGl9ij1s
O0NCpD5AbJ/HN1n1G4hDwP6L1bLjVfLVSuloRJTEHkN8kZaxtFfLi6/6JkIdPGwno7j5xY3jpzeu
zIJsHVy9GiyegeUXWsj1r4JjF419B3ph6m/rP51NOqMFRercLJXKTqMwCfQ5O5z6VTo3CGpVcvOx
iJ6BjKVL1SNAFJSUybL7K6MvbidtKm1KPkXiFn4nNhDr00m9Dd3mEq9mxNdUrgUrOdKWb5KvmtY0
k3wi+L5gkdCBvtQ83rUHq6h6LJ6RAtBlAFzw4FZwZqG7tDTUvb8cPH4fxaLLjzYuzvGMgrn57qOv
1x6sGLVm5ShK4H11C0kDrVLVHrEmPRux7cVQlyTBMu35RW8CGbicc6n6MnFg0GrsSS9UqT65F8w+
DJ7MbVxfDa7cMVqlavvvsx+1Jr12tHeuy0Nwy8JmpfcZB+j/fsv/t9zgv4m/b6XFF31VN95dWl/6
pnPtIZANBlT/GSMtZnyPTRMnJ5b7pWGlqi2eWb99b+OTJ8HKLaEWjsCUXhru2zgacfOk6gNIUVEz
zXgnm0nyW0jxuL2x5TT+syMhGapGBlSJN9/c91pCGhf6kAGeFJYydEgBSrHSAwRZKUkRBUgs1hE/
j2bCHthF9LghMyk5egFwx685BdT/ENkLhOz02nxVs1L8ImqkYJQGLFpbvYkGmoezwY3vmGAEi1/h
OK89/MfsO6/C/7/ouxAo1OSFFa1sQc+FqHLcI/7gsuBMqKiEKxXFZYyWhQELIbhok+UG2NXaj7ck
WZvvnJjtXDnRubi0MXsJpRaD+XUw9w0wDtDxQE50ymNFB+erUV8S6BFruDOma1Incrkn5qmE6aZF
OyesQD9l+YJjZ80SMEhQ0OtHaw0QON9261XfL4FsKOxtYtzGnt2mlTVfdxtvmb6xl8sbnbtfAHqs
n10OPn8PKv8XVD506HWYHUyq++Q4j6F79j4oYsbe3b/GaeWsEaFI84AA/tMeKDNm8jlb9c6C5mgy
R8Ns+iBOtSpSBGImH5XACMfiQpMuorD8VUmGekl+cyW9MAlwIWHYMkHs0YDBy6cLHzDZ7vJNFlYA
F4EIdK5cDea+Xn/0wfrl77qPHxt/OHCI1jNr/vbw4QOp4RFAVhCBDCAPlgkrn9r9+oH94WOQvHuA
FIrpCCUcUhRCAluFfA/D75XlBUdCWGaMsbrrTIVSrjKEkmQWNjKAjQyoRqSMs372HqAu4+vaoyeE
r6dRd589ESzcWnswu347AiKgF8Bp1p4sdT7+EWDFFRli/5h9VxnBfKVs9giFIM7qnUbE0yn3KKxW
bfTFnQDOuu+MDu94qQd92SSHaxAvGIM0tJZHczwBWhaKAlupT3ZL7r9M0RI7K+NaIUpnCo6lrV2m
MGmFHWTgW4iNlc00CkbsPgpOBp+D5jUNHeXsIpM0aLPmePXEmFdx6kelZIbWBE3RZ4sO6OPoe8ly
UcuUZiAEjuuAnHE0JVrTDRIMc8dGF57r1InxHqh701Dxd+7RzFv+C4m3Dg0mTaqR3GWMRUs2x0pe
oU9BnU84UoAYixofure/6Hy2aBzkwRm8pMiIjq8AawJVmjEsOHt1Y+7M+qOlKM13QO23xuAfweHd
I/kywLqUCN1cLdMH0JQdMzNqmawgmBlzOE3/AVhK1Yl8yZ12YZVNrzJehUeECBmyroqly2RzbU2I
UOxFgFkaZqVabKOzMV103Rp+ScDrZMTOKHiIAA3KBCFmFGdsieWd+6vByWtiZ32zGnx2yrSM7AxM
l7BrBjGHsCY3mDXXVs8GSxfQin3tQfDkPWbhwcIHuMXO3WOBEcmaxtqDhXdBbutevwM6GFHxiCiP
IyHTPHURV/rIV1odH/cKnlPKM4ilz7QAqNZwI+UR1W1+LtDY2nP4P5K7hG/aln7sBBZM7pJOIPE6
4mCNq3OEXSBwzGSHQZFWHtUQOskM/Uk7NfQeJ6gLS7YcdbT16IqyGFDnjNqkadB9eKCh3oWEjhrO
Kw8Wlc0CGENyXgHq4hUB0xCNUuZg1NQ96c4kdiQtzYRiKeaXwX3aDomqapIgq4jJLuXIVJx1l7TT
8k5iRCILH1YZNAEpgvnjoH0zjgDJB3qv8A7xgqcJDaK4AmSJJR8m2iQkm5aSra0Kk1wqanEPMNEK
G0SyqR2ZnIDyL4w9br3hAQYBUqBFpQF6uG+Me3UMivCrRmPSNRifkLQZU5XqEZ8eEidRFJjKpOWG
6rEwZaISoXAGovJs97N08TitXlNyctMtKyHeR92POHDVijAAowbXeeTCtDc33nmCUi/ZGuTbE6bW
s/RVaPVNq09/faERoqLGZzTboeB9uT6YptegGQRLn3fm78MIuk8+65wl3xiIRQbLSaDVGygjsJZt
SWlX4odoydLla6vVTkYl4C2MleGCRGlHGoShOvZErFT+gCELDDABrDBqGBSIZp3zN4Mn5zvXjneX
j5lyaKqORV+lXB3rRjRXsQwgZJYheLPOnCrMMRCH8sRGlOlMrKUmGcg92n1yofO360omCiUp9npX
ol7vsAFrRDdwsug30PIyr4yiExx02WW0XPUI1IxJwTtX8G3b+IvRUrtc/mK6In9JBGhnQtFdvsON
0x4Q6mLNK0yp+UZAsBkEhFSgzX5Tzz1sF3TTXUcroiEdaWs/XlW+tJ/n0fdQSgDWag6b7X/Or68Z
nnu9+4JSriwEC/c1H7/y7WuKTMSwj1BLKKxTS5FMywoC1MJPjlMsh4Z5LUQrLT3pGvTFrhKyEcjF
ykUNmnbn4+XO6XdgP68vXV9fPAZCQufMElsNzMj6eT6GwSCoEqJBBkOSXAWh2Y0hMH8eZI2IgSYc
SCiGWSyGKeWmZTbqTgF3Y9Eda07I95Z5xKlX4I+L9g34O+40HKxdcypeARdSipm4xdfvnlhfub1J
30xaQsRwQoK4K1TTnZA4ssK+Sxiw4AWrCVH5CR4rnSEXTqa/Zt4ms0nEdRNW0ZRWWU4pHFqxmBLU
7mOmZyWsu/QYJOkoMIrsyIFJ4aYWP56uyPRBz7h3uo+FdHfqv4ZTv8qncq0Ra+eOtinZLlsZ+Tv2
CKOKohBT6o3jZ4IbZ2DvR6YgpkHCmWxvlzJzNuoJRbCSSW1ZNaKGxZWNUBHCqL8EYK41JGPNgEBF
Byo8LmQPXXuw0vnkO9hE2kBj0ZdqhxKVFEylB5LabtOpuDVWrZZie2395A+d2Xd64bOp3tlPqu6x
fWmweq6f0CDHEFq+dPsYEJa1B7Pd49/1DEhNJYayod+nh0bqn5pNrp5wWXpKoJSAzRBuK6N1ZKnI
+gBisfD9VLIDWHgg1zZ7m6NmCNFqipagCtJjrOoP7H5bSjdU1eyf5dKNGIvYh16oJXunS3u/c/qD
zvwFnjNbhgq1tqE8ixIM6K4Tth0NSLjlyFGne/gi7joetVCzNdoU6tuZTEibWYQNrtwLPp1VbEeF
BoJ85ZUwcLcy7k3Evd7xDSRKgxwfskPZUMlzKw2xs7ZupdpsjKEDPiHrNuve0+pwEeHRmGEXKQji
yP6EEOI37EiELb3cRS/S5amiV0dtAYboc3SIO4PiUnVKM81QdIWdVa5KIyZ6d79/v3PuImoRi19x
YBMH3qzffgd+rj35NLh7gcyVCldMphB/n73CsuHfZz9dW50D/rx+Y4UtLfycTe9rq1+gmeDGORDs
uUdQV3j5UUTVmg0W31djM948uM/gRSXz/WnEq+WHwdzN4MY33e9udk6fCO6e7yx93zlxKrh/k72B
0J5qgB113EKwDCLUx6yjxvs888n6qa8NKbcbG7OXggcPOheWlXi/fvcx9L3fQT83qimqKBTqLt2A
afBAoGH0TEKfpx7CJNGJptQJGSyFnbN6BNgCiwIyAizPFH57Or+khRyElTStcdPGD4rO0pMPGgn+
QpIhfg3wKgwwoRwQ1GVASO4DLLkPtA1qSoOJgg1vX2PfaxlDaeHQdefKmeDk9eDinQz1yFQdiR28
473OLyQNhMdrD691H38EjweMQUNEGmhkGWNkaug/bZuhvYMCW9yjVsNrlEjOzkbUK6WKgcCYMCWA
4YUIzsOn6NyCJ+i4ot8cqIZlTl6DYhy2SW+qY+MYdHXIKTllIL5u3ejcv9+5f0xrDLchFPmjO3aI
Dm0Y7G7id2TGzMNwoYSyR859jSZmfO9PormABiPf0iMDB5brYaDQDjGuDK+5tD4RJAZNXg0ok3sW
5sxNGIO2kUXemiG32OIy7vH733afHGcuy/sRXi7eQjDs3yeWXLLsXBQLsbl+2oXfLJdBlUWaFh3Z
Jlwakd8WRDAGA3yVUSgfLLzbnX2PCcDGR49hf2Uobmoqt4s2kAQR/og2RXYI1U7n7o3OnevBp+c7
V75kUZbbRHLDPgv2X4R06H8eemM/GiMiBOfkHUVwNIyV+1oOJso8YgY/Qx+TYKD3/8abUvgsAUmB
3GlzBlYb0jcitOEAiHSgkQTN52K78ABSqPOkGzOoM7xVERFk1HtyEB8ggjIQe8tMyTLawhEPGsK+
kmk6WsPHPYR9v4ruhHK1GJayhqs7h4dFrIQz7fIbOTjJNv00HioxrZapnpgZhGY7GcaWhWaQiOK6
C/irT2a0Z9M84jgpqstIvURNkwfDWBudYP3LJDfZNQqEQgD7eTF5UT82hzhxmxJudXe85E1MNiIm
FbJM2r2myl3GWNM/GuFHGAmlJMJICNczxE1tHTOFfcndoodO/f3YIsdNhaIhFlVmhlXYCqeY13Q/
/yqY+2Ft9RwHTbLtE4PEFhbXVm4Ei2fZV8TiIks2wdw87zNhKIVaK+iT7BVaydSNgchiR+AglEmP
LEvCz/v5+50vZtnHDZKUErW6x7/srnwlurn0vvBdPrwUXLnDdvPO+R82jp/sfAwixgk22LFZhk6w
5YuVEN6lasEpycgpEOhiZhogxGgbylMxsQfilhxuNDxRCbJmrFVRD2Obbd1k9ywe9ohfiprQzL/R
kYAiWq716X2XFkDBLDW2o8edslci3pjYYe3UzS7i2KVfbWLQRqy/ottA2HCTCW7EqjcrgLabuUGj
5hhuPSMGRZtVPEvuUt7yfQemW9x22wiOr6BiSNoJKoaiNEXx8xhF6NbA0EAyO5prh4ZHOqs67sAs
Wk54vq/s1BL9Yuh6YEgrEJ2+58upO0m1SqobZT/GsPgrKyClB2eusx1ejR82gWWIPYAj8Rt1S9Aa
1Y6Ffnd4kUzKYBJUvuplt6iH+Yb4Kl7m6WxhSFHVCzUuNiQGH1wA/rh+fQlk7mcZl2qnZ1wMi7/Y
auR/UWV1FOZiUY8zdB8sXWJAKVcFjAO0m4337mAw/PenOiuLwafHkX8vLHcfw8Y+zSBde3By7cer
bKPWwQvbfv/uw+hQ+H4JBAv0fYjQvYVljMd7sti9ftrwx8p4uAVkJZAdeWgpr4aYabzMre078Ioh
wLN4duP4me7yJwKjJh1/p3a2SUoKekwsbtd4sGhIa1p9ozdJAmiHUs3m8ZbaDnV186D84IgaR4nJ
ZM3dIILshk9cVlTj8jcPXTCLHhp5B/HYg72dvuGJXXsEv5LEbVrQkYVDjx2qiJ2eeG3vH/a/+frr
4QGKF3tNOfKogFZtD3Lq4gHt1IR+oOIwN7Z3pubVATHFkYs+VikCin7M4urN7vLnQkokgxiK5zCJ
QZN0Upjn0Rp87y7dCx59AkQG4GB0f5gD9oJ+NNKYgcIw++MzG4zExmv7DxkKXxBXKaqGVTyQkTF8
4uSdPmYs/SCHv8kxjp6VUzhAFLQvUvHBDz69m+zttj+ihXHK+GGyIaBjvwLASWxKJdSINCpBoYUA
dw4v6XOwSlVSwbxqXp4Py40Izls07sWgDQ9gDebuAL0ITv8IUnwPNbnMC2TsHsJt8I/Zd/a8th+I
RPfUTaYL66sLRpxioIXjxjmUeR7DEt+UBPI0ni/8+M6W1GNzuoEfpB3GX2yOkkARwgeR27Z3hnES
MeHh5wnem7ioaFdHTNmaZdBGOyA2RWNjN6S0ERqSguO7SL+b0wwQggsN9P6k0CUEvQM+Tu9Mj8Fw
pndigHgk3Eki53M2neTl5Q3LGspubwyjFHoCY9WFTrlwunNtngVRs6+Etolc9JcWuiCkwMEyAf8g
sZyWU2pJHEaTnx6hg/liMxZsPsCPT3YZZVuLdWJf/UwN5COMqURfGgChEEZX5KUjyifvmdDMLE1L
s8w6/HBNJVog/heSKdkq7pICuwPCSgC/bMvkuDeTMzygm8qZCH+2c1pN7gJqtcxxr+KUtGK68/HC
MnLd5WPB/FdAFzvnb3ffR3bNyjKGwNOhThURJk4TUOwERiEsXcfvS5fWfjzRvf1+MH9RuZEFDGwx
nE0AlM1FjgCoNzDuEZyMepAdznFDKrSQA8cU1b/NA2TrzPrqR53P3mdWECyB9HCn++Sd9durpgy+
09vVB6D5HeUQHBElUfGHR/JaGKn2zik10MyGJ3vyqG1SVMqmJfAYEBfQRi+M/DyHH+ZAHOYRd0+/
F1z+TtPqqrD35ZA8H+kCd6mNLGnb/YrR8aNSrRIpqg2BvRVo7Xm4II6M9IKuX+imBjQ8yCfjOENX
rR7QGfHURmI7OSqXsnBsOT1BwYSjNowGdWLxpxY7abWAZSK/hWy4KzVKO2XPZBm5IgHBU6FbBSg6
jtAyJ9EIUPecUfYQI97MhNEsjNWIPT3IGSx+pTv8ZdDXaVCuO3c/j8CZiJ0IYMOBwT4HaJEpV/st
gtdikWsWm2KwHLMARjcoL9TT+IrpUkNoMsb6PCEsJD20Vmg6jhdQL3LtCAjRBqNAljEq0mzUYisy
NkNfIk1Y5tgYjFQAFr4j2cAMP7AA6JctOlAq2Q6hFbJPaSCpIO3W2OBM+J1q/cLYO+MUGkYdkcFA
LmXU3T8BifSBG1aKKeAZQIyRkHqVCYucE75FJw3odElj0q0bzQqGylWMcc8tFX0VGUcqfZRXkU8e
g3KsgtXjbkv24AoG5kjSKuyo8+fYs7OxegGFj9mHKPqc+nB99dPurWPrl88Je+zKSnD/ZgSZhLGr
zByv7pZcx8fMAaRXWzA/C6OL8Vi6Awvj6OG19JuYIZfeLCIFy0XjUP7da/y2OWbsPrBPBBJtfHyx
u7zMMhYQl+7tW8HCBxsXFzvfy0D0evVIxLNTx42HLWuKljNh1wUncCbywrcRdXKL98W6My6ocJ/Q
iOm3ioNvpeU/iVczKTzCtjv1X07q7XQqN4hHx6CHfgeYYQvZ8Co7kslRzINvN5o1dIeiyaHSsOC9
PGeWMpPIubRTZ1HhGCq/nBixRnZYw32PSgOS4BTtcWUETLWg+XYKxP4mfMd1a6cbDkz5bVOLqamg
gTmhmUMETGB7uQ2mUBqlJSgC15DdJS3CgB4xvs8Im/WSLVoZw+Vz6/ki7AfEGMwmQWuzywDtCh2z
irDjL14Z04z3ArUix5yQzvuZoaEJ+NUcQ9/z0CFnwq3vdxtDEihDEqeHZOdDoOE5E4N4SKrPqPtH
y/iTDjCMDOKBkxrPtShahgfbrxGcriQ1LVNI+mYGviC/c6c994iZqcszOq4YomnxASmLfWD+JFJt
WUo+yTsNglyvj1HQaIBsBv6xxJjNDA8z+8sMEE5aZDMjV9Myyy7G5cCTrbBIAdNsRzY5TlNRJ1Bw
TzwO5u+hDvbZDyBj4flIioQ3Dv12dwqGguo1K1HrJzBxhDhGuXSi+8UcVJdhDMfXVn8wZWyyIBVD
JeAKvsophdHHPppdHI5ELld9XLKCW2mUhFKGsDJC2KYVFUmjuppAFVWcAatn6lkN4jmrjtmjfFfz
+/uUSM8uOzOJRD2kP9icgkVWraw4IJVSJ1XhncSBXNIyIn1H6YNeMkIaYpmx9FXgwal1uHuj8/V1
NnKoNVm/8y2wC4A6ev5JogBaiwHOc6CiLgf3jnW+PwW6KhRYe3QF9C1VXnEJcgm1TO7LzPBfy+Rl
ASwFSJCAB6IY/1IajGQdGW4ka/656dZBD2TWId9qLi1kOhGvyzQALDEdJhE55JYBSClYLiATICwC
cmaMkfTIi+nhFEixk056ZNh4JfrkVxYtCj+DlyCxyQIvqDQidPY7b8E62tOYJbDhkVMMSTWrmCFB
R7PITDIUHbGqvmAR62c9TJKDTQwmgK4nrWiQMj8ftpKD3AF85T6IGs9oJ4A569qIpXdfq0d6t7TY
HaeO0WwgU01bIr1KNPpZPFQjFGSXjUzWmC2gb9Ff2YJQdXuMR9E25K+fHs6ju/XRR8GJM+uXH1AE
CofSO6CPiAlhqc7yx1yqc+4eSwPBmePrK7dV8VdE6Wjh87cRnSl5V3Dm242LZ0SV0AOEOyovPer1
GCB8G7adwGyMIsGfArFzun+KqZmkXSL1TbD0GVoGab+RWfBSNFyah8iWZ1n1kjkoIckGsitfMhWk
UHg6jrW8GiycMyP+sfGBzpVZAIy2mS+1fI1gUKSKH6Fl2czIcK7diuCBXkVBAgPGecmQiEo5irdq
eB6A3+ZVAh7TCmkkSlf0OhMdLkhywYP3xHBL8eGaivLQApd0KirOVyhaRBVKT51faav5UbyActLE
xodhW2o8vJi8yIqcBkunO/OLaIy69C4rwmzuw+PbcpwYekCRUDpqRE8QYMg05iYMpa84pEUJlsfU
gBcW12+sEP6I96GrR+ziqNuh4h4BgZR2rr7qyVd6N/MmG5pboKw0uoSET0On0upH3aUVAtYJxM9L
72soejpYXekuLfE+DqHAayGbQr5Osk9vm7x/AKYYRxbH/3kRCYnU4gTRAIo4O39t48qs3uO28ARC
XggEiRppNwIGYZqAurDvgWj6VLqwOWFhU+GkOkLI25v3Px6U7TOTs3e6ZxYpOLAfYpJehDldiJ3B
RhgDxsml11bP6liKQhY58bm3tQd3RVrD0J6Gx4+HM8aMLbJ7lMSzkah1GaWan0UHMlIUDIcvDhso
cWR+MTh5NUw8cu9YuG2OfRjMzXFdbRNiBKwg7dJlqSOYhk4zdinc4uFEtIOcDBEeEqzC+EBrOkKP
EpIcES2a3owWgRTcouN6GmmXHEpv0LYlkRfZ1doDYb4RwCWUlXIY7T5jy1/hMUVk+nGRckZr/DnV
OKUHEoeqFOAEwlw5gRL23MNg6Ud2P6EhgNNLHDi49w/79v5R+CvIbioebZpUU4lnMyrOFs+EhHsK
pTkyGHjTLsXekjnDqcCIfd10UA+FP5g+tNB0SrbI/JxmvSWaDFe0KVLicnbDZDI96c6wdhOmi+HG
nqOtywpQLjRqn+o+eqS0EYoAQ44uMHXuPT5gAxALE0GioikTSKerNbQDi+mZ9Qwo1pTITSO7rE/5
drZMS13GpW7gphEvRBbGNKnuOEihgOUipkU6y8QVpK2ZDgLwIzQbeD6OKKFMKmImZ0+tP/wrJhU9
Nre2crr75HIw/wNbvIOH7wJp1LM52Y20WD9qKmwc4zB64qRFeBqDfpzWIRG1WIRLHXVbqpzT0ejr
sDhZAUSZZwzEVpPQ/O89maR7vafKOUP5muRomnX3QNX3ZmhY2pIk0zwMjs/raWzSazzrOst+cz2N
CDqLbWV6zAgxjMBCOjrgbx0X8Ll8hqk/XwEsf2FkeHQH/ZPREYWJVrDy0SbIIT+A+TAnWy0PgWKX
eBxBiSgyiWEkJZ7sUqGMXFWPY4xEOcKLX774ogq3q465Kmrrqd5QNKzq8YN8UkaEDwpVXAvm7Wf6
4awmouymh12EV1zavTGM+M3XDgz9rzf37YkEvlKcvooyZdpMAsmu3s4BLHiyAEkMHkSzTD/PUZ3o
TIXSFfLqjZsjo78k/+xIJhIXbqbYgM9WTy3cLG4nMlMidk2evIqWVq9Zd8vLU32pPbtF0PaQ2ygM
wRCH0G/nR10iCty2DbABKgmQwYlhaC4q4ugUnhzV6kTymuGnHk/hidUtSvUNMto/k7vz0OHX3njz
sJa9M7nlWiZgyCKeg45PaSHdKiYxPInBsUciOIklgHqaQYcZv0DMErw/I1oa6ixc75w4harEvW/W
V79EVYLzft59DHyIT0oECyf1BC1mb2K5TQNhMv2QU5sPIyGHs0jBeLJZdioKyXGbNSsexz2bv4YV
+52H//6e/v13+vcw/BvbfC8jjTFEXVh+LKLsARSQmkkPj7eNFr5vE6REyV+LCFwuMxKW0dxdQzY2
z8MtNuscrOy7BanBuwXOhgZPgJlY+LvoTSNRga/WSzt3ALHZZUzGX2zfSc/Lng2/hoZ2DutmCxhP
sW0EN/5qtCbh770FBBnluxMWCyigXhitsgff549xNIWakXi68eFVCW2iiLiXVIIKpXtE8wrqdwFg
tIF+HYBufxGhT6qmaFb01qxwFdpHchO82KfDfvvun9hu8WAv8fefzZOrm5TYpFVr5mtuHfUPjpec
BtFxOL1Dy7ntO3gNRTQJbjZusKNlMIewsyHQ8Rp40QEb0N6qUCJb5ZtJojcnJFkKXOXEeNIyxrPb
gWhgItwwp+4rO3j9h8M8cSHFG7G8EVsOcZfM1YJg2kX/pv2S69bU3KBIY9TyRlWV+EBGhoEdvJAY
SSW80ZQ3khxCK3VjNAUdjUTT0CVCxd4KU/KGIA5zz4IQgwcdJAjL/VIO6wAU5SUMe6LXpqy8Nc2J
iDWzakbb4YSJ5exUjvbxtAI9yBAkvcQJ4KZziafZFJ5NmbnGG6dUeJktpwOMf0gEyUQmhIjw7JmV
Xxkl1Ww8O4LscFh8QqI4LgNMesBPgxRyFcmeTx9u0Z3+b0AfXfEyGMu26ZhdVMy21Yrs0jNI4hSS
Fn97KZpiOZwNyhYezEeGVlA4Md5EE1r0s/IWEL7SBXeERblvkzlMC35k0mGfD15OxFHNE+LkhW/g
1UAch18UgrGy55f/FFc5RMdDJteo80EZ5ar4U5p0jQj0ykJX/VPPzsuGXNZSkk943MXS5EdLF0yT
/URZTmYQUmUtzqzf+BkIPPxkX6IaybQtR5yzwtjluEudQ2DYwBMGp2X1I9FT9owWamWZr6IoW5MP
9YiSrQ7N1xBj+rlNKY91lhKP5zjChvMuqAgRy2w0vYIWZ2O2BS/OaknLczK0xA8vlxAyBhfTDvvp
nloZqoMRNNZU0pqyariGIi9kBLuxmgAlG0LITEhG6QSd7dFS3uPvjJGtuWjnrFnpdDrXJoBrlQwB
cEpSKKR9VI2NRtVQJ2AQU8SZd4nhyGEVi1fZ7huVGofCUMI5rRvKrVDHKPRaJpsLj2NRoz8nqzyq
SsopLPUlLNUvUuFpGeh3bJZkviSzzI/+S7PMY8+c8dn16dBYtlRTkUHIz2OdoSRAtNHM5kwUw2ol
ZCJmJjMOnwy546PY4YokqKgi5XEdmn6Co6oEDMl2IOKmI1vcHJp26kPwMwxgwKC6IS1I0ocxTJSq
YyB/vjDU4mbb6ku6gLsv4n8k44KSo0Kn8MOPgrsXWC3BrKK3zuFNDqSGbFyZXb97Ing8Fxy/xtIr
pwqX0dS9ecVPmNKVFmJjqMvOvDj8KwoKrgJK4ReAdJGxM+WBuIXmGDIZpGBhc9ErpyLSE9Sz5aVx
afUFitfwS0IlcbYFlljm82PG80Xj+d9mnv995vlDxvP/aTz/X9oiNt5GwSVsE/95G1hXutkoROnq
Zuil4KrlURTpNjAY4ioeSzv/HYOn6Bz17QRMItU7iUr1SKL/MJJprMfmSKdesU3D+Pula6B4fLC2
ctYYeRF1FLY78PqI3IKrd6F3Vlig+stQTpiho0pOcOKva48uGi0s1Oam5lswxMzz/5l6vpx6HnUg
mggscgv7bwtJvOj4k2NVp15UfMkikkPfYq5mFnJBrUOtGP39Slj/Y2LKmtYoyxGv2Ji0UboeFTqi
rJJ2Hb+Rd3zPqeSpVKIwSek1zD/+RpD3EU5xPIlPtbPLrBJPDZqG+QJKxyAZD6eoieTgtDRCUcCY
iI4qxfFIEoABk5l3SZPB0B5S9VMyiCcqhRGxiQQtHTi49/Dh/8zv3/37vTa66s3XMdJGMMymXfXT
TUp8A5S6WbPHQQpoJHRpr0moDjtnWKksSKJQ9kFdFqWGEWwFWBl+d6YnEmRvQrKPpjbQnwrAakQu
8RHdV233+RgqRUHn1rvBse+NfoXE6P8oM6WjoarF9zHiOFSSn2Tb+OnRFaMloM2/gmNznWsPQOlP
CxCKQs102SlMAhjbYfNst6TmlRmgWRPNdr+7ivb9FoEAQJJJj6IxgX+ORH+O8k/EdQJN24AxhAcH
C7auZwL8oO89B96kjgtkyHiedlahzy13UQ++UKCURgXqXLUh01n/3i0frlK6LFw6SsUMb1Ph292h
hw1L+KrmoSNOTavqN21f1cN3v6m7VEcCDoAMxJ7Gz+Ye7CxJHnX+Df0mCRygT76AL1mPrDYwpR1N
GF2sAGVsXVbym3oTPrSAB4QEeaIe17+7HTy8RrBqVNlXRY3Dj1eG07+K3TskL6ycbDa80i6jaPO3
dNHzp/JNHyR2ym0uJ7X+xTvrly8YQ9q0iun4xIrpBsIpnBwXGRLPw7k9PC1Joaw4DkDUp7T+1xUg
5ei6/OFbJqxU5OWRl1/ePhyfynjBjimdkifDq5Dejdm6tgev0CFWLKILqaS29/acRnVCBuuhmJei
VLlQA0W+yeoRStA2bVrQFDwoVElQR3nBKVFaiThxAhlMdZR8ZXvEnjuWQTB3vn9n4/gCARkaxRPl
H0kYjaEC2AboHPsgfAQ8HIEdPJwFUrC2erPz6c1wZ4mWaYrUOp+vgjHKY2WOJL5DFCEbBqpSHXkg
tmBHLDhHfVKDvdr0jiEQ8TF8Gv2C6J1H+a9eLYU3WYrc97uMP/dtA+nBkFy6P+Olkj1VJQKCtI5g
6Zy6GVz/rHP2djD/g9EqFJgcbVy4GsyfN1p/JgxiclEAWonB6wJZDIN9++EVLKO/FElFjF//+iBB
TYSeNWq6aIUsAIUFPmwllj2F6LD/8IFDRyuFyXq14r3tYpaUVIpSJJoxuQoXlkUTq2UexeTKJkau
LJ7u3L2JZ7eq8ADN1PSA0B8P2y8/7B7/jizJQypZtMhERCcjzTbRIBiuFZ7zJf9yJCoq1fcTqjr9
34cniGp20Ss0Yny67x7htAwROCnFRYBsN128c0ioS/To9yBKH9j3mgLqQZdZuHzwZsVr/MYriUp9
thWMiFQiFT/acO2WyVf8AGCZj609uEsHwdRjzlrSufs55VH06NiGyYDFFaCc2A3MBw4zwDeLyyDo
YSsMdQQMs4DolMyktdkrFXomYq613wxrr2iHdUOwDKPmTx4/21T2EyisxSlSXIJX5MN9m3t8EDa8
D8fFRmxBrbY0ykpVLKkkMWmHahSmUKDBI4cgfwLb25Pf8/rv8of3/C7myKz7vpDr6ArT0KwrbIsx
ia53GE3/qVLdH8oHDx3KoDwX8y8xjMZNvjRPnEDXhZcUOS6gl+zIr3JJIF5TSSUXAQOVZBUmIZ6D
HGKsf7fcXbputBJhZZjNYPhrNJekttjpsn77wzCY/mkKjbKgIoel7GQmC/aDNJfB8QEmb8fPIJlq
hdih75JXTRgt6JM8E+IEqJZgBbNzYdkUCYNFzeh2SgKRlMYymRp38ZYpQ/gKIBW6tnKjKNVZKR/J
IRGmlRLBW8mI8WEaF9HuG3+pMJn6IAzuG1gXWWEQURs2CL4nwxAsGZ1kmIPUErCxQUCBR1f4Papt
LX4xotwG9Dv5iriKceDVgbYZ6YZisOynzZhKaVZNfdT0Ls90xeaCnp8XsQM4V7I40gsR5+U3C+iK
MZMqQC+G25uZHK3dDWA1Y82GxKpI370tAQz0EhmE6aBNELsy233yAcNNHr7H6EtxgnP+RufcXTyq
uniLQ8ei06ZYsLCx4NFH6MQDdqxCizlqi8IhxUrFoiM1qZ4iDWPEhbAJW384bw5ST6ayhmgw6nvC
ngPv+iFYBFy9huCtF/7pi/evWTht6j93lTB7Ags8IyMGRviJnAnsQtf7DOO9IxVkRCGFUYqw6hNK
LpOBljTC8ACZJfwE9uYuCd1uxsdb/igzDiC3pBnpl6ooYFQrdrbP0ZB6dofmO9TaGhcpBUEhxQup
K6SyBHPf8G+snmwPSLlR+jc0qZGTS4jDo/cu4WWXH3/DJ7T59PVPDy9JmXK7IR+d0GMJ0M7s27rp
OlsHxTicBF62Ph7e9FMHPUSzuxLXJLcNeW3IaUPmcrciIdA3na1byRgNWFtbJjyP7Vi9S2yvN4zL
q/k2DZ6lHuw4i5ZtapWuQBQyKQMTiiMz+vQ6xY/j/WJQCx8mMePql3jvXS/REEMM43rmuUmMEWS5
dvVql0HaJ54EeKT6/J/7hrh3GBO0042c+MUcNFXyRj/M2jhE/gIqgSOQTI+tu3rClxAt9IzZWzqN
Ik6vpJ5VOKKaZWRvnJxJO/feB+972KFyKjy7/+ppeQDCAYnjwbXI9QR0qPoZaJsu2+Aoi+WKlrdH
dJHkHU8GXLYzlStt4Na6Jb8Mu9UMrdNbJoHTbcg6EwjrCN86HRpWToFWhYYocsDxhQNhejh5L22q
pSszvj+J+h6PoZiqu361NE0eoBmvvANTUaBWeFQvg3qkD+pikVWB8L7c8KAfj4tVdYorR9rFEUV4
SwImYKJoc8r8Fly5I7PDXWqFmWK4DbIKYGT455+JNOLnfwCdMnLdxtJ7a6tfq/RusLsE/o+XnAnl
rcQEy5vyQzrbKxFLuXO5AenkMSkvz5ec16575sT6nSchgxkd1RKIbdUTNoWK2NO64UMjayungpPX
SY1TbVNptrEsLG4c+xBWIUyQRy+T6iSX8gnG/efE2fJP42lP5U+COlcrYRIzzq9FbErlJBDxi1p2
uX+OjZAd1CnpDui+zCTPLURdj7EoTT+jEsf1obRIwhVRRVo+BE/wnJW4LoVUHBRXNLLeN0RzU7aD
Exm04XVIFas1O0R/NJzV2v/3PPzrp9n47tWAhPBtIjWNCEnOZGlnRGcyqbDeTDKZzbyoceEtJs5X
AUtuEuGEPHWYdB9+2Pn0ZmdlEbniIN5bh4yoWmsLE24tZuaU3QeL86iQQpd0zMslgzJaXbE3vR9+
HOsJUzJJ7orh93dPgIqEtGTlydrKCjyEXYGLxiiI3skrp1RcrXbEB2+vkIdxgDAWXNscMSarzbrh
TFRllF3MZ/4neF1xSiJtUTNmH0pRM6AA4x/8XammashEpeUV2BXmNApTm0UMBbxBSq6Du89N+80x
vLB8ZmTsrSyeJd+Ve6GM9hmrpBmvoB2xI3knkzNMRmRohIAu/2IrU1iZ+hKsqYQ25Ngr2j5ovsM0
Fv6kM+VyC7mQB/WvlDD3Hjz4xkHRH2rNf9x9cL/28ze7D+9+XRi9+AB0rBsZJZCLIA5rDsaIiKPk
AFg89zV3c/2ri1KME7MnkwLgAkWyUiCtMI4xxpX8pCgxjziy+hFgZSxDO5s8O2c/BAUCjyHhZTXi
aFXnxFedhYXO2c8735/iBG8iGerdW8EHJ4c4R4UQ1xFOjNvRg328gPg2m3opE94nZBjmYCmbGR0d
zkVUDCqqlWKSKy5Gnvu28+0ddZyL+9eQnRgdqO8VwEZuACm+TFMFX3uDnyJRCi2K84qduqFiIiHx
pmdtCB+0gpL9aVfYxyVCeUgjG5H8rKhIKi/3Q0FMRpsUykWUqtJOfWI6O5LbxYHy6sloRnEvLGmb
Y05hqllL+S7mtQrv2saHeXyYeAEbSPathEdSSm7D7akoX/StDLQEt38K8/GIlRSP8iDCwpfGUVEv
yjd7GsBLClOwFn7Yv2wIX4FUOVZ3MAfj1sPAQEyNXWJ4w0F+R0G9dCyDfZERnppK0RqQo6U+oVgq
PkwXm+Wan8BKPam3Beoqy705iMW0g2qDyELwjMnqCp74O3k5lmuUizdA1jF1Mb4foMQy8QmFnkXi
x31hIyS1FB1YCSuKx3l6vGVFJIP13or0uG9Fp1n0GimWA8N69FRKh5tXkxPUgIFs3ObqYp5yLX/m
InJT8WWM7FdgQIDwwDvXz97DCCFKhCkPP4CYdBvNKw/m1hePdR//uP7JaZSkrz0Ilj7j8w/UAV59
POEU6BwJ7oFqJd+s0Mg97cYzbrS/Ah0sXQeJYuOjxyhQiCGhICPO/C99b7RkV9ABbgs8womyDY0X
5RY1FAwcQULHF6PpvT3rgNURbJ49ZrzHXnQwYMbPhyvAkIJ7j2F4wdmrweVrIucogyfmGShpnU8C
Ba3Wj+YbsI1RA9a7vPxd5/xfMQUfNHr/b53TJ7hveMIp+MQq0FDMLXYQR1PSubuGN+ah7w4pcLXY
LLkpOtZsmSL9VIryOsIo2hHBm5E02kLs/A5jar9rYVSVBFkGJP5a9GUkF7kwJoIQmLSmaEtIyaZK
ejo2tqTS6PT5PNPYuEIeK/hyVHgrqhyYSgCI2/WVEXVRuXgdcQOhj1LgNp7n3XIi/DMyifhO3AKa
sEj1tFilTQBKf0d1wFp4gtfacnF+3pB/Ds2x3IrfrLt5xy94nrgLfisypK5ijKXOkIMRDA9zw4WZ
DXoED1B02bNH15Nqd+NZ+iPGAZGfr9fgWJ2yoR3oktLS0PG2A7sPHTKNvljHCAAVhF0rRFir9wQr
foouGxtD3V9VxiS4clwGT0cewXdYgup3LxYLIThimRSWD4Kh50PQXDLtTEn3Gvvukxjp8hcoxQOi
CBf+JpW+QUrTErtcY+PCaufu50yXN967s/7ob+osnBytdOeFvoiYHqkhVJ9trK7OxcsKTmKColur
oBuKdHgU9IgJ76S9AqMfyQrVmT/HYap8UI+vzokmoYh0Gqd+WjqKq3j1+sNz3eUP0E5Ph2ij3V+K
AZf3SgzAPWHxXCpjoEALYnQjMbK1CERCfwq3sUbcxBEFSQB2RW/0UMXo+L4kDi2TstaambJlYvIi
M9OrTwgCkiQmgWk08ff2XPtZhogj0oZYjA5RB0MxywPIPWdvMoSRnDrnzndosckuWBQ5hYQXBLBy
4UJwGpMd6rkP0biwfH/jOCYVwhV8/AEHMwdz85wQEbgzupOozagpvKiog6tfhEkU36RUbnRwNsyb
KweGKMjpUnvu/tPWBmbOi4BrFq4OkOzIm35ALuAtm9UJDcLxZCR9eUKcl8lNGDMnmWyZAaTuyacn
cF8kZsNdpzn90KD74AyffkZJiSLMey2Goc4icvNpCo/MQNlPOuYMLirSNjy6GM3s0q+qOJwe1omn
ruhXqYJp+rSFGcYzPSrd8yZzkrlItYNidEm7eC7uDKmrS9qrZbwlK7aj5GM+hqkyd6tO5I3vPb1s
dhX8P9WLZB6+rorgqaEeCYKxsUejRBObMvxsJhyg+fpnigYRM7Yy/g606vIUVublkdG20aKEPWO4
jVBz4Nuq6KmQ+bTcL3+hdKT4zql5qnzn0yedK7Nrj85yLa/ilZvlvJI8oo48KCGPfMG+1TWNfnhS
9ibw8ugIggFdDpOOy727CZ6p8PsQp8OI/H7YrLkQwiq6X6FfJVhVQVDCOrqVNVZ8wtWF7ulNiD5d
RydRIozpwtR1Gag0nZ3KxQjSdBQIz8Dwwhl4vrbt+16BrbB9TDcOiOQTcSCShBBftd6svf0XjS+m
1KmQuKhS8rkedY2OZlE8ZtHl75pKJhRfW14npU2GijJ9ly7F2O2sz3IR0SZ3v7aja6mutRLjUUkI
yHm55S6QFxQASCIXNe2Kkt3ypsRWXMilr1t4R1d87WDfauipyAYa2HtnHbterD3Uil0xDju8/6h4
JqkJdNaSLt+bp2SzBNAhXgMybJUMmu7HCebvGZo91Qiu3OEQkODGue7nX/ElXHSZ5goITp2TN1Te
aJWzv3PpXQw5Fcmh5JVeN46vrT4KfvwhuPE+3hd0fyl4+O5WpgViznwnRiq8FEubd2HSqWDkTb+r
iyaQ9Eeu0nqBIZCJCoqijUwMM+KyiyhmalWEnNOsyHc/eyopgaX6eOTd7aK0lh9NA0FMm3yGe8S2
vo3sGUcuwlZ7TIi9t2RgRMPT8W4rjR+N8Jl/xtCo2b+qzUYxavYS137RPQMYyyQjptEQhlfKoh2O
L5ZAT80ivJpFVy9GqXeXP0W3yeJZPANHOb0wJRYFSQUL5zcuLrJKwHKq8PpvHzH+fuxDYwTvp4ze
8eLUangXyfz93uA/PZtkbLwUZAgaycrHGOKkTxXb042gYmBUkHdgfGD9hxRXnaXoTqoPB2j8Y/ad
4NgcaL7wZeOjx937y0gbrtwLPjyt0p3J+20u82VIfIARVatjZzCglbTbviozp8nmOWkIH9ot+Q40
unFs7fEpIEmYIlKFz8kPCQPo88egltBUE21TRrz0mmZIvrPNQ4d+S0DGlnAf+JMydHj7f6Te3Gds
fPo5yHJmT3WQGxyfQhjVXVDYVRjzxOGchPbiEY6Rxqofp+xdCBkkEwOA9NO3uBtx+QyKkuSu56fM
odstGl3cZB0BL68e671459CVWVZ0FTqJG98u3kHSTxGvqKHBQgDFX7jQufsF8gw2sV16P7wIdWsy
Iy5YwT95kXqwrNm2NGssyIoldxrtDHTfAkiO/DNn410b4+hBxzOldGhprDlh5rIyWSN7gtfvnqBk
vvP02mBnLe7mxa+6S082zi91l2913pujTJibtJjMxQcFQNco45gLKOjaMeauXh+ZBEpo4OSiyNfn
Ugn4GYJDEtPo4lG8WH/zDA0yHiiG6QXdXqzXOq9Vawl1c6LZXb4pYquApNCltzK8CSgSHrN2k3QJ
JzoS7q9CCeVf5mrsUei732WOyfXV20hXqbZe9aeHV48O7cfTMmYyXaoewXDG52wTFYexuutM6Swk
Bmzb5kUIk8lTPlOy5+kBY2YPfrlFTxczPLvmFaZIfgybz3o5u+/aWJEyPW03qhMTEUV+s9Y10dGm
PI2bvIx3UHTZ29zbgQ4rCXeRt/O1va/vPbwX+NG1jYs31H3HlL+TX22avhM/0GV0ePExgcrvRMZU
sbXyYni5fuMDlqyCLYLjd5G13DsW3Pim8wmmcRWjP/jG4d0wei3pKD/ZctD9bjbjcYp7zSwjoj+x
Z1rdS7B+9WbnozNrj67gcYxyUZwCiV56HJcpZfKshJ4pi+MStmkbNaGGaxl73/hN/A5CKRqgZfJc
5wdMh6zCDjHIkayR8HbtwefBw/dw11loI6LwBk6tldylLMO/fCnatRa0/zv3KH85fLTWN45fy5Fk
PUPWrRjVEdOQt7QoStI72B47thgsDJAME/swq1W9WWsoy/pblf8WdLQOtw8nt/0/UEsDBBQAAAAI
AAAAIVzogyn+lAcAAB4UAAARAAAAc2JtL2VudHJ5cG9pbnQucHmtWFtvG8cVftevWPBlyZpk4hS9
hIYeiiIBghYI0BR9YYnFcHdITbzc3c7MymZdAbETJZIh20p9USzJidXareM2kuKmMS1R1o8pd0k9
6S/0zM7shVzSl6Z84c6ZM+f6nTNnt1Ao/Br9sas1Xd+xEO3WNIpNdxHT7huMuxS18RvItwjXLFdz
XK6RjudSriGnq3nU5a7p2lrHtXwbVwuFwpza/pC5TvzM/CZwmpixhNJlcy3qdrSq6VIci1TqypG6
zH6VOBxTZHLiOjHvL5FjYtvGluKjvsNJJxH1G7mcm5uzcEvrIOIUS7U5DX6m2+kgx5oHE6qIthfr
Zxvn4J+lhLdqjYiTtBLmeb2FublQodjGiGGmS1nilzFT7RoRb2xJtEi5xar4I6GwdI5i7lMnr0vJ
qfzBhyRUGEfcfx2N8kDCLpcv0wl/EHpa8T0LcTxdG8N2y5AMsS4lQENMkxuGoiTnpcKJ3WJkTN4K
z2/axKwQb7oBDuYXXHre8Fzg6qY2OC1CO9iapTvHoIKR1x8hD7LsIUL1mkcBeEWB5KrldzxWjLar
cjtyof5mo1TGDvMpNhAzCZl/F9kMl8birMSz+Uu6QmmliczzPjipEB+j15D0ss4c5LEFl1fOE8dK
2WKyIcjlxE350z2QgivI524HcWKmx6INI9nIiGceMvEU+RE9pyC2vm3mLW+bOXbpTIVhZKf8kmgI
YjnmgF5DWt0cjyTPEgtR9WzMce5YvFHWPexYxGlXLlCS5VNkIyLno6gOmVBZNH8oIpeTUJiu163Y
pMnyERFbBmxRRAlmOT0SasgTgvWaRJZcLU3gUiNOgqFaAmm5rquHxkxIx5YSKwb0pKHEwvDAu0rE
7B5hUdQCzPiwpt1MhUJBQB3Ox3IjNkOxJWWScINIvVIRVaULz8R+vtKkyKmllQjCNogSN5Jkruv4
ImGc6Q0lTg+f7ITbq+H24/DG+uDgweja6vDR8X8+uqJPyIjPQ4+hvsdTAfLE8PBm+OUn4cb98F+3
R3uHwY07p/214Mbe4PBhcPTncOevYW95uP7paX9r0Ls26G+Gt54FVx8ND44Hvaujq1eGV55N6mS4
NgYHqa5VmDD1tL95KbbNcS0BKUiZ3ljSBr3HUvJpf0Xygj2jj4+CteVg/R9Z1cPNT4b9O6Pnnwer
e+H2P0/7q4XSmO6WSzVHJCKrKQ1iq6Bplxygog4Wmv8UreKLP0OBs2qlB+t7w1uPdJFp2MEOasI9
rTcixzU9uLwtdpcydrwYcC2oO0wjc34I6KYihSICNv0O2T5+h1KXzgBNJnsyLLEgtoDe+slP9cbL
isYizEQ0V4LSarX5ivXn+bSd6WZSRER82R0vzyNqLpBFXPFs5LwsnorXIM4i9Ag3E9lzyZ2BFrGk
nm2UpZDJYLUKwf6n4X5v8Gw5WLl/cveBdiktuRjRh0fB0yeynmL0rwXL36aszS4XuFzSgm82ANtQ
bsOt3eDodrZKLAKzq7AT+DL4EhhvERtnYS7WmV4BHfmMIMVIf1VwqgixOC3T8hvzjGVpdpo8xBdm
zHu2ayIxBbN49kkSM5nHNGORunrt7Re34Prbtcb/2oYn25kIN3UvZKMtfWrUJm7BpJzcC3XdRk0M
HeWMDhnVz0QkcQwokJ56sL8JRTm89VW4st7Qk4IWXHE1qwajl0o5NcJjDn5iHnkMx9LEB7tfntxd
HhxdGx7tpqoVd6M0pVPrg9534cb3Cf7giPKTY5EXaEFGDEUiUDZVyOh4fbSzFm48DI43xoQwTBeJ
iQ3bbccTq+gw6tjw64OTje/iOydzTIwmDkyVr4BdOXzEc9ckduQwInd/0P39QpS4PgeD8Lw+vL4f
fPPFaHcfgnny0ebo+DMo/XDj78PVFenl6Pmz4e010ZLv9yBZUfJjp23cRmbXAEfFEOM6hu9EhpPM
jSOF6lOv3GB3Z7S7c3LzuWgjyiRxiwVHN4PVa+Huv9MGBApkNpe08N6OtFfcd4kpiHFjAbGF8eaj
YpYmt90BSQKuokwUdYGIltE1OAxlUOLC+Fm1AjZDo9y/DDED87LdLxUdTQiTDVTM3PAONO6GCPXn
X4z+dnnQuw5RCK8/DO59JgNWOJOzQP6KBWi+KkHbj2UgspkCmcP+QfDg22D/OZgYXP8q2Lov5yeZ
wcLrZXCGGVpkxhZU4tcw5QhFT5+Ea6vSHqAMju8Nb99V4InMG9M7JeRTGsjMd/R4rHZabqaCxHJe
fXxISqcqqMXXrCBxZrJ+VAdg4v2k6V6EK0tw1XWIF4PIid4JgIRhNTg8ENPg1a2oQehlTa9+6BKn
KNk5aoueNNVJedlgp02c5CVffD4Rb/jx1Df2nq1eSCb3wF357QUCFX964bRbk59ioiW+aGKPa8Xk
U05Ze+f9d6MxrJRGVPksMH/jTvj9igBsPJylw+3TJ4PeX4L+x2LSLot7PPqcw7iFKYVZBZ7hkuDF
n/18XHU6+JV/hbvy4bddT5F+waFSmj5Xy/ccC1+Uj+9/IP/TL1vVD5JH6YEIGBZPOVdObt0d7e1F
mWGcFiOm0guMPjtmM9jZdGFafE98ExOvKzn5v3f+P8E6++M3S3P/BVBLAwQUAAAACAAAACFcyxu6
jfEVAAAiOAAAFgAAAHNibS9vZmZpY2lhbF9zY2hlbWEucHmlW21z1FaW/u5foZDU3lZZbmxCSLZZ
UcUkZDZTCckCmQ+r7e2Su9W2YrXUK6kde7yuAhKDndiYbAgkYCaQgQkJwYbZZDDm7ceM1d3+lL+w
59xzr/pK3TapWleBpav7cu55fc651/v27fu94zuhHTtazY7tkcD3ZrWmHdoNJ3ZCrR6EjUirh0FD
iycdLXI8pxo7NS2o192qa3ta2PJjt+GwSDtZnXQadnFo6HighU4jgBmrQc0xtI+dcS2qhnbT9ScM
7Q8n3z+uuX6zFWtBqE20nCiC+ZphEAfVwNPcRtNzGo4f27Eb+EXt1KQzRDNrNQdmccedSIvisFWN
WyFM7gex9rEbImkNG0ipRod7xMG46lSE1Niur8F32GIQzhaH9u3bNwQrBWEMNDZn5fOkHU167rh8
/SgKfPkcOkOcC0WxYU20n6BX8bEahE4xgjXsibSHGFBxa7ArN54dGnrv6PGjvz/2VuXksRN/PHbC
nGOxPcEM5rlR7PjpQwVHs/m095vvvnPs+Km0d+SE006YPsje7xx/+8RR6DTu+rWK64MM63bVgW5h
0IpBAJWGHU7hq9OKnIpdq+EUvhP7EfyuuZE97jmVuNqsTDlOs2J77jQMHtLoh+U/5BpowWnbE1/q
dhRXgibfFL43Wl7sVpp2PKnM2apBR2AYCh364SvyC8hFipw4aCGJ1cD3QfWUTy5QfbDC94nbAD1S
JsWPh3Ifmfpa8QNimcFQ93BqoovVAtSWCnQKPM7hdFKY8+MgnKqA+oG9TMwS53hTPNtEdtRtzxu3
q1OV3dprjmfPKlNGTlyJZkHcjQqQMTMLEnz36O+OvXsSRAgCCiNWYp1Ld9qLD7vrt7obZ5BB0OyD
eaZfkosrSAk1ta/cTp5fgabO9/dxb3YUASE1+EITJBvnOjfO9CjQWDOagq87332aLDzY3roLHXb+
57ZYZ8qZ7S2Tfmi5ON+HH77zFrwBiyKwVGhIVla76+udpcX22k/qAuBJJgMckXx2AyZpX36UPFlF
pnjBx0jxL2faF77v8RKatp/c6D77svP0i87jNVQdD9lw6t2T6qwgAz/iEpT9u+vPOk/XoX8wXscB
7YcP2w/PifdKA3xR2ti+c5NoEK3d5xe7N5dla28RYVuSt2sryWc3k2/uKOwFlYHhDzeSZ5/C+2QQ
cXo2H7fXtkgucTDlIHe2H9/qLC2DfIeGak5d8+xxxysAf/VS6IAr8zWSuwVNRWCMExb08jDTCmwY
WoaZzjS3rikfwYeKIZrjRQ5+ElNHThWmpLn5VsQCtj9bmMFh6izg4DXeWOjpisF1oqcBaCLuNKh8
hd5oS+h5cCGm62JhYGYLvMcUmFkB/xPLR15rwmR2Kw5GYDPQzlthN57jF/CjfuTAa6W+XlZp7FXg
ALwJt1yMJu0Drx3iUxcdH4NLQdeLk85MzZ1worigW6VDZXXHrNoCZ9yAKXB2oLLqwR5FpCLikO4K
+C03rlQKEN7qBoZBvYSPRXw08b+htK9wC9TVx/hWc5rxpDkqNiu2xhuPHBjFGIchyo1cP4ptv+oU
aJBbjUHytguS+6PttZxjYRiEBSZCXfLkKzC67vPz7YcP2ouXO4+/bP/50+3NlfaljfbyGaarS7FX
QqfOaBVfw9mlRuFz2hM6mdhgUf+yOkWOQvhugI/TJfEQ0+otz2vYcXWyELKX9//HK8CKaL91dOTf
7ZE/jY78c2UEJGXAOIULfNG+DSarPyYLZ7rrm8nTL5OllWT9a/AHmtz2uYWdT+7Q5pVNovmZMHkx
anpuXGD7mW6NjGV3AF0kC1LRFSfADBinlRlz8y/kd+fJVnLrgbIwCBsilonC4gIvqtLnS1hi+rKF
FJRJGYbH9PwcxVYTujuFuanSNLe5KWNaiqvogvuP0KLBwF8yST7z6gxcmjRRTxOn7dAFxBPtqYrY
bGZIxxZ9kKruwZ3Fc6B4pI053Qt8531QPql4WeET3RZtGDcp+1liXJl/mU6Flm4JO6e8LOc5YeEc
5R4nJHgUrIgAaSksgK9NM6cT2OaEseuQYvBGHIYvvf2hWEzsSoP4e3b/XOOweXfmtdd+bK9e3H52
LVm43bn7jbZfS85vwUN7cyFZ+apf2ebm05Y6t7+aM5g/Uc7W0C1yC999i4zgSPoKoArilZ6ZBnal
uAKclHwBgOe8I7DA+MtW6gHmRo2Do/PMUFx/Vh24IQDiAZnZ8EiTW2W9aDcBI9ZyqrmL2ldBiF4w
wUWt+lw/IiH3lAFA4HjQ8msgs8MAGfu/Q2PaIQw+jkyrnOE9pw+JirgEAGs4tQIsJA02t0mC7U5o
AtgrzO0C5/8FqIgL/kAZUTT2pZVEWcE0bUhzaiYShT1wR1wotNrgdOA3roZzWThxWc9ZsA0pkMk4
9pDb44sSMYQ8Cgwj09cbnc9/6tz9vHN3I1n9S+faF8nFn7qfne2cfcSkpaQz8GEM3e39L5KNR8nW
pc7VT7vP1zp3Pk/WvwOsiZNwK8kpJ0pJassck6JkJS4pZk/brocJDCsNIBZzHtwOK9Fvo09D0x/J
RGlvMB9AFZIJpCKeC6lK7iOykLNZKrW+1/y1oNpKk1wAh5Nx3IxK+/eD4U2MjAczxQgSyBAAcTEI
J/aDmdbdiVbIe+8XWr2fUNIwRMMBsQL4JEAZ5HTVADZTgOzHDlNISEmpKdJX+fHwuANKAcE2l7MW
RENR9uPISDZG3NMViAq7DingCyeQEJDWe8nkowY40e7G42T1ssQH7St/J6SOirK1mqx+0bn0bbL6
dbJ8+dcny92NhzvnV9qX77eX7rZXV4XqEHEmzVDg4I58CceMZg5bYspfrLUazYh3NdDoEfVG5qmw
5RiRg6URyO8jswC2ZoDoAIEOxKIqDiUajDkm2ZImTZItosFgecaxErEIDJtPUiFCWYnWkelEhbty
Hhu4F80AfwQdlnD25T70MTBaKJBEDMT+09ycEKPwQDKfJhwe5c9uWBBb5VZQjWcEIdw7U31ooH8m
5yO8dF8/xU9TRz7ny9p7GIe4goduA/QK5aJFLWizAeT7judpgq/aIaFpWBtyQrAyzUYb8NFbcP9Q
HJI+FsJAwTbGyT3auG2gnr+Mp35XODTMqFLTm8KvihzGKWZmWqyp8ktmBgAqn+2U7QLyiFU4UQNs
I4udtzfvtf92s722lKxudK793L5we2dhBZwreFY1Mf/1ybWdtdPbm18C3t05fRb6gOUARgFDai9e
hAy4ff05S80TPRtfXjfNMZlW8AZrlGhE2AscY4bGih8Frl+YGmYm5FtxWJjWX7xRTDEYEAGJO6FM
jca6gPsINhokDJjB8cFnYuVFkJRJ9Ygo0LhidTIIIqfAdk4vtT//gXJ2iCcIvNLYsvAgubhMyVSO
P8zgO4LJZbb4dhA2ftdyvRo4qF1SRqH0sLph16YRONW4v1AAAscewhfRr8O8CcaY8I9e0sHygZrr
ruPVEJ3Qq+fY08DzuXl6BYeAuMBSADEfoOQFWKbIw2Jwaia2YyZ1uGr7ge9Wbc9UagOHwcgVQClK
WSAdMB9ATKImYGaKAyindLJ0rZe1E1hu1HhxuQUMHodwFrTAjriXg67QjnyvadWgAVS5ZJaiCh0Z
mu+AJWtiJaQ9KqazczjqCHhHzOEUp3RgOEZtRg6YpojfjFsnty8xK0clCgSU81p1ronAS41XkXkr
N07TpExEjhAWI7roR8ayADGdUDxYUgNyOpvqKRgDKwq7Qlnpw0xL8VKq2VSeY4ZVtxgvKwknX1fI
LevlXckE0+a8kFSNlkngzgwVSHOa3NNmrngSjhWylBq92SyGmlHW89iSSjSvzLHhvr7DbJ7lyVVM
QT9iHjo4CC3cvAM5VbJ6tv3V/e7fFyBj1Q4d1HZuPiJ00HnyQ3IfUMMGsDm5d6W9/kt3+ZPk2s8K
yKyjWbAmOaH8quCThlmFDWONvzVeYNZ/itynDHZRgcSnZzu6VTpwQMkmzDm+sRLObwgplQqs552Y
oqACywuYrGiD3lMHqh/OKAU8YjuA3P9qIdxlJZTbvMpFhh50l2S9LisUaOYm9TSCJiLOSNSNeJuS
ITgezIk+wmRY9wfAyvacU3YyIFa7jVZD8S2ihRkjB8YOvn7wjVcPHXwDVWgm349amJF2e10fSBCQ
Ov4iekSfPckZc8Ze25MQ3mEgCeNBAM4IMB6YJfed5V7boP7Csard04osV45eWVfmXbwSj996/tsU
jaQ70lkr60XOAMNp37tFBtG+cqP9v18RGEjWl5KFO2RTvz65mvdFmUKI8KFIvHAbZfNtGxbLJNQQ
yVH7LM7hdx1/gh+4wHPFoxfd4KztfbJn0k/lrDBhUTtV5bo1XiYttctK1PlA8A9PDO1ZDRDuCK+n
8LQZwCBFlQgiRg0hI0DOuguBR9QnlBADi6VikWXGObVgzpk+30chE1MxhdK0TVDce8+M7tcMTraw
YbXam5mSF+2zOkHEpsdG4qhoXqgIFe1HYkgmWBatkNeT/r2ekXfWU5XU0KsUeDIROA0UBEr0vqSV
h4I6P+0A75+CmXHEXoPAzF6V97EDu4eHX5aT21dEeBg7oCUPzmbCw+DA0Cukivxk13oqJgVTUjiE
gOl8BVDO+3U8uMT/4kleG0IZoEQCOuxEBgE2IUgP6c4Ly+mp4QKo7/71DOH67sa97UdLEt3vYbiy
hKE4NirMGr0G2A40ZK1djstSJ6OFNYhNaqSSw7MKLzIJDLwzannSmMngT8A/3Qc3KVkAsvThAhM5
g5JhzOgc8GVahL4zhRBBcZYOtzZj7gLMBuExzB844KBDGpk/kMdWMD0tPzoIA/F+pOaCIguIKOc1
HeBHJpr38vL8oU+a7Kf9B0L5YPwjyNu5s1ALAKnucoqPg0Zk1iWfZIehPZuLr1VI0mMTfHZhzMgE
03d45dwY0/tKzXzIkTcGhSTk6Kft6zc719ZTOKeGpO3Nz3a+udhfvc5wvUQ0pfK0o6mCyDd3EWa6
IjM8SFRqthaV0uEEGQqRsecmEVEU3jAyaEF8fQM01uA0DUTDlqIKveF08IB1Ga4Sw5bMkMtZ7aCE
GcUX2v6EU6B1yv3CE4LPSg81INr9ACHPZsqcYMigysST0+1Lz8AxJQub7atnAVQk17aS9avkqrDg
wGGGkOb5H5PP7hDk2NNbEZ8I3VJdO6U1Bb288pobwYNUzSxkr93shrez1230XhEmnqQOuLKe03vh
ZcxdK22cU7tV1eYzs/FqozXVixx8LD8clGFf7onKcbI1JYM3c+5heYWX6zwIJlk3F7UmsICIlQNl
LVycluLLEFf5LHIVfsGIVugrcE+plxPkBRZDhR79dwwQOBnyjkjvzsE8LNo3/4AEPrOkAkNyu+3z
C31zA4L144KSkv2GjAwTMnAjudSX17SopkSRAbuBZlMMgSid3LybnPsGA4ewh2udH7a6N5d3zp/H
XP7Cne4KWMLyqLa9uYKpKk9YIYv9x+mzOXeHP1Qlm8pWyFCO4IpKtKs607Q5d17X5sS1E30eqdas
5PkCEFNm/SKXwZJ3I5KUbqnypP2ydPFTWTuEyJk/pZTCAKaOMhmzXqiB5f45/JpbdSTYUHzzTBHh
crOgG2MGJvA4n66PjPWifiTvERh5m8CfLEkDGcsN2KXKMKdCk8QPplfemsyFIZI+P8d4+OuTRV6Q
vQLPgG12rl769ckSMzgP8ZyB1Av9Pq99wbrODIhROv2sUEgDR5kurgyRQxiARtIRWRzXis38PYXU
t2QuK+T9UdaR9QgT+y/BzNZU2VSCHPdt0CYC21R5F7yjSAYmyWcOvXSlkKt3ihMKyJxReHT4xOu0
/LScY5uSckxkBKE74fpm/tCMjocFpJUn0EQdXfxMTyvkrc+jbx394NSxEyd5H9xrjGcgc3ZRHHrw
m4EoJ7vIT3TTwwY5sDiNAVVw2i5GQSusoivic424PiNmQ4pVc7GoAabAr+tqIZcI0IsDQ0s5FS3T
Ib7VOzhNk1lJIRUClXtcmd667C6JJD0nJ8OSh3+j4zo6mGjf2EyefwLukXhq9R1+lQV65p6SrkOA
K0zW7ifXT//j9Bk6SIaH9o3znXvPOpcedNZvdi6eS76503n87fbmaXKjPacoIjWSnckIsbHHpkFw
hV9FInrTM5T25fvJd38G+uhYm6hE+lY3kgU01u7qGlCsjY1qycr5ztb36q6TixcGHEXiD9e7HjUD
TixoHrneYnLhWyBo+9H1zvcr1Lj9eCVZu0Nn60QE9xVWVrCpKvQWK+tltYvKNExaM+NNumggFEbV
oYyODbpTpbIzvbOWLF5LHm9BuqqyU9wPEAe1PMYaFNzNvc4UeXeANIRryMPg2IG4laomsiPNvjvA
RYjsRSWcXJUM0I2XQ69fwXsKG2e2H/1V3mK12PbT53h3TOpmsvAAXrWjb753TONXVvF2RHIRq/T4
DhLdfrwAuTm8b29doLtw7a8vtC+fT20BxVnWTZOSRd8BYGlZeIGalWG9Vo1+47tBb+WMGrWXl0iH
uhs/w8ziHOzeLWFo6bEBv6LR28epNz+A+T586wNtv/ZvH77zJrxAkzasQROQkzV10lEqtPNVAN/8
/y4xiNsD8gRM3ZBYh2d9SCnBEWrFwMlPO8kb0CXnzr2lZHMTOCz7gHkwyDPSuj+MSrkkD1AFn679
nNy6KsdhorKzdpr/0YKUyljq0mtOaCqng4UBx4BCtWNT9C/KahbXdauc3uPXD1fznUhXeSeBeDN+
TnamMt0uRV0SOfdplGGJW+Bif9fUspF6HAypWfcvC6TzbGCgK9acqoeXIdzp3p86OHUndGDfEcUm
QEJ4vmeDNc3VxdFO72gqu4FsjXVwfZXbcn3A6dS8yphCjwxATPo/Ka9VeFWoUrDpAPat/dheepYs
3t/evEVnxmjmYP8ZDi6DdXc/eaomscnCT5AAk28DFuO1FEL+NJDq7IuXyW+orJeMBgZxBAP8UvlE
520C0jNakc74wfjUM0OOpZhGFKf2ThRr/D65uAKDl3jmGP6Njx2z0pjB0BhZqe8ed3piRcaKUYkc
DKdBnhAs0X16HNr7o4Cx4mhxlKl3oeTpSkX+6VBpV4BgyMI2XWcrjb1+8OCr6R8KRKyEvlH8fQD8
l1lFXOGK7Qn4iDZEasZKWbVLL8wBrG16ECVZKYrTO169xio0tkJXaWFYQeOUyx3MZ+0EzxIqDdtH
LygthF+s9Dx5KQaf6aJRD5pmbg7RHWMulrLEskED/5KpYIcTkXrFBlAitFijZcyQOd5N8ysBf/n3
sTI5KHw+UJaHq/iqHzmQL/llJsU7dUrNaBfELBYByOzgjkG/skwyUpABssgj6uxx5cgIXsficRtn
FZqvXNGiJQzHj1qhU7GjquvSqVPmRC5y8oUubkDt67fbW1hxUm+i/xbQCkYvQsbJfz06cuC1Q0r3
7CWt3HXKHnLidFsKJ8picxkMBjb837y8gFd6yLWokXAAvufigzZx07Hcd8gyNNjXqZgz+eLp9uNb
WKH7ahE80v8BUEsDBBQAAAAIAAAAIVxnzvduLAsAAEAXAAAWAAAAc2JtL3Byb2ZpbGVfbWFuYWdl
ci5weZ1Ya1Mb1xn+zq84pWXOaljW4LhJK0ZJXaNp3SbGg0lnEoXRLKsj2LAXze7KNnE9gx1zc5Ch
8R3jBmJsU18knMnEXIT5MdHuik/+C33PZbUSyE1bfdDuntt7Oc/7vs85nZ2dpy2POKrm6ecJyqme
2mNbxiQqOLZna7aBNIeonm5b/Ui3XE81DJJDfzk3eAZZ5DxxkGZbngo9iFwkWtFTRw0CbTmidHZ2
duQd20SKZjtE0SMptoV0s2A7HjqlWhqh68kIZOSyulUoeh2iU7MLk9E7aEU83STR95eubUXvthu9
FVRv3NBHo0+HCPGRJW4k9+TAybPD6aFz8ieDA59+nM4OnB5KnxoeHPosakgPDQ0OnTs8XckRzVAd
lTlKLDUQN53MqQUwsaOjI0fyTEVukGSoo8SQoVEtGp6seRcTyQ4Ev4IDPuG93fhtdTn84V79xx+Z
b99W5/zFir++XF9beFtd8MsLwdySv3SjPvvMv75Rr8z4c8/fVh/U39z0px+j9JkBFO7eDB5+B23h
v3ZgUm1vP7y1cbB7r15ef1udxwkmMW87SPU8YhY82EzkqNYYkUAhZXjodPqcUIv+DN0ibioz0mi4
MK7Dvg47RRIPigam4s2TsND+mMb2FvmLd4Kf5kCDD5HQIfrpeWTZHpeEVCvX+FJcz9ELUiLpEK/o
WAwI4HpSoC+ScOORtZpnplIYXIKTo6DYxBF1XUUtFIiVk+jHkXXcoimZakEyiCWz0YnEh8ffP953
4kTSUXWXoL+pRpGkHcd2JBxsrAUP9+s/Tdf3Z9Hx376P/qr/8ZCZnjMZGUIhoRi2mnMl/IWFlS9t
3ZKEjJY55KJGYIdiScmC6rod/++SbZZjyGN7hYLVql9dDO6uBrdhnxbqldcHs6XgziZH489TV4VB
R60HeAYv1jgGG/ODlWe1/Yf+y3vgG//hXZjM44FlEQa2FvRjkOR//0+K6/JybXveLy3Wy2UIBg5g
v3wvuLN9MF0K98rh+k7tzTf+twvoN5f8xavB7U1/qXQZ+aXV2l4pfPGECr+7erAyVdsvB7e269eW
g5UXsf5C3sHUMl13ZdN/OPXz1JXwecVffASLBquz4cs34a1XYXktXJrx72/4a8/9mfsQUVRFppa/
P32wtuu/uevPbQbzUwdT88jVrbGeUfsiuHHL3/86uFUJFq7EQl2jOJaiAaa6Ewwu4BKQBAEMMVL/
5lVwZ9bfXGRiFqhxT65CVr3AMg6NWtlQzdGcitykS7EJWTRfNAxT9bRxycEZteer3p7fj4hntmfk
Uq98/MRlLLsJRAzYLSo5r+oGiGZC+S5hgQ2WeWLtuI21rZdUqaVS+HQT02SlWJDMs5ZqilgxdUs3
i2Y8r155zOMgANfv3YhdEs7PwQ78ghFf5Lq/UKI/6aNkT+Zkz+fcIKVnpDvxUTtr+MrNyMUJGfcp
fSeU3mi7ITvHOvJEGD74h7/0gm+5sK1ojhJH/uDEiff4NIt4kPcy2NMKeETO4GKOP+m3zL9GMnSm
Nm7bLgFV2Jq16irEAYaBw6fOwsBPB+g/vKNuRN9HEjyVeoabap4d3Kv4S08E1qdfwT86eeqTNKpX
rtS2n9D1oJsCe0FEBvc0hyZIgPnQewiyfDJg+uAZhPMVHiugQirVx6uAToycm2qqUJiPqa9t+KXb
tN4ADjOXOifIZGeyk+aeC7aT65Q7GWKgya/MhKtXoMGbLJDmIZdHQOcRVuM4/okDHKFFVLBS8q+v
0U2Yfhw+v88NovVufxrUR3RFiLnaVol9qWPHDN31iCUeWbqvLDQuXY7FaIZOLK/VovL3wdxrKmZ2
578Sw1UVj/Ziio7Odg/iEyooyKhUafn9dOg0itdfrIS370MRphEtcpjQRFR2WBRHOZVn8UsYCjME
BE72yXhCt3I4ibWi69lmD+6mKUTGzPM4yakENu1c0SBZUNQFOgWj+5ReQD508ODMOkWL8iWcFA1y
S33BoogyK3GS/ssYkA9bOOHiJI0BGQNUcRL+ZCxcAk6CFtjd1rU4mnCSP+PRQDIMyPg4yRtkzDep
qYM3QFQ5elMrfF0WNUPwTYmSUnlUt1Rnsok+qZxvpY5SMDYh0e/YtpcSpFA5C0/pMN/ju+Cpzhjx
UnT4MUmsqtBt6IaCCpASm0VzFwxRdDfrTppQZCekBAJCxacr5CIA1G1pah7Znj1AOfBf/wDV0l/Z
CObu1F9X/DfX/OpVf2uLo7NWXa4/mQkf3IFhHE7h8jUONqHWr9FJlC8CjkgP5dko8iQCBoZGCQIX
jpFcP9AoE3yhU3oeDXGRCShDNHqRnc/rmq4C3R8n2oQLbOyCwtaPyHKm2TMjKfHVERGSBih4ZYAq
lgWUEkNK9JsZrGoAxpHUJZyzTTgsAGI5hMFrKuhC4IhgAnwJdBqNzj+0dkLUnddzxIF+AxBKLM2Z
LHjQoY3TQwlQWegZ9zyaqCFzZWmIQ0sBeBm+HKuXwbSguaBNwyKXiaHcRKAsERPfyG26oXuTzLSz
Q4PDg6cGP86mz/zp9Jm00jJCMpuAqpxXDT3HDk8xGwMYtczI4Hhn8Egru3ZIo4wdlipSAGwigC4W
KTfvUlvCzdfMYLrrJAcS2xC7vZv+fIlzL85rAInBjcf+4t3g5XojgaNjqJHbovxH+Z9fnq8/mubo
poeUymu6SGWbL8hp3CGWDCD1im4KA8qBoAGb5ipw4Zz+BY+mgu8e45jVAiVINs3jrLO2teO/mfZL
s+HOUzGbFUEeNVwhmvSnq355O7j7E7zXv947+Hoj3Puhfv1qeHU7lsCi3ZzI6Y5UUB1IVW6KHoBk
FulZe4J9JfptF8o5bIdEx8u99ge9vYl+umWuep5IPBXILCM1VhZc9BDrbeQDbgqQYNzdmo7Q3xEU
BGbzkcXCG5uQRKD81HYfQ5qoL65ALUfvoeD1rn99FUgaF8KNpNvCBxz/HaIla/dpuPuS8wiuRsxh
xfEhzR4A5RiiUWpQCnahJXHKZ+zmoxVDmMjpDjFtcAsbpdlWXqbmkKa03oBpC00U5fDdlJfhvR2W
F5/BBodPdw/urzf8HUFhwZ+ZBmgJ5rv/ECp300k5T4+8cEzOtNQQqnTiGDZVC/KqwwuE3DKCWQRD
co6a9/iAprgW9tHFGzUjSS9RdKtIGqMoXljc08OdRAdDHk3RVgXgJGGWW/EhWMHSqjUpWXwIIxJA
+uiT2WNRY0zeyXMgcLVEO6eFO/u1rescKlCWIKaDxaXaznq9NB9u7Nd2S371NmCMJoPIkxDl/vSc
v34NEMQnQnrg4yNGDr75hXJ8TGpbdumkI2WXOjHqoP75DyUWDjS1XRrqbQttLKeF223OHIKLv/dt
sPaII4kazO9eBtIfp4fTKFwrwwEDJ36VwrwFC20ad1wSF6M62jgwlVRbxIjOXE/jzgn3i7b/JRGJ
KSIXMbGw215KtEdeBnIZXawpjReo+1Ljg/59BaGsFD0tQW9X8rRFwl2fdZldueGuP3d90nWuK/85
TrTuGWgCZcZQNSJRO2UqvUk/+gnKvd9IlJOWlgXriObZziSbonBD2/YLM1qO9TGXatmlB+w6gl4H
cEjzUsJzm7iXsE0IZeqzMbcpC9kF4rDCnaIdmd6RCCNxRwrzOw0cXcZEdLXpqkNms/uaTkSHluDX
iDhOD0ejRCzREuZtI4I1UihJdK+yrv4V+aWrKx4ZPBogLPz1p/Q6ojksOA1ptS9KS1SgMPH4u02E
REWavCQKQOSYaDZ7vvfuVQhV221yFM1orIqAt12b5baW21tFB5pLcytHCId8EuonH3/YunfdcTVV
ZlEeb5ZqeyvRrUPHvwFQSwMEFAAAAAgAAAAhXL+XiZDeAwAAgwgAABkAAABzYm0vcHJvdG9jb2xz
L19faW5pdF9fLnB5jVZbbxtFFH73rxj8srvKet1QBYmAVYXGDxUpjpwUCVzLGu8eO0NnZ1Yzs05M
FAmFS0NRWvEAFIhKpaYSApTSR5r25/iSJ/4Cszdnky7gfVjNzvl8zncu843L5XJ9J6DEJQp1Q+ZR
8JCAPpFKDN9BDAYgEOyAGyqQKKBhnzCJeoL7qArKRVxotM8VoFvNNemUy+US8QMulN7OVlyW4h84
HrgUC6zIAFBqoxx7HY8IcBUXwxSH2VBRmUFWVlfWN+tNhCVKDClqaygVCILfLADObClWCf4JZgXA
xJCiBhRkUdh4P8UIwJSoYQEqtWS+/H/x5Z/7UiFxizjp7RQht7DHtyV37xT5yllTPMO52uaQ8X6p
VPKgN+uuiT0c6CpJa7mE9CNAhlShGtrdi797urcpBBGWLWUCjh7SyzYdHJCOnhRJOENv1NBiNBeM
q5n9DmEeOveXfGunScxzlzEPTCSgDzENoS4EF6YxOnwwPTk5+2z/7MvD0Y+/opX1G2jy9cH46I/x
wffjx3enz74a//B4/N1B9ezu4ej40LDyHPM8GKhtLnQxNRcJyry8b6EK2jWUGxg2MkIvMPbm4zZ5
9e3k9Gjy/HT06JuEykUOahjALJhuAtZZd6ImWYjImCFhKivaInq3horA0f5bS0tXl+Ys2OnD6cnx
5PdnowdPikhFsQQ4vZBSHyt3yxRGC1c+bUevK5W3O5X27hX76uKeYefbZs0XPN+WXNhoqLJB0f1v
ZZ59wogf+h0RMkV8mEX0uRdSyGarfTF2cQ63vYXbTvYyry1XWjqZlcrHOiun0l6wrhl26u5SKv/Z
4HjcRk/+HD+8X1RLrUxm3Eap9VFh5oKpbH3KrKypl0huE7XVyQrdXjBsPQlRbVTuqDkShGbaUbgv
5636oy9Gpy+mn78a3fv5/8m6mFLcpWD2QWGlRDahNsO6BR9wBlbCKvqO22UMtMZ5WIFhG4R1ub4w
9IqHKluGgui3xH5AwWjPy/r+Uz2ik5cvRsfPc0wTcWjlh6+NZicj1SwVikxGtL6lkrehYTOZayW3
hn1+Kdip7NuJstuZdNuJOtuxAtt5ebUTBW1bpZuN1Vtr9c7qjWb9+maj+VGNSwfYgAjOHF1G09h4
72ZnvdnYbFxvrEUwXY7qAIsqJd2qHo5+l+9UfMxwH0Q1EFxxl1Ops3ZDqbhvp/7rzWajuVG7eD2a
l4Nbs4SdMIjaYs6yTtxZVir6EbXc6dWI5Vyd4yJmrlpxoWMr7LgQKGS+D8O4YTba1EIWL3Otfb2t
46PfJr88nd7bn+z/lYji3y9/MtAC0tQSGlbyHyKasdI/UEsDBBQAAAAIAAAAIVzua+ajhQAAAKkA
AAAXAAAAc2JtL3Byb3RvY29scy9hbnl0bHMucHktjbEKgzAURfd8xd1UCu2gQyk4hLZbB2mzl2cT
QRqTkESKf98YfdPlcO87g7cTjj0FhXFy1kdwSS4qzxj7aAoB3Czi8Sp3XF0Y0n1HI9GiILNEHYrM
NPVKr3Bb4ARx7XBAyltBqoFmHd9Z0+LcNHXmLml+1q8PhZ9VMvMb78T9mcBur9gfUEsDBBQAAAAI
AAAAIVzH2UP1ywUAAKUOAAAVAAAAc2JtL3Byb3RvY29scy9iYXNlLnB5tVdRjxM3EH7PrzDhwRux
CUnIHddIUYtEK3igRSo8hShydp076zbeYHuPRFGkokKhVSsqFYraqgLUotI+QB9buJY/Q3LHE3+h
Y3s3u3sJ6JBKdMqt7fHMNzPfzGyKxeJ5EarQCwN06vxZtFOroFM+GSoqJAqvcNRnNPCli4YiHAwV
POyQgPlEsZAjwn10hQmK+qEYECUrxWKxwAbDUCjUI5KuN5JVJIKA9SpDIiQtFM59eOHMJ6c/RS3U
xvVqvV7uBWSbnigTKsu1+kZ50xtgFy0d1dfW7VEBpR/sbRH4q1fLjKp+eRgG49qJ6pq+n73TKRQK
Pu2jy1GoqAM+RLTUNHoEVZHgOYQVKyWViCVdJEmftjAuxWqI7wsqpcNjJVuhVOAObmN0DPE2llTs
UIE7sMIdjFgf4Sb847kzGkia3cjC6eOJ1jltTni7qENY7ExxbDxgfNvhgMnbogPqIhKpLfgWmzJG
czmiYgxwcj7BgnIv9KmjJV0bie4OI61l10sHoFhL0+bx4xNtbPrBJA3A9P2JsTc9OrFhA8CcDGix
UzKIvYBImXDK4iND1gWPpeZQC9XM3iD0o4BmtnGtUq1UsTk8is4xzgbRQDMNhZFAHrAxoIoiReGB
wIPDuBdEPuObSG4RQX3kUaFYn3n6FOi7w3wqShVrzarriogrNqDWXK2R2LMZ6SqyKeHIseGQYNcz
or2IBarMuBXeZlAGsGtXAenRIF1CvkgUqK6pghaqmk1O1ZVQbBvdWHlD7FoLKtBbF0REzXIIgQM5
rfwjAlwxm1HEDmwAWB3v7E3Ge2HE/a4aD/X+xyGHqovhAJV16BxJg76LPDVyUY9xIsYxefQH6vg0
k8NQkl5AUdjvA+V0qIHkO9RToXDBB4gQGJKKBAEEG/JCR9pLeFYhcIcEiAPbbFNIFMeUmmDmQ0HY
nJfxMY2louPoYv2Nm5kN7RvIzh89mP18d/7LZ/N7D1H2RrYZ2I5AuYYNWnQ8XKxBxRqz2XCTuktw
VOjIRKYC3MIr1CaBToHrgGAwEOcpf1AOeTCGdnaisba+Ul1kYlAn6+9Rst4ok15tvdzYoP3yRsOv
lusn62u9tZMe2TjZw9M0e7YPx9njr0sgNBzjcAKtmbMPPWeBuQP8AB0LSQfvP/51/8nV2ZMv9u5f
hTbKK5tUOemFUmnJinZlyYLxL9FO5LaDL148e/rV7s3593/Onj3du/PD3u9P92/8Mfvq0d7te/Ob
377a/enF88fz23/Pbj3Z//e72fWH6Ah6eeObvX8ev9r9ckUID3wCMuj5BMmmsajNd033duTCCYMJ
JgM4kd8raf7qMimlkY4HHc3FOhNjOxl1DbdTbnTSoCR1adp8u1OCWeDkAn8wSQvJ1ASgMmb06LD2
8nE2DgIE64uRKOUEwAYPFWLSVCr34tkHw0MJ47S9hFrQsRbQzGDX1+z002KEjx1Po7AWNTCzxJfE
JX5pVK3iUnMpQToPfcICR4+QpGCnaO/Ha2hizE7R/O79+Z2b+DCcyvsa522Vs1ZQI8zzIPbmSMtK
vAGvoSqaPb/+8sGzF3893f/t2v7Xn8/v7852b+EMQ+I2mxIEyp8GmUCMAO4E6y6Mm9atXGcGiGkf
QxjGDYhB6ejCOUB3HDCpKIdzY6OdrDtuctS1fc4Ut37qTJdiCvMl7/SojWHPVOkkbZtmjoDeeAra
npfYJZ5meRv74YAwvoQzCzkzf7vJ/AVFRkXZ3F6GuLphjWyFWaTtSTwTTJdZFJ6bIXAz3+KmnUPQ
65A2bNtOG1xGdzzcRilBwkjlGPJuqJHMsey7ZJq+d0yLvE3oMtSLhD4wbyhvkeDcRMql75DJS+bN
IjVvSEwk2IqcxHKL9+s0AcmbbQZVaTXzJ1hy9qa44Co2QYQlU2O9oWM9zbQVGQ0GMM5fD7DdSYXh
x9vBGfU/vw8AXGukpQnwttNf/4hK+rD5ajiljK/wKgy/Lbzt1w1ZDaPwH1BLAwQUAAAACAAAACFc
CqmWrF0QAADcMQAAHAAAAHNibS9wcm90b2NvbHMvZGVjbGFyYXRpdmUucHm9G2tz1Nb1u3+FwnQq
KV5vbQq0XaN0Ok0601fIFNKZdtHsyLt3bdVaaStpybquZyAJ4FCMmSYmPEzAKVCaBAOdtAHb4B9T
a3f9KX+h59yHdPVY201muh8s6d5z7z3n3PO+14cOHXrdCq0xz3XmFKthtUPiB0rT85VmJ+z4RAls
d3psyusqbd8LvbrnBJOK6ynkjOWUFNIldQVg35oLZzxXaTudadsNyocOHRqxW23PD5W6154T7zNW
MOPYU+LzD4Hnive2FcpdPhFvHd+B9nLb8oO4rQXAI03faynlKSsgCm/+CcN+ZOTUiV++8abhk3Ld
a7Vth2i+evo7p+e1qjX2JxP/jI/9qGa+qp9eUPWRn5749a9PvGnMq3ZDLamu1SLwCIh/hvjwghOr
CyOnfvfWGycBJgh9YAe2W0HwjufjkE6HjrTdkEzTMW6nNUVfZrwg5BMSaITHlOc5xHLhDYmHiUdG
GqQJ5DaJT9w6CTRga4folREFfnZTsYH9QWhBF+spAQZ6xSewNa4SkFCjtJabttuwHIeP1oeOduwg
TA3Xyx3X9lztVU3CoatTAegqtqvsN2PDrn+TGcv0b6DpfGp5gpgpboP4fBkGvh9faC/+QELqMwbn
Tcdx6DfnTgwE09B2gT2KarlBSBtfGHBQpRDVCdNMxnFwNnvQmdIcqzXVsJRWBZCIx9ExJWnJffej
yinuCmozPDMPtgnzsxXButREs6UzCfvtkLSA+wsy82kPZz682w0rJDX4sF07xB2FbyvZAdcLZUSw
k+GB9gC/ytOwmSqsDCxU9VeMiYpv2aCtv8Vl3vB9z9fUaGl5sL7ee7jWu73du7sVbS1H2+d31zZ3
nm0oEyrjG8i19w5pgPbxuUrqLIg7PBxrijjwbHmNjkNqoLEB4IkNgHKr06r5HTe0qf4BGVbHCWtU
n0FFSQjaOxvAa+jA33hv6Y+rfy20phGiaROnEcRWoQasazvAG2ipOzZxQ7ml49vyp+fbYBHVBcE1
FHDKxzFO1n5MWf2gt/pZ/8796Px7vZUnvaX16NHHvfV/qbFMiSVwb3HmRAlYh4GNVQFlytKf2UIG
kmwi4sraYPfmVc5Mic2ixW4AE+xwDllUnyEtqxbMWIePHlMXcBpcBWxxooZgjRujp8vij/bjylj1
J2O/Z3a5PGaO6j9WUZ/54kyO8qurYDtwfsud0wrWADvfhPnM+WNHFnLTzfLhVC+Qc9X9iTEl+0K1
Jr9x69d7154rJ+kwpXf7fm/j6s72Wu/c497Hd3sri8mmFeBb7wSh1xrj7il2U2Pm/HjpMJKQ6BQX
f6CgQHoGFz+L1m/uPP+gd/fi4PEFrk+b9xW+gBJtnY3ufZnGJaPIbBmmXjo1rWIjJ44bDmGmoMoB
TP248cPxAkxAgqPbH0dXl/p/f5JiAOU6mWN831d5zUpWZv93aYqJgmWHMY6hq3xP6a2e3XlxZbB9
dbB2uf/BYm/1i+z2hXNtmVEp4wJSZQeMqW4osY2xLAVqHjeOHT36/aMFyOxuXh+s3+t//jha/luR
8BRuWGzVdOZYxOps6bjXFMqdbdfH5tWw3kYr1mirCwVo7WzdHbz8sP90M/rkL/swBe1qwgsMfIpM
3fmnOxufK6d+dVJBcV1/Epv/6Nl70ZOPorNbfAG0xUYye8pCV81hvMH+hBfCUsgAKenOCNY7djhT
i+PFUbUUMouBW0sRKhSjT96PNjcG772ILt2K/vakd/1KWvapM5EoEd4FiJjEYDEwaBA02fbtM+BD
2NcQ8tjYhEBUTdamv3bsSBG/l98FLzJYexgtrcSshpb+5vtfb10GwY/u3VSOHVF2155LukqnRJrZ
3Dl9zGKUdiG0CUULdE9y2igu6EPIHzu2TxqJj8ZouWuBByWJMcA3q8vfvDaGIwGF4/4cwGpA/HQ4
wyDFR5EMMx70lpcH22mzhD/A0aAIc0tLUVb1fSxQOrEAg/39CTDYMJgygZs6urnSN0s8hiNIzffu
xaXo3tJ/zp7b2b7dX7nRW7yWQ5nOW7YaDTRuKUwlQii3dW6WFJrODF25QL332OzhvoJ2x15i6HI7
zx71rl0scBMyFVVGgWkYLJUCXW4oWWWW8BEykrGEfC7RawqrQG1XN+aPBmSUwHyX0GxJYXh2eLEf
+eTmzrOXu2c/ACUqokdIbTwhpYViwOfnAOa+1pPyT2HgylDTKdaNVW34yjHIQdcWA/ZdXdobTh5d
4WeWAxMDf1Vu72qocoggPCu8bbhwS2IRZ+RMNGJrkhCLqwjLErcW7WD0+EL/7jkWaIPS9TdvYFB1
6WH/ozu9xatgKHeeLUWrD1nAsHvxMuhm9Og6c9ls7N4SLEoF6XjS8Uoztmx8Yts3oZfkZmEIaeyg
p+YQbtjxslEIbZ6xs82O99qMXSTEK1/C9nJ3cfm96NaXB1FNXvk4KF1jE2TiaDFttCdLWqypZxJN
RS1tOp6V6DhWh8p2QNNWCorqS1PfKkXF1Pcm/AnI7p6Ep8PXIZ7HrGSx50MSxdMkzYNOsyhwHD9u
JADHjYnxIz88+oNjhWbn2kWIVHdXtqONB7s3rkaL/x4ec++fyEro07KAIUfQe/kEqSAxJKpKOUua
3hwZB2/J6hKJsxoapq8uRZfWIDKGSD1a/7S3+BW8s2R5d/Xs4ME5TJlXFhXm8aSiDSUaywgQuWEc
An6BuPELi8gX+EaBLGd5pBC0VGJ0XCDkYLxOKPEFQx9W/fmuWLvI1Kw+iW6fBf/OQv1o+RL4/f6j
l/2PnvbX1/pXL0Q3HvY37+w8OxutfR5duAHGZ/D4q53NK4ziaPHu7o17g+0bOxu3UoUBYfMxCo+r
PlTqivarSuFMUUfKYUnjc7YgNfO964+jx88HT9f4ah3fliLaTAlkaOICcHG8gJErfOuvHRn/0THh
leuIObRS4aUf6mn/tKsWofj2b37OUUyJveU4NZ80A0MqRrK0J7u/pv7nHExOK1IwiK8gTawzptFw
7M8suBuSZiIft1b6Hz3c2bjQW/2MZQn9m+8zq5PwS/sGCOnf5U6zSNjS6gJeDNMUikn/71RvhG6l
ZImXBxGDkZGRugOOVnmdwNO3QvsM4WV3jT95laQD/EVWGNTD06bA6/h1YoBnjseqtAMLjrUa2uta
TQuI0yxJpUY6EtrKSSXSyFVqi2uVQ0z2t64eUmVJ23fQdisMfYY9FhkyKDMDnyZIJN5G2IGQJJ+N
T1IoKdOVAIuz4LTuZwuDbDq+CV6zaddtyxljRS41w2t7mgShwQ9syqwCpuGZRbnRabUDLUNeKQDO
YOgWGKd8rMaTNu6w5weGBgwrqRUw5mWQUq9BNHibIV22BFb7YxEATOqzjIUsj2TOpB52JVkIjVTU
IVMcDo2tRFzEDHKBny0Ou44bdMBxY3j4VQHsyk3LdjIx07/PRxc3WAAhmWTicDQLI6UMlgcOcRj4
HpSwQGtPaihEihgpDtqHGJqR5UhBZJKILWa8CODQF7HQwjiThGi5DEtGiSZWPDvOBmUxMuKI7SAC
QHObZAGeuuyzAD25K6Q2FwZpGFswryoT8ouTJ95U2DJJ2kT9Keb3tBqTWjggB1tOONPYdzKvn/ae
p7vj42qKrTRwHEI1X06SmKRgg5quxzEFXUtm5vZ5DFl4io+eBqjs/2MjP3leauOIelxn9Wa2bVnJ
jcHisDhLFQuHh8ivZDXoGS4djW81ulz2uDAlBPHRLh0kvvYcktQt2LZw9c5K/EEFPjV3nPzS0dSO
1kRbFqn0aR+2oPFt+16rHTLj66LJLU3ZruXP6ZlEIDBccEkh94iaina+RfDSgFqaX0h73CbSl/EU
uaJnWrRp/a1K627mpOc0mMkK4tp9M1VxB6cyGSJ8xhdIO5twhhkb5E/MmWZcnSrBWkN4y2QjGW0F
s/JAfvgbZKUnwClpzUHV95i9wHbirz7j2RDSIW2xZExyHFhXle205wVERof3imcZYh3S1XD90Qnk
iccqubybJTUTulmMXGxLE+rzK1bV6OoDcPGQFMDXYbEIn9kwJjJzZ61ZLIF4xUML9Hwv/kJ/jmMB
7hCgsv6eradRPyl1cz/Le2kAAxCNQAKh9pwBBLpeuDjp1kk7lGJpSUkhHRu8/DA6f5/lncxvgh1P
BfPZX3zdAXSDhz1NKdrJjRkqfZRpefHilxAw6GQalFSL4xM3FoCppiFFfIk9EEG1ZBH0dOGfm+HU
ZPor8myyN5DOtKOv/hktX48uX8Mjh7/8tb95e/DgQv/WtejKncGld/vvPv966xZwtXfu0+jeEs/p
Fq/tXlzqXXsSLd7C0xUKJvE2Nk0Up2E2aYjfDNLnFfzOxCvGvDBEBzdmC7JgiINYRjuvrW9tRPee
onjcu7nz4ob6TQxmgdQEVYGryQRI3ke8Z8N2UdpBkdQB5Vox20p2wwBpAeNnlmgmBx/U5Zkllndg
A6+DgCBCAoANvHKdIGC7U17HbQg5AnkhjoRH1+CXVbIJUz5BZzkVJ8iVVBXsbpvKKiRCMcqsrGPQ
9aqi2iOaa1l0JRGhq0CKl7ZD0GB0U56PXhwBPk3Ci0CAuNaUQxoiCaIEUN5xNKw68q+qNryWhbcx
SnXihzZkYpi+ggs+YwMrDAo2RiFybrubcNbrhDJrD8TUXAHhf2NqwcZLBbD/J0NlFECdSb3j81rD
Xizr+HaeW9x4pBmR7Z2frchXEct/7HhoHPHCl14KrCak1Gr+nlWQvmiFP4wVZewnuQLHDYZaVUcR
alQ1VZrIV2gOj03MTeFblsjiDR9SkBP3whLGBJ1WC6K9PHMc2wXqq9K1Enrq8fXWTXWULkY90aiq
fE/hDel6ivkNDFwu+0idG0l5R/rQSATU3BJWKOplq90G1kg+c1StIKqwcyiuic0zExuq52SIzpWw
y/fCtG/MR8v1GcudBslN6l/fkglFZ12VoSSkA11VLTGUqSLpkwI5/MqHfvJSLPodvgzyUUS+9M8R
TR8yP3e/vC8VQt1nUhUXQ6Plx4MX672lT7EqSk/UwGUqb7/989eVOK5KZJce6bHNKNwK1wg6bVAO
vcxBJahJod8L33aPvk0iktmf/RORQrbnA20GHOsPv1WRSaJK80nVDLJqbVwASJUwPb7WPARkHEGS
rJjHhWW+Jt7Elq4/V6hSlMR1agE9FmIMye9GV+YX+LXpitbMHOpjqFZVwc1Ux80F2heyC31FQXAi
q5lIWPiYRLJ5tllKBbVyRJuzCy6/L4tJBcD7pB56YEbxOjsXD9/zQoNfby+/BU/WKWr82F22g1ow
1wIbM6sVnkeL4BlUpH9rPXqxggfQLz/GgsoXD6Llr3Y/fNm7cj8u1wewq0bVnCQ4PBZtcXUFFyRd
CIMCLb4zzMaU2ADp3o9DqB6A2SUNjY6cdrwpTX21TPdIl+uykKDly0aw9TJxCp+1DPE3XhUPwlpg
/4m8dvjY4YkjBReW0hvK/z3BKDh8kDI7Or9PYD9C0g21rFQItFBOXzH4lGU8ExhVGVX7ocGYJRwL
n0Gq17FkUUvGl06BVWBvvyRz7OXESfrUK4znVc4V0gL/z3OepTvR7WWsCNKL0awABCkTpk/nVnuP
Po0u3R28eKHKZzTpffwvUEsDBBQAAAAIAAAAIVym9+TOzAIAAOoGAAAaAAAAc2JtL3Byb3RvY29s
cy9oeXN0ZXJpYTIucHmVVb1u2zAQ3vUU3Cihipq/dgjgIUEKdAzSdEoMg5IomwhNKiSV2AgydGjQ
JWPRNU/Qjpn6OHXQt+hRokTZtQNEk3n87u67747nQskpSlKiKWLTUiqDDnNSGqpixJm4jNFVJQ0N
giDjRGv0ca7hjpHd0MGigwDBd8lEjgYIT9p7XJs5SSm39s4PvUWfj0/QG/SJcDIlIqeqgea0IBU3
o5rDAO3s7+/VdkHNjVSXGmwhrvISx1Ft11RdUzUyZNxc3TAzGV1VLGsBJfAFT0vrTFW0sSlZME6t
xznWBtITleMY4UwKG5AYdk3tmYzHimptT8Og5Yc0mZachpryIkaZmcUoZYKouROhpjvQVUlVGCUO
bGEO5UFJVebE0FCmhR7gqcwrTrfsYUsKPt/a2d3bf/cex2mqBp6m91fUVEog4ZlBYdPSOGZiE7mW
mkOv4Dy9c2y54CHIBICkVTLEvmlo8fS0eLr/8+v++fELKCaSMTVh4xcthYIi6kiWW9I24NzGzSZS
ahrio6NT9Pfrw/PvnxBoCbZyTGDK6Cx0uWxgaJXXJ4Kx2ol6/bomnNU693VZo0eHc4gOwAokpEFM
M2HTZDRcqhPoGRUhqWqUlw0MRMzDDDHRsxZgrk34Ql2Ii9n2Nu5xsZ8VpSCMbxR68eNx8f0bXibo
1YgatmJZtU05/Jv0DegSdBoykcpK5F5CmFbKe8RntrdOyBbcwTyqHfnbRo4DdIvNvKTwA2u/CqCf
7bTBTafdXbxUQ/NhNhZS0VHGGRVmlEKEG5abCTjaBw+hQJORU6GJVs/i3X8PaebLlZVZqndDoR1M
9ErsPZtXFfcCnUqxNUwczi5oK3XdbbuB3bYOIXSXaAhTeou1YE3KZm3iIXCBmaZZpWqW23idwqCx
a9ZKGfWqWltLb3KUNKtv74Wd5NCv30nAp/Ed2K5D/uDw+PDk7MMpIP3fVRT8A1BLAwQUAAAACAAA
ACFc3pSnakUCAAAlBAAAFgAAAHNibS9wcm90b2NvbHMvbmFpdmUucHl9U11rE0EUfd9fcakPk9CY
QC0+LBQMKvhQStC8hRAm2dlm6O7sdnY2jYSAomAqLVooiB8vFZVIwQqChpjgn8nu1qf8BSf7maB1
3ubMufeec+8dnVsmFJvYIUBN2+ICyhq2BeEFwJrGieMUYN+1BFEUpWVgx4EdTDskF7PyqgLy7FGm
wRYgtnhDIWTgJjEWWMiHe9Vq5QGUoHq7AuvhbSPiaUTHriEaYe0tuLm5eSPEbVnrwOKLtFXukhBz
CO8Q3hB415FwDh1Q0W7su7SFCnklyQYdbFANC5JziKEXgBWgJbqx0DCLaxOeyxdTXsxICVQHZglg
NeTKigybBNWz8MWR9KKOqZGL3QWnQ3/ww3t5PBsdXz6Zzkbj4PMYLWmirGm5TMskmZZGjCVRXWko
EZaQU1rGiiQ5qC7ptV6mT11VWwCU9C96Sm/1fn05GyNCwnthPiRaNlp+FIYsVEPYsFlUELU3UBbO
iXA5g27m0nLFis0r/KU09pezSL7krtj5T0mX039Ui3l6tJDrbSFsRy2VeuEm51htLcm9Vs/31QxO
2rSAb/XiDyBl9q9lnCQMZSIc1zQxf3i1kBryh2fe5IWa/oPwB8wnb8vblR0VZF/lyPxvQ/+p5DiU
7V5vWl3wvryXaxWcX8ymv+SKQegGvGfj4Pz173ePvNEnaHFLzhD80wv/6PF8MtimzJWBJ9PZzw+X
Z0fB4SCYjL2vJ/6r77PJG//5xzhCBYM2uRQdrrq+GMd8cihbrSjlO+VK9e59OYToq+eVP1BLAwQU
AAAACAAAACFcnFWuvZEFAAAQDwAAGAAAAHNibS9wcm90b2NvbHMvcmVhbGl0eS5webVXXWsbRxR9
168Y8jISXcl27PRjQRTTOBAIbYjdPFQIsVqNokWr2WVm1pZqBMmDm6Rx6lAaUpJAEpKUkkLdQhqa
VNA/Y23sJ/+F3pn9Xq2cFFo9STNnz71z7tm5V9bAdZhAjJS6zBmg2qZNOEdWsHr5wtr6erjRNjiJ
1m2L9kulkmkbgL1EDNsSo7ICV/QSgk/foh1UR5gFe1gtWrTteLTTEiOXyE0VKtiyjTax5ZoiQQsR
KfoAXba45dAA1iFdw7NFSyVRRysry2pZ2Bx+nTNsTkoRDnFj4NqkzInd1ZAphhpqW9RgozBD+aF1
7rmElSu1ECxhISoGuczaNATRXK9tW2YdILU+GbmGxcp5KK15bgewZWGwK0TU8dbWVo0MFXfNdAZY
CzZU/nXIXuPUKkDFhCiXRAsi17MJBUvqq8Z7wNuyOnW8uHR6eeXMhx/hJDlGhMcooolCLtTVFaFC
dJ5IkUQhOodLzt7AweFwE2ohVTJ4v4yjOvp7T/ybt94++NV/fH366NH0zu3jyY2jh1f9H/b93Wto
48I6WqotH092/b07B2+eTW/ePpjcP7z+Yvrtz/7Tq/4ft44nN7EGPhm0OwbiuorQc7igxgCKrKEN
5pEKHKMGKZSjVCoF+Snxs0mmk3v7y/507ylWp6xRb9AmLMcaEGjSfVl+KGbx4dc/Py9P++Svgz+/
C6Ic7l87eP3TdPf10c7tf3cyGURLq53Kweoi6ogImfIMTtUzTDa921SEiZ/iU8w1Ohw29JrCRrlF
axXkMEXAiQm+4zXh9Alt9ciwvFJJDLgJ8qj3JW3BAuvFuBARAzJSpTQJRZuLU5XKg0A9eTOV806p
IIsrXS0qsjJK2q5h2Uml0x6a/r2jSv7Gv/vSv/sbzqYTWKvMBZsNmCC7oCMUAUKjbMk0lKlXNq/Q
B4zUup5tDwxh9soMN1arXxnVrxern7Sqze2V5TGOTAUUwAdviz5z88wecbr/zdH3z/3Hk+lkz7/3
2L97I3UybnUK7KDI8y7NZVf+VG9Aaka1u1o919w+Pa5sL2kfyxyBs/Iu3VUodP4sijOKTRZ2ncRj
A6dD7BTjEDKOnBaBY1iCamCPE8Zxs7HYbOCu7Wwp6+MhdJ8qc9mwupnqVOEjsKdQ25hQo22TDtaV
60ARINskrCUtCYuJKeOeqc8+NdsY4IN7Bu3wntEn6pGAN6BM3oconHKYPnMbjudQpy2nF1wbSY11
1MjcCs3xON96hklRHE9kqjKnHDGMZgrxv4lfLIIniQqqgXDXolcIhIebARax2YMeSfA8MU8obOZt
1vO3cVbnjMwnquwxq0DgECdnOOnzcAxTLcDzJKcmXQR6ZFxpUbjLPSblwovyjSbUZCNXSNFhiTqU
FA0u8tzyVpUYYbpYaQ88gQ6xJFJLNyWhFKTdL1CiOAKfFUYySpvoBSYZp64H7g0G0Nvm69TAMJzo
0UB6PHkgaXWUJ4UNf/f62zevoYHHZ4DGD/FhiI2EbCaBmSPyre+E6StEnzB9/acN/d29mxK4t4nZ
n9e71UsBoxUMb4+eo6IxMBn67ocSxSNNzCLYKHv1syg5rw0DqQnOrTGPlhvYcQnl3FYGa5m2Raic
0XDVdCglpvzexdu0cSqIcao51pNf6hKEpQID42pwVaibQku/EFUwwFJrWQUBgNUdtaIRIwcMdwM/
tQhjDiuM9Nmqa4ieJFwAcRfgNAsmYYJLFou6HvyhgE1BhqIeXBpcdOCGrOf0uHj+4tosPWAhch67
vnH2iy83gNQaEEm1dKaSeRJ6NasFiZvQD99nPsgWdyGYdI9e7MKX6bPfD18+l0P+wxfhnL/3o//g
ZWo4IEOTuCJf4o0gvbWhazHSeb8hLLDa4asd/96rwpCl0urZ1Ysba5fAUtF/2ErpH1BLAwQUAAAA
CAAAACFcIlxX7w4DAABDBwAAHAAAAHNibS9wcm90b2NvbHMvc2hhZG93c29ja3MucHmNVU1r2zAY
vudXiOwgi7lumnalpBhW1o5dtpU1O6WhKLa8mDqSJ8lrSsihMMYYG4OxD9ipl5173WA/Z03Zv9hr
x/JHm5SFUizp0fs87/PIcjiKhdRoQBXb3GgEUoyQkw5QOF/Y8WmsmbTR473uo6e7Bzaivi+ZUjZ6
mQjNGo2GF1Gl0MGQ+uJECe9YWfkm0mkg+B2H3EcuwqpE4GwhogMWpSuVvWgVdR/so7vo+e7+HOWz
gCaRPsrkuGhrfWsrm+dMnwgJO1xkYe3F2EY48WNMslUdpQsPaaRYNk4Uk5yOWDFpaiNFR3HELMWi
wEaeHttoEHIqT3P1GZWrkphJizg5OIXlqG3Ee3jE9FD4uO9ib0jhr91aCZkOVmIRna6tt+7hbSSZ
TiRHvCSOwexY58R8Gfe8NMjOA+gBzPGGQihm4ct355cXb2Zff13+/ogrGeUPDjjPxhZ3XjBtGZHF
aq/VJwScXiP9stMejiFNMBa6AdKUzExYtZyA9+r8DOKCh7+ffkDZnKbYT1AYoDo3Qa5rOmKQAnoi
OLPzGVJVYRxFBl/69opGoU81qzlXccxkVeByRAFYIIsLjUJunClrpb/Ug4CGkYX//Pww+3wxe392
9f01qplRzaEkMlZAEzfMqalJ2VXIlabcY5YB2UhpSZCQGaAoBmPKTy0vFVxMBjCbzeBDecgPx60W
JsvauBnj7Nv57Mvba6LKEBwQJrU6CfXQwu1Wu72yqLg3ZN7xUXFayi4qlUgZY8gHIuF+meJI+Cyq
1B2DbSZLAy5gJcpJ4izliSHpVAnhUig879SP97Qskr+c41KdSHRN3hJdBYwvVLSMGlQtEnurokSG
C8TQRA/TGzC7jK2q0/Bm4w6G/8VSyU/IfyQ8f0PnXwYnkZGiATsabG4w7kEEVoAnvNecF2j2p510
ZBhgjJ0cR4jjs/mTI+FAh7GFXXyj0wAr1VldnaQNTe9P8q8M+Dq9MzEdNNMbvNknU1zaIoW+fhcs
usFvvdewuYLc2smZl3a7MmFwbhs7uzv73b1nsLv6rSONf1BLAwQUAAAACAAAACFcghrSYIIAAACp
AAAAFwAAAHNibS9wcm90b2NvbHMvdHJvamFuLnB5LY0xD4IwEIX3/oq3ITHRQRZNGIi6ORDtbg5b
ErTQ5lri37cc3vjde+/r2Y/YdRQthjF4TmgMhWRZKfVyFCM0+zdNmz8uTwr5PsNkUKNI8iyEOeqs
W+DawB763GILfXusAWN7ml16iqbGsaoOwkPWfD0vg5pnm83NpWn19S5A7KX6AVBLAwQUAAAACAAA
ACFc9AhgJnACAACfBQAAFQAAAHNibS9wcm90b2NvbHMvdHVpYy5wec1Uz4vTQBS+5694niZhYy10
99Klh+IqCIuUtXsqJUybaTt0MsnOj27XZQ8eFgTFk+BBFBYUvSweBC8K/jM24Ml/wZlp0rTS3p1D
yLx8877ve3nzRiJNoDbAkgBNslQoaMc4U0SEwCifhnCmU0U8zxsyLCV0Tx/d9wtE0PTArCnlMbQA
KU2HyEUYHhBmQxYNswO4B6dHHdiD7vGTJSImI6yZihxhCw729xsuzok6T8VUmpiPdJyhMHBxScSM
iEjh8fLTOVWT6MwSFoDMiDMnrZCu0MTFtKarfckKEicZI74kbBTCUM1DGFCOxUVhxoloSZ0R4Qe1
AmxhBeoQeA8NUz4mUtGUR+ZViZShfgsNBgIdgiBKCw68YsxMhTNVMPJdpCVlgf4HV2nbzm6Lbfkr
1hlmNMaKbPBu4VvhCsQKQEfAa2Oi/G2EAdwpGKuMdpkMtRGmzEf57QfXLJB/vsnf/fz1/Tp//SV/
+QzsoaDSSfkg1TyuZCZpTNia0LnxVootwStYheohbZpEon6v3u+hsh1cZfj6vjpR05kzfrnNYHNX
pUNAT4lII6FUNME8lhM8JQb+EDNJrjYEKWblIMwy7nT00KSxJqDolHlVi1SrjWLsqMIKxoP/2Y0W
dIuRAmdni/2Ny6kRWn32uprMe4CayDzd3PE3/l0QwiWSnC79LGeC80C5JEMtrHJUR+FGS5Zre11c
D5sMzpbZGk9mZyZPJAjDF5FtMxvnWNEZQVdrnSt1kpi7udtjD7WPO4+bMGn8+fE2f/FxcfM+f/Vp
8fxb014CE6vfPel2m7C4/vr7za2ppee1j9qd7oMTO7XsoA28v1BLAwQUAAAACAAAACFcSTKxpOUA
AABcAQAAFgAAAHNibS9wcm90b2NvbHMvdmxlc3MucHlNkDFrwzAQhXf9itvOpqItbaZABtNmyxBq
06WU4thnEFHO4iQFTOl/r6Qkpbfpe0/vSTfJfIL7Q+8JzMnNEqAZexdINFjDR6XUYHvv4X23bdvq
qtVrBWmOhkfYAJ4teY8F2f5ANrPihwfoXvZwB92uvegjTX204as0beBptXouPEaTozqJpG5GiGIq
T3bSwNfGPEIhCpfXVaxv7cnzgTkFPzV8o2eD64w8yZkkQzTsaYhCScBH1H+B/weJB1lcMDNnG89M
KRrD4sq1MLh8LDkmLAVZjz912lPz2uy77Vv6xWVXtfoFUEsDBBQAAAAIAAAAIVycAEJvXgIAAG8F
AAAWAAAAc2JtL3Byb3RvY29scy92bWVzcy5weX2UzY7TMBSF93kK75yIklZM1UVHXVQCBBJIiKlg
UVWVG99SU8eJfO1Oq1F3vA9LdrwNEo+B7fz1b8im9fVnn3NPHIu8LLQhK4YwGkaiGn3HQkVrXeQk
9ROkLk85Kw3oKIoyyRDJl4+AGNfVZBwR92yF4mRC6C53czSUJFuB9LXAkz75CquHItuCIS/I7MND
RXFYMyvNMihNyN1weBfq1gq/4UxbiBqQIMtLCTGCXPdIZvY9shKK6UNtwj9qgrYEHSdpDXuspu6J
mtOSmQ1dTGg/L7iV8NIAGnpPNBirFVGdWOmCKE0tpp7Ta9Rq+oLrbDXCricHpAy3Me0C+fvr55/f
P2hYnD7i0rNONP0GJq4W9gjtUxecBxAyZxdTU2xBLTewj0dJknTOd0wKzgyceb/hueVqogVOXMSt
8xMBoVaFVbzb32UJ8kRh79psVBq4xTpqTi2CRrqYDxZzyqQ7T+95yGhwChnNFPoDEqaeqDmUQMeE
PqKPJbgbdwkf26X1O913xgtrzpw/Y7nF1InZ1JYhrCfq8rdamIP3wKwpvItgfim4qw3csLM8vjDc
btg9Vy24DTbAuI/GL39XoKmmXVo70K7H4zH5T5vO3Y0OnXsW8tt5L69Cdljtq1gOQZZxfq7koaoN
NDochvAeElcXNeo/VQdeNUZZIOjAK2F2FpcC073BJh5VKPDjzVW/Nza/kZmRvp3w4xWVuAjtMrHq
thr3w4dVXYXpajQElblzGvvbMOU2LzH2yfUIKLQalgwzISZvmURI0ppNkpRD9c9dk9PX00+zN59d
1tVVmUT/AFBLAwQUAAAACAAAACFcRgUKph4FAABUCgAADgAAAHNibS9ydW50aW1lLnB5lVZfb9RG
EH/Pp9imSGsTn+8uUKk9eiAk+lipKqgPTa6nPXt9WeLzWrvrcAEhAW1JoKQpIlAEUQUvLaItqdqH
QhqULxP7jie+ArNeX85HQFCfdJ79Nzvzm9/MeHp6+rQSzFMO6vAk8qmPOoL5XYoUR2qBooAnQi2g
kCxT0UAEySSOQwbbJIu6lQ7vI9qnXqJIJ6Tu9PT0FOvFXCgUE7UQss5oKOhIkkknFtyjUo5mzkoe
jWRFe3HAQjo1NeXTAC1RIRmP2ot02VoiYULtxhSCp0eUt9AU1A2SMMwHlsDWvD9jz7vll3WiUbHm
apVPTla+JpXzbqU1Y9snsGN05apYgCKujMYGEoRJir7Sy58JwYWFs58fZP/cHm5dTVd/Hzs9uLaa
bf7xcucenpFKFLYZhR0iaVMlcUgtFimrbwOGAvURi8wlblfwJJaWPdc40rKPoVjQZr4wd7SVKxBU
JSLK9cxYVt2xRzbCTkRDsM+qOfaMuQJEc0u+q+8y6bMuU5Zd7Kw7ZQNAgyshfsrCLrZtxwacvZBI
ib5MIsV61MCroW+3WcRUu21JGgZOh0VELBfo60fPuma2qREo4u1+AW+r2O0KKnm4RK0CGeOcTELV
HLPAFUlkzZXUObiIOm45HokBC9rmiYoT1TwjEuoo2h9JYDCsNOsfOd4C9Rbz2fFV+ySRlIicId/s
x6+4Alnzp2fsQ9gxZrlS+aAQRu7nYz3vYshw96fhwxuDRz+k2+vZ3w+zzWvD3Y30/i/p+pahzeDe
d68zB9uTSBb2FESot45NUL+8ZXxQka6cdO8MzDTm5WHLPfwup3KVuQZJlaUFuBUCFofEoxZG2IGf
PSILiHblAsYXNRh6s2GXPgoUGlGGRQHPbS3xxGeCeooDSyYYUoq37cZE0EiVKJLz/8I+Dxpl/x2s
74c5KBfUt/b9sJ19BaMHE/8seBOpNtwriGAUzs1FpEfzjMgFSIo5DMue4BEFrDj4Oh76yyBPzoQh
bmkUrH3PqlqRDZnX1pXLslsXx5DkvDQp5PEoYN0SNB+iUzxnVuGwMCmIIF5UQLFlmnPLYKEXJj5F
nqA++MJIKFEgeA8WoOwwHxnF0v1fOZYbBp5VPOzo/C2se9+UO1KzD8YrhkJCfdwoeGfmPe7TZrPm
YNqHcqJHb9hQQkyCZT3yOo2gs5yUi9CRGFCvTzyFCkdQRIEYKAE2EpDPgXyOdiRTtNCEiISVgIRh
h3iLeYsqJfZbs+zT8gquu/Wjbg2XDModP1gKVh6n1x+l6zcHP/71YvPS8NfL48Q/3kRGzcud+8Ot
f9PvV19cujfcXRmub6Zrt1G9htK1lcH2b+mTu9mdZ9mDp+nut6UycY5BGx61R/cM1f0SADg1YqEF
tT1g/SaWnV6FBwHzgCkVg0EF2xoG5U/arzNyMi2Vb1exOePqtown/X0PXpnDmljcEEvrfxut3kCm
Ii4HGIJ0wnLzXTFONT2bz0hFoBTBqy3ZeXr848P12uzR/K9xoCwcDFv6/FZ6bc1Abvp9urWTrmxD
Kc9ur6LTuU8Qtmzz8d7z3cHGo8Hzm4P/Ngc7t9I/72ard/Z2n2Qbz4bXrwyuPMOTvvhEkaaG0g05
8WUOB7hF/LZOqnJnLNoMA8KANxFUYX3W8eHjLPdTj9wuVFx8qADZ/qCJF5SKZaNa1VcU0Xa56FZ9
QQJVna3N1ir12Wpx4F30LeNgetje9tW9p2vZxlZ247JuYwYKlD3YSXfW8YEaoG2cegVQSwECFAMU
AAAACAAAACFc58Vk8SUAAAAlAAAACwAAAAAAAAAAAAAAgAEAAAAAX19tYWluX18ucHlQSwECFAMU
AAAACAAAACFcil+MtzMAAAAxAAAADwAAAAAAAAAAAAAAgAFOAAAAc2JtL19faW5pdF9fLnB5UEsB
AhQDFAAAAAgAAAAhXOCMXmXDBQAAMA8AABUAAAAAAAAAAAAAAIABrgAAAHNibS9hZGFwdGVyX2Vu
Z2luZS5weVBLAQIUAxQAAAAIAAAAIVzLwJGgngIAAHUGAAAPAAAAAAAAAAAAAACAAaQGAABzYm0v
Y29tcGlsZXIucHlQSwECFAMUAAAACAAAACFcCDgNxkAAAABCAAAAFAAAAAAAAAAAAAAAgAFvCQAA
c2JtL2NvcmUvX19pbml0X18ucHlQSwECFAMUAAAACAAAACFcQkeAelYSAADVOAAAEQAAAAAAAAAA
AAAAgAHhCQAAc2JtL2NvcmUvYXVkaXQucHlQSwECFAMUAAAACAAAACFcoooxSMkAAABaAQAAFwAA
AAAAAAAAAAAAgAFmHAAAc2JtL2NvcmUvaW50ZXJhY3Rpb24ucHlQSwECFAMUAAAACAAAACFcMQr6
Z4oFAAA+CgAAFQAAAAAAAAAAAAAAgAFkHQAAc2JtL2NvcmUvbG9jYXRpb25zLnB5UEsBAhQDFAAA
AAgAAAAhXJAMaNVQFQAA7zkAABoAAAAAAAAAAAAAAIABISMAAHNibS9jb3JlL25ldHdvcmtfcG9s
aWN5LnB5UEsBAhQDFAAAAAgAAAAhXEUvIUxyCgAAFxkAABkAAAAAAAAAAAAAAIABqTgAAHNibS9j
b3JlL3JlbGVhc2VfZmV0Y2gucHlQSwECFAMUAAAACAAAACFcnDBET9sQAABYKgAAGQAAAAAAAAAA
AAAAgAFSQwAAc2JtL2NvcmUvcmVsZWFzZV90cnVzdC5weVBLAQIUAxQAAAAIAAAAIVxkIIPYghUA
AFZAAAAXAAAAAAAAAAAAAACAAWRUAABzYm0vY29yZS9zZWxmX3VwZGF0ZS5weVBLAQIUAxQAAAAI
AAAAIVxVzkqqpw8AAFkvAAATAAAAAAAAAAAAAACAARtqAABzYm0vY29yZS9zdG9yYWdlLnB5UEsB
AhQDFAAAAAgAAAAhXLtoNJvFQQAADLEAAA0AAAAAAAAAAAAAAIAB83kAAHNibS9lbmdpbmUucHlQ
SwECFAMUAAAACAAAACFc6IMp/pQHAAAeFAAAEQAAAAAAAAAAAAAAgAHjuwAAc2JtL2VudHJ5cG9p
bnQucHlQSwECFAMUAAAACAAAACFcyxu6jfEVAAAiOAAAFgAAAAAAAAAAAAAAgAGmwwAAc2JtL29m
ZmljaWFsX3NjaGVtYS5weVBLAQIUAxQAAAAIAAAAIVxnzvduLAsAAEAXAAAWAAAAAAAAAAAAAACA
AcvZAABzYm0vcHJvZmlsZV9tYW5hZ2VyLnB5UEsBAhQDFAAAAAgAAAAhXL+XiZDeAwAAgwgAABkA
AAAAAAAAAAAAAIABK+UAAHNibS9wcm90b2NvbHMvX19pbml0X18ucHlQSwECFAMUAAAACAAAACFc
7mvmo4UAAACpAAAAFwAAAAAAAAAAAAAAgAFA6QAAc2JtL3Byb3RvY29scy9hbnl0bHMucHlQSwEC
FAMUAAAACAAAACFcx9lD9csFAAClDgAAFQAAAAAAAAAAAAAAgAH66QAAc2JtL3Byb3RvY29scy9i
YXNlLnB5UEsBAhQDFAAAAAgAAAAhXAqplqxdEAAA3DEAABwAAAAAAAAAAAAAAIAB+O8AAHNibS9w
cm90b2NvbHMvZGVjbGFyYXRpdmUucHlQSwECFAMUAAAACAAAACFcpvfkzswCAADqBgAAGgAAAAAA
AAAAAAAAgAGPAAEAc2JtL3Byb3RvY29scy9oeXN0ZXJpYTIucHlQSwECFAMUAAAACAAAACFc3pSn
akUCAAAlBAAAFgAAAAAAAAAAAAAAgAGTAwEAc2JtL3Byb3RvY29scy9uYWl2ZS5weVBLAQIUAxQA
AAAIAAAAIVycVa69kQUAABAPAAAYAAAAAAAAAAAAAACAAQwGAQBzYm0vcHJvdG9jb2xzL3JlYWxp
dHkucHlQSwECFAMUAAAACAAAACFcIlxX7w4DAABDBwAAHAAAAAAAAAAAAAAAgAHTCwEAc2JtL3By
b3RvY29scy9zaGFkb3dzb2Nrcy5weVBLAQIUAxQAAAAIAAAAIVyCGtJgggAAAKkAAAAXAAAAAAAA
AAAAAACAARsPAQBzYm0vcHJvdG9jb2xzL3Ryb2phbi5weVBLAQIUAxQAAAAIAAAAIVz0CGAmcAIA
AJ8FAAAVAAAAAAAAAAAAAACAAdIPAQBzYm0vcHJvdG9jb2xzL3R1aWMucHlQSwECFAMUAAAACAAA
ACFcSTKxpOUAAABcAQAAFgAAAAAAAAAAAAAAgAF1EgEAc2JtL3Byb3RvY29scy92bGVzcy5weVBL
AQIUAxQAAAAIAAAAIVycAEJvXgIAAG8FAAAWAAAAAAAAAAAAAACAAY4TAQBzYm0vcHJvdG9jb2xz
L3ZtZXNzLnB5UEsBAhQDFAAAAAgAAAAhXEYFCqYeBQAAVAoAAA4AAAAAAAAAAAAAAIABIBYBAHNi
bS9ydW50aW1lLnB5UEsFBgAAAAAeAB4A3gcAAGobAQAAAA==
SBM_BUNDLE
}
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
