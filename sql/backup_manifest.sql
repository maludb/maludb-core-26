-- V3-BACKUP-01 — backup manifest + verification catalog regression coverage.

SET search_path TO maludb_core, public;

-- ---------------------------------------------------------------------
-- Test 1: backup_manifest_record stores a row tagged with the
-- current extension version.
-- ---------------------------------------------------------------------
SELECT backup_manifest_record(
    'smoke-2026-05-14',
    'dump',
    'file:///var/backups/maludb/smoke-2026-05-14.dump',
    jsonb_build_object('dump_sha256', 'deadbeef', 'wal_archive_count', 3),
    'file:///var/backups/maludb/wal/',
    '/etc/maludb',
    'file:///var/lib/maludb/source-archive/manifest.json',
    'file:///etc/maludb/model-configs.tar',
    '/etc/maludb/tls',
    '/usr/local/libexec/maludb-tools',
    '/etc/maludb/broker') AS manifest_id \gset m_

SELECT label, postgres_state_kind, extension_version = maludb_core_version() AS version_recorded,
       hash_summary ? 'dump_sha256' AS hash_summary_present
FROM malu$backup_manifest WHERE manifest_id = :'m_manifest_id'::bigint;

-- ---------------------------------------------------------------------
-- Test 2: record a verification result, then backup_manifest_latest
-- shows it.
-- ---------------------------------------------------------------------
SELECT backup_verification_record(:'m_manifest_id'::bigint, 'passed',
                                  NULL, 'smoke verification') AS verification_id \gset v_

SELECT label, postgres_state_kind, last_verification
FROM backup_manifest_latest();

-- ---------------------------------------------------------------------
-- Test 3: status CHECK.
-- ---------------------------------------------------------------------
DO $body$
DECLARE v_mid bigint;
BEGIN
    SELECT manifest_id INTO v_mid FROM malu$backup_manifest
     WHERE label = 'smoke-2026-05-14' ORDER BY manifest_id DESC LIMIT 1;
    PERFORM backup_verification_record(v_mid, 'maybe', NULL, NULL);
    RAISE EXCEPTION 'accepted invalid status (test 3 fail)';
EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'backup_verification_record rejects invalid status';
END;
$body$;

-- ---------------------------------------------------------------------
-- Test 4: audit coverage.
-- ---------------------------------------------------------------------
SELECT event_kind, count(*) AS n FROM malu$audit_event
WHERE event_kind LIKE 'backup_%'
GROUP BY event_kind ORDER BY event_kind;

-- ---------------------------------------------------------------------
-- Cleanup.
-- ---------------------------------------------------------------------
DELETE FROM malu$backup_verification WHERE manifest_id = :'m_manifest_id'::bigint;
DELETE FROM malu$backup_manifest     WHERE manifest_id = :'m_manifest_id'::bigint;
DELETE FROM malu$audit_event         WHERE event_kind LIKE 'backup_%';
