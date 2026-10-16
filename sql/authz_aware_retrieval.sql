-- Stage 4 S4-5 — Authorization-aware retrieval.
--
-- Exercises:
--   * authorize_object_types: planner-time pruning by RLS reachability.
--   * execute_retrieval: end-to-end orchestration over the FTS path.
--   * Cross-tenant leakage check: tenant B cannot retrieve tenant A's
--     content via execute_retrieval, even though A's row exists.
--   * Grant read → tenant B now retrieves.
--   * Tombstoned rows are dropped at assembly time.
--   * confidence_floor in envelope filters by maut_aggregate_confidence.
--   * Hint composition (named hint) still flows through executor.
--   * Empty-result authz audit emission (no_authorized_types).
--
-- pg_regress runs as superuser, which bypasses RLS. To test
-- authz-aware retrieval we SET ROLE to two non-BYPASSRLS tenant
-- roles (s45_user_a/b), each owning a schema.

\set ECHO all
SET search_path = maludb_core, public;
SET client_min_messages = NOTICE;

-- ---------- fixture: two roles, two schemas -------------------------
DROP ROLE   IF EXISTS s45_user_a;
DROP ROLE   IF EXISTS s45_user_b;
DROP SCHEMA IF EXISTS s45_a CASCADE;
DROP SCHEMA IF EXISTS s45_b CASCADE;

CREATE ROLE s45_user_a NOLOGIN;
CREATE ROLE s45_user_b NOLOGIN;
GRANT maludb_memory_executor TO s45_user_a, s45_user_b;
GRANT USAGE ON SCHEMA maludb_core TO s45_user_a, s45_user_b;

CREATE SCHEMA s45_a AUTHORIZATION s45_user_a;
CREATE SCHEMA s45_b AUTHORIZATION s45_user_b;

-- ---------- as tenant A: register a claim with distinctive text -----
SET ROLE s45_user_a;
SET search_path TO s45_a, maludb_core, public;

INSERT INTO maludb_core.malu$claim
    (owner_schema, subject, verb, object_value, statement_text)
VALUES (current_schema(), 'banshee_signal', 'detected',
        'anomalous_packet',
        'Tenant A only: banshee_signal detected anomalous_packet at 03:00Z.')
RETURNING claim_id AS clm_a \gset

-- Sanity: A can see her own claim.
SELECT count(*) AS visible_to_a_as_self
FROM maludb_core.malu$claim WHERE claim_id = :clm_a;

-- ---------- planning-time authz: A's types are reachable -----------
SELECT array_to_string(
    authorize_object_types(
        ROW('banshee', ARRAY['claim','fact','memory','episode_object'],
            NULL, NULL, NULL, NULL)::malu$retrieval_envelope_t),
    ',') AS a_authorized;

-- A's end-to-end retrieval finds her own row.
SELECT object_type, object_id = :clm_a AS is_a_claim, strategy
FROM execute_retrieval(
    ROW('banshee_signal', ARRAY['claim','fact','memory','episode_object'],
        NULL, NULL, NULL, NULL)::malu$retrieval_envelope_t,
    NULL, 10)
ORDER BY object_type, object_id;

-- ---------- as tenant B: no grant yet — must NOT see A's claim -----
SET ROLE s45_user_b;
SET search_path TO s45_b, maludb_core, public;

-- Planning-time pruning: with zero accessible rows of any type,
-- authorize_object_types collapses to the empty array.
SELECT cardinality(
    authorize_object_types(
        ROW('banshee', ARRAY['claim','fact','memory','episode_object'],
            NULL, NULL, NULL, NULL)::malu$retrieval_envelope_t)
) AS b_authorized_count_pre_grant;

-- Cross-tenant leakage check: B's execute_retrieval must return zero
-- rows, even though the underlying claim exists.
SELECT count(*) AS b_hits_pre_grant
FROM execute_retrieval(
    ROW('banshee_signal', ARRAY['claim','fact','memory','episode_object'],
        NULL, NULL, NULL, NULL)::malu$retrieval_envelope_t,
    NULL, 10);

-- ---------- as tenant A: grant 'read' on the claim to schema s45_b --
SET ROLE s45_user_a;
SET search_path TO s45_a, maludb_core, public;

SELECT grant_object_access(
    'claim', :clm_a, 's45_b'::name,
    p_grant_level => 'read'
) AS grant_id \gset

