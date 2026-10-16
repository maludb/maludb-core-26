-- Stage 2 S2-1 + S2-3 — memory object model + Derivation Ledger.
--
-- Exercises:
--   * register_* helpers for each of the seven object types
--   * source_package content-hash dedupe property
--   * fact aggregates one or more claims via malu$fact_claim
--   * memory_detail_object recursive nesting (parent_mdo_id chain)
--   * relationship_edge polymorphic source/target
--   * record_derivation writes a ledger row with stable inputs_hash
--   * stage_boundary_violations() returns 0 after S2-1 installs the
--     real Stage 2 tables

\set ECHO all
SET search_path = maludb_core, public;
SET client_min_messages = NOTICE;

-- ---------- source package ------------------------------------------
SELECT register_source_package(
    p_source_type   => 'document',
    p_content_text  => 'The 2026-05-13 R1.1 sign-off notes.',
    p_media_type    => 'text/plain',
    p_origin_jsonb  => jsonb_build_object('producer','test_harness','connector','manual')
) AS source_pkg_id \gset

SELECT source_type, content_size, sensitivity, retention_class,
       content_hash IS NOT NULL AS has_hash
FROM malu$source_package WHERE source_package_id = :source_pkg_id;

-- Same content → same content_hash (dedupe property)
SELECT register_source_package(
    p_source_type   => 'document',
    p_content_text  => 'The 2026-05-13 R1.1 sign-off notes.',
    p_media_type    => 'text/plain'
) AS source_pkg_id2 \gset

SELECT a.content_hash = b.content_hash AS hash_stable
FROM   malu$source_package a, malu$source_package b
WHERE  a.source_package_id = :source_pkg_id
  AND  b.source_package_id = :source_pkg_id2;

-- ---------- claim referencing the source ----------------------------
SELECT register_claim(
    p_subject           => 'MaluDB',
    p_verb              => 'shipped',
    p_predicate         => 'release_track',
    p_object_value      => 'R1.1',
    p_statement_text    => 'MaluDB R1.1 shipped on 2026-05-13.',
    p_source_package_id => :source_pkg_id,
    p_source_locator    => jsonb_build_object('line', 1)
) AS claim1_id \gset

SELECT register_claim(
    p_subject        => 'MaluDB',
    p_verb           => 'has_phase_count',
    p_object_value   => '17',
    p_statement_text => 'R1.1 covered 17 distinct phases.',
    p_source_package_id => :source_pkg_id
) AS claim2_id \gset

SELECT subject, verb, object_value, source_package_id = :source_pkg_id AS linked
FROM malu$claim WHERE claim_id IN (:claim1_id, :claim2_id) ORDER BY claim_id;

-- ---------- fact aggregating both claims ----------------------------
SELECT register_fact(
    p_claim_ids       => ARRAY[:claim1_id, :claim2_id]::bigint[],
    p_subject         => 'MaluDB',
    p_verb            => 'release_status',
    p_object_value    => 'R1.1 shipped, 17 phases',
    p_statement_text  => 'Verified from sign-off notes.',
    p_verification_scope  => 'release_log',
    p_verification_method => 'manual_review'
) AS fact_id \gset

SELECT subject, verb, verification_scope, lifecycle_state
FROM malu$fact WHERE fact_id = :fact_id;

SELECT count(*) AS claims_supporting_fact
FROM malu$fact_claim WHERE fact_id = :fact_id;

-- ---------- episode + memory + nested MDO chain ---------------------
SELECT register_episode(
    p_episode_kind => 'release_cut',
    p_title        => 'R1.1 sign-off',
    p_summary      => 'Tagged v1.1.0 after all 24 pg_regress + 28 mc2dbd tests passed.',
    p_payload_jsonb => jsonb_build_object('tag','v1.1.0','tests_pg','24','tests_mc2dbd','28')
) AS episode_id \gset

SELECT register_memory(
    p_memory_kind  => 'lesson',
    p_title        => 'SPI memory context lifetime',
    p_summary      => 'SPI_finish frees children of SPI proc cxt — anchor build_cxt at caller_cxt instead.',
    p_payload_jsonb => jsonb_build_object('phase','R1.1-16','severity','high')
) AS memory_id \gset

-- Top-level MDO under the episode
SELECT register_memory_detail(
    p_detail_kind => 'step',
    p_episode_id  => :episode_id,
    p_ordinal     => 1,
    p_title       => 'Run installcheck',
    p_body_text   => 'make installcheck PG_CONFIG=...'
) AS mdo_step \gset

-- Nested MDO under the step
SELECT register_memory_detail(
    p_detail_kind   => 'validation',
    p_parent_mdo_id => :mdo_step,
    p_ordinal       => 1,
    p_title         => 'Verify 24/24 pass',
    p_body_text     => 'All tests must report ok 1..24.'
) AS mdo_validation \gset

