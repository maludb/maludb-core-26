\set ECHO all
\pset format unaligned
SET client_min_messages = WARNING;
CREATE EXTENSION IF NOT EXISTS maludb_core CASCADE;
DO $body$
DECLARE
    v_schema name;
    v_tables text[] := ARRAY[
        'malu$document_tag',
        'malu$ingest_extraction',
        'malu$document',
        'malu$raw_ingest',
        'malu$vector_compartment',
        'malu$vector_subject',
        'malu$vector_verb',
        'malu$svpor_statement',
        'malu$svpor_subject_relationship_edge',
        'malu$svpor_subject',
        'malu$svpor_verb',
        'malu$memory_detail_object',
        'malu$memory',
        'malu$source_package'
    ];
    v_table text;
BEGIN
    FOREACH v_schema IN ARRAY ARRAY['smi'::name, 'smi_other'::name] LOOP
        FOREACH v_table IN ARRAY v_tables LOOP
            IF to_regclass('maludb_core.' || quote_ident(v_table)) IS NOT NULL THEN
                EXECUTE format('DELETE FROM maludb_core.%I WHERE owner_schema = $1', v_table)
                USING v_schema;
            END IF;
        END LOOP;
        IF to_regclass('maludb_core.malu$enabled_schema_object') IS NOT NULL THEN
            DELETE FROM maludb_core.malu$enabled_schema_object WHERE schema_name = v_schema;
        END IF;
        IF to_regclass('maludb_core.malu$enabled_schema') IS NOT NULL THEN
            DELETE FROM maludb_core.malu$enabled_schema WHERE schema_name = v_schema;
        END IF;
        EXECUTE format('DROP SCHEMA IF EXISTS %I CASCADE', v_schema);
    END LOOP;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'smi_user') THEN
        DROP OWNED BY smi_user;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'smi_other_user') THEN
        DROP OWNED BY smi_other_user;
    END IF;
END;
$body$;
SET search_path TO maludb_core, public;
SET client_min_messages = NOTICE;

DROP SCHEMA IF EXISTS smi CASCADE;
DROP SCHEMA IF EXISTS smi_other CASCADE;
DROP ROLE IF EXISTS smi_user;
DROP ROLE IF EXISTS smi_other_user;

CREATE ROLE smi_user NOLOGIN;
CREATE ROLE smi_other_user NOLOGIN;
GRANT maludb_memory_executor TO smi_user;
GRANT maludb_memory_executor TO smi_other_user;
GRANT USAGE ON SCHEMA maludb_core TO smi_user;
GRANT USAGE ON SCHEMA maludb_core TO smi_other_user;
CREATE SCHEMA smi AUTHORIZATION smi_user;
CREATE SCHEMA smi_other AUTHORIZATION smi_other_user;

SELECT NOT has_function_privilege(
           'maludb_memory_admin',
           'maludb_core._enable_memory_schema_ingest_facade(name)',
           'EXECUTE'
       ) AS private_ingest_helper_not_granted;

SET ROLE smi_user;
SET search_path TO smi, maludb_core, public;

SELECT object_count AS enable_object_count
FROM maludb_core.enable_memory_schema();

INSERT INTO maludb_raw_ingest(source_type, source_name, payload_jsonb)
VALUES ('prompt_session', 'codex', '{"prompt":"p","response":"r"}')
RETURNING source_type, source_name, state;

SELECT count(*) AS unapplied_count_before
FROM maludb_unapplied_ingest;

SELECT maludb_upload_document(
    p_title => 'Cutover notes',
    p_content_text => 'Cutover notes mention postgres_pool risk.',
    p_source_type => 'document',
    p_projects => ARRAY['zozocal migration'],
    p_subjects => ARRAY['postgres_pool'],
    p_verbs => ARRAY['risk'],
    p_events => ARRAY['cutover_planning']
) IS NOT NULL AS document_uploaded;

SELECT title, source_type, media_type, metadata_jsonb
FROM maludb_document
WHERE title = 'Cutover notes';

SELECT tag_kind, tag_value, provenance
FROM maludb_document_tag
ORDER BY tag_kind, tag_value;

