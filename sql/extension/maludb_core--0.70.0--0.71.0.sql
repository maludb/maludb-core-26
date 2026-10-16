-- =====================================================================
-- maludb_core 0.70.0 -> 0.71.0  (V4 alpha.6 — V4-REST-01)
--
-- Registers V4 PageIndex + ChatIndex endpoints in malu$rest_endpoint
-- via rest_register_endpoint. All eight endpoints from
-- version4-pageindex-plan.md §V4-REST-01:
--
--   POST /v4/pageindex/build
--   GET  /v4/pageindex/trees
--   GET  /v4/pageindex/trees/:tree_id
--   POST /v4/pageindex/ask
--   POST /v4/chatindex/build
--   POST /v4/chatindex/append
--   GET  /v4/chatindex/trees
--   POST /v4/chatindex/ask
--
-- All endpoints reuse the alpha.1..alpha.5 SQL functions as
-- handlers. The three needed list/get helpers
-- (pageindex_list_trees, pageindex_get_tree, chatindex_list_trees)
-- are added here as plain SETOF-returning functions so the same
-- handler can serve both REST and direct SQL callers without going
-- through mc2db.put_object.
--
-- Apply with:
--   ALTER EXTENSION maludb_core UPDATE TO '0.71.0';
-- =====================================================================

CREATE OR REPLACE FUNCTION maludb_core_version() RETURNS text
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$ SELECT '0.71.0'::text $body$;

-- Migration-local helper (same pattern as V3-API-02 in
-- 0.61.0->0.62.0). Dropped at the end of the migration.
CREATE OR REPLACE FUNCTION _v3_api_arg(
    p_name text, p_type text, p_required boolean DEFAULT true,
    p_in   text DEFAULT 'body', p_default jsonb DEFAULT 'null'::jsonb)
    RETURNS jsonb
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$
    SELECT jsonb_build_object(
        'name',     p_name,
        'type',     p_type,
        'in',       p_in,
        'required', p_required,
        'default',  p_default)
$body$;

-- =====================================================================
-- 1. List / get helpers — plain SETOF functions for REST GETs.
-- =====================================================================

CREATE FUNCTION pageindex_list_trees(
    p_build_status text    DEFAULT NULL,
    p_limit        integer DEFAULT 50
) RETURNS TABLE (
    tree_id            bigint,
    source_package_id  bigint,
    parser_kind        text,
    build_status       text,
    build_started_at   timestamptz,
    build_finished_at  timestamptz,
    superseded_by      bigint)
LANGUAGE sql STABLE
AS $body$
    SELECT tree_id, source_package_id, parser_kind, build_status,
           build_started_at, build_finished_at, superseded_by
      FROM malu$page_index_tree
     WHERE p_build_status IS NULL OR build_status = p_build_status
     ORDER BY tree_id DESC
     LIMIT GREATEST(p_limit, 1);
$body$;

CREATE FUNCTION pageindex_get_tree(p_tree_id bigint)
RETURNS TABLE (
    tree_id            bigint,
    source_package_id  bigint,
    parser_kind        text,
    model_alias_id     bigint,
    prompt_template_id bigint,
    build_status       text,
    build_started_at   timestamptz,
    build_finished_at  timestamptz,
    failure_reason     text,
    superseded_by      bigint,
    valid_time_start   timestamptz,
    valid_time_end     timestamptz)
LANGUAGE sql STABLE
AS $body$
    SELECT tree_id, source_package_id, parser_kind, model_alias_id,
           prompt_template_id, build_status,
           build_started_at, build_finished_at, failure_reason,
           superseded_by, valid_time_start, valid_time_end
      FROM malu$page_index_tree
     WHERE tree_id = p_tree_id;
$body$;

CREATE FUNCTION chatindex_list_trees(
    p_build_status text    DEFAULT NULL,
    p_limit        integer DEFAULT 50
) RETURNS TABLE (
    tree_id              bigint,
    source_package_id    bigint,
    build_status         text,
    current_node_mdo_id  bigint,
    max_children         integer,
    sub_node_count       integer,
    build_started_at     timestamptz,
    build_finished_at    timestamptz,
    superseded_by        bigint)
LANGUAGE sql STABLE
AS $body$
    SELECT tree_id, source_package_id, build_status,
           current_node_mdo_id, max_children, sub_node_count,
           build_started_at, build_finished_at, superseded_by
      FROM malu$chat_index_tree
     WHERE p_build_status IS NULL OR build_status = p_build_status
     ORDER BY tree_id DESC
     LIMIT GREATEST(p_limit, 1);
$body$;

REVOKE EXECUTE ON FUNCTION pageindex_list_trees(text, integer) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION pageindex_get_tree(bigint)         FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION chatindex_list_trees(text, integer) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION pageindex_list_trees(text, integer) TO
    maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;
GRANT  EXECUTE ON FUNCTION pageindex_get_tree(bigint) TO
    maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;
GRANT  EXECUTE ON FUNCTION chatindex_list_trees(text, integer) TO
    maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;

-- =====================================================================
-- 2. REST endpoint registrations.
-- =====================================================================

