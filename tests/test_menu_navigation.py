"""Exercise menu navigation with isolated actions; never contact a service."""
import os
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


if __name__ == '__main__':
    unittest.main()
