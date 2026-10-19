import json
import os
import pathlib
import shutil
import subprocess
import tempfile
import unittest
from common import ROOT, engine, model, legacy_engine

BASH = shutil.which('bash')


class Transactions(unittest.TestCase):
    def setUp(self):
        self.td=tempfile.TemporaryDirectory(); self.p=pathlib.Path(self.td.name)
        for f in ['systemctl','ss']: (ROOT/'tests/mocks'/f).chmod(0o755)
        (self.p/'service.json').write_text(json.dumps({'active':True,'enabled':True}))
        m=model(); m['nodes']=[m['nodes'][7]]; m['nodes'][0]['port']=18388
        (self.p/'config').mkdir(); engine.save(self.p/'config/manager.json',m)
        engine.save(self.p/'config/config.json',engine.compile_config(m))
        self.old=(self.p/'config/manager.json').read_bytes()
        for name,ver in [('old','1.14.2'),('candidate','1.14.3')]:
            b=self.p/('runtime/releases/old/sing-box' if name=='old' else name)
            b.parent.mkdir(parents=True,exist_ok=True)
            b.write_text('#!/bin/sh\ncase "$1" in version) echo "sing-box version '+ver+'";; check) exit 0;; esac\n')
            b.chmod(0o755)
        (self.p/'runtime/current').symlink_to(self.p/'runtime/releases/old',target_is_directory=True)
        (self.p/'exports').mkdir(); (self.p/'state/exports').mkdir(parents=True)
        (self.p/'state/exports/old.txt').write_text('old export')
        (self.p/'systemd').mkdir()
        (self.p/'systemd/90-singbox-manager.conf').write_text('# Managed by singbox-manager.sh\nExecStart='+str(self.p/'runtime/current/sing-box')+' run\n')

    def tearDown(self): self.td.cleanup()

    def run_bash(self, script, expected=0):
        env=dict(os.environ,PROJECT=str(ROOT),TEST_ROOT=str(self.p),PYTHONDONTWRITEBYTECODE='1')
        r=subprocess.run([BASH,'-c','source "$PROJECT/tests/transaction_harness.sh"\n'+script],env=env,
                         input='yes\n'*10,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
        self.assertEqual(r.returncode,expected,r.stdout)
        return r.stdout

    def prepare(self):
        return '''cp "$CONF/manager.json" "$TMP/model.json"
python3 - "$TMP/model.json" <<'PY'
import json,sys
p=sys.argv[1];m=json.load(open(p));m['nodes'][0]['name']='new node';json.dump(m,open(p,'w'))
PY
'''

    def assertRestored(self):
        self.assertEqual((self.p/'config/manager.json').read_bytes(),self.old)
        self.assertIn('1.14.2',subprocess.check_output([str(self.p/'runtime/current/sing-box'),'version'],text=True))
        self.assertEqual(json.loads((self.p/'service.json').read_text()),{'active':True,'enabled':True})
        self.assertTrue((self.p/'state/exports/old.txt').exists())

    def test_successful_upgrade(self):
        self.run_bash(self.prepare()+'apply_draft "$TEST_ROOT/candidate"\n')
        self.assertEqual(engine.load(self.p/'config/manager.json')['nodes'][0]['name'],'new node')
        self.assertIn('1.14.3',subprocess.check_output([str(self.p/'runtime/current/sing-box'),'version'],text=True))
        self.assertFalse((self.p/'state/pending').exists()); self.assertFalse((self.p/'state/draft.json').exists())

    def test_restart_failure_rolls_back(self):
        self.run_bash(self.prepare()+'touch "$TEST_ROOT/fail-restart"\napply_draft "$TEST_ROOT/candidate"',1)
        self.assertRestored(); self.assertFalse((self.p/'state/pending').exists())

    def test_unhealthy_upgrade_rolls_back(self):
        self.run_bash(self.prepare()+'touch "$TEST_ROOT/fail-health"\napply_draft "$TEST_ROOT/candidate"',1)
        self.assertRestored(); self.assertFalse((self.p/'state/pending').exists())

    def test_failed_rollback_retains_pending_and_recovers_next_run(self):
        self.run_bash(self.prepare()+'touch "$TEST_ROOT/fail-all-restarts"\napply_draft "$TEST_ROOT/candidate"',1)
        self.assertTrue((self.p/'state/pending').exists())
        (self.p/'fail-all-restarts').unlink()
        self.run_bash('recover_pending')
        self.assertRestored(); self.assertFalse((self.p/'state/pending').exists())

    def test_pending_recovery_rejects_corrupt_backup_before_stop(self):
        self.run_bash('begin_transaction\nTX=""')
        backup=pathlib.Path((self.p/'state/pending').read_text().strip())
        (backup/'runtime.bin').write_text('tampered')
        before=(self.p/'service.log').read_text()
        self.run_bash('recover_pending',1)
        self.assertEqual((self.p/'service.log').read_text(),before)
        self.assertTrue((self.p/'state/pending').exists())

    def test_stopped_service_remains_stopped(self):
        (self.p/'service.json').write_text(json.dumps({'active':False,'enabled':False}))
        self.run_bash(self.prepare()+'apply_draft "$TEST_ROOT/candidate"')
        self.assertEqual(json.loads((self.p/'service.json').read_text()),{'active':False,'enabled':False})

    def test_cancellation_keeps_draft_and_original_service(self):
        self.run_bash(self.prepare()+'confirm() { return 1; }\napply_draft "$TEST_ROOT/candidate"')
        self.assertRestored(); self.assertTrue((self.p/'state/draft.json').exists())
        self.assertFalse((self.p/'state/pending').exists())

    def test_outside_edit_during_confirmation_is_not_overwritten(self):
        self.run_bash(self.prepare()+'''confirm() { echo '{"external":true}' >"$CONF/config.json"; return 0; }
apply_draft "$TEST_ROOT/candidate"''',1)
        self.assertEqual(engine.load(self.p/'config/config.json'),{'external':True})
        self.assertNotIn('stop sing-box',(self.p/'service.log').read_text() if (self.p/'service.log').exists() else '')

    def test_signal_rolls_back(self):
        output=self.run_bash('begin_transaction\nsystemctl stop sing-box\nkill -TERM $$',143)
        self.assertRestored(); self.assertFalse((self.p/'state/pending').exists(),output)

    def test_kill9_recovery(self):
        self.run_bash('begin_transaction\nsystemctl stop sing-box\nkill -KILL $$',-9)
        self.assertTrue((self.p/'state/pending').exists())
        self.run_bash('recover_pending')
        self.assertRestored(); self.assertFalse((self.p/'state/pending').exists())

    def test_manual_restart_failure_rolls_back(self):
        self.run_bash('touch "$TEST_ROOT/fail-restart"\nservice_action restart',1)
        self.assertRestored(); self.assertFalse((self.p/'state/pending').exists())

    def test_manual_start_failure_preserves_stopped_state(self):
        (self.p/'service.json').write_text(json.dumps({'active':False,'enabled':False}))
        self.run_bash('touch "$TEST_ROOT/fail-health"\nservice_action start',1)
        self.assertEqual(json.loads((self.p/'service.json').read_text()),{'active':False,'enabled':False})
        self.assertFalse((self.p/'state/pending').exists())

    def test_manual_stop_commits_after_inactive_and_zero_pid(self):
        self.run_bash('sleep() { :; }\nservice_action stop')
        self.assertEqual(json.loads((self.p/'service.json').read_text()),{'active':False,'enabled':True})
        self.assertEqual((self.p/'config/manager.json').read_bytes(),self.old)
        self.assertFalse((self.p/'state/pending').exists())
        log=(self.p/'service.log').read_text()
        self.assertEqual(log.count('show sing-box -p ActiveState --value'),5)
        self.assertEqual(log.count('show sing-box -p MainPID --value'),5)
        self.assertNotIn('restart sing-box',log)
        events=[json.loads(row)['event'] for row in (self.p/'state/audit.jsonl').read_text().splitlines()]
        self.assertIn('transaction-begin',events)
        self.assertIn('transaction-commit',events)

    def test_manual_stop_failure_restores_original_running_state(self):
        self.run_bash('touch "$TEST_ROOT/fail-stop"\nservice_action stop',1)
        self.assertRestored();self.assertFalse((self.p/'state/pending').exists())

    def test_manual_stop_success_without_stopping_rolls_back(self):
        self.run_bash('sleep() { :; }\ntouch "$TEST_ROOT/ignore-stop"\nservice_action stop',1)
        self.assertRestored();self.assertFalse((self.p/'state/pending').exists())

    def test_manual_stop_rejects_lingering_pid(self):
        self.run_bash('sleep() { :; }\ntouch "$TEST_ROOT/lingering-pid"\nservice_action stop',1)
        self.assertRestored();self.assertFalse((self.p/'state/pending').exists())

    def test_manual_stop_rejects_unreadable_service_state(self):
        self.run_bash('sleep() { :; }\ntouch "$TEST_ROOT/fail-show"\nservice_action stop',1)
        self.assertRestored();self.assertFalse((self.p/'state/pending').exists())

    def test_manual_stop_with_invalid_config_does_not_require_validation(self):
        (self.p/'config/config.json').write_text('{invalid')
        (self.p/'config/manager.json').write_text('{invalid')
        self.run_bash('sleep() { :; }\nservice_action stop')
        self.assertFalse(json.loads((self.p/'service.json').read_text())['active'])
        self.assertEqual((self.p/'config/config.json').read_text(),'{invalid')

    def test_manual_stop_without_runtime_and_already_inactive(self):
        (self.p/'runtime/current').unlink()
        (self.p/'service.json').write_text(json.dumps({'active':False,'enabled':False}))
        self.run_bash('sleep() { :; }\nservice_action stop')
        self.assertEqual(json.loads((self.p/'service.json').read_text()),{'active':False,'enabled':False})
        self.assertFalse((self.p/'runtime/current').exists())
        self.assertFalse((self.p/'state/pending').exists())

    def test_unknown_service_action_never_changes_service(self):
        self.run_bash('service_action disable',1)
        self.assertFalse((self.p/'service.log').exists())
        self.assertEqual(list((self.p/'state/backups').iterdir()),[])

    def test_corrupt_audit_does_not_block_stop_or_transaction_commit(self):
        (self.p/'state/audit.jsonl').write_text('{"partial":')
        out=self.run_bash('audit_record action-start started\nsleep() { :; }\nservice_action stop')
        self.assertIn('审计记录未写入',out)
        self.assertFalse(json.loads((self.p/'service.json').read_text())['active'])
        self.assertFalse((self.p/'state/pending').exists())
        self.assertEqual((self.p/'state/audit.jsonl').read_text(),'{"partial":')

    def legacy_config(self):
        config=legacy_engine().compile_config(engine.load(self.p/'config/manager.json'))
        engine.save(self.p/'config/config.json',config)
        return (self.p/'config/config.json').read_bytes()

    def test_legacy_security_status_does_not_change_config_or_service(self):
        original=self.legacy_config()
        output=self.run_bash('security_action status --json')
        self.assertIn('"requires_apply": true',output)
        self.assertEqual((self.p/'config/config.json').read_bytes(),original)
        self.assertFalse((self.p/'service.log').exists())

    def test_security_apply_never_overwrites_an_existing_draft(self):
        original=self.legacy_config();draft=self.p/'state/draft.json';draft.write_text('{"keep":"unfinished"}')
        self.run_bash('TEST_STAMP_SECURITY=1\nsecurity_action apply',1)
        self.assertEqual(draft.read_text(),'{"keep":"unfinished"}')
        self.assertEqual((self.p/'config/config.json').read_bytes(),original)
        self.assertFalse((self.p/'service.log').exists())

    def test_legacy_security_apply_preserves_nodes_and_commits_marker(self):
        original=self.legacy_config()
        before=engine.load(self.p/'config/manager.json')['nodes']
        self.run_bash('TEST_STAMP_SECURITY=1\nsecurity_action apply')
        current=engine.load(self.p/'config/manager.json')
        self.assertEqual(current['nodes'],before)
        self.assertEqual(current['security']['policy'],'public-only-v1')
        self.assertEqual(engine.load(self.p/'config/config.json'),engine.compile_config(current))
        backup=next((self.p/'state/backups').iterdir())
        self.assertEqual((backup/'config-dir/config.json').read_bytes(),original)
        self.assertFalse((self.p/'state/pending').exists())

    def test_cancel_security_apply_keeps_legacy_config_and_service(self):
        original=self.legacy_config()
        self.run_bash('TEST_STAMP_SECURITY=1\nconfirm(){ return 1; }\nsecurity_action apply')
        self.assertEqual((self.p/'config/config.json').read_bytes(),original)
        self.assertRestored();self.assertTrue((self.p/'state/draft.json').exists())
        self.assertNotIn('stop sing-box',(self.p/'service.log').read_text() if (self.p/'service.log').exists() else '')

    def test_failed_security_apply_rolls_back_legacy_config(self):
        original=self.legacy_config()
        self.run_bash('TEST_STAMP_SECURITY=1\ntouch "$TEST_ROOT/fail-restart"\nsecurity_action apply',1)
        self.assertEqual((self.p/'config/config.json').read_bytes(),original)
        self.assertRestored();self.assertFalse((self.p/'state/pending').exists())

    def test_deduplicated_backup_restores_after_old_runtime_is_pruned(self):
        self.run_bash('snapshot\nsaved=$SNAP\nrm -rf -- "$RUNTIME/releases/old"\nrestore_files "$saved"\nrestore_service "$saved"')
        self.assertRestored()

    def test_repeated_service_transactions_share_runtime_backup_inode(self):
        self.run_bash('sleep() { :; }\nservice_action stop\nservice_action start\nservice_action restart')
        backups=list((self.p/'state/backups').glob('*/runtime.bin'))
        self.assertEqual(len(backups),3)
        self.assertEqual(len({p.stat().st_ino for p in backups}),1)
        self.assertEqual(len(list((self.p/'state/runtime-objects').iterdir())),1)

    def test_interrupt_during_stop_check_restores_original_state(self):
        self.run_bash('sleep() { kill -TERM $$; }\nservice_action stop',143)
        self.assertRestored();self.assertFalse((self.p/'state/pending').exists())

    def test_runtime_library_restored_after_failed_upgrade(self):
        (self.p/'runtime/releases/old/libcronet.so').write_bytes(b'original library')
        (self.p/'libcronet.so').write_bytes(b'candidate library')
        self.run_bash(self.prepare()+'touch "$TEST_ROOT/fail-restart"\napply_draft "$TEST_ROOT/candidate"',1)
        self.assertRestored()
        self.assertEqual((self.p/'runtime/current/libcronet.so').read_bytes(),b'original library')

    def test_incompatible_runtime_does_not_stop_service(self):
        candidate=self.p/'candidate';candidate.write_text(candidate.read_text().replace('1.14.3','1.13.12'))
        self.run_bash(self.prepare()+'apply_draft "$TEST_ROOT/candidate"',1)
        self.assertRestored()
        self.assertNotIn('stop sing-box',(self.p/'service.log').read_text() if (self.p/'service.log').exists() else '')

    def test_audit_chain_contains_recovery_without_credentials(self):
        self.run_bash(self.prepare()+'touch "$TEST_ROOT/fail-restart"\napply_draft "$TEST_ROOT/candidate"',1)
        from sbm.core import audit
        self.assertTrue(audit.verify(self.p/'state/audit.jsonl')['valid'])
        rows=[json.loads(line) for line in (self.p/'state/audit.jsonl').read_text().splitlines()]
        self.assertIn('rollback',[row['event'] for row in rows])
        self.assertNotIn('secret',(self.p/'state/audit.jsonl').read_text())

    def test_draft_discard_does_not_change_live_nodes_runtime_or_service(self):
        self.run_bash('engine draft-save "$CONF/manager.json" "$STATE/draft.json" "$CONF" preserve\ndraft_discard_action')
        self.assertRestored();self.assertFalse((self.p/'state/draft.json').exists())
        self.assertEqual(len(list((self.p/'state/discarded-drafts').glob('*.json'))),1)
        self.assertFalse((self.p/'service.log').exists())

    def test_cancel_draft_discard_keeps_draft(self):
        self.run_bash('engine draft-save "$CONF/manager.json" "$STATE/draft.json" "$CONF" preserve\nconfirm() { return 1; }\ndraft_discard_action')
        self.assertRestored();self.assertTrue((self.p/'state/draft.json').exists())
        self.assertFalse((self.p/'state/discarded-drafts').exists())

    def test_protocol_definitions_are_restored_with_snapshot(self):
        folder=self.p/'state/protocols';folder.mkdir();(folder/'original.json').write_text('original data')
        self.run_bash('begin_transaction\nprintf "changed" >"$STATE/protocols/original.json"\nprintf "added" >"$STATE/protocols/new.json"\nexit 1',1)
        self.assertEqual((folder/'original.json').read_text(),'original data')
        self.assertFalse((folder/'new.json').exists())

    def test_permanent_draft_purge_does_not_change_live_service(self):
        self.run_bash('engine draft-save "$CONF/manager.json" "$STATE/draft.json" "$CONF" preserve\npermanent_delete_confirm(){ return 0; }\ndraft_purge_action')
        self.assertFalse((self.p/'state/draft.json').exists())
        self.assertFalse((self.p/'state/discarded-drafts').exists())
        self.assertRestored();self.assertFalse((self.p/'service.log').exists())

    def test_cancel_permanent_draft_purge_keeps_original(self):
        self.run_bash('engine draft-save "$CONF/manager.json" "$STATE/draft.json" "$CONF" preserve\npermanent_delete_confirm(){ return 1; }\ndraft_purge_action')
        self.assertTrue((self.p/'state/draft.json').exists());self.assertRestored()

    def test_clear_archives_when_current_draft_absent(self):
        self.run_bash('engine draft-save "$CONF/manager.json" "$STATE/draft.json" "$CONF" preserve\ndraft_discard_action\npermanent_delete_confirm(){ return 0; }\ndraft_archives_purge_action')
        self.assertFalse((self.p/'state/draft.json').exists())
        self.assertEqual(list((self.p/'state/discarded-drafts').iterdir()),[])
        self.assertRestored()


if __name__=='__main__': unittest.main()
