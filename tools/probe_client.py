#!/usr/bin/env python3
"""Probe existing VPS nodes from an external machine without printing credentials."""
import argparse
import json
import pathlib
import subprocess
import sys
import tempfile
import time
sys.path.insert(0,str(pathlib.Path(__file__).resolve().parents[1]/'src'))
from sbm import engine


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--binary',required=True);parser.add_argument('--model',required=True)
    parser.add_argument('--url',required=True);parser.add_argument('--report',required=True)
    parser.add_argument('--phase',required=True)
    args=parser.parse_args()
    # This import is a test helper and only binds loopback ports.
    sys.path.insert(0,str(pathlib.Path(__file__).resolve().parents[1]/'tests'))
    from live_roundtrip import free_port,wait_tcp
    results=[]
    with tempfile.TemporaryDirectory(prefix='sbm-external-') as td:
        p=pathlib.Path(td)
        for n in engine.load(args.model)['nodes']:
            if not n['enabled']:continue
            row={'phase':args.phase,'protocol':n['kind'],'port':n['port']}
            out=engine.client_node(n);port=free_port()
            c={'log':{'level':'warn'},'inbounds':[{'type':'mixed','listen':'127.0.0.1','listen_port':port}],
                'outbounds':[out],'route':{'final':n['id']}}
            engine.save(p/'client.json',c)
            with (p/'client.log').open('w') as log:
                proc=subprocess.Popen([str(pathlib.Path(args.binary).resolve()),'run','-c',str(p/'client.json')],stdout=log,stderr=log)
                try:
                    wait_tcp(port,proc)
                    r=subprocess.run(['curl','--silent','--show-error','--max-time','25',
                        '--proxy',f'socks5h://127.0.0.1:{port}','--noproxy','',args.url],capture_output=True,text=True)
                    row['result']='PASS' if r.returncode==0 and r.stdout=='sbm-v3-vps-acceptance\n' else 'FAIL'
                    if row['result']=='FAIL':row['detail']='curl failed or response mismatch (credentials omitted)'
                except Exception as ex:row['result']='FAIL';row['detail']=str(ex)
                finally:
                    proc.terminate()
                    try:proc.wait(timeout=5)
                    except subprocess.TimeoutExpired:proc.kill();proc.wait()
            results.append(row);print(json.dumps(row,ensure_ascii=False),flush=True)
    report=pathlib.Path(args.report)
    old=json.loads(report.read_text()) if report.exists() else []
    engine.save(report,old+results)
    return 0 if all(r['result']=='PASS' for r in results) else 1


if __name__=='__main__':raise SystemExit(main())
