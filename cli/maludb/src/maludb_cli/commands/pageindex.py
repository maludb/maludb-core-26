"""`maludb pageindex` — V4-CLI-01 PageIndex subcommand family.

Drives the SQL surface (`source_package_promote_to_page_index`,
`pageindex_list_trees`, `pageindex_get_tree`,
`retrieve_with_envelope_tree`, `page_index_tree_supersede`) so
operators don't have to drop into psql for routine ops.
"""

from __future__ import annotations

import json

from ..db import connect
from ..output import emit_record, emit_table


def register(sub) -> None:
    p = sub.add_parser("pageindex", help="V4 PageIndex tree operations.")
    p_sub = p.add_subparsers(dest="pageindex_cmd", required=True,
                             metavar="<pageindex-cmd>")

    b = p_sub.add_parser("build",
        help="Promote a Source Package to a PageIndex tree (queues builder).")
    b.add_argument("--source-package-id", type=int, required=True)
    b.add_argument("--parser", default="pdf",
                   choices=("pdf", "markdown", "plain_text"))
    b.add_argument("--model-alias-id", type=int, default=None)
    b.add_argument("--prompt-template-id", type=int, default=None)
    b.add_argument("--builder-options", default="{}",
                   help='JSON dict, e.g. \'{"max_depth": 6}\'')
    b.set_defaults(handler=_build)

    ls = p_sub.add_parser("list", help="List PageIndex trees.")
    ls.add_argument("--build-status", default=None,
                    choices=("pending", "building", "ready", "stale",
                             "superseded", "failed"))
    ls.add_argument("--limit", type=int, default=50)
    ls.set_defaults(handler=_list)

    sh = p_sub.add_parser("show", help="Show a single tree row.")
    sh.add_argument("--tree-id", type=int, required=True)
    sh.set_defaults(handler=_show)

    ak = p_sub.add_parser("ask",
        help="Descend a tree to answer a query; emits envelope_id + leaf.")
    ak.add_argument("--tree-id", type=int, required=True)
    ak.add_argument("--query",   required=True)
    ak.add_argument("--max-depth", type=int, default=6)
    ak.add_argument("--choice", default="overlap",
                    choices=("overlap", "first"))
    ak.set_defaults(handler=_ask)

    sp = p_sub.add_parser("supersede",
        help="Mark a tree superseded by a new tree; writes a 'supersedes' edge.")
    sp.add_argument("--prior-tree-id", type=int, required=True)
    sp.add_argument("--new-tree-id",   type=int, required=True)
    sp.set_defaults(handler=_supersede)


def _build(args) -> int:
    opts = json.loads(args.builder_options)
    with connect(args) as conn, conn.cursor() as cur:
        cur.execute(
            "SELECT source_package_promote_to_page_index(%s, %s, %s, %s, %s::jsonb)",
            (args.source_package_id, args.parser,
             args.model_alias_id, args.prompt_template_id,
             json.dumps(opts)),
        )
        tree_id = cur.fetchone()[0]
    emit_record(args.format, {
        "tree_id": tree_id,
        "source_package_id": args.source_package_id,
        "parser_kind": args.parser,
        "build_status": "pending",
    })
    return 0


def _list(args) -> int:
    with connect(args) as conn, conn.cursor() as cur:
        cur.execute(
            "SELECT * FROM pageindex_list_trees(%s, %s)",
            (args.build_status, args.limit),
        )
        rows = cur.fetchall()
        cols = [d.name for d in cur.description]
    emit_table(args.format, cols, rows)
    return 0


def _show(args) -> int:
    with connect(args) as conn, conn.cursor() as cur:
        cur.execute("SELECT * FROM pageindex_get_tree(%s)", (args.tree_id,))
        row = cur.fetchone()
        if row is None:
            print(f"tree_id={args.tree_id} not found", flush=True)
            return 1
        cols = [d.name for d in cur.description]
    emit_record(args.format, dict(zip(cols, row)))
    return 0


def _ask(args) -> int:
    opts = {"max_depth": args.max_depth, "choice": args.choice}
    with connect(args) as conn, conn.cursor() as cur:
        cur.execute(
            "SELECT * FROM retrieve_with_envelope_tree(%s, %s, %s::jsonb, %s)",
            (args.query, args.tree_id, json.dumps(opts), 1),
        )
        row = cur.fetchone()
        cols = [d.name for d in cur.description]
    if row is None:
        print("no descent result", flush=True)
        return 1
    emit_record(args.format, dict(zip(cols, row)))
    return 0


def _supersede(args) -> int:
    with connect(args) as conn, conn.cursor() as cur:
        cur.execute(
            "SELECT page_index_tree_supersede(%s, %s)",
            (args.prior_tree_id, args.new_tree_id),
        )
        edge_id = cur.fetchone()[0]
    emit_record(args.format, {
        "prior_tree_id": args.prior_tree_id,
        "new_tree_id":   args.new_tree_id,
        "edge_id":       edge_id,
    })
    return 0