-- POST /v4/pageindex/build
SELECT rest_register_endpoint(
    'POST', '/v4/pageindex/build',
    'source_package_promote_to_page_index(bigint, text, bigint, bigint, jsonb)'::regprocedure,
    'Promote a Source Package to a PageIndex tree (queues the builder).',
    ARRAY['pageindex.write']::text[], 'state_changing', '{}'::jsonb, true,
    30000, 1048576, 65536,
    jsonb_build_array(
        _v3_api_arg('p_source_package_id',  'bigint'),
        _v3_api_arg('p_parser_kind',        'text'),
        _v3_api_arg('p_model_alias_id',     'bigint', false),
        _v3_api_arg('p_prompt_template_id', 'bigint', false),
        _v3_api_arg('p_builder_options',    'jsonb',  false)));

-- GET /v4/pageindex/trees
SELECT rest_register_endpoint(
    'GET', '/v4/pageindex/trees',
    'pageindex_list_trees(text, integer)'::regprocedure,
    'List PageIndex trees visible to the caller; optional build_status filter.',
    ARRAY['pageindex.read']::text[], 'read_only', '{}'::jsonb, true,
    10000, 4096, 1048576,
    jsonb_build_array(
        _v3_api_arg('p_build_status', 'text',    false, 'query'),
        _v3_api_arg('p_limit',        'integer', false, 'query',
                    to_jsonb(50))));

-- GET /v4/pageindex/trees/:tree_id
SELECT rest_register_endpoint(
    'GET', '/v4/pageindex/trees/:tree_id',
    'pageindex_get_tree(bigint)'::regprocedure,
    'Fetch a single PageIndex tree row by tree_id.',
    ARRAY['pageindex.read']::text[], 'read_only', '{}'::jsonb, true,
    10000, 1024, 65536,
    jsonb_build_array(
        _v3_api_arg('p_tree_id', 'bigint', true, 'path')));

-- POST /v4/pageindex/ask
SELECT rest_register_endpoint(
    'POST', '/v4/pageindex/ask',
    'retrieve_with_envelope_tree(text, bigint, jsonb, integer)'::regprocedure,
    'Descend a PageIndex tree to answer a query; returns leaf terminus + envelope_id.',
    ARRAY['pageindex.read','retrieval.read']::text[], 'read_only', '{}'::jsonb, true,
    30000, 65536, 1048576,
    jsonb_build_array(
        _v3_api_arg('p_cue_text',        'text'),
        _v3_api_arg('p_tree_id',         'bigint'),
        _v3_api_arg('p_descent_options', 'jsonb',   false, 'body',
                    '{}'::jsonb),
        _v3_api_arg('p_limit',           'integer', false, 'body',
                    to_jsonb(1))));

-- POST /v4/chatindex/build
SELECT rest_register_endpoint(
    'POST', '/v4/chatindex/build',
    'source_package_promote_to_chat_index(bigint, bigint, bigint, integer, jsonb)'::regprocedure,
    'Promote a Source Package to a ChatIndex tree (queues the builder).',
    ARRAY['chatindex.write']::text[], 'state_changing', '{}'::jsonb, true,
    30000, 1048576, 65536,
    jsonb_build_array(
        _v3_api_arg('p_source_package_id',  'bigint'),
        _v3_api_arg('p_model_alias_id',     'bigint',  false),
        _v3_api_arg('p_prompt_template_id', 'bigint',  false),
        _v3_api_arg('p_max_children',       'integer', false, 'body',
                    to_jsonb(10)),
        _v3_api_arg('p_builder_options',    'jsonb',   false)));

-- POST /v4/chatindex/append
SELECT rest_register_endpoint(
    'POST', '/v4/chatindex/append',
    'chat_index_append_messages(bigint, jsonb)'::regprocedure,
    'Append one or more messages to a ChatIndex tree (handles topic decisions).',
    ARRAY['chatindex.write']::text[], 'state_changing', '{}'::jsonb, true,
    30000, 4194304, 1048576,
    jsonb_build_array(
        _v3_api_arg('p_tree_id',  'bigint'),
        _v3_api_arg('p_messages', 'jsonb')));

-- GET /v4/chatindex/trees
SELECT rest_register_endpoint(
    'GET', '/v4/chatindex/trees',
    'chatindex_list_trees(text, integer)'::regprocedure,
    'List ChatIndex trees visible to the caller; optional build_status filter.',
    ARRAY['chatindex.read']::text[], 'read_only', '{}'::jsonb, true,
    10000, 4096, 1048576,
    jsonb_build_array(
        _v3_api_arg('p_build_status', 'text',    false, 'query'),
        _v3_api_arg('p_limit',        'integer', false, 'query',
                    to_jsonb(50))));

-- POST /v4/chatindex/ask
SELECT rest_register_endpoint(
    'POST', '/v4/chatindex/ask',
    'retrieve_with_envelope_chat_tree(text, bigint, jsonb, integer)'::regprocedure,
    'Descend a ChatIndex tree to answer a query; returns leaf terminus + envelope_id.',
    ARRAY['chatindex.read','retrieval.read']::text[], 'read_only', '{}'::jsonb, true,
    30000, 65536, 1048576,
    jsonb_build_array(
        _v3_api_arg('p_cue_text',        'text'),
        _v3_api_arg('p_chat_tree_id',    'bigint'),
        _v3_api_arg('p_descent_options', 'jsonb',   false, 'body',
                    '{}'::jsonb),
        _v3_api_arg('p_limit',           'integer', false, 'body',
                    to_jsonb(1))));

-- Cleanup the migration-local helper.
DROP FUNCTION _v3_api_arg(text, text, boolean, text, jsonb);
