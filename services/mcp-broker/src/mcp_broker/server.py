"""stdio JSON-RPC server.

One JSON object per line on stdin → one JSON object per line on
stdout. Errors that are protocol-level (parse, method-not-found) go
out as JSON-RPC error envelopes; tool dispatch failures come back as
tools/call results with `isError: true`.
"""

from __future__ import annotations

import json
import sys
from typing import Any, BinaryIO, TextIO

from . import PROTOCOL_VERSION, __version__
from .tools import Registry


class Server:
    def __init__(self, registry: Registry,
                 stdin: TextIO | None = None,
                 stdout: TextIO | None = None) -> None:
        self.registry = registry
        self.stdin = stdin or sys.stdin
        self.stdout = stdout or sys.stdout

    def serve(self) -> None:
        for line in self.stdin:
            line = line.strip()
            if not line:
                continue
            try:
                request = json.loads(line)
            except json.JSONDecodeError as e:
                self._write_error(None, -32700, f"parse error: {e}")
                continue
            response = self.dispatch(request)
            if response is not None:
                self._write(response)

    # ------------------------------------------------------------ #
    def dispatch(self, request: dict[str, Any]) -> dict[str, Any] | None:
        if request.get("jsonrpc") != "2.0":
            return self._error(request.get("id"), -32600, "missing or wrong jsonrpc")
        method = request.get("method")
        request_id = request.get("id")
        params = request.get("params") or {}

        if method == "initialize":
            return self._ok(request_id, {
                "protocolVersion": PROTOCOL_VERSION,
                "capabilities": {"tools": {"listChanged": False}},
                "serverInfo": {
                    "name": "maludb-mcp-broker",
                    "version": __version__,
                },
            })
        if method == "tools/list":
            return self._ok(request_id, {"tools": self.registry.list()})
        if method == "tools/call":
            name = str(params.get("name", ""))
            arguments = params.get("arguments") or {}
            envelope = self.registry.call(name, arguments)
            return self._ok(request_id, envelope)
        if method == "notifications/initialized":
            # MCP clients send this after initialize. No response.
            return None
        return self._error(request_id, -32601, f"method not found: {method}")

    # ------------------------------------------------------------ #
    @staticmethod
    def _ok(request_id: Any, result: Any) -> dict[str, Any]:
        return {"jsonrpc": "2.0", "id": request_id, "result": result}

    @staticmethod
    def _error(request_id: Any, code: int, msg: str) -> dict[str, Any]:
        return {"jsonrpc": "2.0", "id": request_id,
                "error": {"code": code, "message": msg}}

    def _write(self, obj: dict[str, Any]) -> None:
        self.stdout.write(json.dumps(obj) + "\n")
        self.stdout.flush()

    def _write_error(self, request_id: Any, code: int, msg: str) -> None:
        self._write(self._error(request_id, code, msg))
