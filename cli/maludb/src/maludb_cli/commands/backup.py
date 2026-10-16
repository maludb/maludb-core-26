"""`maludb backup manifest|verify|latest` — V3-BACKUP-01 wiring."""

from __future__ import annotations

import json

from ..db import connect
from ..output import emit_record


def register(sub) -> None:
    p = sub.add_parser("backup", help="Backup manifest catalog (V3-BACKUP-01).")
    p_sub = p.add_subparsers(dest="backup_cmd", required=True, metavar="<backup-cmd>")

    mn = p_sub.add_parser("manifest",
        help="Record a backup manifest: postgres state + every supporting artefact.")
    mn.add_argument("--label",                          required=True)
    mn.add_argument("--postgres-state-kind",            required=True,
        choices=("dump", "basebackup"))
    mn.add_argument("--postgres-state-uri",             required=True)
    mn.add_argument("--hash-summary",                   required=True,
        help='JSON map of artefact_kind -> sha256 hex.')
    mn.add_argument("--wal-archive-uri",                default=None)
    mn.add_argument("--etc-maludb-uri",                 default=None)
    mn.add_argument("--source-archive-manifest-uri",    default=None)
    mn.add_argument("--model-configs-uri",              default=None)
    mn.add_argument("--tls-uri",                        default=None)
    mn.add_argument("--tool-binaries-uri",              default=None)
    mn.add_argument("--broker-configs-uri",             default=None)
    mn.set_defaults(handler=_manifest)

    vf = p_sub.add_parser("verify",
        help="Record a restore-check verification outcome against a manifest.")
    vf.add_argument("--manifest-id", type=int, required=True)
    vf.add_argument("--status",      required=True,
        choices=("running", "passed", "failed"))
    vf.add_argument("--errors",      default=None,
        help="Optional JSON with which artefact failed and why.")
    vf.add_argument("--notes",       default=None)
    vf.set_defaults(handler=_verify)

    lt = p_sub.add_parser("latest",
        help="Print the most recent backup manifest's metadata.")
    lt.set_defaults(handler=_latest)


def _manifest(args) -> int:
    hash_summary = json.loads(args.hash_summary)
    with connect(args) as conn, conn.cursor() as cur:
        cur.execute(
            """
            SELECT backup_manifest_record(%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
            """,
            (args.label, args.postgres_state_kind, args.postgres_state_uri,
             json.dumps(hash_summary),
             args.wal_archive_uri, args.etc_maludb_uri,
             args.source_archive_manifest_uri, args.model_configs_uri,
             args.tls_uri, args.tool_binaries_uri, args.broker_configs_uri),
        )
        manifest_id = cur.fetchone()[0]
    emit_record(args.format, {"label": args.label, "manifest_id": manifest_id,
                              "postgres_state_kind": args.postgres_state_kind,
                              "postgres_state_uri": args.postgres_state_uri})
    return 0


def _verify(args) -> int:
    errors = json.loads(args.errors) if args.errors else None
    with connect(args) as conn, conn.cursor() as cur:
        cur.execute(
            "SELECT backup_verification_record(%s, %s, %s, %s)",
            (args.manifest_id, args.status,
             json.dumps(errors) if errors else None,
             args.notes),
        )
        verification_id = cur.fetchone()[0]
    emit_record(args.format, {"manifest_id": args.manifest_id,
                              "verification_id": verification_id,
                              "status": args.status})
    return 0 if args.status == "passed" else 65


def _latest(args) -> int:
    with connect(args) as conn, conn.cursor() as cur:
        cur.execute(
            """
            SELECT manifest_id, label, postgres_state_kind, postgres_state_uri,
                   extension_version, created_at,
                   last_verification, last_verification_at
              FROM backup_manifest_latest()
            """
        )
        row = cur.fetchone()
    if not row:
        emit_record(args.format, {"error": "no_backup_manifest_recorded"})
        return 65
    keys = ("manifest_id", "label", "postgres_state_kind", "postgres_state_uri",
            "extension_version", "created_at",
            "last_verification", "last_verification_at")
    emit_record(args.format, dict(zip(keys, row)))
    return 0
