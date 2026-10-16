-- =====================================================================
-- 04-extraction.sql — acceptance test for maludb_core 0.89.0
-- In-DB model gateway wired into the memory-extraction path (Option B):
-- config layer + async request/harvest pipeline.
--
-- Run AFTER bringing a DB up to 0.89.0:
--   psql -v ON_ERROR_STOP=1 -d <db> -f 04-extraction.sql
--
-- Self-contained: own schema `extract_demo`. The model gateway tables are
-- GLOBAL, so the provider/alias/secret are registered once (guarded).
-- No live model daemon ships in this repo, so we SIMULATE the daemon by
-- inserting the malu$model_response it would write — exercising the full
-- request -> response -> harvest -> compartment-search path in SQL.
-- =====================================================================

\set ON_ERROR_STOP on

DROP SCHEMA IF EXISTS extract_demo CASCADE;
CREATE SCHEMA extract_demo;
SET search_path = extract_demo, maludb_core, public;

\echo == enable memory (expect enabled_version 0.89.0) ==
SELECT * FROM maludb_core.enable_memory_schema('extract_demo');

-- ---------------------------------------------------------------------
-- GLOBAL gateway config (an admin does this once). A 'stub' provider; the
-- API key goes into the encrypted secret store and is referenced by
-- secret_ref — never inline on the provider. base_url rides in the alias's
-- runtime_params.
-- ---------------------------------------------------------------------
\echo == register provider / secret / alias (global, guarded) ==
SELECT maludb_core.secret_set('demo_model_key', 'provider', 'sk-demo-not-a-real-key');
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM maludb_core.malu$model_provider WHERE provider_name = 'demo-stub') THEN
        PERFORM maludb_core.register_model_provider(
            'demo-stub', 'stub',
            p_adapter_name => 'stub',
            p_secret_ref   => 'demo_model_key');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM maludb_core.malu$model_alias WHERE alias_name = 'demo-extractor') THEN
        PERFORM maludb_core.register_model_alias(
            'demo-extractor', 'demo-stub', 'demo-extract-model',
            p_runtime_params => '{"base_url":"https://api.example.test/v1"}'::jsonb);
    END IF;
END $$;

-- ---------------------------------------------------------------------
-- CONFIG LAYER: bind which alias / prompt / embedding model this schema uses.
-- ---------------------------------------------------------------------
\echo == bind the extraction model for extract_demo ==
SELECT jsonb_pretty(extract_demo.maludb_memory_set_model_config(
    p_extraction_alias => 'demo-extractor',
    p_embedding_model  => 'demo-4d',
    p_prompt_template  => E'Extract canonical memory edges from this chunk.\n{{chunk}}'));

\echo == resolve the binding (worker reads this; note secret_ref + base_url, NO secret value) ==
SELECT jsonb_pretty(extract_demo.maludb_memory_model_config());

-- ---------------------------------------------------------------------
-- A source document, then ENQUEUE an extraction request for its text.
-- ---------------------------------------------------------------------
\echo == upload a source document ==
SELECT extract_demo.maludb_upload_document(
    p_title         => 'Sunday maintenance log',
    p_content_text  => 'We performed the Oracle 21c upgrade on Sunday March 30 at 11 pm. We also restarted the billing API.',
    p_document_type => 'log') AS doc_id \gset

\echo == request extraction (enqueues a malu$model_request via the bound alias) ==
SELECT extract_demo.maludb_memory_request_extraction(
    'document', :doc_id,
    'We performed the Oracle 21c upgrade on Sunday March 30 at 11 pm. We also restarted the billing API.'
) AS req_id \gset

\echo == ASSERT A: a pending extraction row exists, tied to the request ==
SELECT status, source_kind, source_id = :doc_id AS source_ok, request_id = :req_id AS request_ok
FROM   maludb_core.malu$memory_extraction
WHERE  request_id = :req_id;
-- EXPECT: pending, source_ok t, request_ok t

