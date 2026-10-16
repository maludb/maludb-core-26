SET search_path TO maludb_core, public;

-- =======================================================================
-- R1.0-6.5: Prompt and Response Refinements
--   - {{var}} and :var substitution from the same variables jsonb
--   - system / developer / user prompt channels (with body fallback)
--   - preview_prompt: dry-run, no INSERT into malu$prompt_render
--   - finish_reason and four new response columns
--   - widened provider_kind taxonomy
-- =======================================================================

INSERT INTO malu$account(account_name, account_kind) VALUES ('nan','human');

-- Legacy body-only template, both syntaxes mixed
SELECT register_prompt_template(
    p_name => 'r65-legacy',
    p_body => 'Hello {{name}}, code=:code'
) AS legacy_tid \gset

-- Channel-aware template (body kept as fallback marker)
SELECT register_prompt_template(
    p_name               => 'r65-channels',
    p_body               => '(unused fallback)',
    p_owner_account      => NULL,
    p_variables          => NULL,
    p_version            => NULL,
    p_system_template    => 'You are :role assistant.',
    p_developer_template => 'Operator: {{operator}}',
    p_user_template      => 'Hi :name, your code is {{code}}.'
) AS channel_tid \gset

-- Confirm the channel columns landed
SELECT (system_template    IS NOT NULL) AS has_sys,
       (developer_template IS NOT NULL) AS has_dev,
       (user_template      IS NOT NULL) AS has_usr,
       body = '(unused fallback)' AS body_kept
FROM malu$prompt_template WHERE template_id = :channel_tid;

SELECT start_session('nan') AS sid \gset
SELECT append_context(:sid, 'user', 'r65 ctx', NULL, 'manual') AS cid;

-- preview_prompt on legacy template; both {{name}} and :code substitute
SELECT rendered_prompt FROM preview_prompt(
    :sid, 'r65-legacy', NULL,
    jsonb_build_object('name','Bob','code','42'));

-- preview_prompt on channel template; :name and {{code}} both work
SELECT rendered_prompt FROM preview_prompt(
    :sid, 'r65-channels', NULL,
    jsonb_build_object('name','Bob','code','42','operator','sonia','role','helpful'));

-- preview did NOT insert any render rows for this session
SELECT count(*) AS render_rows_after_preview
FROM malu$prompt_render WHERE session_id = :sid;

-- {{var}} alone and :var alone produce identical hashes for equivalent input
WITH curly  AS (SELECT prompt_hash FROM preview_prompt(:sid,'r65-legacy',NULL,
                  jsonb_build_object('name','Bob','code','42'))),
     colon  AS (SELECT prompt_hash FROM preview_prompt(:sid,'r65-legacy',NULL,
                  jsonb_build_object('name','Bob','code','42')))
SELECT curly.prompt_hash = colon.prompt_hash AS dual_syntax_deterministic
FROM curly, colon;

-- Now actually render (one row inserted) and confirm channels appear
SELECT render_prompt(:sid, 'r65-channels', NULL,
    jsonb_build_object('name','Bob','code','42','operator','sonia','role','helpful'))
    AS rid \gset

SELECT rendered_prompt LIKE '%SYSTEM:%'    AS has_system_marker,
       rendered_prompt LIKE '%DEVELOPER:%' AS has_developer_marker,
       rendered_prompt LIKE '%USER:%'      AS has_user_marker,
       rendered_prompt LIKE '%helpful%'    AS sys_var_substituted,
       rendered_prompt LIKE '%sonia%'      AS dev_var_substituted,
       rendered_prompt LIKE '%Hi Bob%'     AS usr_colon_substituted,
       rendered_prompt LIKE '%code is 42%' AS usr_curly_substituted,
       context_block_count
FROM malu$prompt_render WHERE render_id = :rid;

-- Stub adapter populates finish_reason; output_json/tool_calls/raw stay NULL
SELECT submit_render(:rid, 'alias-stub') AS req_id \gset
SELECT mc_stub_process(:req_id) AS resp_id \gset

SELECT status, finish_reason,
       output_json IS NULL            AS output_json_null,
       tool_calls IS NULL             AS tool_calls_null,
       raw_provider_response IS NULL  AS raw_null
FROM malu$model_response WHERE response_id = :resp_id;

-- model_run_audit surfaces finish_reason
SELECT finish_reason FROM model_run_audit WHERE response_id = :resp_id;

-- Widened provider_kind taxonomy: all six values accept
INSERT INTO malu$model_provider(provider_name, provider_kind) VALUES
    ('r65-cloudapi',  'cloud_api'),
    ('r65-localrun',  'local_runtime'),
    ('r65-localhttp', 'local_http'),
    ('r65-localsock', 'local_socket'),
    ('r65-shell',     'shell_adapter'),
    ('r65-stub',      'stub');
SELECT count(*) AS r65_provider_count FROM malu$model_provider WHERE provider_name LIKE 'r65-%';

-- Old taxonomy values rejected. Wrap in DO blocks so the CHECK violation is
-- caught and re-raised as a normalized NOTICE — the raw error includes a
-- timestamp in the failing-row DETAIL whose format is pg_regress-environment
-- dependent.
DO $body$
BEGIN
    INSERT INTO malu$model_provider(provider_name, provider_kind) VALUES ('r65-old-cloud','cloud');
    RAISE EXCEPTION 'old provider_kind cloud unexpectedly accepted';
EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'old provider_kind cloud rejected (expected)';
END
$body$;
DO $body$
BEGIN
    INSERT INTO malu$model_provider(provider_name, provider_kind) VALUES ('r65-old-local','local');
    RAISE EXCEPTION 'old provider_kind local unexpectedly accepted';
EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'old provider_kind local rejected (expected)';
END
$body$;

-- preview_prompt with an unknown template raises the standard error
SELECT * FROM preview_prompt(:sid, 'no-such-template', NULL, '{}'::jsonb);
