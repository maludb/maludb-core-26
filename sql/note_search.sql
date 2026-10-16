\set ECHO all
\pset format unaligned
SET client_min_messages = WARNING;

CREATE EXTENSION IF NOT EXISTS maludb_core CASCADE;
SET search_path TO maludb_core, public;

\set ON_ERROR_STOP on

-- =====================================================================
-- note_search -- 0.98.0
--
-- Relational note retrieval by subject/verb over extracted SVO edges:
--   * maludb_note_search: subject patterns (canonical + aliases, both
--     statement endpoints), verb-like bidirectional containment
--     ('installation' finds 'install'), verb-exact canonical/alias
--     match, both statement->document rails (vector_chunk soft ref +
--     'document' statement endpoints), one row per document with
--     matched edges aggregated, source_type scope ('note' by default,
--     p_all_sources widens), paging, tenant isolation.
--   * maludb_note_query_parse: deterministic free-text parse against
--     the tenant verb catalog (exact beats containment; containment
--     needs a 4+ char token).
-- =====================================================================

DO $body$
DECLARE
    v_existing_role name;
BEGIN
    SELECT r.rolname INTO v_existing_role
      FROM pg_catalog.pg_roles r
     WHERE r.rolname = ANY (ARRAY['nts_user_a', 'nts_user_b'])
     LIMIT 1;
    IF v_existing_role IS NOT NULL THEN
        RAISE EXCEPTION 'Refusing to start note_search test: role % already exists',
            v_existing_role;
    END IF;
END;
$body$;

CREATE ROLE nts_user_a NOLOGIN;
CREATE ROLE nts_user_b NOLOGIN;
GRANT maludb_memory_executor TO nts_user_a, nts_user_b;
GRANT USAGE ON SCHEMA maludb_core TO nts_user_a, nts_user_b;
GRANT nts_user_a, nts_user_b TO CURRENT_USER;
CREATE SCHEMA nts_a AUTHORIZATION nts_user_a;
CREATE SCHEMA nts_b AUTHORIZATION nts_user_b;

SET ROLE nts_user_a;
SET search_path TO nts_a, maludb_core, public;
SELECT object_count > 0 AS enabled_a FROM maludb_core.enable_memory_schema('nts_a');

-- ---------------------------------------------------------------------
-- 1. Seed tenant A. Extraction rail: a note whose edges anchor the
--    document as $source on both sides (subject AND object endpoint).
-- ---------------------------------------------------------------------
SELECT maludb_memory_ingest_extraction($json$
{
  "document": {"title": "Install Ubuntu 24.04 Server",
               "content_text": "Install Ubuntu 24.04 Server in the Chicago Datacenter on June 11, 2026.",
               "source_type": "note"},
  "subjects": [
    {"key": "ubuntu", "name": "Ubuntu 24.04 Server", "type": "software",
     "aliases": ["noble numbat"]},
    {"key": "dc", "name": "Chicago Datacenter", "type": "equipment"}
  ],
  "edges": [
    {"subject": "$source", "verb": "install", "object": "ubuntu",
     "source_span": "Install Ubuntu 24.04 Server", "confidence": 0.95},
    {"subject": "ubuntu", "verb": "located_in", "object": "$source",
     "source_span": "in the Chicago Datacenter"}
  ]
}
$json$::jsonb) AS note_report \gset

SELECT (:'note_report'::jsonb -> 'created' ->> 'subjects')::int AS subjects_created,
       (:'note_report'::jsonb -> 'created' ->> 'edges')::int    AS edges_created,
       jsonb_array_length(:'note_report'::jsonb -> 'skipped')   AS skipped;

-- verb alias for the exact-match-by-alias case.
SELECT maludb_core.register_svpor_verb('install', ARRAY['set up']) > 0 AS install_alias_added;

-- A second matching document that is NOT a note (scope test).
SELECT maludb_memory_ingest_extraction($json$
{
  "document": {"title": "Ubuntu rollout runbook",
               "content_text": "Runbook: how we install Ubuntu fleet-wide.",
               "source_type": "document"},
  "subjects": [{"key": "ubuntu", "name": "Ubuntu 24.04 Server", "type": "software"}],
  "edges": [{"subject": "$source", "verb": "install", "object": "ubuntu"}]
}
$json$::jsonb) -> 'created' ->> 'edges' AS runbook_edges;

