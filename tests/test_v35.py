import copy
import hashlib
import json
import multiprocessing
import pathlib
import subprocess
import tempfile
import unittest
import tarfile
import io
from unittest.mock import patch
from common import ROOT, engine as e, model
from sbm.adapter_engine import PROTOCOL_ENGINE as pipeline
from sbm.core import audit
from sbm.protocols import ADAPTERS,registry
from sbm.protocols.base import Adapter
from sbm.runtime import Runtime,version_key
from sbm.core.storage import runtime_identity,runtime_copy_libraries,draft_summary,draft_discard


def audit_worker(path):audit.append(path,'action-start','18','started')


class ProtocolPipeline(unittest.TestCase):
    def runtime(self,version='1.14.3',tags='with_acme,with_quic,with_utls,with_naive_outbound'):
        td=tempfile.TemporaryDirectory();self.addCleanup(td.cleanup)
        p=pathlib.Path(td.name)/'sing-box'
        p.write_text('#!/bin/sh\nif [ "$1" = version ]; then\necho "sing-box version '+version+'"\necho "Tags: '+tags+'"\nelse exit 0; fi\n')
        p.chmod(0o755);return str(p)

    def test_all_nine_compatible_with_current_official_capabilities(self):
        r=pipeline.compatibility(model(),self.runtime(),e.validation)
        self.assertTrue(r['compatible']);self.assertEqual(len(r['nodes']),9)

    def test_too_old_version_rejected(self):
        r=pipeline.compatibility(model(),self.runtime('1.13.12'),e.validation)
        self.assertFalse(r['compatible']);self.assertTrue(all(not n['compatible'] for n in r['nodes']))

    def test_prerelease_below_minimum_is_rejected(self):
        self.assertLess(version_key('1.14.0-alpha.9'),version_key('1.14.0'))
        self.assertGreater(version_key('1.15.0-alpha.10'),version_key('1.15.0-alpha.9'))
        self.assertFalse(pipeline.compatibility(model(),self.runtime('1.14.0-alpha.9'),e.validation)['compatible'])

    def test_missing_acme_rejected(self):
        r=pipeline.compatibility(model(),self.runtime(tags='with_quic'),e.validation)
        self.assertFalse(r['compatible']);self.assertTrue(r['nodes'][7]['compatible'])

    def test_missing_quic_rejected(self):
        r=pipeline.compatibility(model(),self.runtime(tags='with_acme'),e.validation)
        self.assertFalse(r['compatible']);self.assertFalse(r['nodes'][1]['compatible'])

    def test_disabled_modules_do_not_block_current_runtime(self):
        m=model()
        for n in m['nodes']: n['enabled']=n['kind']=='shadowsocks'
        r=pipeline.compatibility(m,self.runtime(tags=''),e.validation)
        self.assertTrue(r['compatible']);self.assertFalse(r['nodes'][0]['compatible'])

    def test_unknown_runtime_version_is_not_guessed(self):
        with self.assertRaises(ValueError):Runtime(self.runtime('unknown'))

    def test_registry_checks_module_contract(self):
        class Bad(Adapter):kind='new';default_port=10000;minimum_runtime='latest'
        with self.assertRaises(ValueError):registry([Bad()])
        Bad.minimum_runtime='1.14.0';Bad.server_tags=('invented_feature',)
        with self.assertRaises(ValueError):registry([Bad()])

    def test_new_adapter_gets_pipeline_compatibility_without_core_change(self):
        class New(Adapter):
            kind='new';default_port=10000;minimum_runtime='1.15.0';tls=False;username=False
        with patch.dict(ADAPTERS,{'new':New()}):
            m=e.new_model();m['nodes']=[{'kind':'new','id':'new','name':'new','port':10000,'enabled':True,'server':'192.0.2.1'}]
            self.assertFalse(pipeline.compatibility(m,self.runtime(),e.validation)['compatible'])
            self.assertTrue(pipeline.compatibility(m,self.runtime('1.15.0'),e.validation)['compatible'])
            self.assertEqual(pipeline.compile(m,e.validation)['inbounds'][0]['type'],'new')

    def test_module_samples_are_valid_and_do_not_mutate_real_model(self):
        original=model(); saved=copy.deepcopy(original)
        for a in ADAPTERS.values():
            with self.subTest(kind=a.kind):
                m=e.new_model();m['acme']=original['acme'].copy();m['acme']['domain']='module.example.com'
                with patch.object(e,'keypair',return_value=('A'*43,'B'*43)):
                    m['nodes']=[a.sample(e,'unused')]
                e.validation(m)
        self.assertEqual(original,saved)

    def test_module_test_result_is_explicitly_offline(self):
        r=pipeline.module_tests(self.runtime(),e,'shadowsocks')
        self.assertTrue(r['passed']);self.assertIn('no listeners',r['scope'])
        self.assertEqual(r['modules'][0]['result'],'PASS')

    def test_module_test_failure_does_not_leak_runtime_stderr(self):
        with patch.object(Runtime,'check',return_value={'passed':False,'exit_code':1}):
            r=pipeline.module_tests(self.runtime(),e,'shadowsocks')
        self.assertFalse(r['passed']);self.assertNotIn('password',json.dumps(r))

    def test_v30_configuration_and_exports_remain_compatible(self):
        with tempfile.TemporaryDirectory() as td:
            p=pathlib.Path(td);e.save(p/'model.json',model())
            with (p/'old.pyz').open('wb') as out:
                subprocess.run(['bash','-c','source "$1"; emit_engine','bash',str(ROOT/'3.0版本备份/singbox-manager.sh')],check=True,stdout=out)
            subprocess.run(['python3',str(p/'old.pyz'),'compile',str(p/'model.json'),str(p/'old.json')],check=True)
            self.assertEqual(e.compile_config(model()),e.load(p/'old.json'))
            subprocess.run(['python3',str(p/'old.pyz'),'export',str(p/'model.json'),str(p/'old-export')],check=True)
            e.export(model(),p/'new-export')
            for f in (p/'old-export').iterdir():self.assertEqual(f.read_bytes(),(p/'new-export'/f.name).read_bytes())


