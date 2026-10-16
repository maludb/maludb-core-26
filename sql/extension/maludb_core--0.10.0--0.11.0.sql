\echo Use "ALTER EXTENSION maludb_core UPDATE TO '0.11.0'" to load this file. \quit

-- =====================================================================
-- maludb_core 0.10.0 → 0.11.0
--
-- R1.1-9: Budget + quota + token accounting.
--
-- Adds:
--   * pricing columns on malu$model_alias (micro-cents per token, USD)
--   * response_cost() rewired to compute real numbers (NULL when token
--     counts or pricing aren't set; 0 for cache hits)
--   * malu$budget_policy table: scope IN (account, prompt, role, global)
--     × kind IN (tokens_daily, cost_daily, requests_daily)
--   * check_budget() raises BUDGET_EXCEEDED at submit time (hard-reject,
--     per 2026-05-12 decision)
--   * usage_today() helper for operators
--   * cost_by_account view for daily roll-ups
--
-- Currency: signed integer micro-cents (10^-6 USD) per the 2026-05-12
-- decision. Single implied currency for v1; multi-currency is a
-- follow-up.
-- =====================================================================

CREATE OR REPLACE FUNCTION maludb_core_version() RETURNS text
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$ SELECT '0.11.0'::text $body$;

-- ---------------------------------------------------------------------
-- Pricing columns on malu$model_alias
-- ---------------------------------------------------------------------
ALTER TABLE malu$model_alias
    ADD COLUMN price_per_input_token  bigint NOT NULL DEFAULT 0
        CHECK (price_per_input_token >= 0),
    ADD COLUMN price_per_output_token bigint NOT NULL DEFAULT 0
        CHECK (price_per_output_token >= 0);

COMMENT ON COLUMN malu$model_alias.price_per_input_token  IS
    'Input-token price in micro-cents (10^-6 USD). 0 = unpriced (response_cost will return 0 for input).';
COMMENT ON COLUMN malu$model_alias.price_per_output_token IS
    'Output-token price in micro-cents (10^-6 USD). 0 = unpriced.';

-- ---------------------------------------------------------------------
-- malu$budget_policy
--
-- Exactly one of scope_role / scope_template_id / scope_account_id is
-- non-NULL (or all NULL for scope='global'). Enforced via CHECK.
-- ---------------------------------------------------------------------
CREATE TABLE malu$budget_policy (
    policy_id          bigserial PRIMARY KEY,
    policy_name        text NOT NULL UNIQUE,
    scope              text NOT NULL
        CHECK (scope IN ('account','prompt','role','global')),
    scope_account_id   bigint REFERENCES malu$account(account_id) ON DELETE CASCADE,
    scope_template_id  bigint REFERENCES malu$prompt_template(template_id) ON DELETE CASCADE,
    scope_role         text,
    limit_kind         text NOT NULL
        CHECK (limit_kind IN ('tokens_daily','cost_daily','requests_daily')),
    limit_value        bigint NOT NULL CHECK (limit_value > 0),
    enabled            boolean NOT NULL DEFAULT true,
    created_at         timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT malu$budget_policy_scope_one_of CHECK (
        CASE scope
            WHEN 'account' THEN scope_account_id IS NOT NULL AND scope_template_id IS NULL AND scope_role IS NULL
            WHEN 'prompt'  THEN scope_template_id IS NOT NULL AND scope_account_id IS NULL AND scope_role IS NULL
            WHEN 'role'    THEN scope_role IS NOT NULL AND scope_account_id IS NULL AND scope_template_id IS NULL
            WHEN 'global'  THEN scope_account_id IS NULL AND scope_template_id IS NULL AND scope_role IS NULL
        END
    )
);

CREATE INDEX malu$budget_policy_lookup_idx
    ON malu$budget_policy (scope, enabled);

GRANT SELECT ON malu$budget_policy TO
    maludb_llm_admin,
    maludb_llm_prompt_author,
    maludb_llm_prompt_approver,
    maludb_llm_model_admin,
    maludb_llm_executor,
    maludb_llm_auditor;
GRANT INSERT, UPDATE, DELETE ON malu$budget_policy TO
    maludb_llm_admin;

-- ---------------------------------------------------------------------
-- response_cost: rewired to compute from tokens × per-alias pricing.
--
--  * cache_hit row → 0 (the original is what got charged)
--  * NULL prompt_tokens or completion_tokens → NULL (don't lie)
--  * any other case → prompt*input_price + completion*output_price,
--    expressed in micro-cents
-- ---------------------------------------------------------------------
DROP FUNCTION response_cost(malu$model_response);
DROP FUNCTION response_cost(bigint);

CREATE FUNCTION response_cost(r malu$model_response) RETURNS numeric
LANGUAGE plpgsql STABLE
AS $body$
DECLARE
    v_input_price  bigint;
    v_output_price bigint;
BEGIN
    IF r.cache_hit THEN
        RETURN 0;
    END IF;
    IF r.prompt_tokens IS NULL OR r.completion_tokens IS NULL THEN
        RETURN NULL;
    END IF;

    SELECT ma.price_per_input_token, ma.price_per_output_token
    INTO v_input_price, v_output_price
    FROM malu$model_request mr
    JOIN malu$model_alias   ma ON ma.alias_id = mr.alias_id
    WHERE mr.request_id = r.request_id;

    IF v_input_price IS NULL THEN
        RETURN NULL;
    END IF;
    RETURN (r.prompt_tokens::numeric    * v_input_price) +
           (r.completion_tokens::numeric * v_output_price);
END;
$body$;

CREATE FUNCTION response_cost(p_request_id bigint) RETURNS numeric
LANGUAGE sql STABLE
AS $body$
    SELECT response_cost(r) FROM malu$model_response r WHERE r.request_id = p_request_id;
$body$;

GRANT EXECUTE ON FUNCTION response_cost(malu$model_response),
                          response_cost(bigint)
TO maludb_llm_admin,
   maludb_llm_prompt_author,
   maludb_llm_prompt_approver,
   maludb_llm_model_admin,
   maludb_llm_executor,
   maludb_llm_auditor;

-- ---------------------------------------------------------------------
-- usage_today
--
-- Returns today's usage value for one scope row. The "today" boundary
-- is the calling session's current_date.
--
-- For cost/tokens, cache_hit responses are excluded (they were free).
-- For requests, every request counts.
-- ---------------------------------------------------------------------
CREATE FUNCTION usage_today(
    p_scope            text,
    p_scope_account_id bigint,
    p_scope_template_id bigint,
    p_scope_role       text,
    p_limit_kind       text
) RETURNS numeric
LANGUAGE plpgsql STABLE
AS $body$
DECLARE
    v_value numeric := 0;
BEGIN
    CASE p_limit_kind
    WHEN 'requests_daily' THEN
        SELECT count(*)::numeric INTO v_value
        FROM malu$model_request mr
        LEFT JOIN malu$account a ON a.account_id = mr.account_id
        LEFT JOIN malu$account_role ar ON ar.account_id = mr.account_id
        LEFT JOIN malu$role         r  ON r.role_id     = ar.role_id
        WHERE mr.submitted_at >= date_trunc('day', now())
          AND (
              CASE p_scope
                WHEN 'account' THEN mr.account_id = p_scope_account_id
                WHEN 'prompt'  THEN EXISTS (
                    SELECT 1 FROM malu$prompt_render pr
                    WHERE pr.render_id = mr.prompt_render_id
                      AND pr.template_id = p_scope_template_id)
                WHEN 'role'    THEN r.role_name = p_scope_role
                WHEN 'global'  THEN true
              END
          );
    WHEN 'tokens_daily' THEN
        SELECT COALESCE(sum(
                    COALESCE(resp.prompt_tokens, 0) +
                    COALESCE(resp.completion_tokens, 0)
                ), 0)::numeric INTO v_value
        FROM malu$model_response resp
        JOIN malu$model_request  mr ON mr.request_id = resp.request_id
        LEFT JOIN malu$account_role ar ON ar.account_id = mr.account_id
        LEFT JOIN malu$role         r  ON r.role_id     = ar.role_id
        WHERE resp.finished_at >= date_trunc('day', now())
          AND resp.cache_hit  = false
          AND (
              CASE p_scope
                WHEN 'account' THEN mr.account_id = p_scope_account_id
                WHEN 'prompt'  THEN EXISTS (
                    SELECT 1 FROM malu$prompt_render pr
                    WHERE pr.render_id = mr.prompt_render_id
                      AND pr.template_id = p_scope_template_id)
                WHEN 'role'    THEN r.role_name = p_scope_role
                WHEN 'global'  THEN true
              END
          );
    WHEN 'cost_daily' THEN
        SELECT COALESCE(sum(response_cost(resp)), 0)::numeric INTO v_value
        FROM malu$model_response resp
        JOIN malu$model_request  mr ON mr.request_id = resp.request_id
        LEFT JOIN malu$account_role ar ON ar.account_id = mr.account_id
        LEFT JOIN malu$role         r  ON r.role_id     = ar.role_id
        WHERE resp.finished_at >= date_trunc('day', now())
          AND resp.cache_hit  = false
          AND (
              CASE p_scope
                WHEN 'account' THEN mr.account_id = p_scope_account_id
                WHEN 'prompt'  THEN EXISTS (
                    SELECT 1 FROM malu$prompt_render pr
                    WHERE pr.render_id = mr.prompt_render_id
                      AND pr.template_id = p_scope_template_id)
                WHEN 'role'    THEN r.role_name = p_scope_role
                WHEN 'global'  THEN true
              END
          );
    END CASE;

    RETURN COALESCE(v_value, 0);
END;
$body$;

GRANT EXECUTE ON FUNCTION usage_today(text, bigint, bigint, text, text)
TO maludb_llm_admin,
   maludb_llm_prompt_author,
   maludb_llm_prompt_approver,
   maludb_llm_model_admin,
   maludb_llm_executor,
   maludb_llm_auditor;

-- ---------------------------------------------------------------------
-- check_budget
--
-- Iterate over every enabled policy that applies to this submission.
-- Raise BUDGET_EXCEEDED on the first violation. Idempotent and cache
-- hits don't trigger budget checks because they don't reach this far
-- (submit_render/call return early on those paths).
-- ---------------------------------------------------------------------
CREATE FUNCTION check_budget(
    p_account_id  bigint,
    p_template_id bigint
) RETURNS void
LANGUAGE plpgsql STABLE
AS $body$
DECLARE
    v_policy malu$budget_policy%ROWTYPE;
    v_usage  numeric;
BEGIN
    FOR v_policy IN
        SELECT * FROM malu$budget_policy
        WHERE enabled = true
          AND (
              (scope = 'account' AND scope_account_id  = p_account_id)
           OR (scope = 'prompt'  AND scope_template_id = p_template_id)
           OR (scope = 'role'    AND EXISTS (
                   SELECT 1 FROM malu$account_role ar
                   JOIN malu$role r ON r.role_id = ar.role_id
                   WHERE ar.account_id = p_account_id
                     AND r.role_name   = scope_role))
           OR (scope = 'global')
          )
        ORDER BY
            CASE scope
                WHEN 'account' THEN 1
                WHEN 'prompt'  THEN 2
                WHEN 'role'    THEN 3
                WHEN 'global'  THEN 4
            END
    LOOP
        v_usage := usage_today(v_policy.scope,
                               v_policy.scope_account_id,
                               v_policy.scope_template_id,
                               v_policy.scope_role,
                               v_policy.limit_kind);
        IF v_usage >= v_policy.limit_value THEN
            RAISE EXCEPTION
              'BUDGET_EXCEEDED: policy % (scope=%, kind=%) — today % >= limit %',
              v_policy.policy_name, v_policy.scope, v_policy.limit_kind,
              v_usage, v_policy.limit_value
              USING ERRCODE = 'insufficient_resources';
        END IF;
    END LOOP;
END;
$body$;

GRANT EXECUTE ON FUNCTION check_budget(bigint, bigint)
TO maludb_llm_admin,
   maludb_llm_executor;

-- ---------------------------------------------------------------------
-- submit_render (budget-aware)
--
-- check_budget runs BEFORE the request INSERT. Cache hits and
-- idempotent replays return early so they bypass the check, which is
-- the intended behavior (no model invocation, no cost).
-- ---------------------------------------------------------------------
DROP FUNCTION submit_render(bigint, text, text, jsonb, integer, text, text);

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

    -- Idempotency wins: skip cache + budget entirely on replay.
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

    -- Budget check: only applies when we're actually going to invoke
    -- the model (cache miss or cache off). Cache hits skip below.
    IF v_orig_request_id IS NULL THEN
        PERFORM check_budget(v_account_id, v_render.template_id);
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
-- call (budget-aware) — bound_prompt path
-- ---------------------------------------------------------------------
DROP FUNCTION call(bound_prompt, text, bigint, jsonb, integer, text, text, text);

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

    IF v_orig_request_id IS NULL THEN
        PERFORM check_budget(v_account_id, v_bound_row.template_id);
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

-- ---------------------------------------------------------------------
-- cost_by_account view
--
-- Live view (not materialized) for v1; daily roll-up by account +
-- alias. Operators can materialize this themselves with a partial
-- index if the volume warrants.
-- ---------------------------------------------------------------------
CREATE VIEW cost_by_account AS
SELECT
    a.account_id,
    a.account_name,
    ma.alias_name,
    date_trunc('day', resp.finished_at)::date AS day,
    count(*)                                  AS request_count,
    sum(COALESCE(resp.prompt_tokens, 0))      AS input_tokens,
    sum(COALESCE(resp.completion_tokens, 0))  AS output_tokens,
    sum(response_cost(resp))                  AS cost_micro_cents
FROM malu$model_response  resp
JOIN malu$model_request   mr ON mr.request_id = resp.request_id
LEFT JOIN malu$account    a  ON a.account_id  = mr.account_id
JOIN malu$model_alias     ma ON ma.alias_id   = mr.alias_id
WHERE resp.cache_hit = false
GROUP BY a.account_id, a.account_name, ma.alias_name, date_trunc('day', resp.finished_at);

GRANT SELECT ON cost_by_account TO
    maludb_llm_admin,
    maludb_llm_prompt_author,
    maludb_llm_prompt_approver,
    maludb_llm_model_admin,
    maludb_llm_auditor;
