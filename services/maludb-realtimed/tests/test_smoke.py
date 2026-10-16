"""V3-REALTIME-01 smoke — drives maludb-realtimed end-to-end."""

from __future__ import annotations

import json
import os
import socket
import threading
import time
import unittest
import urllib.request

import psycopg

from maludb_realtimed.db import Pool
from maludb_realtimed.server import RealtimeServer


def _free_port() -> int:
    s = socket.socket(); s.bind(("127.0.0.1", 0)); p = s.getsockname()[1]; s.close(); return p


def _conn():
    return psycopg.connect(
        dbname=os.environ.get("MALUDB_REALTIMED_DB", "contrib_regression"),
        autocommit=True,
    )


class RealtimedSmoke(unittest.TestCase):

    @classmethod
    def setUpClass(cls) -> None:
        os.environ.setdefault("MALUDB_REALTIMED_DB", "contrib_regression")
        cls.pool   = Pool()
        cls.port   = _free_port()
        cls.server = RealtimeServer("127.0.0.1", cls.port, cls.pool)
        cls.thread = threading.Thread(target=cls.server.serve_forever,
                                      kwargs={"poll_interval": 0.05},
                                      daemon=True)
        cls.thread.start()
        for _ in range(40):
            try:
                with socket.create_connection(("127.0.0.1", cls.port), timeout=0.5):
                    break
            except OSError:
                time.sleep(0.05)

        # Seed: an account, a token, and a subscription with cursor=0.
        with _conn() as c, c.cursor() as cur:
            cur.execute("SET search_path TO maludb_core, public")
            cur.execute("""
                INSERT INTO malu$account(account_name, account_kind, description)
                VALUES ('realtimed_smoke', 'service', 'V3-REALTIME-01 smoke')
                ON CONFLICT (account_name) DO UPDATE SET enabled = true
                RETURNING account_id
            """)
            cls.account_id = cur.fetchone()[0]
            cur.execute(
                "SELECT plaintext_token FROM auth_token_create(%s, 'service', 'realtimed-smoke')",
                (cls.account_id,),
            )
            cls.token = cur.fetchone()[0]
            cur.execute("SELECT MAX(event_id) FROM malu$event")
            start = cur.fetchone()[0] or 0
            cls.start_cursor = start
            cur.execute(
                "SELECT event_subscribe('realtimed_smoke_sub', %s, "
                "ARRAY[]::text[], ARRAY[]::text[], NULL, %s)",
                (cls.account_id, start),
            )
            cls.sub_id = cur.fetchone()[0]

    @classmethod
    def tearDownClass(cls) -> None:
        cls.server.shutdown()
        cls.thread.join(timeout=2)
        cls.pool.close()
        with _conn() as c, c.cursor() as cur:
            cur.execute("SET search_path TO maludb_core, public")
            cur.execute("DELETE FROM malu$event_delivery WHERE subscription_id = %s", (cls.sub_id,))
            cur.execute("DELETE FROM malu$event_subscription WHERE subscription_id = %s", (cls.sub_id,))
            cur.execute("DELETE FROM malu$event WHERE event_kind LIKE 'rt_smoke_%'")
            cur.execute("DELETE FROM malu$auth_token_use WHERE token_id IN (SELECT token_id FROM malu$auth_token WHERE account_id = %s)", (cls.account_id,))
            cur.execute("DELETE FROM malu$auth_token WHERE account_id = %s", (cls.account_id,))
            cur.execute("DELETE FROM malu$audit_event WHERE event_kind LIKE 'auth_token_%'")
            cur.execute("DELETE FROM malu$account WHERE account_id = %s", (cls.account_id,))

    # -- tests -----------------------------------------------------------

    def test_01_healthz(self):
        with urllib.request.urlopen(f"http://127.0.0.1:{self.port}/healthz", timeout=2) as r:
            self.assertEqual(r.status, 200)
            body = json.loads(r.read())
            self.assertEqual(body["status"], "ok")

    def test_02_ack_advances_cursor(self):
        # Emit two events, ack through the second one, confirm the
        # subscription's cursor moved.
        with _conn() as c, c.cursor() as cur:
            cur.execute("SET search_path TO maludb_core, public")
            cur.execute("SELECT emit_event('rt_smoke_ack', '{\"i\":1}'::jsonb)")
            e1 = cur.fetchone()[0]
            cur.execute("SELECT emit_event('rt_smoke_ack', '{\"i\":2}'::jsonb)")
            e2 = cur.fetchone()[0]

        req = urllib.request.Request(
            f"http://127.0.0.1:{self.port}/events/ack",
            data=json.dumps({"subscription_id": self.sub_id, "through_event_id": e2}).encode("utf-8"),
            method="POST",
            headers={"Authorization": f"Bearer {self.token}",
                     "Content-Type": "application/json"},
        )
        with urllib.request.urlopen(req, timeout=2) as r:
            body = json.loads(r.read())
            self.assertEqual(body["subscription_id"], self.sub_id)
            self.assertGreaterEqual(body["acked"], 2)

        with _conn() as c, c.cursor() as cur:
            cur.execute("SET search_path TO maludb_core, public")
            cur.execute("SELECT cursor FROM malu$event_subscription WHERE subscription_id = %s", (self.sub_id,))
            self.assertEqual(cur.fetchone()[0], e2)

    def test_03_sse_stream_receives_emitted(self):
        # Open an SSE stream in a thread, then emit an event. Verify
        # the thread reads at least one event row with our test kind.
        received: list[str] = []
        reader_error: list[Exception] = []
        stop = threading.Event()

        def reader():
            # Blocking-read reader; the daemon thread is reaped when
            # the test process exits. We don't try to interrupt via
            # socket timeout because that puts the buffered reader
            # into an unrecoverable "timed out object" state on the
            # first miss. Server shutdown closes the connection,
            # which makes readline() return b''.
            req = urllib.request.Request(
                f"http://127.0.0.1:{self.port}/events?subscription={self.sub_id}",
                headers={"Authorization": f"Bearer {self.token}"},
            )
            try:
                with urllib.request.urlopen(req, timeout=15) as r:
                    while not stop.is_set():
                        line = r.readline()
                        if not line:
                            break
                        received.append(line.decode("utf-8", "replace").rstrip("\n"))
            except Exception as e:                                      # noqa: BLE001
                reader_error.append(e)

        t = threading.Thread(target=reader, daemon=True)
        t.start()
        time.sleep(1.0)  # let the stream attach + initial drain

        with _conn() as c, c.cursor() as cur:
            cur.execute("SET search_path TO maludb_core, public")
            cur.execute("SELECT emit_event('rt_smoke_sse', '{\"hello\":\"stream\"}'::jsonb)")
            eid = cur.fetchone()[0]

        # Wait up to 6s for the stream to surface that event.
        deadline = time.monotonic() + 6
        while time.monotonic() < deadline:
            if any(f"id: {eid}" in line for line in received):
                break
            time.sleep(0.1)

        stop.set()
        t.join(timeout=3)

        self.assertFalse(reader_error,
            f"reader exception: {reader_error[0] if reader_error else None}")
        self.assertTrue(any(f"id: {eid}" in line for line in received),
                        f"SSE stream did not surface event {eid}; "
                        f"received_count={len(received)}; sample={received[:8]}")
        self.assertTrue(any("event: rt_smoke_sse" in line for line in received))

    def test_04_unauthenticated_rejected(self):
        req = urllib.request.Request(
            f"http://127.0.0.1:{self.port}/events?subscription={self.sub_id}",
        )
        try:
            with urllib.request.urlopen(req, timeout=2) as r:
                self.fail(f"unauthenticated stream returned {r.status}")
        except urllib.error.HTTPError as e:
            self.assertEqual(e.code, 401)

    # -- V3-REALTIME-02b: WebSocket transport ---------------------------

    def test_05_ws_stream_receives_emitted(self):
        """Open a WebSocket against /events/ws, emit an event, expect
        the framed JSON to arrive."""
        import base64
        import os as _os

        # Manual WS handshake over a raw TCP socket — stdlib has no WS
        # client. We send the GET upgrade, parse the 101 response, then
        # read framed text from the same socket.
        sock = socket.create_connection(("127.0.0.1", self.port), timeout=5)
        try:
            key = base64.b64encode(_os.urandom(16)).decode("ascii")
            req = (
                f"GET /events/ws?subscription={self.sub_id} HTTP/1.1\r\n"
                f"Host: 127.0.0.1:{self.port}\r\n"
                f"Upgrade: websocket\r\n"
                f"Connection: Upgrade\r\n"
                f"Sec-WebSocket-Key: {key}\r\n"
                f"Sec-WebSocket-Version: 13\r\n"
                f"Authorization: Bearer {self.token}\r\n"
                f"\r\n"
            )
            sock.sendall(req.encode("ascii"))

            # Read response headers up to \r\n\r\n.
            buf = b""
            while b"\r\n\r\n" not in buf:
                chunk = sock.recv(4096)
                if not chunk:
                    self.fail("server closed before handshake")
                buf += chunk
            head, _, rest = buf.partition(b"\r\n\r\n")
            status_line = head.split(b"\r\n", 1)[0].decode("ascii")
            self.assertIn("101", status_line, f"expected 101 upgrade, got: {status_line}")

            # Emit a fresh event AFTER the handshake so it's past the
            # subscription's persistent cursor.
            with _conn() as c, c.cursor() as cur:
                cur.execute("SET search_path TO maludb_core, public")
                cur.execute("SELECT emit_event('rt_smoke_ws', '{\"src\":\"ws\"}'::jsonb)")
                eid = cur.fetchone()[0]

            # Read frames (server -> client is unmasked text). Carry
            # `rest` from the handshake-read in case the first frame
            # arrived in the same recv().
            buf = rest
            deadline = time.monotonic() + 6
            matched = False
            while time.monotonic() < deadline and not matched:
                while len(buf) < 2:
                    chunk = sock.recv(4096)
                    if not chunk:
                        break
                    buf += chunk
                if len(buf) < 2:
                    break
                b1, b2 = buf[0], buf[1]
                opcode = b1 & 0x0F
                length = b2 & 0x7F
                off = 2
                if length == 126:
                    while len(buf) < off + 2:
                        chunk = sock.recv(4096)
                        if not chunk:
                            break
                        buf += chunk
                    length = int.from_bytes(buf[off:off+2], "big")
                    off += 2
                elif length == 127:
                    while len(buf) < off + 8:
                        chunk = sock.recv(4096)
                        if not chunk:
                            break
                        buf += chunk
                    length = int.from_bytes(buf[off:off+8], "big")
                    off += 8
                while len(buf) < off + length:
                    chunk = sock.recv(4096)
                    if not chunk:
                        break
                    buf += chunk
                payload = buf[off:off+length]
                buf = buf[off+length:]
                if opcode == 0x1:               # text
                    try:
                        ev = json.loads(payload.decode("utf-8"))
                    except (UnicodeDecodeError, json.JSONDecodeError):
                        continue
                    if ev.get("event_id") == eid and ev.get("event_kind") == "rt_smoke_ws":
                        matched = True
            self.assertTrue(matched,
                f"WS stream did not surface event {eid} within deadline; buf_tail={buf[-256:]!r}")
        finally:
            sock.close()

    def test_06_ws_unauthenticated_rejected(self):
        """No bearer + WS upgrade headers must yield 401 (not 101)."""
        import base64
        import os as _os
        sock = socket.create_connection(("127.0.0.1", self.port), timeout=5)
        try:
            key = base64.b64encode(_os.urandom(16)).decode("ascii")
            req = (
                f"GET /events/ws?subscription={self.sub_id} HTTP/1.1\r\n"
                f"Host: 127.0.0.1:{self.port}\r\n"
                f"Upgrade: websocket\r\n"
                f"Connection: Upgrade\r\n"
                f"Sec-WebSocket-Key: {key}\r\n"
                f"Sec-WebSocket-Version: 13\r\n"
                f"\r\n"
            )
            sock.sendall(req.encode("ascii"))
            buf = b""
            while b"\r\n\r\n" not in buf:
                chunk = sock.recv(4096)
                if not chunk:
                    break
                buf += chunk
            status_line = buf.split(b"\r\n", 1)[0].decode("ascii")
            self.assertIn("401", status_line, f"expected 401, got: {status_line}")
        finally:
            sock.close()


if __name__ == "__main__":
    unittest.main(verbosity=2)
