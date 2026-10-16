-- =====================================================================
-- 03-embedding.sql — acceptance test for maludb_core 0.88.0
-- Subject/verb-compartmentalized memory search (the embedding rail bound
-- to the canonical SVPOR graph).
--
-- Run AFTER bringing a DB up to 0.88.0 (see README / 00-bootstrap, extended
-- with the 0.86.1->0.87.0 and 0.87.0->0.88.0 deltas):
--   psql -v ON_ERROR_STOP=1 -d mist_e2e -f 03-embedding.sql
--
-- Self-contained: uses its own schema `embed_demo`, so it does NOT depend on
-- 01-part1 / 02-part2 having run.
-- =====================================================================

\set ON_ERROR_STOP on

DROP SCHEMA IF EXISTS embed_demo CASCADE;
CREATE SCHEMA embed_demo;
SET search_path = embed_demo, maludb_core, public;

\echo == enable memory (expect enabled_version 0.88.0) ==
SELECT * FROM maludb_core.enable_memory_schema('embed_demo');

-- ---------------------------------------------------------------------
-- Seed canonical vocabulary with aliases. A strong cloud extractor emits
-- near-canonical surface forms; alias resolution maps them to the canon.
-- LOCKED rule: the canonical VERB is the edge + compartment key; the
-- "performed / completed / when" detail rides as predicate edge ATTRIBUTES.
-- ---------------------------------------------------------------------
\echo == seed canonical subjects/verbs (with aliases) ==
SELECT maludb_core.register_svpor_subject('Oracle Database 21c',
           ARRAY['Oracle 21c','the database'], 'Oracle DB 21c', 'software') AS oracle_subject;
SELECT maludb_core.register_svpor_subject('Billing API',
           ARRAY['billing api'], 'Billing service', 'software')             AS billing_subject;
SELECT maludb_core.register_svpor_verb('upgrade',
           ARRAY['upgraded','performed upgrade'], 'Upgrade action', 'updated') AS upgrade_verb;
SELECT maludb_core.register_svpor_verb('restart',
           ARRAY['restarted'], 'Restart action', 'updated')                  AS restart_verb;

-- ---------------------------------------------------------------------
-- A source document (the chunk's source object). upload_document returns
-- the document_id; capture it with \gset.
-- ---------------------------------------------------------------------
\echo == upload the source document ==
SELECT embed_demo.maludb_upload_document(
    p_title         => 'Oracle 21c upgrade runbook',
    p_content_text  => 'We performed the Oracle 21c upgrade on Sunday March 30 at 11 pm. We also restarted the billing API.',
    p_document_type => 'runbook') AS doc_id \gset

-- ---------------------------------------------------------------------
-- INGEST two candidate edges from the document (what the external model
-- would feed). Each carries a precomputed per-edge-span embedding (4-dim
-- demo vectors). Edge 1: Oracle upgrade. Edge 2: billing restart — lands in
-- a DIFFERENT compartment.
-- ---------------------------------------------------------------------
\echo == ingest edge 1: document --upgrade--> Oracle Database 21c ==
SELECT embed_demo.maludb_memory_ingest_edge(
    p_source_kind      => 'document',
    p_source_id        => :doc_id,
    p_subject_text     => 'Oracle 21c',          -- alias -> Oracle Database 21c
    p_verb_text        => 'upgraded',            -- alias -> upgrade
    p_predicate        => '[
        {"attr_name":"status","value_text":"completed"},
        {"attr_name":"action_form","value_text":"performed"},
        {"attr_name":"event_at","value_timestamp":"2026-03-30T23:00:00-05:00"},
        {"attr_name":"event_at_text","value_text":"Sunday March 30 at 11 pm"}
    ]'::jsonb,
    p_embedding        => '[1, 0, 0, 0]'::maludb_core.malu_vector,
    p_embedding_model  => 'demo-4d',
    p_subject_type     => 'software',
    p_source_span      => 'We performed the Oracle 21c upgrade on Sunday March 30 at 11 pm',
    p_confidence       => 0.94,
    p_extraction_model => 'strong-cloud-model',
    p_document_id      => :doc_id) AS oracle_stmt \gset

\echo == ingest edge 2: document --restart--> Billing API ==
SELECT embed_demo.maludb_memory_ingest_edge(
    p_source_kind      => 'document',
    p_source_id        => :doc_id,
    p_subject_text     => 'billing api',         -- alias -> Billing API
    p_verb_text        => 'restarted',           -- alias -> restart
    p_predicate        => '[{"attr_name":"status","value_text":"completed"}]'::jsonb,
    p_embedding        => '[0, 1, 0, 0]'::maludb_core.malu_vector,
    p_embedding_model  => 'demo-4d',
    p_subject_type     => 'software',
    p_source_span      => 'restarted the billing API',
    p_confidence       => 0.90,
    p_extraction_model => 'strong-cloud-model',
    p_document_id      => :doc_id) AS billing_stmt \gset

