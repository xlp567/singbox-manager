import io
import json
import pathlib
import tempfile
import unittest
import urllib.error
from unittest.mock import patch
from common import ROOT
from test_bootstrap import b,c,load
from signed_release import SignedRelease

p=load('public_bootstrap',ROOT/'tools/public_bootstrap.py')


class PublicBootstrap(unittest.TestCase):
    def setUp(self):
        td=tempfile.TemporaryDirectory();self.addCleanup(td.cleanup);self.root=pathlib.Path(td.name).resolve()
        self.marker=self.root/'installer-ran'
        payload=('assert BOOTSTRAP_TOKEN == ""\nassert BOOTSTRAP_CONFIRMED\nwith open('+repr(str(self.marker))+',"w") as f:f.write("ran")\n').encode()
        self.fixture=SignedRelease(self.root/'assets',{'install.py':payload})
        trust=self.fixture.activate(p);trust.__enter__();self.addCleanup(trust.close)

    def launch(self,consent=True):
        def read(path,token=''):
            self.assertEqual(token,'');return self.fixture.request(p.API+path,token)
        with patch.object(p,'read',side_effect=read) as request,patch.object(p,'asset_bytes',side_effect=self.fixture.asset),patch.object(p,'consent',return_value=consent):
            p.launch()
        return request

    def test_signed_installer_executes_only_after_consent(self):
        calls=self.launch();self.assertTrue(self.marker.exists())
        self.assertEqual(calls.call_args_list[0].args,('/releases/latest',''))
        self.assertFalse(any('/commits/' in str(call) for call in calls.call_args_list))

    def test_decline_never_executes_even_a_validly_signed_installer(self):
        self.launch(False);self.assertFalse(self.marker.exists())

    def test_corrupt_installer_never_executes_or_prompts(self):
        data=self.fixture.payload['install.py'];self.fixture.payload['install.py']=data[:-1]+b'X'
        with patch.object(p,'consent') as consent,self.assertRaises(ValueError):self.launch()
        self.assertFalse(self.marker.exists())

    def test_public_metadata_request_has_no_authorization(self):
        response=io.BytesIO(b'{"ok":true}')
        opener=unittest.mock.Mock();opener.open.return_value=response
        with patch.object(p.urllib.request,'build_opener',return_value=opener):self.assertTrue(p.read('/releases/latest')['ok'])
        self.assertIsNone(opener.open.call_args.args[0].get_header('Authorization'))
        with self.assertRaises(ValueError):p.NoRedirect().redirect_request(None)
        with self.assertRaises(ValueError):p.read('/commits/main')

    def test_permission_error_does_not_prompt_for_token(self):
        opener=unittest.mock.Mock();opener.open.side_effect=urllib.error.HTTPError(p.API,403,'',{},None)
        with patch.object(p.urllib.request,'build_opener',return_value=opener),self.assertRaisesRegex(ValueError,'HTTP 403'):p.read('/releases/latest')

    def test_generated_wrapper_contains_pinned_verifier_and_short_command(self):
        self.assertIn(c.embedded_loader(),(ROOT/'install.sh').read_text())
        command=(ROOT/'新服务器一键安装命令.txt').read_text();self.assertEqual(len(command.splitlines()),1);self.assertLess(len(command.strip()),110)
        self.assertIn('https://github.com/xlp567/singbox-manager/releases/latest/download/install.sh',command)
        self.assertNotIn('getpass',(ROOT/'install.sh').read_text())

    def test_fresh_anonymous_install_creates_no_token_file(self):
        fixture=SignedRelease(self.root/'manager',rekey_bundle=True);stage=self.root/'stage';stage.mkdir()
        root=self.root/'root';root.mkdir();binary=self.root/'bin';binary.mkdir();state=self.root/'state'
        with fixture.activate(b),patch.object(b,'request',side_effect=lambda path,token:fixture.request(b.API+path,token)),patch.object(b,'asset_bytes',side_effect=fixture.asset):
            origin=b.prepare(stage,'');b.install(stage,'',origin,root,binary/'sbm',state)
        self.assertFalse((state/'github-token').exists());self.assertEqual(json.loads((state/'update-source.json').read_text())['channel'],'stable')


if __name__=='__main__':unittest.main()
