from .base import Adapter


class AnyTLS(Adapter):
    kind = 'anytls'
    label = 'AnyTLS / TCP + TLS'
    default_port = 8443
    password = True


ADAPTER = AnyTLS()
