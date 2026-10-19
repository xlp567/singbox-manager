"""Durable storage, backup integrity and transaction markers."""
import hashlib, json, os, pathlib, sys, shutil, datetime, uuid, re
import errno, tempfile, time

RUNTIME_LIBRARIES=('libcronet.so','libcronet.dylib','libcronet.dll')
AUTO_BACKUPS=10


def runtime_backup(binary,destination,pool):
    """One immutable private copy per digest; snapshots retain portable hard links."""
    binary=pathlib.Path(binary).resolve();destination=pathlib.Path(destination);pool=pathlib.Path(pool)
    if pool.is_symlink():fail('运行文件对象目录不得为符号链接')
    pool.mkdir(mode=0o700,exist_ok=True);identity=runtime_identity(binary);target=pool/identity
    if target.is_symlink():fail('运行文件对象不得为符号链接')
    if not target.exists():
        temporary=pathlib.Path(tempfile.mkdtemp(prefix='.object-',dir=pool))
        try:
            shutil.copyfile(binary,temporary/'runtime.bin');os.chmod(temporary/'runtime.bin',0o700)
            runtime_copy_libraries(binary,temporary/'runtime-libs')
            if runtime_identity(temporary/'runtime.bin',temporary/'runtime-libs')!=identity:fail('备份期间运行文件发生变化')
            backup_seal(temporary);backup_complete(temporary)
            os.replace(temporary,target);sync_directory(pool)
        finally:
            if temporary.exists():shutil.rmtree(temporary)
    backup_verify(target)
    if runtime_identity(target/'runtime.bin',target/'runtime-libs')!=identity:fail('运行文件对象摘要不符')
    (destination/'runtime-libs').mkdir(mode=0o700,exist_ok=True)
    for source in [target/'runtime.bin',*(target/'runtime-libs').iterdir()]:
        dest=destination/('runtime.bin' if source.name=='runtime.bin' else 'runtime-libs/'+source.name)
        try:os.link(source,dest)
        except OSError as error:
            if error.errno!=errno.EXDEV:raise
            shutil.copyfile(source,dest);os.chmod(dest,source.stat().st_mode&0o777)


def snapshot_kind(root,kind):
    if kind not in {'manual','automatic'}:fail('备份类型无效')
    save(pathlib.Path(root)/'backup-kind.json',{'format':1,'kind':kind,'created_ns':time.time_ns()})


def runtime_gc(pool):
    pool=pathlib.Path(pool);removed=0
    if pool.is_symlink():fail('运行文件对象目录不得为符号链接')
    if not pool.exists():return 0
    for directory in pool.iterdir():
        if directory.is_symlink() or not directory.is_dir() or not re.fullmatch(r'[a-f0-9]{64}',directory.name):continue
        files=[p for p in directory.rglob('*') if p.is_file() and not p.is_symlink()]
        if files and all(p.stat().st_nlink==1 for p in files):shutil.rmtree(directory);removed+=1
    sync_directory(pool);return removed


def prune_automatic(backups,pool,pending,keep=AUTO_BACKUPS):
    root=pathlib.Path(backups);marker=pathlib.Path(pending)
    protected=marker.read_text().strip() if marker.is_file() and not marker.is_symlink() else ''
    automatic=[]
    for directory in root.iterdir():
        if directory.is_symlink() or not directory.is_dir() or not (directory/'.complete').is_file():continue
        kind=directory/'backup-kind.json'
        if not kind.is_file() or kind.is_symlink():continue
        try:
            data=json.loads(kind.read_text())
            if data.get('format')==1 and data.get('kind')=='automatic' and type(data.get('created_ns')) is int:
                automatic.append((data['created_ns'],directory))
        except (ValueError,OSError):continue
    automatic.sort(key=lambda row:row[0],reverse=True);removed=0
    for _,directory in automatic[int(keep):]:
        if str(directory)==protected:continue
        shutil.rmtree(directory);removed+=1
    sync_directory(root);runtime_gc(pool);return removed


