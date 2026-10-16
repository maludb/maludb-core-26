"""PostgreSQL connection helpers for maludb-restd.

The first cut opens a fresh psycopg connection per request. That keeps
the runtime dependency to `psycopg[binary]` alone (matching the
existing Python driver) and dodges the connection-pooling library
question for an alpha. A `psycopg_pool.ConnectionPool` upgrade is a
no-op refactor once the daemon needs to scale.
"""

from __future__ import annotations

import contextlib
import os
from typing import Iterator

import psycopg


def _dsn_from_env() -> str:
    """Build a libpq DSN from MALUDB_RESTD_* environment variables.

    Required: MALUDB_RESTD_DB (database name).
    Optional: MALUDB_RESTD_HOST, _PORT, _USER, _PASSWORD.
    """
    parts = []
    db = os.environ.get("MALUDB_RESTD_DB")
    if not db:
        raise RuntimeError("MALUDB_RESTD_DB is required")
    parts.append(f"dbname={db}")
    for var, key in (
        ("MALUDB_RESTD_HOST", "host"),
        ("MALUDB_RESTD_PORT", "port"),
        ("MALUDB_RESTD_USER", "user"),
        ("MALUDB_RESTD_PASSWORD", "password"),
    ):
        v = os.environ.get(var)
        if v:
            parts.append(f"{key}={v}")
    parts.append("application_name=maludb-restd")
    return " ".join(parts)


class Pool:
    """Connection-per-request wrapper. The class name is preserved so
    a future swap to `psycopg_pool.ConnectionPool` is a one-file edit.
    """

    def __init__(self, dsn: str | None = None) -> None:
        self._dsn = dsn or _dsn_from_env()

    @contextlib.contextmanager
    def connection(self) -> Iterator[psycopg.Connection]:
        conn = psycopg.connect(self._dsn, autocommit=False)
        try:
            # Pin search_path so unqualified table refs inside
            # maludb_core's SECURITY INVOKER helpers (e.g.,
            # rest_log_invocation, rest_openapi_spec) resolve.
            with conn.cursor() as cur:
                cur.execute("SET search_path TO maludb_core, public")
            yield conn
            conn.commit()
        except Exception:
            conn.rollback()
            raise
        finally:
            conn.close()

    def close(self) -> None:
        # No persistent pool; nothing to release.
        return


def set_account_guc(conn: psycopg.Connection, account_id: int | None) -> None:
    """Bind the connection to a tenant account for RLS.

    Per maludb_core's current_account_id() helper, the GUC
    `maludb_core.current_account_id` is the primary binding mechanism;
    setting it to NULL clears the binding (RLS returns no rows).
    """
    with conn.cursor() as cur:
        if account_id is None:
            cur.execute("RESET maludb_core.current_account_id")
        else:
            cur.execute(
                "SELECT set_config('maludb_core.current_account_id', %s, true)",
                (str(account_id),),
            )
