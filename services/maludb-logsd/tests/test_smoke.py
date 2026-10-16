"""maludb-logsd smoke tests.

Exercises the worker against the live contrib_regression database.
Each test inserts catalog rows directly, runs Worker.iterate_once()
synchronously, and asserts the sink side-effects + cursor advance.
"""

from __future__ import annotations

import json
import os
import socket
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer

import psycopg

from maludb_logsd.db import Pool
from maludb_logsd.worker import Worker


def _conn():
    return psycopg.connect(
        dbname=os.environ.get("MALUDB_LOGSD_DB", "contrib_regression"),
        autocommit=True,
    )


def _free_port() -> int:
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


class _Collector(BaseHTTPRequestHandler):
    received: list[dict] = []

    def do_POST(self):                                          # noqa: N802
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length)
        self.__class__.received.append(json.loads(body))
        self.send_response(200)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def log_message(self, *args, **kwargs):                     # noqa: ARG002
        pass


class LogsdSmoke(unittest.TestCase):

    @classmethod
    def setUpClass(cls) -> None:
        os.environ.setdefault("MALUDB_LOGSD_DB", "contrib_regression")
        cls.pool = Pool()

        # Spin up a tiny HTTP collector for the http-sink test.
        cls.collector_port = _free_port()
        cls.collector = HTTPServer(("127.0.0.1", cls.collector_port), _Collector)
        cls.collector_thread = threading.Thread(
            target=cls.collector.serve_forever, kwargs={"poll_interval": 0.05},
            daemon=True)
        cls.collector_thread.start()

        # Wait for socket readiness.
        for _ in range(40):
            try:
                with socket.create_connection(("127.0.0.1", cls.collector_port),
                                              timeout=0.5):
                    break
            except OSError:
                time.sleep(0.05)

        cls.tmpdir = tempfile.mkdtemp(prefix="logsd-smoke-")

    @classmethod
    def tearDownClass(cls) -> None:
        cls.collector.shutdown()
        cls.collector_thread.join(timeout=2)

    def setUp(self) -> None:
        _Collector.received.clear()
        with _conn() as c, c.cursor() as cur:
            cur.execute("SET search_path TO maludb_core, public")
            cur.execute(
                "DELETE FROM malu$log_drain_run WHERE drain_id IN "
                "(SELECT drain_id FROM malu$log_drain WHERE name LIKE 'logsd_smoke_%')")
            cur.execute(
                "DELETE FROM malu$log_drain WHERE name LIKE 'logsd_smoke_%'")
            cur.execute(
                "DELETE FROM malu$audit_event WHERE event_kind = 'logsd_smoke_kind'")

    # ------------------------------------------------------------------

    def test_01_file_sink_audit_stream(self):
        path = os.path.join(self.tmpdir, "audit.jsonl")
        # Make sure the file is empty so the assertion is unambiguous.
        open(path, "w").close()

        with _conn() as c, c.cursor() as cur:
            cur.execute("SET search_path TO maludb_core, public")
            cur.execute(
                "SELECT log_drain_set(%s, %s, %s, %s)",
                ("logsd_smoke_file", "file",
                 json.dumps({"path": path}),
                 ["audit"]))
            drain_id = cur.fetchone()[0]

            # Insert two audit events that will be > the (zero) cursor.
            cur.execute(
                "SELECT audit_event('logsd_smoke_kind', NULL, NULL, '{\"i\":1}'::jsonb, NULL)")
            cur.execute(
                "SELECT audit_event('logsd_smoke_kind', NULL, NULL, '{\"i\":2}'::jsonb, NULL)")

        worker = Worker(self.pool, batch_size=100)
        summary = worker.iterate_once()
        self.assertGreaterEqual(summary["records"], 2)
        self.assertEqual(summary["errors"], 0)

        with open(path) as f:
            lines = [json.loads(l) for l in f if l.strip()]
        kinds = [r["event_kind"] for r in lines]
        self.assertEqual(kinds.count("logsd_smoke_kind"), 2)
        self.assertTrue(all(r["stream"] == "audit" for r in lines))

        # Cursor advanced; a second iteration is a no-op.
        summary2 = worker.iterate_once()
        self.assertEqual(summary2["records"], 0)

        with _conn() as c, c.cursor() as cur:
            cur.execute("SET search_path TO maludb_core, public")
            cur.execute(
                "SELECT cursor_jsonb ->> 'audit' FROM malu$log_drain "
                "WHERE drain_id = %s", (drain_id,))
            cur_val = int(cur.fetchone()[0])
            self.assertGreater(cur_val, 0)

            # A malu$log_drain_run row was recorded with records >= 2.
            cur.execute(
                "SELECT MAX(records) FROM malu$log_drain_run "
                "WHERE drain_id = %s", (drain_id,))
            self.assertGreaterEqual(cur.fetchone()[0], 2)

    def test_02_http_sink_realtime_stream(self):
        url = f"http://127.0.0.1:{self.collector_port}/ingest"
        with _conn() as c, c.cursor() as cur:
            cur.execute("SET search_path TO maludb_core, public")
            cur.execute(
                "SELECT log_drain_set(%s, %s, %s, %s)",
                ("logsd_smoke_http", "http",
                 json.dumps({"url": url, "timeout_s": 5}),
                 ["realtime_event"]))
            drain_id = cur.fetchone()[0]

            cur.execute(
                "SELECT emit_event('logsd_smoke_rt', '{\"i\":1}'::jsonb)")
            cur.execute(
                "SELECT emit_event('logsd_smoke_rt', '{\"i\":2}'::jsonb)")

        worker = Worker(self.pool, batch_size=100)
        summary = worker.iterate_once()
        self.assertGreaterEqual(summary["records"], 2)
        self.assertEqual(summary["errors"], 0)

        self.assertGreaterEqual(len(_Collector.received), 1)
        records = []
        for body in _Collector.received:
            records.extend(body.get("records", []))
        kinds = [r["event_kind"] for r in records]
        self.assertGreaterEqual(kinds.count("logsd_smoke_rt"), 2)

        # cleanup the emitted realtime events.
        with _conn() as c, c.cursor() as cur:
            cur.execute("SET search_path TO maludb_core, public")
            cur.execute(
                "DELETE FROM malu$event WHERE event_kind = 'logsd_smoke_rt'")

    def test_03_unimplemented_kind_records_error(self):
        with _conn() as c, c.cursor() as cur:
            cur.execute("SET search_path TO maludb_core, public")
            cur.execute(
                "SELECT log_drain_set(%s, %s, %s, %s)",
                ("logsd_smoke_s3", "s3",
                 json.dumps({"bucket": "fake", "key_prefix": "/logs/"}),
                 ["audit"]))
            drain_id = cur.fetchone()[0]

        worker = Worker(self.pool, batch_size=100)
        summary = worker.iterate_once()
        self.assertGreaterEqual(summary["errors"], 1)

        with _conn() as c, c.cursor() as cur:
            cur.execute("SET search_path TO maludb_core, public")
            cur.execute(
                "SELECT last_error FROM malu$log_drain_run "
                "WHERE drain_id = %s ORDER BY run_id DESC LIMIT 1",
                (drain_id,))
            err = cur.fetchone()[0]
            self.assertIn("s3", err)

    def test_04_disabled_drain_is_skipped(self):
        with _conn() as c, c.cursor() as cur:
            cur.execute("SET search_path TO maludb_core, public")
            cur.execute(
                "SELECT log_drain_set(%s, %s, %s, %s)",
                ("logsd_smoke_disabled", "file",
                 json.dumps({"path": "/tmp/never-written"}),
                 ["audit"]))
            cur.execute("SELECT log_drain_disable('logsd_smoke_disabled', 'test')")

        worker = Worker(self.pool, batch_size=100)
        summary = worker.iterate_once()
        # The disabled drain must not contribute to drains visited.
        # If any other drains exist in the regression DB the count
        # is whatever it is — we just assert this drain wasn't seen
        # by checking no run was recorded for it.
        with _conn() as c, c.cursor() as cur:
            cur.execute("SET search_path TO maludb_core, public")
            cur.execute(
                "SELECT count(*) FROM malu$log_drain_run r "
                "JOIN malu$log_drain d USING (drain_id) "
                "WHERE d.name = 'logsd_smoke_disabled'")
            self.assertEqual(cur.fetchone()[0], 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
