import http.client
import io
import unittest
import urllib.error
from unittest.mock import patch
from common import ROOT
from sbm.core import release_trust, self_update


class Socket:
    def __init__(self,data):self.data=data
    def makefile(self,mode):return io.BytesIO(self.data)


def truncated_response(body,declared):
    raw=b'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: '+str(declared).encode()+b'\r\n\r\n'+body
    response=http.client.HTTPResponse(Socket(raw));response.begin();return response


class ShortRead(unittest.TestCase):
    def setUp(self):
        sleeper=patch.object(release_trust.time,'sleep');self.sleep=sleeper.start();self.addCleanup(sleeper.stop)

    def test_real_http_response_early_eof_raises_incomplete_read(self):
        response=truncated_response(b'{"tag_name":"v3',40)
        with self.assertRaises(http.client.IncompleteRead) as error:release_trust.bounded_read(response)
        self.assertEqual(error.exception.partial,b'{"tag_name":"v3')

    def test_complete_responses_and_undeclared_lengths_still_pass(self):
        self.assertEqual(release_trust.bounded_read(truncated_response(b'{"ok":1}',8)),b'{"ok":1}')
        class Plain(io.BytesIO):headers={'Content-Type':'application/octet-stream'}
        self.assertEqual(release_trust.bounded_read(Plain(b'no length header')),b'no length header')

    def test_declared_header_shortfall_is_detected_without_length_attribute(self):
        class Short(io.BytesIO):headers={'Content-Length':'20'}
        with self.assertRaises(http.client.IncompleteRead):release_trust.bounded_read(Short(b'0123456789'))

    def opener(self,bodies):
        class Opener:
            def __init__(self):self.count=0
            def open(self,request,timeout):
                body,declared=bodies[min(self.count,len(bodies)-1)];self.count+=1
                return truncated_response(body,declared)
        return Opener()

    def test_truncated_metadata_is_retried_then_succeeds(self):
        good=b'{"tag_name":"v3.5.9"}';opener=self.opener([(good[:9],len(good)),(good,len(good))])
        with patch.object(self_update.urllib.request,'build_opener',return_value=opener):
            self.assertEqual(self_update.request_json('https://api.github.com/repos/a/b/releases/latest')['tag_name'],'v3.5.9')
        self.assertEqual(opener.count,2);self.sleep.assert_called_once_with(0.5)

    def test_persistent_truncation_gives_a_clean_error_after_three_attempts(self):
        opener=self.opener([(b'{"tag',30)])
        with patch.object(self_update.urllib.request,'build_opener',return_value=opener):
            with self.assertRaisesRegex(ValueError,'已重试') as error:self_update.request_json('https://api.github.com/repos/a/b/releases/latest')
        self.assertEqual(opener.count,3);self.assertNotIn('IncompleteRead',str(error.exception))

    def test_truncated_asset_is_retried(self):
        class Opener:
            def __init__(self):self.count=0
            def open(self,request,timeout):
                self.count+=1
                raw=b'HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: 12\r\n\r\n'+(b'partial' if self.count==1 else b'complete-ok!')
                response=http.client.HTTPResponse(Socket(raw));response.begin();return response
        opener=Opener()
        with patch.object(release_trust.urllib.request,'build_opener',return_value=opener):
            self.assertEqual(release_trust.asset_bytes('https://github.com/a/b/releases/download/v3.5.9/install.py'),b'complete-ok!')
        self.assertEqual(opener.count,2)

    def test_malformed_json_without_transport_error_is_a_clean_value_error(self):
        opener=self.opener([(b'{"tag_name":',12)])
        with patch.object(self_update.urllib.request,'build_opener',return_value=opener):
            with self.assertRaisesRegex(ValueError,'不完整或格式无效'):self_update.request_json('https://api.github.com/repos/a/b/releases/latest')
        self.assertEqual(opener.count,1)


class BootstrapReaders(unittest.TestCase):
    def test_both_bootstrap_readers_report_malformed_json_cleanly(self):
        from test_bootstrap import b,load
        p=load('public_bootstrap_v359',ROOT/'tools/public_bootstrap.py')
        for module,call in ((b,lambda:b.request('/releases/latest','')),(p,lambda:p.read('/releases/latest'))):
            opener=unittest.mock.Mock();opener.open.return_value=truncated_response(b'{"a":',5)
            with patch.object(module.urllib.request,'build_opener',return_value=opener):
                with self.assertRaisesRegex(ValueError,'不完整或格式无效'):call()


if __name__=='__main__':unittest.main()
