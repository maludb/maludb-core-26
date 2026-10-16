"""Tool registry + dispatcher.

Pure stdlib. Loads a JSON config at construction time and dispatches
`tools/call` requests against it. v1 supports the `shell` tool kind
only.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import subprocess
import sys
import time
from dataclasses import dataclass, field
from typing import Any, Iterable

VARSUB_RE = re.compile(r"\{\{([a-zA-Z_][a-zA-Z0-9_]*)\}\}")


@dataclass
class ToolError(Exception):
    """Raised when a tools/call cannot proceed (validation, timeout, exec).

    The broker translates these into MCP result envelopes with
    `isError: true` — they are NOT JSON-RPC protocol errors.
    """

    message: str
    detail: str | None = None

    def __str__(self) -> str:
        return self.message + (f" — {self.detail}" if self.detail else "")


@dataclass
class Tool:
    name: str
    description: str
    kind: str
    input_schema: dict[str, Any]
    spec: dict[str, Any] = field(default_factory=dict)


class Registry:
    def __init__(self, tools: list[Tool]) -> None:
        self._tools: dict[str, Tool] = {t.name: t for t in tools}

    @classmethod
    def from_config_path(cls, path: str) -> "Registry":
        with open(path) as f:
            raw = json.load(f)
        items = raw.get("tools", []) or []
        tools: list[Tool] = []
        for it in items:
            tools.append(
                Tool(
                    name=str(it["name"]),
                    description=str(it.get("description", "")),
                    kind=str(it["kind"]),
                    input_schema=dict(it.get("input_schema", {"type": "object"})),
                    spec=dict(it.get("spec", {})),
                )
            )
        return cls(tools)

    def list(self) -> list[dict[str, Any]]:
        return [
            {
                "name": t.name,
                "description": t.description,
                "inputSchema": t.input_schema,
            }
            for t in self._tools.values()
        ]

    def call(self, name: str, arguments: dict[str, Any]) -> dict[str, Any]:
        """Dispatch a tools/call. Returns the MCP result envelope.

        Returns `{"content":[…], "isError": false|true}`. Never
        raises through the wire — `ToolError` is translated to an
        isError envelope inline.
        """
        tool = self._tools.get(name)
        if tool is None:
            return self._err_envelope(f"unknown tool: {name}")

        try:
            self._validate(tool, arguments)
        except ToolError as e:
            return self._err_envelope(str(e))

        try:
            if tool.kind == "shell":
                return self._dispatch_shell(tool, arguments)
            return self._err_envelope(
                f"unsupported tool kind: {tool.kind!r}; v1 only supports 'shell'"
            )
        except ToolError as e:
            return self._err_envelope(str(e))
        except Exception as e:  # pragma: no cover  defence in depth
            return self._err_envelope(f"internal error: {e}")

    # ------------------------------------------------------------ #

    def _validate(self, tool: Tool, args: dict[str, Any]) -> None:
        schema = tool.input_schema
        if not isinstance(args, dict):
            raise ToolError("arguments must be a JSON object")
        props = (schema or {}).get("properties", {}) or {}
        required = (schema or {}).get("required", []) or []
        for r in required:
            if r not in args:
                raise ToolError(f"missing required argument: {r}")
        for k in args:
            if k not in props:
                raise ToolError(f"unknown argument: {k}")

    def _dispatch_shell(self, tool: Tool, args: dict[str, Any]) -> dict[str, Any]:
        argv_template = tool.spec.get("argv")
        if not isinstance(argv_template, list) or not argv_template:
            raise ToolError("shell tool missing spec.argv")
        timeout_ms = int(tool.spec.get("timeout_ms", 5000))

        argv = [self._subst(s, args, tool.input_schema) for s in argv_template]
        if not argv[0].startswith("/"):
            raise ToolError("shell argv[0] must be an absolute path")

        start = time.monotonic()
        try:
            result = subprocess.run(
                argv,
                shell=False,
                capture_output=True,
                text=True,
                timeout=timeout_ms / 1000.0,
                check=False,
            )
        except subprocess.TimeoutExpired:
            duration = int((time.monotonic() - start) * 1000)
            self._audit(tool.name, argv, -1, duration, b"")
            raise ToolError(f"timeout after {timeout_ms} ms") from None
        duration = int((time.monotonic() - start) * 1000)
        self._audit(tool.name, argv, result.returncode,
                    duration, (result.stdout or "").encode("utf-8"))

        body = result.stdout
        if result.returncode != 0:
            err = result.stderr.strip() or f"exit {result.returncode}"
            return self._err_envelope(f"shell exit {result.returncode}: {err}")
        return {
            "content": [{"type": "text", "text": body}],
            "isError": False,
        }

    @staticmethod
    def _subst(template: str, args: dict[str, Any], schema: dict[str, Any]) -> str:
        """Substitute {{name}} markers from args. Defence in depth:
        every referenced name MUST appear in input_schema.properties.
        """
        props = (schema or {}).get("properties", {}) or {}

        def repl(m: re.Match[str]) -> str:
            key = m.group(1)
            if key not in props:
                raise ToolError(f"variable {{{{{key}}}}} not declared in input_schema")
            if key not in args:
                raise ToolError(f"variable {{{{{key}}}}} not in arguments")
            return str(args[key])

        return VARSUB_RE.sub(repl, template)

    def _audit(self, name: str, argv: list[str], exit_code: int,
               duration_ms: int, output: bytes) -> None:
        try:
            argv_hash = hashlib.sha256(json.dumps(argv).encode()).hexdigest()
            output_hash = hashlib.sha256(output).hexdigest()
            audit = {
                "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                "tool": name,
                "argv_hash": f"sha256:{argv_hash[:32]}",
                "exit": exit_code,
                "duration_ms": duration_ms,
                "output_hash": f"sha256:{output_hash[:32]}",
            }
            sys.stderr.write(json.dumps(audit) + "\n")
            sys.stderr.flush()
        except Exception:
            pass  # auditing failure must never break tool dispatch

    @staticmethod
    def _err_envelope(msg: str) -> dict[str, Any]:
        return {
            "content": [{"type": "text", "text": msg}],
            "isError": True,
        }
