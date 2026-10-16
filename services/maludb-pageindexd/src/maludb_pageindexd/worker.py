"""Long-running worker loop.

Polls the V3-QUEUE-01 `pageindex_build` queue. Each leased job runs
through `build_tree`; on success `queue_ack`, on failure `queue_nack`
with the error text. Visibility timeout defaults to the queue's
registered value (120s from V4-PAGEINDEX-02).
"""

from __future__ import annotations

import json
import logging
import socket
import threading
import time

from .builder import build_tree
from .db import Pool

log = logging.getLogger("maludb_pageindexd.worker")


def run_forever(pool: Pool,
                poll_interval_s: float,
                batch_size: int,
                stop: threading.Event) -> None:
    worker_id = f"maludb-pageindexd@{socket.gethostname()}:{int(time.time())}"
    log.info("starting worker_id=%s poll=%ss batch=%s",
             worker_id, poll_interval_s, batch_size)
    while not stop.is_set():
        try:
            n = _drain(pool, worker_id, batch_size)
        except Exception:
            log.exception("worker drain failed; sleeping before retry")
            n = 0
        if n == 0:
            stop.wait(poll_interval_s)
    log.info("worker stopping")


def _drain(pool: Pool, worker_id: str, batch_size: int) -> int:
    conn = pool.connect()
    leased: list[tuple[int, dict]] = []
    with conn.transaction():
        with conn.cursor() as cur:
            cur.execute("""
                SELECT job_id, payload
                FROM maludb_core.queue_lease('pageindex_build', %s, %s, NULL)
            """, (worker_id, batch_size))
            for row in cur.fetchall():
                job_id, payload = row
                if isinstance(payload, str):
                    payload = json.loads(payload)
                leased.append((int(job_id), payload))
    for job_id, payload in leased:
        try:
            result = build_tree(conn, payload)
            if result.outcome == "ok":
                with conn.transaction():
                    with conn.cursor() as cur:
                        cur.execute(
                            "SELECT maludb_core.queue_ack(%s)", (job_id,))
                log.info("built tree_id=%s outline_nodes=%s leaves=%s",
                         result.tree_id, result.outline_node_count,
                         result.leaf_count)
            else:
                _nack(conn, job_id, result.error_text or "builder failed")
        except Exception as e:
            log.exception("build_tree raised for job_id=%s", job_id)
            _nack(conn, job_id, str(e))
    return len(leased)


def _nack(conn, job_id: int, reason: str) -> None:
    with conn.transaction():
        with conn.cursor() as cur:
            cur.execute("SELECT maludb_core.queue_nack(%s, %s)",
                        (job_id, reason))
