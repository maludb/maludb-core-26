\echo Use "ALTER EXTENSION maludb_core UPDATE TO '0.9.0'" to load this file. \quit

-- =====================================================================
-- maludb_core 0.8.0 → 0.9.0
--
-- R1.1-8: Response caching.
--
-- Adds cache_key + cache_mode on malu$model_request and cache_hit +
-- cached_from_request_id on malu$model_response. Cache scope is
-- per-account (chosen 2026-05-12): cache_key embeds the resolved
-- account_id so tenants never serve each other's cached responses.
--
-- Cache modes:
--   off       — default. No cache lookup, no cache_key recorded.
--   prefer    — lookup first; serve hit synchronously, else execute
--               normally and record cache_key for future hits.
--   required  — lookup; serve hit, else raise CACHE_MISS_REQUIRED.
--   refresh   — skip lookup; always execute; record cache_key.
--
-- Cache key = sha256(account || template_id || alias_id ||
--                    prompt_hash || sha256(generation_params)).
-- generation_params normalisation is the legacy jsonb::text — same
-- params text always hashes the same way.
--
-- Cache hit produces a NEW malu$model_request (audit) + a NEW
-- malu$model_response with cache_hit=true, cached_from_request_id
-- pointing at the original, and prompt_tokens/completion_tokens=0
-- (so R1.1-9 budget accounting will skip cache rows).
-- =====================================================================

CREATE OR REPLACE FUNCTION maludb_core_version() RETURNS text
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$ SELECT '0.9.0'::text $body$;

-- ---------------------------------------------------------------------
-- Schema additions
-- ---------------------------------------------------------------------
ALTER TABLE malu$model_request
    ADD COLUMN cache_key  text,
    ADD COLUMN cache_mode text NOT NULL DEFAULT 'off'
        CHECK (cache_mode IN ('off','prefer','required','refresh'));

CREATE INDEX malu$model_request_cache_key_idx
    ON malu$model_request (cache_key, submitted_at DESC)
    WHERE cache_key IS NOT NULL;

ALTER TABLE malu$model_response
    ADD COLUMN cache_hit              boolean NOT NULL DEFAULT false,
    ADD COLUMN cached_from_request_id bigint
        REFERENCES malu$model_request(request_id) ON DELETE SET NULL;

CREATE INDEX malu$model_response_cache_hit_idx
    ON malu$model_response (cache_hit) WHERE cache_hit = true;

-- ---------------------------------------------------------------------
-- _compute_cache_key
--
-- Stable, per-account cache key. account_id NULL → 'anon' so anonymous
-- callers share a separate, narrower cache slot rather than colliding
-- with any real tenant.
-- ---------------------------------------------------------------------
CREATE FUNCTION _compute_cache_key(
    p_account_id       bigint,
    p_template_id      bigint,
    p_alias_id         bigint,
    p_prompt_hash      text,
    p_generation_params jsonb
) RETURNS text
LANGUAGE sql IMMUTABLE PARALLEL SAFE
AS $body$
    SELECT encode(sha256(
        (
            COALESCE(p_account_id::text, 'anon') || '|' ||
            p_template_id::text || '|' ||
            p_alias_id::text   || '|' ||
            COALESCE(p_prompt_hash, '') || '|' ||
            encode(sha256(
                COALESCE(p_generation_params, '{}'::jsonb)::text::bytea
            ), 'hex')
        )::bytea
    ), 'hex');
$body$;

-- ---------------------------------------------------------------------
-- _lookup_cache
--
-- Returns the request_id of the most recent successful, non-cached
-- response matching cache_key. NULL means cache miss.
-- ---------------------------------------------------------------------
CREATE FUNCTION _lookup_cache(p_cache_key text) RETURNS bigint
LANGUAGE sql STABLE
AS $body$
    SELECT mr.request_id
    FROM malu$model_request mr
    JOIN malu$model_response resp ON resp.request_id = mr.request_id
    WHERE mr.cache_key = p_cache_key
      AND resp.cache_hit = false
      AND resp.status    = 'succeeded'
    ORDER BY mr.submitted_at DESC
    LIMIT 1;
$body$;

-- ---------------------------------------------------------------------
-- _apply_cache_hit
--
-- Given the new request_id and the cached original's request_id, copy
-- the original's response into a new response row with cache_hit=true,
-- token counts zeroed, and set the new request to 'succeeded'.
-- Returns the new response_id.
-- ---------------------------------------------------------------------
CREATE FUNCTION _apply_cache_hit(
    p_new_request_id      bigint,
    p_original_request_id bigint
) RETURNS bigint
LANGUAGE plpgsql
AS $body$
DECLARE
    v_orig       malu$model_response%ROWTYPE;
    v_new_resp_id bigint;
