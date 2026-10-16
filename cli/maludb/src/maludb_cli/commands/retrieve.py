"""`maludb retrieve` — Stage 4 retrieval entrypoint."""

from __future__ import annotations

import json

from ..db import connect
from ..output import emit_table


def register(sub) -> None:
    p = sub.add_parser("retrieve", help="Hybrid retrieval over the memory catalog.")
    p.add_argument("--cue",          required=True, help="Free-text retrieval cue.")
    p.add_argument("--object-types", default=None, help="Comma-separated object_type filter.")
    p.add_argument("--limit",        type=int, default=20)
    p.add_argument("--hint",         default=None, help="Named query hint to apply.")
    p.add_argument("--valid-as-of",        default=None)
    p.add_argument("--transaction-as-of",  default=None)
    p.add_argument("--confidence-floor",   default=None)
    p.set_defaults(handler=_handler)


def _handler(args) -> int:
    types = [t.strip() for t in args.object_types.split(",")] if args.object_types else None
    confidence = float(args.confidence_floor) if args.confidence_floor else None
    with connect(args) as conn, conn.cursor() as cur:
        cur.execute(
            """
            SELECT *
              FROM execute_retrieval(
                  ROW(%s, %s::text[], %s::timestamptz, %s::timestamptz,
                      %s::numeric, %s::jsonb)::malu$retrieval_envelope_t,
                  %s, %s)
            """,
            (args.cue, types, args.valid_as_of, args.transaction_as_of,
             confidence, json.dumps({}), args.hint, args.limit),
        )
        rows = cur.fetchall()
        cols = [d.name for d in cur.description]
    emit_table(args.format, cols, rows)
    return 0
