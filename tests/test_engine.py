import base64
import copy
import hashlib
import io
import json
import os
import pathlib
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch
from common import ROOT, engine as e, legacy_engine, model
from sbm.protocols import ADAPTERS, registry
from sbm.protocols.base import Adapter, METHODS


class Compatibility(unittest.TestCase):
    def setUp(self):
        self.m = model()
        self.old = legacy_engine()

    def test_all_nine_server_templates_exact_v24(self):
        def same_protocols(new,old):
            self.assertIn('rules',new['route'])
            new=copy.deepcopy(new);new.pop('dns');new['route']={'final':'direct'}
            self.assertEqual(new,old)
        same_protocols(e.compile_config(self.m), self.old.compile_config(self.m))
        for node in self.m['nodes']:
            with self.subTest(kind=node['kind']):
                m = copy.deepcopy(self.m); m['nodes'] = [node]
                same_protocols(e.compile_config(m), self.old.compile_config(m))

    def test_all_nine_client_configs_and_uris_exact_v24(self):
        for n in self.m['nodes']:
            with self.subTest(kind=n['kind']):
                self.assertEqual(e.client_node(n), self.old.client_node(n))
                self.assertEqual(e.uri(n), self.old.uri(n))

    def test_exports_exact_v24_including_permissions(self):
        with tempfile.TemporaryDirectory() as td:
            a, b = pathlib.Path(td)/'new', pathlib.Path(td)/'old'
            e.export(self.m, a); self.old.export(self.m, b)
            for p in a.iterdir():
                self.assertEqual(p.read_bytes(), (b/p.name).read_bytes())
                self.assertEqual(p.stat().st_mode & 0o777, 0o600)

    def test_disabled_and_empty_models(self):
        for n in self.m['nodes']: n['enabled'] = False
        new=e.compile_config(self.m);new.pop('dns');new['route']={'final':'direct'}
        self.assertEqual(new, self.old.compile_config(self.m))
        self.assertEqual(e.ports(self.m), [])
        new=e.compile_config(e.new_model());new.pop('dns');new['route']={'final':'direct'}
        self.assertEqual(new, self.old.compile_config(self.old.new_model()))

    def test_v1_migration_exact_roundtrip(self):
        self.m['nodes'] = [n for n in self.m['nodes'] if n['kind'] in {'anytls','hysteria2'}]
        with tempfile.TemporaryDirectory() as td:
            p = pathlib.Path(td)/'config.json'; e.save(p, self.old.compile_config(self.m))
            migrated=e.import_v1(p);self.assertEqual(e.compile_config(migrated)['inbounds'],e.load(p)['inbounds'])
            self.assertIn('rules',e.compile_config(migrated)['route'])
            c = e.load(p); c['route']['rules'] = []; e.save(p,c)
            with self.assertRaises(ValueError): e.import_v1(p)

    def test_all_shadowsocks_methods_and_ipv6_uris(self):
        n = self.m['nodes'][7]
        for method in METHODS:
            n['method'] = method
            n['password'] = base64.b64encode(b'k' * (16 if method == METHODS[0] else 32)).decode()
            n['server'] = '2001:db8::1'
            with self.subTest(method=method):
                self.assertEqual(e.uri(n), self.old.uri(n)); e.validation(self.m)

    def test_no_reality_private_key_in_exports(self):
        with tempfile.TemporaryDirectory() as td:
            e.export(self.m, td)
            for p in pathlib.Path(td).iterdir(): self.assertNotIn('A'*43,p.read_text())

    def test_draft_v24_read_and_changed_config_blocked(self):
        with tempfile.TemporaryDirectory() as td:
            conf=pathlib.Path(td); draft=conf/'draft.json'; out=conf/'model.json'
            self.old.save(draft, {'model':self.m,'base':self.old.draft_fingerprint(conf),'mode':'preserve'})
            with patch('sys.argv',['engine','draft-load',str(draft),str(conf),str(out)]): e.main()
            self.assertEqual(e.load(out),self.m)
            e.save(conf/'config.json',{})
            with patch('sys.argv',['engine','draft-load',str(draft),str(conf),str(out)]):
                with self.assertRaises(ValueError): e.main()

    def test_hand_edited_generated_config_blocked(self):
        with tempfile.TemporaryDirectory() as td:
            p=pathlib.Path(td); e.save(p/'model',self.m); c=e.compile_config(self.m)
            c['route']['rules']=[]; e.save(p/'config',c)
            with patch('sys.argv',['engine','verify-generated',str(p/'model'),str(p/'config')]):
                with self.assertRaises(ValueError): e.main()


