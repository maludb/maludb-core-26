-- V3-AUTH-01 — auth_token catalog + verifier regression coverage.
--
-- Exercises: create / verify / revoke / expire / CIDR / RLS / audit /
-- jwt_verify stub. Runs as the regression superuser (BYPASSRLS) for
-- seeding, then SET SESSION AUTHORIZATION into a non-superuser PG role
-- to exercise the RLS policies under GUC-driven tenancy.

SET search_path TO maludb_core, public;

-- ---------------------------------------------------------------------
-- Setup. Two test accounts and a non-superuser PG role.
-- ---------------------------------------------------------------------
INSERT INTO malu$account(account_name, account_kind, description) VALUES
    ('auth_alice', 'service', 'V3-AUTH-01 test tenant alice'),
    ('auth_bob',   'service', 'V3-AUTH-01 test tenant bob');

SELECT account_id AS alice_id
FROM malu$account WHERE account_name='auth_alice' \gset
SELECT account_id AS bob_id
FROM malu$account WHERE account_name='auth_bob' \gset

DO $body$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'auth_test_user') THEN
        CREATE ROLE auth_test_user LOGIN;
    END IF;
END;
$body$;
GRANT maludb_memory_executor TO auth_test_user;

-- ---------------------------------------------------------------------
-- Test 1: create a token for alice. Plaintext is returned exactly once,
-- starts with `mldbat_`, length matches the base64url-of-32-bytes shape.
-- The hash-persisted check runs in a SEPARATE statement so the EXISTS
-- subquery sees the inserted row (PostgreSQL snapshot rules forbid the
-- same statement seeing rows that statement just INSERTed).
-- ---------------------------------------------------------------------
SELECT *
FROM auth_token_create(
    :'alice_id'::bigint,
    'personal',
    'alice cli token',
    ARRAY['retrieve','replay']::text[]) \gset cli_

SELECT
    :'cli_token_id'::bigint > 0                       AS token_id_assigned,
    :'cli_plaintext_token' LIKE 'mldbat_%'            AS prefix_ok,
    length(:'cli_plaintext_token') = 50               AS length_50,
    octet_length(t.token_hash) = 32                   AS hash_is_sha256,
    t.scopes                                          AS scopes_persisted,
    t.token_kind                                      AS kind_persisted
FROM malu$auth_token t WHERE t.token_id = :'cli_token_id'::bigint;

-- Issue a second token whose plaintext we capture for verify / revoke
-- tests further down. \gset prefixes column names with `tok_`.
SELECT *
FROM auth_token_create(
    :'alice_id'::bigint,
    'personal',
    'alice verify token',
    ARRAY['retrieve']::text[]) \gset tok_

-- ---------------------------------------------------------------------
-- Test 2: verify the just-created plaintext, expect a row back keyed
-- to alice with the registered scopes.
-- ---------------------------------------------------------------------
SELECT v.account_id = :'alice_id'::bigint            AS verifies_to_alice,
       v.token_kind                                  AS kind,
       v.scopes                                      AS scopes
FROM auth_token_verify(:'tok_plaintext_token') v;

-- ---------------------------------------------------------------------
-- Test 3: garbage plaintext returns zero rows.
-- ---------------------------------------------------------------------
SELECT count(*) AS rows_for_garbage_token
FROM auth_token_verify('mldbat_definitely_not_a_real_token_xxxxxxxxxxxxx');

-- ---------------------------------------------------------------------
-- Test 4: revoke the alice verify token; the next auth_token_verify
-- call must return zero rows and a malu$auth_token_use row with
-- outcome = 'rejected_revoked' must appear.
-- ---------------------------------------------------------------------
SELECT auth_token_revoke(:'tok_token_id'::bigint, 'test 4 revoke')
    AS revoked_was_active;

SELECT count(*) AS rows_after_revoke
FROM auth_token_verify(:'tok_plaintext_token');

SELECT outcome
FROM malu$auth_token_use
WHERE token_id = :'tok_token_id'::bigint
ORDER BY used_at DESC
LIMIT 1;

-- ---------------------------------------------------------------------
-- Test 5: expired token. Create with a future expiry (CHECK requires
-- expires_at > created_at), then back-date both columns as superuser.
-- ---------------------------------------------------------------------
SELECT *
FROM auth_token_create(
    :'alice_id'::bigint,
    'personal',
    'alice expired token',
    ARRAY[]::text[],
    NULL,
    now() + interval '1 day') \gset exp_

UPDATE malu$auth_token
   SET created_at = now() - interval '1 hour',
       expires_at = now() - interval '1 minute'
 WHERE token_id = :'exp_token_id'::bigint;

SELECT count(*) AS rows_after_expiry
FROM auth_token_verify(:'exp_plaintext_token');

SELECT outcome
FROM malu$auth_token_use
WHERE token_id = :'exp_token_id'::bigint
ORDER BY used_at DESC
LIMIT 1;

