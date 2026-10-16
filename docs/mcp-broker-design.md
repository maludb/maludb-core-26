# MaluDB external MCP broker — design

Per `requirements.md` §9 Stage 6: "External MCP broker / reference
implementation for non-database tools."

The existing `mc2dbd` listener handles MCP for *database* tools —
anything that resolves to a `malu$mc2db_tool` row, dispatched
through one of the four `implementation_type` paths (`sql_function`,
`external_exec`, `mcp_proxy`, `http_endpoint`). The **external MCP
broker** is a sibling process that exposes *non-database* tools to
the same MCP clients without bloating the database catalog.

This document defines the v1 contract; the reference implementation
lives in `services/mcp-broker/`.

## Motivation

Some tools don't belong in `malu$mc2db_tool`:

- **Shell commands** with arguments substituted from MCP input
  (e.g. `kubectl get pods -n {namespace}`). Putting these in
  `malu$mc2db_tool_external_exec` works, but the dispatcher runs
  inside the MaluDB-owned listener process, which means the
  `kubectl` binary, its kubeconfig, and any required network access
  live alongside the database. That's the wrong blast radius for a
  tool an operator might restart hourly.
- **HTTP endpoints to external services** with bearer tokens or
  mTLS certs that should NOT be readable by the database role. The
  existing `mc2db_tool_http_endpoint` schema works but stores the
  auth token in the catalog; some operators want secrets to live
  only in the broker's own credential store.
- **MCP servers running elsewhere** that the operator wants to
  expose under their own MaluDB-scoped policy without forwarding
  every call through `mc2db_proxy`.

The broker is the place to put these. It runs under its own
identity, its own filesystem, its own outbound network policy, and
it talks back to MaluDB only through the standard
`malu$mc2db_invocation` audit path (via the maludb driver SDKs of
this repo).

## Architecture

```
┌──────────────┐        stdio MCP        ┌─────────────────┐
│  MCP client  │ <─────────────────────> │ mcp-broker      │
│  (LLM agent) │                         │ (this process)  │
└──────────────┘                         │                 │
                                         │  tool registry  │
                                         │     │           │
                                         │     ▼           │
                                         │ ┌──────────────┐│
                                         │ │ shell exec   ││ ──> /usr/bin/kubectl …
                                         │ │ http call    ││ ──> https://api.x/…
                                         │ │ mcp proxy    ││ ──> remote stdio MCP
                                         │ └──────────────┘│
                                         │                 │
                                         │  audit emitter  │ ──> stderr JSONL
                                         │     (v1)        │     stdout for newer:
                                         │                 │     PG INSERT via SDK
                                         └─────────────────┘
```

### Transport

v1 uses **stdio JSON-RPC** (the simplest MCP transport). The MCP
client (`claude-cli`, `mcp-cli`, `mc2dbd` acting as a downstream)
spawns the broker as a subprocess and exchanges JSON-RPC messages
on stdin / stdout. Each message is a single line — no chunked
encoding, no length-prefix framing — terminated by newline.

HTTPS/SSE transport is deferred to v2. The contract is identical;
only the I/O layer changes.

### Tool registry

A JSON config file at `MCP_BROKER_CONFIG` (default
`/etc/maludb/mcp-broker.json`) declares every tool:

```json
{
  "tools": [
    {
      "name": "shell.kubectl_get_pods",
      "description": "Run kubectl get pods -n <namespace>",
      "kind": "shell",
      "input_schema": {
        "type": "object",
        "properties": {
          "namespace": {"type": "string"}
        },
        "required": ["namespace"]
      },
      "spec": {
        "argv": ["/usr/bin/kubectl", "get", "pods", "-n", "{{namespace}}"],
        "timeout_ms": 5000
      }
    }
  ]
}
```

`spec.argv` uses `{{name}}` substitution against the validated
input. Substitution is **literal-only** — no shell, no glob, no
operator chaining. The broker spawns the configured executable
directly via `subprocess.run` with `shell=False`.

### Identity + audit

The broker doesn't authenticate its caller in v1 — that's the
upstream MCP client's responsibility. It records every invocation
on stderr as a JSONL line:

```json
{"ts":"2026-05-13T15:42:01Z","tool":"shell.kubectl_get_pods","argv_hash":"sha256:…","exit":0,"duration_ms":221,"output_hash":"sha256:…"}
```

The mc2dbd listener can ingest these lines into
`malu$mc2db_invocation` via the maludb driver SDK in a follow-up;
the broker itself stays out of the PostgreSQL connection.

### Threat model

- Tool config is **trusted**: anyone with write access to
  `mcp-broker.json` can run arbitrary processes.
- Tool input is **untrusted**: the broker validates against
  `input_schema` before substituting, refuses unknown keys, and
  never passes input through a shell.
- Broker is **single-tenant**: the operator runs one broker per
  identity slice. Cross-tenant policy lives in the upstream MC2DB
  listener, not the broker.

## v1 scope

Implemented:
- stdio JSON-RPC transport
- `initialize` → returns capabilities (`tools.listChanged: false`)
- `tools/list` → returns the configured tool array
- `tools/call` → validates input, dispatches to `shell` kind
- shell kind with `{{var}}` substitution + per-tool timeout
- JSONL audit on stderr

Deferred to v2:
- `http` and `mcp_proxy` tool kinds
- HTTPS/SSE transport
- Live ingest into `malu$mc2db_invocation`
- mTLS to upstream MCP clients
- `tools.listChanged` notifications when config file is touched

## Wire-level contract (excerpt)

Initialize:

```
→ {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25"}}
← {"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-11-25","capabilities":{"tools":{"listChanged":false}},"serverInfo":{"name":"maludb-mcp-broker","version":"0.1.0"}}}
```

List:

```
→ {"jsonrpc":"2.0","id":2,"method":"tools/list"}
← {"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"shell.kubectl_get_pods","description":"…","inputSchema":{…}}]}}
```

Call:

```
→ {"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"shell.kubectl_get_pods","arguments":{"namespace":"prod"}}}
← {"jsonrpc":"2.0","id":3,"result":{"content":[{"type":"text","text":"<stdout>"}],"isError":false}}
```

On dispatch error (validation failure, exec failure, timeout) the
result carries `"isError":true` and a text content block describing
the failure. JSON-RPC error envelopes are reserved for **protocol**
errors (parse, method not found) — never tool errors.

## Acceptance criteria

The reference implementation in `services/mcp-broker/` MUST:

1. Pass the smoke test (`tests/test_smoke.py`): spawn the broker as
   a subprocess, send `initialize` + `tools/list` + a successful
   `tools/call` + a validation-failure `tools/call`, assert the
   wire shapes match the above.
2. Refuse `tools/call` for a name not in the config (returns
   `isError:true`, never crashes).
3. Refuse argv substitution from input fields that aren't in
   `input_schema.properties` (defence in depth).
4. Respect the per-tool `timeout_ms` and kill the subprocess on
   overrun.
5. Emit JSONL audit on stderr for every accepted `tools/call`.
