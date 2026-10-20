#!/usr/bin/env python3
"""Package only publishable source and evidence. Never includes .cache or credentials."""
import hashlib
import gzip
import io
import json
import pathlib
import subprocess
import sys
import tarfile
import re
import tempfile
import argparse

ROOT=pathlib.Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--require-private',action='store_true',help='require the unpublished private identifier list before packaging')
args=parser.parse_args()
DEST=ROOT/'dist'
DEST.mkdir(exist_ok=True)
version=re.search(r'^SBM_VERSION=([0-9.]+)$',(ROOT/'src/manager-core.sh').read_text(),re.M)[1]
prefix='singbox-manager-v'+version
archive=DEST/(prefix+'.tar.gz')
# Use exactly the same allowlist and contents as the GitHub source publication.
# In particular, old nested archives and unpublished server evidence stay out.
with tempfile.TemporaryDirectory(prefix='sbm-package-') as temporary:
    manifest=pathlib.Path(temporary)/'manifest.json'
    command=[sys.executable,str(ROOT/'tools/prepare_github.py'),'--output',str(manifest)]
    if args.require_private:command.append('--require-private')
    prepared=subprocess.run(command,capture_output=True,text=True)
    if prepared.stderr:print(prepared.stderr,end='',file=sys.stderr)
    if prepared.returncode:raise SystemExit(prepared.stdout or '发布隐私门禁失败，未打包')
    files=json.loads(manifest.read_text())
with archive.open('wb') as output,gzip.GzipFile(filename='',mode='wb',fileobj=output,mtime=0) as compressed:
    with tarfile.open(fileobj=compressed,mode='w',format=tarfile.PAX_FORMAT) as tar:
        for item in sorted(files,key=lambda item:item['path']):
            data=item['content'].encode()
            info=tarfile.TarInfo(prefix+'/'+item['path'])
            info.size=len(data);info.mode=int(item['mode'],8);info.mtime=0
            info.uid=info.gid=0;info.uname=info.gname='root'
            tar.addfile(info,io.BytesIO(data))
with tarfile.open(archive) as tar:
    members=tar.getnames()
    assert not any('/.cache/' in n or '/private/' in n or 'askpass' in n for n in members)
    file=tar.extractfile(prefix+'/singbox-manager.sh').read()
    assert hashlib.sha256(file).hexdigest()==(ROOT/'singbox-manager.sha256').read_text().split()[0]
digest=hashlib.sha256(archive.read_bytes()).hexdigest()
payloads={archive.name:archive.read_bytes()}
for name in ['singbox-manager.sh','singbox-manager.sha256','install.py','install.sh','RELEASE_SIGNING.pub']:
    payloads[name]=(ROOT/name).read_bytes()
(DEST/'SHA256SUMS').write_text('# singbox-manager release v'+version+'\n'+''.join(hashlib.sha256(data).hexdigest()+'  '+name+'\n' for name,data in sorted(payloads.items())))
stage=DEST/('release-v'+version);stage.mkdir(exist_ok=True)
for name,data in payloads.items():(stage/name).write_bytes(data)
(stage/'SHA256SUMS').write_bytes((DEST/'SHA256SUMS').read_bytes())
print(f'Packaged {archive.name}: {len(files)} published files, {archive.stat().st_size} bytes, SHA-256 {digest}')