def snapshot_space(backups,pool,config,exports,binary=''):
    def size(path):
        root=pathlib.Path(path)
        if not root.exists():return 0
        if root.is_file():return root.stat().st_size
        return sum(p.stat().st_size for p in root.rglob('*') if p.is_file() and not p.is_symlink())
    state=pathlib.Path(pool).parent
    needed=size(config)+size(exports)+size(state/'protocols')+size(state/'client-info.txt')+8*1024*1024
    runtime_size=0;pool_needed=0;pool=pathlib.Path(pool)
    if binary:
        p=pathlib.Path(binary).resolve()
        runtime_size=p.stat().st_size+sum((p.parent/name).stat().st_size for name in RUNTIME_LIBRARIES if (p.parent/name).is_file())
        if not (pool/runtime_identity(binary)).is_dir():pool_needed=runtime_size
    state=pool.parent
    if state.stat().st_dev==pathlib.Path(backups).stat().st_dev:needed+=pool_needed
    else:
        needed+=runtime_size
        if shutil.disk_usage(state).free<pool_needed+8*1024*1024:fail('运行文件对象目录空间不足；请先用菜单 24 清理')
    if shutil.disk_usage(backups).free<needed:fail('本次备份空间不足（按实际新增数据估算）；请先用菜单 24 清理')

def file_digest(path):
    h=hashlib.sha256()
    with pathlib.Path(path).open('rb') as f:
        for chunk in iter(lambda:f.read(1024*1024),b''):h.update(chunk)
    return h.hexdigest()

def fail(message): raise ValueError(message)

def save(p,obj):
    p=pathlib.Path(p); tmp=p.with_suffix(p.suffix+'.tmp')
    with open(tmp,'w') as f:
        json.dump(obj,f,ensure_ascii=False,indent=2); f.write('\n')
        f.flush(); os.fsync(f.fileno())
    os.chmod(tmp,0o600); os.replace(tmp,p)
    sync_directory(p.parent)


def sync_directory(path):
    fd=os.open(str(path),os.O_RDONLY)
    try: os.fsync(fd)
    finally: os.close(fd)


def backup_inventory(root):
    root=pathlib.Path(root); result={}
    for p in sorted(root.rglob('*')):
        rel=str(p.relative_to(root))
        if rel in {'manifest.json','.complete'}: continue
        if p.is_symlink():
            result[rel]={'link':os.readlink(p)}
        elif p.is_file():
            h=hashlib.sha256()
            with p.open('rb') as f:
                for chunk in iter(lambda:f.read(1024*1024),b''): h.update(chunk)
                os.fsync(f.fileno())
            result[rel]={'sha256':h.hexdigest(),'mode':p.stat().st_mode & 0o777}
        elif p.is_dir(): result[rel]={'directory':True,'mode':p.stat().st_mode & 0o777}
        else: fail('备份含不支持的文件类型：'+rel)
    return result


def backup_seal(root):
    save(pathlib.Path(root)/'manifest.json',{'format':1,'files':backup_inventory(root)})
    sync_directory(root)


def backup_verify(root):
    root=pathlib.Path(root)
    manifest=root/'manifest.json'
    if not manifest.exists():
        marker=root/'.complete'
        if marker.exists() and marker.read_text().strip()=='3.5': fail('v3.5 备份缺少完整性清单，拒绝按旧格式恢复')
        print('旧版备份没有完整性摘要；按 v2.4 兼容方式恢复。',file=sys.stderr)
        return
    m=json.loads(manifest.read_text())
    if m.get('format')!=1 or m.get('files')!=backup_inventory(root):
        fail('备份完整性校验失败，拒绝恢复')


def pending_write(path,snapshot):
    p=pathlib.Path(path); temp=p.with_suffix('.new')
    with temp.open('w') as f:
        f.write(snapshot+'\n'); f.flush(); os.fsync(f.fileno())
    os.chmod(temp,0o600); os.replace(temp,p); sync_directory(p.parent)


def pending_clear(path):
    p=pathlib.Path(path); p.unlink(missing_ok=True); sync_directory(p.parent)


def backup_complete(root):
    root=pathlib.Path(root)
    with (root/'.complete').open('w') as f:
        f.write('3.5\n');f.flush();os.fsync(f.fileno())
    sync_directory(root)

def runtime_identity(binary,library_dir=None):
    binary=pathlib.Path(binary).resolve()
    directory=pathlib.Path(library_dir) if library_dir else binary.parent
    digest=file_digest(binary)
    libraries=[]
    for name in RUNTIME_LIBRARIES:
        p=directory/name
        if p.is_symlink():fail('运行库不得为符号链接')
        if p.exists():libraries.append((name,file_digest(p)))
    if not libraries:return digest
    return hashlib.sha256(json.dumps([digest,libraries],separators=(',',':')).encode()).hexdigest()

