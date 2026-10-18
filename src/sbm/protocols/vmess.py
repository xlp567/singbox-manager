import base64
import json
from .base import Adapter


class VMess(Adapter):
    kind = 'vmess'
    label = 'VMess / WebSocket + TLS'
    default_port = 3443
    uuid = True

    def sample(self, ctx, binary):
        n=super().sample(ctx,binary); n['path']='/module-test'; return n

    def prompt(self, n, ctx, binary):
        super().prompt(n, ctx, binary)
        n['path'] = ctx.ask('WebSocket 路径', ctx.ws_path, n.get('path', '/' + ctx.secrets.token_hex(6)))

    def validate(self, n, ctx):
        super().validate(n, ctx)
        ctx.ws_path(n['path'])

    def inbound(self, n, model):
        x = super().inbound(n, model)
        x['users'][0]['alterId'] = 0
        x['transport'] = {'type': 'ws', 'path': n['path']}
        return x

    def outbound(self, n):
        x = super().outbound(n)
        x.update({'security': 'auto', 'alter_id': 0, 'transport': {'type': 'ws',
                  'path': n['path'], 'headers': {'Host': n['server']}}})
        return x

    def uri(self, n):
        data = {'v': '2', 'ps': n['name'], 'add': n['server'], 'port': str(n['port']), 'id': n['uuid'],
                'aid': '0', 'scy': 'auto', 'net': 'ws', 'type': 'none', 'host': n['server'],
                'path': n['path'], 'tls': 'tls', 'sni': n['server']}
        return 'vmess://' + base64.b64encode(json.dumps(data, ensure_ascii=False).encode()).decode()


ADAPTER = VMess()
