#!/usr/bin/env bash
# singbox-manager v3.6.0 - transactional core and independent protocol adapters
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
SBM_VERSION=3.6.0
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
    local saved=$1 cc qdisc
    cc=$(sed -n 's/^tcp_congestion_control=\([a-z0-9_]\{1,32\}\)$/\1/p' "$saved")
    qdisc=$(sed -n 's/^default_qdisc=\([a-z0-9_]\{1,32\}\)$/\1/p' "$saved")
    [[ -n $cc && -n $qdisc ]] || return 1
    grep -qw -- "$cc" "$CC_AVAILABLE" || return 1
    sysctl -w "net.ipv4.tcp_congestion_control=$cc" >/dev/null || return 1
    sysctl -w "net.core.default_qdisc=$qdisc" >/dev/null || return 1
}
bbr_action() {
    local f=$BBR_CONF saved=$STATE/bbr-original.conf cc qdisc
    cc=$(sysctl -n net.ipv4.tcp_congestion_control)
    if [[ -f $f ]]; then
        say "当前拥塞控制：${cc}（由本脚本开启）。"
        if [[ -f $saved && ! -L $saved ]]; then
            confirm '关闭本脚本开启的 BBR，恢复开启前的拥塞算法与队列规则' || return 0
        else
            confirm '关闭本脚本开启的 BBR（旧版开启时未记录原设置，将恢复为 cubic 并重新加载系统 sysctl 配置）' || return 0
        fi
        rm -f "$f"
        sysctl --system >/dev/null 2>&1 || true
        if [[ -f $saved && ! -L $saved ]]; then
            if bbr_original_restore "$saved"; then rm -f "$saved"
            else say '警告：记录的原设置无效或内核不再支持，已回退为 cubic；请检查 sysctl 配置。' >&2
                sysctl -w net.ipv4.tcp_congestion_control=cubic >/dev/null; fi
        else
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
        rm -f "$f"; bbr_original_restore "$saved" || true; rm -f "$saved"
        die '系统拒绝修改该参数（可能是容器环境），已撤销。'
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
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
UEsFBgAAAAAdAB0AmQcAAF8FAQAAAA==
SBM_BUNDLE
}
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
