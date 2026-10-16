-- R1.1-4: bound_prompt composite + bind_prompt() + call().
--
-- Exercises:
--   * channel-aware rendering (system/developer/user split preserved)
--   * legacy body-only template still produces rendered_full
--   * variable validation propagates from R1.1-5 into bind_prompt
--   * session context merges into rendered_full when session_id given
--   * call() submits a malu$model_request linked to the bind's render
--   * template_hash detects template body change between binds
--   * max_rendered_prompt_chars enforced against the final rendered text

\set ECHO all
SET search_path = maludb_core, public;
SET client_min_messages = NOTICE;

-- ---------- fixture ----------------------------------------------------
INSERT INTO malu$account(account_name, account_kind, description)
VALUES ('bp_tenant', 'admin', 'R1.1-4 bound_prompt test');

-- body is NOT NULL on malu$prompt_template; channel-only callers still
-- supply a body (it's preserved for the legacy render path but channels
-- win at compose time).
INSERT INTO malu$prompt_template (template_name, body, system_template, developer_template, user_template)
VALUES
    ('bp_channels', 'fallback body unused when channels exist',
     'You are a helpful assistant for {{tenant}}.',
     'Behaviour: terse.',
     'Greet {{name}}.'),
    ('bp_body', 'plain hello {{name}}', NULL, NULL, NULL);

SELECT declare_prompt_variable('bp_channels', 'tenant', p_required=>true) > 0 AS ok1;
SELECT declare_prompt_variable('bp_channels', 'name',   p_required=>true) > 0 AS ok2;
SELECT declare_prompt_variable('bp_body',     'name',   p_required=>true) > 0 AS ok3;

INSERT INTO malu$model_provider (provider_name, provider_kind, adapter_name)
VALUES ('bp_provider', 'stub', 'stub_adapter');

INSERT INTO malu$model_alias (alias_name, provider_id, model_identifier)
VALUES ('bp_alias',
        (SELECT provider_id FROM malu$model_provider WHERE provider_name='bp_provider'),
        'bp-model');

-- ---------- bind_prompt: channels --------------------------------------
SELECT
    template_name,
    template_version,
    rendered_system,
    rendered_developer,
    rendered_user,
    rendered_full,
    validation_status,
    estimated_tokens > 0 AS tokens_set
FROM bind_prompt('bp_channels',
                 jsonb_build_object('tenant','Acme','name','Mira'));

-- the row landed in malu$bound_prompt
SELECT count(*) AS bound_rows,
       max(validation_status) AS status_seen,
       max(char_length(rendered_full)) > 0 AS has_text
FROM malu$bound_prompt
WHERE template_id = (SELECT template_id FROM malu$prompt_template WHERE template_name='bp_channels');

-- and pairs with a malu$prompt_render row
SELECT count(*) > 0 AS paired_render
FROM malu$bound_prompt bp
JOIN malu$prompt_render pr ON pr.render_id = bp.render_id
WHERE bp.template_id = (SELECT template_id FROM malu$prompt_template WHERE template_name='bp_channels');

-- ---------- bind_prompt: legacy body-only template ---------------------
SELECT rendered_system IS NULL  AS no_system,
       rendered_developer IS NULL AS no_developer,
       rendered_user IS NULL    AS no_user,
       rendered_full
FROM bind_prompt('bp_body', jsonb_build_object('name','Noor'));

-- ---------- bind_prompt: validation propagates -------------------------
DO $$ BEGIN
    PERFORM bind_prompt('bp_channels', jsonb_build_object('tenant','Acme'));
    RAISE EXCEPTION 'should have rejected missing required';
EXCEPTION WHEN not_null_violation THEN
    RAISE NOTICE 'OK: bind propagates required-missing';
END $$;

-- on_extra_variable=warn (default): bind still succeeds, validation_status='warned'
SELECT validation_status
FROM bind_prompt('bp_channels',
                 jsonb_build_object('tenant','Acme','name','Pia','extra','x'));

-- ---------- bind_prompt: session context appended ----------------------
INSERT INTO malu$session (account_id, prompt_template_id)
SELECT account_id, (SELECT template_id FROM malu$prompt_template WHERE template_name='bp_channels')
FROM malu$account WHERE account_name='bp_tenant'
RETURNING session_id \gset

INSERT INTO malu$session_context (session_id, ordinal, role, content_text, content_hash)
VALUES
    (:session_id, 1, 'user',      'previous turn 1',
     encode(sha256('previous turn 1'::bytea),'hex')),
    (:session_id, 2, 'assistant', 'previous turn 2',
     encode(sha256('previous turn 2'::bytea),'hex'));

SELECT
    char_length(rendered_full) >
    char_length(rendered_system) + char_length(rendered_developer) + char_length(rendered_user)
        AS context_extends_full,
    validation_status
FROM bind_prompt('bp_channels',
                 jsonb_build_object('tenant','Acme','name','Quinn'),
                 NULL,
                 :session_id);

-- the bind row carries the session_id forward
SELECT count(*) > 0 AS bind_has_session
FROM malu$bound_prompt
WHERE session_id = :session_id;

