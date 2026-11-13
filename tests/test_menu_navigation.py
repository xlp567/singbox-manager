"""Exercise menu navigation with isolated actions; never contact a service."""
import os
import pathlib
import select
import subprocess
import tempfile
import time
import unittest

from common import ROOT


HARNESS = r'''
source "$1"
STATE=$2
require_host() { :; }
recover_pending() { :; }
status_line() { :; }
action() {
    case $1 in
        dash) echo DASHBOARD;;
        12) echo DIAGNOSTIC_FAILED; return 7;;
        13) echo LOG_INTERRUPTED; return 130;;
        30) echo UPDATE_EXIT;;
        31) echo RECOVERY_EXIT; return 76;;
        *) echo "RESULT:$1";;
    esac
}
main "${3:-menu}"
'''


class MenuNavigation(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.directory = directory.name

    def run_menu(self, inputs, command='menu'):
        return subprocess.run(
            ['bash', '-c', HARNESS, 'bash', str(ROOT / 'singbox-manager.sh'),
             self.directory, command], input=inputs, capture_output=True,
            text=True, timeout=5)

    def test_result_waits_until_zero_before_redrawing(self):
        process = subprocess.Popen(
            ['bash', '-c', HARNESS, 'bash', str(ROOT / 'singbox-manager.sh'),
             self.directory], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT)
        self.addCleanup(process.stdout.close)
        self.addCleanup(process.stdin.close)
        def stop():
            if process.poll() is None:
                process.kill()
            process.wait(timeout=5)
        self.addCleanup(stop)
        process.stdin.write(b'2\n')
        process.stdin.flush()
        output = b''
        deadline = time.monotonic() + 5
        while '0  返回主菜单'.encode() not in output and time.monotonic() < deadline:
            if select.select([process.stdout], [], [], .1)[0]:
                output += os.read(process.stdout.fileno(), 65536)
        self.assertIn('0  返回主菜单'.encode(), output)
        self.assertIn(b'RESULT:2', output)
        self.assertEqual(output.count('多节点管理'.encode()), 1)
        self.assertIsNone(process.poll())
        self.assertFalse(select.select([process.stdout], [], [], .1)[0])
        remaining, _ = process.communicate(b'0\n0\n', timeout=5)
        self.assertEqual((output + remaining).count('多节点管理'.encode()), 2)
        self.assertEqual(process.returncode, 0)

    def test_result_page_does_not_dispatch_other_menu_numbers(self):
        result = self.run_menu('2\n\n17\nwrong\n0\n0\n')
        self.assertEqual(result.returncode, 0)
        self.assertNotIn('RESULT:17', result.stdout)
        self.assertEqual(result.stdout.count('当前为结果页'), 3)
        self.assertEqual(result.stdout.count('多节点管理'), 2)

    def test_invalid_main_choice_does_not_redraw_or_run_action(self):
        result = self.run_menu('\n32\ninvalid\n0\n')
        self.assertEqual(result.stdout.count('多节点管理'), 1)
        self.assertEqual(result.stdout.count('无效选择'), 3)
        self.assertNotIn('RESULT:', result.stdout)

    def test_failure_stays_on_result_page(self):
        result = self.run_menu('12\n0\n0\n')
        self.assertIn('退出码 7', result.stdout)
        self.assertIn('0  返回主菜单', result.stdout)
        self.assertLess(result.stdout.index('退出码 7'), result.stdout.index('0  返回主菜单'))

    def test_eof_at_result_exits_without_redraw(self):
        result = self.run_menu('2\n')
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout.count('多节点管理'), 1)

    def test_cli_list_does_not_wait_or_clear_output(self):
        result = self.run_menu('', 'list')
        self.assertEqual(result.stdout, 'RESULT:2\n')
        self.assertEqual(result.returncode, 0)

    def test_log_interrupt_returns_without_extra_zero(self):
        result = self.run_menu('13\n0\n')
        self.assertNotIn('0  返回主菜单', result.stdout)
        self.assertEqual(result.stdout.count('多节点管理'), 2)

    def test_update_and_recovery_keep_exit_behavior(self):
        for choice in ('30', '31'):
            with self.subTest(choice=choice):
                result = self.run_menu(choice + '\n')
                self.assertEqual(result.returncode, 0)
                self.assertNotIn('0  返回主菜单', result.stdout)
                self.assertEqual(result.stdout.count('多节点管理'), 1)

    def test_redirected_output_has_no_clear_escape_codes(self):
        self.assertNotIn('\x1b', self.run_menu('2\n0\n0\n').stdout)


# Run the real action/submenu/cleanup functions. Only external services and the
# Python engine are replaced; the previous all-mocked action missed submenu 0.
SUBMENU_HARNESS = r"""
source "$1"
STATE=$2
CONF=$STATE/config
mkdir -p "$CONF"
require_host() { :; }
recover_pending() { :; }
status_line() { :; }
require_managed() { :; }
prepare_model() { :; }
active_binary() { echo /unused-runtime; }
engine() {
    printf '%s\n' "$*" >>"$STATE/engine.calls"
    case $1 in
        dashboard) echo DASHBOARD;;
        list) echo NODE_LIST;;
        security-status)
            if [[ ${TEST_STATUS_FAILURE:-0} == 1 ]]; then return 77; fi
            echo SECURITY_STATUS;;
        security-management) echo unchanged;;
        draft-summary) echo DRAFT_SUMMARY;;
        protocols) echo PROTOCOLS;;
    esac
}
# Have list_action take the managed path without accessing the host.
touch "$CONF/manager.json"
shift 2
main "$@"
"""


