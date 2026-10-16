"""`maludb env create|record-seed|promote-check|list` — V3-ENV-01 wiring."""

from __future__ import annotations

import json

from ..db import connect
from ..output import emit_record, emit_table


def register(sub) -> None:
    p = sub.add_parser("env", help="Self-hosted preview environments (V3-ENV-01).")
    p_sub = p.add_subparsers(dest="env_cmd", required=True, metavar="<env-cmd>")

    cr = p_sub.add_parser("create",
        help="Register a preview env. seed_policy defaults to {production_data: false}.")
    cr.add_argument("--name",            required=True)
    cr.add_argument("--base-migration",  required=True,
        help="Extension version this env is built against (e.g., 0.60.0).")
    cr.add_argument("--seed-policy",     default='{"production_data": false}',
        help="JSON. production_data must be false (V3-ENV-01 default).")
    cr.add_argument("--anonymizer-ref",  default=None,
        help="malu$secret name pointing to the anonymizer config.")
    cr.add_argument("--description",     default=None)
    cr.set_defaults(handler=_create)

    rs = p_sub.add_parser("record-seed",
        help="Record a seed import for a preview env.")
    rs.add_argument("--env-id",          type=int, required=True)
    rs.add_argument("--seed-kind",       required=True,
        choices=("sql_file", "csv_dir", "anonymized_dump", "synthetic"))
    rs.add_argument("--source-uri",      required=True)
    rs.add_argument("--redaction-rules", default="[]",
        help='JSON array. Each rule: {"path":"$.<jsonpath>","replace":"<value>"}.')
    rs.set_defaults(handler=_record_seed)

    pc = p_sub.add_parser("promote-check",
        help="Report the gate matrix for a preview env. Returns 0 only if all gates pass.")
    pc.add_argument("--env-id", type=int, required=True)
    pc.set_defaults(handler=_promote_check)

    ls = p_sub.add_parser("list", help="List preview envs.")
    ls.add_argument("--include-retired", action="store_true")
    ls.set_defaults(handler=_list)


def _create(args) -> int:
    seed_policy = json.loads(args.seed_policy)
    with connect(args) as conn, conn.cursor() as cur:
        cur.execute(
            "SELECT preview_env_create(%s, %s, %s, %s, %s)",
            (args.name, args.base_migration, json.dumps(seed_policy),
             args.anonymizer_ref, args.description),
        )
        env_id = cur.fetchone()[0]
    emit_record(args.format, {"name": args.name, "env_id": env_id,
                              "base_migration": args.base_migration})
    return 0


def _record_seed(args) -> int:
    with connect(args) as conn, conn.cursor() as cur:
        cur.execute(
            "SELECT preview_env_record_seed(%s, %s, %s, %s)",
            (args.env_id, args.seed_kind, args.source_uri, args.redaction_rules),
        )
        seed_id = cur.fetchone()[0]
    emit_record(args.format, {"env_id": args.env_id, "seed_id": seed_id,
                              "seed_kind": args.seed_kind})
    return 0


def _promote_check(args) -> int:
    with connect(args) as conn, conn.cursor() as cur:
        cur.execute(
            "SELECT gate, ok, detail FROM preview_env_promote_check(%s) ORDER BY gate",
            (args.env_id,),
        )
        rows = cur.fetchall()
    emit_table(args.format, ("gate", "ok", "detail"), rows)
    return 0 if all(r[1] for r in rows) else 65


def _list(args) -> int:
    with connect(args) as conn, conn.cursor() as cur:
        cur.execute(
            "SELECT env_id, name, base_migration, current_migration, seed_count, retired_at "
            "FROM preview_env_list(%s)",
            (args.include_retired,),
        )
        rows = cur.fetchall()
    emit_table(args.format,
        ("env_id", "name", "base_migration", "current_migration", "seed_count", "retired_at"),
        rows)
    return 0
