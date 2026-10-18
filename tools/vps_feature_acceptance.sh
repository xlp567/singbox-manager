#!/usr/bin/env bash
# Only the user's named practice VPS. Uses isolated draft state and read-only live configuration.
set -Eeuo pipefail
[[ $(hostname) == node.example.com ]] || exit 1
ip -4 -o addr show scope global | grep -q '192.0.2.10/' || exit 1
[[ ${RESULT_DIR:-} == /root/sbm-v351-prebackup-* ]] || exit 1
# shellcheck disable=SC1091
source /root/singbox-manager.sh
require_host cli
[[ $(systemctl show x-ui -p MainPID --value) == 310831 && -d /proc/349403 ]] || exit 1
pid_before=$(systemctl show sing-box -p MainPID --value)
sha256sum /etc/sing-box/config.json /etc/sing-box/manager.json /opt/singbox-manager/current/sing-box /opt/singbox-manager/current/libcronet.so > "$RESULT_DIR/feature-before.sha256"
fixture=$(mktemp -d /var/lib/singbox-manager/feature-test.XXXXXX)
trap 'rm -rf -- "$fixture"' EXIT
STATE=$fixture
BACKUPS=$STATE/backups
mkdir -m 700 "$BACKUPS"
setup_tmp
engine draft-save "$CONF/manager.json" "$STATE/draft.json" "$CONF" preserve
before=$(engine draft-fingerprint "$STATE/draft.json")
action draft-purge <<< 'no' > "$RESULT_DIR/draft-purge-cancel.log"
[[ $(engine draft-fingerprint "$STATE/draft.json") == "$before" ]]
action draft-purge <<< 'DELETE' > "$RESULT_DIR/draft-purge.log"
[[ ! -e $STATE/draft.json && ! -e $STATE/discarded-drafts ]]
engine draft-save "$CONF/manager.json" "$STATE/draft.json" "$CONF" preserve
action draft-discard <<< 'yes' > "$RESULT_DIR/draft-archive.log"
[[ $(find "$STATE/discarded-drafts" -type f | wc -l) == 1 ]]
action draft-archives-purge <<< 'DELETE' > "$RESULT_DIR/draft-archives-purge.log"
[[ $(find "$STATE/discarded-drafts" -type f | wc -l) == 0 ]]
engine audit-verify "$STATE/audit.jsonl" --json > "$RESULT_DIR/feature-audit.json"
sha256sum -c "$RESULT_DIR/feature-before.sha256" > "$RESULT_DIR/feature-hashes-verified.log"
[[ $(systemctl show sing-box -p MainPID --value) == "$pid_before" ]]
[[ $(systemctl show x-ui -p MainPID --value) == 310831 && -d /proc/349403 ]]
python3 - "$RESULT_DIR/feature-results.json" "$pid_before" <<'PY'
import json,pathlib,sys
pathlib.Path(sys.argv[1]).write_text(json.dumps({'draft_purge_cancel':'PASS','draft_permanent_delete_no_archive':'PASS',
 'archived_drafts_permanent_delete':'PASS','live_config_and_runtime_unchanged':True,'sing_box_pid_unchanged':True,
 'sing_box_pid':int(sys.argv[2]),'protected_original_user_drafts':'untouched; isolated private fixture',
 'x_ui_pid':310831,'xray_pid':349403},indent=2)+'\n')
PY
printf '%s\n' 'PASS permanent draft deletion and archive cleanup; live files and PID unchanged'
