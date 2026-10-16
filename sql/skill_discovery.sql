\set ECHO none
\pset format unaligned
SET client_min_messages = WARNING;
CREATE EXTENSION IF NOT EXISTS maludb_core CASCADE;

SET search_path TO maludb_core, public;

\set ON_ERROR_STOP on
DO $body$
DECLARE
    v_schema name;
    v_expected_owner name;
    v_public_schema constant name := 'maludb_public';
    v_public_owner constant name := 'sd_public_curator';
    v_test_public_skill_names text[] := ARRAY[
        'sd_public_summary_skill',
        'sd_blocked_public_write',
        'sd_public_skill_to_fork'
    ];
    v_tables text[] := ARRAY[
        'malu$skill_access',
        'malu$skill_embedding',
        'malu$skill_keyword',
        'malu$skill_subject',
        'malu$skill_verb',
        'malu$skill_execution_step',
        'malu$skill_execution_record',
        'malu$skill_transition',
        'malu$skill_state',
        'malu$skill_package'
    ];
    v_table text;
    v_has_non_test_public_state boolean;
    v_has_enabled_public_state boolean;
    v_existing_role name;
BEGIN
    SELECT r.rolname
    INTO v_existing_role
    FROM pg_catalog.pg_roles r
    WHERE r.rolname = ANY (ARRAY['sd_user_a', 'sd_user_b', 'sd_public_curator'])
    LIMIT 1;

    IF v_existing_role IS NOT NULL THEN
        RAISE EXCEPTION 'Refusing to start skill_discovery test: role % already exists',
            v_existing_role;
    END IF;

    FOR v_schema, v_expected_owner IN
        SELECT schema_name::name, owner_name::name
        FROM (VALUES
            ('skill_a', 'sd_user_a'),
            ('skill_b', 'sd_user_b'),
            ('maludb_public', 'sd_public_curator')
        ) AS test_schema(schema_name, owner_name)
    LOOP
        IF to_regnamespace(v_schema::text) IS NOT NULL
           AND NOT EXISTS (
               SELECT 1
               FROM pg_catalog.pg_namespace n
               JOIN pg_catalog.pg_roles r ON r.oid = n.nspowner
               WHERE n.nspname = v_schema
                 AND r.rolname = v_expected_owner
           )
        THEN
            RAISE EXCEPTION 'Refusing to clean schema %: existing schema is not owned by test role %',
                v_schema, v_expected_owner;
        END IF;
    END LOOP;

    IF to_regclass('maludb_core.malu$enabled_schema') IS NOT NULL THEN
        EXECUTE 'SELECT EXISTS (
                    SELECT 1
                    FROM maludb_core."malu$enabled_schema"
                    WHERE schema_name = $1
                )'
        INTO v_has_enabled_public_state
        USING v_public_schema;

        IF v_has_enabled_public_state
           AND (
               to_regnamespace(v_public_schema::text) IS NULL
               OR NOT EXISTS (
                   SELECT 1
                   FROM pg_catalog.pg_namespace n
                   JOIN pg_catalog.pg_roles r ON r.oid = n.nspowner
                   WHERE n.nspname = v_public_schema
                     AND r.rolname = v_public_owner
               )
           )
        THEN
            RAISE EXCEPTION 'Refusing to clean enabled-schema state for %: state is not test-owned',
                v_public_schema;
        END IF;
    END IF;

    IF to_regclass('maludb_core.malu$enabled_schema_object') IS NOT NULL THEN
        EXECUTE 'SELECT EXISTS (
                    SELECT 1
                    FROM maludb_core."malu$enabled_schema_object"
                    WHERE schema_name = $1
                )'
        INTO v_has_enabled_public_state
        USING v_public_schema;

        IF v_has_enabled_public_state
           AND (
               to_regnamespace(v_public_schema::text) IS NULL
               OR NOT EXISTS (
                   SELECT 1
                   FROM pg_catalog.pg_namespace n
                   JOIN pg_catalog.pg_roles r ON r.oid = n.nspowner
                   WHERE n.nspname = v_public_schema
                     AND r.rolname = v_public_owner
               )
           )
        THEN
            RAISE EXCEPTION 'Refusing to clean enabled-schema object state for %: state is not test-owned',
                v_public_schema;
        END IF;
    END IF;

    IF to_regclass('maludb_core.malu$skill_package') IS NOT NULL THEN
        EXECUTE 'SELECT EXISTS (
                    SELECT 1
                    FROM maludb_core."malu$skill_package"
                    WHERE owner_schema = $1
                      AND skill_name <> ALL($2)
                )'
        INTO v_has_non_test_public_state
        USING v_public_schema, v_test_public_skill_names;

        IF v_has_non_test_public_state THEN
            RAISE EXCEPTION 'Refusing to clean schema %: non-test public skill rows exist',
                v_public_schema;
        END IF;

        FOREACH v_table IN ARRAY v_tables LOOP
            IF v_table <> 'malu$skill_package'
               AND to_regclass('maludb_core.' || quote_ident(v_table)) IS NOT NULL
               AND EXISTS (
                   SELECT 1
                   FROM pg_catalog.pg_attribute
                   WHERE attrelid = to_regclass('maludb_core.' || quote_ident(v_table))
                     AND attname = 'owner_schema'
                     AND NOT attisdropped
               )
               AND EXISTS (
                   SELECT 1
                   FROM pg_catalog.pg_attribute
                   WHERE attrelid = to_regclass('maludb_core.' || quote_ident(v_table))
                     AND attname = 'skill_id'
                     AND NOT attisdropped
               )
            THEN
                EXECUTE format(
                    'SELECT EXISTS (
                         SELECT 1
                         FROM maludb_core.%I child
                         WHERE child.owner_schema = $1
                           AND NOT EXISTS (
                               SELECT 1
                               FROM maludb_core."malu$skill_package" pkg
                               WHERE pkg.owner_schema = child.owner_schema
                                 AND pkg.skill_id = child.skill_id
                                 AND pkg.skill_name = ANY($2)
                           )
                     )',
                    v_table
                )
                INTO v_has_non_test_public_state
                USING v_public_schema, v_test_public_skill_names;

                IF v_has_non_test_public_state THEN
                    RAISE EXCEPTION 'Refusing to clean schema %: non-test rows exist in %',
                        v_public_schema, v_table;
                END IF;
            END IF;
        END LOOP;
    END IF;

    FOREACH v_schema IN ARRAY ARRAY['skill_a'::name, 'skill_b'::name, v_public_schema] LOOP
        FOREACH v_table IN ARRAY v_tables LOOP
            IF to_regclass('maludb_core.' || quote_ident(v_table)) IS NOT NULL
               AND EXISTS (
                   SELECT 1
                   FROM pg_catalog.pg_attribute
                   WHERE attrelid = to_regclass('maludb_core.' || quote_ident(v_table))
                     AND attname = 'owner_schema'
                     AND NOT attisdropped
               )
            THEN
                EXECUTE format('DELETE FROM maludb_core.%I WHERE owner_schema = $1', v_table)
                USING v_schema;
            END IF;
        END LOOP;
        IF to_regclass('maludb_core.malu$svpor_subject') IS NOT NULL THEN
            EXECUTE 'DELETE FROM maludb_core."malu$svpor_subject" WHERE owner_schema = $1'
            USING v_schema;
        END IF;
        IF to_regclass('maludb_core.malu$svpor_verb') IS NOT NULL THEN
            EXECUTE 'DELETE FROM maludb_core."malu$svpor_verb" WHERE owner_schema = $1'
            USING v_schema;
        END IF;
        IF to_regclass('maludb_core.malu$enabled_schema_object') IS NOT NULL THEN
            EXECUTE 'DELETE FROM maludb_core."malu$enabled_schema_object" WHERE schema_name = $1'
            USING v_schema;
        END IF;
        IF to_regclass('maludb_core.malu$enabled_schema') IS NOT NULL THEN
            EXECUTE 'DELETE FROM maludb_core."malu$enabled_schema" WHERE schema_name = $1'
            USING v_schema;
        END IF;
        EXECUTE format('DROP SCHEMA IF EXISTS %I CASCADE', v_schema);
    END LOOP;
