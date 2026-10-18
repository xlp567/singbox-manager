from .base import Adapter, address, quote


class Naive(Adapter):
    kind = 'naive'
    label = 'Naive HTTPS / TCP + HTTP2'
    default_port = 6443
    password = True
    server_tags = ('with_quic',)

    def validate(self, n, ctx):
        super().validate(n, ctx)
        if not n['username']:
            ctx.fail('Naive 用户名不能为空')

    def inbound(self, n, model):
        x = super().inbound(n, model)
        x['users'] = [{'username': n['username'], 'password': n['password']}]
        x['network'] = 'tcp'
        x['tls']['alpn'] = ['h2']
        return x

    def outbound(self, n):
        x = super().outbound(n)
        x['username'] = n['username']
        return x

    def uri(self, n):
        return f'naive+https://{quote(n["username"])}:{quote(n["password"])}@{address(n)}#{quote(n["name"])}'

    def summary(self, n):
        return ['模式: HTTPS / HTTP2；ALPN: h2', '注意: sing-box 客户端使用 naive 出站需带 cronet 支持（Linux 命令行版缺少时会报 cronet: library not found）']


ADAPTER = Naive()
