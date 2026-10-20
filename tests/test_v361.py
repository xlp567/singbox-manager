"""Regression coverage for audit publication, retention and failed BBR recovery."""
import gzip
import ipaddress
import json
import multiprocessing
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
from common import ROOT
from sbm.core import audit,locations,network_policy,storage
import test_v360 as previous


def competing_writer(path,ready,done):
    audit.sync_directory=storage.sync_directory
    ready.set()
    for _ in range(3):audit.append(path,'action-start','writer-b','started')
    done.set()


def concurrent_reader(path,ready,done):
    ready.set();audit.verify(path);done.set()


def legacy_log(path,count=22,keep=20):
    """Small format-3 segments model v3.6.0's unsigned pruning boundary."""
    def row(sequence,previous_hash,event='action-start',**extra):
        result=dict(format=1,sequence=sequence,timestamp='2026-01-01T00:00:00+00:00',event=event,
                    action='fixture',result='started',snapshot='',previous=previous_hash)
        result.update(extra);result['hash']=audit.digest(result);return result
    rows=[row(1,'0'*64)];sealed=[]
    for index in range(count):
        data=('\n'.join(json.dumps(r,separators=(',',':')) for r in rows)+'\n').encode()
        name=path.name+'.20260101T000000Z-'+format(index,'08x')+'.gz'
        target=path.parent/name;target.write_bytes(gzip.compress(data,mtime=0));target.chmod(0o400);sealed.append(target)
        reference=dict(file=name,sha256=storage.file_digest(target),last_hash=rows[-1]['hash'],entries=len(rows))
        head=row(1,reference['last_hash'],'audit-rotate',format=3,previous_segment=reference)
        rows=[head,row(2,head['hash'])]
    path.write_text('\n'.join(json.dumps(r,separators=(',',':')) for r in rows)+'\n');path.chmod(0o600)
    for target in sealed[:-keep]:target.unlink()


