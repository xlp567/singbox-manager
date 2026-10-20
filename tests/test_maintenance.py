"""Release portability, privacy prerequisites and source distribution regressions."""
import ast
import io
import json
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
from common import ROOT
from sbm.core import release_trust as trust
from test_bootstrap import b
from test_public_bootstrap import p

sys.path.insert(0,str(ROOT/'tools'))
from privacy_guard import private_values


class InstallationRequirements(unittest.TestCase):
    def test_old_ssh_y_option_reports_dependency_not_bad_signature(self):
        for message in [b'unknown option -- Y\n',b'illegal option -- Y\n',b"unrecognized option '-Y'\n"]:
            result=subprocess.CompletedProcess([],1,b'',message)
            with self.subTest(message=message),patch.object(trust.subprocess,'run',return_value=result),self.assertRaisesRegex(ValueError,'OpenSSH 8.1'):
                trust.verify_signature(b'manifest',b'signature')

    def test_bad_signature_on_supported_ssh_is_still_rejected(self):
        result=subprocess.CompletedProcess([],1,b'',b'Signature verification failed')
        with patch.object(trust.subprocess,'run',return_value=result),self.assertRaisesRegex(ValueError,'发布签名验证失败'):
            trust.verify_signature(b'manifest',b'signature')

    def test_missing_ssh_has_install_instruction(self):
        with patch.object(trust.subprocess,'run',side_effect=FileNotFoundError),self.assertRaisesRegex(ValueError,'openssh-client'):
            trust.verify_signature(b'manifest',b'signature')

    def test_old_python_refused_before_signature_tool(self):
        with patch.object(trust.sys,'version_info',(3,7,9)),patch.object(trust.subprocess,'run') as run,self.assertRaisesRegex(ValueError,'Python 3.8'):
            trust.verify_signature(b'manifest',b'signature')
        run.assert_not_called()

    def test_old_python_bootstrap_refused_before_download_or_consent(self):
        with patch.object(p.sys,'version_info',(3,7,9)),patch.object(p,'read') as read,patch.object(p,'consent') as consent,self.assertRaisesRegex(ValueError,'Python 3.8'):
            p.launch()
        read.assert_not_called();consent.assert_not_called()

    def test_supported_os_version_boundaries(self):
        for identity,version in [('debian','11'),('debian','13'),('ubuntu','20.04'),('ubuntu','24.04')]:
            trust.require_supported_os(identity,version)
        for identity,version in [('debian','10'),('ubuntu','18.04'),('ubuntu','20.03'),('debian',''),('other','99')]:
            with self.subTest(identity=identity,version=version),self.assertRaisesRegex(ValueError,'Debian 11'):
                trust.require_supported_os(identity,version)

    def test_installer_rejects_old_os_before_running_commands(self):
        for release in ['ID=debian\nVERSION_ID="10"\n','ID=ubuntu\nVERSION_ID="18.04"\n']:
            with patch.object(b.sys,'platform','linux'),patch.object(b.os,'geteuid',return_value=0),\
                 patch.object(b.pathlib.Path,'read_text',return_value=release),patch.object(b.subprocess,'run') as run,\
                 self.assertRaisesRegex(ValueError,'最低支持'):
                b.host_check()
            run.assert_not_called()

    def test_python_sources_parse_at_minimum_language_version(self):
        for path in [*ROOT.glob('install.py'),*(ROOT/'src').rglob('*.py'),*(ROOT/'tools').glob('*.py')]:
            ast.parse(path.read_text(),filename=str(path),feature_version=8)

    def test_generated_shell_rejects_old_os_before_install_steps(self):
        source=(ROOT/'install.sh').read_text()
        guard='IFS=. read'+source.split('IFS=. read',1)[1].split('[[ -d /run/systemd/system ]]',1)[0]
        for identity,version,accepted in [('debian','10',False),('debian','11',True),('ubuntu','18.04',False),('ubuntu','20.03',False),('ubuntu','20.04',True),('ubuntu','24.04',True)]:
            result=subprocess.run(['bash','-c','ID=$1; VERSION_ID=$2; '+guard,'bash',identity,version],capture_output=True,text=True)
            self.assertEqual(result.returncode==0,accepted,(identity,version))
            if not accepted:self.assertIn('最低支持',result.stdout)


