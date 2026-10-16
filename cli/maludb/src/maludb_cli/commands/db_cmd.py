"""`maludb db upgrade|backup|restore-check`.

Thin wrappers — the actual upgrade is `ALTER EXTENSION ... UPDATE`,
backup is `pg_dump` / `pg_basebackup`, restore-check inspects the
manifest produced by V3-BACKUP-01 (a Stage 15 ticket). For the v0.1.0
CLI we wire up:

  * `maludb db upgrade`        — issues `ALTER EXTENSION maludb_core UPDATE` and prints before/after versions.
  * `maludb db backup`         — emits a `pg_dump --format=custom` to a path; emits a manifest sidecar.
  * `maludb db restore-check`  — verifies a manifest sidecar's hash against the dump file.
"""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import subprocess
import sys
from datetime import datetime, timezone

from ..db import connect
from ..output import emit_record


def register(sub) -> None:
    p = sub.add_parser("db", help="Database lifecycle commands.")
    p_sub = p.add_subparsers(dest="db_cmd", required=True, metavar="<db-cmd>")

    up = p_sub.add_parser("upgrade", help="Run ALTER EXTENSION maludb_core UPDATE.")
    up.set_defaults(handler=_upgrade)

    bk = p_sub.add_parser("backup", help="pg_dump the database to a file with a sidecar manifest.")
    bk.add_argument("--out", required=True, help="Output path for the custom-format dump.")
    bk.set_defaults(handler=_backup)

    rc = p_sub.add_parser("restore-check", help="Verify a backup manifest hash matches the dump file.")
    rc.add_argument("--in", dest="path", required=True, help="Dump path (sidecar .manifest.json expected next to it).")
    rc.set_defaults(handler=_restore_check)


def _upgrade(args) -> int:
    with connect(args) as conn, conn.cursor() as cur:
        cur.execute("SELECT extversion FROM pg_extension WHERE extname = 'maludb_core'")
        before = cur.fetchone()[0]
        cur.execute("ALTER EXTENSION maludb_core UPDATE")
        cur.execute("SELECT extversion FROM pg_extension WHERE extname = 'maludb_core'")
        after = cur.fetchone()[0]
    emit_record(args.format, {"before": before, "after": after, "noop": before == after})
    return 0


def _backup(args) -> int:
    if shutil.which("pg_dump") is None:
        emit_record(args.format, {"error": "pg_dump not on PATH"})
        return 69

    cmd = ["pg_dump", "--format=custom", "--file", args.out]
    if args.db:        cmd += ["--dbname",   args.db]
    if args.host:      cmd += ["--host",     args.host]
    if args.port:      cmd += ["--port",     str(args.port)]
    if args.user:      cmd += ["--username", args.user]

    env = os.environ.copy()
    if args.password:
        env["PGPASSWORD"] = args.password

    rc = subprocess.run(cmd, env=env).returncode
    if rc != 0:
        emit_record(args.format, {"error": "pg_dump failed", "rc": rc})
        return rc

    digest = _sha256_file(args.out)
    size   = os.path.getsize(args.out)
    manifest = {
        "format":          "maludb-backup-manifest/1",
        "created_at":      datetime.now(timezone.utc).isoformat(),
        "dump_path":       os.path.abspath(args.out),
        "dump_size_bytes": size,
        "dump_sha256":     digest,
        "pg_dump":         "pg_dump --format=custom",
        "ticket":          "V3-BACKUP-01-pending",
    }
    sidecar = args.out + ".manifest.json"
    with open(sidecar, "w") as f:
        json.dump(manifest, f, indent=2)
        f.write("\n")
    emit_record(args.format, {"dump": args.out, "manifest": sidecar, "sha256": digest, "size_bytes": size})
    return 0


def _restore_check(args) -> int:
    dump_path = args.path
    sidecar   = dump_path + ".manifest.json"
    if not os.path.exists(sidecar):
        emit_record(args.format, {"error": f"manifest not found: {sidecar}"})
        return 65
    with open(sidecar) as f:
        manifest = json.load(f)
    actual = _sha256_file(dump_path)
    expected = manifest.get("dump_sha256")
    ok = actual == expected
    emit_record(args.format, {
        "dump":     dump_path,
        "manifest": sidecar,
        "expected": expected,
        "actual":   actual,
        "match":    ok,
    })
    return 0 if ok else 65


def _sha256_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()