class AuditBoundaries(unittest.TestCase):
    def setUp(self):
        td=tempfile.TemporaryDirectory();self.addCleanup(td.cleanup);self.folder=pathlib.Path(td.name);self.path=self.folder/'audit.jsonl'
        patcher=patch.object(audit,'ROTATE_ENTRIES',3);patcher.start();self.addCleanup(patcher.stop)

    def append(self,count):
        for _ in range(count):audit.append(self.path,'action-start','fixture','started')

    def head(self):return json.loads(self.path.read_text().splitlines()[0])

    def rows(self):
        rows=[json.loads(r) for r in self.path.read_text().splitlines()]
        for path in self.folder.glob('*.gz'):rows.extend(json.loads(r) for r in gzip.decompress(path.read_bytes()).decode().splitlines())
        return rows

    def test_two_processes_cannot_rotate_while_first_writer_prunes(self):
        self.append(3);ctx=multiprocessing.get_context('fork');ready=ctx.Event();done=ctx.Event()
        process=ctx.Process(target=competing_writer,args=(str(self.path),ready,done));calls=0;real_sync=audit.sync_directory
        def hook(directory):
            nonlocal calls
            real_sync(directory);calls+=1
            if calls==2:
                process.start();self.assertTrue(ready.wait(5));self.assertFalse(done.wait(.15))
        try:
            with patch.object(audit,'sync_directory',side_effect=hook):self.append(1)
            process.join(5);self.assertEqual(process.exitcode,0);self.assertTrue(done.is_set())
        finally:
            if process.pid and process.is_alive():process.terminate();process.join()
        self.assertEqual(sum(r['event']=='action-start' for r in self.rows()),7)
        report=audit.verify(self.path);self.assertTrue(report['valid']);self.assertFalse(report['history_truncated'])

    def test_reader_waits_until_replacement_pruning_and_append_finish(self):
        self.append(3);ctx=multiprocessing.get_context('fork');ready=ctx.Event();done=ctx.Event()
        process=ctx.Process(target=concurrent_reader,args=(str(self.path),ready,done));calls=0;real_sync=audit.sync_directory
        def hook(directory):
            nonlocal calls
            real_sync(directory);calls+=1
            if calls==2:
                process.start();self.assertTrue(ready.wait(5));self.assertFalse(done.wait(.15))
        try:
            with patch.object(audit,'sync_directory',side_effect=hook):self.append(1)
            process.join(5);self.assertEqual(process.exitcode,0);self.assertTrue(done.is_set())
        finally:
            if process.pid and process.is_alive():process.terminate();process.join()

    def test_lock_inode_is_stable_and_private_across_rotations(self):
        self.append(1);lock=self.path.with_name(self.path.name+'.lock');inode=lock.stat().st_ino
        self.append(15);self.assertEqual(lock.stat().st_ino,inode);self.assertEqual(lock.stat().st_mode&0o777,0o600)

    def test_paths_lists_the_persistent_lock_and_recovery_record(self):
        report=locations.inventory('/config',self.folder,'/runtime','/override','/exports','/data','/sbm','/manager','')
        paths={row['path'] for row in report['paths']}
        self.assertIn(str(self.folder/'audit.jsonl.lock'),paths)
        self.assertIn(str(self.folder/'bbr-original.conf'),paths)

    def test_symlink_lock_is_rejected_without_changing_target(self):
        target=self.folder/'unrelated';target.write_text('preserve')
        self.path.with_name(self.path.name+'.lock').symlink_to(target)
        with self.assertRaises(ValueError):self.append(1)
        self.assertEqual(target.read_text(),'preserve');self.assertFalse(self.path.exists())

    def test_missing_newest_segment_is_an_error_in_api_and_cli(self):
        self.append(7);(self.folder/self.head()['previous_segment']['file']).unlink()
        with self.assertRaisesRegex(ValueError,'缺失'):audit.verify(self.path)
        result=subprocess.run([sys.executable,'-c','from sbm.entrypoint import run; run()','audit-verify',str(self.path)],
                              env=dict(os.environ,PYTHONPATH=str(ROOT/'src')),capture_output=True,text=True)
        self.assertNotEqual(result.returncode,0);self.assertIn('缺失',result.stderr);self.assertNotIn('按记录的保留边界清理',result.stdout)

    def test_missing_middle_segment_is_not_a_pruning_boundary(self):
        self.append(9);latest=self.folder/self.head()['previous_segment']['file']
        prior=json.loads(gzip.decompress(latest.read_bytes()).decode().splitlines()[0])['previous_segment']
        (self.folder/prior['file']).unlink()
        with self.assertRaisesRegex(ValueError,'缺失'):audit.verify(self.path)

    def test_missing_current_log_cannot_silently_start_another_chain(self):
        self.append(5);self.path.unlink()
        for action in [lambda:audit.verify(self.path),lambda:self.append(1),lambda:audit.repair(self.path)]:
            with self.assertRaisesRegex(ValueError,'当前审计段缺失'):action()
        self.assertFalse(self.path.exists())

    def test_pruning_is_proven_by_the_hash_bound_current_header(self):
        with patch.object(audit,'KEEP_SEGMENTS',2):self.append(12)
        head=self.head();self.assertEqual(head['format'],4);self.assertIsNotNone(head['retention_boundary'])
        report=audit.verify(self.path);self.assertEqual(report['segments'],2);self.assertTrue(report['history_truncated'])
        self.assertTrue(report['retention_verified']);self.assertFalse(report['legacy_retention_unverified'])
        self.assertFalse((self.folder/head['retention_boundary']['file']).exists())

    def test_removing_a_retained_segment_still_fails_after_normal_pruning(self):
        with patch.object(audit,'KEEP_SEGMENTS',2):self.append(12)
        newest=self.folder/self.head()['previous_segment']['file'];newest.unlink()
        with self.assertRaisesRegex(ValueError,'缺失'):audit.verify(self.path)

    def test_retention_marker_is_included_in_the_header_hash(self):
        with patch.object(audit,'KEEP_SEGMENTS',2):self.append(12)
        lines=self.path.read_text().splitlines();head=json.loads(lines[0]);head['retention_boundary']=None
        lines[0]=json.dumps(head,separators=(',',':'));self.path.write_text('\n'.join(lines)+'\n')
        with self.assertRaisesRegex(ValueError,'损坏'):audit.verify(self.path)

    def test_interrupted_pruning_keeps_a_durable_valid_boundary(self):
        with patch.object(audit,'KEEP_SEGMENTS',2):
            self.append(7);unlink=pathlib.Path.unlink;observed=[]
            def fail_old_delete(path,*args,**kwargs):
                if path.suffix=='.gz':
                    observed.append(self.head()['retention_boundary']);raise OSError('injected cleanup interruption')
                return unlink(path,*args,**kwargs)
            with patch.object(pathlib.Path,'unlink',fail_old_delete),self.assertRaises(OSError):self.append(1)
            self.assertTrue(observed);self.assertTrue(audit.verify(self.path)['retention_verified'])
            self.append(4)
        self.assertEqual(len(list(self.folder.glob('*.gz'))),2);self.assertTrue(audit.verify(self.path)['valid'])

    def test_legacy_pruned_tail_is_reported_as_unverified_not_normal_pruning(self):
        legacy_log(self.path);report=audit.verify(self.path)
        self.assertEqual(report['segments'],20);self.assertTrue(report['legacy_retention_unverified']);self.assertFalse(report['retention_verified'])
        result=subprocess.run([sys.executable,'-c','from sbm.entrypoint import run; run()','audit-verify',str(self.path)],
                              env=dict(os.environ,PYTHONPATH=str(ROOT/'src')),capture_output=True,text=True)
        self.assertEqual(result.returncode,0);self.assertIn('无法核实',result.stdout);self.assertNotIn('已按记录',result.stdout)
        self.assertNotIn('审计链：通过',result.stdout)

    def test_legacy_latest_segment_loss_is_rejected(self):
        legacy_log(self.path,count=3);(self.folder/self.head()['previous_segment']['file']).unlink()
        with self.assertRaisesRegex(ValueError,'缺失'):audit.verify(self.path)

    def test_legacy_rotation_establishes_a_proven_boundary(self):
        legacy_log(self.path);self.append(2)
        self.assertEqual(self.head()['format'],4);report=audit.verify(self.path)
        self.assertTrue(report['retention_verified']);self.assertFalse(report['legacy_retention_unverified'])

    def test_repair_refuses_to_call_a_missing_history_complete(self):
        self.append(5);(self.folder/self.head()['previous_segment']['file']).unlink();before=self.path.read_bytes()
        with self.assertRaisesRegex(ValueError,'缺失'):audit.repair(self.path)
        self.assertEqual(self.path.read_bytes(),before)

    def test_repair_keeps_sealed_evidence_after_future_live_cleanup(self):
        self.append(7);segments={p.name:p.read_bytes() for p in self.folder.glob('*.gz')}
        self.path.write_bytes(self.path.read_bytes()[:-20]);report=audit.repair(self.path)
        archive=pathlib.Path(report['sealed_archive']);self.assertTrue(archive.is_dir())
        self.append(6)
        self.assertEqual({p.name:p.read_bytes() for p in archive.iterdir()},segments)
        self.assertTrue(audit.verify(self.path)['valid'])


