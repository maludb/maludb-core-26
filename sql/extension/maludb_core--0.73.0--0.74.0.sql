\echo Use "ALTER EXTENSION maludb_core UPDATE TO '0.74.0'" to load this file. \quit

-- ---------------------------------------------------------------------
-- maludb_core 0.73.0 -> 0.74.0
-- User-facing onboarding roles for standard PostgreSQL role grants.
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION maludb_core.maludb_core_version() RETURNS text
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$ SELECT '0.74.0'::text $body$;

DO $body$
DECLARE
    v_maludb_is_safe_alias boolean := false;
    v_maludb_oid oid;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'maludb_memory_reader') THEN
        CREATE ROLE maludb_memory_reader NOLOGIN NOINHERIT;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'maludb_read') THEN
        CREATE ROLE maludb_read NOLOGIN INHERIT;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'maludb_user') THEN
        CREATE ROLE maludb_user NOLOGIN INHERIT;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'maludb_admin') THEN
        CREATE ROLE maludb_admin NOLOGIN INHERIT;
    END IF;

    GRANT maludb_memory_reader TO maludb_read;
    GRANT maludb_read TO maludb_user;
    GRANT maludb_memory_executor TO maludb_user;
    GRANT maludb_user TO maludb_admin;
    GRANT maludb_memory_admin TO maludb_admin;

    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'maludb') THEN
        CREATE ROLE maludb NOLOGIN INHERIT;
        COMMENT ON ROLE maludb IS 'MaluDB convenience role: normal read/write user access.';
        v_maludb_is_safe_alias := true;
    ELSE
        SELECT oid
          INTO v_maludb_oid
          FROM pg_roles
         WHERE rolname = 'maludb';

        SELECT obj_description(v_maludb_oid, 'pg_authid') =
               'MaluDB convenience role: normal read/write user access.'
          INTO v_maludb_is_safe_alias;

        IF v_maludb_is_safe_alias THEN
            ALTER ROLE maludb NOLOGIN INHERIT;
        ELSE
            RAISE NOTICE 'role "maludb" already exists and is not the MaluDB convenience role; use role "maludb_user" or maludb_core.grant_memory_access(...)';
        END IF;
    END IF;

    IF v_maludb_is_safe_alias THEN
        GRANT maludb_user TO maludb;
    END IF;

    COMMENT ON ROLE maludb_memory_reader IS 'MaluDB internal non-BYPASSRLS read role for schema-local facades.';
    COMMENT ON ROLE maludb_read IS 'MaluDB convenience role: read-only schema-local access.';
    COMMENT ON ROLE maludb_user IS 'MaluDB convenience role: normal read/write user access.';
    COMMENT ON ROLE maludb_admin IS 'MaluDB convenience role: trusted admin delegation.';
END;
$body$;

GRANT USAGE ON SCHEMA maludb_core
TO maludb_memory_admin,
   maludb_memory_executor,
   maludb_memory_auditor,
   maludb_memory_reader,
   maludb_read,
   maludb_user,
   maludb_admin;

CREATE OR REPLACE FUNCTION maludb_core.grant_memory_access(
    p_role_name name,
    p_access_level text DEFAULT 'write'
) RETURNS name
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
DECLARE
    v_access text := lower(coalesce(nullif(btrim(p_access_level), ''), 'write'));
    v_grant_role name;
BEGIN
    IF p_role_name IS NULL THEN
        RAISE EXCEPTION 'grant_memory_access: role name is required'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = p_role_name) THEN
        RAISE EXCEPTION 'grant_memory_access: role % does not exist', p_role_name
            USING ERRCODE = 'undefined_object';
    END IF;

    v_grant_role := CASE v_access
        WHEN 'read' THEN 'maludb_read'::name
        WHEN 'reader' THEN 'maludb_read'::name
        WHEN 'select' THEN 'maludb_read'::name
        WHEN 'write' THEN 'maludb_user'::name
        WHEN 'user' THEN 'maludb_user'::name
        WHEN 'execute' THEN 'maludb_user'::name
        WHEN 'executor' THEN 'maludb_user'::name
        WHEN 'admin' THEN 'maludb_admin'::name
        WHEN 'administrator' THEN 'maludb_admin'::name
        ELSE NULL::name
    END;

    IF v_grant_role IS NULL THEN
        RAISE EXCEPTION 'grant_memory_access: unsupported access level %. Use read, write, or admin',
            p_access_level
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    EXECUTE format('GRANT %I TO %I', v_grant_role, p_role_name);
    RETURN v_grant_role;
