\echo Use "ALTER EXTENSION maludb_core UPDATE TO '0.80.1'" to load this file. \quit

-- =====================================================================
-- maludb_core 0.80.0 -> 0.80.1
--
-- Fix: enable_memory_schema() is no longer idempotent after 0.80.0.
--
-- 0.80.0 widened maludb_subject / maludb_project / maludb_person /
-- maludb_stakeholder (archived_at), maludb_memory (issue_closed_at),
-- maludb_skill (markdown), and maludb_document (body_text) by re-creating
-- them in _enable_memory_schema_080_facade -- which runs AFTER the base
-- facade builders that still emit the narrower column lists. The first
-- enable works (adding a trailing column is allowed), but a second enable
-- makes the base builder try to shrink the already-widened view, which
-- CREATE OR REPLACE VIEW rejects ("cannot drop columns from view").
--
-- Fix: drop those views at the start of enable_memory_schema so the base
-- builders always recreate them cleanly and the 080 facade re-widens.
-- Dropping maludb_subject CASCADE also removes its dependent
-- maludb_project / maludb_person / maludb_stakeholder views, all of which
-- the subject facade recreates; the other three views have no dependents.
-- It all happens inside the single enable_memory_schema transaction.
-- =====================================================================

CREATE OR REPLACE FUNCTION maludb_core.maludb_core_version() RETURNS text
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$ SELECT '0.80.1'::text $body$;

CREATE OR REPLACE FUNCTION maludb_core.enable_memory_schema(p_schema name DEFAULT current_schema())
RETURNS TABLE(schema_name name, enabled_version text, object_count integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
DECLARE
    v_enabled_version text := maludb_core.maludb_core_version();
    v_count integer := 0;
BEGIN
    IF p_schema IS NULL THEN
        p_schema := current_schema();
    END IF;

    PERFORM maludb_core._memory_schema_assert_manageable(p_schema);

    -- Drop the views the 0.80 facade widens, so the base builders can
    -- recreate them without hitting "cannot drop columns from view" on
    -- re-enable. CASCADE on maludb_subject also drops the dependent
    -- maludb_project / maludb_person / maludb_stakeholder views.
    EXECUTE format('DROP VIEW IF EXISTS %I.maludb_subject CASCADE', p_schema);
    EXECUTE format('DROP VIEW IF EXISTS %I.maludb_memory CASCADE', p_schema);
    EXECUTE format('DROP VIEW IF EXISTS %I.maludb_skill CASCADE', p_schema);
    EXECUTE format('DROP VIEW IF EXISTS %I.maludb_document CASCADE', p_schema);

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
    v_count := v_count + maludb_core._enable_memory_schema_075_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_076_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_078_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_080_facade(p_schema);
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
