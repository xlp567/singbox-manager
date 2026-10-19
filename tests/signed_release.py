"""Disposable signing keys and signed payloads; never uses the release private key."""
import base64
import contextlib
import hashlib
import io
import pathlib
import re
import subprocess
import zipfile
from unittest.mock import patch
from common import ROOT


class SignedRelease:
    def __init__(self,root,files=None,tag='v3.5.6',rekey_bundle=False):
        self.root=pathlib.Path(root);self.root.mkdir(parents=True,exist_ok=True)
        key=self.root/'fixture-signing-key'
        subprocess.run(['ssh-keygen','-q','-t','ed25519','-N','','-f',str(key)],check=True)
        self.key=key;self.public=key.with_suffix('.pub').read_text().strip()
        self.tag=tag;self.commit='a'*40
        if files is None:
            data=(ROOT/'singbox-manager.sh').read_bytes()
            if rekey_bundle:data=self.rekey(data)
            files={'singbox-manager.sh':data,'singbox-manager.sha256':(hashlib.sha256(data).hexdigest()+'  singbox-manager.sh\n').encode()}
        self.files=dict(files);self.resign()

    def rekey(self,data):
        match=re.search(rb"<<'SBM_BUNDLE'\n([A-Za-z0-9+/=\s]+)\nSBM_BUNDLE",data)
        source=base64.b64decode(match[1]);out=io.BytesIO()
        previous=(ROOT/'RELEASE_SIGNING.pub').read_text().strip().encode()
        with zipfile.ZipFile(io.BytesIO(source)) as old,zipfile.ZipFile(out,'w') as new:
            for item in old.infolist():new.writestr(item,old.read(item).replace(previous,self.public.encode()))
        return data[:match.start(1)]+base64.encodebytes(out.getvalue()).rstrip()+data[match.end(1):]

    def resign(self):
        for name,data in self.files.items():(self.root/name).write_bytes(data)
        manifest=('# singbox-manager release '+self.tag+'\n'+''.join(hashlib.sha256(data).hexdigest()+'  '+name+'\n' for name,data in sorted(self.files.items()))).encode()
        path=self.root/'SHA256SUMS';path.write_bytes(manifest);(self.root/'SHA256SUMS.sig').unlink(missing_ok=True)
        subprocess.run(['ssh-keygen','-q','-Y','sign','-f',str(self.key),'-n','singbox-manager-release',str(path)],check=True,capture_output=True)
        payload=dict(self.files,**{'SHA256SUMS':manifest,'SHA256SUMS.sig':(self.root/'SHA256SUMS.sig').read_bytes()})
        self.payload=payload;self.ids={i:name for i,name in enumerate(sorted(payload),100)}
        self.release={'tag_name':self.tag,'draft':False,'prerelease':False,'target_commitish':self.commit,
                      'assets':[{'name':name,'id':i,'size':len(payload[name])} for i,name in self.ids.items()]}

    def request(self,url,token=''):
        if url.endswith('/releases/latest'):return self.release
        if '/git/ref/tags/' in url:return {'object':{'type':'commit','sha':self.commit}}
        raise AssertionError('Unexpected release request')

    def asset(self,url,token=''):return self.payload[self.ids[int(url.rsplit('/',1)[1])]]

    def activate(self,*modules):
        stack=contextlib.ExitStack();seen=set()
        for module in modules:
            for name in ['download_release','verify_directory','verify_signature']:
                function=getattr(module,name,None)
                if function is not None and id(function.__globals__) not in seen:
                    namespace=function.__globals__;seen.add(id(namespace))
                    stack.enter_context(patch.dict(namespace,{'PUBLIC_KEY':self.public}))
        return stack