INSERT INTO maludb_document_tag(document_id, tag_kind, tag_value, provenance, confidence, metadata_jsonb)
SELECT document_id, 'subject', 'api_gateway', 'suggested', 0.82, '{"source":"model"}'::jsonb
FROM maludb_document WHERE title = 'Cutover notes';

SELECT tag_kind, tag_value, confidence, metadata_jsonb
FROM maludb_document_suggested_tag;

SET search_path TO public, maludb_core;

SELECT smi.maludb_upload_document(
    p_title => 'Schema qualified notes',
    p_content_text => 'Called with a non-tenant search path.',
    p_source_type => 'document',
    p_subjects => ARRAY['schema_qualified']
) IS NOT NULL AS schema_qualified_document_uploaded;

RESET ROLE;
SET search_path TO maludb_core, public;

SELECT owner_schema, title
FROM maludb_core.malu$document
WHERE title = 'Schema qualified notes';

SET search_path TO maludb_core, public;

DO $body$
BEGIN
    WITH other_doc AS (
        INSERT INTO maludb_core.malu$document(owner_schema, title, source_type)
        VALUES ('smi_other', 'Other tenant doc', 'document')
        RETURNING document_id
    )
    INSERT INTO maludb_core.malu$document_tag(owner_schema, document_id, tag_kind, tag_value)
    SELECT 'smi', document_id, 'subject', 'cross tenant'
    FROM other_doc;

    RAISE EXCEPTION 'cross-tenant document_tag insert unexpectedly succeeded';
EXCEPTION WHEN foreign_key_violation THEN
    RAISE NOTICE 'OK: document_tag blocks cross-tenant document';
END;
$body$;

DO $body$
BEGIN
    WITH smi_ingest AS (
        SELECT ingest_id
        FROM maludb_core.malu$raw_ingest
        WHERE owner_schema = 'smi'
          AND source_name = 'codex'
    )
    INSERT INTO maludb_core.malu$ingest_extraction(owner_schema, ingest_id, derived_object_type, extraction_state)
    SELECT 'smi_other', ingest_id, 'document', 'accepted'
    FROM smi_ingest;

    RAISE EXCEPTION 'cross-tenant ingest_extraction insert unexpectedly succeeded';
EXCEPTION WHEN foreign_key_violation THEN
    RAISE NOTICE 'OK: ingest_extraction blocks cross-tenant raw ingest';
END;
$body$;

SET ROLE smi_user;
SET search_path TO smi, maludb_core, public;

SELECT count(*) AS unapplied_count_after_cross_owner_extraction
FROM maludb_unapplied_ingest;

RESET ROLE;
SET search_path TO maludb_core, public;

DROP SCHEMA smi CASCADE;
DROP SCHEMA smi_other CASCADE;

DO $body$
DECLARE
    v_schema name;
    v_tables text[] := ARRAY[
        'malu$document_tag',
        'malu$ingest_extraction',
        'malu$document',
        'malu$raw_ingest',
        'malu$vector_compartment',
        'malu$vector_subject',
        'malu$vector_verb',
        'malu$svpor_statement',
        'malu$svpor_subject_relationship_edge',
        'malu$svpor_subject',
        'malu$svpor_verb',
        'malu$memory_detail_object',
        'malu$memory',
        'malu$source_package'
    ];
    v_table text;
BEGIN
    FOREACH v_schema IN ARRAY ARRAY['smi'::name, 'smi_other'::name] LOOP
        FOREACH v_table IN ARRAY v_tables LOOP
            IF to_regclass('maludb_core.' || quote_ident(v_table)) IS NOT NULL THEN
                EXECUTE format('DELETE FROM maludb_core.%I WHERE owner_schema = $1', v_table)
                USING v_schema;
            END IF;
        END LOOP;
        IF to_regclass('maludb_core.malu$enabled_schema_object') IS NOT NULL THEN
            DELETE FROM maludb_core.malu$enabled_schema_object WHERE schema_name = v_schema;
        END IF;
        IF to_regclass('maludb_core.malu$enabled_schema') IS NOT NULL THEN
            DELETE FROM maludb_core.malu$enabled_schema WHERE schema_name = v_schema;
        END IF;
    END LOOP;
END;
$body$;

DROP OWNED BY smi_user;
DROP OWNED BY smi_other_user;
DROP ROLE smi_user;
DROP ROLE smi_other_user;
