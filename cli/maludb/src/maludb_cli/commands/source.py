"""`maludb source put|get|verify|list|promote` — V3-STOR-01 wiring.

Storage adapters live in the catalog (`malu$storage_adapter`); the
CLI handles the actual byte read/write to whichever adapter kind the
object is bound to. v0.1.0 supports the `local_fs` kind end-to-end;
`s3` adapter rows are accepted by the catalog but the CLI raises an
explicit error pointing to the Stage 12 follow-up.
"""

from __future__ import annotations

import hashlib
import json
import os

from ..db import connect
from ..output import emit_record, emit_table
from .. import s3 as _s3


def register(sub) -> None:
    p = sub.add_parser("source", help="Verbatim Source Archive (V3-STOR-01).")
    p_sub = p.add_subparsers(dest="source_cmd", required=True, metavar="<source-cmd>")

    ad = p_sub.add_parser("adapter-register",
        help="Register a storage adapter (local_fs or s3).")
    ad.add_argument("--name",        required=True)
    ad.add_argument("--kind",        required=True, choices=("local_fs", "s3"))
    ad.add_argument("--config",      required=True,
        help='JSON. local_fs: {"base_path":"..."}. s3: {"bucket":...,"region":...,"key_prefix":...}.')
    ad.add_argument("--secret-ref",  default=None, help="malu$secret name holding adapter credentials.")
    ad.add_argument("--description", default=None)
    ad.set_defaults(handler=_adapter_register)

    pu = p_sub.add_parser("put",
        help="Upload a file: writes bytes through the adapter, registers the object.")
    pu.add_argument("--file",            required=True)
    pu.add_argument("--adapter",         required=True)
    pu.add_argument("--media-type",      default=None)
    pu.add_argument("--source-time",     default=None)
    pu.add_argument("--retention-class", default="standard",
        choices=("standard", "sensitive", "restricted", "prohibited"))
    pu.add_argument("--sensitivity",     default="internal",
        choices=("public", "internal", "restricted", "prohibited"))
    pu.add_argument("--partition",       default=None)
    pu.set_defaults(handler=_put)

    gt = p_sub.add_parser("get", help="Download a source object to a local file path.")
    gt.add_argument("--object-id", type=int, required=True)
    gt.add_argument("--out",       required=True)
    gt.set_defaults(handler=_get)

    vr = p_sub.add_parser("verify", help="Read the object from its adapter and verify the hash.")
    vr.add_argument("--object-id", type=int, required=True)
    vr.set_defaults(handler=_verify)

    ls = p_sub.add_parser("list", help="List source objects.")
    ls.add_argument("--partition", default=None)
    ls.set_defaults(handler=_list)

    pr = p_sub.add_parser("promote",
        help="Promote a source object to a malu$source_package and write a Derivation Ledger entry.")
    pr.add_argument("--object-id",   type=int, required=True)
    pr.add_argument("--source-type", required=True)
    pr.add_argument("--content",     default=None,
        help="Text content for the source_package; defaults to reading from the object's bytes (text/* media types only).")
    pr.set_defaults(handler=_promote)

    su = p_sub.add_parser("signed-url",
        help="Issue a SigV4 pre-signed GET URL for an S3-backed source object.")
    su.add_argument("--object-id",  type=int, required=True)
    su.add_argument("--expires-in", type=int, default=600,
        help="Expiry in seconds (1..604800); default 600.")
    su.set_defaults(handler=_signed_url)


# -- Adapter dispatch ---------------------------------------------------

def _load_adapter(cur, name: str):
    cur.execute(
        """
        SELECT adapter_id, kind, config, secret_ref FROM malu$storage_adapter
         WHERE name = %s AND retired_at IS NULL
        """,
        (name,),
    )
    row = cur.fetchone()
    if not row:
        raise RuntimeError(f"adapter '{name}' not found or retired")
    return {"adapter_id": row[0], "kind": row[1],
            "config":     row[2], "secret_ref": row[3]}


def _s3_credentials(cur, adapter: dict) -> dict:
    """Resolve the adapter's secret_ref into S3 credentials.

    Schema: {"access_key": "...", "secret_key": "...",
             "session_token": "..."(optional)}.
    """
    ref = adapter.get("secret_ref")
    if not ref:
        raise RuntimeError("s3 adapter has no secret_ref; cannot resolve credentials")
    cur.execute("SELECT __secret_resolve(%s)", (ref,))
    raw = cur.fetchone()[0]
    try:
        creds = json.loads(raw)
    except json.JSONDecodeError as e:
        raise RuntimeError(f"s3 credentials secret {ref!r} is not valid JSON: {e}") from e
    if not creds.get("access_key") or not creds.get("secret_key"):
        raise RuntimeError(f"s3 credentials secret {ref!r} missing access_key/secret_key")
    return creds


