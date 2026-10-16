"""`maludb replay` — Stage 5 episode replay entrypoint."""

from __future__ import annotations

import json
import sys

from ..db import connect


def register(sub) -> None:
    p = sub.add_parser("replay", help="Replay an Episode Object under a chosen temporal mode.")
    p.add_argument("--episode-id", type=int, required=True)
    p.add_argument("--mode",
        choices=("current_valid", "historical_valid", "as_of_transaction_time", "full_bitemporal"),
        default="current_valid")
    p.add_argument("--as-of", default=None, help="ISO timestamp for as_of_transaction_time.")
    p.set_defaults(handler=_handler)


def _handler(args) -> int:
    with connect(args) as conn, conn.cursor() as cur:
        cur.execute("SELECT replay_episode(%s, %s, %s::timestamptz)",
                    (args.episode_id, args.mode, args.as_of))
        row = cur.fetchone()
    payload = row[0] if row else None
    if args.format == "json":
        json.dump(payload, sys.stdout, default=str, indent=2)
        sys.stdout.write("\n")
    else:
        print(json.dumps(payload, default=str, indent=2))
    return 0
