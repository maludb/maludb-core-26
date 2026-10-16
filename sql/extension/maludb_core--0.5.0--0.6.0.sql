\echo Use "ALTER EXTENSION maludb_core UPDATE TO '0.6.0'" to load this file. \quit

-- =====================================================================
-- maludb_core 0.5.0 → 0.6.0
--
-- R1.1-4: Prompt-binding ergonomics.
--
-- Adds the `bound_prompt` composite type plus bind_prompt() and call()
-- as a convenience layer on top of the R1.0 render_prompt/submit_render
-- primitives. The legacy three-step flow keeps working unchanged.
--
-- bind_prompt:
--   1. resolve template by name + version
--   2. run R1.1-5 _validate_bind_variables on the supplied variables
--   3. substitute into each channel (system/developer/user) and into
--      the legacy body field, then assemble rendered_full
--   4. (optional) merge session context if p_session_id is supplied
--   5. persist a malu$prompt_render row (so legacy submit_render can
--      consume it) and a malu$bound_prompt row (channel-aware)
--   6. return the bound_prompt composite
--
-- call:
--   1. resolve alias by name
--   2. resolve account_id (param > current_account_id() > NULL)
--   3. insert malu$model_request pointing at the render captured at
--      bind time
--   4. return request_id
-- =====================================================================

CREATE OR REPLACE FUNCTION maludb_core_version() RETURNS text
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$ SELECT '0.6.0'::text $body$;

