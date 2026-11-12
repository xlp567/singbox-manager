"""Regression coverage for UDP session binding in the egress policy (policy v2)."""
import copy
import json
import unittest
from unittest.mock import patch
from common import ROOT,engine,model
from sbm.core import network_policy as policy
import test_transactions as transactions

V1='public-only-v1'
V4='192.0.2.10'
V6='2001:db8::10'


def v1_applied(m=None):
    """A model and configuration exactly as v3.5.6 - v3.6.2 wrote them."""
    m=m or model();policy.stamp(m,[V4,V6]);m['security']['policy']=V1
    config=engine.compile_config(m);config['route']=policy.route(m,udp_connect=False)
    return m,config


class UdpSessionBinding(unittest.TestCase):
    def test_every_rule_that_can_admit_udp_binds_the_session(self):
        m=model();policy.stamp(m,[V4,V6])
        m['security']['management']={'ssh':{'address':V4,'port':22022},
            'panel':{'address':V6,'port':22443,'domain':'panel.example.com'}}
        # Documentation-only addresses stand in for interface public addresses.
        with patch.object(policy,'is_public',return_value=True):rules=engine.compile_config(m)['route']['rules']
        routed=[r for r in rules if r['action']=='route']
        self.assertEqual(len(routed),4)
        for rule in routed:
            self.assertTrue(rule.get('network')=='tcp' or rule.get('udp_connect') is True,rule)
        self.assertEqual(rules[-2],{'ip_cidr':['0.0.0.0/0','::/0'],'action':'route','outbound':'direct','udp_connect':True})
        self.assertEqual(rules[-1],{'action':'reject'})

    def test_minimum_runtime_schema_defines_the_route_field(self):
        schema=json.loads((ROOT/'tests/fixtures/sing-box-1.14.3-schema.json').read_text())
        route=next(a for a in schema['$defs']['RuleAction']['oneOf'] if a['properties']['action'].get('const')=='route')
        self.assertEqual(route['properties']['udp_connect'],{'type':'boolean'})

    def test_new_and_refreshed_models_carry_the_current_marker(self):
        self.assertEqual(policy.POLICY,'public-only-v2')
        m,_=v1_applied();m['security']['management']={'ssh':{'address':V4,'port':22022}}
        policy.stamp(m,[V4,V6])
        self.assertEqual(m['security']['policy'],policy.POLICY)
        self.assertEqual(m['security']['management'],{'ssh':{'address':V4,'port':22022}})

    def test_unknown_markers_are_still_rejected(self):
        for marker in ['public-only-v0','public-only-v3','public-only','off','']:
            m=model();m['security']={'policy':marker,'local_addresses':[]}
            with self.assertRaises(ValueError):engine.compile_config(m)


class PreviousPolicyMigration(unittest.TestCase):
    def test_applied_v1_configuration_is_recognized_and_reported_outdated(self):
        m,config=v1_applied();compiled=engine.compile_config(m)
        self.assertNotEqual(config,compiled)
        self.assertTrue(policy.matches(m,config,compiled))
        report=policy.status(m,config,compiled)
        self.assertFalse(report['applied']);self.assertTrue(report['outdated']);self.assertTrue(report['requires_apply'])

    def test_live_v1_management_exceptions_remain_visible(self):
        m=model();policy.stamp(m,[V4,V6]);m['security']['management']={'ssh':{'address':V4,'port':22022}}
        with patch.object(policy,'is_public',return_value=True):
            m,config=v1_applied(m);report=policy.status(m,config,engine.compile_config(m))
        self.assertTrue(report['outdated']);self.assertIn('ssh',report['management'])

    def test_v1_template_tolerates_no_other_difference(self):
        m,config=v1_applied();compiled=engine.compile_config(m)
        def changed(edit):
            other=copy.deepcopy(config);edit(other);return other
        for other in [
            changed(lambda c:c['route']['rules'].pop(0)),
            changed(lambda c:c['route']['rules'][0]['ip_cidr'].remove('127.0.0.0/8')),
            changed(lambda c:c['route']['rules'].insert(0,{'action':'route','outbound':'direct'})),
            changed(lambda c:c['route'].update(rules=[])),
            changed(lambda c:c.pop('dns')),
            changed(lambda c:c['inbounds'].pop()),
        ]:
            self.assertFalse(policy.matches(m,other,compiled))
            self.assertFalse(policy.status(m,other,compiled)['outdated'])

    def test_current_marker_rejects_configuration_without_binding(self):
        m=model();policy.stamp(m,[V4,V6]);compiled=engine.compile_config(m)
        unbound=copy.deepcopy(compiled);unbound['route']=policy.route(m,udp_connect=False)
        self.assertFalse(policy.matches(m,unbound,compiled))
        report=policy.status(m,unbound,compiled)
        self.assertFalse(report['applied']);self.assertFalse(report['outdated'])
        self.assertTrue(policy.status(m,compiled,compiled)['applied'])

    def test_unrestricted_legacy_template_is_not_reported_as_outdated_policy(self):
        m=model();compiled=engine.compile_config(m)
        legacy=copy.deepcopy(compiled);legacy.pop('dns');legacy['route']={'final':'direct'}
        report=policy.status(m,legacy,compiled)
        self.assertTrue(report['legacy_recognized']);self.assertFalse(report['outdated']);self.assertFalse(report['applied'])


