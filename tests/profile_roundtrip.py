#!/usr/bin/env python3
"""Real loopback transfer using a JSON-only protocol absent from the nine built-ins."""
import argparse,hashlib,http.server,json,os,pathlib,socket,subprocess,sys,tempfile,threading,time
from wire_fixture import map_public_origin


def free_port():
    with socket.socket() as s:s.bind(('127.0.0.1',0));return s.getsockname()[1]


def wait(port,process):
    for _ in range(100):
        if process.poll() is not None:raise RuntimeError('测试进程未启动')
        try:
            with socket.create_connection(('127.0.0.1',port),0.1):return
        except OSError:time.sleep(0.05)
    raise RuntimeError('测试监听超时')


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--binary',required=True);parser.add_argument('--report',required=True)
    parser.add_argument('--official-kind',help='Generate a protocol form from the runtime Schema without JSON input')
    args=parser.parse_args()
    root=pathlib.Path(__file__).resolve().parents[1];binary=str(pathlib.Path(args.binary).resolve())
    script_before=hashlib.sha256((root/'singbox-manager.sh').read_bytes()).hexdigest()
    processes=[];handles=[]
    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):self.send_response(200);self.end_headers();self.wfile.write(b'sbm-v35-custom-profile\n')
        def log_message(self,*args):pass
    origin=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
    threading.Thread(target=origin.serve_forever,daemon=True).start()
    try:
        with tempfile.TemporaryDirectory(prefix='sbm-profile-wire-') as td:
            p=pathlib.Path(td);profiles=p/'profiles';profiles.mkdir()
            if not args.official_kind:(profiles/'custom-socks-demo.json').write_bytes((root/'examples/custom-socks.json').read_bytes())
            os.environ['SBM_PROTOCOL_DIR']=str(profiles);sys.path.insert(0,str(root/'src'))
            from sbm import engine as e
            from sbm.protocols import get
            if args.official_kind:
                from sbm.official_schema import create
                class Defaults:
                    def __getattr__(self,key):return getattr(e,key)
                    def choose(self,label,opts,default=1):return default-1
                    def ask(self,label,parse,default=None):
                        if default is None:raise ValueError('表单没有推荐值：'+label)
                        return parse(str(default))
                kind=create(binary,Defaults(),args.official_kind)
            else:kind='custom-socks-demo'
            a=get(kind);n=a.sample(e,binary);n['port']=free_port();m=e.new_model();m['nodes']=[n]
            server=e.compile_config(m);server['inbounds'][0]['listen']='127.0.0.1'
            out=e.client_node(n);out['server']='127.0.0.1';cp=free_port()
            client={'log':{'level':'warn'},'inbounds':[{'type':'mixed','listen':'127.0.0.1','listen_port':cp}],
                    'outbounds':[out],'route':{'final':n['id']}}
            map_public_origin(server,origin.server_port)
            for role,config in [('server',server),('client',client)]:
                e.save(p/(role+'.json'),config)
                subprocess.run([binary,'check','-c',str(p/(role+'.json'))],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
                log=(p/(role+'.log')).open('w');handles.append(log)
                processes.append(subprocess.Popen([binary,'run','-c',str(p/(role+'.json'))],stdout=log,stderr=log))
            wait(n['port'],processes[0]);wait(cp,processes[1])
            r=subprocess.run(['curl','--silent','--show-error','--max-time','20','--proxy',f'socks5h://127.0.0.1:{cp}',
                '--noproxy','','http://public.example/'],capture_output=True,text=True)
            assert r.returncode==0 and r.stdout=='sbm-v35-custom-profile\n','自定义协议实际传输失败'
            report={'kind':a.kind,'server_type':server['inbounds'][0]['type'],
                    'definition':'official runtime Schema; no JSON input' if args.official_kind else 'JSON-only; no Python or shell plugin',
                    'origin':a.definition.get('origin'),
                    'result':'PASS','script_unchanged':hashlib.sha256((root/'singbox-manager.sh').read_bytes()).hexdigest()==script_before,
                    'scope':'temporary authenticated loopback demonstration; no public listener'}
            assert report['script_unchanged'];pathlib.Path(args.report).write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n');print(json.dumps(report,ensure_ascii=False))
    finally:
        for proc in processes:proc.terminate()
        for proc in processes:
            try:proc.wait(timeout=5)
            except subprocess.TimeoutExpired:proc.kill();proc.wait()
        for handle in handles:handle.close()
        origin.shutdown()


if __name__=='__main__':main()
