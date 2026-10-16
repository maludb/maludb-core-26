-- Stage 5 S5-3 — Active Memory Pool manager.
--
-- Exercises (per requirements.md §3.12):
--   * create_active_memory_pool returns a pool_id; idempotent on
--     (owner_schema, pool_name).
--   * pool_add_observation rejects observation with object_id set
--     (CHECK constraint enforces observation has no object).
--   * pool_add_reference rejects 'observation' kind.
--   * The promotion path observation → pending_claim → fact preserves
--     provenance + records both intermediate audit_events.
--   * promoted_from_member_id and promoted_to_object_id+type captured.
--   * Lifecycle: sealed/archived/tombstoned pools refuse writes.
--   * max_member_count cap is enforced (cardinality_violation).
--   * Cross-tenant RLS: tenant B can't see A's pool members.
--   * skill_execution_record.active_pool_id FK now exists and a
--     skill execution can be bound to a pool.

\set ECHO all
SET search_path = maludb_core, public;
SET client_min_messages = NOTICE;

-- ---------- create a pool -------------------------------------------
SELECT create_active_memory_pool(
    p_pool_name      => 'incident-7421',
    p_creation_kind  => 'api',
    p_task_objective => 'Investigate api-gateway 5xx surge',
    p_authorized_partitions => ARRAY['prod','observability'],
    p_confidence_floor => 0.4,
    p_max_member_count => 6
) AS pool_id \gset

SELECT pool_name, creation_kind, lifecycle_state, confidence_floor,
       max_member_count
FROM malu$active_memory_pool WHERE pool_id = :pool_id;

-- Re-create with same name is idempotent.
SELECT create_active_memory_pool(
    p_pool_name      => 'incident-7421',
    p_creation_kind  => 'api',
    p_task_objective => 'Investigate api-gateway 5xx surge (refined)'
) = :pool_id AS reentrant_pool_id_stable;

SELECT task_objective LIKE '%(refined)' AS objective_updated
FROM malu$active_memory_pool WHERE pool_id = :pool_id;

-- ---------- observation: free-form working-set entry ---------------
SELECT pool_add_observation(
    p_pool_id    => :pool_id,
    p_payload_jsonb => jsonb_build_object('signal', '5xx_burst', 'window', '60s'),
    p_confidence => 0.7,
    p_provenance => jsonb_build_object('source','grafana-dashboard-12')
) AS obs_1 \gset

SELECT member_kind, member_object_id, confidence,
       provenance ->> 'source' AS provenance_source
FROM malu$active_memory_pool_member WHERE member_id = :obs_1;

-- ---------- pool_add_reference: link an existing memory ------------
SELECT register_memory(
    p_memory_kind => 'lesson',
    p_title       => 'Increase 5xx detection window',
    p_summary     => 'Earlier 30s window was missing the bursts.'
) AS mem_existing \gset

SELECT pool_add_reference(
    p_pool_id            => :pool_id,
    p_member_kind        => 'memory',
    p_member_object_type => 'memory',
    p_member_object_id   => :mem_existing,
    p_confidence         => 0.9
) AS mem_member \gset

-- Refusing 'observation' on pool_add_reference.
DO $body$
BEGIN
    PERFORM pool_add_reference(
        (SELECT pool_id FROM malu$active_memory_pool WHERE pool_name = 'incident-7421'),
        'observation', 'memory', 1);
    RAISE NOTICE 'UNEXPECTED: add_reference observation accepted';
EXCEPTION WHEN invalid_parameter_value THEN
    RAISE NOTICE 'OK: add_reference rejected observation kind';
END;
$body$;

-- ---------- promote observation → pending_claim ---------------------
SELECT pool_promote_to_claim(
    p_member_id      => :obs_1,
    p_subject        => 'api_gateway',
    p_verb           => 'observed',
    p_object_value   => '5xx_burst',
    p_statement_text => 'Burst confirmed in 60s window at 14:22Z.'
) AS claim_a \gset

-- Source member is now marked promoted.
SELECT promoted_to_object_type, promoted_to_object_id = :claim_a AS to_id_matches,
       promoted_at IS NOT NULL AS promoted_at_set
FROM malu$active_memory_pool_member WHERE member_id = :obs_1;

