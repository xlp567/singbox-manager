#!/usr/bin/env python3
"""Sign staged release hashes with an explicitly provided, unpublished key."""
import argparse
import pathlib
import subprocess
import sys

ROOT=pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'src'))
from sbm.core.release_trust import PUBLIC_KEY,NAMESPACE,verify_directory,parse_manifest


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--key',required=True,type=pathlib.Path)
    parser.add_argument('--directory',required=True,type=pathlib.Path)
    args=parser.parse_args();key=args.key;root=args.directory
    if key.is_symlink() or not key.is_file() or key.stat().st_mode&0o077:raise ValueError('签名私钥必须为权限 600 的普通私有文件')
    public=subprocess.check_output(['ssh-keygen','-y','-f',str(key)],text=True).strip().split()[:2]
    if public!=PUBLIC_KEY.split()[:2]:raise ValueError('私钥与固定发布公钥不匹配')
    manifest=root/'SHA256SUMS'
    if manifest.is_symlink() or not manifest.is_file():raise ValueError('签名清单路径无效')
    signature=root/'SHA256SUMS.sig'
    if signature.is_symlink():raise ValueError('签名目标不得为符号链接')
    signature.unlink(missing_ok=True)
    subprocess.run(['ssh-keygen','-q','-Y','sign','-f',str(key),'-n',NAMESPACE,str(manifest)],check=True)
    signed_tag,files=parse_manifest(manifest.read_bytes())
    tag=verify_directory(root,tuple(files),signed_tag)
    print('PASS signed release '+tag+'; private key is not part of publication')


if __name__=='__main__':main()