END;
$body$;
DROP SCHEMA IF EXISTS skill_a CASCADE;
DROP SCHEMA IF EXISTS skill_b CASCADE;
DROP ROLE IF EXISTS sd_user_a;
DROP ROLE IF EXISTS sd_user_b;
DROP ROLE IF EXISTS sd_public_curator;
DELETE FROM maludb_core.malu$svpor_subject_type
WHERE subject_type = 'document' AND NOT system_defined;

SET client_min_messages = NOTICE;

CREATE ROLE sd_user_a NOLOGIN;
CREATE ROLE sd_user_b NOLOGIN;
CREATE ROLE sd_public_curator NOLOGIN;
COMMENT ON ROLE sd_user_a IS 'maludb skill_discovery regression test role';
COMMENT ON ROLE sd_user_b IS 'maludb skill_discovery regression test role';
COMMENT ON ROLE sd_public_curator IS 'maludb skill_discovery regression test role';
GRANT maludb_memory_executor TO sd_user_a, sd_user_b;
GRANT maludb_memory_admin TO sd_public_curator;
GRANT USAGE ON SCHEMA maludb_core TO sd_user_a, sd_user_b, sd_public_curator;

CREATE SCHEMA skill_a AUTHORIZATION sd_user_a;
CREATE SCHEMA skill_b AUTHORIZATION sd_user_b;
CREATE SCHEMA maludb_public AUTHORIZATION sd_public_curator;

SELECT object_count >= 54 AS maludb_public_enabled
FROM maludb_core.enable_memory_schema('maludb_public');

GRANT USAGE ON SCHEMA maludb_public TO sd_user_b;

SELECT object_count >= 56 AS skill_a_enabled
FROM maludb_core.enable_memory_schema('skill_a');

SELECT object_count >= 56 AS skill_b_enabled
FROM maludb_core.enable_memory_schema('skill_b');

SELECT enabled_version = maludb_core.maludb_core_version() AS skill_schema_enabled_version_current
FROM maludb_core.malu$enabled_schema
WHERE schema_name = 'skill_a';

GRANT USAGE ON SCHEMA skill_b TO sd_user_a;

-- The 0.75.0 typed-subject registry only seeds the standard types; register
-- the 'document' type this test's fixtures use (removed again in cleanup).
INSERT INTO maludb_core.malu$svpor_subject_type(subject_type, display_name, description, sort_order, system_defined)
VALUES ('document', 'Document', 'skill_discovery regression test fixture type', 500, false)
ON CONFLICT (subject_type) DO NOTHING;

SET ROLE sd_user_a;
SET search_path TO skill_a, maludb_core, public;

INSERT INTO maludb_subject(subject_type, canonical_name)
VALUES
    ('document', 'meeting transcript'),
    ('document', 'invoice'),
    ('document', 'project note'),
    ('document', 'incident report');

INSERT INTO maludb_verb(canonical_name)
VALUES
    ('extract'),
    ('summarize'),
    ('organize'),
    ('classify');

