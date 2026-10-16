# `maludb_mc2dbd` service contract

This document describes the wire and database contract for
`maludb_mc2dbd`, the C sidecar that exposes MaluDB as an MCP-compatible
HTTP listener. It is the production peer of the in-database
`mc2db.put_object` / `_begin_request` / `_end_request` plumbing that
shipped in R1.0-6 — any binary that honors this contract is
behaviorally substitutable.

R1.0 ships the binary and the `sql_function` dispatch path. The other
three implementation types (`external_exec`, `mcp_proxy`,
`http_endpoint`) are catalog-modeled and rejected at call time with
`IMPL_TYPE_NOT_AVAILABLE`. R1.1-1/2/3 fill them in.

## Roles

| Actor | Role |
|---|---|
| MCP client (LLM agent, Claude Desktop, custom tool) | Speaks MCP JSON-RPC 2.0 over HTTP/HTTPS. |
| `maludb_mc2dbd` (this service) | Terminates HTTP, parses JSON-RPC, looks up tools in the catalog, dispatches, returns MCP-shaped results. |
| PostgreSQL + `maludb_core` extension | Owns the tool registry (`malu$mc2db_tool` and per-type companion tables), the active-request context, and the invocation audit. |
| Stored procedures registered as tools | Run `SECURITY INVOKER` under the listener's PG role. Emit results via `mc2db.put_object` / `put_text` / `put_error`. |

## Network surface

```
HTTP[S] POST  /  or  /mcp
Content-Type: application/json
Authorization: Bearer <TOKEN>          (when configured)
X-MaluDB-User: <agent or account>      (optional; recorded in audit)
Body: JSON-RPC 2.0 request
```

```
GET  /healthz                          → "ok\n"
```

The listener also accepts `POST /mcp` so clients that prefer a
namespaced path can route via that. `/` is canonical.

## MCP methods

### `initialize`

```jsonc
// request
{"jsonrpc":"2.0","id":1,"method":"initialize",
 "params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{...}}}
// response
{"jsonrpc":"2.0","id":1,
 "result":{
   "protocolVersion":"2025-11-25",
   "capabilities":{"tools":{"listChanged":false}},
   "serverInfo":{"name":"maludb_mc2dbd","version":"0.1.0"}}}
```

### `tools/list`

Reads `maludb_core.malu$mc2db_tool` filtered by `enabled = true` and any
applicable account/role policy (R1.0 implements no per-account ACL;
that lands in R1.1-7). All implementation types appear in the result so
callers can see the registry; deferred types simply error at call time.

```jsonc
// response (one tool per row)
{
  "name": "maludb.health",
  "title": "...",
  "description": "...",
  "inputSchema": { ... },
  "outputSchema": { ... },
  "_meta": { "implementation_type": "sql_function", "tool_id": 42 }
}
```

`_meta.implementation_type` is MaluDB-specific and lets clients render
"deferred type" badges in UI.

### `tools/call`

```jsonc
// request
{"jsonrpc":"2.0","id":3,"method":"tools/call",
 "params":{"name":"<tool name>","arguments":{ ... }}}
```

Dispatch flow inside the listener:

1. Look up the tool in `malu$mc2db_tool` (joined to per-type companion).
2. If not found / disabled → tool-execution error `TOOL_NOT_FOUND` /
   `TOOL_DISABLED`. Audit row written with `success=false`.
3. Generate a v4 UUID `call_id`.
4. Switch on `implementation_type`:
   - **`sql_function`**: open a TX; pin `search_path`; call
     `mc2db._begin_request(call_id, tool_name)`; execute the registered
     function as `func(args jsonb, context jsonb)`; call
     `mc2db._end_request()` to drain the response context; COMMIT.
     Tools MUST use the two-arg signature — there is no longer a
     dynamic arity fallback. Any error from the SQL call (permission
     denied, missing function, runtime exception) surfaces directly
     as a `TOOL_EXECUTION_ERROR` rather than being masked behind
     a secondary "current transaction is aborted" (a real R1.0-10
     bug, fixed at v1.0.0-rc1).
   - **`external_exec` / `mcp_proxy` / `http_endpoint`**: return tool
     execution error `IMPL_TYPE_NOT_AVAILABLE` with a user-safe message.
5. Compose the MCP result from the captured `payload` (preferred) or
   `text_blocks`. If the tool wrote `isError=true` via
   `mc2db.put_error`, the result echoes that flag.
6. Always write a row to `malu$mc2db_invocation` carrying:
   `call_id`, `tool_id`, `tool_name`, `implementation_type`,
   `request_user`, `database_role`, `success`, `error_code`,
   `error_message`, `started_at`, `finished_at`, `duration_ms`. Reserved
   columns `external_exit_code` and `external_stderr` stay NULL in
   R1.0; R1.1-1 starts populating them for the `external_exec` path.

