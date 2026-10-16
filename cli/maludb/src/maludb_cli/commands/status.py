"""`maludb status` — extension health, version, and migration state."""

from __future__ import annotations

from ..db import connect
from ..output import emit_record


def register(sub) -> None:
    p = sub.add_parser("status", help="Show extension version, services, migration state.")
    p.set_defaults(handler=_handler)


def _handler(args) -> int:
    out = {}
    with connect(args) as conn, conn.cursor() as cur:
        cur.execute("SELECT maludb_core_version()")
        out["extension_version"] = cur.fetchone()[0]
        cur.execute("SELECT extversion FROM pg_extension WHERE extname = 'maludb_core'")
        row = cur.fetchone()
        out["installed_version"] = row[0] if row else None
        cur.execute("SELECT version()")
        out["postgresql_version"] = cur.fetchone()[0]
        cur.execute("""
            SELECT count(*) FROM pg_class c
            JOIN pg_namespace n ON n.oid=c.relnamespace
            WHERE n.nspname='maludb_core' AND c.relkind='r' AND c.relname LIKE 'malu$%'
        """)
        out["catalog_tables"] = cur.fetchone()[0]
        cur.execute("SELECT count(*) FROM malu$audit_event")
        out["audit_event_rows"] = cur.fetchone()[0]
        # Best-effort check that mc2dbd / rest invocations exist (services
        # have written something at least once).
        cur.execute("SELECT count(*) FROM malu$mc2db_invocation")
        out["mc2db_invocations"] = cur.fetchone()[0]
        cur.execute("SELECT count(*) FROM malu$rest_invocation")
        out["rest_invocations"] = cur.fetchone()[0]
    emit_record(args.format, out)
    return 0
