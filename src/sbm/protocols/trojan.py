from .base import Adapter


class Trojan(Adapter):
    kind = 'trojan'
    label = 'Trojan / TCP + TLS'
    default_port = 9443
    password = True


ADAPTER = Trojan()
