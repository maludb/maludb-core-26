-- examples/03-pool-promotion.sql
--
-- Walkthrough of the Stage 5 Active Memory Pool (S5-3) promotion
-- path: observation → pending_claim → fact, preserving provenance
-- across the chain.

SET search_path = maludb_core, public;

DELETE FROM malu$audit_event WHERE event_kind LIKE 'pool_%'
   OR event_kind LIKE 'active_memory_pool_%';
DELETE FROM malu$active_memory_pool_member WHERE pool_id IN (
    SELECT pool_id FROM malu$active_memory_pool WHERE pool_name = 'ex03-incident');
DELETE FROM malu$active_memory_pool WHERE pool_name = 'ex03-incident';
DELETE FROM malu$fact_claim WHERE fact_id IN (
    SELECT fact_id FROM malu$fact WHERE statement_text LIKE 'ex03:%');
DELETE FROM malu$fact  WHERE statement_text LIKE 'ex03:%';
DELETE FROM malu$claim WHERE statement_text LIKE 'ex03:%';

-- ---------- create the pool ----------------------------------------
SELECT create_active_memory_pool(
    p_pool_name      => 'ex03-incident',
    p_creation_kind  => 'api',
    p_task_objective => 'ex03: investigate api-gateway latency spike',
    p_authorized_partitions => ARRAY['prod','observability'],
    p_confidence_floor => 0.3,
    p_max_member_count => 10
) AS pool \gset

-- ---------- add an observation -------------------------------------
SELECT pool_add_observation(
    p_pool_id => :pool,
    p_payload_jsonb => jsonb_build_object(
        'signal','5xx_burst','window_s',60,'note','ex03 raw sensor'),
    p_confidence => 0.7,
    p_provenance => jsonb_build_object('source','grafana-panel-12')
) AS obs \gset

\echo '=== observation row ==='
SELECT member_kind, confidence, provenance ->> 'source' AS source
FROM malu$active_memory_pool_member WHERE member_id = :obs;

-- ---------- promote to claim ---------------------------------------
\echo '=== promote observation → pending_claim ==='
SELECT pool_promote_to_claim(
    p_member_id      => :obs,
    p_subject        => 'api_gateway',
    p_verb           => 'observed',
    p_object_value   => '5xx_burst',
    p_statement_text => 'ex03: 5xx burst within 60s window'
) AS claim_id \gset

-- Source observation marked as promoted; a new pending_claim row
-- exists pointing to the new claim and back at the observation.
SELECT member_id, member_kind, member_object_id, promoted_from_member_id
FROM malu$active_memory_pool_member
WHERE pool_id = :pool ORDER BY member_id;

-- ---------- promote pending_claim → fact ---------------------------
\echo '=== promote pending_claim → fact ==='
SELECT pool_promote_to_fact(
    p_member_id => (
        SELECT member_id FROM malu$active_memory_pool_member
        WHERE pool_id = :pool AND member_kind = 'pending_claim'),
    p_subject        => 'api_gateway',
    p_verb           => 'verified_root_cause',
    p_object_value   => '5xx_burst',
    p_statement_text => 'ex03: oncall confirmed root cause',
    p_verification_scope  => 'manual',
    p_verification_method => 'oncall_review'
) AS fact_id \gset

-- The pool now carries: observation (promoted), pending_claim
-- (promoted), fact (new). Every row has provenance chain back to
-- the observation.
SELECT member_kind, member_object_type, member_object_id, promoted_from_member_id
FROM malu$active_memory_pool_member
WHERE pool_id = :pool ORDER BY member_id;

-- ---------- seal the pool ------------------------------------------
SELECT pool_seal(:pool, 'investigation closed');

SELECT lifecycle_state FROM malu$active_memory_pool WHERE pool_id = :pool;

\echo 'example 03 done.'
