-- R1.1-10: Idempotency + retry framework.
--
-- Exercises:
--   * idempotency_key NULL (default) preserves R1.0/R1.1 behavior
--   * idempotency_key non-NULL: second submit returns prior request_id
--   * different account, same key → different requests (per-account scope)
--   * idempotency wins over cache_mode (cache check skipped on idempotent hit)
--   * UNIQUE partial index prevents two pending rows with the same key
--   * malu$retry_policy default row seeded; get_retry_policy falls back
--   * per-provider override resolves before the default

\set ECHO all
SET search_path = maludb_core, public;
SET client_min_messages = NOTICE;

-- ---------- fixture ----------------------------------------------------
INSERT INTO malu$account(account_name, account_kind, description) VALUES
    ('idp_tenant_a', 'admin', 'R1.1-10 idempotency tenant A'),
    ('idp_tenant_b', 'admin', 'R1.1-10 idempotency tenant B');

INSERT INTO malu$model_provider (provider_name, provider_kind, adapter_name)
VALUES ('idp_provider', 'stub', 'stub_adapter');
INSERT INTO malu$model_alias (alias_name, provider_id, model_identifier)
VALUES ('idp_alias',
        (SELECT provider_id FROM malu$model_provider WHERE provider_name='idp_provider'),
        'idp-model');

INSERT INTO malu$prompt_template (template_name, body) VALUES
    ('idp_template', 'hello {{name}}');
SELECT declare_prompt_variable('idp_template', 'name', p_required=>true) > 0;

INSERT INTO malu$session (account_id, prompt_template_id)
SELECT account_id, (SELECT template_id FROM malu$prompt_template WHERE template_name='idp_template')
FROM malu$account WHERE account_name='idp_tenant_a'
RETURNING session_id AS session_a \gset

-- ---------- default: NULL key, normal flow -----------------------------
SELECT call(bind_prompt('idp_template', jsonb_build_object('name','Alpha'),
                        NULL, :session_a,
                        NULL, (SELECT account_id FROM malu$account WHERE account_name='idp_tenant_a')),
            'idp_alias') AS req_no_key \gset

SELECT idempotency_key IS NULL AS no_key, attempt_count
FROM malu$model_request WHERE request_id = :req_no_key;

-- ---------- second submit with same key returns prior request ----------
SELECT call(bind_prompt('idp_template', jsonb_build_object('name','Beta'),
                        NULL, :session_a,
                        NULL, (SELECT account_id FROM malu$account WHERE account_name='idp_tenant_a')),
            'idp_alias',
            p_idempotency_key=>'beta-key-1') AS req_first \gset

-- second call with same key → same request_id (no new row)
SELECT call(bind_prompt('idp_template', jsonb_build_object('name','Beta'),
                        NULL, :session_a,
                        NULL, (SELECT account_id FROM malu$account WHERE account_name='idp_tenant_a')),
            'idp_alias',
            p_idempotency_key=>'beta-key-1') AS req_replay \gset

SELECT :req_first = :req_replay AS replay_returns_prior;

-- only one row exists with that key
SELECT count(*) AS rows_with_key
FROM malu$model_request
WHERE idempotency_key = 'beta-key-1';

-- ---------- per-account scope: same key, different tenant -------------
INSERT INTO malu$session (account_id, prompt_template_id)
SELECT account_id, (SELECT template_id FROM malu$prompt_template WHERE template_name='idp_template')
FROM malu$account WHERE account_name='idp_tenant_b'
RETURNING session_id AS session_b \gset

SELECT call(bind_prompt('idp_template', jsonb_build_object('name','Beta'),
                        NULL, :session_b,
                        NULL, (SELECT account_id FROM malu$account WHERE account_name='idp_tenant_b')),
            'idp_alias',
            p_idempotency_key=>'beta-key-1') AS req_tenant_b \gset

SELECT :req_first <> :req_tenant_b AS different_request_per_tenant;

-- ---------- idempotency wins over cache_mode ---------------------------
-- Set up a cached entry, then submit with same key but cache_mode='off'
-- → still returns the prior idempotent request (no cache lookup needed)
UPDATE malu$model_request SET status='succeeded', finished_at=now()
WHERE request_id = :req_first;
INSERT INTO malu$model_response (request_id, status, output_text, prompt_tokens, completion_tokens, adapter_name)
VALUES (:req_first, 'succeeded', 'first reply', 5, 4, 'stub_adapter');

