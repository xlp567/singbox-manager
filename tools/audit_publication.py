#!/usr/bin/env python3
"""Read-only privacy checks of a fetched Git mirror and downloaded releases.

Fetch all public refs and download every Release's notes/assets before invoking.
Never point this at private recovery mirrors. Output contains no matched values.
"""
import argparse
import io
import json
import pathlib
import subprocess
import tarfile
import zipfile
from privacy_guard import scan_text,private_values


def scan_payload(label,data,values=(),depth=0):
    if depth>3:raise ValueError('archive nesting exceeds review limit')
    findings=[]
    if data.startswith(b'\x1f\x8b'):
        with tarfile.open(fileobj=io.BytesIO(data),mode='r:gz') as archive:
            for member in archive:
                if member.isfile():
                    if member.size>16*1024*1024:raise ValueError('archive member exceeds review limit')
                    findings.extend(scan_payload(label+'::'+member.name,archive.extractfile(member).read(),values,depth+1))
    elif data.startswith(b'PK\x03\x04'):
        with zipfile.ZipFile(io.BytesIO(data)) as archive:
            for member in archive.infolist():
                if not member.is_dir():
                    if member.file_size>16*1024*1024:raise ValueError('archive member exceeds review limit')
                    findings.extend(scan_payload(label+'::'+member.filename,archive.read(member),values,depth+1))
    else:
        try:text=data.decode('utf8')
        except UnicodeError:raise ValueError('unexpected binary publication payload') from None
        findings.extend(scan_text(label,text,values))
    return findings


def scan_git(directory,values=()):
    def git(*args):return subprocess.check_output(['git','--git-dir='+str(directory),*args])
    commits=git('rev-list','--all').splitlines();objects={};findings=[]
    for commit in commits:
        findings.extend(scan_payload('commit/'+commit.decode()[:12],git('cat-file','commit',commit.decode()),values))
        for record in git('ls-tree','-r','-z',commit.decode()).split(b'\0'):
            if not record:continue
            header,path=record.split(b'\t',1);_,kind,oid=header.split()
            if kind==b'blob':objects.setdefault(oid,path.decode())
    for line in git('for-each-ref','--format=%(objecttype) %(objectname)').splitlines():
        kind,oid=line.split()
        if kind==b'tag':findings.extend(scan_payload('tag/'+oid.decode()[:12],git('cat-file','tag',oid.decode()),values))
    for oid,path in objects.items():
        findings.extend(scan_payload('history/'+oid.decode()[:12]+'/'+path,git('cat-file','blob',oid.decode()),values))
    return {'commits':len(commits),'blobs':len(objects),'refs':len(git('for-each-ref','--format=%(refname)').splitlines())},findings


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--git-dir',type=pathlib.Path,required=True)
    parser.add_argument('--releases',type=pathlib.Path,required=True,help='downloaded notes, assets and generated source archives')
    parser.add_argument('--output',type=pathlib.Path,required=True)
    parser.add_argument('--require-private',action='store_true',help='require the unpublished private identifier list')
    args=parser.parse_args();root=pathlib.Path(__file__).resolve().parents[1]
    try:values=private_values(root,args.require_private)
    except (ValueError,OSError):raise SystemExit('FAIL privacy audit: 私有标识符清单缺失、为空或无效。') from None
    stats,findings=scan_git(args.git_dir,values);count=0
    for path in sorted(args.releases.rglob('*')):
        if path.is_symlink():raise ValueError('publication input must not contain symlinks')
        if path.is_file():
            findings.extend(scan_payload('releases/'+str(path.relative_to(args.releases)),path.read_bytes(),values));count+=1
    report={'privacy':'FAIL' if findings else 'PASS','history':stats,'release_files':count,'findings':findings}
    args.output.write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
    print(json.dumps({'privacy':report['privacy'],'history':stats,'release_files':count,'findings':len(findings)}))
    return 1 if findings else 0


if __name__=='__main__':raise SystemExit(main())
