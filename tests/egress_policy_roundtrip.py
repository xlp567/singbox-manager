#!/usr/bin/env python3
"""Real local TCP/UDP tests of generated policy; no VPS or external connection."""
import argparse
import http.server
import ipaddress
import json
import pathlib
import socket
import struct
import subprocess
import tempfile
import threading
import time
from common import engine
from sbm.core import network_policy


def readn(stream,size):
    data=b''
    while len(data)<size:
        chunk=stream.recv(size-len(data))
        if not chunk:raise EOFError('closed')
        data+=chunk
    return data


def encoded(host):
    try:
        address=ipaddress.ip_address(host)
        return (b'\x01' if address.version==4 else b'\x04')+address.packed
    except ValueError:
        data=host.encode();return b'\x03'+bytes([len(data)])+data


def reply(stream):
    head=readn(stream,4)
    if head[1]:raise OSError('proxy rejected')
    size={1:4,4:16}.get(head[3])
    if size is None:size=readn(stream,1)[0]
    address=readn(stream,size);port=struct.unpack('!H',readn(stream,2))[0]
    return address,port


def authenticated(port):
    stream=socket.create_connection(('127.0.0.1',port),2);stream.settimeout(2)
    stream.sendall(b'\x05\x01\x02')
    if readn(stream,2)!=b'\x05\x02':raise RuntimeError('SOCKS authentication negotiation failed')
    stream.sendall(b'\x01\x04test\x0blocal-tests')
    if readn(stream,2)!=b'\x01\x00':raise RuntimeError('SOCKS authentication failed')
    return stream


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--binary',required=True);parser.add_argument('--report',required=True);args=parser.parse_args()
    results=[];hits={'tcp':0,'udp':0};stopped=threading.Event()
    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            hits['tcp']+=1;self.send_response(200);self.end_headers();self.wfile.write(b'sbm-egress-public-pass')
        def log_message(self,*args):pass
    origin=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
    threading.Thread(target=origin.serve_forever,daemon=True).start()
    udp=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);udp.bind(('127.0.0.1',0));udp.settimeout(.1)
    def echo():
        while not stopped.is_set():
            try:data,address=udp.recvfrom(2048);hits['udp']+=1;udp.sendto(data,address)
            except socket.timeout:pass
            except OSError:return
    threading.Thread(target=echo,daemon=True).start()
    with socket.socket() as available:available.bind(('127.0.0.1',0));port=available.getsockname()[1]
    process=None
    try:
        with tempfile.TemporaryDirectory(prefix='sbm-egress-wire-') as folder:
            root=pathlib.Path(folder);m=engine.new_model();network_policy.stamp(m,['192.0.2.10','2001:db8::10'])
            config=engine.compile_config(m)
            config['log']={'level':'debug'}
            config['inbounds']=[{'type':'mixed','tag':'fixture','listen':'127.0.0.1','listen_port':port,'users':[{'username':'test','password':'local-tests'}]}]
            public='.'.join(map(str,[8,8,4,4]))
            config['dns']={'servers':[{'type':'hosts','tag':'system','predefined':{
                'public.example':[public],'lan.example':['127.0.0.1'],'mixed.example':[public,'127.0.0.1'],
                'own.example':['192.0.2.10'],'metadata.example':['169.254.169.254']}}]}
            # Test-only mapping AFTER the generated deny rules. A synthetic
            # public destination reaches an origin without Internet access.
            # Production compilation never includes these override fields.
            rules=config['route']['rules'];allowed=rules[-2]
            config['route']['rules']=rules[:-2]+[
                dict(allowed,network='tcp',override_address='127.0.0.1',override_port=origin.server_port),
                dict(allowed,network='udp',override_address='127.0.0.1',override_port=udp.getsockname()[1]),rules[-1]]
            engine.save(root/'server.json',config)
            binary=str(pathlib.Path(args.binary).resolve())
            subprocess.run([binary,'check','-c',str(root/'server.json')],check=True,capture_output=True)
            with (root/'server.log').open('w') as log:
                process=subprocess.Popen([binary,'run','-c',str(root/'server.json')],stdout=log,stderr=log)
                for _ in range(100):
                    if process.poll() is not None:
                        raise RuntimeError('temporary sing-box exited before listening: '+(root/'server.log').read_text()[-1500:])
                    try:
                        with socket.create_connection(('127.0.0.1',port),.1):break
                    except OSError:time.sleep(.05)
                cases=[('loopback4','127.0.0.1'),('loopback6','::1'),('mapped-loopback','::ffff:127.0.0.1'),
                    ('private10','10.1.2.3'),('private172','172.16.2.3'),('private192','192.168.2.3'),
                    ('link-local4','169.254.169.254'),('link-local6','fe80::1'),('private6','fd00::1'),
                    ('cgnat','100.100.100.200'),('own4','192.0.2.10'),('own6','2001:db8::10'),
                    ('localhost-name','localhost'),('resolved-private','lan.example'),('mixed-answer','mixed.example'),
                    ('resolved-own','own.example'),('resolved-metadata','metadata.example'),('dns-failure','missing.example')]
                for label,host in [*cases,('public-pass','public.example')]:
                    before=hits['tcp'];response=b''
                    try:
                        with authenticated(port) as stream:
                            stream.sendall(b'\x05\x01\x00'+encoded(host)+struct.pack('!H',80));reply(stream)
                            stream.sendall(b'GET / HTTP/1.0\r\nHost: public.example\r\n\r\n')
                            while True:
                                data=stream.recv(4096)
                                if not data:break
                                response+=data
                    except (OSError,EOFError):pass
                    passed=(b'sbm-egress-public-pass' in response and hits['tcp']==before+1) if label=='public-pass' else (not response and hits['tcp']==before)
                    results.append({'case':label,'network':'tcp','expected':'allowed' if label=='public-pass' else 'blocked','passed':passed})
                for label,host in [*cases[:3],cases[6],cases[13],cases[14],cases[10],('public-pass','public.example')]:
                    before=hits['udp'];response=b''
                    with authenticated(port) as control,socket.socket(socket.AF_INET,socket.SOCK_DGRAM) as client:
                        control.sendall(b'\x05\x03\x00\x01'+socket.inet_aton('127.0.0.1')+b'\x00\x00')
                        _,relay=reply(control);client.settimeout(.4)
                        client.sendto(b'\x00\x00\x00'+encoded(host)+struct.pack('!H',53)+b'sbm-egress-public-pass',('127.0.0.1',relay))
                        try:response=client.recvfrom(2048)[0]
                        except socket.timeout:pass
                    passed=(response.endswith(b'sbm-egress-public-pass') and hits['udp']==before+1) if label=='public-pass' else (not response and hits['udp']==before)
                    results.append({'case':label,'network':'udp','expected':'allowed' if label=='public-pass' else 'blocked','passed':passed})
            report={'runtime':'1.14.3','passed':all(r['passed'] for r in results),'cases':results,
                'scope':'real local authenticated SOCKS TCP/UDP through generated policy; test-only public-target redirect after deny rules; no VPS or external connection'}
            pathlib.Path(args.report).write_text(json.dumps(report,indent=2)+'\n')
            print(json.dumps({'passed':report['passed'],'cases':len(results),'failed':[r for r in results if not r['passed']]}))
            return 0 if report['passed'] else 1
    finally:
        if process is not None:
            process.terminate()
            try:process.wait(timeout=5)
            except subprocess.TimeoutExpired:process.kill();process.wait()
        stopped.set();udp.close();origin.shutdown();origin.server_close()


if __name__=='__main__':raise SystemExit(main())