-- A new pending_claim member exists pointing at the new claim.
SELECT member_kind, member_object_type, member_object_id = :claim_a AS refs_claim,
       promoted_from_member_id = :obs_1 AS provenance_chain_intact
FROM malu$active_memory_pool_member
WHERE pool_id = :pool_id AND member_kind = 'pending_claim';

-- Double-promote rejected.
DO $body$
BEGIN
    PERFORM pool_promote_to_claim(
        (SELECT member_id FROM malu$active_memory_pool_member
         WHERE promoted_to_object_id IS NOT NULL ORDER BY member_id LIMIT 1),
        p_subject => 'x', p_verb => 'y');
    RAISE NOTICE 'UNEXPECTED: double-promotion accepted';
EXCEPTION WHEN object_not_in_prerequisite_state THEN
    RAISE NOTICE 'OK: double-promotion rejected';
END;
$body$;

-- ---------- promote pending_claim → fact ---------------------------
SELECT member_id AS pc_member FROM malu$active_memory_pool_member
 WHERE pool_id = :pool_id AND member_kind = 'pending_claim' \gset

SELECT pool_promote_to_fact(
    p_member_id           => :pc_member,
    p_subject             => 'api_gateway',
    p_verb                => 'verified_5xx_burst',
    p_object_value        => 'incident-7421',
    p_statement_text      => 'Verified: api-gateway 5xx burst confirmed.',
    p_verification_scope  => 'manual',
    p_verification_method => 'oncall_review'
) AS fact_a \gset

SELECT count(*) AS fact_member_rows
FROM malu$active_memory_pool_member
WHERE pool_id = :pool_id AND member_kind = 'fact'
  AND member_object_id = :fact_a;

-- pending_claim member is now marked promoted.
SELECT promoted_to_object_type, promoted_to_object_id = :fact_a AS to_fact_id
FROM malu$active_memory_pool_member WHERE member_id = :pc_member;

-- Fact has a claim_id linkage via malu$fact_claim
SELECT count(*) AS fact_claim_links
FROM malu$fact_claim WHERE fact_id = :fact_a;

-- ---------- skill execution binding to the pool --------------------
SELECT register_skill(
    p_skill_name      => 'incident_review',
    p_packaging_kind  => 'markdown',
    p_applicability_jsonb => '{}'::jsonb
) AS sk_id \gset
SELECT add_skill_state(:sk_id, 'gather',   'start');
SELECT add_skill_state(:sk_id, 'success',  'terminal');
SELECT add_skill_transition(:sk_id, 'gather', 'success', 'success');

SELECT begin_skill_execution(
    p_skill_id       => :sk_id,
    p_active_pool_id => :pool_id,
    p_task_objective => 'Review incident-7421'
) AS exec_id \gset

SELECT active_pool_id = :pool_id AS exec_bound_to_pool
FROM malu$skill_execution_record WHERE execution_id = :exec_id;

-- ---------- max_member_count enforcement ----------------------------
-- Pool capped at 6. We already have: obs_1, mem_member, pending_claim,
-- fact (4). Add two more references then attempt a third → cap fires.
SELECT pool_add_observation(:pool_id, jsonb_build_object('n',1)) AS obs_filler1 \gset
SELECT pool_add_observation(:pool_id, jsonb_build_object('n',2)) AS obs_filler2 \gset

DO $body$
BEGIN
    PERFORM pool_add_observation(
        (SELECT pool_id FROM malu$active_memory_pool WHERE pool_name = 'incident-7421'),
        jsonb_build_object('n',3));
    RAISE NOTICE 'UNEXPECTED: capacity overrun accepted';
EXCEPTION WHEN cardinality_violation THEN
    RAISE NOTICE 'OK: capacity overrun rejected';
END;
$body$;

-- ---------- lifecycle: seal then attempt add -----------------------
SELECT pool_seal(:pool_id, 'investigation closed');

SELECT lifecycle_state, sealed_at IS NOT NULL AS sealed_at_set
FROM malu$active_memory_pool WHERE pool_id = :pool_id;

DO $body$
BEGIN
    PERFORM pool_add_observation(
        (SELECT pool_id FROM malu$active_memory_pool WHERE pool_name = 'incident-7421'),
        jsonb_build_object('post_seal', true));
    RAISE NOTICE 'UNEXPECTED: write to sealed accepted';
EXCEPTION WHEN object_not_in_prerequisite_state THEN
    RAISE NOTICE 'OK: write to sealed rejected';
