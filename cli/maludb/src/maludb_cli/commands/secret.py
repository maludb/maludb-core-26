"""`maludb secret set|get-metadata|rotate|revoke|set-external` — V3-SECRET-01 wiring."""

from __future__ import annotations

import sys

from ..db import connect
from ..output import emit_record


def register(sub) -> None:
    p = sub.add_parser("secret", help="Governed secret store (V3-SECRET-01).")
    p_sub = p.add_subparsers(dest="secret_cmd", required=True, metavar="<secret-cmd>")

    set_p = p_sub.add_parser("set", help="Store an inline (AES-encrypted) secret. Reads value from stdin or --value.")
    set_p.add_argument("--name",                 required=True)
    set_p.add_argument("--kind",                 default="other",
        choices=("provider", "tool", "broker", "storage", "log_drain", "backup", "other"))
    set_p.add_argument("--value",                default=None, help="Inline secret value; if omitted, read from stdin.")
    set_p.add_argument("--description",          default=None)
    set_p.add_argument("--rotation-policy-days", type=int, default=None)
    set_p.set_defaults(handler=_set)

    setx = p_sub.add_parser("set-external", help="Register an external reference (file:// / env:// / https://).")
    setx.add_argument("--name",                 required=True)
    setx.add_argument("--kind",                 default="other",
        choices=("provider", "tool", "broker", "storage", "log_drain", "backup", "other"))
    setx.add_argument("--ref",                  required=True)
    setx.add_argument("--description",          default=None)
    setx.add_argument("--rotation-policy-days", type=int, default=None)
    setx.set_defaults(handler=_set_external)

    gm = p_sub.add_parser("get-metadata", help="Print metadata for a secret (never returns the value).")
    gm.add_argument("--name", required=True)
    gm.set_defaults(handler=_get_metadata)

    rt = p_sub.add_parser("rotate", help="Rotate a secret — alias for `set` on an existing name.")
    rt.add_argument("--name",  required=True)
    rt.add_argument("--value", default=None, help="New secret value; if omitted, read from stdin.")
    rt.set_defaults(handler=_rotate)

    rv = p_sub.add_parser("revoke", help="Retire a secret and all of its versions.")
    rv.add_argument("--name",   required=True)
    rv.add_argument("--reason", default=None)
    rv.set_defaults(handler=_revoke)


def _read_value(args) -> str:
    if args.value is not None:
        return args.value
    if sys.stdin.isatty():
        raise RuntimeError("--value not provided and stdin is a TTY; pipe the value in or pass --value.")
    return sys.stdin.read().rstrip("\n")


def _set(args) -> int:
    val = _read_value(args)
    with connect(args) as conn, conn.cursor() as cur:
        cur.execute(
            """
            SELECT secret_id, secret_version_id, version
              FROM secret_set(%s, %s, %s, %s, %s)
            """,
            (args.name, args.kind, val, args.description, args.rotation_policy_days),
        )
        sid, vid, ver = cur.fetchone()
    emit_record(args.format, {"name": args.name, "secret_id": sid, "secret_version_id": vid, "version": ver, "mode": "inline"})
    return 0


def _set_external(args) -> int:
    with connect(args) as conn, conn.cursor() as cur:
        cur.execute(
            """
            SELECT secret_id, secret_version_id, version
              FROM secret_set_external(%s, %s, %s, %s, %s)
            """,
            (args.name, args.kind, args.ref, args.description, args.rotation_policy_days),
        )
        sid, vid, ver = cur.fetchone()
    emit_record(args.format, {"name": args.name, "secret_id": sid, "secret_version_id": vid, "version": ver, "mode": "external"})
    return 0


def _get_metadata(args) -> int:
    with connect(args) as conn, conn.cursor() as cur:
        cur.execute(
            """
            SELECT secret_id, name, kind, owner_schema, current_version, mode,
                   rotation_policy_days, last_used_at, created_at, retired_at
              FROM secret_get_metadata(%s)
            """,
            (args.name,),
        )
        row = cur.fetchone()
    if not row:
        emit_record(args.format, {"name": args.name, "error": "not_found"})
        return 65
    keys = ("secret_id", "name", "kind", "owner_schema", "current_version", "mode",
            "rotation_policy_days", "last_used_at", "created_at", "retired_at")
    emit_record(args.format, dict(zip(keys, row)))
    return 0


def _rotate(args) -> int:
    val = _read_value(args)
    with connect(args) as conn, conn.cursor() as cur:
        cur.execute("SELECT kind FROM malu$secret WHERE name = %s", (args.name,))
        row = cur.fetchone()
        if row is None:
            emit_record(args.format, {"name": args.name, "error": "not_found"})
            return 65
        kind = row[0]
        cur.execute(
            "SELECT secret_id, secret_version_id, version FROM secret_set(%s, %s, %s)",
            (args.name, kind, val),
        )
        sid, vid, ver = cur.fetchone()
    emit_record(args.format, {"name": args.name, "secret_id": sid, "secret_version_id": vid, "version": ver, "rotated_to": ver})
    return 0


def _revoke(args) -> int:
    with connect(args) as conn, conn.cursor() as cur:
        cur.execute("SELECT secret_revoke(%s, %s)", (args.name, args.reason))
        was_active = cur.fetchone()[0]
    emit_record(args.format, {"name": args.name, "was_active": was_active})
    return 0
