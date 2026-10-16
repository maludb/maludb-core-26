-- V3-ENV-01 — preview environment catalog regression coverage.

SET search_path TO maludb_core, public;

-- ---------------------------------------------------------------------
-- Test 1: preview_env_create with the default (production_data=false)
-- seed_policy succeeds.
-- ---------------------------------------------------------------------
SELECT preview_env_create('pe_smoke', maludb_core_version(),
                          '{"production_data": false}'::jsonb,
                          NULL, 'V3-ENV-01 smoke') AS env_id \gset e_

SELECT name,
       base_migration = maludb_core_version() AS base_migration_current,
       current_migration = maludb_core_version() AS current_migration_current,
       COALESCE(anonymizer_ref, '<null>') AS anonymizer_ref
FROM malu$preview_env WHERE env_id = :'e_env_id'::bigint;

-- ---------------------------------------------------------------------
-- Test 2: seed_policy with production_data=true is rejected.
-- ---------------------------------------------------------------------
DO $body$
BEGIN
    PERFORM preview_env_create('pe_prod_bad', maludb_core_version(),
                               '{"production_data": true}'::jsonb,
                               NULL, NULL);
    RAISE EXCEPTION 'accepted production_data=true (test 2 fail)';
EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'preview_env_create rejects production_data=true';
END;
$body$;

-- ---------------------------------------------------------------------
-- Test 3: record a seed; promote_check reports the gates.
-- ---------------------------------------------------------------------
SELECT preview_env_record_seed(
    :'e_env_id'::bigint, 'sql_file',
    'file:///var/lib/maludb/preview-seeds/smoke.sql',
    '[{"path":"$.email","replace":"redacted@example.com"}]'::jsonb)
    AS seed_id \gset s_

SELECT gate, ok FROM preview_env_promote_check(:'e_env_id'::bigint) ORDER BY gate;

-- ---------------------------------------------------------------------
-- Test 4: list.
-- ---------------------------------------------------------------------
SELECT name, seed_count,
       current_migration = maludb_core_version() AS migration_current
FROM preview_env_list() WHERE name = 'pe_smoke';

-- ---------------------------------------------------------------------
-- Test 5: audit coverage.
-- ---------------------------------------------------------------------
SELECT event_kind, count(*) AS n FROM malu$audit_event
WHERE event_kind LIKE 'preview_env_%'
GROUP BY event_kind ORDER BY event_kind;

-- ---------------------------------------------------------------------
-- Cleanup.
-- ---------------------------------------------------------------------
DELETE FROM malu$preview_env_seed WHERE env_id = :'e_env_id'::bigint;
DELETE FROM malu$preview_env      WHERE env_id = :'e_env_id'::bigint;
DELETE FROM malu$audit_event      WHERE event_kind LIKE 'preview_env_%';
