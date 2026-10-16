-- R1.1-8: Response caching.
--
-- Exercises:
--   * cache_mode='off' (default) leaves cache_key NULL, no hit lookup
--   * cache_mode='prefer' miss → record cache_key, normal pending flow
--   * cache_mode='prefer' hit  → new request + response with cache_hit=true
--   * cache_mode='required' miss → CACHE_MISS_REQUIRED raise
--   * cache_mode='required' hit  → served from cache
--   * cache_mode='refresh' → ignores cache, records key, re-executes
--   * per-account scope: different accounts do not share cache entries
--   * different generation_params produce different cache keys
--   * call() (bound_prompt path) honours the same cache_mode surface

\set ECHO all
SET search_path = maludb_core, public;
SET client_min_messages = NOTICE;

-- ---------- fixture ----------------------------------------------------
INSERT INTO malu$account(account_name, account_kind, description) VALUES
    ('rc_tenant_a', 'admin', 'R1.1-8 cache test, tenant A'),
    ('rc_tenant_b', 'admin', 'R1.1-8 cache test, tenant B');

INSERT INTO malu$model_provider (provider_name, provider_kind, adapter_name)
VALUES ('rc_provider', 'stub', 'stub_adapter');
INSERT INTO malu$model_alias (alias_name, provider_id, model_identifier)
VALUES ('rc_alias',
        (SELECT provider_id FROM malu$model_provider WHERE provider_name='rc_provider'),
        'rc-model');

INSERT INTO malu$prompt_template (template_name, body) VALUES
    ('rc_template', 'hello {{name}}');
SELECT declare_prompt_variable('rc_template', 'name', p_required=>true) > 0;

INSERT INTO malu$session (account_id, prompt_template_id)
SELECT account_id, (SELECT template_id FROM malu$prompt_template WHERE template_name='rc_template')
FROM malu$account WHERE account_name='rc_tenant_a'
RETURNING session_id AS session_a \gset

INSERT INTO malu$session (account_id, prompt_template_id)
SELECT account_id, (SELECT template_id FROM malu$prompt_template WHERE template_name='rc_template')
FROM malu$account WHERE account_name='rc_tenant_b'
RETURNING session_id AS session_b \gset

-- ---------- cache_mode='off' (default) ---------------------------------
SELECT call(bind_prompt('rc_template', jsonb_build_object('name','Alpha'),
                        NULL, :session_a,
                        NULL, (SELECT account_id FROM malu$account WHERE account_name='rc_tenant_a')),
            'rc_alias') AS req_off \gset

SELECT cache_key IS NULL AS no_cache_key, cache_mode
FROM malu$model_request WHERE request_id = :req_off;

-- ---------- cache_mode='prefer', miss (no prior response yet) ----------
SELECT call(bind_prompt('rc_template', jsonb_build_object('name','Bravo'),
                        NULL, :session_a,
                        NULL, (SELECT account_id FROM malu$account WHERE account_name='rc_tenant_a')),
            'rc_alias',
            p_cache_mode=>'prefer') AS req_pref_miss \gset

SELECT cache_key IS NOT NULL AS has_key, cache_mode, status
FROM malu$model_request WHERE request_id = :req_pref_miss;

-- mark it succeeded so it becomes cache-eligible
UPDATE malu$model_request SET status='succeeded', finished_at=now()
WHERE request_id = :req_pref_miss;
INSERT INTO malu$model_response (request_id, status, output_text, prompt_tokens, completion_tokens, adapter_name)
VALUES (:req_pref_miss, 'succeeded', 'cached output for Bravo', 5, 4, 'stub_adapter');

-- ---------- cache_mode='prefer', hit -----------------------------------
SELECT call(bind_prompt('rc_template', jsonb_build_object('name','Bravo'),
                        NULL, :session_a,
                        NULL, (SELECT account_id FROM malu$account WHERE account_name='rc_tenant_a')),
            'rc_alias',
            p_cache_mode=>'prefer') AS req_pref_hit \gset

-- new request must be 'succeeded' synchronously
SELECT mr.status, mr.cache_mode, mr.cache_key IS NOT NULL AS has_key,
       resp.cache_hit, resp.cached_from_request_id = :req_pref_miss AS points_to_original,
       resp.output_text,
       resp.prompt_tokens     AS p_tok_zero,
       resp.completion_tokens AS c_tok_zero
FROM malu$model_request mr
JOIN malu$model_response resp ON resp.request_id = mr.request_id
WHERE mr.request_id = :req_pref_hit;

-- the original request remains the source of truth (cache_hit=false)
SELECT cache_hit FROM malu$model_response WHERE request_id = :req_pref_miss;

-- ---------- cache_mode='required', hit ---------------------------------
SELECT call(bind_prompt('rc_template', jsonb_build_object('name','Bravo'),
                        NULL, :session_a,
                        NULL, (SELECT account_id FROM malu$account WHERE account_name='rc_tenant_a')),
            'rc_alias',
            p_cache_mode=>'required') AS req_req_hit \gset

