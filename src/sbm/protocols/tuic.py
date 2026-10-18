from .base import Adapter, link, quote


class TUIC(Adapter):
    kind = 'tuic'
    label = 'TUIC v5 / UDP + TLS'
    default_port = 5443
    networks = ('udp',)
    server_tags = ('with_quic',)
    password = True
    uuid = True

    def sample(self, ctx, binary):
        n=super().sample(ctx,binary); n['congestion_control']='bbr'; return n

    def prompt(self, n, ctx, binary):
        super().prompt(n, ctx, binary)
        n['congestion_control'] = 'bbr'

    def validate(self, n, ctx):
        super().validate(n, ctx)
        if n.get('congestion_control') != 'bbr':
            ctx.fail('此 TUIC 模板仅支持 bbr')

    def inbound(self, n, model):
        x = super().inbound(n, model)
        x['users'][0]['password'] = n['password']
        x.update({'congestion_control': n['congestion_control'], 'zero_rtt_handshake': False})
        x['tls']['alpn'] = ['h3']
        return x

    def outbound(self, n):
        x = super().outbound(n)
        x.update({'congestion_control': n['congestion_control'], 'zero_rtt_handshake': False})
        x['tls']['alpn'] = ['h3']
        return x

    def uri(self, n):
        return link(n, 'tuic', n['uuid'] + ':' + quote(n['password']), {'sni': n['server'], 'insecure': '0',
                    'congestion_control': 'bbr', 'alpn': 'h3', 'udp_relay_mode': 'native'})

    def summary(self, n):
        return ['ALPN: h3；拥塞控制: bbr；0-RTT: 关闭']


ADAPTER = TUIC()
