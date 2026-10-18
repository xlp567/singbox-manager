#!/usr/bin/env bash
set -Eeuo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
python3 tools/build.py
bash -n singbox-manager.sh
shellcheck src/manager-core.sh src/core/*.sh singbox-manager.sh tests/transaction_harness.sh tools/vps_acceptance.sh tools/vps_feature_acceptance.sh tools/ssh_upgrade.sh tools/test.sh
python3 -m unittest discover -s tests -v
python3 - <<'PY'
import hashlib,pathlib
p=pathlib.Path('singbox-manager.sh')
assert hashlib.sha256(p.read_bytes()).hexdigest()==pathlib.Path('singbox-manager.sha256').read_text().split()[0]
print('PASS distribution SHA-256')
PY