-- ---------------------------------------------------------------------
-- Test 6: CIDR allow-list. Token allows 10.0.0.0/8 only.
--   * verify from 10.1.2.3   → accepted
--   * verify from 192.168.1.1 → rejected_cidr
-- ---------------------------------------------------------------------
SELECT *
FROM auth_token_create(
    :'alice_id'::bigint,
    'service',
    'alice cidr token',
    ARRAY[]::text[],
    ARRAY['10.0.0.0/8']::inet[]) \gset cidr_

SELECT count(*) AS rows_inside_cidr
FROM auth_token_verify(:'cidr_plaintext_token', '10.1.2.3'::inet);

SELECT count(*) AS rows_outside_cidr
FROM auth_token_verify(:'cidr_plaintext_token', '192.168.1.1'::inet);

SELECT outcome
FROM malu$auth_token_use
WHERE token_id = :'cidr_token_id'::bigint
ORDER BY used_at DESC
LIMIT 1;

-- ---------------------------------------------------------------------
-- Test 7: RLS isolation. Bind the GUC to alice via maludb_memory_executor
-- (a non-BYPASSRLS role) and confirm bob's seed token is invisible.
-- malu$auth_token grants SELECT to maludb_memory_executor in this
-- migration; malu$account does not, so account_ids are captured in
-- psql variables before the role switch.
-- ---------------------------------------------------------------------
INSERT INTO malu$auth_token(account_id, token_hash, token_kind, label)
VALUES (:'bob_id'::bigint,
        sha256('bob-rls-seed'::bytea),
        'service',
        'bob seed token');

SET SESSION AUTHORIZATION auth_test_user;

SELECT set_config('maludb_core.current_account_id',
                  :'alice_id'::text, false) IS NOT NULL AS guc_set_alice;

SELECT count(*) > 0   AS alice_sees_own_tokens,
       count(*) FILTER (WHERE account_id <> :'alice_id'::bigint)
                       AS foreign_rows_visible
FROM malu$auth_token;

SELECT set_config('maludb_core.current_account_id',
                  :'bob_id'::text, false) IS NOT NULL AS guc_set_bob;

SELECT count(*) AS bob_visible_count
FROM malu$auth_token;

RESET SESSION AUTHORIZATION;
RESET maludb_core.current_account_id;

-- ---------------------------------------------------------------------
-- Test 8: jwt_verify (V3-AUTH-02). The C verifier ships in 0.63.0 with
-- HS256 fully implemented and RS/ES/EdDSA branches still raising
-- feature_not_supported (SQLSTATE 0A000). Register an RS256 key so the
-- verifier can dispatch past the kid check and hit the unsupported-
-- algorithm branch.
-- ---------------------------------------------------------------------
INSERT INTO malu$jwt_signing_key(kid, kty, alg, public_jwk)
VALUES ('auth-token-test-rs256', 'RSA', 'RS256', '{"n":"x","e":"AQAB"}'::jsonb)
ON CONFLICT (kid) DO UPDATE
    SET public_jwk = EXCLUDED.public_jwk, enabled = true;

DO $body$
DECLARE
    v_header  text := translate(encode(convert_to(
        '{"alg":"RS256","kid":"auth-token-test-rs256"}', 'UTF8'),
        'base64'), E'+/=\n', '-_');
    v_payload text := translate(encode(convert_to(
        '{"account_id":"1"}', 'UTF8'),
        'base64'), E'+/=\n', '-_');
BEGIN
    PERFORM * FROM jwt_verify(v_header || '.' || v_payload || '.' || 'AAAA');
    RAISE EXCEPTION 'jwt_verify did not raise (test 8 fail)';
EXCEPTION WHEN feature_not_supported THEN
    RAISE NOTICE 'jwt_verify correctly raised feature_not_supported';
END;
$body$;

DELETE FROM malu$jwt_signing_key WHERE kid = 'auth-token-test-rs256';

-- ---------------------------------------------------------------------
-- Test 9: audit_event coverage. Every create / revoke / verify (accept
-- and reject) must have produced a malu$audit_event row.
-- ---------------------------------------------------------------------
SELECT event_kind, count(*) AS n
FROM malu$audit_event
WHERE event_kind LIKE 'auth_token_%'
GROUP BY event_kind
ORDER BY event_kind;

-- ---------------------------------------------------------------------
-- Cleanup.
-- ---------------------------------------------------------------------
DELETE FROM malu$auth_token_use
WHERE token_id IN (
    SELECT token_id FROM malu$auth_token
     WHERE account_id IN (:'alice_id'::bigint, :'bob_id'::bigint)
);

DELETE FROM malu$auth_token
WHERE account_id IN (:'alice_id'::bigint, :'bob_id'::bigint);

DELETE FROM malu$audit_event WHERE event_kind LIKE 'auth_token_%';

REVOKE maludb_memory_executor FROM auth_test_user;
DROP ROLE auth_test_user;

DELETE FROM malu$account WHERE account_name IN ('auth_alice','auth_bob');
