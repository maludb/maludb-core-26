"""maludb-logsd worker — one iteration of the poll loop."""

from __future__ import annotations

import json
import logging
import time
from typing import Any

from .db import Pool
from .sinks import SinkError, make_sink


log = logging.getLogger("maludb_logsd.worker")


def _decode_destination(raw: Any) -> dict[str, Any]:
    if raw is None:
        return {}
    if isinstance(raw, dict):
        return raw
    if isinstance(raw, str):
        return json.loads(raw)
    return dict(raw)


def _resolve_secret(conn, secret_ref: str | None) -> str | None:
    """Resolve a malu$secret reference via the inline path.

    External resolvers (file:// / https://) ship in V3-SECRET-02
    (Stage I). For now we only support the inline (AES-encrypted)
    secret_get_inline path. Returns the plaintext, or None if no
    secret is referenced.
    """
    if not secret_ref:
        return None
    with conn.cursor() as cur:
        cur.execute(
            "SELECT secret_get_inline(%s)",
            (secret_ref,),
        )
        row = cur.fetchone()
    return row[0] if row else None


class Worker:
    """Stateless poll-once worker. Real daemon loops on iterate_once()."""

    def __init__(self, pool: Pool, batch_size: int = 100) -> None:
        self._pool       = pool
        self._batch_size = batch_size

    def iterate_once(self) -> dict[str, int]:
        """One pass: visit every enabled drain × every subscribed stream.

        Returns a summary dict: {"drains": N, "records": N, "errors": N}.
        """
        summary = {"drains": 0, "records": 0, "errors": 0}
        with self._pool.connection() as conn:
            with conn.cursor() as cur:
                cur.execute(
                    """
                    SELECT drain_id, kind, destination, source_streams,
                           destination_secret_ref, batch_size
                      FROM malu$log_drain
                     WHERE enabled = true AND retired_at IS NULL
                     ORDER BY drain_id
                    """
                )
                drains = cur.fetchall()
            for drain_id, kind, destination, streams, secret_ref, drain_batch in drains:
                summary["drains"] += 1
                dest = _decode_destination(destination)
                batch_size = drain_batch or self._batch_size
                try:
                    secret_value = _resolve_secret(conn, secret_ref)
                    sink = make_sink(kind, dest, secret_value)
                except SinkError as e:
                    log.warning("drain %s setup failed: %s", drain_id, e)
                    self._record_run(conn, drain_id, batches=0, bytes_=0, records=0,
                                     errors=1, last_error=str(e))
                    summary["errors"] += 1
                    continue
                streams = list(streams or [])
                drain_records = 0
                drain_bytes   = 0
                drain_batches = 0
                drain_errors  = 0
                last_error    = None
                for stream in streams:
                    try:
                        delivered, advanced, batched, byte_count = \
                            self._drain_one_stream(conn, drain_id, stream,
                                                   sink, batch_size)
                        drain_records += delivered
                        drain_bytes   += byte_count
                        drain_batches += batched
                    except SinkError as e:
                        drain_errors += 1
                        last_error    = str(e)
                        log.warning("drain %s stream %s: %s",
                                    drain_id, stream, e)
                if drain_records or drain_errors:
                    self._record_run(conn, drain_id,
                                     batches=drain_batches, bytes_=drain_bytes,
                                     records=drain_records, errors=drain_errors,
                                     last_error=last_error)
                summary["records"] += drain_records
                summary["errors"]  += drain_errors
        return summary

    def _drain_one_stream(self, conn, drain_id: int, stream: str, sink,
                          batch_size: int) -> tuple[int, int, int, int]:
        """Ship a single batch for one (drain, stream). Returns
        (records_delivered, cursor_new, batches, bytes_)."""
        with conn.cursor() as cur:
            cur.execute(
                "SELECT record_id, payload FROM log_drain_fetch_batch(%s, %s, %s)",
                (drain_id, stream, batch_size),
            )
            rows = cur.fetchall()
        if not rows:
            return (0, 0, 0, 0)
        batch = [r[1] if isinstance(r[1], dict) else json.loads(r[1])
                 for r in rows]
        batches, byte_count = sink.ship(batch)
        last_id = rows[-1][0]
        with conn.cursor() as cur:
            cur.execute(
                "SELECT log_drain_advance_cursor(%s, %s, %s)",
                (drain_id, stream, last_id),
            )
            advanced = cur.fetchone()[0]
        return (len(rows), advanced, batches, byte_count)

    def _record_run(self, conn, drain_id: int, batches: int, bytes_: int,
                    records: int, errors: int, last_error: str | None) -> None:
        with conn.cursor() as cur:
            cur.execute(
                "SELECT log_drain_record_run(%s, %s, %s, %s, %s, %s)",
                (drain_id, batches, bytes_, records, errors, last_error),
            )


def run_forever(pool: Pool, interval_s: float, batch_size: int,
                stop_event) -> None:
    worker = Worker(pool, batch_size=batch_size)
    while not stop_event.is_set():
        try:
            summary = worker.iterate_once()
            if summary["records"] or summary["errors"]:
                log.info("logsd iteration: %s", summary)
            else:
                log.debug("logsd iteration: %s", summary)
        except Exception as e:                                  # noqa: BLE001
            log.exception("logsd iteration failed: %s", e)
        stop_event.wait(timeout=interval_s)
