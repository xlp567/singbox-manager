#!/usr/bin/env bash
# Explicitly invoked, destructive acceptance tests for the user's practice VPS ONLY.
# Requires the pre-deployment backup and an exact public IP. Never run on production.
set -Eeuo pipefail
PROJECT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck disable=SC1091
source "$PROJECT/singbox-manager.sh"
set -Eeuo pipefail
# The authorized address lives only on the practice VPS (root-owned marker), never in the repository.
MARKER=/root/.sbm-practice-vps
[[ -f $MARKER && ! -L $MARKER && $(stat -c %u "$MARKER") == 0 ]] || die "缺少练手 VPS 标记文件 $MARKER。"
AUTHORIZED_IP=$(tr -d '[:space:]' < "$MARKER")
[[ $AUTHORIZED_IP =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || die '练手 VPS 标记文件内容无效。'
[[ ${EXPECTED_VPS_IP:-} == "$AUTHORIZED_IP" ]] || die '仅允许本次授权的练手 VPS。'
ip -4 -o addr show scope global | grep -qF " $AUTHORIZED_IP/" || die '本机 IP 不匹配练手 VPS。'
ORIGINAL=${ACCEPTANCE_DIR:?必须明确指定本次验收备份目录}
[[ $ORIGINAL == /root/sbm-v35-prebackup-* && $ORIGINAL != *'/../'* ]] || die '备份目录不匹配本次 v3.5 验收。'
[[ -s $ORIGINAL/singbox-state.tar.gz && -f $ORIGINAL/prebackup.sha256 ]] || die '缺少部署前备份。'
PHASE=${1:-}
case $PHASE in install|downgrade|upgrade|fault|crash|recover) ;; *) die '未知验收阶段。';; esac
require_host cli
if [[ $PHASE != recover && -f $STATE/pending ]]; then die '有未完成事务，必须先恢复。'; fi
setup_tmp
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
[[ $(systemctl show x-ui -p MainPID --value) == 310831 ]] || die '3X-UI 进程与初始记录不同，停止验收。'
[[ -d /proc/349403 ]] || die 'Xray 原进程不存在，停止验收。'
LOG=$ORIGINAL/acceptance-$PHASE.log
stage_exact() {
    fetch_versions
    python3 - "$TMP/catalog.json" "$TMP/selected.json" "$1" <<'PY'
import json,sys
catalog,out,version=sys.argv[1:]
rows=json.load(open(catalog))['all']
entry=next(r for r in rows if r['version']==version and not r['preview'])
with open(out,'w') as f:json.dump(entry,f)
PY
    stage_selected
}
case $PHASE in
    install)
        prepare_model
        engine compile "$TMP/model.json" "$TMP/config.json"
        cmp "$CONF/config.json" "$TMP/config.json"
        snapshot
        printf '%s\n' "$SNAP" >"$ORIGINAL/v35-snapshot-path"
        sha256sum -c "$ORIGINAL/config-before.sha256"
        install -m 700 "$PROJECT/singbox-manager.sh" /root/singbox-manager.sh
        install -m 600 "$PROJECT/singbox-manager.sha256" /root/singbox-manager.sha256
        install_shortcut
        /usr/local/bin/sbm version
        ;;
    downgrade|upgrade)
        prepare_model
        if [[ $PHASE == downgrade ]]; then stage_exact 1.14.2; else stage_exact 1.14.3; fi
        apply_draft "$CANDIDATE" >"$LOG" 2>&1
        say "PASS $PHASE: $(current_version)"
        ;;
    fault)
        prepare_model
        sha256sum "$CONF/config.json" "$CONF/manager.json" >"$ORIGINAL/config-prefault.sha256"
        active=$(readlink -f "$(active_binary)")
        # A deliberate bad runtime accepts config checks, but fails service startup.
        # Only this acceptance script can construct it; normal installs use official releases.
        python3 - "$TMP/broken-runtime" "$active" <<'PY'
import pathlib,shlex,sys
p=pathlib.Path(sys.argv[1]);active=shlex.quote(sys.argv[2])
p.write_text('#!/bin/sh\ncase "$1" in check|version) exec '+active+' "$@";; *) exit 42;; esac\n')
p.chmod(0o755)
PY
        apply_draft "$TMP/broken-runtime" >"$LOG" 2>&1
        die '故障注入没有触发失败，验收不通过。'
        ;;
    crash)
        sha256sum "$CONF/config.json" "$CONF/manager.json" >"$ORIGINAL/config-precrash.sha256"
        begin_transaction
        systemctl stop sing-box
        printf '{"deliberate_crash_test":true}\n' >"$CONF/config.json"
        say '故障测试：强制终止管理进程，下一步必须执行 recover。'
        kill -KILL "$BASHPID"
        ;;
    recover)
        recover_pending
        sha256sum -c "$ORIGINAL/config-precrash.sha256"
        say 'PASS interrupted transaction recovery'
        ;;
esac
[[ $(systemctl show x-ui -p MainPID --value) == 310831 && -d /proc/349403 ]] || die '受保护进程发生变化。'
