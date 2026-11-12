#!/usr/bin/env bash
# singbox-manager v3.6.3 - transactional core and independent protocol adapters
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
SBM_VERSION=3.6.3
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
    local mode=${1:-menu} choice kind='' operation='' address='' port='' domain='' default_ip='' default_port='' changed
    require_managed
    if [[ $mode == menu ]]; then
        engine security-status "$CONF/manager.json" "$CONF/config.json"
        say '1  应用 / 刷新保护（保留管理例外）'
        say '2  允许通过节点 SSH 管理本机    3  允许访问本机 3X-UI 面板'
        say '4  撤销 SSH 例外               5  撤销 3X-UI 面板例外'
        say '6  撤销全部管理例外'
        say '0  返回'
        read -r -p '选择: ' choice || return 0
        case $choice in
            1) mode=apply;;
            2|3)
                kind=ssh; [[ $choice != 3 ]] || kind=panel
                operation=allow;mode=management
                read -r _ _ default_ip default_port _ <<<"${SSH_CONNECTION:-}"
                [[ $kind == ssh ]] || default_port=''
                read -r -p "本机网卡公网 IP${default_ip:+ [$default_ip]}: " address || return 0
                address=${address:-$default_ip}; [[ -n $address ]] || return 0
                read -r -p "服务 TCP 端口${default_port:+ [$default_port]}: " port || return 0
                port=${port:-$default_port}; [[ -n $port ]] || return 0
                if [[ $kind == panel ]]; then
                    read -r -p '面板完整域名（HTTPS 可填写；直接用 IP 则留空）: ' domain || return 0
                fi
                ;;
            4|5|6)
                case $choice in 4) kind=ssh;; 5) kind=panel;; 6) kind=all;; esac
                operation=revoke;mode=management;;
            *) return 0;;
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
              ssh allow <公网IP> <端口> / ssh revoke
              panel allow <公网IP> <端口> [完整域名] / panel revoke / all revoke
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
SwUGAAAAAB0AHQCZBwAA9RYBAAAA
SBM_BUNDLE
}
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
