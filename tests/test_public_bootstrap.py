import importlib.util
import io
import json
import pathlib
import tempfile
import unittest
import urllib.error
from unittest.mock import patch
from common import ROOT
from test_bootstrap import b,content

spec=importlib.util.spec_from_file_location('public_bootstrap',ROOT/'tools/public_bootstrap.py')
p=importlib.util.module_from_spec(spec);spec.loader.exec_module(p)


class PublicBootstrap(unittest.TestCase):
    def test_anonymous_entry_pins_installer_and_passes_empty_token(self):
        sha='a'*40;payload=b'assert BOOTSTRAP_TOKEN == ""\nassert BOOTSTRAP_COMMIT == "'+sha.encode()+b'"\n'
        with patch.object(p,'read',side_effect=[{'sha':sha},content(payload)]) as read:p.launch()
        self.assertEqual(read.call_args_list[1].args,('/contents/install.py?ref='+sha,))

    def test_public_request_never_adds_authorization(self):
        response=unittest.mock.MagicMock();response.__enter__.return_value.read.return_value=b'{"sha":"ok"}'
        opener=unittest.mock.Mock();opener.open.return_value=response
        with patch.object(p.urllib.request,'build_opener',return_value=opener):self.assertEqual(p.read('/commits/main'),{'sha':'ok'})
        self.assertIsNone(opener.open.call_args.args[0].get_header('Authorization'))
        with self.assertRaises(ValueError):p.NoRedirect().redirect_request(None)
        with self.assertRaises(ValueError):p.read('https://untrusted.example/')

    def test_corrupt_public_installer_never_runs(self):
        item=content(b'raise RuntimeError("must not execute")');item['sha']='0'*40
        with patch.object(p,'read',side_effect=[{'sha':'a'*40},item]):
            with self.assertRaisesRegex(ValueError,'摘要不符'):p.launch()

    def test_api_permission_or_rate_limit_is_clear_and_does_not_prompt(self):
        opener=unittest.mock.Mock();opener.open.side_effect=urllib.error.HTTPError(p.API,403,'',{},None)
        with patch.object(p.urllib.request,'build_opener',return_value=opener):
            with self.assertRaisesRegex(ValueError,'HTTP 403'):p.read('/commits/main')

    def test_generated_public_shell_contains_tested_source_and_short_command(self):
        wrapper=(ROOT/'install.sh').read_text();command=(ROOT/'新服务器一键安装命令.txt').read_text()
        self.assertIn((ROOT/'tools/public_bootstrap.py').read_text(),wrapper)
        self.assertEqual(len(command.splitlines()),1);self.assertLess(len(command.strip()),110)
        self.assertIn('https://raw.githubusercontent.com/xlp567/singbox-manager/main/install.sh',command)
        self.assertNotIn('getpass',wrapper);self.assertNotIn('Authorization',wrapper)

    def test_fresh_public_install_saves_source_but_creates_no_credential(self):
        with tempfile.TemporaryDirectory() as temp:
            path=pathlib.Path(temp).resolve();stage=path/'stage';stage.mkdir(mode=0o700);root=path/'root';root.mkdir();binary=path/'bin';binary.mkdir()
            def request(endpoint,token):
                self.assertEqual(token,'')
                name='singbox-manager.sha256' if 'sha256' in endpoint else 'singbox-manager.sh'
                return content((ROOT/name).read_bytes())
            with patch.object(b,'request',side_effect=request):b.prepare(stage,'','a'*40)
            result=b.install(stage,'','a'*40,root,binary/'sbm',path/'state')
            self.assertFalse((path/'state/github-token').exists())
            self.assertEqual(json.loads((path/'state/update-source.json').read_text()),{'repository':'xlp567/singbox-manager','branch':'main'})
            self.assertTrue((binary/'sbm').is_file());self.assertNotIn('token',json.dumps(result))


if __name__=='__main__':unittest.main()
