SET search_path TO maludb_core, public;

-- =======================================================================
-- R1.0-8 minimum tool surface — pg_regress coverage.
-- Verifies the 11 sql_function tools + 2 catalog-only exemplars are
-- registered against the maludb.r10 server profile, then exercises each
-- function inside the mc2db._begin_request / _end_request bracket and
-- asserts payload shape. Cumulative state: account → session → context
-- → render → submit → response.
-- =======================================================================

-- 1. Catalog: registered count and impl_type breakdown
SELECT count(*) AS r10_tool_count
FROM malu$mc2db_tool t JOIN malu$mc2db_server s USING (server_id)
WHERE s.server_name = 'maludb.r10';

SELECT implementation_type, count(*) AS n
FROM malu$mc2db_tool t JOIN malu$mc2db_server s USING (server_id)
WHERE s.server_name = 'maludb.r10'
GROUP BY implementation_type ORDER BY implementation_type;

-- 2. Stable registration order (alphabetical-by-name)
SELECT tool_name, implementation_type
FROM malu$mc2db_tool t JOIN malu$mc2db_server s USING (server_id)
WHERE s.server_name = 'maludb.r10'
ORDER BY tool_name;

-- ----- helper: bracket each tool call inside a request --------------
-- Each section: _begin_request → SELECT r10_<tool>(args, context) → _end_request
-- and read out structuredContent fields we want to assert.

-- 3. maludb.health
SELECT mc2db._begin_request('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaa0001'::uuid,'maludb.health');
SELECT r10_health('{}'::jsonb,
                  jsonb_build_object('call_id','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaa0001',
                                     'request_user','r10-tester'));
SELECT payload->>'isError' AS is_err,
       payload->'structuredContent'->>'status'  AS status,
       payload->'structuredContent'->>'release' AS release
FROM mc2db._end_request();

-- 4. maludb.catalog.describe — default scope
SELECT mc2db._begin_request('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaa0002'::uuid,'maludb.catalog.describe');
SELECT r10_catalog_describe('{}'::jsonb,
                  jsonb_build_object('call_id','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaa0002'));
SELECT payload->>'isError' AS is_err,
       payload->'structuredContent'->>'schema' AS schema,
       jsonb_array_length(payload->'structuredContent'->'tables') > 10 AS many_tables
FROM mc2db._end_request();

-- 5. maludb.models.list — empty registry on a fresh install is fine;
-- seed two providers + aliases first so the listing has rows.
INSERT INTO malu$account(account_name, account_kind) VALUES ('r10','human');
SELECT register_model_provider('r10-stub','stub','stub','SECRET','internal') AS provider_id;
SELECT register_model_provider('r10-cloud','cloud_api','openai','env:K','restricted') AS provider_id;
SELECT register_model_alias('r10-alias-stub','r10-stub','stub-model-1') AS alias_id;
SELECT register_model_alias('r10-alias-cloud','r10-cloud','gpt-test',NULL,NULL,NULL,8192) AS alias_id;

SELECT mc2db._begin_request('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaa0003'::uuid,'maludb.models.list');
SELECT r10_models_list('{}'::jsonb, '{}'::jsonb);
SELECT payload->>'isError' AS is_err,
       jsonb_array_length(payload->'structuredContent'->'aliases') AS alias_count
FROM mc2db._end_request();

-- 6. maludb.prompts.list — two-channel prompt to make has_channels true
SELECT register_prompt_template(
    p_name => 'r10-greet',
    p_body => 'fallback',
    p_owner_account => 'r10',
    p_variables => NULL,
    p_version => NULL,
    p_system_template    => 'You are r10.',
    p_developer_template => NULL,
    p_user_template      => 'Hi :name from {{operator}}.') AS template_id;

SELECT mc2db._begin_request('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaa0004'::uuid,'maludb.prompts.list');
SELECT r10_prompts_list(jsonb_build_object('name_pattern','r10-%'), '{}'::jsonb);
SELECT payload->>'isError' AS is_err,
       jsonb_array_length(payload->'structuredContent'->'templates') AS templates,
       (payload->'structuredContent'->'templates'->0->>'has_channels')::bool AS has_channels
FROM mc2db._end_request();

-- 7. maludb.sessions.create
SELECT mc2db._begin_request('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaa0005'::uuid,'maludb.sessions.create');
SELECT r10_sessions_create(
    jsonb_build_object('account_name','r10','alias_name','r10-alias-stub','template_name','r10-greet'),
    '{}'::jsonb);
SELECT payload->>'isError' AS is_err,
       (payload->'structuredContent'->>'session_id')::bigint > 0 AS got_session
FROM mc2db._end_request();