-- ---------------------------------------------------------------------
-- SIMULATE THE DAEMON: write the malu$model_response it would produce.
-- output_json is the candidate_edges contract, with per-edge embeddings.
-- ---------------------------------------------------------------------
\echo == simulate the model daemon response ==
UPDATE maludb_core.malu$model_request SET status = 'succeeded' WHERE request_id = :req_id;
INSERT INTO maludb_core.malu$model_response (request_id, status, adapter_name, output_json)
VALUES (:req_id, 'succeeded', 'sim',
$json${
  "candidate_edges": [
    {
      "subject_text": "Oracle 21c", "subject_type": "software",
      "verb_text": "upgrade",
      "predicate": [
        {"attr_name": "status", "value_text": "completed"},
        {"attr_name": "action_form", "value_text": "performed"},
        {"attr_name": "event_at", "value_timestamp": "2026-03-30T23:00:00-05:00"}
      ],
      "source_span": "We performed the Oracle 21c upgrade on Sunday March 30 at 11 pm",
      "confidence": 0.94,
      "embedding": [1, 0, 0, 0], "embedding_model": "demo-4d"
    },
    {
      "subject_text": "billing API", "subject_type": "software",
      "verb_text": "restart",
      "predicate": [{"attr_name": "status", "value_text": "completed"}],
      "source_span": "restarted the billing API",
      "confidence": 0.90,
      "embedding": [0, 1, 0, 0], "embedding_model": "demo-4d"
    }
  ]
}$json$::jsonb);

-- ---------------------------------------------------------------------
-- HARVEST: turn the response into graph edges + compartment embeddings.
-- ---------------------------------------------------------------------
\echo == ASSERT B: harvest yields one extraction, 2 edges ==
SELECT status, edge_count
FROM   extract_demo.maludb_memory_harvest_extractions();
-- EXPECT: harvested, 2

\echo == ASSERT C: the edges + predicate attributes were ingested ==
SELECT v.canonical_name AS verb, s.canonical_name AS subject,
       (SELECT count(*) FROM extract_demo.maludb_svpor_attribute a
         WHERE a.target_kind='svpor_statement' AND a.target_id=st.statement_id) AS attr_count
FROM   maludb_core.malu$svpor_statement st
JOIN   maludb_core.malu$svpor_verb    v ON v.verb_id    = st.verb_id
JOIN   maludb_core.malu$svpor_subject s ON s.subject_id = st.object_id AND st.object_kind='subject'
WHERE  st.subject_kind='document' AND st.subject_id = :doc_id
ORDER  BY verb;
-- EXPECT: restart/billing API (1 attr), upgrade/Oracle 21c (3 attrs)

\echo == ASSERT D: compartment search finds the Oracle edge, returns its statement_id ==
SELECT chunk_id, statement_id, source_text, round(similarity::numeric,4) AS sim, subject_name, verb_name
FROM   extract_demo.maludb_memory_search(
           '[1, 0, 0, 0]'::maludb_core.malu_vector,
           p_subject => 'Oracle 21c', p_verb => 'upgrade');
-- EXPECT one row, subject_name 'Oracle 21c', verb_name 'upgrade'.

\echo == ASSERT E: same query, billing compartment -> only the billing edge (isolation) ==
SELECT statement_id, subject_name, verb_name
FROM   extract_demo.maludb_memory_search(
           '[1, 0, 0, 0]'::maludb_core.malu_vector,
           p_subject => 'billing API', p_verb => 'restart');
-- EXPECT the billing edge only; the Oracle edge must NOT appear.

\echo == ASSERT F: re-harvest is a no-op (the row is no longer pending) ==
SELECT count(*) AS still_pending
FROM   (SELECT * FROM extract_demo.maludb_memory_harvest_extractions()) h;
-- EXPECT: 0

\echo == DONE ==