-- =====================================================================
-- ASSERT 1 — pre-filtered compartment search returns the Oracle chunk and
-- its statement_id. Search is narrowed to (Oracle Database 21c, upgrade)
-- BEFORE the ANN — the whole point.
-- =====================================================================
\echo == ASSERT 1: search compartment (Oracle Database 21c, upgrade) ==
SELECT chunk_id, statement_id, document_id, source_text,
       round(similarity::numeric, 4) AS similarity, subject_name, verb_name
FROM   embed_demo.maludb_memory_search(
           '[1, 0, 0, 0]'::maludb_core.malu_vector,
           p_subject => 'Oracle Database 21c',
           p_verb    => 'upgrade');
-- EXPECT exactly one row: statement_id = :oracle_stmt, subject_name
-- 'Oracle Database 21c', verb_name 'upgrade', document_id = :doc_id.

-- =====================================================================
-- ASSERT 2 — compartmentalization: the SAME query vector against the
-- billing compartment returns the billing chunk, NOT the Oracle one.
-- =====================================================================
\echo == ASSERT 2: same query, different compartment (Billing API, restart) ==
SELECT statement_id, subject_name, verb_name
FROM   embed_demo.maludb_memory_search(
           '[1, 0, 0, 0]'::maludb_core.malu_vector,
           p_subject => 'Billing API',
           p_verb    => 'restart');
-- EXPECT one row: statement_id = :billing_stmt (Billing API/restart). The
-- Oracle statement must NOT appear — vectors are compartment-partitioned.

-- =====================================================================
-- ASSERT 3 — relational first-pass, NO graph traversal: the chunk's
-- statement_id reaches subject_id/verb_id in a single join.
-- =====================================================================
\echo == ASSERT 3: chunk -> edge -> (subject, verb) in one hop ==
SELECT vc.chunk_id,
       vc.statement_id,
       subj.canonical_name AS subject,
       v.canonical_name    AS verb
FROM   maludb_core.malu$vector_chunk     vc
JOIN   maludb_core.malu$svpor_statement  st   ON st.statement_id = vc.statement_id
JOIN   maludb_core.malu$svpor_subject    subj ON subj.subject_id = st.object_id
                                             AND st.object_kind   = 'subject'
JOIN   maludb_core.malu$svpor_verb       v    ON v.verb_id        = st.verb_id
WHERE  vc.statement_id IS NOT NULL
ORDER  BY vc.chunk_id;
-- EXPECT two rows: (Oracle Database 21c, upgrade) and (Billing API, restart).

-- =====================================================================
-- ASSERT 4 — the predicate landed as TYPED edge attributes on the
-- statement (the handoff's "predicate" = the attribute store).
-- =====================================================================
\echo == ASSERT 4: predicate is typed edge attributes on the Oracle edge ==
SELECT attr_name, value_text, value_timestamp
FROM   embed_demo.maludb_svpor_attribute
WHERE  target_kind = 'svpor_statement' AND target_id = :oracle_stmt
ORDER  BY attr_name;
-- EXPECT: action_form=performed, event_at=2026-03-30 23:00:00-05,
-- event_at_text='Sunday March 30 at 11 pm', status=completed.

-- =====================================================================
-- ASSERT 5 — graph reachability: from the Oracle subject, the document is
-- reachable via the 'upgrade' edge (document --upgrade--> subject, so it is
-- an INCOMING edge on the subject). The compartment rail and the graph rail
-- share identity.
-- =====================================================================
\echo == ASSERT 5: the document is graph-reachable from the subject ==
SELECT neighbor_kind, label, rel, edge_store
FROM   embed_demo.maludb_graph_neighbors(
           'subject',
           (SELECT subject_id FROM embed_demo.maludb_subject WHERE canonical_name = 'Oracle Database 21c'),
           'in',
           ARRAY['upgrade']);
-- EXPECT one row: neighbor_kind 'document', label 'Oracle 21c upgrade runbook',
-- rel 'upgrade'.

-- =====================================================================
-- ASSERT 6 — idempotency: re-ingesting the identical edge returns the SAME
-- statement_id (the SVO edge is upserted on its identity).
-- =====================================================================
\echo == ASSERT 6: re-ingest is edge-idempotent (statement_id stable) ==
SELECT embed_demo.maludb_memory_ingest_edge(
    p_source_kind  => 'document', p_source_id => :doc_id,
    p_subject_text => 'Oracle 21c', p_verb_text => 'upgraded',
    p_embedding    => '[1, 0, 0, 0]'::maludb_core.malu_vector,
    p_embedding_model => 'demo-4d') = :oracle_stmt AS edge_idempotent;
-- EXPECT: t  (same statement_id). NOTE: chunks are NOT deduplicated — a
-- re-ingest adds another chunk to the compartment; chunk-level dedup is a
-- Tier-2 concern (tracked in embedding-handoff-analysis.md).

-- =====================================================================
-- ASSERT 7 — re-enable stays clean (idempotent).
-- =====================================================================
\echo == ASSERT 7: re-enable is idempotent ==
SELECT enabled_version FROM maludb_core.enable_memory_schema('embed_demo');
-- EXPECT: 0.88.0, no error.

\echo == DONE ==
