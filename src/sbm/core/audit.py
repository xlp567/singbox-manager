"""Credential-free local audit chain. Detects corruption, not privileged rewriting."""
import datetime
import fcntl
import gzip
import hashlib
import io
import json
import os
import pathlib
import re
import tempfile
import uuid
from .storage import file_digest,sync_directory

FIELDS={'format','sequence','timestamp','event','action','result','snapshot','previous','hash'}
EVENTS={'action-start','action-finish','transaction-begin','transaction-commit','rollback',
        'recovery-start','recovery-finish','snapshot','draft-discard','audit-repair','audit-rotate'}
# Appends verify only the current segment, so cost stays bounded. Sealed segments
# are gzip files linked by hash; the oldest are pruned beyond KEEP_SEGMENTS.
ROTATE_ENTRIES=5000
ROTATE_BYTES=2*1024*1024
KEEP_SEGMENTS=20
SEGMENT=r'[A-Za-z0-9_.-]+\.[0-9]{8}T[0-9]{6}Z-[a-f0-9]{8}\.gz'


def digest(row):
    return hashlib.sha256(json.dumps(row,sort_keys=True,separators=(',',':')).encode()).hexdigest()


def _verify(stream,tolerate=False):
    previous='0'*64; count=0; anchor=None
    stream.seek(0)
    for line in stream:
        count+=1
        try:
            if not line.endswith('\n'):raise ValueError()
            row=json.loads(line)
            if not isinstance(row,dict):raise ValueError()
            fields={2:FIELDS|{'previous_chain'},3:FIELDS|{'previous_segment'}}.get(row.get('format'),FIELDS)
            if row.get('format')==3:
                # A rotation row may only open a segment; it continues the sealed chain.
                segment=row.get('previous_segment')
                if count!=1 or row.get('event')!='audit-rotate' or not isinstance(segment,dict):raise ValueError()
                if set(segment)!={'file','sha256','last_hash','entries'} or not re.fullmatch(SEGMENT,str(segment['file'])):raise ValueError()
                if any(not re.fullmatch(r'[a-f0-9]{64}',str(segment[k])) for k in ['sha256','last_hash']):raise ValueError()
                if type(segment['entries']) is not int or segment['entries']<1:raise ValueError()
                previous=segment['last_hash'];anchor=dict(segment)
            if set(row)!=fields or row['format'] not in {1,2,3} or row['sequence']!=count or row['previous']!=previous:
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
    return {'valid':True,'entries':count,'last_hash':previous,'anchor':anchor}


def _segments(path):
    pattern=re.escape(path.name)+r'\.[0-9]{8}T[0-9]{6}Z-[a-f0-9]{8}\.gz'
    return sorted(p for p in path.parent.iterdir() if re.fullmatch(pattern,p.name) and p.is_file() and not p.is_symlink())


def _history(path,anchor):
    """Walk back through retained sealed segments; a pruned link ends the walk."""
    segments=0;entries=0;truncated=False
    while anchor:
        sealed=path.parent/anchor['file']
        if sealed.is_symlink() or not sealed.is_file():truncated=True;break
        if file_digest(sealed)!=anchor['sha256']:raise ValueError('已封存审计段摘要不符：'+anchor['file'])
        with gzip.open(sealed,'rt',encoding='utf8') as raw:status=_verify(io.StringIO(raw.read()))
        if status['entries']!=anchor['entries'] or status['last_hash']!=anchor['last_hash']:raise ValueError('已封存审计段与链接记录不符：'+anchor['file'])
        segments+=1;entries+=status['entries'];anchor=status['anchor']
    return {'segments':segments,'sealed_entries':entries,'history_truncated':truncated}


def verify(path):
    path=pathlib.Path(path)
    if path.is_symlink():raise ValueError('审计文件不得为符号链接')
    if not path.exists():return {'valid':True,'entries':0,'last_hash':'0'*64,'segments':0,'sealed_entries':0,'history_truncated':False}
    fd=os.open(str(path),os.O_RDONLY|os.O_NOFOLLOW)
    with os.fdopen(fd,'r') as stream:
        fcntl.flock(stream,fcntl.LOCK_SH)
        status=_verify(stream)
        anchor=status.pop('anchor')
        status.update(_history(path,anchor))
        return status