BEGIN
    SELECT * INTO v_orig
    FROM malu$model_response WHERE request_id = p_original_request_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'cache hit pointed at request % but no response found',
            p_original_request_id
            USING ERRCODE = 'no_data_found';
    END IF;

    INSERT INTO malu$model_response (
        request_id, status, output_text, output_hash, output_json, tool_calls,
        finish_reason, raw_provider_response,
        prompt_tokens, completion_tokens, latency_ms,
        error_class, user_safe_error, adapter_name,
        cache_hit, cached_from_request_id
    ) VALUES (
        p_new_request_id, 'succeeded', v_orig.output_text, v_orig.output_hash,
        v_orig.output_json, v_orig.tool_calls,
        v_orig.finish_reason, v_orig.raw_provider_response,
        0, 0, 0,  -- cache hits don't consume tokens or model time
        NULL, NULL,
        v_orig.adapter_name,
        true, p_original_request_id
    ) RETURNING response_id INTO v_new_resp_id;

    UPDATE malu$model_request
       SET status      = 'succeeded',
           started_at  = now(),
           finished_at = now()
     WHERE request_id = p_new_request_id;

    RETURN v_new_resp_id;
END;
$body$;

-- ---------------------------------------------------------------------
-- submit_render (cache-aware)
--
-- New optional p_cache_mode parameter. Default 'off' preserves R1.0/R1.1
-- behavior exactly. Modes 'prefer' and 'required' look up cache; mode
-- 'refresh' records cache_key but skips lookup.
--
-- Adding p_cache_mode changes the function's identity (PG matches on
-- argument types, not names), so CREATE OR REPLACE would produce a new
-- overload instead of replacing the prior 5-arg version. Drop the
-- old signature first.
-- ---------------------------------------------------------------------
DROP FUNCTION submit_render(bigint, text, text, jsonb, integer);

CREATE FUNCTION submit_render(
    p_render_id         bigint,
    p_alias_name        text,
    p_account_name      text DEFAULT NULL,
    p_generation_params jsonb DEFAULT '{}'::jsonb,
    p_timeout_ms        integer DEFAULT 30000,
    p_cache_mode        text DEFAULT 'off'
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
            status)
    VALUES (v_alias_id,
            v_account_id,
            v_render.session_id, p_render_id,
            v_render.rendered_prompt, v_render.prompt_hash,
            COALESCE(p_generation_params, '{}'::jsonb), p_timeout_ms,
            v_cache_key, p_cache_mode,
            CASE WHEN v_orig_request_id IS NOT NULL THEN 'pending' ELSE 'pending' END)
    RETURNING request_id INTO v_request_id;

    IF v_orig_request_id IS NOT NULL THEN
        PERFORM _apply_cache_hit(v_request_id, v_orig_request_id);
    END IF;

    RETURN v_request_id;
END;
$body$;

-- ---------------------------------------------------------------------
-- call (cache-aware) — bound_prompt path
--
-- Same surface as 0.5.0→0.6.0 plus p_cache_mode. The cache key uses
-- the bound prompt's account_id when p_account_name isn't supplied,
-- preserving tenant isolation. As with submit_render above, drop the
-- old 6-arg signature so the new 7-arg form replaces it cleanly.
-- ---------------------------------------------------------------------
DROP FUNCTION call(bound_prompt, text, bigint, jsonb, integer, text);

CREATE FUNCTION call(
    p_bound             bound_prompt,
    p_alias_name        text,
    p_session_id        bigint  DEFAULT NULL,
    p_generation_params jsonb   DEFAULT '{}'::jsonb,
    p_timeout_ms        integer DEFAULT 30000,
    p_account_name      text    DEFAULT NULL,
    p_cache_mode        text    DEFAULT 'off'
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
         cache_key, cache_mode, status)
    VALUES
        (COALESCE(p_session_id, v_bound_row.session_id),
         v_bound_row.render_id, v_alias_id, v_account_id,
         v_bound_row.rendered_full, v_bound_row.prompt_hash,
         COALESCE(p_generation_params, '{}'::jsonb),
         p_timeout_ms,
         v_cache_key, p_cache_mode, 'pending')
    RETURNING request_id INTO v_request_id;

    IF v_orig_request_id IS NOT NULL THEN
        PERFORM _apply_cache_hit(v_request_id, v_orig_request_id);
    END IF;

    RETURN v_request_id;
END;
$body$;

-- ---------------------------------------------------------------------
-- Grants: cache helpers are read by every LLM role that already reads
-- malu$model_request / _response. EXECUTE on the new function overload
-- is implicitly granted PUBLIC by CREATE OR REPLACE, but we make it
-- explicit for the helpers for symmetry with the prior phases.
-- ---------------------------------------------------------------------
GRANT EXECUTE ON FUNCTION _compute_cache_key(bigint, bigint, bigint, text, jsonb),
                          _lookup_cache(text)
TO maludb_llm_admin,
   maludb_llm_prompt_author,
   maludb_llm_prompt_approver,
   maludb_llm_model_admin,
   maludb_llm_executor,
   maludb_llm_auditor;

GRANT EXECUTE ON FUNCTION _apply_cache_hit(bigint, bigint)
TO maludb_llm_admin,
   maludb_llm_executor;
