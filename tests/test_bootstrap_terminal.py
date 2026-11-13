"""Exercise real controlling terminals; never replace open('/dev/tty') with a mock."""
import importlib.util
import json
import os
import pathlib
import pty
import select
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch
from common import ROOT
from signed_release import SignedRelease

sys.path.insert(0,str(ROOT))
from tools import public_bootstrap, build_install_command


def installer():
    spec=importlib.util.spec_from_file_location('terminal_installer',ROOT/'install.py')
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
    return module


class BootstrapTerminal(unittest.TestCase):
    def setUp(self):
        temporary=tempfile.TemporaryDirectory();self.addCleanup(temporary.cleanup)
        self.p=pathlib.Path(temporary.name).resolve()

    def terminal(self,callback,answer,prompt='输入 yes',before=None):
        pid,fd=pty.fork()
        if pid==0:
            signal.signal(signal.SIGINT,signal.default_int_handler)
            try:
                # The public Bash bootstrap supplies Python source over a pipe.
                read_end,write_end=os.pipe();os.close(write_end);os.dup2(read_end,0);os.close(read_end)
                callback();code=0
            except KeyboardInterrupt:code=130
            except BaseException:
                import traceback
                traceback.print_exc();code=1
            sys.stdout.flush();sys.stderr.flush();os._exit(code)
        output=bytearray();sent=False;status=None;deadline=time.monotonic()+25
        try:
            while time.monotonic()<deadline:
                if select.select([fd],[],[],.1)[0]:
                    try:chunk=os.read(fd,65536)
                    except OSError:chunk=b''
                    output.extend(chunk)
                if not sent and prompt.encode() in output:
                    if before:before()
                    time.sleep(.1)
                    os.write(fd,answer);sent=True
                exited,value=os.waitpid(pid,os.WNOHANG)
                if exited:status=os.waitstatus_to_exitcode(value);break
            self.assertIsNotNone(status,'terminal did not finish: '+output.decode(errors='replace'))
        finally:
            if status is None:
                os.kill(pid,signal.SIGKILL);os.waitpid(pid,0)
            os.close(fd)
        return status,bytes(output),sent

    def public_flow(self,answer,embedded=False):
        marker=self.p/'executed'
        fixture=SignedRelease(self.p/'assets',{'install.py':("from pathlib import Path\nPath("+repr(str(marker))+").write_text('confirmed')\n").encode()})
        def run():
            if embedded:
                namespace={'__name__':'test_loader'};exec(build_install_command.embedded_loader(),namespace)
                namespace['read']=lambda path,token='':fixture.request(public_bootstrap.API+path,token)
                namespace['asset_bytes']=fixture.asset
                namespace['PUBLIC_KEY']=fixture.public
                namespace['launch']()
            else:
                with fixture.activate(public_bootstrap),patch.object(public_bootstrap,'read',side_effect=lambda path,token='':fixture.request(public_bootstrap.API+path,token)),patch.object(public_bootstrap,'asset_bytes',side_effect=fixture.asset):
                    public_bootstrap.launch()
        result=self.terminal(run,answer,before=lambda:self.assertFalse(marker.exists()))
        return result,marker

    def test_previous_update_stream_is_not_seekable_on_a_real_terminal(self):
        def run():
            try:open('/dev/tty','r+')
            except OSError as error:
                if 'seekable' not in str(error):raise
                print('REPRODUCED_NON_SEEKABLE');return
            raise AssertionError('expected unsupported seek on terminal')
        code,data,_=self.terminal(run,b'',prompt='not-a-prompt')
        self.assertEqual(code,0,data.decode());self.assertIn(b'REPRODUCED_NON_SEEKABLE',data)

    def test_public_signed_consent_reads_tty_with_piped_stdin_before_execution(self):
        (code,data,sent),marker=self.public_flow(b'YeS\n')
        self.assertEqual(code,0,data.decode());self.assertTrue(sent);self.assertTrue(marker.exists())
        self.assertNotIn(b'not seekable',data)

    def test_bundled_public_loader_uses_the_same_real_terminal_fix(self):
        (code,data,sent),marker=self.public_flow(b'yes\n',embedded=True)
        self.assertEqual(code,0,data.decode());self.assertTrue(sent);self.assertTrue(marker.exists())

    def test_public_decline_never_executes_verified_candidate(self):
        (code,data,sent),marker=self.public_flow(b'no\n')
        self.assertEqual(code,0,data.decode());self.assertTrue(sent);self.assertFalse(marker.exists())

    def test_public_empty_confirmation_never_executes_candidate(self):
        (code,data,sent),marker=self.public_flow(b'\n')
        self.assertEqual(code,0,data.decode());self.assertTrue(sent);self.assertFalse(marker.exists())

    def test_public_eof_cancels_without_candidate_execution(self):
        (code,data,sent),marker=self.public_flow(b'\x04')
        self.assertEqual(code,0,data.decode());self.assertTrue(sent);self.assertFalse(marker.exists())

    def test_public_ctrl_c_never_executes_candidate(self):
        (code,data,sent),marker=self.public_flow(b'\x03')
        self.assertEqual(code,130,data.decode());self.assertTrue(sent);self.assertFalse(marker.exists())

    def direct_flow(self,answer):
        module=installer();fixture=SignedRelease(self.p/'assets',rekey_bundle=True)
        root=self.p/'root';root.mkdir();shortcut=self.p/'bin/sbm';shortcut.parent.mkdir();state=self.p/'state'
        real_install=module.install;real_run=subprocess.run;exists=pathlib.Path.exists
        def run_command(args,*a,**kw):
            if args==['/usr/local/bin/sbm']:
                assert kw['stdin'].isatty();(self.p/'menu-opened').touch()
                return subprocess.CompletedProcess(args,0)
            return real_run(args,*a,**kw)
        def run():
            with fixture.activate(module),patch.object(module,'host_check'),patch.object(module,'request',side_effect=lambda path,token:fixture.request(module.API+path,token)),patch.object(module,'asset_bytes',side_effect=fixture.asset),patch.object(module,'install',side_effect=lambda stage,token,origin:real_install(stage,token,origin,root,shortcut,state)),patch.object(pathlib.Path,'exists',lambda p:False if str(p) in ['/root/singbox-manager.sh','/usr/local/bin/sbm'] else exists(p)),patch.object(module.subprocess,'run',side_effect=run_command):
                module.main()
        result=self.terminal(run,answer,before=lambda:self.assertFalse(shortcut.exists()))
        return result,root,shortcut,state

    def test_direct_signed_installer_confirms_then_installs_in_isolated_paths(self):
        (code,data,sent),root,shortcut,state=self.direct_flow(b'yes\n')
        self.assertEqual(code,0,data.decode());self.assertTrue(sent)
        self.assertEqual(shortcut.read_bytes(),(root/'singbox-manager.sh').read_bytes())
        self.assertTrue(json.loads((state/'install-origin.json').read_text())['signature_verified'])
        self.assertTrue((self.p/'menu-opened').exists())

    def test_direct_installer_cancel_writes_no_manager_or_state(self):
        (code,data,sent),root,shortcut,state=self.direct_flow(b'no\n')
        self.assertEqual(code,0,data.decode());self.assertTrue(sent)
        self.assertFalse(shortcut.exists());self.assertFalse(state.exists())
        self.assertFalse((self.p/'menu-opened').exists())

    def test_no_controlling_terminal_fails_closed(self):
        code="import sys;sys.path[:0]=['src','.'];from tools.public_bootstrap import consent;consent('v0.0.0');print('UNEXPECTED_SUCCESS')"
        result=subprocess.run([sys.executable,'-c',code],cwd=ROOT,start_new_session=True,
                              stdin=subprocess.DEVNULL,capture_output=True,text=True)
        self.assertNotEqual(result.returncode,0);self.assertNotIn('UNEXPECTED_SUCCESS',result.stdout)