END;
$body$;

REVOKE ALL ON FUNCTION maludb_core.grant_memory_access(name, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core.grant_memory_access(name, text)
TO maludb_memory_admin, maludb_admin;

CREATE OR REPLACE FUNCTION maludb_core._grant_memory_schema_reader_access(p_schema name)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
DECLARE
    v_object record;
    v_count integer := 0;
BEGIN
    PERFORM maludb_core._memory_schema_assert_manageable(p_schema);

    EXECUTE format(
        'GRANT USAGE ON SCHEMA %I TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor, maludb_memory_reader, maludb_read, maludb_user, maludb_admin',
        p_schema
    );

    FOR v_object IN
        SELECT object_name
          FROM maludb_core.malu$enabled_schema_object
         WHERE schema_name = p_schema
           AND object_kind = 'view'
         ORDER BY object_name
    LOOP
        EXECUTE format('GRANT SELECT ON %I.%I TO maludb_memory_reader, maludb_read',
                       p_schema, v_object.object_name);
        v_count := v_count + 1;
    END LOOP;

    IF to_regprocedure(format('%I.maludb_vector_search(text,text,text,maludb_core.malu_vector,integer,text)', p_schema)) IS NOT NULL THEN
        EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_vector_search(text, text, text, maludb_core.malu_vector, integer, text) TO maludb_memory_reader, maludb_read', p_schema);
    END IF;
    IF to_regprocedure(format('%I.maludb_pool_search(text,text,integer,boolean)', p_schema)) IS NOT NULL THEN
        EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_pool_search(text, text, integer, boolean) TO maludb_memory_reader, maludb_read', p_schema);
    END IF;
    IF to_regprocedure(format('%I.maludb_skill_search(text,text,text,maludb_core.malu_vector,integer,boolean)', p_schema)) IS NOT NULL THEN
        EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_skill_search(text, text, text, maludb_core.malu_vector, integer, boolean) TO maludb_memory_reader, maludb_read', p_schema);
    END IF;
    IF to_regprocedure(format('%I.maludb_skill_get(name,bigint)', p_schema)) IS NOT NULL THEN
        EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_skill_get(name, bigint) TO maludb_memory_reader, maludb_read', p_schema);
    END IF;

    RETURN v_count;
END;
$body$;

REVOKE ALL ON FUNCTION maludb_core._grant_memory_schema_reader_access(name) FROM PUBLIC;

CREATE OR REPLACE FUNCTION maludb_core.enable_memory_schema(p_schema name DEFAULT current_schema())
RETURNS TABLE(schema_name name, enabled_version text, object_count integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
DECLARE
    v_count integer := 0;
    v_enabled_version text := maludb_core.maludb_core_version();
BEGIN
    PERFORM maludb_core._memory_schema_assert_manageable(p_schema);

    INSERT INTO maludb_core.malu$enabled_schema(schema_name, enabled_version, enabled_by)
    VALUES (p_schema, v_enabled_version, session_user)
    ON CONFLICT ON CONSTRAINT malu$enabled_schema_pkey DO UPDATE
       SET enabled_version   = EXCLUDED.enabled_version,
           last_refreshed_at = now();

    v_count := v_count + maludb_core._enable_memory_schema_subject_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_core_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_ingest_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_pool_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_ai_facade(p_schema);
    PERFORM maludb_core._grant_memory_schema_reader_access(p_schema);

    schema_name := p_schema;
    enabled_version := v_enabled_version;
    object_count := v_count;
    RETURN NEXT;
END;
$body$;

REVOKE ALL ON FUNCTION maludb_core.enable_memory_schema(name) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core.enable_memory_schema(name)
TO maludb_memory_admin, maludb_memory_executor, maludb_user, maludb_admin;
