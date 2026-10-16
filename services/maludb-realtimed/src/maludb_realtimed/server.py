"""HTTP server for maludb-realtimed.

Endpoints:
  GET  /healthz                  no auth, liveness probe.
  GET  /events?subscription=<id> SSE stream of malu$event rows past
                                 the subscription's persistent cursor.
                                 Bearer token verified via V3-AUTH-01.
                                 LISTEN on `maludb_event` wakes the
                                 stream for new rows; polling fallback
                                 every poll_interval_s seconds.
  POST /events/ack               { "subscription_id": N, "through_event_id": M }
                                 advances the persistent cursor.
"""

from __future__ import annotations

import json
import logging
import os
import select
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any

import psycopg

from .db import Pool
from . import ws

log = logging.getLogger("maludb_realtimed")

POLL_INTERVAL_S = float(os.environ.get("MALUDB_REALTIMED_POLL_S", "1.0"))
BATCH_SIZE      = int(  os.environ.get("MALUDB_REALTIMED_BATCH", "100"))


class _Handler(BaseHTTPRequestHandler):
    server_version = "maludb-realtimed/0.1.0"

    def log_message(self, format: str, *args: Any) -> None:
        return

    # -- helpers --------------------------------------------------------

    def _read_body(self) -> bytes:
        n = int(self.headers.get("Content-Length", "0") or 0)
        return self.rfile.read(n) if n > 0 else b""

    def _bearer(self) -> str | None:
        h = self.headers.get("Authorization", "")
        if h.startswith("Bearer "):
            return h[len("Bearer "):].strip()
        return None

    def _reply_json(self, code: int, body: Any) -> None:
        data = b"" if body is None else json.dumps(body).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _verify_token(self, pool: Pool) -> dict | None:
        token = self._bearer()
        if not token:
            return None
        src_ip = self.client_address[0] if self.client_address else None
        with pool.connection() as conn, conn.cursor() as cur:
            cur.execute(
                "SELECT token_id, account_id, token_kind, scopes "
                "FROM maludb_core.auth_token_verify(%s, %s::inet)",
                (token, src_ip),
            )
            row = cur.fetchone()
        if not row or row[1] is None:
            return None
        return {"token_id": row[0], "account_id": row[1], "kind": row[2], "scopes": row[3] or []}

    # -- routes ---------------------------------------------------------

    def do_GET(self) -> None:
        path, _, qs = self.path.partition("?")
        if path == "/healthz":
            self._reply_json(200, {"status": "ok"})
            return
        if path == "/events":
            self._serve_sse(qs)
            return
        if path == "/events/ws":
            self._serve_ws(qs)
            return
        self._reply_json(404, {"error": "not_found", "path": path})

    def do_POST(self) -> None:
        path = self.path.split("?", 1)[0]
        if path == "/events/ack":
            self._serve_ack()
            return
        self._reply_json(404, {"error": "not_found", "path": path})

    # -- SSE stream -----------------------------------------------------

    def _serve_sse(self, qs: str) -> None:
        pool: Pool = self.server.pool                  # type: ignore[attr-defined]
        params = dict(p.split("=", 1) for p in qs.split("&") if "=" in p)
        try:
            subscription_id = int(params.get("subscription", "0"))
        except ValueError:
            self._reply_json(400, {"error": "subscription must be an integer"})
            return
        if subscription_id <= 0:
            self._reply_json(400, {"error": "subscription required"})
            return

        ctx = self._verify_token(pool)
        if ctx is None:
            self._reply_json(401, {"error": "invalid_or_missing_token"})
            return

        self.send_response(200)
        self.send_header("Content-Type",  "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection",    "keep-alive")
        self.end_headers()

        try:
            with pool.connection() as conn:
                self._bind_account(conn, ctx["account_id"])
                # LISTEN needs autocommit so NOTIFY payloads arrive
                # between transactions instead of being buffered. The
                # account GUC was set in _bind_account; setting
                # autocommit after that is safe because we have no
                # open transaction yet.
                conn.commit()
                conn.autocommit = True
                with conn.cursor() as cur:
                    cur.execute("LISTEN maludb_event")

                # Initial drain (replay anything past the cursor) +
                # then loop: poll/notify, drain, repeat.
                self._drain_once(conn, subscription_id)

                # Bounded loop: gracefully stops when the client
                # disconnects. We use psycopg's notify generator via
                # the underlying conn.pgconn socket.
                deadline = time.monotonic() + 600  # cap a stream at 10 min in case the client never disconnects
                while time.monotonic() < deadline:
                    pg_sock = conn.pgconn.socket
                    r, _, _ = select.select([pg_sock], [], [], POLL_INTERVAL_S)
                    if r:
                        # Drain libpq's socket buffer + any pending
                        # NOTIFY messages without blocking. We don't
                        # act on payloads; the SELECT past the cursor
                        # below picks up whatever has been emitted.
                        conn.pgconn.consume_input()
                        while conn.pgconn.notifies() is not None:
                            pass
                    drained = self._drain_once(conn, subscription_id)
                    if not drained:
                        # Keepalive comment line, per the SSE spec.
                        try:
                            self.wfile.write(b": keepalive\n\n")
                            self.wfile.flush()
                        except Exception:
                            break
        except (BrokenPipeError, ConnectionResetError):
            pass
        except Exception as e:
            log.exception("sse stream error: %s", e)

    def _bind_account(self, conn: psycopg.Connection, account_id: int) -> None:
        with conn.cursor() as cur:
            cur.execute("SET search_path TO maludb_core, public")
            cur.execute(
                "SELECT set_config('maludb_core.current_account_id', %s, false)",
                (str(account_id),),
            )

    def _drain_once(self, conn: psycopg.Connection, subscription_id: int) -> int:
        with conn.cursor() as cur:
            cur.execute(
                "SELECT event_id, event_kind, account_id, partition, "
                "       active_pool_id, object_type, object_id, scope, "
                "       transaction_time, payload "
                "FROM maludb_core.event_fetch_batch(%s, %s)",
                (subscription_id, BATCH_SIZE),
            )
            rows = cur.fetchall()
        if not rows:
            return 0
        for row in rows:
            event = {
                "event_id":          row[0],
                "event_kind":        row[1],
                "account_id":        row[2],
                "partition":         row[3],
                "active_pool_id":    row[4],
                "object_type":       row[5],
                "object_id":         row[6],
                "scope":             row[7],
                "transaction_time":  row[8].isoformat() if row[8] else None,
                "payload":           row[9],
            }
            try:
                self.wfile.write(f"id: {row[0]}\nevent: {row[1]}\ndata: {json.dumps(event, default=str)}\n\n".encode("utf-8"))
                self.wfile.flush()
            except Exception:
                raise
        return len(rows)

    # -- WebSocket stream ----------------------------------------------

    def _serve_ws(self, qs: str) -> None:
        pool: Pool = self.server.pool                  # type: ignore[attr-defined]
        params = dict(p.split("=", 1) for p in qs.split("&") if "=" in p)
        try:
            subscription_id = int(params.get("subscription", "0"))
        except ValueError:
            self._reply_json(400, {"error": "subscription must be an integer"})
            return
        if subscription_id <= 0:
            self._reply_json(400, {"error": "subscription required"})
            return

        # Auth must succeed before we accept the WS upgrade so that
        # rejection is a normal HTTP response (401), not a half-open
        # WebSocket close.
        ctx = self._verify_token(pool)
        if ctx is None:
            self._reply_json(401, {"error": "invalid_or_missing_token"})
            return

        status, hdrs = ws.handshake_response(self.headers)
        if status != 101:
            self.send_response(status)
            for k, v in hdrs.items():
                self.send_header(k, v)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return

        self.send_response(101)
        for k, v in hdrs.items():
            self.send_header(k, v)
        self.end_headers()

        # Hand off the raw socket from BaseHTTPRequestHandler. We continue
        # to use self.wfile/self.rfile for the WS framing; both are
        # buffered file-like wrappers around the underlying socket.
        try:
            with pool.connection() as conn:
                self._bind_account(conn, ctx["account_id"])
                conn.commit()
                conn.autocommit = True
                with conn.cursor() as cur:
                    cur.execute("LISTEN maludb_event")

                self._ws_drain(conn, subscription_id)

                deadline = time.monotonic() + 600
                while time.monotonic() < deadline:
                    pg_sock = conn.pgconn.socket
                    client_sock = self.request
                    r, _, _ = select.select(
                        [pg_sock, client_sock], [], [], POLL_INTERVAL_S)
                    if pg_sock in r:
                        conn.pgconn.consume_input()
                        while conn.pgconn.notifies() is not None:
                            pass
                    if client_sock in r:
                        # Read one inbound frame. The client either sent
                        # an ack message (JSON {ack: N}), a close, or a
                        # ping.
                        try:
                            opcode, payload = ws.recv_frame(self.rfile)
                        except ws.WSError:
                            ws.send_close(self.wfile, 1002, "protocol_error")
                            break
                        if opcode == ws.OPCODE_CLOSE:
                            try:
                                ws.send_close(self.wfile, 1000, "")
                            except Exception:
                                pass
                            break
                        if opcode == ws.OPCODE_PING:
                            ws._send_frame(self.wfile, ws.OPCODE_PONG, payload)
                            continue
                        if opcode == ws.OPCODE_TEXT:
                            self._ws_handle_inbound(conn, payload, subscription_id)
                    self._ws_drain(conn, subscription_id)
        except (BrokenPipeError, ConnectionResetError):
            pass
        except Exception as e:
            log.exception("ws stream error: %s", e)
            try:
                ws.send_close(self.wfile, 1011, "internal_error")
            except Exception:
                pass

    def _ws_drain(self, conn: psycopg.Connection, subscription_id: int) -> int:
        with conn.cursor() as cur:
            cur.execute(
                "SELECT event_id, event_kind, account_id, partition, "
                "       active_pool_id, object_type, object_id, scope, "
                "       transaction_time, payload "
                "FROM maludb_core.event_fetch_batch(%s, %s)",
                (subscription_id, BATCH_SIZE),
            )
            rows = cur.fetchall()
        for row in rows:
            event = {
                "event_id":         row[0],
                "event_kind":       row[1],
                "account_id":       row[2],
                "partition":        row[3],
                "active_pool_id":   row[4],
                "object_type":      row[5],
                "object_id":        row[6],
                "scope":            row[7],
                "transaction_time": row[8].isoformat() if row[8] else None,
                "payload":          row[9],
            }
            ws.send_text(self.wfile, json.dumps(event, default=str))
        return len(rows)

    def _ws_handle_inbound(self, conn: psycopg.Connection,
                           payload: bytes, subscription_id: int) -> None:
        try:
            msg = json.loads(payload.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            return
        if not isinstance(msg, dict):
            return
        through = msg.get("ack")
        if isinstance(through, int) and through > 0:
            with conn.cursor() as cur:
                cur.execute(
                    "SELECT maludb_core.event_ack(%s, %s)",
                    (subscription_id, through),
                )
                acked = cur.fetchone()[0]
            ws.send_text(self.wfile,
                json.dumps({"ack_result": {"subscription_id": subscription_id,
                                           "through_event_id": through,
                                           "acked": acked}}))

    # -- ack ------------------------------------------------------------

    def _serve_ack(self) -> None:
        pool: Pool = self.server.pool                  # type: ignore[attr-defined]
        try:
            body = json.loads(self._read_body() or b"{}")
        except json.JSONDecodeError:
            self._reply_json(400, {"error": "invalid_json"})
            return
        sid     = body.get("subscription_id")
        through = body.get("through_event_id")
        if not isinstance(sid, int) or not isinstance(through, int):
            self._reply_json(400, {"error": "subscription_id and through_event_id required (integers)"})
            return

        ctx = self._verify_token(pool)
        if ctx is None:
            self._reply_json(401, {"error": "invalid_or_missing_token"})
            return

        with pool.connection() as conn:
            self._bind_account(conn, ctx["account_id"])
            with conn.cursor() as cur:
                cur.execute(
                    "SELECT maludb_core.event_ack(%s, %s)",
                    (sid, through),
                )
                n = cur.fetchone()[0]
        self._reply_json(200, {"subscription_id": sid, "acked": n, "through_event_id": through})


class RealtimeServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, bind_host: str, bind_port: int, pool: Pool) -> None:
        super().__init__((bind_host, bind_port), _Handler)
        self.pool = pool


def serve(bind_host: str, bind_port: int, pool: Pool) -> RealtimeServer:
    server = RealtimeServer(bind_host, bind_port, pool)
    log.info("maludb-realtimed listening on %s:%d", bind_host, bind_port)
    return server
