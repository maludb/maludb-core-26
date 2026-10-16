SET search_path TO maludb_core, public;
INSERT INTO malu$account(account_name, account_kind) VALUES ('alice', 'human');
SELECT register_prompt_template(
    'greeting',
    E'Hello {{name}}, your task is {{task}}.',
    'alice'
) AS template_id;
SELECT start_session('alice', 'alias-stub', 'greeting') AS session_id \gset
SELECT lifecycle_state, account_id IS NOT NULL AS account_bound,
       model_alias_id IS NOT NULL AS alias_bound,
       prompt_template_id IS NOT NULL AS template_bound
FROM malu$session WHERE session_id = :session_id;
SELECT append_context(:session_id, 'system', 'You are a helpful assistant.', NULL, 'system_template') AS c1;
SELECT append_context(:session_id, 'user',   'What is the weather?',          NULL, 'user') AS c2;
SELECT append_context(:session_id, 'tool',   NULL,
                      '{"tool":"clock","value":"2026-05-04T12:00Z"}'::jsonb,  'tool_call') AS c3;
SELECT count(*) AS block_count FROM read_context(:session_id);
SELECT ordinal, role, source_label, sensitivity,
       (content_hash IS NOT NULL) AS has_hash
FROM read_context(:session_id) ORDER BY ordinal;
SELECT render_prompt(:session_id, 'greeting', NULL,
                     '{"name":"Alice","task":"forecasting"}'::jsonb) AS render_id \gset
SELECT context_block_count, length(rendered_prompt) > 0 AS rendered,
       length(prompt_hash) AS hash_len, length(context_hash) AS context_hash_len
FROM malu$prompt_render WHERE render_id = :render_id;
SELECT submit_render(:render_id, 'alias-stub', 'alice') AS request_id \gset
SELECT prompt_render_id = :render_id AS render_linked,
       session_id = :session_id     AS session_linked,
       prompt_hash = (SELECT prompt_hash FROM malu$prompt_render WHERE render_id=:render_id)
       AS prompt_hash_linked
FROM malu$model_request WHERE request_id = :request_id;
SELECT mc_stub_process(:request_id);
SELECT status,
       output_text = 'MALUDB_STUB_REPLY:' ||
                    (SELECT prompt_hash FROM malu$prompt_render WHERE render_id=:render_id)
       AS output_matches_render_hash
FROM get_response(:request_id);
SELECT clear_context(:session_id) AS cleared;
SELECT count(*) AS blocks_after_clear FROM read_context(:session_id);
SELECT close_session(:session_id);
SELECT lifecycle_state, closed_at IS NOT NULL AS has_closed_at
FROM malu$session WHERE session_id = :session_id;
SELECT start_session('no-such-account');
SELECT append_context(999999, 'system', 'x');
SELECT render_prompt(:session_id, 'no-such-template');
SELECT close_session(999999);
