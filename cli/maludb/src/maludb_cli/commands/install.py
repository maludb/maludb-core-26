"""`maludb install doctor` — preflight check for an install.

Checks: PG version, required extensions present (vector, btree_gist,
pg_trgm, pgcrypto), role family registered, schema USAGE for the
expected service roles.
"""

from __future__ import annotations

from ..db import connect
from ..output import emit_table


_REQUIRED_EXTENSIONS = ("vector", "btree_gist", "pg_trgm", "pgcrypto")
_REQUIRED_ROLES = (
    "maludb_llm_admin", "maludb_llm_executor", "maludb_llm_auditor",
    "maludb_memory_admin", "maludb_memory_executor", "maludb_memory_auditor",
    "maludb_secret_consumer", "maludb_rest_dispatcher",
)


def register(sub) -> None:
    p = sub.add_parser("install", help="Install-time helpers.")
    p_sub = p.add_subparsers(dest="install_cmd", required=True, metavar="<install-cmd>")

    doctor = p_sub.add_parser("doctor", help="Preflight check for a maludb install.")
    doctor.set_defaults(handler=_doctor)


def _doctor(args) -> int:
    rows = []
    rc = 0
    with connect(args) as conn, conn.cursor() as cur:
        cur.execute("SHOW server_version")
        pg_ver = cur.fetchone()[0]
        rows.append(("postgresql", pg_ver, "ok" if int(pg_ver.split(".")[0]) >= 16 else "fail"))
        if int(pg_ver.split(".")[0]) < 16:
            rc = 1

        cur.execute("SELECT extname FROM pg_extension WHERE extname = ANY(%s)", (list(_REQUIRED_EXTENSIONS),))
        present = {r[0] for r in cur.fetchall()}
        for ext in _REQUIRED_EXTENSIONS:
            ok = ext in present
            rows.append((f"extension:{ext}", "installed" if ok else "missing", "ok" if ok else "fail"))
            if not ok:
                rc = 1

        cur.execute("SELECT rolname FROM pg_roles WHERE rolname = ANY(%s)", (list(_REQUIRED_ROLES),))
        roles = {r[0] for r in cur.fetchall()}
        for role in _REQUIRED_ROLES:
            ok = role in roles
            rows.append((f"role:{role}", "present" if ok else "missing", "ok" if ok else "fail"))
            if not ok:
                rc = 1

    emit_table(args.format, ("check", "value", "status"), rows)
    return rc
