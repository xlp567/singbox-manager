import re
from .vless import VLESS
from .base import link


class Reality(VLESS):
    kind = 'reality'
    inbound_type = 'vless'
    label = 'VLESS / Reality + Vision'
    default_port = 443
    tls = False

    def sample(self, ctx, binary):
        n=super().sample(ctx,binary)
        private,public=ctx.keypair(binary)
        n.update(target='www.example.com',target_port=443,sni='www.example.com',
                 private_key=private,public_key=public,short_id='01234567')
        return n

    def prompt(self, n, ctx, binary):
        super().prompt(n, ctx, binary)
        n['target'] = ctx.ask('Reality 握手目标域名（需支持 TLS 1.3，提交前会自动检测）', lambda s: ctx.hostname(s, True), n.get('target'))
        n['target_port'] = ctx.ask('握手目标端口', ctx.number, n.get('target_port', 443))
        n['sni'] = ctx.ask('Reality SNI（须与目标证书匹配）', lambda s: ctx.hostname(s, True), n.get('sni', n['target']))
        if not n.get('private_key'):
            n['private_key'], n['public_key'] = ctx.keypair(binary)
        n['short_id'] = n.get('short_id') or ctx.secrets.token_hex(4)

    def validate(self, n, ctx):
        super().validate(n, ctx)
        ctx.hostname(n['target'], True)
        ctx.hostname(n['sni'], True)
        if type(n['target_port']) is not int:
            ctx.fail('Reality 目标端口必须为整数')
        ctx.number(str(n['target_port']))
        for key in ['private_key', 'public_key']:
            if not re.fullmatch(r'[A-Za-z0-9_-]{43}', n.get(key, '')):
                ctx.fail('Reality 密钥格式无效')
        sid = n.get('short_id', '')
        if not re.fullmatch(r'(?:[0-9a-fA-F]{2}){1,8}', sid):
            ctx.fail('Reality short ID 无效')

    def inbound(self, n, model):
        x = super().inbound(n, model)
        x['users'][0]['flow'] = 'xtls-rprx-vision'
        x['tls'] = {'enabled': True, 'server_name': n['sni'], 'reality': {'enabled': True,
                    'handshake': {'server': n['target'], 'server_port': n['target_port']},
                    'private_key': n['private_key'], 'short_id': [n['short_id']]}}
        return x

    def outbound(self, n):
        x = super().outbound(n)
        x['flow'] = 'xtls-rprx-vision'
        x['tls'] = {'enabled': True, 'server_name': n['sni'],
                    'utls': {'enabled': True, 'fingerprint': 'chrome'},
                    'reality': {'enabled': True, 'public_key': n['public_key'], 'short_id': n['short_id']}}
        return x

    def uri(self, n):
        return link(n, 'vless', n['uuid'], {'sni': n['sni'], 'insecure': '0', 'encryption': 'none',
                    'type': 'tcp', 'security': 'reality', 'fp': 'chrome', 'pbk': n['public_key'],
                    'sid': n['short_id'], 'flow': 'xtls-rprx-vision'})

    def summary(self, n):
        return ['TLS: Reality；flow: xtls-rprx-vision；指纹: chrome', 'SNI: ' + n['sni']]

    def rotate(self, n, ctx, binary):
        super().rotate(n, ctx, binary)
        n['private_key'], n['public_key'] = ctx.keypair(binary)
        n['short_id'] = ctx.secrets.token_hex(4)

    def netcheck(self, n, ctx):
        print('检查 Reality 握手目标 TLS 1.3：' + n['target'])
        try:
            r = ctx.subprocess.run(['openssl', 's_client', '-connect', f'{n["target"]}:{n["target_port"]}',
                '-servername', n['sni'], '-tls1_3', '-verify_hostname', n['sni'], '-verify_return_error',
                '-CApath', '/etc/ssl/certs'], input='', text=True, stdout=ctx.subprocess.PIPE,
                stderr=ctx.subprocess.STDOUT, timeout=15)
            if r.returncode:
                ctx.fail('Reality 目标 TLS 1.3/证书验证失败，未提交变更')
        except ctx.subprocess.TimeoutExpired:
            ctx.fail('Reality 目标握手超时，未提交变更')


ADAPTER = Reality()