class PreviousPolicyTransactions(transactions.Transactions):
    """Managed operations on a host still running the v1 rules."""
    def v1_config(self):
        m,config=v1_applied(engine.load(self.p/'config/manager.json'))
        engine.save(self.p/'config/manager.json',m);engine.save(self.p/'config/config.json',config)
        self.old=(self.p/'config/manager.json').read_bytes()
        return (self.p/'config/config.json').read_bytes()

    def test_status_reports_outdated_without_changing_config_or_service(self):
        original=self.v1_config()
        output=self.run_bash('security_action status --json')
        self.assertIn('"outdated": true',output);self.assertIn('"requires_apply": true',output)
        self.assertIn('旧版规则',self.run_bash('security_action status'))
        self.assertEqual((self.p/'config/config.json').read_bytes(),original)
        self.assertFalse((self.p/'service.log').exists())

    def test_v1_configuration_does_not_block_managed_edits(self):
        self.v1_config()
        self.run_bash('prepare_model')

    def test_apply_refreshes_marker_and_binds_udp_after_backup(self):
        original=self.v1_config();before=engine.load(self.p/'config/manager.json')['nodes']
        self.run_bash('TEST_STAMP_SECURITY=1\nsecurity_action apply')
        current=engine.load(self.p/'config/manager.json');config=engine.load(self.p/'config/config.json')
        self.assertEqual(current['nodes'],before)
        self.assertEqual(current['security']['policy'],'public-only-v2')
        self.assertEqual(config,engine.compile_config(current))
        self.assertIs(config['route']['rules'][-2]['udp_connect'],True)
        backup=next((self.p/'state/backups').iterdir())
        self.assertEqual((backup/'config-dir/config.json').read_bytes(),original)
        self.assertFalse((self.p/'state/pending').exists())

    def test_failed_apply_restores_the_v1_pair(self):
        original=self.v1_config()
        self.run_bash('TEST_STAMP_SECURITY=1\ntouch "$TEST_ROOT/fail-restart"\nsecurity_action apply',1)
        self.assertEqual((self.p/'config/config.json').read_bytes(),original)
        self.assertRestored();self.assertFalse((self.p/'state/pending').exists())

    def test_removing_the_binding_after_refresh_is_an_external_change(self):
        self.v1_config()
        self.run_bash('TEST_STAMP_SECURITY=1\nsecurity_action apply')
        config=engine.load(self.p/'config/config.json');del config['route']['rules'][-2]['udp_connect']
        engine.save(self.p/'config/config.json',config)
        self.assertIn('脚本外被修改',self.run_bash('prepare_model',1))


def load_tests(loader,standard,pattern):
    # The inherited base cases already run in test_transactions.
    suite=unittest.TestSuite()
    for case in (UdpSessionBinding,PreviousPolicyMigration):suite.addTests(loader.loadTestsFromTestCase(case))
    own=[name for name in vars(PreviousPolicyTransactions) if name.startswith('test_')]
    suite.addTests(PreviousPolicyTransactions(name) for name in sorted(own))
    return suite