class Validation(unittest.TestCase):
    def assertInvalid(self, change):
        m=model(); change(m)
        with self.assertRaises((ValueError,KeyError)): e.validation(m)

    def test_schema(self): self.assertInvalid(lambda m:m.update(schema=3))
    def test_unknown_kind(self): self.assertInvalid(lambda m:m['nodes'][0].update(kind='external'))
    def test_duplicate_id(self): self.assertInvalid(lambda m:m['nodes'][1].update(id=m['nodes'][0]['id']))
    def test_tcp_conflict(self): self.assertInvalid(lambda m:m['nodes'][2].update(port=8443))
    def test_udp_conflict(self): self.assertInvalid(lambda m:m['nodes'][6].update(port=1443))
    def test_tcp_udp_can_share_number(self):
        m=model(); m['nodes'][1]['port']=8443; e.validation(m)
    def test_acme_conflict(self): self.assertInvalid(lambda m:m['nodes'][0].update(port=80))
    def test_string_port(self): self.assertInvalid(lambda m:m['nodes'][0].update(port='8443'))
    def test_bool_port(self): self.assertInvalid(lambda m:m['nodes'][0].update(port=True))
    def test_invalid_uuid(self): self.assertInvalid(lambda m:m['nodes'][3].update(uuid='bad'))
    def test_invalid_password(self): self.assertInvalid(lambda m:m['nodes'][0].update(password='x\ny'))
    def test_short_legacy_password_is_preserved(self):
        m=model(); m['nodes'][0]['password']='legacy'; e.validation(m)
    def test_invalid_bbr(self): self.assertInvalid(lambda m:m['nodes'][1].update(bbr='unknown'))
    def test_invalid_ws(self): self.assertInvalid(lambda m:m['nodes'][5].update(path='not-a-path'))
    def test_invalid_reality(self): self.assertInvalid(lambda m:m['nodes'][4].update(short_id='x'))
    def test_invalid_acme(self): self.assertInvalid(lambda m:m['acme'].update(challenge='dns'))
    def test_invalid_ss2022_key(self):
        self.assertInvalid(lambda m:m['nodes'][7].update(method=METHODS[0],password='bad'))
    def test_missing_credential(self):
        self.assertInvalid(lambda m:m['nodes'][0].pop('password'))
    def test_ss_unavailable_fails_closed(self):
        with patch.object(e.subprocess,'run',side_effect=FileNotFoundError()):
            with self.assertRaises(ValueError): e.preflight(model())
    def test_ss_nonzero_fails_closed(self):
        with patch.object(e.subprocess,'run',side_effect=subprocess.CalledProcessError(1,'ss')):
            with self.assertRaises(ValueError): e.preflight(model())
    def test_external_listener_does_not_get_ignored_if_singbox_shares_port(self):
        with patch.object(e,'system_listeners',return_value={('tcp',8443):'sing-box,xray'}):
            with self.assertRaises(ValueError): e.preflight(model())
    def test_external_listener_and_suggestion(self):
        parse=e.port_parser(model(),'anytls','new',{('tcp',8444):'xray'})
        self.assertEqual(e.suggest_port(parse,8443),8445)


