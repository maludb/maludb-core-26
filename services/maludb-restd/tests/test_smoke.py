"""V3-API-01b — smoke test for maludb-restd.

Drives the daemon end-to-end against the live `contrib_regression` DB
(populated by `make installcheck`). Exercises:
  * GET /healthz   — built-in, no auth.
  * GET /version   — calls maludb_core_version().
  * GET /openapi.json — calls rest_openapi_spec().
  * GET /test/version — catalog-registered endpoint (created by this
    test), no auth required; audited via malu$rest_invocation.
  * GET /test/auth   — catalog-registered with auth_required=true;
    missing token returns 401 and a malu$rest_invocation reject row.
  * GET /test/auth with valid token — 200 + accept audit row.
  * /v3/note, /v3/document, and /v3/chat/* — release catalog entries
    expose typed dispatch arguments and scopes.
"""

from __future__ import annotations

import json
import os
import socket
import threading
import time
import unittest
import urllib.error
import urllib.request

import psycopg

from maludb_restd.db import Pool
from maludb_restd.server import RestServer


def _free_port() -> int:
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


def _conn() -> psycopg.Connection:
    return psycopg.connect(
        dbname=os.environ.get("MALUDB_RESTD_DB", "contrib_regression"),
        host=os.environ.get("MALUDB_RESTD_HOST"),
        port=os.environ.get("MALUDB_RESTD_PORT"),
        user=os.environ.get("MALUDB_RESTD_USER"),
        password=os.environ.get("MALUDB_RESTD_PASSWORD"),
        autocommit=True,
    )


