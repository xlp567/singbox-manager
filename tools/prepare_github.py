#!/usr/bin/env python3
"""Create a source-only upload manifest, excluding all server data and caches."""
import argparse
import json
import pathlib
import re
from privacy_guard import check_manifest, private_values

ROOT=pathlib.Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser();parser.add_argument('--output',required=True)
parser.add_argument('--require-private',action='store_true',help='require a non-empty unpublished private identifier list')
args=parser.parse_args()
try:values=private_values(ROOT,args.require_private)
except (ValueError,OSError):raise SystemExit('FAIL privacy guard: 私有标识符清单缺失、为空或无效；未生成发布清单。') from None
files=[]
for name in ['README.md','LICENSE','CONTRIBUTING.md','SECURITY.md','AGENTS.md','RELEASING.md','RELEASE_SIGNING.pub','使用说明.md','架构与扩展.md','自定义协议模块.md','测试与部署结果.md','文件目录速查.md','管理脚本升级.md',
             'singbox-manager.sh','singbox-manager.sha256','install.py','install.sh','README.en.md','docs','CHANGELOG.md','新服务器安装.md','新服务器一键安装命令.txt','.gitignore','src','tools','tests','examples',
             '2.4版本备份/singbox-manager.sh','3.0版本备份/singbox-manager.sh','reports/PUBLIC_VALIDATION.md']:
    base=ROOT/name
    for p in sorted(base.rglob('*')) if base.is_dir() else [base]:
        if not p.is_file() or p.is_symlink() or '__pycache__' in p.parts or p.suffix=='.pyc' or p.name=='.DS_Store' or p.name.startswith('._'):continue
        data=p.read_text();rel=str(p.relative_to(ROOT))
        if re.search(r'^-----BEGIN (?:OPENSSH|RSA|EC) PRIVATE KEY-----$',data,re.M):
            raise ValueError('发现私钥，拒绝生成上传清单：'+rel)
        files.append({'path':rel,'mode':'100755' if rel.endswith('.sh') else '100644','type':'blob','content':data})
findings=check_manifest(files,values)
if findings:
    raise SystemExit(json.dumps({'privacy':'FAIL','findings':findings},ensure_ascii=False,indent=2))
pathlib.Path(args.output).write_text(json.dumps(files,ensure_ascii=False))
print(f'Prepared {len(files)} source / documentation / sanitized evidence files; excluded .cache, dist and private server state')
