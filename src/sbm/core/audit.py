"""Credential-free local audit chain. Detects corruption, not privileged rewriting."""
import datetime
import contextlib
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
LEGACY_KEEP_SEGMENTS=20
SEGMENT=r'[A-Za-z0-9_.-]+\.[0-9]{8}T[0-9]{6}Z-[a-f0-9]{8}\.gz'


def digest(row):
    return hashlib.sha256(json.dumps(row,sort_keys=True,separators=(',',':')).encode()).hexdigest()


@contextlib.contextmanager
def _locked(path,exclusive=True):
    """Keep the same lock inode across replacement of the current log."""
    if path.is_symlink():raise OSError('审计文件不得为符号链接')
    try:fd=os.open(str(path)+'.lock',os.O_RDWR|os.O_CREAT|os.O_NOFOLLOW,0o600)
    except OSError:raise ValueError('无法安全打开审计锁文件') from None
    try:
        fcntl.flock(fd,fcntl.LOCK_EX if exclusive else fcntl.LOCK_SH)
        os.fchmod(fd,0o600)
        yield
    finally:
        # Explicit unlock also releases a lock description inherited across fork.
        fcntl.flock(fd,fcntl.LOCK_UN);os.close(fd)


def _valid_reference(reference):
    return (isinstance(reference,dict) and set(reference)=={'file','sha256','last_hash','entries'}
            and isinstance(reference['file'],str) and re.fullmatch(SEGMENT,reference['file'])
            and all(isinstance(reference[k],str) and re.fullmatch(r'[a-f0-9]{64}',reference[k]) for k in ['sha256','last_hash'])
            and type(reference['entries']) is int and reference['entries']>0)


def _verify(stream,tolerate=False):
    previous='0'*64; count=0; anchor=None;boundary=None;proven=False
    stream.seek(0)
    for line in stream:
        count+=1
        try:
            if not line.endswith('\n'):raise ValueError()
            row=json.loads(line)
            if not isinstance(row,dict):raise ValueError()
            fields={2:FIELDS|{'previous_chain'},3:FIELDS|{'previous_segment'},
                    4:FIELDS|{'previous_segment','retention_boundary'}}.get(row.get('format'),FIELDS)
            if row.get('format') in {3,4}:
                # A rotation row may only open a segment; it continues the sealed chain.
                segment=row.get('previous_segment')
                if count!=1 or row.get('event')!='audit-rotate' or not _valid_reference(segment):raise ValueError()
                previous=segment['last_hash'];anchor=dict(segment)
                if row.get('format')==4:
                    boundary=row['retention_boundary'];proven=True
                    if boundary is not None and not _valid_reference(boundary):raise ValueError()
            if set(row)!=fields or row['format'] not in {1,2,3,4} or row['sequence']!=count or row['previous']!=previous:
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
    return {'valid':True,'entries':count,'last_hash':previous,'anchor':anchor,
            'retention_boundary':boundary,'retention_proven':proven}


def _segments(path):
    pattern=re.escape(path.name)+r'\.[0-9]{8}T[0-9]{6}Z-[a-f0-9]{8}\.gz'
    return sorted(p for p in path.parent.iterdir() if re.fullmatch(pattern,p.name) and p.is_file() and not p.is_symlink())


def _read_sealed(path,anchor):
    if not _valid_reference(anchor) or not anchor['file'].startswith(path.name+'.'):
        raise ValueError('已封存审计段链接无效')
    sealed=path.parent/anchor['file']
    if sealed.is_symlink() or not sealed.is_file():raise ValueError('已封存审计段缺失或不是普通文件：'+anchor['file'])
    if file_digest(sealed)!=anchor['sha256']:raise ValueError('已封存审计段摘要不符：'+anchor['file'])
    try:
        with gzip.open(sealed,'rt',encoding='utf8') as raw:status=_verify(io.StringIO(raw.read()))
    except (OSError,EOFError,UnicodeError):raise ValueError('已封存审计段无法读取：'+anchor['file']) from None
    if status['entries']!=anchor['entries'] or status['last_hash']!=anchor['last_hash']:
        raise ValueError('已封存审计段与链接记录不符：'+anchor['file'])
    return status


def _history(path,anchor,boundary=None,proven=False):
    """Only a hash-bound retention boundary proves deliberate pruning."""
    segments=0;entries=0;truncated=False;legacy=False;seen=set()
    while anchor:
        if anchor['file'] in seen:raise ValueError('审计段链接存在循环')
        seen.add(anchor['file'])
        sealed=path.parent/anchor['file']
        if sealed.is_symlink():raise ValueError('已封存审计段不得为符号链接')
        if proven and boundary is not None and anchor==boundary:truncated=True;break
        if not sealed.is_file():
            # v3.6.0 did not record pruning. Preserve compatibility with its full
            # retained window, but never assert that an unproved gap was pruning.
            if not proven and segments>=LEGACY_KEEP_SEGMENTS:truncated=True;legacy=True;break
            raise ValueError('已封存审计段缺失，且不是已记录的清理边界：'+anchor['file'])
        status=_read_sealed(path,anchor)
        segments+=1;entries+=status['entries'];anchor=status['anchor']
    if proven and boundary is not None and not truncated:raise ValueError('审计清理边界未出现在历史链接中')
    return {'segments':segments,'sealed_entries':entries,'history_truncated':truncated,
            'retention_verified':not legacy,'legacy_retention_unverified':legacy}


def _history_status(path,status):
    return _history(path,status['anchor'],status['retention_boundary'],status['retention_proven'])


