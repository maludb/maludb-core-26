"""V3-CLI-01 smoke tests.

Drives `maludb_cli.__main__:main` directly (no subprocess) against
the live `contrib_regression` database. Exercises the high-traffic
subcommand families that have backing SQL:
  * status
  * install doctor
  * auth token create / list / revoke
  * secret set / get-metadata / rotate / revoke
  * metrics scrape (text + JSON)
  * source / queue / cron stubs return EX_SOFTWARE (70)
"""

from __future__ import annotations

import io
import json
import os
import unittest
from contextlib import redirect_stdout, redirect_stderr

import psycopg

from maludb_cli.__main__ import main
from maludb_cli.db import connect


def _conn():
    return psycopg.connect(
        dbname=os.environ.get("MALUDB_DB", "contrib_regression"),
        autocommit=True,
    )


def _run(*argv, env=None) -> tuple[int, str, str]:
    env = env or {}
    env.setdefault("MALUDB_DB", os.environ.get("MALUDB_DB", "contrib_regression"))
    saved = {}
    for k, v in env.items():
        saved[k] = os.environ.get(k)
        os.environ[k] = v
    out, err = io.StringIO(), io.StringIO()
    try:
        with redirect_stdout(out), redirect_stderr(err):
            rc = main(list(argv))
    finally:
        for k, v in saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
    return rc, out.getvalue(), err.getvalue()


