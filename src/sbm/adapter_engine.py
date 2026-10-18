"""Layer 2. One protocol pipeline shared by menu, CLI and offline module checks."""
import pathlib
import tempfile
from .protocols import ADAPTERS, get
from .compiler import ConfigurationCompiler
from .runtime import Runtime, version_key


class ProtocolEngine:
    def __init__(self):
        self.compiler=ConfigurationCompiler(self.adapter)

    def adapter(self,kind):return get(kind)

    def catalog(self):
        return [dict(kind=a.kind,label=a.label,api=a.api_version,module_version=a.module_version,
                     minimum_runtime=a.minimum_runtime,networks=list(a.networks),tls=a.tls,
                     server_tags=list(a.server_tags),source=a.source) for a in ADAPTERS.values()]

    def validate_node(self,node,ctx):self.adapter(node['kind']).validate(node,ctx)

    def compile(self,model,validate):
        return self.compiler.compile(model,validate)

    def outbound(self,node):return self.adapter(node['kind']).outbound(node)
    def uri(self,node):return self.adapter(node['kind']).uri(node)

    def compatibility(self,model,binary,validate):
        validate(model); runtime=Runtime(binary); rows=[]
        for n in model['nodes']:
            a=self.adapter(n['kind']); issues=[]
            if version_key(runtime.version)<version_key(a.minimum_runtime):
                issues.append('模板要求 sing-box >= '+a.minimum_runtime)
            required=set(a.server_tags)|({'with_acme'} if a.tls else set())
            missing=required-runtime.tags
            if missing:issues.append('缺少构建能力：'+', '.join(sorted(missing)))
            rows.append({'id':n['id'],'protocol':a.kind,'enabled':n['enabled'],
                         'minimum_runtime':a.minimum_runtime,'compatible':not issues,'issues':issues})
        return {'runtime':runtime.info(),'compatible':all(r['compatible'] for r in rows if r['enabled']),
                'nodes':rows,'scope':'server-template; actual sing-box check remains required'}

    def module_tests(self,binary,ctx,kind='all'):
        adapters=list(ADAPTERS.values()) if kind=='all' else [self.adapter(kind)]
        runtime=Runtime(binary); rows=[]
        with tempfile.TemporaryDirectory(prefix='sbm-module-check-') as td:
            p=pathlib.Path(td)
            for a in adapters:
                row={'protocol':a.kind,'module_version':a.module_version}
                try:
                    model=ctx.new_model()
                    model['acme']={'domain':'module.example.com','email':'module@example.com',
                        'provider':'letsencrypt','challenge':'http','key_type':'p256'}
                    model['nodes']=[a.sample(ctx,binary)]
                    report=self.compatibility(model,binary,ctx.validation)
                    row['compatible']=report['compatible']
                    if not row['compatible']:
                        row.update(result='FAIL',reason='运行版本或构建能力不兼容')
                    else:
                        ctx.save(p/'server.json',self.compile(model,ctx.validation))
                        outbound=self.outbound(model['nodes'][0])
                        ctx.save(p/'client.json',{'outbounds':[outbound]})
                        row['server_check']=runtime.check(p/'server.json')['passed']
                        row['client_check']=runtime.check(p/'client.json')['passed']
                        row['result']='PASS' if row['server_check'] and row['client_check'] else 'FAIL'
                except (ValueError,KeyError,OSError,ctx.subprocess.SubprocessError):
                    row.update(result='FAIL',reason='模块自检失败；未输出测试凭据')
                rows.append(row)
        return {'runtime':runtime.info(),'passed':all(r['result']=='PASS' for r in rows),
                'scope':'offline configuration checks; no listeners or traffic', 'modules':rows}


PROTOCOL_ENGINE=ProtocolEngine()
