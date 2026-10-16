\echo Use "ALTER EXTENSION maludb_core UPDATE TO '0.5.0'" to load this file. \quit

-- =====================================================================
-- maludb_core 0.4.0 → 0.5.0
--
-- R1.1-5: Prompt variable schema + bind options.
--
-- Adds malu$prompt_variable (typed declaration of the variables a
-- prompt template expects) and the malu$bind_options composite that
-- the R1.1-4 bind_prompt() will accept. _validate_bind_variables()
-- centralises the rules so the eventual bind_prompt and the legacy
-- render_prompt path can both reuse them.
--
-- Doctrine (per release-1.0-build-plan.md §13): the new table is
-- ADDITIVE. Existing templates that declare their variables only via
-- the JSONB `variables` column on malu$prompt_template keep working;
-- when malu$prompt_variable rows exist for a template, they become
-- authoritative.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Version bump
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION maludb_core_version() RETURNS text
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$ SELECT '0.5.0'::text $body$;

-- ---------------------------------------------------------------------
-- malu$prompt_variable
--
-- One row per declared variable on a prompt template. PK is
-- (template_id, variable_name) so callers can upsert by name.
-- ---------------------------------------------------------------------
CREATE TABLE malu$prompt_variable (
    template_id     bigint  NOT NULL
        REFERENCES malu$prompt_template(template_id) ON DELETE CASCADE,
    variable_name   text    NOT NULL
        CHECK (variable_name ~ '^[A-Za-z_][A-Za-z0-9_]*$'),
    variable_type   text    NOT NULL DEFAULT 'text'
        CHECK (variable_type IN ('text','integer','number','boolean','json','enum')),
    required        boolean NOT NULL DEFAULT false,
    default_value   text,
    validation_rule text,
    max_length      integer
        CHECK (max_length IS NULL OR max_length > 0),
    enum_values     text[],
    sensitivity     text    NOT NULL DEFAULT 'internal'
        CHECK (sensitivity IN ('public','internal','restricted','prohibited')),
    created_at      timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (template_id, variable_name),
    -- enum_values is only meaningful for the enum type, but only enforce
    -- the positive direction (enum → values required); allow enum_values
    -- to be set on non-enum types for forward-compat with future kinds.
    CHECK (variable_type <> 'enum' OR (enum_values IS NOT NULL AND array_length(enum_values, 1) > 0))
);

COMMENT ON TABLE malu$prompt_variable IS
    'Typed declaration of variables expected by a malu$prompt_template. '
    'Additive over the legacy malu$prompt_template.variables JSONB; when '
    'rows exist for a template here, _validate_bind_variables treats them '
    'as authoritative.';

-- ---------------------------------------------------------------------
-- malu$bind_options
--
-- Composite-typed bag of bind-time policy knobs. _default_bind_options()
-- returns the production-safe default posture. Callers can override
-- individual fields by SELECTing the default and rewriting the columns
-- they care about.
-- ---------------------------------------------------------------------
CREATE TYPE malu$bind_options AS (
    strict                      boolean,
    on_missing_variable         text,   -- 'error' | 'blank' | 'preserve'
    on_extra_variable           text,   -- 'ignore' | 'warn'  | 'error'
    null_handling               text,   -- 'null_literal' | 'empty' | 'error'
    max_variable_chars          integer,
    max_rendered_prompt_chars   integer,
    on_truncate                 text,   -- 'error' | 'truncate_with_notice'
    escape_mode                 text    -- 'none' | 'json' | 'sql_literal'
);

CREATE FUNCTION _default_bind_options() RETURNS malu$bind_options
LANGUAGE sql IMMUTABLE PARALLEL SAFE
AS $body$
    SELECT ROW(
        true,           -- strict
        'error',        -- on_missing_variable
        'warn',         -- on_extra_variable
        'null_literal', -- null_handling
        NULL::integer,  -- max_variable_chars
        NULL::integer,  -- max_rendered_prompt_chars
        'error',        -- on_truncate
        'none'          -- escape_mode
    )::malu$bind_options;
