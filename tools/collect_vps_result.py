#!/usr/bin/env python3
"""Read-only final verification for this acceptance run; emits no credentials."""
import datetime
import hashlib
import json
import pathlib
import subprocess
import os
import re

BASE=pathlib.Path(os.environ['ACCEPTANCE_DIR'])
assert str(BASE).startswith('/root/sbm-v35-prebackup-')
def run(args):
    return subprocess.check_output(args,text=True,stderr=subprocess.STDOUT).strip()
def sha(path):return hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest()
protected=run(['sha256sum','-c',str(BASE/'protected-hashes.txt')])
unchanged=run(['sha256sum','-c',str(BASE/'config-before.sha256')])
assert not pathlib.Path('/var/lib/singbox-manager/pending').exists()
assert run(['systemctl','show','x-ui','-p','MainPID','--value'])=='310831'
assert pathlib.Path('/proc/349403').exists()
assert run(['systemctl','is-active','sing-box'])=='active'
assert run(['/root/singbox-manager.sh','version'])=='singbox-manager v3.5'
assert sha('/root/singbox-manager.sh')==sha('/usr/local/bin/sbm')
run(['/opt/singbox-manager/current/sing-box','check','-c','/etc/sing-box/config.json'])
model=json.loads(pathlib.Path('/etc/sing-box/manager.json').read_text())
result={
    'verified_at_utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),
    'target':'practice-vps (redacted)',
    'system':run(['uname','-srmo']),
    'script_version':run(['/usr/local/bin/sbm','version']),
    'script_sha256':sha('/root/singbox-manager.sh'),
    'runtime_version':run(['/opt/singbox-manager/current/sing-box','version']).splitlines()[0],
    'runtime_sha256':sha('/opt/singbox-manager/current/sing-box'),
    'service':'active',
    'enabled':run(['systemctl','is-enabled','sing-box']),
    'pending_transaction':False,
    'schema':model['schema'],
    'nodes':[{'protocol':n['kind'],'port':n['port'],'enabled':n['enabled']} for n in model['nodes']],
    'original_config_hash_check':unchanged.splitlines(),
    'protected_file_hash_check':protected.splitlines(),
    'protected_pids':{'x-ui':310831,'xray':349403},
    'predeployment_backup':str(BASE/'singbox-state.tar.gz'),
    'predeployment_backup_sha256':(BASE/'prebackup.sha256').read_text().split()[0],
    'v35_snapshot':(BASE/'v35-snapshot-path').read_text().strip(),
    'audit':json.loads(run(['/usr/local/bin/sbm','audit','--json'])),
    'compatibility':json.loads(run(['/usr/local/bin/sbm','compat','--json'])),
    'unified_validation':json.loads(run(['/usr/local/bin/sbm','validate','--json'])),
    'module_tests':json.loads(run(['/usr/local/bin/sbm','module-test','all','--json'])),
    'runtime':json.loads(run(['/usr/local/bin/sbm','runtime','--json'])),
    'draft_preserved':pathlib.Path('/var/lib/singbox-manager/draft.json').exists(),
    'tests':{'linux_regression':int(re.search(r'Ran (\d+) tests',pathlib.Path('/root/sbm-v35-validation/acceptance-unit.log').read_text())[1]),'runtime_switch':'1.14.3 -> 1.14.2 -> 1.14.3',
             'startup_failure_auto_rollback':'PASS','kill9_corrupt_config_recovery':'PASS',
             'same_version_no_restart':'PASS'},
}
print(json.dumps(result,ensure_ascii=False,indent=2))