INSERT INTO maludb_skill(skill_name, version, description, packaging_kind)
VALUES
    (
        'sd_rank_exact_extract_transcript',
        '1.0.0',
        'Extract action items from meeting transcripts.',
        'markdown'
    ),
    (
        'sd_rank_subject_only_transcript',
        '1.0.0',
        'Summarize meeting transcripts for stakeholders.',
        'markdown'
    ),
    (
        'sd_rank_verb_only_extract',
        '1.0.0',
        'Extract payable amounts from invoices.',
        'markdown'
    ),
    (
        'sd_rank_keyword_only_action_items',
        '1.0.0',
        'Organize follow-up owners from project notes.',
        'markdown'
    ),
    (
        'sd_rank_description_only_commitments',
        '1.0.0',
        'Locate commitments in decision minutes using description text only.',
        'markdown'
    )
RETURNING skill_name, version;

INSERT INTO maludb_skill_subject(skill_id, subject_name, weight)
SELECT skill_id, subject_name, 1.0
FROM maludb_skill
CROSS JOIN LATERAL (
    VALUES
        ('sd_rank_exact_extract_transcript', 'meeting transcript'),
        ('sd_rank_subject_only_transcript', 'meeting transcript'),
        ('sd_rank_verb_only_extract', 'invoice'),
        ('sd_rank_keyword_only_action_items', 'project note'),
        ('sd_rank_description_only_commitments', 'incident report')
) AS fixture(skill_name, subject_name)
WHERE maludb_skill.skill_name = fixture.skill_name;

INSERT INTO maludb_skill_verb(skill_id, verb_name, weight)
SELECT skill_id, verb_name, 1.0
FROM maludb_skill
CROSS JOIN LATERAL (
    VALUES
        ('sd_rank_exact_extract_transcript', 'extract'),
        ('sd_rank_subject_only_transcript', 'summarize'),
        ('sd_rank_verb_only_extract', 'extract'),
        ('sd_rank_keyword_only_action_items', 'organize'),
        ('sd_rank_description_only_commitments', 'classify')
) AS fixture(skill_name, verb_name)
WHERE maludb_skill.skill_name = fixture.skill_name;

INSERT INTO maludb_skill_keyword(skill_id, keyword, weight)
SELECT skill_id, keyword, 1.0
FROM maludb_skill
CROSS JOIN LATERAL (
    VALUES
        ('sd_rank_exact_extract_transcript', 'action items'),
        ('sd_rank_subject_only_transcript', 'meeting recap'),
        ('sd_rank_verb_only_extract', 'invoice amount'),
        ('sd_rank_keyword_only_action_items', 'action items'),
        ('sd_rank_description_only_commitments', 'incident classifier')
) AS fixture(skill_name, keyword)
WHERE maludb_skill.skill_name = fixture.skill_name;

INSERT INTO maludb_skill_embedding(
    skill_id,
    embedding_model,
    embedding_dim,
    embedding,
    source_text_hash,
    source_text_kind
)
SELECT skill_id,
       'sd-regression-4d',
       4,
       fixture.embedding::maludb_core.malu_vector,
       fixture.source_text_hash,
       'description'
FROM maludb_skill
CROSS JOIN LATERAL (
    VALUES
        ('sd_rank_exact_extract_transcript', '[0.99,0.01,0,0]', 'sd-embedding-close-hash'),
        ('sd_rank_subject_only_transcript', '[0.05,0.95,0,0]', 'sd-embedding-far-hash')
) AS fixture(skill_name, embedding, source_text_hash)
WHERE maludb_skill.skill_name = fixture.skill_name;

WITH ranked AS (
    SELECT row_number() OVER (ORDER BY score DESC, owner_schema, skill_name) AS search_rank,
           skill_name,
           owner_schema,
           CASE skill_name
               WHEN 'sd_rank_exact_extract_transcript' THEN 'exact_subject_verb_keyword'
               WHEN 'sd_rank_subject_only_transcript' THEN 'subject_only'
               WHEN 'sd_rank_verb_only_extract' THEN 'verb_only'
               WHEN 'sd_rank_keyword_only_action_items' THEN 'keyword_only'
               WHEN 'sd_rank_description_only_commitments' THEN 'description_only'
           END AS match_kind
    FROM maludb_skill_search(
        p_query => 'action items commitments',
        p_subject => 'meeting transcript',
        p_verb => 'extract',
        p_limit => 10
    )
    WHERE owner_schema = 'skill_a'
      AND skill_name LIKE 'sd_rank_%'
)
SELECT search_rank, skill_name, owner_schema, match_kind
FROM ranked
ORDER BY search_rank;

WITH subject_matches AS (
    SELECT skill_name
    FROM maludb_skill_search(
        p_query => '',
        p_subject => 'meeting transcript',
        p_limit => 10
    )
    WHERE owner_schema = 'skill_a'
      AND skill_name LIKE 'sd_rank_%'
    ORDER BY score DESC, owner_schema, skill_name
)
SELECT array_agg(skill_name) = ARRAY[
           'sd_rank_exact_extract_transcript',
           'sd_rank_subject_only_transcript'
       ] AS subject_only_order
FROM subject_matches;

WITH verb_matches AS (
    SELECT skill_name
    FROM maludb_skill_search(
        p_query => '',
        p_verb => 'extract',
        p_limit => 10
    )
    WHERE owner_schema = 'skill_a'
      AND skill_name LIKE 'sd_rank_%'
    ORDER BY score DESC, owner_schema, skill_name
)
SELECT array_agg(skill_name) = ARRAY[
           'sd_rank_exact_extract_transcript',
           'sd_rank_verb_only_extract'
       ] AS verb_only_order
