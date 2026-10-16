"""HTTP server for maludb-restd.

Uses stdlib http.server.ThreadingHTTPServer; psycopg is the only
runtime dependency. Built-in routes (/healthz, /version, /openapi.json)
short-circuit the catalog lookup so the daemon stays responsive even
when the endpoint catalog is empty.
"""

from __future__ import annotations

import json
import logging
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any

from .db import Pool
from .dispatcher import Dispatcher, DispatchResult


log = logging.getLogger("maludb_restd")


class _Handler(BaseHTTPRequestHandler):
    server_version = "maludb-restd/0.1.0"

    # BaseHTTPRequestHandler logs every request to stderr; silence it,
    # the dispatcher writes a structured audit row instead.
    def log_message(self, format: str, *args: Any) -> None:
        return

    def _read_body(self) -> bytes:
        n = int(self.headers.get("Content-Length", "0") or 0)
        return self.rfile.read(n) if n > 0 else b""

    def _client_ip(self) -> str | None:
        # client_address is (host, port); host may be IPv6.
        addr = self.client_address[0] if self.client_address else None
        return addr

    def _bearer_token(self) -> str | None:
        auth = self.headers.get("Authorization", "")
        if auth.startswith("Bearer "):
            return auth[len("Bearer "):].strip()
        return None

    def _reply(self, result: DispatchResult) -> None:
        body = b"" if result.body is None else json.dumps(result.body).encode("utf-8")
        self.send_response(result.status_code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _serve(self, method: str) -> None:
        path = self.path.split("?", 1)[0]
        dispatcher: Dispatcher = self.server.dispatcher                # type: ignore[attr-defined]

        # Built-in routes — no audit (V3-OBS-01 picks these up later).
        if method == "GET" and path == "/healthz":
            self._reply(dispatcher.healthz())
            return
        if method == "GET" and path == "/version":
            self._reply(dispatcher.version())
            return
        if method == "GET" and path == "/openapi.json":
            self._reply(dispatcher.openapi())
            return

        # Catalog-driven dispatch.
        result = dispatcher.dispatch(
            method=method,
            path=path,
            request_body=self._read_body(),
            bearer_token=self._bearer_token(),
            source_ip=self._client_ip(),
        )
        self._reply(result)

    def do_GET(self) -> None:    self._serve("GET")
    def do_POST(self) -> None:   self._serve("POST")
    def do_PUT(self) -> None:    self._serve("PUT")
    def do_PATCH(self) -> None:  self._serve("PATCH")
    def do_DELETE(self) -> None: self._serve("DELETE")


class RestServer(ThreadingHTTPServer):
    """ThreadingHTTPServer with an attached Dispatcher."""

    daemon_threads = True

    def __init__(self, bind_host: str, bind_port: int, pool: Pool) -> None:
        super().__init__((bind_host, bind_port), _Handler)
        self.dispatcher = Dispatcher(pool)


def serve(bind_host: str, bind_port: int, pool: Pool) -> RestServer:
    """Return a running RestServer. Caller is responsible for calling
    server.shutdown() on teardown.
    """
    server = RestServer(bind_host, bind_port, pool)
    log.info("maludb-restd listening on %s:%d", bind_host, bind_port)
    return server
