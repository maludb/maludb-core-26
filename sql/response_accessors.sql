-- R1.1-11: Convenience response accessors.
--
-- Exercises:
--   * response_text / _json / _tokens / _cost / _error on a composite row
--   * same five accessors looked up by request_id (bigint overload)
--   * NULL semantics: response_cost is always NULL until R1.1-9; missing
--     response yields NULL across the surface
--   * response_json prefers output_json, falls back to parsing output_text
--   * response_error: NULL on success, curated message otherwise

\set ECHO all
SET search_path = maludb_core, public;
SET client_min_messages = NOTICE;

-- ---------- fixture ----------------------------------------------------
INSERT INTO malu$account(account_name, account_kind, description) VALUES
    ('ra_tenant', 'admin', 'R1.1-11 accessors test');

INSERT INTO malu$model_provider (provider_name, provider_kind, adapter_name)
VALUES ('ra_provider', 'stub', 'stub_adapter');
-- Pricing set so response_cost returns a real number (R1.1-9 wired
-- pricing into the accessor). Pre-R1.1-9 this column didn't exist.
INSERT INTO malu$model_alias (alias_name, provider_id, model_identifier,
                              price_per_input_token, price_per_output_token)
VALUES ('ra_alias',
        (SELECT provider_id FROM malu$model_provider WHERE provider_name='ra_provider'),
        'ra-model',
        100, 250);

INSERT INTO malu$prompt_template (template_name, body) VALUES
    ('ra_template', 'hi {{name}}');
SELECT declare_prompt_variable('ra_template', 'name', p_required=>true) > 0;

INSERT INTO malu$session (account_id, prompt_template_id)
SELECT account_id, (SELECT template_id FROM malu$prompt_template WHERE template_name='ra_template')
FROM malu$account WHERE account_name='ra_tenant'
RETURNING session_id \gset

-- Three requests with three response shapes: succeeded-with-text,
-- succeeded-with-json, and failed.
SELECT call(bind_prompt('ra_template', jsonb_build_object('name','Alpha')), 'ra_alias') AS req_text \gset
SELECT call(bind_prompt('ra_template', jsonb_build_object('name','Beta')),  'ra_alias') AS req_json \gset
SELECT call(bind_prompt('ra_template', jsonb_build_object('name','Gamma')), 'ra_alias') AS req_fail \gset

-- Mark all three as fulfilled (matches what maludb_modeld would write).
UPDATE malu$model_request SET status='succeeded', finished_at=now()
WHERE request_id IN (:req_text, :req_json, :req_fail);

INSERT INTO malu$model_response
    (request_id, status, output_text, output_hash, prompt_tokens, completion_tokens,
     latency_ms, adapter_name)
VALUES
    (:req_text, 'succeeded', 'hello back, Alpha',
     encode(sha256('hello back, Alpha'::bytea),'hex'),
     8, 5, 120, 'stub_adapter');

INSERT INTO malu$model_response
    (request_id, status, output_text, output_json, prompt_tokens, completion_tokens,
     latency_ms, adapter_name)
VALUES
    (:req_json, 'succeeded', '{"answer": 42, "ok": true}',
     '{"answer": 42, "ok": true}'::jsonb, 10, 6, 145, 'stub_adapter');

INSERT INTO malu$model_response
    (request_id, status, error_class, user_safe_error, latency_ms, adapter_name)
VALUES
    (:req_fail, 'failed', 'rate_limit_exceeded', 'Service temporarily busy. Try again shortly.',
     30, 'stub_adapter');

-- ---------- accessor: row overload (passed via SELECT FROM r) ----------
SELECT response_text(r), response_error(r) IS NULL AS no_error
FROM malu$model_response r WHERE r.request_id = :req_text;

SELECT response_json(r) FROM malu$model_response r WHERE r.request_id = :req_json;

-- output_text-only response: response_json should parse it because the
-- text happens to be JSON-shaped.
INSERT INTO malu$prompt_template (template_name, body) VALUES ('ra_extra', 'x');
SELECT approve_prompt('ra_extra') > 0;
SELECT call(bind_prompt('ra_extra', '{}'::jsonb), 'ra_alias') AS req_text_as_json \gset
UPDATE malu$model_request SET status='succeeded', finished_at=now()
WHERE request_id = :req_text_as_json;
INSERT INTO malu$model_response (request_id, status, output_text, adapter_name)
VALUES (:req_text_as_json, 'succeeded', '{"reparsed": 1}', 'stub_adapter');

SELECT response_json(:req_text_as_json) AS parsed_from_text;

-- output_text non-JSON: response_json returns NULL without raising
SELECT response_json(:req_text) IS NULL AS text_not_json;

-- ---------- accessor: bigint overload ---------------------------------
SELECT response_text(:req_text)  AS req_text_via_id,
       response_text(:req_json)  AS req_json_text_via_id,
       response_text(:req_fail)  IS NULL AS req_fail_text_null;

SELECT response_tokens(:req_text)  AS toks_text,
       response_tokens(:req_json)  AS toks_json,
       response_tokens(:req_fail)  AS toks_fail;

-- response_cost: real numbers post R1.1-9.
-- req_text: 8*100 + 5*250 = 800 + 1250 = 2050 micro-cents
-- req_json: 10*100 + 6*250 = 1000 + 1500 = 2500 micro-cents
-- req_fail: NULL (no prompt_tokens / completion_tokens recorded)
SELECT response_cost(:req_text)  AS cost_text,
       response_cost(:req_json)  AS cost_json,
       response_cost(:req_fail)  IS NULL AS cost_fail_null;

-- response_error
SELECT response_error(:req_text)  AS err1,
       response_error(:req_json)  AS err2,
       response_error(:req_fail)  AS err3;

-- ---------- missing response: bigint overload returns NULL -------------
SELECT response_text(999999)   IS NULL AS missing_text_null,
       response_json(999999)   IS NULL AS missing_json_null,
       response_tokens(999999) IS NULL AS missing_tokens_null,
       response_cost(999999)   IS NULL AS missing_cost_null,
       response_error(999999)  IS NULL AS missing_error_null;

-- ---------- composite token totals ------------------------------------
-- prompt+completion sums when both non-null; NULL total when either is.
SELECT
    (response_tokens(:req_text)).prompt   AS p1,
    (response_tokens(:req_text)).completion AS c1,
    (response_tokens(:req_text)).total    AS t1,
    (response_tokens(:req_fail)).total    AS t_fail;  -- fail row has no token counts

-- ---------- cleanup ----------------------------------------------------
DELETE FROM malu$model_response WHERE request_id IN
    (:req_text, :req_json, :req_fail, :req_text_as_json);
DELETE FROM malu$model_request WHERE alias_id =
    (SELECT alias_id FROM malu$model_alias WHERE alias_name='ra_alias');
DELETE FROM malu$bound_prompt WHERE template_id IN
    (SELECT template_id FROM malu$prompt_template WHERE template_name IN ('ra_template','ra_extra'));
DELETE FROM malu$prompt_render WHERE template_id IN
    (SELECT template_id FROM malu$prompt_template WHERE template_name IN ('ra_template','ra_extra'));
DELETE FROM malu$session WHERE session_id = :session_id;
DELETE FROM malu$prompt_template WHERE template_name IN ('ra_template','ra_extra');
DELETE FROM malu$model_alias WHERE alias_name='ra_alias';
DELETE FROM malu$model_provider WHERE provider_name='ra_provider';
DELETE FROM malu$account WHERE account_name='ra_tenant';
