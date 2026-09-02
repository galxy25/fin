#!/usr/bin/env python3
"""Bearer-auth shim in front of LM Studio for PUBLIC (Funnel) exposure.

LM Studio has no auth of its own, so the public path must never reach it
directly: Tailscale Funnel mounts a path (e.g. :8443/llm) that proxies here,
and this shim forwards to LM Studio (localhost:1234) only when the request
carries the expected bearer token. Streaming (SSE) responses are passed
through unbuffered — chunked reads, immediate writes — because buffering
breaks token streaming.

Config via environment:
  FIN_LLM_SHIM_TOKEN   required, the bearer token
  FIN_LLM_SHIM_PORT    default 8446
  FIN_LLM_UPSTREAM     default http://127.0.0.1:1234
"""
import http.client
import http.server
import os
import socketserver
import sys
from urllib.parse import urlsplit

TOKEN = os.environ.get("FIN_LLM_SHIM_TOKEN")
PORT = int(os.environ.get("FIN_LLM_SHIM_PORT", "8446"))
UPSTREAM = urlsplit(os.environ.get("FIN_LLM_UPSTREAM", "http://127.0.0.1:1234"))

if not TOKEN:
    sys.exit("FIN_LLM_SHIM_TOKEN is required")

# Hop-by-hop headers must not be forwarded either direction.
HOP_BY_HOP = {
    "connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
    "te", "trailers", "transfer-encoding", "upgrade", "host", "authorization",
}


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _reject(self, code, message):
        body = message.encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _proxy(self):
        auth = self.headers.get("Authorization", "")
        if auth != f"Bearer {TOKEN}":
            self._reject(401, "unauthorized")
            return

        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else None

        upstream = http.client.HTTPConnection(
            UPSTREAM.hostname, UPSTREAM.port or 80, timeout=600
        )
        try:
            headers = {
                key: value for key, value in self.headers.items()
                if key.lower() not in HOP_BY_HOP
            }
            upstream.request(self.command, self.path, body=body, headers=headers)
            response = upstream.getresponse()

            self.send_response(response.status)
            for key, value in response.getheaders():
                if key.lower() not in HOP_BY_HOP and key.lower() != "content-length":
                    self.send_header(key, value)
            # Stream chunked: SSE responses have no usable length up front.
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            while True:
                chunk = response.read(8192)
                if not chunk:
                    break
                self.wfile.write(b"%x\r\n" % len(chunk) + chunk + b"\r\n")
                self.wfile.flush()
            self.wfile.write(b"0\r\n\r\n")
        except Exception:
            try:
                self._reject(502, "upstream error")
            except Exception:
                pass
        finally:
            upstream.close()

    do_GET = _proxy
    do_POST = _proxy

    def log_message(self, format, *args):  # quiet: launchd captures stderr anyway
        pass


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True


if __name__ == "__main__":
    # Localhost bind ONLY — the sole public route is the Funnel mount.
    Server(("127.0.0.1", PORT), Handler).serve_forever()