FROM verb_matches;

WITH keyword_matches AS (
    SELECT skill_name
    FROM maludb_skill_search(
        p_query => 'action items',
        p_limit => 10
    )
    WHERE owner_schema = 'skill_a'
      AND skill_name LIKE 'sd_rank_%'
    ORDER BY score DESC, owner_schema, skill_name
)
SELECT array_agg(skill_name) = ARRAY[
           'sd_rank_exact_extract_transcript',
           'sd_rank_keyword_only_action_items'
       ] AS keyword_only_order
FROM keyword_matches;

SELECT skill_name, owner_schema
FROM maludb_skill_search(
    p_query => 'commitments description text only',
    p_limit => 10
)
WHERE owner_schema = 'skill_a'
  AND skill_name = 'sd_rank_description_only_commitments'
ORDER BY score DESC, owner_schema, skill_name;

WITH embedding_matches AS (
    SELECT row_number() OVER (ORDER BY score DESC, owner_schema, skill_name) AS search_rank,
           skill_name,
           owner_schema
    FROM maludb_skill_search(
        p_query_embedding => '[1,0,0,0]'::maludb_core.malu_vector,
        p_limit => 10
    )
    WHERE owner_schema = 'skill_a'
      AND skill_name IN (
          'sd_rank_exact_extract_transcript',
          'sd_rank_subject_only_transcript'
      )
)
SELECT search_rank, skill_name, owner_schema
FROM embedding_matches
ORDER BY search_rank;

RESET ROLE;
SET ROLE sd_user_b;
SET search_path TO skill_b, maludb_core, public;

INSERT INTO maludb_skill(skill_name, version, description, packaging_kind)
VALUES (
    'sd_private_checklist_builder',
    '1.0.0',
    'A private checklist skill that must not appear across tenants.',
    'markdown'
)
RETURNING skill_name, version;

INSERT INTO maludb_skill_keyword(skill_id, keyword, weight)
SELECT skill_id, 'private checklist', 1.0
FROM maludb_skill
WHERE skill_name = 'sd_private_checklist_builder';

INSERT INTO maludb_skill(skill_name, version, description, packaging_kind)
VALUES (
    'sd_shared_readonly_checklist',
    '1.0.0',
    'Build reusable checklists from operational notes.',
    'markdown'
)
RETURNING skill_name, version;

INSERT INTO maludb_skill_keyword(skill_id, keyword, weight)
SELECT skill_id, 'shared checklist', 1.0
FROM maludb_skill
WHERE skill_name = 'sd_shared_readonly_checklist';

INSERT INTO maludb_skill_access(skill_id, grantee_role, access_level)
SELECT skill_id, 'sd_user_a', 'read'
FROM maludb_skill
WHERE skill_name = 'sd_shared_readonly_checklist';

INSERT INTO maludb_skill(skill_name, version, description, packaging_kind)
VALUES
    (
        'sd_execute_only_hidden_skill',
        '1.0.0',
        'Reserved execute grants must not make skills discoverable.',
        'markdown'
    ),
    (
        'sd_admin_only_hidden_skill',
        '1.0.0',
        'Reserved admin grants must not make skills discoverable.',
        'markdown'
    )
RETURNING skill_name, version;

INSERT INTO maludb_skill_keyword(skill_id, keyword, weight)
SELECT skill_id, 'reserved visibility', 1.0
FROM maludb_skill
WHERE skill_name IN ('sd_execute_only_hidden_skill', 'sd_admin_only_hidden_skill');

INSERT INTO maludb_skill_access(skill_id, grantee_role, access_level)
SELECT skill_id,
       'sd_user_a',
       CASE skill_name
           WHEN 'sd_execute_only_hidden_skill' THEN 'execute'
           ELSE 'admin'
       END
FROM maludb_skill
WHERE skill_name IN ('sd_execute_only_hidden_skill', 'sd_admin_only_hidden_skill');

RESET ROLE;
SET ROLE sd_user_a;
SET search_path TO skill_a, maludb_core, public;

SELECT count(*) = 0 AS private_skill_hidden
FROM maludb_skill_search(
    p_query => 'private checklist',
    p_limit => 10,
    p_include_public => false
)
WHERE owner_schema = 'skill_b'
  AND skill_name = 'sd_private_checklist_builder';

SELECT count(*) = 0 AS direct_core_search_cannot_spoof_schema
FROM maludb_core.find_skill(
    p_query => 'private checklist',
    p_owner_schema => 'skill_b',
    p_limit => 10,
    p_include_public => false
)
WHERE owner_schema = 'skill_b';

WITH reserved_matches AS (
    SELECT skill_name, is_forkable
    FROM maludb_skill_search(
        p_query => 'reserved visibility',
        p_limit => 10,
        p_include_public => false
    )
    WHERE owner_schema = 'skill_b'
      AND skill_name IN ('sd_execute_only_hidden_skill', 'sd_admin_only_hidden_skill')
)
SELECT count(*) = 0
       AND COALESCE(bool_or(is_forkable), false) = false
       AS reserved_access_not_visible_or_forkable
FROM reserved_matches;

SET search_path TO skill_b, maludb_core, public;

SELECT count(*) = 0 AS reserved_access_core_package_hidden
FROM maludb_core.malu$skill_package
WHERE owner_schema = 'skill_b'
  AND skill_name IN ('sd_execute_only_hidden_skill', 'sd_admin_only_hidden_skill');

