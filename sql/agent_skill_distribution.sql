\set ECHO none
\pset format unaligned
SET client_min_messages = WARNING;
CREATE EXTENSION IF NOT EXISTS maludb_core CASCADE;

SET search_path TO maludb_core, public;

\set ON_ERROR_STOP on

-- =====================================================================
-- agent_skill_distribution -- 0.97.0
--
-- Registered agent skills (Claude Agent Skill bundles) as immutable,
-- multi-file, distributable artifacts:
--   * 'skill' entity subject type seeded (closed entity list admits it)
--   * maludb_skill_register: dedupe on bundle_hash, hash-derived
--     version, extracted discovery tags, bundle-file manifest
--   * supersession: a non-materially-different revision disables its
--     parent; materially different versions stay visible side by side
--   * divergent fork lineage via source_owner_schema / source_skill_id
--   * content immutability once bundle_hash is set
--   * fork_skill copies markdown + bundle (0.73.0 bug fix) and
--     re-anchors file content in the target schema
-- =====================================================================

DO $body$
DECLARE
    v_existing_role name;
BEGIN
    SELECT r.rolname INTO v_existing_role
      FROM pg_catalog.pg_roles r
     WHERE r.rolname = ANY (ARRAY['asd_user_a', 'asd_user_b'])
     LIMIT 1;
    IF v_existing_role IS NOT NULL THEN
        RAISE EXCEPTION 'Refusing to start agent_skill_distribution test: role % already exists',
            v_existing_role;
    END IF;
END;
$body$;

CREATE ROLE asd_user_a NOLOGIN;
CREATE ROLE asd_user_b NOLOGIN;
GRANT maludb_memory_executor TO asd_user_a, asd_user_b;
GRANT USAGE ON SCHEMA maludb_core TO asd_user_a, asd_user_b;
GRANT asd_user_a, asd_user_b TO CURRENT_USER;
CREATE SCHEMA asd_a AUTHORIZATION asd_user_a;
CREATE SCHEMA asd_b AUTHORIZATION asd_user_b;

SET ROLE asd_user_a;
SELECT object_count AS enable_a FROM maludb_core.enable_memory_schema('asd_a');
RESET ROLE;
SET ROLE asd_user_b;
SELECT object_count AS enable_b FROM maludb_core.enable_memory_schema('asd_b');
RESET ROLE;

-- ---- 'skill' entity type is seeded and curated ------------------------
SELECT subject_type, category, system_defined AS curated
  FROM maludb_core.malu$svpor_subject_type
 WHERE subject_type = 'skill';

-- ---- bundle files as source packages ----------------------------------
INSERT INTO maludb_core.malu$source_package(owner_schema, source_type, content_text, content_hash, content_size, media_type)
VALUES ('asd_a', 'skill_file', E'#!/usr/bin/env python3\nprint("extract")\n',
        encode(digest(E'#!/usr/bin/env python3\nprint("extract")\n', 'sha256'), 'hex'), 41, 'text/x-python'),
       ('asd_a', 'skill_file', '| field | meaning |',
        encode(digest('| field | meaning |', 'sha256'), 'hex'), 19, 'text/markdown');

-- ---- register v1 (hash-derived version, tags, files) -------------------
SET ROLE asd_user_a;
SET search_path TO asd_a, maludb_core, public;

SELECT r.report - 'skill_id' AS register_v1
  FROM (SELECT asd_a.maludb_skill_register(
    'pdf-processing',
    E'# PDF processing\nExtract text and tables from PDF files.',
    encode(digest('bundle-v1', 'sha256'), 'hex'),
    'Extract text and tables from PDF files, fill forms. Use when working with PDFs.',
    '{"name":"pdf-processing","license":"Apache-2.0"}'::jsonb,
    NULL,
    ARRAY['pdf','forms','extraction'],
    '[{"name":"pdf file"},{"name":"form"}]'::jsonb,
    '[{"name":"extracts"},{"name":"fills"}]'::jsonb,
    (SELECT jsonb_agg(jsonb_build_object('relative_path',
              CASE WHEN media_type = 'text/x-python' THEN 'scripts/extract.py' ELSE 'references/fields.md' END,
              'source_package_id', source_package_id,
              'is_executable', media_type = 'text/x-python')
            ORDER BY source_package_id)
       FROM maludb_core.malu$source_package
      WHERE owner_schema = 'asd_a' AND source_type = 'skill_file')
  ) AS report) r;

SELECT skill_name, version, enabled,
       (SELECT count(*) FROM asd_a.maludb_skill_file f WHERE f.skill_id = s.skill_id) AS files
  FROM asd_a.maludb_skill s
 WHERE bundle_hash = encode(digest('bundle-v1', 'sha256'), 'hex');

-- frontmatter and provenance landed
SELECT frontmatter_jsonb ->> 'license' AS license
  FROM asd_a.maludb_skill
 WHERE bundle_hash = encode(digest('bundle-v1', 'sha256'), 'hex');
