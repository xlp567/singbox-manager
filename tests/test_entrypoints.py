import re
import subprocess
import unittest
from common import ROOT


class Entrypoints(unittest.TestCase):
    def test_service_menu_actions_share_transaction_path(self):
        for name in ['src/manager-core.sh','singbox-manager.sh']:
            s=(ROOT/name).read_text()
            for number,command in [(15,'start'),(16,'stop'),(17,'restart')]:
                self.assertIn(f'{number}) service_action {command};;',s)

    def test_all_27_menu_actions_preserved(self):
        s=(ROOT/'src/manager-core.sh').read_text()
        menu=s.split("cat <<'MENU'",1)[1].split('\nMENU',1)[0]
        self.assertEqual(set(map(int,re.findall(r'(?<!\d)(\d+)\s',menu))),set(range(32)))
        action=s.split('action() (',1)[1].split('\nmain() {',1)[0]
        cases=set()
        for group in re.findall(r'(?:^|;;)\s*([0-9|]+)(?:\|(?:dash|paths))?\)',action,re.M):
            cases.update(map(int,group.split('|')))
        self.assertEqual(cases,set(range(1,32)))

    def test_help_version_run_without_root_or_dependencies(self):
        for command,expected in [('help','upgrade'),('version','v3.5')]:
            out=subprocess.check_output(['bash',str(ROOT/'singbox-manager.sh'),command],text=True)
            self.assertIn(expected,out)

    def test_unknown_command_fails(self):
        r=subprocess.run(['bash',str(ROOT/'singbox-manager.sh'),'nonexistent'],capture_output=True,text=True)
        self.assertNotEqual(r.returncode,0)
        self.assertIn('未知命令',r.stderr)


if __name__=='__main__':unittest.main()
