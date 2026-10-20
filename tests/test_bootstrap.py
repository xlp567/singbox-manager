import fcntl
import importlib.util
import io
import json
import os
import pathlib
import subprocess
import tempfile
import unittest
import urllib.error
from unittest.mock import patch
from common import ROOT
from signed_release import SignedRelease


def load(name,path):
    spec=importlib.util.spec_from_file_location(name,ROOT/path)
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module);return module


b=load('first_install','install.py')
l=load('first_loader','tools/github_bootstrap.py')
c=load('install_command','tools/build_install_command.py')


class FirstInstallation(unittest.TestCase):
    def setUp(self):
        td=tempfile.TemporaryDirectory();self.addCleanup(td.cleanup);self.p=pathlib.Path(td.name).resolve()
        self.signed=SignedRelease(self.p/'assets',rekey_bundle=True)
        self.stage=self.p/'stage';self.stage.mkdir(mode=0o700);self.root=self.p/'root';self.root.mkdir()
        self.shortcut=self.p/'bin/sbm';self.shortcut.parent.mkdir();self.state=self.p/'state'
        self.token='github_pat_test_readonly';self.origin={'tag':self.signed.tag,'commit':self.signed.commit}
        trust=self.signed.activate(b);trust.__enter__();self.addCleanup(trust.close)

    def prepare(self,token=None):
        def request(path,credential):return self.signed.request(b.API+path,credential)
        with patch.object(b,'request',side_effect=request),patch.object(b,'asset_bytes',side_effect=self.signed.asset):
            self.origin=b.prepare(self.stage,self.token if token is None else token)
        return self.origin

    def install(self,token=None):return b.install(self.stage,self.token if token is None else token,self.origin,self.root,self.shortcut,self.state)

    def test_signed_first_install_and_stable_update_channel(self):
        info=self.prepare();protected=self.p/'protected-config';protected.write_text('unchanged')
        result=self.install();self.assertEqual(result['sha256'],info['sha256'])
        self.assertEqual(self.shortcut.read_bytes(),self.signed.files['singbox-manager.sh'])
        self.assertEqual((self.root/'singbox-manager.sh').read_bytes(),self.shortcut.read_bytes())
        self.assertEqual((self.state/'github-token').read_text(),self.token)
        self.assertEqual((self.state/'github-token').stat().st_mode&0o777,0o600)
        self.assertEqual(json.loads((self.state/'update-source.json').read_text()),{'repository':b.REPOSITORY,'channel':'stable'})
        self.assertEqual(protected.read_text(),'unchanged');self.assertTrue(result['signature_verified'])
        self.assertNotIn(self.token,json.dumps(result));self.assertFalse((self.state/'manager-update-pending.json').exists())

    def test_corrupt_download_does_not_execute_candidate_engine(self):
        name='singbox-manager.sh';data=self.signed.payload[name]
        self.signed.payload[name]=data[:-1]+bytes([data[-1]^1])
        with patch.object(b,'engine') as run:
            with self.assertRaisesRegex(ValueError,'摘要'):self.prepare()
        run.assert_not_called();self.assertFalse(self.shortcut.exists())

    def test_prepare_only_decodes_engine_without_executing_it(self):
        with patch.object(b,'engine') as run:self.prepare()
        run.assert_not_called();self.assertTrue((self.stage/'engine.pyz').is_file())

    def test_existing_manager_never_replaced(self):
        self.shortcut.write_text('previous')
        with self.assertRaisesRegex(ValueError,'菜单 30'):self.install()
        self.assertEqual(self.shortcut.read_text(),'previous');self.assertFalse(self.state.exists())

    def test_existing_credentials_and_symlinks_preserved(self):
        self.state.mkdir(mode=0o700);(self.state/'github-token').write_text('previous')
        with self.assertRaisesRegex(ValueError,'已有'):self.install()
        self.assertEqual((self.state/'github-token').read_text(),'previous')
        (self.state/'github-token').unlink();self.shortcut.symlink_to(self.p/'outside')
        with self.assertRaisesRegex(ValueError,'符号链接'):self.install()

    def test_busy_lock_does_not_write_targets(self):
        self.state.mkdir(mode=0o700)
        with (self.state/'manager.lock').open('w') as lock:
            fcntl.flock(lock,fcntl.LOCK_EX)
            with self.assertRaisesRegex(ValueError,'已有管理脚本运行'):self.install()
        self.assertFalse(self.shortcut.exists())

    def test_pending_transaction_prevents_install(self):
        self.state.mkdir(mode=0o700);(self.state/'pending').write_text('keep')
        with self.assertRaisesRegex(ValueError,'未完成事务'):self.install()
        self.assertEqual((self.state/'pending').read_text(),'keep');self.assertFalse(self.shortcut.exists())

    def test_metadata_failure_restores_both_new_targets(self):
        self.prepare();atomic=b.atomic
        def write(path,*args):
            if pathlib.Path(path)==self.state/'github-token':raise OSError('injected metadata failure')
            return atomic(path,*args)
        with patch.object(b,'atomic',side_effect=write),self.assertRaises(OSError):self.install()
        self.assertFalse(self.shortcut.exists());self.assertFalse((self.root/'singbox-manager.sh').exists())
        self.assertFalse((self.root/'singbox-manager.sha256').exists());self.assertFalse((self.state/'update-source.json').exists())

    def test_weak_permissions_and_moving_commit_are_refused(self):
        self.state.mkdir();self.state.chmod(0o755)
        with self.assertRaisesRegex(ValueError,'权限 700'):self.install()
        with patch.object(b,'request') as request:
            with self.assertRaisesRegex(ValueError,'正式 Release'):b.prepare(self.stage,self.token,'main')
        request.assert_not_called()

    def test_staging_tamper_is_refused_again_before_execution(self):
        self.prepare();p=self.stage/'singbox-manager.sh';p.write_bytes(p.read_bytes()+b'\n# tampered')
        with patch.object(b,'engine') as run,self.assertRaisesRegex(ValueError,'摘要'):self.install()
        run.assert_not_called();self.assertFalse(self.shortcut.exists())

    def test_http_permission_error_never_discloses_token(self):
        opener=unittest.mock.Mock();opener.open.side_effect=urllib.error.HTTPError(b.API,403,'',{},None)
        with patch.object(b.urllib.request,'build_opener',return_value=opener),patch.object(b.time,'sleep') as sleep:
            with self.assertRaisesRegex(ValueError,'HTTP 403') as error:b.request('/releases/latest',self.token)
        self.assertNotIn(self.token,str(error.exception));sleep.assert_not_called()
        with self.assertRaises(ValueError):b.request('/commits/main',self.token)

    def test_transient_metadata_failure_retries_once(self):
        response=io.BytesIO(b'{"ok":true}')
        opener=unittest.mock.Mock();opener.open.side_effect=[urllib.error.HTTPError(b.API,504,'',{},None),response]
        with patch.object(b.urllib.request,'build_opener',return_value=opener),patch.object(b.time,'sleep'):
            self.assertTrue(b.request('/releases/latest',self.token)['ok'])
        self.assertEqual(opener.open.call_count,2)

    def test_private_loader_reads_token_once_and_reuses_signed_bootstrap(self):
        with patch.object(l.sys,'platform','linux'),patch.object(l.os,'geteuid',return_value=0),\
             patch.object(l.getpass,'getpass',return_value=self.token) as prompt,patch.object(l.public_bootstrap,'launch') as launch:
            l.launch()
        prompt.assert_called_once();launch.assert_called_once_with(self.token)

    def test_private_command_is_one_line_and_contains_trusted_verifier(self):
        command=c.private_command();self.assertEqual(len(command.splitlines()),1)
        self.assertIn('python3 -c',command);self.assertIn('openssh-client',command)
        self.assertNotIn(self.token,command)
        subprocess.run(['bash','-n'],input=command,text=True,check=True)
        self.assertIn('verify_signature',c.embedded_loader());self.assertNotIn('/commits/main',c.embedded_loader())

    def test_cancel_before_install_never_runs_engine_or_saves_credentials(self):
        terminal=unittest.mock.MagicMock();terminal.__enter__.return_value.readline.return_value='no\n'
        info=dict(version='3.5.6',tag='v3.5.6',commit='a'*40)
        with patch.object(b,'host_check'),patch.object(b.pathlib.Path,'exists',return_value=False),\
             patch.object(b,'prepare',return_value=info),patch.object(b,'install') as install,\
             patch('builtins.open',return_value=terminal),patch('sys.stdout',new_callable=io.StringIO) as output:
            b.main(self.token)
        install.assert_not_called();self.assertIn('已取消',output.getvalue());self.assertNotIn(self.token,output.getvalue())

    def test_host_check_rejects_mac_before_install(self):
        with patch.object(b.sys,'platform','darwin'),patch.object(b.subprocess,'run') as run:
            with self.assertRaisesRegex(ValueError,'Debian/Ubuntu'):b.host_check()
        run.assert_not_called()


if __name__=='__main__':unittest.main()
