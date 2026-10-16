\set ECHO none
\pset format unaligned
SET client_min_messages = WARNING;
CREATE EXTENSION IF NOT EXISTS maludb_core CASCADE;

SET search_path TO maludb_core, public;

\set ON_ERROR_STOP on

-- Refuse to run against a non-test role of the same name.
DO $body$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'dr_user_a') THEN
        RAISE EXCEPTION 'Refusing to start document_reindex test: role dr_user_a already exists';
    END IF;
END;
$body$;

DROP SCHEMA IF EXISTS dr_a CASCADE;
DROP ROLE IF EXISTS dr_user_a;

SET client_min_messages = NOTICE;

CREATE ROLE dr_user_a NOLOGIN;
COMMENT ON ROLE dr_user_a IS 'maludb document_reindex regression test role';
GRANT maludb_memory_executor TO dr_user_a;
GRANT USAGE ON SCHEMA maludb_core TO dr_user_a;

CREATE SCHEMA dr_a AUTHORIZATION dr_user_a;

SELECT object_count >= 56 AS dr_a_enabled
FROM maludb_core.enable_memory_schema('dr_a');

SET ROLE dr_user_a;
SET search_path TO dr_a, maludb_core, public;

-- A real registry verb so the tenant has a reindex watermark.
INSERT INTO maludb_verb(canonical_name) VALUES ('reconcile');

-- Ingest a note with a deliberately weak/wrong extraction (the "poor
-- initial indexing" case): one $source-->subject edge via a vague verb.
SELECT maludb_memory_ingest_extraction(
    p_extraction => '{
        "subjects": [{"key": "s1", "name": "generic thing", "type": "other"}],
        "verbs": [{"name": "mention"}],
        "edges": [{"subject": "$source", "verb": "mention", "object": "s1"}],
        "document": {"title": "dr note one",
                     "content_text": "Reconcile the Acme invoice against the purchase order.",
                     "source_type": "note", "document_type": "note"}
    }'::jsonb,
    p_source_kind => 'note', p_source_id => NULL, p_provenance => 'suggested'
) IS NOT NULL AS ingested;

SELECT document_id AS dr_doc_id
FROM maludb_document WHERE title = 'dr note one' \gset

-- (A) The never-indexed note is claimed, and the claim hands back its text.
SELECT count(*) = 1 AS claim_picks_unindexed
FROM maludb_memory_reindex_claim()
WHERE document_id = :'dr_doc_id'::bigint;

SELECT content_text LIKE '%Acme invoice%' AS claim_returns_text
FROM maludb_memory_reindex_claim()
WHERE document_id = :'dr_doc_id'::bigint;

-- Apply a corrected extraction (the worker's job): replace the footprint.
WITH r AS (
    SELECT maludb_memory_reindex_apply(
        :'dr_doc_id'::bigint,
        '{
            "subjects": [{"key": "inv", "name": "acme invoice", "type": "other"}],
            "verbs": [{"name": "reconcile"}],
            "edges": [{"subject": "$source", "verb": "reconcile", "object": "inv"}]
        }'::jsonb,
        'claude-opus-4-8'
    ) AS j
)
SELECT (j->>'statements_replaced')::int AS statements_replaced,
       j->>'last_indexed_model'         AS model
FROM r;

-- (B) Footprint replaced, verified at the core tables (as superuser).
RESET ROLE;
SET search_path TO maludb_core, public;

SELECT bool_or(v.canonical_name = 'reconcile' AND obj.canonical_name = 'acme invoice') AS has_new_edge,
       NOT bool_or(v.canonical_name = 'mention')                                       AS dropped_old_edge
FROM maludb_core.malu$svpor_statement st
JOIN maludb_core.malu$svpor_verb v
  ON v.verb_id = st.verb_id AND v.owner_schema = 'dr_a'
LEFT JOIN maludb_core.malu$svpor_subject obj
  ON st.object_kind = 'subject' AND obj.subject_id = st.object_id AND obj.owner_schema = 'dr_a'
WHERE st.owner_schema = 'dr_a'
  AND st.subject_kind = 'document' AND st.subject_id = :'dr_doc_id'::bigint;

SELECT last_indexed IS NOT NULL AS last_indexed_stamped,
       last_indexed_model       AS last_indexed_model
FROM maludb_core.malu$document
WHERE owner_schema = 'dr_a' AND document_id = :'dr_doc_id'::bigint;

-- (C) note_search now finds the note via the reindexed subject + verb.
SET ROLE dr_user_a;
SET search_path TO dr_a, maludb_core, public;

SELECT count(*) = 1 AS note_search_finds_via_new_tags
FROM maludb_note_search(
    p_subject_like => ARRAY['acme invoice'],
    p_verb_like    => 'reconcile',
    p_all_sources  => true)
WHERE document_id = :'dr_doc_id'::bigint;

-- (D) A freshly-indexed note is not reclaimed.
SELECT count(*) = 0 AS reindexed_not_reclaimed
FROM maludb_memory_reindex_claim()
WHERE document_id = :'dr_doc_id'::bigint;

-- (E) Registry-aware re-pick: backdate last_indexed so it predates the
--     newest subject/verb -> the watermark clause re-selects it.
RESET ROLE;
SET search_path TO maludb_core, public;
UPDATE maludb_core.malu$document
   SET last_indexed = now() - interval '1 hour'
 WHERE owner_schema = 'dr_a' AND document_id = :'dr_doc_id'::bigint;

SET ROLE dr_user_a;
SET search_path TO dr_a, maludb_core, public;

SELECT count(*) = 1 AS stale_reclaimed_by_watermark
FROM maludb_memory_reindex_claim()
WHERE document_id = :'dr_doc_id'::bigint;

-- Teardown.
RESET ROLE;
SET search_path TO maludb_core, public;
SET client_min_messages = WARNING;
\unset ON_ERROR_STOP
DROP SCHEMA IF EXISTS dr_a CASCADE;
DO $body$
DECLARE
    v_table text;
    v_tables text[] := ARRAY[
        'malu$svpor_attribute', 'malu$svpor_statement', 'malu$svpor_subject_relationship_edge',
        'malu$embedding_dirty', 'malu$vector_chunk', 'malu$document_tag', 'malu$document',
        'malu$source_package', 'malu$svpor_subject', 'malu$svpor_verb',
        'malu$enabled_schema_object', 'malu$enabled_schema'
    ];
BEGIN
    FOREACH v_table IN ARRAY v_tables LOOP
        IF to_regclass('maludb_core.' || quote_ident(v_table)) IS NOT NULL
           AND EXISTS (SELECT 1 FROM pg_catalog.pg_attribute
                        WHERE attrelid = to_regclass('maludb_core.' || quote_ident(v_table))
                          AND attname = 'owner_schema' AND NOT attisdropped) THEN
            EXECUTE format('DELETE FROM maludb_core.%I WHERE owner_schema = $1', v_table) USING 'dr_a';
        ELSIF to_regclass('maludb_core.' || quote_ident(v_table)) IS NOT NULL
           AND EXISTS (SELECT 1 FROM pg_catalog.pg_attribute
                        WHERE attrelid = to_regclass('maludb_core.' || quote_ident(v_table))
                          AND attname = 'schema_name' AND NOT attisdropped) THEN
            EXECUTE format('DELETE FROM maludb_core.%I WHERE schema_name = $1', v_table) USING 'dr_a';
        END IF;
    END LOOP;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'dr_user_a') THEN
        DROP OWNED BY dr_user_a;
    END IF;
END;
$body$;
DROP ROLE IF EXISTS dr_user_a;
