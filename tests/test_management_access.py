import copy
import ipaddress
import subprocess
import unittest
from unittest.mock import patch

from common import ROOT,engine,model
from sbm.core import network_policy as policy


V4='192.0.2.10'
V6='2001:db8::10'
SSH_PORT=22022
PANEL_PORT=22443
PANEL_NAME='panel.example.com'


class ManagementAccess(unittest.TestCase):
    def setUp(self):
        self.m=model()
        policy.stamp(self.m,[V4,V6])
        # Documentation-only addresses stand in for interface public addresses.
        old=policy.is_public
        fixture=patch.object(policy,'is_public',side_effect=lambda a:str(a) in {V4,V6} or old(a))
        fixture.start();self.addCleanup(fixture.stop)
        local=patch.object(policy,'collect_local',return_value={V4,V6})
        local.start();self.addCleanup(local.stop)

    def allow(self,kind,ip,port,domain=''):
        with patch.object(policy,'_listener_is',return_value=True):
            return policy.configure_management(self.m,kind,'allow',ip,str(port),domain)

    def test_enabled_entries_precede_local_denial_and_are_exact(self):
        self.allow('ssh',V4,SSH_PORT)
        self.allow('panel',V6,PANEL_PORT,'PANEL.EXAMPLE.COM.')
        rules=engine.compile_config(self.m)['route']['rules']
        self.assertEqual(rules[:3],[
            dict(network='tcp',port=[PANEL_PORT],action='route',outbound='direct',ip_cidr=[V6+'/128']),
            dict(network='tcp',port=[PANEL_PORT],action='route',outbound='direct',domain=[PANEL_NAME],override_address=V6),
            dict(network='tcp',port=[SSH_PORT],action='route',outbound='direct',ip_cidr=[V4+'/32']),
        ])
        self.assertEqual(rules[3]['action'],'reject')
        self.assertIn(V4+'/32',rules[3]['ip_cidr'])
        self.assertIn(V6+'/128',rules[3]['ip_cidr'])
        self.assertEqual(rules[-1],{'action':'reject'})

    def test_revoke_independently_and_all_restores_strict_policy(self):
        before=engine.compile_config(self.m)
        self.allow('ssh',V4,SSH_PORT)
        self.allow('panel',V4,PANEL_PORT,PANEL_NAME)
        self.assertTrue(policy.configure_management(self.m,'ssh','revoke'))
        self.assertEqual(set(self.m['security']['management']),{'panel'})
        self.assertFalse(policy.configure_management(self.m,'ssh','revoke'))
        self.assertTrue(policy.configure_management(self.m,'all','revoke'))
        self.assertNotIn('management',self.m['security'])
        self.assertEqual(engine.compile_config(self.m),before)

    def test_invalid_or_unowned_endpoint_does_not_change_the_model(self):
        before=copy.deepcopy(self.m)
        for args in [('127.0.0.1',str(SSH_PORT)),('10.0.0.1',str(SSH_PORT)),
                     ('::ffff:192.0.2.10',str(SSH_PORT)),('192.0.2.11',str(SSH_PORT)),
                     (V4,'0'),(V4,'65536'),('',''),(V4,'22:23')]:
            with self.subTest(args=args),self.assertRaises(ValueError):
                policy.configure_management(self.m,'ssh','allow',*args)
            self.assertEqual(self.m,before)

    def test_panel_alias_is_one_nonlocal_domain_and_ssh_has_no_alias(self):
        for name in ['*.example.com','https://panel.example.com','panel.internal','panel.localhost',V4,'panel.example.com..']:
            with self.subTest(name=name),self.assertRaises(ValueError):
                self.allow('panel',V4,PANEL_PORT,name)
        with self.assertRaises(ValueError):
            self.allow('ssh',V4,SSH_PORT,PANEL_NAME)

    def test_stamp_preserves_options_but_live_verification_rejects_stale_ip(self):
        self.allow('ssh',V4,SSH_PORT)
        policy.stamp(self.m,[V4,V6,'127.0.0.1'])
        self.assertEqual(self.m['security']['management']['ssh']['address'],V4)
        with self.assertRaisesRegex(ValueError,'不在本机网卡'):
            policy.verify_management(self.m,{V6})
        self.assertTrue(policy.configure_management(self.m,'ssh','revoke'))

    def test_status_never_claims_an_unapplied_exception(self):
        original=engine.compile_config(self.m)
        self.allow('ssh',V4,SSH_PORT)
        updated=engine.compile_config(self.m)
        self.assertEqual(policy.status(self.m,original,updated)['management'],{})
        self.assertIn('ssh',policy.status(self.m,updated,updated)['management'])

    def test_listener_owner_and_binding_are_both_checked(self):
        def run(v4='',v6=''):
            return patch.object(policy.subprocess,'run',side_effect=[
                subprocess.CompletedProcess([],0,v4,''),
                subprocess.CompletedProcess([],0,v6,''),
            ])
        ssh=f'LISTEN 0 128 {V4}:{SSH_PORT} 0.0.0.0:* users:(("sshd",pid=123,fd=3))\n'
        other=ssh.replace('"sshd"','"x-ui"')
        with run(ssh):self.assertTrue(policy._listener_is('ssh',ipaddress.ip_address(V4),SSH_PORT))
        with run(other):self.assertFalse(policy._listener_is('ssh',ipaddress.ip_address(V4),SSH_PORT))
        with run(other):self.assertTrue(policy._listener_is('panel',ipaddress.ip_address(V4),SSH_PORT))
        with run(ssh+other):self.assertFalse(policy._listener_is('ssh',ipaddress.ip_address(V4),SSH_PORT))
        with run(ssh.replace(V4,'127.0.0.1')):self.assertFalse(policy._listener_is('ssh',ipaddress.ip_address(V4),SSH_PORT))
        dual=f'LISTEN 0 128 *:{SSH_PORT} *:* users:(("sshd",pid=123,fd=3)) v6only:0\n'
        with run(v6=dual):self.assertTrue(policy._listener_is('ssh',ipaddress.ip_address(V4),SSH_PORT))
        with run(v6=dual.replace('v6only:0','v6only:1')):
            self.assertFalse(policy._listener_is('ssh',ipaddress.ip_address(V4),SSH_PORT))

    def test_cli_passes_optional_panel_alias_and_rejects_extra_revoke_arguments(self):
        stub='source "$1"; shift; require_host(){ :; }; action(){ printf "%s\\n" "$@"; }; main "$@"'
        args=['bash','-c',stub,'test',str(ROOT/'singbox-manager.sh')]
        out=subprocess.check_output([*args,'security','panel','allow',V4,str(PANEL_PORT),PANEL_NAME],text=True)
        self.assertEqual(out.splitlines(),['security','panel','allow',V4,str(PANEL_PORT),PANEL_NAME])
        self.assertNotEqual(subprocess.run([*args,'security','all','revoke',V4],capture_output=True).returncode,0)
