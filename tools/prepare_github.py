#!/usr/bin/env python3
"""Create a source-only upload manifest, excluding all server data and caches."""
import argparse
import json
import pathlib
import re

ROOT=pathlib.Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser();parser.add_argument('--output',required=True);args=parser.parse_args()
files=[]
for name in ['README.md','LICENSE','CONTRIBUTING.md','使用说明.md','架构与扩展.md','自定义协议模块.md','测试与部署结果.md','文件目录速查.md','管理脚本升级.md',
             'singbox-manager.sh','singbox-manager.sha256','install.py','install.sh','README.en.md','docs','CHANGELOG.md','新服务器安装.md','新服务器一键安装命令.txt','.gitignore','src','tools','tests','examples',
             '2.4版本备份/singbox-manager.sh','3.0版本备份/singbox-manager.sh','reports/v3.5.1','reports/v3.5.2','reports/v3.5.3','reports/v3.5.4']:
    base=ROOT/name
    for p in sorted(base.rglob('*')) if base.is_dir() else [base]:
        if not p.is_file() or p.is_symlink() or '__pycache__' in p.parts or p.suffix=='.pyc' or p.name=='.DS_Store' or p.name.startswith('._'):continue
        data=p.read_text();rel=str(p.relative_to(ROOT))
        if re.search(r'^-----BEGIN (?:OPENSSH|RSA|EC) PRIVATE KEY-----$',data,re.M):
            raise ValueError('发现私钥，拒绝生成上传清单：'+rel)
        files.append({'path':rel,'mode':'100755' if rel.endswith('.sh') else '100644','type':'blob','content':data})
pathlib.Path(args.output).write_text(json.dumps(files,ensure_ascii=False))
print(f'Prepared {len(files)} source / documentation / sanitized evidence files; excluded .cache, dist and private server state')
