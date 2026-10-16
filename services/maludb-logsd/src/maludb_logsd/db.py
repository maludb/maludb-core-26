"""PostgreSQL connection helpers for maludb-logsd."""

from __future__ import annotations

import contextlib
import os
from typing import Iterator

import psycopg


def _dsn_from_env() -> str:
    parts = []
    db = os.environ.get("MALUDB_LOGSD_DB")
    if not db:
        raise RuntimeError("MALUDB_LOGSD_DB is required")
    parts.append(f"dbname={db}")
    for var, key in (
        ("MALUDB_LOGSD_HOST", "host"),
        ("MALUDB_LOGSD_PORT", "port"),
        ("MALUDB_LOGSD_USER", "user"),
        ("MALUDB_LOGSD_PASSWORD", "password"),
    ):
        v = os.environ.get(var)
        if v:
            parts.append(f"{key}={v}")
    parts.append("application_name=maludb-logsd")
    return " ".join(parts)


class Pool:
    """Connection-per-call wrapper, matching maludb-restd's pattern."""

    def __init__(self, dsn: str | None = None) -> None:
        self._dsn = dsn or _dsn_from_env()

    @contextlib.contextmanager
    def connection(self) -> Iterator[psycopg.Connection]:
        conn = psycopg.connect(self._dsn, autocommit=False)
        try:
            with conn.cursor() as cur:
                cur.execute("SET search_path TO maludb_core, public")
            yield conn
            conn.commit()
        except Exception:
            conn.rollback()
            raise
        finally:
            conn.close()
