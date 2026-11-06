"""The board: a local web page over the same data as `radar json`.

Listens on 127.0.0.1 only. Actions (open, seen) need the X-Radar header, which a
web page on another origin cannot send without a CORS preflight this server never
answers, so other sites cannot trigger them.
"""
import json
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import core

BOARD = Path(__file__).resolve().parent / "board.html"


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def _send(self, code, body, kind="application/json"):
        data = body if isinstance(body, bytes) else json.dumps(body, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", kind + "; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path in ("/", "/index.html"):
            self._send(200, BOARD.read_bytes(), "text/html")
        elif self.path == "/api/state":
            rows = core.sessions()
            self._send(200, {"counts": core.summary(rows), "sessions": rows})
        else:
            self._send(404, {"error": "not found"})

    def do_POST(self):
        if self.headers.get("X-Radar") != "1":
            return self._send(403, {"error": "missing X-Radar header"})
        parts = self.path.strip("/").split("/")
        if len(parts) != 3 or parts[0] != "api" or parts[1] not in ("open", "seen"):
            return self._send(404, {"error": "not found"})
        rows = core.sessions()
        if parts[1] == "seen" and parts[2] == "all":
            core.mark_seen([r["id"] for r in rows if r["column"] in ("review", "done")])
            return self._send(200, {"ok": True})
        row = core.find(rows, parts[2])
        if not row:
            return self._send(404, {"error": "no such session"})
        core.open_session(row) if parts[1] == "open" else core.mark_seen([row["id"]])
        self._send(200, {"ok": True})


def serve(port=7878, open_browser=True):
    httpd = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    url = f"http://127.0.0.1:{port}/"
    print(f"AI Session Radar board on {url}  (Ctrl+C to stop)")
    if open_browser:
        webbrowser.open(url)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