END;
$body$;

-- Promotions on a sealed pool also rejected.
DO $body$
DECLARE v_filler bigint := (SELECT member_id FROM malu$active_memory_pool_member
                            WHERE pool_id = (SELECT pool_id FROM malu$active_memory_pool WHERE pool_name = 'incident-7421')
                              AND member_kind = 'observation'
                              AND promoted_to_object_id IS NULL
                            ORDER BY member_id DESC LIMIT 1);
BEGIN
    PERFORM pool_promote_to_claim(v_filler, p_subject => 'late', p_verb => 'attempt');
    RAISE NOTICE 'UNEXPECTED: promote on sealed accepted';
EXCEPTION WHEN object_not_in_prerequisite_state THEN
    RAISE NOTICE 'OK: promote on sealed rejected';
END;
$body$;

-- archive then tombstone
SELECT pool_archive(:pool_id, 'aged out');
SELECT pool_tombstone(:pool_id, 'final purge');

SELECT lifecycle_state FROM malu$active_memory_pool WHERE pool_id = :pool_id;

-- ---------- cross-tenant RLS check ---------------------------------
DROP ROLE   IF EXISTS s53_user_a;
DROP ROLE   IF EXISTS s53_user_b;
DROP SCHEMA IF EXISTS s53_a CASCADE;
DROP SCHEMA IF EXISTS s53_b CASCADE;

CREATE ROLE s53_user_a NOLOGIN;
CREATE ROLE s53_user_b NOLOGIN;
GRANT maludb_memory_executor TO s53_user_a, s53_user_b;
GRANT USAGE ON SCHEMA maludb_core TO s53_user_a, s53_user_b;
CREATE SCHEMA s53_a AUTHORIZATION s53_user_a;
CREATE SCHEMA s53_b AUTHORIZATION s53_user_b;

SET ROLE s53_user_a;
SET search_path TO s53_a, maludb_core, public;
SELECT create_active_memory_pool('a_private', 'sql') AS a_pool \gset
SELECT pool_add_observation(:a_pool, jsonb_build_object('secret', 'A'));

SET ROLE s53_user_b;
SET search_path TO s53_b, maludb_core, public;
SELECT count(*) AS b_sees_a_pools
FROM maludb_core.malu$active_memory_pool WHERE pool_name = 'a_private';
SELECT count(*) AS b_sees_a_members
FROM maludb_core.malu$active_memory_pool_member;

RESET ROLE;
RESET search_path;
SET search_path = maludb_core, public;

-- ---------- audit emission summary ---------------------------------
SELECT event_kind, count(*) AS n
FROM malu$audit_event
WHERE event_kind IN (
    'active_memory_pool_created',
    'pool_observation_added',
    'pool_reference_added',
    'pool_member_promoted',
    'active_memory_pool_sealed',
    'active_memory_pool_archived',
    'active_memory_pool_tombstoned')
GROUP BY event_kind ORDER BY event_kind;

-- ---------- cleanup -----------------------------------------------
DELETE FROM malu$audit_event WHERE event_kind LIKE 'pool_%' OR event_kind LIKE 'active_memory_pool_%';
DELETE FROM malu$skill_execution_step    WHERE execution_id = :exec_id;
DELETE FROM malu$skill_execution_record  WHERE execution_id = :exec_id;
DELETE FROM malu$skill_transition        WHERE skill_id = :sk_id;
DELETE FROM malu$skill_state             WHERE skill_id = :sk_id;
DELETE FROM malu$skill_package           WHERE skill_id = :sk_id;
DELETE FROM malu$fact_claim              WHERE fact_id = :fact_a;
DELETE FROM malu$active_memory_pool_member WHERE pool_id = :pool_id;
DELETE FROM malu$active_memory_pool      WHERE pool_id = :pool_id;
DELETE FROM malu$fact                    WHERE fact_id = :fact_a;
DELETE FROM malu$claim                   WHERE claim_id = :claim_a;
DELETE FROM malu$memory                  WHERE memory_id = :mem_existing;
DROP SCHEMA s53_a CASCADE;
DROP SCHEMA s53_b CASCADE;
DROP OWNED BY s53_user_a;
DROP OWNED BY s53_user_b;
DROP ROLE   s53_user_a;
DROP ROLE   s53_user_b;