class Audit(unittest.TestCase):
    def setUp(self):
        td=tempfile.TemporaryDirectory();self.addCleanup(td.cleanup);self.p=pathlib.Path(td.name)/'audit.jsonl'

    def test_append_chain_and_permissions(self):
        audit.append(self.p,'action-start','18','started')
        audit.append(self.p,'snapshot','18','ok','20261018T000000Z-example')
        self.assertEqual(audit.verify(self.p)['entries'],2)
        self.assertEqual(self.p.stat().st_mode & 0o777,0o600)

    def test_missing_log_is_empty(self):self.assertEqual(audit.verify(self.p)['entries'],0)

    def test_corruption_blocks_append(self):
        audit.append(self.p,'action-start','18','started')
        self.p.write_text(self.p.read_text().replace('started','failed'))
        with self.assertRaises(ValueError):audit.verify(self.p)
        with self.assertRaises(ValueError):audit.append(self.p,'action-finish','18','failed')

    def test_truncation_is_detected(self):
        audit.append(self.p,'action-start','18','started');self.p.write_text(self.p.read_text().rstrip())
        with self.assertRaises(ValueError):audit.verify(self.p)

    def test_reordering_is_detected(self):
        for i in range(3):audit.append(self.p,'action-start','18','started')
        self.p.write_text(''.join(reversed(self.p.read_text().splitlines(keepends=True))))
        with self.assertRaises(ValueError):audit.verify(self.p)

    def test_arbitrary_payloads_and_secrets_are_rejected(self):
        for kwargs in [{'event':'password'},{'action':'password=secret'},{'result':'secret'},{'snapshot':'/path/password'}]:
            values=dict(path=self.p,event='action-start',action='18',result='started');values.update(kwargs)
            with self.assertRaises(ValueError):audit.append(**values)
        self.assertFalse(self.p.exists())

    def test_symlink_is_rejected(self):
        other=self.p.with_name('other');other.write_text('private');self.p.symlink_to(other)
        with self.assertRaises((ValueError,OSError)):audit.verify(self.p)
        with self.assertRaises(OSError):audit.append(self.p,'action-start','18','started')
        self.assertEqual(other.read_text(),'private')

    def test_concurrent_append_is_serialized(self):
        jobs=[multiprocessing.Process(target=audit_worker,args=(str(self.p),)) for _ in range(4)]
        for job in jobs:job.start()
        for job in jobs:job.join(10);self.assertEqual(job.exitcode,0)
        self.assertEqual(audit.verify(self.p)['entries'],4)


