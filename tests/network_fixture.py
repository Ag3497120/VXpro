# SPDX-License-Identifier: MIT
"""Loopback-only HTTP/TLS fixtures; no real accounts, tokens or save files."""
import http.server, json, pathlib, ssl, subprocess, sys, threading, time
out = pathlib.Path(sys.argv[1]); out.mkdir(parents=True, exist_ok=True)
class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def reply(self, status, body=b'', **headers):
        self.send_response(status)
        for k,v in headers.items(): self.send_header(k.replace('_','-'),v)
        self.send_header('Content-Length',str(len(body))); self.end_headers()
        try: self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError, ssl.SSLError): pass
    def do_GET(self):
        if self.path=='/slow': time.sleep(1.2)
        if self.path=='/short-delay': time.sleep(.08)
        if self.path=='/redirect': return self.reply(302,Location='/ok')
        if self.path=='/loop': return self.reply(302,Location='/loop')
        if self.path=='/big':
            self.send_response(200); self.send_header('Content-Length',str(33*1024*1024));self.end_headers();self.wfile.write(b'x'*1024);self.wfile.flush();time.sleep(.4);return
        self.reply(404 if self.path=='/missing' else 200,b'fixture-ok',Content_Type='text/plain')
    def do_POST(self):
        body=self.rfile.read(int(self.headers.get('Content-Length','0')))
        self.reply(200,json.dumps({'method':self.command,'body':body.decode(),'fixture':self.headers.get('X-Fixture','')}).encode(),Content_Type='application/json')
    do_PUT=do_POST
http_server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
cert=out/'fixture-cert.pem';key=out/'fixture-key.pem'
subprocess.run(['/usr/bin/openssl','req','-x509','-newkey','rsa:2048','-nodes','-keyout',str(key),'-out',str(cert),'-days','1','-subj','/CN=localhost'],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
key.chmod(0o600)
tls=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
ctx=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER);ctx.load_cert_chain(str(cert),str(key));tls.socket=ctx.wrap_socket(tls.socket,server_side=True)
for server in (http_server,tls):threading.Thread(target=server.serve_forever,daemon=True).start()
try:
    subprocess.run([sys.argv[2],f'http://127.0.0.1:{http_server.server_port}',f'https://127.0.0.1:{tls.server_port}',str(out/'http-result.json')],check=True)
finally:
    http_server.shutdown();tls.shutdown();http_server.server_close();tls.server_close()
