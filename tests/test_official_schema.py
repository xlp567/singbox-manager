import copy
import io
import json
import pathlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch
from common import ROOT,engine as e
from sbm import official_schema as official,profile_manager
from sbm.protocols import ADAPTERS
from sbm.protocols.declarative import DeclarativeAdapter
from sbm.runtime import Runtime


class Defaults:
    """Accept the same recommendations displayed by the interactive form."""
    def __getattr__(self,key):return getattr(e,key)
    def choose(self,label,opts,default=1):return default-1
    def ask(self,label,parse,default=None):
        if default is None:raise AssertionError('Unexpected non-default input: '+label)
        return parse(str(default))


class OfficialSchemas(unittest.TestCase):
    def setUp(self):
        self.schema=json.loads((ROOT/'tests/fixtures/sing-box-1.14.3-schema.json').read_text())
        td=tempfile.TemporaryDirectory();self.addCleanup(td.cleanup);self.root=pathlib.Path(td.name)
        self.source=self.root/'schema.json';self.source.write_text(json.dumps(self.schema))
        self.binary=self.root/'sing-box'
        self.binary.write_text('#!/bin/sh\ncase "$1" in\nversion) echo "sing-box version 1.14.3";;\nschema) cp "'+str(self.source)+'" "$3";;\ncheck) exit 0;;\n*) exit 1;;\nesac\n');self.binary.chmod(0o755)
        self.ctx=Defaults()

    def test_schema_comes_from_selected_binary_and_identity(self):
        schema,origin=official.discover(self.binary)
        self.assertEqual(schema.data,self.schema)
        self.assertEqual(origin['runtime_identity'],e.runtime_identity(self.binary))
        self.assertEqual(len(origin['schema_sha256']),64)

    def test_nested_unions_find_snell_and_exclude_non_nodes(self):
        rows={r['protocol']:r for r in official.Schema(self.schema).catalog()}
        self.assertTrue(rows['snell']['available']);self.assertEqual(rows['snell']['server_variants'],2)
        self.assertFalse(rows['tun']['available']);self.assertFalse(rows['cloudflared']['available'])

    def test_snell_pairs_common_version_six_not_five_with_four(self):
        a,b=official.select_pair(official.Schema(self.schema),'snell',self.ctx)
        self.assertEqual(a['properties']['version']['const'],6)
        self.assertEqual(b['properties']['version']['const'],6)

    def install(self,kind):
        with patch.object(profile_manager,'MODULE_DIRECTORY',str(self.root/'profiles')),patch.dict(ADAPTERS,clear=False),patch('sys.stdout',new_callable=io.StringIO):
            value=official.create(self.binary,self.ctx,kind)
            data=json.loads((self.root/'profiles'/ (value+'.json')).read_text())
        return DeclarativeAdapter(data)

    def test_no_json_snell_form_has_shared_auth_and_runtime_provenance(self):
        a=self.install('snell');n=a.sample(e,self.binary)
        a.validate(n,e);server=a.inbound(n,{'listen':'127.0.0.1'});client=a.outbound(n)
        self.assertEqual(a.source,'official-schema');self.assertEqual(a.minimum_runtime,'1.14.3')
        self.assertEqual(server['version'],6);self.assertEqual(client['version'],6)
        self.assertEqual(server['psk'],client['psk'])
        self.assertEqual(server['users'][0]['userkey'],client['userkey'])
        self.assertTrue(all('default' not in f for f in a.definition['fields'] if f['type']=='password'))

    def test_no_json_socks_form_reuses_nested_user_credentials(self):
        a=self.install('socks');n=a.sample(e,self.binary)
        self.assertEqual(a.inbound(n,{'listen':'127.0.0.1'})['users'][0]['Password'],a.outbound(n)['password'])

    def test_node_menu_can_discover_then_prompt_and_compile_in_one_process(self):
        original=official.create
        def generate(binary,ctx):return original(binary,self.ctx,'snell')
        def ask(label,parse,default=None):
            return parse('127.0.0.1' if default is None else str(default))
        with patch.object(profile_manager,'MODULE_DIRECTORY',str(self.root/'profiles')),patch.dict(ADAPTERS,clear=False),\
             patch.object(e,'KINDS',list(e.KINDS)),patch.object(e,'TLS_KINDS',set(e.TLS_KINDS)),\
             patch.object(official,'create',side_effect=generate),patch.object(e,'choose',return_value=len(e.KINDS)),\
             patch.object(e,'system_listeners',return_value={}),patch.object(e,'ask',side_effect=ask),\
             patch.object(e.getpass,'getpass',return_value=''),patch('sys.stdout',new_callable=io.StringIO):
            m=e.new_model();n=e.node_prompt(m,str(self.binary));m['nodes']=[n]
            e.validation(m);server=e.compile_config(m)['inbounds'][0]
            self.assertEqual(server['type'],'snell');self.assertEqual(server['psk'],e.client_node(n)['psk'])
            self.assertIn(n['kind'],[k[0] for k in e.KINDS])

    def test_unseen_future_protocol_is_discovered_without_manager_code(self):
        future=copy.deepcopy(self.schema)
        for name,props in [('Inbound',{'listen':{'type':'string'},'listen_port':{'type':'integer'},'password':{'type':'string'},'new_parameter':{'type':'integer','minimum':3,'maximum':9}}),('Outbound',{'server':{'type':'string'},'server_port':{'type':'integer'},'password':{'type':'string'}})]:
            future['$defs'][name]['oneOf'].append({'type':'object','properties':dict(type={'const':'futureproto'},**props),'required':['type','new_parameter'] if name=='Inbound' else ['type']})
        self.source.write_text(json.dumps(future))
        a=self.install('futureproto');n=a.sample(e,self.binary)
        self.assertEqual(a.inbound(n,{'listen':'127.0.0.1'})['new_parameter'],3)
        self.assertEqual(a.outbound(n)['type'],'futureproto')

    def test_remote_refs_cycles_and_compositions_fail_closed(self):
        s=official.Schema({'$defs':{'Loop':{'$ref':'#/$defs/Loop'}}})
        for node in [{'$ref':'https://example.com/schema.json'},{'$ref':'#/$defs/Loop'}]:
            with self.assertRaises(ValueError):s.resolve(node)
        with self.assertRaises(ValueError):official.FormBuilder(s,self.ctx).build({'allOf':[]},['unsupported'],'server')

    def test_schema_failure_does_not_use_stale_website_data(self):
        with patch('sbm.runtime.subprocess.run') as run:
            run.return_value.returncode=1
            runtime=object.__new__(Runtime);runtime.version='1.14.3';runtime.binary=str(self.binary)
            with self.assertRaises(ValueError):runtime.schema()

    def test_incompatible_discriminators_refuse_guessing(self):
        s=copy.deepcopy(self.schema)
        s['$defs']['Outbound']['oneOf']=[{'type':'object','properties':{'type':{'const':'snell'},'version':{'const':100}}}]
        with self.assertRaises(ValueError):official.select_pair(official.Schema(s),'snell',self.ctx)

    def test_private_key_never_automatically_shared_to_client(self):
        b=official.FormBuilder(official.Schema({}),self.ctx)
        a=b.field({'type':'string'},['private_key'],'server');c=b.field({'type':'string'},['private_key'],'client')
        self.assertNotEqual(a,c);self.assertFalse(b.shared);self.assertFalse(b.fields[0]['export'])

    def test_public_unauthenticated_template_is_refused(self):
        class NoAuth(Defaults):
            def choose(self,label,opts,default=1):return 1 if label=='参数表单' else super().choose(label,opts,default)
            def ask(self,label,parse,default=None):return parse('0') if label.startswith('字段序号') else super().ask(label,parse,default)
        with patch.object(profile_manager,'MODULE_DIRECTORY',str(self.root/'profiles')):
            with self.assertRaises(ValueError):official.create(self.binary,NoAuth(),'socks')
        self.assertFalse((self.root/'profiles').exists())

    def test_numeric_enums_preserve_json_type_and_reject_boolean_alias(self):
        a=self.install('snell');data=copy.deepcopy(a.definition)
        data['fields'].append({'key':'numeric','label':'数字枚举','type':'enum','options':[1,2]})
        a=DeclarativeAdapter(data);n=a.sample(e,self.binary);a.validate(n,e)
        n['parameters']['numeric']=True
        with self.assertRaises(ValueError):a.validate(n,e)

    def test_shell_cli_auto_discovery_routes_and_rejects_extra_options(self):
        code='source "$1"; require_host(){ :; }; action(){ printf "%s " "$@"; };shift;main "$@"'
        for args,expected in [(['protocol','discover','--json'],'official-discover --json'),(['protocol','create','snell'],'profile-create snell'),(['protocol','advanced'],'profile-advanced')]:
            out=subprocess.check_output(['bash','-c',code,'bash',str(ROOT/'singbox-manager.sh')]+args,text=True)
            self.assertEqual(out.strip(),expected)
        r=subprocess.run(['bash','-c',code,'bash',str(ROOT/'singbox-manager.sh'),'protocol','discover','bad'],capture_output=True,text=True)
        self.assertNotEqual(r.returncode,0)


if __name__=='__main__':unittest.main()
