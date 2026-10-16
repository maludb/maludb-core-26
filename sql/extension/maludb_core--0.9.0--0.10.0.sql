\echo Use "ALTER EXTENSION maludb_core UPDATE TO '0.10.0'" to load this file. \quit

-- =====================================================================
-- maludb_core 0.9.0 → 0.10.0
--
-- R1.1-10: Idempotency + retry framework.
--
-- Adds:
--   * malu$model_request.idempotency_key (Stripe-style; second submit
--     with same key returns the prior request_id, regardless of its
--     status)
--   * malu$retry_policy (per-provider backoff metadata; the
--     maludb_modeld daemon consumes this in a follow-up phase)
--   * malu$model_request.attempt_count + last_retry_error (counters
--     bumped by the daemon when it retries)
--   * submit_render / call gain p_idempotency_key
--
-- Idempotency key scope is per-account (matches cache scope choice
-- from R1.1-8 / 2026-05-12 decisions). UNIQUE partial index on
-- (account_id, idempotency_key) WHERE idempotency_key IS NOT NULL.
--
-- Retry policy storage only; the daemon's retry executor is the
-- consumer and is not part of this phase. get_retry_policy(provider)
-- returns the provider-specific policy when present, else the row
-- with provider_id IS NULL (the "default" row).
-- =====================================================================

CREATE OR REPLACE FUNCTION maludb_core_version() RETURNS text
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$ SELECT '0.10.0'::text $body$;

-- ---------------------------------------------------------------------
-- Schema additions on malu$model_request
-- ---------------------------------------------------------------------
ALTER TABLE malu$model_request
    ADD COLUMN idempotency_key text,
    ADD COLUMN attempt_count   integer NOT NULL DEFAULT 1
        CHECK (attempt_count >= 1),
    ADD COLUMN last_retry_error text;

CREATE UNIQUE INDEX malu$model_request_idempotency_idx
    ON malu$model_request (account_id, idempotency_key)
    WHERE idempotency_key IS NOT NULL;

