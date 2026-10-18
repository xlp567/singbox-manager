#!/usr/bin/env python3
"""Real protocol round trips on loopback using an explicitly supplied official binary.

Local certificates and credentials are temporary. No system service/config is changed.
"""
import argparse
import contextlib
import copy
import http.server
import json
import pathlib
import socket
import subprocess
import tempfile
import threading
import time
from common import engine, model


def free_port(udp=False):
    with socket.socket(socket.AF_INET,socket.SOCK_DGRAM if udp else socket.SOCK_STREAM) as s:
        s.bind(('127.0.0.1',0)); return s.getsockname()[1]


def wait_tcp(port, process):
    for _ in range(100):
        if process.poll() is not None: raise RuntimeError('process exited before ready')
        try:
            with socket.create_connection(('127.0.0.1',port),0.2): return
        except OSError: time.sleep(0.05)
    raise RuntimeError('listener not ready')


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--binary',required=True);parser.add_argument('--report',required=True)
    args=parser.parse_args();binary=str(pathlib.Path(args.binary).resolve())
    results=[]
    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            body=b'sbm-v3-real-roundtrip\n';self.send_response(200);self.end_headers();self.wfile.write(body)
        def log_message(self,*args): pass
    server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
    threading.Thread(target=server.serve_forever,daemon=True).start()
    with tempfile.TemporaryDirectory(prefix='sbm-v3-live-') as td:
        p=pathlib.Path(td)
        subprocess.run(['openssl','req','-x509','-newkey','rsa:2048','-nodes','-keyout',str(p/'key.pem'),
            '-out',str(p/'cert.pem'),'-days','2','-subj','/CN=node.example.com',
            '-addext','subjectAltName=DNS:node.example.com'],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        keypair=engine.keypair(binary)
        target_port=free_port(); target_log=(p/'target.log').open('w')
        target=subprocess.Popen(['openssl','s_server','-accept',f'127.0.0.1:{target_port}',
                '-cert',str(p/'cert.pem'),'-key',str(p/'key.pem'),'-tls1_3','-www'],stdout=target_log,stderr=target_log)
        try:
            wait_tcp(target_port,target)
            for node in model()['nodes']:
                kind=node['kind']; processes=[]; handles=[]; row={'protocol':kind}
                try:
                    n=copy.deepcopy(node);n['port']=free_port(kind in {'hysteria2','tuic'})
                    if kind=='reality':
                        n.update(target='node.example.com',target_port=target_port,sni='node.example.com',private_key=keypair[0],public_key=keypair[1])
                    m=model();m['nodes']=[n]
                    conf=engine.compile_config(m);conf['inbounds'][0]['listen']='127.0.0.1'
                    if kind=='reality': conf['inbounds'][0]['tls']['reality']['handshake']['server']='127.0.0.1'
                    if kind in engine.TLS_KINDS:
                        conf.pop('certificate_providers',None)
                        tls=conf['inbounds'][0]['tls'];tls.pop('certificate_provider',None)
                        tls.update(certificate_path=str(p/'cert.pem'),key_path=str(p/'key.pem'))
                    out=engine.client_node(n);out['server']='127.0.0.1'
                    if kind in engine.TLS_KINDS:out['tls']['certificate_path']=str(p/'cert.pem')
                    cp=free_port();client={'log':{'level':'warn'},'inbounds':[{'type':'mixed','listen':'127.0.0.1','listen_port':cp}],
                        'outbounds':[out],'route':{'final':n['id']}}
                    engine.save(p/'server.json',conf);engine.save(p/'client.json',client)
                    for role in ['server','client']:
                        r=subprocess.run([binary,'check','-c',str(p/f'{role}.json')],capture_output=True,text=True)
                        if r.returncode:raise RuntimeError(role+' check failed: '+r.stderr[-500:])
                    row['config_check']='PASS'
                    for role in ['server','client']:
                        log=(p/f'{kind}-{role}.log').open('w');handles.append(log)
                        processes.append(subprocess.Popen([binary,'run','-c',str(p/f'{role}.json')],stdout=log,stderr=log))
                    wait_tcp(cp,processes[1])
                    if kind not in {'hysteria2','tuic'}:wait_tcp(n['port'],processes[0])
                    r=subprocess.run(['curl','--silent','--show-error','--max-time','25','--retry','2','--retry-delay','1',
                        '--proxy',f'socks5h://127.0.0.1:{cp}','--noproxy','',f'http://127.0.0.1:{server.server_port}/'],capture_output=True,text=True)
                    if r.returncode or r.stdout!='sbm-v3-real-roundtrip\n':
                        raise RuntimeError('proxy request failed: '+r.stderr[-250:])
                    row['roundtrip']='PASS'
                except Exception as ex:
                    detail=str(ex)
                    for f in p.glob(f'{kind}-*.log'):
                        text=f.read_text()
                        if text.strip():detail+='; '+f.name+': '+text[-700:]
                    row['roundtrip']='FAIL';row['detail']=detail
                finally:
                    for proc in processes:
                        proc.terminate()
                    for proc in processes:
                        try:proc.wait(timeout=5)
                        except subprocess.TimeoutExpired:proc.kill();proc.wait()
                    for handle in handles:handle.close()
                results.append(row);print(json.dumps(row,ensure_ascii=False),flush=True)
        finally:
            target.terminate();target.wait(timeout=5);target_log.close();server.shutdown()
    pathlib.Path(args.report).write_text(json.dumps(results,ensure_ascii=False,indent=2)+'\n')
    return 0 if all(r.get('roundtrip')=='PASS' for r in results) else 1


if __name__=='__main__': raise SystemExit(main())
