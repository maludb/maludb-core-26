"""Minimal RFC 6455 WebSocket helpers for maludb-realtimed.

We only need:
  * handshake against an incoming HTTP/1.1 Upgrade request,
  * send a text frame (server -> client; unmasked),
  * receive one frame (client -> server; masked; control frames handled).

The wire format is small enough to implement in <100 lines of stdlib
Python. A real-world deployment can substitute `websockets` if
extension dependencies become acceptable; the surface here is
intentionally pluggable.
"""

from __future__ import annotations

import base64
import hashlib
import os
import struct


WS_MAGIC = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

OPCODE_CONT  = 0x0
OPCODE_TEXT  = 0x1
OPCODE_BIN   = 0x2
OPCODE_CLOSE = 0x8
OPCODE_PING  = 0x9
OPCODE_PONG  = 0xA


class WSError(RuntimeError):
    pass


def handshake_response(headers) -> tuple[int, dict[str, str]]:
    """Return (status_code, headers) for the incoming handshake.

    headers: BaseHTTPRequestHandler.headers (case-insensitive dict).
    """
    upgrade = (headers.get("Upgrade") or "").lower()
    conn    = (headers.get("Connection") or "").lower()
    version = headers.get("Sec-WebSocket-Version") or ""
    key     = headers.get("Sec-WebSocket-Key")

    if upgrade != "websocket" or "upgrade" not in conn:
        return 400, {}
    if version != "13":
        return 426, {"Sec-WebSocket-Version": "13"}
    if not key:
        return 400, {}

    accept_raw = (key + WS_MAGIC).encode("ascii")
    accept = base64.b64encode(hashlib.sha1(accept_raw).digest()).decode("ascii")
    return 101, {
        "Upgrade":              "websocket",
        "Connection":           "Upgrade",
        "Sec-WebSocket-Accept": accept,
    }


def send_text(wfile, text: str) -> None:
    _send_frame(wfile, OPCODE_TEXT, text.encode("utf-8"))


def send_close(wfile, code: int = 1000, reason: str = "") -> None:
    body = struct.pack(">H", code) + reason.encode("utf-8")
    _send_frame(wfile, OPCODE_CLOSE, body)


def _send_frame(wfile, opcode: int, payload: bytes) -> None:
    header = bytearray()
    header.append(0x80 | (opcode & 0x0F))           # FIN=1, opcode
    n = len(payload)
    if n < 126:
        header.append(n)
    elif n <= 0xFFFF:
        header.append(126)
        header += struct.pack(">H", n)
    else:
        header.append(127)
        header += struct.pack(">Q", n)
    # No masking from server.
    wfile.write(bytes(header))
    wfile.write(payload)
    wfile.flush()


def recv_frame(rfile) -> tuple[int, bytes]:
    """Read one frame; return (opcode, payload).

    Raises WSError on malformed input. Returns (OPCODE_CLOSE, b"") on
    a clean close from the peer.
    """
    hdr = _read_exact(rfile, 2)
    if not hdr:
        return (OPCODE_CLOSE, b"")
    b1, b2 = hdr[0], hdr[1]
    fin    = (b1 & 0x80) != 0
    opcode = b1 & 0x0F
    masked = (b2 & 0x80) != 0
    length =  b2 & 0x7F
    if length == 126:
        length = struct.unpack(">H", _read_exact(rfile, 2))[0]
    elif length == 127:
        length = struct.unpack(">Q", _read_exact(rfile, 8))[0]
    if not masked:
        # RFC 6455: client must mask. Treat as protocol error.
        raise WSError("client sent unmasked frame")
    mask = _read_exact(rfile, 4)
    raw  = _read_exact(rfile, length) if length else b""
    payload = bytes(raw[i] ^ mask[i % 4] for i in range(length))
    if not fin:
        # We don't support fragmented frames in v0.1 — sticks to small
        # JSON messages which fit in a single frame. Surface as a
        # protocol error so the caller sends close.
        raise WSError("fragmented frames not supported")
    return (opcode, payload)


def _read_exact(rfile, n: int) -> bytes:
    if n <= 0:
        return b""
    chunks: list[bytes] = []
    remaining = n
    while remaining > 0:
        buf = rfile.read(remaining)
        if not buf:
            return b"".join(chunks) if chunks else b""
        chunks.append(buf)
        remaining -= len(buf)
    return b"".join(chunks)
