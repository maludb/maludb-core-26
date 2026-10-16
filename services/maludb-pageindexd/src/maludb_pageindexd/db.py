"""Database access helpers for maludb-pageindexd.

A thin psycopg wrapper that the worker uses to lease queue jobs, call
SQL helpers, and ack / nack jobs. The connection string is whatever
`psycopg.connect()` finds via the standard libpq environment variables
(`PGHOST`, `PGUSER`, `PGDATABASE`, `PGPASSWORD`, …) or an explicit
`MALUDB_PAGEINDEXD_DSN`.

Designed to match the maludb-logsd / maludb-realtimed db.py shape so
operators see the same operational surface.
"""

from __future__ import annotations

import os
import threading
from typing import Any

import psycopg


class Pool:
    """Single-connection pool keyed by thread.

    Each worker thread gets its own connection; the worker loop is
    single-threaded by default, so this is effectively a 1-connection
    pool that survives reconnects.
    """

    def __init__(self, dsn: str | None = None) -> None:
        self._dsn = dsn or os.environ.get("MALUDB_PAGEINDEXD_DSN") or ""
        self._local = threading.local()

    def connect(self) -> psycopg.Connection:
        conn = getattr(self._local, "conn", None)
        if conn is None or conn.closed:
            conn = psycopg.connect(self._dsn, autocommit=False)
            self._local.conn = conn
        return conn

    def close(self) -> None:
        conn = getattr(self._local, "conn", None)
        if conn is not None and not conn.closed:
            conn.close()
        self._local.conn = None
