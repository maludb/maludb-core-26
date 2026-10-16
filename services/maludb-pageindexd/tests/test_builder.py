"""V4-PAGEINDEX-02 — builder end-to-end against the live extension.

Four service-level cases per the V4 plan:
  1. End-to-end build: enqueue, drain once, tree lands in 'ready' with
     the expected node count and a structure-pass audit row.
  2. Idempotent retry: re-running the worker against the same queue
     entry is a no-op (no duplicate nodes).
  3. Summarizer failure → tree marked 'failed' (the queue-side DLQ
     transition is V3-QUEUE-01's responsibility; we only assert tree
     status here).
  4. Structure-pass determinism: re-promoting the same source bytes
     under a new tree_id yields an identical
     `deterministic_inputs_hash`.

The tests open their own psycopg connection so they can verify state
between drains.
"""

from __future__ import annotations

import json
import os
import unittest

import psycopg

from maludb_pageindexd.builder import build_tree
from maludb_pageindexd.db import Pool
from maludb_pageindexd.model_gateway import (
    LocalDeterministicSummarizer,
    SummarizationRequest,
    SummarizationResult,
)
from maludb_pageindexd.worker import _drain


MARKDOWN_FIXTURE = b"""\
# Introduction
A short intro section.

## Background
History of the topic.

# Conclusion
The end.
"""


def _dsn() -> str:
    return os.environ.get("MALUDB_PAGEINDEXD_TEST_DSN", "")


def _new_database() -> tuple[psycopg.Connection, str]:
    """Create a throwaway DB with the extension loaded."""
    admin = psycopg.connect(_dsn() or "dbname=postgres", autocommit=True)
    name = "pageindexd_test_" + os.urandom(4).hex()
    with admin.cursor() as cur:
        cur.execute(f'DROP DATABASE IF EXISTS "{name}"')
        cur.execute(f'CREATE DATABASE "{name}"')
    admin.close()
    conn = psycopg.connect(f"dbname={name}", autocommit=False)
    with conn.cursor() as cur:
        cur.execute("CREATE EXTENSION maludb_core CASCADE")
    conn.commit()
    return conn, name


def _drop_database(name: str) -> None:
    admin = psycopg.connect(_dsn() or "dbname=postgres", autocommit=True)
    with admin.cursor() as cur:
        cur.execute(f'DROP DATABASE IF EXISTS "{name}" WITH (FORCE)')
    admin.close()


class FailingSummarizer:
    model_alias = "fail-test"
    prompt_template_version = "fail-1"

    def summarize(self, req: SummarizationRequest) -> SummarizationResult:
        raise RuntimeError("forced summarizer failure")


@unittest.skipUnless(os.environ.get("MALUDB_PAGEINDEXD_TEST_DB", "") == "1",
                     "set MALUDB_PAGEINDEXD_TEST_DB=1 to run live-DB builder tests")