def _local_fs_path(adapter: dict, content_hash_hex: str) -> str:
    base = adapter["config"]["base_path"]
    return os.path.join(base, content_hash_hex[0:2], content_hash_hex[2:4], content_hash_hex)


def _adapter_put_bytes(cur, adapter: dict, content_hash_hex: str, data: bytes) -> str:
    """Write bytes via the adapter; return the adapter_uri to record."""
    if adapter["kind"] == "local_fs":
        path = _local_fs_path(adapter, content_hash_hex)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        rel = os.path.relpath(path, adapter["config"]["base_path"])
        if not os.path.exists(path):
            tmp = path + ".tmp"
            with open(tmp, "wb") as f:
                f.write(data)
            os.replace(tmp, path)
        return rel
    if adapter["kind"] == "s3":
        creds = _s3_credentials(cur, adapter)
        return _s3.put_bytes(adapter["config"], creds, content_hash_hex, data)
    raise RuntimeError(f"unknown adapter kind {adapter['kind']!r}")


def _adapter_read_bytes(cur, adapter: dict, adapter_uri: str) -> bytes:
    if adapter["kind"] == "local_fs":
        path = os.path.join(adapter["config"]["base_path"], adapter_uri)
        with open(path, "rb") as f:
            return f.read()
    if adapter["kind"] == "s3":
        creds = _s3_credentials(cur, adapter)
        return _s3.get_bytes(adapter["config"], creds, adapter_uri)
    raise RuntimeError(f"unknown adapter kind {adapter['kind']!r}")


# -- Subcommand handlers -------------------------------------------------

def _adapter_register(args) -> int:
    try:
        config = json.loads(args.config)
    except json.JSONDecodeError as e:
        emit_record(args.format, {"error": f"invalid --config JSON: {e}"})
        return 64
    with connect(args) as conn, conn.cursor() as cur:
        cur.execute(
            "SELECT register_storage_adapter(%s, %s, %s::jsonb, %s, %s)",
            (args.name, args.kind, json.dumps(config), args.secret_ref, args.description),
        )
        aid = cur.fetchone()[0]
    emit_record(args.format, {"adapter_id": aid, "name": args.name, "kind": args.kind})
    return 0


def _put(args) -> int:
    with open(args.file, "rb") as f:
        data = f.read()
    h = hashlib.sha256(data).digest()
    h_hex = h.hex()
    with connect(args) as conn, conn.cursor() as cur:
        adapter = _load_adapter(cur, args.adapter)
        uri = _adapter_put_bytes(cur, adapter, h_hex, data)
        cur.execute(
            """
            SELECT source_object_register(%s, %s, %s::bytea, %s, %s, %s::timestamptz, %s, %s, %s)
            """,
            (args.adapter, uri, h, len(data),
             args.media_type, args.source_time,
             args.retention_class, args.sensitivity, args.partition),
        )
        oid = cur.fetchone()[0]
    emit_record(args.format, {
        "object_id":   oid,
        "adapter":     args.adapter,
        "adapter_uri": uri,
        "content_hash_sha256_hex": h_hex,
        "byte_length": len(data),
    })
    return 0


def _get(args) -> int:
    with connect(args) as conn, conn.cursor() as cur:
        cur.execute(
            """
            SELECT a.name, o.adapter_uri, o.content_hash, o.byte_length
              FROM malu$source_object o
              JOIN malu$storage_adapter a ON a.adapter_id = o.adapter_id
             WHERE o.object_id = %s
            """,
            (args.object_id,),
        )
        row = cur.fetchone()
        if not row:
            emit_record(args.format, {"object_id": args.object_id, "error": "not_found"})
            return 65
        adapter_name, adapter_uri, content_hash, byte_length = row
        adapter = _load_adapter(cur, adapter_name)
        data = _adapter_read_bytes(cur, adapter, adapter_uri)

    actual = hashlib.sha256(data).digest()
    if actual != bytes(content_hash):
        emit_record(args.format, {
            "object_id": args.object_id,
            "error":     "hash_mismatch",
            "expected":  bytes(content_hash).hex(),
            "actual":    actual.hex(),
        })
        return 65
    with open(args.out, "wb") as f:
        f.write(data)
    emit_record(args.format, {
        "object_id":   args.object_id,
        "out":         args.out,
        "byte_length": len(data),
        "sha256_hex":  actual.hex(),
    })
    return 0


