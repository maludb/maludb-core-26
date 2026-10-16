-- Stage 6 S6-4 — Advanced MC2DB tool registry.
--
-- Exercises:
--   * 'maludb.advanced' server exists and carries 27 tools.
--   * Every tool's impl_metadata.function_signature resolves to a real
--     function in maludb_core.
--   * Calling a tool wrapper directly via mc2db.* dispatch works:
--     advanced_write_memory() inserts a memory and the response
--     envelope is queued by mc2db.put_object.
--   * Risk class + read_only flags set correctly: write tools NOT read_only.

\set ECHO all
SET search_path = maludb_core, public;
SET client_min_messages = NOTICE;

-- ---------- server + count -----------------------------------------
SELECT server_name, title
FROM malu$mc2db_server WHERE server_name = 'maludb.advanced';

SELECT count(*) AS advanced_tool_count
FROM malu$mc2db_tool t
JOIN malu$mc2db_server s ON s.server_id = t.server_id
WHERE s.server_name = 'maludb.advanced';

-- ---------- one tool per category exists ---------------------------
SELECT
    bool_or(tool_name = 'maludb.retrieve')                   AS has_retrieve,
    bool_or(tool_name = 'maludb.text_search')                AS has_text_search,
    bool_or(tool_name = 'maludb.episode.replay')             AS has_replay,
    bool_or(tool_name = 'maludb.workflow.extract_trace')     AS has_workflow_extract,
    bool_or(tool_name = 'maludb.skill.begin')                AS has_skill_begin,
    bool_or(tool_name = 'maludb.pool.create')                AS has_pool_create,
    bool_or(tool_name = 'maludb.node.submit')                AS has_node_submit,
    bool_or(tool_name = 'maludb.write.memory')               AS has_write_memory
FROM malu$mc2db_tool t
JOIN malu$mc2db_server s ON s.server_id = t.server_id
WHERE s.server_name = 'maludb.advanced';

-- ---------- write tools are NOT read_only --------------------------
SELECT tool_name, read_only, risk_class
FROM malu$mc2db_tool t
JOIN malu$mc2db_server s ON s.server_id = t.server_id
WHERE s.server_name = 'maludb.advanced'
  AND tool_name IN ('maludb.write.claim','maludb.write.memory',
                    'maludb.write.episode','maludb.skill.step',
                    'maludb.pool.create','maludb.node.submit')
ORDER BY tool_name;

-- ---------- node.accept is the only require_confirmation tool -------
SELECT tool_name
FROM malu$mc2db_tool t
JOIN malu$mc2db_server s ON s.server_id = t.server_id
WHERE s.server_name = 'maludb.advanced' AND require_confirmation
ORDER BY tool_name;

-- ---------- function_signature is regprocedure: every row points to
-- a real function (regprocedure NOT NULL enforces it at INSERT time).
SELECT count(*) AS sql_function_rows
FROM malu$mc2db_tool t
JOIN malu$mc2db_server s ON s.server_id = t.server_id
JOIN malu$mc2db_tool_sql_function sf ON sf.tool_id = t.tool_id
WHERE s.server_name = 'maludb.advanced';

-- ---------- direct wrapper invocation under an MC2DB request -----
-- Wrappers call mc2db.put_object which requires an active request
-- context; we open one via mc2db._begin_request, run the wrapper,
-- and close with mc2db._end_request.
SELECT mc2db._begin_request(gen_random_uuid(), 'maludb.write.memory');

SELECT advanced_write_memory(
    jsonb_build_object(
        'memory_kind', 'lesson',
        'title', 's6-4 tool test',
        'summary', 'Direct wrapper invocation works'),
    '{}'::jsonb);

-- Drain the response context so the next call can begin.
SELECT count(*) > 0 AS write_memory_envelope_produced
FROM mc2db._end_request();

SELECT count(*) AS memory_inserted
FROM malu$memory WHERE title = 's6-4 tool test';

-- ---------- second invocation: retrieve ---------------------------
SELECT mc2db._begin_request(gen_random_uuid(), 'maludb.retrieve');

SELECT advanced_retrieve(
    jsonb_build_object('cue_text', 's6-4', 'object_types',
                       jsonb_build_array('memory'), 'limit', 5),
    '{}'::jsonb);

SELECT count(*) > 0 AS retrieve_envelope_produced
FROM mc2db._end_request();

-- ---------- cleanup -----------------------------------------------
DELETE FROM malu$memory WHERE title = 's6-4 tool test';
