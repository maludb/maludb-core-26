"""Text + JSON output formatting for the maludb CLI."""

from __future__ import annotations

import json
import sys
from typing import Any, Iterable, Sequence


def _stringify(v: Any) -> str:
    if v is None:
        return ""
    if isinstance(v, (list, tuple)):
        return ",".join(_stringify(x) for x in v)
    if isinstance(v, dict):
        return json.dumps(v, default=str)
    if isinstance(v, (bytes, bytearray, memoryview)):
        return bytes(v).hex()
    return str(v)


def emit_table(format_mode: str, columns: Sequence[str], rows: Iterable[Sequence[Any]]) -> None:
    rows = list(rows)
    if format_mode == "json":
        out = [
            {col: _json_safe(val) for col, val in zip(columns, row)}
            for row in rows
        ]
        json.dump(out, sys.stdout, default=str, indent=2)
        sys.stdout.write("\n")
        return

    if not rows:
        # Header only.
        print("  ".join(columns))
        return

    str_rows = [[_stringify(v) for v in r] for r in rows]
    widths = [
        max(len(columns[i]), *(len(r[i]) for r in str_rows))
        for i in range(len(columns))
    ]
    fmt = "  ".join(f"{{:<{w}}}" for w in widths)
    print(fmt.format(*columns))
    print(fmt.format(*("-" * w for w in widths)))
    for r in str_rows:
        print(fmt.format(*r))


def emit_record(format_mode: str, record: dict[str, Any]) -> None:
    if format_mode == "json":
        json.dump(record, sys.stdout, default=str, indent=2)
        sys.stdout.write("\n")
        return
    width = max((len(k) for k in record), default=0)
    for k, v in record.items():
        print(f"{k:<{width}} : {_stringify(v)}")


def emit_kv(format_mode: str, pairs: Sequence[tuple[str, Any]]) -> None:
    emit_record(format_mode, dict(pairs))


def emit_error(format_mode: str, message: str, code: str | None = None) -> None:
    if format_mode == "json":
        json.dump({"error": message, "code": code}, sys.stderr, default=str)
        sys.stderr.write("\n")
    else:
        if code:
            print(f"maludb: {code}: {message}", file=sys.stderr)
        else:
            print(f"maludb: {message}", file=sys.stderr)


def _json_safe(v: Any) -> Any:
    if isinstance(v, (bytes, bytearray, memoryview)):
        return bytes(v).hex()
    return v
