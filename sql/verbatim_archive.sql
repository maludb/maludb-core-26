-- Stage 2 S2-2 — Verbatim Source Archive.
--
-- Exercises:
--   * seal_source_package → sealed_at + first verbatim_archive row
--   * immutability trigger rejects content UPDATE after seal
--   * verify_source_hash records audit row on match + mismatch
--   * unseal_source_package requires admin + reason; supersedes
--     prior archive rows
--   * archive_source_package transitions placement_tier
--   * tombstone_source_package nulls content unless legal_hold
--   * reingest_source_package returns canonical content + verifies
--     by default; raises on hash mismatch
--   * _validate_source_locator accepts the §3.6 reference keys

\set ECHO all
SET search_path = maludb_core, public;
SET client_min_messages = NOTICE;

-- ---------- fixture: one source package ----------------------------
SELECT register_source_package(
    p_source_type   => 'document',
    p_content_text  => 'Verbatim S2-2 fixture text.',
    p_media_type    => 'text/plain'
) AS sp_id \gset

SELECT content_hash IS NOT NULL AS has_hash,
       sealed_at IS NULL AS unsealed_initially,
       tombstoned_at IS NULL AS not_tombstoned
FROM malu$source_package WHERE source_package_id = :sp_id;

-- ---------- seal_source_package ------------------------------------
SELECT seal_source_package(:sp_id) AS first_archive_id \gset

SELECT sealed_at IS NOT NULL AS now_sealed
FROM malu$source_package WHERE source_package_id = :sp_id;

SELECT placement_tier, archive_hash = (SELECT content_hash FROM malu$source_package
                                       WHERE source_package_id = :sp_id) AS hash_matches,
       superseded_at IS NULL AS active
FROM malu$verbatim_archive WHERE archive_id = :first_archive_id;

-- Re-sealing is idempotent — returns the same archive_id.
SELECT :first_archive_id = seal_source_package(:sp_id) AS reseal_idempotent;

-- ---------- immutability after seal --------------------------------
DO $$
DECLARE v_sp_id bigint;
BEGIN
    SELECT source_package_id INTO v_sp_id FROM malu$source_package
     WHERE content_text = 'Verbatim S2-2 fixture text.';
    UPDATE malu$source_package SET content_text = 'tampered'
     WHERE source_package_id = v_sp_id;
    RAISE EXCEPTION 'should have rejected content UPDATE after seal';
EXCEPTION WHEN object_not_in_prerequisite_state THEN
    RAISE NOTICE 'OK: seal_lock trigger rejects content UPDATE';
END $$;

-- Non-content UPDATE (e.g., sensitivity) still works.
UPDATE malu$source_package SET sensitivity = 'restricted'
 WHERE source_package_id = :sp_id;
SELECT sensitivity FROM malu$source_package WHERE source_package_id = :sp_id;

-- ---------- verify_source_hash: matching ---------------------------
SELECT (verify_source_hash(:sp_id, 'after seal')).matched AS hash_matches_after_seal;

SELECT count(*) AS verification_rows
FROM malu$source_verification WHERE source_package_id = :sp_id;

-- ---------- verify mismatch path -----------------------------------
-- Lift the seal, corrupt content, re-seal with a deliberately wrong
-- content_hash to simulate corruption, verify — should record a
-- mismatch.
SELECT unseal_source_package(:sp_id, 'corruption test setup');

UPDATE malu$source_package
   SET content_hash = repeat('0', 64)        -- 64-hex stand-in for "wrong"
 WHERE source_package_id = :sp_id;

SELECT seal_source_package(:sp_id) > 0 AS resealed;

SELECT (verify_source_hash(:sp_id, 'mismatch probe')).matched AS hash_now_mismatches;

SELECT count(*) AS mismatch_rows
FROM malu$source_verification
WHERE source_package_id = :sp_id AND matched = false;

-- Restore the real hash so the rest of the test runs cleanly.
SELECT unseal_source_package(:sp_id, 'restore hash');
UPDATE malu$source_package
   SET content_hash = encode(sha256(convert_to(content_text, 'UTF8')), 'hex')
 WHERE source_package_id = :sp_id;
SELECT seal_source_package(:sp_id) > 0 AS resealed_clean;
SELECT (verify_source_hash(:sp_id, 'post-restore')).matched AS hash_restored;

-- ---------- reingest_source_package --------------------------------
SELECT (reingest_source_package(:sp_id)).content_text AS roundtrip_text;
SELECT (reingest_source_package(:sp_id)).source_type   AS roundtrip_type;

-- p_verify=false still returns content but no verification audit.
SELECT count(*) AS verifications_before_skip
FROM malu$source_verification WHERE source_package_id = :sp_id;

SELECT (reingest_source_package(:sp_id, p_verify=>false)).content_text AS skip_verify_text;

SELECT count(*) AS verifications_after_skip
FROM malu$source_verification WHERE source_package_id = :sp_id;
-- ^ same as before; skipped path didn't write a verification row.

-- ---------- archive_source_package: transition to cold tier --------
SELECT archive_source_package(
    :sp_id,
    p_placement_tier => 'cold',
    p_external_uri   => 's3://maludb-test/verbatim/' || :sp_id::text,
    p_external_etag  => 'etag-abc',
    p_note           => 'moved off-host'
) AS cold_archive_id \gset