SELECT resp.cache_hit, resp.output_text
FROM malu$model_response resp WHERE resp.request_id = :req_req_hit;

-- ---------- cache_mode='required', miss → raise ------------------------
DO $$ BEGIN
    PERFORM call(bind_prompt('rc_template', jsonb_build_object('name','NeverBound'),
                             NULL, NULL,
                             NULL, (SELECT account_id FROM malu$account WHERE account_name='rc_tenant_a')),
                 'rc_alias',
                 p_cache_mode=>'required');
    RAISE EXCEPTION 'should have raised CACHE_MISS_REQUIRED';
EXCEPTION WHEN no_data_found THEN
    RAISE NOTICE 'OK: required miss rejected';
END $$;

-- ---------- per-account isolation --------------------------------------
-- tenant B with the SAME variables must miss tenant A's cache.
SELECT call(bind_prompt('rc_template', jsonb_build_object('name','Bravo'),
                        NULL, :session_b,
                        NULL, (SELECT account_id FROM malu$account WHERE account_name='rc_tenant_b')),
            'rc_alias',
            p_cache_mode=>'prefer') AS req_tenant_b \gset

SELECT mr.cache_mode, mr.cache_key <> (SELECT cache_key FROM malu$model_request WHERE request_id=:req_pref_miss) AS keys_differ,
       resp.response_id IS NULL OR resp.cache_hit = false AS no_cross_tenant_hit
FROM malu$model_request mr
LEFT JOIN malu$model_response resp ON resp.request_id = mr.request_id
WHERE mr.request_id = :req_tenant_b;

-- ---------- different generation_params → different keys ---------------
SELECT call(bind_prompt('rc_template', jsonb_build_object('name','Bravo'),
                        NULL, :session_a,
                        NULL, (SELECT account_id FROM malu$account WHERE account_name='rc_tenant_a')),
            'rc_alias',
            p_generation_params=>jsonb_build_object('temperature', 0.7),
            p_cache_mode=>'prefer') AS req_params_a \gset

SELECT mr.cache_key <> (SELECT cache_key FROM malu$model_request WHERE request_id=:req_pref_miss) AS keys_differ
FROM malu$model_request mr WHERE mr.request_id = :req_params_a;

-- ---------- cache_mode='refresh' ---------------------------------------
SELECT call(bind_prompt('rc_template', jsonb_build_object('name','Bravo'),
                        NULL, :session_a,
                        NULL, (SELECT account_id FROM malu$account WHERE account_name='rc_tenant_a')),
            'rc_alias',
            p_cache_mode=>'refresh') AS req_refresh \gset

-- refresh writes cache_key but doesn't serve from cache: status stays 'pending', no response yet
SELECT cache_key IS NOT NULL AS has_key, cache_mode, status
FROM malu$model_request WHERE request_id = :req_refresh;
SELECT count(*) AS resp_rows FROM malu$model_response WHERE request_id = :req_refresh;

-- ---------- submit_render path (cache-aware) ---------------------------
SELECT render_prompt(:session_a, 'rc_template',
                     p_variables=>jsonb_build_object('name','SubR')) AS render_sr \gset

SELECT submit_render(:render_sr, 'rc_alias',
                     p_cache_mode=>'prefer') AS req_sr_miss \gset

SELECT cache_mode FROM malu$model_request WHERE request_id = :req_sr_miss;

-- ---------- bad cache_mode ---------------------------------------------
DO $$ BEGIN
    PERFORM call(bind_prompt('rc_template', jsonb_build_object('name','X'),
                             NULL, NULL,
                             NULL, (SELECT account_id FROM malu$account WHERE account_name='rc_tenant_a')),
                 'rc_alias',
                 p_cache_mode=>'bogus');
    RAISE EXCEPTION 'should have raised CACHE_BAD_MODE';
EXCEPTION WHEN invalid_parameter_value THEN
    RAISE NOTICE 'OK: bad cache mode rejected';
END $$;

-- ---------- cleanup ----------------------------------------------------
DELETE FROM malu$model_response WHERE request_id IN
    (SELECT request_id FROM malu$model_request WHERE alias_id =
        (SELECT alias_id FROM malu$model_alias WHERE alias_name='rc_alias'));
DELETE FROM malu$model_request WHERE alias_id =
    (SELECT alias_id FROM malu$model_alias WHERE alias_name='rc_alias');
DELETE FROM malu$bound_prompt WHERE template_id IN
    (SELECT template_id FROM malu$prompt_template WHERE template_name='rc_template');
DELETE FROM malu$prompt_render WHERE template_id IN
    (SELECT template_id FROM malu$prompt_template WHERE template_name='rc_template');
DELETE FROM malu$session WHERE session_id IN (:session_a, :session_b);
DELETE FROM malu$prompt_template WHERE template_name='rc_template';
DELETE FROM malu$model_alias WHERE alias_name='rc_alias';
DELETE FROM malu$model_provider WHERE provider_name='rc_provider';
DELETE FROM malu$account WHERE account_name IN ('rc_tenant_a','rc_tenant_b');
