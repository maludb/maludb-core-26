-- Stage 2 S2-5 — Cross-tenant object_grant.
--
-- Exercises:
--   * grant_object_access creates rows + upgrade is idempotent
--   * RLS denies cross-schema access without a grant
--   * RLS allows cross-schema SELECT after a 'read' grant
--   * 'write' grant enables UPDATE; 'read' alone does not
--   * revoke_object_grant drops visibility
--   * expires_at past now() drops visibility
--   * grant to self / bad level rejected
--   * list_object_grants returns active + revoked history
--
-- pg_regress runs as superuser; RLS bypasses unless the session is
-- SET ROLE'd to a non-bypassrls role. We create two stand-in tenant
-- roles for the cross-tenant tests.

\set ECHO all
SET search_path = maludb_core, public;
SET client_min_messages = NOTICE;

-- ---------- fixture: two roles, two schemas -------------------------
DROP ROLE   IF EXISTS s2_user_a;
DROP ROLE   IF EXISTS s2_user_b;
DROP SCHEMA IF EXISTS s2_a CASCADE;
DROP SCHEMA IF EXISTS s2_b CASCADE;

CREATE ROLE s2_user_a NOLOGIN;
CREATE ROLE s2_user_b NOLOGIN;
GRANT maludb_memory_executor TO s2_user_a, s2_user_b;
GRANT USAGE ON SCHEMA maludb_core TO s2_user_a, s2_user_b;

CREATE SCHEMA s2_a AUTHORIZATION s2_user_a;
CREATE SCHEMA s2_b AUTHORIZATION s2_user_b;

-- ---------- as tenant A: register a memory --------------------------
SET ROLE s2_user_a;
SET search_path TO s2_a, maludb_core, public;

INSERT INTO maludb_core.malu$memory (owner_schema, memory_kind, title, summary)
VALUES (current_schema(), 'event', 'A: ship event', 'tenant A owns this')
RETURNING memory_id AS mem_a \gset

SELECT count(*) AS visible_to_a_as_self
FROM maludb_core.malu$memory WHERE memory_id = :mem_a;

-- ---------- as tenant B: cannot see it (no grant yet) ---------------
SET ROLE s2_user_b;
SET search_path TO s2_b, maludb_core, public;

SELECT count(*) AS visible_to_b_pre_grant
FROM maludb_core.malu$memory WHERE memory_id = :mem_a;

-- ---------- as tenant A: grant 'read' to B --------------------------
SET ROLE s2_user_a;
SET search_path TO s2_a, maludb_core, public;

SELECT grant_object_access(
    'memory', :mem_a, 's2_b'::name,
    p_grant_level => 'read'
) AS grant_id \gset

-- ---------- as tenant B: SELECT now works ---------------------------
SET ROLE s2_user_b;
SET search_path TO s2_b, maludb_core, public;

SELECT count(*) AS visible_to_b_post_read_grant
FROM maludb_core.malu$memory WHERE memory_id = :mem_a;
SELECT title FROM maludb_core.malu$memory WHERE memory_id = :mem_a;

-- read-level grant cannot UPDATE — the WITH CHECK clause on the
-- grant_visibility policy requires grant_level ∈ {write, full},
-- and an attempted UPDATE raises rather than silently filtering.
UPDATE maludb_core.malu$memory SET summary = 'B tries to edit'
 WHERE memory_id = :mem_a;

-- ---------- as tenant A: upgrade to 'write' -------------------------
SET ROLE s2_user_a;
SET search_path TO s2_a, maludb_core, public;

SELECT grant_object_access(
    'memory', :mem_a, 's2_b'::name,
    p_grant_level => 'write'
) AS grant_id_again \gset

SELECT :grant_id = :grant_id_again AS grant_id_stable_on_upgrade;

-- ---------- as tenant B: UPDATE now works ---------------------------
SET ROLE s2_user_b;
SET search_path TO s2_b, maludb_core, public;

UPDATE maludb_core.malu$memory SET summary = 'edited by B via write grant'
 WHERE memory_id = :mem_a;

-- back to A: see the edit
SET ROLE s2_user_a;
SET search_path TO s2_a, maludb_core, public;
SELECT summary FROM maludb_core.malu$memory WHERE memory_id = :mem_a;

-- ---------- revoke + recheck ----------------------------------------
SELECT revoke_object_grant(:grant_id, 'test revoke') IS NULL AS revoked;

SET ROLE s2_user_b;
SET search_path TO s2_b, maludb_core, public;

SELECT count(*) AS visible_to_b_post_revoke
FROM maludb_core.malu$memory WHERE memory_id = :mem_a;

-- ---------- expires_at gates visibility -----------------------------
SET ROLE s2_user_a;
SET search_path TO s2_a, maludb_core, public;

SELECT grant_object_access(
    'memory', :mem_a, 's2_b'::name,
    p_grant_level => 'read',
    p_expires_at  => now() - interval '1 second',
    p_note        => 'already expired'
) AS expired_grant_id \gset

SET ROLE s2_user_b;
SET search_path TO s2_b, maludb_core, public;
SELECT count(*) AS visible_to_b_with_expired_grant
FROM maludb_core.malu$memory WHERE memory_id = :mem_a;

-- ---------- negative cases ------------------------------------------
SET ROLE s2_user_a;
SET search_path TO s2_a, maludb_core, public;

-- self-grant rejected
SELECT grant_object_access('memory', :mem_a, 's2_a'::name, 'read');

-- bad grant level rejected
SELECT grant_object_access('memory', :mem_a, 's2_b'::name, 'bogus');

-- ---------- list_object_grants returns history ----------------------
SELECT granted_to_schema, grant_level, revoked_at IS NOT NULL AS is_revoked
FROM list_object_grants('memory', :mem_a)
ORDER BY granted_at, grant_id;

-- ---------- cleanup -------------------------------------------------
RESET ROLE;
RESET search_path;
SET search_path TO maludb_core, public;

DELETE FROM malu$object_grant
 WHERE granted_by_schema IN ('s2_a','s2_b');
DELETE FROM malu$memory
 WHERE owner_schema      IN ('s2_a','s2_b');

DROP SCHEMA s2_a CASCADE;
DROP SCHEMA s2_b CASCADE;
-- DROP OWNED first in case the roles still hold privileges on
-- shared catalog objects from the test.
DROP OWNED BY s2_user_a;
DROP OWNED BY s2_user_b;
DROP ROLE   s2_user_a;
DROP ROLE   s2_user_b;
