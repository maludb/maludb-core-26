-- Stage 2 S2-7 — multi-model atomic insertion.
--
-- Exercises:
--   * ingest_claim_atomic creates source + claim + ledger in one tx
--   * promote_claim_to_fact_atomic creates fact + fact_claim + ledger
--   * a forced failure mid-chain rolls back the entire transaction
--   * non-existent claim_id in promote → raises, no fact written

\set ECHO all
SET search_path = maludb_core, public;
SET client_min_messages = NOTICE;

-- ---------- ingest_claim_atomic: happy path -------------------------
SELECT ingest_claim_atomic(
    p_source_type    => 'document',
    p_source_text    => 'Atomic ingest fixture: a 2026 incident report.',
    p_subject        => 'incident-42',
    p_verb           => 'caused_by',
    p_object_value   => 'connection_pool_exhaustion',
    p_statement_text => 'Incident 42 was caused by pool exhaustion at 14:22 UTC.',
    p_parser_name    => 'incident_extractor_v1',
    p_origin_jsonb   => jsonb_build_object('producer','test_harness'),
    p_source_locator => jsonb_build_object('line', 1, 'page_no', 1),
    p_inputs_jsonb   => jsonb_build_object('source_id_placeholder', 0)
) AS claim_a \gset

-- All three rows present
SELECT count(*) AS sources_for_claim_a
FROM malu$source_package WHERE source_package_id = (
    SELECT source_package_id FROM malu$claim WHERE claim_id = :claim_a);
SELECT count(*) AS claim_rows FROM malu$claim WHERE claim_id = :claim_a;
SELECT count(*) AS ledger_rows
FROM malu$derivation_ledger
WHERE derived_object_type = 'claim' AND derived_object_id = :claim_a;

-- ---------- a second claim to support promotion ---------------------
SELECT ingest_claim_atomic(
    p_source_type    => 'log',
    p_source_text    => 'pool_size=10 active=10 wait_queue=42 ts=14:22:01Z',
    p_subject        => 'incident-42',
    p_verb           => 'measured_at',
    p_object_value   => '14:22:01Z',
    p_statement_text => 'At 14:22:01Z, pool was saturated with 42 waiters.',
    p_parser_name    => 'log_extractor_v1'
) AS claim_b \gset

-- ---------- promote_claim_to_fact_atomic: happy path ----------------
SELECT promote_claim_to_fact_atomic(
    p_claim_ids           => ARRAY[:claim_a, :claim_b]::bigint[],
    p_subject             => 'incident-42',
    p_verb                => 'root_cause',
    p_object_value        => 'connection_pool_exhaustion',
    p_statement_text      => 'Verified root cause via log + extracted narrative.',
    p_verification_scope  => 'incident-postmortem',
    p_verification_method => 'manual + log_corroboration',
    p_parser_name         => 'manual',
    p_verifier_name       => 'sre-on-call'
) AS fact_id \gset

SELECT subject, verb, verification_scope, lifecycle_state
FROM malu$fact WHERE fact_id = :fact_id;

-- Both claims linked
SELECT count(*) AS claims_under_fact
FROM malu$fact_claim WHERE fact_id = :fact_id;

-- Ledger row present
SELECT count(*) AS fact_ledger_rows
FROM malu$derivation_ledger
WHERE derived_object_type = 'fact' AND derived_object_id = :fact_id;

-- ---------- promote with a bogus claim_id raises --------------------
SELECT promote_claim_to_fact_atomic(
    p_claim_ids => ARRAY[:claim_a, 999999999]::bigint[],
    p_subject   => 'should-not-exist',
    p_verb      => 'test',
    p_statement_text => 'should be rolled back'
);

-- No new fact row was created (atomicity)
SELECT count(*) AS fact_rows_with_test_subject
FROM malu$fact WHERE subject = 'should-not-exist';

-- ---------- ingest with NULL required args raises -------------------
-- p_source_type is required
SELECT ingest_claim_atomic(NULL, 'text body');

-- p_source_text is required (v1; v2 may accept jsonb/bytea)
SELECT ingest_claim_atomic('document', NULL);

-- ---------- cleanup -------------------------------------------------
DELETE FROM malu$derivation_ledger
 WHERE derived_object_id IN (
    SELECT claim_id FROM malu$claim
     WHERE claim_id IN (:claim_a, :claim_b))
   AND derived_object_type = 'claim';
DELETE FROM malu$derivation_ledger
 WHERE derived_object_id = :fact_id AND derived_object_type = 'fact';
DELETE FROM malu$fact_claim WHERE fact_id = :fact_id;
DELETE FROM malu$fact WHERE fact_id = :fact_id;
DELETE FROM malu$claim WHERE claim_id IN (:claim_a, :claim_b);
DELETE FROM malu$source_package
 WHERE source_package_id IN (
    SELECT source_package_id FROM malu$claim
     WHERE claim_id IN (:claim_a, :claim_b));
