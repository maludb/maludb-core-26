#!/usr/bin/env python3
"""Minimal HTTP MCP server fixture for mc2dbd R1.1-2 service tests.

Listens on 127.0.0.1:<port> (port passed as argv[1]). On POST, parses
the JSON-RPC request and replies with a result that echoes the
arguments back as MCP content. Exits cleanly on SIGTERM.
"""

import json
import sys
from http.server import HTTPServer, BaseHTTPRequestHandler


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args, **_kwargs):
        return  # quiet

    def do_POST(self):
        n = int(self.headers.get("Content-Length", "0") or "0")
        try:
            req = json.loads(self.rfile.read(n) or b"{}")
        except Exception:
            self.send_response(400)
            self.end_headers()
            return
        rid = req.get("id")
        params = req.get("params") or {}
        text = "http_echo:" + json.dumps(params, sort_keys=True)
        resp = {
            "jsonrpc": "2.0",
            "id": rid,
            "result": {
                "content": [{"type": "text", "text": text}],
                "structuredContent": {"params": params},
            },
        }
        body = json.dumps(resp).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 6001
    HTTPServer(("127.0.0.1", port), Handler).serve_forever()
