import base64
from .base import Adapter, METHODS, address, quote


class Shadowsocks(Adapter):
    kind = 'shadowsocks'
    label = 'Shadowsocks / TCP + UDP'
    default_port = 8388
    networks = ('tcp', 'udp')
    tls = False
    username = False

    def sample(self, ctx, binary):
        n=super().sample(ctx,binary); n['method']='chacha20-ietf-poly1305'; return n

    def prompt(self, n, ctx, binary):
        method = METHODS[ctx.choose('加密方式', METHODS, METHODS.index(n.get('method', METHODS[0])) + 1)]
        n['password'] = ctx.password('Shadowsocks 密码 / 密钥', n.get('password') if n.get('method') == method else None, method)
        n['method'] = method

    def validate(self, n, ctx):
        super().validate(n, ctx)
        if n.get('method') not in METHODS:
            ctx.fail('不支持的 Shadowsocks 加密方式')
        password = n.get('password')
        if not isinstance(password, str) or not password or any(c in password for c in '\r\n\x00'):
            ctx.fail('Shadowsocks 密码无效')
        if n['method'].startswith('2022-'):
            ctx.check_password(password, n['method'])

    def inbound(self, n, model):
        x = super().inbound(n, model)
        x.update({'method': n['method'], 'password': n['password']})
        return x

    def outbound(self, n):
        x = super().outbound(n)
        x.update({'password': n['password'], 'method': n['method']})
        return x

    def uri(self, n):
        auth = (quote(n['method']) + ':' + quote(n['password'])) if n['method'].startswith('2022-') else base64.urlsafe_b64encode(f'{n["method"]}:{n["password"]}'.encode()).decode().rstrip('=')
        return f'ss://{auth}@{address(n)}#{quote(n["name"])}'

    def rotate(self, n, ctx, binary):
        n['password'] = ctx.password('', method=n['method'], rotate=True)


ADAPTER = Shadowsocks()
