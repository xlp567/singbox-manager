"""Strict, bounded bridge to the fourth layer: a supplied sing-box executable."""
import pathlib
import re
import subprocess
import json
import tempfile


def version_key(value):
    match=re.fullmatch(r'(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?',value)
    if not match: raise ValueError('无法识别 sing-box 版本：'+str(value))
    base=tuple(int(x) for x in match.groups()[:3]); pre=match[4]
    return base+((1,) if not pre else (0,)+tuple((0,int(x)) if x.isdigit() else (1,x) for x in pre.split('.')),)


class Runtime:
    def __init__(self,binary):
        self.binary=str(pathlib.Path(binary).resolve())
        result=subprocess.run([self.binary,'version'],capture_output=True,text=True,timeout=15,check=True)
        match=re.search(r'^sing-box version (\S+)$',result.stdout,re.M)
        if not match: raise ValueError('运行程序没有返回可识别的 sing-box 版本')
        self.version=match[1]; version_key(self.version)
        tags=re.search(r'^Tags:\s*(.*)$',result.stdout,re.M)
        self.tags=set(tags[1].replace(' ',',').split(','))-{''} if tags else set()

    def info(self):
        directory=pathlib.Path(self.binary).parent
        return {'version':self.version,'tags':sorted(self.tags),
                'adjacent_libraries':[name for name in ['libcronet.so','libcronet.dylib','libcronet.dll'] if (directory/name).is_file()]}

    def check(self,config):
        # Do not return runtime stderr: it may include credentials from invalid configs.
        result=subprocess.run([self.binary,'check','-c',str(config)],capture_output=True,text=True,timeout=30)
        return {'passed':result.returncode==0,'exit_code':result.returncode}

    def schema(self):
        """Ask this exact binary, never use a newer website schema as a fallback."""
        if version_key(self.version)<version_key('1.14.0'):
            raise ValueError('自动发现需要 sing-box >= 1.14.0；请先通过菜单 10 升级官方核心')
        with tempfile.TemporaryDirectory(prefix='sbm-official-schema-') as td:
            path=pathlib.Path(td)/'schema.json'
            result=subprocess.run([self.binary,'schema','-o',str(path)],capture_output=True,timeout=30)
            if result.returncode or not path.is_file() or path.stat().st_size>8*1024*1024:
                raise ValueError('当前核心无法导出有效 Schema；未使用网络缓存或修改节点')
            data=json.loads(path.read_text())
        if not isinstance(data,dict) or data.get('$schema')!='https://json-schema.org/draft/2020-12/schema':
            raise ValueError('当前核心返回了不支持的 Schema 格式')
        return data
