import json
import pathlib
import subprocess
import tempfile
import unittest
from common import ROOT,engine as e
from sbm.core.storage import draft_purge,draft_archive_inventory,draft_archives_purge,draft_discard,file_digest
from sbm.core.locations import inventory
from sbm.core import audit


class CleanupPaths(unittest.TestCase):
    def setUp(self):
        td=tempfile.TemporaryDirectory();self.addCleanup(td.cleanup);self.p=pathlib.Path(td.name)
        self.draft=self.p/'draft.json';self.archive=self.p/'discarded-drafts'
        self.draft.write_text('test draft credential which must not be logged')
        self.digest=file_digest(self.draft)

    def test_permanent_purge_leaves_no_archive_and_keeps_live_config(self):
        live=self.p/'config.json';live.write_text('unchanged live config')
        draft_purge(self.draft,self.digest)
        self.assertFalse(self.draft.exists());self.assertFalse(self.archive.exists())
        self.assertEqual(live.read_text(),'unchanged live config')

    def test_purge_refuses_changed_draft_and_symlink(self):
        self.draft.write_text('changed')
        with self.assertRaises(ValueError):draft_purge(self.draft,self.digest)
        link=self.p/'link';link.symlink_to(self.draft)
        with self.assertRaises(ValueError):draft_purge(link,file_digest(self.draft))
        self.assertTrue(self.draft.exists())

    def test_clear_archived_drafts_only_after_identical_preview(self):
        draft_discard(self.draft,self.archive,self.digest)
        report=draft_archive_inventory(self.archive);self.assertEqual(report['count'],1)
        self.assertNotIn('credential',json.dumps(report))
        plan=self.p/'plan.json';e.save(plan,report)
        self.assertEqual(draft_archives_purge(self.archive,plan),1)
        self.assertEqual(list(self.archive.iterdir()),[])

    def test_archive_change_after_preview_refuses_all_deletions(self):
        path=pathlib.Path(draft_discard(self.draft,self.archive,self.digest))
        plan=self.p/'plan.json';e.save(plan,draft_archive_inventory(self.archive));path.write_text('changed')
        with self.assertRaises(ValueError):draft_archives_purge(self.archive,plan)
        self.assertTrue(path.exists())

    def test_archive_does_not_follow_links_or_delete_unknown_files(self):
        self.archive.mkdir();link=self.archive/'discarded-20261018T000000Z-12345678.json';link.symlink_to(self.draft)
        with self.assertRaises(ValueError):draft_archive_inventory(self.archive)
        link.unlink();(self.archive/'unknown.json').write_text('keep')
        with self.assertRaises(ValueError):draft_archive_inventory(self.archive)
        self.assertTrue(self.draft.exists())

    def test_paths_include_resolved_runtime_and_all_managed_locations(self):
        runtime=self.p/'runtime';(runtime/'releases/1.14.3').mkdir(parents=True)
        (runtime/'current').symlink_to(runtime/'releases/1.14.3')
        report=inventory(self.p/'conf',self.p,runtime,self.p/'unit.conf',self.p/'exports',self.p/'data',self.p/'sbm',self.p/'script.sh',self.p/'sing-box.service')
        rows={r['label']:r for r in report['paths']}
        self.assertTrue(rows['当前运行版本目录']['target'].endswith('/releases/1.14.3'))
        self.assertEqual(rows['未提交草稿（含凭据）']['path'],str(self.draft))
        self.assertTrue(rows['已放弃草稿归档']['path'].endswith('/discarded-drafts'))
        self.assertNotIn('test draft credential',json.dumps(report))
        self.assertIn('journalctl',report['service_log_command'])

    def test_deletion_audit_contains_only_operation_metadata(self):
        path=self.p/'audit.jsonl'
        for action in ['draft-purge','draft-archives-purge']:audit.append(path,'action-finish',action,'ok')
        self.assertEqual(audit.verify(path)['entries'],2)
        self.assertNotIn('credential',path.read_text())

    def test_cleanup_cli_routes(self):
        code='source "$1"; require_host(){ :; }; action(){ printf "%s " "$@"; };shift;main "$@"'
        for args,want in [(['draft','purge'],'draft-purge'),(['draft','purge-archives'],'draft-archives-purge'),(['paths','--json'],'paths --json')]:
            out=subprocess.check_output(['bash','-c',code,'bash',str(ROOT/'singbox-manager.sh')]+args,text=True)
            self.assertEqual(out.strip(),want)


if __name__=='__main__':unittest.main()
