#!/usr/bin/env python3
from __future__ import annotations

import argparse
import http.client
import json
from pathlib import Path
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

HOP_BY_HOP = {
    "connection", "keep-alive", "proxy-authenticate",
    "proxy-authorization", "te", "trailers",
    "transfer-encoding", "upgrade",
}


class Handler(SimpleHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def __init__(self, *args, web_dir: Path, api_host: str, api_port: int, **kwargs):
        self.web_dir = web_dir
        self.api_host = api_host
        self.api_port = api_port
        super().__init__(*args, directory=str(web_dir), **kwargs)

    def end_headers(self):
        self.send_header("Cache-Control", "no-store, no-cache, must-revalidate")
        self.send_header("Pragma", "no-cache")
        self.send_header("Expires", "0")
        super().end_headers()

    def _is_api(self):
        path = urlsplit(self.path).path
        return path == "/api" or path.startswith("/api/")

    def do_GET(self):
        if self._is_api():
            self._proxy()
            return
        parsed = urlsplit(self.path)
        target = (self.web_dir / parsed.path.lstrip("/")).resolve()
        try:
            target.relative_to(self.web_dir.resolve())
        except ValueError:
            self.send_error(403)
            return
        if parsed.path == "/" or target.is_file():
            super().do_GET()
            return
        index = self.web_dir / "index.html"
        data = index.read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_HEAD(self):
        if self._is_api():
            self._proxy()
        else:
            super().do_HEAD()

    def do_POST(self): self._proxy_or_404()
    def do_PUT(self): self._proxy_or_404()
    def do_PATCH(self): self._proxy_or_404()
    def do_DELETE(self): self._proxy_or_404()

    def do_OPTIONS(self):
        if self._is_api():
            self._proxy()
            return
        self.send_response(204)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def _proxy_or_404(self):
        if not self._is_api():
            self.send_error(404)
            return
        self._proxy()

    def _proxy(self):
        parsed = urlsplit(self.path)
        path = parsed.path.removeprefix("/api") or "/"
        if parsed.query:
            path += "?" + parsed.query
        length = int(self.headers.get("Content-Length", "0") or "0")
        body = self.rfile.read(length) if length else None
        headers = {}
        for name, value in self.headers.items():
            lower = name.lower()
            if lower in HOP_BY_HOP or lower in {"host", "content-length", "accept-encoding"}:
                continue
            headers[name] = value
        headers["Host"] = f"{self.api_host}:{self.api_port}"

        connection = http.client.HTTPConnection(self.api_host, self.api_port, timeout=12)
        try:
            connection.request(self.command, path, body=body, headers=headers)
            response = connection.getresponse()
            payload = response.read()
            self.send_response(response.status, response.reason)
            for name, value in response.getheaders():
                lower = name.lower()
                if lower in HOP_BY_HOP or lower == "content-length":
                    continue
                self.send_header(name, value)
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(payload)
        except (OSError, TimeoutError, http.client.HTTPException) as error:
            payload = json.dumps({"detail": f"API interna indisponível: {error}"}).encode()
            self.send_response(502)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(payload)
        finally:
            connection.close()

    def log_message(self, fmt, *args):
        print(f"[gateway] {fmt % args}", flush=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--web-dir", type=Path, required=True)
    parser.add_argument("--listen", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--api-host", default="127.0.0.1")
    parser.add_argument("--api-port", type=int, default=8080)
    args = parser.parse_args()
    web_dir = args.web_dir.expanduser().resolve()
    if not (web_dir / "index.html").is_file():
        raise SystemExit(f"Build Flutter ausente em {web_dir}")

    def factory(*a, **kw):
        return Handler(*a, web_dir=web_dir, api_host=args.api_host, api_port=args.api_port, **kw)

    server = ThreadingHTTPServer((args.listen, args.port), factory)
    print(f"Aplicativo: http://{args.listen}:{args.port}", flush=True)
    print(f"API pelo app: http://{args.listen}:{args.port}/api", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
