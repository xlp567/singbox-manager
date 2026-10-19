#!/usr/bin/env python3
"""Explicit real-systemd acceptance on a disposable unit, never sing-box.service.

Requires --allow-systemd-test and root on an authorized Linux test host. The
temporary unit/files are removed in finally. Evidence must remain private.
"""
import argparse
import hashlib
import json
import os
import pathlib
import secrets
import shutil
import socket
import subprocess
import sys
import tempfile

ROOT=pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'src'))
from sbm import engine

HARNESS=r'''
set -Eeuo pipefail
source "$PROJECT/singbox-manager.sh"
CONF=$FIXTURE/config
STATE=$FIXTURE/state
BACKUPS=$STATE/backups
RUNTIME=$FIXTURE/runtime
BIN=$RUNTIME/current/sing-box
DROP=/run/systemd/system/$TEST_UNIT.service.d/90-singbox-manager.conf
EXPORTS=$STATE/exports
DATA=$FIXTURE/data
mkdir -p "$BACKUPS" "$EXPORTS" "$DATA"
systemctl() {
    local value
    local -a rewritten=()
    for value in "$@"; do
        if [[ $value == sing-box ]]; then rewritten+=("$TEST_UNIT"); else rewritten+=("$value"); fi
    done
    command systemctl "${rewritten[@]}"
}
managed_unit_check(){ [[ $TEST_UNIT == sbm-validation-* && $CONF == "$FIXTURE/config" ]]; }
firewall_info(){ :; }
show_qr(){ :; }
confirm(){ return 0; }
engine_original(){ SBM_PROTOCOL_DIR="$STATE/protocols" python3 "$TMP/engine.pyz" "$@"; }
engine(){
    if [[ $1 == netcheck ]]; then
        PYTHONPATH="$PROJECT/src" python3 - "$2" <<'PY_POLICY'
import sys
from sbm import engine
from sbm.core import network_policy
path=sys.argv[1];m=engine.load(path);network_policy.stamp(m,network_policy.collect_local());engine.save(path,m)
PY_POLICY
    else engine_original "$@"; fi
}
setup_tmp
trap cleanup EXIT
trap 'exit 143' TERM
case $PHASE in
    cycle) service_action stop; service_action start; service_action restart;;
    migrate) security_action apply;;
    fault) prepare_model; apply_draft "$FIXTURE/broken-runtime";;
    crash) begin_transaction; systemctl stop sing-box; printf '{"test_interruption":true}\n' >"$CONF/config.json"; kill -KILL "$BASHPID";;
    recover) recover_pending;;
    audit-corrupt) service_action stop; service_action start;;
    audit-repair) engine audit-repair "$STATE/audit.jsonl"; engine audit-verify "$STATE/audit.jsonl" --json;;
    retention) for _ in {1..12}; do begin_transaction; commit_transaction; done;;
    *) exit 2;;
esac
'''


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary',required=True,type=pathlib.Path)
    parser.add_argument('--report',required=True,type=pathlib.Path)
    parser.add_argument('--allow-systemd-test',action='store_true')
    args=parser.parse_args()
    if not args.allow_systemd_test or sys.platform!='linux' or os.geteuid()!=0:
        parser.error('requires explicit --allow-systemd-test on an authorized Linux host as root')
    binary=args.binary.resolve();assert binary.is_file()
    unit='sbm-validation-'+secrets.token_hex(6);unitfile=pathlib.Path('/run/systemd/system')/(unit+'.service')
    assert not unitfile.exists()
    results=[]
    def ctl(*a,check=True):return subprocess.run(['systemctl',*a],check=check,capture_output=True,text=True)
    with tempfile.TemporaryDirectory(prefix='singbox-manager-validation-',dir='/var/lib') as folder:
        p=pathlib.Path(folder);p.chmod(0o700);conf=p/'config';conf.mkdir();state=p/'state';state.mkdir()
        runtime=p/'runtime';initial=runtime/'releases/initial';initial.mkdir(parents=True)
        shutil.copyfile(binary,initial/'sing-box');(initial/'sing-box').chmod(0o700);(runtime/'current').symlink_to(initial)
        with socket.socket() as available:available.bind(('127.0.0.1',0));port=available.getsockname()[1]
        node={'id':'fixture-ss','kind':'shadowsocks','name':'isolated acceptance','port':port,'enabled':True,
              'server':'192.0.2.10','method':'chacha20-ietf-poly1305','password':'isolated-example-password'}
        model=engine.new_model();model['nodes']=[node];engine.save(conf/'manager.json',model)
        legacy=engine.compile_config(model);legacy.pop('dns');legacy['route']={'final':'direct'};engine.save(conf/'config.json',legacy)
        unitfile.write_text('[Unit]\nDescription=Disposable singbox-manager acceptance\n[Service]\nType=simple\nExecStart='+str(runtime/'current/sing-box')+' -c '+str(conf/'config.json')+' run\nRestart=on-failure\nRestartSec=1\n')
        unitfile.chmod(0o600);harness=p/'harness.sh';harness.write_text(HARNESS)
        broken=p/'broken-runtime'
        broken.write_text('#!/bin/sh\ncase "$1" in check|version) exec '+str(initial/'sing-box')+' "$@";; *) exit 42;; esac\n');broken.chmod(0o700)
        args.report.parent.mkdir(parents=True,exist_ok=True)
        def run(phase,expected=0):
            env=dict(os.environ,PROJECT=str(ROOT),FIXTURE=str(p),TEST_UNIT=unit,PHASE=phase)
            r=subprocess.run(['bash',str(harness)],env=env,capture_output=True,timeout=180)
            log=args.report.with_name(args.report.stem+'-'+phase+'-'+str(len(results))+'.log');log.write_bytes(r.stdout+r.stderr);log.chmod(0o600)
            if r.returncode!=expected:raise RuntimeError('isolated phase failed: '+phase+' (private log retained)')
            results.append({'phase':phase,'passed':True})
        def live():assert ctl('is-active',unit).stdout.strip()=='active'
        def config_hash():return hashlib.sha256((conf/'config.json').read_bytes()).hexdigest()
        try:
            ctl('daemon-reload');ctl('start',unit)
            for _ in range(3):run('cycle');live()
            original_nodes=engine.load(conf/'manager.json')['nodes'];run('migrate');live()
            assert engine.load(conf/'manager.json')['nodes']==original_nodes
            assert engine.load(conf/'manager.json')['security']['policy']=='public-only-v1'
            digest=config_hash();run('fault',1);live();assert config_hash()==digest
            run('crash',-9);assert (state/'pending').exists()
            run('recover');live();assert config_hash()==digest and not (state/'pending').exists()
            auditfile=state/'audit.jsonl';raw=auditfile.read_bytes()[:-20];auditfile.write_bytes(raw)
            run('audit-corrupt');live();assert auditfile.read_bytes()==raw
            run('audit-repair');assert len(list(state.glob('audit.jsonl.corrupt-*')))==1
            run('retention');live()
            automatic=[d for d in (state/'backups').iterdir() if engine.load(d/'backup-kind.json')['kind']=='automatic']
            assert len(automatic)==10
            assert len({(d/'runtime.bin').stat().st_ino for d in automatic})==1
            report={'passed':True,'phases':results,'automatic_backups':10,'shared_runtime_inode':True,
                    'scope':'real disposable systemd unit; does not target existing sing-box, 3X-UI or Xray'}
            args.report.write_text(json.dumps(report,indent=2)+'\n');args.report.chmod(0o600);print(json.dumps(report))
        finally:
            ctl('stop',unit,check=False);ctl('reset-failed',unit,check=False)
            shutil.rmtree(unitfile.with_suffix('.service.d'),ignore_errors=True);unitfile.unlink(missing_ok=True);ctl('daemon-reload')
    return 0


if __name__=='__main__':raise SystemExit(main())
