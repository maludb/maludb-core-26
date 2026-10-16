\echo Use "ALTER EXTENSION maludb_core UPDATE TO '0.7.0'" to load this file. \quit

-- =====================================================================
-- maludb_core 0.6.0 → 0.7.0
--
-- R1.1-6: Prompt approval workflow.
--
-- Adds the draft/approved/deprecated lifecycle to malu$prompt_template,
-- a minimal malu$safety_policy catalog, and promote/deprecate helpers.
-- submit_render and bind_prompt now reject non-'approved' templates;
-- render_prompt and preview_prompt still work (so authors can debug
-- drafts).
--
-- Migration choice (per session 2026-05-12): existing rows default to
-- 'approved' so R1.0 fixtures keep working. New rows also default to
-- 'approved'; operators opt into the draft workflow by setting
-- status='draft' explicitly at INSERT time or via request_review().
-- =====================================================================

CREATE OR REPLACE FUNCTION maludb_core_version() RETURNS text
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$ SELECT '0.7.0'::text $body$;

-- ---------------------------------------------------------------------
-- malu$safety_policy (Tier-A catalog)
--
-- A named, declarative label attached to a prompt template. R1.1-6
-- only stores the label; enforcement (PII redaction, legal review, etc.)
-- is the responsibility of downstream code in later phases. The catalog
-- gives operators a stable surface to attach to prompts now.
-- ---------------------------------------------------------------------
CREATE TABLE malu$safety_policy (
    policy_id     bigserial PRIMARY KEY,
    policy_name   text NOT NULL UNIQUE,
    description   text,
    created_at    timestamptz NOT NULL DEFAULT now()
);

INSERT INTO malu$safety_policy (policy_name, description) VALUES
    ('open',          'No additional safety filtering beyond model defaults.'),
    ('pii_redact',    'Redact personally identifiable information from inputs and outputs.'),
    ('legal_review',  'Outputs require legal review before delivery to external parties.'),
    ('internal_only', 'Outputs may not leave the internal environment.');

GRANT SELECT ON malu$safety_policy TO
    maludb_llm_admin,
    maludb_llm_prompt_author,
    maludb_llm_prompt_approver,
    maludb_llm_model_admin,
    maludb_llm_executor,
    maludb_llm_auditor;
GRANT INSERT, UPDATE, DELETE ON malu$safety_policy TO maludb_llm_admin;

-- ---------------------------------------------------------------------
-- ALTER malu$prompt_template — lifecycle columns
-- ---------------------------------------------------------------------
ALTER TABLE malu$prompt_template
    ADD COLUMN status text NOT NULL DEFAULT 'approved'
        CHECK (status IN ('draft','approved','deprecated')),
    ADD COLUMN safety_policy_id bigint
        REFERENCES malu$safety_policy(policy_id) ON DELETE SET NULL,
    ADD COLUMN approved_at timestamptz,
    ADD COLUMN approved_by_account_id bigint
        REFERENCES malu$account(account_id) ON DELETE SET NULL,
    ADD COLUMN deprecated_at timestamptz,
    ADD COLUMN deprecation_reason text;

-- mark existing rows as approved (the default already does this for the
-- ADD COLUMN, but stamp approved_at so audit views know when the row
-- entered the approved state)
UPDATE malu$prompt_template SET approved_at = now()
WHERE status = 'approved' AND approved_at IS NULL;

CREATE INDEX malu$prompt_template_status_idx
    ON malu$prompt_template (status, template_name);

-- ---------------------------------------------------------------------
-- _resolve_template_for_lifecycle: helper used by all three transition
-- functions. Resolves by name+version (NULL version = latest by
-- template_version), returns the template_id, or raises.
-- ---------------------------------------------------------------------
CREATE FUNCTION _resolve_template_for_lifecycle(
    p_template_name    text,
    p_template_version integer
) RETURNS bigint
LANGUAGE plpgsql
AS $body$
DECLARE
    v_id bigint;
