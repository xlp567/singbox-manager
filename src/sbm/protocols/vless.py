from .base import Adapter, link


class VLESS(Adapter):
    kind = 'vless'
    label = 'VLESS / TCP + TLS'
    default_port = 2443
    uuid = True

    def uri(self, n):
        return link(n, 'vless', n['uuid'], {'sni': n['server'], 'insecure': '0',
                    'encryption': 'none', 'type': 'tcp', 'security': 'tls'})


ADAPTER = VLESS()
