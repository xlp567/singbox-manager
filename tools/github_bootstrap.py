"""Optional private-source entry; uses the same signed Release bootstrap."""
import getpass
import os
import pathlib
import re
import sys
sys.path.insert(0,str(pathlib.Path(__file__).resolve().parents[1]/'src'))
sys.path.insert(0,str(pathlib.Path(__file__).resolve().parents[1]))
from tools import public_bootstrap


def launch():
    if sys.platform!='linux' or os.geteuid()!=0:raise ValueError('请在 Debian/Ubuntu 上以 root 执行')
    token=getpass.getpass('GitHub 只读令牌（隐藏输入）: ').strip()
    if not re.fullmatch(r'[A-Za-z0-9_]{10,255}',token):raise ValueError('令牌格式无效')
    return public_bootstrap.launch(token)


if __name__=='__main__':launch()
