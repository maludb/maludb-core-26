\set ECHO all
\pset format unaligned
SET client_min_messages = WARNING;
CREATE EXTENSION IF NOT EXISTS maludb_core CASCADE;

SET search_path TO maludb_core, public;

DROP SCHEMA IF EXISTS note_hint_a CASCADE;
DROP ROLE IF EXISTS note_hint_user;

CREATE ROLE note_hint_user NOLOGIN;
GRANT maludb_memory_executor TO note_hint_user;
GRANT USAGE ON SCHEMA maludb_core TO note_hint_user;
CREATE SCHEMA note_hint_a AUTHORIZATION note_hint_user;

SET ROLE note_hint_user;
SET search_path TO note_hint_a, maludb_core, public;

SELECT object_count > 0 AS enabled
FROM maludb_core.enable_memory_schema();

SELECT maludb_quick_add_note(
    p_title => 'multi hint note',
    p_body_text => 'Remember to test notes as documents before promotion.',
    p_projects => ARRAY['Project A', 'Project B'],
    p_subjects => ARRAY['Subject A', 'Subject B'],
    p_verbs => ARRAY['decided', 'verified'],
    p_svpor_frames => jsonb_build_array(
        jsonb_build_object('project', 'Project A', 'subject', 'Subject A', 'verb', 'decided'),
        jsonb_build_object('project', 'Project B', 'subject', 'Subject B', 'verb', 'verified'),
        jsonb_build_object('subject', 'Subject A', 'verb', 'verified')
    ),
    p_metadata_jsonb => jsonb_build_object('origin', 'quick_add')
) AS document_id \gset

SELECT source_type, title, media_type, metadata_jsonb ->> 'origin' AS origin
FROM maludb_document
WHERE document_id = :document_id;

SELECT tag_kind, array_agg(tag_value ORDER BY tag_value) AS values
FROM maludb_document_tag
WHERE document_id = :document_id
GROUP BY tag_kind
ORDER BY tag_kind;

SELECT project_name, subject_name, verb_name, provenance
FROM maludb_document_svpor_hint
WHERE document_id = :document_id
ORDER BY hint_id;

SELECT maludb_document_get(:document_id)::jsonb ? 'document' AS has_document,
       jsonb_array_length(maludb_document_get(:document_id)::jsonb -> 'tags') AS tag_count,
       jsonb_array_length(maludb_document_get(:document_id)::jsonb -> 'svpor_hints') AS frame_count;

RESET ROLE;
SET search_path TO maludb_core, public;

DELETE FROM malu$document_svpor_hint WHERE owner_schema = 'note_hint_a';
DELETE FROM malu$document_tag WHERE owner_schema = 'note_hint_a';
DELETE FROM malu$document WHERE owner_schema = 'note_hint_a';
DELETE FROM malu$source_package WHERE owner_schema = 'note_hint_a';
DELETE FROM malu$enabled_schema_object WHERE schema_name = 'note_hint_a';
DELETE FROM malu$enabled_schema WHERE schema_name = 'note_hint_a';
DROP SCHEMA note_hint_a CASCADE;
DROP OWNED BY note_hint_user;
DROP ROLE note_hint_user;
