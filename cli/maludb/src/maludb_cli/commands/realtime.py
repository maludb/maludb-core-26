"""`maludb realtime subscribe|list|fetch|ack` — V3-REALTIME-01 wiring.

The CLI uses the SQL-only path (no SSE service required). Operators
who want a long-lived SSE stream point a client at `maludb-realtimed`;
the CLI is for batch fetch / ack workflows and for `maludb metrics`-
style observability.
"""

from __future__ import annotations

import json
import sys
import time

from ..db import connect
from ..output import emit_record, emit_table


def register(sub) -> None:
    p = sub.add_parser("realtime", help="Memory event stream (V3-REALTIME-01).")
    p_sub = p.add_subparsers(dest="realtime_cmd", required=True, metavar="<realtime-cmd>")

    sb = p_sub.add_parser("subscribe", help="Create a new event subscription.")
    sb.add_argument("--name",          required=True)
    sb.add_argument("--account-id",    type=int, default=None)
    sb.add_argument("--kind",          action="append", default=[], help="Repeatable kind filter.")
    sb.add_argument("--partition",     action="append", default=[], help="Repeatable partition filter.")
    sb.add_argument("--active-pool-id", type=int, default=None)
    sb.add_argument("--start-cursor",  type=int, default=0)
    sb.set_defaults(handler=_subscribe)

    ls = p_sub.add_parser("list", help="List subscriptions.")
    ls.add_argument("--include-retired", action="store_true")
    ls.set_defaults(handler=_list)

    ft = p_sub.add_parser("fetch", help="Fetch a batch of events past the subscription cursor (no ack).")
    ft.add_argument("--subscription-id", type=int, required=True)
    ft.add_argument("--limit",           type=int, default=100)
    ft.set_defaults(handler=_fetch)

    ac = p_sub.add_parser("ack", help="Advance the subscription cursor.")
    ac.add_argument("--subscription-id", type=int, required=True)
    ac.add_argument("--through-event-id", type=int, required=True)
    ac.set_defaults(handler=_ack)

    tl = p_sub.add_parser("tail", help="Fetch + auto-ack in a loop. Stops on Ctrl-C.")
    tl.add_argument("--subscription-id", type=int, required=True)
    tl.add_argument("--limit",           type=int, default=100)
    tl.add_argument("--poll-seconds",    type=float, default=1.0)
    tl.add_argument("--auto-ack",        action="store_true",
        help="Advance the cursor after each batch instead of leaving it for the caller.")
    tl.set_defaults(handler=_tail)


def _subscribe(args) -> int:
    with connect(args) as conn, conn.cursor() as cur:
        cur.execute(
            "SELECT event_subscribe(%s, %s, %s::text[], %s::text[], %s, %s)",
            (args.name, args.account_id, args.kind or [],
             args.partition or [], args.active_pool_id, args.start_cursor),
        )
        sid = cur.fetchone()[0]
    emit_record(args.format, {"subscription_id": sid, "name": args.name})
    return 0


def _list(args) -> int:
    with connect(args) as conn, conn.cursor() as cur:
        cur.execute("SELECT * FROM event_list_subscriptions(%s)", (args.include_retired,))
        rows = cur.fetchall()
    emit_table(args.format,
        ("subscription_id", "name", "account_id", "kinds", "partitions",
         "active_pool_id", "cursor", "last_seen_at", "retired_at"),
        rows)
    return 0


def _fetch(args) -> int:
    with connect(args) as conn, conn.cursor() as cur:
        cur.execute(
            "SELECT * FROM event_fetch_batch(%s, %s)",
            (args.subscription_id, args.limit),
        )
        rows = cur.fetchall()
    emit_table(args.format,
        ("event_id", "event_kind", "account_id", "partition",
         "active_pool_id", "object_type", "object_id", "scope",
         "transaction_time", "payload"),
        rows)
    return 0


def _ack(args) -> int:
    with connect(args) as conn, conn.cursor() as cur:
        cur.execute("SELECT event_ack(%s, %s)", (args.subscription_id, args.through_event_id))
        acked = cur.fetchone()[0]
    emit_record(args.format, {
        "subscription_id":  args.subscription_id,
        "through_event_id": args.through_event_id,
        "acked":            acked,
    })
    return 0


def _tail(args) -> int:
    try:
        while True:
            with connect(args) as conn, conn.cursor() as cur:
                cur.execute(
                    "SELECT event_id, event_kind, payload "
                    "FROM event_fetch_batch(%s, %s)",
                    (args.subscription_id, args.limit),
                )
                rows = cur.fetchall()
                last_id = None
                for r in rows:
                    last_id = r[0]
                    if args.format == "json":
                        json.dump({"event_id": r[0], "event_kind": r[1], "payload": r[2]},
                                  sys.stdout, default=str)
                        sys.stdout.write("\n")
                    else:
                        print(f"{r[0]}\t{r[1]}\t{json.dumps(r[2], default=str)}")
                    sys.stdout.flush()
                if args.auto_ack and last_id is not None:
                    cur.execute("SELECT event_ack(%s, %s)", (args.subscription_id, last_id))
            time.sleep(args.poll_seconds)
    except KeyboardInterrupt:
        return 130
