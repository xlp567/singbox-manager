import copy
import errno
import io
import json
import os
import pathlib
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch
from common import ROOT,engine,legacy_engine,model
from sbm.core import audit,network_policy,storage,release_trust
from signed_release import SignedRelease


class EgressPolicy(unittest.TestCase):
    def test_all_protocols_receive_same_policy(self):
        sample=model();rules=engine.compile_config(sample)['route']
        for node in sample['nodes']:
            m=copy.deepcopy(sample);m['nodes']=[node]
            # Own server address is the same for these fixtures.
            self.assertEqual(engine.compile_config(m)['route'],rules)

    def test_resolve_before_address_filter_and_fail_closed(self):
        rules=engine.compile_config(model())['route']['rules']
        resolve=next(i for i,r in enumerate(rules) if r['action']=='resolve')
        self.assertTrue(any(r.get('ip_is_private') and r['action']=='reject' for r in rules[resolve+1:]))
        self.assertEqual(rules[-1],{'action':'reject'})
        self.assertEqual(rules[-2]['ip_cidr'],['0.0.0.0/0','::/0'])

    def test_loopback_metadata_private_and_mapped_ranges_are_explicit(self):
        ranges=set(network_policy.NON_PUBLIC)
        for cidr in ['127.0.0.0/8','::1/128','169.254.0.0/16','fe80::/10','10.0.0.0/8','172.16.0.0/12','192.168.0.0/16','fc00::/7','100.64.0.0/10','::ffff:0:0/96']:
            self.assertIn(cidr,ranges)

    def test_local_interface_snapshot_is_host_exact_not_network_wide(self):
        m=model();network_policy.stamp(m,['192.0.2.10','2001:db8::10'])
        ranges=engine.compile_config(m)['route']['rules'][0]['ip_cidr']
        self.assertIn('192.0.2.10/32',ranges);self.assertIn('2001:db8::10/128',ranges)
        self.assertNotIn('192.0.2.0/24',ranges)

    def test_legacy_config_is_recognized_but_custom_rules_are_not(self):
        m=model();legacy=legacy_engine().compile_config(m);compiled=engine.compile_config(m)
        self.assertTrue(network_policy.matches(m,legacy,compiled))
        modified=copy.deepcopy(legacy);modified['route']['rules']=[]
        self.assertFalse(network_policy.matches(m,modified,compiled))

    def test_security_marker_prevents_downgrade_to_unrestricted_route(self):
        m=model();network_policy.stamp(m,['192.0.2.10']);compiled=engine.compile_config(m)
        stripped=copy.deepcopy(compiled);stripped.pop('dns');stripped['route']={'final':'direct'}
        self.assertFalse(network_policy.matches(m,stripped,compiled))
        self.assertTrue(network_policy.status(m,compiled,compiled)['applied'])

    def test_cannot_disable_or_inject_prefix_into_security_marker(self):
        for state in [{'policy':'off','local_addresses':[]},{'policy':network_policy.POLICY,'local_addresses':['0.0.0.0/0']}]:
            m=model();m['security']=state
            with self.assertRaises(ValueError):engine.compile_config(m)

    def test_compile_performs_no_network_or_interface_reads(self):
        with patch.object(network_policy.subprocess,'run',side_effect=AssertionError('unexpected I/O')):
            self.assertEqual(engine.compile_config(model()),engine.compile_config(model()))

    def test_collect_local_fails_closed_on_missing_or_empty_ip_output(self):
        with patch.object(network_policy.subprocess,'run',side_effect=FileNotFoundError),self.assertRaises(FileNotFoundError):network_policy.collect_local()
        response=subprocess.CompletedProcess([],0,'[]','')
        with patch.object(network_policy.subprocess,'run',return_value=response),self.assertRaises(ValueError):network_policy.collect_local()