SELECT count(*) = 0 AS reserved_access_core_grants_hidden
FROM maludb_core.malu$skill_access
WHERE owner_schema = 'skill_b'
  AND grantee_role = 'sd_user_a'
  AND access_level IN ('execute', 'admin');

SET search_path TO skill_a, maludb_core, public;

SELECT skill_name, owner_schema, is_forkable
FROM maludb_skill_search(
    p_query => 'shared checklist',
    p_limit => 10,
    p_include_public => false
)
WHERE owner_schema = 'skill_b'
ORDER BY score DESC, skill_name;

RESET ROLE;
SET ROLE sd_user_b;
SET search_path TO skill_b, maludb_core, public;

INSERT INTO maludb_skill_access(skill_id, grantee_role, access_level)
SELECT skill_id, 'sd_user_a', 'fork'
FROM maludb_skill
WHERE skill_name = 'sd_shared_readonly_checklist';

RESET ROLE;
SET ROLE sd_user_a;
SET search_path TO skill_a, maludb_core, public;

SELECT skill_name, owner_schema, is_forkable
FROM maludb_skill_search(
    p_query => 'shared checklist',
    p_limit => 10,
    p_include_public => false
)
WHERE owner_schema = 'skill_b'
ORDER BY score DESC, skill_name;

RESET ROLE;
SET ROLE sd_public_curator;
SET search_path TO maludb_public, maludb_core, public;

INSERT INTO maludb_skill(skill_name, version, description, packaging_kind, visibility)
VALUES (
    'sd_public_summary_skill',
    '1.0.0',
    'Summarize public documents for general use.',
    'markdown',
    'public'
)
RETURNING skill_name, owner_schema, visibility;

INSERT INTO maludb_subject(subject_type, canonical_name)
VALUES ('document', 'public document');

INSERT INTO maludb_verb(canonical_name)
VALUES ('summarize');

INSERT INTO maludb_skill_subject(skill_id, subject_name, weight)
SELECT skill_id, 'public document', 1.0
FROM maludb_skill
WHERE skill_name = 'sd_public_summary_skill';

INSERT INTO maludb_skill_verb(skill_id, verb_name, weight)
SELECT skill_id, 'summarize', 1.0
FROM maludb_skill
WHERE skill_name = 'sd_public_summary_skill';

INSERT INTO maludb_skill_keyword(skill_id, keyword, weight)
SELECT skill_id, 'summarize', 1.0
FROM maludb_skill
WHERE skill_name = 'sd_public_summary_skill';

INSERT INTO maludb_skill_embedding(
    skill_id,
    embedding_model,
    embedding_dim,
    embedding,
    source_text_hash,
    source_text_kind
)
SELECT skill_id,
       'sd-public-4d',
       4,
       '[0.25,0.25,0.25,0.25]'::maludb_core.malu_vector,
       'sd-public-summary-hash',
       'description'
FROM maludb_skill
WHERE skill_name = 'sd_public_summary_skill';

INSERT INTO maludb_skill_access(skill_id, grantee_role, access_level)
SELECT skill_id, 'sd_user_b', 'read'
FROM maludb_skill
WHERE skill_name = 'sd_public_summary_skill';

RESET ROLE;
SET ROLE sd_user_a;
SET search_path TO skill_a, maludb_core, public;

SELECT count(*) = 0 AS public_skill_excluded_when_public_disabled
FROM maludb_skill_search(
    p_query => 'summarize',
    p_limit => 10,
    p_include_public => false
)
WHERE owner_schema = 'maludb_public'
  AND skill_name = 'sd_public_summary_skill';

SELECT skill_name, owner_schema, is_public
FROM maludb_skill_search(
    p_query => 'summarize',
    p_limit => 10,
    p_include_public => true
)
WHERE owner_schema = 'maludb_public'
ORDER BY is_public DESC, skill_name;

RESET ROLE;
SET search_path TO maludb_core, public;

SELECT t.tool_name, t.risk_class, t.read_only, f.function_signature::text AS function_signature
FROM maludb_core.malu$mc2db_tool t
JOIN maludb_core.malu$mc2db_server s ON s.server_id = t.server_id
JOIN maludb_core.malu$mc2db_tool_sql_function f ON f.tool_id = t.tool_id
WHERE s.server_name = 'maludb.r10'
  AND t.tool_name IN ('skill.find', 'skill.get', 'skill.fork')
ORDER BY t.tool_name;

SELECT bool_and(
           CASE t.tool_name
               WHEN 'skill.find' THEN t.input_schema->'required' ? 'requesting_schema'
               WHEN 'skill.get' THEN t.input_schema->'required' ?& ARRAY['owner_schema','skill_id','requesting_schema']
               WHEN 'skill.fork' THEN t.input_schema->'required' ?& ARRAY['source_owner_schema','source_skill_id','target_owner_schema']
               ELSE false
           END
       ) AS mc2db_skill_required_args
FROM maludb_core.malu$mc2db_tool t
JOIN maludb_core.malu$mc2db_server s ON s.server_id = t.server_id
WHERE s.server_name = 'maludb.r10'
  AND t.tool_name IN ('skill.find', 'skill.get', 'skill.fork');

SELECT skill_id AS sd_public_skill_id
FROM maludb_core.malu$skill_package
WHERE owner_schema = 'maludb_public'
  AND skill_name = 'sd_public_summary_skill' \gset

SET ROLE sd_user_a;
SET search_path TO skill_a, maludb_core, public;

