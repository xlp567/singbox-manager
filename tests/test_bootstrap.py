import base64
import fcntl
import hashlib
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


def load(name,path):
    spec=importlib.util.spec_from_file_location(name,ROOT/path)
    result=importlib.util.module_from_spec(spec);spec.loader.exec_module(result);return result


b=load('first_install','install.py')
l=load('first_loader','tools/github_bootstrap.py')


def content(data):
    return {'type':'file','encoding':'base64','size':len(data),'content':base64.b64encode(data).decode(),
            'sha':hashlib.sha1(b'blob '+str(len(data)).encode()+b'\0'+data).hexdigest()}


class FirstInstallation(unittest.TestCase):
    def setUp(self):
        temp=tempfile.TemporaryDirectory();self.addCleanup(temp.cleanup);self.p=pathlib.Path(temp.name).resolve()
        self.stage=self.p/'stage';self.stage.mkdir(mode=0o700)
        self.root=self.p/'root';self.root.mkdir();self.shortcut=self.p/'bin/sbm';self.shortcut.parent.mkdir()
        self.state=self.p/'state';self.sha='a'*40;self.token='github_pat_test_readonly'
        self.script=(ROOT/'singbox-manager.sh').read_bytes();self.checksum=(ROOT/'singbox-manager.sha256').read_bytes()

    def prepare(self):
        calls=[]
        def request(path,token):
            calls.append((path,token))
            return content(self.checksum if 'sha256' in path else self.script)
        with patch.object(b,'request',side_effect=request):info=b.prepare(self.stage,self.token,self.sha)
        return info,calls

    def install(self):return b.install(self.stage,self.token,self.sha,self.root,self.shortcut,self.state)

    def test_real_bundle_first_install_pins_files_and_configures_future_updates(self):
        info,calls=self.prepare()
        live=self.p/'existing-x-ui-config';live.write_text('existing protected service')
        result=self.install()
        self.assertEqual(result['sha256'],info['sha256'])
        self.assertEqual((self.root/'singbox-manager.sh').read_bytes(),self.script)
        self.assertEqual(self.shortcut.read_bytes(),self.script)
        self.assertEqual((self.state/'github-token').read_text(),self.token)
        self.assertEqual((self.state/'github-token').stat().st_mode&0o777,0o600)
        self.assertEqual(json.loads((self.state/'update-source.json').read_text()),{'repository':b.REPOSITORY,'branch':'main'})
        self.assertNotIn(self.token,json.dumps(result));self.assertEqual(result['commit'],self.sha)
        self.assertTrue(all('?ref='+self.sha in path and token==self.token for path,token in calls))
        self.assertEqual(live.read_text(),'existing protected service')
        self.assertFalse((self.state/'pending').exists());self.assertFalse((self.state/'manager-update-pending.json').exists())

    def test_digest_mismatch_is_rejected_before_executing_downloaded_code(self):
        self.script+=b'\n# changed'
        with patch.object(b,'request',side_effect=lambda path,token:content(self.checksum if 'sha256' in path else self.script)),patch.object(b.subprocess,'run') as run:
            with self.assertRaisesRegex(ValueError,'SHA-256'):b.prepare(self.stage,self.token,self.sha)
        run.assert_not_called();self.assertFalse(self.shortcut.exists())

    def test_existing_manager_is_never_replaced_by_first_install(self):
        self.shortcut.write_text('previous manager')
        with self.assertRaisesRegex(ValueError,'菜单 30'):self.install()
        self.assertEqual(self.shortcut.read_text(),'previous manager');self.assertFalse(self.state.exists())

    def test_existing_credentials_and_symlink_targets_are_preserved(self):
        self.state.mkdir(mode=0o700);(self.state/'github-token').write_text('previous token')
        with self.assertRaisesRegex(ValueError,'已有'):self.install()
        self.assertEqual((self.state/'github-token').read_text(),'previous token')
        (self.state/'github-token').unlink();self.shortcut.symlink_to(self.p/'outside')
        with self.assertRaisesRegex(ValueError,'符号链接'):self.install()

    def test_busy_management_lock_does_not_write_any_target(self):
        self.state.mkdir(mode=0o700)
        with (self.state/'manager.lock').open('w') as lock:
            fcntl.flock(lock,fcntl.LOCK_EX)
            with self.assertRaisesRegex(ValueError,'已有管理脚本运行'):self.install()
        self.assertFalse(self.shortcut.exists());self.assertFalse((self.state/'github-token').exists())

    def test_pending_configuration_transaction_prevents_first_install(self):
        self.state.mkdir(mode=0o700);(self.state/'pending').write_text('original snapshot')
        with self.assertRaisesRegex(ValueError,'未完成事务'):self.install()
        self.assertFalse(self.shortcut.exists());self.assertEqual((self.state/'pending').read_text(),'original snapshot')

    def test_metadata_failure_rolls_back_both_new_scripts(self):
        self.prepare();atomic=b.atomic
        def write(path,*args):
            if pathlib.Path(path)==self.state/'github-token':raise OSError('injected write failure')
            return atomic(path,*args)
        with patch.object(b,'atomic',side_effect=write):
            with self.assertRaises(OSError):self.install()
        self.assertFalse(self.shortcut.exists());self.assertFalse((self.root/'singbox-manager.sh').exists())
        self.assertFalse((self.root/'singbox-manager.sha256').exists());self.assertFalse((self.state/'update-source.json').exists())

    def test_weak_state_permissions_and_invalid_commit_are_refused(self):
        self.state.mkdir();self.state.chmod(0o755)
        with self.assertRaisesRegex(ValueError,'权限 700'):self.install()
        with patch.object(b,'request') as request:
            with self.assertRaisesRegex(ValueError,'提交标识'):b.prepare(self.stage,self.token,'main')
        request.assert_not_called()

    def test_download_decoder_checks_type_size_encoding_and_blob_digest(self):
        good=content(b'hello');self.assertEqual(b.file_content(good),b'hello')
        for changes in [{'type':'symlink'},{'size':b.LIMIT+1},{'size':0},{'sha':'0'*40},{'content':'?'}]:
            with self.subTest(changes=changes),self.assertRaises(ValueError):b.file_content(dict(good,**changes))

    def test_http_permissions_errors_do_not_retry_or_disclose_secret(self):
        opener=unittest.mock.Mock();opener.open.side_effect=urllib.error.HTTPError(b.API,403,'private response',{},None)
        with patch.object(b.urllib.request,'build_opener',return_value=opener),patch.object(b.time,'sleep') as sleep:
            with self.assertRaisesRegex(ValueError,'HTTP 403') as error:b.request('/commits/main',self.token)
        self.assertNotIn(self.token,str(error.exception));self.assertEqual(opener.open.call_count,1);sleep.assert_not_called()
        with self.assertRaises(ValueError):b.NoRedirect().redirect_request(None)
        with self.assertRaises(ValueError):b.request('https://untrusted.example/',self.token)

    def test_temporary_github_failure_retries_once(self):
        response=unittest.mock.MagicMock();response.__enter__.return_value.read.return_value=b'{"sha":"ok"}'
        opener=unittest.mock.Mock();opener.open.side_effect=[urllib.error.HTTPError(b.API,504,'',{},None),response]
        with patch.object(b.urllib.request,'build_opener',return_value=opener),patch.object(b.time,'sleep'):
            self.assertEqual(b.request('/commits/main',self.token),{'sha':'ok'})
        self.assertEqual(opener.open.call_count,2)

    def test_bootstrap_loader_pins_installer_and_keeps_token_out_of_argv(self):
        payload=b'assert BOOTSTRAP_TOKEN == "github_pat_test_readonly"\nassert BOOTSTRAP_COMMIT == "'+self.sha.encode()+b'"\n'
        with patch.object(l.sys,'platform','linux'),patch.object(l.os,'geteuid',return_value=0),\
             patch.object(l.pathlib.Path,'exists',return_value=False),patch('builtins.open',return_value=io.StringIO()),\
             patch.object(l.getpass,'getpass',return_value=self.token),patch.object(l,'read',side_effect=[{'sha':self.sha},content(payload)]) as read:
            l.launch()
        self.assertEqual(read.call_args_list[1].args,('/contents/install.py?ref='+self.sha,self.token))
        self.assertNotIn(self.token,(ROOT/'新服务器一键安装命令.txt').read_text())

    def test_loader_corrupt_blob_is_refused_before_execution(self):
        bad=content(b'raise RuntimeError("should not execute")');bad['sha']='0'*40
        with patch.object(l.sys,'platform','linux'),patch.object(l.os,'geteuid',return_value=0),\
             patch.object(l.pathlib.Path,'exists',return_value=False),patch('builtins.open',return_value=io.StringIO()),\
             patch.object(l.getpass,'getpass',return_value=self.token),patch.object(l,'read',side_effect=[{'sha':self.sha},bad]):
            with self.assertRaisesRegex(ValueError,'摘要不符'):l.launch()

    def test_copy_once_command_matches_tested_loader_and_has_no_pipe_to_shell(self):
        command=(ROOT/'新服务器一键安装命令.txt').read_text()
        self.assertIn((ROOT/'tools/github_bootstrap.py').read_text(),command)
        self.assertNotIn('curl |',command);self.assertIn('python3 ca-certificates',command)
        subprocess.run(['bash','-n'],input=command,text=True,check=True)

    def test_cancel_does_not_install_or_store_credentials(self):
        terminal=unittest.mock.MagicMock();terminal.__enter__.return_value.readline.return_value='no\n'
        with patch.object(b,'host_check'),patch.object(b.pathlib.Path,'exists',return_value=False),\
             patch.object(b,'prepare',return_value={'version':'3.5.3'}),patch.object(b,'install') as install,\
             patch('builtins.open',return_value=terminal),patch('sys.stdout',new_callable=io.StringIO) as output:
            b.main(self.token,self.sha)
        install.assert_not_called();self.assertIn('已取消',output.getvalue());self.assertNotIn(self.token,output.getvalue())

    def test_host_check_rejects_local_mac_before_any_install(self):
        with patch.object(b.sys,'platform','darwin'),patch.object(b.subprocess,'run') as run:
            with self.assertRaisesRegex(ValueError,'Debian/Ubuntu'):b.host_check()
        run.assert_not_called()


if __name__=='__main__':unittest.main()