class PublicationMaintenance(unittest.TestCase):
    def test_missing_private_list_warns_and_strict_mode_fails(self):
        with tempfile.TemporaryDirectory() as folder:
            root=pathlib.Path(folder)
            with patch('sys.stderr',new_callable=io.StringIO) as output:self.assertEqual(private_values(root),[])
            self.assertIn('警告',output.getvalue());self.assertIn('--require-private',output.getvalue())
            with self.assertRaisesRegex(ValueError,'缺少'):private_values(root,require=True)

    def test_empty_private_list_is_not_strict_release_evidence(self):
        with tempfile.TemporaryDirectory() as folder:
            root=pathlib.Path(folder);(root/'.cache').mkdir();file=root/'.cache/private-identifiers.json';file.write_text('[]')
            with self.assertRaisesRegex(ValueError,'为空'):private_values(root,require=True)
            file.write_text(json.dumps(['synthetic-private-identifier']))
            self.assertEqual(private_values(root,require=True),['synthetic-private-identifier'])

    def test_strict_prepare_rejects_missing_list_before_creating_output(self):
        with tempfile.TemporaryDirectory() as folder:
            root=pathlib.Path(folder);(root/'tools').mkdir();(root/'README.md').write_text('public fixture')
            for name in ['prepare_github.py','privacy_guard.py']:shutil.copy(ROOT/'tools'/name,root/'tools'/name)
            output=root/'manifest.json'
            result=subprocess.run([sys.executable,str(root/'tools/prepare_github.py'),'--require-private','--output',str(output)],capture_output=True,text=True)
            self.assertNotEqual(result.returncode,0);self.assertFalse(output.exists());self.assertIn('私有标识符清单',result.stderr)

    def test_strict_privacy_cli_fails_without_list(self):
        with tempfile.TemporaryDirectory() as folder:
            root=pathlib.Path(folder);(root/'tools').mkdir();shutil.copy(ROOT/'tools/privacy_guard.py',root/'tools/privacy_guard.py')
            manifest=root/'manifest.json';manifest.write_text('[]')
            result=subprocess.run([sys.executable,str(root/'tools/privacy_guard.py'),str(manifest),'--require-private'],capture_output=True,text=True)
            self.assertNotEqual(result.returncode,0);self.assertIn('FAIL',result.stderr)

    def test_packaging_strict_mode_reaches_privacy_gate(self):
        with tempfile.TemporaryDirectory() as folder:
            root=pathlib.Path(folder);(root/'tools').mkdir();(root/'src').mkdir()
            (root/'src/manager-core.sh').write_text('SBM_VERSION=3.5.7\n')
            for name in ['package.py','prepare_github.py','privacy_guard.py']:shutil.copy(ROOT/'tools'/name,root/'tools'/name)
            result=subprocess.run([sys.executable,str(root/'tools/package.py'),'--require-private'],capture_output=True,text=True)
            self.assertNotEqual(result.returncode,0);self.assertIn('私有标识符清单',result.stderr+result.stdout)
            self.assertEqual(list((root/'dist').glob('*.tar.gz')),[])

    def test_history_release_audit_strict_mode_fails_before_scanning(self):
        with tempfile.TemporaryDirectory() as folder:
            root=pathlib.Path(folder);(root/'tools').mkdir()
            for name in ['audit_publication.py','privacy_guard.py']:shutil.copy(ROOT/'tools'/name,root/'tools'/name)
            output=root/'audit.json'
            result=subprocess.run([sys.executable,str(root/'tools/audit_publication.py'),'--require-private','--git-dir',str(root/'unused.git'),'--releases',str(root/'unused'),'--output',str(output)],capture_output=True,text=True)
            self.assertNotEqual(result.returncode,0);self.assertFalse(output.exists());self.assertIn('私有标识符清单',result.stderr)

    def test_git_tracks_core_and_excludes_private_directory(self):
        with tempfile.TemporaryDirectory() as folder:
            root=pathlib.Path(folder);shutil.copy(ROOT/'.gitignore',root/'.gitignore')
            subprocess.run(['git','init','-q',str(root)],check=True)
            for path,wanted in [('src/manager-core.sh',1),('private/fixture.txt',0),('.cache/fixture.txt',0)]:
                result=subprocess.run(['git','-C',str(root),'check-ignore','--no-index',path],capture_output=True)
                self.assertEqual(result.returncode,wanted,path)

    def test_published_manual_references_public_validation(self):
        text=(ROOT/'使用说明.md').read_text()
        self.assertNotIn('reports/v3.5.1/',text);self.assertNotIn('reports/v3.5/',text)
        self.assertIn('reports/PUBLIC_VALIDATION.md',text)

    def test_installer_template_and_generated_outputs_have_no_legacy_decoder(self):
        for name in ['src/bootstrap/install.py','install.py','install.sh']:
            tree=ast.parse((ROOT/name).read_text()) if name.endswith('.py') else None
            text=(ROOT/name).read_text();self.assertNotIn('def file_content(',text);self.assertNotIn('import getpass',text)
            if tree:self.assertFalse(any(isinstance(node,ast.FunctionDef) and node.name=='file_content' for node in ast.walk(tree)))


if __name__=='__main__':unittest.main()
