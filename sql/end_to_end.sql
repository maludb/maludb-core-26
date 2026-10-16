SET search_path TO maludb_core, public;
INSERT INTO malu$account(account_name, account_kind) VALUES ('eve', 'human');
SELECT register_prompt_template(
    'e2e',
    E'Task for {{user}}: {{action}}',
    'eve'
) AS template_id;
SELECT start_session('eve', 'alias-stub', 'e2e') AS session_id \gset
SELECT append_context(:session_id, 'system', 'be terse');
SELECT append_context(:session_id, 'user',   'about the weather');
SELECT render_id, request_id, response_id IS NOT NULL AS sync_response
FROM run_session_step(
    :session_id, 'e2e', 'alias-stub',
    '{"user":"eve","action":"summarize"}'::jsonb
) \gset
\echo render=:render_id request=:request_id response_id_returned=true
SELECT account_name, alias_name, provider_kind, request_status, response_status,
       context_block_count
FROM model_run_audit
WHERE render_id = :render_id;
SELECT (SELECT prompt_hash FROM malu$prompt_render WHERE render_id = :render_id) =
       (SELECT prompt_hash FROM malu$model_request  WHERE request_id = :request_id)
       AS render_request_hash_matches;
SELECT (SELECT output_text FROM malu$model_response WHERE request_id = :request_id) =
       'MALUDB_STUB_REPLY:' ||
       (SELECT prompt_hash FROM malu$prompt_render WHERE render_id = :render_id)
       AS output_carries_prompt_hash;
SELECT count(*) AS audit_rows_for_session
FROM model_run_audit
WHERE session_id = :session_id;
INSERT INTO malu$model_provider(provider_name, provider_kind, adapter_name, secret_ref)
VALUES ('cloud-stubby', 'cloud_api', 'pretend-openai', 'env:UNUSED');
INSERT INTO malu$model_alias(alias_name, provider_id, model_identifier)
VALUES ('alias-cloudish',
        (SELECT provider_id FROM malu$model_provider WHERE provider_name='cloud-stubby'),
        'pretend-model');
SELECT response_id IS NULL AS response_deferred_for_non_stub
FROM run_session_step(
    :session_id, 'e2e', 'alias-cloudish',
    '{"user":"eve","action":"plan"}'::jsonb
);
SELECT close_session(:session_id);
SELECT lifecycle_state, closed_at IS NOT NULL AS has_closed_at
FROM malu$session WHERE session_id = :session_id;