class RestdSmoke(unittest.TestCase):

    @classmethod
    def setUpClass(cls) -> None:
        os.environ.setdefault("MALUDB_RESTD_DB", "contrib_regression")
        cls.pool = Pool()
        cls.port = _free_port()
        cls.server = RestServer("127.0.0.1", cls.port, cls.pool)
        cls.thread = threading.Thread(target=cls.server.serve_forever,
                                      kwargs={"poll_interval": 0.05},
                                      daemon=True)
        cls.thread.start()
        # Wait for socket readiness.
        for _ in range(40):
            try:
                with socket.create_connection(("127.0.0.1", cls.port), timeout=0.5):
                    break
            except OSError:
                time.sleep(0.05)
        # Seed two test endpoints in the catalog.
        with _conn() as c, c.cursor() as cur:
            cur.execute("SET search_path TO maludb_core, public")
            # Clear leftovers from a previous run.
            cur.execute("DELETE FROM malu$rest_endpoint WHERE path LIKE '/test/%'")
            cur.execute("DELETE FROM malu$rest_invocation WHERE path LIKE '/test/%'")
            cur.execute(
                """
                SELECT rest_register_endpoint(
                    'GET', '/test/version',
                    'maludb_core.maludb_core_version()'::regprocedure,
                    'restd smoke: version (no auth)', ARRAY[]::text[],
                    'read_only', '{}'::jsonb, false)
                """
            )
            cur.execute(
                """
                SELECT rest_register_endpoint(
                    'GET', '/test/auth',
                    'maludb_core.maludb_core_version()'::regprocedure,
                    'restd smoke: version (auth required)', ARRAY[]::text[],
                    'read_only', '{}'::jsonb, true)
                """
            )
            # Make an account and a token.
            cur.execute("""
                INSERT INTO malu$account(account_name, account_kind, description)
                VALUES ('restd_smoke_user', 'service', 'restd smoke test')
                ON CONFLICT (account_name) DO UPDATE SET enabled = true
                RETURNING account_id
            """)
            cls.account_id = cur.fetchone()[0]
            cur.execute(
                "SELECT plaintext_token FROM auth_token_create(%s, 'service', 'restd-smoke')",
                (cls.account_id,),
            )
            cls.token = cur.fetchone()[0]
        # Grant the restd-running role permission to insert audit rows.
        # In production, operators bind the daemon's login role to
        # maludb_rest_dispatcher; for this in-process smoke test we run
        # as the regression superuser, which already bypasses everything.

    @classmethod
    def tearDownClass(cls) -> None:
        cls.server.shutdown()
        cls.thread.join(timeout=2)
        cls.pool.close()
        # Cleanup.
        with _conn() as c, c.cursor() as cur:
            cur.execute("SET search_path TO maludb_core, public")
            cur.execute("DELETE FROM malu$rest_invocation WHERE path LIKE '/test/%'")
            cur.execute("DELETE FROM malu$rest_endpoint   WHERE path LIKE '/test/%'")
            cur.execute("DELETE FROM malu$auth_token_use WHERE token_id IN (SELECT token_id FROM malu$auth_token WHERE account_id = %s)", (cls.account_id,))
            cur.execute("DELETE FROM malu$auth_token      WHERE account_id = %s", (cls.account_id,))
            cur.execute("DELETE FROM malu$audit_event     WHERE event_kind LIKE 'auth_token_%' OR event_kind LIKE 'rest_endpoint_%'")
            cur.execute("DELETE FROM malu$account         WHERE account_id = %s", (cls.account_id,))

    # -- helpers ---------------------------------------------------------

    def _get(self, path, headers=None):
        req = urllib.request.Request(f"http://127.0.0.1:{self.port}{path}", headers=headers or {})
        try:
            with urllib.request.urlopen(req, timeout=5) as resp:
                return resp.status, json.loads(resp.read().decode("utf-8"))
        except urllib.error.HTTPError as e:
            return e.code, json.loads(e.read().decode("utf-8"))

    def _post(self, path, payload, headers=None):
        hdr = dict(headers or {})
        hdr.setdefault("Content-Type", "application/json")
        req = urllib.request.Request(
            f"http://127.0.0.1:{self.port}{path}",
            data=json.dumps(payload).encode("utf-8"),
            method="POST",
            headers=hdr,
        )
        try:
            with urllib.request.urlopen(req, timeout=5) as resp:
                return resp.status, json.loads(resp.read().decode("utf-8"))
        except urllib.error.HTTPError as e:
            return e.code, json.loads(e.read().decode("utf-8"))

    def _invocation_count(self, path):
        with _conn() as c, c.cursor() as cur:
            cur.execute(
                "SELECT count(*) FROM maludb_core.malu$rest_invocation WHERE path = %s",
                (path,),
            )
            return cur.fetchone()[0]

    # -- tests -----------------------------------------------------------

    def test_01_healthz(self):
        code, body = self._get("/healthz")
        self.assertEqual(code, 200)
        self.assertEqual(body["status"], "ok")

    def test_02_version(self):
        code, body = self._get("/version")
        self.assertEqual(code, 200)
        self.assertIn("version", body)
        self.assertRegex(body["version"], r"^\d+\.\d+\.\d+$")

    def test_03_openapi(self):
        code, body = self._get("/openapi.json")
        self.assertEqual(code, 200)
        self.assertEqual(body["openapi"], "3.1.0")
        self.assertEqual(body["info"]["title"], "MaluDB REST API")
        self.assertIn("paths", body)

    def test_04_catalog_unauth(self):
        before = self._invocation_count("/test/version")
        code, body = self._get("/test/version")
        self.assertEqual(code, 200)
        self.assertRegex(body, r"^\d+\.\d+\.\d+$")
        after = self._invocation_count("/test/version")
        self.assertEqual(after - before, 1, "audit row missing for /test/version")

    def test_05_catalog_auth_missing_token(self):
        before = self._invocation_count("/test/auth")
        code, body = self._get("/test/auth")
        self.assertEqual(code, 401)
        self.assertEqual(body["error"], "missing_token")
        after = self._invocation_count("/test/auth")
        self.assertEqual(after - before, 1, "audit row missing for unauthenticated /test/auth")

    def test_06_catalog_auth_valid_token(self):
        before = self._invocation_count("/test/auth")
        code, body = self._get(
            "/test/auth",
            headers={"Authorization": f"Bearer {self.token}"},
        )
        self.assertEqual(code, 200)
        self.assertRegex(body, r"^\d+\.\d+\.\d+$")
        after = self._invocation_count("/test/auth")
        self.assertEqual(after - before, 1)

    def test_07_unknown_path(self):
        code, body = self._get("/no/such/endpoint")
        self.assertEqual(code, 404)
        self.assertEqual(body["error"], "endpoint_not_found")

    def test_08_typed_arg_dispatch_post_memory(self):
        # Use the curated POST /v3/memory endpoint seeded by V3-API-02.
        # We deliberately call it WITHOUT a token; the seeded endpoint
        # requires auth, so this should land 401, exercising the
        # typed-arg lookup path before the auth check.
        code, body = self._post(
            "/v3/memory",
            {"memory_kind": "note", "title": "restd typed-arg smoke"},
        )
        # auth_required=true on /v3/memory -> 401
        self.assertEqual(code, 401)

        # With the smoke token (which doesn't carry memory.write scope)
        # we should get 403 scope_missing — also exercises the typed
        # binding before SQL dispatch.
        code, body = self._post(
            "/v3/memory",
            {"memory_kind": "note", "title": "restd typed-arg smoke"},
            headers={"Authorization": f"Bearer {self.token}"},
        )
        self.assertEqual(code, 403)
        self.assertEqual(body["error"], "scope_missing")
        self.assertIn("memory.write", body["required_scopes"])

    def test_09_note_document_chat_catalog_entries(self):
        with _conn() as c, c.cursor() as cur:
            cur.execute(
                """
                SELECT method, path, required_scopes, arg_schema
                  FROM maludb_core.malu$rest_endpoint
                 WHERE (method, path) IN (
                    ('POST', '/v3/note'),
                    ('GET', '/v3/document'),
                    ('POST', '/v3/chat/session'),
                    ('POST', '/v3/chat/message'),
                    ('POST', '/v3/chat/finalize'),
                    ('GET', '/v3/chat/session'),
                    ('GET', '/v3/chat/messages'))
                 ORDER BY method, path
                """
            )
            rows = cur.fetchall()

        self.assertEqual(len(rows), 7)
        by_endpoint = {(row[0], row[1]): row for row in rows}
        self.assertEqual(by_endpoint[("POST", "/v3/note")][2], ["document.write"])
        self.assertEqual(by_endpoint[("GET", "/v3/document")][2], ["document.read"])
        self.assertEqual(by_endpoint[("GET", "/v3/chat/session")][2], ["chat.read"])
        self.assertEqual(by_endpoint[("GET", "/v3/chat/messages")][2], ["chat.read"])
        self.assertEqual(by_endpoint[("POST", "/v3/chat/message")][2], ["chat.write"])

        note_args = {arg["name"]: arg for arg in by_endpoint[("POST", "/v3/note")][3]}
        self.assertEqual(note_args["p_title"]["type"], "text")
        self.assertTrue(note_args["p_title"]["required"])
        self.assertEqual(note_args["p_projects"]["type"], "text[]")
        self.assertFalse(note_args["p_projects"]["required"])
        self.assertEqual(note_args["p_svpor_frames"]["type"], "jsonb")

        document_args = {arg["name"]: arg for arg in by_endpoint[("GET", "/v3/document")][3]}
        self.assertEqual(document_args["p_document_id"]["type"], "bigint")
        self.assertEqual(document_args["p_document_id"]["in"], "query")

        chat_start_args = {arg["name"]: arg for arg in by_endpoint[("POST", "/v3/chat/session")][3]}
        self.assertEqual(chat_start_args["p_title"]["type"], "text")
        self.assertEqual(chat_start_args["p_projects"]["type"], "text[]")
        self.assertEqual(chat_start_args["p_svpor_frames"]["type"], "jsonb")

        chat_message_args = {arg["name"]: arg for arg in by_endpoint[("POST", "/v3/chat/message")][3]}
        self.assertEqual(chat_message_args["p_chat_session_id"]["type"], "bigint")
        self.assertTrue(chat_message_args["p_chat_session_id"]["required"])
        self.assertEqual(chat_message_args["p_content_jsonb"]["type"], "jsonb")

        chat_read_args = {arg["name"]: arg for arg in by_endpoint[("GET", "/v3/chat/messages")][3]}
        self.assertEqual(chat_read_args["p_chat_session_id"]["in"], "query")

    def test_10_typed_arg_missing_required(self):
        # Bypass auth via the open /v3/metrics endpoint pattern? No —
        # /v3/metrics is GET with auth=true too. Instead seed a small
        # open endpoint with arg_schema for this test.
        with _conn() as c, c.cursor() as cur:
            cur.execute("SET search_path TO maludb_core, public")
            cur.execute(
                """
                SELECT rest_register_endpoint(
                    'POST', '/test/typed-echo',
                    'maludb_core.maludb_core_version()'::regprocedure,
                    'restd typed-arg smoke: requires a body field',
                    ARRAY[]::text[], 'read_only', '{}'::jsonb, false,
                    30000, 1048576, 65536,
                    jsonb_build_array(
                        jsonb_build_object('name','p_required_field','type','text','in','body','required',true)))
                """
            )

        # Missing required arg -> SQL handler call raises ValueError
        # in the dispatcher, which surfaces as HTTP 500 with error_code
        # set. Without typed arg support, this used to silently succeed.
        code, body = self._post("/test/typed-echo", {})
        self.assertEqual(code, 500)
        self.assertIn("required", body.get("detail", "") or body.get("error", ""))


if __name__ == "__main__":
    unittest.main(verbosity=2)