FAIL_RESTORE=previous.SYSCTL_MOCK.replace("-w) printf '%s\\n'", "-w) [[ $2 != net.core.default_qdisc=pfifo_fast || ! -f $TEST_ROOT/fail-restore ]] || return 1; printf '%s\\n'")


class BbrFailedRecovery(previous.ShellCase):
    def state(self):return dict(line.split('=',1) for line in (self.p/'sysctl.state').read_text().split())

    def failed_enable(self):
        (self.p/'fail-sysctl-p').write_text('');(self.p/'fail-restore').write_text('')
        return self.run_bash(FAIL_RESTORE+'bbr_action',1)

    def test_failed_restore_keeps_record_and_does_not_claim_rollback(self):
        output=self.failed_enable();self.assertTrue((self.p/'state/bbr-original.conf').exists())
        self.assertIn('未能完全恢复',output);self.assertNotIn('已撤销',output)
        self.assertEqual(self.state()['net.core.default_qdisc'],'fq');self.assertFalse((self.p/'90-bbr.conf').exists())

    def test_next_invocation_recovers_without_overwriting_or_enabling(self):
        self.failed_enable();(self.p/'fail-restore').unlink();(self.p/'fail-sysctl-p').unlink()
        output=self.run_bash(FAIL_RESTORE+'bbr_action')
        self.assertIn('读回确认',output);self.assertFalse((self.p/'state/bbr-original.conf').exists());self.assertFalse((self.p/'90-bbr.conf').exists())
        self.assertEqual(self.state(),{'net.ipv4.tcp_congestion_control':'reno','net.core.default_qdisc':'pfifo_fast'})

    def test_cancel_pending_recovery_preserves_original_record(self):
        self.failed_enable();record=self.p/'state/bbr-original.conf';before=record.read_bytes();state=self.state()
        self.run_bash(FAIL_RESTORE+'bbr_action',answers='no\n')
        self.assertEqual(record.read_bytes(),before);self.assertEqual(self.state(),state)

    def test_failure_again_preserves_the_same_recovery_values(self):
        self.failed_enable();record=self.p/'state/bbr-original.conf';before=record.read_bytes()
        self.run_bash(FAIL_RESTORE+'bbr_action',1);self.assertEqual(record.read_bytes(),before)

    def test_successful_command_without_restored_values_is_not_accepted(self):
        (self.p/'fail-sysctl-p').write_text('')
        lying=previous.SYSCTL_MOCK.replace("-w) printf '%s\\n'", "-w) [[ $2 != net.core.default_qdisc=pfifo_fast ]] || return 0; printf '%s\\n'")
        output=self.run_bash(lying+'bbr_action',1)
        self.assertIn('未能完全恢复',output);self.assertTrue((self.p/'state/bbr-original.conf').exists())

    def test_normal_restore_does_not_reload_unrelated_system_settings(self):
        self.run_bash(previous.SYSCTL_MOCK+'bbr_action');self.run_bash(previous.SYSCTL_MOCK+'bbr_action')
        self.assertNotIn('system\n',(self.p/'sysctl.log').read_text())

    def test_failed_disable_keeps_record_for_a_recovery_attempt(self):
        self.run_bash(FAIL_RESTORE+'bbr_action');(self.p/'fail-restore').write_text('')
        output=self.run_bash(FAIL_RESTORE+'bbr_action',1)
        self.assertIn('恢复记录保留',output);self.assertTrue((self.p/'state/bbr-original.conf').exists());self.assertFalse((self.p/'90-bbr.conf').exists())


