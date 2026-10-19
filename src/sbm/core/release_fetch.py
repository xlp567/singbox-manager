"""Fresh, bounded public SagerNet release queries; no mirrors or cached fallback."""
import datetime
import json
import pathlib
import subprocess
import tempfile
import time
from .storage import save

BASE='https://api.github.com/repos/SagerNet/sing-box/releases'
PAGE_SIZE=10
LIMIT=4*1024*1024


class QueryError(ValueError):
    def __init__(self,reason,retry=False,rate_limit=False):
        super().__init__(reason);self.retry=retry;self.rate_limit=rate_limit


class Fetcher:
    def __init__(self,budget=58):
        self.deadline=time.monotonic()+budget;self.sources=[]

    def request(self,path):
        if path!='/latest' and not (path.startswith('?per_page=10&page=') and path.split('=')[-1].isdigit()):
            raise QueryError('拒绝非官方发布查询路径')
        remaining=self.deadline-time.monotonic()
        if remaining<1:raise QueryError('本次官方查询已达到时间上限')
        timeout=min(12,remaining)
        with tempfile.TemporaryDirectory(prefix='sbm-release-query-') as td:
            body=pathlib.Path(td)/'body.json'
            args=['curl','-q','--proto','=https','--tlsv1.2','--silent','--show-error',
                  '--connect-timeout','5','--max-time',str(timeout),'--max-filesize',str(LIMIT),
                  '--max-redirs','0','--output',str(body),'--write-out','%{http_code}',
                  '-H','Accept: application/vnd.github+json','-H','User-Agent: singbox-manager',
                  '-H','X-GitHub-Api-Version: 2022-11-28',BASE+path]
            try:r=subprocess.run(args,capture_output=True,text=True,timeout=timeout+1)
            except subprocess.TimeoutExpired:raise QueryError('官方接口连接超时',retry=True) from None
            status=r.stdout.strip()
            if status in {'403','429'}:raise QueryError('GitHub 拒绝请求或触发限流（HTTP '+status+'），请稍后重试',rate_limit=True)
            if status!='200':
                reason='官方接口返回 HTTP '+status if status.isdigit() and status!='000' else '无法连接官方 GitHub API（DNS / 连接 / 超时）'
                raise QueryError(reason,retry=status in {'500','502','503','504'} or r.returncode in {5,6,7,18,28,52,55,56})
            if r.returncode or not body.is_file() or body.stat().st_size>LIMIT:
                raise QueryError('官方响应未完整下载或超过大小限制',retry=r.returncode in {18,28,52,55,56})
            try:data=json.loads(body.read_text())
            except (ValueError,UnicodeError):raise QueryError('官方接口未返回有效 JSON') from None
        self.sources.append(BASE+path)
        return data

    def get(self,path):
        for attempt in range(2):
            try:return self.request(path)
            except QueryError as error:
                if not error.retry or attempt or self.deadline-time.monotonic()<2:raise
                time.sleep(0.25)


def fetch(output,metadata,mode='full'):
    if mode not in {'full','summary'}:raise ValueError('版本查询模式无效')
    # Never leave a previous successful response selectable after this query fails.
    for name in [output,metadata]:pathlib.Path(name).unlink(missing_ok=True)
    client=Fetcher();recent=[];stable=None;warnings=[];recent_ok=False;history_complete=False;rate_limited=False
    try:
        recent=client.get('?per_page=10&page=1')
        if not isinstance(recent,list) or any(not isinstance(r,dict) for r in recent):raise QueryError('官方发布列表格式异常')
        recent_ok=bool(recent)
    except QueryError as error:
        recent=[]
        if error.rate_limit:raise
        warnings.append('发布列表查询未完成：'+str(error)+'；尝试官方稳定版接口')
    try:
        stable=client.get('/latest')
        if not isinstance(stable,dict) or not isinstance(stable.get('tag_name'),str) or stable.get('draft') or stable.get('prerelease'):
            raise QueryError('官方稳定版接口格式异常')
    except QueryError as error:
        if error.rate_limit and not recent_ok:raise
        warnings.append('稳定版专用接口查询未完成：'+str(error))
        stable=None
        rate_limited=error.rate_limit
    if not recent_ok and stable is None:
        raise QueryError('官方版本查询失败：'+'；'.join(warnings)+'。当前运行版本和节点保持不变；未使用旧缓存，请稍后重试')
    # A summary needs only the latest page plus the independent stable endpoint.
    history_complete=len(recent)<PAGE_SIZE if recent_ok else False
    if mode=='full' and recent_ok and not history_complete and not rate_limited:
        for page in range(2,11):
            try:
                rows=client.get('?per_page=10&page='+str(page))
                if not isinstance(rows,list) or any(not isinstance(r,dict) for r in rows):raise QueryError('官方发布列表格式异常')
                recent.extend(rows)
                if len(rows)<PAGE_SIZE:history_complete=True;break
            except QueryError as error:
                warnings.append('历史版本列表仅取得部分：'+str(error));break
    # Deduplicate by tag, preferring the independent stable endpoint for that tag.
    merged={r.get('tag_name',''):r for r in recent}
    if stable:merged[stable['tag_name']]=stable
    if not recent_ok:warnings.append('本次仅确认稳定版；含测试版的最新发布暂不可确认或选择')
    report={'recent_available':recent_ok,'history_complete':history_complete,'history_limit':100,
            'mode':mode,'sources':client.sources,'warnings':warnings,
            'checked_at':datetime.datetime.now(datetime.timezone.utc).isoformat()}
    save(output,list(merged.values()));save(metadata,report)
    return report


def status(state,operation,catalog=None):
    root=pathlib.Path(state)
    value={'success':operation=='success','checked_at':datetime.datetime.now(datetime.timezone.utc).isoformat()}
    if operation=='success':
        data=json.loads(pathlib.Path(catalog).read_text())
        save(root/'latest-query.json',value)
        # This legacy hint is display-only; selection always uses a fresh catalog.
        hint=data['stable']['version']+' '+value['checked_at'][:10]+'\n'
        from .self_update import atomic_bytes
        atomic_bytes(root/'latest-stable',hint.encode(),0o600)
    elif operation=='failed':save(root/'latest-query.json',value)
    else:raise ValueError('版本查询状态无效')
