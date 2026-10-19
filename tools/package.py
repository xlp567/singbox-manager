#!/usr/bin/env python3
"""Package only publishable source and evidence. Never includes .cache or credentials."""
import hashlib
import pathlib
import tarfile
import re

ROOT=pathlib.Path(__file__).resolve().parents[1]
DEST=ROOT/'dist'
DEST.mkdir(exist_ok=True)
names=['README.md','LICENSE','CONTRIBUTING.md','README.en.md','CHANGELOG.md','docs','管理脚本升级.md','singbox-manager.sh','singbox-manager.sha256','install.py','install.sh','新服务器安装.md','新服务器一键安装命令.txt','使用说明.md','架构与扩展.md','自定义协议模块.md',
       '测试与部署结果.md','文件目录速查.md','src','tools','tests','examples','reports','2.4版本备份','3.0版本备份','.gitignore']
version=re.search(r'^SBM_VERSION=([0-9.]+)$',(ROOT/'src/manager-core.sh').read_text(),re.M)[1]
prefix='singbox-manager-v'+version
archive=DEST/(prefix+'.tar.gz')
def select(info):
    if '__pycache__' in info.name or pathlib.PurePosixPath(info.name).name=='.DS_Store' or pathlib.PurePosixPath(info.name).name.startswith('._'):
        return None
    info.uid=info.gid=0; info.uname=info.gname='root'
    return info
with tarfile.open(archive,'w:gz',format=tarfile.PAX_FORMAT) as tar:
    for name in names:
        tar.add(ROOT/name,arcname=prefix+'/'+name,filter=select)
with tarfile.open(archive) as tar:
    members=tar.getnames()
    assert not any('/.cache/' in n or '/private/' in n or 'askpass' in n for n in members)
    file=tar.extractfile(prefix+'/singbox-manager.sh').read()
    assert hashlib.sha256(file).hexdigest()==(ROOT/'singbox-manager.sha256').read_text().split()[0]
digest=hashlib.sha256(archive.read_bytes()).hexdigest()
(DEST/'SHA256SUMS').write_text(digest+'  '+archive.name+'\n')
print(f'Packaged {archive.name}: {archive.stat().st_size} bytes, SHA-256 {digest}')
