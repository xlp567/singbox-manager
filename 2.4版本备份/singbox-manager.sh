#!/usr/bin/env bash
# singbox-manager v2.4 — Debian / Ubuntu, Bash >=4, systemd
# Single-file distribution: Bash service/transaction layer + embedded Python config engine.
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
# Not VERSION: sourcing /etc/os-release in require_host would overwrite it.
SBM_VERSION=2.4
SHORTCUT=/usr/local/bin/sbm
TMP=''; TX=''; POLICY=0; CANDIDATE=''
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
engine() { python3 "$TMP/engine.py" "$@"; }
setup_tmp() {
    TMP=$(mktemp -d "$STATE/tmp.XXXXXX")
    emit_engine >"$TMP/engine.py"
}
atomic_link() {
    python3 - "$1" "$2" <<'PY'
import os,sys
src,dst=sys.argv[1:]; tmp=dst+'.new'
if os.path.lexists(tmp): os.unlink(tmp)
os.symlink(src,tmp); os.replace(tmp,dst)
PY
}
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
    for p in "$CONF" "$CONF/config.json" "$CONF/manager.json" "$STATE" "$BACKUPS" "$RUNTIME" "$DROP"; do
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
    for c in python3 curl gpg openssl ss dig; do command -v "$c" >/dev/null || missing=1; done
    if (( missing )); then
        say '安装必要的系统依赖……'
        apt-get update
        apt-get install -y python3 curl ca-certificates gnupg openssl iproute2 dnsutils util-linux
    fi
}
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
    POLICY=0
    # A cancelled first deployment must not leave a default daemon enabled at boot.
    systemctl disable --now sing-box
}
fetch_versions() {
    local arch
    arch=$(dpkg --print-architecture)
    case $arch in amd64|arm64|386|s390x|riscv64|loong64) ;; armhf) arch=armv7;; armel) arch=armv6;; *) die "暂不支持架构 ${arch}；不猜测二进制型号。";; esac
    say '实时查询 SagerNet 官方 GitHub 发布版本（网络失败不会改动现有程序）……'
    curl --proto '=https' --tlsv1.2 -fsSL --retry 2 --connect-timeout 10 --max-time 60 \
        -H 'Accept: application/vnd.github+json' 'https://api.github.com/repos/SagerNet/sing-box/releases?per_page=100' -o "$TMP/releases.json"
    engine releases "$TMP/releases.json" "$TMP/catalog.json" "$arch"
    # Cached only for the dashboard hint; selecting a version always uses this fresh query.
    printf '%s %s\n' "$(engine get "$TMP/catalog.json" stable.version)" "$(date -u +%F)" >"$STATE/latest-stable" || true
}
current_version() {
    local b
    b=$(active_binary 2>/dev/null) || return 0
    "$b" version 2>/dev/null | awk 'NR==1 {print $3}'
}
stage_version() {
    # $1=skip-same: picking the version already running is a no-op (CANDIDATE stays empty).
    local url version expected dest actual current
    CANDIDATE=''
    disk_guard
    fetch_versions
    current=$(current_version) || current=""
    engine select-release "$TMP/catalog.json" "$TMP/selected.json" "$current"
    url=$(engine get "$TMP/selected.json" url)
    version=$(engine get "$TMP/selected.json" version)
    expected=$(engine get "$TMP/selected.json" sha256)
    if [[ ${1:-} == skip-same && $version == "$current" ]]; then
        say "当前已在运行 ${version}，与所选版本相同，无需升级；未下载、未重启服务。"
        return 0
    fi
    say "下载并验证官方版本 ${version}……"
    curl --proto '=https' --tlsv1.2 -fL --retry 2 --connect-timeout 10 --max-time 300 "$url" -o "$TMP/release.tar.gz"
    engine extract "$TMP/selected.json" "$TMP/release.tar.gz" "$TMP/sing-box"
    actual=$("$TMP/sing-box" version | head -n 1)
    [[ $actual == "sing-box version $version" ]] || die '二进制自报版本与选择不符。'
    dest="$RUNTIME/releases/$version-${expected:0:12}"
    install -d -m 700 "$dest"
    install -m 755 "$TMP/sing-box" "$dest/sing-box"
    install -m 600 "$TMP/selected.json" "$dest/release.json"
    CANDIDATE=$dest/sing-box
    say "已准备 ${version}；尚未切换运行中的版本。"
}
active_binary() {
    if [[ -f $DROP ]] && grep -q '^ExecStart=/usr/bin/sing-box ' "$DROP" && [[ -x /usr/bin/sing-box ]]; then
        printf '%s' /usr/bin/sing-box; return
    fi
    if [[ -x $BIN ]]; then printf '%s' "$BIN"; elif [[ -x /usr/bin/sing-box ]]; then printf '%s' /usr/bin/sing-box; else return 1; fi
}
disk_guard() {
    local p available
    for p in "$STATE" "$RUNTIME"; do
        available=$(df -Pk "$p" | awk 'NR==2 {print $4}')
        [[ $available =~ ^[0-9]+$ ]] || die "无法检查 $p 可用空间。"
        (( available >= 524288 )) || die "${p} 所在磁盘剩余不足 512 MiB，请先整理空间。"
    done
}
snapshot() {
    disk_guard
    local dest binary
    dest=$(mktemp -d "$BACKUPS/$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")
    [[ ! -d $CONF ]] || cp -a "$CONF" "$dest/config-dir"
    [[ ! -f $DROP ]] || cp -a "$DROP" "$dest/manager-override"
    [[ ! -d $EXPORTS ]] || cp -a "$EXPORTS" "$dest/exports"
    [[ ! -f $STATE/client-info.txt ]] || cp -a "$STATE/client-info.txt" "$dest/legacy-info"
    if binary=$(active_binary); then
        cp -L "$binary" "$dest/runtime.bin"
        "$binary" version >"$dest/version.txt"
    fi
    systemctl is-active --quiet sing-box && touch "$dest/was-active"
    systemctl is-enabled --quiet sing-box 2>/dev/null && touch "$dest/was-enabled"
    touch "$dest/.complete"
    SNAP=$dest
    say "备份已保存：$dest"
}
restore_files() {
    local src=$1 digest dest
    [[ -f $src/.complete ]] || return 1
    if [[ -f $src/runtime.bin ]]; then
        digest=$(sha256sum "$src/runtime.bin" | awk '{print $1}') || return 1
        dest="$RUNTIME/releases/restored-$digest"
        install -d -m 700 "$dest" || return 1
        install -m 755 "$src/runtime.bin" "$dest/sing-box" || return 1
        atomic_link "$dest" "$RUNTIME/current" || return 1
    else
        rm -f "$RUNTIME/current" || return 1
    fi
    rm -rf -- "$CONF" "$EXPORTS" || return 1
    [[ ! -d $src/config-dir ]] || cp -a "$src/config-dir" "$CONF" || return 1
    [[ ! -d $src/exports ]] || cp -a "$src/exports" "$EXPORTS" || return 1
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
        if restore_files "$TX" && restore_service "$TX"; then
            rm -f "$STATE/pending"
            say '回滚完成。' >&2
        else
            say "回滚未完成；保留恢复标记和备份 ${TX}，下次运行可恢复。" >&2
        fi
    fi
    if (( POLICY )) && grep -qx '# singbox-manager temporary policy' /usr/sbin/policy-rc.d 2>/dev/null; then rm -f /usr/sbin/policy-rc.d; fi
    [[ -z $TMP ]] || rm -rf -- "$TMP"
    exit "$rc"
}
begin_transaction() {
    snapshot
    printf '%s\n' "$SNAP" >"$STATE/pending.new"
    mv "$STATE/pending.new" "$STATE/pending"
    TX=$SNAP
}
commit_transaction() { rm -f "$STATE/pending"; TX=''; }
recover_pending() {
    if [[ -f /usr/sbin/policy-rc.d ]] && grep -qx '# singbox-manager temporary policy' /usr/sbin/policy-rc.d; then
        say '发现上次安装中断遗留的本脚本临时策略，正在清理。'
        rm -f /usr/sbin/policy-rc.d
    fi
    [[ -f $STATE/pending ]] || return 0
    local src
    src=$(cat "$STATE/pending")
    [[ $src == "$BACKUPS/"* && $src != *'/../'* && -f $src/.complete ]] || die '未完成事务标记异常，请人工检查。'
    confirm "上次操作异常中断。先恢复备份 $src 才能继续" || die '恢复前暂不执行其他修改。'
    systemctl stop sing-box || return 1
    restore_files "$src" || return 1
    restore_service "$src" || return 1
    rm -f "$STATE/pending" || return 1
    say '上次操作已恢复。'
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
write_override() {
    install -d -m 755 "$(dirname "$DROP")"
    cat >"$DROP" <<UNIT
# Managed by singbox-manager.sh
[Service]
User=root
Group=root
ExecStart=
ExecStart=$BIN -D /var/lib/sing-box -c /etc/sing-box/config.json run
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
apply_draft() {
    local candidate=$1 mode=${2:-preserve} net p
    engine draft-save "$TMP/model.json" "$STATE/draft.json" "$CONF" "$mode"
    say '本次草稿已保存；若取消或检查失败，可用菜单 22 继续。'
    engine netcheck "$TMP/model.json"
    engine compile "$TMP/model.json" "$TMP/config.json"
    "$candidate" check -c "$TMP/config.json"
    engine export "$TMP/model.json" "$TMP/exports"
    engine preflight "$TMP/model.json"
    firewall_info
    if ! confirm '已核对节点/防火墙并同意所选 ACME CA 条款；应用此次变更（服务短暂重启）'; then
        say '节点尚未部署；草稿和凭据已保存，选择菜单 22 可继续。'
        return 0
    fi
    begin_transaction
    systemctl stop sing-box
    engine ports "$TMP/model.json" >"$TMP/ports"
    while read -r net p; do port_free "$net" "$p"; done <"$TMP/ports"
    # Promote candidate into an immutable directory before switching the symlink.
    local digest dest
    digest=$(sha256sum "$candidate" | awk '{print $1}')
    dest="$RUNTIME/releases/runtime-$digest"
    install -d -m 700 "$dest"
    if [[ ! -f $dest/sing-box ]] || ! cmp -s "$candidate" "$dest/sing-box"; then
        install -m 755 "$candidate" "$dest/sing-box"
    fi
    atomic_link "$dest" "$RUNTIME/current"
    install -d -m 700 "$CONF" /var/lib/sing-box/acme
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
    if [[ ! -f $checker ]]; then
        say '此旧版备份没有运行二进制，仅恢复配置；将使用现有 APT 程序。'
        checker=/usr/bin/sing-box
        [[ -x $checker ]] || die '缺少旧版备份所需的 APT 运行程序。'
    fi
    chmod u+x "$checker"
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
require_managed() {
    [[ -f $CONF/manager.json || -f $DROP ]] && return 0
    [[ -f $CONF/config.json ]] || die '尚未部署节点，请先用菜单 1 初始化安装。'
    if [[ -f $STATE/draft.json ]]; then
        die '现有配置尚未由本脚本接管。你有未提交草稿：用菜单 22 补全节点并提交，或用菜单 23 重新接管。'
    fi
    die '现有配置尚未由本脚本接管，暂不能使用此功能。请先用菜单 23 接管（会先备份，再按原端口和密码重新填写节点）。'
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
    case $1 in
        1) initialize;;
        2) list_action;;
        3) edit_nodes add;; 4) edit_nodes edit;; 5) edit_nodes toggle;;
        6) edit_nodes delete;; 7) edit_nodes rotate;;
        8) edit_nodes acme;; 9) export_action;;
        10) change_version;;
        11) dependencies; fetch_versions; engine catalog "$TMP/catalog.json" "$(current_version)";;
        12) diagnostics;;
        13) say 'Ctrl+C 返回菜单。日志可能包含访问地址；UDP 不能据此精确统计在线人数。'; journalctl -u sing-box -n 30 -f -o cat;;
        14) engine connections "$CONF";;
        15|17) b=$(active_binary); "$b" check -c "$CONF/config.json"; if [[ $1 == 15 ]]; then systemctl start sing-box; else systemctl restart sing-box; fi; health;;
        16) systemctl stop sing-box;;
        18) snapshot; say '快照含明文凭据和运行二进制，请私密保存。';;
        19) restore_action;; 20) edit_nodes loglevel;;
        21) uninstall_action;;
        22) resume_draft;;
        23) reinitialize;;
        24) prune_action;;
        25) install_shortcut;;
        26|dash) engine dashboard "$CONF" "$STATE" "$(current_version)";;
        27) bbr_action;;
        *) say '无效选择。';;
    esac
)
main() {
    case ${1:-menu} in
        menu) ;;
        help|-h|--help) usage; return 0;;
        version|-v|--version) say "singbox-manager v$SBM_VERSION"; return 0;;
        status|versions|list|export|check|backup|restart|log|prune|shortcut)
            require_host cli
            [[ ! -f $STATE/pending ]] || die '存在未完成事务；请先不带参数运行脚本，在菜单中完成恢复。'
            case $1 in
                status) action dash;;
                versions) action 11;;
                list) action 2;; export) action 9;; check) action 12;;
                backup) action 18;; restart) action 17;; log) action 13;;
                prune) action 24;; shortcut) action 25;;
            esac
            return;;
        *) usage >&2; die "未知命令：$1";;
    esac
    require_host
    # Recovery is deliberately before the menu; errors must not silently continue.
    recover_pending || die '未完成事务尚未恢复。'
    action dash || true
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
22 继续上次未提交的草稿
23 先备份，再重新初始化（处理未完成安装/外部配置）
24 清理旧备份 / 旧运行版本
25 安装快捷命令 sbm
26 服务器概况        27 开启 / 关闭 BBR
0  退出
MENU
        read -r -p '请选择: ' n || break
        [[ $n != 0 ]] || break
        action "$n"
        rc=$?
        if (( rc!=0 && rc!=130 )); then say "操作未完成（退出码 ${rc}）；请查看上方原因。"; fi
    done
}
emit_engine() {
    cat <<'PY_ENGINE'
#!/usr/bin/env python3
"""Embedded offline config engine. All persistent changes are committed by Bash."""
import base64, copy, datetime, getpass, hashlib, ipaddress, json, os, pathlib, re
import secrets, socket, subprocess, sys, tarfile, urllib.parse, urllib.request, uuid
KINDS = [('anytls','AnyTLS / TCP + TLS',8443),('hysteria2','Hysteria2 / UDP + Salamander',1443),
         ('trojan','Trojan / TCP + TLS',9443),('vless','VLESS / TCP + TLS',2443),
         ('reality','VLESS / Reality + Vision',443),('vmess','VMess / WebSocket + TLS',3443),
         ('tuic','TUIC v5 / UDP + TLS',5443),('shadowsocks','Shadowsocks / TCP + UDP',8388),
         ('naive','Naive HTTPS / TCP + HTTP2',6443)]
TLS_KINDS = {'anytls','hysteria2','trojan','vless','vmess','tuic','naive'}
METHODS = ['2022-blake3-aes-128-gcm','2022-blake3-aes-256-gcm','chacha20-ietf-poly1305','aes-256-gcm']

def fail(s): raise ValueError(s)
def load(p): return json.loads(pathlib.Path(p).read_text())
def save(p,obj):
    p=pathlib.Path(p); tmp=p.with_suffix(p.suffix+'.tmp')
    with open(tmp,'w') as f: json.dump(obj,f,ensure_ascii=False,indent=2); f.write('\n')
    os.chmod(tmp,0o600); os.replace(tmp,p)
def prompt(label, default=None):
    x=input(label + (f' [{default}]' if default is not None else '') + ': ').strip()
    return x if x else (str(default) if default is not None else '')
TRIES = 5
def ask(label, parse, default=None):
    """Re-prompt on invalid input instead of discarding everything typed so far."""
    for i in range(TRIES):
        s=prompt(label,default)
        try: return parse(s)
        except ValueError as e:
            print('  输入无效：'+str(e)+('；请重新输入' if i<TRIES-1 else ''))
    fail('连续多次输入无效，已取消本次编辑')

def choose(label,opts,default=1):
    print(label)
    for i,s in enumerate(opts,1): print(f'  {i}) {s}')
    return ask('选择',lambda s: number(s,1,len(opts)),default)-1

def check_password(s,method=None):
    if '\n' in s or '\r' in s: fail('密码不能包含换行')
    if method and method.startswith('2022-'):
        size=16 if method=='2022-blake3-aes-128-gcm' else 32
        try: valid=len(base64.b64decode(s,validate=True))==size
        except Exception: valid=False
        if not valid: fail(f'此 Shadowsocks 2022 方法要求 {size} 字节随机密钥的 Base64 编码；可留空生成')
    elif len(s)<12: fail('密码至少 12 个字符')
    return s

def password(label,old=None,method=None,rotate=False):
    def generate():
        size=16 if method=='2022-blake3-aes-128-gcm' else 32
        return base64.b64encode(secrets.token_bytes(size)).decode() if method and method.startswith('2022-') else secrets.token_urlsafe(32)
    if rotate: return generate()
    desc='留空保留；输入 ! 生成新密码' if old else '留空自动生成'
    for i in range(TRIES):
        s=getpass.getpass(f'{label}（{desc}）: ')
        if not s and old: return old
        if not s or s=='!': return generate()
        try: return check_password(s,method)
        except ValueError as e:
            print('  输入无效：'+str(e)+('；请重新输入' if i<TRIES-1 else ''))
    fail('连续多次输入无效，已取消本次编辑')

def system_listeners():
    """{(net,port): process names} of current listeners; empty when ss is unavailable."""
    try: out=subprocess.run(['ss','-H','-lntup'],text=True,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,timeout=10).stdout
    except (OSError,subprocess.SubprocessError): return {}
    found={}
    for line in out.splitlines():
        f=line.split()
        if len(f)<5 or f[0] not in ('tcp','udp'): continue
        try: p=int(f[4].rsplit(':',1)[1])
        except (IndexError,ValueError): continue
        found.setdefault((f[0],p),set()).update(re.findall(r'\("([^"]+)"',line) or ['未知进程'])
    return {k:','.join(sorted(v)) for k,v in found.items()}

def challenge_port(m):
    return (80 if m['acme']['challenge']=='http' else 443) if m.get('acme') else None

def port_parser(m,kind,node_id,listeners):
    nets=set(networks({'kind':kind}))
    tls_active=kind in TLS_KINDS or any(o['enabled'] and o['kind'] in TLS_KINDS and o['id']!=node_id for o in m['nodes'])
    def parse(s):
        p=number(s)
        for o in m['nodes']:
            shared=nets & set(networks(o))
            if o['id']!=node_id and o['enabled'] and o['port']==p and shared:
                fail(f'与节点「{o["name"]}」的 {"/".join(sorted(shared))} 端口冲突')
        if tls_active and 'tcp' in nets and p==challenge_port(m):
            fail(f'TCP/{p} 是 ACME 验证端口；可换端口，或用菜单 8 更换验证方式')
        for net in sorted(nets):
            who=listeners.get((net,p))
            if who and 'sing-box' not in who: fail(f'{net}/{p} 已被 {who} 占用')
        return p
    return parse

def suggest_port(parse,base):
    for p in range(base,min(base+2000,65536)):
        try: return parse(str(p))
        except ValueError: pass
    return base

def hostname(s,domain_only=False):
    try:
        ipaddress.ip_address(s)
        if domain_only: fail('这里需要域名，不能填写 IP')
        return s
    except ValueError:
        if domain_only and re.fullmatch(r'[0-9.]+',s): fail('这里需要域名')
    s=s.lower()
    if len(s)>253 or '.' not in s or not all(re.fullmatch(r'[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?',v) for v in s.split('.')):
        fail('主机名无效；不带协议/路径，国际域名先转为 punycode')
    return s

def number(s,lo=1,hi=65535):
    if not s.isdigit() or not lo<=int(s)<=hi: fail(f'数值必须在 {lo}–{hi}')
    return int(s)

def email(s):
    if not re.fullmatch(r'[^\s@]+@[^\s@]+\.[^\s@]+',s): fail('邮箱格式无效')
    return s

def node_name(s):
    if not s or len(s)>80: fail('名称长度要求 1–80')
    return s

def uuid_value(s,old=''):
    if not s and old: return old
    if not s or s=='!': return str(uuid.uuid4())
    try: return str(uuid.UUID(s))
    except ValueError: fail('UUID 格式无效；留空或输入 ! 自动生成')

def ws_path(s):
    if not s.startswith('/') or any(c.isspace() for c in s) or '?' in s or '#' in s: fail('路径须以 / 开头，不含空格、?、#')
    return s

def acme_prompt(m,force=False):
    if m.get('acme') and not force: return
    old=m.get('acme') or {}
    d=ask('证书域名（所有普通 TLS 节点共用）',lambda s: hostname(s,True),old.get('domain'))
    e=ask('ACME 邮箱',email,old.get('email'))
    ca=['letsencrypt','zerossl'][choose('证书 CA',['Let\'s Encrypt 正式环境','ZeroSSL（通过邮箱获取 EAB）'],1 if old.get('provider')!='zerossl' else 2)]
    used={n['port'] for n in m['nodes'] if n['enabled'] and 'tcp' in networks(n)}
    for _ in range(TRIES):
        ch=['http','tls'][choose('域名验证方式（该端口须长期公网直达 VPS）',['HTTP-01 / TCP 80','TLS-ALPN-01 / TCP 443'],1 if old.get('challenge')!='tls' else 2)]
        if (80 if ch=='http' else 443) not in used: break
        print(f'  TCP/{80 if ch=="http" else 443} 已被现有节点使用，请选另一种验证方式或先修改该节点端口。')
    else: fail('ACME 验证端口与现有节点冲突')
    key=['p256','rsa2048'][choose('证书密钥',['p256','rsa2048'],1 if old.get('key_type')!='rsa2048' else 2)]
    m['acme']={'domain':d,'email':e,'provider':ca,'challenge':ch,'key_type':key}
    for n in m['nodes']:
        if n['kind'] in TLS_KINDS: n['server']=d

def keypair(binary):
    text=subprocess.check_output([binary,'generate','reality-keypair'],text=True)
    a=re.search(r'PrivateKey:\s*(\S+)',text); b=re.search(r'PublicKey:\s*(\S+)',text)
    if not a or not b: fail('无法解析 Reality 密钥输出；未修改原配置')
    return a[1],b[1]

def new_model(): return {'schema':2,'listen':'0.0.0.0','log_level':'info','acme':None,'nodes':[]}

def node_prompt(m,binary,old=None):
    n=copy.deepcopy(old) if old else {}
    if not old:
        idx=choose('添加节点类型', [x[1] for x in KINDS]); kind,_,default=KINDS[idx]
        n={'id':'node-'+secrets.token_hex(4),'kind':kind,'enabled':True}
    else:
        kind=n['kind']; default=n['port']; print('修改类型：'+kind+'（切换协议请另加节点）')
    n['name']=ask('节点名称',node_name,n.get('name',kind+'-'+n['id'][-4:]))
    # Certificate settings first, so the port check knows the ACME challenge port.
    if kind in TLS_KINDS: acme_prompt(m)
    parse=port_parser(m,kind,n['id'],system_listeners())
    if not old:
        default=suggest_port(parse,default)
    n['port']=ask('监听端口（已自动避开占用端口）' if not old else '监听端口',parse,default)
    if kind in TLS_KINDS:
        n['server']=m['acme']['domain']
    else:
        n['server']=ask('客户端连接的 VPS 公网 IP 或域名',hostname,n.get('server',m.get('acme',{}).get('domain') if m.get('acme') else None))
    if kind!='shadowsocks': n['username']=prompt('用户名 / 日志标识',n.get('username','user'))
    if kind in {'anytls','hysteria2','trojan','tuic','naive'}:
        n['password']=password('认证密码',n.get('password'))
    if kind in {'vless','reality','vmess','tuic'}:
        n['uuid']=ask('UUID（新建留空自动生成；修改可输入 ! 重置）',lambda s: uuid_value(s,n.get('uuid','')),n.get('uuid') or None)
    if kind=='hysteria2':
        n['obfs']=password('Salamander 混淆密码',n.get('obfs'))
        profiles=['standard','conservative','aggressive']
        n['bbr']=profiles[choose('BBR 配置',profiles,profiles.index(n.get('bbr','standard'))+1)]
    if kind=='tuic': n['congestion_control']='bbr'
    if kind=='shadowsocks':
        method=METHODS[choose('加密方式',METHODS,METHODS.index(n.get('method',METHODS[0]))+1)]
        n['password']=password('Shadowsocks 密码 / 密钥',n.get('password') if n.get('method')==method else None,method)
        n['method']=method
    if kind=='vmess':
        n['path']=ask('WebSocket 路径',ws_path,n.get('path','/'+secrets.token_hex(6)))
    if kind=='reality':
        n['target']=ask('Reality 握手目标域名（需支持 TLS 1.3，提交前会自动检测）',lambda s: hostname(s,True),n.get('target'))
        n['target_port']=ask('握手目标端口',number,n.get('target_port',443))
        n['sni']=ask('Reality SNI（须与目标证书匹配）',lambda s: hostname(s,True),n.get('sni',n['target']))
        if not n.get('private_key'): n['private_key'],n['public_key']=keypair(binary)
        n['short_id']=n.get('short_id') or secrets.token_hex(4)
    return n

def list_nodes(m):
    if not m['nodes']: print('还没有节点。')
    for i,n in enumerate(m['nodes'],1):
        print(f"{i:>2}) {'启用' if n['enabled'] else '停用'} | {n['name']} | {n['kind']} | {n['server']}:{n['port']} | {n['id']}")

def pick(m):
    list_nodes(m)
    if not m['nodes']: fail('没有节点')
    return number(prompt('节点序号'),1,len(m['nodes']))-1

def networks(n):
    return ['udp'] if n['kind'] in {'hysteria2','tuic'} else (['tcp','udp'] if n['kind']=='shadowsocks' else ['tcp'])

def validation(m):
    if m.get('schema')!=2: fail('不支持的管理数据格式')
    ids=set(); ports=set()
    for n in m['nodes']:
        if n['kind'] not in {x[0] for x in KINDS}: fail('未知节点类型')
        if not re.fullmatch(r'[a-zA-Z0-9_-]{1,64}',n['id']) or n['id'] in ids: fail('节点标识重复或无效')
        ids.add(n['id']); number(str(n['port'])); hostname(n['server'])
        if not isinstance(n['enabled'],bool): fail('节点状态无效')
        if n['kind'] in TLS_KINDS:
            if not m.get('acme') or n['server']!=m['acme']['domain']: fail('TLS 节点证书域名不一致')
        if n['enabled']:
            for net in networks(n):
                p=(net,n['port'])
                if p in ports: fail(f'节点端口冲突：{net}/{n["port"]}')
                ports.add(p)
    if any(n['enabled'] and n['kind'] in TLS_KINDS for n in m['nodes']):
        cp=80 if m['acme']['challenge']=='http' else 443
        if ('tcp',cp) in ports: fail(f'ACME 挑战端口 TCP/{cp} 与节点冲突；可修改节点端口或更换 ACME 验证方式')
    if m['listen'] not in {'0.0.0.0','::'}: fail('监听地址不支持')

def compile_config(m):
    validation(m)
    out={'log':{'level':m.get('log_level','info'),'timestamp':True},'inbounds':[],
         'outbounds':[{'type':'direct','tag':'direct'}],'route':{'final':'direct'}}
    if any(n['enabled'] and n['kind'] in TLS_KINDS for n in m['nodes']):
        a=m['acme']; out['certificate_providers']=[{'type':'acme','tag':'acme-main','domain':[a['domain']],
          'default_server_name':a['domain'],'data_directory':'/var/lib/sing-box/acme','email':a['email'],
          'provider':a['provider'],'key_type':a['key_type'],'disable_http_challenge':a['challenge']!='http',
          'disable_tls_alpn_challenge':a['challenge']!='tls'}]
    for n in m['nodes']:
        if not n['enabled']: continue
        k=n['kind']; x={'type':'vless' if k=='reality' else k,'tag':n['id'],'listen':m['listen'],'listen_port':n['port']}
        if k in TLS_KINDS: x['tls']={'enabled':True,'server_name':m['acme']['domain'],'certificate_provider':'acme-main'}
        if k in {'anytls','hysteria2','trojan'}: x['users']=[{'name':n['username'],'password':n['password']}]
        if k=='hysteria2': x.update({'obfs':{'type':'salamander','password':n['obfs']},'ignore_client_bandwidth':True,'bbr_profile':n['bbr']})
        if k in {'vless','reality','vmess'}:
            x['users']=[{'name':n['username'],'uuid':n['uuid']}]
            if k=='vmess':
                x['users'][0]['alterId']=0
                x['transport']={'type':'ws','path':n['path']}
            if k=='reality':
                x['users'][0]['flow']='xtls-rprx-vision'
                x['tls']={'enabled':True,'server_name':n['sni'],'reality':{'enabled':True,
                    'handshake':{'server':n['target'],'server_port':n['target_port']},'private_key':n['private_key'],'short_id':[n['short_id']]}}
        if k=='tuic':
            x['users']=[{'name':n['username'],'uuid':n['uuid'],'password':n['password']}]
            x.update({'congestion_control':n['congestion_control'],'zero_rtt_handshake':False})
            x['tls']['alpn']=['h3']
        if k=='shadowsocks': x.update({'method':n['method'],'password':n['password']})
        if k=='naive':
            x['users']=[{'username':n['username'],'password':n['password']}]
            x['network']='tcp'; x['tls']['alpn']=['h2']
        out['inbounds'].append(x)
    return out

def client_node(n):
    k=n['kind']; x={'type':'vless' if k=='reality' else k,'tag':n['id'],'server':n['server'],'server_port':n['port']}
    if k in TLS_KINDS: x['tls']={'enabled':True,'server_name':n['server'],'insecure':False}
    if k in {'anytls','hysteria2','trojan','tuic','shadowsocks','naive'}: x['password']=n['password']
    if k in {'vless','reality','vmess','tuic'}: x['uuid']=n['uuid']
    if k=='hysteria2': x.update({'obfs':{'type':'salamander','password':n['obfs']}})
    if k=='tuic':
        x.update({'congestion_control':n['congestion_control'],'zero_rtt_handshake':False}); x['tls']['alpn']=['h3']
    if k=='shadowsocks': x['method']=n['method']
    if k=='naive': x.update({'username':n['username']})
    if k=='vmess': x.update({'security':'auto','alter_id':0,'transport':{'type':'ws','path':n['path'],'headers':{'Host':n['server']}}})
    if k=='reality':
        x['flow']='xtls-rprx-vision'
        x['tls']={'enabled':True,'server_name':n['sni'],'utls':{'enabled':True,'fingerprint':'chrome'},
                  'reality':{'enabled':True,'public_key':n['public_key'],'short_id':n['short_id']}}
    return x

def uri(n):
    q=lambda s:urllib.parse.quote(str(s),safe='')
    k=n['kind']; host=n['server']; host=f'[{host}]' if ':' in host else host
    address=f'{host}:{n["port"]}'; frag=q(n['name']); args={'sni':n['server'],'insecure':'0'}
    if k=='shadowsocks':
        auth=(q(n['method'])+':'+q(n['password'])) if n['method'].startswith('2022-') else base64.urlsafe_b64encode(f'{n["method"]}:{n["password"]}'.encode()).decode().rstrip('=')
        return f'ss://{auth}@{address}#{frag}'
    if k=='vmess':
        data={'v':'2','ps':n['name'],'add':n['server'],'port':str(n['port']),'id':n['uuid'],'aid':'0','scy':'auto',
              'net':'ws','type':'none','host':n['server'],'path':n['path'],'tls':'tls','sni':n['server']}
        return 'vmess://'+base64.b64encode(json.dumps(data,ensure_ascii=False).encode()).decode()
    if k=='naive': return f'naive+https://{q(n["username"])}:{q(n["password"])}@{address}#{frag}'
    auth=q(n.get('password','')); scheme=k
    if k=='hysteria2': args.update({'obfs':'salamander','obfs-password':n['obfs']})
    if k in {'vless','reality'}:
        scheme='vless';auth=n['uuid'];args.update({'encryption':'none','type':'tcp','security':'tls'})
        if k=='reality': args.update({'security':'reality','sni':n['sni'],'fp':'chrome','pbk':n['public_key'],'sid':n['short_id'],'flow':'xtls-rprx-vision'})
    if k in {'anytls','trojan'}: args['security']='tls'
    if k=='tuic': auth=n['uuid']+':'+q(n['password']);args.update({'congestion_control':'bbr','alpn':'h3','udp_relay_mode':'native'})
    return f'{scheme}://{auth}@{address}?{urllib.parse.urlencode(args,quote_via=urllib.parse.quote)}#{frag}'

def export(m,dest):
    dest=pathlib.Path(dest); dest.mkdir(parents=True,exist_ok=True)
    lines=['sing-box 客户端连接资料（含密码；请私密保存）',
        '状态“启用”仅表示配置启用，不代表外网连接已验证。',
        '各客户端 URI 支持不同；导入失败按字段手工填写。客户端需要支持对应协议。',
        '单独 username 通常是日志标签；Naive 的 username 是认证字段。不要拼接为 username:password。']
    outs=[]; links=[]
    for n in m['nodes']:
        lines+=['',f'===== {n["name"]} / {n["kind"]} / {"启用" if n["enabled"] else "停用"} =====',
                '节点 ID: '+n['id'],f'服务器: {n["server"]}',f'端口: {n["port"]}',f'传输: {" + ".join(networks(n)).upper()}']
        for key,title in [('username','用户名'),('password','密码'),('uuid','UUID'),('method','加密方法'),('obfs','Salamander 混淆密码'),('path','WebSocket 路径'),('public_key','Reality 公钥'),('short_id','Reality short ID')]:
            if key in n: lines.append(title+': '+n[key])
        if n['kind'] in TLS_KINDS: lines += ['TLS: 开启；跳过证书验证: 否','SNI: '+n['server']]
        if n['kind']=='reality': lines+=['TLS: Reality；flow: xtls-rprx-vision；指纹: chrome','SNI: '+n['sni']]
        if n['kind']=='tuic': lines+=['ALPN: h3；拥塞控制: bbr；0-RTT: 关闭']
        if n['kind']=='naive': lines+=['模式: HTTPS / HTTP2；ALPN: h2','注意: sing-box 客户端使用 naive 出站需带 cronet 支持（Linux 命令行版缺少时会报 cronet: library not found）']
        if n['enabled']:
            link=uri(n); lines+=['参考导入链接:',link]; links.append(link); outs.append(client_node(n))
        else: lines+=['此节点已停用，不加入导入链接与客户端配置。']
    for name,text in [('client-info.txt','\n'.join(lines)+'\n'),('links.txt','\n'.join(links)+'\n')]:
        (dest/name).write_text(text); os.chmod(dest/name,0o600)
    save(dest/'client-outbounds.json',{'outbounds':outs})

def ports(m):
    validation(m); result=set()
    for n in m['nodes']:
        if n['enabled']: result.update((p,n['port']) for p in networks(n))
    if any(n['enabled'] and n['kind'] in TLS_KINDS for n in m['nodes']): result.add(('tcp',80 if m['acme']['challenge']=='http' else 443))
    return sorted(result)

def preflight(m):
    listeners=system_listeners(); busy=[]
    for net,p in ports(m):
        who=listeners.get((net,p))
        if who and 'sing-box' not in who: busy.append(f'{net}/{p} ← {who}')
    if busy: fail('以下端口被其他进程占用，提交后无法监听；请先停用占用程序或修改节点端口：'+'；'.join(busy))
    print('端口预检通过（sing-box 自身占用的端口会在切换时释放）。')

def verify_dns(m):
    names={n['server'] for n in m['nodes'] if n['enabled']}
    if not names: return
    public=set()
    for family,url in [(socket.AF_INET,'https://api.ipify.org'),(socket.AF_INET6,'https://api6.ipify.org')]:
        try:
            s=subprocess.check_output(['curl','-4' if family==socket.AF_INET else '-6','-fsS','--connect-timeout','5','--max-time','10',url],stderr=subprocess.DEVNULL,text=True).strip()
            public.add(ipaddress.ip_address(s))
        except (subprocess.CalledProcessError,ValueError): pass
    if not public: fail('无法检测本机公网 IP；请检查网络后重试')
    print('检测到公网 IP：'+', '.join(map(str,sorted(public,key=str))))
    has6=False
    for name in sorted(names):
        try: addresses={ipaddress.ip_address(name)}
        except ValueError:
            addresses=set()
            for typ in ['A','AAAA']:
                s=subprocess.check_output(['dig','+time=3','+tries=1','+short',typ,name],text=True)
                for line in s.splitlines():
                    try: addresses.add(ipaddress.ip_address(line.strip()))
                    except ValueError: pass
        print(name+' => '+(', '.join(map(str,sorted(addresses,key=str))) or '无解析'))
        if not addresses or not addresses.issubset(public): fail('节点地址未全部匹配本机公网 IP；检查 A/AAAA、CDN、多 IP/NAT。脚本不会跳过')
        has6 |= any(x.version==6 for x in addresses)
    for n in m['nodes']:
        if n['enabled'] and n['kind']=='reality':
            print('检查 Reality 握手目标 TLS 1.3：'+n['target'])
            try:
                r=subprocess.run(['openssl','s_client','-connect',f'{n["target"]}:{n["target_port"]}',
                    '-servername',n['sni'],'-tls1_3','-verify_hostname',n['sni'],'-verify_return_error',
                    '-CApath','/etc/ssl/certs'],input='',text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=15)
                if r.returncode: fail('Reality 目标 TLS 1.3/证书验证失败，未提交变更')
            except subprocess.TimeoutExpired: fail('Reality 目标握手超时，未提交变更')
    m['listen']='::' if has6 else '0.0.0.0' 
    if has6:
        if subprocess.check_output(['sysctl','-n','net.ipv6.bindv6only'],text=True).strip()!='0': fail('bindv6only 必须为 0，才能使用双栈监听')

def import_v1(path):
    c=load(path); m=new_model()
    expected={'log','certificate_providers','inbounds','outbounds','route'}
    if set(c)-expected or c.get('outbounds')!=[{'type':'direct','tag':'direct'}] or c.get('route')!={'final':'direct'}: fail('不是可识别的旧脚本配置；保留原配置，不自动接管自定义规则')
    providers=c.get('certificate_providers',[])
    if len(providers)!=1 or providers[0].get('type')!='acme': fail('旧配置证书结构无法安全迁移')
    a=providers[0]
    if len(a['domain'])!=1 or a.get('dns01_challenge') or a.get('alternative_http_port') or a.get('alternative_tls_port'): fail('旧 ACME 配置超出迁移范围')
    if bool(a.get('disable_http_challenge'))==bool(a.get('disable_tls_alpn_challenge')): fail('旧挑战模式不能安全迁移')
    m['acme']={'domain':a['domain'][0],'email':a['email'],'provider':a['provider'],'challenge':'tls' if a.get('disable_http_challenge') else 'http','key_type':a.get('key_type','p256')}
    for x in c['inbounds']:
        k=x['type']
        if k not in {'anytls','hysteria2'} or len(x.get('users',[]))!=1: fail('旧配置含不支持的节点，停止迁移')
        n={'id':x['tag'],'name':x['tag'],'kind':k,'enabled':True,'port':x['listen_port'],'server':a['domain'][0],
           'username':x['users'][0]['name'],'password':x['users'][0]['password']}
        if k=='hysteria2': n.update({'obfs':x['obfs']['password'],'bbr':x.get('bbr_profile','standard')})
        m['nodes'].append(n); m['listen']=x['listen']
    # Exact round trip rejects hand-added routing, users, TLS and other unknown fields.
    if compile_config(m)!=c: fail('旧配置有自定义字段或不同默认值；拒绝覆盖，请人工迁移')
    return m

def releases(source,out,arch):
    data=load(source)
    if not isinstance(data,list): fail('GitHub API 返回错误，可能触发限流')
    rows=[]
    for r in data:
        tag=r.get('tag_name','')
        if r.get('draft') or not re.fullmatch(r'v\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?',tag): continue
        ver=tag[1:]; nums=tuple(map(int,ver.split('-')[0].split('.')))
        if nums<(1,14,0): continue
        filename=f'sing-box-{ver}-linux-{arch}.tar.gz'
        a=next((a for a in r.get('assets',[]) if a.get('name')==filename),None)
        if not a: continue
        url=a.get('browser_download_url',''); digest=a.get('digest') or ''
        if not url.startswith('https://github.com/SagerNet/sing-box/releases/download/'+tag+'/'): continue
        if not re.fullmatch(r'sha256:[0-9a-f]{64}',digest): continue
        rows.append({'version':ver,'preview':r.get('prerelease',False),'published':r.get('published_at',''),
                     'url':url,'sha256':digest[7:],'asset':filename,'member':f'sing-box-{ver}-linux-{arch}/sing-box'})
    if not rows: fail('未找到本架构带官方 SHA-256 的可用版本；不安装未验证文件')
    # GitHub /latest is not the same as the most recently published prerelease.
    rows.sort(key=lambda r:r['published'],reverse=True)
    stable=max((r for r in rows if not r['preview'] and '-' not in r['version']), key=lambda r:tuple(map(int,r['version'].split('.'))), default=None)
    if not stable: fail('此次查询未找到稳定版；停止，避免误将测试版作为稳定版')
    save(out,{'stable':stable,'latest':rows[0],'all':rows})

def vkey(v):
    """Semver-ish ordering: 1.15.0-alpha.10 > 1.15.0-alpha.9, and 1.15.0 > any 1.15.0-*."""
    base,_,pre=v.partition('-')
    nums=tuple(int(x) for x in base.split('.'))
    if not pre: return nums+((1,),)
    return nums+((0,)+tuple((0,int(x)) if x.isdigit() else (1,x) for x in pre.split('.')),)

def compare_note(v,current):
    if not current: return ''
    try: a,b=vkey(v),vkey(current)
    except ValueError: return ''
    return '（与当前相同）' if a==b else ('（比当前新，可升级）' if a>b else '（比当前旧，选择即降级）')

def version_summary(r,current):
    s=r['stable']; l=r['latest']
    print('官方版本（本次实时查询）：')
    print('当前运行版本：'+(current or '未安装 / 无法读取'))
    print(f"最新稳定版：{s['version']} / {s['published'][:10]}{compare_note(s['version'],current)}")
    print(f"最新发布版：{l['version']} / {'测试版' if l['preview'] else '稳定版'} / {l['published'][:10]}{compare_note(l['version'],current)}")
    if current:
        try: newer=vkey(s['version'])>vkey(current)
        except ValueError: newer=None
        if newer: print('结论：有新的稳定版，建议升级。')
        elif newer is False: print('结论：当前已是最新稳定版（或更新），通常无需升级。')

def select_release(p,out,current=''):
    r=load(p); s=r['stable']; l=r['latest']
    version_summary(r,current)
    ch=choose('安装版本',['最新稳定版（推荐）','最新发布版（可能是 alpha / beta）','从本次查询的其他版本中选择'])
    if ch==0: x=s
    elif ch==1: x=l
    else:
        idx=choose('版本列表',[f"{v['version']} ({'测试' if v['preview'] else '稳定'}){'（当前运行）' if v['version']==current else ''}" for v in r['all']]); x=r['all'][idx]
    if x['preview'] and x['version']!=current and prompt('测试版可能有不兼容改动，输入 PREVIEW 确认')!='PREVIEW': fail('未选择测试版')
    save(out,x)

def extract_release(meta,archive,dest):
    r=load(meta); actual=hashlib.sha256(pathlib.Path(archive).read_bytes()).hexdigest()
    if actual!=r['sha256']: fail('下载 SHA-256 与官方发布元数据不符')
    with tarfile.open(archive,'r:gz') as t:
        members=[m for m in t.getmembers() if m.name==r['member']]
        if len(members)!=1 or not members[0].isfile(): fail('官方压缩包内二进制结构异常')
        f=t.extractfile(members[0]); pathlib.Path(dest).write_bytes(f.read())
    os.chmod(dest,0o755)

def probe(m):
    for n in m['nodes']:
        if not n['enabled'] or n['kind'] not in TLS_KINDS: continue
        if 'tcp' not in networks(n):
            print(n['name']+': UDP/QUIC，请使用外网客户端测试。'); continue
        args=['openssl','s_client','-connect',f'127.0.0.1:{n["port"]}','-servername',n['server'],
              '-verify_hostname',n['server'],'-verify_return_error','-CApath','/etc/ssl/certs']
        if n['kind']=='naive': args+=['-alpn','h2']
        try:
            r=subprocess.run(args,input='',text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=10)
            print(n['name']+(': 本机 TLS 证书验证通过（不代表公网可达）' if r.returncode==0 else ': 证书/握手未就绪，检查签发日志及验证端口'))
        except subprocess.TimeoutExpired: print(n['name']+': 本机 TLS 测试超时')

def human(n):
    for unit in ['B','KiB','MiB','GiB','TiB']:
        if n<1024 or unit=='TiB': return (f'{n:.0f} {unit}' if unit=='B' else f'{n:.1f} {unit}')
        n/=1024

def duration(sec):
    sec=int(sec); d,sec=divmod(sec,86400); h,sec=divmod(sec,3600); mi=sec//60
    return f'{d} 天 {h} 小时' if d else (f'{h} 小时 {mi} 分' if h else f'{mi} 分钟')

def read(path,default=''):
    try: return pathlib.Path(path).read_text()
    except OSError: return default

def run_text(args,timeout=5):
    try: return subprocess.run(args,text=True,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,timeout=timeout).stdout
    except (OSError,subprocess.SubprocessError): return ''

def cpu_percent(interval=0.4):
    def sample():
        f=[int(x) for x in read('/proc/stat').split('\n',1)[0].split()[1:]]
        return sum(f), f[3]+(f[4] if len(f)>4 else 0)
    try:
        t1,i1=sample(); import time; time.sleep(interval); t2,i2=sample()
        return 100.0*(1-(i2-i1)/max(t2-t1,1))
    except (ValueError,IndexError): return None

def meminfo():
    m={}
    for line in read('/proc/meminfo').splitlines():
        k,_,v=line.partition(':')
        try: m[k]=int(v.split()[0])*1024
        except (ValueError,IndexError): pass
    return m

def default_iface():
    for line in read('/proc/net/route').splitlines()[1:]:
        f=line.split()
        if len(f)>2 and f[1]=='00000000': return f[0]
    return None

def iface_bytes(name):
    for line in read('/proc/net/dev').splitlines():
        k,_,v=line.partition(':')
        if k.strip()==name:
            f=v.split(); return int(f[0]),int(f[8])
    return None

def service_inbounds(conf_dir):
    """[(label, kind, port, nets)] of what the live config listens on, managed or not."""
    mj=pathlib.Path(conf_dir)/'manager.json'
    if mj.exists():
        m=load(mj)
        return [(n['name'],n['kind'],n['port'],networks(n),n['enabled']) for n in m['nodes']],True
    try: c=load(pathlib.Path(conf_dir)/'config.json')
    except (OSError,ValueError): return [],False
    rows=[]
    for x in c.get('inbounds',[]):
        k=x.get('type','?'); p=x.get('listen_port')
        if not isinstance(p,int): continue
        nets=['udp'] if k in {'hysteria2','tuic','hysteria'} else (['tcp','udp'] if k=='shadowsocks' else ['tcp'])
        rows.append((x.get('tag',k),k,p,nets,True))
    return rows,False

def established(ports):
    """{port: [peer ip,...]} for established inbound TCP connections to sing-box node ports."""
    out=run_text(['ss','-Htnp','state','established']); res={p:[] for p in ports}
    for line in out.splitlines():
        if 'sing-box' not in line: continue
        f=line.split()
        if len(f)<4: continue
        try: lp=int(f[2].rsplit(':',1)[1])
        except (IndexError,ValueError): continue
        if lp in res: res[lp].append(f[3].rsplit(':',1)[0].strip('[]').replace('::ffff:',''))
    return res

def cert_status(domain):
    hits=sorted(pathlib.Path('/var/lib/sing-box/acme/certificates').glob(f'*/{domain}/{domain}.crt'))
    if not hits: return '未找到缓存证书（首次签发需等待几分钟，或检查 ACME 验证端口）'
    s=run_text(['openssl','x509','-noout','-enddate','-in',str(hits[-1])]).strip()
    try:
        end=datetime.datetime.strptime(s.split('=',1)[1],'%b %d %H:%M:%S %Y %Z').replace(tzinfo=datetime.timezone.utc)
    except (IndexError,ValueError): return '无法解析证书到期时间'
    days=(end-datetime.datetime.now(datetime.timezone.utc)).days
    warn='  ⚠ 少于 15 天，请检查自动续期' if days<15 else ''
    return f'剩余 {days} 天（{end:%Y-%m-%d} 到期）{warn}'

def dashboard(conf_dir,state_dir,current):
    import unicodedata
    def W(k,v):
        width=sum(2 if unicodedata.east_asian_width(ch) in 'WF' else 1 for ch in k)
        print(k+' '*max(1,10-width)+v)
    os_name=next((l.split('=',1)[1].strip('"') for l in read('/etc/os-release').splitlines() if l.startswith('PRETTY_NAME=')),'Linux')
    u=os.uname(); up=float(read('/proc/uptime','0').split()[0] or 0); load1=os.getloadavg(); cores=os.cpu_count() or 1
    print('==================== 服务器概况 ====================')
    W('主机',f'{socket.gethostname()} ｜ {os_name} ｜ 内核 {u.release} ｜ {u.machine}')
    W('运行',f'{duration(up)} ｜ 负载 {load1[0]:.2f} {load1[1]:.2f} {load1[2]:.2f}（{cores} 核）')
    c=cpu_percent(); W('CPU',f'{c:.0f}%' if c is not None else '无法读取')
    m=meminfo(); tot=m.get('MemTotal',0); used=tot-m.get('MemAvailable',0); st=m.get('SwapTotal',0); su=st-m.get('SwapFree',0)
    W('内存',f'{human(used)} / {human(tot)}（{100*used/max(tot,1):.0f}%）｜ Swap {human(su)} / {human(st)}'+('  ⚠ 内存紧张' if tot and used/tot>0.9 else ''))
    import shutil; d=shutil.disk_usage('/')
    W('磁盘 /',f'{human(d.used)} / {human(d.total)}（{100*d.used/d.total:.0f}%），剩余 {human(d.free)}'+('  ⚠ 空间不足' if d.free<1<<30 else ''))
    ifc=default_iface()
    if ifc:
        b=iface_bytes(ifc); addrs=[l.split()[3] for l in run_text(['ip','-o','addr','show','dev',ifc,'scope','global']).splitlines() if len(l.split())>3]
        if b: W('流量',f'{ifc} ↓ {human(b[0])}  ↑ {human(b[1])}（开机以来）')
        if addrs: W('地址',' '.join(a.split('/')[0] for a in addrs))
    cc=read('/proc/sys/net/ipv4/tcp_congestion_control').strip() or '?'; q=read('/proc/sys/net/core/default_qdisc').strip() or '?'
    W('TCP',f'拥塞控制 {cc} ｜ 队列 {q}'+('' if cc=='bbr' else '  （可用菜单 27 开启 BBR）'))
    ntp=run_text(['timedatectl','show','-p','NTPSynchronized','--value']).strip()
    W('时间',{'yes':'已同步','no':'未同步 ⚠ 会导致 TLS / Reality 连接失败'}.get(ntp,'无法确认'))
    print('---------------------- sing-box ----------------------')
    prop=dict(l.split('=',1) for l in run_text(['systemctl','show','sing-box','-p','ActiveState','-p','MainPID','-p','NRestarts','-p','UnitFileState']).splitlines() if '=' in l)
    state={'active':'运行中','inactive':'已停止','failed':'失败 ⚠','activating':'启动中'}.get(prop.get('ActiveState',''),prop.get('ActiveState','未安装') or '未安装')
    pid=prop.get('MainPID','0'); extra=''
    if pid.isdigit() and pid!='0':
        try:
            stat=read(f'/proc/{pid}/stat').rsplit(')',1)[1].split(); tck=os.sysconf('SC_CLK_TCK')
            rss=next((int(l.split()[1])*1024 for l in read(f'/proc/{pid}/status').splitlines() if l.startswith('VmRSS:')),0)
            extra=f'，已运行 {duration(up-int(stat[19])/tck)} ｜ 内存 {human(rss)} ｜ CPU 累计 {(int(stat[11])+int(stat[12]))/tck:.0f} 秒'
        except (IndexError,ValueError): pass
    W('状态',state+extra+f" ｜ 重启 {prop.get('NRestarts','?')} 次 ｜ 开机自启 {'是' if prop.get('UnitFileState')=='enabled' else '否'}")
    cache=read(pathlib.Path(state_dir)/'latest-stable').split()
    vline=current or '未安装'
    if cache and current:
        try: vline+=f'（最新稳定版 {cache[0]}，'+('可升级' if vkey(cache[0])>vkey(current) else '已是最新')+f'｜查询于 {cache[1] if len(cache)>1 else "?"}）'
        except ValueError: pass
    elif current: vline+='（菜单 11 可查询最新版本）'
    W('版本',vline)
    rows,managed=service_inbounds(conf_dir)
    if not rows: W('节点','暂无')
    else:
        on=[r for r in rows if r[4]]
        W('节点',f"启用 {len(on)} / 共 {len(rows)}"+('' if managed else '  （现有配置尚未由脚本接管：菜单 23 接管）'))
        conns=established([r[2] for r in on if 'tcp' in r[3]])
        for label,kind,port,nets,en in rows:
            if not en: tail='停用'
            elif 'tcp' in nets:
                ips=conns.get(port,[]); tail=f'TCP 连接 {len(ips)} 条 / {len(set(ips))} 个 IP'
            else: tail='UDP/QUIC（连接数无法统计）'
            print(f"          · {label} | {kind} | {'+'.join(nets).upper()}/{port} | {tail}")
    domains=set()
    if managed:
        a=load(pathlib.Path(conf_dir)/'manager.json').get('acme')
        if a: domains.add(a['domain'])
    else:
        try:
            for p in load(pathlib.Path(conf_dir)/'config.json').get('certificate_providers',[]): domains.update(p.get('domain',[]))
        except (OSError,ValueError): pass
    for dmn in sorted(domains): W('证书',f'{dmn} {cert_status(dmn)}')
    others=sorted({n for (net,p),n in system_listeners().items()}-{'sing-box','sshd','systemd-resolve','exim4','chronyd','systemd-timesyncd','未知进程'})
    if others: W('其他',f"本机还有其他程序在监听：{', '.join(others)}（新增节点时会自动避开它们的端口）")
    flags=[]
    if (pathlib.Path(state_dir)/'draft.json').exists(): flags.append('有未提交草稿（菜单 22）')
    if (pathlib.Path(state_dir)/'pending').exists(): flags.append('有未完成事务 ⚠')
    if flags: W('提醒','；'.join(flags))

def connections(conf_dir):
    rows,_=service_inbounds(conf_dir)
    on=[r for r in rows if r[4]]
    if not on: print('没有启用的节点。'); return
    conns=established([r[2] for r in on if 'tcp' in r[3]]); total=[]
    for label,kind,port,nets,_ in on:
        if 'tcp' not in nets: print(f'{label} | {kind} | UDP/{port} | QUIC/UDP 无连接状态，无法统计'); continue
        ips=conns.get(port,[]); total+=ips
        top=', '.join(f'{ip}×{ips.count(ip)}' for ip in sorted(set(ips),key=lambda x:-ips.count(x))[:5])
        print(f'{label} | {kind} | TCP/{port} | {len(ips)} 条连接，{len(set(ips))} 个来源 IP'+(f' | {top}' if top else ''))
    print(f'合计 TCP：{len(total)} 条，{len(set(total))} 个来源 IP。连接数不等于在线人数；UDP 节点需看客户端。')

def log_summary(since='1 hour ago'):
    out=run_text(['journalctl','-u','sing-box','--since',since,'--no-pager','-o','cat'],timeout=15).splitlines()
    clean=[re.sub(r'\x1b\[[0-9;]*m','',l) for l in out]
    inbound=sum('inbound connection from' in l for l in clean)
    tls=[l for l in clean if 'TLS handshake' in l]
    other=[l for l in clean if ('ERROR' in l or 'WARN' in l or 'FATAL' in l) and 'TLS handshake' not in l]
    print(f'最近 1 小时日志：入站连接 {inbound} 次；TLS 握手失败 {len(tls)} 次（大多是公网扫描器探测，通常可忽略）；其他警告/错误 {len(other)} 条。')
    for l in other[-8:]: print('  '+l[:220])
    if not other: print('  没有需要关注的其他错误。')

def draft_fingerprint(conf):
    conf=pathlib.Path(conf)
    return {name:hashlib.sha256((conf/name).read_bytes()).hexdigest() if (conf/name).exists() else None
            for name in ['config.json','manager.json']}

def main():
    cmd=sys.argv[1]; args=sys.argv[2:]
    if cmd=='draft-save':
        m=load(args[0]); validation(m)
        save(args[1],{'model':m,'base':draft_fingerprint(args[2]),'mode':args[3]})
        return
    if cmd=='draft-load':
        d=load(args[0])
        if d['base']!=draft_fingerprint(args[1]): fail('保存草稿后当前配置已变化，拒绝覆盖。请重新编辑，或先人工核查草稿')
        if d.get('mode') not in {'start','preserve'}: fail('草稿启动模式无效')
        validation(d['model']); save(args[2],d['model']); return
    if cmd=='catalog':
        version_summary(load(args[0]),args[1] if len(args)>1 else '')
        print('来源：SagerNet/sing-box 官方 GitHub；查询失败时不使用旧缓存。'); return
    if cmd=='releases': return releases(*args)
    if cmd=='select-release': return select_release(*args)
    if cmd=='extract': return extract_release(*args)
    if cmd=='new': save(args[0],new_model()); return
    if cmd=='migrate': save(args[1],import_v1(args[0])); return
    if cmd=='dashboard': return dashboard(*args)
    if cmd=='connections': return connections(*args)
    if cmd=='logsummary': return log_summary()
    if cmd=='get':
        v=load(args[0])
        for k in args[1].split('.'): v=v[k]
        print(v); return
    m=load(args[0]); validation(m)
    if cmd=='list': return list_nodes(m)
    if cmd=='probe': return probe(m)
    if cmd=='compile': save(args[1],compile_config(m)); return
    if cmd=='export': return export(m,args[1])
    if cmd in {'ports','nodeports'}:
        entries=ports(m) if cmd=='ports' else sorted({(net,n['port']) for n in m['nodes'] if n['enabled'] for net in networks(n)})
        for net,p in entries: print(net,p)
        return
    if cmd=='netcheck': verify_dns(m); save(args[0],m); return
    if cmd=='preflight': return preflight(m)
    if cmd=='count':
        print(f"{sum(n['enabled'] for n in m['nodes'])}/{len(m['nodes'])}"); return
    if cmd=='verify-generated':
        if compile_config(m)!=load(args[1]): fail('检测到 config.json 在脚本外被修改。为保护自定义配置，暂停改动；请先备份并处理差异')
        return
    if cmd=='acme': acme_prompt(m,True)
    elif cmd=='loglevel': m['log_level']=['info','warn','debug'][choose('日志等级（debug 可能包含访问详情）',['info','warn','debug'])]
    elif cmd=='add':
        before=len(m['nodes'])
        while True:
            m['nodes'].append(node_prompt(m,args[1]))
            try: validation(m)
            except ValueError as e:
                m['nodes'].pop(); print('该节点未加入草稿：'+str(e)+'；已添加的其他节点保留。')
            if prompt('继续添加其他节点？y/N','N').lower()!='y': break
        if len(m['nodes'])==before: fail('本次没有新增节点')
    elif cmd=='edit':
        i=pick(m); m['nodes'][i]=node_prompt(m,args[1],m['nodes'][i])
    elif cmd=='toggle':
        i=pick(m); m['nodes'][i]['enabled']=not m['nodes'][i]['enabled']
    elif cmd=='delete':
        i=pick(m)
        if prompt('输入 DELETE 删除此节点')!='DELETE': fail('取消删除')
        del m['nodes'][i]
    elif cmd=='rotate':
        n=m['nodes'][pick(m)]
        if prompt('旧客户端凭据将失效；输入 ROTATE 确认')!='ROTATE': fail('取消重置')
        if 'password' in n: n['password']=password('',method=n.get('method'),rotate=True)
        if 'uuid' in n: n['uuid']=str(uuid.uuid4())
        if 'obfs' in n: n['obfs']=password('',rotate=True)
        if n['kind']=='reality':
            n['private_key'],n['public_key']=keypair(args[1]); n['short_id']=secrets.token_hex(4)
    else: fail('未知操作 '+cmd)
    validation(m); save(args[0],m)

if __name__=='__main__':
    try: main()
    except (ValueError,KeyError,OSError,EOFError,subprocess.SubprocessError) as e:
        print('错误：'+str(e),file=sys.stderr); sys.exit(1)
    except KeyboardInterrupt: print('\n已取消，未提交的编辑已丢弃。',file=sys.stderr); sys.exit(130)

PY_ENGINE
}
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
