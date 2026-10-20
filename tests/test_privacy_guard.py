import base64
import io
import json
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile
from common import ROOT

sys.path.insert(0,str(ROOT/'tools'))
from privacy_guard import check_manifest, scan_text
from audit_publication import scan_payload,scan_git


class PrivacyGuard(unittest.TestCase):
    def scan(self,text): return scan_text('fixture.txt',text)

    def test_documentation_addresses_are_allowed(self):
        self.assertEqual(self.scan('192.0.2.7 198.51.100.9 203.0.113.4 2001:db8::5 127.0.0.1 ::1'),[])

    def test_public_ipv4_and_escaped_address_are_blocked(self):
        value='.'.join(map(str,[11,22,33,44]))
        for text in (value,value.replace('.',r'\.'),value.replace('.',r'\\.')):
            self.assertTrue(self.scan(text))
            self.assertNotIn(value,json.dumps(self.scan(text)))

    def test_public_ipv6_is_blocked(self):
        self.assertTrue(self.scan(':'.join(['2606','4700','','1234'])))

    def test_private_keys_and_tokens_are_blocked(self):
        for text in ('-----BEGIN '+'PRIVATE KEY-----','-----BEGIN '+'ENCRYPTED PRIVATE KEY-----','ghp_'+'a'*36,'github_pat_'+'x'*80):
            result=self.scan(text)
            self.assertTrue(result);self.assertNotIn(text,json.dumps(result))

    def test_nonstandard_ssh_port_is_blocked(self):
        port=str(2000+222)
        for text in ('SSH port: '+port,'ssh -p '+port+' root@host.example','scp -P '+port+' file root@host.example:'):
            self.assertTrue(self.scan(text))
        self.assertEqual(self.scan('ssh -p 22 root@host.example'),[])
        self.assertTrue(self.scan(json.dumps({'ssh_port':2000+222})))

    def test_custom_host_url_is_blocked(self):
        self.assertTrue(self.scan('https://'+'private-node'+'.internal-domain.net/path'))
        self.assertEqual(self.scan('https://api.github.com/repos/x/y https://node.example.com'),[])
        self.assertTrue(self.scan(json.dumps({'server_name':'private-node'+'.internal-domain.net'})))

    def test_bare_node_domain_is_blocked_without_private_list(self):
        host='.'.join(['private-node','fixture-domain','cloud'])
        result=self.scan('node: '+host)
        self.assertTrue(any(item['category']=='unreviewed-bare-host' for item in result))
        self.assertNotIn(host,json.dumps(result))
        self.assertEqual(self.scan('node.example.com engine.new_model manager.json'),[])

    def test_extra_private_values_and_base64_are_blocked(self):
        private='test-fixture-credential'
        for text in (private,base64.b64encode(private.encode()).decode()):
            self.assertTrue(scan_text('fixture',text,[private]))

    def test_bundle_is_decoded_and_scanned(self):
        stream=io.BytesIO()
        with zipfile.ZipFile(stream,'w') as archive:
            archive.writestr('sbm/private.py','target='+'.'.join(map(str,[11,22,33,44])))
        text="emit_engine() {\n    base64 -d <<'SBM_BUNDLE'\n"+base64.b64encode(stream.getvalue()).decode()+"\nSBM_BUNDLE\n}\n"
        self.assertTrue(any('::sbm/private.py' in item['path'] for item in self.scan(text)))

    def test_invalid_bundle_is_rejected(self):
        self.assertTrue(self.scan("emit_engine() {\n    base64 -d <<'SBM_BUNDLE'\nAAAA\nSBM_BUNDLE\n}\n"))

    def test_nested_archives_and_private_paths_are_blocked(self):
        for path in ('backup.tar.gz','nested.zip','.cache/state.txt','../escape.txt','/root/secret.txt'):
            self.assertTrue(check_manifest([{'path':path,'content':'sample'}]))

    def test_publish_command_fails_before_creating_manifest(self):
        with tempfile.TemporaryDirectory() as folder:
            root=pathlib.Path(folder);(root/'tools').mkdir()
            for name in ('prepare_github.py','privacy_guard.py'):shutil.copy(ROOT/'tools'/name,root/'tools'/name)
            # Synthetic detector input only; no credentials or network access.
            synthetic_address='.'.join(map(str,[11,22,33,44]))
            (root/'README.md').write_text('target='+synthetic_address)
            out=root/'manifest.json'
            result=subprocess.run([sys.executable,str(root/'tools/prepare_github.py'),'--output',str(out)],capture_output=True,text=True)
            self.assertNotEqual(result.returncode,0);self.assertFalse(out.exists())
            self.assertNotIn(synthetic_address,result.stdout+result.stderr)

    def test_current_source_passes_and_raw_reports_are_excluded(self):
        with tempfile.TemporaryDirectory() as folder:
            out=pathlib.Path(folder)/'manifest.json'
            subprocess.run([sys.executable,str(ROOT/'tools/prepare_github.py'),'--output',str(out)],check=True,capture_output=True)
            files=json.loads(out.read_text());self.assertEqual(check_manifest(files),[])
            self.assertEqual([f['path'] for f in files if f['path'].startswith('reports/')],['reports/PUBLIC_VALIDATION.md'])

    def test_downloaded_archive_is_scanned_without_extracting(self):
        output=io.BytesIO()
        with zipfile.ZipFile(output,'w') as archive:
            archive.writestr('source/README.md','node='+'.'.join(map(str,[11,22,33,44])))
        result=scan_payload('release.zip',output.getvalue())
        self.assertTrue(result);self.assertIn('::source/README.md',result[0]['path'])

    def test_git_audit_checks_old_reachable_blobs(self):
        with tempfile.TemporaryDirectory() as folder:
            p=pathlib.Path(folder)
            def git(*args):return subprocess.check_output(['git','-C',str(p),*args],stderr=subprocess.DEVNULL)
            git('init');git('config','user.name','Test');git('config','user.email','test@example.com')
            (p/'README.md').write_text('node='+'.'.join(map(str,[11,22,33,44])))
            git('add','README.md');git('commit','-m','fixture')
            (p/'README.md').write_text('safe documentation');git('add','README.md');git('commit','-m','clean')
            stats,findings=scan_git(p/'.git')
            self.assertEqual(stats['commits'],2);self.assertTrue(findings)
