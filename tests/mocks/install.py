import os, pathlib, shutil, sys
args=sys.argv[1:]; mode=0o755; directory=False; parents=False; files=[]
while args:
    x=args.pop(0)
    if x=='-m': mode=int(args.pop(0),8)
    elif x=='-d': directory=True
    elif x=='-D': parents=True
    else: files.append(x)
if directory:
    for f in files: pathlib.Path(f).mkdir(parents=True,exist_ok=True); os.chmod(f,mode)
else:
    src,dst=map(pathlib.Path,files)
    if parents: dst.parent.mkdir(parents=True,exist_ok=True)
    shutil.copyfile(src,dst); os.chmod(dst,mode)
