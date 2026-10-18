#!/usr/bin/env bash
# singbox-manager v3.0 — Debian / Ubuntu, Bash >=4, systemd
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
SBM_VERSION=3.0
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
engine() { python3 "$TMP/engine.pyz" "$@"; }
setup_tmp() {
    TMP=$(mktemp -d "$STATE/tmp.XXXXXX")
    emit_engine >"$TMP/engine.pyz"
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
    local current
    CANDIDATE=''
    disk_guard
    fetch_versions
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
    engine backup-seal "$dest"
    touch "$dest/.complete"
    SNAP=$dest
    say "备份已保存：$dest"
}
restore_files() {
    local src=$1 digest dest
    [[ -f $src/.complete ]] || return 1
    engine backup-verify "$src" || return 1
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
        if restore_files "$TX" && restore_service "$TX" && { [[ ! -f $TX/was-active ]] || health; }; then
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
    engine pending-write "$STATE/pending" "$SNAP"
    TX=$SNAP
}
commit_transaction() { engine pending-clear "$STATE/pending"; TX=''; }
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
    systemctl stop sing-box || return 1
    restore_files "$src" || return 1
    restore_service "$src" || return 1
    if [[ -f $src/was-active ]]; then health || return 1; fi
    engine pending-clear "$STATE/pending" || return 1
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
    # A human/another tool may edit files while the final confirmation is open.
    # Recheck the saved base before stopping any service.
    engine draft-load "$STATE/draft.json" "$CONF" "$TMP/checked-model.json"
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
service_action() {
    local command=$1 binary
    binary=$(active_binary) || die '尚未安装。'
    managed_unit_check
    "$binary" check -c "$CONF/config.json"
    begin_transaction
    systemctl "$command" sing-box
    health || die '服务未稳定运行，自动恢复之前状态。'
    commit_transaction
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
  upgrade     选择 / 升级官方运行版本（与菜单 10 相同）
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
        15) service_action start;;
        17) service_action restart;;
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
        status|versions|list|export|check|backup|restart|log|prune|shortcut|upgrade)
            require_host cli
            [[ ! -f $STATE/pending ]] || die '存在未完成事务；请先不带参数运行脚本，在菜单中完成恢复。'
            case $1 in
                status) action dash;;
                versions) action 11;;
                list) action 2;; export) action 9;; check) action 12;;
                backup) action 18;; restart) action 17;; log) action 13;;
                prune) action 24;; shortcut) action 25;;
                upgrade) action 10;;
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
    base64 -d <<'SBM_BUNDLE'
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
bWVzcy5weVBLBQYAAAAADgAOAKwDAAAXWAAAAAA=
SBM_BUNDLE
}
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