SELECT call(bind_prompt('idp_template', jsonb_build_object('name','Beta'),
                        NULL, :session_a,
                        NULL, (SELECT account_id FROM malu$account WHERE account_name='idp_tenant_a')),
            'idp_alias',
            p_cache_mode=>'prefer',
            p_idempotency_key=>'beta-key-1') AS req_idem_wins \gset

SELECT :req_idem_wins = :req_first AS idem_wins_over_cache;

-- the existing request was NOT modified for cache (it had its own cache_mode='off')
SELECT cache_mode, cache_key IS NULL AS no_cache_key
FROM malu$model_request WHERE request_id = :req_first;

-- ---------- submit_render path --------------------------------------
SELECT render_prompt(:session_a, 'idp_template',
                     p_variables=>jsonb_build_object('name','Gamma')) AS render_g \gset

SELECT submit_render(:render_g, 'idp_alias',
                     p_idempotency_key=>'gamma-key') AS req_sr_first \gset
SELECT submit_render(:render_g, 'idp_alias',
                     p_idempotency_key=>'gamma-key') AS req_sr_replay \gset
SELECT :req_sr_first = :req_sr_replay AS submit_render_replay_returns_prior;

-- ---------- malu$retry_policy seeded ----------------------------------
SELECT max_attempts, backoff_initial_ms, backoff_multiplier, retry_on,
       provider_id IS NULL AS is_default_row
FROM malu$retry_policy ORDER BY policy_id;

-- get_retry_policy falls back to the default row
SELECT (get_retry_policy((SELECT provider_id FROM malu$model_provider WHERE provider_name='idp_provider'))).max_attempts AS default_max;

-- per-provider override takes precedence
INSERT INTO malu$retry_policy (provider_id, max_attempts, backoff_initial_ms,
                               backoff_multiplier, max_backoff_ms, retry_on)
VALUES ((SELECT provider_id FROM malu$model_provider WHERE provider_name='idp_provider'),
        7, 500, 1.5, 30000, ARRAY['timeout']);

SELECT (get_retry_policy((SELECT provider_id FROM malu$model_provider WHERE provider_name='idp_provider'))).max_attempts AS provider_specific_max;

-- ---------- retry policy CHECK constraints ----------------------------
DO $$ BEGIN
    INSERT INTO malu$retry_policy (provider_id, max_attempts)
    VALUES (NULL, 0);
    RAISE EXCEPTION 'should have rejected max_attempts=0';
EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'OK: max_attempts CHECK enforced';
END $$;

DO $$ BEGIN
    INSERT INTO malu$retry_policy (provider_id, max_attempts)
    VALUES (NULL, 11);
    RAISE EXCEPTION 'should have rejected max_attempts=11';
EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'OK: max_attempts upper bound enforced';
END $$;

-- ---------- cleanup ----------------------------------------------------
DELETE FROM malu$retry_policy WHERE provider_id =
    (SELECT provider_id FROM malu$model_provider WHERE provider_name='idp_provider');
DELETE FROM malu$model_response WHERE request_id IN
    (SELECT request_id FROM malu$model_request WHERE alias_id =
        (SELECT alias_id FROM malu$model_alias WHERE alias_name='idp_alias'));
DELETE FROM malu$model_request WHERE alias_id =
    (SELECT alias_id FROM malu$model_alias WHERE alias_name='idp_alias');
DELETE FROM malu$bound_prompt WHERE template_id IN
    (SELECT template_id FROM malu$prompt_template WHERE template_name='idp_template');
DELETE FROM malu$prompt_render WHERE template_id IN
    (SELECT template_id FROM malu$prompt_template WHERE template_name='idp_template');
DELETE FROM malu$session WHERE session_id IN (:session_a, :session_b);
DELETE FROM malu$prompt_template WHERE template_name='idp_template';
DELETE FROM malu$model_alias WHERE alias_name='idp_alias';
DELETE FROM malu$model_provider WHERE provider_name='idp_provider';
DELETE FROM malu$account WHERE account_name IN ('idp_tenant_a','idp_tenant_b');
