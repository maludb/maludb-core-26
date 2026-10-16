"""`maludb queue list|drain|retry|enqueue|stats` — V3-QUEUE-01 wiring."""

from __future__ import annotations

import json

from ..db import connect
from ..output import emit_record, emit_table


def register(sub) -> None:
    p = sub.add_parser("queue", help="Durable job queue (V3-QUEUE-01).")
    p_sub = p.add_subparsers(dest="queue_cmd", required=True, metavar="<queue-cmd>")

    ls = p_sub.add_parser("list", help="List queues with current depth + retry stats.")
    ls.set_defaults(handler=_list)

    en = p_sub.add_parser("enqueue", help="Push a payload onto a queue.")
    en.add_argument("--queue",            required=True)
    en.add_argument("--payload",          required=True, help="JSON object passed as job payload.")
    en.add_argument("--idempotency-key",  default=None)
    en.add_argument("--priority",         type=int, default=0)
    en.set_defaults(handler=_enqueue)

    dr = p_sub.add_parser("drain", help="Reap expired leases (returns expired-then-pending count).")
    dr.set_defaults(handler=_drain)

    rt = p_sub.add_parser("retry", help="Re-queue a single dead-letter job by id (sets visible_at=now()).")
    rt.add_argument("--job-id", type=int, required=True)
    rt.set_defaults(handler=_retry)

    sg = p_sub.add_parser("stats", help="Stats per queue (alias of `list`).")
    sg.set_defaults(handler=_list)


def _list(args) -> int:
    with connect(args) as conn, conn.cursor() as cur:
        cur.execute(
            "SELECT queue_name, pending, leased, completed, failed, dead FROM queue_stats()"
        )
        rows = cur.fetchall()
    emit_table(args.format,
        ("queue", "pending", "leased", "completed", "failed", "dead"),
        rows)
    return 0


def _enqueue(args) -> int:
    try:
        payload = json.loads(args.payload)
    except json.JSONDecodeError as e:
        emit_record(args.format, {"error": f"invalid --payload JSON: {e}"})
        return 64
    with connect(args) as conn, conn.cursor() as cur:
        cur.execute(
            "SELECT queue_enqueue(%s, %s::jsonb, %s, %s, NULL, NULL)",
            (args.queue, json.dumps(payload), args.idempotency_key, args.priority),
        )
        job_id = cur.fetchone()[0]
    emit_record(args.format, {"queue": args.queue, "job_id": job_id})
    return 0


def _drain(args) -> int:
    with connect(args) as conn, conn.cursor() as cur:
        cur.execute("SELECT queue_reap_expired_leases()")
        reclaimed = cur.fetchone()[0]
    emit_record(args.format, {"reclaimed": reclaimed})
    return 0


def _retry(args) -> int:
    with connect(args) as conn, conn.cursor() as cur:
        cur.execute(
            """
            UPDATE malu$queue_job
               SET status = 'pending', visible_at = now(),
                   last_state_change_at = now(), attempts = 0, last_error = NULL
             WHERE job_id = %s AND status = 'dead'
            RETURNING job_id, queue_id
            """,
            (args.job_id,),
        )
        row = cur.fetchone()
    if not row:
        emit_record(args.format, {"job_id": args.job_id, "error": "not_in_dead_state"})
        return 65
    emit_record(args.format, {"job_id": row[0], "queue_id": row[1], "status": "pending"})
    return 0
