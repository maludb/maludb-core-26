#!/usr/bin/env python3
"""Minimal stdio MCP server fixture for mc2dbd R1.1-2 service tests.

Reads one JSON-RPC request (terminated by newline or EOF) on stdin,
writes one JSON-RPC response on stdout, exits 0. Matches the
one-shot dispatch behavior of proxy_stdio() in mc2dbd/src/proxy.c.
"""

import json
import sys


def main() -> int:
    data = sys.stdin.read()
    try:
        req = json.loads(data) if data.strip() else {}
    except Exception:
        sys.stderr.write("bad json\n")
        return 2
    rid = req.get("id")
    params = req.get("params") or {}
    text = "stdio_echo:" + json.dumps(params, sort_keys=True)
    resp = {
        "jsonrpc": "2.0",
        "id": rid,
        "result": {
            "content": [{"type": "text", "text": text}],
            "structuredContent": {"params": params},
        },
    }
    sys.stdout.write(json.dumps(resp) + "\n")
    sys.stdout.flush()
    return 0


if __name__ == "__main__":
    sys.exit(main())
