-- R1.1-7 LLM roles + RLS verification.
--
-- Runs as the regression superuser; sets up two test tenants and a
-- non-superuser PG role, then SWITCHes into that role to exercise the
-- RLS policies under each binding mode.

SET search_path TO maludb_core, public;

-- ---------------------------------------------------------------------
-- Setup. Inserts happen as superuser → RLS bypassed → seeds land
-- regardless of policy.
-- ---------------------------------------------------------------------

INSERT INTO malu$account(account_name, account_kind, description) VALUES
    ('rls_tenant_a', 'service', 'RLS test tenant A'),
    ('rls_tenant_b', 'service', 'RLS test tenant B'),
    ('rls_test_user', 'service', 'session_user-fallback test account');

-- Tenant-bound sessions
INSERT INTO malu$session(account_id, lifecycle_state)
SELECT account_id, 'open' FROM malu$account
WHERE account_name IN ('rls_tenant_a','rls_tenant_b','rls_test_user');

-- Tenant-bound prompt templates (one private per tenant + one shared)
INSERT INTO malu$prompt_template(template_name, template_version, owner_account_id, body)
SELECT 'rls_priv_'||account_name, 1, account_id, 'private template for ' || account_name
FROM malu$account
WHERE account_name IN ('rls_tenant_a','rls_tenant_b');

INSERT INTO malu$prompt_template(template_name, template_version, owner_account_id, body)
VALUES ('rls_shared', 1, NULL, 'shared template (no owner)');

-- Test PG role. Idempotent so reruns work.
DO $body$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'rls_test_user') THEN
        CREATE ROLE rls_test_user LOGIN;
    END IF;
END;
$body$;
GRANT maludb_llm_executor TO rls_test_user;

-- ---------------------------------------------------------------------
-- Test 1: GUC-driven tenancy. Switch into the test role, set the GUC
-- to tenant A, expect to see only A's session.
-- ---------------------------------------------------------------------
SET SESSION AUTHORIZATION rls_test_user;

SELECT set_config('maludb_core.current_account_id',
    (SELECT account_id::text FROM malu$account WHERE account_name='rls_tenant_a'),
    false) IS NOT NULL AS guc_set;

SELECT a.account_name, count(s.session_id) AS visible_sessions
FROM malu$account a
LEFT JOIN malu$session s ON s.account_id = a.account_id
WHERE a.account_name LIKE 'rls_tenant_%'
GROUP BY a.account_name
ORDER BY a.account_name;

-- Templates: tenant A sees its private + the shared one (NULL owner).
SELECT template_name, owner_account_id IS NULL AS is_shared
FROM malu$prompt_template
WHERE template_name LIKE 'rls_%'
ORDER BY template_name;

-- ---------------------------------------------------------------------
-- Test 2: switch GUC to tenant B; visibility flips.
-- ---------------------------------------------------------------------
SELECT set_config('maludb_core.current_account_id',
    (SELECT account_id::text FROM malu$account WHERE account_name='rls_tenant_b'),
    false) IS NOT NULL AS guc_set;

SELECT a.account_name, count(s.session_id) AS visible_sessions
FROM malu$account a
LEFT JOIN malu$session s ON s.account_id = a.account_id
WHERE a.account_name LIKE 'rls_tenant_%'
GROUP BY a.account_name
ORDER BY a.account_name;

-- ---------------------------------------------------------------------
-- Test 3: WITH CHECK enforcement. As tenant A, try to INSERT a session
-- for tenant B — must fail.
-- ---------------------------------------------------------------------
SELECT set_config('maludb_core.current_account_id',
    (SELECT account_id::text FROM malu$account WHERE account_name='rls_tenant_a'),
    false) IS NOT NULL AS guc_set;

INSERT INTO malu$session(account_id, lifecycle_state)
SELECT account_id, 'open' FROM malu$account WHERE account_name='rls_tenant_b';

-- ---------------------------------------------------------------------
-- Test 4: session_user fallback. Reset the GUC; current_account_id()
-- now resolves rls_test_user → the seeded account of the same name.
-- That account has no sessions, so visible_sessions = 0 for both
-- rls_tenant_* rows (they belong to different account_ids).
-- ---------------------------------------------------------------------
RESET maludb_core.current_account_id;

SELECT current_account_id() =
       (SELECT account_id FROM malu$account WHERE account_name='rls_test_user')
       AS session_user_fallback_resolves;

SELECT a.account_name, count(s.session_id) AS visible_sessions
FROM malu$account a
LEFT JOIN malu$session s ON s.account_id = a.account_id
WHERE a.account_name LIKE 'rls_tenant_%'
GROUP BY a.account_name
ORDER BY a.account_name;

-- ---------------------------------------------------------------------
-- Test 5: back to superuser; verify BYPASSRLS sees both tenants.
-- ---------------------------------------------------------------------
RESET SESSION AUTHORIZATION;

SELECT a.account_name, count(s.session_id) AS visible_sessions
FROM malu$account a
LEFT JOIN malu$session s ON s.account_id = a.account_id
WHERE a.account_name LIKE 'rls_tenant_%'
GROUP BY a.account_name
ORDER BY a.account_name;

-- ---------------------------------------------------------------------
-- Cleanup.
-- ---------------------------------------------------------------------
REVOKE maludb_llm_executor FROM rls_test_user;
DROP ROLE rls_test_user;

DELETE FROM malu$session
WHERE account_id IN (SELECT account_id FROM malu$account
                     WHERE account_name IN ('rls_tenant_a','rls_tenant_b','rls_test_user'));

DELETE FROM malu$prompt_template WHERE template_name LIKE 'rls_%';

DELETE FROM malu$account
WHERE account_name IN ('rls_tenant_a','rls_tenant_b','rls_test_user');
