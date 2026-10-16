"""Sinks. Each ship() raises on failure; the worker catches and records.

A sink is constructed with the drain's destination jsonb dict and the
optional inline secret value (for the http / s3 / otlp_http kinds that
need credentials). The worker decides when to call ship().
"""

from __future__ import annotations

import json
import os
import urllib.error
import urllib.request
from typing import Any


class SinkError(RuntimeError):
    pass


def make_sink(kind: str, destination: dict[str, Any], secret_value: str | None):
    if kind == "file":
        return FileSink(destination)
    if kind == "http":
        return HttpSink(destination, secret_value)
    if kind in ("s3", "otlp_http"):
        raise SinkError(f"sink kind '{kind}' is not yet implemented "
                        f"(maludb-logsd v0.1.0 ships file + http only)")
    raise SinkError(f"unknown sink kind: {kind}")


class FileSink:
    """Append-only JSON Lines to destination['path']."""

    def __init__(self, destination: dict[str, Any]) -> None:
        path = destination.get("path")
        if not path:
            raise SinkError("file sink requires destination.path")
        self._path = path
        # Parent dir must exist; we do not create it.
        if not os.path.isdir(os.path.dirname(path)):
            raise SinkError(f"file sink: parent directory does not exist: "
                            f"{os.path.dirname(path)}")

    def ship(self, batch: list[dict[str, Any]]) -> tuple[int, int]:
        body = "\n".join(json.dumps(r, default=str) for r in batch) + "\n"
        with open(self._path, "a") as f:
            f.write(body)
        return (1, len(body.encode("utf-8")))


class HttpSink:
    """POST the batch as a single JSON document to destination['url']."""

    def __init__(self, destination: dict[str, Any], secret_value: str | None) -> None:
        url = destination.get("url")
        if not url:
            raise SinkError("http sink requires destination.url")
        self._url = url
        self._header_name  = destination.get("auth_header") or "Authorization"
        self._header_value = secret_value
        self._timeout_s    = float(destination.get("timeout_s", 10.0))

    def ship(self, batch: list[dict[str, Any]]) -> tuple[int, int]:
        body = json.dumps({"records": batch}, default=str).encode("utf-8")
        req = urllib.request.Request(
            self._url,
            data=body,
            method="POST",
            headers={"Content-Type": "application/json"},
        )
        if self._header_value:
            req.add_header(self._header_name, self._header_value)
        try:
            with urllib.request.urlopen(req, timeout=self._timeout_s) as resp:
                code = getattr(resp, "status", 200)
        except urllib.error.HTTPError as e:
            raise SinkError(f"http sink: HTTP {e.code} {e.reason}") from e
        except urllib.error.URLError as e:
            raise SinkError(f"http sink: {e.reason}") from e
        if code >= 400:
            raise SinkError(f"http sink: HTTP {code}")
        return (1, len(body))