class PublicUnicast(unittest.TestCase):
    def rejected(self):
        return [ipaddress.IPv4Address(bytes([224,0,0,1])),ipaddress.IPv6Address(bytes([255,2]+[0]*13+[1])),
                ipaddress.ip_address('0.0.0.0'),ipaddress.ip_address('::'),ipaddress.ip_address('127.0.0.1'),
                ipaddress.ip_address('169.254.1.1'),ipaddress.ip_address('fe80::1'),
                ipaddress.IPv6Address(bytes([254,192]+[0]*13+[1]))]

    def test_non_unicast_and_local_addresses_are_rejected(self):
        for address in self.rejected():self.assertFalse(network_policy.is_public(address))

    def test_confirmed_command_cannot_save_multicast_or_unspecified_addresses(self):
        with tempfile.TemporaryDirectory() as state:
            for address in self.rejected():
                with self.assertRaises(ValueError):network_policy.confirmed_command(state,'add',str(address))
            self.assertFalse((pathlib.Path(state)/'public-addresses.json').exists())

    def test_detection_ignores_multicast_answers(self):
        for address in self.rejected()[:2]:
            with patch.object(network_policy.subprocess,'check_output',return_value=str(address)) as run:
                self.assertEqual(network_policy.detect_public(address.version,runner=run),(None,None))


if __name__=='__main__':unittest.main()