SELECT DISTINCT provenance AS tag_provenance
  FROM maludb_core.malu$skill_verb WHERE owner_schema = 'asd_a';

-- ---- idempotent re-push of the unchanged bundle ------------------------
SELECT (asd_a.maludb_skill_register(
        'pdf-processing', '# PDF processing',
        encode(digest('bundle-v1', 'sha256'), 'hex'))) - 'skill_id' AS repush;

-- ---- non-material revision supersedes its parent -----------------------
SELECT r.report - 'skill_id' - 'superseded_skill_id'
       || jsonb_build_object('superseded', (r.report ? 'superseded_skill_id')) AS register_v2
  FROM (SELECT asd_a.maludb_skill_register(
    'pdf-processing',
    E'# PDF processing\nExtract text and tables from PDF files. (typo fix)',
    encode(digest('bundle-v2', 'sha256'), 'hex'),
    'Extract text and tables from PDF files, fill forms. Use when working with PDFs.',
    '{}'::jsonb, NULL, NULL, NULL, NULL, NULL,
    'asd_a',
    (SELECT skill_id FROM asd_a.maludb_skill WHERE bundle_hash = encode(digest('bundle-v1', 'sha256'), 'hex')),
    false
  ) AS report) r;

SELECT version, enabled
  FROM asd_a.maludb_skill
 WHERE skill_name = 'pdf-processing'
 ORDER BY skill_id;

-- ---- material revision coexists with its parent -------------------------
SELECT r.report - 'skill_id'
       || jsonb_build_object('superseded', (r.report ? 'superseded_skill_id')) AS register_v3
  FROM (SELECT asd_a.maludb_skill_register(
    'pdf-processing',
    E'# PDF processing\nNow also merges and splits PDFs.',
    encode(digest('bundle-v3', 'sha256'), 'hex'),
    'Extract text, merge and split PDF files. Use when working with PDFs.',
    '{}'::jsonb, NULL, NULL, NULL,
    '[{"name":"extracts"},{"name":"merges"}]'::jsonb, NULL,
    'asd_a',
    (SELECT skill_id FROM asd_a.maludb_skill WHERE bundle_hash = encode(digest('bundle-v2', 'sha256'), 'hex')),
    true
  ) AS report) r;

SELECT count(*) AS visible_versions
  FROM asd_a.maludb_skill
 WHERE skill_name = 'pdf-processing' AND enabled;

-- divergent lineage chain (each version points at the row it changed)
SELECT s.version AS version, COALESCE(p.version, 'none') AS parent_version
  FROM asd_a.maludb_skill s
  LEFT JOIN asd_a.maludb_skill p
    ON p.skill_id = s.source_skill_id AND s.source_owner_schema = 'asd_a'
 WHERE s.skill_name = 'pdf-processing'
 ORDER BY s.skill_id;

-- ---- content immutability ------------------------------------------------
DO $body$
BEGIN
    PERFORM set_config('asd.guard', 'did_not_fire', false);
    UPDATE asd_a.maludb_skill SET markdown = 'tampered' WHERE bundle_hash IS NOT NULL;
EXCEPTION WHEN integrity_constraint_violation THEN
    PERFORM set_config('asd.guard', 'fired', false);
END;
$body$;
SELECT current_setting('asd.guard', true) AS immutability_guard;

-- lifecycle columns stay mutable
UPDATE asd_a.maludb_skill SET visibility = 'shared'
 WHERE bundle_hash = encode(digest('bundle-v3', 'sha256'), 'hex');
SELECT count(*) AS lifecycle_update_ok FROM asd_a.maludb_skill WHERE visibility = 'shared';

-- ---- discovery: superseded versions drop out; tags find the live one ----
SELECT count(*) AS verb_hits_superseded_only
  FROM asd_a.maludb_skill_search(NULL, NULL, 'fills');
SELECT skill_name, version, array_to_string(match_reasons, ',') AS reasons
  FROM asd_a.maludb_skill_search(NULL, NULL, 'merges');

-- ---- get_skill: superseded versions are invisible ---------------------------
SELECT count(*) = 0 AS superseded_hidden
  FROM asd_a.maludb_skill_get('asd_a',
       (SELECT skill_id FROM asd_a.maludb_skill WHERE bundle_hash = encode(digest('bundle-v1', 'sha256'), 'hex')));

-- ---- extraction can mint 'skill' subjects (closed entity list) ------------
SELECT (asd_a.maludb_memory_ingest_extraction(
  '{"subjects":[{"key":"s1","name":"pdf-processing","type":"skill","description":"agent skill"}],
    "verbs":[{"name":"extracts"}],
    "edges":[{"subject":"s1","verb":"extracts","object":"s1"}]}'::jsonb,
  'document', NULL, 'suggested')) -> 'created' AS ingest_created;

