"""`maludb log-drain set|enable|disable|list|record-run` — V3-LOG-01 wiring."""

from __future__ import annotations

import json

from ..db import connect
from ..output import emit_record, emit_table


def register(sub) -> None:
    p = sub.add_parser("log-drain", help="Log drain catalog (V3-LOG-01).")
    p_sub = p.add_subparsers(dest="log_drain_cmd", required=True, metavar="<log-drain-cmd>")

    st = p_sub.add_parser("set",
        help="Register or replace a log drain.")
    st.add_argument("--name",                  required=True)
    st.add_argument("--kind",                  required=True,
        choices=("http", "file", "s3", "otlp_http"))
    st.add_argument("--destination",           required=True,
        help='JSON. http: {"url":...}. file: {"path":...}. s3: {"bucket":...,"key_prefix":...}. otlp_http: {"endpoint":...}.')
    st.add_argument("--source-streams",        required=True, nargs="+",
        help="One or more stream names (audit, queue, mc2db, postgres, ...).")
    st.add_argument("--destination-secret-ref", default=None,
        help="malu$secret name holding outbound credentials.")
    st.add_argument("--redaction-rules",       default="[]",
        help='JSON array. Each rule: {"path":"$.<jsonpath>","replace":"<value>"}.')
    st.add_argument("--batch-size",            type=int, default=100)
    st.add_argument("--flush-interval-ms",     type=int, default=5000)
    st.set_defaults(handler=_set)

    en = p_sub.add_parser("enable",  help="Re-enable a drain previously disabled.")
    en.add_argument("--name", required=True)
    en.set_defaults(handler=_enable)

    dis = p_sub.add_parser("disable", help="Disable a drain without retiring it.")
    dis.add_argument("--name",   required=True)
    dis.add_argument("--reason", default=None)
    dis.set_defaults(handler=_disable)

    ls = p_sub.add_parser("list", help="List drains.")
    ls.add_argument("--include-disabled", action="store_true")
    ls.set_defaults(handler=_list)

    rr = p_sub.add_parser("record-run",
        help="Record a delivery run outcome (used by the service runner).")
    rr.add_argument("--drain-id",   type=int, required=True)
    rr.add_argument("--batches",    type=int, required=True)
    rr.add_argument("--bytes",      type=int, required=True)
    rr.add_argument("--records",    type=int, required=True)
    rr.add_argument("--errors",     type=int, default=0)
    rr.add_argument("--last-error", default=None,
        help="Most recent error string, if any.")
    rr.set_defaults(handler=_record_run)


def _set(args) -> int:
    destination = json.loads(args.destination)
    redaction = json.loads(args.redaction_rules)
    with connect(args) as conn, conn.cursor() as cur:
        cur.execute(
            """
            SELECT log_drain_set(%s, %s, %s, %s, %s, %s, %s, %s)
            """,
            (args.name, args.kind, json.dumps(destination),
             list(args.source_streams), args.destination_secret_ref,
             json.dumps(redaction), args.batch_size, args.flush_interval_ms),
        )
        drain_id = cur.fetchone()[0]
    emit_record(args.format, {"name": args.name, "drain_id": drain_id,
                              "kind": args.kind,
                              "source_streams": list(args.source_streams),
                              "batch_size": args.batch_size,
                              "flush_interval_ms": args.flush_interval_ms})
    return 0


def _enable(args) -> int:
    with connect(args) as conn, conn.cursor() as cur:
        cur.execute("SELECT log_drain_enable(%s)", (args.name,))
        ok = cur.fetchone()[0]
    emit_record(args.format, {"name": args.name, "enabled": ok})
    return 0 if ok else 65


def _disable(args) -> int:
    with connect(args) as conn, conn.cursor() as cur:
        cur.execute("SELECT log_drain_disable(%s, %s)", (args.name, args.reason))
        ok = cur.fetchone()[0]
    emit_record(args.format, {"name": args.name, "disabled": ok})
    return 0 if ok else 65


def _list(args) -> int:
    with connect(args) as conn, conn.cursor() as cur:
        cur.execute(
            "SELECT drain_id, name, kind, source_streams, enabled, retired_at "
            "FROM log_drain_list(%s)",
            (args.include_disabled,),
        )
        rows = cur.fetchall()
    emit_table(args.format,
        ("drain_id", "name", "kind", "source_streams", "enabled", "retired_at"),
        rows)
    return 0


def _record_run(args) -> int:
    with connect(args) as conn, conn.cursor() as cur:
        cur.execute(
            "SELECT log_drain_record_run(%s, %s, %s, %s, %s, %s)",
            (args.drain_id, args.batches, args.bytes, args.records,
             args.errors, args.last_error),
        )
        run_id = cur.fetchone()[0]
    emit_record(args.format, {"drain_id": args.drain_id, "run_id": run_id,
                              "batches": args.batches, "bytes": args.bytes,
                              "records": args.records, "errors": args.errors})
    return 0