def _rotate(path,stream,status):
    """Seal the verified current segment and open a new one linked to its last hash."""
    stamp=datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')+'-'+uuid.uuid4().hex[:8]
    sealed=path.with_name(path.name+'.'+stamp+'.gz')
    stream.seek(0);data=stream.read().encode()
    fd,temporary=tempfile.mkstemp(prefix='.'+path.name+'.seal-',dir=path.parent)
    try:
        with os.fdopen(fd,'wb') as raw:
            with gzip.GzipFile(filename='',mode='wb',fileobj=raw,mtime=0) as packed:packed.write(data)
            raw.flush();os.fsync(raw.fileno());os.fchmod(raw.fileno(),0o400)
        os.replace(temporary,sealed)
    finally:
        if os.path.exists(temporary):os.unlink(temporary)
    sync_directory(path.parent)
    segment={'file':sealed.name,'sha256':file_digest(sealed),'last_hash':status['last_hash'],'entries':status['entries']}
    row={'format':3,'sequence':1,'timestamp':datetime.datetime.now(datetime.timezone.utc).isoformat(),'event':'audit-rotate',
         'action':'audit-rotate','result':'ok','snapshot':'','previous':segment['last_hash'],'previous_segment':segment}
    row['hash']=digest(row)
    fd,temporary=tempfile.mkstemp(prefix='.'+path.name+'.new-',dir=path.parent)
    try:
        with os.fdopen(fd,'w') as fresh:
            fresh.write(json.dumps(row,separators=(',',':'))+'\n');fresh.flush();os.fsync(fresh.fileno());os.fchmod(fresh.fileno(),0o600)
        os.replace(temporary,path)
    finally:
        if os.path.exists(temporary):os.unlink(temporary)
    sync_directory(path.parent)
    # Keep the newest KEEP_SEGMENTS by following hash links from the new head;
    # names are not ordered within one second, and orphans from a crash are dropped.
    keep=set();anchor=segment
    while anchor and len(keep)<KEEP_SEGMENTS:
        sealed=path.parent/anchor['file']
        if sealed.is_symlink() or not sealed.is_file():break
        keep.add(sealed.name)
        with gzip.open(sealed,'rt',encoding='utf8') as raw:first=raw.readline()
        try:head=json.loads(first)
        except ValueError:break
        anchor=head.get('previous_segment') if isinstance(head,dict) and head.get('format')==3 else None
    for old in _segments(path):
        if old.name not in keep:old.unlink()
    sync_directory(path.parent)


def append(path,event,action,result,snapshot='',previous_chain=None):
    if event not in EVENTS or not re.fullmatch(r'[a-z0-9-]{1,40}',action):
        raise ValueError('审计事件或操作标识无效')
    if result not in {'started','ok','failed','cancelled','interrupted'}:raise ValueError('审计结果无效')
    if snapshot and not re.fullmatch(r'[A-Za-z0-9_-]{1,100}',snapshot):raise ValueError('审计快照标识无效')
    path=pathlib.Path(path)
    while True:
        fd=os.open(str(path),os.O_RDWR|os.O_CREAT|os.O_APPEND|os.O_NOFOLLOW,0o600)
        stream=os.fdopen(fd,'r+')
        fcntl.flock(stream,fcntl.LOCK_EX)
        # Another writer may have rotated the file while this one waited for the lock.
        try:same=os.fstat(stream.fileno()).st_ino==os.stat(path,follow_symlinks=False).st_ino
        except FileNotFoundError:same=False
        if not same:stream.close();continue
        status=_verify(stream)
        if status['entries']>=ROTATE_ENTRIES or os.fstat(stream.fileno()).st_size>=ROTATE_BYTES:
            _rotate(path,stream,status);stream.close();continue
        break
    with stream:
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
