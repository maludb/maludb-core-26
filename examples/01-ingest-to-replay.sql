-- examples/01-ingest-to-replay.sql
--
-- End-to-end Stage 2/3/4/5 walkthrough:
--   source package → claims → fact → episode + steps →
--   FTS → retrieval planner → replay → supersession correction.
--
-- Idempotent: re-running cleans up its own rows before re-inserting.

SET search_path = maludb_core, public;

DELETE FROM malu$audit_event WHERE event_jsonb ->> 'demo_tag' = 'ex01';
DELETE FROM malu$memory_detail_object WHERE title IN ('ex01-shift_traffic','ex01-health_check');
DELETE FROM malu$fact_claim
 WHERE fact_id IN (SELECT fact_id FROM malu$fact WHERE statement_text LIKE 'ex01:%');
DELETE FROM malu$supersession_edge
 WHERE successor_id IN (SELECT fact_id FROM malu$fact WHERE statement_text LIKE 'ex01:%')
    OR predecessor_id IN (SELECT fact_id FROM malu$fact WHERE statement_text LIKE 'ex01:%');
DELETE FROM malu$fact   WHERE statement_text LIKE 'ex01:%';
DELETE FROM malu$claim  WHERE statement_text LIKE 'ex01:%';
DELETE FROM malu$episode_replay
 WHERE episode_id IN (SELECT episode_id FROM malu$episode_object WHERE title = 'ex01-outage');
DELETE FROM malu$episode_object WHERE title = 'ex01-outage';
DELETE FROM malu$source_package
 WHERE content_text LIKE 'ex01:%';

-- ---------- 1. record the source -----------------------------------
SELECT register_source_package(
    p_source_type   => 'log',
    p_content_text  => 'ex01: 14:22Z api-gateway 5xx 18%/min for 60s',
    p_origin_jsonb  => jsonb_build_object('uri','log://oncall-bot/2026-05-13')
) AS sp_id \gset

-- ---------- 2. raise two claims ------------------------------------
SELECT register_claim(
    p_subject        => 'api_gateway',
    p_verb           => 'observed',
    p_object_value   => '5xx_burst',
    p_statement_text => 'ex01: initial 5xx surge at 14:22Z',
    p_source_package_id => :sp_id) AS c1 \gset

SELECT register_claim(
    p_subject        => 'api_gateway',
    p_verb           => 'timed_out',
    p_object_value   => 'health_probe',
    p_statement_text => 'ex01: health probe exceeded 2s',
    p_source_package_id => :sp_id) AS c2 \gset

-- ---------- 3. verify into a fact -----------------------------------
SELECT register_fact(
    p_claim_ids => ARRAY[:c1, :c2]::bigint[],
    p_subject        => 'api_gateway',
    p_verb           => 'incident',
    p_object_value   => 'latency_breach',
    p_statement_text => 'ex01: latency SLO breach (initial)',
    p_verification_scope  => 'manual',
    p_verification_method => 'oncall_review') AS f1 \gset

-- ---------- 4. capture episode + steps -----------------------------
SELECT register_episode(
    p_episode_kind => 'incident',
    p_title        => 'ex01-outage',
    p_summary      => 'Two-step deploy with one validation failure.',
    p_payload_jsonb => jsonb_build_object(
        'subject_class','api_gateway','environment','prod')) AS ep \gset

INSERT INTO malu$memory_detail_object
    (episode_id, detail_kind, ordinal, title, body_jsonb)
VALUES
    (:ep, 'step', 1, 'ex01-shift_traffic',
     jsonb_build_object('action_class','traffic_shift','actor','release-bot',
                        'tool','kubectl','outcome','success')),
    (:ep, 'step', 2, 'ex01-health_check',
     jsonb_build_object('action_class','health_probe','actor','ci',
                        'tool','curl','outcome','failure',
                        'exception','LatencySLOBreach'));

-- ---------- 5a. FTS -----------------------------------------------
\echo '=== text_search latency breach ==='
SELECT object_type, object_id, title_or_subject
FROM text_search('latency breach', ARRAY['claim','fact','episode_object'])
ORDER BY rank DESC, object_id;

-- ---------- 5b. retrieval planner ---------------------------------
\echo '=== execute_retrieval api_gateway ==='
SELECT object_type, object_id, strategy
FROM execute_retrieval(
    ROW('api_gateway',
        ARRAY['claim','fact','memory','episode_object']::text[],
        NULL, NULL, NULL, NULL)::malu$retrieval_envelope_t,
    NULL, 10)
ORDER BY rank DESC, object_id;

-- ---------- 5c. episode replay (current_valid) --------------------
\echo '=== replay_episode current_valid (shape only) ==='
SELECT jsonb_object_keys(replay_episode(:ep, 'current_valid')) AS envelope_key
ORDER BY 1;

-- ---------- 6. correct the fact via supersession ------------------
\echo '=== correct_fact ==='
SELECT correct_fact(
    p_fact_id            => :f1,
    p_new_object_value   => 'pool_exhaustion',
    p_reason             => 'oncall determined connection pool exhaustion'
);

\echo '=== replay later_changes after correction ==='
SELECT jsonb_array_length(
    replay_episode(:ep, 'current_valid') -> 'later_changes')
       AS later_changes_count;

\echo 'example 01 done.'
