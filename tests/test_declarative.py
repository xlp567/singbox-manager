import copy
import json
import os
import pathlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch
from common import ROOT,engine as e
from sbm.protocols import ADAPTERS
from sbm.protocols.declarative import DeclarativeAdapter,validate_definition,load_directory
from sbm import profile_manager


def definition():return json.loads((ROOT/'examples/custom-socks.json').read_text())


class DeclarativeProtocols(unittest.TestCase):
    def setUp(self):
        td=tempfile.TemporaryDirectory();self.addCleanup(td.cleanup);self.p=pathlib.Path(td.name)
        self.binary=self.p/'sing-box';self.binary.write_text('#!/bin/sh\ncase "$1" in version) echo "sing-box version 1.14.3";; *) exit 0;; esac\n');self.binary.chmod(0o755)

    def sample(self,adapter):
        m=e.new_model();m['nodes']=[adapter.sample(e,str(self.binary))];return m

    def test_template_renders_server_client_uri_without_script_changes(self):
        a=DeclarativeAdapter(definition());m=self.sample(a)
        with patch.dict(ADAPTERS,{a.kind:a}):
            e.validation(m);server=e.compile_config(m)['inbounds'][0];client=e.client_node(m['nodes'][0])
            self.assertEqual(server['type'],'socks');self.assertEqual(client['type'],'socks')
            self.assertEqual(server['users'][0]['password'],m['nodes'][0]['parameters']['password'])
            self.assertEqual(client['password'],server['users'][0]['password'])
            self.assertTrue(e.uri(m['nodes'][0]).startswith('socks5://'))

    def test_fingerprint_blocks_modified_template(self):
        a=DeclarativeAdapter(definition());m=self.sample(a);data=definition();data['server_template']['version']='5'
        changed=DeclarativeAdapter(data)
        with self.assertRaises(ValueError):changed.validate(m['nodes'][0],e)

    def test_unknown_parameters_and_private_key_export_rejected(self):
        for field in ['server_template','client_template']:
            data=definition();data[field]['unknown']='${missing}'
            with self.assertRaises(ValueError):DeclarativeAdapter(data)
        data=definition();data['fields'].append({'key':'private_key','label':'私钥','type':'string','default':'private'})
        data['client_template']['private']='${private_key}'
        with self.assertRaises(ValueError):DeclarativeAdapter(data)

    def test_reserved_listen_and_server_fields_rejected(self):
        for side,key in [('server_template','listen'),('client_template','server')]:
            data=definition();data[side][key]='127.0.0.1'
            with self.assertRaises(ValueError):DeclarativeAdapter(data)

    def test_data_is_not_python_or_shell(self):
        data=definition();data['client_template']['password']='$(touch /tmp/never-executed)'
        a=DeclarativeAdapter(data);n=self.sample(a)['nodes'][0]
        self.assertEqual(a.outbound(n)['password'],'$(touch /tmp/never-executed)')

    def test_typed_json_and_integer_placeholders_preserve_types(self):
        data=definition();data['fields'] += [{'key':'count','label':'数值','type':'integer','default':4},
            {'key':'settings','label':'对象','type':'json','default':{'x':1}}]
        data['server_template']['count']='${count}';data['server_template']['settings']='${settings}'
        a=DeclarativeAdapter(data);m=self.sample(a);a.validate(m['nodes'][0],e)
        self.assertEqual(a.inbound(m['nodes'][0],m)['settings'],{'x':1})
        self.assertIs(type(a.inbound(m['nodes'][0],m)['count']),int)

    def test_corrupt_module_does_not_disable_builtins(self):
        (self.p/'custom-bad.json').write_text('{broken')
        valid,errors=load_directory(self.p);self.assertFalse(valid);self.assertIn('custom-bad',errors)

    def test_future_template_is_saved_but_current_runtime_rejects_deployment(self):
        data=definition();data['minimum_runtime']='9.0.0';data['server_template']['type']='future'
        with patch.object(profile_manager,'MODULE_DIRECTORY',str(self.p/'profiles')),patch.dict(ADAPTERS,clear=False):
            profile_manager.install(data,str(self.binary),e)
            self.assertTrue((self.p/'profiles/custom-socks-demo.json').exists())
            a=ADAPTERS[data['kind']];m=self.sample(a)
            self.assertFalse(e.PROTOCOL_ENGINE.compatibility(m,str(self.binary),e.validation)['compatible'])

    def test_current_runtime_must_accept_template_before_import(self):
        binary=self.p/'bad';binary.write_text('#!/bin/sh\nif [ "$1" = version ]; then echo "sing-box version 1.14.3"; else exit 1; fi');binary.chmod(0o755)
        with patch.object(profile_manager,'MODULE_DIRECTORY',str(self.p/'profiles')),patch.dict(ADAPTERS,clear=False):
            with self.assertRaises(ValueError):profile_manager.install(definition(),str(binary),e)
            self.assertFalse((self.p/'profiles/custom-socks-demo.json').exists())

    def test_referenced_module_cannot_be_removed(self):
        profiles=self.p/'profiles';profiles.mkdir();e.save(profiles/'custom-socks-demo.json',definition())
        conf=self.p/'conf';conf.mkdir();e.save(conf/'manager.json',{'nodes':[{'kind':'custom-socks-demo'}]})
        with patch.object(profile_manager,'MODULE_DIRECTORY',str(profiles)):
            with self.assertRaises(ValueError):profile_manager.remove('custom-socks-demo',conf,self.p,e)
        self.assertTrue((profiles/'custom-socks-demo.json').exists())

    def test_restart_loads_json_modules_for_node_creation(self):
        e.save(self.p/'custom-socks-demo.json',definition())
        env=dict(os.environ,PYTHONPATH=str(ROOT/'src'),SBM_PROTOCOL_DIR=str(self.p))
        code='from sbm import engine; assert "custom-socks-demo" in {k[0] for k in engine.KINDS}; print("loaded")'
        self.assertIn('loaded',subprocess.check_output(['python3','-c',code],env=env,text=True))

    def test_cli_module_commands(self):
        code='source "$1"; require_host(){ :; }; action(){ printf "%s " "$@"; };shift;main "$@"'
        for args,expected in [(['protocol'],'28'),(['protocol','create'],'profile-create'),(['protocol','import','/tmp/data.json'],'profile-import /tmp/data.json'),(['protocol','test','custom-new'],'module-test custom-new')]:
            result=subprocess.check_output(['bash','-c',code,'bash',str(ROOT/'singbox-manager.sh')]+args,text=True)
            self.assertEqual(result.strip(),expected)

    def test_no_code_wizard_builds_the_same_data_contract(self):
        data=definition()
        with patch.object(e,'ask',side_effect=['socks-demo',data['label'],'1.14.0',17443]),\
             patch.object(e,'choose',side_effect=[0,0]),\
             patch.object(e,'prompt',return_value=data['uri_template']),\
             patch.object(profile_manager,'json_input',side_effect=[data['fields'],data['server_template'],data['client_template']]):
            self.assertEqual(profile_manager.create(e),data)


if __name__=='__main__':unittest.main()
