\set ECHO none
\pset format unaligned
SET client_min_messages = WARNING;
CREATE EXTENSION IF NOT EXISTS maludb_core CASCADE;

SET search_path TO maludb_core, public;

\set ON_ERROR_STOP on

-- Refuse to run against a non-test role of the same name.
DO $body$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'skr_user_a') THEN
        RAISE EXCEPTION 'Refusing to start skill_reindex test: role skr_user_a already exists';
    END IF;
END;
$body$;

DROP SCHEMA IF EXISTS skr_a CASCADE;
DROP ROLE IF EXISTS skr_user_a;

SET client_min_messages = NOTICE;

CREATE ROLE skr_user_a NOLOGIN;
COMMENT ON ROLE skr_user_a IS 'maludb skill_reindex regression test role';
GRANT maludb_memory_executor TO skr_user_a;
GRANT USAGE ON SCHEMA maludb_core TO skr_user_a;

CREATE SCHEMA skr_a AUTHORIZATION skr_user_a;

-- 0990 facades push the object count past the 0.97.0/0.98.0 baseline.
SELECT object_count >= 56 AS skr_a_enabled
FROM maludb_core.enable_memory_schema('skr_a');

SET ROLE skr_user_a;
SET search_path TO skr_a, maludb_core, public;

-- A real registry verb so the tenant has a reindex watermark
-- (max(created_at) over svpor subjects/verbs). Created BEFORE the first
-- index, so its timestamp is older than last_indexed after apply.
INSERT INTO maludb_verb(canonical_name) VALUES ('reconcile');

-- Register a skill the way the API would, but with deliberately weak /
-- wrong machine-extracted discovery tags (the "poor load" case).
SELECT (maludb_skill_register(
    p_skill_name => 'skr_invoice_helper',
    p_markdown   => '# Invoice helper. Reconcile invoices against purchase orders.',
    p_bundle_hash => repeat('a', 64),
    p_description => 'Reconcile invoices against purchase orders.',
    p_keywords   => ARRAY['misc'],
    p_subjects   => '[{"name":"genericdoc"}]'::jsonb,
    p_verbs      => '[{"name":"process"}]'::jsonb
) ->> 'skill_id')::bigint AS skr_skill_id \gset

-- A curator-authored 'manual' tag that reindex must never disturb.
INSERT INTO maludb_skill_subject(skill_id, subject_name, weight)
VALUES (:'skr_skill_id'::bigint, 'curated topic', 1.0);

-- (A) Never-indexed skill is claimed for reindexing.
SELECT count(*) = 1 AS claim_picks_unindexed
FROM maludb_skill_reindex_claim()
WHERE skill_id = :'skr_skill_id'::bigint;

-- (A2) The claim hands the worker the body + current tag set.
SELECT markdown IS NOT NULL AS claim_returns_body,
       current_subjects @> '[{"name":"genericdoc"}]'::jsonb AS claim_returns_old_subject,
       current_subjects @> '[{"name":"curated topic"}]'::jsonb AS claim_returns_manual_subject
FROM maludb_skill_reindex_claim()
WHERE skill_id = :'skr_skill_id'::bigint;

