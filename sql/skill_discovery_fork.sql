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
    WHERE r.rolname = ANY (ARRAY['sd_fork_user_a', 'sd_fork_source_user', 'sd_public_curator'])
    LIMIT 1;

    IF v_existing_role IS NOT NULL THEN
        RAISE EXCEPTION 'Refusing to start skill_discovery_fork test: role % already exists',
            v_existing_role;
    END IF;

    FOR v_schema, v_expected_owner IN
        SELECT schema_name::name, owner_name::name
        FROM (VALUES
            ('fork_a', 'sd_fork_user_a'),
            ('fork_source', 'sd_fork_source_user'),
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

    FOREACH v_schema IN ARRAY ARRAY['fork_a'::name, 'fork_source'::name, v_public_schema] LOOP
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
DROP SCHEMA IF EXISTS fork_a CASCADE;
DROP SCHEMA IF EXISTS fork_source CASCADE;
DROP ROLE IF EXISTS sd_fork_user_a;
DROP ROLE IF EXISTS sd_fork_source_user;
DROP ROLE IF EXISTS sd_public_curator;
DELETE FROM maludb_core.malu$svpor_subject_type
WHERE subject_type = 'document' AND NOT system_defined;

SET client_min_messages = NOTICE;

CREATE ROLE sd_fork_user_a NOLOGIN;
CREATE ROLE sd_fork_source_user NOLOGIN;
CREATE ROLE sd_public_curator NOLOGIN;
COMMENT ON ROLE sd_fork_user_a IS 'maludb skill_discovery_fork regression test role';
COMMENT ON ROLE sd_fork_source_user IS 'maludb skill_discovery_fork regression test role';
COMMENT ON ROLE sd_public_curator IS 'maludb skill_discovery_fork regression test role';
GRANT maludb_memory_executor TO sd_fork_user_a, sd_fork_source_user;
GRANT maludb_memory_admin TO sd_public_curator;
GRANT USAGE ON SCHEMA maludb_core TO sd_fork_user_a, sd_fork_source_user, sd_public_curator;

CREATE SCHEMA fork_a AUTHORIZATION sd_fork_user_a;
CREATE SCHEMA fork_source AUTHORIZATION sd_fork_source_user;
CREATE SCHEMA maludb_public AUTHORIZATION sd_public_curator;

SELECT maludb_core.enable_memory_schema('fork_a') IS NOT NULL AS fork_schema_enabled;
SELECT maludb_core.enable_memory_schema('fork_source') IS NOT NULL AS source_schema_enabled;
SELECT maludb_core.enable_memory_schema('maludb_public') IS NOT NULL AS public_schema_enabled;

-- The 0.75.0 typed-subject registry only seeds the standard types; register
-- the 'document' type this test's fixtures use (removed again in cleanup).
INSERT INTO maludb_core.malu$svpor_subject_type(subject_type, display_name, description, sort_order, system_defined)
VALUES ('document', 'Document', 'skill_discovery_fork regression test fixture type', 500, false)
ON CONFLICT (subject_type) DO NOTHING;

SET ROLE sd_public_curator;
SET search_path TO maludb_public, maludb_core, public;

INSERT INTO maludb_skill(
    skill_name,
    version,
    description,
    packaging_kind,
    visibility,
    applicability_jsonb,
    precondition_jsonb
)
VALUES (
    'sd_public_skill_to_fork',
    '1.0.0',
    'A public skill that tenants can fork.',
    'markdown',
    'public',
    '{"domains":["public-docs"],"languages":["en"]}'::jsonb,
    '{"requires":["document"]}'::jsonb
)
RETURNING skill_name, version;

INSERT INTO maludb_subject(subject_type, canonical_name)
VALUES ('document', 'public fork document');

INSERT INTO maludb_verb(canonical_name)
VALUES ('fork summarize');

INSERT INTO maludb_skill_subject(skill_id, subject_name, weight)
SELECT skill_id, 'public fork document', 1.0
FROM maludb_skill
WHERE skill_name = 'sd_public_skill_to_fork';

INSERT INTO maludb_skill_verb(skill_id, verb_name, weight)
SELECT skill_id, 'fork summarize', 1.0
FROM maludb_skill
WHERE skill_name = 'sd_public_skill_to_fork';

INSERT INTO maludb_skill_keyword(skill_id, keyword)
SELECT skill_id, 'sd public keyword'
FROM maludb_skill
WHERE skill_name = 'sd_public_skill_to_fork';

INSERT INTO maludb_skill_embedding(
    skill_id,
    embedding_model,
    embedding_dim,
    embedding,
    source_text_hash,
    source_text_kind
)
SELECT skill_id,
       'sd-test-embedding',
       4,
       '[1,0,0,0]'::maludb_core.malu_vector,
       'sd-public-skill-description-hash',
       'description'
FROM maludb_skill
WHERE skill_name = 'sd_public_skill_to_fork';

WITH source_skill AS (
    SELECT skill_id
    FROM maludb_skill
    WHERE skill_name = 'sd_public_skill_to_fork'
)
INSERT INTO maludb_skill_state(skill_id, state_name, state_kind, step_jsonb, validation_jsonb)
SELECT source_skill.skill_id,
       fixture.state_name,
       fixture.state_kind,
       fixture.step_jsonb,
       fixture.validation_jsonb
FROM source_skill
CROSS JOIN (VALUES
    ('start', 'start', '{"instruction":"draft summary"}'::jsonb, '{"required":["input"]}'::jsonb),
    ('finish', 'terminal', '{"instruction":"return summary"}'::jsonb, '{"required":["summary"]}'::jsonb)
) AS fixture(state_name, state_kind, step_jsonb, validation_jsonb)
RETURNING state_name, state_kind;

INSERT INTO maludb_skill_transition(skill_id, from_state_id, to_state_id, on_outcome, guard_jsonb, ordinal)
SELECT s.skill_id,
       from_state.state_id,
       to_state.state_id,
       'success',
       '{"requires":"summary"}'::jsonb,
       10
FROM maludb_skill s
JOIN maludb_skill_state from_state
  ON from_state.skill_id = s.skill_id
 AND from_state.state_name = 'start'
JOIN maludb_skill_state to_state
  ON to_state.skill_id = s.skill_id
 AND to_state.state_name = 'finish'
WHERE s.skill_name = 'sd_public_skill_to_fork'
RETURNING on_outcome, ordinal;

RESET ROLE;
SET ROLE sd_fork_user_a;
SET search_path TO fork_a, maludb_core, public;

CREATE TEMP TABLE maludb_fork_state_map (
    old_state_id bigint PRIMARY KEY,
    new_state_id bigint NOT NULL,
    attacker_marker text DEFAULT 'precreated'
) ON COMMIT PRESERVE ROWS;

SELECT maludb_skill_fork(
    p_source_owner_schema => 'maludb_public',
    p_source_skill_id => (
        SELECT skill_id
        FROM maludb_skill_search(
            p_query => 'sd public keyword',
            p_limit => 10,
            p_include_public => true
        )
        WHERE owner_schema = 'maludb_public'
          AND skill_name = 'sd_public_skill_to_fork'
        LIMIT 1
    ),
    p_new_skill_name => 'sd_tenant_forked_skill'
) IS NOT NULL AS fork_created;

SELECT count(*) = 0 AS precreated_state_map_ignored
FROM maludb_fork_state_map;

SELECT skill_name, source_owner_schema, source_skill_id IS NOT NULL AS has_source
FROM maludb_skill
WHERE skill_name = 'sd_tenant_forked_skill';

SELECT keyword
FROM maludb_skill_keyword
WHERE skill_id = (
    SELECT skill_id
    FROM maludb_skill
    WHERE skill_name = 'sd_tenant_forked_skill'
)
ORDER BY keyword;

SELECT subject_name
FROM maludb_skill_subject
WHERE skill_id = (
    SELECT skill_id
    FROM maludb_skill
    WHERE skill_name = 'sd_tenant_forked_skill'
)
ORDER BY subject_name;

SELECT verb_name
FROM maludb_skill_verb
WHERE skill_id = (
    SELECT skill_id
    FROM maludb_skill
    WHERE skill_name = 'sd_tenant_forked_skill'
)
ORDER BY verb_name;

SELECT embedding_model, embedding_dim, source_text_hash, source_text_kind
FROM maludb_skill_embedding
WHERE skill_id = (
    SELECT skill_id
    FROM maludb_skill
    WHERE skill_name = 'sd_tenant_forked_skill'
)
ORDER BY embedding_model, source_text_kind, source_text_hash;

SELECT state_name, state_kind, step_jsonb, validation_jsonb
FROM maludb_skill_state
WHERE skill_id = (
    SELECT skill_id
    FROM maludb_skill
    WHERE skill_name = 'sd_tenant_forked_skill'
)
ORDER BY state_name;

SELECT from_state.state_name AS from_state,
       to_state.state_name AS to_state,
       tr.on_outcome,
       tr.guard_jsonb,
       tr.ordinal
FROM maludb_skill_transition tr
JOIN maludb_skill_state from_state
  ON from_state.skill_id = tr.skill_id
 AND from_state.state_id = tr.from_state_id
JOIN maludb_skill_state to_state
  ON to_state.skill_id = tr.skill_id
 AND to_state.state_id = tr.to_state_id
WHERE tr.skill_id = (
    SELECT skill_id
    FROM maludb_skill
    WHERE skill_name = 'sd_tenant_forked_skill'
)
ORDER BY tr.ordinal, from_state.state_name, to_state.state_name;

SELECT payload ? 'skill' AS has_skill,
       payload ? 'keywords' AS has_keywords,
       payload ? 'subjects' AS has_subjects,
       payload ? 'verbs' AS has_verbs,
       payload ? 'states' AS has_states,
       payload ? 'transitions' AS has_transitions
FROM maludb_skill_get(
    p_owner_schema => 'fork_a',
    p_skill_id => (
        SELECT skill_id
        FROM maludb_skill
        WHERE skill_name = 'sd_tenant_forked_skill'
    )
) AS got(payload);

SELECT payload #>> '{skill,skill_name}' = 'sd_tenant_forked_skill' AS payload_skill_name,
       payload #>> '{skill,description}' = 'A public skill that tenants can fork.' AS payload_description,
       payload #>> '{skill,packaging_kind}' = 'markdown' AS payload_packaging_kind,
       payload #> '{skill,applicability_jsonb}' = '{"domains":["public-docs"],"languages":["en"]}'::jsonb AS payload_applicability,
       payload #> '{skill,precondition_jsonb}' = '{"requires":["document"]}'::jsonb AS payload_precondition,
       jsonb_path_exists(payload, '$.keywords[*] ? (@.keyword == "sd public keyword")') AS payload_keyword,
       jsonb_path_exists(payload, '$.subjects[*] ? (@.subject_name == "public fork document")') AS payload_subject,
       jsonb_path_exists(payload, '$.verbs[*] ? (@.verb_name == "fork summarize")') AS payload_verb,
       jsonb_path_exists(
           payload,
           '$.states[*] ? (@.state_name == "start" && @.state_kind == "start" && @.step_jsonb.instruction == "draft summary" && @.validation_jsonb.required[0] == "input")'
       ) AS payload_start_state,
       jsonb_path_exists(
           payload,
           '$.transitions[*] ? (@.on_outcome == "success" && @.guard_jsonb.requires == "summary" && @.ordinal == 10 && @.from_state_name == "start" && @.to_state_name == "finish")'
       ) AS payload_transition,
       payload #>> '{skill,source_owner_schema}' = 'maludb_public' AS payload_lineage_owner,
       payload #> '{skill,source_skill_id}' IS NOT NULL AS payload_lineage_id,
       payload #>> '{access_policy,visibility}' = 'private' AS payload_access_visibility,
       payload #>> '{access_policy,is_public}' = 'false' AS payload_access_public
FROM maludb_skill_get(
    p_owner_schema => 'fork_a',
    p_skill_id => (
        SELECT skill_id
        FROM maludb_skill
        WHERE skill_name = 'sd_tenant_forked_skill'
    )
) AS got(payload);

SELECT jsonb_path_exists(
           payload,
           '$.transitions[*] ? (@.on_outcome == "success" && @.guard_jsonb.requires == "summary" && @.ordinal == 10 && @.from_state_name == "start" && @.to_state_name == "finish")'
       ) AS public_payload_transition_details
FROM maludb_skill_get(
    p_owner_schema => 'fork_a',
    p_skill_id => (
        SELECT skill_id
        FROM maludb_skill
        WHERE skill_name = 'sd_tenant_forked_skill'
    )
) AS got(payload);

RESET ROLE;
SET ROLE sd_fork_source_user;
SET search_path TO fork_source, maludb_core, public;

INSERT INTO maludb_skill(skill_name, version, description, packaging_kind)
VALUES (
    'sd_shared_skill_to_fork',
    '1.0.0',
    'A shared skill that tenants can fork only after a fork grant.',
    'markdown'
)
RETURNING skill_name, version;

INSERT INTO maludb_subject(subject_type, canonical_name)
VALUES ('document', 'shared fork document');

INSERT INTO maludb_verb(canonical_name)
VALUES ('route');

INSERT INTO maludb_skill_subject(skill_id, subject_name, weight)
SELECT skill_id, 'shared fork document', 1.0
FROM maludb_skill
WHERE skill_name = 'sd_shared_skill_to_fork';

INSERT INTO maludb_skill_verb(skill_id, verb_name, weight)
SELECT skill_id, 'route', 1.0
FROM maludb_skill
WHERE skill_name = 'sd_shared_skill_to_fork';

INSERT INTO maludb_skill_keyword(skill_id, keyword)
SELECT skill_id, 'sd shared fork keyword'
FROM maludb_skill
WHERE skill_name = 'sd_shared_skill_to_fork';

DO $body$
DECLARE
    v_shared_skill_id bigint;
BEGIN
    SELECT skill_id
    INTO v_shared_skill_id
    FROM maludb_skill
    WHERE skill_name = 'sd_shared_skill_to_fork';

    PERFORM set_config('maludb_test.shared_skill_id', v_shared_skill_id::text, false);
END;
$body$;

RESET ROLE;
SET ROLE sd_fork_user_a;
SET search_path TO fork_a, maludb_core, public;

DO $body$
DECLARE
    v_private_state text;
    v_private_message text;
    v_absent_state text;
    v_absent_message text;
BEGIN
    BEGIN
        PERFORM maludb_skill_fork(
            p_source_owner_schema => 'fork_source',
            p_source_skill_id => current_setting('maludb_test.shared_skill_id')::bigint,
            p_new_skill_name => 'sd_shared_no_grant_fork_denied'
        );
        RAISE EXCEPTION 'no-grant shared skill fork was not blocked';
    EXCEPTION WHEN no_data_found THEN
        GET STACKED DIAGNOSTICS
            v_private_state = RETURNED_SQLSTATE,
            v_private_message = MESSAGE_TEXT;
        RAISE NOTICE 'OK: no-grant shared skill fork blocked';
    END;

    BEGIN
        PERFORM maludb_skill_fork(
            p_source_owner_schema => 'fork_source',
            p_source_skill_id => current_setting('maludb_test.shared_skill_id')::bigint + 1000000,
            p_new_skill_name => 'sd_absent_shared_fork_denied'
        );
        RAISE EXCEPTION 'absent shared skill fork was not blocked';
    EXCEPTION WHEN no_data_found THEN
        GET STACKED DIAGNOSTICS
            v_absent_state = RETURNED_SQLSTATE,
            v_absent_message = MESSAGE_TEXT;
    END;

    PERFORM set_config(
        'maludb_test.private_absent_fork_same',
        (
            v_private_state = v_absent_state
            AND v_private_message LIKE '%not found or not visible'
            AND v_absent_message LIKE '%not found or not visible'
        )::text,
        false
    );
END;
$body$;

SELECT current_setting('maludb_test.private_absent_fork_same')::boolean
       AS fork_private_absent_indistinguishable;

RESET ROLE;
SET ROLE sd_fork_source_user;
SET search_path TO fork_source, maludb_core, public;

INSERT INTO maludb_skill_access(skill_id, grantee_role, access_level)
SELECT skill_id, 'sd_fork_user_a', 'read'
FROM maludb_skill
WHERE skill_name = 'sd_shared_skill_to_fork';

RESET ROLE;
SET ROLE sd_fork_user_a;
SET search_path TO fork_a, maludb_core, public;

DO $body$
BEGIN
    BEGIN
        PERFORM maludb_skill_fork(
            p_source_owner_schema => 'fork_source',
            p_source_skill_id => (
                SELECT skill_id
                FROM maludb_skill_search(
                    p_query => 'sd shared fork keyword',
                    p_limit => 10,
                    p_include_public => false
                )
                WHERE owner_schema = 'fork_source'
                  AND skill_name = 'sd_shared_skill_to_fork'
                LIMIT 1
            ),
            p_new_skill_name => 'sd_shared_readonly_fork_denied'
        );
        RAISE EXCEPTION 'read-only shared skill fork was not blocked';
    EXCEPTION WHEN insufficient_privilege OR check_violation THEN
        RAISE NOTICE 'OK: read-only shared skill fork blocked';
    END;
END;
$body$;

RESET ROLE;
SET ROLE sd_fork_source_user;
SET search_path TO fork_source, maludb_core, public;

INSERT INTO maludb_skill_access(skill_id, grantee_role, access_level)
SELECT skill_id, 'sd_fork_user_a', 'fork'
FROM maludb_skill
WHERE skill_name = 'sd_shared_skill_to_fork';

RESET ROLE;
SET ROLE sd_fork_user_a;
SET search_path TO fork_a, maludb_core, public;

SELECT maludb_skill_fork(
    p_source_owner_schema => 'fork_source',
    p_source_skill_id => (
        SELECT skill_id
        FROM maludb_skill_search(
            p_query => 'sd shared fork keyword',
            p_limit => 10,
            p_include_public => false
        )
        WHERE owner_schema = 'fork_source'
          AND skill_name = 'sd_shared_skill_to_fork'
        LIMIT 1
    ),
    p_new_skill_name => 'sd_shared_forked_skill'
) IS NOT NULL AS shared_fork_created;

SELECT skill_name, source_owner_schema, source_skill_id IS NOT NULL AS has_source
FROM maludb_skill
WHERE skill_name = 'sd_shared_forked_skill';

SELECT keyword
FROM maludb_skill_keyword
WHERE skill_id = (
    SELECT skill_id
    FROM maludb_skill
    WHERE skill_name = 'sd_shared_forked_skill'
)
ORDER BY keyword;

SELECT subject_name
FROM maludb_skill_subject
WHERE skill_id = (
    SELECT skill_id
    FROM maludb_skill
    WHERE skill_name = 'sd_shared_forked_skill'
)
ORDER BY subject_name;

SELECT verb_name
FROM maludb_skill_verb
WHERE skill_id = (
    SELECT skill_id
    FROM maludb_skill
    WHERE skill_name = 'sd_shared_forked_skill'
)
ORDER BY verb_name;

RESET ROLE;
SET search_path TO maludb_core, public;
SET client_min_messages = WARNING;
\unset ON_ERROR_STOP
DROP SCHEMA fork_a CASCADE;
DROP SCHEMA fork_source CASCADE;
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
    FOREACH v_schema IN ARRAY ARRAY['fork_a'::name, 'fork_source'::name, 'maludb_public'::name] LOOP
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
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'sd_fork_user_a') THEN
        DROP OWNED BY sd_fork_user_a;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'sd_fork_source_user') THEN
        DROP OWNED BY sd_fork_source_user;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'sd_public_curator') THEN
        DROP OWNED BY sd_public_curator;
    END IF;
END;
$body$;
DROP ROLE IF EXISTS sd_fork_user_a;
DROP ROLE IF EXISTS sd_fork_source_user;
DROP ROLE IF EXISTS sd_public_curator;
DELETE FROM maludb_core.malu$svpor_subject_type
WHERE subject_type = 'document' AND NOT system_defined;
