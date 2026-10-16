-- Stage 4 S4-3 — retrieval planner.
--
-- Exercises:
--   * extract_cues handles phrases / time markers / SVPOR-resolved
--     tokens / unresolved terms
--   * classify_intent picks correctly across the closed taxonomy
--   * select_search_paths produces the expected strategy ordering
--     per intent
--   * plan_retrieval composes the pipeline end-to-end
--   * record_retrieval_envelope persists for replay

\set ECHO all
SET search_path = maludb_core, public;
SET client_min_messages = NOTICE;

-- ---------- SVPOR registry setup -----------------------------------
SELECT register_svpor_subject('postgres_pool', ARRAY['pg_pool','pool']) > 0 AS sj;
SELECT register_svpor_verb('exhausted',       ARRAY['saturated']) > 0 AS sv;
SELECT register_svpor_predicate('cap')                                > 0 AS sp;

-- ---------- extract_cues -------------------------------------------
SELECT cue_kind, cue_value, weight
FROM extract_cues('"pool exhaustion" pool exhausted cap during outage as of 2026-05-13')
ORDER BY weight DESC, cue_kind, cue_value;

-- ---------- classify_intent ----------------------------------------
-- Two SVPOR cues → narrow
SELECT classify_intent(ROW('postgres_pool exhausted cap',
                           ARRAY['fact']::text[], NULL, NULL, NULL, NULL)
                       ::malu$retrieval_envelope_t) AS narrow_intent;

-- "show me" prefix → recall
SELECT classify_intent(ROW('show me anything about widgets',
                           ARRAY['claim']::text[], NULL, NULL, NULL, NULL)
                       ::malu$retrieval_envelope_t) AS recall_intent;

-- valid_as_of set → time_as_of
SELECT classify_intent(ROW('anything',
                           ARRAY['fact']::text[],
                           '2026-01-01 00:00Z'::timestamptz,
                           NULL, NULL, NULL)
                       ::malu$retrieval_envelope_t) AS time_intent;

-- confidence_floor set → by_confidence
SELECT classify_intent(ROW('anything',
                           ARRAY['fact']::text[], NULL, NULL, 0.8::numeric, NULL)
                       ::malu$retrieval_envelope_t) AS confidence_intent;

-- source_package_id hint → by_source
SELECT classify_intent(ROW('anything',
                           ARRAY['claim']::text[], NULL, NULL, NULL,
                           jsonb_build_object('source_package_id', 42))
                       ::malu$retrieval_envelope_t) AS source_intent;

-- Plain text with no SVPOR matches, no prefix → broad
SELECT classify_intent(ROW('plain free text',
                           ARRAY['fact']::text[], NULL, NULL, NULL, NULL)
                       ::malu$retrieval_envelope_t) AS broad_intent;

-- ---------- select_search_paths ------------------------------------
-- broad → [fts, vector, graph_walk]
SELECT jsonb_array_length(
    select_search_paths('broad',
        ROW('plain text', ARRAY['fact']::text[], NULL, NULL, NULL, NULL)::malu$retrieval_envelope_t,
        '[]'::jsonb)
) AS broad_strategy_count;

SELECT jsonb_path_query_array(
    select_search_paths('broad',
        ROW('plain text', ARRAY['fact']::text[], NULL, NULL, NULL, NULL)::malu$retrieval_envelope_t,
        '[]'::jsonb),
    '$[*].strategy'::jsonpath) AS broad_strategies;

-- time_as_of starts with temporal_as_of
SELECT (select_search_paths('time_as_of',
        ROW('anything', ARRAY['fact']::text[],
            '2026-01-01 00:00Z'::timestamptz,
            NULL, NULL, NULL)::malu$retrieval_envelope_t,
        '[]'::jsonb) -> 0 ->> 'strategy') AS time_first_strategy;

-- ---------- plan_retrieval end-to-end -------------------------------
SELECT (plan_retrieval(
    ROW('postgres_pool exhausted',
        ARRAY['fact']::text[], NULL, NULL, NULL, NULL)
    ::malu$retrieval_envelope_t)).intent AS plan_intent;

SELECT jsonb_array_length(
    (plan_retrieval(
        ROW('postgres_pool exhausted',
            ARRAY['fact']::text[], NULL, NULL, NULL, NULL)
        ::malu$retrieval_envelope_t)).cues
) AS cue_count;

-- ---------- record_retrieval_envelope -------------------------------
WITH env AS (
    SELECT ROW('postgres_pool exhausted',
               ARRAY['fact']::text[], NULL, NULL, NULL, NULL)
           ::malu$retrieval_envelope_t AS e
)
SELECT record_retrieval_envelope(e, plan_retrieval(e)) > 0 AS persisted
FROM env;

SELECT cue_text, plan_jsonb ->> 'intent' AS recorded_intent
FROM malu$retrieval_envelope
WHERE cue_text = 'postgres_pool exhausted';

-- ---------- cleanup -------------------------------------------------
DELETE FROM malu$retrieval_envelope
 WHERE cue_text = 'postgres_pool exhausted';
DELETE FROM malu$svpor_predicate WHERE canonical_name = 'cap';
DELETE FROM malu$svpor_verb      WHERE canonical_name = 'exhausted';
DELETE FROM malu$svpor_subject   WHERE canonical_name = 'postgres_pool';
