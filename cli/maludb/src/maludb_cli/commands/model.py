"""`maludb model list|register|probe`."""

from __future__ import annotations

from ..db import connect
from ..output import emit_record, emit_table


def register(sub) -> None:
    p = sub.add_parser("model", help="Model alias and provider catalog (Stage 1.5+).")
    p_sub = p.add_subparsers(dest="model_cmd", required=True, metavar="<model-cmd>")

    ls = p_sub.add_parser("list", help="List configured model aliases.")
    ls.set_defaults(handler=_list)

    rg = p_sub.add_parser("register", help="Register a model alias against an existing provider.")
    rg.add_argument("--alias",            required=True)
    rg.add_argument("--provider",         required=True)
    rg.add_argument("--model-identifier", required=True)
    rg.add_argument("--model-path",       default=None)
    rg.add_argument("--model-hash",       default=None)
    rg.add_argument("--quantization",     default=None)
    rg.add_argument("--context-length",   type=int, default=None)
    rg.set_defaults(handler=_register)

    pb = p_sub.add_parser("probe", help="Probe an alias for availability (best-effort; full probe is V3-OBS-01).")
    pb.add_argument("--alias", required=True)
    pb.set_defaults(handler=_probe)


def _list(args) -> int:
    with connect(args) as conn, conn.cursor() as cur:
        cur.execute("""
            SELECT a.alias_id, a.alias_name AS alias, p.provider_name, a.model_identifier,
                   a.quantization, a.context_length, a.enabled
              FROM malu$model_alias a
              JOIN malu$model_provider p ON p.provider_id = a.provider_id
             ORDER BY a.alias_name
        """)
        rows = cur.fetchall()
    emit_table(args.format,
        ("alias_id", "alias", "provider", "model_identifier", "quantization", "context_length", "enabled"),
        rows)
    return 0


def _register(args) -> int:
    with connect(args) as conn, conn.cursor() as cur:
        cur.execute("""
            SELECT register_model_alias(%s, %s, %s, %s, %s, %s, %s)
        """, (args.alias, args.provider, args.model_identifier,
              args.model_path, args.model_hash, args.quantization,
              args.context_length))
        alias_id = cur.fetchone()[0]
    emit_record(args.format, {"alias": args.alias, "alias_id": alias_id})
    return 0


def _probe(args) -> int:
    with connect(args) as conn, conn.cursor() as cur:
        cur.execute("""
            SELECT a.alias_name AS alias, p.provider_name, p.provider_kind, a.enabled, a.context_length
              FROM malu$model_alias a
              JOIN malu$model_provider p ON p.provider_id = a.provider_id
             WHERE a.alias_name = %s
        """, (args.alias,))
        row = cur.fetchone()
    if not row:
        emit_record(args.format, {"alias": args.alias, "error": "alias_not_found"})
        return 65
    emit_record(args.format, {
        "alias":         row[0],
        "provider":      row[1],
        "provider_kind": row[2],
        "enabled":       row[3],
        "context_length": row[4],
        "probe":         "catalog-only (full probe ships with V3-OBS-01)",
    })
    return 0
