-- Stage 2 S2-8 — ingestion contracts.
--
-- Exercises:
--   * register_connector upserts by (owner_schema, connector_name)
--   * advance_checkpoint creates + updates per-(connector, cursor_name)
--   * propose_pending_claim queues candidates
--   * accept_pending_claim promotes → malu$claim + ledger + state=accepted
--   * reject_pending_claim is non-destructive
--   * accept of an already-accepted row raises
--   * list_pending_claims returns only review_state='pending'

\set ECHO all
SET search_path = maludb_core, public;
SET client_min_messages = NOTICE;

-- ---------- register a connector + checkpoint ------------------------
SELECT register_connector(
    p_connector_name => 'test_slack',
    p_connector_kind => 'slack',
    p_source_type    => 'conversation',
    p_config_jsonb   => jsonb_build_object(
        'workspace_id','T-TEST', 'secret_ref','vault://slack/test')
) AS conn_id \gset

SELECT connector_name, connector_kind, source_type, enabled
FROM malu$ingestion_connector WHERE connector_id = :conn_id;

-- upsert: re-register replaces config
SELECT register_connector(
    p_connector_name => 'test_slack',
    p_connector_kind => 'slack',
    p_source_type    => 'conversation',
    p_config_jsonb   => jsonb_build_object('workspace_id','T-NEW')
) AS conn_id_again \gset

SELECT :conn_id = :conn_id_again AS connector_id_stable;
SELECT config_jsonb ->> 'workspace_id' AS workspace_after_upsert
FROM malu$ingestion_connector WHERE connector_id = :conn_id;

-- ---------- advance_checkpoint ---------------------------------------
-- First advance — creates the row, format defaults to 'opaque'.
SELECT advance_checkpoint(
    p_connector_id  => :conn_id,
    p_cursor_value  => '2026-05-13T00:00:00Z',
    p_cursor_format => 'timestamp',
    p_items_added   => 5
) AS ckpt_id \gset

SELECT cursor_name, cursor_format, cursor_value, items_ingested, last_error
FROM malu$ingestion_checkpoint WHERE checkpoint_id = :ckpt_id;

-- Second advance — same cursor_name, moves the value forward.
SELECT advance_checkpoint(
    p_connector_id  => :conn_id,
    p_cursor_value  => '2026-05-13T00:05:00Z',
    p_items_added   => 12
) AS ckpt_again \gset

SELECT :ckpt_id = :ckpt_again AS ckpt_id_stable;
SELECT cursor_value, items_ingested
FROM malu$ingestion_checkpoint WHERE checkpoint_id = :ckpt_id;

-- Failure advance — preserves prior cursor_value, records last_error.
SELECT advance_checkpoint(
    p_connector_id => :conn_id,
    p_last_error   => 'upstream 503 Service Unavailable'
);

SELECT cursor_value, last_error IS NOT NULL AS has_error,
       last_advanced_at < last_attempt_at AS attempt_after_advance
FROM malu$ingestion_checkpoint WHERE checkpoint_id = :ckpt_id;

-- ---------- propose_pending_claim ------------------------------------
-- Make a source first
SELECT register_source_package(
    p_source_type   => 'conversation',
    p_content_text  => '#incident: pool exhausted at 14:22Z',
    p_origin_jsonb  => jsonb_build_object('producer','test_slack')
) AS src_id \gset

SELECT propose_pending_claim(
    p_connector_id      => :conn_id,
    p_source_package_id => :src_id,
    p_subject           => 'incident-42',
    p_verb              => 'reported_via',
    p_object_value      => 'slack',
    p_statement_text    => 'Slack reported the incident.',
    p_source_locator    => jsonb_build_object('message_id','M-001'),
    p_confidence        => 0.85,
    p_proposed_by       => 'auto_extractor_v1'
) AS pending_a \gset

SELECT propose_pending_claim(
    p_connector_id      => :conn_id,
    p_source_package_id => :src_id,
    p_subject           => 'pool',
    p_verb              => 'saturated_at',
    p_object_value      => '14:22Z',
    p_statement_text    => 'Pool went to capacity at 14:22Z.',
    p_confidence        => 0.92
) AS pending_b \gset

-- ---------- list_pending_claims --------------------------------------
SELECT count(*) AS pending_count
FROM list_pending_claims(p_connector_id => :conn_id);

SELECT subject, verb, object_value, confidence
FROM list_pending_claims(p_connector_id => :conn_id)
ORDER BY proposed_at, pending_claim_id;

-- ---------- accept_pending_claim -------------------------------------
SELECT accept_pending_claim(
    p_pending_claim_id => :pending_a,
    p_reviewer         => 'sre-on-call',
    p_review_note      => 'matches event log',
    p_parser_name      => 'incident_extractor_v1'
) AS accepted_claim_id \gset

-- Pending row state transitioned
SELECT review_state, promoted_claim_id = :accepted_claim_id AS claim_linked,
       reviewed_by
FROM malu$pending_claim WHERE pending_claim_id = :pending_a;

-- The real malu$claim row exists with the proposed shape
SELECT subject, verb, object_value, source_package_id = :src_id AS sources_linked
FROM malu$claim WHERE claim_id = :accepted_claim_id;

-- Derivation ledger row written for the accepted claim
SELECT count(*) AS ledger_rows_for_accepted
FROM malu$derivation_ledger
WHERE derived_object_type = 'claim'
  AND derived_object_id   = :accepted_claim_id;

-- Inputs manifest captured connector + source linkage
SELECT inputs_jsonb ? 'pending_claim_id'  AS has_pending_id,
       inputs_jsonb ? 'connector_id'      AS has_connector_id,
       inputs_jsonb ? 'source_package_id' AS has_source_id
FROM malu$derivation_ledger
WHERE derived_object_type = 'claim'
  AND derived_object_id   = :accepted_claim_id;

-- ---------- accept twice → raises ------------------------------------
SELECT accept_pending_claim(
    p_pending_claim_id => :pending_a,
    p_reviewer         => 'someone_else'
);

-- ---------- reject_pending_claim -------------------------------------
SELECT reject_pending_claim(
    p_pending_claim_id => :pending_b,
    p_reviewer         => 'sre-on-call',
    p_review_note      => 'duplicate of pending_a verb-shape',
    p_final_state      => 'duplicate'
) IS NULL AS rejected;

SELECT review_state, reviewed_by FROM malu$pending_claim
WHERE pending_claim_id = :pending_b;

-- list now empty for this connector
SELECT count(*) AS pending_count_after_resolution
FROM list_pending_claims(p_connector_id => :conn_id);

-- bad final_state rejected
SELECT reject_pending_claim(:pending_b, 'x', 'y', p_final_state => 'bogus');

-- ---------- cleanup --------------------------------------------------
DELETE FROM malu$derivation_ledger WHERE derived_object_id = :accepted_claim_id
                                     AND derived_object_type = 'claim';
DELETE FROM malu$claim WHERE claim_id = :accepted_claim_id;
DELETE FROM malu$pending_claim WHERE pending_claim_id IN (:pending_a, :pending_b);
DELETE FROM malu$source_package WHERE source_package_id = :src_id;
DELETE FROM malu$ingestion_checkpoint WHERE connector_id = :conn_id;
DELETE FROM malu$ingestion_connector WHERE connector_id = :conn_id;
