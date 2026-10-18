#!/usr/bin/env bash
# Every path and service command is redirected into TEST_ROOT; no host service is touched.
set -Eeuo pipefail
source "$PROJECT/singbox-manager.sh"
CONF=$TEST_ROOT/config
STATE=$TEST_ROOT/state
BACKUPS=$STATE/backups
RUNTIME=$TEST_ROOT/runtime
BIN=$RUNTIME/current/sing-box
DROP=$TEST_ROOT/systemd/90-singbox-manager.conf
EXPORTS=$STATE/exports
DATA=$TEST_ROOT/data
mkdir -p "$CONF" "$BACKUPS" "$RUNTIME/releases/old" "$EXPORTS" "$(dirname "$DROP")"
export MOCK_STATE=$TEST_ROOT/service.json
export MOCK_LOG=$TEST_ROOT/service.log
export PATH="$PROJECT/tests/mocks:$PATH"
disk_guard() { :; }
health() {
    if [[ -f $TEST_ROOT/fail-health ]]; then rm "$TEST_ROOT/fail-health"; return 1; fi
    systemctl is-active --quiet sing-box
}
firewall_info() { :; }
show_qr() { :; }
managed_unit_check() { :; }
# Portable install replacement for macOS test runs; production uses /usr/bin/install.
install() { python3 "$PROJECT/tests/mocks/install.py" "$@"; }
engine_real() { SBM_PROTOCOL_DIR="$STATE/protocols" python3 "$TMP/engine.pyz" "$@"; }
engine() {
    case $1 in netcheck) return 0;; *) engine_real "$@";; esac
}
setup_tmp
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
