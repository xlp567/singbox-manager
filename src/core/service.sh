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
