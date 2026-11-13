"""Real menu/action/engine cancellation paths with isolated service and data paths."""
import json
import os
import pathlib
import pty
import select
import shutil
import signal
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch

from common import ROOT, engine, model
from sbm.core.interaction import Cancelled
from sbm import entrypoint, profile_manager
import test_transactions as transaction_fixture
from test_v360 import SYSCTL_MOCK

BASH = shutil.which('bash')
PREFIX = r'''
source "$PROJECT/tests/transaction_harness.sh"
set +e
trap - EXIT INT TERM
SHORTCUT=$TEST_ROOT/sbm
require_host() { :; }
recover_pending() { :; }
status_line() { :; }
dependencies() { :; }
engine() {
    case $1 in
        dashboard) echo DASHBOARD;;
        netcheck) return 0;;
        *) engine_real "$@";;
    esac
}
'''


class Inputs(unittest.TestCase):
    def test_text_cancellation_preserves_empty_defaults_and_numeric_zero(self):
        for value in ['/cancel',' /cancel ']:
            with patch('builtins.input',return_value=value), self.assertRaises(Cancelled):
                engine.prompt('field','default')
        for value,expected in [('', 'default'),('0','0')]:
            with patch('builtins.input',return_value=value):
                self.assertEqual(engine.prompt('field','default'),expected)

    def test_password_cancellation_and_empty_keep_existing_value(self):
        with patch.object(engine.getpass,'getpass',return_value='/cancel'),self.assertRaises(Cancelled):
            engine.password('password',old='fixture-existing-value')
        with patch.object(engine.getpass,'getpass',return_value=''):
            self.assertEqual(engine.password('password',old='fixture-existing-value'),'fixture-existing-value')

    def test_selection_zero_cancels_and_invalid_choice_retries(self):
        with patch('builtins.input',return_value='0'),self.assertRaises(Cancelled):
            engine.choose('selection',['first','second'])
        with patch('builtins.input',side_effect=['invalid','99','2']):
            self.assertEqual(engine.choose('selection',['first','second']),1)

    def test_node_choice_zero_empty_cancel_and_invalid_retries(self):
        m=model()
        for value in ['0','','/cancel']:
            with patch('builtins.input',return_value=value),self.assertRaises(Cancelled):engine.pick(m)
        with patch('builtins.input',side_effect=['invalid','999','1']):self.assertEqual(engine.pick(m),0)

    def test_json_form_cancels_without_interpreting_sentinel_as_json(self):
        with patch('builtins.input',return_value='/cancel'),self.assertRaises(Cancelled):
            profile_manager.json_input('template',{},engine.CTX)

    def test_eof_and_cancel_have_the_same_engine_boundary(self):
        for error in [EOFError(),Cancelled()]:
            with patch.object(entrypoint,'main',side_effect=error),self.assertRaises(SystemExit) as result:
                entrypoint.run()
            self.assertEqual(result.exception.code,78)