-- Chunk rail: a note reachable ONLY through the vector_chunk soft ref
-- (both edge endpoints are graph subjects; document_id rides the chunk).
SELECT maludb_upload_document('Upgrade PostgreSQL 17',
                              'Upgrade PostgreSQL 17 on the db host tonight.',
                              'note') AS pg_doc \gset
SELECT maludb_core.register_svpor_subject('db host', ARRAY[]::text[], NULL, 'equipment') AS host_id \gset
SELECT maludb_memory_ingest_edge(
           p_source_kind  => 'subject',
           p_source_id    => :host_id,
           p_subject_text => 'PostgreSQL 17',
           p_verb_text    => 'upgrade',
           p_embedding    => '[0.10, 0.20, 0.30]'::malu_vector,
           p_embedding_model => 'test-model',
           p_subject_type => 'software',
           p_source_span  => 'Upgrade PostgreSQL 17',
           p_document_id  => :pg_doc) > 0 AS chunk_edge_created;

-- ---------------------------------------------------------------------
-- 2. verb-like is bidirectional: the query 'installation' CONTAINS the
--    verb 'install' even though no verb contains 'installation'.
-- ---------------------------------------------------------------------
SELECT title, source_type, match_count,
       jsonb_array_length(matched_edges) AS edge_count
  FROM maludb_note_search(p_subject_like => ARRAY['ubuntu'],
                          p_verb_like    => 'installation');

-- ---------------------------------------------------------------------
-- 3. Exact verb: canonical name and alias hit; a non-verb stays empty.
-- ---------------------------------------------------------------------
SELECT title FROM maludb_note_search(p_subject_like => ARRAY['ubuntu'],
                                     p_verb_exact   => 'install');
SELECT title FROM maludb_note_search(p_subject_like => ARRAY['ubuntu'],
                                     p_verb_exact   => 'SET UP');
SELECT count(*) AS exact_is_exact
  FROM maludb_note_search(p_subject_like => ARRAY['ubuntu'],
                          p_verb_exact   => 'installation');

-- ---------------------------------------------------------------------
-- 4. Subject alias + verb alias containment ('set' is inside 'set up').
-- ---------------------------------------------------------------------
SELECT title FROM maludb_note_search(p_subject_like => ARRAY['noble'],
                                     p_verb_like    => 'set');

-- ---------------------------------------------------------------------
-- 5. Subject-only search: the note carries TWO doc-linked edges (the
--    document is the subject endpoint of one and the object endpoint
--    of the other) -> one row, both edges aggregated.
-- ---------------------------------------------------------------------
SELECT title, match_count,
       (SELECT array_agg(e ->> 'verb_name' ORDER BY e ->> 'verb_name')
          FROM jsonb_array_elements(matched_edges) e) AS verbs,
       (SELECT array_agg(e ->> 'matched_endpoint' ORDER BY e ->> 'verb_name')
          FROM jsonb_array_elements(matched_edges) e) AS matched_endpoints
  FROM maludb_note_search(p_subject_like => ARRAY['ubuntu']);

-- ---------------------------------------------------------------------
-- 6. Chunk rail: doc linked only through vector_chunk.document_id.
-- ---------------------------------------------------------------------
SELECT title, source_type,
       matched_edges -> 0 ->> 'match_via'         AS match_via,
       matched_edges -> 0 ->> 'subject_name'      AS edge_subject,
       matched_edges -> 0 ->> 'verb_name'         AS edge_verb,
       matched_edges -> 0 ->> 'object_name'       AS edge_object,
       matched_edges -> 0 ->> 'matched_endpoint'  AS matched_endpoint
  FROM maludb_note_search(p_subject_like => ARRAY['postgresql'],
                          p_verb_like    => 'upgrades');

-- ---------------------------------------------------------------------
-- 7. Scope: default sees only notes; p_all_sources adds the runbook;
--    snippet comes from the source package text.
-- ---------------------------------------------------------------------
SELECT title, source_type
  FROM maludb_note_search(p_subject_like => ARRAY['ubuntu'])
 ORDER BY title;
SELECT title, source_type, left(snippet, 24) AS snippet_head
  FROM maludb_note_search(p_subject_like => ARRAY['ubuntu'],
                          p_all_sources  => true)
 ORDER BY title;

-- ---------------------------------------------------------------------
-- 8. Paging: stable order (created_at DESC, document_id DESC).
-- ---------------------------------------------------------------------
SELECT title FROM maludb_note_search(p_subject_like => ARRAY['ubuntu'],
                                     p_all_sources  => true,
                                     p_limit        => 1);
