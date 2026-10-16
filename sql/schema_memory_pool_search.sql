\set ECHO all
\pset format unaligned
SET client_min_messages = WARNING;
CREATE EXTENSION IF NOT EXISTS maludb_core CASCADE;
DO $body$
DECLARE
    v_schema name;
    v_tables text[] := ARRAY[
        'malu$active_memory_pool_access',
        'malu$active_memory_pool_tag',
        'malu$active_memory_pool_member',
        'malu$pool_presence_event',
        'malu$pool_presence',
        'malu$active_memory_pool',
        'malu$document_tag',
        'malu$ingest_extraction',
        'malu$document',
        'malu$raw_ingest',
        'malu$vector_compartment',
        'malu$vector_subject',
        'malu$vector_verb',
        'malu$svpor_subject',
        'malu$svpor_verb',
        'malu$memory_detail_object',
        'malu$memory',
        'malu$source_package'
    ];
    v_table text;
BEGIN
    FOREACH v_schema IN ARRAY ARRAY['smp'::name, 'smp_foreign'::name] LOOP
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
        IF to_regclass('maludb_core.malu$enabled_schema_object') IS NOT NULL THEN
            DELETE FROM maludb_core.malu$enabled_schema_object WHERE schema_name = v_schema;
        END IF;
        IF to_regclass('maludb_core.malu$enabled_schema') IS NOT NULL THEN
            DELETE FROM maludb_core.malu$enabled_schema WHERE schema_name = v_schema;
        END IF;
        EXECUTE format('DROP SCHEMA IF EXISTS %I CASCADE', v_schema);
    END LOOP;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'smp_user') THEN
        DROP OWNED BY smp_user;
    END IF;
END;
$body$;
SET search_path TO maludb_core, public;
SET client_min_messages = NOTICE;

DROP SCHEMA IF EXISTS smp CASCADE;
DROP ROLE IF EXISTS smp_user;

CREATE ROLE smp_user NOLOGIN;
GRANT maludb_memory_executor TO smp_user;
GRANT USAGE ON SCHEMA maludb_core TO smp_user;
CREATE SCHEMA smp AUTHORIZATION smp_user;

SET ROLE smp_user;
SET search_path TO smp, maludb_core, public;

SELECT object_count AS enable_object_count
FROM maludb_core.enable_memory_schema();

INSERT INTO maludb_subject(subject_type, canonical_name, aliases, description)
VALUES ('project', 'zozocal', ARRAY['zzc'], 'schema-memory pool search project')
RETURNING subject_type, canonical_name;

INSERT INTO maludb_verb(canonical_name, aliases, description)
VALUES ('schema', ARRAY['schemas'], 'schema memory pool verb')
RETURNING canonical_name;

INSERT INTO maludb_memory(memory_kind, title, summary, payload_jsonb)
VALUES (
    'lesson',
    'Zozocal schema memory pool lesson',
    'Zozocal pool search should find scoped schema memory.',
    '{"project":"zozocal","verb":"schema"}'::jsonb
)
RETURNING memory_kind, title;

INSERT INTO maludb_memory_pool(pool_name, task_objective)
VALUES ('zozocal-schema', 'Find schema memory for zozocal')
RETURNING pool_name, task_objective;

SELECT maludb_pool_add_named_member('zozocal-schema', 'project', 'zozocal', 0.91)
       IS NOT NULL AS project_member_added;

SELECT maludb_core.pool_add_reference(
    p_pool_id            => (SELECT pool_id FROM maludb_memory_pool WHERE pool_name = 'zozocal-schema'),
    p_member_kind        => 'memory',
    p_member_object_type => 'memory',
    p_member_object_id   => (SELECT memory_id FROM maludb_memory WHERE title = 'Zozocal schema memory pool lesson'),
    p_confidence         => 0.87
) IS NOT NULL AS memory_member_added;

CREATE TABLE "malu$memory" (
    memory_id   bigint,
    title       text,
    memory_kind text,
    summary     text,
    fts_tsv     tsvector
);

INSERT INTO "malu$memory"(memory_id, title, memory_kind, summary, fts_tsv)
SELECT memory_id,
       'Shadowed tenant memory',
       memory_kind,
       'shadowed tenant relation should not affect pool search',
       to_tsvector('english', 'scoped schema memory')
FROM maludb_memory
WHERE title = 'Zozocal schema memory pool lesson';

SELECT member_kind, member_object_type, confidence
FROM maludb_memory_pool_member
ORDER BY member_kind, member_object_type;

SELECT pool_name, canonical_name, confidence
FROM maludb_pool_subject
ORDER BY canonical_name;

SELECT object_type, title_or_subject, source
FROM maludb_pool_search('zozocal-schema', 'scoped schema memory', 5, false)
ORDER BY rank DESC, object_id;

SELECT object_type, title_or_subject, source
FROM maludb_pool_search('zozocal-schema', NULL, 5, true)
ORDER BY object_type, object_id;

