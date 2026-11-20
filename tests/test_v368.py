import contextlib
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from common import ROOT
from sbm.core import self_update as updater, storage
from signed_release import SignedRelease


class MaintenanceTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.stage = self.root / 'stage'
        self.stage.mkdir()
        self.shortcut = self.root / 'sbm'
        self.original = self.root / 'singbox-manager.sh'
        self.signed = SignedRelease(self.root / 'release')
        self.original.write_bytes(self.signed.files['singbox-manager.sh'])
        self.version = self.signed.tag[1:]
        stack = contextlib.ExitStack()
        self.addCleanup(stack.close)
        stack.enter_context(self.signed.activate(updater))
        def request(url, token=''):
            if url.endswith('/releases/tags/' + self.signed.tag):
                return self.signed.release
            return self.signed.request(url, token)
        stack.enter_context(patch.object(updater, 'request_json', side_effect=request))
        stack.enter_context(patch.object(updater, 'asset_bytes', side_effect=self.signed.asset))

    def run_op(self, op):
        return op(self.root, self.stage, self.version, self.root, self.shortcut)

    def test_shortcut_installs_only_pinned_signed_copy(self):
        self.run_op(updater.repair_shortcut)
        self.assertEqual(self.shortcut.read_bytes(), self.original.read_bytes())
        self.assertEqual(self.shortcut.stat().st_mode & 0o777, 0o700)

    def test_shortcut_rejects_modified_installed_source(self):
        self.original.write_bytes(self.original.read_bytes() + b'\n')
        with self.assertRaisesRegex(ValueError, '摘要不符'):
            self.run_op(updater.repair_shortcut)
        self.assertFalse(self.shortcut.exists())

    def test_shortcut_preserves_foreign_executable(self):
        self.shortcut.write_bytes(b'other tool')
        with self.assertRaises(ValueError):
            self.run_op(updater.repair_shortcut)
        self.assertEqual(self.shortcut.read_bytes(), b'other tool')

    def test_check_missing_entry_reports_without_install(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            self.run_op(updater.check_update)
        self.assertIn('当前已是最新版本', output.getvalue())
        self.assertIn('缺失', output.getvalue())
        self.assertFalse(self.shortcut.exists())
        self.assertFalse((self.root / 'manager-backups').exists())

    def test_check_refuses_invalid_signature(self):
        self.signed.payload['SHA256SUMS.sig'] = b'x' * len(self.signed.payload['SHA256SUMS.sig'])
        with self.assertRaises(ValueError):
            self.run_op(updater.check_update)
        self.assertFalse(self.shortcut.exists())

    def test_recovery_rejects_duplicate_swapped_or_missing_rows_before_write(self):
        folder = self.root / 'manager-backups' / 'backup'
        folder.mkdir(parents=True)
        pending = self.root / 'manager-update-pending.json'
        pending.write_text(json.dumps({'backup': str(folder)}))
        self.shortcut.write_text('keep')
        original = self.original.read_bytes()
        for files in [('1.sh','0.sh'), ('0.sh','0.sh'), ('0.sh',)]:
            with self.subTest(files=files):
                rows = [dict(file=name, exists=False) for name in files]
                (folder/'manifest.json').write_text(json.dumps(dict(
                    targets=updater.targets(self.root, self.shortcut), files=rows)))
                with self.assertRaises(ValueError):
                    updater.recover(self.root, self.root, self.shortcut)
                with self.assertRaises(ValueError):
                    updater.rollback_stage(self.root,folder,self.root,self.shortcut,self.stage)
                self.assertEqual(self.original.read_bytes(), original)
                self.assertEqual(self.shortcut.read_text(), 'keep')
                self.assertTrue(pending.exists())

    def test_menu_19_reports_valid_legacy_and_corrupt_without_restore(self):
        backups = self.root/'backups'
        for name in ('valid','legacy','bad'):
            d = backups/name
            d.mkdir(parents=True)
            (d/'item').write_text('test')
            if name == 'legacy':
                (d/'.complete').touch()
            else:
                storage.backup_seal(d)
                storage.backup_complete(d)
        (backups/'bad/item').write_text('changed')
        cmd = '''source "$1"
set -e
BACKUPS=$2
TMP=$3
emit_engine > "$TMP/engine.pyz"
restore_action
'''
        result = subprocess.run(['bash','-c',cmd,'_',str(ROOT/'singbox-manager.sh'),str(backups),str(self.stage)],
                                input='v\n', text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        for phrase in ('valid：文件清单与摘要一致','legacy：旧格式无摘要','bad：校验失败'):
            self.assertIn(phrase,result.stdout)
        self.assertEqual((backups/'bad/item').read_text(),'changed')

    def test_ssh_tool_invokes_installed_manager_on_uploaded_file(self):
        import shutil
        project = self.root / 'project'
        tools = project / 'tools'
        tools.mkdir(parents=True)
        helper = tools / 'ssh_upgrade.sh'
        shutil.copy(ROOT/'tools/ssh_upgrade.sh', helper)
        shutil.copytree(ROOT/'src/sbm', project/'src/sbm')
        trust = project/'src/sbm/core/release_trust.py'
        trust.write_text(trust.read_text().replace((ROOT/'RELEASE_SIGNING.pub').read_text().strip(), self.signed.public))
        stage = project/'dist'/('release-' + self.signed.tag)
        stage.mkdir(parents=True)
        for name, data in self.signed.payload.items():
            (stage/name).write_bytes(data)
        for name in ('singbox-manager.sh','singbox-manager.sha256'):
            shutil.copy(stage/name, project/name)
        # Record SSH command dispatch while using a real, disposable signed release.
        (tools/'ssh').write_text("""#!/usr/bin/env bash
arg=${!#}
printf '%s\\n' "$arg" >> "$COMMAND_LOG"
if [[ $arg == *"/sbm self-update"* ]]; then
    read -r answer && [[ $answer == yes ]] || exit 12
    printf '%s\\n' "$REMOTE_RECEIPT"
    exit "$REMOTE_STATUS"
fi
if [[ $arg == *'/usr/local/bin/sbm'* && $arg == *'sha256sum -c'* ]]; then exit "$DIGEST_STATUS"; fi
""")
        (tools/'scp').write_text('#!/bin/sh\necho upload >> "$COMMAND_LOG"\n')
        for name in ('ssh', 'scp'):
            (tools/name).chmod(0o700)
        log = self.root/'commands'
        import hashlib
        digest = hashlib.sha256(self.original.read_bytes()).hexdigest()
        receipt = dict(version=self.version, sha256=digest, changed=True)
        cases = [
            ('no\n', receipt, 0, 0, True, '已取消'),
            ('', receipt, 0, 0, True, '输入结束，已取消'),
            ('wrong\nYES\n', receipt, 0, 0, True, '升级成功'),
            ('yes\n', dict(receipt, changed=False), 0, 0, True, '已确认，两个已安装脚本的内容已一致'),
            ('yes\n', {}, 0, 0, False, '没有唯一的安装回执'),
            ('yes\n', dict(receipt, sha256='wrong'), 0, 0, False, '安装回执与已确认版本'),
            ('yes\n', receipt, 22, 0, False, ''),
            ('yes\n', receipt, 0, 23, False, ''),
        ]
        for answer, row, remote_code, hash_code, success, message in cases:
            with self.subTest(answer=answer, receipt=row, status=(remote_code,hash_code)):
                log.write_text('')
                env = dict(os.environ, PATH=str(tools)+os.pathsep+os.environ['PATH'],
                           COMMAND_LOG=str(log), REMOTE_RECEIPT=json.dumps(row),
                           REMOTE_STATUS=str(remote_code), DIGEST_STATUS=str(hash_code))
                result = subprocess.run(['bash',str(helper),'root@example.com'],env=env,
                                        input=answer,text=True,capture_output=True)
                self.assertEqual(result.returncode==0,success,result.stderr)
                self.assertIn(message,result.stdout+result.stderr)
                calls=log.read_text().splitlines()
                commands = [line for line in calls if 'self-update' in line]
                if answer in ('no\n',''):
                    self.assertFalse(commands)
                    self.assertNotIn('upload',calls)
                else:
                    self.assertEqual(len(commands),1)
                    self.assertRegex(commands[0],r'^/usr/local/bin/sbm self-update local /root/singbox-manager-upload-[0-9a-f]+\.sh$')
                if not success or answer in ('no\n',''):
                    self.assertNotIn('升级成功',result.stdout)

    def test_inspection_with_pending_state_stops_before_recovery_or_download(self):
        shell = r"""
source "$1"
STATE=$2
shift 2
require_host() { :; }
engine() { echo "unexpected engine call $*" >&2; exit 44; }
setup_tmp() { TMP=$STATE; }
audit_record() { :; }
cleanup() { :; }
BACKUPS=$STATE/backups
"$@"
"""
        protected = {self.original: self.original.read_bytes(), self.shortcut: b'existing shortcut'}
        self.shortcut.write_bytes(protected[self.shortcut])
        entries = [('main','self-update','check'), ('action','19'), ('action','30'),
                   ('main','self-update','menu')]
        for name in ('pending','manager-update-pending.json'):
            marker=self.root/name
            marker.write_text('preserve pending data')
            for entry in entries:
                with self.subTest(marker=name, entry=entry):
                    res=subprocess.run(['bash','-c',shell,'_',str(ROOT/'singbox-manager.sh'),
                                        str(self.root),*entry],input=('v\n' if '19' in entry else '5\n'),text=True,capture_output=True)
                    self.assertEqual(res.returncode,1,res.stderr)
                    self.assertIn('恢复',res.stderr)
                    self.assertNotIn('unexpected',res.stderr)
                    self.assertEqual(marker.read_text(),'preserve pending data')
                    for path, content in protected.items():
                        self.assertEqual(path.read_bytes(), content)
            marker.unlink()

    def test_startup_and_mutating_submenu_keep_recovery(self):
        # Exercise the real dispatcher; intercept the recovery command before it
        # can access any host paths. Exit 76 tells the caller to reload sbm.
        (self.root/'manager-update-pending.json').write_text('pending')
        shell = r"""
source "$1"
STATE=$2
shift 2
require_host() { :; }
recover_pending() { echo CONFIG_RECOVERY_PREFLIGHT; }
setup_tmp() { TMP=$STATE; }
cleanup() { :; }
audit_record() { :; }
engine() {
    if [[ $1 == manager-update && $2 == recover ]]; then echo MANAGER_RECOVERY; return; fi
    echo unexpected >&2; exit 44
}
main "$@"
"""
        for args, user_input, expected_code in [((),'',0), (('self-update','menu'),'2\n',76)]:
            with self.subTest(args=args):
                result=subprocess.run(['bash','-c',shell,'_',str(ROOT/'singbox-manager.sh'),
                                       str(self.root),*args],input=user_input,text=True,capture_output=True)
                self.assertEqual(result.returncode,expected_code,result.stderr)
                self.assertIn('MANAGER_RECOVERY',result.stdout)
                if not args:
                    self.assertIn('CONFIG_RECOVERY_PREFLIGHT',result.stdout)