def _signed_url(args) -> int:
    with connect(args) as conn, conn.cursor() as cur:
        cur.execute(
            """
            SELECT a.name, o.adapter_uri
              FROM malu$source_object o
              JOIN malu$storage_adapter a ON a.adapter_id = o.adapter_id
             WHERE o.object_id = %s
            """,
            (args.object_id,),
        )
        row = cur.fetchone()
        if not row:
            emit_record(args.format, {"object_id": args.object_id, "error": "not_found"})
            return 65
        adapter_name, adapter_uri = row
        adapter = _load_adapter(cur, adapter_name)
        if adapter["kind"] != "s3":
            emit_record(args.format, {
                "object_id": args.object_id,
                "error": "signed_url_unsupported",
                "adapter_kind": adapter["kind"],
            })
            return 65
        creds = _s3_credentials(cur, adapter)
    url = _s3.presign_get(adapter["config"], creds, adapter_uri, args.expires_in)
    emit_record(args.format, {
        "object_id":  args.object_id,
        "adapter":    adapter_name,
        "expires_in": args.expires_in,
        "signed_url": url,
    })
    return 0


def _verify(args) -> int:
    with connect(args) as conn, conn.cursor() as cur:
        cur.execute(
            """
            SELECT a.name, o.adapter_uri, o.content_hash, o.byte_length
              FROM malu$source_object o
              JOIN malu$storage_adapter a ON a.adapter_id = o.adapter_id
             WHERE o.object_id = %s
            """,
            (args.object_id,),
        )
        row = cur.fetchone()
        if not row:
            emit_record(args.format, {"object_id": args.object_id, "error": "not_found"})
            return 65
        adapter_name, adapter_uri, content_hash, byte_length = row
        adapter = _load_adapter(cur, adapter_name)
        data = _adapter_read_bytes(cur, adapter, adapter_uri)

    actual = hashlib.sha256(data).digest()
    match = actual == bytes(content_hash) and len(data) == byte_length
    emit_record(args.format, {
        "object_id":             args.object_id,
        "expected_sha256_hex":   bytes(content_hash).hex(),
        "actual_sha256_hex":     actual.hex(),
        "expected_byte_length":  byte_length,
        "actual_byte_length":    len(data),
        "match":                 match,
    })
    return 0 if match else 65


def _list(args) -> int:
    with connect(args) as conn, conn.cursor() as cur:
        if args.partition:
            cur.execute(
                """
                SELECT object_id, encode(content_hash,'hex'), byte_length,
                       media_type, retention_class, sensitivity, partition
                  FROM malu$source_object
                 WHERE retired_at IS NULL AND partition = %s
                 ORDER BY object_id
                """,
                (args.partition,),
            )
        else:
            cur.execute(
                """
                SELECT object_id, encode(content_hash,'hex'), byte_length,
                       media_type, retention_class, sensitivity, partition
                  FROM malu$source_object
                 WHERE retired_at IS NULL
                 ORDER BY object_id
                """,
            )
        rows = cur.fetchall()
    emit_table(args.format,
        ("object_id", "sha256_hex", "byte_length", "media_type",
         "retention_class", "sensitivity", "partition"),
        rows)
    return 0


def _promote(args) -> int:
    content_text = args.content
    with connect(args) as conn, conn.cursor() as cur:
        if content_text is None:
            # Fall back to reading the object's bytes (decoded as UTF-8)
            # — only safe for text/* media types.
            cur.execute(
                """
                SELECT a.name, o.adapter_uri, o.media_type
                  FROM malu$source_object o
                  JOIN malu$storage_adapter a ON a.adapter_id = o.adapter_id
                 WHERE o.object_id = %s
                """,
                (args.object_id,),
            )
            row = cur.fetchone()
            if not row:
                emit_record(args.format, {"object_id": args.object_id, "error": "not_found"})
                return 65
            adapter_name, adapter_uri, media_type = row
            if media_type is None or not media_type.startswith("text/"):
                emit_record(args.format, {
                    "object_id": args.object_id,
                    "error":     "non_text_media_requires_--content",
                    "media_type": media_type,
                })
                return 64
            adapter = _load_adapter(cur, adapter_name)
            content_text = _adapter_read_bytes(cur, adapter, adapter_uri).decode("utf-8")

        cur.execute(
            "SELECT source_object_promote_to_source_package(%s, %s, NULL, %s, NULL, NULL, NULL)",
            (args.object_id, args.source_type, content_text),
        )
        pid = cur.fetchone()[0]
    emit_record(args.format, {
        "object_id":         args.object_id,
        "source_package_id": pid,
    })
    return 0
