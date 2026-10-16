"""Smoke test for the MaluDB external MCP broker.

Spawns the broker as a subprocess and drives it through one full
initialize → tools/list → tools/call sequence. Stdlib only.
"""

from __future__ import annotations

import json
import os
import pathlib
import subprocess
import sys
import unittest

REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
CONFIG = str(REPO_ROOT / "samples" / "mcp-broker.json")


def converse(messages: list[dict]) -> list[dict]:
    """Pipe a list of JSON-RPC requests, return the responses (one
    per request that expected a response — notifications drop out).
    """
    env = os.environ.copy()
    env["MCP_BROKER_CONFIG"] = CONFIG
    env["PYTHONPATH"] = str(REPO_ROOT / "src") + os.pathsep + env.get("PYTHONPATH", "")
    proc = subprocess.run(
        [sys.executable, "-m", "mcp_broker"],
        input="\n".join(json.dumps(m) for m in messages) + "\n",
        capture_output=True,
        text=True,
        timeout=10,
        env=env,
    )
    responses: list[dict] = []
    for line in proc.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        responses.append(json.loads(line))
    return responses


class BrokerSmoke(unittest.TestCase):
    def test_initialize_returns_capabilities(self) -> None:
        rs = converse([
            {"jsonrpc": "2.0", "id": 1, "method": "initialize",
             "params": {"protocolVersion": "2025-11-25"}}
        ])
        self.assertEqual(len(rs), 1)
        self.assertEqual(rs[0]["id"], 1)
        self.assertIn("capabilities", rs[0]["result"])
        self.assertEqual(rs[0]["result"]["serverInfo"]["name"],
                         "maludb-mcp-broker")

    def test_tools_list_includes_samples(self) -> None:
        rs = converse([
            {"jsonrpc": "2.0", "id": 1, "method": "initialize"},
            {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
        ])
        self.assertEqual(len(rs), 2)
        names = [t["name"] for t in rs[1]["result"]["tools"]]
        self.assertIn("shell.echo", names)
        self.assertIn("shell.uname", names)

    def test_tools_call_echo_round_trip(self) -> None:
        rs = converse([
            {"jsonrpc": "2.0", "id": 1, "method": "initialize"},
            {"jsonrpc": "2.0", "id": 2, "method": "tools/call",
             "params": {"name": "shell.echo",
                        "arguments": {"text": "hello broker"}}}
        ])
        self.assertEqual(rs[1]["result"]["isError"], False)
        text = rs[1]["result"]["content"][0]["text"]
        self.assertEqual(text, "hello broker")

    def test_tools_call_unknown_tool_returns_iserror(self) -> None:
        rs = converse([
            {"jsonrpc": "2.0", "id": 1, "method": "initialize"},
            {"jsonrpc": "2.0", "id": 2, "method": "tools/call",
             "params": {"name": "shell.no_such_tool", "arguments": {}}}
        ])
        self.assertEqual(rs[1]["result"]["isError"], True)

    def test_tools_call_validation_failure(self) -> None:
        rs = converse([
            {"jsonrpc": "2.0", "id": 1, "method": "initialize"},
            {"jsonrpc": "2.0", "id": 2, "method": "tools/call",
             "params": {"name": "shell.echo",
                        "arguments": {"text": "ok", "bogus": "x"}}}
        ])
        self.assertEqual(rs[1]["result"]["isError"], True)
        self.assertIn("bogus", rs[1]["result"]["content"][0]["text"])

    def test_method_not_found_returns_jsonrpc_error(self) -> None:
        rs = converse([
            {"jsonrpc": "2.0", "id": 1, "method": "no/such/method"}
        ])
        self.assertEqual(rs[0]["error"]["code"], -32601)


if __name__ == "__main__":
    unittest.main()
