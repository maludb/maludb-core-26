"""`maludb metrics scrape` — Prometheus-style exposition built from
the catalog. V3-OBS-01 will replace this with a dedicated endpoint;
for now we surface the counters that the v0.1.0 catalog can support.
"""

from __future__ import annotations

import sys

from ..db import connect
from ..output import emit_record


def register(sub) -> None:
    p = sub.add_parser("metrics", help="Observability surfaces.")
    p_sub = p.add_subparsers(dest="metrics_cmd", required=True, metavar="<metrics-cmd>")

    sc = p_sub.add_parser("scrape", help="Prometheus-format scrape over the current catalog (V3-OBS-01 preview).")
    sc.set_defaults(handler=_scrape)


def _scrape(args) -> int:
    with connect(args) as conn, conn.cursor() as cur:
        cur.execute("SELECT maludb_core_version()")
        ext_version = cur.fetchone()[0]

        cur.execute("""
            SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
             WHERE n.nspname = 'maludb_core' AND c.relkind = 'r' AND c.relname LIKE 'malu$%'
        """)
        catalog_tables = cur.fetchone()[0]

        cur.execute("SELECT count(*) FROM malu$audit_event")
        audit_events = cur.fetchone()[0]

        cur.execute("""
            SELECT event_kind, count(*) FROM malu$audit_event
             GROUP BY event_kind
        """)
        per_kind = cur.fetchall()

        cur.execute("SELECT count(*) FROM malu$mc2db_invocation")
        mc2db_calls = cur.fetchone()[0]

        cur.execute("""
            SELECT count(*) FILTER (WHERE success),
                   count(*) FILTER (WHERE NOT success)
              FROM malu$mc2db_invocation
        """)
        mc2db_ok, mc2db_fail = cur.fetchone()

        cur.execute("SELECT count(*) FROM malu$rest_invocation")
        rest_calls = cur.fetchone()[0]
        cur.execute("""
            SELECT count(*) FILTER (WHERE success),
                   count(*) FILTER (WHERE NOT success)
              FROM malu$rest_invocation
        """)
        rest_ok, rest_fail = cur.fetchone()

        cur.execute("""
            SELECT count(*) FILTER (WHERE revoked_at IS NULL AND (expires_at IS NULL OR expires_at > now())),
                   count(*) FILTER (WHERE revoked_at IS NOT NULL)
              FROM malu$auth_token
        """)
        tokens_active, tokens_revoked = cur.fetchone()

        cur.execute("""
            SELECT count(*) FILTER (WHERE retired_at IS NULL),
                   count(*) FILTER (WHERE retired_at IS NOT NULL)
              FROM malu$secret
        """)
        secrets_active, secrets_retired = cur.fetchone()

    if args.format == "json":
        emit_record(args.format, {
            "extension_version": ext_version,
            "catalog_tables":   catalog_tables,
            "audit_events":     audit_events,
            "audit_per_kind":   {k: n for k, n in per_kind},
            "mc2db_calls":      mc2db_calls,
            "mc2db_ok":         mc2db_ok,
            "mc2db_fail":       mc2db_fail,
            "rest_calls":       rest_calls,
            "rest_ok":          rest_ok,
            "rest_fail":        rest_fail,
            "tokens_active":    tokens_active,
            "tokens_revoked":   tokens_revoked,
            "secrets_active":   secrets_active,
            "secrets_retired":  secrets_retired,
        })
        return 0

    out = sys.stdout
    out.write(f"# maludb_metrics preview (V3-OBS-01 ships a server-side exposition)\n")
    out.write(f"maludb_extension_version{{version=\"{ext_version}\"}} 1\n")
    out.write(f"maludb_catalog_tables {catalog_tables}\n")
    out.write(f"maludb_audit_event_total {audit_events}\n")
    for kind, n in per_kind:
        out.write(f'maludb_audit_event_by_kind_total{{event_kind="{kind}"}} {n}\n')
    out.write(f"maludb_mc2db_invocation_total {mc2db_calls}\n")
    out.write(f'maludb_mc2db_invocation_outcome_total{{outcome="success"}} {mc2db_ok}\n')
    out.write(f'maludb_mc2db_invocation_outcome_total{{outcome="failure"}} {mc2db_fail}\n')
    out.write(f"maludb_rest_invocation_total {rest_calls}\n")
    out.write(f'maludb_rest_invocation_outcome_total{{outcome="success"}} {rest_ok}\n')
    out.write(f'maludb_rest_invocation_outcome_total{{outcome="failure"}} {rest_fail}\n')
    out.write(f'maludb_auth_token_total{{state="active"}} {tokens_active}\n')
    out.write(f'maludb_auth_token_total{{state="revoked"}} {tokens_revoked}\n')
    out.write(f'maludb_secret_total{{state="active"}} {secrets_active}\n')
    out.write(f'maludb_secret_total{{state="retired"}} {secrets_retired}\n')
    return 0
