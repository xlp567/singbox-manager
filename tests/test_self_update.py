import base64
import hashlib
import json
import pathlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch
from common import ROOT
from sbm.core import self_update as u
from sbm.core.storage import file_digest,save


def script(path,version):
    data='#!/usr/bin/env bash\n# singbox-manager v'+version+'\ncase "${1:-}" in version) echo "singbox-manager v'+version+'";; help) echo "singbox-manager upgrade";; *) exit 90;; esac\n'
    path.write_text(data);return path


class ManagerUpdates(unittest.TestCase):
    def setUp(self):
        td=tempfile.TemporaryDirectory();self.addCleanup(td.cleanup);self.p=pathlib.Path(td.name)
        self.state=self.p/'state';self.state.mkdir();self.root=self.p/'root';self.root.mkdir()
        self.shortcut=self.p/'sbm';script(self.shortcut,'3.5');script(self.root/'singbox-manager.sh','3.5')
        self.old=self.shortcut.read_bytes();self.candidate=script(self.p/'candidate.sh','3.5.1')
        self.checksum=self.p/'candidate.sha256';self.checksum.write_text(file_digest(self.candidate)+'  singbox-manager.sh\n')

    def install(self):return u.install(self.candidate,self.checksum,self.state,self.root,self.shortcut)

    def test_local_upload_install_backs_up_both_scripts_no_service_control(self):
        run=subprocess.run
        with patch.object(u.subprocess,'run',wraps=run) as calls:report=self.install()
        self.assertTrue(report['changed']);self.assertEqual(self.shortcut.read_bytes(),self.candidate.read_bytes())
        self.assertEqual((pathlib.Path(report['backup'])/'1.sh').read_bytes(),self.old)
        self.assertTrue(all(c.args[0][0]=='bash' for c in calls.call_args_list))
        self.assertFalse((self.state/'manager-update-pending.json').exists())

    def test_identical_install_does_not_produce_more_backups(self):
        self.install();count=len(list((self.state/'manager-backups').iterdir()))
        self.assertFalse(self.install()['changed'])
        self.assertEqual(count,len(list((self.state/'manager-backups').iterdir())))

    def test_wrong_digest_and_broken_syntax_refused_before_backup(self):
        self.candidate.write_text(self.candidate.read_text()+'# changed\n')
        with self.assertRaises(ValueError):self.install()
        self.candidate.write_text('#!/usr/bin/env bash\n# singbox-manager v3.5.1\nif then\n')
        self.checksum.write_text(file_digest(self.candidate)+'  singbox-manager.sh\n')
        with self.assertRaises(ValueError):self.install()
        self.assertEqual(self.shortcut.read_bytes(),self.old)
        self.assertFalse((self.state/'manager-backups').exists())

    def test_partial_copy_failure_restores_originals_and_clears_marker(self):
        atomic=u.atomic_bytes;failed=False
        def copy(path,data,mode=0o700):
            nonlocal failed
            if pathlib.Path(path)==self.root/'singbox-manager.sh' and data==self.candidate.read_bytes() and not failed:
                failed=True;raise OSError('injected disk failure')
            return atomic(path,data,mode)
        with patch.object(u,'atomic_bytes',side_effect=copy):
            with self.assertRaises(OSError):self.install()
        self.assertEqual(self.shortcut.read_bytes(),self.old)
        self.assertEqual((self.root/'singbox-manager.sh').read_bytes(),self.old)
        self.assertFalse((self.state/'manager-update-pending.json').exists())

    def test_interrupted_update_recovers_from_pending_on_next_run(self):
        code='''import os,sys
from sbm.core import self_update as u
original=u.atomic_bytes
def atomic(path,data,mode=0o700):
 original(path,data,mode)
 if str(path)==sys.argv[4]+"/singbox-manager.sh":os._exit(78)
u.atomic_bytes=atomic
u.install(*sys.argv[1:])
'''
        import os
        r=subprocess.run(['python3','-c',code,*map(str,[self.candidate,self.checksum,self.state,self.root,self.shortcut])],env=dict(os.environ,PYTHONPATH=str(ROOT/'src')))
        self.assertEqual(r.returncode,78);self.assertTrue((self.state/'manager-update-pending.json').exists())
        self.assertTrue(u.recover(self.state,self.root,self.shortcut))
        self.assertEqual(self.shortcut.read_bytes(),self.old);self.assertEqual((self.root/'singbox-manager.sh').read_bytes(),self.old)

    def test_manual_rollback_is_itself_a_backed_up_install(self):
        report=self.install();temp=self.p/'stage';temp.mkdir()
        u.rollback_stage(self.state,report['backup'],self.root,self.shortcut,temp)
        rollback=u.install(temp/'singbox-manager.sh',temp/'singbox-manager.sha256',self.state,self.root,self.shortcut)
        self.assertEqual(rollback['version'],'3.5');self.assertEqual(self.shortcut.read_bytes(),self.old)
        self.assertEqual(len(list((self.state/'manager-backups').iterdir())),2)

    def test_corrupt_backup_prevents_recovery_and_retains_marker(self):
        r=self.install();backup=pathlib.Path(r['backup']);(backup/'1.sh').write_text('corrupt')
        save(self.state/'manager-update-pending.json',{'backup':str(backup)})
        with self.assertRaises(ValueError):u.recover(self.state,self.root,self.shortcut)
        self.assertTrue((self.state/'manager-update-pending.json').exists())

    def test_symlink_targets_and_backup_path_escape_rejected(self):
        self.shortcut.unlink();self.shortcut.symlink_to(self.p/'outside')
        with self.assertRaises(ValueError):self.install()
        with self.assertRaises(ValueError):u.restore(self.state,self.p,self.root,self.shortcut)

    def test_github_download_uses_one_fixed_commit_and_private_read_token(self):
        (self.state/'github-token').write_text('github_pat_readonly_example');(self.state/'github-token').chmod(0o600)
        dest=self.p/'download';dest.mkdir();calls=[];sha='a'*40
        def request(url,token):
            calls.append((url,token))
            if '/commits/' in url:return {'sha':sha}
            data=self.checksum.read_bytes() if '.sha256' in url else self.candidate.read_bytes()
            return {'type':'file','encoding':'base64','size':len(data),'content':base64.b64encode(data).decode()}
        with patch.object(u,'request_json',side_effect=request):r=u.fetch(self.state,dest)
        self.assertEqual(r['commit'],sha);self.assertEqual(r['version'],'3.5.1')
        self.assertTrue(all(token=='github_pat_readonly_example' for url,token in calls))
        self.assertTrue(all('?ref='+sha in url for url,token in calls[1:]))
        self.assertNotIn('github_pat',json.dumps(r))

    def test_github_mismatch_and_weak_token_permissions_fail_closed(self):
        token=self.state/'github-token';token.write_text('github_pat_readonly_example');token.chmod(0o644)
        with self.assertRaises(ValueError):u.fetch(self.state,self.p)
        with self.assertRaises(ValueError):u.request_json('https://example.com/','secret')
        with self.assertRaises(ValueError):u.NoRedirect().redirect_request(None,None,302,'',{},'https://example.com')

    def test_cli_update_entrypoints(self):
        code='source "$1"; require_host(){ :; }; action(){ printf "%s " "$@"; };shift;main "$@"'
        for args,want in [(['self-update','github'],'self-update github'),(['self-update','local','/root/new.sh'],'self-update local /root/new.sh')]:
            r=subprocess.check_output(['bash','-c',code,'bash',str(ROOT/'singbox-manager.sh')]+args,text=True)
            self.assertEqual(r.strip(),want)


if __name__=='__main__':unittest.main()