def runtime_copy_libraries(binary,destination,library_dir=None):
    binary=pathlib.Path(binary).resolve()
    source=pathlib.Path(library_dir) if library_dir else binary.parent
    dest=pathlib.Path(destination);dest.mkdir(parents=True,exist_ok=True)
    for name in RUNTIME_LIBRARIES:
        p=source/name
        if p.is_symlink():fail('运行库不得为符号链接')
        if p.is_file():
            target=dest/name
            if target.is_symlink():fail('目标运行库不得为符号链接')
            if p.resolve()!=target.resolve():shutil.copyfile(p,target)
            os.chmod(target,0o600)

def draft_summary(path):
    p=pathlib.Path(path)
    if p.is_symlink():fail('草稿不得为符号链接')
    if not p.exists():return {'exists':False,'nodes':[],'node_count':0}
    result={'exists':True,'sha256':file_digest(p),'nodes':[],'node_count':0,'corrupt':False}
    try:
        data=json.loads(p.read_text());nodes=data['model']['nodes']
        if not isinstance(nodes,list):raise ValueError()
        for n in nodes:
            if not isinstance(n,dict):raise ValueError()
            name=str(n.get('name','未命名'))[:80]
            name=''.join(c if ord(c)>=32 and ord(c)!=127 else '?' for c in name)
            kind=str(n.get('kind','未知'))[:32]
            kind=''.join(c if c.isalnum() or c in '_-' else '?' for c in kind)
            port=n.get('port');port=port if type(port) is int and 1<=port<=65535 else None
            result['nodes'].append({'name':name,'protocol':kind,'port':port,'enabled':n.get('enabled') is True})
        result['node_count']=len(nodes)
    except (ValueError,KeyError,TypeError,AttributeError,UnicodeError):
        result.update(nodes=[],node_count=0,corrupt=True)
    return result

def draft_discard(path,archive_dir,expected):
    p=pathlib.Path(path);archive=pathlib.Path(archive_dir)
    if p.is_symlink() or archive.is_symlink():fail('草稿和归档目录不得为符号链接')
    if not p.is_file():fail('没有未提交草稿')
    if file_digest(p)!=expected:fail('确认期间草稿已变化，拒绝清理；请重新查看')
    archive.mkdir(parents=True,exist_ok=True);os.chmod(archive,0o700)
    stamp=datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    target=archive/('discarded-'+stamp+'-'+uuid.uuid4().hex[:8]+'.json')
    os.replace(p,target);os.chmod(target,0o600)
    with target.open('rb') as f:os.fsync(f.fileno())
    sync_directory(archive);sync_directory(p.parent)
    return str(target)


def draft_purge(path,expected):
    p=pathlib.Path(path)
    if p.is_symlink() or not p.is_file():fail('草稿不存在或路径异常')
    if file_digest(p)!=expected:fail('确认期间草稿已变化，拒绝永久删除')
    p.unlink();sync_directory(p.parent)


def draft_archive_inventory(directory):
    root=pathlib.Path(directory);files=[]
    if root.is_symlink():fail('草稿归档目录不得为符号链接')
    if root.exists():
        for p in sorted(root.iterdir()):
            if p.is_symlink() or not p.is_file() or not re.fullmatch(r'discarded-\d{8}T\d{6}Z-[a-f0-9]{8}\.json',p.name):
                fail('草稿归档目录存在非预期文件，拒绝批量删除：'+p.name)
            files.append({'name':p.name,'size':p.stat().st_size,'sha256':file_digest(p)})
    return {'directory':str(root),'count':len(files),'bytes':sum(f['size'] for f in files),'files':files}


def draft_archives_purge(directory,plan):
    expected=json.loads(pathlib.Path(plan).read_text());actual=draft_archive_inventory(directory)
    if expected!=actual:fail('确认期间归档目录已变化，拒绝删除；请重新预览')
    root=pathlib.Path(directory)
    for f in actual['files']:(root/f['name']).unlink()
    if root.exists():sync_directory(root)
    return actual['count']