$body$;

-- ---------------------------------------------------------------------
-- malu$bind_validation
--
-- Result of _validate_bind_variables(). status is 'ok' when no warnings
-- were emitted and 'warned' otherwise. Errors raise; the validator
-- never returns status='error'.
-- ---------------------------------------------------------------------
CREATE TYPE malu$bind_validation AS (
    status                 text,
    normalized_variables   jsonb,
    declared_count         integer,
    supplied_count         integer,
    warnings               text[]
);

-- ---------------------------------------------------------------------
-- _coerce_variable: cast a raw JSONB value to the declared variable
-- type, applying max_length / enum constraints. Returns the coerced
-- value as TEXT (the rendering path is text-based) plus a boolean
-- indicating whether the input was NULL.
-- ---------------------------------------------------------------------
CREATE FUNCTION _coerce_variable(
    p_var       malu$prompt_variable,
    p_raw       jsonb,
    p_opts      malu$bind_options,
    OUT v_text  text,
    OUT v_null  boolean
)
LANGUAGE plpgsql IMMUTABLE
AS $body$
DECLARE
    v_max int;
BEGIN
    v_null := (p_raw IS NULL OR jsonb_typeof(p_raw) = 'null');
    IF v_null THEN
        v_text := NULL;
        RETURN;
    END IF;

    CASE p_var.variable_type
        WHEN 'text' THEN
            IF jsonb_typeof(p_raw) = 'string' THEN
                v_text := p_raw #>> '{}';
            ELSE
                v_text := p_raw::text;
            END IF;
        WHEN 'integer' THEN
            IF jsonb_typeof(p_raw) NOT IN ('number','string') THEN
                RAISE EXCEPTION
                  'BIND_TYPE_MISMATCH: variable % expects integer, got %',
                  p_var.variable_name, jsonb_typeof(p_raw)
                  USING ERRCODE = 'invalid_parameter_value';
            END IF;
            v_text := (p_raw #>> '{}')::bigint::text;
        WHEN 'number' THEN
            IF jsonb_typeof(p_raw) NOT IN ('number','string') THEN
                RAISE EXCEPTION
                  'BIND_TYPE_MISMATCH: variable % expects number, got %',
                  p_var.variable_name, jsonb_typeof(p_raw)
                  USING ERRCODE = 'invalid_parameter_value';
            END IF;
            v_text := (p_raw #>> '{}')::numeric::text;
        WHEN 'boolean' THEN
            IF jsonb_typeof(p_raw) NOT IN ('boolean','string') THEN
                RAISE EXCEPTION
                  'BIND_TYPE_MISMATCH: variable % expects boolean, got %',
                  p_var.variable_name, jsonb_typeof(p_raw)
                  USING ERRCODE = 'invalid_parameter_value';
            END IF;
            v_text := (p_raw #>> '{}')::boolean::text;
        WHEN 'json' THEN
            v_text := p_raw::text;
        WHEN 'enum' THEN
            IF jsonb_typeof(p_raw) <> 'string' THEN
                RAISE EXCEPTION
                  'BIND_TYPE_MISMATCH: variable % (enum) expects string, got %',
                  p_var.variable_name, jsonb_typeof(p_raw)
                  USING ERRCODE = 'invalid_parameter_value';
            END IF;
            v_text := p_raw #>> '{}';
            IF v_text <> ALL (p_var.enum_values) THEN
                RAISE EXCEPTION
                  'BIND_ENUM_VIOLATION: variable %=% not in allowed set %',
                  p_var.variable_name, v_text, p_var.enum_values
                  USING ERRCODE = 'invalid_parameter_value';
            END IF;
    END CASE;

    -- max_length applies to the rendered string form. per-var declared
    -- max wins over the global cap when both are set.
    v_max := COALESCE(p_var.max_length, p_opts.max_variable_chars);
    IF v_max IS NOT NULL AND char_length(v_text) > v_max THEN
        IF COALESCE(p_opts.on_truncate, 'error') = 'truncate_with_notice' THEN
            RAISE NOTICE
              'BIND_TRUNCATE: variable % length %, truncated to %',
              p_var.variable_name, char_length(v_text), v_max;
            v_text := left(v_text, v_max);
        ELSE
            RAISE EXCEPTION
              'BIND_LENGTH_VIOLATION: variable % length % exceeds limit %',
              p_var.variable_name, char_length(v_text), v_max
              USING ERRCODE = 'string_data_right_truncation';
        END IF;
    END IF;

    -- validation_rule is a regex check for text/enum, opaque otherwise.
    IF p_var.validation_rule IS NOT NULL
       AND p_var.variable_type IN ('text','enum')
       AND v_text !~ p_var.validation_rule THEN
        RAISE EXCEPTION
          'BIND_VALIDATION_FAILED: variable %=% does not match rule %',
          p_var.variable_name, v_text, p_var.validation_rule
          USING ERRCODE = 'check_violation';
    END IF;
END;
$body$;

-- ---------------------------------------------------------------------
-- _escape_for: text-rendering escape, applied by the bind path before
-- substitution. The legacy render_prompt() does NOT call this (it
-- keeps its raw substitution semantics for backward compat); R1.1-4
-- bind_prompt() will.
-- ---------------------------------------------------------------------
CREATE FUNCTION _escape_for(p_value text, p_mode text) RETURNS text
LANGUAGE sql IMMUTABLE PARALLEL SAFE
AS $body$
    SELECT CASE COALESCE(p_mode, 'none')
        WHEN 'none'        THEN p_value
        WHEN 'json'        THEN trim(both '"' FROM to_jsonb(p_value)::text)
        WHEN 'sql_literal' THEN replace(p_value, '''', '''''')
        ELSE p_value
    END;
$body$;

-- ---------------------------------------------------------------------
-- _validate_bind_variables
--
-- Centralised validator. Resolves the variable schema for the template
-- (preferring malu$prompt_variable rows; falling back to the JSONB
-- column on malu$prompt_template), applies the bind options, and
-- returns the normalized variables JSONB along with metadata.
--
-- Schema sources, in order of authority:
--   1. malu$prompt_variable rows for the template (typed)
--   2. malu$prompt_template.variables JSONB keys (loose, type=text,
--      required=false, no default)
--   3. empty (template declares nothing, free-form binding)
--
-- Raises on hard errors:
--   - required variable missing + on_missing_variable='error'
--   - extra variable supplied + on_extra_variable='error'
--   - null + null_handling='error'
--   - per-variable type/length/enum/regex failure (always raises)
--   - rendered output projected to exceed max_rendered_prompt_chars
--     with on_truncate='error'
--
-- Returns the normalized variables (after coercion + escaping) so the
-- caller can pass them through to the rendering path without re-doing
-- the work.
-- ---------------------------------------------------------------------
CREATE FUNCTION _validate_bind_variables(
    p_template_id bigint,
    p_variables   jsonb,
    p_opts        malu$bind_options
) RETURNS malu$bind_validation
LANGUAGE plpgsql
AS $body$
DECLARE
    v_opts        malu$bind_options := COALESCE(p_opts, _default_bind_options());
    v_vars        jsonb             := COALESCE(p_variables, '{}'::jsonb);
    v_declared    jsonb;
    v_normalized  jsonb := '{}'::jsonb;
    v_warnings    text[] := ARRAY[]::text[];
    v_status      text   := 'ok';
    v_declared_n  integer := 0;
    v_supplied_n  integer;
    v_var         malu$prompt_variable;
    v_supplied    jsonb;
    v_coerced     record;
    v_used_typed  boolean := false;
    v_legacy_keys text[];
    v_extra_keys  text[];
    v_msg         text;
BEGIN
    IF jsonb_typeof(v_vars) <> 'object' THEN
        RAISE EXCEPTION
          'BIND_BAD_INPUT: variables must be a JSON object, got %',
          jsonb_typeof(v_vars)
          USING ERRCODE = 'invalid_parameter_value';
    END IF;

    v_supplied_n := (SELECT count(*)::integer FROM jsonb_object_keys(v_vars));

    -- Pull typed declarations. If any exist for this template, they
    -- become authoritative; the JSONB fallback is ignored.
    SELECT count(*) INTO v_declared_n
    FROM malu$prompt_variable WHERE template_id = p_template_id;
    v_used_typed := v_declared_n > 0;

    IF v_used_typed THEN
        FOR v_var IN
            SELECT * FROM malu$prompt_variable
            WHERE template_id = p_template_id
            ORDER BY variable_name
        LOOP
            v_supplied := v_vars -> v_var.variable_name;

            IF v_supplied IS NULL THEN
                -- not supplied: default or missing
                IF v_var.default_value IS NOT NULL THEN
                    v_normalized := v_normalized
                        || jsonb_build_object(v_var.variable_name,
                            _escape_for(v_var.default_value, v_opts.escape_mode));
                    CONTINUE;
                END IF;
                IF v_var.required THEN
                    CASE COALESCE(v_opts.on_missing_variable, 'error')
                        WHEN 'error' THEN
                            RAISE EXCEPTION
                              'BIND_REQUIRED_MISSING: variable % not supplied',
                              v_var.variable_name
                              USING ERRCODE = 'not_null_violation';
                        WHEN 'blank' THEN
                            v_normalized := v_normalized
                                || jsonb_build_object(v_var.variable_name, '');
                        WHEN 'preserve' THEN
                            -- leave the {{name}}/:name token in place
                            NULL;
                        ELSE
                            RAISE EXCEPTION
                              'BIND_BAD_OPTION: on_missing_variable=%',
                              v_opts.on_missing_variable
                              USING ERRCODE = 'invalid_parameter_value';
                    END CASE;
                END IF;
                CONTINUE;
            END IF;

            -- supplied: coerce + length-check
            v_coerced := _coerce_variable(v_var, v_supplied, v_opts);

            IF v_coerced.v_null THEN
                CASE COALESCE(v_opts.null_handling, 'null_literal')
                    WHEN 'null_literal' THEN
                        v_normalized := v_normalized
                            || jsonb_build_object(v_var.variable_name, 'null');
                    WHEN 'empty' THEN
                        v_normalized := v_normalized
                            || jsonb_build_object(v_var.variable_name, '');
                    WHEN 'error' THEN
                        RAISE EXCEPTION
                          'BIND_NULL_REJECTED: variable % was null',
                          v_var.variable_name
                          USING ERRCODE = 'null_value_not_allowed';
                    ELSE
                        RAISE EXCEPTION
                          'BIND_BAD_OPTION: null_handling=%',
                          v_opts.null_handling
                          USING ERRCODE = 'invalid_parameter_value';
                END CASE;
            ELSE
                v_normalized := v_normalized
                    || jsonb_build_object(
                        v_var.variable_name,
                        _escape_for(v_coerced.v_text, v_opts.escape_mode));
            END IF;
        END LOOP;

        -- detect extras: keys in v_vars not declared
        SELECT array_agg(k ORDER BY k) INTO v_extra_keys
        FROM jsonb_object_keys(v_vars) k
        WHERE k NOT IN (
            SELECT variable_name FROM malu$prompt_variable
            WHERE template_id = p_template_id
        );

    ELSE
        -- Legacy JSONB path: variable keys declared on the template
        -- itself, no type info. Accept all of them as text.
        SELECT array_agg(k ORDER BY k) INTO v_legacy_keys
        FROM jsonb_object_keys(
            COALESCE(
                (SELECT variables FROM malu$prompt_template
                 WHERE template_id = p_template_id),
                '{}'::jsonb)
        ) k;
        v_declared_n := COALESCE(array_length(v_legacy_keys, 1), 0);

        -- carry every supplied var through, escaped, with NULL handling
        FOR v_msg IN SELECT k FROM jsonb_object_keys(v_vars) k LOOP
            v_supplied := v_vars -> v_msg;
            IF v_supplied IS NULL OR jsonb_typeof(v_supplied) = 'null' THEN
                CASE COALESCE(v_opts.null_handling, 'null_literal')
                    WHEN 'null_literal' THEN
                        v_normalized := v_normalized
                            || jsonb_build_object(v_msg, 'null');
                    WHEN 'empty' THEN
                        v_normalized := v_normalized
                            || jsonb_build_object(v_msg, '');
                    WHEN 'error' THEN
                        RAISE EXCEPTION
                          'BIND_NULL_REJECTED: variable % was null', v_msg
                          USING ERRCODE = 'null_value_not_allowed';
                END CASE;
                CONTINUE;
            END IF;
            v_normalized := v_normalized
                || jsonb_build_object(
                    v_msg,
                    _escape_for(
                        CASE WHEN jsonb_typeof(v_supplied) = 'string'
                             THEN v_supplied #>> '{}'
                             ELSE v_supplied::text
                        END,
                        v_opts.escape_mode));
        END LOOP;

        IF v_legacy_keys IS NOT NULL THEN
            SELECT array_agg(k ORDER BY k) INTO v_extra_keys
            FROM jsonb_object_keys(v_vars) k
            WHERE k <> ALL(v_legacy_keys);
        END IF;
    END IF;

    -- Handle extra-variable policy. Empty array -> NULL via the SELECT
    -- above; normalise here for branching.
    IF v_extra_keys IS NOT NULL AND array_length(v_extra_keys, 1) > 0 THEN
        CASE COALESCE(v_opts.on_extra_variable, 'warn')
            WHEN 'error' THEN
                RAISE EXCEPTION
                  'BIND_UNDECLARED_VARIABLES: %', v_extra_keys
                  USING ERRCODE = 'invalid_parameter_value';
            WHEN 'warn' THEN
                v_warnings := v_warnings ||
                    format('undeclared variables: %s', v_extra_keys);
                v_status := 'warned';
                RAISE NOTICE 'BIND_UNDECLARED_VARIABLES: %', v_extra_keys;
                -- still carry them through (typed path drops; legacy path keeps)
                IF v_used_typed THEN
                    -- already dropped (not in the typed loop above)
                    NULL;
                END IF;
            WHEN 'ignore' THEN
                -- drop in typed mode; keep in legacy mode (no-op)
                IF v_used_typed THEN
                    NULL;
                END IF;
            ELSE
                RAISE EXCEPTION
                  'BIND_BAD_OPTION: on_extra_variable=%',
                  v_opts.on_extra_variable
                  USING ERRCODE = 'invalid_parameter_value';
        END CASE;
    END IF;

    -- Project a worst-case rendered length cap. Without the template
    -- text in hand we can only cap the sum of variable values; the
    -- bind path (R1.1-4) re-checks the actual rendered text against
    -- max_rendered_prompt_chars.
    IF v_opts.max_rendered_prompt_chars IS NOT NULL THEN
        DECLARE
            v_total int := 0;
            v_k     text;
        BEGIN
            FOR v_k IN SELECT k FROM jsonb_object_keys(v_normalized) k LOOP
                v_total := v_total + char_length(v_normalized #>> ARRAY[v_k]);
            END LOOP;
            IF v_total > v_opts.max_rendered_prompt_chars THEN
                IF COALESCE(v_opts.on_truncate, 'error') = 'error' THEN
                    RAISE EXCEPTION
                      'BIND_RENDER_TOO_LARGE: variables sum % chars exceeds cap %',
                      v_total, v_opts.max_rendered_prompt_chars
                      USING ERRCODE = 'string_data_right_truncation';
                ELSE
                    v_warnings := v_warnings ||
                        format('variables sum %s chars (cap %s); bind path will truncate',
                               v_total, v_opts.max_rendered_prompt_chars);
                    v_status := 'warned';
                END IF;
            END IF;
        END;
    END IF;

    RETURN ROW(v_status, v_normalized, v_declared_n, v_supplied_n, v_warnings)::malu$bind_validation;
END;
$body$;

-- ---------------------------------------------------------------------
-- declare_prompt_variable: convenience writer for malu$prompt_variable.
-- Upserts by (template_id, variable_name). Resolves the template by
-- name+version, current latest version when version is NULL.
-- ---------------------------------------------------------------------
CREATE FUNCTION declare_prompt_variable(
    p_template_name    text,
    p_variable_name    text,
    p_variable_type    text    DEFAULT 'text',
    p_required         boolean DEFAULT false,
    p_default_value    text    DEFAULT NULL,
    p_validation_rule  text    DEFAULT NULL,
    p_max_length       integer DEFAULT NULL,
    p_enum_values      text[]  DEFAULT NULL,
    p_sensitivity      text    DEFAULT 'internal',
    p_template_version integer DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql
AS $body$
DECLARE
    v_template_id bigint;
BEGIN
    IF p_template_version IS NULL THEN
        SELECT template_id INTO v_template_id
        FROM malu$prompt_template
        WHERE template_name = p_template_name AND enabled = true
        ORDER BY template_version DESC
        LIMIT 1;
    ELSE
        SELECT template_id INTO v_template_id
        FROM malu$prompt_template
        WHERE template_name = p_template_name
          AND template_version = p_template_version;
    END IF;
    IF v_template_id IS NULL THEN
        RAISE EXCEPTION
          'unknown prompt template: % (version %)',
          p_template_name, COALESCE(p_template_version::text, 'latest')
          USING ERRCODE = 'no_data_found';
    END IF;

    INSERT INTO malu$prompt_variable AS pv (
        template_id, variable_name, variable_type, required,
        default_value, validation_rule, max_length, enum_values, sensitivity)
    VALUES (
        v_template_id, p_variable_name, p_variable_type, p_required,
        p_default_value, p_validation_rule, p_max_length, p_enum_values,
        p_sensitivity)
    ON CONFLICT (template_id, variable_name) DO UPDATE
        SET variable_type   = EXCLUDED.variable_type,
            required        = EXCLUDED.required,
            default_value   = EXCLUDED.default_value,
            validation_rule = EXCLUDED.validation_rule,
            max_length      = EXCLUDED.max_length,
            enum_values     = EXCLUDED.enum_values,
            sensitivity     = EXCLUDED.sensitivity;
    RETURN v_template_id;
END;
$body$;

-- ---------------------------------------------------------------------
-- RLS + grants, mirroring the R1.1-7 pattern on malu$prompt_template.
-- ---------------------------------------------------------------------
ALTER TABLE malu$prompt_variable ENABLE ROW LEVEL SECURITY;
CREATE POLICY prompt_variable_via_template
    ON malu$prompt_variable
    USING (
        EXISTS (
            SELECT 1 FROM malu$prompt_template pt
            WHERE pt.template_id = malu$prompt_variable.template_id
              AND (pt.owner_account_id IS NULL
                   OR pt.owner_account_id = current_account_id())
        )
    )
    WITH CHECK (
        EXISTS (
            SELECT 1 FROM malu$prompt_template pt
            WHERE pt.template_id = malu$prompt_variable.template_id
              AND (pt.owner_account_id IS NULL
                   OR pt.owner_account_id = current_account_id())
        )
    );

GRANT SELECT, INSERT, UPDATE, DELETE ON malu$prompt_variable TO
    maludb_llm_admin,
    maludb_llm_prompt_author;
GRANT SELECT ON malu$prompt_variable TO
    maludb_llm_prompt_approver,
    maludb_llm_model_admin,
    maludb_llm_executor,
    maludb_llm_auditor;