-- Apply a corrected extraction (the worker's job), naming the model.
WITH r AS (
    SELECT maludb_skill_reindex_apply(
        p_skill_id => :'skr_skill_id'::bigint,
        p_subjects => '[{"name":"invoice reconciliation"}]'::jsonb,
        p_verbs    => '[{"name":"reconcile"}]'::jsonb,
        p_keywords => ARRAY['accounts payable'],
        p_model    => 'claude-opus-4-8'
    ) AS j
)
SELECT (j->'replaced'->>'subjects')::int AS replaced_subjects,
       (j->'written'->>'subjects')::int  AS written_subjects,
       (j->'replaced'->>'verbs')::int     AS replaced_verbs,
       (j->'replaced'->>'keywords')::int  AS replaced_keywords,
       j->>'last_indexed_model'           AS model
FROM r;

-- (B) Replace-extracted semantics, verified at the core tables (which
--     expose provenance). Done as superuser.
RESET ROLE;
SET search_path TO maludb_core, public;

SELECT bool_or(subject_name = 'invoice reconciliation' AND provenance = 'extracted') AS has_new_extracted_subject,
       bool_or(subject_name = 'curated topic'          AND provenance = 'manual')    AS keeps_manual_subject,
       NOT bool_or(subject_name = 'genericdoc')                                       AS dropped_old_extracted_subject
FROM maludb_core.malu$skill_subject
WHERE owner_schema = 'skr_a' AND skill_id = :'skr_skill_id'::bigint;

SELECT bool_or(verb_name = 'reconcile' AND provenance = 'extracted') AS has_new_extracted_verb,
       NOT bool_or(verb_name = 'process')                            AS dropped_old_extracted_verb
FROM maludb_core.malu$skill_verb
WHERE owner_schema = 'skr_a' AND skill_id = :'skr_skill_id'::bigint;

SELECT bool_or(keyword = 'accounts payable') AS has_new_keyword,
       NOT bool_or(keyword = 'misc')          AS dropped_old_keyword
FROM maludb_core.malu$skill_keyword
WHERE owner_schema = 'skr_a' AND skill_id = :'skr_skill_id'::bigint;

-- last_indexed / last_indexed_model stamped (UPDATE survived the
-- 0.97.0 content-immutability guard, which only freezes content cols).
SELECT last_indexed IS NOT NULL AS last_indexed_stamped,
       last_indexed_model       AS last_indexed_model
FROM maludb_core.malu$skill_package
WHERE owner_schema = 'skr_a' AND skill_id = :'skr_skill_id'::bigint;

-- (C) find_skill's high-weight subject facet now fires on the reindexed
--     tag (the discovery win).
SET ROLE skr_user_a;
SET search_path TO skr_a, maludb_core, public;

SELECT bool_or(score >= 100)                      AS subject_facet_scored,
       bool_or('subject' = ANY(match_reasons))    AS match_reason_has_subject
FROM maludb_skill_search(p_query => '', p_subject => 'invoice reconciliation', p_limit => 10)
WHERE owner_schema = 'skr_a' AND skill_id = :'skr_skill_id'::bigint;

-- (D) A freshly-indexed skill is NOT reclaimed: last_indexed (now) is
--     newer than both the max_age cutoff and the registry watermark.
SELECT count(*) = 0 AS reindexed_skill_not_reclaimed
FROM maludb_skill_reindex_claim()
WHERE skill_id = :'skr_skill_id'::bigint;

-- (E) Registry-aware re-pick: backdate last_indexed so it predates the
--     'reconcile' verb's created_at -> the watermark clause re-selects it
--     even though it is well within max_age.
RESET ROLE;
SET search_path TO maludb_core, public;
UPDATE maludb_core.malu$skill_package
   SET last_indexed = now() - interval '1 hour'
 WHERE owner_schema = 'skr_a' AND skill_id = :'skr_skill_id'::bigint;

SET ROLE skr_user_a;
SET search_path TO skr_a, maludb_core, public;

SELECT count(*) = 1 AS stale_skill_reclaimed_by_watermark
FROM maludb_skill_reindex_claim()
WHERE skill_id = :'skr_skill_id'::bigint;

-- Teardown.
RESET ROLE;
SET search_path TO maludb_core, public;
SET client_min_messages = WARNING;
\unset ON_ERROR_STOP
DROP SCHEMA IF EXISTS skr_a CASCADE;
DO $body$
DECLARE
    v_table text;
    v_tables text[] := ARRAY[
        'malu$skill_access','malu$skill_embedding','malu$skill_keyword',
        'malu$skill_subject','malu$skill_verb','malu$skill_execution_step',
        'malu$skill_execution_record','malu$skill_transition','malu$skill_state',
        'malu$skill_package'
    ];
BEGIN
    FOREACH v_table IN ARRAY v_tables LOOP
        IF to_regclass('maludb_core.' || quote_ident(v_table)) IS NOT NULL THEN
            EXECUTE format('DELETE FROM maludb_core.%I WHERE owner_schema = $1', v_table)
            USING 'skr_a';
        END IF;
    END LOOP;
    IF to_regclass('maludb_core.malu$svpor_subject') IS NOT NULL THEN
        EXECUTE 'DELETE FROM maludb_core."malu$svpor_subject" WHERE owner_schema = $1' USING 'skr_a';
    END IF;
    IF to_regclass('maludb_core.malu$svpor_verb') IS NOT NULL THEN
        EXECUTE 'DELETE FROM maludb_core."malu$svpor_verb" WHERE owner_schema = $1' USING 'skr_a';
    END IF;
    IF to_regclass('maludb_core.malu$enabled_schema_object') IS NOT NULL THEN
        EXECUTE 'DELETE FROM maludb_core."malu$enabled_schema_object" WHERE schema_name = $1' USING 'skr_a';
    END IF;
    IF to_regclass('maludb_core.malu$enabled_schema') IS NOT NULL THEN
        EXECUTE 'DELETE FROM maludb_core."malu$enabled_schema" WHERE schema_name = $1' USING 'skr_a';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'skr_user_a') THEN
        DROP OWNED BY skr_user_a;
    END IF;
END;
$body$;
DROP ROLE IF EXISTS skr_user_a;
