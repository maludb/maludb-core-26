SET search_path TO maludb_core, public;

-- create_server round-trip
SELECT mc2db.create_server(
    name => 'r106.test',
    title => 'R1.0-6 catalog test',
    description => 'pg_regress fixture for the polymorphic catalog'
) AS server_id \gset
SELECT server_name, default_risk_class, enabled,
       protocol_versions = ARRAY['2025-11-25'] AS protocol_default
FROM malu$mc2db_server WHERE server_id = :server_id;

-- sql_function tool round-trip
SELECT mc2db.register_tool(
    server_name => 'r106.test',
    tool_name   => 'health',
    description => 'liveness probe',
    implementation_type => 'sql_function',
    impl_metadata => jsonb_build_object(
        'function_signature','maludb_core.maludb_core_version()')
) AS sql_tool_id \gset

SELECT t.implementation_type,
       sf.function_signature::text AS sig,
       sf.transaction_mode,
       sf.pinned_search_path
FROM malu$mc2db_tool t
JOIN malu$mc2db_tool_sql_function sf USING (tool_id)
WHERE t.tool_id = :sql_tool_id;

-- external_exec tool round-trip (catalog only — R1.0 does not dispatch)
SELECT mc2db.register_tool(
    server_name => 'r106.test',
    tool_name   => 'risk_score',
    description => 'external risk scoring (R1.1 dispatch)',
    implementation_type => 'external_exec',
    impl_metadata => jsonb_build_object(
        'command_path','/usr/local/maludb/tools/risk_score.py',
        'argv_template', '[]'::jsonb,
        'environment',   '{}'::jsonb)
) AS exec_tool_id \gset

SELECT t.implementation_type, ee.command_path, ee.input_mode, ee.output_mode
FROM malu$mc2db_tool t
JOIN malu$mc2db_tool_external_exec ee USING (tool_id)
WHERE t.tool_id = :exec_tool_id;

-- mcp_proxy tool round-trip (catalog only — R1.0 does not dispatch)
SELECT mc2db.register_tool(
    server_name => 'r106.test',
    tool_name   => 'doc_search',
    description => 'federated document search (R1.1 dispatch)',
    implementation_type => 'mcp_proxy',
    impl_metadata => jsonb_build_object(
        'remote_server_name','docs',
        'remote_tool_name','search',
        'transport_type','http',
        'endpoint_url','http://127.0.0.1:6000')
) AS proxy_tool_id \gset

SELECT t.implementation_type, px.remote_server_name, px.remote_tool_name, px.transport_type
FROM malu$mc2db_tool t
JOIN malu$mc2db_tool_mcp_proxy px USING (tool_id)
WHERE t.tool_id = :proxy_tool_id;

-- register_tool rejects unknown implementation_type
SELECT mc2db.register_tool(
    server_name => 'r106.test', tool_name => 'bad', description => 'x',
    implementation_type => 'wat',
    impl_metadata => '{}'::jsonb);

-- register_tool rejects per-type metadata mismatch (command_path on sql_function)
SELECT mc2db.register_tool(
    server_name => 'r106.test', tool_name => 'mismatch', description => 'x',
    implementation_type => 'sql_function',
    impl_metadata => jsonb_build_object(
        'function_signature','maludb_core.maludb_core_version()',
        'command_path','/bin/false'));

-- register_tool rejects required metadata missing (sql_function w/o function_signature)
SELECT mc2db.register_tool(
    server_name => 'r106.test', tool_name => 'no_sig', description => 'x',
    implementation_type => 'sql_function',
    impl_metadata => '{}'::jsonb);

-- register_prompt + register_resource round-trip
SELECT mc2db.register_prompt(
    server_name => 'r106.test',
    prompt_name => 'hello',
    description => 'demo prompt') AS prompt_id;

SELECT mc2db.register_resource(
    server_name => 'r106.test',
    uri_template => 'maludb://health',
    description => 'static health resource') AS resource_id;

-- put_object outside active context errors
CALL mc2db.put_object('{"a":1}'::jsonb);

-- begin/put/end happy path
SELECT mc2db._begin_request('11111111-1111-4111-8111-111111111111'::uuid, 'health');
CALL mc2db.put_object(
    jsonb_build_object('content', jsonb_build_array(
        jsonb_build_object('type','text','text','ok')),
                       'isError', false));
CALL mc2db.put_text('extra block');
SELECT tool_name,
       payload->>'isError' AS is_err,
       jsonb_array_length(text_blocks) AS text_count
FROM mc2db._end_request();

-- after end_request, put_object errors again
CALL mc2db.put_object('{"a":2}'::jsonb);

-- double-begin errors
SELECT mc2db._begin_request('22222222-2222-4222-8222-222222222222'::uuid, 'a');
SELECT mc2db._begin_request('33333333-3333-4333-8333-333333333333'::uuid, 'b');
SELECT * FROM mc2db._end_request();

-- invocation audit row writeable; reserved external columns NULL for sql_function
INSERT INTO malu$mc2db_invocation(
    call_id, tool_id, tool_name, implementation_type,
    request_user, database_role, success, started_at, finished_at, duration_ms)
VALUES ('44444444-4444-4444-8444-444444444444', :sql_tool_id, 'health',
        'sql_function', 'eve', current_user, true, now(), now(), 12);

SELECT tool_name, implementation_type, success,
       external_exit_code IS NULL AS exit_null,
       external_stderr   IS NULL AS stderr_null
FROM malu$mc2db_invocation
WHERE call_id = '44444444-4444-4444-8444-444444444444';