-- ---- cross-schema fork copies body + bundle --------------------------------
-- (superseded versions are not forkable -- enabled gates _skill_is_visible --
--  so fork a fresh enabled skill that carries bundle files)
SELECT (asd_a.maludb_skill_register(
    'csv-cruncher',
    E'# CSV cruncher\nAnalyze CSV files.',
    encode(digest('csv-bundle-v1', 'sha256'), 'hex'),
    'Analyze CSV files and produce summaries. Use when working with CSV data.',
    '{}'::jsonb, NULL, ARRAY['csv'], NULL, '[{"name":"analyzes"}]'::jsonb,
    (SELECT jsonb_agg(jsonb_build_object('relative_path',
              CASE WHEN media_type = 'text/x-python' THEN 'scripts/crunch.py' ELSE 'references/columns.md' END,
              'source_package_id', source_package_id,
              'is_executable', media_type = 'text/x-python')
            ORDER BY source_package_id)
       FROM maludb_core.malu$source_package
      WHERE owner_schema = 'asd_a' AND source_type = 'skill_file')
)) ->> 'files_linked' AS register_csv_files;

-- get_skill payload carries the bundle manifest for a visible skill
SELECT jsonb_array_length(payload -> 'files') AS payload_files,
       (payload -> 'skill' ->> 'bundle_hash') IS NOT NULL AS payload_hash_set,
       (SELECT count(*) FROM jsonb_array_elements(payload -> 'files') f
         WHERE (f.value ->> 'is_executable')::boolean) AS payload_executables
  FROM asd_a.maludb_skill_get('asd_a',
       (SELECT skill_id FROM asd_a.maludb_skill WHERE skill_name = 'csv-cruncher'));

RESET ROLE;
INSERT INTO maludb_core.malu$skill_access(owner_schema, skill_id, grantee_role, access_level)
SELECT 'asd_a', skill_id, 'asd_user_b', 'fork'
  FROM maludb_core.malu$skill_package
 WHERE owner_schema = 'asd_a' AND skill_name = 'csv-cruncher';

SET ROLE asd_user_b;
SET search_path TO asd_b, maludb_core, public;
SELECT asd_b.maludb_skill_fork('asd_a',
       (SELECT skill_id FROM maludb_core.malu$skill_package
         WHERE owner_schema = 'asd_a' AND skill_name = 'csv-cruncher')) IS NOT NULL AS forked;

SELECT (markdown IS NOT NULL) AS fork_markdown_copied,
       (bundle_hash = encode(digest('csv-bundle-v1', 'sha256'), 'hex')) AS fork_hash_copied,
       (SELECT count(*) FROM asd_b.maludb_skill_file f WHERE f.skill_id = s.skill_id) AS fork_files,
       source_owner_schema AS fork_lineage_schema
  FROM asd_b.maludb_skill s
 WHERE skill_name = 'csv-cruncher';

-- file content re-anchored as packages owned by the target schema
SELECT count(*) AS fork_packages
  FROM maludb_core.malu$source_package
 WHERE owner_schema = 'asd_b' AND source_type = 'skill_file';

-- a forked agent skill is content-immutable too
DO $body$
BEGIN
    PERFORM set_config('asd.guard', 'did_not_fire', false);
    UPDATE asd_b.maludb_skill SET markdown = 'tampered' WHERE skill_name = 'csv-cruncher';
EXCEPTION WHEN integrity_constraint_violation THEN
    PERFORM set_config('asd.guard', 'fired', false);
END;
$body$;
SELECT current_setting('asd.guard', true) AS fork_immutability_guard;

RESET ROLE;

-- ---- cleanup ----------------------------------------------------------------
SET search_path TO maludb_core, public;
DO $body$
DECLARE
    v_schema name;
    v_table text;
BEGIN
    FOREACH v_schema IN ARRAY ARRAY['asd_a','asd_b']::name[]
    LOOP
        -- skill_package cascades keyword/subject/verb/embedding/access/file
        EXECUTE 'DELETE FROM maludb_core."malu$skill_package" WHERE owner_schema = $1' USING v_schema;
        FOREACH v_table IN ARRAY ARRAY[
            'malu$source_package',
            'malu$svpor_attribute',
            'malu$svpor_statement',
            'malu$svpor_subject_relationship_edge',
            'malu$svpor_subject',
            'malu$svpor_verb',
            'malu$enabled_schema_object',
            'malu$enabled_schema'
        ]
        LOOP
            IF to_regclass('maludb_core.' || quote_ident(v_table)) IS NOT NULL THEN
                EXECUTE format('DELETE FROM maludb_core.%I WHERE %s = $1',
                               v_table,
                               CASE WHEN v_table LIKE 'malu$enabled%' THEN 'schema_name' ELSE 'owner_schema' END)
                USING v_schema;
            END IF;
        END LOOP;
    END LOOP;
END;
$body$;
DROP SCHEMA IF EXISTS asd_a CASCADE;
DROP SCHEMA IF EXISTS asd_b CASCADE;
DROP OWNED BY asd_user_a;
DROP OWNED BY asd_user_b;
DROP ROLE asd_user_a;
DROP ROLE asd_user_b;
