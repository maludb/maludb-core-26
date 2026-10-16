"""`maludb cron list|create|enable|disable|run-now|tick` — V3-CRON-01 wiring."""

from __future__ import annotations

import json

from ..db import connect
from ..output import emit_record, emit_table


def register(sub) -> None:
    p = sub.add_parser("cron", help="Scheduled jobs (V3-CRON-01).")
    p_sub = p.add_subparsers(dest="cron_cmd", required=True, metavar="<cron-cmd>")

    ls = p_sub.add_parser("list", help="List schedules.")
    ls.add_argument("--include-disabled", action="store_true")
    ls.set_defaults(handler=_list)

    cr = p_sub.add_parser("create", help="Register a schedule.")
    cr.add_argument("--name",        required=True)
    cr.add_argument("--cron-expr",   required=True, help="Standard 5-field cron or @hourly/@daily/@weekly/@monthly/@yearly.")
    cr.add_argument("--action-kind", required=True, choices=("enqueue", "sql"))
    cr.add_argument("--payload",     required=True,
        help="JSON object. For enqueue: {\"queue\":...,\"payload\":...}. For sql: {\"sql\":...} (admin-only).")
    cr.add_argument("--description", default=None)
    cr.set_defaults(handler=_create)

    en = p_sub.add_parser("enable", help="Enable a schedule and recompute next_run_at.")
    en.add_argument("--name", required=True)
    en.set_defaults(handler=_enable)

    di = p_sub.add_parser("disable", help="Disable a schedule.")
    di.add_argument("--name",   required=True)
    di.add_argument("--reason", default=None)
    di.set_defaults(handler=_disable)

    rn = p_sub.add_parser("run-now", help="Invoke a schedule immediately.")
    rn.add_argument("--name", required=True)
    rn.set_defaults(handler=_run_now)

    tk = p_sub.add_parser("tick", help="Run every schedule whose next_run_at <= now().")
    tk.set_defaults(handler=_tick)


def _list(args) -> int:
    with connect(args) as conn, conn.cursor() as cur:
        cur.execute("SELECT * FROM schedule_list(%s)", (args.include_disabled,))
        rows = cur.fetchall()
    emit_table(args.format,
        ("schedule_id", "name", "cron_expr", "action_kind", "enabled",
         "next_run_at", "last_run_at", "last_error"),
        rows)
    return 0


def _create(args) -> int:
    try:
        payload = json.loads(args.payload)
    except json.JSONDecodeError as e:
        emit_record(args.format, {"error": f"invalid --payload JSON: {e}"})
        return 64
    with connect(args) as conn, conn.cursor() as cur:
        cur.execute(
            "SELECT schedule_create(%s, %s, %s, %s::jsonb, %s, true)",
            (args.name, args.cron_expr, args.action_kind, json.dumps(payload), args.description),
        )
        sid = cur.fetchone()[0]
    emit_record(args.format, {"schedule_id": sid, "name": args.name})
    return 0


def _enable(args) -> int:
    with connect(args) as conn, conn.cursor() as cur:
        cur.execute("SELECT schedule_enable(%s)", (args.name,))
        reenabled = cur.fetchone()[0]
    emit_record(args.format, {"name": args.name, "reenabled": reenabled})
    return 0


def _disable(args) -> int:
    with connect(args) as conn, conn.cursor() as cur:
        cur.execute("SELECT schedule_disable(%s, %s)", (args.name, args.reason))
        was = cur.fetchone()[0]
    emit_record(args.format, {"name": args.name, "was_enabled": was})
    return 0


def _run_now(args) -> int:
    with connect(args) as conn, conn.cursor() as cur:
        cur.execute("SELECT schedule_run_now(%s)", (args.name,))
        run_id = cur.fetchone()[0]
    emit_record(args.format, {"name": args.name, "run_id": run_id})
    return 0


def _tick(args) -> int:
    with connect(args) as conn, conn.cursor() as cur:
        cur.execute("SELECT schedule_tick()")
        fired = cur.fetchone()[0]
    emit_record(args.format, {"fired": fired})
    return 0
