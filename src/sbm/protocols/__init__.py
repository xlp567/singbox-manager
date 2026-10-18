"""Explicit bundled registry; never executes plugins from /etc or remote URLs."""
import re
import os
from .declarative import load_directory
from .anytls import ADAPTER as anytls
from .hysteria2 import ADAPTER as hysteria2
from .trojan import ADAPTER as trojan
from .vless import ADAPTER as vless
from .reality import ADAPTER as reality
from .vmess import ADAPTER as vmess
from .tuic import ADAPTER as tuic
from .shadowsocks import ADAPTER as shadowsocks
from .naive import ADAPTER as naive


def registry(adapters):
    result = {}
    for adapter in adapters:
        if adapter.api_version != 1 or not adapter.kind or adapter.kind in result:
            raise ValueError('协议适配器 API 版本或标识无效/重复')
        if not adapter.networks or set(adapter.networks) - {'tcp', 'udp'}:
            raise ValueError('协议网络类型无效')
        if type(adapter.default_port) is not int or not 1 <= adapter.default_port <= 65535:
            raise ValueError('协议默认端口无效')
        if not re.fullmatch(r'[a-z][a-z0-9_-]{0,31}',adapter.kind):
            raise ValueError('协议标识无效')
        for version in [adapter.minimum_runtime,adapter.module_version]:
            if not re.fullmatch(r'\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?',version):
                raise ValueError('协议版本声明无效')
        if any(not isinstance(t,str) or not re.fullmatch(r'with_[a-z0-9_]+',t) for t in adapter.server_tags):
            raise ValueError('协议构建能力声明无效')
        if any(not callable(getattr(adapter,name,None)) for name in ['validate','inbound','outbound','uri','sample']):
            raise ValueError('协议接口缺失')
        result[adapter.kind] = adapter
    return result


ADAPTERS = registry([anytls, hysteria2, trojan, vless, reality, vmess, tuic, shadowsocks, naive])
MODULE_DIRECTORY=os.environ.get('SBM_PROTOCOL_DIR','/var/lib/singbox-manager/protocols')
custom,MODULE_ERRORS=load_directory(MODULE_DIRECTORY)
ADAPTERS.update(registry(custom))


def get(kind):
    try:
        return ADAPTERS[kind]
    except (KeyError, TypeError):
        raise ValueError('未知节点类型：' + str(kind)) from None