def verify(path):
    path=pathlib.Path(path)
    with _locked(path,exclusive=False):
        if not path.exists():
            if _segments(path):raise ValueError('当前审计段缺失；请恢复审计资料后再校验')
            return dict(valid=True,entries=0,last_hash='0'*64,segments=0,sealed_entries=0,
                        history_truncated=False,retention_verified=True,legacy_retention_unverified=False)
        fd=os.open(str(path),os.O_RDONLY|os.O_NOFOLLOW)
        with os.fdopen(fd,'r') as stream:
            fcntl.flock(stream,fcntl.LOCK_SH);status=_verify(stream)
            history=_history_status(path,status)
            return dict(valid=status['valid'],entries=status['entries'],last_hash=status['last_hash'],**history)


def _retention_plan(path,anchor,old_status):
    keep=set();old_boundary=old_status['retention_boundary'] if old_status['retention_proven'] else None
    while anchor and len(keep)<KEEP_SEGMENTS:
        if anchor==old_boundary:return keep,anchor
        if anchor['file'] in keep:raise ValueError('审计段链接存在循环')
        status=_read_sealed(path,anchor);keep.add(anchor['file']);anchor=status['anchor']
    if anchor is not None and anchor!=old_boundary:_read_sealed(path,anchor)
    return keep,anchor


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
    try:keep,boundary=_retention_plan(path,segment,status)
    except BaseException:
        sealed.unlink();sync_directory(path.parent);raise
    row={'format':4,'sequence':1,'timestamp':datetime.datetime.now(datetime.timezone.utc).isoformat(),'event':'audit-rotate',
         'action':'audit-rotate','result':'ok','snapshot':'','previous':segment['last_hash'],
         'previous_segment':segment,'retention_boundary':boundary}
    row['hash']=digest(row)
    fd,temporary=tempfile.mkstemp(prefix='.'+path.name+'.new-',dir=path.parent)
    try:
        with os.fdopen(fd,'w') as fresh:
            fresh.write(json.dumps(row,separators=(',',':'))+'\n');fresh.flush();os.fsync(fresh.fileno());os.fchmod(fresh.fileno(),0o600)
        os.replace(temporary,path)
    finally:
        if os.path.exists(temporary):os.unlink(temporary)
    sync_directory(path.parent)
    # The new head records the boundary durably BEFORE any file is removed.
    # The stable lock remains held through replacement, pruning and append.
    for old in _segments(path):
        if old.name not in keep:old.unlink()
    sync_directory(path.parent)


def append(path,event,action,result,snapshot='',previous_chain=None):
    if event not in EVENTS or not re.fullmatch(r'[a-z0-9-]{1,40}',action):
        raise ValueError('审计事件或操作标识无效')
    if result not in {'started','ok','failed','cancelled','interrupted'}:raise ValueError('审计结果无效')
    if snapshot and not re.fullmatch(r'[A-Za-z0-9_-]{1,100}',snapshot):raise ValueError('审计快照标识无效')
    path=pathlib.Path(path)
    with _locked(path):_append_locked(path,event,action,result,snapshot,previous_chain)


def _append_locked(path,event,action,result,snapshot='',previous_chain=None):
    if not path.exists() and previous_chain is None and _segments(path):
        raise ValueError('当前审计段缺失，拒绝静默创建新链；请恢复审计资料')
    while True:
        fd=os.open(str(path),os.O_RDWR|os.O_CREAT|os.O_APPEND|os.O_NOFOLLOW,0o600)
        stream=os.fdopen(fd,'r+')
        try:
            fcntl.flock(stream,fcntl.LOCK_EX)
            # Retain the inode check for older writers without the sidecar lock.
            try:same=os.fstat(stream.fileno()).st_ino==os.stat(path,follow_symlinks=False).st_ino
            except FileNotFoundError:same=False
            if not same:stream.close();continue
            status=_verify(stream)
            if status['entries']>=ROTATE_ENTRIES or os.fstat(stream.fileno()).st_size>=ROTATE_BYTES:
                _rotate(path,stream,status);stream.close();continue
        except BaseException:
            stream.close();raise
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
    with _locked(path):return _repair_locked(path)


def _repair_locked(path):
    if not path.exists():
        if _segments(path):raise ValueError('当前审计段缺失；repair 无法重建丢失记录，请先恢复审计资料')
        return {'changed':False,'reason':'审计文件不存在'}
    fd=os.open(str(path),os.O_RDWR|os.O_NOFOLLOW)
    with os.fdopen(fd,'r',encoding='utf8',errors='replace') as stream:
        fcntl.flock(stream,fcntl.LOCK_EX)
        status=_verify(stream,tolerate=True)
        if status['valid']:
            history=_history_status(path,status)
            return {'changed':False,'reason':'现存段完整，但旧版清理边界无法核实' if history['legacy_retention_unverified'] else '审计链完整，无需修复'}
        stamp=datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')+'-'+uuid.uuid4().hex[:8]
        archive=path.with_name('audit.jsonl.corrupt-'+stamp)
        chain={'file':archive.name,'sha256':file_digest(path),'last_valid_hash':status['last_hash'],'valid_entries':status['entries']}
        # Preserve sealed history alongside the corrupt original; later retention
        # may remove the live names without deleting this repair evidence.
        sealed=_segments(path);sealed_archive=archive.with_name(archive.name+'.segments')
        if sealed:
            sealed_archive.mkdir(mode=0o700)
            for segment in sealed:os.link(segment,sealed_archive/segment.name)
            sync_directory(sealed_archive)
        os.rename(path,archive);os.chmod(archive,0o600);sync_directory(path.parent)
        _append_locked(path,'audit-repair','audit-repair','ok',previous_chain=chain)
    return {'changed':True,'archive':str(archive),'previous_chain':chain,
            'sealed_archive':str(sealed_archive) if sealed else None}
