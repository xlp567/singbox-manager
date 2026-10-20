#!/usr/bin/env bash
# singbox-manager v3.6.1 - transactional core and independent protocol adapters
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
SBM_VERSION=3.6.1
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
    grep -qw bbr "$CC_AVAILABLE" || modprobe tcp_bbr 2>/dev/null || true
    grep -qw bbr "$CC_AVAILABLE" || die '内核不支持 BBR（部分 OpenVZ/LXC 容器无法修改），未做改动。'
    qdisc=$(sysctl -n net.core.default_qdisc)
    say "当前拥塞控制：${cc}；队列规则：${qdisc}。"
    say 'BBR 可改善 TCP 节点（AnyTLS/Trojan/VLESS/Reality/VMess/Naive/Shadowsocks）在高延迟、丢包线路上的速度；Hysteria2/TUIC 自带拥塞控制，不受影响。'
    say '注意：这是整机 TCP 参数，会同时影响本机其他 TCP 服务；关闭时恢复当前记录的设置。'
    confirm "写入 $f 开启 BBR + fq（立即生效，重启后保持，可随时在此关闭）" || return 0
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
              public-ip show|add|remove|clear：确认 NAT / 浮动 IP 的本机公网地址
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
        security) security_action "${2:-menu}" "${3:-}" "${4:-}";;
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
        action security "${2:-menu}" "${3:-}" "${4:-}"
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
Q4mkktCqlS+drfO6WP0OV+cHnyHHo+xUs1uarZm/A1BLAwQUAAAACAAAACFcMQr6Z4oFAAA+CgAA
FQAAAHNibS9jb3JlL2xvY2F0aW9ucy5weXVWTVPbVhTd8yte2chuLZNmunKGRdPptJs2nUx3mQwj
Sw9QkCX1SSJhMpmBNAZsMCYJ33GaOHHATUDQNAlgY/gzepJY5S/06j0Z2zXxBlm+59yvc+9lcHDw
JpYU0dC1KaTqk1i3DTKFjFGUk3RpDBPRuKtjBWmGLNmqoVtp9CuexAQRQFloVNUwkg3dBpyVHhwc
HFBzpkFsZEr2uKZmBwYGFDzaIU6A7WjKsiUbp4ij22oOpxRimCl8L4JZKUWypZQ1Ds+yY6csmaim
nXJ01U5mBhB85OGYOf0b/GV0yWtW70tGn7xGet/G7pLXlN73kcck445eW8O3EgJtPaWFUuBWg+XZ
8NGWX9kV4lCSqYRw88aN31HwzKWt1V4TYYgYhj1kqfpY1rgnxgVMW+NCBKNn7/zSIX3c8po14SJF
9ou74a8dh2fLYXUxqC/QRllIkSFBdgiBqjE+EQiBhYUZf9phxrjCPMTAo+pGM9d+YdqvFOjhe+9o
IWy1uhHMlmANSxa2+jz4lRItVoN3+9T963wzf54vBS1XSMlAD4VXx9J3LENnLsLiw+DhMa+Hv3rg
l9zPJ/N0+R2d22PPBYZqlySG9Trj7O0UZBZ45a1fXvYatbBUCOpnfZTWkKAQadS+nBAS9ldO6cmf
HE1bT/zqaw5SLVkiClZEBrd4g9xFf/UDrc15zRazykryhGP2V4W6r/z5w6gq+yd0rhF+fOSvbfbF
FiuaFWfuLXW3vOMCGkLRc7FOS+XQdf16lT5fZ75MYtiGbGiXeDt8H+w0zzdr3ZiuXCQij6uTkEo3
RULwGgvQOn/mFa2V/JdzoXvA/WBdAT1dklM1dKv++ht6xgOSHEXlddXi6kQG4VmLFl96R0thyw1b
u+crM/83TsOmmOjv7dZKsN2MnaxBhT/RchEaTt+s04MZurfhux/bnWclu379JqJLL0L3FDQBZaOn
eZ4LJMKtoD9Z2E5EHVN1SUtHguxzy/VIH28EVTd0a8HWI5rfDVqPaeWAPp/mBXGymiqLkqIQbMEM
dCTNlcCHJY55/zj8p8pg8TYRjewdLNv9XePT5b94E+6/Coqf/GleKA02k2WLfziYTHU8eUdFf7ca
1P8FlURAhgLhB7UGyMpr5oOVutdY8jdO2ZtCNxUsu6yGv5B5uz/tuYt7Az+zkHoqHifKZldIKZcT
8lVHl2Zp+X3XpLRvRWdigI+bluaCxk6fDNsAx4T1i8VYlZeP8U+q/bOTRTFTY5kRxEDLcIiMO5WM
bYOdGVh4XvMpbTyl5bfhfhOWblBYZNAx1R53sqJtTOAvOjvfXoOOULcQvs53KU7VodyaFqvu8nC/
/+GXH1G4P+Mdb0dz8mEbdsVFVWFU5BxmoVpTlo1zCoo1ulkPt2eDZ2tcaQK7isnbjFodRdEFzLD7
lJbMqFqJDoF31OR7ug1l55KfNGLchYvGaUYNgnQJDu6kpDkYbjI/eJmL8M3ew8jM4Iwad4fvg9qy
WBMyDC9EZkLGsknCTKYEfE+1YAIyZpo/JZIPLighdDOtWiPWVE5T9YlEEkEQHUMk6Qp8hckztEmc
SH41bKalLHxxbPiWAde3BFsiY9gWbg8zfx3b5IWTKMl2WeA5zhzbDtHRfRYsRBcZpQQLk0lVxiOa
MTYiGzmQoSJkhDugItghsq0h0UHte4tEHX175QoSRd0QzUiuQk+rkSDD2dQdExjCcoWWVtHVq59P
tvyDI+84T+dfRjubn2h2f2CL+Uf54O8GbHS+v9tX7Vkb/l0EBxu4oes7fL7ok0V47j3ZvVGACODS
SGRqRFEJLCMQJ5xy1h6QrJ0z018LyW8E2CTdM3w+PQ23y1//xP1BEN7Rnr+257sLweomrdThf4Vo
BMpr9HT9YpvQ5aW2fUF4MPAfUEsDBBQAAAAIAAAAIVzNSxeyFQwAAMMcAAAaAAAAc2JtL2NvcmUv
bmV0d29ya19wb2xpY3kucHmdWW1v3MYR/q5fsbY/kEQo6qTIik2DARJHQQQ4shDJQQpBOOyRezra
PJJd8iRdVAFpEsMvje028UvqyEWCOo2TxnLRoI0ix/GPqe5O/pS/0Jnd5ZG8O7lNzoBI7svM7Mwz
b+ujR48utGqB75K5MGU8ZClhq5wlCYnCoH2KJA3KmUdqbcLWGG+ThHF4kphHaeRGAaEejWGfdfTo
0TG/GUc8JX5MPQ9JZAPnkyjM3qP+aEzTRuDXss+kVQOiLm4bWzh7Zu70bxwtFpKNoyTja5Pa2DEy
uxHDiJ8SNwIx6CqDl2YcsCYL04SkDUZ4K0z9JtMSkKPqJ9WY+2s0ZcTPltHUj0JrbP7sfHXh3KvA
yNHHCPy0iiX+TZzQTG2y/FGxZqbF52QFv6deymfl3smZk9bUcbVmBte8NGVNzsjvKfw+id8nCgtO
nrAm1ffxjMzU1LSiPA1LpqYrhS/bnjg5I56TQPKEeKvDz67YFTEjSdTdSgWWvgTzdXYCX4XM9boY
zgQ+RpY4DZNAKGMibYUhCwiMrLKEuDQkDd9jBJ6sWWOeBwDI1Di3sDZNPJakfqgUKbjOTIMsJ2uZ
jNnnJAxMo6hTlcoUijIj33H8RVDLmDE2NuaxOlmjge8Bfb0ZeSwwbEE1AVsxR4xYqyzVtYS5Le6n
bc0Q835dLiF+QuajkNmcpS0eZnNhBFhM/BDWhC7TxVLT893UIBEHIKdyyDjibGpxBLBqg3BB5NKg
qgDMEm1LrMV1y9milSOOBKiUEn+c+gkjb9OgxWY5j7iudS7tdW78tbNzpXPxQe/h7d6tL7t3Pu/e
uvzzjx/t7147+OBJ5+J3z+48fPb404Od+/tP73Wv3len6vN2FNtBkVYOOWB/hRn4iTxkwMJ82Hj5
+OSUPSxqd/vb7vZeZ/sfnXvvdZ7+vXfxKymqkqcOdBQN4oe5ePnpDxXFTFJu/HKOgmYWRCxwY/Wa
kc1AA/EnYG5aFQrSFWhgQStInTycWBAR9GXNj8G64+fhj6ICb0kjWtdWTLfB3AvOEm8x04Vo1uKs
GrXSuJXKsZRtZG8QWGDGmaxIQQGx1MHoZgUR9RJd8raS1INVxiFmwk25hXASR0ZpCXTy3a2DR487
N25LjXWvf4mgEnoDIHW3v+ns3ezdfFCE2TCKAOi5JX2M8nXqMrSlYNxXuZhOWRNn+suk4yG1qh/W
I81cXjHyLeqEuEsurNOmH4B/Io1NzYd0AmrGx4y2ZfdlsuANnI/rI62M1BTqtRXDKOkxR99hqCrq
aH93r/f13v/QlAwaOWUFLrBWM5bhyMxdSB5djC7n4WgljyC2DA3DgcROIMsxT9889NzUMKSzldxs
y9hSEnEAVTlADkRNMRath8Lko8KmubllyKFB6dCsxikvalLA6QBkQqCEIqlT4ycEoRwEKW/bwPX5
RsVdqDGsHnKr4o9tuCxOC5a0lRiCYHkf+Nk647phcWDkx7pmaYqS63s8cdCt9Dyzjwxgyg4gcQHI
fuw8P+JkCwUfi8YxC7PTGi/oGmYz4QmxBYImkBgdZ5qwACCqiWytxKyB4i8wD/BSqk40W8QXHEQG
mi3YQKhyMcdqtsbZeYh02pYgEtIm+PWmJvVUTVr1ur+h2cpnGlGSZokse8qV8NWImsyiPKbCLbHg
Qyc7jBEcSNnCFjyXFUsAvNKimjZUUfEWS6JgjUHtKAJMglWEKMoQuvwUqUVpgwTg4JxC6Rh6GK1x
g1csKRICJaciKEIz1p8MrMiI53OQDh4A/HDVJOsN320AkRZgWDLK6GUGR0RYRT/f1HgrQH9cxlJA
VwYxTHFAc7OoCUEK04REn60l7QRiE4x4fkJrAaSJGFICcPDdqktBVmnHLbNMuhQu+7/N3NrL/dqz
Igu9StkmqD2YgEctaoUeDElFaFuH0h4yKBCs+2jtfLOKK02aguiJinVuFNb9VRPLaj8A6e0MCdmI
48glqtoieOJsTR5q+gEjW/Y6BWdQVj0LBb0wF9sAOaHYTNKI+4BT0gpB7eDaLoCLgK7jQNV3IHG0
GvrvMs8kIbYiihTlNT/lFDoTwAAnwrZEBNGY8hRwApw4a0aIiZCtExmmJSICtkrdtiOM1T/vKTlq
xRGEFy+E0IilZTa8rIyBEX9InQWUKdJKVXlKSVvP1zNoj0OP4gwqWzjL80O6SkCGo6rTMugH0xNE
sMBnACXFEQKFELmaK1qzMeOqeSnAc5FSxmI5xVRdAG6q2ViQ/orMNECas9+2QOlJFU/RLskJ3upG
MTiiBuXfRrvczHoRgEMsbmCrQxYX3zBJHSitA05M8uI74+fmEDzvcNoW7nGMyOZ4PAsn4Pii82yL
rIIQFtnxtflFGaossojgBCS/sbS0sAjJpsWhCMWIBnkSFA4kY8CprJNOkdUgqsHivCrrH1woHE7C
KfjGuNA1b+aBDeqUY0Sff2WJTJA6VJ8QPFehOTMEJzBJDYouj6z7EG/XG+BD2LSjuJlAnGHXbY3J
RFmdW6gunj331unZRWdz2ta1RprGiT0xQWMf0qFfb1sRX8X8ocb9eG3aAo8NG/RdyHnAsDApNAGj
tEnfjUK6noj50XFwpsxs5jBuMwPcoCo6fXb+9bm33px9rXpm7s25JWdmWvkZ5lVhtn76tlW0gBml
cRqAV8PfJCLUxQIkIU2o3YFJkgJaSNKKY5HiyEI7bcCASutJKZno/ZIhJwxmK1SqOJMTHjHZCpOY
uX4dsVFUzIilQRTFNepeGDnnhxdkIzRqFp6Yw0ZzALejKVQyWdOmwYYEcnRVlRAichtZ0+WxFHsu
pWCJY1OhysFQaXK8TeDFDkwAQvVUyhboPi2OyCd6hkkYGoLjsuRQbDqw3iwdRDRokis0ehAIsO4Z
117A8kxuN+B7XNxZwYwjYIVL6skiPtC7QjjUuOrvYOy4GG/SDTEm7oA0EwivHJJwCd5WeIyXjv3a
7Nvz586cGdFATlUMS1awRtkk0gSja1EkM1Q26wV+pyGKMW9BfolS2izMLknesxsxBDzPPLsoV+R1
t2GDHiCOqHSOP0jpmSD9slZqVKBnhKOVuylUWdFfBD7wT7+DV2GtireB8j5GgKh0AyQveQAdUWKx
cM3n0HCLXLH46pvVxaVXlmbBQOVuTl0uWgt9ssZEdp2Yt6HYumv5NZIo10dKh+39sHTIxBl1hH7L
ikPZ7VTW7eOYxTag5kn0vr6WV4pb0GWTdhN9WjdK+2CiDslWH3Wr0vn+n70vdg527ncuftt78ifZ
AndvX9p//O/93Wudn+5gO/zt3zo3vn/2yU/QJmujLzEEH86oV0XA6apx4dF64uDS/EJA5mdDtD0D
1xvylg0hkm8Bj4f6AeuTyYKm1akH7kiQW/kWC0eMlwdC/i9TQumOSek9a8pV9EY2sgmHF4xNyHbL
vMDaTkCbNY8Saus08wUT0jZ27VlozIisoTwKIxisnuvVGKTkhiwiSAGH2+Lhw4JZu58+6m5fgXNB
8ifZzdBdGfskWTgPj5ojtD3su8PavPHNwQdPSgq9dqv78cP8CuoPH/ce3+s9/hAGoRLpffV7WAMv
nc/+0rv+CF662990P7rU2bkL7/tP7/Vu/XlAyIz7qMuYIT+EzN+koXJFM4pNcUQHnF9lFTyphd0E
/tdA9j8LdI0NFNfDft132Sh2HHkxmCcZ6NLB0jm2enc/VFeYBZCJE+maSTTrfORDmUtjNK6puBrC
UbJqWt4MACK1wk2IYtO7+eDZezeBnKzuuv/a6Vx9gObtPbyirpXV7db1zsXiZde1zh8/AtH2dx+D
aD//+BlYD2jt710/uPp+7/0flC98vtt59IO8ht5/utO9+YOc7V6+3d2+1rn6xX/ee18zTpWv0oVS
wCj9diHr//GmKDvg7zbLDvB/+I0AepAxkH1aQe8p5RA6nDLZYnKSCySew0y5I3B88OjLXEnbD/Ig
cfnOwRcP9ncf9uEoKRaMkh14meaXc5kVMT0eceSWleJhjjiaGzAKrf0InyoGpk+u7T/Zzv5n4DLC
DiwOioa/UhvwIij9/OMVLdNXwvpmyPMGBsnMEr82Th48vdS5f1fxQbfRR2Y3czML5vakWUgF9rJw
aGNIUStbkmTuRxAKOg8//RUuIy0GFLq7F3tf76H7/BdQSwMEFAAAAAgAAAAhXEUvIUxyCgAAFxkA
ABkAAABzYm0vY29yZS9yZWxlYXNlX2ZldGNoLnB5rVhtkxPHEf5+v2IClcwqt9qTZI4QnZXUpYxt
UgkhxdmVyuVKtdKOdGtWu+uZ2TtkiiqMjX28+Ygx4GDsmMSOSeIAfsM4PuDHhNWJT/yFdM/srnYl
Ac6LPkir2Zme7qe7n+6ZHTt2PMuZWDVJK4h8hzkkjFqe2yYH7S7j+5kknHnMFoy8HDHuMrFA/ID0
XM4DLkjASdtur8Kqju15Lbt9yNqxY8eM2wsDLoljSybdHkv/vyQCP30Obbnqua30r4haIQ/aTIh0
RLJe2HG9bLES1OFBj1hCBhy0I+lae43NzPxs8eDeBl2VMhT1uTk7dK2uK1ejltUOenOchYGYS02a
E67fLbeCw3OJbYLOHFh8bm/z4L7f7m1UKzO/2PfLfUuNXT+sVmr6a2Zmpu3ZQpBfAwj9vWi88aLt
RUw9luozBD4O65Bm0/Vd2Wwagnkdk4PwwIcfyfuNZ21PMJMDJk3P7blSDyRr8SOikHGjZGUy9PLS
AsqytBD1nQyMJI0eM0WfZRL8wh+lWStyukw25vfk90epDrMdz/VZA/G2eoEfyMB320ZpVi/Re4sg
4uCsxvLKTLYBZxAhQmr56N6caLejHP69Bp3zQFchKbF9ByJJEgNfgEttLsU6eMygPwUYmiH4Clzx
A/VLS2q6nhl6rjQojC2XqyuWKxwXHG2Ucrvhh9suxGzOXXRw+u3tb99/8P4H8fV3Bxe/iTd/H99+
bfDHj4c3/jT8+kZ893VayiRw1rMBLr/bKIBSHgclb2C25ulqfcruVz4dfHpVb603jb/+fHj3brxx
c3Dp1oNLX96/ferBH87ldMC9gkg2eq5vVGtmJn40A+HK8sRaYpgONu8/43LWhhTpGyFnHfdwg4pW
r5yEehnTuF9GRAWRThG0VuD0G0lmWgfg15BOaY7isIXJSwuzbd6FCKDtiHvUpOWX8asMWSwDeGqo
TFRD0hNrVaumngVo6kv9uBqslxmiQ82CXP2BGe3A98GScoIErJpXK3v2YTVGTSG5kbwtpW8QDOG+
krxVqVx6xAY4nTPH5ahoRckGSSFuhWvRbiV2nbuSlbUK3z+CljXbgcOOPkLx52HaYrvNQlkndgjx
2ralG/hza76TkNKsQtPUU18QjJcXu4BLnSAzATGBZj6S1WM2+E35OVc+H7XKi6FbfpFxATvUSa1S
q5Wr1XJtDzWREWfRmysFIUAgdd4YEa7FI99AX5ptO5QRZ02NQWOJR8yU7HD6lMRj8jtbLRXEssNo
cI7IrSU9ce/hEALSmZITSTa89XG8+efhvQ/gYXjrBGQDTRgTty0Rxfn7A58VtgPCkJFocGAOBzaB
H+6GRlElSEo9jbg+OUJ3VZ4C3HbVfkyPTlFGo0k0SwxvfD347Phg4+Lwk78AUUBiDr569eHWxvNL
SwcIndVSZ+nDrZMPt87A5O1rZ+Nzbz148+zwxgWa53hlwnSlgAxrlQqtT3hY035jDJ534vc+IIX9
R6JGLKh4MpNfAfmEQZUhdHDpw8EXFzTKWjBJLF48sA8se2b/QTJH9Ht8UI4A++ikeuPQFapcHvD5
CubUfKWmvp9S37voUewaONaziPuYRmryvLnb/JFZ3WPW9pjzNXN+3pzffXQCucIyEIMFRLGTK5qY
9wAAjKoRVASKqZBNJIOfKB6YgvUjgjI+fzb+5zuDK3+Lr58ZXAByPj28cwfj4daJ4b03448+iW9u
QlTEG1mwTlj0WFswCaE9shtIBJYX2I5QdANCbKeJSQcVbVp+5doO8wWoQbBb0oM8Pr/AFB1Dgysn
Bxc2yM8P/mo/nZZc+fpuAXsx3zEyJslXSDQWWzx71AJAfzC1/HfAKbbESiURGm77XWbUxiq24iUt
NWl4dD9R3DcHxchUrGWqkkw6GIIGg0S91T0UySkDj48v8E/XNK4TctVE4TEWGhWrNl+CxgsR6GDb
ZWgCNXtM2giQ2QMvNWgn8jyaGA1q4aDSTeWKemlSEfV6UMIzhhp526DbJzewi1DNw+Da1XhrE5P6
wkbSM+wk+9ka4wTK/BojNoHiv+YGkIsiaiMfww7gNREGPsgFq6Gy2i0PZnYkrJKrrlAtfh9aedcT
1kzqON/uqYBeHrNqpV7oFHBayYp8gPGQ0XMFVrJmcCjHgG3PhRrXSDpTo7QAbQoOLK8sCKVKAwNx
Yd3m2OZgc5nMQDGqWV4AJbGxgerbCz0mWTI8Ilzm6KGZNKJyAas200pYGKlTGs0qLbR0yjtgCKjn
t5mhRZgeKKF4xvb7xvgU03Hb8BaB4yrW1ZpHZ6duQ+ONS8Or1wYfboFT463j8e3bhWY0BaEVBF6i
hX79XTIhQzlvWZIPGW5jUZ76ICUAWlBTR6Dmxo1zD7cuY0XihpJZwqr4XnwTSugFbeH2tS/i65cx
eBURJYYVfJO4P++b9JzwOH/oZQniSTWYeK3FSbvbxAilJezs1Oz8a4dDFtCJYUihpG2mTzxeTDV2
ike/i8umOCg7L2XR8CSXZarcv31++51riUKP9V1p3COFylDIsnH9UlYrqJh2I0gzQC8oLReXj4Iw
R3PxR58Nv/xYaYlhRa2XAjgNpaZCrP3r2PH4zvn45NnhvXPDq2f02vjtM8NTx7ePf3P/3vuDM6/e
v3023nwXloPZ9+/cQywufbK9dT7+x7tTureUTBdJwsXEZ8wRJPC9PrAkIzowCfIFCT3gVxx0fYch
7GB3ajD8C0FbqZl0grngHJSm8tPZ5YM+R6boqc5tRGdJzWgklUSBW4QawR/faBQ4OfcVS7MyZVSX
zWp1SmmebJ2CdfEEOtWxhY9jzcz0fEaJ/yG7wor/iVszYxSOFvRdmDtK7DSFldPw5chl9QnPYsVb
aEEjd+i/7lom+fetN+LNz5PwVgbd//ZEvHkxvnvpwWvX4o03xjM5p8BO8gxzIn0MZaQFUWx3TWwP
OjAXdnlSACu45aotcaGO5h7jXSCBI3yMXU0KRMnHq9/RNHy14Lpevaz/LY9Wr6w09NhUMqlPgKLv
VACI7avXh9c/yggPC9C5vw++Og35DH+3L78+uHJscPFmcuVz+bhihBt6FTT1D46dHJz+axIVeFXI
ZeMITTa216AdQqVoPVPFpONOpxNhMJqjco7Wq5VK8TRPMZtpHb+h8dMdN60nGZX8N2lqNc3sH5MC
zVT7EHOaNuyR3rha2YMfrBvZH/x6BUjYimS7BGemABzVw2OS9hBepKa9K6ahoR1lrWETKuBAUlpQ
U7K+VmOV4qZadz2UdMP6MIiFGPAIgB7UPYgJcWh7QVdVl4RpeBDI4s2TWqRFq/3BI0kjS+uZKODC
dND8PwIBoTdti1Gejh/dCpon5pWmn+UUgmjuHNWVRN/I6fs1U5k6mryTLGFf7rGu3e4DtftIh8Rx
RejZ/TKWpIWklQdNie2t231BIsEE9P8dvNYniTJWJhKFNFD/ZaqTja4s0zV9f0RXZimhs0qJ5Tye
K8sQvvDyd7krwOQuHo5PzShEZNP7eFsGPbfdbPXBumx2frBofqKFiYpZTJ2fjZJZCXZXKknH5I35
Aw8ozKH17wwlFtInHKi2T90aHHs1O1D9G1BLAwQUAAAACAAAACFcnDBET9sQAABYKgAAGQAAAHNi
bS9jb3JlL3JlbGVhc2VfdHJ1c3QucHmlWv9z1EaW/91/hYCta4nRyDPGZsmASDlgguv44rVNNqw9
O6UZ9XgUNNKspAEMcZVTuwQ44kAOSJZA9pJaElK5LHCXXGANJP+MNbZ/yr+w73W3vs4Yu+qmyjNS
6/Xr1++9/rwv8u7du6csx6Gm5FGbGj6VfGvBMYKuR33JcEzJD4zAakiW43doI7Bc56Dk0PPUk+hF
2ugGSCU1gNAyjYBqu3fvHrLaHdcLpJbht2yrHt8GQUdr2BZ1gmjoPd91omvXj646RpCe59Hoyu/W
O57boH5M6i/GlwFtd5qWHRMHVju+7no2MNSo57lebqxjeH6ezqN/6lI/lrLbtcyhoakzb52YPFL7
94mzOvH9VpGaI2Nj5Tekcfgc2XfqknGkbP/h6GT51OzEGI5Njv/+wNHupfrZ0uL+xRnznX0TzXdL
7wYT9Len3IW3Jn43+vZs/VhzwTAnjg6Dyp2Funux2DYcY4F6RWEKMjQz+fapiWlYcSuCU+MnJ2am
xo9MvIZmdvrMzGztxOTJyVl9ZG+5NDLKvoamJ2anz9ZmZsdnz8zoTc+9RB2fBvLl0dIBdXTkDXWs
VIK/EfjbB3+jS4qYcXTixPjZGV0uaWNqWRtThoaGTNoEQwXeIsggux3qGegpqkltY9HX09OUypAE
H/CTmZbhgdu9bQXHu3U+uyIFnuH46CP8ihlgWAKJ8HvkDfgeu3hRch17UWN8pqjXtnwfFwMWpuWB
j6qgz0tUlZqu1zYC7sSRT0tNw7K5b8MNd2Rc2qIm813kCfMkJjk4vSTv5ZtQT7kOFcLjB6WFiV3P
keL9ykr8mF5s0E7W87Tjs7NTE3glGb7EhhJ2+LGafFRruCbI5ga4ftpIUiKYL6E8Fc+wwH1zi8qZ
Vc9Mn2CLqqdn+G/qIHKR2CwQX+kT53WL4QHTfJvSjszIEjf4UxfMUOssBi1UCWcKzOCwaqButFXN
cpqudEiS96kHUquyBaR3DLtLmagy2XywvPHNB9IU4yXt0w4Ufn15v/dgee3Vx707T3offSAdpXXL
cKRyuQC+cabedYKuNFLSSqNA+dHGk2fhytX11UfrP7xYf/FfvWufClYkL63f7aCvUbPm+rJlgm6s
YFEV4goR25Zjtbtt/TIx2aKkIpfLaklRSZetC/cjJXVUWYp2HPGJbCkYoBlxxKNas2vb4KONluyR
ebMgv1mZ1+BX2Utyaw9Wz9qLKztQw/3eZ1/2fri78eTD8Np/c02sX7/We/A94f4KGBj4etDt2FRu
Gx3ZcgJVFssXiFYiiuZ3bCuQiUaUucpIVVGiHbKph8S+5qL9Vl8n846tdx+td+Va2oBg0t6D78KX
y+GjG+Hj6xt/vxIbsu52HRPM51HDlOF8d1wAM9W22lagpwBQqLPR6jrnfH2uejBwA8PWS2z0QgsC
iMRGDulsarIRNkOPGGtsGdi3vH9sbN9+vk6hXGRzlQQGQEVoaTa5UodJ57IMfc3odKhjyuxO4dIU
dJs6YiRSNHtwmMvUr9Pw5ifh8z+Ht1fC1TsbP13Z+OVq+PBR+PTm5r1b4bWfhJkhPht6nRDtPdcS
7H3+ZE86OEtsa0Y7UCSOb74EkwByJWp49qI0cfoYJgMBUElukxkYQP8gRGevaTSoZAWCJ4DcpNNw
2+BWAZ1Gct9NgoQCCEqNALMH03NBCabUcCEPYSkGzo0jAQd6j7YNcDNnQV+gkJEEXmJkAupaCFqE
QzSjbsFy4MADaMWTNLFJGzaGIl0802CWTI64TgCrF08I5oQoaAjIahhHQasSIIYn1AaTEDLEYRgz
JeAHB0mOmLPJqCrIp5wGjcdVP/AUFqOiEc3yTWsBjpvgioJGbiAHix0qx7pQEJthFTY/Hj1cUhBi
5EgOJEIvREaMknt49LgPYdIBImtBGX1IjRdijrkjgfhOohXFMRF2ZTEUGYuTHMUIDkjn0c2TIDIY
NxloxuD5JoAnnzUAff7x9/DlTQ5/4c1niIx3r5GMKHkgxNkDYHAfwiCXmKfINb/hWZ2AxTamqKzU
OKIBJQDmBStoyXWyZ9dw1/eG65YzTJ3zUh3y5XlnTz4ZlM6TQRtZe77S++sT2MXmV/9cv/94/fFX
67c+3PjL5wmsB/RioLNVwbMgo5BJN2geiPbqXvB1VKTlmIZtgxr/OPPWydo7E9Mzk6dP6XK/UpXf
EBVZgvm1kzEuIVIhL2WXXkanY/dbsk1zwBkD9pXeyOYX93rLH3Bj9b68CgFskL0uE+ExpIKSzJWq
KvFbxsjYflIRNYjG77lVtBa9CAcMMnwZQnd9EUoYUkG52dOlxAut5mItThzBIRyrCZPUeEjYN5/w
pFUTTVIOszgRaShhcbi8f9+B0UF6+MfP4a0VyFh6X361+d1HvedXwpW7HNjF9tGL4rJHm6VYrRje
4lGWA7veotzxaNO6CIVBvV2MVywCWAG6Nl0b4Ct18l030EXlpU3Br8wplINgRvcCgBlSDBNxx/SC
MHoQLsSjaK8aDJGYsZigXfCsgNbQ/DIvagpEIoWkqiqQecjKkJ0gZYZJaSqTeWcSVQD3rh3oSXmo
eV1HnmNl2jm6uEAdQO/iWfjiRsW7JkHglYV04AfFSaJyweAaJsSFFdz6nBhkUapqZmlmaqfTDfTY
PRpGB+Wtud0Ax2e9LlUxV4Z7vTymwkmHBHJqfPY4qbg+HM0mal0lJ47Uxk+cIBVyhCz1lRHHwMKn
3OAY5jjMPwY5zMvV8Okn3G3AYTaefBA++zq88kxK1CByKpY4YdXi4CMO9OAVUAG2k2AjnJjrVuNH
DVEkq3rTMhYc1wf00wWlH4DXeIXkDvadLyvg/PuQTCB61wkgDGQijnvBed+ybbpg2O9bDoCuZb7f
dcCV3QUHqjmIny4rUub+OO/NO9W98/Wz83WiJgIgqkzmSpgkpqU1lShEQhTlmWjxrJTWHahK1B6n
QU8zM8elA1o5U1LkFPjry2uvS2avE2Xo9VLxHC5jv4f/s/Hj1zzn7V1/tPHVR+Hyvc3l6+vf3ghX
b8aZL2th1CL/4yE6MBb0VMFqWw71s7HA8BuWFYU09jxBLgxXbGiLSqU/RkW9o/NR3GBfRGVcAJEH
RTC+4TS8hQ9/zAA8AxmzhpuJGGmeiMESUcvKXLkaJ8jGQlzp8zm7dPjaGlnZimvPP+YZgTQtdgBx
BgjAL9aeL29c/VFIghDr65eX4v4AyoMlHZerXEmVPExLek5l8pxRbJaKb1Qv7x9dUiRJnhsv/sEo
XsKh5LKmFauXS2p5pLSkcOX1lRKMIdqFXcyNVFEKJt6OVNz78iXsNqPleH9zEcuqzq+EdkWcTTSr
MvJsoDTjsBNfqSIymrqcb05BQAYU7h9kUVvJu2/MMRuh4uEojW/y2sUx2qLyS8FBR4/Jh5EgrdcO
pNw1f7ENCj8nK5HTs1HcKR/qYPIGKQP81LC/tGUxxoG4d+/x5vLn3NeEGT69uvbip19ffk4KKECi
fKHfDisqRdzjT6NDrbN9kZnj46CfmTMnZ4jK8gkWL3l87CNhYVhl6QVntpOM5mDeyHoOXeI5QKHE
pwH3g34YGbyS8Vp8KDogjCdqM5eYJXZL1+qZVG2Xzp0UqapbHuu0qnuf/BUAHI7y+vff5NQOYg1y
yS32AAm9PiDH5xof5NmZTaR1Qc6TAs6di3PW6i490fmW+XB479t0MgywJVAsQivYYjYrTpjCOYXC
0vcjiBv3fRpMi16pnO15s4Zg9Ow44KkNKWAldbz4k5ogl31qN/GYq82OinFFbfsLalQaO/QCcE/3
TA0PqmU93XrX4IYjuqBOa4vTa36jRdt0l06wMPUJuo940vWpx9wrGerATi+4nhmdYjHcghwhohww
rFHH5GUZ0aD0bnXryLrBWwAalMAkl1lshbWb9/4Cnrfx7IeNV9+H155ufvG3qMHNfXLt+Yveg1WI
6eGz/+3d+M/1F1+kUHiPdIo1pOFIXTA8LKA7rm8hZEkNUD021wzbh/JdClo0NgYU+AaaVMLNaHlU
ydl3WhiOazsyFWSkZ2C/xfEFTAUrW75KWIpyDraggCrkE7jnqKOTSEtGx9LrrmvLuSjIDFgZHobn
80LP86jdYbbT4WwgLPTdCzH8Yba8P8xSDHQarsI6ln/Ue+3K6UV3vJwJyantGuZwNr3JT0jLIqI1
bJRlJXgtxNsyTHPXCR88Db9YzgToxEjjDSwHwEBGB85Mg710GHbBBYKij+20NgTVHRlSJe8WuV8W
xztW8Z2ogCYjpZGRYrlcHDkANEcMOHlFbIR5rg0PHbfYwCESd7hhf8m5gN0XdPJmpC29/G9Qeeqk
gC/QNPwalRmiZ444Ok5F7HCOjHehhvasS2xnpKqTt6BOgBNBCowwBiIjwMI3kFOnkpXDOW+vdy3b
rGGiTj15EPwpGj7Mg2B0SNInRPwqcS23r8QK6aiz2PfuJGMjfNMpootoIA/sNc4udijrNG7jJBu/
3Anv/21t9cPwyp97d5/2Vh5jlcDgZO3Vg7Xnq7xEWHv1y/qdb/OVB8eFgf1y0TiCAps1i+NmrVC3
ItqbO3q1tc0OnrwIb34aVTjXcD4YGavs5BWYUiCscMpVpv/vt1wDuoLsBcna8xsbr17xeiAtK8gH
aL15dWXjyd1BAoleD2sfHU6F/u1UsFWjvr8lGh2pmji/Mpw71QQXtRz+ojVKWlR0tCg6qxylxZ2e
wuwYr9VG1/NARTWRjuCQWCOdgCeBKF/XbIPo8jYYC1UOzMxAZrLWlu1brsW1F7fD1dsD8DLaQFSU
glem1YLKK5AE3W0DNBIQrhNxAqD+EM/5AYWBGuYJ7HBG0mYoTM9oYhdF9NqPGTZfOUPUASwTCNxP
OaDQzpfTmHRv826t9+nTXEUbYwRX0q8v70O+CPCxubwsYYNewibj/90A54bkMtldzjNYGMu25kEa
rHyVQ9nh3MStu/BJzf3kTvjqdnh9JU52e/d/7H32KAa1javfhf/x7ea9lfXVqPvJU4CslfgYUeeq
ykG0VlyxC9dKvX7hpFAl+sF2YCsK57SHYc1jASQionNO2YonuxZSqqYF0UYS87i4zKEU5MGE3S4x
uLWy/ugpoFD4kLWF8yU84zGX517VcUTEzRgvcnV08qC/pJvLVJ199eXeCHlSDRBcUWfiMEmyxW6k
HtQeZu34+igR2jKJEp8MfI/UT4K1dz8RXpYOIdUcp6geSr/23S55H3hwMh1VEQn6ivc90lS3DnE+
xmhfgtKBJejiABRZqJXcZtNqQP4eE0oQszTptG2meDFnKk4elcanJuNcwcf/rxJv0ySWgEHG3wyo
J3yP/SsLwKZtNKippSXzrPMAbgmkWsALbG3bTEYDki2sKSBHAY64oih4JIGUvpbO7fQ8cIosnIdt
rnqwX1VR4sSOv/aTc9k3iw+kkAD9XLma5hun25D1GQvwJK9zlpxkgltShGQ8LQ7Lu/S0a2xz0jbv
/hKufpMpqvHT0VMHZZse0jYrrN9/DJU7wvDPn2G29v034c1nm7d/7n38dXrBzJsQto+DkNO02q4p
l9z9pVL2VIFAup4/oFnH72sBpc/+cPqkK5lmlMoWz7DK9YV2yihuG/W3DQelMzG5R5sQOgFN9QGh
HNwKvKc5DNQ+dxrhCxwx3Pp7sAZRLy+lQrdgJ8I75t0KaA+mksq2a4l1ckz8lsHSg9euDa6P/5Gy
xdTXirdLJ3w22SJbiFvMo6UlyOwY7U6iL+sh9W7eWlt9OPj9KtMKajUSoMJ/sYMrPKnG7GlRk1Tw
jdfS0L8AUEsDBBQAAAAIAAAAIVzPaAaBxhIAAOk2AAAXAAAAc2JtL2NvcmUvc2VsZl91cGRhdGUu
cHnVW+tzFFd2/85f0UCxtwf1tCRe9o7S2ZKJHajCawrjrewKZao1c0fqMNPd2w8hIKoSuxagBFli
AQFGLBDDmhCQiE2BLIT1vyTq1ugT/0LOuff2cx7Sev0lUwUzffs+zj3P3zn3as+ePZ/qpj5KnaJl
1s9Lvl3VPeqq0q/pOHWkhlU1agZ1JdcwR4sj1oRUscyaMeo7umdYpmQ52OA5Vh26UGfcqMDYPXv2
7DIatuV40oju0iOHoqdR6tm660aPY7o7VjdG4kfPs9VK3aCmFzX9i2uZ0W8rHmfrXnqcQ6Nfrj9i
OxaQEHf1aMOuGfW4h+/UYaRKHcdycm227rj5fg79vU/dmBzfN6q7ao7VkFTXsxzgmhStrI9TxT1v
VspVw6EVeHlewXXhcRQn4IMcWqfAkLLn+K4nxeR7znngruJ6wNNK2a04hu2VDbNmKVXrnFm39GpZ
jFRAJkbtfGoRYCf1yiPnQWbKiOWbVYqd9Sr2dEFCZc+3Yfu7/uHjTwa/OHG6fOrjk599fvz0Z6d+
q5GJun34yAe9KFqQbLHB9YDsOnH80+OntQP7+/sOHGL/7dq1q0prQOmoX9cdGflfKO2S4GNrQhjq
Sfjmb9gLoybZquGW3fONumGelQuoKqbl8VZkDW+yVdy2XICvsmtcoH/PFueT48fRDZdKv9HrPv0Y
hSaT5pdfh4vPpV4pfPho69m1cOHKxtvXGyuz4Z3l8O7S1tTXvCW8utB8PR1cWQ0efxu8nNu6Ox9c
fU04ccBy3zElW+yLM1XmjFcqY7Ry1vUb8Q6jbfP3hQE3bom7qsjyskcnYCdsVEP3KmPQT6359Tp7
kB1yxt0vD+nF2mDxk77iL4cvHjk0WTjj9pzZ/6uhf+4945wxh3ugC1HcmIXIMDYaWZXSJ9ku7NbY
i6H+YbVunaOOXCi18mpz6dHm/GXBsc+PDRYPHD4i+BY8/u/mqyfv166Fi8+CpZnmN9OCOWD/umbz
HTG9kjPk4GuUmeO55wwQ+QjZu7vXd53eEcPspeY4mvzYGXOvlFMraZwUuolVSHDx+dajHzbvLQVz
14OVP25+/WV6C4JCNA2t1VpkJI33YILREnegOr4pDxEkjSikWDQteIH8FE9OBX+YwHoP1LswrFR0
G1SEli3fs31PO+34VPGMBoVnrf+wEu+j5QMc0C6Sk4Onj5GS5aqgXmgTCjlxtDx44gQpkaNkMuYn
I1Pl2lixqnQ7CX4E9EvN5Rfh97fCb6bCB0+4ELNajawQiq17VgN4xKXI6EAWKeDUqdZnfdDX91db
cRsKg9krm6vfgsjCh1dAiMGPtzdWVjef/yWYe7N148fwq4i8WlUx9QbVIpesNs66+Fu2HVozJjSi
kh5bxS49RHVHGkWigJsDTQTHDCGBTwKuMlEi1D8IC2qtatnUlGEBcm6EFCTdlWqlmnrOMTzKlWKg
ptbqvjsmFwawPzpqGZqACtOSC7yxMgZ8SbUyNhXixaCLQ+26XqEy0qjY4Agy/l7OUlozTL1eT1EL
vIQ5kLcqnTBcz2XzFFBLfJNxlz0L0YGBQbR0ZceyPMUdg0BR8T1gP5fxENPTtMywX6GX5IxOBX0v
KC2d4/kKw2I516jSCng0Nk20ys4W0MGnkOw0QuO4r4qnE889RMr7BhU9BimolFmBHPGAmUdZBDK5
optVA8GJUvEdxudSpKOZWJd0LPxd7kVmXHs3FEzd3Zqa4VYX3H0aLt8M3t0IZmY3Z66CBYb3XoW3
v0Wn+e9/2nx7f+vuLKj++7V7W4tTzb9cCu79eWtqKrz9urn8ZuPd+ubNp825xWD2lnSwT/qfy3+S
Dkrgz3CWRQhKEKPekWinI3rlrG+XkccyOjba3jD5q14i2Fbkw1yyY1tNexNOArrad7e62a0NhgpK
LnPldrkvZBpcts6yJ2Y/3HxshfuVgVyIdSgCJsp3oHC6lZxus9UQMGqt7BjIcYL36AI1ImMEo3Wt
+jgo1W4N506e27AnzZjmm+Xgxy+DtT8EKyuCEw0N8aiKgAwMMwJDTBxGDTao4muSAQMxhQ0VzFkm
wqwJUNPJwltVMhIUc7BfcQVCiV37YWt6NnL+1jlXawwR9F4uGU5HbAOsDbhogufCXkodRMd4BH6O
tQAxB7bhRrgyDYoczj4I7s9F/hxmgNEQb9jiGUcHDXy/LMYWOBmmdJH0qSwC9+PX5HZrMhwXzM+G
tx+Gt66SQm6FIcL9KBmWwOIz8CgRDuvHqBguwD7Zo/BZw23WB+vOkHD9Dtg18BrsAqx+Y/3+5q27
4aX/CB7PgjCaSy8FUej3NCFi4QNJLHpsACEwJvzaMmmGUzkBYV8IexUuIHxK83G3Fs0e+d12W0jB
4o7CS5G2Izbyjgkf+XN3RrYhZIfsRNXi5qEIDbtg2DJod2Q+wwrT27zOJVspZaCPmCunDhmIm7CF
1tGhpJ0NH17YzrnyjUR22s6V8uldWmo7vUABDcPF8Jg41zzMaDc2jTz2Ak5kcQFSB9C8EQrspNL4
QfWw+iHk3OMUlC6K1IBXAVINgCvAdm+MSiJIMj2QfNOzfAjDVXV7ZeakaBkk0VnXOgkoo2gZCUFk
OQKRJSsnPvBnlIyYcIeyEL0j7kexrmIB8BCxrl2QA7RahWm7B3deiSmKvjy2xPFONG6zb+HKGEBP
m1m3cJ+aXcDUtJkBYG8bBPmIbOgbyAZ9HIspGKomM+A0X+IVorWFAFo4zrmUdHcME9xj8OY7vr+N
lX8Lnz/aWHkRLrxA1JbNHwGpATQDjIZlgfmvtq7Mhgsvm+vzzUfXJMg4/nfqDyl1EAgG5Z5Orz7R
QU2EpJnbrtfzlQOljeQVVvPB4oxVryMTNDZRgmHRoPJ9SvlyTw7G84JExvhZbtyhoDHAUvtcOSNj
YwNVEFkHZBIRKqp2IgLx/EodoxMiZkBwQBq6BweWvIaLD7Zuv+KAW2jq3J3g2kIMrzNlCRZiM85l
gE7YwBZa1bJpR3b5TBj+2XJZRJgYl5BfmSiUTaS3jRk7XbCLkrConV+21XTxk02oOJ/EE1hkm4pK
bN+5YJkaFvMXDaHN7kWpLw8t7IKW05MsU1OU75VOQ1xCkcdRCwJQg3o66p6EZesBsM4auJsxSZfQ
JCGMWfZ5ViCwfA8b2aZEnqXmWRqpRlKWjI0E3mT3vluL1C4bwhhyi17lY5XwHQjsGNvBJnVzFDSX
O4GfNyjEsm+jbi/uBItPWcXvWnh1HtxjOkSA4YF7DKavcl8aBQRepsZ1sQImsjTkY5s8rVeO+qnx
D9M6l7TifxcAN6i+V8Gir1PDFpns++2+xr7q6X3H9n267/PfkUIPKZIerLer+N8hmbmYodKHQt+E
IHlmmqpnDbA8aGg4tlJD4d4M9YqafoM6OhaFshqWSy4FqMK5tIsci5SwhmIUsDKF+YtAMSU7ZvZk
ZyiaMcHEogYy6sM3lManSrYGy8hJrEVLG1Pr4JTqAUNU3UblwGQvcabl9PbyeUWyRWYb2V0KZ1ru
sM12+0r6i811NjBhOwPJkG57zk8s9gdoNuqRS8+Vi3EWUUI1UETKXGK5cZy9laKJFSKiPLjcyOmV
cq5zMrWqsEJYRkAdpjqiXjHZpoq5VzrOF+Dw22o00FcyXA4e03HBPVnowfwRF0+jTFTlcavCz98q
uhnhzcSrxY7UwTM8l1aFvmfLwUpSLu8S0oS882cP24Z4HrsBZHEHk878UiENPwKs2AlOaa9JXR2s
UduZy+5CaO44KUvoXwFL6USFQqj5SHfpx+wnyClVcdy+EPZTsTDbWxqqtoYbVrsTzjullpi5VOq6
60JKd4ryBeTsEah67PTpk9G7Y6ChdeoID8pzHv6mLLrLLq3XwMh/r9RAsOCflYY7qoyBUEAhFZOe
g9m71mH/0fCO+SPS4MnjUnP9JlZWr8wGS18H89cTeDh/PZh+vfF2IVh8GdyfCuaub01dai6tb91e
Cq68CGeXSLIvPt0pWJ/PnyyV2kQZQI/hlcuceOSun64xYKvKWzX+lbzybTyBU+MZIvqby2+DuYXo
rO0qMlEiPch6MX0Peb82A3lJMP08WJvaeHsjWL0BQXjz6SxPUJrLt2DDm99eChdn+Ntgbnlrenbz
3ZJ01DI9LMmWUNmljbePN2eukSQLZYIoo9NDWSqedZaaGiHZlAPepE/zCB7Cu6XeXt021FFo8UdU
cEm9DrUtt5e0xRRzz4Jp4PuKYLIULN0JF37gxKIAhRkJ4UPIGaygWUDQgbBUN7gn6x03q2LBHu6n
yRcuAJ7BUdghi0/ZQ2qF/FORr1cctI3ibyLPTA70HThQ7O8vHvgQ+hzVwakUj/IbCvDStIoVbCI8
kMHmezSZ/IIgN8ivCLo/aGOVAHwG6UBaqLUCkYiDjKclsbMhMugD3nSMC2xHEK/IRxRSMwckzjrG
iqZ7ePDlpeE5O8vKmdyIb9SrZTzbAuVKLLOgsuOuXOdTwvBQ1BGrxXchPro82MdOx5w8JmHuIn19
QHYUdhCfxCuRO/K7CrLYQcbjpe9WMHfBFATXoxN5U8/bI51Q0UsUJHZRAgtL6ZnlzNRfnDrBBimf
fc6/UxdH+LqR2+3qYbCq/P2t5vqfIcsS9ICFBm++i6xuhh+Ob6wvhTd/yB5D58gETcBaOguo4gJD
R48W3JgNVm82X08316+0uZqArBbySNVZklAtOJJMvN1KmFUC2L/1Kry6ED5cC9bmeDl9R5sTp3qW
71ToTg6mRHrCB6Syk3Gkrm3hKFsy4mc5EdrkdniRMOdjYMgjpdZ7LArB6GZStG+gY6QeWTfCVOrJ
bO34CELOTKeQEUc3K2NkUsm1R3NOxhdXcpc5hgaLv9OLF/qKvyyrxeGe3twzv0rA1h5Kzzxc2EnY
EyW71Xnu6TMHIOiqIupwR2wNll+L1aKXw3hcwBnSRkk23k6HN5fDa5fCF9+AUkin+A0jafPp9xBn
w5WHW5duZC8WZAXRZmttJSGikShWlKF9tBv6URB+GqaeMt+f5+gvn6n+PzwIzJ3bipLRDk4B/7aD
Pl5/ibMgKSIRqzA6j3hYORqn0rkxaoImSr6NrIGuvaxqw44S9Dpy4zyA0loNYpI4UICAM6H1i5zZ
xctMjDsiqRQeoI9l4qwDGxDvK3fMuJthWtZFZOqx7UYdo4nbFSVfPBYs+O4RgC2AWeLYoO0dJF5Q
0tofNEb0pbMmUW7d/ghSaF0qbUpf2IouaWGdNmMWabthXTLJE75teztE4XR1PGnZ0Sy8ZCBndraD
ax7ROtxF1Cg6Vu4ZUpuJbntEyXeCYPlNVC0TnQYY0GKFvPYRikPMIutGBiJMzLdqG9o2+LeHr5l1
e2xwHW/NehoM6yG94ram28tbSSqysxdaBpzzTpnwnoNHDEOxYJ9OeDka4nlEfMJ+qK9fOdR3EP4d
moy0P+FJrjaYykq5Gic9M6l1aoLktiZW3X7RZ/V98EFnCMJzkvD+HxHjrE9vPXq7sbIqgdAlRCP3
Xm2sPAFMksqzuUBS66VcKFYLDVtuKYh3DszDF/v7lAOHD08Snv20M/sspSmAlDkK6ig2MfFOjRJ8
5ahhavl7vTLoDVN6RW5rpJ1srqCkSepyLRHVO3VTmBGdtyxFEBMFfSz7RkdJnf1HV5+Qnkrl4FBO
TEdrZ03K/v2cSRnswaeI7oXxGpkMcTPKzy1bw6ehvjg2QItGOPWkxI8JWdCu+g3blcW29rNB/aXh
gkJNFy986m7FMERZPrrFlJmSVamKcSVQ0Jc9WUmmzQwVIbQNOdFB4k+gRwwtRghrJ7O3Hkay0+0d
r8m5VxT6Eq3YcljJlxtuPwdz922I5WHgJzBClEFjkUTH8B2EIQpxqe68MNepu+BUkQHYZFQW13YY
jDeuSOK741KrCzpNq3IanEY8Uw2POni4gSbOqrhcRi2V2S637NnwEv59hmH6NDOwobXA1fzEjdzp
HbuLnj3PbPE3ne4HNNpg4fSHawG/fA3A4V8lXpVF6MXuXYqaGU7PcVxrTV4hkM5uPgCAxGpq94LL
08H8f4nq7sxsBrwljiVr2uJPW2hKVgw3aEIqA1a9msUbqelir2aYtu+lAgurg4HDpw6DEdIQ6YF5
sl6vB6CgROIQh2Js6dNy6YEniSxTe78G25sKF15mszksaNxbhXxO4vkY8AVShuabB82VZ8HVy5AA
vl+bSTGF5+nZRC/53THTFkz8KVlyMnu74MyZ1yEqc6wg/qZIFd8yydZKnzWX3/LYDrzAnHdmamtK
vM0WUIE3m7fubv7nKr+WhldKcBo+dCYtnRZoFNvH3wZFumIQfri0w6KLwoseLYSWWv4ioDtA5rS2
APacIuaLFsA64GHw4g6qG9sTyIG3sNNnvL/KpcRPW/AqICSyl+8G00/C20+C9duADnnlI1heC66s
sos5aZ+/zc1mTsiN2Y13izEf/w9QSwMEFAAAAAgAAAAhXFXOSqqnDwAAWS8AABMAAABzYm0vY29y
ZS9zdG9yYWdlLnB5tRppc9xU8rt/hZKt8CQsy5OT7AzarQDZWoojFCTUgpmakkdvPMIaSSVpnExS
rgKKLEmRbLiScARI2HAsyyaBpciBgR+zmbH9KX9hu98hPUkztrmmyuPRO7r79d39tH379kf6sTPv
Uy1Jw9hZoKY277QX+5HmBSldiL10oDmBq6WxEyROO/XCQOs58SKNE2v79u1TXi8K41TrOknX9+ZN
7cUkDEwtTEwtclI+lAzgKen2U883NddJaer1AE2/77mmFlMJgsZxEJpaSntRx/NhAS6bmnr6yJOH
H33iYOvxRx96+sDTjx58xtYJgG3HYUBTKwmJqTy6A/hdHPF9YkwdOHL4UOuhAw8/duSpZ+ydtamp
KZd2tLgfII4WP7A+7wVOPDBdmqTwC09qRmHoG/UpDT5w2EMB1bxer58yfkWxtwSH0dphNNAiGmuu
twBbG1oSOFHSDdMEDpc6XqDh8diWrhO7mu8Fi5x3CJYjtQWzrKfgvyDEsGKahP4S1Y2GQlNxqTJh
NJDa4jSjn+HxOho+WF7SSgY9pEE36h3H83Wy9tMba1fOjC68dvf774bXb699fWX1g2vDH87fvXV2
+OPFu7furH712fDczfW3fxz941PCwTFYvUXXi/Ve6FK7Fj5Qq5n0mJekrXDRPhz3qdHwXAoMTge2
ZLQckCdspE68QFMboc3KSUkun9sawRuRCqCCMJXgGImJLoSKH1Q40PyyEKQe4inxtx7FtOMds4kV
zr9I2+kMMeH0jHTDyIHFgxwyfrjeW6gkCE0qWYZ0lgjmWDBDjEaYWO0usFSfsMJknDYKOCR7EUkL
DgC7PJpMRjUDaxJShOHl5pBJaRIJEyFus+VeIanhVZDRD6NLH69f/LYgtXNvrr7z8fDcu8MzF0qE
cGNsJdTxcwKMhhhuh73IpylVpgq7gX0xjXynrawwueiNRjII2i0QGkgvjAeKceCnA9zy/ZL0UA0l
mFx1hEzjXhrTCiWC0CUaex1gIUctFbHKYjZf5m9xcBJzq2YwevPdtc9eBmMAMxBsVT1EGeJmBswA
dMJYS8J+3AbfF2hzYwm+v3wOicBLaYwojGbOVyTIVqnSC8CQTRyfFTg9atvFWeonVCugmSXTyvqi
KYI6MM/BFzDXni+gx9o0SrVDzxyMYzikk2AICuOKBrBRi4WnbTb7Zx382yMHn63HjpfQDa1dxZub
Nj6aguYkdVLdgH8tFMN9IIYHHjBEfJKBpLXoBa4eh2Fq4i/hu4AyfGLODSRzgvScoO/4EP2cfhr2
gLdtslyww9Wvvx9+9Pro4uXR+VNCPRIH4kvB7yEaY5ZwNZ5BDBbGdGKeIKAKAJbUd5oEx0kdv03S
jinEQbcVJKTOBMVUPABLWTZKkXahrSshdUK8asS0Fy5R1679HpFLhAMGMrNoCNT9ONBqmcZnXkJj
8RvRS1XO9QNAZesK5GkAAZEUZvnmdgicCPq52vxBexj8DqRTWjf0Ic/qUsivAkjEYs0P24uQOYWa
A8mZs+AFCypdiebTTqoBp2KtE4c9WMXyC8zb4rgfoW1ZKq0xtTp93wcRtkHM5AUZyOYOzDzvzByv
zfyx1ZxmUU0Qzeyp5O2y2UxM0/bORuVUgssllHPOTAfQNE/s27NcRVQBgiaU2HMRkwgmpApD4wU/
nNfJ/cRgCoIMZhZnsGyVSbggkqZKGgPMFgLr9UgxwgBX2/bOHCVbuyUucIMaE2MaQr3EUmETERgF
bWW2qnOLS1jOaUY0cEHe5iKlka1mr0L90EpLSSPfbjR4dl6yKw5O5G5xmAJ5YGB8KURMx22l9Bjn
QexFOmOqmK1yNp/INZ77ZcIQZGey55rjLQrJ/40sSs7kMpkllkwTMARJ8qv6he7LVrZVfF5ZndlM
zg/ALEdyz1TBUkkJoQRybIRv+aHjJjqDocigkpjhBgvCqy49sIEaitLIZ5hDhnHF+fO6bRCBumbL
FF9tGOhDwFsUqSsI0HIiVB2dQZhTdzdz8zUqIVV/1vH7lIVVU4TXEmNyDAkUR/oiHdi+05t3HVCN
o3X4m6s1zZiCb0uoqCaKUQFVqmUWlCqDOQeH0tFyjHqzoFug3Irp2nZmCVWp/UJ7Z9GzUQ534x1A
Ft6TCPPVgv0DPR1vAfIxrB0TU1SJhAhbYdu94zx0K/ZTdQtsQcUto/mND35iFTfQzHQk/TiaO0uk
IEfNlyT9XsGh4prcmTIAP9d1i0wFQNIx2YIVOTGkxWxNQKkLGsI4wzloTLMHwUfxxEDNEpR+2A59
MIXCeNv3AOCMF3RCKz0G1ja9//6dtV172Bf3vkK+uMuusbq7JXDXNqvCuShzkUWb1P45g1WkZRZP
I9+B8ZwZsyygjpMCTqAgKl0VJK28PxNMRYHYkWYnlfVGnu6orFEPoIoUsytFiMxOYUIh36VL9vho
V1xU55imbQUtg4nRKWe5XFUhSKLntu96yWKrn0AqxjXDsDrgCx5UYKuKsUlKuvqvO1ADQ2K69t1/
7618sHb95vDkqdV3vlg7d2l49ry2a482unVy9Y2/51lqlYrs0IwOToJAO7r01eirKyLNL6A6NTpz
enjto/X3To4u3Bh+8tHo/I3R2Wt3V26sXrt4b+X0JrQwR4VK0OLdLdXhdG3R9bOSrrNr7z6hq0e9
tKtVfZAVQiSBUm8ezB5KrU4uDtTLdrcfLKJiYlKg81BQ77CoqGcsNsx59IBdqx9hG1FnmzhS4X26
VpceE5RK4pE/PZogB426xmo2LY9P2ZTwyaweMiEzljVKyZSNhpb2YNDCY7aSfqfjHUOHx35MEwsm
icIHdmgYM8nRyrlZCuD2e5EO6MyOSYOkH0NGmLQ9z/6LAyprQlAHs7B3AdaOdTQG5ujkhUDpmHSs
jt9PujosgPKyg9FIhzEQWBBKu81bSkBHLdxXq/HVWaMEhiNjbPYq7DIrSEvTuS50XBsgstNikGUz
Jowcaj39yKEnH3+Og8dUSKHTFR0G0XlhhPphQtkMxyi6KV6wBGRkAXZSDsyjLyhD0vdT+8Rylimw
4IOZBuV1tBKD1OhJfZtRD6zxIZFYoq005EALHhBms4rb64CuiQpZyTuX69q4mqgY2IqJF6d6DoA3
7RMEV5A6k5LjsuWRsZznWX4xchYhTTBM+eEGOtkef6ldauMMU/1M1NDxLODEk3rBqE2CfRJSj0qd
E+0+jfVOxvGIh6IS9EyNSR3zy58DF2KJpvZVhm/8G7zt6J3rozMvr77/Knf+vNlyb+V9Mg0YC16K
E1LUcNbvVJR7YmOmpHOFrgyrVUl9vNEsjzVxNlUkRbQuN7c0NifpsXGoTJ7acclmqi14UbJyCLkR
qZYjak65l6WKk8tXqIN2W3uJFNMSPGgiOK7cGd54c3jtzOj8t6OXPodAByHv3sqZ0etvrX7/IcTK
0cXPR5dXhivnRi9/Mrx6VvG1UYx1BYEFq6dPic72N1dGl07n0Fj/FUIqwNGWdll7tOHJleG126ML
tzOA/3vpFWKioOxkkAC9Lo1jJcljGsIZq9aIGfMqdSLyplgcboPiEExXjjKdgMGNXCkzd1WjsxNd
vrL+5Znh1a/Xvv0055LkjGhk8OZCi8cnVBNTljYTgihGhwbrrJcCKbECelSNn7hGeKpqAJUhUWKb
ZrGx8TODIp0QFSkLi43NYqI8fdunTqyGxPGHjqw+6zHpPS9JcF92W7YZovINyBbtk7FRL5uWsSlT
0YAYO3NuTmTmeJ+iNn5LJYLJb6kGuMl+MgyoOMiWbkN5BSyxFRcrcFl1qTzzFhWHptYbPLLYapIr
ULLp7D5NbWZNLKPUui7vLOHyDdIAtXIY3nl7o+51BiBzohl9Wa8GsZmFnN3IfQV64myLrOv5ukIi
XUwgslQ10ef4YjMD0jQTCux04KSJrUMWZJI6pFUWDdoQP0FFqjn5xheW6gX8r9YTfs3y65UEVWTy
zTs+iNs0vilhRj3pPm1L6sMp/z10Z0LaKC7j8SxFrGLj5At5KHFHl1/bMhEZIZmottkCeDZSL1+l
RaZ6lyo/uRtnk8KRcy1zY6eTQmTpQZ4w2MwzZ1dNY9l79vTqFz9t5Vap0lU7QfgIqfOKjgRgFPA0
1+Q/wQbAGEi9tizMj5cu2S6em8pUuGjVk4GZpB2yOyCBdjkrv/Jr2FIXOiqkFg0G2eZtX8yDfdKc
E+gKVyns9hECGWTNAURNtgKsNoHQVCm1lbIVjQAtgK2v3LiWgZqu194YIH7YdTHWbwHPfPAZnNHo
0pfDNyFHh4TFmKvvrzWrmwixXgy9QG8j8jB29bbxJ3v3LpZk8kfIqXY9IC45/kx4acToL1w544dd
KihUsMY8o2L1408ZCbt3Nas7CiS0QQkdP+j3+CUDw0RaM2QMAexCuAAOO522QI6/Cb4YFONLNnHK
zBhvBPBB9v/ZMXc+yBY8aO/bu3f3Xo4IHe64+kzqgYw4Jzir6yzwZG1VeT3MaKjjt0logO9BubCU
0yefGSmo6stqKpwjE4rdtCHr4DrG1425b3iMDviPw3BO/utAClXBfD8Vj0cCDyOTuJYo4ZMlLNd/
MKwcvV0zhVUp7rxU0uV+x/WStgO6w/JhJ253sZ0AAQJ7+uzOYaM0UawvTilAJrgrVBaxarIbG751
ZvjDW6Mr/9z6XbkSMUS7kdU9oNOjc2/cvXOVA843Fd3UNlseWYaLK9fWrl0VbwVxmm5+w18GymsM
1oHk3cn1186OLtwYffzp6qXXBRJ5yk1jbv7WhdiivkAF/gVKEPlKopX9CMKjevaAX8fBEqx+2mYF
ZgdHdLLjuR29He7hHX/d8cSOZ54XdIkYKnDN6kSoAXVnyDRDN03gF777aOHXHp2lR+CXmtOE18xZ
fSIrkSzyNSZEO1zPqyUeRMudna3m7YLq6otSWSWiaDy6OBmRVb2P+jDGtX4Lmj5Zj8crXh6J//Pu
8NIXo1MX1m5eH/746nDlleGtW7+tBt64dff2yeGpy+vvXZVvPcribQMWqbyQFpvX3PlF4qTKTblq
FO8/NOWh5KXcBLveulEX7/8KUbnSKc1u6Y1KmN5UaHKo9BpIbhMvuCf2Lx+G733Lz89kb4fsX35B
dLci8WpItTc54eBcLdY//Gj9k1dBvLwVl4v09O31185xkbLOXGRVAzjjejm08YWQiHnHS01CHJmU
oC0XLKbQc0TzYXUypmosacPQxl82Mcn8IMW8Di/1OnMcaZOJp5O/kpK1+9i/5XGKlwhrzPCa4FEC
wU5pEoUksGCguLaYFTrttO/49ubaLTVNItlm861j7K8gvooVSmHlcQAku/a5fH9tI/vJyi3GNI5/
TjCtWectEeAuE3DTyEx7vJGMbXEowpXgRaIy9X9QSwMEFAAAAAgAAAAhXO5OspcTQAAAKqsAAA0A
AABzYm0vZW5naW5lLnB51X1pdxNXtuj3/IqKe+WVFJfkAUKnRSq5NKFv8zohPCDd915FV6ssle1q
a2qVZOyotZYzGMxoZwICJEDC1EmwSWeA2AbWeu+fdLtk+VP/hbeHc06dKslA+vWXZxa2VHXGffbZ
89nnF88ONf360JhXGXIr00ZttjFZrex4ZmBg4HDDGSu5RnV8vORVXKPsVJwJt+xWGoZbmYAnaeNg
vdqoFqolY8yddKa9at0oedOub3gVwyk6tYZb99PQ0DNeuVatN4wxx3d37bSMQrU2axlFp+E2vLJr
GRNuo+b4vmVMOv5kyRuzDK/mFIt1F5/90a9WLKMKn2pOg9/WXdmi7xbqbgPe+dXClNuAv82xWr1a
oJr+LPxqOPVxrwSdNOslqJyuOXU//FZ3/9R0fajXbHrFZ8br1bKRrolJwTS4kz2v7jl4ZN+hwzRQ
w/ENWSJeIY0TlLVe33fkt2+8eliUEeDIM+RkmYOH3jjyxt43XsvvO/Dv+w/sE2UL1boq4TSLXqPP
84rbOFqtT+Vr1ZJXmNUKpP1GtQ7rJAv6zrSLoKgU8kWv7hbgLcB+zClMNWt5rzINy6k/8V2npL5M
u3VvHN7V3ErRq0zkj9a9hht+LZRcp64KF6rlWsnF9/VmBdc17xWhca8xGz7Bhc8D3OtO3XNhcQ69
eeDI/tf35V/b/+tDew7t3yehJcrLORzir8/8bv+BVw8btpFNOOkpr1K0DCddcsbcEn4ouuNOs9TI
Y42kMQ646CAeysVLTzslWOpEMvfMkdcO52VTLW7pMeUNbxxab5T89jN7j/wHVAG0SperxWbJ9bP5
fMWBeeVzzzwD/RvjjldK+MmMUXc8wITfYxP76vVqHR5SgVLVKSZqWMBtNOsVQu40PvQTArvTB+Ev
FAHUdIr5hjvTSCSTz/APtgDIVq41EmLaYtL2gWrFTWaeMeBnxvYqtaYoYQwaiXHTyLZEwXbOxPmI
b4bnG5Vqw8DahluCEZtmEqqYGcNMAiLVvVoiSY2K4c5g5RkumoD3CdFQ8kmNPnMEVxeA9wJNwvGn
5AzEfuwzESAch9wUz9eoVmBxYEm8okHTg99+AyAE1Mkoen7BqSNKGi6gLBAw/NiYrblFoAuwKHUi
QtgmLrOHy1x3KhNugkYlusMf346AV85OvW/UZ9XS0cBxXeVLd6bgwkjDRUdS4YaN40+t7lUaCdMw
ug8/CuZvdM5f7Xyy8I/1i+YgQtNNDibMf6xf6q7c2zp+pnPuLpeiJfNeosGmRhRMuWdCObP76PPN
tTvB9Yudb65Fmz4d3PtrsHiu8+NC5/I38HZz/Vz34QewIrQQhclqFWbB063WgJLKhRgRYOERU4Fk
CEKLaLxbaZbdOpDxBFWFKqI4oJzR8tpJo+W3zQgG4cqbW3MnOqf+YlolpzxWdAw/Y0BDYy7sEmvE
KrkVai6ZVPBPjcjRugUgecAqgPYVoXTZBWZV1JEGIGW+VTFxdL4BIzXfqvOXjIBUsHJs8+o7G/fP
dN97EJyeD5a+7pz5onvttBgm1OdGDQeoAn+EneDUG/5RDzamOTo8OpoydZzx3nbtkV1hTdvmQmMl
Z8rdkXJcPzUy+mJqolA2ee12jEYRitDaxnkzg0yP7dpZdAvVIqCXRS8BxPaRetNNJm0b+4vj3D76
41UrsrHfONCRKgVDwx1JrwQcxs3OnevG4UmnWD2KvNM3cMxG59xPne8+6d58p/Ptu7B40FXbCO6c
7558d+viYufyKkBv68MbmxffN35NQzUAnQCcgLPB4srmJ59u/mV18+MrnYUlAU63BH3jzPzkSyOj
0TXoHv8uuPuBMTJqbNz/CjrZ/OZmFFd8QfHkegssLfGC64tvAQdGGNG0xdpg1Qm3wvj5r1ovMbJw
ndwKrxPLIelGdcqt5MdmG8A5sKNkMi1WMvnUqMWdRlsEccV3xt3EjlGFpjxlRY7CqYrZ+wXb5BXZ
ePQZfEC6QpTBeNbgNQICwytBBAbgKkgL1+oe/yo4eVus5tMRTyHHpcVfQLIWrVn7H+sLLRwRfDiB
vCWOmT6BBEagpgOfewtB/z6s1rPmdrOO0+htCMb/3zQb5I+GWwYxCv7A7P1EyC9bCZALLZKAkBST
HGyghOK3kVEWmvU6iu+q6m7DBW43axyddGG7+ci6mxVnGoaHkr/imgTSarNhh9I1imiJrOn7pmWm
fou/SpVGs2bmLBRZiFhZfqMYq3Rw/8F9+Nit13seo4SHxUeGLVo2JnhpbuQZbbESbxympbK0Fg6r
j/QqycsoAI1g/e6TzpdznSs3Ni99ECx9s/n1SrD4pbaGkrU1K0W71VbYTnoPIDyMIO3XSl4DH/g6
NRm38RG/TETwGqneePKlFxBrx7PDOcJhaCthNgo1AFizWAM2AroQyLaVphvF35pNbDS7M5euc9tm
xgQGmx3J9SBvYn+l6M4wSEJE7tc0zS/tuw3BWBMJHJhVS1rwDMTMdLOGrCYBWsQ4CMVOqZSom28l
BhLZ/x7IDSYHgGPDZJM4o6zZufzV5pUb3UeXNm+fMnMRwt2agsGa6T9WPSD8gIxuMTGdZJl8yppG
IPBIQJsoAzTbkrtDh6AfuSTCJ8oCyqLNxIvDREGzplMou2Yua6ryZg6IwmSjURP0eufOHUxtkRAl
uLygqsgsBFeBPvIkw9UTZYu0iQrQaVBaLLU9xAhgT/k2QkgoXX6iZWIFM4O/2wJ5QEPIO4UG6L82
aRQwy1DRQMJSmU1Us6Zbwa1VNHNM8rLcUi5aXLzy4MWzthgWga+K5QAG+MyXUGcmydJoiJk1WwpV
SQ0BepqI0jp/0qm7RRtnbPwPIzLnajIZKYosIz5EMe6eOSKwcZVq9IA7iXasyOK4uXH/LMgbm+/+
9Pe5061qdgDp10Cu/fe5Myh3tAaGBiKYxa0lk22Dd3Vw7K+bX70T5THh2tAAaAciGGie+KRm29ug
X2xwR/YeHGrV2kbnwoqxZ+/r+4ytr053V96RBAXFIJAn5dfTnYVzmx/f7i5eDs58YrxodC59D2+5
CohawfqiGV0cGBBJqzw1HF5sGEcnq7bCT8JvJvm9iwMlaWr491nbMH1QilJj1RlTSYAtqNmm2QC/
6X7xtdGCsvDlzFUYszYwqfDo25HwTfCj5sSE67PinWB1DuUjMXCcVS0UGvCNVfZY1B0cHR4etna9
8MKOXUltnn20LCDS+hR72HaGpER9gNg+j2+y6jcQh4D9F6tlx6vkq5XSbERWxB5DfJG2p7RXy4uP
+iZCVTdsJ6O4+adbx09vXZ4D4Tm4ciVYOgPLL9SMa18Hxz419h/shan/TP/pbNMZLShS52apVHYa
hUmgz9nh1K/SuUHTQrvDdmMRPQMZS5eqR4EoKDGShfOXR1/YQepS2pR8isQt/ExsINank3obus0l
XsmIj6lcC1ZypC3fJF8xrWkm+UTwfcEioQN9qXm8G/fXULdYOiMFoEsAuOD+zeDMYnd5eah7byV4
+D6KRZcebH06zzMK5he6D77ZuL9q1JqVWRSx+yoPSrEsVe0Ra9KzEdteCJVFEizTnl/0JpCByzmX
qi8RBwa1xZ70Qp3pk7vB3HrwaH7r2lpw+bbRKlXbf5v7qDXpxdRcrstDcMvCKqT3GQfof7/l/1tu
8N/E37fS4oO+qlvvLm8uf9u5ug5kgwHVf8ZIixnfY9PEyYnlfnFY6WJLZzZv3d365FGwelPofSMw
pReH+zaOZtI8WcYApKiJmWa8k+0k+cdI8bi9seU0/tqZkAxVIwOqxJtv7n8VJpDcZt+ISWEpQ4cU
oBRrNUCQlRYU0XDEYh3182iI64FdRFEbMpOSoxcAd/yaU0AFD5G9QMhOr81XNDPEL6JWCEZpwKKN
tRvGkBGszwXXv2eCESx9jeO8uv73uXdegf+/6LsQKNTkhbGqbEHPhaj22yP+4LLgTKiohCsVxWWM
loUBCyG4aJPBBtjVxk83JVlb6JyY61w+0fl0eWvuIkotBvPrYP5bYByg4umWHY36kkCPWMOdMV2T
OpHLPTFPJUw3Ldo5YQX6KssXHDtrloBBggZen601QOB8261Xfb8EsqEwa4lxG3v3mFbWfM1tvGX6
xj4ub3TufAnosXl2JfjiPaj8X1D58OHXYHYwqe6j4zyG7tl7oIgZ+/b8GqeVs0aEpswDAvhPe6DM
mMlnbdU7C5qjyRwNs+mDONWqSBGImXxUAiMciwtNuojC8lclGeol+e218MIkwIWEYcsEsUcDBi+f
LnzAZLsrN1hYAVwEItC5fCWY/2bzwQebl77vPnxo/P7gYVrPrPnbI0cOpoZHAFlBBDKAPFgmrHxq
z2sHD4SPQfLuAVIopiOUcEhRCAlsFfI9DL9XlhccCWGZMcbqrjMVSrnK3kiSWdjIADYyoBqRMs7m
2buAuoyvGw8eEb6eRt197kSweHPj/tzmrQiIgF4Ap9l4tNz5+CeAFVdkiP197l1l5fKVstkjFII4
q3caEU+n3FlYrdroC7sAnHXfGR3e+WIP+rLNDdcgXjAGaWgtj1ZvArQsFAW2Up/sltx/maIldlbG
tUKUzhQcS1u7TGHSCjvIwKcQGyvbaRSM2H0UnAw+B81rGjrK2UUmadBmzfHqiTGv4tRnpWSG1gRN
0WeLDujj6OLIclHLlGYgBI7rgJwxmxKt6QYJhrljo5PMderEeA/WvWmo+Dt3NvOW/3zircODSZNq
JHcbY9GSzbGSV+hTUOcTjhQgxqLGh+6tLzufLxmHeHAGLykyouOrwJpAlWYMC85e2Zo/s/lgOWY0
B7XfGoNfgsO7R/NlgHUpETqSWqYPoCk7ZmbUMllBMDPmcJr+AVhK1Yl8yZ12YZVNrzJehUeECBky
n4qly2RzbU2IUOxFgFlaXqVabKM7L1103Rp+SMDrZMSQKHiIAA3KBCFmFGdsieWde2vByatiZ327
Fnx+yrSM7AxMl7BrBjGHsCY3mDU31s4GyxfQTH31fvDoPWbhweIHuMXO3WWBEcmaxtqDxXdBbute
uw06GFHxiCiPIyHbO3URV/rIG1kdH/cKnlPKM4ilV7IAqNZwI+UR1W1+LtDY2nvkP5K7hffXlp7i
BBZM7pa+FvE64sKMq3OEXSBwzGSHQZFWPssQOskM/Uk7NfTPJqgLS7Yc9Wf16IqyGFDnjNqkadB9
eKCh3oWEjhrOK0cRlc0CGENyXgHq4hUB0xCNUuZg1JY96c4kdiYtzYRiKeaXwX3aDomqapIgq4jJ
buUvVJx1t7TT8k5iRCILH1YZNAEpgoXjoH0zjgDJB3qv8A7xgqcJDaK4AmSJJR8m2iQkm5aSra0K
k1wqanEPMNEKG0SyqZ2ZnIDyL4y9br3hAQYBUqBFpQF6uG+Me3UMO/CrRmPSNRifkLQZU5XqUZ8e
EidRFJjKpOWG6rEwZaISIfdNyrPdz9LF47R6TcnJbbeshHgfdT/iJ1UrwgCMGlwXkAvT3tx65xFK
vWRrkG9PmFrP0hmh1TetPv31hUaIihqf0WyHgvfl+mCaXoNmECx/0Vm4ByPoPvq8c5acXyAWGSwn
gVZvoIzAWrYlpV2JH6IlS5evrVY7GZWAH2OsDBckSjvSIAzVsSdipfILDFlggAlghVHDoEA065y/
ETw637l6vLtyzJRDU3Us+ijl6lg3ormKZQAhswzBm3XmVGGOgTiUJzaiTGdiLTXJQO7R7qMLnb9e
UzJRKEmxc7kSdS6HDVgjuoGTRb+Blpd5eRR9zaDLrqDlqkegZkwK3rmMb9vGn42W2uXyG9MV+U0i
QDsTiu7yHW6c9oBQF2teYUrNNwKC7SAgpAJt9lFeLwwWchkF/VldDBbvmUnhHtcMwMo3rukJEbs5
DiqhFlXNNJmWFcRMhJ/Zq1bUfKIxRmnpidYmJ5BWiB4gdioXLyiynY9XOqffge2yuXxtc+kY8ODO
mWVWys0IeDwfgzmcCijRokGeXZIs8aFVi0GxcB5YecT+EQ4klHIslnKU7tAyG3XQ0uF50R1rTsj3
lnnUqVfgj4vmA/g77jQcrF1zKl7BbIdSHO6gzTsnNldvbdM379wQPZ2Q3uwOtWAnpD2sD+8W9iF4
wVJ4VDyBx0okz4WT6a/4tskqEfGMhFU0nVCWU/K8ViymY7T7WMFZx+kuPwRBNQqMIvtJYFK4Z8SX
J+sJfdAz7vztY4Dck/qv4dSv8qlca8TatbNtSq7GRjz+jD3CqKIoxIRw6/iZ4PoZoN2RKYhpkOwj
29utrIiNekLRg2RSW1aNZmBxZYJTdCbqjgCYaw3JiCkgZ9GBCocGmRs37q92PvkeNpE20Fj4oNqh
RIQEze6BpLbbdCJpjVWrpdhe2zz5Y2funV74bKvW9RNae0xLGqye7ceT5RhCw5JufgLCAlp69/j3
PQNSU4mhbOhW6aGR+k/NJk9KuCw9JZAJYzOE28omHFkqUu5B6hSulUp2AAsP5Npmb3PUDCFaTdES
lPB7bEH9gd1vS+l2oJr9szymEVsMu6gLtWTvdGnvd05/0Fm4wHNmw0uh1jaU406CAb1hwnSiAQm3
HPnBdAdaxBvGoxZarEabQnU2kwlpM0uIweW7wWdziu2oADdgo14JI08r495E3Kkc30CiNIjJITuU
DZU8t9IQO+vxrVSbjTH0bydk3Wbde1IdLiIcBjPsgQQ5F9mf8PH6DTsSIkovd9OLdHmq6NVRGIch
+hx84c6gNFKd0iwfFLxgZ5Un0IhJtt0f3u+c+xSF9KWvOTCI41o2b70DXzcefRbcuUDWQIUrJlOI
v81dZtHrb3OfbazNA3/evL7Khgx+zpbtjbUvUQu/fg7kZu4RtAFefpQAtWaDpffV2Iw3D+03eFHJ
On4a8WplPZi/EVz/tvv9jc7pE8Gd853lHzonTgX3brCzDdpTDbAfjFsIVkCW+phVwHifZz7ZPPWN
IcViY2vuYnD/fufCipKeN+88hL4POOhGRi1AFYVC3eXrMA0eCDSMjj/o89Q6TBJ9VEpal7FI2Dlr
H4AtsCggI8DyTOGnJ/NLWshBWEnTGjdt/EHJVDrKQeDHb0gyxLcBXoUBJpQDgroMCMF4gAXjgbZB
TWkwUbDh7WvsfzVjKCUXuu5cPhOcvBZ8ejtDPTJVR2IH73iv8wtJA+HxxvrV7sOP4PGAMWgIR75G
ljEEpYbuybYZmhMobsSdtRpeo0ThONmI9qI0HRAYE6YEMLwQwW34FH1H8AT9QvSd48CwzMmrUIzD
HulNdWwcY5oOOyWnDMTXrRude/c6945pjeE2hCJ/cMcO06kDg705/I6shHkYLpRQ5r75b9CCi+/9
SdTGaTDyLT0ycGC5HgYK7RDjyvCaS+MOQWLQ5NWAMrmnYc7chDFoG1nkrRnyOi2t4B6/91330XHm
srwf4eXSTQTDgf1iySXLzkWxEJvrp134zXIZNEWkadGRbcOlEfltQQRjMMBXGYXyweK73bn3mABs
ffQQ9leGwpKmcrtpA0kQ4ZdoU6Tmq3Y6d653bl8LPjvfufwVi7LcJpIbdgmweyCkQ//z8BsHUNeP
EJyTtxXB0TBW7ms5mCjziNnTDH1MgoHe+ytvSuESBCQFcqfNGVhtSN+I0IYDINKBNgi0TovtwgNI
oc6TbsygzvBWRQRoUe/JQXyACMpA7C0zJctoC0c8aAj7SqbpbAifVxDm8ypa68vVYljKGq7uGh4W
oQjOtMtv5OAk2/TTeCrCtFqmemJmEJrtZBi6FVoZIorrbuCvPlmpnk7ziOOkqC4D4RI1TR4MQ1l0
gvUvk9xk1ygQCgHs54W8Rd3EHEHEbUq41d3xkjcx2YhYLMjwZ/daAncbY01/NsKPMNBISYSRCKmn
CEt6fEgS9iV3ix6Z9LdjSxyWFIqGWFSZGdZgK5xiXtP94utg/seNtXMck8imRYzBWlzaWL0eLJ1l
VwyLiyzZBPMLvM+EHRJqraLLr1doJUsyxvmKHYGDUBYzsmkJN+oX73e+nGMXMkhSStTqHv+qu/q1
6Obi+8I1uH4xuHybzdKd8z9uHT/Z+RhEjBNsD2OzDB3ByhcrIbxL1YJTkoFJINDFzDRAiEtuoZGn
YmIPUAiwrVu2nsYRHXHfUBOalTTaKSiU5RpIrLGxJXdrcQbMGmM7c9wpeyXicYmd1i7dfCLO//nV
JsY2xPorug2cIzeZ4EaserMC6LedtzBqVuHWM2JQtOnEs+Ru5VTef3C6xW23jeD4Kip4pGWggidK
U2g7j1FEOA0MDSSzo7l26FKAxtz6uAOzaDnhQbOyU0v0CzXrgSGtQHT6ni+n7iTVKqlulJkVo8cv
r4K0HZy5xuZqNX5AZssQuIwj8Rt1S9AM1Y6F7ml4kUzKmAtUouplt6hHw4Z4J17m6ZBbSBnVCzUu
NggGH1wAPrd5bRlk56cZl2qnZ1wMiz/bauR/VmV1FOZiUccsdB8sX2RAKYs+jAO0lK33bmPM+A+n
OqtLwWfHkQ8vrnQfwgY9zSDduH9y46crbMrVwQvb98CeI2h3/2EZBAR0EYgIt8UVDFt7tNS9dtrw
x8p4yANkHpABeWgpr4aYabzEre0/+LIhwLN0duv4me7KJwKjJh1/l3bGR3J8PXQUt2s8pjKkGa2+
QY7EyduhdLJ9WKK2Q13dzCd/cESNWWIWWXMPiBJ74Ccu86lx+dt7+M2ih8baQTwdYO+gT3h01B7B
jyQ5mxZ0ZOHQY2cPYocMXt33+wNvvvZaeM7ghV6TjIyo16rtRY5bPKgdLtDPHRzhxvbN1Lw6IKY4
mdDHukRA0U8jXLnRXflCSHtk2EIxGyYxaJJuCfOcrcHn7vLd4MEnQGQADkb3x3lgE+huIs0XKAyz
MT7awEhsvHrgsKHwBXGVgk9YVQNZF6MMTt7uY47Szzv425x26Fk5hQNEQfsiFZ+P4LOkyd5u+yNa
GM6LP0w2BHTslwE4iW2phBqRRiUoAg/gzlEYZrLHJqoqqZhXNS/Ph+VGBOctGvdG0IYHsAbzt4Fe
BKd/Amm8h5pc4gUy9gzhNvj73Dt7Xz0ARKJ76gbThc21RSNOMdBScf0cyi4PYYlvSAJ5Gs/ZfXz7
sdRje7qBP0g7jD/bHEyQBmHAB9HZtneF4QQh6/knBOhtXE20qyMmac3CZ6M9D5uisbG3Ttr6DEnB
8V2k3+1pBgizhQZ6cVLo2oHeAR+nd6XHYDjTuzCOOhIVJJHzWdsclsHxZljWUPZ3YxilyRMY0i10
w8XTnasLLFDK8IGnkov+3EJXghQ4WCbgLyRe03JKbYejTfLTI3RCXGzGgs0nyfHJbqNsayFB7NKe
qYF8hKGH6BMDIBTCIIS8dCj55AUTGpalaVuWWYcvrqlEC8T/QjIlW8VdUmCzflgJ4JdtmRweZnKq
AXQ3ORPh13ZOq8ldQK2WOe5VnJJWTHciXlhBrrtyLFj4Guhi5/yt7vvIrlnpxUhxOtyoAqdE0D2F
GKCzfvkafl6+uPHTie6t94OFT03l5mYY2GI42wAom4tEyqs3MO4RnIx6kB3OcUMqAo/jqxTVv8UD
ZCvL5tpHnc/fZ1YQLIP0cLv76J3NW2umjFHT29UHoPkP5RAcEUxQ8YdH8lq0pfbOKTXQXIYHYPKo
NVLwxrYl8LQMF9BGL4z1PIcf50Ec5hF3T78XXPpe086qsPflkDwf6QJ3qY0sadv9itEpnVKtEimq
DYG9Dmi1WV8UJyt6QdcvwlEDGp53k+GOoctVj3uMeFwjIZAcvErpIB47PUHBhMM1DJp0YmGaFjtb
tbheIr+FbLgrNUo7Zc9kGbkicbNToXsEKDqO0DInUZmve84oe3oRb2bCoA/GasSeHuQMlr7WHfcy
Nuo0KMmdO19E4EzETsR54cBgnwO0yCSrfRcxXrEAL4tNKliOWQCjG5QX6ml8xXSpITT9Yn2eEBaS
nlYrNAHHC6gXuXYEhGhLUSDLGBVp/mmxNRiboQ+RJixzbAxGKgALn5FsYKoZWAD0rxYdKJVsh9AK
2ac0dFSQdmtscCb8TLV+YeybcQoNo47IYCCXMuruH4FE+sANK8UU8AwgxkhIvcqERU4G36KAfDqE
0Zh060azghFlFWPcc0tFXwWQkUof5VXkW8fYFatg9bjNkj24gvErkrQKe+jCOfbQbK1dQOFjbh1F
n1Mfbq591r15bPPSOWFXXV0N7t2IIJMwWpWZ49Xdkuv4eIKe9GoL5mdhEC6e3nZgYRw9CpW+EzPk
0ttFlmC5aDzJv3uN3zbHjD0H9xvdRx8Hlz7f+vjT7soKy1hAXLq3bgaLH2x9utT5QcZr16tHIx6a
Om48bFlTtJwJuy44gTORFz6KqLNavC/WnXFBhfuEOEy/VRx8Ky1/JV7JpPCk157Ufzmpt9Op3CCe
sIIe+p3zhS1kw6vsSCZHsQu+3WjW0K2JJodKw4L38jhWykwi59IOZ0WFY6j8UmLEGtlpDfc9UQxI
glO0x5UxL9WC5tspEPub8BnXrZ1uODDlt00tNqaChuKEZg4RMIHt5TaYQmmUlqAIXEN2l7QIA3rE
+D4jbNZLtmhlDJfPreeLsB8QYzCrAq3NbgO0K3SwKsKO33hlTDPeC9SKnAZCOu9nhoYm4FtzDH3I
Q4edCbd+wG0MSaAMSZwekp0PgYbnTAziWaI+o+4f9eJPOsAwMogHTmo816KoFx5sv0ZwupLUtEwh
6ZsZ+ID8zp323KNmpi6PsrhiiKbF54gs9mX5k0i1ZSn5JO80CHK9vkJBowGyGfhliTGbGR5m9pcZ
IJy0yGZGrqZlll2Mr4Enj8MiBUyzHdnkOE1FnUDBPfEwWLiLOtjnP4KMhccIKWDcOPzbPSkYCqrX
rERtnsD8CuK04fKJ7pfzUF2GIxzfWPvRlCG8glQMlYAr+CrDEQbp+mh2cThgt1z1cckKbqVREkoZ
wsoIYZtWVCSN6moCVVRxVKqeqWc1iOesOuYy8l3Nf+9TPja77MwkEvWQ/mBzChZZtbLiHFFKHeiE
dxIHcknLiPQdpQ96yQhpiOVp0leBB6fW4c71zjfX2Mih1mTz9nfALgDq6MEniQJoLcYBz4OKuhLc
Pdb54RToqlBg48Fl0LdUecUlyLXTMrkvM8N/LZOXBbAUIEECHohi/E1pMJJ1ZLiRrPmnplsHPZBZ
h3yruaaQ6US8J9MAsMR0mGvjsFsGIKVguYBMgLAIyJkxRtIjL6SHUyDFTjrpkWHj5eiTX1m0KPwM
XoLEJgs8r7Jt0BHpvAXraE9jurqGR84tJNWsYoYEHc0iM8lQdMSq+oJFrJ/1MFkMNjGYALqetOLB
p/h82EoOcgfwkfsgajyjHZTlHGAjlt59rR7p3dJicJw6RqWBTDVtiSwk0SBh8VCNUJBdNjJZY7aA
vkV/ZQtC1e0xHkXbkN/+sb6AbtMHHwUnzmxeuk+RJBxx7oA+IiaEpTorH3Opzrm7LA0EZ45vrt5S
xV8WpaOFz99CdKbUVsGZ77Y+PSOqhJ4c3FF56RmvxwDh27DtBGZjNAh+FYid0/1MTM0k7RIZYoLl
z9EySPuNzIIXlZ7LlWiIbHmWVS+agxKSbCC7/BVTQYoYp1NLK2vB4jkz4ucaH+hcngPAaJv5YsvX
CAZFnPgRWpbNjAzn2q0IHuhVFCQwrpqXDImolKN4q4Zh8/w2r/LUmFZII1G6oteZ6HBBkgvuvyeG
W4oP11SUhxa4pFNRcQxB0SKqUHri/EqPmx/5/ZWTJjY+DL9S4+HF5EVW5DRYPt1ZWEJj1MV3WRFm
cx+ecpbjxBACimjSUSMaaI+hz5gpL5S+4pAWJVgeUwNeXNq8vkr4I96Hrh6xi6Nuh4p7FARS2rn6
qidf7t3M22xoboGSt+gSEj4NnUprH3WXVwlYJxA/L76voejpYG21u7zM+ziEAq+FbAr5Osk+vW3y
/gGYYjxYHP8XREQjUosTRAMocuz81a3Lc3qPnC3DJe+sEAgSNdJuBAzC0/R1Yd8D0fSJdGF7wsKm
wkl10o63N+9/PE/aZyZnb3fPLFGQXz/EJL0IU58QO4ONMAaMk0tvrJ3VsRSFLHLGc28b9++IpH+h
PQ1P6Q5njBlbJMEoiWcjUesySjU/iw5kpCgYDl8cGlDiyMJScPJKmJ/j7rFw2xz7MJif57raJsRI
VkHapctSRzANnWbsUrjFw4lo5x0ZIjwkWIXxgdZ0hB4lJDkiWjS9HS0CKbhFp9o00i45lN6gbUsi
L5KQtQfCtByASygr5TBqfcaW38LTfMj04yLljNb4s6pxyqIjDq0owAmEuXwCJez59WD5J3Y/oSGA
szAcPLTv9/v3/UH4K8huKh6ZmkzPoA+JdExOm1GBs3jII9xcKNaR5cCbdimYluwaTgWG7us2hHoo
BQIcoIWmU7JFLuI0KzDR9KyiTZGkldP9JZPpSXeG1ZwwvQo39iztYdaEcqF1+1T3wQOlllBIF7J2
gbLz7/GJGQBdmBkRNU6Z0jhdraFBWEzPrGdAw6bEZxr9ZcXKt7NlWvMyrnkDd494IdISpkmHx0EK
TSwXsTHSmSOuII3OFNnPj9B+4Pk4ooSyrYiZnD21uf4XzLJ5bH5j9XT30aVg4Uc2fQfr7wKN1LMf
2Y20WD9qKmwcAzJ6Ap9FvBmDfpzWIRE1XYRLHfVfqizI0XDqsDiZA0SZp4ysVpPQHPE9uY173ajK
S0P5jeRomnX3YNX3ZmhY2pIk0zwMDrjraWzSazztOst+cz2NCIKLbWV67AkxjMBCOjrgdx0X8Ll8
hrkwXwYsf35keHQn/croiMLUK1j9aBvkkD+A+TAnWy0PgWK3eBxBiSgyiWEkJZ7sVrGJXFUPTIyE
LcKLX77wgoqfq465KgzriW5RtLDqAYF89EXEAwqdXIvO7WcD4iwgouy2p1eEe1wawDEu+M1XDw79
rzf3741EslLgvQobZWpKksnu3s4BLHhUAEkMniyzTD/PYZroVYXSFXLvjZsjo78kR+1IJhLobabY
ks/mTy3uLG4wMlMiwk0epYqWVq9ZicvLY3qpvXtEFPaQ2ygMwRCH0IHnR30jCty2DbABKgmQwYlh
rC1q5OgdnhzV6kTygOFPPZ7yEqtblIEahLV/Jtfl4SOvvvHmES3bZfKxa5mAIYvADjoPpcVoqyDD
8GgFByGJKCUWBeppBh1myAJ5SwgBGdHSUGfxWufEKdQp7n67ufYV6hScJ/POQ+BDfPQhWDypJzQx
exOxbRsRk+mHnNp8GAk5rkVKyJPNslNRSI7brFnxOJDZ/DWs2O88/P06/f53+n0Efsc230tIYwxR
F5YfiyjDAEWYZtLD422jhe/bBClR8tcipJbLjIRlNL/XkI3N83CLzTpHH/tuQaryboGzh8ETYCYW
fi9600hU4KP14q6dQGx2G5PxFzt20fOyZ8O3oaFdw7r9AsZTbBvB9b8YrUn4e3cRQUb54YTpAgqo
F0ar7MHnhWMcVqFmJJ5ufXhFQpsoIu4lldBBKSHRPHx6dnoMO9AT1OuGGBEDpWqKZkVvzQpXoX0k
N8ELfTrst+/+ie0Wj/oSf//ZvLK6bYltW7VmvubWURHhwMlpEB2H0zu1JNS+gxcjRJPGZuOWO1oG
cwg7GwJlr4H599mS9laFEr8qJ00S3TohyVLgKifGk5Yxnt0BRAMTx4Y5aF/eyes/HOZVCyneiOWN
2HKIu2VuEwTTbvqd9kuuW1NzgyKNUcsbVVXiAxkZBnbwfGIklfBGU95IcgjN1Y3RFHQ0Ek3blgg1
fCtMYRuCOMzVCkIMnlyQICz3S9GrA1CUlzDsCWObsvLWNCfu1eyrGW2HEyaWs1M52sfTCvQgQ5D0
EieA284lnpZSuDhlphdvnFLHZR47HWD8QyJaJjIhRISnz0T88ijpaOPZEWSHw+InJIrjMtKkB/w0
SCFXkez55OEW3en/B+ijT15GZdk2nZuLitm2WpHdesZFnELS4k8vRlMSh7NB2cKD+cgYC4orxrtR
QtN+Vl5OwZeM4I6wKFdsModptI9OOuz8wctuOLx5Qhyl8A28rIZvyikKwVgZ9st/jKscouMhk2vU
+eSL8ln8MU26RgR6ZaGr/rFn52VDLmspySc8v2Jp8qOlC6bJfqIsZycIqbIWcNZv/AwEHn6yL1GN
ZKaWI85ZYRBz3LfOsTBs6Qmj1LL6Gecpe0aLubLMV1CUrcmHemjJ407B1xBj+vlPKe9zlhJ15zjU
hhMpqFARy2w0vYIWcGO2BS/Oakm+czLGxA9vWxAyBhfTTu/pLlsZs4OhNNZU0pqyariGIo9iBLux
mgAlG0LIXkjW6QQd1tFSxOP3jJGtuWjwrFnpdDrXJoBrlQwBcErqJ6R9VI2NRtVQR1oQU8Qhdonh
yGEVi1fZ4RuVGsfEUII2rRtKllDHcPRaJpsLz1dRoz8nCzuqSso7LPUlLNUvZOFJGdt3bpeUvSSz
so/+S7OyY8+cIdn16RRYtlRTIULIz2OdoSRAtNHM5kwUw2olZCJmJjMOPxnyy0exwxVJQ1FFyuM6
NP0Eh1cJGJLtQARQR7a4OTTt1IfgaxjJgNF1Q1q0pA9jmChVx0D+fH6oxc221Yd0AXdfxBFJxgUl
R4Xe4fWPgjsXWC3BLJw3z+HNB6SGbF2e27xzIng4Hxy/ytIrp9aWYdW9ebhPmNKnFmJjqMvOvDD8
K4oOrgJK4QeAdJGxM+WBuIXmGDIZpGBhc9GbkCLSE9Sz5TVmafUBitfwQ0IlPbYFlljmc2PGc0Xj
ud9mnns989xh47n/NJ77L20RG2+j4BK2ib/eBtaVbjYKUbq6HXopuGp5B0X+DIyKuILnzM5/z+Ap
OrO+nYBJpHonUakeTfQfRjKN9dgc6dQrtmkYf7t4FRSPDzZWzxojL6COwnYHXh+Ri2/tDvTOCgtU
fwnKCXt0VMkJTvxl48GnRgsLtbmphRYMMfPcf6aeK6eeQx2IJgKL3ML+20ISLzr+5FjVqRcVX7KI
5NCnmM+ZhVxQ61ArRse/Etb/kJiypjXKctQrNiZtlK5HhY4oq6Rdx2/kHd9zKnkqlShMUr4M8w+/
EeR9hFMCT+JT7TAyq8RTg6ZhPo/SMUjGwylqIjk4LY1QFDkmwqRKcTySBGDAZOZd0mQwtIdU/ZSM
5olKYURsItFLBw/tO3LkP/MH9ry+z0afvfkahtwIhtm0q366SZlsgFI3a/Y4SAGNhC7tNQnVYecM
K5UFSRTKPqjLotQwgq0AK8PPzvREguxNSPbR1Ab6UwFYjci9PaI7re0+P4bKOdC5+W5w7AejXyEx
+j/IzOJoqGrxDYE4DpW1J9k2/vHgstES0OZvwbH5ztX7oPSnBQhFoWa67BQmAYztsHm2W1LzygzQ
rIlmu99fQft+i0AAIMmkR9GYwF9Hol9H+SviOoGmbcAYwhOEBVvXMwF+0Pfeg29SxwUyZDxHO6vQ
5/K1qCtfKFBKowJ1rtqQ6Z9fd8tHqpT/CpeOUhfD21T4dk/oasMSvqp5+KhT06r6TdtX9fDdb+ou
1ZGAAyADsafxs7kHO0uSa52/Q79JAgfok8/jS9Yjqw1MAUcTRl8rQBlbl5X8pt6EDy3gSSFBnqjH
ze9vBetXCVaNKjutqHH48vJw+lexe3rkFYqTzYZX2m0Ubf6ULnr+VL7pg8ROucDlpDa/fGfz0gVj
SJtWMR2fWDHdQDiFk+MiQ+J5OLf105IUyorjAER9Spt/WQVSjj7MH79jwkpFXhp56aUdw/GpjBfs
mNIpeTK8CundmK1re/AKHWLFIrqQSmp778hpVCdksB6KeSlKLQs1UOSbrB6ljGvTpgVNwYNClQR1
lBecEuWJiBMnkMFUR8mXd0TsuWMZBHPnh3e2ji8SkKFRPCL+kYTRGCqAbYDOsQ/CR8DDEdjB+hyQ
go21G53PboQ7S7RMU6TW+aAVjFGeL3Mk8R2iUNkwYpXqyJOxBTtiwZn1SQ32atM7h0DExzhq9Aui
mx7lv3q1FF6wKHLF7zb+1LcNpAdDcun+hHcd9lSVCAjSOoKlc+pGcO3zztlbwcKPRqtQYHK0deFK
sHDeaP2JMIjJRQFoJUaxC2QxDHbyh1eWjP5SZAkxfv3rQwQ1EYPWqOmiFbIAFBb41JVY9hSiw4Ej
Bw/PVgqT9WrFe9vFtCepFN0fYMbkKlxYFk2sljmLyYhNDGFZOt25cwMPcVXhAZqp6QGhP56eX1nv
Hv+eLMlDKrmySC1ERyTNNtEgGK4VHvglR3MkPCrV9ydUdfq/D48S1eyiV2jE+HTfPcJ5FiJwUoqL
ANkeuqjmsFCX6NHrIEof3P+qAuohl1m4fPBmxWv8xiuJSn22FYyIVCIVSNpw7ZbJV+IAYJmPbdy/
QyfC1GNOQ9K58wUlRvTo/IbJgMUVoBzSDcyfDTPAN0srIOhhKwx1BAyzgOiUzKS13SsVgyaCr7Xv
DGuvaId1Q7AMo+ZPHj/bVPYTKKwFLFKAglfkU37be3wQNrwPx8VGbEGttjTKSlUsqSQxaYdqFKZQ
oMGzhyB/Atvbm9/72u/yR/b+LubIrPu+kOvoZs3QrCtsizGJrncYTf+JUt3vy4cOH86gPBfzLzGM
xk2+ZE4cRdeFlxQ5LqCX7MivckkgXlNJJRcBA5VkFSYhnoMcYmx+v9Jdvma0EmFlmM1g+G00l6S2
2OmyeevDMKr+SQqNsqAih6V0YyYL9oM0l8HxASZvx88gmWqF2KHvkldMGC3okzwT4gSolmAFs3Nh
xRQJdkXN6HZKApGUxjKZSnbppilj+QogFbq2cqMo1VkpH8khEa+VElFcyYjxYRoX0e4biKkwmfog
DO4bYRdZYRBRGzYIvifDWCwZpmSYg9QSsLFBQIEHl/k9qm0tfjGi3Ab0PfmyuLpw4JWBthnphoKx
7CfNmEppVk191PQuz3TF5oKenxexAzhXsjjSCxHw5TcL6IoxkypSL4bb25kcrT0NYDVjzYbEqkjf
vS0BDPQSGYTpoE0QuzzXffQBw02ewscwTHGUc+F659wdPLO6dJNjyKLTpqCwsLHgwUfoxAN2rGKM
OXyL4iLFSsXCJDWpnkIOY8SFsAlbX18wB6knU1lDNBj1PWrPEXj9ECwCrl5D8OMX/smL969ZOG3q
P3eVMI0CCzwjIwaG+onkCexC1/sMA78jFWRoIcVTivjqE0oukxGXNMLwJJkl/AT29i4J3W7G51z+
IFMPILekGemXkChgVCt2ts8ZkXp2p+Y71NoaFzkCQSHF+5crpLIE89/yd6yebA9IuVH6NzSpkbNM
iFOkdy/i5ZAff8tHtfkY9j/WL0qZcochH53QYwnQzuzbuuk6WwfFOJwE3gE+Ht6MUwc9RLO7Etck
tw15bchpQ+ZytyIh0Dc/rVvJGA1YW1smCI/tWL1LbK83jMur+TYNnqUe7DiLlm1qla4MFDIpAxOK
IzP67BoFkuN9XFALHyYxhepXeE9cL9EQQwzjeha4SYwRZLl27UqXQdonngR4pPr53/cMcSsvJjSn
GyzxgzloqmyMfpiGcYj8BVQCRyCZHlt39cwvIVroKbAf6zSKOL2SeprgiGqWkb1xlibtAHwfvO9h
h8qp8PT+qyclBAgHJM4J1yLp/Ol09VPQNl22wVEWyxUtgY/oIsk7ngy4bGcqV9rArXVLfhl2qxla
px+b1U23IetMIKwjfOt0elg5BVoVGqJI6sYJ+sN8b/Ie11RLV2Z8fxL1PR5DMVV3/WppmjxAM155
J+akQK1wVi+DeqQP6mKRVYHwftnwxB+Pi1V1CjBH2sURRXirAGZiorBzSuUWXL4t071dbIUpY7gN
sgpgiPgXn4u84Od/BJ0ycj3F8nsba9+ofG2wuwT+j5ecCeWtxIzJ2/JDOuQrEUu5c7kB6eQxKUHP
V5yornvmxObtRyGDGR3VMok9ridsChWxJ3XDp0c2Vk8FJ6+RGqfaptJsY1lc2jr2IaxCmPGOXibV
kS7lE4z7z4mz5Z/E057InwR1xivt5bkTTrRFbEolJxDxi1qauX+OjZAd1CnpDui+zCTPLURdj7Eo
TT+jMsj1obRIwhVRRVo+BE/wwJW4XoRUHBRXNLLeN0RzW7aDExm04XVIFas1O0R/NJzV2v/nPPz2
02x892pAQvj2jZpGhCRnsrTDojOZVFhvJpnMZl7QuPBjJs5X50puEuGEPHWYdB9+2PnsRmd1Cbni
IN7zhoyoWmsLE24tZuaU3QdLC6iQQpd03sslgzJaXbE3vR9+HOsJczNJ7orh93dOgIqEtGT10cbq
KjyEXYGLxiiI3snLp1RcrXbWB6+jkKdygDAWXNscMSarzbrhTFRllF3MZ/5HeF1xSiJ/UTNmH0pR
M6AA4x/8XqmmashEpeUV2BUmNwpznEUMBbxBSq6Du89N+80xvOB7ZmTsrSweKt+de76M9hmrpBmv
oB2xI3knkzNMRmRohIAuy2IrU1iZ+hKsqYQ25Ngr2j5ovsN8Fv6kM+VyC7mQB/WvlDD3HTr0xiHR
H2rNf9hz6ID29Td7jux5TRi9+CR0rBsZJZCLIA5rDsaIiKPkAFg8ADZ/Y/PrT6UYJ2ZPJgXABYpk
pUBaYRxjjCv5SVFiAXFk7SPAyljKdTZ5ds5+CAoEnkf66Yo6Y9U58XVncbFz9ovOD6c405vIbnrn
ZvDBySFOViHEdYQT43b0hB8vIL7Npl7MhPfvGIY5WMpmRkeHcxEVg4pqpZjkiouE57/rfHdbnevi
/jVkJ0YH6nsFsJEbQIov81XBx97gp0iUQovivGKnbqiYyDC87VkbwgetoGR/2pXvcYlQHtLIRiQ/
KyqSysvwUBCT0SaFchGlqrRTn5jOjuR2c6C8ejKaUdwLS9rmmFOYatZSvosJrsK7qfFhHh8mnscG
kn0r4ZGUkttweyrKF30rAy3B7Z/CxDxiJcWjPIiw8KExK+pF+WZPA3ipXwrWwg/7lw3hK5Aqx+oO
JmN8/DAwEFNjlxjecIjfUVAvHctgX2SEp6ZStAbkaKlPKJaKD9PFZrnmJ7BSTy5tgbrKcm8OYjHt
xNogshA8Y7K2ikf/Tl6KJR3l4g2QdUxdjO8HKLFMfEKhZ5H4cV/YCEktRQdWworicZ4eP7YiksF6
b0V63Lei0yx6jRTLgWE9eiqlw+2ryQlqwEA2bnN1MU+5lj9zEbmp+DJG9iswIEB44J2bZ+9ihBBl
xJSHH0BMuoXmlfvzm0vHug9/2vzkNErSV+8Hy5/z+QfqAK8KnnAKdI4E90C1km9WaOSedkMYN9pf
gQ6Wr4FEsfXRQxQoxJBQkBGH/5d/MFqyK+gAtwWe5UTZhsaLcosaCgaOIKHji8T03p52wOosNs8e
U9hjLzoYMPXn+iowpODuQxhecPZKcOmqSD7K4Il5Bkpa55NAQav12XwDtjFqwHqXl77vnP8L5uKD
Ru/9tXP6BPcNTzgXn1gFGkrPjfcafnE0JZ27a3hjHvrukAJXi82Sm6LzzZYp8lClKMEjjKIdEbwZ
SaMtxM7vMKb2u+dFVUmQZUDir0UfRnKRG2AiCIHZa4q2hJRsqqTnZWNLKo1On89TjY0r5LGCL0eF
t4jKgalMgLhdXx5RF3uL1xE3EPooBW7jwd7HToS/RiYR34mPgSYsUj0tVmkbgNLfUR2wFp7gtR67
OD9vyD+H5lhuxW/W3bzjFzxP3J3+ODKkri6M5dCQgxEMD5PEhSkOegQPUHTZs0fXeWqX3Vn6I8YB
kaiv1+BYnbKhHeiS8tPQ8baDew4fNo2+WMcIABWEXStEWKv3BCv+FF02Noa6v6qM2XDluAyejjyL
77AE1e+iKxZCcMQyOywfBEPPh6C5ZNqZku419t0nMdLlz1CKB0QRLvxJKn2DlK8ldlvG1oW1zp0v
mC5vvXd788Ff1Vk4OVrpzgt9ETE9UkOoPttYXTWLtw+cxExFN9dANxR58SjoETPfSXsFRj+SFaqz
cI7DVPmgHt+FE81GEek0Tv20vBRX8Kry9XPdlQ/QTk+HaKPdX4wBl/dKDMA9YfFcKmOgQAtidCMx
8ngRiIT+FG5jjbiJIwqSAOyOXtGhitHxfUkcWialrzUzZcvELEZmplefEAQkSUwC82ni9x259tMM
EUekDbEYHaIOhmKWB5B71t5mCCM5dc6dL8Vik12wJJILCS8IYOXiheA0Zj3UkyCicWHl3tZxzC6E
K/jwAw5mxmvmKTMicGd0J1GbUVN4UVEHV7/Zkii+STnd6OBsmEBXDgxRkPOm9lzmp60NzJwXAdcs
XB0g2ZE3/YBcwGszqxMahONZSfryhDgvk5swZk4y2TIDSN2TWE/gvsjQhrtOc/qhQff+GT79jJIS
RZj3WgxDnUUk6dMUHpmKsp90zKlcVKRteHQxmuKlX1VxOD2sE09d0a9SBfP1aQszjGd6VN7nbeYk
k5JqB8XoUnPxPC80XnWpebWM117FdpR8zMcwVQpv1Ym8Ib2nl+2uTv+nepHMw9dVETw11CNBMDb2
aJRoYlOGn+2EAzRf/0zRIGLGVsbfgVZdnsLKvDQy2jZalLlnDLcRag58/RQ9FTKflgTmz5SXFN85
NU+V73z2qHN5buPBWa7lVbxys5xXkkfUkQcl5JEv2Le6ptEPT8reBF62HEEwoMth9nG5d7fBMxV+
H+J0GJHfD5s1F0JYRfcr9KsEqyoISlhHt7LGik+4utA9vQ3Rp/vlJEqEMV2Ywy4DlaazU7kYQZqO
AuEpGF44A8/Xtn3fK6MVto/pxgGRfCIORJIQ4qvWm763/6LxTZM6FRI3T0o+16Ou0dEsiscsuvxZ
U8mE4mvL+6G0yVBRpu/SpRi7bvVpbiTa5jLXdnQt1T1VYjwqCQE5Lx+7C+RNBQCSyM1Lu6Nkt7wt
sRU3bOnrFl66FV872LcaeiqygQb23lnH7gtrD7ViV4HDDu8/Kp5JagKdtaTL9+Yp2S4TdIjXgAyP
ywpNF+UEC3cNzZ5qBJdvcwhIcP1c94uv+VYtuh1zFQSnzsnrKoG0St7fufguhpyKLFHyjq7rxzfW
HgQ//Rhcfx8vDrq3HKy/+zjTAjFnvhwjJSIme6xXvTc1oDP9yVN+nLKJ9t/MP2Pjkmka+ZIpymov
RHgUI1c/ltfaS2XTqQGJ0u+2p5AbLshgY6lH+JB3jODFhdFLQ7CJ2bi+I+UtklfZq/73uXeCY/Og
rsCHrY8edu+t4IJevht8eFrlqJK3k1ziq2z41BnKw8fOYBQiqSS9ek7klipugiVmvLbk8hyLyGpO
4tKoT28j0lCsHMp26xcRVxYvdO58idjGyvnF98M7ER+PJeKOBvyTF9nLyppWrNlxgMvwzfIZStmu
LprP2dnYVfJ8wXwuK/O96XfH40U++NpgNw+mxlr6urv8aOv8cnflZue9eUqmt02LyVx8UE5R38xj
LhAK146RBfX66CQgsoGTi+Jen7z0eH+5AofcC9HFo0iT/oodDTIeYoKJydxeU4bWea1aS6jL18zu
yg0RlQF4TfdfysAI2BZ4QNNN0n18aIK8twYllGeKq7Etsq9yLdPUba7dwlOJVFuv+o/1K7NDBzDO
3kymS9WjGAj1rG2iyDFWd50pnQLEgG3bvAhh7jpKiUiWAD3UxOzBL7fo6czAs2teYYo4T9h81svZ
fdfGipTpabtRnZiIqADbta4xHZsyvG3zMt4BKCDkp+rtQIeVhLtI/ffqvtf2HdlnBAtXtz69rq4+
pRSA/EplAAwWz3V+XOCC2nJCr9ERxocF+oITGVbF1sqLEeb6DRG0ReWpDY7fQRJ39xgolaA7I3nl
CYDWsQcmoKUu5CexcQMdA1oUUWp7r0jioYoLkiwjIn+xZ0slQ9y8cqPzEWi1lzGcu1wUUeTRW1Bj
0opKvpPQM+2wX/MZbbvqaUx+587yhyOztb7BuFqiE3nxmbXvjd88MYdOjBKI/S4vX1C720L1lDyr
nNUHZxWzSolRw0hJzdiPOWrqzVpD2cneqpAVBlcBZQsZYoUBXWR5gbcb978I1t+ju8Af1+GO4eQz
/xdQSwMEFAAAAAgAAAAhXATHNFFxBwAAhBMAABEAAABzYm0vZW50cnlwb2ludC5weaVY3W8bxxF/
119x4MuRNcnEKVogNPTQhwQIWiBAE+SFJQ7LuyW18fHuursnm3UFxE6USIZsK/WHYklOrMRuHbeR
FDeNaYmy/pjyjtST/oXO3u59kEf6o+ELb2dmZ2ZnfjM7d4VC4Q/oL12t6fqOhWi3plFsuouYdt9g
3KWojd9AvkW4Zrma43KNdDyXcg05Xc2jLndN19Y6ruXbuFooFOYU+2PmOvEz85sgaWLGEkqXzbWo
29GqpktxrFKZK0fmFJ/6DiedROSPcjk3N2fhltZBxCmWanMa/Ey300GONQ+qq4i2F+tnG+fgn6WE
t2qNSJK0EuF5vYW5uVCh2MaIYaZLXeKXuldVXCOSjT2JFqm0WBV/JQyWzlHMferkbSk9lT/7ENwK
44j7r2NRbkjE5fJlNuEPQkorvmchjqdbY9huGVIgtqUUaIhpkmEoSrJfGpzgFiNn8l54ftMmZoV4
0x1wML/g0vOG54JUN/XBaRHawdYs2zkBFYy8/QhRkGUPEarXPEocXhQIrVp+x2PFiF2V7OgI9Tcb
pTJ2mE+xgZhJyPy7yGa4NBZnpZ7NX9IVSitNZJ734ZAKyTF6DUkv68xBHltweeU8caxULCYbglxO
jil/ugdacAX53O0gTsx0W8QwEkZGPfOQiafoj+g5A7H3bTPvedvMicvDVBhGdioviYYglmMJ6CGk
1c3JSPIstRBVz8Yc57bFjLLuYcciTrtygZKsnCIbETkfRbXJhMqi+U0RuZyEwnS9bsUmTZaPiGAZ
wKKIEsxydiTUkCcU6zWJLLlamsClRpwEQ7UE0nJdVw+NmZCOPSVWDOhJR4mF4YF3lYrZPcKiqAWY
8WFNu5kKhYKAOpyP9UZihhJLyiSRBpV6pSKqShcnE/x8pUmVU0srUYRtUCVuGilc1/FFwjjTG0qd
Hj7ZCbdXw+3H4Y31wcGD0bXV4aPj/35yRZ/QEe+HHkN9j6cK5I7h4c3w68/Cjfvhv2+P9g6DG3dO
+2vBjb3B4cPg6G/hzndhb3m4/vlpf2vQuzbob4a3ngVXHw0Pjge9q6OrV4ZXnk3aZLg2BgdprlWY
cPW0v3kp9s1xLQEpSJneWNIGvcdS82l/RcqCP6NPj4K15WD9n1nTw83Phv07o+dfBqt74fa/Tvur
hdKY7ZZLNUckImspDWKroGmXHKCiDhaW/xqt4gs9Q4G9aqUH63vDW490kWngYAc1bWzpjejgmh5c
3hbcpYwfLwZcC+oO08idXwK6qUihiIBPHyHbx+9Q6tIZoMlkT4YlVsQW0Fu/+a3eeFnRWISZiOZK
UHqtmK9Yf55P25luJlVExJfd8XI/ouYCWcQVz0bOy+KpZA3iLEKPcDORPZfcGWgRS+rZRlkqmQxW
qxDsfx7u9wbPloOV+yd3H2iX0pKLEX14FDx9IuspRv9asPxjKtrscoHLJS34YQOwDeU23NoNjm5n
q8QiMJMKP0Eugy+B8RaxcRbmYp3pFdCRzwhSjPRXBaeKEIvTMi2/scxYlmanyUN8Yca8Z7sm3OCu
w+LZJ0nMZB7TjEXm6rW3X9yC62/XGv9vG55sZyLc1L2QjbY8U6M2cQsm5eReqOs2amLoKGd0yKh+
JiKJbUCB9NSD/U0oyuGtb8KV9YaeFLSQiqtZNRi9VMqZESfmcE7MoxPDtjTxwe7XJ3eXB0fXhke7
qWkl3ShN6dT6oPdTuPFzgj/Yos7JscgLtCAjhiIRKJuqZHS8PtpZCzceBscbY0oYpovExIbttuOJ
VXQYtW34/cHJxk/xnZPZJkYTB6bKV8CuHD7iuWsSO3IYkdxfdH+/ECWuz8EhPK8Pr+8HP3w12t2H
YJ58sjk6/gJKP9z4x3B1RZ5y9PzZ8PaaaMn3e5CsKPnxoW3cRmbXgIOKIcZ1DN+JHCeZG0cq1ade
ucHuzmh35+Tmc9FGlEviFguObgar18Ld/6QNCAzIbC5p4b0d6a+47xJXEOPGAmIL481HxSxNbrsD
mgRcRZko6gIRLaNrcBjKoMSF87NqBXyGRrl/GWIG7mW7X6o6mhAmG6iYueEdaPwYItRffjX6++VB
7zpEIbz+MLj3hQxY4UzOA/krFqD5qgRtP5aByGYKdA77B8GDH4P95+BicP2bYOu+nJ9kBguvl8EZ
bmiRG1tQid/DlCMMPX0Srq1Kf4AyOL43vH1XgSdyb8zulJBPaSAz39HjsdppuZkKEst59fEhKZ2q
oBZfs4LEnsn6UR2AifeTpnsRriwhVdchXgwiJ3onABKG1eDwQEyDV7eiBqGXNb36sUucohTnqC16
0tRDyssGO23iJC/54vOJeMOPp76x92z1QjLJg+PKby8QqPjTC6fdmvwUEy3xRRN7XCum01f597gr
Hz7seor0Ow5wbfpcLd9zLHxRPr7/gfx/5/135UP6/aj6QfIYsUrCfSye0lSpYJ7cujva24vixDgt
RkKlshgFoi9CjFtAgnEHnuGe4cWzY86Dw00XZrf3HI6jl4ec/j85olxv3Al/XhG1Fs+V6Vz+9Mmg
923Q/1S8JLzI7q/fLM39D1BLAwQUAAAACAAAACFcyxu6jfEVAAAiOAAAFgAAAHNibS9vZmZpY2lh
bF9zY2hlbWEucHmlW21z1FaW/u5foZDU3lZZbmxCSLZZUcUkZDZTCckCmQ+r7e2Su9W2YrXUK6kd
e7yuAhKDndiYbAgkYCaQgQkJwYbZZDDm7ceM1d3+lL+w59xzr/pK3TapWleBpav7cu55fc651/v2
7fu94zuhHTtazY7tkcD3ZrWmHdoNJ3ZCrR6EjUirh0FDiycdLXI8pxo7NS2o192qa3ta2PJjt+Gw
SDtZnXQadnFo6HighU4jgBmrQc0xtI+dcS2qhnbT9ScM7Q8n3z+uuX6zFWtBqE20nCiC+ZphEAfV
wNPcRtNzGo4f27Eb+EXt1KQzRDNrNQdmccedSIvisFWNWyFM7gex9rEbImkNG0ipRod7xMG46lSE
1Niur8F32GIQzhaH9u3bNwQrBWEMNDZn5fOkHU167rh8/SgKfPkcOkOcC0WxYU20n6BX8bEahE4x
gjXsibSHGFBxa7ArN54dGnrv6PGjvz/2VuXksRN/PHbCnGOxPcEM5rlR7PjpQwVHs/m095vvvnPs
+Km0d+SE006YPsje7xx/+8RR6DTu+rWK64MM63bVgW5h0IpBAJWGHU7hq9OKnIpdq+EUvhP7Efyu
uZE97jmVuNqsTDlOs2J77jQMHtLoh+U/5BpowWnbE1/qdhRXgibfFL43Wl7sVpp2PKnM2apBR2AY
Ch364SvyC8hFipw4aCGJ1cD3QfWUTy5QfbDC94nbAD1SJsWPh3Ifmfpa8QNimcFQ93BqoovVAtSW
CnQKPM7hdFKY8+MgnKqA+oG9TMwS53hTPNtEdtRtzxu3q1OV3dprjmfPKlNGTlyJZkHcjQqQMTML
Enz36O+OvXsSRAgCCiNWYp1Ld9qLD7vrt7obZ5BB0OyDeaZfkosrSAk1ta/cTp5fgabO9/dxb3YU
ASE1+EITJBvnOjfO9CjQWDOagq87332aLDzY3roLHXb+57ZYZ8qZ7S2Tfmi5ON+HH77zFrwBiyKw
VGhIVla76+udpcX22k/qAuBJJgMckXx2AyZpX36UPFlFpnjBx0jxL2faF77v8RKatp/c6D77svP0
i87jNVQdD9lw6t2T6qwgAz/iEpT9u+vPOk/XoX8wXscB7YcP2w/PifdKA3xR2ti+c5NoEK3d5xe7
N5dla28RYVuSt2sryWc3k2/uKOwFlYHhDzeSZ5/C+2QQcXo2H7fXtkgucTDlIHe2H9/qLC2DfIeG
ak5d8+xxxysAf/VS6IAr8zWSuwVNRWCMExb08jDTCmwYWoaZzjS3rikfwYeKIZrjRQ5+ElNHThWm
pLn5VsQCtj9bmMFh6izg4DXeWOjpisF1oqcBaCLuNKh8hd5oS+h5cCGm62JhYGYLvMcUmFkB/xPL
R15rwmR2Kw5GYDPQzlthN57jF/CjfuTAa6W+XlZp7FXgALwJt1yMJu0Drx3iUxcdH4NLQdeLk85M
zZ1worigW6VDZXXHrNoCZ9yAKXB2oLLqwR5FpCLikO4K+C03rlQKEN7qBoZBvYSPRXw08b+htK9w
C9TVx/hWc5rxpDkqNiu2xhuPHBjFGIchyo1cP4ptv+oUaJBbjUHytguS+6PttZxjYRiEBSZCXfLk
KzC67vPz7YcP2ouXO4+/bP/50+3NlfaljfbyGaarS7FXQqfOaBVfw9mlRuFz2hM6mdhgUf+yOkWO
QvhugI/TJfEQ0+otz2vYcXWyELKX9//HK8CKaL91dOTf7ZE/jY78c2UEJGXAOIULfNG+DSarPyYL
Z7rrm8nTL5OllWT9a/AHmtz2uYWdT+7Q5pVNovmZMHkxanpuXGD7mW6NjGV3AF0kC1LRFSfADBin
lRlz8y/kd+fJVnLrgbIwCBsilonC4gIvqtLnS1hi+rKFFJRJGYbH9PwcxVYTujuFuanSNLe5KWNa
iqvogvuP0KLBwF8yST7z6gxcmjRRTxOn7dAFxBPtqYrYbGZIxxZ9kKruwZ3Fc6B4pI053Qt8531Q
Pql4WeET3RZtGDcp+1liXJl/mU6Flm4JO6e8LOc5YeEc5R4nJHgUrIgAaSksgK9NM6cT2OaEseuQ
YvBGHIYvvf2hWEzsSoP4e3b/XOOweXfmtdd+bK9e3H52LVm43bn7jbZfS85vwUN7cyFZ+apf2ebm
05Y6t7+aM5g/Uc7W0C1yC999i4zgSPoKoArilZ6ZBnaluAKclHwBgOe8I7DA+MtW6gHmRo2Do/PM
UFx/Vh24IQDiAZnZ8EiTW2W9aDcBI9ZyqrmL2ldBiF4wwUWt+lw/IiH3lAFA4HjQ8msgs8MAGfu/
Q2PaIQw+jkyrnOE9pw+JirgEAGs4tQIsJA02t0mC7U5oAtgrzO0C5/8FqIgL/kAZUTT2pZVEWcE0
bUhzaiYShT1wR1wotNrgdOA3roZzWThxWc9ZsA0pkMk49pDb44sSMYQ8Cgwj09cbnc9/6tz9vHN3
I1n9S+faF8nFn7qfne2cfcSkpaQz8GEM3e39L5KNR8nWpc7VT7vP1zp3Pk/WvwOsiZNwK8kpJ0pJ
assck6JkJS4pZk/brocJDCsNIBZzHtwOK9Fvo09D0x/JRGlvMB9AFZIJpCKeC6lK7iOykLNZKrW+
1/y1oNpKk1wAh5Nx3IxK+/eD4U2MjAczxQgSyBAAcTEIJ/aDmdbdiVbIe+8XWr2fUNIwRMMBsQL4
JEAZ5HTVADZTgOzHDlNISEmpKdJX+fHwuANKAcE2l7MWRENR9uPISDZG3NMViAq7DingCyeQEJDW
e8nkowY40e7G42T1ssQH7St/J6SOirK1mqx+0bn0bbL6dbJ8+dcny92NhzvnV9qX77eX7rZXV4Xq
EHEmzVDg4I58CceMZg5bYspfrLUazYh3NdDoEfVG5qmw5RiRg6URyO8jswC2ZoDoAIEOxKIqDiUa
jDkm2ZImTZItosFgecaxErEIDJtPUiFCWYnWkelEhbtyHhu4F80AfwQdlnD25T70MTBaKJBEDMT+
09ycEKPwQDKfJhwe5c9uWBBb5VZQjWcEIdw7U31ooH8m5yO8dF8/xU9TRz7ny9p7GIe4goduA/QK
5aJFLWizAeT7judpgq/aIaFpWBtyQrAyzUYb8NFbcP9QHJI+FsJAwTbGyT3auG2gnr+Mp35XODTM
qFLTm8KvihzGKWZmWqyp8ktmBgAqn+2U7QLyiFU4UQNsI4udtzfvtf92s722lKxudK793L5we2dh
BZwreFY1Mf/1ybWdtdPbm18C3t05fRb6gOUARgFDai9ehAy4ff05S80TPRtfXjfNMZlW8AZrlGhE
2AscY4bGih8Frl+YGmYm5FtxWJjWX7xRTDEYEAGJO6FMjca6gPsINhokDJjB8cFnYuVFkJRJ9Ygo
0LhidTIIIqfAdk4vtT//gXJ2iCcIvNLYsvAgubhMyVSOP8zgO4LJZbb4dhA2ftdyvRo4qF1SRqH0
sLph16YRONW4v1AAAscewhfRr8O8CcaY8I9e0sHygZrrruPVEJ3Qq+fY08DzuXl6BYeAuMBSADEf
oOQFWKbIw2Jwaia2YyZ1uGr7ge9Wbc9UagOHwcgVQClKWSAdMB9ATKImYGaKAyindLJ0rZe1E1hu
1HhxuQUMHodwFrTAjriXg67QjnyvadWgAVS5ZJaiCh0Zmu+AJWtiJaQ9KqazczjqCHhHzOEUp3Rg
OEZtRg6YpojfjFsnty8xK0clCgSU81p1ronAS41XkXkrN07TpExEjhAWI7roR8ayADGdUDxYUgNy
OpvqKRgDKwq7Qlnpw0xL8VKq2VSeY4ZVtxgvKwknX1fILevlXckE0+a8kFSNlkngzgwVSHOa3NNm
rngSjhWylBq92SyGmlHW89iSSjSvzLHhvr7DbJ7lyVVMQT9iHjo4CC3cvAM5VbJ6tv3V/e7fFyBj
1Q4d1HZuPiJ00HnyQ3IfUMMGsDm5d6W9/kt3+ZPk2s8KyKyjWbAmOaH8quCThlmFDWONvzVeYNZ/
itynDHZRgcSnZzu6VTpwQMkmzDm+sRLObwgplQqs552YoqACywuYrGiD3lMHqh/OKAU8YjuA3P9q
IdxlJZTbvMpFhh50l2S9LisUaOYm9TSCJiLOSNSNeJuSITgezIk+wmRY9wfAyvacU3YyIFa7jVZD
8S2ihRkjB8YOvn7wjVcPHXwDVWgm349amJF2e10fSBCQOv4iekSfPckZc8Ze25MQ3mEgCeNBAM4I
MB6YJfed5V7boP7Csard04osV45eWVfmXbwSj996/tsUjaQ70lkr60XOAMNp37tFBtG+cqP9v18R
GEjWl5KFO2RTvz65mvdFmUKI8KFIvHAbZfNtGxbLJNQQyVH7LM7hdx1/gh+4wHPFoxfd4KztfbJn
0k/lrDBhUTtV5bo1XiYttctK1PlA8A9PDO1ZDRDuCK+n8LQZwCBFlQgiRg0hI0DOuguBR9QnlBAD
i6VikWXGObVgzpk+30chE1MxhdK0TVDce8+M7tcMTrawYbXam5mSF+2zOkHEpsdG4qhoXqgIFe1H
YkgmWBatkNeT/r2ekXfWU5XU0KsUeDIROA0UBEr0vqSVh4I6P+0A75+CmXHEXoPAzF6V97EDu4eH
X5aT21dEeBg7oCUPzmbCw+DA0Cukivxk13oqJgVTUjiEgOl8BVDO+3U8uMT/4kleG0IZoEQCOuxE
BgE2IUgP6c4Ly+mp4QKo7/71DOH67sa97UdLEt3vYbiyhKE4NirMGr0G2A40ZK1djstSJ6OFNYhN
aqSSw7MKLzIJDLwzannSmMngT8A/3Qc3KVkAsvThAhM5g5JhzOgc8GVahL4zhRBBcZYOtzZj7gLM
BuExzB844KBDGpk/kMdWMD0tPzoIA/F+pOaCIguIKOc1HeBHJpr38vL8oU+a7Kf9B0L5YPwjyNu5
s1ALAKnucoqPg0Zk1iWfZIehPZuLr1VI0mMTfHZhzMgE03d45dwY0/tKzXzIkTcGhSTk6Kft6zc7
19ZTOKeGpO3Nz3a+udhfvc5wvUQ0pfK0o6mCyDd3EWa6IjM8SFRqthaV0uEEGQqRsecmEVEU3jAy
aEF8fQM01uA0DUTDlqIKveF08IB1Ga4Sw5bMkMtZ7aCEGcUX2v6EU6B1yv3CE4LPSg81INr9ACHP
ZsqcYMigysST0+1Lz8AxJQub7atnAVQk17aS9avkqrDgwGGGkOb5H5PP7hDk2NNbEZ8I3VJdO6U1
Bb288pobwYNUzSxkr93shrez1230XhEmnqQOuLKe03vhZcxdK22cU7tV1eYzs/FqozXVixx8LD8c
lGFf7onKcbI1JYM3c+5heYWX6zwIJlk3F7UmsICIlQNlLVycluLLEFf5LHIVfsGIVugrcE+plxPk
BRZDhR79dwwQOBnyjkjvzsE8LNo3/4AEPrOkAkNyu+3zC31zA4L144KSkv2GjAwTMnAjudSX17So
pkSRAbuBZlMMgSid3LybnPsGA4ewh2udH7a6N5d3zp/HXP7Cne4KWMLyqLa9uYKpKk9YIYv9x+mz
OXeHP1Qlm8pWyFCO4IpKtKs607Q5d17X5sS1E30eqdas5PkCEFNm/SKXwZJ3I5KUbqnypP2ydPFT
WTuEyJk/pZTCAKaOMhmzXqiB5f45/JpbdSTYUHzzTBHhcrOgG2MGJvA4n66PjPWifiTvERh5m8Cf
LEkDGcsN2KXKMKdCk8QPplfemsyFIZI+P8d4+OuTRV6QvQLPgG12rl769ckSMzgP8ZyB1Av9Pq99
wbrODIhROv2sUEgDR5kurgyRQxiARtIRWRzXis38PYXUt2QuK+T9UdaR9QgT+y/BzNZU2VSCHPdt
0CYC21R5F7yjSAYmyWcOvXSlkKt3ihMKyJxReHT4xOu0/LScY5uSckxkBKE74fpm/tCMjocFpJUn
0EQdXfxMTyvkrc+jbx394NSxEyd5H9xrjGcgc3ZRHHrwm4EoJ7vIT3TTwwY5sDiNAVVw2i5GQSus
oivic424PiNmQ4pVc7GoAabAr+tqIZcI0IsDQ0s5FS3TIb7VOzhNk1lJIRUClXtcmd667C6JJD0n
J8OSh3+j4zo6mGjf2EyefwLukXhq9R1+lQV65p6SrkOAK0zW7ifXT//j9Bk6SIaH9o3znXvPOpce
dNZvdi6eS76503n87fbmaXKjPacoIjWSnckIsbHHpkFwhV9FInrTM5T25fvJd38G+uhYm6hE+lY3
kgU01u7qGlCsjY1qycr5ztb36q6TixcGHEXiD9e7HjUDTixoHrneYnLhWyBo+9H1zvcr1Lj9eCVZ
u0Nn60QE9xVWVrCpKvQWK+tltYvKNExaM+NNumggFEbVoYyODbpTpbIzvbOWLF5LHm9BuqqyU9wP
EAe1PMYaFNzNvc4UeXeANIRryMPg2IG4laomsiPNvjvARYjsRSWcXJUM0I2XQ69fwXsKG2e2H/1V
3mK12PbT53h3TOpmsvAAXrWjb753TONXVvF2RHIRq/T4DhLdfrwAuTm8b29doLtw7a8vtC+fT20B
xVnWTZOSRd8BYGlZeIGalWG9Vo1+47tBb+WMGrWXl0iHuhs/w8ziHOzeLWFo6bEBv6LR28epNz+A
+T586wNtv/ZvH77zJrxAkzasQROQkzV10lEqtPNVAN/8/y4xiNsD8gRM3ZBYh2d9SCnBEWrFwMlP
O8kb0CXnzr2lZHMTOCz7gHkwyDPSuj+MSrkkD1AFn679nNy6KsdhorKzdpr/0YKUyljq0mtOaCqn
g4UBx4BCtWNT9C/KahbXdauc3uPXD1fznUhXeSeBeDN+TnamMt0uRV0SOfdplGGJW+Bif9fUspF6
HAypWfcvC6TzbGCgK9acqoeXIdzp3p86OHUndGDfEcUmQEJ4vmeDNc3VxdFO72gqu4FsjXVwfZXb
cn3A6dS8yphCjwxATPo/Ka9VeFWoUrDpAPat/dheepYs3t/evEVnxmjmYP8ZDi6DdXc/eaomscnC
T5AAk28DFuO1FEL+NJDq7IuXyW+orJeMBgZxBAP8UvlE520C0jNakc74wfjUM0OOpZhGFKf2ThRr
/D65uAKDl3jmGP6Njx2z0pjB0BhZqe8ed3piRcaKUYkcDKdBnhAs0X16HNr7o4Cx4mhxlKl3oeTp
SkX+6VBpV4BgyMI2XWcrjb1+8OCr6R8KRKyEvlH8fQD8l1lFXOGK7Qn4iDZEasZKWbVLL8wBrG16
ECVZKYrTO169xio0tkJXaWFYQeOUyx3MZ+0EzxIqDdtHLygthF+s9Dx5KQaf6aJRD5pmbg7RHWMu
lrLEskED/5KpYIcTkXrFBlAitFijZcyQOd5N8ysBf/n3sTI5KHw+UJaHq/iqHzmQL/llJsU7dUrN
aBfELBYByOzgjkG/skwyUpABssgj6uxx5cgIXsficRtnFZqvXNGiJQzHj1qhU7GjquvSqVPmRC5y
8oUubkDt67fbW1hxUm+i/xbQCkYvQsbJfz06cuC1Q0r37CWt3HXKHnLidFsKJ8picxkMBjb837y8
gFd6yLWokXAAvufigzZx07Hcd8gyNNjXqZgz+eLp9uNbWKH7ahE80v8BUEsDBBQAAAAIAAAAIVw3
b4x/CwsAAAsXAAAWAAAAc2JtL3Byb2ZpbGVfbWFuYWdlci5weZ1Y+VMb1x3/nb/ilZZ5q2FZg+M6
rRgldY2mdRsbD8adSRSNZlk9wYY9NLsr28T1DD64HGRofGPcQIxt6kPCmUzMIcwfE+2u+Mn/Qr/v
WB0gN231g3b3Hd/z8z3e6+zsPGV5xFE1T79AUFb11B7bMiZQ3rE9W7MNpDlE9XTb6ke65XqqYZAs
+su5wTPIIheIgzTb8lSYQeQS0QqeOmIQGMsSpbOzs0M387bjwXd+InoHDsTTTRJ9f+XaVvRuu9Fb
XvXGDH0k+nRIR86xTaREUrlIzJwYOHF2ODl0Tj49OHD+s2Rm4NRQ8uTw4NDn0UByaGhw6NzB7UqW
aIbqqExpQWqgMXQiq+bBKB0dHVmSYyJmdCtf8CRDHSGGDINqwfBkzbsUi3cg+OUd3RKz3fh9ZSn8
4UHtxx+Znd5XZv2Fsr+2VFudf1+Z90vzweyiv3irNvPCv7leK0/7sy/fVx7V3t32p56i5JkBFO7c
Dh5/B2Phv7ZhU3V3L7yzvr/zoFZae1+ZwzHGMWc7SPU8YuY9cAxyVGuUSCCQMjx0KnlOiEV/hm4R
N5FK1wcujungo2GnQBqLooUJriamgn+CBKvop+eQZXucIFKtbP1LcT1Hz0uxuEO8gmMxf4OFSZ6+
SMJah2g170wkMGiO4yMAtvFDUrmKms8TKyvRj0N03IIpmWpeMogls9Wx2CdHjx/tO3Ys7qi6S9Df
VKNAko5jOxIO1leDx3u1n6ZqezPo6G+Po7/qfzygpudMRIpQzyuGrWZdCX9pYeUrW7ckwaNlD7mk
EXBEg1M8r7pux/9Lsg05BjDmFxSsVPzKQnB/Jbg7C4iqld/uzxSDexscdD9PXhMKHdYeUBi8WuVQ
q+8Pll9U9x77rx+AbfzH92Ezhz0LfIapFpBj4OR//08K39JSdWvOLy7USiXAPMepX3oQ3NvanyqG
u6Vwbbv67hv/23n0m8v+wrXg7oa/WLyC/OJKdbcYvnpGmd9f2V+erO6VgjtbtRtLwfKrhvyC3/7k
EqW7vOE/nvx58mr4suwvPAGiwcpM+PpdeOdNWFoNF6f9h+v+6kt/+iEEDhWRieXvTe2v7vjv7vuz
G8Hc5P7kHHJ1a7RnxL4EZtz0964Hd8rB/NUGU9cojCZoHKnuOIMLmAQ4QZxCINe+eRPcm/E3Fhib
earcs2uQCC+yxEKDUzZUcySrIjfuUmw6RMkVDMNUPW1McnBK7fm6t+f3afHM9KQv98pHj13BshtD
xABvUc45VTeANWPKvYQFNliCaUjHdaxuvqZCLRbD5xuY5iTFgvybsVRTxIqpW7pZMBv7auWnPA4C
MP3urYZJwrlZ8MAvKPFltvtLJfqTPo33pE70fMEVUnrS3bFP22nDKTcjF8dk3Kf0HVN6I3dDEm7I
yPNd+Ogf/uIr7nKhW8EcIY788bFjH/FtFvEgvaWwp+VxWk7hQpY/6bfMv9IpulMbs22XgCiMZrWy
AnGAYeHwybOw8PwA/Yd31I3oezrGM6ZnuInm3cGDsr/4TGB96g38oxMnTydRrXy1uvWM0oNpCux5
ERnc0hyawAH2w+wByPLNgOn9FxDOV3msgAiJRB9P9joxsm6iqRBhvqa2uu4X79KyAjhMXe4cJxOd
8U6aey7aTrZT7mSIgSG/PB2uXIUBbyJPmpdcSYPMaVbKOP6JA2W9hVWwXPRvrlInTD0NXz7kCtGy
tjcF4iNKEWKuullkX+roEUN3PWKJR4b6lYXG5SsNNpqhE8tr1aj0fTD7lrKZ2f6v2HBRxaM9m4Kj
M+9BfEKhBB7lCq2y54dOoQb9hXJ49yHUWhrRIocJSUQBB6I4yqk8i1/GUH8hIHC8T8bjupXFcawV
XM82e3A3TSEyZpbHcd4xYNPOFgySAUFd6KVgdZ/SC8iHCR6cGadg0bYIx8WA3FJfsCiiTEscp/8y
BuSDC8ddHKcxIGOAKo7Dn4yFScBIMALebaXF0YTj/NlYDb2EARkfx/mAjLmTmib4AESVozeNwtcV
UTNEiyjRPlIe0S3VmWjqklTeViUOd1psQ6zfsW0vIXo/5Sw8pYNtHfeCpzqjxEvQ5UckQVWhbuiG
ggqQEs6iuQuWKLqbcSdMKLLjUgxB38S3K+QSANRtGWpe2b57gHLgv/0BqqW/vB7M3qu9LfvvbviV
a/7mJkdntbJUezYdProHyzicwqUbHGxCrF+jEyhXAByRHs12CIosiTTVQiMEgQlHSbYf2igTbKHT
jjpa4iITUIZo9CI7l9M1XYUOfYxo4y50YxcVRj/qiVPNlkknxFdH1JDUQcErA1SxDKCUGFKs30xh
VQMwphOXcdY2ob8HxHIIg9VUkIUoIB3Al8CkUZ/8Q+skRN0FPUscmDcAocTSnIm8BxPaGD1HQMcK
M2OeRxM1ZK4MDXEYyUNfhq80xEthWtBckKaukcvY0N5EoCzW6G8js+mG7k0w1c4ODQ4Pnhz8LJM8
86dTZ5JKywrJbAKqckE19Cw77zS6MYBRy44UbngGp1ubaIfUy9hBriIFgBMBdA2WcrOX2jbcnGYK
U6+TLHBs09jt3vbnirz34n0NIDG49dRfuB+8XqsncHQE1XNblP9o/+eX5mpPpji66Vmk/JYSKW9x
gryNO9AlA0i9gpvAgHJo0KCb5iJw5rz9C55MBt89xY2uFlqCeNM+3nVWN7f9d1N+cSbcfi52syLI
o4YLRJP+VMUvbQX3f4L32vXd/evr4e4PtZvXwmtbDQ4s2s3xrO5IedWBVOUm6DlHZpGescfZV6zf
dqGcgzskul7utT/u7Y31U5e56gUi8VQgs4xUpyx60QNdbz0fcFWgCcbdrekI/R1BQWA6HyIW3tqA
JALlp7rzFNJEbWEZajn6CAVvd/ybK9CkcSZcSeoWvuDo7xAtWTvPw53XvI/gYjR6WHF8SLIHQLkB
0Sg1KHk735I45TN289GKIUzkdIeYNpiFrYLTfk6m6pCmtF6HaUubKMrhh1tehvd2WF54AQ4On+/s
P1yr2zuCwrw/PQXQEp3v3mOo3E0H4hw92cJpONVSQ6jQsSPYVC3Iqw4vEHLLCqYRLMk6as7jC5ri
WuhHiddrRpzee+hWgdRXUbywuKeHO4kuhjyaoKMKwEnCLLfiA7AC0qo1IVl8CWskoOmjT6aPRZUx
+STPgdCrxdoZLdzeq27e5FCBsgQxHSwsVrfXasW5cH2vulP0K3cBYzQZRJaEKPenZv21G4AgvhHS
A18fdeRgm18ox0ektmWXbjpUdqkRowlqn/9QYuFAU92hod620Db4tPR2G9MH4OLvfhusPuFIogrz
K5aB5GfJ4SQKV0twwMCxXyUwH8HtsAilfuFe8NMsJ8hJCfaqo41BB5NoiyQxme2pXznhfjH2vyQo
sUXkKMYWUOAlxHhkfWg6o3s1pf4C/YBU/6B/X0OIKwVPi9FblxwdkXDX511mV3a4689dp7vOdeW+
wLFWX4IkUH4MVSMS1VOm3Jvko58g3PF6Ap2wtAxoRzTPdibYFoUr2nZeqNFy3G/0WC3ee8SuKeg1
AYc6LzE854n7CtuEEKc2G3WbspOdJw4r6Ak6kepNR9hpTCQwv+vA0SVN1MY2XYHIbHdf00npAAl+
i4gbaeNw9AgSLeHfNlLYIIWSRH2VcfWvyS9dafGI4VEC4eKvPafXFM3hwtuTVv2idEUZChWPflhF
SGCkyUqiMESGiXaz50cfpkKo2G6ToWimY9UFrA3Iozmv5fJW0aH9pTmXI4RDPg51la8/qN2H7r6a
KrYom7eL1d3l6Dai499QSwMEFAAAAAgAAAAhXL+XiZDeAwAAgwgAABkAAABzYm0vcHJvdG9jb2xz
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
AAAAgAHhCQAAc2JtL2NvcmUvYXVkaXQucHlQSwECFAMUAAAACAAAACFcMQr6Z4oFAAA+CgAAFQAA
AAAAAAAAAAAAgAFmHAAAc2JtL2NvcmUvbG9jYXRpb25zLnB5UEsBAhQDFAAAAAgAAAAhXM1LF7IV
DAAAwxwAABoAAAAAAAAAAAAAAIABIyIAAHNibS9jb3JlL25ldHdvcmtfcG9saWN5LnB5UEsBAhQD
FAAAAAgAAAAhXEUvIUxyCgAAFxkAABkAAAAAAAAAAAAAAIABcC4AAHNibS9jb3JlL3JlbGVhc2Vf
ZmV0Y2gucHlQSwECFAMUAAAACAAAACFcnDBET9sQAABYKgAAGQAAAAAAAAAAAAAAgAEZOQAAc2Jt
L2NvcmUvcmVsZWFzZV90cnVzdC5weVBLAQIUAxQAAAAIAAAAIVzPaAaBxhIAAOk2AAAXAAAAAAAA
AAAAAACAAStKAABzYm0vY29yZS9zZWxmX3VwZGF0ZS5weVBLAQIUAxQAAAAIAAAAIVxVzkqqpw8A
AFkvAAATAAAAAAAAAAAAAACAASZdAABzYm0vY29yZS9zdG9yYWdlLnB5UEsBAhQDFAAAAAgAAAAh
XO5OspcTQAAAKqsAAA0AAAAAAAAAAAAAAIAB/mwAAHNibS9lbmdpbmUucHlQSwECFAMUAAAACAAA
ACFcBMc0UXEHAACEEwAAEQAAAAAAAAAAAAAAgAE8rQAAc2JtL2VudHJ5cG9pbnQucHlQSwECFAMU
AAAACAAAACFcyxu6jfEVAAAiOAAAFgAAAAAAAAAAAAAAgAHctAAAc2JtL29mZmljaWFsX3NjaGVt
YS5weVBLAQIUAxQAAAAIAAAAIVw3b4x/CwsAAAsXAAAWAAAAAAAAAAAAAACAAQHLAABzYm0vcHJv
ZmlsZV9tYW5hZ2VyLnB5UEsBAhQDFAAAAAgAAAAhXL+XiZDeAwAAgwgAABkAAAAAAAAAAAAAAIAB
QNYAAHNibS9wcm90b2NvbHMvX19pbml0X18ucHlQSwECFAMUAAAACAAAACFc7mvmo4UAAACpAAAA
FwAAAAAAAAAAAAAAgAFV2gAAc2JtL3Byb3RvY29scy9hbnl0bHMucHlQSwECFAMUAAAACAAAACFc
x9lD9csFAAClDgAAFQAAAAAAAAAAAAAAgAEP2wAAc2JtL3Byb3RvY29scy9iYXNlLnB5UEsBAhQD
FAAAAAgAAAAhXAqplqxdEAAA3DEAABwAAAAAAAAAAAAAAIABDeEAAHNibS9wcm90b2NvbHMvZGVj
bGFyYXRpdmUucHlQSwECFAMUAAAACAAAACFcpvfkzswCAADqBgAAGgAAAAAAAAAAAAAAgAGk8QAA
c2JtL3Byb3RvY29scy9oeXN0ZXJpYTIucHlQSwECFAMUAAAACAAAACFc3pSnakUCAAAlBAAAFgAA
AAAAAAAAAAAAgAGo9AAAc2JtL3Byb3RvY29scy9uYWl2ZS5weVBLAQIUAxQAAAAIAAAAIVycVa69
kQUAABAPAAAYAAAAAAAAAAAAAACAASH3AABzYm0vcHJvdG9jb2xzL3JlYWxpdHkucHlQSwECFAMU
AAAACAAAACFcIlxX7w4DAABDBwAAHAAAAAAAAAAAAAAAgAHo/AAAc2JtL3Byb3RvY29scy9zaGFk
b3dzb2Nrcy5weVBLAQIUAxQAAAAIAAAAIVyCGtJgggAAAKkAAAAXAAAAAAAAAAAAAACAATAAAQBz
Ym0vcHJvdG9jb2xzL3Ryb2phbi5weVBLAQIUAxQAAAAIAAAAIVz0CGAmcAIAAJ8FAAAVAAAAAAAA
AAAAAACAAecAAQBzYm0vcHJvdG9jb2xzL3R1aWMucHlQSwECFAMUAAAACAAAACFcSTKxpOUAAABc
AQAAFgAAAAAAAAAAAAAAgAGKAwEAc2JtL3Byb3RvY29scy92bGVzcy5weVBLAQIUAxQAAAAIAAAA
IVycAEJvXgIAAG8FAAAWAAAAAAAAAAAAAACAAaMEAQBzYm0vcHJvdG9jb2xzL3ZtZXNzLnB5UEsB
AhQDFAAAAAgAAAAhXEYFCqYeBQAAVAoAAA4AAAAAAAAAAAAAAIABNQcBAHNibS9ydW50aW1lLnB5
UEsFBgAAAAAdAB0AmQcAAH8MAQAAAA==
SBM_BUNDLE
}
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
