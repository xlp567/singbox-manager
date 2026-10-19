import contextlib
import io
import json
import os
import pathlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch
from common import ROOT,engine as e
from sbm.core import release_fetch as f


def release(version='1.14.3',preview=False):
    name='sing-box-'+version+'-linux-amd64.tar.gz'
    return {'tag_name':'v'+version,'prerelease':preview,'draft':False,'published_at':'2026-10-19T00:00:00Z',
            'assets':[{'name':name,'browser_download_url':'https://github.com/SagerNet/sing-box/releases/download/v'+version+'/'+name,'digest':'sha256:'+'a'*64}]}


class ReleaseQueries(unittest.TestCase):
    def setUp(self):
        td=tempfile.TemporaryDirectory();self.addCleanup(td.cleanup);self.p=pathlib.Path(td.name)
        self.output=self.p/'releases.json';self.meta=self.p/'query.json'

    def fetch(self,responses,mode='summary'):
        with patch.object(f.Fetcher,'get',side_effect=responses) as call:
            report=f.fetch(self.output,self.meta,mode)
        return report,call

    def test_summary_uses_two_small_official_endpoints_and_fresh_metadata(self):
        report,call=self.fetch([[release('1.15.0-alpha.9',True)],release()])
        self.assertEqual([c.args[0] for c in call.call_args_list],['?per_page=10&page=1','/latest'])
        e.releases(self.output,self.p/'catalog','amd64',self.meta)
        self.assertEqual(e.load(self.p/'catalog')['stable']['version'],'1.14.3')
        self.assertTrue(report['recent_available'])

    def test_http_504_list_falls_back_to_live_stable_and_does_not_invent_preview(self):
        report,_=self.fetch([f.QueryError('官方接口返回 HTTP 504'),release()])
        self.assertFalse(report['recent_available'])
        e.releases(self.output,self.p/'catalog','amd64',self.meta)
        result=e.load(self.p/'catalog')
        with contextlib.redirect_stdout(io.StringIO()) as output:e.version_summary(result,'1.14.3')
        self.assertIn('最新发布版（含测试版）：本次查询未完成',output.getvalue())
        with patch.object(e,'choose',return_value=1):
            with self.assertRaises(ValueError):e.select_release(self.p/'catalog',self.p/'selected')
        self.assertFalse((self.p/'selected').exists())
        with patch.object(e,'choose',return_value=0):e.select_release(self.p/'catalog',self.p/'selected')
        self.assertEqual(e.load(self.p/'selected')['version'],'1.14.3')

    def test_all_sources_failed_removes_stale_outputs_and_preserves_cached_hint(self):
        self.output.write_text('old response');self.meta.write_text('old metadata')
        hint=self.p/'latest-stable';hint.write_text('1.14.3 2026-10-16\n')
        with self.assertRaisesRegex(ValueError,'未使用旧缓存'):
            self.fetch([f.QueryError('HTTP 504'),f.QueryError('HTTP 504')])
        f.status(self.p,'failed')
        self.assertFalse(self.output.exists());self.assertFalse(self.meta.exists())
        self.assertEqual(hint.read_text(),'1.14.3 2026-10-16\n')
        self.assertFalse(e.load(self.p/'latest-query.json')['success'])

    def test_rate_limit_does_not_retry_or_call_another_endpoint(self):
        with patch.object(f.Fetcher,'request',side_effect=f.QueryError('HTTP 429',rate_limit=True)) as request:
            with self.assertRaises(f.QueryError):f.fetch(self.output,self.meta)
        self.assertEqual(request.call_count,1)

    def test_transient_failure_retries_once_but_forbidden_does_not(self):
        client=f.Fetcher()
        with patch.object(client,'request',side_effect=[f.QueryError('HTTP 504',retry=True),[release()]]),patch.object(f.time,'sleep') as sleep:
            self.assertEqual(client.get('?per_page=10&page=1'),[release()]);sleep.assert_called_once()
        with patch.object(client,'request',side_effect=f.QueryError('HTTP 403',rate_limit=True)) as request:
            with self.assertRaises(f.QueryError):client.get('/latest')
            self.assertEqual(request.call_count,1)

    def test_partial_history_keeps_fresh_latest_and_reports_failure(self):
        report,call=self.fetch([[release('1.15.0-alpha.'+str(i),True) for i in range(10)],release(),f.QueryError('HTTP 504')],mode='full')
        self.assertEqual(call.call_count,3);self.assertFalse(report['history_complete'])
        self.assertTrue(any('历史版本列表仅取得部分' in w for w in report['warnings']))
        e.releases(self.output,self.p/'catalog','amd64',self.meta)
        self.assertEqual(e.load(self.p/'catalog')['stable']['version'],'1.14.3')

    def test_full_history_keeps_hundred_releases_with_small_pages(self):
        responses=[[release('1.15.0-alpha.'+str(i+j*10),True) for i in range(10)] for j in range(10)]
        report,call=self.fetch([responses[0],release(),*responses[1:]],mode='full')
        self.assertEqual(call.call_count,11);self.assertEqual(report['history_limit'],100)
        self.assertEqual(len(e.load(self.output)),101)

    def test_bad_json_shape_recovers_through_stable_endpoint(self):
        report,_=self.fetch([{'message':'unavailable'},release()])
        self.assertFalse(report['recent_available']);self.assertEqual(len(e.load(self.output)),1)

    def test_official_sha256_is_still_required_in_fallback(self):
        stable=release();stable['assets'][0]['digest']=None
        self.fetch([f.QueryError('HTTP 504'),stable])
        with self.assertRaises(ValueError):e.releases(self.output,self.p/'catalog','amd64',self.meta)
        self.assertFalse((self.p/'catalog').exists())

    def test_curl_errors_are_bounded_and_never_print_response_or_credentials(self):
        def curl(args,**kwargs):
            self.assertEqual(args[:2],['curl','-q'])
            self.assertEqual(args[-1],f.BASE+'/latest');self.assertNotIn('-L',args)
            self.assertNotIn('Authorization',' '.join(args));self.assertIn('--max-time',args)
            return subprocess.CompletedProcess(args,0,'504','private response body which must not be displayed')
        with patch.object(f.subprocess,'run',side_effect=curl):
            with self.assertRaisesRegex(f.QueryError,'HTTP 504') as ex:f.Fetcher().request('/latest')
        self.assertNotIn('private',str(ex.exception))
        with self.assertRaises(f.QueryError):f.Fetcher().request('https://untrusted.example/releases')

    def test_incomplete_http_200_is_retried_and_never_parsed(self):
        def curl(args,**kwargs):
            pathlib.Path(args[args.index('--output')+1]).write_text('{"partial":')
            return subprocess.CompletedProcess(args,18,'200','transfer closed early')
        with patch.object(f.subprocess,'run',side_effect=curl) as run,patch.object(f.time,'sleep'):
            with self.assertRaisesRegex(f.QueryError,'未完整下载'):f.Fetcher().get('/latest')
        self.assertEqual(run.call_count,2)

    def test_deadline_prevents_further_network_requests(self):
        client=f.Fetcher(budget=-1)
        with patch.object(f.subprocess,'run') as run:
            with self.assertRaisesRegex(f.QueryError,'时间上限'):client.request('/latest')
            run.assert_not_called()

    def test_dashboard_does_not_claim_up_to_date_after_failed_query(self):
        (self.p/'latest-stable').write_text('1.14.3 2026-10-16\n');f.status(self.p,'failed')
        with patch.object(e,'cpu_percent',return_value=0),patch.object(e,'default_iface',return_value=None),\
             patch.object(e,'run_text',return_value=''),patch.object(e,'service_inbounds',return_value=([],False)),\
             patch.object(e,'system_listeners',return_value={}),contextlib.redirect_stdout(io.StringIO()) as output:
            e.dashboard(self.p/'conf',self.p,'1.14.3')
        self.assertIn('上次查询稳定版',output.getvalue());self.assertIn('最近查询失败，暂无法判断是否最新',output.getvalue())
        self.assertNotIn('已是最新',output.getvalue())

    def test_real_menu_11_failure_path_never_calls_service_or_changes_live_files(self):
        state=self.p/'state';state.mkdir();(state/'latest-stable').write_text('1.14.3 2026-10-16\n')
        live=self.p/'config.json';live.write_text('original config');binary=self.p/'sing-box';binary.write_text('original runtime')
        bin_dir=self.p/'bin';bin_dir.mkdir()
        curl=bin_dir/'curl';curl.write_text('#!/bin/sh\nprintf 504\n');curl.chmod(0o755)
        service=bin_dir/'systemctl';service.write_text('#!/bin/sh\ntouch "$TEST_SERVICE_TOUCHED"\nexit 99\n');service.chmod(0o755)
        script='''source "$1"
STATE=$2/state
dependencies(){ :; }
dpkg(){ printf amd64; }
current_version(){ printf 1.14.3; }
action 11
'''
        env=dict(os.environ,PATH=str(bin_dir)+os.pathsep+os.environ['PATH'],TEST_SERVICE_TOUCHED=str(self.p/'service-touched'))
        r=subprocess.run(['bash','-c',script,'bash',str(ROOT/'singbox-manager.sh'),str(self.p)],env=env,capture_output=True,text=True)
        self.assertNotEqual(r.returncode,0);self.assertIn('HTTP 504',r.stderr)
        self.assertIn('无法判断是否有新版本',r.stderr);self.assertNotIn('curl: (22)',r.stderr)
        self.assertFalse((self.p/'service-touched').exists())
        self.assertEqual(live.read_text(),'original config');self.assertEqual(binary.read_text(),'original runtime')
        self.assertEqual((state/'latest-stable').read_text(),'1.14.3 2026-10-16\n')


if __name__=='__main__':unittest.main()