class CliSmoke(unittest.TestCase):

    @classmethod
    def setUpClass(cls) -> None:
        with _conn() as c, c.cursor() as cur:
            cur.execute("SET search_path TO maludb_core, public")
            cur.execute("""
                INSERT INTO malu$account(account_name, account_kind, description)
                VALUES ('cli_smoke_user', 'service', 'V3-CLI-01 smoke test')
                ON CONFLICT (account_name) DO UPDATE SET enabled = true
                RETURNING account_id
            """)
            cls.account_id = cur.fetchone()[0]

    @classmethod
    def tearDownClass(cls) -> None:
        with _conn() as c, c.cursor() as cur:
            cur.execute("SET search_path TO maludb_core, public")
            cur.execute("""
                DELETE FROM malu$auth_token_use WHERE token_id IN
                    (SELECT token_id FROM malu$auth_token WHERE account_id = %s)
            """, (cls.account_id,))
            cur.execute("DELETE FROM malu$auth_token WHERE account_id = %s", (cls.account_id,))
            cur.execute("DELETE FROM malu$secret_use WHERE secret_version_id IN (SELECT secret_version_id FROM malu$secret_version WHERE secret_id IN (SELECT secret_id FROM malu$secret WHERE name LIKE 'cli_smoke_%'))")
            cur.execute("DELETE FROM malu$secret_version WHERE secret_id IN (SELECT secret_id FROM malu$secret WHERE name LIKE 'cli_smoke_%')")
            cur.execute("DELETE FROM malu$secret WHERE name LIKE 'cli_smoke_%'")
            cur.execute("DELETE FROM malu$audit_event WHERE event_kind LIKE 'auth_token_%' OR event_kind LIKE 'secret_%'")
            cur.execute("DELETE FROM malu$account WHERE account_id = %s", (cls.account_id,))

    # -- tests -----------------------------------------------------------

    def test_01_status_json(self):
        rc, out, _ = _run("--format", "json", "status")
        self.assertEqual(rc, 0)
        data = json.loads(out)
        self.assertIn("extension_version", data)
        self.assertRegex(data["extension_version"], r"^\d+\.\d+\.\d+$")
        self.assertIn("catalog_tables", data)

    def test_02_status_text(self):
        rc, out, _ = _run("status")
        self.assertEqual(rc, 0)
        self.assertIn("extension_version", out)

    def test_02b_schema_env_prefixes_search_path(self):
        class Args:
            db = os.environ.get("MALUDB_DB", "contrib_regression")
            host = None
            port = None
            user = None
            password = None
            schema = None

        saved = os.environ.get("MALUDB_SCHEMA")
        os.environ["MALUDB_SCHEMA"] = "driver_tenant"
        try:
            with connect(Args()) as conn, conn.cursor() as cur:
                cur.execute("SHOW search_path")
                self.assertTrue(
                    cur.fetchone()[0].startswith("driver_tenant, maludb_core, public")
                )
        finally:
            if saved is None:
                os.environ.pop("MALUDB_SCHEMA", None)
            else:
                os.environ["MALUDB_SCHEMA"] = saved

    def test_03_install_doctor(self):
        rc, out, _ = _run("--format", "json", "install", "doctor")
        # Doctor returns 0 only if every check is 'ok'. The regression
        # cluster has all required extensions and roles, so expect rc=0.
        self.assertEqual(rc, 0, f"doctor stderr: {out}")
        rows = json.loads(out)
        names = {r["check"] for r in rows}
        self.assertIn("extension:pgcrypto", names)
        self.assertIn("role:maludb_rest_dispatcher", names)
        for r in rows:
            self.assertEqual(r["status"], "ok", f"failing check: {r}")

    def test_04_auth_token_lifecycle(self):
        rc, out, _ = _run(
            "--format", "json", "auth", "token", "create",
            "--account-id", str(self.account_id),
            "--kind", "service",
            "--label", "cli-smoke",
            "--scope", "retrieve",
        )
        self.assertEqual(rc, 0)
        created = json.loads(out)
        self.assertIn("plaintext_token", created)
        self.assertTrue(created["plaintext_token"].startswith("mldbat_"))
        token_id = created["token_id"]

        rc, out, _ = _run("--format", "json", "auth", "token", "list",
                          "--account-id", str(self.account_id))
        self.assertEqual(rc, 0)
        listed = json.loads(out)
        self.assertTrue(any(r["token_id"] == token_id for r in listed))

        rc, out, _ = _run("--format", "json", "auth", "token", "revoke",
                          "--token-id", str(token_id),
                          "--reason", "smoke complete")
        self.assertEqual(rc, 0)
        revoked = json.loads(out)
        self.assertTrue(revoked["was_active"])

    def test_05_secret_lifecycle(self):
        # set
        rc, out, _ = _run(
            "--format", "json", "secret", "set",
            "--name", "cli_smoke_provider",
            "--kind", "provider",
            "--value", "sk-cli-test-1111",
            "--description", "cli smoke",
        )
        self.assertEqual(rc, 0)
        sset = json.loads(out)
        self.assertEqual(sset["version"], 1)
        self.assertEqual(sset["mode"], "inline")

        # get-metadata
        rc, out, _ = _run("--format", "json", "secret", "get-metadata",
                          "--name", "cli_smoke_provider")
        self.assertEqual(rc, 0)
        meta = json.loads(out)
        self.assertEqual(meta["current_version"], 1)
        self.assertEqual(meta["mode"], "inline")

        # rotate (no --value → reads stdin; pass via --value path here)
        rc, out, _ = _run(
            "--format", "json", "secret", "rotate",
            "--name", "cli_smoke_provider",
            "--value", "sk-cli-test-2222",
        )
        self.assertEqual(rc, 0)
        rot = json.loads(out)
        self.assertEqual(rot["rotated_to"], 2)

        # revoke
        rc, out, _ = _run("--format", "json", "secret", "revoke",
                          "--name", "cli_smoke_provider",
                          "--reason", "smoke complete")
        self.assertEqual(rc, 0)

    def test_06_metrics_text(self):
        rc, out, _ = _run("metrics", "scrape")
        self.assertEqual(rc, 0)
        self.assertIn("maludb_extension_version", out)
        self.assertIn("maludb_catalog_tables", out)

    def test_07_metrics_json(self):
        rc, out, _ = _run("--format", "json", "metrics", "scrape")
        self.assertEqual(rc, 0)
        data = json.loads(out)
        self.assertIn("extension_version", data)
        self.assertIn("audit_per_kind", data)

    def test_08_source_lifecycle(self):
        import tempfile
        with tempfile.TemporaryDirectory() as base:
            # Register a local_fs adapter pointing at the temp dir.
            rc, out, _ = _run(
                "--format", "json", "source", "adapter-register",
                "--name", "cli_smoke_adapter",
                "--kind", "local_fs",
                "--config", json.dumps({"base_path": base}),
            )
            self.assertEqual(rc, 0)

            payload = base + "/payload.txt"
            with open(payload, "w") as f:
                f.write("cli-smoke source bytes")

            # Put the file → registers an object.
            rc, out, _ = _run(
                "--format", "json", "source", "put",
                "--file", payload,
                "--adapter", "cli_smoke_adapter",
                "--media-type", "text/plain",
            )
            self.assertEqual(rc, 0)
            obj = json.loads(out)
            self.assertGreater(obj["object_id"], 0)

            # Verify.
            rc, out, _ = _run("--format", "json", "source", "verify",
                              "--object-id", str(obj["object_id"]))
            self.assertEqual(rc, 0)
            self.assertTrue(json.loads(out)["match"])

            # Get → roundtrip.
            out_path = base + "/roundtrip.txt"
            rc, _, _ = _run("--format", "json", "source", "get",
                            "--object-id", str(obj["object_id"]),
                            "--out", out_path)
            self.assertEqual(rc, 0)
            with open(out_path) as f:
                self.assertEqual(f.read(), "cli-smoke source bytes")

            # Promote → source_package.
            with _conn() as c, c.cursor() as cur:
                cur.execute("SET search_path TO maludb_core, public")
                cur.execute(
                    """
                    INSERT INTO malu$source_type(source_type, stage, description)
                    VALUES ('cli_smoke_source', 2, 'CLI smoke')
                    ON CONFLICT DO NOTHING
                    """
                )
            try:
                rc, out, _ = _run(
                    "--format", "json", "source", "promote",
                    "--object-id", str(obj["object_id"]),
                    "--source-type", "cli_smoke_source",
                )
                self.assertEqual(rc, 0)
                pid = json.loads(out)["source_package_id"]
                self.assertGreater(pid, 0)
            finally:
                with _conn() as c, c.cursor() as cur:
                    cur.execute("SET search_path TO maludb_core, public")
                    cur.execute("DELETE FROM malu$derivation_ledger WHERE derived_object_id = %s AND derived_object_type='source_package'", (pid,))
                    cur.execute("DELETE FROM malu$source_package WHERE source_package_id = %s", (pid,))
                    cur.execute("DELETE FROM malu$source_type WHERE source_type='cli_smoke_source'")
                    cur.execute("DELETE FROM malu$source_object_reference WHERE object_id = %s", (obj["object_id"],))
                    cur.execute("DELETE FROM malu$source_object WHERE object_id = %s", (obj["object_id"],))
                    cur.execute("DELETE FROM malu$storage_adapter WHERE name='cli_smoke_adapter'")
                    cur.execute("DELETE FROM malu$audit_event WHERE event_kind LIKE 'storage_%' OR event_kind LIKE 'source_object_%'")

    def test_09_queue_lifecycle(self):
        # Register a smoke queue via SQL (the CLI doesn't expose
        # queue_register; that's an operator/migration concern).
        with _conn() as c, c.cursor() as cur:
            cur.execute("SET search_path TO maludb_core, public")
            cur.execute("SELECT queue_register('cli_smoke_queue', 5000, 1)")
            qid = cur.fetchone()[0]

        try:
            rc, out, _ = _run(
                "--format", "json", "queue", "enqueue",
                "--queue", "cli_smoke_queue",
                "--payload", '{"task":"cli-smoke"}',
            )
            self.assertEqual(rc, 0)
            self.assertGreater(json.loads(out)["job_id"], 0)

            rc, out, _ = _run("--format", "json", "queue", "list")
            self.assertEqual(rc, 0)
            rows = json.loads(out)
            row = next((r for r in rows if r["queue"] == "cli_smoke_queue"), None)
            self.assertIsNotNone(row, "cli_smoke_queue not in queue list")
            self.assertGreaterEqual(row["pending"], 1)

            rc, out, _ = _run("--format", "json", "queue", "drain")
            self.assertEqual(rc, 0)
            self.assertIn("reclaimed", json.loads(out))
        finally:
            with _conn() as c, c.cursor() as cur:
                cur.execute("SET search_path TO maludb_core, public")
                cur.execute("DELETE FROM malu$queue_job WHERE queue_id = %s", (qid,))
                cur.execute("DELETE FROM malu$queue     WHERE queue_id = %s", (qid,))
                cur.execute("DELETE FROM malu$audit_event WHERE event_kind LIKE 'queue_%'")

    def test_11_realtime_lifecycle(self):
        # Subscribe → emit → fetch → ack via the CLI.
        with _conn() as c, c.cursor() as cur:
            cur.execute("SET search_path TO maludb_core, public")
            cur.execute("SELECT MAX(event_id) FROM malu$event")
            start = cur.fetchone()[0] or 0

        rc, out, _ = _run(
            "--format", "json", "realtime", "subscribe",
            "--name", "cli_realtime_smoke",
            "--start-cursor", str(start),
        )
        self.assertEqual(rc, 0)
        sid = json.loads(out)["subscription_id"]

        try:
            # Emit two events via SQL.
            with _conn() as c, c.cursor() as cur:
                cur.execute("SET search_path TO maludb_core, public")
                cur.execute("SELECT emit_event('cli_rt_a', '{\"i\":1}'::jsonb)")
                e1 = cur.fetchone()[0]
                cur.execute("SELECT emit_event('cli_rt_b', '{\"i\":2}'::jsonb)")
                e2 = cur.fetchone()[0]

            rc, out, _ = _run("--format", "json", "realtime", "fetch",
                              "--subscription-id", str(sid))
            self.assertEqual(rc, 0)
            fetched = json.loads(out)
            ids = {r["event_id"] for r in fetched}
            self.assertIn(e1, ids)
            self.assertIn(e2, ids)

            rc, out, _ = _run("--format", "json", "realtime", "ack",
                              "--subscription-id", str(sid),
                              "--through-event-id", str(e2))
            self.assertEqual(rc, 0)
            self.assertEqual(json.loads(out)["through_event_id"], e2)

            # After ack the cursor is at e2; fetch returns nothing new.
            rc, out, _ = _run("--format", "json", "realtime", "fetch",
                              "--subscription-id", str(sid))
            self.assertEqual(rc, 0)
            self.assertEqual(json.loads(out), [])
        finally:
            with _conn() as c, c.cursor() as cur:
                cur.execute("SET search_path TO maludb_core, public")
                cur.execute("DELETE FROM malu$event_delivery WHERE subscription_id = %s", (sid,))
                cur.execute("DELETE FROM malu$event_subscription WHERE subscription_id = %s", (sid,))
                cur.execute("DELETE FROM malu$event WHERE event_kind LIKE 'cli_rt_%'")

    def test_10_cron_lifecycle(self):
        with _conn() as c, c.cursor() as cur:
            cur.execute("SET search_path TO maludb_core, public")
            cur.execute("SELECT queue_register('cli_cron_queue', 5000, 1)")
            qid = cur.fetchone()[0]

        try:
            rc, out, _ = _run(
                "--format", "json", "cron", "create",
                "--name", "cli_cron_smoke",
                "--cron-expr", "*/5 * * * *",
                "--action-kind", "enqueue",
                "--payload", '{"queue":"cli_cron_queue","payload":{"task":"cli-cron"}}',
            )
            self.assertEqual(rc, 0)
            sid = json.loads(out)["schedule_id"]

            rc, out, _ = _run("--format", "json", "cron", "list")
            self.assertEqual(rc, 0)
            rows = json.loads(out)
            self.assertTrue(any(r["name"] == "cli_cron_smoke" for r in rows))

            rc, out, _ = _run("--format", "json", "cron", "run-now",
                              "--name", "cli_cron_smoke")
            self.assertEqual(rc, 0)
            self.assertGreater(json.loads(out)["run_id"], 0)

            rc, out, _ = _run("--format", "json", "cron", "disable",
                              "--name", "cli_cron_smoke", "--reason", "smoke complete")
            self.assertEqual(rc, 0)
            self.assertTrue(json.loads(out)["was_enabled"])
        finally:
            with _conn() as c, c.cursor() as cur:
                cur.execute("SET search_path TO maludb_core, public")
                cur.execute("DELETE FROM malu$schedule_run WHERE schedule_id = %s", (sid,))
                cur.execute("DELETE FROM malu$schedule     WHERE schedule_id = %s", (sid,))
                cur.execute("DELETE FROM malu$queue_job WHERE queue_id = %s", (qid,))
                cur.execute("DELETE FROM malu$queue     WHERE queue_id = %s", (qid,))
                cur.execute("DELETE FROM malu$audit_event WHERE event_kind LIKE 'queue_%' OR event_kind LIKE 'schedule_%'")

    def test_12_env_lifecycle(self):
        # Read default_version to use as base_migration so the
        # migration_current gate is t.
        with _conn() as c, c.cursor() as cur:
            cur.execute("SELECT maludb_core.maludb_core_version()")
            cur_ver = cur.fetchone()[0]

        rc, out, _ = _run(
            "--format", "json", "env", "create",
            "--name", "cli_env_smoke",
            "--base-migration", cur_ver,
            "--description", "V3-CLI-02 smoke",
        )
        self.assertEqual(rc, 0)
        env_id = json.loads(out)["env_id"]
        self.assertGreater(env_id, 0)

        try:
            rc, out, _ = _run(
                "--format", "json", "env", "record-seed",
                "--env-id", str(env_id),
                "--seed-kind", "sql_file",
                "--source-uri", "file:///tmp/cli_env_smoke.sql",
                "--redaction-rules", '[{"path":"$.email","replace":"x@x"}]',
            )
            self.assertEqual(rc, 0)
            self.assertGreater(json.loads(out)["seed_id"], 0)

            rc, out, _ = _run("--format", "json", "env", "promote-check",
                              "--env-id", str(env_id))
            self.assertEqual(rc, 0)
            rows = json.loads(out)
            self.assertTrue(all(r["ok"] for r in rows))

            rc, out, _ = _run("--format", "json", "env", "list")
            self.assertEqual(rc, 0)
            self.assertTrue(any(r["name"] == "cli_env_smoke" for r in json.loads(out)))
        finally:
            with _conn() as c, c.cursor() as cur:
                cur.execute("SET search_path TO maludb_core, public")
                cur.execute("DELETE FROM malu$preview_env_seed WHERE env_id = %s", (env_id,))
                cur.execute("DELETE FROM malu$preview_env      WHERE env_id = %s", (env_id,))
                cur.execute("DELETE FROM malu$audit_event WHERE event_kind LIKE 'preview_env_%'")

    def test_13_log_drain_lifecycle(self):
        rc, out, _ = _run(
            "--format", "json", "log-drain", "set",
            "--name", "cli_log_drain_smoke",
            "--kind", "file",
            "--destination", '{"path":"/tmp/cli_log_drain_smoke.log"}',
            "--source-streams", "audit", "queue",
        )
        self.assertEqual(rc, 0)
        drain_id = json.loads(out)["drain_id"]
        self.assertGreater(drain_id, 0)

        try:
            rc, out, _ = _run("--format", "json", "log-drain", "list")
            self.assertEqual(rc, 0)
            self.assertTrue(any(r["name"] == "cli_log_drain_smoke" for r in json.loads(out)))

            rc, out, _ = _run(
                "--format", "json", "log-drain", "record-run",
                "--drain-id", str(drain_id),
                "--batches", "1",
                "--bytes", "4096",
                "--records", "42",
                "--errors", "0",
            )
            self.assertEqual(rc, 0)
            self.assertGreater(json.loads(out)["run_id"], 0)

            rc, out, _ = _run("--format", "json", "log-drain", "disable",
                              "--name", "cli_log_drain_smoke",
                              "--reason", "smoke complete")
            self.assertEqual(rc, 0)
            self.assertTrue(json.loads(out)["disabled"])

            rc, out, _ = _run("--format", "json", "log-drain", "enable",
                              "--name", "cli_log_drain_smoke")
            self.assertEqual(rc, 0)
            self.assertTrue(json.loads(out)["enabled"])
        finally:
            with _conn() as c, c.cursor() as cur:
                cur.execute("SET search_path TO maludb_core, public")
                cur.execute("DELETE FROM malu$log_drain_run WHERE drain_id = %s", (drain_id,))
                cur.execute("DELETE FROM malu$log_drain     WHERE drain_id = %s", (drain_id,))
                cur.execute("DELETE FROM malu$audit_event WHERE event_kind LIKE 'log_drain_%'")

    def test_14_backup_lifecycle(self):
        rc, out, _ = _run(
            "--format", "json", "backup", "manifest",
            "--label", "cli_backup_smoke",
            "--postgres-state-kind", "dump",
            "--postgres-state-uri", "file:///tmp/cli_backup_smoke.dump",
            "--hash-summary", '{"postgres_state":"deadbeef","wal":"cafef00d"}',
            "--wal-archive-uri", "file:///var/lib/maludb/wal-archive/",
        )
        self.assertEqual(rc, 0)
        manifest_id = json.loads(out)["manifest_id"]
        self.assertGreater(manifest_id, 0)

        try:
            rc, out, _ = _run(
                "--format", "json", "backup", "verify",
                "--manifest-id", str(manifest_id),
                "--status", "passed",
            )
            self.assertEqual(rc, 0)
            self.assertGreater(json.loads(out)["verification_id"], 0)

            rc, out, _ = _run("--format", "json", "backup", "latest")
            self.assertEqual(rc, 0)
            latest = json.loads(out)
            self.assertEqual(latest["label"], "cli_backup_smoke")
        finally:
            with _conn() as c, c.cursor() as cur:
                cur.execute("SET search_path TO maludb_core, public")
                cur.execute("DELETE FROM malu$backup_verification WHERE manifest_id = %s", (manifest_id,))
                cur.execute("DELETE FROM malu$backup_manifest     WHERE manifest_id = %s", (manifest_id,))
                cur.execute("DELETE FROM malu$audit_event WHERE event_kind LIKE 'backup_%'")


    def test_15_s3_signed_url_round_trip(self):
        """Full S3 round-trip against a stdlib mock S3 (path-style HTTP).

        The mock stores object bytes in a dict keyed by request path, so
        we exercise the CLI's source put -> get -> signed-url path
        without depending on real AWS. SigV4 signature math is verified
        by the mock checking that the Authorization header begins with
        AWS4-HMAC-SHA256.
        """
        import threading
        import socket as _sock
        from http.server import BaseHTTPRequestHandler, HTTPServer

        store: dict[str, bytes] = {}
        seen_auth: list[str] = []

        class _MockS3(BaseHTTPRequestHandler):
            def log_message(self, *a, **kw):       # noqa: ARG002
                pass
            def _auth(self):
                seen_auth.append(self.headers.get("Authorization", ""))
            def do_PUT(self):                       # noqa: N802
                self._auth()
                length = int(self.headers.get("Content-Length", "0"))
                store[self.path] = self.rfile.read(length)
                self.send_response(200); self.send_header("Content-Length", "0"); self.end_headers()
            def do_GET(self):                       # noqa: N802
                # Strip query string for storage lookup so pre-signed URLs work.
                path_only = self.path.split("?", 1)[0]
                if path_only not in store:
                    self.send_response(404); self.send_header("Content-Length", "0"); self.end_headers()
                    return
                self._auth() if "?" not in self.path else None
                data = store[path_only]
                self.send_response(200)
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)
            def do_HEAD(self):                      # noqa: N802
                if self.path in store:
                    self.send_response(200)
                else:
                    self.send_response(404)
                self.send_header("Content-Length", "0"); self.end_headers()

        sock = _sock.socket(); sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]; sock.close()
        srv = HTTPServer(("127.0.0.1", port), _MockS3)
        t = threading.Thread(target=srv.serve_forever, kwargs={"poll_interval": 0.05}, daemon=True)
        t.start()
        try:
            # Register an S3 adapter pointing at the mock, and a secret
            # holding fake credentials so _s3_credentials() resolves.
            sec_name     = "cli_smoke_s3_creds"
            adapter_name = "cli_smoke_s3_adapter"
            try:
                rc, out, _ = _run(
                    "--format", "json", "secret", "set",
                    "--name", sec_name, "--kind", "storage",
                    "--value", json.dumps({"access_key": "AKIATEST",
                                           "secret_key": "supersecret"}),
                )
                self.assertEqual(rc, 0)

                rc, out, _ = _run(
                    "--format", "json", "source", "adapter-register",
                    "--name", adapter_name, "--kind", "s3",
                    "--config", json.dumps({
                        "bucket": "smoke-bucket",
                        "region": "us-east-1",
                        "key_prefix": "tests",
                        "endpoint_url": f"http://127.0.0.1:{port}",
                        "addressing_style": "path",
                    }),
                    "--secret-ref", sec_name,
                )
                self.assertEqual(rc, 0)
                aid = json.loads(out)["adapter_id"]

                # Put -> registers a source_object via the catalog.
                import tempfile
                with tempfile.NamedTemporaryFile("w", delete=False, suffix=".txt") as f:
                    f.write("hello-s3-smoke")
                    payload = f.name
                rc, out, _ = _run(
                    "--format", "json", "source", "put",
                    "--file", payload, "--adapter", adapter_name,
                    "--media-type", "text/plain",
                )
                self.assertEqual(rc, 0)
                pu = json.loads(out)
                self.assertGreater(pu["object_id"], 0)
                self.assertEqual(pu["byte_length"], len("hello-s3-smoke"))

                # Mock saw a SigV4 PUT.
                self.assertTrue(any(a.startswith("AWS4-HMAC-SHA256 ")
                                    for a in seen_auth),
                                "no SigV4 Authorization header observed")

                # Get -> roundtrip the bytes through the mock.
                out_path = payload + ".roundtrip"
                rc, _, _ = _run(
                    "--format", "json", "source", "get",
                    "--object-id", str(pu["object_id"]),
                    "--out", out_path,
                )
                self.assertEqual(rc, 0)
                with open(out_path) as f:
                    self.assertEqual(f.read(), "hello-s3-smoke")

                # Signed-URL -> URL parses with the right query keys.
                rc, out, _ = _run(
                    "--format", "json", "source", "signed-url",
                    "--object-id", str(pu["object_id"]),
                    "--expires-in", "120",
                )
                self.assertEqual(rc, 0)
                signed = json.loads(out)
                self.assertIn("X-Amz-Signature=", signed["signed_url"])
                self.assertIn("X-Amz-Algorithm=AWS4-HMAC-SHA256",
                              signed["signed_url"])
                self.assertIn("X-Amz-Expires=120", signed["signed_url"])
            finally:
                with _conn() as c, c.cursor() as cur:
                    cur.execute("SET search_path TO maludb_core, public")
                    cur.execute(
                        "DELETE FROM malu$source_object WHERE adapter_id = "
                        "(SELECT adapter_id FROM malu$storage_adapter WHERE name=%s)",
                        (adapter_name,))
                    cur.execute("DELETE FROM malu$storage_adapter WHERE name=%s",
                                (adapter_name,))
                    cur.execute(
                        "DELETE FROM malu$secret_use WHERE secret_version_id IN "
                        "(SELECT sv.secret_version_id FROM malu$secret_version sv "
                        "JOIN malu$secret s USING (secret_id) WHERE s.name=%s)",
                        (sec_name,))
                    cur.execute(
                        "DELETE FROM malu$secret_version WHERE secret_id IN "
                        "(SELECT secret_id FROM malu$secret WHERE name=%s)",
                        (sec_name,))
                    cur.execute("DELETE FROM malu$secret WHERE name=%s",
                                (sec_name,))
                    cur.execute(
                        "DELETE FROM malu$audit_event "
                        "WHERE event_kind LIKE 'storage_%' "
                        "   OR event_kind LIKE 'source_object_%' "
                        "   OR event_kind LIKE 'secret_%'")
        finally:
            srv.shutdown()
            t.join(timeout=2)


if __name__ == "__main__":
    unittest.main(verbosity=2)