SELECT placement_tier, external_uri, external_etag, superseded_at IS NULL AS active
FROM malu$verbatim_archive WHERE archive_id = :cold_archive_id;

-- Older archive rows were superseded.
SELECT count(*) AS superseded_archive_rows
FROM malu$verbatim_archive
WHERE source_package_id = :sp_id AND superseded_at IS NOT NULL;

-- archive_source_package CHECK: cold tier requires external_uri.
DO $$
DECLARE v_sp_id bigint;
BEGIN
    SELECT source_package_id INTO v_sp_id FROM malu$source_package
     WHERE content_text = 'Verbatim S2-2 fixture text.';
    PERFORM archive_source_package(v_sp_id, 'cold');
    RAISE EXCEPTION 'should have rejected cold without external_uri';
EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'OK: cold archive requires external_uri';
END $$;

-- ---------- tombstone_source_package: drops content (no legal hold)
SELECT tombstone_source_package(:sp_id, 'retention sweep');

SELECT tombstoned_at IS NOT NULL AS tombstoned,
       content_text IS NULL    AS content_cleared,
       sealed_at IS NOT NULL   AS resealed_empty
FROM malu$source_package WHERE source_package_id = :sp_id;

-- reingest of a content-tombstoned source raises.
DO $$
DECLARE v_sp_id bigint; v_r malu$reingest_result;
BEGIN
    SELECT source_package_id INTO v_sp_id FROM malu$source_package
     WHERE content_text IS NULL AND tombstoned_at IS NOT NULL
     ORDER BY source_package_id DESC LIMIT 1;
    v_r := reingest_source_package(v_sp_id, p_verify=>false);
    RAISE EXCEPTION 'should have raised SOURCE_TOMBSTONED';
EXCEPTION WHEN object_not_in_prerequisite_state THEN
    RAISE NOTICE 'OK: reingest rejects tombstoned source';
END $$;

-- ---------- legal_hold preserves content on tombstone --------------
SELECT register_source_package(
    p_source_type   => 'document',
    p_content_text  => 'Legal hold fixture.',
    p_media_type    => 'text/plain'
) AS lh_id \gset

UPDATE malu$source_package
   SET legal_hold = true, legal_hold_reason = 'litigation 2026-Q2'
 WHERE source_package_id = :lh_id;

SELECT seal_source_package(:lh_id) > 0 AS sealed;

SELECT tombstone_source_package(:lh_id, 'attempt during legal hold');

SELECT tombstoned_at IS NOT NULL AS tombstoned,
       content_text IS NOT NULL  AS content_retained,
       legal_hold AS still_on_hold
FROM malu$source_package WHERE source_package_id = :lh_id;

-- ---------- _validate_source_locator --------------------------------
SELECT _validate_source_locator(NULL)                              AS null_ok;
SELECT _validate_source_locator(jsonb_build_object(
    'document_id', 'doc-42',
    'page_no',     3,
    'byte_offset', 100,
    'message_id',  'mid-9')) AS rich_ok;

DO $$ BEGIN
    PERFORM _validate_source_locator(jsonb_build_object('page_no', 'three'));
    RAISE EXCEPTION 'should have rejected string page_no';
EXCEPTION WHEN invalid_parameter_value THEN
    RAISE NOTICE 'OK: page_no must be integer';
END $$;

DO $$ BEGIN
    PERFORM _validate_source_locator(jsonb_build_object('document_id', 42));
    RAISE EXCEPTION 'should have rejected integer document_id';
EXCEPTION WHEN invalid_parameter_value THEN
    RAISE NOTICE 'OK: document_id must be string';
END $$;

-- unknown keys are allowed (forward-compat).
SELECT _validate_source_locator(jsonb_build_object('custom_cursor', 'foo'))
       AS unknown_key_allowed;

-- ---------- unseal requires reason ---------------------------------
DO $$
DECLARE v_sp_id bigint;
BEGIN
    SELECT source_package_id INTO v_sp_id FROM malu$source_package
     WHERE content_text = 'Legal hold fixture.';
    PERFORM unseal_source_package(v_sp_id, '');
    RAISE EXCEPTION 'should have rejected empty reason';
EXCEPTION WHEN invalid_parameter_value THEN
    RAISE NOTICE 'OK: unseal requires non-empty reason';
END $$;

-- ---------- stage_boundary: verbatim_archive no longer flagged -----
SELECT count(*) AS verbatim_archive_still_flagged
FROM stage_boundary_violations()
WHERE object_name = 'malu$verbatim_archive';

-- ---------- cleanup -------------------------------------------------
DELETE FROM malu$source_verification WHERE source_package_id IN (:sp_id, :lh_id);
DELETE FROM malu$verbatim_archive    WHERE source_package_id IN (:sp_id, :lh_id);
UPDATE malu$source_package SET sealed_at = NULL
 WHERE source_package_id IN (:sp_id, :lh_id);
DELETE FROM malu$source_package WHERE source_package_id IN (:sp_id, :lh_id);
