import copy
import importlib.util
import pathlib
import sys
import types

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'src'))
from sbm import engine


def legacy_engine():
    source = (ROOT / '2.4版本备份/singbox-manager.sh').read_text()
    python = source.split("    cat <<'PY_ENGINE'\n", 1)[1].split('\nPY_ENGINE', 1)[0]
    module = types.ModuleType('legacy_engine')
    exec(compile(python, '<v2.4-baseline>', 'exec'), module.__dict__)
    return module


def model():
    m = engine.new_model()
    m['acme'] = {'domain': 'node.example.com', 'email': 'admin@example.com', 'provider': 'letsencrypt',
                 'challenge': 'http', 'key_type': 'p256'}
    for i, (kind, label, port) in enumerate(engine.KINDS):
        n = {'id': 'node-' + kind, 'kind': kind, 'name': '测试 ' + kind, 'port': port, 'enabled': True,
             'server': 'node.example.com', 'username': 'user', 'password': 'a@b:c#d?e/+secret',
             'uuid': '2a69ea64-ab16-48ef-84d0-2725b57ca87b'}
        if kind == 'hysteria2': n.update(obfs='salaman/der?secret', bbr='standard')
        if kind == 'tuic': n['congestion_control'] = 'bbr'
        if kind == 'vmess': n['path'] = '/ws-test'
        if kind == 'shadowsocks': n['method'] = 'chacha20-ietf-poly1305'
        if kind == 'reality':
            n.update(target='www.example.com', target_port=443, sni='www.example.com',
                     private_key='A' * 43, public_key='B' * 43, short_id='01234567')
        m['nodes'].append(n)
    return m
