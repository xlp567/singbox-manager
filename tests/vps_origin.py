#!/usr/bin/env python3
"""Temporary loopback-only origin for external proxy acceptance; never serves files."""
import http.server
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200);self.end_headers();self.wfile.write(b'sbm-v3-vps-acceptance\n')
    def log_message(self,*args):pass
server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
print(server.server_port,flush=True)
server.serve_forever()