DROP TABLE "malu$memory";

INSERT INTO maludb_memory_pool_access(pool_id, grantee_role, access_level)
SELECT pool_id, 'smp_user'::name, 'read'
FROM maludb_memory_pool
WHERE pool_name = 'zozocal-schema'
RETURNING grantee_role, access_level;

UPDATE maludb_memory_pool_access
   SET revoked_at = now()
 WHERE grantee_role = 'smp_user'
   AND access_level = 'read';

INSERT INTO maludb_memory_pool_access(pool_id, grantee_role, access_level)
SELECT pool_id, 'smp_user'::name, 'read'
FROM maludb_memory_pool
WHERE pool_name = 'zozocal-schema'
RETURNING grantee_role, access_level;

RESET ROLE;
SET search_path TO maludb_core, public;

DO $body$
DECLARE
    v_pool_id         bigint;
    v_foreign_pool_id bigint;
    v_member_id       bigint;
    v_foreign_memory_id bigint;
BEGIN
    SELECT pool_id INTO v_pool_id
      FROM maludb_core.malu$active_memory_pool
     WHERE owner_schema = 'smp'
       AND pool_name = 'zozocal-schema';

    INSERT INTO maludb_core.malu$active_memory_pool(owner_schema, pool_name)
    VALUES ('smp_foreign', 'foreign-pool')
    RETURNING pool_id INTO v_foreign_pool_id;

    BEGIN
        INSERT INTO maludb_core.malu$active_memory_pool_member
            (owner_schema, pool_id, member_kind, member_object_type, member_object_id)
        VALUES ('smp', v_foreign_pool_id, 'memory', 'memory', 1);
        RAISE EXCEPTION 'cross-tenant pool member was not blocked';
    EXCEPTION WHEN foreign_key_violation THEN
        RAISE NOTICE 'cross-tenant pool member blocked';
    END;

    SELECT member_id INTO v_member_id
      FROM maludb_core.malu$active_memory_pool_member
     WHERE owner_schema = 'smp'
     ORDER BY member_id
     LIMIT 1;

    BEGIN
        INSERT INTO maludb_core.malu$active_memory_pool_member
            (owner_schema, pool_id, member_kind, member_object_type, member_object_id,
             promoted_from_member_id)
        VALUES ('smp_foreign', v_foreign_pool_id, 'memory', 'memory', 1, v_member_id);
        RAISE EXCEPTION 'cross-tenant promoted_from member was not blocked';
    EXCEPTION WHEN foreign_key_violation THEN
        RAISE NOTICE 'cross-tenant promoted_from member blocked';
    END;

    INSERT INTO maludb_core.malu$memory(owner_schema, memory_kind, title, summary)
    VALUES ('smp_foreign', 'lesson', 'Foreign forged memory', 'foreign forged memory')
    RETURNING memory_id INTO v_foreign_memory_id;

    INSERT INTO maludb_core.malu$active_memory_pool_member
        (owner_schema, pool_id, member_kind, member_object_type, member_object_id)
    VALUES ('smp', v_pool_id, 'memory', 'memory', v_foreign_memory_id);
END;
$body$;

SET ROLE smp_user;
SET search_path TO smp, maludb_core, public;

SELECT count(*) AS forged_foreign_search_hits
FROM maludb_pool_search('zozocal-schema', 'foreign forged memory', 10, true)
WHERE title_or_subject = 'Foreign forged memory';

RESET ROLE;
SET search_path TO maludb_core, public;

DROP SCHEMA smp CASCADE;

DO $body$
DECLARE
    v_schema name := 'smp';
    v_tables text[] := ARRAY[
        'malu$active_memory_pool_access',
        'malu$active_memory_pool_tag',
        'malu$active_memory_pool_member',
        'malu$pool_presence_event',
        'malu$pool_presence',
        'malu$active_memory_pool',
        'malu$document_tag',
        'malu$ingest_extraction',
        'malu$document',
        'malu$raw_ingest',
        'malu$vector_compartment',
        'malu$vector_subject',
        'malu$vector_verb',
        'malu$svpor_subject',
        'malu$svpor_verb',
        'malu$memory_detail_object',
        'malu$memory',
        'malu$source_package'
    ];
    v_table text;
BEGIN
    FOREACH v_schema IN ARRAY ARRAY['smp'::name, 'smp_foreign'::name] LOOP
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
        IF to_regclass('maludb_core.malu$enabled_schema_object') IS NOT NULL THEN
            DELETE FROM maludb_core.malu$enabled_schema_object WHERE schema_name = v_schema;
        END IF;
        IF to_regclass('maludb_core.malu$enabled_schema') IS NOT NULL THEN
            DELETE FROM maludb_core.malu$enabled_schema WHERE schema_name = v_schema;
        END IF;
    END LOOP;
END;
$body$;

DROP OWNED BY smp_user;
DROP ROLE smp_user;
