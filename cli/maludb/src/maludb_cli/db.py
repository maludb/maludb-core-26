"""Connection helper for the maludb CLI.

Single connection per invocation; pins search_path to the optional
tenant schema and maludb_core so unqualified table refs inside the
extension's SECURITY INVOKER helpers resolve.
"""

from __future__ import annotations

import contextlib
import os
from typing import Iterator

import psycopg


def _quote_identifier(identifier: str) -> str:
    return '"' + identifier.replace('"', '""') + '"'


def _search_path(schema: str | None) -> str:
    if not schema:
        return "maludb_core, public"
    return f"{_quote_identifier(schema)}, maludb_core, public"


def _dsn(args) -> str:
    parts = []
    db = args.db or os.environ.get("MALUDB_DB")
    if not db:
        raise RuntimeError("MALUDB_DB env var or --db argument is required")
    parts.append(f"dbname={db}")
    for var, key, attr in (
        ("MALUDB_HOST",     "host",     "host"),
        ("MALUDB_PORT",     "port",     "port"),
        ("MALUDB_USER",     "user",     "user"),
        ("MALUDB_PASSWORD", "password", "password"),
    ):
        v = getattr(args, attr, None) or os.environ.get(var)
        if v:
            parts.append(f"{key}={v}")
    parts.append("application_name=maludb-cli")
    return " ".join(parts)


@contextlib.contextmanager
def connect(args) -> Iterator[psycopg.Connection]:
    conn = psycopg.connect(_dsn(args), autocommit=False)
    try:
        with conn.cursor() as cur:
            schema = getattr(args, "schema", None) or os.environ.get("MALUDB_SCHEMA")
            cur.execute(f"SET search_path = {_search_path(schema)}")
        yield conn
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()