class RealSubmenuNavigation(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.directory = directory.name

    def run_menu(self, inputs, *arguments, failure=False):
        env = dict(os.environ, TEST_STATUS_FAILURE='1' if failure else '0')
        return subprocess.run(
            ['bash', '-c', SUBMENU_HARNESS, 'bash',
             str(ROOT / 'singbox-manager.sh'), self.directory, *arguments],
            input=inputs, capture_output=True, text=True, env=env, timeout=10)

    def test_zero_returns_once_then_next_main_action_works(self):
        for menu in ('22', '28', '30', '31'):
            with self.subTest(menu=menu):
                result = self.run_menu(menu + '\n0\n2\n0\n0\n')
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.count('多节点管理'), 3)
                self.assertEqual(result.stdout.count('0  返回主菜单'), 1)
                self.assertIn('NODE_LIST', result.stdout)
                self.assertNotIn('当前为结果页', result.stdout)
                self.assertNotIn('操作未完成', result.stdout)

    def test_repeated_submenu_returns_do_not_leave_state_or_wait(self):
        result = self.run_menu(('22\n0\n28\n0\n30\n0\n31\n0\n') * 3 + '0\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.count('多节点管理'), 13)
        self.assertNotIn('0  返回主菜单', result.stdout)
        self.assertNotIn('当前为结果页', result.stdout)
        self.assertEqual(list(pathlib.Path(self.directory).glob('tmp.*')), [])

    def test_explicit_return_is_audited_as_success(self):
        result = self.run_menu('31\n0\n0\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = (pathlib.Path(self.directory) / 'engine.calls').read_text()
        self.assertIn('action-finish 31 ok', calls)
        self.assertNotIn('action-finish 31 failed', calls)

    def test_cli_submenu_zero_exits_successfully_without_main_menu(self):
        for command in ('security', 'draft', 'protocol', 'self-update'):
            with self.subTest(command=command):
                result = self.run_menu('0\n', command)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertNotIn('多节点管理', result.stdout)
                self.assertNotIn('0  返回主菜单', result.stdout)

    def test_real_results_still_wait_after_submenu_action(self):
        for menu, choice, marker in [('22', '2', 'DRAFT_SUMMARY'),
                                    ('28', '6', 'PROTOCOLS'),
                                    ('31', '6', '管理例外没有变化')]:
            with self.subTest(menu=menu):
                result = self.run_menu(menu + '\n' + choice + '\n17\n0\n0\n')
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(marker, result.stdout)
                self.assertEqual(result.stdout.count('0  返回主菜单'), 1)
                self.assertEqual(result.stdout.count('当前为结果页'), 1)
                self.assertEqual(result.stdout.count('多节点管理'), 2)

    def test_invalid_submenu_input_retries_without_leaving(self):
        for menu in ('22', '28', '30', '31'):
            with self.subTest(menu=menu):
                result = self.run_menu(menu + '\ninvalid\n99\n0\n0\n')
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.count('无效选择'), 2)
                self.assertEqual(result.stdout.count('多节点管理'), 2)
                self.assertNotIn('0  返回主菜单', result.stdout)

    def test_engine_failure_is_not_mistaken_for_navigation(self):
        result = self.run_menu('31\n0\n0\n', failure=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('操作未完成', result.stdout)
        self.assertEqual(result.stdout.count('0  返回主菜单'), 1)
        calls = (pathlib.Path(self.directory) / 'engine.calls').read_text()
        self.assertIn('action-finish 31 failed', calls)

    def test_real_submenus_return_once_in_a_terminal(self):
        master, slave = os.openpty()
        process = subprocess.Popen(
            ['bash', '-c', SUBMENU_HARNESS, 'bash', str(ROOT / 'singbox-manager.sh'),
             self.directory], stdin=slave, stdout=slave, stderr=slave,
            env=dict(os.environ, TERM='xterm-256color'))
        os.close(slave)
        output = b''
        position = 0
        def until(prompt):
            nonlocal output, position
            token = prompt.encode()
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                at = output.find(token, position)
                if at >= 0:
                    position = at + len(token)
                    return
                if select.select([master], [], [], .1)[0]:
                    output += os.read(master, 65536)
            self.fail('terminal did not reach the expected navigation prompt')
        try:
            until('请选择: ')
            for menu, prompt in [('31', '选择: '), ('22', '草稿操作 [1]: '),
                                 ('28', '模块操作: '), ('30', '升级方式: ')]:
                os.write(master, (menu + '\n').encode())
                until(prompt)
                os.write(master, b'0\n')
                until('请选择: ')
            self.assertEqual(output.count('多节点管理'.encode()), 5)
            self.assertNotIn('请输入 0 返回'.encode(), output)
            self.assertIn(b'\x1b[2J\x1b[H', output)
            self.assertNotIn(b'\x1b[3J', output)
            os.write(master, b'0\n')
            self.assertEqual(process.wait(timeout=5), 0)
        finally:
            if process.poll() is None:
                process.kill()
            process.wait(timeout=5)
            os.close(master)

    def test_blank_draft_choice_keeps_default_resume(self):
        harness = SUBMENU_HARNESS.replace('main "$@"',
            'resume_draft() { echo RESUME_DRAFT; }; main "$@"')
        result = subprocess.run(
            ['bash', '-c', harness, 'bash', str(ROOT / 'singbox-manager.sh'), self.directory],
            input='22\n\n0\n0\n', text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('RESUME_DRAFT', result.stdout)
        self.assertEqual(result.stdout.count('0  返回主菜单'), 1)


if __name__ == '__main__':
    unittest.main()
