from .base import Adapter, link, quote


class Hysteria2(Adapter):
    kind = 'hysteria2'
    label = 'Hysteria2 / UDP + Salamander'
    default_port = 1443
    networks = ('udp',)
    server_tags = ('with_quic',)
    password = True
    profiles = ['standard', 'conservative', 'aggressive']

    def sample(self, ctx, binary):
        n=super().sample(ctx,binary)
        n.update(obfs='module-obfs-only-123456',bbr='standard')
        return n

    def prompt(self, n, ctx, binary):
        super().prompt(n, ctx, binary)
        n['obfs'] = ctx.password('Salamander 混淆密码', n.get('obfs'))
        n['bbr'] = self.profiles[ctx.choose('BBR 配置', self.profiles, self.profiles.index(n.get('bbr', 'standard')) + 1)]

    def validate(self, n, ctx):
        super().validate(n, ctx)
        if not isinstance(n.get('obfs'), str) or not n['obfs'] or any(c in n['obfs'] for c in '\r\n\x00'):
            ctx.fail('Salamander 混淆密码无效')
        if n.get('bbr') not in self.profiles:
            ctx.fail('Hysteria2 BBR 配置无效')

    def inbound(self, n, model):
        x = super().inbound(n, model)
        x.update({'obfs': {'type': 'salamander', 'password': n['obfs']},
                  'ignore_client_bandwidth': True, 'bbr_profile': n['bbr']})
        return x

    def outbound(self, n):
        x = super().outbound(n)
        x['obfs'] = {'type': 'salamander', 'password': n['obfs']}
        return x

    def uri(self, n):
        return link(n, self.kind, quote(n['password']), {'sni': n['server'], 'insecure': '0',
                    'obfs': 'salamander', 'obfs-password': n['obfs']})

    def rotate(self, n, ctx, binary):
        super().rotate(n, ctx, binary)
        n['obfs'] = ctx.password('', rotate=True)


ADAPTER = Hysteria2()
