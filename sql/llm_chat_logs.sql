\set ECHO all
\pset format unaligned
SET client_min_messages = WARNING;
CREATE EXTENSION IF NOT EXISTS maludb_core CASCADE;

SET search_path TO maludb_core, public;

DROP SCHEMA IF EXISTS llm_chat_a CASCADE;
DROP ROLE IF EXISTS llm_chat_user;

CREATE ROLE llm_chat_user NOLOGIN;
GRANT maludb_memory_executor TO llm_chat_user;
GRANT USAGE ON SCHEMA maludb_core TO llm_chat_user;
CREATE SCHEMA llm_chat_a AUTHORIZATION llm_chat_user;

SET ROLE llm_chat_user;
SET search_path TO llm_chat_a, maludb_core, public;

SELECT object_count > 0 AS enabled
FROM maludb_core.enable_memory_schema();

SELECT maludb_chat_start(
    p_title => 'LLM release planning chat',
    p_account_name => NULL,
    p_projects => ARRAY['Project Chat'],
    p_subjects => ARRAY['Person A', 'AI Agent B'],
    p_verbs => ARRAY['discussed', 'decided'],
    p_svpor_frames => jsonb_build_array(
        jsonb_build_object('project', 'Project Chat', 'subject', 'Person A', 'verb', 'discussed'),
        jsonb_build_object('project', 'Project Chat', 'subject', 'AI Agent B', 'verb', 'decided')
    ),
    p_metadata_jsonb => jsonb_build_object('origin', 'desktop')
) AS chat_session_id \gset

SELECT maludb_chat_append_message(:chat_session_id, 'user', 'How should we store chats?', NULL, '{}'::jsonb) > 0 AS user_message_added;
SELECT maludb_chat_append_message(:chat_session_id, 'assistant', 'Use durable chat logs with an llm-chat document projection.', NULL, '{}'::jsonb) > 0 AS assistant_message_added;
SELECT maludb_chat_append_message(:chat_session_id, 'tool', NULL, jsonb_build_object('name', 'memory.lookup', 'status', 'ok'), '{}'::jsonb) > 0 AS tool_message_added;

SELECT ordinal, role, content_text, content_jsonb
FROM maludb_chat_messages(:chat_session_id)
ORDER BY ordinal;

WITH finalized AS (
    SELECT maludb_chat_finalize(:chat_session_id)::jsonb AS payload
)
SELECT payload ->> 'source_type' AS finalized_source_type,
       (payload ->> 'document_id') IS NOT NULL AS has_document,
       (payload ->> 'message_count')::integer AS finalized_message_count
FROM finalized;

SELECT lifecycle_state, message_count, document_id IS NOT NULL AS has_document
FROM maludb_chat_session
WHERE chat_session_id = :chat_session_id;

SELECT source_type, title, media_type, metadata_jsonb ->> 'projection' AS projection
FROM maludb_document
WHERE document_id = (
    SELECT document_id FROM maludb_chat_session WHERE chat_session_id = :chat_session_id
);

SELECT tag_kind, array_agg(tag_value ORDER BY tag_value) AS values
FROM maludb_document_tag
WHERE document_id = (
    SELECT document_id FROM maludb_chat_session WHERE chat_session_id = :chat_session_id
)
GROUP BY tag_kind
ORDER BY tag_kind;

SELECT project_name, subject_name, verb_name, provenance
FROM maludb_document_svpor_hint
WHERE document_id = (
    SELECT document_id FROM maludb_chat_session WHERE chat_session_id = :chat_session_id
)
ORDER BY hint_id;

SELECT maludb_chat_get(:chat_session_id)::jsonb ? 'chat_session' AS has_chat_session,
       maludb_chat_get(:chat_session_id)::jsonb ? 'document' AS has_document_payload;

DO $body$
BEGIN
    PERFORM maludb_chat_append_message(
        (SELECT chat_session_id FROM maludb_chat_session ORDER BY chat_session_id DESC LIMIT 1),
        'user', 'This should fail after close.', NULL, '{}'::jsonb);
    RAISE EXCEPTION 'closed chat append unexpectedly succeeded';
EXCEPTION
    WHEN object_not_in_prerequisite_state THEN
        NULL;
END;
$body$;
SELECT true AS closed_append_rejected;

RESET ROLE;
SET search_path TO maludb_core, public;

DELETE FROM malu$chat_message WHERE owner_schema = 'llm_chat_a';
DELETE FROM malu$chat_session WHERE owner_schema = 'llm_chat_a';
DELETE FROM malu$document_svpor_hint WHERE owner_schema = 'llm_chat_a';
DELETE FROM malu$document_tag WHERE owner_schema = 'llm_chat_a';
DELETE FROM malu$document WHERE owner_schema = 'llm_chat_a';
DELETE FROM malu$source_package WHERE owner_schema = 'llm_chat_a';
DELETE FROM malu$enabled_schema_object WHERE schema_name = 'llm_chat_a';
DELETE FROM malu$enabled_schema WHERE schema_name = 'llm_chat_a';
DROP SCHEMA llm_chat_a CASCADE;
DROP OWNED BY llm_chat_user;
DROP ROLE llm_chat_user;