BEGIN
    IF p_template_version IS NULL THEN
        SELECT template_id INTO v_id
        FROM malu$prompt_template
        WHERE template_name = p_template_name
        ORDER BY template_version DESC
        LIMIT 1;
    ELSE
        SELECT template_id INTO v_id
        FROM malu$prompt_template
        WHERE template_name = p_template_name
          AND template_version = p_template_version;
    END IF;
    IF v_id IS NULL THEN
        RAISE EXCEPTION
          'unknown prompt template: % (version %)',
          p_template_name, COALESCE(p_template_version::text, 'latest')
          USING ERRCODE = 'no_data_found';
    END IF;
    RETURN v_id;
END;
$body$;

-- ---------------------------------------------------------------------
-- approve_prompt: draft → approved (or re-affirm approved).
-- Records approver + safety policy. Deprecated rows are NOT promotable
-- here; callers must explicitly rehab via UPDATE.
-- ---------------------------------------------------------------------
CREATE FUNCTION approve_prompt(
    p_template_name    text,
    p_template_version integer DEFAULT NULL,
    p_safety_policy    text    DEFAULT NULL,
    p_approver_account text    DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql
AS $body$
DECLARE
    v_template_id  bigint := _resolve_template_for_lifecycle(p_template_name, p_template_version);
    v_policy_id    bigint;
    v_approver_id  bigint;
    v_current_status text;
BEGIN
    SELECT status INTO v_current_status FROM malu$prompt_template WHERE template_id = v_template_id;
    IF v_current_status = 'deprecated' THEN
        RAISE EXCEPTION
          'PROMPT_LIFECYCLE_INVALID: cannot approve a deprecated template (%); rehab via UPDATE first',
          p_template_name
          USING ERRCODE = 'invalid_parameter_value';
    END IF;

    IF p_safety_policy IS NOT NULL THEN
        SELECT policy_id INTO v_policy_id
        FROM malu$safety_policy WHERE policy_name = p_safety_policy;
        IF v_policy_id IS NULL THEN
            RAISE EXCEPTION 'unknown safety_policy: %', p_safety_policy
                USING ERRCODE = 'no_data_found';
        END IF;
    END IF;

    IF p_approver_account IS NOT NULL THEN
        SELECT account_id INTO v_approver_id
        FROM malu$account WHERE account_name = p_approver_account;
        IF v_approver_id IS NULL THEN
            RAISE EXCEPTION 'unknown account: %', p_approver_account
                USING ERRCODE = 'no_data_found';
        END IF;
    END IF;

    UPDATE malu$prompt_template
       SET status                 = 'approved',
           approved_at            = now(),
           approved_by_account_id = COALESCE(v_approver_id, approved_by_account_id),
           safety_policy_id       = COALESCE(v_policy_id, safety_policy_id),
           deprecated_at          = NULL,
           deprecation_reason     = NULL
     WHERE template_id = v_template_id;

    RETURN v_template_id;
END;
$body$;

-- ---------------------------------------------------------------------
-- deprecate_prompt: approved|draft → deprecated. Optional reason.
-- ---------------------------------------------------------------------
CREATE FUNCTION deprecate_prompt(
    p_template_name    text,
    p_template_version integer DEFAULT NULL,
    p_reason           text    DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql
AS $body$
DECLARE
    v_template_id bigint := _resolve_template_for_lifecycle(p_template_name, p_template_version);
BEGIN
    UPDATE malu$prompt_template
       SET status             = 'deprecated',
           deprecated_at      = now(),
           deprecation_reason = p_reason
     WHERE template_id = v_template_id;
    RETURN v_template_id;
END;
$body$;

-- ---------------------------------------------------------------------
-- request_review: approved → draft. Moves a previously-approved row
-- back to draft for further editing; clears approved_at.
-- Deprecated rows must rehab explicitly via UPDATE.
-- ---------------------------------------------------------------------
CREATE FUNCTION request_review(
    p_template_name    text,
    p_template_version integer DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql
AS $body$
DECLARE
    v_template_id    bigint := _resolve_template_for_lifecycle(p_template_name, p_template_version);
    v_current_status text;
BEGIN
    SELECT status INTO v_current_status FROM malu$prompt_template WHERE template_id = v_template_id;
    IF v_current_status = 'deprecated' THEN
        RAISE EXCEPTION
          'PROMPT_LIFECYCLE_INVALID: cannot request_review on a deprecated template (%)',
          p_template_name
          USING ERRCODE = 'invalid_parameter_value';
    END IF;

    UPDATE malu$prompt_template
       SET status                 = 'draft',
           approved_at            = NULL,
           approved_by_account_id = NULL
     WHERE template_id = v_template_id;

    RETURN v_template_id;
END;
$body$;

-- ---------------------------------------------------------------------
-- Gate: submit_render rejects draft + deprecated templates.
--
-- bind_prompt gets the same gate (see CREATE OR REPLACE below).
-- render_prompt + preview_prompt stay open so authors can debug drafts.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION submit_render(
    p_render_id         bigint,
    p_alias_name        text,
    p_account_name      text DEFAULT NULL,
    p_generation_params jsonb DEFAULT '{}'::jsonb,
    p_timeout_ms        integer DEFAULT 30000
) RETURNS bigint
LANGUAGE plpgsql
AS $body$
DECLARE
    v_render        malu$prompt_render%ROWTYPE;
    v_alias_id      bigint;
    v_account_id    bigint;
    v_request_id    bigint;
    v_template_status text;
BEGIN
    SELECT * INTO v_render
    FROM malu$prompt_render WHERE render_id = p_render_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'unknown render: %', p_render_id
            USING ERRCODE = 'no_data_found';
    END IF;

    SELECT status INTO v_template_status
    FROM malu$prompt_template WHERE template_id = v_render.template_id;
    IF v_template_status <> 'approved' THEN
        RAISE EXCEPTION
          'PROMPT_NOT_APPROVED: render % refers to template (id %) with status %; only approved templates may be submitted',
          p_render_id, v_render.template_id, v_template_status
          USING ERRCODE = 'invalid_parameter_value';
    END IF;

    SELECT alias_id INTO v_alias_id
    FROM malu$model_alias
    WHERE alias_name = p_alias_name AND enabled = true;
    IF v_alias_id IS NULL THEN
        RAISE EXCEPTION 'unknown or disabled alias: %', p_alias_name
            USING ERRCODE = 'foreign_key_violation';
    END IF;

    IF p_account_name IS NOT NULL THEN
        SELECT account_id INTO v_account_id
        FROM malu$account WHERE account_name = p_account_name;
        IF v_account_id IS NULL THEN
            RAISE EXCEPTION 'unknown account: %', p_account_name
                USING ERRCODE = 'foreign_key_violation';
        END IF;
    END IF;

    INSERT INTO malu$model_request
           (alias_id, account_id, session_id, prompt_render_id,
            rendered_prompt, prompt_hash,
            generation_params, timeout_ms)
    VALUES (v_alias_id,
            COALESCE(v_account_id, v_render.account_id),
            v_render.session_id, p_render_id,
            v_render.rendered_prompt, v_render.prompt_hash,
            COALESCE(p_generation_params, '{}'::jsonb), p_timeout_ms)
    RETURNING request_id INTO v_request_id;
    RETURN v_request_id;
END;
$body$;

-- ---------------------------------------------------------------------
-- Gate: bind_prompt rejects draft + deprecated templates.
--
-- The only change vs 0.5.0→0.6.0 is the status check inserted right
-- after the template lookup. The rest of the function is unchanged.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bind_prompt(
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

    IF v_template.status <> 'approved' THEN
        RAISE EXCEPTION
          'PROMPT_NOT_APPROVED: template % (version %) has status %; only approved templates may be bound',
          v_template.template_name, v_template.template_version, v_template.status
          USING ERRCODE = 'invalid_parameter_value';
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
-- Grants: prompt_approver gets EXECUTE on the workflow helpers.
-- prompt_author keeps EXECUTE on request_review (they're the ones who
-- author drafts and request review). deprecate_prompt is open to both
-- author and approver — either can pull a bad prompt out of service.
-- ---------------------------------------------------------------------
GRANT EXECUTE ON FUNCTION approve_prompt(text, integer, text, text) TO
    maludb_llm_admin,
    maludb_llm_prompt_approver;
GRANT EXECUTE ON FUNCTION deprecate_prompt(text, integer, text) TO
    maludb_llm_admin,
    maludb_llm_prompt_approver,
    maludb_llm_prompt_author;
GRANT EXECUTE ON FUNCTION request_review(text, integer) TO
    maludb_llm_admin,
    maludb_llm_prompt_author,
    maludb_llm_prompt_approver;