-- Recursive walk — verify the nesting structure
SELECT count(*) AS mdos_under_episode
FROM malu$memory_detail_object WHERE episode_id = :episode_id;
SELECT count(*) AS mdos_under_step
FROM malu$memory_detail_object WHERE parent_mdo_id = :mdo_step;

-- ---------- relationship edges (polymorphic) ------------------------
SELECT register_relationship_edge(
    p_source_object_type => 'memory',
    p_source_object_id   => :memory_id,
    p_target_object_type => 'episode_object',
    p_target_object_id   => :episode_id,
    p_relationship_type  => 'part_of',
    p_label              => 'lesson learned during this episode',
    p_confidence         => 0.95
) AS edge1 \gset

SELECT register_relationship_edge(
    p_source_object_type => 'fact',
    p_source_object_id   => :fact_id,
    p_target_object_type => 'episode_object',
    p_target_object_id   => :episode_id,
    p_relationship_type  => 'supports',
    p_confidence         => 1.0
) AS edge2 \gset

SELECT source_object_type, target_object_type, relationship_type, confidence
FROM malu$relationship_edge
WHERE edge_id IN (:edge1, :edge2)
ORDER BY edge_id;

-- ---------- derivation ledger ---------------------------------------
SELECT record_derivation(
    p_derived_object_type => 'fact',
    p_derived_object_id   => :fact_id,
    p_parser_name         => 'r11_signoff_parser',
    p_policy_name         => 'manual_review',
    p_verifier_name       => 'ed',
    p_inputs_jsonb        => jsonb_build_array(
        jsonb_build_object('claim_id', :claim1_id),
        jsonb_build_object('claim_id', :claim2_id))
) AS ledger_id \gset

SELECT derived_object_type, parser_name, policy_name, verifier_name,
       inputs_hash IS NOT NULL AS has_hash
FROM malu$derivation_ledger WHERE derivation_id = :ledger_id;

-- inputs_hash stability — same inputs → same hash
SELECT record_derivation(
    p_derived_object_type => 'fact',
    p_derived_object_id   => :fact_id,
    p_parser_name         => 'r11_signoff_parser',
    p_inputs_jsonb        => jsonb_build_array(
        jsonb_build_object('claim_id', :claim1_id),
        jsonb_build_object('claim_id', :claim2_id))
) AS ledger_id2 \gset

SELECT a.inputs_hash = b.inputs_hash AS hash_stable
FROM malu$derivation_ledger a, malu$derivation_ledger b
WHERE a.derivation_id = :ledger_id AND b.derivation_id = :ledger_id2;

-- ---------- bad inputs / required-arg rejections --------------------
DO $$ BEGIN
    PERFORM register_source_package(p_source_type => 'document');
    RAISE EXCEPTION 'should have rejected empty content';
EXCEPTION WHEN invalid_parameter_value THEN
    RAISE NOTICE 'OK: source_package needs at least one content slot';
END $$;

DO $$ BEGIN
    PERFORM register_memory_detail(p_detail_kind => 'orphan');
    RAISE EXCEPTION 'should have rejected orphan MDO';
EXCEPTION WHEN invalid_parameter_value THEN
    RAISE NOTICE 'OK: memory_detail needs parent_mdo / memory / or episode';
END $$;

-- ---------- stage_boundary still happy ------------------------------
SELECT count(*) AS s3_plus_violations
FROM stage_boundary_violations()
WHERE stage >= 2;
-- ↑ Stage 2 tables we installed shouldn't be flagged; only Stage 3+
-- placeholders remain forbidden. The S2-2 (verbatim_archive) and
-- malu$governed_object slots ARE still in the forbidden list because
-- we haven't installed those tables yet.

-- ---------- cleanup -------------------------------------------------
DELETE FROM malu$derivation_ledger
 WHERE derivation_id IN (:ledger_id, :ledger_id2);
DELETE FROM malu$relationship_edge
 WHERE edge_id IN (:edge1, :edge2);
DELETE FROM malu$memory_detail_object
 WHERE mdo_id IN (:mdo_validation, :mdo_step);
DELETE FROM malu$memory   WHERE memory_id  = :memory_id;
DELETE FROM malu$episode_object WHERE episode_id = :episode_id;
DELETE FROM malu$fact_claim WHERE fact_id = :fact_id;
DELETE FROM malu$fact     WHERE fact_id   = :fact_id;
DELETE FROM malu$claim    WHERE claim_id IN (:claim1_id, :claim2_id);
DELETE FROM malu$source_package
 WHERE source_package_id IN (:source_pkg_id, :source_pkg_id2);
