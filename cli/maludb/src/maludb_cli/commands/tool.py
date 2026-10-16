"""`maludb tool list|call|register` — MC2DB tool catalog."""

from __future__ import annotations

import json

from ..db import connect
from ..output import emit_record, emit_table


def register(sub) -> None:
    p = sub.add_parser("tool", help="MC2DB tool catalog.")
    p_sub = p.add_subparsers(dest="tool_cmd", required=True, metavar="<tool-cmd>")

    ls = p_sub.add_parser("list", help="List registered MC2DB tools.")
    ls.add_argument("--server", default=None, help="Filter by server_name.")
    ls.set_defaults(handler=_list)

    cl = p_sub.add_parser("call", help="Invoke an MC2DB tool by name (catalog dispatch).")
    cl.add_argument("--tool",  required=True)
    cl.add_argument("--args",  default="{}", help="JSON object passed to the tool (default '{}').")
    cl.set_defaults(handler=_call)

    rg = p_sub.add_parser("register", help="Register a SQL-function-backed tool.")
    rg.add_argument("--server",          required=True)
    rg.add_argument("--name",            required=True)
    rg.add_argument("--description",     required=True)
    rg.add_argument("--function",        required=True, help="SQL function reference, e.g. maludb_core.retrieve(text,integer).")
    rg.add_argument("--risk-class",      default="read_only",
        choices=("read_only", "evidence_producing", "state_changing", "external_effect", "administrative"))
    rg.add_argument("--input-schema",    default="{}")
    rg.add_argument("--output-schema",   default=None)
    rg.set_defaults(handler=_register)


def _list(args) -> int:
    with connect(args) as conn, conn.cursor() as cur:
        if args.server:
            cur.execute("""
                SELECT t.tool_id, s.server_name, t.tool_name, t.implementation_type,
                       t.risk_class, t.read_only, t.timeout_ms
                  FROM malu$mc2db_tool t
                  JOIN malu$mc2db_server s ON s.server_id = t.server_id
                 WHERE s.server_name = %s
                 ORDER BY t.tool_name
            """, (args.server,))
        else:
            cur.execute("""
                SELECT t.tool_id, s.server_name, t.tool_name, t.implementation_type,
                       t.risk_class, t.read_only, t.timeout_ms
                  FROM malu$mc2db_tool t
                  JOIN malu$mc2db_server s ON s.server_id = t.server_id
                 ORDER BY s.server_name, t.tool_name
            """)
        rows = cur.fetchall()
    emit_table(args.format,
        ("tool_id", "server", "tool_name", "implementation_type", "risk_class", "read_only", "timeout_ms"),
        rows)
    return 0


def _call(args) -> int:
    """Synchronous tool call against the catalog. v0.1.0 supports
    sql_function tools by reading the registered function_signature
    and invoking it; non-sql_function tools route through the running
    mc2dbd (out of scope for this in-process helper). Operators who
    need the full MCP-shaped call should curl the mc2dbd listener.
    """
    try:
        call_args = json.loads(args.args)
    except json.JSONDecodeError as e:
        emit_record(args.format, {"error": f"invalid --args JSON: {e}"})
        return 64

    with connect(args) as conn, conn.cursor() as cur:
        cur.execute("""
            SELECT t.implementation_type, sf.function_signature
              FROM malu$mc2db_tool t
              LEFT JOIN malu$mc2db_tool_sql_function sf ON sf.tool_id = t.tool_id
             WHERE t.tool_name = %s
             ORDER BY t.tool_id DESC
             LIMIT 1
        """, (args.tool,))
        row = cur.fetchone()
        if not row:
            emit_record(args.format, {"tool": args.tool, "error": "tool_not_found"})
            return 65
        impl, fnsig = row
        if impl != "sql_function":
            emit_record(args.format, {
                "tool":  args.tool,
                "error": f"impl_type_{impl}_requires_mc2dbd",
                "hint":  "POST a tools/call against the maludb_mc2dbd listener for non-SQL tool kinds.",
            })
            return 70
        # SQL function signature looks like `schema.fn(arg_t1,arg_t2)`.
        # For the alpha, the CLI only supports zero-arg SQL tools; an
        # argument-marshalling pass lands with V3-API-01b's typed routes.
        if "()" not in fnsig and fnsig.endswith(")"):
            emit_record(args.format, {
                "tool":  args.tool,
                "error": "non_zero_arg_sql_tool_not_yet_supported",
                "hint":  "CLI typed-arg marshalling is a Stage 10 follow-up.",
            })
            return 70
        cur.execute(f"SELECT {fnsig.split('(')[0]}()")
        result = cur.fetchone()
        cols   = [d.name for d in cur.description]
    emit_record(args.format, {"tool": args.tool, "result": dict(zip(cols, result))})
    return 0


def _register(args) -> int:
    out_schema = "NULL::jsonb" if args.output_schema is None else "%(out)s::jsonb"
    sql = (
        "SELECT mc2db.register_tool("
        "  server_name => %(server)s,"
        "  tool_name => %(name)s,"
        "  description => %(description)s,"
        "  implementation_type => 'sql_function',"
        f"  input_schema => %(in)s::jsonb,"
        f"  output_schema => {out_schema},"
        "  risk_class => %(risk)s,"
        "  impl_metadata => jsonb_build_object('function_signature', %(fn)s::regprocedure::text)"
        ")"
    )
    params = {
        "server":      args.server,
        "name":        args.name,
        "description": args.description,
        "in":          args.input_schema,
        "risk":        args.risk_class,
        "fn":          args.function,
    }
    if args.output_schema is not None:
        params["out"] = args.output_schema
    with connect(args) as conn, conn.cursor() as cur:
        cur.execute(sql, params)
        tid = cur.fetchone()[0]
    emit_record(args.format, {"tool_id": tid, "tool_name": args.name, "server": args.server})
    return 0
