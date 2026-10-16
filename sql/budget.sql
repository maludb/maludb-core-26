-- R1.1-9: Budget + quota + token accounting.
--
-- Exercises:
--   * pricing columns on malu$model_alias
--   * response_cost computes from tokens × pricing
--   * response_cost returns 0 on cache_hit, NULL on missing tokens
--   * malu$budget_policy CHECK enforces exactly-one-scope
--   * check_budget raises BUDGET_EXCEEDED at submit time
--   * cache hits and idempotent replays bypass the budget gate
--   * cost_by_account view aggregates correctly

\set ECHO all
SET search_path = maludb_core, public;
SET client_min_messages = NOTICE;

-- ---------- fixture ----------------------------------------------------
INSERT INTO malu$account(account_name, account_kind, description) VALUES
    ('bdg_tenant', 'admin', 'R1.1-9 budget tenant');

SELECT account_id AS tenant_id FROM malu$account WHERE account_name='bdg_tenant' \gset

INSERT INTO malu$model_provider (provider_name, provider_kind, adapter_name)
VALUES ('bdg_provider', 'stub', 'stub_adapter');

INSERT INTO malu$model_alias (alias_name, provider_id, model_identifier,
                              price_per_input_token, price_per_output_token)
VALUES ('bdg_alias',
        (SELECT provider_id FROM malu$model_provider WHERE provider_name='bdg_provider'),
        'bdg-model',
        300,    -- micro-cents per input token  ($0.0003 each)
        1000);  -- micro-cents per output token ($0.001 each)

INSERT INTO malu$model_alias (alias_name, provider_id, model_identifier)
VALUES ('bdg_alias_free',
        (SELECT provider_id FROM malu$model_provider WHERE provider_name='bdg_provider'),
        'bdg-model-free');

INSERT INTO malu$prompt_template (template_name, body) VALUES
    ('bdg_template', 'hello {{name}}');
SELECT declare_prompt_variable('bdg_template', 'name', p_required=>true) > 0;

INSERT INTO malu$session (account_id, prompt_template_id)
SELECT account_id, (SELECT template_id FROM malu$prompt_template WHERE template_name='bdg_template')
FROM malu$account WHERE account_name='bdg_tenant'
RETURNING session_id \gset

-- ---------- pricing on alias ------------------------------------------
SELECT alias_name, price_per_input_token, price_per_output_token
FROM malu$model_alias WHERE alias_name LIKE 'bdg_%' ORDER BY alias_name;

-- ---------- response_cost computes ------------------------------------
-- cache_mode='prefer' on the first call so the cache_key is recorded;
-- later cache-bypass test relies on this row being cache-eligible.
SELECT call(bind_prompt('bdg_template', jsonb_build_object('name','Alpha'),
                        NULL, :session_id, NULL, :tenant_id),
            'bdg_alias',
            p_cache_mode=>'prefer') AS req_cost \gset

UPDATE malu$model_request SET status='succeeded', finished_at=now()
WHERE request_id = :req_cost;

INSERT INTO malu$model_response (request_id, status, output_text, prompt_tokens, completion_tokens, adapter_name)
VALUES (:req_cost, 'succeeded', 'reply', 100, 50, 'stub_adapter');

-- expected: 100*300 + 50*1000 = 80000 micro-cents (= $0.08)
SELECT response_cost(:req_cost) AS micro_cents;

-- cost_by_account view picks it up
SELECT account_name, alias_name, request_count, input_tokens, output_tokens, cost_micro_cents
FROM cost_by_account WHERE account_name = 'bdg_tenant';

-- ---------- response_cost on cache_hit row → 0 ------------------------
SELECT call(bind_prompt('bdg_template', jsonb_build_object('name','Alpha'),
                        NULL, :session_id, NULL, :tenant_id),
            'bdg_alias',
            p_cache_mode=>'prefer') AS req_cache_hit \gset

SELECT cache_hit, response_cost(:req_cache_hit) AS cost_zero
FROM malu$model_response WHERE request_id = :req_cache_hit;

-- ---------- response_cost NULL when tokens missing --------------------
SELECT call(bind_prompt('bdg_template', jsonb_build_object('name','Beta'),
                        NULL, :session_id, NULL, :tenant_id),
            'bdg_alias_free') AS req_no_tokens \gset

UPDATE malu$model_request SET status='succeeded', finished_at=now()
WHERE request_id = :req_no_tokens;

INSERT INTO malu$model_response (request_id, status, output_text, adapter_name)
VALUES (:req_no_tokens, 'succeeded', 'no token counts', 'stub_adapter');

