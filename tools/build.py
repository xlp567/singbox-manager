#!/usr/bin/env python3
"""Build a reproducible, standalone Bash script with a bundled Python zipapp."""
import base64
import hashlib
import io
import pathlib
import zipfile
import re

ROOT = pathlib.Path(__file__).resolve().parents[1]


def build():
    from build_install_command import build as install_command
    install_command()
    stream = io.BytesIO()
    with zipfile.ZipFile(stream, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
        files = {str(p.relative_to(ROOT / 'src')): p.read_bytes()
                 for p in sorted((ROOT / 'src/sbm').rglob('*.py'))}
        files['__main__.py'] = b'from sbm.entrypoint import run\nrun()\n'
        for name, data in sorted(files.items()):
            info = zipfile.ZipInfo(name, (2026, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o600 << 16
            archive.writestr(info, data)
    encoded = base64.encodebytes(stream.getvalue()).decode()
    core = (ROOT / 'src/manager-core.sh').read_text()
    core = re.sub(r'^# @include (core/[a-z-]+\.sh)$',
                  lambda m: (ROOT / 'src' / m[1]).read_text().rstrip(), core, flags=re.M)
    emit = "emit_engine() {\n    base64 -d <<'SBM_BUNDLE'\n"
    result = core + emit + encoded + "SBM_BUNDLE\n}\nif [[ ${BASH_SOURCE[0]} == \"$0\" ]]; then main \"$@\"; fi\n"
    path = ROOT / 'singbox-manager.sh'
    path.write_text(result)
    path.chmod(0o755)
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    (ROOT / 'singbox-manager.sha256').write_text(digest + '  singbox-manager.sh\n')
    version=re.search(r'^SBM_VERSION=([0-9.]+)$',core,re.M)[1]
    print(f'Built v{version}: {len(result.encode())} bytes, SHA-256 {digest}')


if __name__ == '__main__':
    build()