class BuilderEndToEndTests(unittest.TestCase):
    def setUp(self) -> None:
        self.conn, self.db_name = _new_database()
        self.conn.execute("SET search_path TO maludb_core, public")
        self.conn.commit()

    def tearDown(self) -> None:
        try:
            self.conn.close()
        finally:
            _drop_database(self.db_name)

    def _promote_markdown(self) -> tuple[int, int]:
        with self.conn.cursor() as cur:
            cur.execute("""
                SELECT register_source_package(
                    p_source_type  => 'document',
                    p_content_text => %s,
                    p_media_type   => 'text/markdown')""",
                (MARKDOWN_FIXTURE.decode("utf-8"),))
            sp_id = cur.fetchone()[0]
            cur.execute("""
                SELECT source_package_promote_to_page_index(%s, 'markdown')
            """, (sp_id,))
            tree_id = cur.fetchone()[0]
        self.conn.commit()
        return sp_id, tree_id

    def _lease_one(self) -> dict | None:
        with self.conn.cursor() as cur:
            cur.execute("""
                SELECT job_id, payload
                FROM queue_lease('pageindex_build', 'test-worker', 1, NULL)
            """)
            row = cur.fetchone()
        self.conn.commit()
        if row is None:
            return None
        return {"job_id": row[0], "payload": row[1]}

    # --- case 1: end-to-end build -----------------------------------
    def test_end_to_end_build(self) -> None:
        sp_id, tree_id = self._promote_markdown()
        job = self._lease_one()
        self.assertIsNotNone(job)
        result = build_tree(self.conn, job["payload"])
        self.assertEqual(result.outcome, "ok")
        # Two top-level headings + one ## = 3 outline entries.
        self.assertEqual(result.outline_node_count, 3)
        # "Introduction" wraps "Background", "Conclusion" stands alone.
        # Leaves are Background + Conclusion.
        self.assertEqual(result.leaf_count, 2)

        # Tree is 'ready', structure-pass audit row exists, nodes carry
        # mdo_kind='page_index_node'.
        with self.conn.cursor() as cur:
            cur.execute(
                "SELECT build_status FROM malu$page_index_tree WHERE tree_id=%s",
                (tree_id,))
            self.assertEqual(cur.fetchone()[0], "ready")

            cur.execute(
                "SELECT outline_node_count, leaf_count, outcome "
                "FROM malu$structure_pass_audit WHERE tree_id=%s",
                (tree_id,))
            row = cur.fetchone()
            self.assertEqual(row, (3, 2, "ok"))

            cur.execute("""
                SELECT count(*) FROM malu$memory_detail_object
                 WHERE tree_id=%s AND mdo_kind='page_index_node'""",
                (tree_id,))
            self.assertEqual(cur.fetchone()[0], 3)

            # Every node has a ledger entry.
            cur.execute("""
                SELECT count(*) FROM malu$derivation_ledger l
                JOIN malu$memory_detail_object m ON m.mdo_id = l.derived_object_id
                WHERE l.derived_object_type = 'page_index_node'
                  AND m.tree_id = %s""",
                (tree_id,))
            self.assertEqual(cur.fetchone()[0], 3)

    # --- case 2: idempotent retry -----------------------------------
    def test_idempotent_retry(self) -> None:
        sp_id, tree_id = self._promote_markdown()
        job = self._lease_one()
        build_tree(self.conn, job["payload"])

        # Second drain finds nothing in the queue (idempotency via the
        # queue layer — the ack happens during _drain). For this test
        # we ack the job manually because build_tree alone doesn't ack.
        with self.conn.cursor() as cur:
            cur.execute("SELECT queue_ack(%s)", (job["job_id"],))
        self.conn.commit()

        second = self._lease_one()
        self.assertIsNone(second)

        # Node count unchanged.
        with self.conn.cursor() as cur:
            cur.execute(
                "SELECT count(*) FROM malu$memory_detail_object "
                "WHERE tree_id=%s", (tree_id,))
            self.assertEqual(cur.fetchone()[0], 3)

    # --- case 3: summarizer failure → tree 'failed' -----------------
    def test_summarizer_failure_marks_tree_failed(self) -> None:
        sp_id, tree_id = self._promote_markdown()
        job = self._lease_one()
        result = build_tree(self.conn, job["payload"],
                            summarizer=FailingSummarizer())
        self.assertEqual(result.outcome, "failed")
        with self.conn.cursor() as cur:
            cur.execute(
                "SELECT build_status, failure_reason FROM malu$page_index_tree "
                "WHERE tree_id=%s", (tree_id,))
            row = cur.fetchone()
            self.assertEqual(row[0], "failed")
            self.assertIn("summarizer", row[1])

    # --- case 4: structure-pass determinism -------------------------
    def test_structure_pass_is_deterministic(self) -> None:
        sp_id, tree_a = self._promote_markdown()
        job = self._lease_one()
        build_tree(self.conn, job["payload"])

        # Re-promote a second tree over the same source bytes.
        with self.conn.cursor() as cur:
            cur.execute("""
                SELECT source_package_promote_to_page_index(%s, 'markdown')
            """, (sp_id,))
            tree_b = cur.fetchone()[0]
        self.conn.commit()

        job2 = self._lease_one()
        build_tree(self.conn, job2["payload"])

        with self.conn.cursor() as cur:
            cur.execute("""
                SELECT tree_id, deterministic_inputs_hash
                  FROM malu$structure_pass_audit
                 WHERE tree_id IN (%s, %s)
                 ORDER BY tree_id""", (tree_a, tree_b))
            rows = cur.fetchall()
        hashes = {h for _, h in rows}
        self.assertEqual(len(hashes), 1,
            f"deterministic_inputs_hash diverged: {rows}")


if __name__ == "__main__":
    unittest.main()