class AuditRepair(unittest.TestCase):
    def setUp(self):
        td=tempfile.TemporaryDirectory();self.addCleanup(td.cleanup);self.root=pathlib.Path(td.name);self.path=self.root/'audit.jsonl'

    def test_partial_tail_is_preserved_and_new_chain_links_last_valid_hash(self):
        audit.append(self.path,'action-start','test','started');previous=audit.verify(self.path)['last_hash']
        audit.append(self.path,'action-finish','test','ok');raw=self.path.read_bytes()[:-20];self.path.write_bytes(raw)
        result=audit.repair(self.path);self.assertTrue(result['changed'])
        archive=pathlib.Path(result['archive']);self.assertEqual(archive.read_bytes(),raw)
        self.assertEqual(archive.stat().st_mode&0o777,0o600)
        row=json.loads(self.path.read_text());self.assertEqual(row['previous_chain']['last_valid_hash'],previous)
        self.assertEqual(row['previous_chain']['sha256'],storage.file_digest(archive))
        audit.append(self.path,'action-start','test','started');self.assertEqual(audit.verify(self.path)['entries'],2)

    def test_intact_chain_is_not_rotated(self):
        audit.append(self.path,'action-start','test','started');raw=self.path.read_bytes()
        self.assertFalse(audit.repair(self.path)['changed']);self.assertEqual(self.path.read_bytes(),raw)

    def test_symlink_repair_is_rejected(self):
        target=self.root/'target';target.write_text('keep');self.path.symlink_to(target)
        with self.assertRaises(ValueError):audit.repair(self.path)
        self.assertEqual(target.read_text(),'keep')

    def test_non_object_json_tail_can_be_repaired(self):
        for raw in ['[]\n','null\n','{"format":2,"previous_chain":[]}\n']:
            self.path.write_text(raw)
            with self.assertRaises(ValueError):audit.verify(self.path)
            self.assertTrue(audit.repair(self.path)['changed'])
            self.assertTrue(audit.verify(self.path)['valid'])


class RuntimeObjects(unittest.TestCase):
    def setUp(self):
        td=tempfile.TemporaryDirectory();self.addCleanup(td.cleanup);self.root=pathlib.Path(td.name)
        self.binary=self.root/'runtime/sing-box';self.binary.parent.mkdir();self.binary.write_bytes(b'original-runtime')
        self.binary.chmod(0o700);(self.binary.parent/'libcronet.so').write_bytes(b'original-library')
        self.pool=self.root/'runtime-objects';self.backups=self.root/'backups';self.backups.mkdir();self.pending=self.root/'pending'

    def snapshot(self,name,kind='automatic'):
        dest=self.backups/name;dest.mkdir();storage.runtime_backup(self.binary,dest,self.pool)
        storage.snapshot_kind(dest,kind);storage.backup_seal(dest);storage.backup_complete(dest);return dest

    def test_identical_runtime_is_stored_once_with_portable_hard_links(self):
        first=self.snapshot('one');second=self.snapshot('two')
        self.assertEqual((first/'runtime.bin').stat().st_ino,(second/'runtime.bin').stat().st_ino)
        self.assertEqual(len(list(self.pool.iterdir())),1)
        self.binary.write_bytes(b'changed-live-runtime')
        self.assertEqual((first/'runtime.bin').read_bytes(),b'original-runtime')
        storage.backup_verify(first);storage.backup_verify(second)

    def test_backup_survives_runtime_directory_removal(self):
        backup=self.snapshot('one');shutil.rmtree(self.binary.parent)
        storage.backup_verify(backup);self.assertEqual((backup/'runtime-libs/libcronet.so').read_bytes(),b'original-library')

    def test_cross_filesystem_falls_back_to_independent_copy(self):
        first=self.snapshot('one')
        with patch.object(storage.os,'link',side_effect=OSError(errno.EXDEV,'cross-device')):second=self.snapshot('two')
        self.assertEqual((second/'runtime.bin').read_bytes(),(first/'runtime.bin').read_bytes())
        self.assertNotEqual((second/'runtime.bin').stat().st_ino,(first/'runtime.bin').stat().st_ino)

    def test_retention_keeps_manual_legacy_and_pending_backups(self):
        first=self.snapshot('auto-0')
        for i in range(1,12):self.snapshot('auto-'+str(i))
        manual=self.snapshot('manual','manual');legacy=self.backups/'legacy';legacy.mkdir();(legacy/'.complete').write_text('2.4')
        self.pending.write_text(str(first)+'\n');storage.prune_automatic(self.backups,self.pool,self.pending)
        self.assertTrue(first.exists());self.assertTrue(manual.exists());self.assertTrue(legacy.exists())
        self.assertEqual(len([d for d in self.backups.iterdir() if d.name.startswith('auto-')]),11)
        self.pending.unlink();storage.prune_automatic(self.backups,self.pool,self.pending)
        self.assertEqual(len([d for d in self.backups.iterdir() if d.name.startswith('auto-')]),10)
        storage.backup_verify(manual)

    def test_gc_never_removes_objects_with_backup_hard_links(self):
        backup=self.snapshot('one');self.assertEqual(storage.runtime_gc(self.pool),0)
        shutil.rmtree(backup);self.assertEqual(storage.runtime_gc(self.pool),1)

    def test_low_space_guard_uses_incremental_size_not_fixed_512_mib(self):
        self.snapshot('one');conf=self.root/'conf';conf.mkdir();exports=self.root/'exports';exports.mkdir()
        usage=shutil._ntuple_diskusage(1024**3,1000,16*1024**2)
        with patch.object(storage.shutil,'disk_usage',return_value=usage):storage.snapshot_space(self.backups,self.pool,conf,exports,str(self.binary))
        with patch.object(storage.shutil,'disk_usage',return_value=shutil._ntuple_diskusage(1024**3,1000,1024)),self.assertRaises(ValueError):
            storage.snapshot_space(self.backups,self.pool,conf,exports,str(self.binary))


