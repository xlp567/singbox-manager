#!/usr/bin/env bash
# singbox-manager v3.6.2 - transactional core and independent protocol adapters
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
SBM_VERSION=3.6.2
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
UEsFBgAAAAAdAB0AmQcAAPUUAQAAAA==
SBM_BUNDLE
}
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