-- ---------------------------------------------------------------------
-- malu$retry_policy
--
-- One row per provider plus an optional "default" row (provider_id
-- IS NULL) that applies when no provider-specific policy exists.
-- ---------------------------------------------------------------------
CREATE TABLE malu$retry_policy (
    policy_id           bigserial PRIMARY KEY,
    provider_id         bigint
        REFERENCES malu$model_provider(provider_id) ON DELETE CASCADE,
    max_attempts        integer NOT NULL DEFAULT 3
        CHECK (max_attempts >= 1 AND max_attempts <= 10),
    backoff_initial_ms  integer NOT NULL DEFAULT 1000
        CHECK (backoff_initial_ms >= 0),
    backoff_multiplier  numeric(4,2) NOT NULL DEFAULT 2.0
        CHECK (backoff_multiplier >= 1.0),
    max_backoff_ms      integer NOT NULL DEFAULT 60000
        CHECK (max_backoff_ms >= 0),
    retry_on            text[] NOT NULL DEFAULT ARRAY['timeout','rate_limit','transient'],
    enabled             boolean NOT NULL DEFAULT true,
    created_at          timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX malu$retry_policy_provider_idx
    ON malu$retry_policy (COALESCE(provider_id, 0));

INSERT INTO malu$retry_policy (provider_id, max_attempts, backoff_initial_ms,
                               backoff_multiplier, max_backoff_ms, retry_on)
VALUES (NULL, 3, 1000, 2.0, 60000,
        ARRAY['timeout','rate_limit','transient']);

GRANT SELECT ON malu$retry_policy TO
    maludb_llm_admin,
    maludb_llm_prompt_author,
    maludb_llm_prompt_approver,
    maludb_llm_model_admin,
    maludb_llm_executor,
    maludb_llm_auditor;
GRANT INSERT, UPDATE, DELETE ON malu$retry_policy TO
    maludb_llm_admin,
    maludb_llm_model_admin;

-- ---------------------------------------------------------------------
-- get_retry_policy: return the policy for a provider, falling back to
-- the default row when no provider-specific policy is configured.
-- ---------------------------------------------------------------------
CREATE FUNCTION get_retry_policy(p_provider_id bigint) RETURNS malu$retry_policy
LANGUAGE sql STABLE
AS $body$
    SELECT *
    FROM malu$retry_policy
    WHERE enabled = true
      AND (provider_id = p_provider_id OR provider_id IS NULL)
    ORDER BY (provider_id IS NULL) ASC  -- prefer specific, fall back to default
    LIMIT 1;
$body$;

-- ---------------------------------------------------------------------
-- _lookup_idempotent_request: returns existing request_id when the
-- (account_id, idempotency_key) pair already exists. NULL otherwise.
-- ---------------------------------------------------------------------
CREATE FUNCTION _lookup_idempotent_request(
    p_account_id      bigint,
    p_idempotency_key text
) RETURNS bigint
LANGUAGE sql STABLE
AS $body$
    SELECT request_id
    FROM malu$model_request
    WHERE idempotency_key = p_idempotency_key
      AND (account_id = p_account_id
           OR (account_id IS NULL AND p_account_id IS NULL))
    ORDER BY submitted_at ASC
    LIMIT 1;
$body$;

-- ---------------------------------------------------------------------
-- submit_render (idempotency-aware)
--
-- Adds p_idempotency_key. When set, the function first looks for a
-- prior request with the same (account, key). If found, returns that
-- request_id without creating a new row — Stripe-style idempotency.
-- The cache lookup runs only when no idempotent match exists.
-- ---------------------------------------------------------------------
DROP FUNCTION submit_render(bigint, text, text, jsonb, integer, text);

CREATE FUNCTION submit_render(
    p_render_id         bigint,
    p_alias_name        text,
    p_account_name      text    DEFAULT NULL,
    p_generation_params jsonb   DEFAULT '{}'::jsonb,
    p_timeout_ms        integer DEFAULT 30000,
    p_cache_mode        text    DEFAULT 'off',
    p_idempotency_key   text    DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql
AS $body$
DECLARE
    v_render          malu$prompt_render%ROWTYPE;
    v_alias_id        bigint;
    v_account_id      bigint;
    v_request_id      bigint;
    v_template_status text;
    v_cache_key       text;
    v_orig_request_id bigint;
    v_existing        bigint;
BEGIN
    IF p_cache_mode NOT IN ('off','prefer','required','refresh') THEN
        RAISE EXCEPTION 'CACHE_BAD_MODE: %', p_cache_mode
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

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
    v_account_id := COALESCE(v_account_id, v_render.account_id);

    -- Idempotency wins over cache: if a prior request with the same
    -- (account, key) exists, return it.
    IF p_idempotency_key IS NOT NULL THEN
        v_existing := _lookup_idempotent_request(v_account_id, p_idempotency_key);
        IF v_existing IS NOT NULL THEN
            RETURN v_existing;
        END IF;
    END IF;

    IF p_cache_mode <> 'off' THEN
        v_cache_key := _compute_cache_key(
            v_account_id, v_render.template_id, v_alias_id,
            v_render.prompt_hash, COALESCE(p_generation_params, '{}'::jsonb));
    END IF;

    IF p_cache_mode IN ('prefer','required') THEN
        v_orig_request_id := _lookup_cache(v_cache_key);
        IF v_orig_request_id IS NULL AND p_cache_mode = 'required' THEN
            RAISE EXCEPTION
              'CACHE_MISS_REQUIRED: no cached response for key % (template=%, alias=%)',
              v_cache_key, v_render.template_id, v_alias_id
              USING ERRCODE = 'no_data_found';
        END IF;
    END IF;

    INSERT INTO malu$model_request
           (alias_id, account_id, session_id, prompt_render_id,
            rendered_prompt, prompt_hash,
            generation_params, timeout_ms,
            cache_key, cache_mode,
            idempotency_key,
            status)
    VALUES (v_alias_id,
            v_account_id,
            v_render.session_id, p_render_id,
            v_render.rendered_prompt, v_render.prompt_hash,
            COALESCE(p_generation_params, '{}'::jsonb), p_timeout_ms,
            v_cache_key, p_cache_mode,
            p_idempotency_key,
            'pending')
    RETURNING request_id INTO v_request_id;

    IF v_orig_request_id IS NOT NULL THEN
        PERFORM _apply_cache_hit(v_request_id, v_orig_request_id);
    END IF;

    RETURN v_request_id;
END;
$body$;

-- ---------------------------------------------------------------------
-- call (idempotency-aware) — bound_prompt path
-- ---------------------------------------------------------------------
DROP FUNCTION call(bound_prompt, text, bigint, jsonb, integer, text, text);

CREATE FUNCTION call(
    p_bound             bound_prompt,
    p_alias_name        text,
    p_session_id        bigint  DEFAULT NULL,
    p_generation_params jsonb   DEFAULT '{}'::jsonb,
    p_timeout_ms        integer DEFAULT 30000,
    p_account_name      text    DEFAULT NULL,
    p_cache_mode        text    DEFAULT 'off',
    p_idempotency_key   text    DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql
AS $body$
DECLARE
    v_alias_id        bigint;
    v_account_id      bigint;
    v_request_id      bigint;
    v_bound_row       malu$bound_prompt%ROWTYPE;
    v_cache_key       text;
    v_orig_request_id bigint;
    v_existing        bigint;
BEGIN
    IF p_cache_mode NOT IN ('off','prefer','required','refresh') THEN
        RAISE EXCEPTION 'CACHE_BAD_MODE: %', p_cache_mode
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

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

    IF p_idempotency_key IS NOT NULL THEN
        v_existing := _lookup_idempotent_request(v_account_id, p_idempotency_key);
        IF v_existing IS NOT NULL THEN
            RETURN v_existing;
        END IF;
    END IF;

    IF p_cache_mode <> 'off' THEN
        v_cache_key := _compute_cache_key(
            v_account_id, v_bound_row.template_id, v_alias_id,
            v_bound_row.prompt_hash, COALESCE(p_generation_params, '{}'::jsonb));
    END IF;

    IF p_cache_mode IN ('prefer','required') THEN
        v_orig_request_id := _lookup_cache(v_cache_key);
        IF v_orig_request_id IS NULL AND p_cache_mode = 'required' THEN
            RAISE EXCEPTION
              'CACHE_MISS_REQUIRED: no cached response for key % (template=%, alias=%)',
              v_cache_key, v_bound_row.template_id, v_alias_id
              USING ERRCODE = 'no_data_found';
        END IF;
    END IF;

    INSERT INTO malu$model_request
        (session_id, prompt_render_id, alias_id, account_id,
         rendered_prompt, prompt_hash,
         generation_params, timeout_ms,
         cache_key, cache_mode,
         idempotency_key,
         status)
    VALUES
        (COALESCE(p_session_id, v_bound_row.session_id),
         v_bound_row.render_id, v_alias_id, v_account_id,
         v_bound_row.rendered_full, v_bound_row.prompt_hash,
         COALESCE(p_generation_params, '{}'::jsonb),
         p_timeout_ms,
         v_cache_key, p_cache_mode,
         p_idempotency_key,
         'pending')
    RETURNING request_id INTO v_request_id;

    IF v_orig_request_id IS NOT NULL THEN
        PERFORM _apply_cache_hit(v_request_id, v_orig_request_id);
    END IF;

    RETURN v_request_id;
END;
$body$;

GRANT EXECUTE ON FUNCTION get_retry_policy(bigint),
                          _lookup_idempotent_request(bigint, text)
TO maludb_llm_admin,
   maludb_llm_prompt_author,
   maludb_llm_prompt_approver,
   maludb_llm_model_admin,
   maludb_llm_executor,
   maludb_llm_auditor;
