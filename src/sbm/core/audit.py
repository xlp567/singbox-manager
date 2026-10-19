"""Credential-free local audit chain. Detects corruption, not privileged rewriting."""
import datetime
import fcntl
import hashlib
import json
import os
import pathlib
import re
import uuid
from .storage import file_digest,sync_directory

FIELDS={'format','sequence','timestamp','event','action','result','snapshot','previous','hash'}
EVENTS={'action-start','action-finish','transaction-begin','transaction-commit','rollback',
        'recovery-start','recovery-finish','snapshot','draft-discard','audit-repair'}


def digest(row):
    return hashlib.sha256(json.dumps(row,sort_keys=True,separators=(',',':')).encode()).hexdigest()


def _verify(stream,tolerate=False):
    previous='0'*64; count=0
    stream.seek(0)
    for line in stream:
        count+=1
        try:
            if not line.endswith('\n'):raise ValueError()
            row=json.loads(line)
            if not isinstance(row,dict):raise ValueError()
            fields=FIELDS|{'previous_chain'} if row.get('format')==2 else FIELDS
            if set(row)!=fields or row['format'] not in {1,2} or row['sequence']!=count or row['previous']!=previous:
                raise ValueError()
            if row['format']==2:
                chain=row['previous_chain']
                if not isinstance(chain,dict):raise ValueError()
                if row['event']!='audit-repair' or set(chain)!={'file','sha256','last_valid_hash','valid_entries'}:raise ValueError()
                if not re.fullmatch(r'audit\.jsonl\.corrupt-[A-Za-z0-9_-]+',chain['file']):raise ValueError()
                if any(not re.fullmatch(r'[a-f0-9]{64}',chain[k]) for k in ['sha256','last_valid_hash']):raise ValueError()
                if type(chain['valid_entries']) is not int or chain['valid_entries']<0:raise ValueError()
            saved=row.pop('hash')
            if digest(row)!=saved or row['event'] not in EVENTS:raise ValueError()
        except (ValueError,KeyError,TypeError):
            if tolerate:return {'valid':False,'entries':count-1,'last_hash':previous,'broken_line':count}
            raise ValueError(f'审计链第 {count} 行损坏，拒绝继续写入') from None
        previous=saved
    return {'valid':True,'entries':count,'last_hash':previous}


def verify(path):
    path=pathlib.Path(path)
    if path.is_symlink():raise ValueError('审计文件不得为符号链接')
    if not path.exists():return {'valid':True,'entries':0,'last_hash':'0'*64}
    fd=os.open(str(path),os.O_RDONLY|os.O_NOFOLLOW)
    with os.fdopen(fd,'r') as stream:
        fcntl.flock(stream,fcntl.LOCK_SH)
        return _verify(stream)


def append(path,event,action,result,snapshot='',previous_chain=None):
    if event not in EVENTS or not re.fullmatch(r'[a-z0-9-]{1,40}',action):
        raise ValueError('审计事件或操作标识无效')
    if result not in {'started','ok','failed','cancelled','interrupted'}:raise ValueError('审计结果无效')
    if snapshot and not re.fullmatch(r'[A-Za-z0-9_-]{1,100}',snapshot):raise ValueError('审计快照标识无效')
    path=pathlib.Path(path)
    fd=os.open(str(path),os.O_RDWR|os.O_CREAT|os.O_APPEND|os.O_NOFOLLOW,0o600)
    with os.fdopen(fd,'r+') as stream:
        fcntl.flock(stream,fcntl.LOCK_EX)
        status=_verify(stream)
        row={'format':1,'sequence':status['entries']+1,'timestamp':datetime.datetime.now(datetime.timezone.utc).isoformat(),
             'event':event,'action':action,'result':result,'snapshot':snapshot,'previous':status['last_hash']}
        if previous_chain is not None:
            row.update(format=2,previous_chain=previous_chain)
        row['hash']=digest(row)
        stream.seek(0,os.SEEK_END);stream.write(json.dumps(row,separators=(',',':'))+'\n');stream.flush();os.fsync(stream.fileno())
        os.fchmod(stream.fileno(),0o600)
    fd=os.open(str(path.parent),os.O_RDONLY)
    try:os.fsync(fd)
    finally:os.close(fd)


def repair(path):
    path=pathlib.Path(path)
    if path.name!='audit.jsonl' or path.is_symlink():raise ValueError('审计修复路径无效')
    if not path.exists():return {'changed':False,'reason':'审计文件不存在'}
    fd=os.open(str(path),os.O_RDWR|os.O_NOFOLLOW)
    with os.fdopen(fd,'r',encoding='utf8',errors='replace') as stream:
        fcntl.flock(stream,fcntl.LOCK_EX)
        status=_verify(stream,tolerate=True)
        if status['valid']:return {'changed':False,'reason':'审计链完整，无需修复'}
        stamp=datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')+'-'+uuid.uuid4().hex[:8]
        archive=path.with_name('audit.jsonl.corrupt-'+stamp)
        chain={'file':archive.name,'sha256':file_digest(path),'last_valid_hash':status['last_hash'],'valid_entries':status['entries']}
        os.rename(path,archive);os.chmod(archive,0o600);sync_directory(path.parent)
        append(path,'audit-repair','audit-repair','ok',previous_chain=chain)
    return {'changed':True,'archive':str(archive),'previous_chain':chain}