SELECT mc2db._begin_request('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbb0001'::uuid, 'skill.find');
SELECT true AS mc2db_find_called
FROM (
    SELECT maludb_core.r10_skill_find(
        jsonb_build_object('query', 'summarize', 'requesting_schema', 'skill_a'),
        '{}'::jsonb
    )
) AS call;
SELECT payload->>'isError' AS is_err,
       jsonb_array_length(payload->'structuredContent'->'results') > 0 AS has_results,
       payload->'structuredContent'->'results'->0->>'skill_name' AS first_skill
FROM mc2db._end_request();

SELECT mc2db._begin_request('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbb0002'::uuid, 'skill.get');
SELECT true AS mc2db_get_called
FROM (
    SELECT maludb_core.r10_skill_get(
        jsonb_build_object(
            'owner_schema', 'maludb_public',
            'skill_id', :'sd_public_skill_id'::bigint,
            'requesting_schema', 'skill_a'
        ),
        '{}'::jsonb
    )
) AS call;
SELECT payload->>'isError' AS is_err,
       payload->'structuredContent'->'payload'->'skill'->>'skill_name' AS skill_name,
       payload->'structuredContent'->'payload'->'access_policy'->>'is_public' AS is_public
FROM mc2db._end_request();

SELECT mc2db._begin_request('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbb0003'::uuid, 'skill.fork');
SELECT true AS mc2db_fork_called
FROM (
    SELECT maludb_core.r10_skill_fork(
        jsonb_build_object(
            'source_owner_schema', 'maludb_public',
            'source_skill_id', :'sd_public_skill_id'::bigint,
            'target_owner_schema', 'skill_a',
            'new_skill_name', 'sd_mc2db_forked_skill'
        ),
        '{}'::jsonb
    )
) AS call;
SELECT payload->>'isError' AS is_err,
       (payload->'structuredContent'->>'skill_id')::bigint > 0 AS forked_skill_id
FROM mc2db._end_request();

SELECT mc2db._begin_request('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbb0004'::uuid, 'skill.find');
SELECT true AS mc2db_find_missing_schema_called
FROM (
    SELECT maludb_core.r10_skill_find(
        jsonb_build_object('query', 'summarize', 'owner_schema', 'skill_a'),
        '{}'::jsonb
    )
) AS call;
SELECT payload->>'isError' AS is_err,
       payload->'structuredContent'->'error'->>'code' AS err_code,
       payload->'structuredContent'->'error'->>'message' AS err_msg
FROM mc2db._end_request();

SELECT mc2db._begin_request('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbb0005'::uuid, 'skill.get');
SELECT true AS mc2db_get_missing_schema_called
FROM (
    SELECT maludb_core.r10_skill_get(
        jsonb_build_object(
            'owner_schema', 'maludb_public',
            'skill_id', :'sd_public_skill_id'::bigint
        ),
        '{}'::jsonb
    )
) AS call;
SELECT payload->>'isError' AS is_err,
       payload->'structuredContent'->'error'->>'code' AS err_code,
       payload->'structuredContent'->'error'->>'message' AS err_msg
FROM mc2db._end_request();

SELECT mc2db._begin_request('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbb0006'::uuid, 'skill.fork');
SELECT true AS mc2db_fork_missing_target_called
FROM (
    SELECT maludb_core.r10_skill_fork(
        jsonb_build_object(
            'source_owner_schema', 'maludb_public',
            'source_skill_id', :'sd_public_skill_id'::bigint,
            'requesting_schema', 'skill_a',
            'new_skill_name', 'sd_mc2db_bad_fork'
        ),
        '{}'::jsonb
    )
) AS call;
SELECT payload->>'isError' AS is_err,
       payload->'structuredContent'->'error'->>'code' AS err_code,
       payload->'structuredContent'->'error'->>'message' AS err_msg
FROM mc2db._end_request();

RESET ROLE;
SET ROLE sd_user_b;
SET search_path TO maludb_public, maludb_core, public;

SELECT skill_name, visibility
FROM maludb_skill
WHERE skill_name = 'sd_public_summary_skill';

SELECT subject_name
FROM maludb_skill_subject
WHERE skill_id = (
    SELECT skill_id
    FROM maludb_skill
    WHERE skill_name = 'sd_public_summary_skill'
)
ORDER BY subject_name;

SELECT verb_name
FROM maludb_skill_verb
WHERE skill_id = (
    SELECT skill_id
    FROM maludb_skill
    WHERE skill_name = 'sd_public_summary_skill'
)
ORDER BY verb_name;

SELECT keyword
FROM maludb_skill_keyword
WHERE skill_id = (
    SELECT skill_id
    FROM maludb_skill
    WHERE skill_name = 'sd_public_summary_skill'
)
ORDER BY keyword;

SELECT embedding_model, embedding_dim, source_text_kind
FROM maludb_skill_embedding
WHERE skill_id = (
    SELECT skill_id
    FROM maludb_skill
    WHERE skill_name = 'sd_public_summary_skill'
)
ORDER BY embedding_model;

SELECT grantee_role, access_level
FROM maludb_skill_access
WHERE skill_id = (
    SELECT skill_id
    FROM maludb_skill
    WHERE skill_name = 'sd_public_summary_skill'
)
ORDER BY grantee_role, access_level;

SET search_path TO skill_b, maludb_core, public;

SELECT skill_name, owner_schema, is_public
FROM maludb_skill_search(
    p_query => 'summarize',
    p_limit => 10,
    p_include_public => true
)
WHERE owner_schema = 'maludb_public'
ORDER BY is_public DESC, skill_name;

SET search_path TO maludb_public, maludb_core, public;

