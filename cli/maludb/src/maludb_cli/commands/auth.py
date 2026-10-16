"""`maludb auth token create|list|revoke` — V3-AUTH-01 wiring."""

from __future__ import annotations

from ..db import connect
from ..output import emit_record, emit_table


def register(sub) -> None:
    p = sub.add_parser("auth", help="Authentication and token management.")
    p_sub = p.add_subparsers(dest="auth_cmd", required=True, metavar="<auth-cmd>")

    p_tok = p_sub.add_parser("token", help="Manage API tokens (malu$auth_token).")
    p_tok_sub = p_tok.add_subparsers(dest="auth_token_cmd", required=True, metavar="<token-cmd>")

    cr = p_tok_sub.add_parser("create", help="Issue a new token; plaintext is returned ONCE.")
    cr.add_argument("--account-id",  type=int, required=True)
    cr.add_argument("--kind",        choices=("personal", "service"), default="service")
    cr.add_argument("--label",       default=None)
    cr.add_argument("--scope",       action="append", default=[])
    cr.add_argument("--cidr",        action="append", default=[], help="Allowed CIDR; repeatable.")
    cr.add_argument("--expires-at",  default=None, help="ISO timestamp (optional).")
    cr.set_defaults(handler=_create)

    ls = p_tok_sub.add_parser("list", help="List tokens visible to the current account.")
    ls.add_argument("--account-id", type=int, default=None, help="Filter by account (admin-only).")
    ls.set_defaults(handler=_list)

    rv = p_tok_sub.add_parser("revoke", help="Revoke a token by token_id.")
    rv.add_argument("--token-id", type=int, required=True)
    rv.add_argument("--reason",   default=None)
    rv.set_defaults(handler=_revoke)


def _create(args) -> int:
    with connect(args) as conn, conn.cursor() as cur:
        cur.execute(
            """
            SELECT token_id, plaintext_token
              FROM auth_token_create(%s, %s, %s, %s::text[], %s::inet[], %s)
            """,
            (args.account_id, args.kind, args.label,
             args.scope or [], args.cidr or None, args.expires_at),
        )
        tid, plaintext = cur.fetchone()
    emit_record(args.format, {
        "token_id":         tid,
        "plaintext_token":  plaintext,
        "warning":          "Plaintext is returned once. Store it now.",
    })
    return 0


def _list(args) -> int:
    with connect(args) as conn, conn.cursor() as cur:
        if args.account_id is not None:
            cur.execute(
                """
                SELECT token_id, account_id, token_kind, label, scopes,
                       created_at, expires_at, last_used_at, revoked_at
                  FROM malu$auth_token
                 WHERE account_id = %s
                 ORDER BY token_id
                """,
                (args.account_id,),
            )
        else:
            cur.execute(
                """
                SELECT token_id, account_id, token_kind, label, scopes,
                       created_at, expires_at, last_used_at, revoked_at
                  FROM malu$auth_token
                 ORDER BY token_id
                """,
            )
        rows = cur.fetchall()
    emit_table(
        args.format,
        ("token_id", "account_id", "kind", "label", "scopes",
         "created_at", "expires_at", "last_used_at", "revoked_at"),
        rows,
    )
    return 0


def _revoke(args) -> int:
    with connect(args) as conn, conn.cursor() as cur:
        cur.execute(
            "SELECT auth_token_revoke(%s, %s)",
            (args.token_id, args.reason),
        )
        was_active = cur.fetchone()[0]
    emit_record(args.format, {"token_id": args.token_id, "was_active": was_active})
    return 0
