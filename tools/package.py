#!/usr/bin/env python3
"""Package only publishable source and evidence. Never includes .cache or credentials."""
import hashlib
import pathlib
import tarfile

ROOT=pathlib.Path(__file__).resolve().parents[1]
DEST=ROOT/'dist'
DEST.mkdir(exist_ok=True)
names=['README.md','管理脚本升级.md','singbox-manager.sh','singbox-manager.sha256','使用说明.md','架构与扩展.md','自定义协议模块.md',
       '测试与部署结果.md','文件目录速查.md','src','tools','tests','examples','reports','2.4版本备份','3.0版本备份','.gitignore']
archive=DEST/'singbox-manager-v3.5.1.tar.gz'
def select(info):
    if '__pycache__' in info.name or pathlib.PurePosixPath(info.name).name=='.DS_Store' or pathlib.PurePosixPath(info.name).name.startswith('._'):
        return None
    info.uid=info.gid=0; info.uname=info.gname='root'
    return info
with tarfile.open(archive,'w:gz',format=tarfile.PAX_FORMAT) as tar:
    for name in names:
        tar.add(ROOT/name,arcname='singbox-manager-v3.5.1/'+name,filter=select)
with tarfile.open(archive) as tar:
    members=tar.getnames()
    assert not any('/.cache/' in n or '/private/' in n or 'askpass' in n for n in members)
    file=tar.extractfile('singbox-manager-v3.5.1/singbox-manager.sh').read()
    assert hashlib.sha256(file).hexdigest()==(ROOT/'singbox-manager.sha256').read_text().split()[0]
digest=hashlib.sha256(archive.read_bytes()).hexdigest()
(DEST/'SHA256SUMS').write_text(digest+'  '+archive.name+'\n')
print(f'Packaged {archive.name}: {archive.stat().st_size} bytes, SHA-256 {digest}')