DO $body$
BEGIN
    BEGIN
        INSERT INTO maludb_skill(skill_name, version, description, packaging_kind, visibility)
        VALUES ('sd_blocked_public_write', '1.0.0', 'should fail', 'markdown', 'public');
        RAISE EXCEPTION 'non-curator public skill write was not blocked';
    EXCEPTION WHEN insufficient_privilege OR check_violation OR with_check_option_violation THEN
        RAISE NOTICE 'OK: non-curator public skill write blocked';
    END;
END;
$body$;

DO $body$
DECLARE
    v_public_skill_id bigint;
BEGIN
    SELECT skill_id
    INTO v_public_skill_id
    FROM maludb_skill
    WHERE skill_name = 'sd_public_summary_skill';

    BEGIN
        UPDATE maludb_skill
        SET description = 'should fail'
        WHERE skill_id = v_public_skill_id;
        RAISE EXCEPTION 'non-curator public skill update was not blocked';
    EXCEPTION WHEN insufficient_privilege OR check_violation OR with_check_option_violation THEN
        RAISE NOTICE 'OK: non-curator public skill update blocked';
    END;

    BEGIN
        DELETE FROM maludb_skill
        WHERE skill_id = v_public_skill_id;
        RAISE EXCEPTION 'non-curator public skill delete was not blocked';
    EXCEPTION WHEN insufficient_privilege OR check_violation OR with_check_option_violation THEN
        RAISE NOTICE 'OK: non-curator public skill delete blocked';
    END;

    BEGIN
        INSERT INTO maludb_skill_keyword(skill_id, keyword, weight)
        VALUES (v_public_skill_id, 'should fail', 1.0);
        RAISE EXCEPTION 'non-curator public keyword write was not blocked';
    EXCEPTION WHEN insufficient_privilege OR check_violation OR with_check_option_violation THEN
        RAISE NOTICE 'OK: non-curator public keyword write blocked';
    END;

    BEGIN
        UPDATE maludb_skill_keyword
        SET keyword = 'should fail'
        WHERE skill_id = v_public_skill_id
          AND keyword = 'summarize';
        RAISE EXCEPTION 'non-curator public keyword update was not blocked';
    EXCEPTION WHEN insufficient_privilege OR check_violation OR with_check_option_violation THEN
        RAISE NOTICE 'OK: non-curator public keyword update blocked';
    END;

    BEGIN
        DELETE FROM maludb_skill_keyword
        WHERE skill_id = v_public_skill_id
          AND keyword = 'summarize';
        RAISE EXCEPTION 'non-curator public keyword delete was not blocked';
    EXCEPTION WHEN insufficient_privilege OR check_violation OR with_check_option_violation THEN
        RAISE NOTICE 'OK: non-curator public keyword delete blocked';
    END;

    BEGIN
        INSERT INTO maludb_skill_subject(skill_id, subject_name, weight)
        VALUES (v_public_skill_id, 'public document', 1.0);
        RAISE EXCEPTION 'non-curator public subject write was not blocked';
    EXCEPTION WHEN insufficient_privilege OR check_violation OR with_check_option_violation THEN
        RAISE NOTICE 'OK: non-curator public subject write blocked';
    END;

    BEGIN
        UPDATE maludb_skill_subject
        SET weight = 0.5
        WHERE skill_id = v_public_skill_id
          AND subject_name = 'public document';
        RAISE EXCEPTION 'non-curator public subject update was not blocked';
    EXCEPTION WHEN insufficient_privilege OR check_violation OR with_check_option_violation THEN
        RAISE NOTICE 'OK: non-curator public subject update blocked';
    END;

    BEGIN
        DELETE FROM maludb_skill_subject
        WHERE skill_id = v_public_skill_id
          AND subject_name = 'public document';
        RAISE EXCEPTION 'non-curator public subject delete was not blocked';
    EXCEPTION WHEN insufficient_privilege OR check_violation OR with_check_option_violation THEN
        RAISE NOTICE 'OK: non-curator public subject delete blocked';
    END;

    BEGIN
        INSERT INTO maludb_skill_verb(skill_id, verb_name, weight)
        VALUES (v_public_skill_id, 'summarize', 1.0);
        RAISE EXCEPTION 'non-curator public verb write was not blocked';
    EXCEPTION WHEN insufficient_privilege OR check_violation OR with_check_option_violation THEN
        RAISE NOTICE 'OK: non-curator public verb write blocked';
    END;

    BEGIN
        UPDATE maludb_skill_verb
        SET weight = 0.5
        WHERE skill_id = v_public_skill_id
          AND verb_name = 'summarize';
        RAISE EXCEPTION 'non-curator public verb update was not blocked';
    EXCEPTION WHEN insufficient_privilege OR check_violation OR with_check_option_violation THEN
        RAISE NOTICE 'OK: non-curator public verb update blocked';
    END;

    BEGIN
        DELETE FROM maludb_skill_verb
        WHERE skill_id = v_public_skill_id
          AND verb_name = 'summarize';
        RAISE EXCEPTION 'non-curator public verb delete was not blocked';
    EXCEPTION WHEN insufficient_privilege OR check_violation OR with_check_option_violation THEN
        RAISE NOTICE 'OK: non-curator public verb delete blocked';
    END;

    BEGIN
        INSERT INTO maludb_skill_embedding(
            skill_id,
            embedding_model,
            embedding_dim,
            embedding,
            source_text_hash,
            source_text_kind
        )
        VALUES (
            v_public_skill_id,
            'sd-public-4d-blocked',
            4,
            '[1,0,0,0]'::maludb_core.malu_vector,
            'sd-public-blocked-hash',
            'description'
        );
        RAISE EXCEPTION 'non-curator public embedding write was not blocked';
    EXCEPTION WHEN insufficient_privilege OR check_violation OR with_check_option_violation THEN
        RAISE NOTICE 'OK: non-curator public embedding write blocked';
    END;

    BEGIN
        UPDATE maludb_skill_embedding
        SET source_text_kind = 'should fail'
        WHERE skill_id = v_public_skill_id
          AND embedding_model = 'sd-public-4d';
        RAISE EXCEPTION 'non-curator public embedding update was not blocked';
    EXCEPTION WHEN insufficient_privilege OR check_violation OR with_check_option_violation THEN
        RAISE NOTICE 'OK: non-curator public embedding update blocked';
    END;

    BEGIN
        DELETE FROM maludb_skill_embedding
        WHERE skill_id = v_public_skill_id
          AND embedding_model = 'sd-public-4d';
        RAISE EXCEPTION 'non-curator public embedding delete was not blocked';
    EXCEPTION WHEN insufficient_privilege OR check_violation OR with_check_option_violation THEN
        RAISE NOTICE 'OK: non-curator public embedding delete blocked';
    END;

    BEGIN
        INSERT INTO maludb_skill_access(skill_id, grantee_role, access_level)
        VALUES (v_public_skill_id, 'sd_user_a', 'read');
        RAISE EXCEPTION 'non-curator public access write was not blocked';
    EXCEPTION WHEN insufficient_privilege OR check_violation OR with_check_option_violation THEN
        RAISE NOTICE 'OK: non-curator public access write blocked';
    END;

    BEGIN
        UPDATE maludb_skill_access
        SET access_level = 'fork'
        WHERE skill_id = v_public_skill_id
          AND grantee_role = 'sd_user_b'
          AND access_level = 'read';
        RAISE EXCEPTION 'non-curator public access update was not blocked';
    EXCEPTION WHEN insufficient_privilege OR check_violation OR with_check_option_violation THEN
        RAISE NOTICE 'OK: non-curator public access update blocked';
    END;

    BEGIN
        DELETE FROM maludb_skill_access
        WHERE skill_id = v_public_skill_id
          AND grantee_role = 'sd_user_b'
          AND access_level = 'read';
        RAISE EXCEPTION 'non-curator public access delete was not blocked';
    EXCEPTION WHEN insufficient_privilege OR check_violation OR with_check_option_violation THEN
        RAISE NOTICE 'OK: non-curator public access delete blocked';
    END;