SELECT title FROM maludb_note_search(p_subject_like => ARRAY['ubuntu'],
                                     p_all_sources  => true,
                                     p_limit        => 1,
                                     p_offset       => 1);

-- ---------------------------------------------------------------------
-- 9. Free-text parse: exact verb token wins; leftover tokens become
--    subject patterns; short tokens (<4 chars) never claim a verb by
--    containment; verbless queries return verb = null.
-- ---------------------------------------------------------------------
SELECT maludb_note_query_parse('Install Ubuntu') AS parse_install \gset
SELECT (:'parse_install'::jsonb ->> 'verb')           AS verb,
       (:'parse_install'::jsonb ->> 'matched_token')  AS matched_token,
       (:'parse_install'::jsonb -> 'subject_tokens')  AS subject_tokens;

SELECT maludb_note_query_parse('How do we upgrade the PostgreSQL fleet') AS parse_upgrade \gset
SELECT (:'parse_upgrade'::jsonb ->> 'verb')          AS verb,
       (:'parse_upgrade'::jsonb -> 'subject_tokens') AS subject_tokens;

SELECT maludb_note_query_parse('ins ubuntu') -> 'verb'           AS short_token_verb;
SELECT maludb_note_query_parse('chicago datacenter capacity') ->> 'verb' AS verbless_verb,
       maludb_note_query_parse('chicago datacenter capacity') -> 'subject_tokens' AS verbless_subjects;
SELECT maludb_note_query_parse('') AS empty_parse;

-- ---------------------------------------------------------------------
-- 10. Criteria are required.
-- ---------------------------------------------------------------------
DO $body$
BEGIN
    PERFORM * FROM nts_a.maludb_note_search();
    RAISE WARNING 'note_search accepted empty criteria';
EXCEPTION WHEN invalid_parameter_value THEN
    RAISE WARNING 'rejected empty criteria: %', SQLERRM;
END;
$body$;

RESET ROLE;

-- ---------------------------------------------------------------------
-- 11. Tenant isolation: tenant B sees none of tenant A's notes.
-- ---------------------------------------------------------------------
SET ROLE nts_user_b;
SET search_path TO nts_b, maludb_core, public;
SELECT object_count > 0 AS enabled_b FROM maludb_core.enable_memory_schema('nts_b');
SELECT count(*) AS b_sees
  FROM maludb_note_search(p_subject_like => ARRAY['ubuntu'],
                          p_all_sources  => true);
RESET ROLE;

-- ---------------------------------------------------------------------
-- Teardown.
-- ---------------------------------------------------------------------
SET search_path TO maludb_core, public;
DO $body$
DECLARE
    v_schema name;
    v_table text;
BEGIN
    FOREACH v_schema IN ARRAY ARRAY['nts_a','nts_b']::name[]
    LOOP
        -- chunk rows hang off compartments (no owner_schema of their own)
        EXECUTE 'DELETE FROM maludb_core."malu$vector_chunk"
                  WHERE compartment_id IN (SELECT compartment_id
                                             FROM maludb_core."malu$vector_compartment"
                                            WHERE owner_schema = $1)' USING v_schema;
        FOREACH v_table IN ARRAY ARRAY[
            'malu$vector_compartment',
            'malu$vector_subject',
            'malu$vector_verb',
            'malu$document',
            'malu$source_package',
            'malu$svpor_attribute',
            'malu$svpor_statement',
            'malu$svpor_subject',
            'malu$svpor_verb',
            'malu$enabled_schema_object',
            'malu$enabled_schema'
        ]
        LOOP
            IF to_regclass('maludb_core.' || quote_ident(v_table)) IS NOT NULL THEN
                EXECUTE format('DELETE FROM maludb_core.%I WHERE %s = $1',
                               v_table,
                               CASE WHEN v_table LIKE 'malu$enabled%' THEN 'schema_name' ELSE 'owner_schema' END)
                USING v_schema;
            END IF;
        END LOOP;
    END LOOP;
END;
$body$;
DROP SCHEMA IF EXISTS nts_a CASCADE;
DROP SCHEMA IF EXISTS nts_b CASCADE;
DROP OWNED BY nts_user_a;
DROP OWNED BY nts_user_b;
DROP ROLE nts_user_a;
DROP ROLE nts_user_b;
