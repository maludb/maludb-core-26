SET search_path TO maludb_core, public;
INSERT INTO malu$account(account_name, account_kind) VALUES ('bob', 'agent');
SELECT register_prompt_template(
    'echo-vars',
    E'A={{alpha}} B={{beta}} C={{gamma}}',
    'bob'
) AS template_id \gset
SELECT register_prompt_template('echo-vars', E'V2 A={{alpha}}', 'bob') AS v2_id;
SELECT start_session('bob', 'alias-stub') AS session_id \gset
SELECT render_prompt(:session_id, 'echo-vars', 1, '{"alpha":"1","beta":"2","gamma":"3"}'::jsonb) AS r_a \gset
SELECT render_prompt(:session_id, 'echo-vars', 1, '{"gamma":"3","beta":"2","alpha":"1"}'::jsonb) AS r_b \gset
SELECT (SELECT prompt_hash FROM malu$prompt_render WHERE render_id=:r_a) =
       (SELECT prompt_hash FROM malu$prompt_render WHERE render_id=:r_b)
       AS variable_order_independent;
SELECT render_prompt(:session_id, 'echo-vars', 1, '{"alpha":"X","beta":"2","gamma":"3"}'::jsonb) AS r_c \gset
SELECT (SELECT prompt_hash FROM malu$prompt_render WHERE render_id=:r_a) <>
       (SELECT prompt_hash FROM malu$prompt_render WHERE render_id=:r_c)
       AS different_value_changes_hash;
SELECT render_prompt(:session_id, 'echo-vars', NULL, '{"alpha":"1"}'::jsonb) AS r_latest \gset
SELECT template_id = :v2_id AS picked_latest_version
FROM malu$prompt_render WHERE render_id = :r_latest;
SELECT append_context(:session_id, 'user', 'context-A') AS ctx_a \gset
SELECT render_prompt(:session_id, 'echo-vars', 1, '{"alpha":"1","beta":"2","gamma":"3"}'::jsonb) AS r_with_ctx \gset
SELECT (SELECT prompt_hash FROM malu$prompt_render WHERE render_id=:r_a) <>
       (SELECT prompt_hash FROM malu$prompt_render WHERE render_id=:r_with_ctx)
       AS adding_context_changes_hash,
       context_block_count
FROM malu$prompt_render WHERE render_id = :r_with_ctx;
SELECT clear_context(:session_id);
SELECT render_prompt(:session_id, 'echo-vars', 1, '{"alpha":"1","beta":"2","gamma":"3"}'::jsonb) AS r_after_clear \gset
SELECT (SELECT prompt_hash FROM malu$prompt_render WHERE render_id=:r_a) =
       (SELECT prompt_hash FROM malu$prompt_render WHERE render_id=:r_after_clear)
       AS clearing_context_returns_to_baseline;