END;
$body$;

RESET ROLE;
SET search_path TO maludb_core, public;
SET client_min_messages = WARNING;
\unset ON_ERROR_STOP
DROP SCHEMA skill_a CASCADE;
DROP SCHEMA skill_b CASCADE;
DROP SCHEMA maludb_public CASCADE;
DO $body$
DECLARE
    v_schema name;
    v_tables text[] := ARRAY[
        'malu$skill_access',
        'malu$skill_embedding',
        'malu$skill_keyword',
        'malu$skill_subject',
        'malu$skill_verb',
        'malu$skill_execution_step',
        'malu$skill_execution_record',
        'malu$skill_transition',
        'malu$skill_state',
        'malu$skill_package'
    ];
    v_table text;
BEGIN
    FOREACH v_schema IN ARRAY ARRAY['skill_a'::name, 'skill_b'::name, 'maludb_public'::name] LOOP
        FOREACH v_table IN ARRAY v_tables LOOP
            IF to_regclass('maludb_core.' || quote_ident(v_table)) IS NOT NULL
               AND EXISTS (
                   SELECT 1
                   FROM pg_catalog.pg_attribute
                   WHERE attrelid = to_regclass('maludb_core.' || quote_ident(v_table))
                     AND attname = 'owner_schema'
                     AND NOT attisdropped
               )
            THEN
                EXECUTE format('DELETE FROM maludb_core.%I WHERE owner_schema = $1', v_table)
                USING v_schema;
            END IF;
        END LOOP;
        IF to_regclass('maludb_core.malu$svpor_subject') IS NOT NULL THEN
            EXECUTE 'DELETE FROM maludb_core."malu$svpor_subject" WHERE owner_schema = $1'
            USING v_schema;
        END IF;
        IF to_regclass('maludb_core.malu$svpor_verb') IS NOT NULL THEN
            EXECUTE 'DELETE FROM maludb_core."malu$svpor_verb" WHERE owner_schema = $1'
            USING v_schema;
        END IF;
        IF to_regclass('maludb_core.malu$enabled_schema_object') IS NOT NULL THEN
            EXECUTE 'DELETE FROM maludb_core."malu$enabled_schema_object" WHERE schema_name = $1'
            USING v_schema;
        END IF;
        IF to_regclass('maludb_core.malu$enabled_schema') IS NOT NULL THEN
            EXECUTE 'DELETE FROM maludb_core."malu$enabled_schema" WHERE schema_name = $1'
            USING v_schema;
        END IF;
    END LOOP;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'sd_user_a') THEN
        DROP OWNED BY sd_user_a;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'sd_user_b') THEN
        DROP OWNED BY sd_user_b;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'sd_public_curator') THEN
        DROP OWNED BY sd_public_curator;
    END IF;
END;
$body$;
DROP ROLE IF EXISTS sd_user_a;
DROP ROLE IF EXISTS sd_user_b;
DROP ROLE IF EXISTS sd_public_curator;
DELETE FROM maludb_core.malu$svpor_subject_type
WHERE subject_type = 'document' AND NOT system_defined;
