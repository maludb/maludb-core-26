-- Stage 2 S2-9 — pgaudit + pg_stat_statements wiring.
--
-- Exercises:
--   * audit_status() reports per-extension presence + preload state
--   * audit_event(...) writes governance rows under RLS
--   * retrofitted seal/unseal/tombstone/grant/revoke emit audit rows
--   * pgaudit_recommended_settings() returns the config text block
--   * malu$query_stats view is conditionally created when
--     pg_stat_statements is installed (skipped on regression boxes
--     without the preload)

\set ECHO all
SET search_path = maludb_core, public;
SET client_min_messages = NOTICE;

-- ---------- audit_status -------------------------------------------
SELECT component, available,
       length(note) > 0 AS has_note
FROM audit_status()
ORDER BY component COLLATE "C";

-- pgaudit_recommended_settings yields a non-empty text block
SELECT length(pgaudit_recommended_settings()) > 100 AS recipe_size_ok;
SELECT pgaudit_recommended_settings() LIKE '%shared_preload_libraries%' AS recipe_has_preload;
SELECT pgaudit_recommended_settings() LIKE '%pgaudit.log%' AS recipe_has_pgaudit_log;

-- ---------- audit_event direct write -------------------------------
SELECT audit_event(
    p_event_kind         => 'test_event',
    p_target_object_type => 'memory',
    p_target_object_id   => 42,
    p_event_jsonb        => jsonb_build_object('note','manual call')
) > 0 AS direct_write_ok;

SELECT count(*) AS test_events
FROM malu$audit_event WHERE event_kind = 'test_event';

-- ---------- retrofitted seal_source_package writes audit row -------
SELECT register_source_package(
    p_source_type   => 'document',
    p_content_text  => 'S2-9 governance audit fixture.'
) AS sp_id \gset

SELECT count(*) AS audit_before_seal
FROM malu$audit_event
WHERE event_kind = 'seal_source_package' AND target_object_id = :sp_id;

SELECT seal_source_package(:sp_id) > 0 AS sealed;

SELECT count(*) AS audit_after_seal,
       (event_jsonb ->> 'placement_tier') AS placement_in_audit
FROM malu$audit_event
WHERE event_kind = 'seal_source_package' AND target_object_id = :sp_id
GROUP BY placement_in_audit;

-- ---------- unseal + tombstone audit -------------------------------
SELECT unseal_source_package(:sp_id, 'governance audit test') IS NULL AS unsealed;

SELECT event_kind, event_jsonb ->> 'reason' AS reason
FROM malu$audit_event
WHERE target_object_id = :sp_id AND event_kind = 'unseal_source_package';

-- re-seal so tombstone has something to clear
SELECT seal_source_package(:sp_id) > 0 AS resealed;

SELECT tombstone_source_package(:sp_id, 'retention sweep audit test') IS NULL AS tombstoned;

SELECT event_kind, (event_jsonb ->> 'legal_hold')::boolean AS legal_hold_recorded
FROM malu$audit_event
WHERE target_object_id = :sp_id AND event_kind = 'tombstone_source_package';

-- ---------- retrofitted grant/revoke writes audit ------------------
-- Need a target row first
SELECT register_memory(p_memory_kind => 'event', p_title => 'audit target') AS mem_id \gset

-- Set up tenant schemas so the cross-tenant grant test fires
DROP SCHEMA IF EXISTS s29_a CASCADE;
DROP SCHEMA IF EXISTS s29_b CASCADE;
CREATE SCHEMA s29_a;
CREATE SCHEMA s29_b;

SELECT grant_object_access(
    'memory', :mem_id, 's29_b'::name, 'read'
) AS grant_id \gset

SELECT event_kind, event_jsonb ->> 'grant_level' AS lvl
FROM malu$audit_event
WHERE event_kind IN ('grant','grant_upgrade')
  AND target_object_id = :mem_id
ORDER BY event_id DESC LIMIT 1;

-- Upgrade emits 'grant_upgrade'
SELECT grant_object_access(
    'memory', :mem_id, 's29_b'::name, 'write'
);

SELECT event_kind FROM malu$audit_event
WHERE target_object_id = :mem_id
ORDER BY event_id DESC LIMIT 2;

-- Revoke
SELECT revoke_object_grant(:grant_id, 'audit test') IS NULL AS revoked;

SELECT event_kind FROM malu$audit_event
WHERE target_object_id = :mem_id
ORDER BY event_id DESC LIMIT 1;

-- ---------- malu$query_stats — only present when extension is too --
SELECT EXISTS (
    SELECT 1 FROM pg_views WHERE viewname = 'malu$query_stats'
      AND schemaname = 'maludb_core'
) AS query_stats_view_present;

-- attach helper is idempotent + no-op on systems without pg_stat_statements
SELECT maludb_core_attach_stat_statements_view() IS NULL AS attach_returns_void;

-- ---------- cleanup -------------------------------------------------
DELETE FROM malu$audit_event
 WHERE target_object_id IN (:sp_id, :mem_id) OR event_kind = 'test_event';
DELETE FROM malu$object_grant WHERE object_id = :mem_id;
DELETE FROM malu$memory WHERE memory_id = :mem_id;
DELETE FROM malu$verbatim_archive WHERE source_package_id = :sp_id;
DELETE FROM malu$source_package WHERE source_package_id = :sp_id;
DROP SCHEMA s29_a CASCADE;
DROP SCHEMA s29_b CASCADE;
