"""Protocol API v1. Adapters own fields, prompts, validation and wire formats."""
import base64
import urllib.parse

METHODS = ['2022-blake3-aes-128-gcm', '2022-blake3-aes-256-gcm',
           'chacha20-ietf-poly1305', 'aes-256-gcm']


def quote(value):
    return urllib.parse.quote(str(value), safe='')


def address(n):
    host = '[' + n['server'] + ']' if ':' in n['server'] else n['server']
    return f'{host}:{n["port"]}'


def link(n, scheme, auth, args):
    query = urllib.parse.urlencode(args, quote_via=urllib.parse.quote)
    return f'{scheme}://{auth}@{address(n)}?{query}#{quote(n["name"])}'


class Adapter:
    api_version = 1
    module_version = '1.0.0'
    # Minimum for our complete template (including shared certificate provider).
    minimum_runtime = '1.14.0'
    server_tags = ()
    source = 'built-in'
    kind = ''
    label = ''
    default_port = 0
    networks = ('tcp',)
    tls = True
    password = False
    uuid = False
    username = True
    inbound_type = None

    def sample(self, ctx, binary):
        """Disposable offline test vector, never installed or exported to real nodes."""
        return {'id':'module-'+self.kind,'kind':self.kind,'name':'模块检查 '+self.kind,
                'enabled':True,'port':self.default_port,'server':'module.example.com',
                'username':'module-test','password':'module-test-only-123456',
                'uuid':'2a69ea64-ab16-48ef-84d0-2725b57ca87b'}

    def prompt(self, n, ctx, binary):
        if self.password:
            n['password'] = ctx.password('认证密码', n.get('password'))
        if self.uuid:
            n['uuid'] = ctx.ask('UUID（新建留空自动生成；修改可输入 ! 重置）',
                               lambda s: ctx.uuid_value(s, n.get('uuid', '')), n.get('uuid') or None)

    def validate(self, n, ctx):
        fields = (['username'] if self.username else []) + (['password'] if self.password else [])
        for field in fields:
            value = n.get(field)
            if not isinstance(value, str) or (field == 'password' and not value) or any(c in value for c in '\r\n\x00'):
                ctx.fail(f'{self.kind} 的 {field} 无效')
        if self.uuid:
            value = n.get('uuid')
            if not value or ctx.uuid_value(value) != value:
                ctx.fail('UUID 必须为规范格式')

    def inbound(self, n, model):
        x = {'type': self.inbound_type or self.kind, 'tag': n['id'],
             'listen': model['listen'], 'listen_port': n['port']}
        if self.tls:
            x['tls'] = {'enabled': True, 'server_name': model['acme']['domain'],
                        'certificate_provider': 'acme-main'}
        if self.password:
            x['users'] = [{'name': n['username'], 'password': n['password']}]
        if self.uuid:
            x['users'] = [{'name': n['username'], 'uuid': n['uuid']}]
        return x

    def outbound(self, n):
        x = {'type': self.inbound_type or self.kind, 'tag': n['id'],
             'server': n['server'], 'server_port': n['port']}
        if self.tls:
            x['tls'] = {'enabled': True, 'server_name': n['server'], 'insecure': False}
        if self.password:
            x['password'] = n['password']
        if self.uuid:
            x['uuid'] = n['uuid']
        return x

    def uri(self, n):
        return link(n, self.kind, quote(n['password']),
                    {'sni': n['server'], 'insecure': '0', 'security': 'tls'})

    def summary(self, n):
        return []

    def rotate(self, n, ctx, binary):
        if self.password:
            n['password'] = ctx.password('', rotate=True)
        if self.uuid:
            n['uuid'] = str(ctx.uuid.uuid4())

    def netcheck(self, n, ctx):
        pass
