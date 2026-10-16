# `maludb-mcp-broker` — external MCP broker

Stdlib-only Python service that proxies non-database tools to MCP
clients via stdio JSON-RPC. Designed to run alongside the `mc2dbd`
listener so the database stays out of the path for tools that
shouldn't go through SQL.

Status: **alpha, reference implementation.** v0.1.0 supports
`shell` tool kind only over stdio transport. See
[docs/mcp-broker-design.md](../../docs/mcp-broker-design.md) for the
full contract.

## Install (dev)

```bash
cd services/mcp-broker
python3 -m venv .venv
.venv/bin/pip install -e .
```

Once installed the broker is available as both:

- `python -m mcp_broker --config /etc/maludb/mcp-broker.json`
- `maludb-mcp-broker --config /etc/maludb/mcp-broker.json`

## Quick smoke

```bash
cd services/mcp-broker
MCP_BROKER_CONFIG=samples/mcp-broker.json \
    python3 -c '
import json, subprocess, sys
msgs = [
  {"jsonrpc":"2.0","id":1,"method":"initialize"},
  {"jsonrpc":"2.0","id":2,"method":"tools/list"},
  {"jsonrpc":"2.0","id":3,"method":"tools/call",
   "params":{"name":"shell.echo","arguments":{"text":"hi"}}}
]
r = subprocess.run(["python","-m","mcp_broker"],
    input="\n".join(json.dumps(m) for m in msgs),
    capture_output=True, text=True,
    env={**__import__("os").environ,
         "PYTHONPATH":"src",
         "MCP_BROKER_CONFIG":"samples/mcp-broker.json"})
for line in r.stdout.splitlines():
    print(json.dumps(json.loads(line), indent=2))
'
```

Expected: three JSON-RPC responses — initialize, tools/list,
tools/call returning `"text": "hi"`.

## Run tests

```bash
cd services/mcp-broker
python3 -m unittest discover tests -v
```

(No external dependencies — stdlib-only.)

## Config file

JSON, default location `/etc/maludb/mcp-broker.json` (override with
`--config` or `MCP_BROKER_CONFIG`):

```json
{
  "tools": [
    {
      "name": "shell.kubectl_get_pods",
      "description": "Run kubectl get pods -n <namespace>",
      "kind": "shell",
      "input_schema": {
        "type": "object",
        "properties": {"namespace": {"type": "string"}},
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

Variable substitution rules (defence in depth):

- Every `{{name}}` in `spec.argv` MUST appear in
  `input_schema.properties` — otherwise the broker refuses the call
  (you can't smuggle in a new field by passing it in arguments).
- All caller-supplied keys MUST be declared in
  `input_schema.properties`. Extra keys are rejected.
- `spec.argv[0]` MUST be an absolute path. The broker never invokes
  the system PATH lookup.
- `shell=False` always — the executable is run directly, no shell
  metacharacters are honoured.

## Audit

Every accepted `tools/call` emits one JSONL line on **stderr**:

```json
{"ts":"2026-05-13T15:42:01Z","tool":"shell.kubectl_get_pods",
 "argv_hash":"sha256:abcd…","exit":0,"duration_ms":221,
 "output_hash":"sha256:ef01…"}
```

`mc2dbd` is expected to ingest these into `malu$mc2db_invocation`
in a follow-up (v0.2.0). The broker itself never opens a
PostgreSQL connection.

## What's NOT in v1

- `http` and `mcp_proxy` tool kinds.
- HTTPS/SSE transport (stdio only).
- Live INSERT into `malu$mc2db_invocation` (JSONL on stderr only).
- mTLS auth to upstream MCP clients.
- `tools.listChanged` hot-reload when the config file changes.
- A systemd unit file (the broker is meant to be spawned as a
  subprocess by an MCP client; long-running daemonisation is
  unnecessary for stdio transport).