```jsonc
// success response
{"jsonrpc":"2.0","id":3,"result":{
  "content":[{"type":"text","text":"..."}],
  "structuredContent":{ ... },
  "isError":false,
  "_meta":{"call_id":"<uuid>"}}}
```

```jsonc
// tool error response (deferred type, NOT a protocol error)
{"jsonrpc":"2.0","id":3,"result":{
  "content":[{"type":"text","text":"implementation_type 'external_exec' is registered but not dispatched in R1.0"}],
  "isError":true,
  "_meta":{"call_id":"<uuid>","error_code":"IMPL_TYPE_NOT_AVAILABLE"}}}
```

### `ping`

Returns `result: {}`. Useful for health checks at the JSON-RPC layer.

## Protocol errors vs tool errors

| Class | Where it lives in the response | Examples |
|---|---|---|
| **Protocol error** | top-level `error: {code, message}` | parse error (`-32700`), invalid request (`-32600`), method not found (`-32601`), invalid params (`-32602`), internal (`-32603`) |
| **Tool error** | `result.isError = true` plus `_meta.error_code` | `TOOL_NOT_FOUND`, `TOOL_DISABLED`, `IMPL_TYPE_NOT_AVAILABLE`, `BAD_INPUT`, `TOOL_EXECUTION_ERROR`, `INTERNAL_ERROR` |

Tool errors always produce an audit row; protocol errors do not.

## SQL contract for tool implementations

Tool functions registered with `implementation_type = 'sql_function'`
SHOULD use this preferred signature:

```sql
CREATE PROCEDURE app.my_tool(args jsonb, context jsonb)
LANGUAGE plpgsql
SECURITY INVOKER
AS $body$
BEGIN
  CALL mc2db.put_object(jsonb_build_object(
    'content', jsonb_build_array(
      jsonb_build_object('type','text','text','hello')),
    'structuredContent', jsonb_build_object(...),
    'isError', false));
END;
$body$;
```

The two-arg shape is REQUIRED — `context` carries the `call_id` and
is where R1.1-7 will pass account/agent identity, locale, and pool
information. Tools that don't need any input still take both args:
they simply ignore them. Earlier R1.0-7 builds accepted one-arg and
zero-arg shapes via a dynamic fallback, but the heuristic that drove
the fallback masked permission errors as "current transaction is
aborted" — fixed at v1.0.0-rc1 by requiring the canonical signature.

## Database role

`maludb_mc2dbd` connects to PostgreSQL with one role configured at
startup (`PG_CONNINFO`). That role MUST NOT be a superuser. The role
needs:

- USAGE on schemas `mc2db` and `maludb_core`.
- SELECT on `maludb_core.malu$mc2db_tool` and the four companion
  tables.
- EXECUTE on `mc2db._begin_request`, `mc2db._end_request`,
  `mc2db.put_object`, `mc2db.put_text`, `mc2db.put_error`,
  `mc2db.flush`.
- INSERT on `maludb_core.malu$mc2db_invocation`.
- EXECUTE on every registered tool's function (granted at
  registration time or via a role inheritance scheme).

The R1.0 setup assumes a single role for the whole listener; per-account
session mapping comes in R1.1-7.

## Authorization-filtered discovery (R1.0 → R1.1)

R1.0 returns every enabled tool to every authorized client. R1.1-7 will
extend `tools/list` to filter by:

- `malu$mc2db_tool.required_privileges` matched against the client's
  account roles,
- per-tool grants in `malu$mc2db_tool_grant` (R1.1-7 introduces),
- delegated-agent chain when one is set in the client's MCP request
  metadata.

## Lifecycle

- Startup: parse args / env, probe PG, start MHD, log "ready".
- Steady state: each HTTP request opens a libpq connection, runs a
  bounded amount of SQL, closes it. R1.0 does not pool connections.
- SIGTERM / SIGINT: drain in-flight requests via
  `MHD_stop_daemon`, exit 0.

## What lives outside this contract

- The shape of any individual tool's input / output schema. That's
  per-tool and recorded in `malu$mc2db_tool.input_schema` /
  `output_schema`.
- The deferred dispatcher contracts (external_exec runner with
  execve+stdin-JSON, mcp_proxy with transport-specific forwarding,
  http_endpoint). Those will be peer documents to this one when
  R1.1-1/2/3 ship.
- Streamable HTTP, server-sent events, MCP `prompts/*` and
  `resources/*` discovery, prompt argument auto-completion. Out of R1.0
  scope.
