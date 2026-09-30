#!/usr/bin/env python3
"""Local storage proxy for the OpenHarmony Flutter tool.

The SIG OBS bucket (flutter-ohos.obs.cn-south-1.myhuaweicloud.com) does not
carry every upstream host artifact (notably linux-x64/font-subset.zip), but
the SIG flutter tool requests them by upstream layout. This proxy fronts the
OBS bucket and falls back to the official Flutter mirror (storage.flutter-io.cn)
on 404, so `FLUTTER_STORAGE_BASE_URL=http://127.0.0.1:8899` just works. Fallback
order prefers storage.googleapis.com (runners sit outside CN where the
flutter-io.cn mirror answers 403).

Run: python3 scripts/ohos_storage_proxy.py [port]
"""
import sys
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PRIMARY = 'https://flutter-ohos.obs.cn-south-1.myhuaweicloud.com'
# Order matters: runners are usually outside CN, where the flutter-io.cn
# mirror answers 403 — prefer the global Google bucket first.
FALLBACKS = [
    'https://storage.googleapis.com',
    'https://storage.flutter-io.cn',
]


class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def _upstream(self, method):
        last_error = None
        for base in [PRIMARY, *FALLBACKS]:
            try:
                req = urllib.request.Request(base + self.path, method=method)
                resp = urllib.request.urlopen(req, timeout=300)
                return resp
            except urllib.error.HTTPError as e:
                last_error = e
                if e.code not in (404, 403):
                    raise
            except Exception as e:  # network hiccup — try the fallback
                last_error = e
        raise last_error or urllib.error.URLError('all upstreams failed')

    def _relay(self, send_body):
        try:
            resp = self._upstream('GET' if send_body else 'HEAD')
        except urllib.error.HTTPError as e:
            self.send_error(e.code)
            return
        except Exception as e:
            self.send_error(502, str(e))
            return
        with resp:
            length = resp.headers.get('Content-Length')
            self.send_response(resp.status)
            for key in ('Content-Type', 'Content-Length', 'ETag'):
                if key in resp.headers:
                    self.send_header(key, resp.headers[key])
            self.end_headers()
            if send_body:
                while True:
                    chunk = resp.read(1024 * 1024)
                    if not chunk:
                        break
                    self.wfile.write(chunk)

    def do_GET(self):
        self._relay(send_body=True)

    def do_HEAD(self):
        self._relay(send_body=False)

    def log_message(self, fmt, *args):
        sys.stderr.write('%s %s\n' % (self.command, self.path))


if __name__ == '__main__':
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8899
    print(f'ohos storage proxy on 127.0.0.1:{port} '
          f'(primary={PRIMARY}, fallbacks={FALLBACKS})', flush=True)
    ThreadingHTTPServer(('127.0.0.1', port), Handler).serve_forever()
