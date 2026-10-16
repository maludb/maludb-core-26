"""`maludb chatindex` — V4-CLI-01 ChatIndex subcommand family.

Drives the SQL surface (`source_package_promote_to_chat_index`,
`chat_index_append_messages`, `chatindex_list_trees`,
`retrieve_with_envelope_chat_tree`).
"""

from __future__ import annotations

import json
from pathlib import Path

from ..db import connect
from ..output import emit_record, emit_table


def register(sub) -> None:
    p = sub.add_parser("chatindex", help="V4 ChatIndex tree operations.")
    p_sub = p.add_subparsers(dest="chatindex_cmd", required=True,
                             metavar="<chatindex-cmd>")

    b = p_sub.add_parser("build",
        help="Promote a chat-transcript Source Package to a ChatIndex tree.")
    b.add_argument("--source-package-id", type=int, required=True)
    b.add_argument("--model-alias-id",    type=int, default=None)
    b.add_argument("--prompt-template-id", type=int, default=None)
    b.add_argument("--max-children",      type=int, default=10)
    b.add_argument("--builder-options",   default="{}")
    b.set_defaults(handler=_build)

    ap = p_sub.add_parser("append",
        help="Append messages from a JSONL file (one message object per line).")
    ap.add_argument("--tree-id",        type=int, required=True)
    ap.add_argument("--messages-jsonl", required=True,
        help='JSONL file. Each line: {"message_index":N, "user_message":..., '
             '"assistant_message":..., "topic_branch":{"new":"X"} (optional)}.')
    ap.set_defaults(handler=_append)

    ak = p_sub.add_parser("ask",
        help="Descend a chat tree to answer a query.")
    ak.add_argument("--tree-id",   type=int, required=True)
    ak.add_argument("--query",     required=True)
    ak.add_argument("--max-depth", type=int, default=6)
    ak.add_argument("--choice", default="overlap",
                    choices=("overlap", "first"))
    ak.set_defaults(handler=_ask)

    ls = p_sub.add_parser("list", help="List ChatIndex trees.")
    ls.add_argument("--build-status", default=None,
                    choices=("pending", "building", "ready", "stale",
                             "superseded", "failed"))
    ls.add_argument("--limit", type=int, default=50)
    ls.set_defaults(handler=_list)


def _build(args) -> int:
    opts = json.loads(args.builder_options)
    with connect(args) as conn, conn.cursor() as cur:
        cur.execute(
            "SELECT source_package_promote_to_chat_index(%s, %s, %s, %s, %s::jsonb)",
            (args.source_package_id, args.model_alias_id,
             args.prompt_template_id, args.max_children,
             json.dumps(opts)),
        )
        tree_id = cur.fetchone()[0]
    emit_record(args.format, {
        "tree_id": tree_id,
        "source_package_id": args.source_package_id,
        "build_status": "pending",
    })
    return 0


def _append(args) -> int:
    path = Path(args.messages_jsonl)
    if not path.is_file():
        print(f"messages JSONL file not found: {path}", flush=True)
        return 1
    messages = []
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line:
            messages.append(json.loads(line))
    if not messages:
        print("no messages in JSONL", flush=True)
        return 1

    with connect(args) as conn, conn.cursor() as cur:
        cur.execute(
            "SELECT * FROM chat_index_append_messages(%s, %s::jsonb)",
            (args.tree_id, json.dumps(messages)),
        )
        rows = cur.fetchall()
        cols = [d.name for d in cur.description]
    emit_table(args.format, cols, rows)
    return 0


def _ask(args) -> int:
    opts = {"max_depth": args.max_depth, "choice": args.choice}
    with connect(args) as conn, conn.cursor() as cur:
        cur.execute(
            "SELECT * FROM retrieve_with_envelope_chat_tree(%s, %s, %s::jsonb, %s)",
            (args.query, args.tree_id, json.dumps(opts), 1),
        )
        row = cur.fetchone()
        cols = [d.name for d in cur.description]
    if row is None:
        print("no descent result", flush=True)
        return 1
    emit_record(args.format, dict(zip(cols, row)))
    return 0


def _list(args) -> int:
    with connect(args) as conn, conn.cursor() as cur:
        cur.execute(
            "SELECT * FROM chatindex_list_trees(%s, %s)",
            (args.build_status, args.limit),
        )
        rows = cur.fetchall()
        cols = [d.name for d in cur.description]
    emit_table(args.format, cols, rows)
    return 0