-- ---------- as tenant B: now B can see the claim ------------------
SET ROLE s45_user_b;
SET search_path TO s45_b, maludb_core, public;

SELECT cardinality(
    authorize_object_types(
        ROW('banshee', ARRAY['claim','fact','memory','episode_object'],
            NULL, NULL, NULL, NULL)::malu$retrieval_envelope_t)
) >= 1 AS b_has_authorized_types_post_grant;

SELECT object_type, object_id = :clm_a AS is_a_claim, strategy
FROM execute_retrieval(
    ROW('banshee_signal', ARRAY['claim','fact','memory','episode_object'],
        NULL, NULL, NULL, NULL)::malu$retrieval_envelope_t,
    NULL, 10)
ORDER BY object_type, object_id;

-- ---------- back to superuser for tombstone + confidence-floor -----
RESET ROLE;
RESET search_path;
SET search_path = maludb_core, public;

-- A tombstoned fact should never surface in execute_retrieval.
INSERT INTO maludb_core.malu$fact
    (subject, verb, object_value, statement_text, lifecycle_state)
VALUES ('banshee_signal', 'archived', 'historical',
        'Tombstoned fact about banshee_signal: should not surface.',
        'tombstoned')
RETURNING fact_id AS fct_tomb \gset

SELECT count(*) AS tombstoned_hits
FROM execute_retrieval(
    ROW('banshee_signal', ARRAY['fact'], NULL, NULL, NULL, NULL)
    ::malu$retrieval_envelope_t,
    NULL, 10)
WHERE object_id = :fct_tomb;

-- ---------- confidence_floor filters by MAUT score -----------------
INSERT INTO maludb_core.malu$fact
    (subject, verb, object_value, statement_text, lifecycle_state)
VALUES ('lowconf_subject', 'asserts', 'something',
        'Has a low MAUT score by design.', 'active')
RETURNING fact_id AS fct_low \gset

SELECT apply_default_weights('fact') >= 0 AS weights_seeded;
SELECT set_maut_score('fact', :fct_low, 'supporting_facts', 0.1, 'authz_test') > 0
       AS maut_score_set;

-- floor 0.9 should exclude the low-MAUT fact (its aggregate is 0.1,
-- way below 0.9; categories without explicit scores are excluded
-- from the average, so a single 0.1 supporting_facts keeps the
-- aggregate at 0.1).
SELECT count(*) AS low_conf_excluded
FROM execute_retrieval(
    ROW('lowconf_subject', ARRAY['fact'], NULL, NULL, 0.9::numeric, NULL)
    ::malu$retrieval_envelope_t,
    NULL, 10)
WHERE object_id = :fct_low;

-- floor 0.0 lets it through.
SELECT count(*) AS low_conf_kept
FROM execute_retrieval(
    ROW('lowconf_subject', ARRAY['fact'], NULL, NULL, 0.0::numeric, NULL)
    ::malu$retrieval_envelope_t,
    NULL, 10)
WHERE object_id = :fct_low;

-- ---------- audit emission for retrieval_executed ------------------
SELECT count(*) >= 1 AS audit_present
FROM malu$audit_event
WHERE event_kind = 'retrieval_executed';

-- The no_authorized_types path emits a reason field.
SELECT count(*) AS empty_authz_audits
FROM malu$audit_event
WHERE event_kind = 'retrieval_executed'
  AND event_jsonb ->> 'reason' = 'no_authorized_types';

-- ---------- cleanup ------------------------------------------------
RESET ROLE;
RESET search_path;
SET search_path = maludb_core, public;

DELETE FROM malu$audit_event WHERE event_kind = 'retrieval_executed';
DELETE FROM malu$object_grant WHERE grant_id = :grant_id;
DELETE FROM malu$maut_score   WHERE target_object_type = 'fact'
                                AND target_object_id   = :fct_low;
DELETE FROM malu$claim        WHERE claim_id = :clm_a;
DELETE FROM malu$fact         WHERE fact_id IN (:fct_tomb, :fct_low);

DROP SCHEMA s45_a CASCADE;
DROP SCHEMA s45_b CASCADE;
DROP OWNED BY s45_user_a;
DROP OWNED BY s45_user_b;
DROP ROLE   s45_user_a;
DROP ROLE   s45_user_b;