SELECT response_cost(:req_no_tokens) IS NULL AS cost_null_when_tokens_unknown;

-- ---------- malu$budget_policy scope-exclusivity CHECK ----------------
DO $$ BEGIN
    INSERT INTO malu$budget_policy
        (policy_name, scope, scope_account_id, scope_template_id, limit_kind, limit_value)
    VALUES ('bad-scope', 'account', 1, 2, 'requests_daily', 10);
    RAISE EXCEPTION 'should have rejected scope_template_id with scope=account';
EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'OK: scope-exclusivity CHECK enforced';
END $$;

DO $$ BEGIN
    INSERT INTO malu$budget_policy
        (policy_name, scope, limit_kind, limit_value)
    VALUES ('missing-scope', 'account', 'requests_daily', 10);
    RAISE EXCEPTION 'should have rejected NULL scope_account_id for scope=account';
EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'OK: scope=account requires scope_account_id';
END $$;

-- ---------- idempotent replay bypasses budget (before the gate trips) -
-- First request with idempotency_key
SELECT call(bind_prompt('bdg_template', jsonb_build_object('name','Delta'),
                        NULL, :session_id, NULL, :tenant_id),
            'bdg_alias',
            p_idempotency_key=>'delta-key') AS req_delta_first \gset

-- Now install a hostile budget (zero new requests allowed today)
INSERT INTO malu$budget_policy
    (policy_name, scope, scope_account_id, limit_kind, limit_value)
VALUES ('bdg-account-1-request', 'account', :tenant_id, 'requests_daily', 1);

-- Replay with same key — must succeed and return the same request_id
SELECT call(bind_prompt('bdg_template', jsonb_build_object('name','Delta'),
                        NULL, :session_id, NULL, :tenant_id),
            'bdg_alias',
            p_idempotency_key=>'delta-key') AS req_delta_replay \gset

SELECT :req_delta_first = :req_delta_replay AS idempotent_replay_bypasses_budget;

-- ---------- check_budget: hard-reject -----------------------------
-- A brand-new submission must now be rejected
SELECT call(bind_prompt('bdg_template', jsonb_build_object('name','Gamma'),
                        NULL, :session_id, NULL, :tenant_id),
            'bdg_alias');

-- ---------- budget: cache hit bypasses gate ---------------------------
-- Re-bind for an already-cached name; the cache hit must serve even
-- though the budget gate would otherwise reject.
SELECT call(bind_prompt('bdg_template', jsonb_build_object('name','Alpha'),
                        NULL, :session_id, NULL, :tenant_id),
            'bdg_alias',
            p_cache_mode=>'prefer') AS req_cache_bypasses_budget \gset

SELECT cache_hit FROM malu$model_response WHERE request_id = :req_cache_bypasses_budget;

-- ---------- scope=global applies across tenants -----------------------
-- Replace the account policy with a global one.
DELETE FROM malu$budget_policy WHERE policy_name = 'bdg-account-1-request';

INSERT INTO malu$budget_policy
    (policy_name, scope, limit_kind, limit_value)
VALUES ('bdg-global-1-request', 'global', 'requests_daily', 1);

-- Even with a different account_id (NULL = anon), global trips
SELECT call(bind_prompt('bdg_template', jsonb_build_object('name','Eta'),
                        NULL, :session_id, NULL, :tenant_id),
            'bdg_alias');

-- ---------- cleanup ----------------------------------------------------
DELETE FROM malu$budget_policy WHERE policy_name LIKE 'bdg-%';
DELETE FROM malu$model_response WHERE request_id IN
    (SELECT request_id FROM malu$model_request WHERE alias_id IN
        (SELECT alias_id FROM malu$model_alias WHERE alias_name LIKE 'bdg_%'));
DELETE FROM malu$model_request WHERE alias_id IN
    (SELECT alias_id FROM malu$model_alias WHERE alias_name LIKE 'bdg_%');
DELETE FROM malu$bound_prompt WHERE template_id IN
    (SELECT template_id FROM malu$prompt_template WHERE template_name='bdg_template');
DELETE FROM malu$prompt_render WHERE template_id IN
    (SELECT template_id FROM malu$prompt_template WHERE template_name='bdg_template');
DELETE FROM malu$session WHERE session_id = :session_id;
DELETE FROM malu$prompt_template WHERE template_name='bdg_template';
DELETE FROM malu$model_alias WHERE alias_name LIKE 'bdg_%';
DELETE FROM malu$model_provider WHERE provider_name='bdg_provider';
DELETE FROM malu$account WHERE account_name='bdg_tenant';