class Cancellation(unittest.TestCase):
    def setUp(self):
        self.fixture=transaction_fixture.Transactions();self.fixture.setUp();self.addCleanup(self.fixture.tearDown)
        self.p=self.fixture.p
        self.env=dict(os.environ,PROJECT=str(ROOT),TEST_ROOT=str(self.p),PYTHONDONTWRITEBYTECODE='1')

    def run_shell(self,script,answers=''):
        return subprocess.run([BASH,'-c',PREFIX+script],input=answers,text=True,
                              capture_output=True,env=self.env,timeout=30)

    def unchanged(self):
        self.fixture.assertRestored()
        commands=(self.p/'service.log').read_text() if (self.p/'service.log').exists() else ''
        self.assertNotIn('stop sing-box',commands)
        self.assertNotIn('restart sing-box',commands)
        self.assertFalse((self.p/'state/pending').exists())

    def test_confirm_no_empty_and_cancel_return_once(self):
        for menu in ['1','21','23']:
            for answer in ['no','','/cancel']:
                with self.subTest(menu=menu,answer=answer):
                    r=self.run_shell('main',menu+'\n'+answer+'\n0\n')
                    self.assertEqual(r.returncode,0,r.stderr)
                    self.assertEqual(r.stdout.count('多节点管理'),2)
                    self.assertNotIn('0  返回主菜单',r.stdout)
                    self.assertNotIn('操作未完成',r.stdout)
                    self.unchanged()

    def test_eof_submenus_and_confirmation_exit_cleanly_without_wait(self):
        for menu in ['1','21','23','22','28','30','31']:
            with self.subTest(menu=menu):
                r=self.run_shell('main',menu+'\n')
                self.assertEqual(r.returncode,0,r.stderr)
                self.assertNotIn('操作未完成',r.stdout)
                self.assertNotIn('0  返回主菜单',r.stdout)

    def test_restore_and_prune_zero_cancel_invalid_retries(self):
        for menu in ['19','24']:
            r=self.run_shell('snapshot\nmain',menu+'\nwrong\n0\n0\n')
            self.assertEqual(r.returncode,0,r.stderr)
            self.assertIn('重新输入',r.stdout)
            self.assertNotIn('操作未完成',r.stdout)
            self.assertNotIn('0  返回主菜单',r.stdout)
            self.unchanged()

    def test_draft_cancel_preserves_original_and_skips_wait(self):
        for choice,answer in [('3','no'),('4','no'),('4','')]:
            r=self.run_shell('engine draft-save "$CONF/manager.json" "$STATE/draft.json" "$CONF" preserve\nmain',
                             '22\n'+choice+'\n'+answer+'\n0\n')
            self.assertEqual(r.returncode,0,r.stderr)
            self.assertTrue((self.p/'state/draft.json').exists())
            self.assertNotIn('0  返回主菜单',r.stdout)
            self.unchanged()

    def test_update_rollback_empty_returns_and_failure_is_visible(self):
        r=self.run_shell('main','30\n3\n\n0\n')
        self.assertEqual(r.stdout.count('多节点管理'),2)
        self.assertNotIn('0  返回主菜单',r.stdout)
        r=self.run_shell('main','30\n1\n/not-a-script\n0\n0\n')
        self.assertIn('操作未完成（退出码 1）',r.stdout)
        self.assertIn('0  返回主菜单',r.stdout)
        self.assertEqual(r.stdout.count('多节点管理'),2)
        self.unchanged()

    def test_cli_update_failure_is_nonzero_and_cancel_is_success(self):
        r=self.run_shell('main self-update local /not-a-script')
        self.assertEqual(r.returncode,1)
        r=self.run_shell('main self-update rollback','\n')
        self.assertEqual(r.returncode,0)
        self.assertNotIn('0  返回主菜单',r.stdout)

    def test_cancelled_audit_not_failed(self):
        r=self.run_shell('main','1\nno\n0\n')
        self.assertEqual(r.returncode,0,r.stderr)
        rows=[json.loads(line) for line in (self.p/'state/audit.jsonl').read_text().splitlines()]
        self.assertIn('cancelled',str(rows))
        self.assertNotIn('failed',str(rows))

    def test_bbr_cancel_never_loads_module_or_writes_sysctl(self):
        script=SYSCTL_MOCK+'''printf 'reno cubic\n' >"$CC_AVAILABLE"
modprobe() { echo loaded >"$TEST_ROOT/module-loaded"; echo 'reno cubic bbr' >"$CC_AVAILABLE"; }
main
'''
        r=self.run_shell(script,'27\nno\n0\n')
        self.assertEqual(r.returncode,0,r.stderr)
        for name in ['module-loaded','sysctl.log','90-bbr.conf','state/bbr-original.conf']:
            self.assertFalse((self.p/name).exists(),name)
        self.assertNotIn('0  返回主菜单',r.stdout)

    def test_bbr_confirm_can_load_module_and_unsupported_does_not_write(self):
        for supported in [True,False]:
            extra='echo "reno cubic bbr" >"$CC_AVAILABLE";' if supported else ':;'
            r=self.run_shell(SYSCTL_MOCK+'''printf 'reno cubic\n' >"$CC_AVAILABLE"
modprobe() { echo loaded >"$TEST_ROOT/module-loaded"; '''+extra+''' }
action 27
''','yes\n')
            self.assertTrue((self.p/'module-loaded').exists())
            self.assertEqual(r.returncode,0 if supported else 1,r.stderr)
            if supported:
                (self.p/'90-bbr.conf').unlink();(self.p/'state/bbr-original.conf').unlink()
                (self.p/'sysctl.state').unlink()
            else:self.assertFalse((self.p/'90-bbr.conf').exists())

    def terminal(self,extra=''):
        pid,fd=pty.fork()
        if pid==0:
            # An SSH/CI runner may inherit SIGINT ignored; model an interactive terminal.
            signal.signal(signal.SIGINT,signal.SIG_DFL)
            signal.signal(signal.SIGTERM,signal.SIG_DFL)
            os.execve(BASH,[BASH,'-c',PREFIX+extra+'\nmain'],dict(self.env,TERM='xterm'))
        data=bytearray();position=0
        def until(prompt):
            nonlocal position
            token=prompt.encode();deadline=time.monotonic()+10
            while time.monotonic()<deadline:
                at=data.find(token,position)
                if at>=0:position=at+len(token);return
                if select.select([fd],[],[],.1)[0]:
                    try:chunk=os.read(fd,65536)
                    except OSError:break
                    if not chunk:break
                    data.extend(chunk)
            self.fail('Missing prompt '+prompt+'\n'+data.decode(errors='replace'))
        def close():
            try:os.kill(pid,signal.SIGKILL)
            except ProcessLookupError:pass
            try:os.waitpid(pid,0)
            except ChildProcessError:pass
            os.close(fd)
        self.addCleanup(close)
        return data,until,lambda value:os.write(fd,value.encode())

    def test_real_python_delete_rotate_cancel_and_following_action_in_terminal(self):
        data,until,send=self.terminal();until('请选择: ')
        for menu,prompt in [('6','输入 DELETE 删除此节点: '),('7','输入 ROTATE 确认: ')]:
            for answer in ['no','','/cancel']:
                begin=len(data);send(menu+'\n');until('节点序号: ');send('1\n');until(prompt);send(answer+'\n');until('请选择: ')
                self.assertNotIn('请输入 0 返回'.encode(),data[begin:])
                self.assertNotIn('操作未完成'.encode(),data[begin:])
        send('2\n');until('请输入 0 返回: ');send('0\n');until('请选择: ')
        self.unchanged()

    def test_zero_eof_and_ctrl_c_return_from_real_python_forms(self):
        data,until,send=self.terminal();until('请选择: ')
        for menu,prompt,answer in [('3','选择 [1]: ','0\n'),('4','节点序号: ','0\n'),('5','节点序号: ','\n'),
                                   ('8','证书域名（所有普通 TLS 节点共用） [node.example.com]: ','\x03'),('20','选择 [1]: ','/cancel\n'),
                                   ('3','选择 [1]: ','\x04'),('30','升级方式: ','\x03')]:
            begin=len(data);send(menu+'\n');until(prompt)
            # Wait for the complete terminal prompt before injecting a signal.
            if answer.startswith('\x03'): time.sleep(.2)
            send(answer);until('请选择: ')
            self.assertNotIn('请输入 0 返回'.encode(),data[begin:])
            self.assertNotIn('操作未完成'.encode(),data[begin:])
        self.unchanged()

    def test_result_ctrl_c_returns_and_main_ctrl_c_keeps_menu(self):
        data,until,send=self.terminal();until('请选择: ')
        time.sleep(.2);send('\x03');time.sleep(.2)
        send('2\n');until('请输入 0 返回: ');time.sleep(.2);send('\x03');until('请选择: ')
        send('2\n');until('请输入 0 返回: ');send('/cancel\n');until('请选择: ')
        self.assertNotIn('操作未完成'.encode(),data)

    def test_update_only_exits_after_successful_install(self):
        mock=r'''engine() {
    case $1 in
        dashboard) echo DASHBOARD;;
        get) case $3 in version) echo "$SBM_VERSION";; sha256) echo CHECKSUM;; *) echo fixture;; esac;;
        manager-update)
            case $2 in install) touch "$TEST_ROOT/installed";; esac;;
        *) engine_real "$@";;
    esac
}
'''
        r=self.run_shell(mock+'main','30\n2\nno\n0\n')
        self.assertEqual(r.stdout.count('多节点管理'),2)
        self.assertFalse((self.p/'installed').exists())
        r=self.run_shell(mock+'main','30\n2\nyes\n')
        self.assertEqual(r.returncode,0,r.stderr)
        self.assertTrue((self.p/'installed').exists())
        self.assertEqual(r.stdout.count('多节点管理'),1)
        self.assertNotIn('0  返回主菜单',r.stdout)
        self.unchanged()

    def test_cancel_does_not_mask_failed_transaction_rollback(self):
        r=self.run_shell('''touch "$TEST_ROOT/fail-all-restarts"
service_action() { begin_transaction; systemctl stop sing-box; exit 78; }
action 16
''')
        self.assertEqual(r.returncode,1,r.stderr)
        self.assertTrue((self.p/'state/pending').exists())
        self.assertIn('回滚未完成',r.stderr)

    def test_github_configuration_cancel_keeps_credentials_file_absent(self):
        r=self.run_shell('main self-update configure','/cancel\n')
        self.assertEqual(r.returncode,0,r.stderr)
        self.assertFalse((self.p/'state/update-source.json').exists())
        self.assertNotIn('错误：',r.stderr)
