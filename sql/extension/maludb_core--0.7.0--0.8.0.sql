\echo Use "ALTER EXTENSION maludb_core UPDATE TO '0.8.0'" to load this file. \quit

-- =====================================================================
-- maludb_core 0.7.0 → 0.8.0
--
-- R1.1-11: Convenience response accessors.
--
-- Pure SQL helpers on malu$model_response. Each accessor has two
-- overloads:
--
--   accessor(r malu$model_response)  — pure function, IMMUTABLE
--   accessor(p_request_id bigint)    — looks up response by request_id,
--                                      STABLE (reads malu$model_response)
--
-- response_cost() returns NULL until R1.1-9 wires per-alias pricing
-- columns. The accessor is provided now so application code can adopt
-- the surface and start benefiting once R1.1-9 lands without churn.
--
-- No schema change.
-- =====================================================================

CREATE OR REPLACE FUNCTION maludb_core_version() RETURNS text
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$ SELECT '0.8.0'::text $body$;

-- ---------------------------------------------------------------------
-- malu$response_tokens
--
-- Composite returned by response_tokens(). total is the sum when both
-- input and output token counts are recorded, NULL otherwise (so the
-- caller can distinguish "we don't know" from "0 tokens").
-- ---------------------------------------------------------------------
CREATE TYPE malu$response_tokens AS (
    prompt      integer,
    completion  integer,
    total       integer
);

-- ---------------------------------------------------------------------
-- response_text
--
-- Returns the recorded text output. Returns NULL when:
--   * response is missing
--   * response succeeded but adapter wrote only output_json (rare in R1.0)
--   * response failed (use response_error to inspect)
-- ---------------------------------------------------------------------
CREATE FUNCTION response_text(r malu$model_response) RETURNS text
LANGUAGE sql IMMUTABLE
AS $body$ SELECT r.output_text $body$;

CREATE FUNCTION response_text(p_request_id bigint) RETURNS text
LANGUAGE sql STABLE
AS $body$
    SELECT output_text FROM malu$model_response WHERE request_id = p_request_id;
$body$;

-- ---------------------------------------------------------------------
-- response_json
--
-- Returns the recorded structured output. Preference order:
--   1. output_json (already parsed)
--   2. output_text parsed as JSON (if it parses)
--   3. NULL
-- ---------------------------------------------------------------------
CREATE FUNCTION response_json(r malu$model_response) RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE
AS $body$
DECLARE
    v jsonb;
BEGIN
    IF r.output_json IS NOT NULL THEN
        RETURN r.output_json;
    END IF;
    IF r.output_text IS NULL THEN
        RETURN NULL;
    END IF;
    BEGIN
        v := r.output_text::jsonb;
        RETURN v;
    EXCEPTION WHEN invalid_text_representation OR datatype_mismatch THEN
        RETURN NULL;
    END;
END;
$body$;

CREATE FUNCTION response_json(p_request_id bigint) RETURNS jsonb
LANGUAGE sql STABLE
AS $body$
    SELECT response_json(r) FROM malu$model_response r WHERE r.request_id = p_request_id;
$body$;

-- ---------------------------------------------------------------------
-- response_tokens
--
-- Composite of (prompt, completion, total). Any NULL inputs propagate
-- into a NULL `total`.
-- ---------------------------------------------------------------------
CREATE FUNCTION response_tokens(r malu$model_response) RETURNS malu$response_tokens
LANGUAGE sql IMMUTABLE
AS $body$
    SELECT ROW(
        r.prompt_tokens,
        r.completion_tokens,
        CASE
            WHEN r.prompt_tokens IS NULL OR r.completion_tokens IS NULL THEN NULL
            ELSE r.prompt_tokens + r.completion_tokens
        END
    )::malu$response_tokens;
$body$;

CREATE FUNCTION response_tokens(p_request_id bigint) RETURNS malu$response_tokens
LANGUAGE sql STABLE
AS $body$
    SELECT response_tokens(r) FROM malu$model_response r WHERE r.request_id = p_request_id;
$body$;

-- ---------------------------------------------------------------------
-- response_cost
--
-- Returns the run-time cost in currency-neutral units. Always NULL
-- until R1.1-9 adds pricing columns to malu$model_alias. Provided now
-- so application code can adopt the API stable surface.
-- ---------------------------------------------------------------------
CREATE FUNCTION response_cost(r malu$model_response) RETURNS numeric
LANGUAGE sql IMMUTABLE PARALLEL SAFE
AS $body$ SELECT NULL::numeric $body$;

CREATE FUNCTION response_cost(p_request_id bigint) RETURNS numeric
LANGUAGE sql STABLE
AS $body$
    -- Touch the table so the function still semantically depends on a
    -- recorded response (returns NULL for unknown request_id too, but
    -- callers can disambiguate via response_text() returning NULL).
    SELECT NULL::numeric FROM malu$model_response WHERE request_id = p_request_id;
$body$;

-- ---------------------------------------------------------------------
-- response_error
--
-- Returns the user-safe error message. Preference order:
--   1. user_safe_error (curated)
--   2. error_class (uncurated, may be technical)
--   3. NULL when the response succeeded
-- ---------------------------------------------------------------------
CREATE FUNCTION response_error(r malu$model_response) RETURNS text
LANGUAGE sql IMMUTABLE
AS $body$
    SELECT CASE
        WHEN r.status = 'succeeded' THEN NULL
        ELSE COALESCE(r.user_safe_error, r.error_class)
    END;
$body$;

CREATE FUNCTION response_error(p_request_id bigint) RETURNS text
LANGUAGE sql STABLE
AS $body$
    SELECT response_error(r) FROM malu$model_response r WHERE r.request_id = p_request_id;
$body$;

-- ---------------------------------------------------------------------
-- Grants. All accessors are read-only; expose to every LLM role that
-- already has SELECT on malu$model_response.
-- ---------------------------------------------------------------------
GRANT EXECUTE ON FUNCTION response_text(malu$model_response),
                       response_text(bigint),
                       response_json(malu$model_response),
                       response_json(bigint),
                       response_tokens(malu$model_response),
                       response_tokens(bigint),
                       response_cost(malu$model_response),
                       response_cost(bigint),
                       response_error(malu$model_response),
                       response_error(bigint)
TO maludb_llm_admin,
   maludb_llm_prompt_author,
   maludb_llm_prompt_approver,
   maludb_llm_model_admin,
   maludb_llm_executor,
   maludb_llm_auditor;
