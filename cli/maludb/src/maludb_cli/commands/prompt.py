"""`maludb prompt list|render`."""

from __future__ import annotations

import json

from ..db import connect
from ..output import emit_record, emit_table


def register(sub) -> None:
    p = sub.add_parser("prompt", help="Prompt template catalog and rendering.")
    p_sub = p.add_subparsers(dest="prompt_cmd", required=True, metavar="<prompt-cmd>")

    ls = p_sub.add_parser("list", help="List prompt templates.")
    ls.set_defaults(handler=_list)

    rd = p_sub.add_parser("render", help="Render a template against a variable map.")
    rd.add_argument("--name",       required=True)
    rd.add_argument("--version",    type=int, default=None)
    rd.add_argument("--variables",  default="{}", help="JSON object of template variables (default '{}').")
    rd.add_argument("--preview", action="store_true", help="Dry-run via preview_prompt (no malu$prompt_render INSERT).")
    rd.set_defaults(handler=_render)


def _list(args) -> int:
    with connect(args) as conn, conn.cursor() as cur:
        cur.execute("""
            SELECT template_id, template_name, template_version,
                   owner_account_id, enabled
              FROM malu$prompt_template
             ORDER BY template_name, template_version
        """)
        rows = cur.fetchall()
    emit_table(args.format,
        ("id", "name", "version", "owner_account_id", "enabled"),
        rows)
    return 0


def _render(args) -> int:
    try:
        variables = json.loads(args.variables)
    except json.JSONDecodeError as e:
        emit_record(args.format, {"error": f"invalid --variables JSON: {e}"})
        return 64
    fn = "preview_prompt" if args.preview else "render_prompt"
    with connect(args) as conn, conn.cursor() as cur:
        cur.execute(f"SELECT * FROM {fn}(%s, %s, %s::jsonb)",
                    (args.name, args.version, json.dumps(variables)))
        row = cur.fetchone()
        cols = [d.name for d in cur.description]
    emit_record(args.format, dict(zip(cols, row)))
    return 0
