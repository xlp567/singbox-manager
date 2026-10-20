import http.client
import io
import socket
import subprocess
import unittest
import urllib.error
from unittest.mock import patch
from common import engine, model
from sbm.core import release_trust, self_update


class DnsLookupFailure(unittest.TestCase):
    def setUp(self):
        # Fixtures use the RFC 5737 documentation range, which Python does not call global.
        public=lambda address:address.is_global or str(address).startswith('203.0.113.')
        patcher=patch.object(engine.network_policy,'is_public',side_effect=public);patcher.start();self.addCleanup(patcher.stop)

    def test_dig_failure_reports_the_name_instead_of_a_raw_command_error(self):
        m=model();m['nodes']=[m['nodes'][0]]
        def run(command,**kwargs):
            if command[0]=='curl':
                if '-4' in command:return '203.0.113.5\n'
                raise subprocess.CalledProcessError(7,command)
            if command[0]=='dig':raise subprocess.CalledProcessError(9,command)
            raise AssertionError(command)
        with patch.object(engine.network_policy,'collect_local',return_value=[]),\
             patch.object(engine.network_policy,'confirmed_load',return_value=[]),\
             patch.object(engine.subprocess,'check_output',side_effect=run):
            with self.assertRaisesRegex(ValueError,'node.example.com.*dig 超时或失败'):engine.verify_dns(m)

    def test_dig_timeout_is_bounded(self):
        m=model();m['nodes']=[m['nodes'][0]];seen=[]
        def run(command,**kwargs):
            if command[0]=='curl':return '203.0.113.5\n'
            seen.append(kwargs.get('timeout'));raise subprocess.TimeoutExpired(command,kwargs.get('timeout'))
        with patch.object(engine.network_policy,'collect_local',return_value=[]),\
             patch.object(engine.network_policy,'confirmed_load',return_value=[]),\
             patch.object(engine.subprocess,'check_output',side_effect=run),self.assertRaises(ValueError):
            engine.verify_dns(m)
        self.assertEqual(seen,[15])


class SharedRetry(unittest.TestCase):
    def setUp(self):
        sleeper=patch.object(release_trust.time,'sleep');self.sleep=sleeper.start();self.addCleanup(sleeper.stop)

    def calls(self,*outcomes):
        queue=list(outcomes);count=[0]
        def operation():
            count[0]+=1;item=queue.pop(0)
            if isinstance(item,BaseException):raise item
            return item
        return operation,count

    def test_transient_failures_retry_with_bounded_backoff(self):
        for error in (urllib.error.HTTPError('u',503,'',{},None),urllib.error.HTTPError('u',429,'',{},None),
                      urllib.error.URLError('reset'),socket.timeout(),ConnectionResetError(),http.client.IncompleteRead(b'')):
            self.sleep.reset_mock();operation,count=self.calls(error,b'ok')
            self.assertEqual(release_trust.retrying(operation),b'ok');self.assertEqual(count[0],2)
            self.sleep.assert_called_once_with(0.5)

    def test_gives_up_after_three_attempts(self):
        operation,count=self.calls(*[urllib.error.URLError('down')]*3)
        with self.assertRaises(urllib.error.URLError):release_trust.retrying(operation)
        self.assertEqual(count[0],3);self.assertEqual([c.args[0] for c in self.sleep.call_args_list],[0.5,1.5])

    def test_permission_and_verification_failures_are_never_retried(self):
        for error in (urllib.error.HTTPError('u',401,'',{},None),urllib.error.HTTPError('u',403,'',{},None),
                      urllib.error.HTTPError('u',404,'',{},None),ValueError('signature')):
            self.sleep.reset_mock();operation,count=self.calls(error,b'unused')
            with self.assertRaises(type(error)):release_trust.retrying(operation)
            self.assertEqual(count[0],1);self.sleep.assert_not_called()

    def test_asset_and_api_reads_share_the_retry(self):
        class Response(io.BytesIO):headers={'Content-Type':'application/octet-stream'}
        class Opener:
            def __init__(self):self.count=0
            def open(self,request,timeout):
                self.count+=1
                if self.count==1:raise urllib.error.HTTPError(request.full_url,502,'',{},None)
                return Response(b'{"tag_name":"v3.5.8"}')
        opener=Opener()
        with patch.object(release_trust.urllib.request,'build_opener',return_value=opener):
            self.assertEqual(release_trust.asset_bytes('https://github.com/a/b/releases/download/v3.5.8/install.py'),b'{"tag_name":"v3.5.8"}')
        self.assertEqual(opener.count,2);opener=Opener()
        with patch.object(self_update.urllib.request,'build_opener',return_value=opener):
            self.assertEqual(self_update.request_json('https://api.github.com/repos/a/b/releases/latest')['tag_name'],'v3.5.8')
        self.assertEqual(opener.count,2)

    def test_private_fallback_still_sees_the_original_permission_status(self):
        opener=unittest.mock.Mock();opener.open.side_effect=urllib.error.HTTPError('u',404,'',{},None)
        with patch.object(self_update.urllib.request,'build_opener',return_value=opener):
            with self.assertRaises(self_update.GitHubReadError) as error:self_update.request_json('https://api.github.com/repos/a/b/releases/latest')
        self.assertEqual(error.exception.status,404);self.assertEqual(opener.open.call_count,1)


if __name__=='__main__':unittest.main()