class ArchitectureAndBackups(unittest.TestCase):
    def test_extension_uses_registry_without_core_changes(self):
        class Extra(Adapter):
            kind='extra'; label='Example'; default_port=12345; tls=False; username=False
        adapter=Extra()
        with patch.dict(ADAPTERS,{'extra':adapter}):
            m=e.new_model(); m['nodes']=[{'id':'extra','kind':'extra','name':'Example','port':12345,'server':'192.0.2.1','enabled':True}]
            self.assertEqual(e.compile_config(m)['inbounds'][0]['type'],'extra')
            self.assertEqual(e.networks(m['nodes'][0]),['tcp'])
    def test_duplicate_registry_and_bad_api(self):
        with self.assertRaises(ValueError): registry([ADAPTERS['anytls']]*2)
        class Bad(Adapter): api_version=99
        with self.assertRaises(ValueError): registry([Bad()])
    def test_manifest_detects_tamper_and_added_file(self):
        with tempfile.TemporaryDirectory() as td:
            p=pathlib.Path(td); (p/'runtime.bin').write_bytes(b'runtime'); e.backup_seal(p); e.backup_verify(p)
            (p/'runtime.bin').write_bytes(b'bad')
            with self.assertRaises(ValueError): e.backup_verify(p)
            (p/'runtime.bin').write_bytes(b'runtime'); (p/'extra').write_text('x')
            with self.assertRaises(ValueError): e.backup_verify(p)
    def test_legacy_backup_accepted(self):
        with tempfile.TemporaryDirectory() as td: e.backup_verify(td)
    def test_manifest_detects_permission_and_symlink_change(self):
        with tempfile.TemporaryDirectory() as td:
            p=pathlib.Path(td); (p/'bin').write_text('x'); (p/'link').symlink_to('bin'); e.backup_seal(p)
            (p/'link').unlink(); (p/'link').symlink_to('other')
            with self.assertRaises(ValueError): e.backup_verify(p)
    def test_pending_is_atomic_and_private(self):
        with tempfile.TemporaryDirectory() as td:
            p=pathlib.Path(td)/'pending'; e.pending_write(str(p),'/backups/one')
            self.assertEqual(p.read_text(),'/backups/one\n'); self.assertEqual(p.stat().st_mode & 0o777,0o600)
            self.assertFalse(p.with_suffix('.new').exists())
    def test_download_sha_mismatch_and_tar_symlink_rejected(self):
        with tempfile.TemporaryDirectory() as td:
            p=pathlib.Path(td); arc=p/'archive'; arc.write_bytes(b'bad')
            e.save(p/'meta',{'sha256':'0'*64,'member':'sing-box'})
            with self.assertRaises(ValueError): e.extract_release(p/'meta',arc,p/'out')
            with tarfile.open(arc,'w:gz') as t:
                item=tarfile.TarInfo('sing-box'); item.type=tarfile.SYMTYPE; item.linkname='/etc/passwd'; t.addfile(item)
            e.save(p/'meta',{'sha256':hashlib.sha256(arc.read_bytes()).hexdigest(),'member':'sing-box'})
            with self.assertRaises(ValueError): e.extract_release(p/'meta',arc,p/'out')
    def test_semver_and_official_source_guard(self):
        self.assertGreater(e.vkey('1.15.0-alpha.10'),e.vkey('1.15.0-alpha.9'))
        self.assertGreater(e.vkey('1.15.0'),e.vkey('1.15.0-alpha.10'))
        with tempfile.TemporaryDirectory() as td:
            p=pathlib.Path(td); e.save(p/'releases',[{'tag_name':'v1.14.3','assets':[{'name':'sing-box-1.14.3-linux-amd64.tar.gz','browser_download_url':'https://evil.example/bin','digest':'sha256:'+'a'*64}]}])
            with self.assertRaises(ValueError): e.releases(p/'releases',p/'out','amd64')
    def test_standalone_bundle_runs_and_is_reproducible(self):
        before=(ROOT/'singbox-manager.sh').read_bytes()
        subprocess.run([sys.executable,str(ROOT/'tools/build.py')],check=True,stdout=subprocess.DEVNULL)
        self.assertEqual(before,(ROOT/'singbox-manager.sh').read_bytes())
        with tempfile.TemporaryDirectory() as td:
            p=pathlib.Path(td)/'engine.pyz'
            with p.open('wb') as out:
                subprocess.run(['bash','-c','source "$1"; emit_engine','bash',str(ROOT/'singbox-manager.sh')],stdout=out,check=True)
            result=subprocess.check_output([sys.executable,str(p),'protocols'],text=True)
            self.assertEqual(len(json.loads(result)),9)


import sys
if __name__=='__main__': unittest.main()