-- ---------------------------------------------------------------------
-- malu$bound_prompt
--
-- One row per bind_prompt() call. Pairs with malu$prompt_render via
-- render_id (the legacy R1.0 artifact); adds the channel-aware shape,
-- the resolved bind options, and the validator's status + warnings.
-- ---------------------------------------------------------------------
CREATE TABLE malu$bound_prompt (
    bound_prompt_id        bigserial PRIMARY KEY,
    render_id              bigint REFERENCES malu$prompt_render(render_id) ON DELETE SET NULL,
    template_id            bigint NOT NULL
        REFERENCES malu$prompt_template(template_id) ON DELETE RESTRICT,
    template_hash          text NOT NULL,
    account_id             bigint REFERENCES malu$account(account_id) ON DELETE SET NULL,
    session_id             bigint REFERENCES malu$session(session_id) ON DELETE SET NULL,
    variables_raw          jsonb NOT NULL DEFAULT '{}'::jsonb,
    variables_normalized   jsonb NOT NULL DEFAULT '{}'::jsonb,
    rendered_system        text,
    rendered_developer     text,
    rendered_user          text,
    rendered_full          text NOT NULL,
    prompt_hash            text NOT NULL,
    bind_options           malu$bind_options NOT NULL,
    validation_status      text NOT NULL
        CHECK (validation_status IN ('ok','warned')),
    validation_warnings    text[] NOT NULL DEFAULT ARRAY[]::text[],
    estimated_tokens       integer NOT NULL,
    created_at             timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX malu$bound_prompt_template_idx
    ON malu$bound_prompt (template_id, created_at DESC);

COMMENT ON TABLE malu$bound_prompt IS
    'R1.1-4: persistent audit row for a bind_prompt() result. The composite '
    'returned by bind_prompt mirrors a subset of these columns; call() looks '
    'rows up by bound_prompt_id to recover render_id for submission.';

-- ---------------------------------------------------------------------
-- bound_prompt composite type
--
-- Caller-facing surface. Mirrors what's persistent but stays narrower —
-- bind_options, raw variables, audit timestamps are kept in the table
-- only.
-- ---------------------------------------------------------------------
CREATE TYPE bound_prompt AS (
    bound_prompt_id     bigint,
    template_id         bigint,
    template_name       text,
    template_version    integer,
    template_hash       text,
    variables           jsonb,
    rendered_system     text,
    rendered_developer  text,
    rendered_user       text,
    rendered_full       text,
    prompt_hash         text,
    validation_status   text,
    estimated_tokens    integer
);

-- ---------------------------------------------------------------------
-- _template_hash: SHA256 of the channel+body bytes at bind time. Lets
-- callers detect template body changes even when version stays pinned.
-- ---------------------------------------------------------------------
CREATE FUNCTION _template_hash(p_t malu$prompt_template) RETURNS text
LANGUAGE sql IMMUTABLE PARALLEL SAFE
AS $body$
    SELECT encode(sha256(
        (COALESCE(p_t.system_template,    '') || E'\x1f' ||
         COALESCE(p_t.developer_template, '') || E'\x1f' ||
         COALESCE(p_t.user_template,      '') || E'\x1f' ||
         COALESCE(p_t.body,               ''))::bytea
    ), 'hex');
$body$;

-- ---------------------------------------------------------------------
-- _render_channels: substitute normalized variables into each channel
-- + body separately. rendered_full reuses _render_compose so callers
-- that ignore channels still get the same flattened text the R1.0
-- legacy path produced.
-- ---------------------------------------------------------------------
CREATE FUNCTION _render_channels(
    p_template       malu$prompt_template,
    p_variables      jsonb,
    OUT s_text       text,
    OUT d_text       text,
    OUT u_text       text,
    OUT full_text    text
)
LANGUAGE sql IMMUTABLE
AS $body$
    SELECT
        CASE WHEN p_template.system_template IS NULL THEN NULL
             ELSE _render_substitute(p_template.system_template, p_variables) END,
        CASE WHEN p_template.developer_template IS NULL THEN NULL
             ELSE _render_substitute(p_template.developer_template, p_variables) END,
        CASE WHEN p_template.user_template IS NULL THEN NULL
             ELSE _render_substitute(p_template.user_template, p_variables) END,
        _render_substitute(_render_compose(p_template), p_variables);
$body$;

-- ---------------------------------------------------------------------
-- _estimate_tokens: rough heuristic. Real tokenization happens on the
-- model side and is recorded in malu$model_response.prompt_tokens.
-- ---------------------------------------------------------------------
CREATE FUNCTION _estimate_tokens(p_text text) RETURNS integer
LANGUAGE sql IMMUTABLE PARALLEL SAFE
AS $body$
    SELECT GREATEST(1, (char_length(COALESCE(p_text, '')) + 3) / 4);
$body$;

-- ---------------------------------------------------------------------
-- bind_prompt: render variables into a template, persist + return the
-- bound_prompt composite. p_session_id is optional; when supplied,
-- session context is appended to rendered_full (same shape _render_core
-- produces).
-- ---------------------------------------------------------------------
CREATE FUNCTION bind_prompt(
    p_template_name    text,
    p_variables        jsonb              DEFAULT '{}'::jsonb,
    p_opts             malu$bind_options  DEFAULT NULL,
    p_session_id       bigint             DEFAULT NULL,
    p_template_version integer            DEFAULT NULL,
    p_account_id       bigint             DEFAULT NULL
) RETURNS bound_prompt
LANGUAGE plpgsql
AS $body$
DECLARE
    v_template          malu$prompt_template%ROWTYPE;
    v_opts              malu$bind_options := COALESCE(p_opts, _default_bind_options());
    v_validation        malu$bind_validation;
    v_normalized        jsonb;
    v_channels          record;
    v_full              text;
    v_context_text      text;
    v_context_hash      text;
    v_context_count     integer := 0;
    v_prompt_hash       text;
    v_render_id         bigint;
    v_bound_id          bigint;
    v_template_hash     text;
    v_account_id        bigint := p_account_id;
    v_bound             bound_prompt;
BEGIN
    IF p_template_version IS NULL THEN
        SELECT * INTO v_template
        FROM malu$prompt_template
        WHERE template_name = p_template_name AND enabled = true
        ORDER BY template_version DESC
        LIMIT 1;
    ELSE
        SELECT * INTO v_template
        FROM malu$prompt_template
        WHERE template_name = p_template_name
          AND template_version = p_template_version;
    END IF;
    IF v_template.template_id IS NULL THEN
        RAISE EXCEPTION
          'unknown prompt template: % (version %)',
          p_template_name, COALESCE(p_template_version::text, 'latest')
          USING ERRCODE = 'no_data_found';
    END IF;

    v_validation := _validate_bind_variables(
        v_template.template_id, p_variables, v_opts);
    v_normalized := v_validation.normalized_variables;

    v_channels := _render_channels(v_template, v_normalized);
    v_full     := v_channels.full_text;

    IF p_session_id IS NOT NULL THEN
        PERFORM 1 FROM malu$session WHERE session_id = p_session_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'unknown session: %', p_session_id
                USING ERRCODE = 'no_data_found';
        END IF;

        SELECT
            string_agg(
                COALESCE(role, '') || ': ' ||
                COALESCE(content_text, content_jsonb::text),
                E'\n'
                ORDER BY ordinal
            ),
            encode(sha256(string_agg(content_hash, '|' ORDER BY ordinal)::bytea), 'hex'),
            count(*)::integer
        INTO v_context_text, v_context_hash, v_context_count
        FROM malu$session_context
        WHERE session_id = p_session_id;

        v_context_count := COALESCE(v_context_count, 0);
        v_full := v_full || COALESCE(E'\n\n' || v_context_text, '');

        IF v_account_id IS NULL THEN
            SELECT account_id INTO v_account_id
            FROM malu$session WHERE session_id = p_session_id;
        END IF;
    END IF;

    v_prompt_hash := encode(sha256(v_full::bytea), 'hex');

    -- Enforce max_rendered_prompt_chars against the actual rendered text.
    IF v_opts.max_rendered_prompt_chars IS NOT NULL
       AND char_length(v_full) > v_opts.max_rendered_prompt_chars THEN
        IF COALESCE(v_opts.on_truncate, 'error') = 'error' THEN
            RAISE EXCEPTION
              'BIND_RENDER_TOO_LARGE: rendered prompt % chars exceeds cap %',
              char_length(v_full), v_opts.max_rendered_prompt_chars
              USING ERRCODE = 'string_data_right_truncation';
        ELSE
            RAISE NOTICE
              'BIND_TRUNCATE: rendered prompt % chars truncated to %',
              char_length(v_full), v_opts.max_rendered_prompt_chars;
            v_full := left(v_full, v_opts.max_rendered_prompt_chars);
            v_prompt_hash := encode(sha256(v_full::bytea), 'hex');
        END IF;
    END IF;

    v_template_hash := _template_hash(v_template);

    INSERT INTO malu$prompt_render
        (template_id, session_id, account_id, variables,
         rendered_prompt, prompt_hash, context_block_count, context_hash)
    VALUES
        (v_template.template_id, p_session_id, v_account_id,
         COALESCE(p_variables, '{}'::jsonb),
         v_full, v_prompt_hash, v_context_count, v_context_hash)
    RETURNING render_id INTO v_render_id;

    INSERT INTO malu$bound_prompt
        (render_id, template_id, template_hash, account_id, session_id,
         variables_raw, variables_normalized,
         rendered_system, rendered_developer, rendered_user, rendered_full,
         prompt_hash, bind_options, validation_status, validation_warnings,
         estimated_tokens)
    VALUES
        (v_render_id, v_template.template_id, v_template_hash, v_account_id, p_session_id,
         COALESCE(p_variables, '{}'::jsonb), v_normalized,
         v_channels.s_text, v_channels.d_text, v_channels.u_text, v_full,
         v_prompt_hash, v_opts, v_validation.status, v_validation.warnings,
         _estimate_tokens(v_full))
    RETURNING bound_prompt_id INTO v_bound_id;

    v_bound := ROW(
        v_bound_id,
        v_template.template_id,
        v_template.template_name,
        v_template.template_version,
        v_template_hash,
        v_normalized,
        v_channels.s_text,
        v_channels.d_text,
        v_channels.u_text,
        v_full,
        v_prompt_hash,
        v_validation.status,
        _estimate_tokens(v_full)
    )::bound_prompt;
    RETURN v_bound;
END;
$body$;

-- ---------------------------------------------------------------------
-- call: submit a bound prompt against a model alias. Returns the new
-- malu$model_request.request_id.
--
-- The function is named `call` per the R1.1-4 spec. CALL is a reserved
-- statement keyword but PG accepts `call(...)` as a function invocation;
-- the schema-qualified form `maludb_core.call(...)` is unambiguous.
-- ---------------------------------------------------------------------
CREATE FUNCTION call(
    p_bound             bound_prompt,
    p_alias_name        text,
    p_session_id        bigint  DEFAULT NULL,
    p_generation_params jsonb   DEFAULT '{}'::jsonb,
    p_timeout_ms        integer DEFAULT 30000,
    p_account_name      text    DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql
AS $body$
DECLARE
    v_alias_id    bigint;
    v_account_id  bigint;
    v_render_id   bigint;
    v_request_id  bigint;
    v_bound_row   malu$bound_prompt%ROWTYPE;
BEGIN
    IF p_bound.bound_prompt_id IS NULL THEN
        RAISE EXCEPTION 'call: bound_prompt is NULL or unbound'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    SELECT * INTO v_bound_row
    FROM malu$bound_prompt
    WHERE bound_prompt_id = p_bound.bound_prompt_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'call: unknown bound_prompt_id %', p_bound.bound_prompt_id
            USING ERRCODE = 'no_data_found';
    END IF;

    SELECT alias_id INTO v_alias_id
    FROM malu$model_alias
    WHERE alias_name = p_alias_name AND enabled = true;
    IF v_alias_id IS NULL THEN
        RAISE EXCEPTION 'unknown or disabled alias: %', p_alias_name
            USING ERRCODE = 'no_data_found';
    END IF;

    IF p_account_name IS NOT NULL THEN
        SELECT account_id INTO v_account_id
        FROM malu$account WHERE account_name = p_account_name;
        IF v_account_id IS NULL THEN
            RAISE EXCEPTION 'unknown account: %', p_account_name
                USING ERRCODE = 'no_data_found';
        END IF;
    ELSE
        v_account_id := COALESCE(v_bound_row.account_id, current_account_id());
    END IF;

    v_render_id := v_bound_row.render_id;

    INSERT INTO malu$model_request
        (session_id, prompt_render_id, alias_id, account_id,
         rendered_prompt, prompt_hash,
         generation_params, timeout_ms, status)
    VALUES
        (COALESCE(p_session_id, v_bound_row.session_id),
         v_render_id, v_alias_id, v_account_id,
         v_bound_row.rendered_full, v_bound_row.prompt_hash,
         COALESCE(p_generation_params, '{}'::jsonb),
         p_timeout_ms, 'pending')
    RETURNING request_id INTO v_request_id;

    RETURN v_request_id;
END;
$body$;

-- ---------------------------------------------------------------------
-- RLS + grants on malu$bound_prompt. Mirrors the prompt_render policy:
-- NULL account_id = anonymous/shared; otherwise tenant-scoped.
-- ---------------------------------------------------------------------
ALTER TABLE malu$bound_prompt ENABLE ROW LEVEL SECURITY;
CREATE POLICY bound_prompt_tenant
    ON malu$bound_prompt
    USING (account_id IS NULL OR account_id = current_account_id())
    WITH CHECK (account_id IS NULL OR account_id = current_account_id());

GRANT SELECT, INSERT, UPDATE, DELETE ON malu$bound_prompt TO
    maludb_llm_admin,
    maludb_llm_executor;
GRANT SELECT ON malu$bound_prompt TO
    maludb_llm_prompt_author,
    maludb_llm_prompt_approver,
    maludb_llm_model_admin,
    maludb_llm_auditor;
