\set ECHO none
\pset format unaligned
SET client_min_messages = WARNING;
CREATE EXTENSION IF NOT EXISTS maludb_core CASCADE;

DO $body$
DECLARE
    v_role name;
BEGIN
    FOREACH v_role IN ARRAY ARRAY[
        'onboard_schema_owner'::name,
        'onboard_reader'::name,
        'onboard_writer'::name,
        'onboard_short_writer'::name,
        'onboard_admin'::name,
        'onboard_helper_reader'::name
    ] LOOP
        IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = v_role) THEN
            EXECUTE format('DROP OWNED BY %I', v_role);
        END IF;
    END LOOP;

    DELETE FROM maludb_core.malu$enabled_schema_object WHERE schema_name = 'onboard';
    DELETE FROM maludb_core.malu$enabled_schema WHERE schema_name = 'onboard';
    DELETE FROM maludb_core.malu$svpor_subject WHERE owner_schema = 'onboard';

    IF to_regnamespace('onboard') IS NOT NULL THEN
        EXECUTE 'DROP SCHEMA onboard CASCADE';
    END IF;
END;
$body$;

DROP ROLE IF EXISTS onboard_schema_owner;
DROP ROLE IF EXISTS onboard_reader;
DROP ROLE IF EXISTS onboard_writer;
DROP ROLE IF EXISTS onboard_short_writer;
DROP ROLE IF EXISTS onboard_admin;
DROP ROLE IF EXISTS onboard_helper_reader;

CREATE ROLE onboard_schema_owner NOLOGIN;
CREATE ROLE onboard_reader NOLOGIN;
CREATE ROLE onboard_writer NOLOGIN;
CREATE ROLE onboard_short_writer NOLOGIN;
CREATE ROLE onboard_admin NOLOGIN;
CREATE ROLE onboard_helper_reader NOLOGIN;

SELECT bool_and(r.oid IS NOT NULL) AS onboarding_roles_exist
FROM unnest(ARRAY[
    'maludb_memory_reader',
    'maludb_read',
    'maludb_user',
    'maludb_admin'
]) AS expected(rolname)
LEFT JOIN pg_roles r USING (rolname);

GRANT maludb_user TO onboard_schema_owner;
GRANT maludb_read TO onboard_reader;
GRANT maludb_user TO onboard_writer;
GRANT maludb_admin TO onboard_admin;

SELECT maludb_core.grant_memory_access('onboard_helper_reader', 'read') AS helper_granted_role;

DO $body$
DECLARE
    v_safe_short_alias boolean;
BEGIN
    SELECT EXISTS (
        SELECT 1
          FROM pg_roles
         WHERE rolname = 'maludb'
           AND NOT rolcanlogin
           AND NOT rolsuper
           AND NOT rolbypassrls
    ) INTO v_safe_short_alias;

    IF v_safe_short_alias THEN
        GRANT maludb TO onboard_short_writer;
    ELSE
        GRANT maludb_user TO onboard_short_writer;
    END IF;
END;
$body$;

SELECT pg_has_role('onboard_schema_owner', 'maludb_memory_executor', 'member') AS owner_has_executor,
       pg_has_role('onboard_reader', 'maludb_memory_reader', 'member') AS reader_has_reader,
       pg_has_role('onboard_writer', 'maludb_memory_executor', 'member') AS writer_has_executor,
       pg_has_role('onboard_admin', 'maludb_memory_admin', 'member') AS admin_has_admin;

CREATE SCHEMA onboard AUTHORIZATION onboard_schema_owner;

SET ROLE onboard_schema_owner;
SET search_path TO onboard, maludb_core, public;

SELECT object_count >= 48 AS schema_enabled
FROM maludb_core.enable_memory_schema();

INSERT INTO maludb_project(subject_type, canonical_name)
VALUES ('project', 'onboarding project');

RESET ROLE;

SET ROLE onboard_reader;
SET search_path TO onboard, maludb_core, public;

SELECT canonical_name AS reader_project
FROM maludb_project
ORDER BY canonical_name;

INSERT INTO maludb_project(subject_type, canonical_name)
VALUES ('project', 'reader should not write');

RESET ROLE;

SET ROLE onboard_helper_reader;
SET search_path TO onboard, maludb_core, public;

SELECT canonical_name AS helper_reader_project
FROM maludb_project
ORDER BY canonical_name;

RESET ROLE;

SET ROLE onboard_writer;
SET search_path TO onboard, maludb_core, public;

INSERT INTO maludb_project(subject_type, canonical_name)
VALUES ('project', 'writer project');

SELECT count(*) AS writer_project_count
FROM maludb_project;

RESET ROLE;

SET ROLE onboard_short_writer;
SET search_path TO onboard, maludb_core, public;

INSERT INTO maludb_project(subject_type, canonical_name)
VALUES ('project', 'short writer project');

SELECT count(*) AS short_writer_project_count
FROM maludb_project;

RESET ROLE;

DELETE FROM maludb_core.malu$enabled_schema_object WHERE schema_name = 'onboard';
DELETE FROM maludb_core.malu$enabled_schema WHERE schema_name = 'onboard';
DELETE FROM maludb_core.malu$svpor_subject WHERE owner_schema = 'onboard';

DROP SCHEMA onboard CASCADE;
DROP OWNED BY onboard_schema_owner;
DROP OWNED BY onboard_reader;
DROP OWNED BY onboard_writer;
DROP OWNED BY onboard_short_writer;
DROP OWNED BY onboard_admin;
DROP OWNED BY onboard_helper_reader;
DROP ROLE onboard_schema_owner;
DROP ROLE onboard_reader;
DROP ROLE onboard_writer;
DROP ROLE onboard_short_writer;
DROP ROLE onboard_admin;
DROP ROLE onboard_helper_reader;