class UnifiedEntrypoints(unittest.TestCase):
    def main(self,args):
        code='source "$1"; require_host() { :; }; action() { printf "%s " "$@"; }; shift; main "$@"'
        return subprocess.run(['bash','-c',code,'bash',str(ROOT/'singbox-manager.sh')]+args,capture_output=True,text=True)

    def test_legacy_cli_and_node_service_aliases_share_actions(self):
        pairs=[(['restart'],['service','restart'],'17'),(['list'],['node','list'],'2'),(['status'],['service','status'],'26')]
        for old,new,action in pairs:
            self.assertEqual(self.main(old).stdout.strip(),action)
            self.assertEqual(self.main(new).stdout.strip(),action)
        for verb,number in [('add','3'),('edit','4'),('toggle','5'),('delete','6'),('rotate','7'),('acme','8')]:
            self.assertEqual(self.main(['node',verb]).stdout.strip(),number)

    def test_structured_commands_and_json(self):
        for cmd in ['protocols','compat','validate','runtime','audit']:
            self.assertEqual(self.main([cmd,'--json']).stdout.strip(),cmd+' --json')
        self.assertEqual(self.main(['module-test','--json']).stdout.strip(),'module-test all --json')

    def test_invalid_flags_and_extra_args_are_rejected(self):
        for args in [['backup','--yes'],['node','add','--yes'],['service','unknown'],['compat','--force'],['module-test','all','--force']]:
            self.assertNotEqual(self.main(args).returncode,0)

    def test_draft_entrypoints_share_management_actions(self):
        for verb,action in [('list','draft-list'),('resume','draft-resume'),('discard','draft-discard'),('clear','draft-discard')]:
            self.assertEqual(self.main(['draft',verb]).stdout.strip(),action)
        self.assertEqual(self.main(['draft']).stdout.strip(),'22')
        self.assertNotEqual(self.main(['draft','discard','--yes']).returncode,0)


class DraftCleanup(unittest.TestCase):
    def setUp(self):
        td=tempfile.TemporaryDirectory();self.addCleanup(td.cleanup)
        self.p=pathlib.Path(td.name);self.draft=self.p/'draft.json'
        e.save(self.draft,{'model':model(),'base':{},'mode':'preserve'})

    def test_summary_has_no_credentials(self):
        r=draft_summary(self.draft)
        self.assertEqual(r['node_count'],9)
        self.assertNotIn('secret',json.dumps(r));self.assertNotIn('password',json.dumps(r))

    def test_discard_archives_exact_original_and_clears_reminder(self):
        before=self.draft.read_bytes();r=draft_summary(self.draft)
        out=pathlib.Path(draft_discard(self.draft,self.p/'archive',r['sha256']))
        self.assertFalse(self.draft.exists());self.assertEqual(out.read_bytes(),before)
        self.assertEqual(out.stat().st_mode & 0o777,0o600)
        self.assertEqual(out.parent.stat().st_mode & 0o777,0o700)
        self.assertFalse(draft_summary(self.draft)['exists'])

    def test_changed_draft_is_not_discarded(self):
        old=draft_summary(self.draft)['sha256'];self.draft.write_text('{}')
        with self.assertRaises(ValueError):draft_discard(self.draft,self.p/'archive',old)
        self.assertEqual(self.draft.read_text(),'{}')

    def test_corrupt_draft_can_be_archived_without_parsing_secrets(self):
        self.draft.write_text('{"password":"secret", bad json')
        r=draft_summary(self.draft);self.assertTrue(r['corrupt']);self.assertNotIn('secret',json.dumps(r))
        path=draft_discard(self.draft,self.p/'archive',r['sha256'])
        self.assertTrue(pathlib.Path(path).exists())

    def test_symlink_draft_or_archive_rejected(self):
        self.draft.unlink();self.draft.symlink_to('/etc/passwd')
        with self.assertRaises(ValueError):draft_summary(self.draft)
        with self.assertRaises(ValueError):draft_discard(self.draft,self.p/'archive','invalid')


