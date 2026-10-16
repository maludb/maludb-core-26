"""Connection helper — connection-per-stream + search_path pin."""

from __future__ import annotations

import contextlib
import os
from typing import Iterator

import psycopg


def _dsn_from_env() -> str:
    parts = []
    db = os.environ.get("MALUDB_REALTIMED_DB")
    if not db:
        raise RuntimeError("MALUDB_REALTIMED_DB is required")
    parts.append(f"dbname={db}")
    for var, key in (
        ("MALUDB_REALTIMED_HOST",     "host"),
        ("MALUDB_REALTIMED_PORT",     "port"),
        ("MALUDB_REALTIMED_USER",     "user"),
        ("MALUDB_REALTIMED_PASSWORD", "password"),
    ):
        v = os.environ.get(var)
        if v:
            parts.append(f"{key}={v}")
    parts.append("application_name=maludb-realtimed")
    return " ".join(parts)


class Pool:
    """Connection-per-stream wrapper; SSE streams hold the connection
    for the lifetime of the stream (LISTEN needs a sticky session).
    Short-lived REST calls (/events/ack, /healthz) also use one
    connection per call.
    """

    def __init__(self, dsn: str | None = None) -> None:
        self._dsn = dsn or _dsn_from_env()

    @contextlib.contextmanager
    def connection(self) -> Iterator[psycopg.Connection]:
        conn = psycopg.connect(self._dsn, autocommit=False)
        try:
            with conn.cursor() as cur:
                cur.execute("SET search_path TO maludb_core, public")
            yield conn
            try:
                conn.commit()
            except Exception:
                pass
        finally:
            conn.close()

    def close(self) -> None:
        return