class ReleaseTrust(unittest.TestCase):
    def setUp(self):
        td=tempfile.TemporaryDirectory();self.addCleanup(td.cleanup);self.root=pathlib.Path(td.name)
        self.signed=SignedRelease(self.root/'assets');ctx=self.signed.activate(release_trust);ctx.__enter__();self.addCleanup(ctx.close)

    def download(self,current=''):
        dest=self.root/'download';dest.mkdir(exist_ok=True)
        return release_trust.download_release('https://api.github.com/repos/xlp567/singbox-manager',dest,
            ('singbox-manager.sh','singbox-manager.sha256'),self.signed.request,self.signed.asset,current_version=current)

    def test_missing_signature_foreign_key_and_tampered_manifest_are_rejected(self):
        other=SignedRelease(self.root/'foreign');original=self.signed.payload['SHA256SUMS.sig']
        self.signed.payload['SHA256SUMS.sig']=other.payload['SHA256SUMS.sig']
        self.signed.release['assets']= [dict(x,size=len(self.signed.payload[x['name']])) for x in self.signed.release['assets']]
        with self.assertRaisesRegex(ValueError,'签名'):self.download()
        self.signed.payload['SHA256SUMS.sig']=original
        self.signed.payload['SHA256SUMS']+=b'# tamper\n'
        self.signed.release['assets']=[dict(x,size=len(self.signed.payload[x['name']])) for x in self.signed.release['assets']]
        with self.assertRaisesRegex(ValueError,'签名'):self.download()

    def test_draft_prerelease_and_automatic_downgrade_are_rejected(self):
        for field in ['draft','prerelease']:
            self.signed.release[field]=True
            with self.assertRaises(ValueError):self.download()
            self.signed.release[field]=False
        with self.assertRaisesRegex(ValueError,'更旧'):self.download('9.9.9')

    def test_release_tag_cannot_relabel_an_old_signed_manifest(self):
        self.signed.release['tag_name']='v9.9.9'
        with self.assertRaisesRegex(ValueError,'标签'):self.download()

    def test_public_downloads_are_bound_to_version_and_asset_name(self):
        requests=[];dest=self.root/'public';dest.mkdir()
        def asset(url,token):
            requests.append(url)
            self.assertTrue(url.startswith('https://github.com/xlp567/singbox-manager/releases/download/'+self.signed.tag+'/'))
            return self.signed.asset(url,token)
        release_trust.download_release('https://api.github.com/repos/xlp567/singbox-manager',dest,
            ('singbox-manager.sh','singbox-manager.sha256'),self.signed.request,asset)
        self.assertEqual(len(requests),4)

    def test_private_downloads_use_authenticated_asset_api(self):
        requests=[];dest=self.root/'private';dest.mkdir()
        def asset(url,token):
            requests.append(url);self.assertEqual(token,'private-fixture')
            self.assertIn('/releases/assets/',url);return self.signed.asset(url,token)
        release_trust.download_release('https://api.github.com/repos/xlp567/singbox-manager',dest,
            ('singbox-manager.sh','singbox-manager.sha256'),self.signed.request,asset,token='private-fixture')
        self.assertEqual(len(requests),4)

    def test_stale_asset_content_is_rejected_before_candidate_execution(self):
        self.signed.payload['singbox-manager.sh']=b'old cached asset of a different size'
        with self.assertRaisesRegex(ValueError,'长度'):self.download()

    def test_asset_credentials_stay_on_api_and_requests_bypass_old_cache(self):
        requests=[]
        class Response(io.BytesIO):headers={'Content-Type':'application/octet-stream'}
        class Opener:
            def open(self,request,timeout):requests.append(request);return Response(b'fixture')
        with patch.object(release_trust.urllib.request,'build_opener',return_value=Opener()):
            for _ in range(2):release_trust.asset_bytes('https://api.github.com/repos/a/b/releases/assets/1','private-fixture')
            release_trust.asset_bytes('https://github.com/a/b/releases/download/v3.5.6/install.py','private-fixture')
        self.assertNotEqual(requests[0].full_url,requests[1].full_url)
        self.assertEqual(requests[0].get_header('Authorization'),'Bearer private-fixture')
        self.assertIsNone(requests[2].get_header('Authorization'))

    def test_short_network_reads_are_completed_with_a_hard_size_limit(self):
        class ShortReader(io.BytesIO):
            def read(self,size=-1):return super().read(min(size,2))
        self.assertEqual(release_trust.bounded_read(ShortReader(b'complete'),8),b'complete')
        with self.assertRaises(ValueError):release_trust.bounded_read(ShortReader(b'oversized'),4)

    def test_redirect_drops_token_and_rejects_non_github_asset_hosts(self):
        request=release_trust.urllib.request.Request('https://api.github.com/repos/a/b/releases/assets/1',headers={'Authorization':'Bearer private-fixture'})
        handler=release_trust.ReleaseAssetRedirect()
        target=handler.redirect_request(request,None,302,'',{},'https://release-assets.githubusercontent.com/file')
        self.assertIsNone(target.get_header('Authorization'))
        with self.assertRaises(ValueError):handler.redirect_request(request,None,302,'',{},'https://node.example.com/file')

    def test_static_preview_cannot_execute_top_level_shell_code(self):
        from sbm.core import self_update
        script=self.root/'hostile.sh';marker=self.root/'must-not-exist'
        script.write_text('#!/usr/bin/env bash\n# singbox-manager v3.5.6\nSBM_VERSION=3.5.6\ntouch '+str(marker)+'\n')
        checksum=self.root/'hostile.sha256';checksum.write_text(storage.file_digest(script)+'  hostile.sh\n')
        self.assertEqual(self_update.verify(script,checksum)['version'],'3.5.6')
        self.assertFalse(marker.exists())


if __name__=='__main__':unittest.main()