-- ---------- bind_prompt: template_hash detects body change -------------
SELECT bp1.template_hash = bp2.template_hash AS hash_stable
FROM (SELECT * FROM bind_prompt('bp_channels',
        jsonb_build_object('tenant','Acme','name','Rae'))) bp1,
     (SELECT * FROM bind_prompt('bp_channels',
        jsonb_build_object('tenant','Globex','name','Sasha'))) bp2;

UPDATE malu$prompt_template SET system_template = 'You are a NEW helpful assistant for {{tenant}}.'
WHERE template_name='bp_channels';

-- after the body change, two new binds against the new body still hash
-- the same as each other (sanity), and they differ from a pre-change
-- hash. We verify the second clause indirectly via the bound_prompt
-- table (it kept the pre-change hashes).
SELECT bp1.template_hash = bp2.template_hash AS hash_stable_post_change
FROM (SELECT * FROM bind_prompt('bp_channels',
        jsonb_build_object('tenant','Acme','name','Tao'))) bp1,
     (SELECT * FROM bind_prompt('bp_channels',
        jsonb_build_object('tenant','Acme','name','Tao'))) bp2;

SELECT count(DISTINCT template_hash) >= 2 AS hashes_diverged
FROM malu$bound_prompt
WHERE template_id = (SELECT template_id FROM malu$prompt_template WHERE template_name='bp_channels');

-- ---------- call(): submits a model request ----------------------------
CREATE TEMP TABLE _bp_call_test AS
    SELECT bind_prompt('bp_body', jsonb_build_object('name','Uma')) AS bp;

SELECT call((SELECT bp FROM _bp_call_test), 'bp_alias') AS request_id \gset

SELECT :request_id > 0 AS request_created,
       mr.status,
       mr.rendered_prompt
FROM malu$model_request mr
WHERE mr.request_id = :request_id;

-- the request points at the bound prompt's render
SELECT count(*) > 0 AS request_linked_to_bind
FROM malu$model_request mr
JOIN malu$bound_prompt bp ON bp.render_id = mr.prompt_render_id
WHERE bp.bound_prompt_id = (SELECT (bp).bound_prompt_id FROM _bp_call_test);

-- a more idiomatic call: nest bind_prompt() inside call() directly
SELECT call(bind_prompt('bp_body', jsonb_build_object('name','Vee')), 'bp_alias') > 0
    AS request_via_nested_call;

-- ---------- call(): rejects bad inputs ---------------------------------
DO $$ BEGIN
    PERFORM call(
        ROW(999999, NULL, NULL, NULL, NULL,
            NULL::jsonb, NULL, NULL, NULL,
            NULL, NULL, NULL, NULL)::bound_prompt,
        'bp_alias');
    RAISE EXCEPTION 'should have rejected unknown bound_prompt_id';
EXCEPTION WHEN no_data_found THEN
    RAISE NOTICE 'OK: call rejects unknown bound_prompt_id';
END $$;

DO $$ BEGIN
    PERFORM call(
        ROW(NULL::bigint, NULL, NULL, NULL, NULL,
            NULL::jsonb, NULL, NULL, NULL,
            NULL, NULL, NULL, NULL)::bound_prompt,
        'bp_alias');
    RAISE EXCEPTION 'should have rejected NULL bound_prompt_id';
EXCEPTION WHEN invalid_parameter_value THEN
    RAISE NOTICE 'OK: call rejects NULL bound_prompt_id';
END $$;

-- ---------- bind_prompt: max_rendered_prompt_chars on actual text ------
-- big enough that the rendered_full exceeds the cap; truncate_with_notice
-- mode succeeds with a NOTICE. error mode is exercised in prompt_variable.sql.
SELECT char_length(rendered_full) AS post_truncate_len
FROM bind_prompt('bp_body',
                 jsonb_build_object('name', repeat('Z', 200)),
                 ROW(true,'error','warn','null_literal',NULL,40,'truncate_with_notice','none')::malu$bind_options);

-- ---------- cleanup ----------------------------------------------------
DROP TABLE _bp_call_test;
DELETE FROM malu$model_request WHERE alias_id =
    (SELECT alias_id FROM malu$model_alias WHERE alias_name='bp_alias');
DELETE FROM malu$bound_prompt WHERE template_id IN
    (SELECT template_id FROM malu$prompt_template WHERE template_name IN ('bp_channels','bp_body'));
DELETE FROM malu$prompt_render WHERE template_id IN
    (SELECT template_id FROM malu$prompt_template WHERE template_name IN ('bp_channels','bp_body'));
DELETE FROM malu$session_context WHERE session_id = :session_id;
DELETE FROM malu$session WHERE session_id = :session_id;
DELETE FROM malu$prompt_variable WHERE template_id IN
    (SELECT template_id FROM malu$prompt_template WHERE template_name IN ('bp_channels','bp_body'));
DELETE FROM malu$prompt_template WHERE template_name IN ('bp_channels','bp_body');
DELETE FROM malu$model_alias WHERE alias_name='bp_alias';
DELETE FROM malu$model_provider WHERE provider_name='bp_provider';
DELETE FROM malu$account WHERE account_name='bp_tenant';
