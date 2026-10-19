"""The single compilation/validation boundary shared by core and protocol adapters."""
from .runtime import Runtime
from .core import network_policy


class ConfigurationCompiler:
    def __init__(self,adapter):
        self.adapter=adapter

    def compile(self,model,validate):
        validate(model)
        out={'log':{'level':model.get('log_level','info'),'timestamp':True},'inbounds':[],
             'outbounds':[{'type':'direct','tag':'direct'}],
             'dns':{'servers':[{'type':'local','tag':'system'}]},'route':network_policy.route(model)}
        if any(n['enabled'] and self.adapter(n['kind']).tls for n in model['nodes']):
            a=model['acme']
            out['certificate_providers']=[{'type':'acme','tag':'acme-main','domain':[a['domain']],
                'default_server_name':a['domain'],'data_directory':'/var/lib/sing-box/acme','email':a['email'],
                'provider':a['provider'],'key_type':a['key_type'],'disable_http_challenge':a['challenge']!='http',
                'disable_tls_alpn_challenge':a['challenge']!='tls'}]
        for n in model['nodes']:
            if n['enabled']:out['inbounds'].append(self.adapter(n['kind']).inbound(n,model))
        return out


    def checked(self,model,binary,destination,validate,save,compatibility):
        report=compatibility(model,binary,validate)
        report['config_check']=None
        if report['compatible']:
            save(destination,self.compile(model,validate))
            report['config_check']=Runtime(binary).check(destination)['passed']
        report['passed']=report['compatible'] and report['config_check'] is True
        return report