-- Pull the session_id back so subsequent steps can use it.
SELECT session_id FROM malu$session WHERE account_id =
   (SELECT account_id FROM malu$account WHERE account_name='r10') \gset

-- 8. maludb.sessions.create — missing account_name → tool error
SELECT mc2db._begin_request('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaa0006'::uuid,'maludb.sessions.create');
SELECT r10_sessions_create('{}'::jsonb, '{}'::jsonb);
SELECT payload->>'isError' AS is_err,
       payload->'structuredContent'->'error'->>'code' AS err_code
FROM mc2db._end_request();

-- 9. maludb.context.append (twice)
SELECT mc2db._begin_request('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaa0007'::uuid,'maludb.context.append');
SELECT r10_context_append(
    jsonb_build_object('session_id', :session_id, 'role','system','content_text','be terse'),
    '{}'::jsonb);
SELECT payload->>'isError' AS is_err,
       payload->'structuredContent'->>'ordinal' AS ordinal
FROM mc2db._end_request();

SELECT mc2db._begin_request('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaa0008'::uuid,'maludb.context.append');
SELECT r10_context_append(
    jsonb_build_object('session_id', :session_id, 'role','user','content_text','about widgets'),
    '{}'::jsonb);
SELECT payload->>'isError' AS is_err,
       payload->'structuredContent'->>'ordinal' AS ordinal
FROM mc2db._end_request();

-- 10. maludb.context.read — should see two blocks
SELECT mc2db._begin_request('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaa0009'::uuid,'maludb.context.read');
SELECT r10_context_read(jsonb_build_object('session_id', :session_id), '{}'::jsonb);
SELECT payload->>'isError' AS is_err,
       jsonb_array_length(payload->'structuredContent'->'blocks') AS block_count,
       payload->'structuredContent'->'blocks'->0->>'role' AS first_role
FROM mc2db._end_request();

-- 11. maludb.prompts.render
SELECT mc2db._begin_request('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaa000a'::uuid,'maludb.prompts.render');
SELECT r10_prompts_render(
    jsonb_build_object(
        'session_id', :session_id,
        'template_name','r10-greet',
        'variables', jsonb_build_object('name','Bob','operator','sonia')),
    '{}'::jsonb);
SELECT payload->>'isError' AS is_err,
       (payload->'structuredContent'->>'render_id')::bigint > 0 AS got_render,
       length(payload->'structuredContent'->>'prompt_hash') AS hash_len,
       payload->'structuredContent'->>'context_block_count' AS ctx_blocks
FROM mc2db._end_request();

-- Pull render_id for the next step
SELECT max(render_id) AS render_id FROM malu$prompt_render \gset

-- 12. maludb.models.submit — stub adapter resolves synchronously
SELECT mc2db._begin_request('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaa000b'::uuid,'maludb.models.submit');
SELECT r10_models_submit(
    jsonb_build_object('render_id', :render_id, 'alias_name','r10-alias-stub'),
    '{}'::jsonb);
SELECT payload->>'isError' AS is_err,
       (payload->'structuredContent'->>'request_id')::bigint > 0 AS got_request,
       (payload->'structuredContent'->>'response_id')::bigint > 0 AS sync_response,
       payload->'structuredContent'->>'provider_kind' AS kind
FROM mc2db._end_request();

SELECT max(request_id) AS request_id FROM malu$model_request \gset

-- 13. maludb.responses.get — stub response is present
SELECT mc2db._begin_request('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaa000c'::uuid,'maludb.responses.get');
SELECT r10_responses_get(jsonb_build_object('request_id', :request_id), '{}'::jsonb);
SELECT payload->>'isError' AS is_err,
       payload->'structuredContent'->>'pending' AS pending,
       payload->'structuredContent'->'response'->>'finish_reason' AS finish_reason,
       payload->'structuredContent'->'response'->>'status' AS status
FROM mc2db._end_request();

-- 14. maludb.responses.get — unknown request_id surfaces pending=true (not an error)
SELECT mc2db._begin_request('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaa000d'::uuid,'maludb.responses.get');
SELECT r10_responses_get(jsonb_build_object('request_id', 999999999), '{}'::jsonb);
SELECT payload->>'isError' AS is_err,
       payload->'structuredContent'->>'pending' AS pending
FROM mc2db._end_request();

-- 15. maludb.sessions.get — closes the loop on the cumulative state
SELECT mc2db._begin_request('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaa000e'::uuid,'maludb.sessions.get');
SELECT r10_sessions_get(jsonb_build_object('session_id', :session_id), '{}'::jsonb);
SELECT payload->>'isError' AS is_err,
       payload->'structuredContent'->'session'->>'lifecycle_state' AS state,
       payload->'structuredContent'->'session'->>'account_name'    AS account
FROM mc2db._end_request();