class BackupFormat(unittest.TestCase):
    def test_new_backup_cannot_fall_back_if_manifest_missing(self):
        with tempfile.TemporaryDirectory() as td:
            e.backup_seal(td);e.backup_complete(td);p=pathlib.Path(td)
            e.backup_verify(td);(p/'manifest.json').unlink()
            with self.assertRaises(ValueError):e.backup_verify(td)

    def test_runtime_identity_includes_libraries_and_restore_preserves_them(self):
        with tempfile.TemporaryDirectory() as td:
            p=pathlib.Path(td);b=p/'sing-box';b.write_bytes(b'binary')
            before=runtime_identity(b);self.assertEqual(before,hashlib.sha256(b'binary').hexdigest())
            (p/'libcronet.so').write_bytes(b'library');after=runtime_identity(b)
            self.assertNotEqual(before,after)
            runtime_copy_libraries(b,p/'backup')
            self.assertEqual(runtime_identity(b,p/'backup'),after)
            self.assertEqual((p/'backup/libcronet.so').read_bytes(),b'library')

    def test_verified_release_companion_is_extracted_and_links_rejected(self):
        with tempfile.TemporaryDirectory() as td:
            p=pathlib.Path(td);archive=p/'release.tar.gz'
            for symlink in [False,True]:
                with tarfile.open(archive,'w:gz') as t:
                    binary=tarfile.TarInfo('release/sing-box');binary.size=6;t.addfile(binary,io.BytesIO(b'binary'))
                    lib=tarfile.TarInfo('release/libcronet.so')
                    if symlink:lib.type=tarfile.SYMTYPE;lib.linkname='/etc/passwd';t.addfile(lib)
                    else:lib.size=7;t.addfile(lib,io.BytesIO(b'library'))
                e.save(p/'meta',{'sha256':hashlib.sha256(archive.read_bytes()).hexdigest(),'member':'release/sing-box'})
                if symlink:
                    with self.assertRaises(ValueError):e.extract_release(p/'meta',archive,p/'bin',p/'libs')
                else:
                    e.extract_release(p/'meta',archive,p/'bin',p/'libs')
                    self.assertEqual((p/'libs/libcronet.so').read_bytes(),b'library')

    def test_recovery_entrypoint_does_not_import_protocols(self):
        code='''
import sys,tempfile,pathlib
from sbm import entrypoint
class BlockProtocols:
    def find_spec(self,fullname,*args):
        if fullname.startswith('sbm.protocols') or fullname=='sbm.engine':raise RuntimeError('protocols unavailable')
sys.meta_path.insert(0,BlockProtocols())
with tempfile.TemporaryDirectory() as td:
    for command in ['backup-seal','backup-complete','backup-verify']:
        sys.argv=['entrypoint',command,td];entrypoint.main()
print('core recovery independent')
'''
        r=subprocess.check_output(['python3','-c',code],env=dict(__import__('os').environ,PYTHONPATH=str(ROOT/'src')),text=True)
        self.assertIn('core recovery independent',r)


if __name__=='__main__':unittest.main()
