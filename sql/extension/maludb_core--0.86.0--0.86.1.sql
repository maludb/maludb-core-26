\echo Use "ALTER EXTENSION maludb_core UPDATE TO '0.86.1'" to load this file. \quit

-- =====================================================================
-- maludb_core 0.86.0 -> 0.86.1
--
-- Fix: re-enable idempotency for maludb_svpor_attribute.
--
-- The 0830 facade creates maludb_svpor_attribute (16 columns); the 0840
-- facade then CREATE OR REPLACE-widens it with ref_source/ref_entity/
-- ref_key (19 columns). On a FIRST enable that is fine (create then
-- widen), but on a RE-enable the 0830 builder runs first and tries to
-- CREATE OR REPLACE the already-19-column view back to 16 columns, which
-- Postgres rejects with "cannot drop columns from view".
--
-- This is the same failure mode the 0.80.1 fix addressed for the
-- facade-widened views (maludb_subject/memory/skill/document) by dropping
-- them up front (CASCADE, only when extension-managed) so the base
-- builders recreate them cleanly. maludb_svpor_attribute was simply
-- missing from that list. Add it.
--
-- No new objects; this only replaces enable_memory_schema. Existing
-- schemas become re-enable-safe the next time enable_memory_schema()
-- runs (and this release makes that run succeed).
-- =====================================================================

CREATE OR REPLACE FUNCTION maludb_core.maludb_core_version() RETURNS text
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$ SELECT '0.86.1'::text $body$;

CREATE OR REPLACE FUNCTION maludb_core.enable_memory_schema(p_schema name DEFAULT current_schema())
RETURNS TABLE(schema_name name, enabled_version text, object_count integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
DECLARE
    v_enabled_version text := maludb_core.maludb_core_version();
    v_count integer := 0;
    v_view  name;
BEGIN
    IF p_schema IS NULL THEN
        p_schema := current_schema();
    END IF;

    PERFORM maludb_core._memory_schema_assert_manageable(p_schema);

    -- Drop the views that a later facade widens, so the earlier builder
    -- can recreate them without hitting "cannot drop columns from view"
    -- on re-enable -- but ONLY when extension-managed (recorded in
    -- malu$enabled_schema_object); a tenant's own same-named view is left
    -- in place so the builder's assert_object_slot still refuses to
    -- replace it. maludb_svpor_attribute is widened by the 0840 facade
    -- (ref_source/ref_entity/ref_key), so it joins the list here.
    FOREACH v_view IN ARRAY ARRAY['maludb_subject','maludb_memory','maludb_skill','maludb_document','maludb_svpor_attribute']::name[]
    LOOP
        IF EXISTS (
            SELECT 1 FROM maludb_core.malu$enabled_schema_object o
             WHERE o.schema_name = p_schema
               AND o.object_name = v_view
               AND o.object_kind = 'view'
        ) THEN
            EXECUTE format('DROP VIEW IF EXISTS %I.%I CASCADE', p_schema, v_view);
        END IF;
    END LOOP;

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
    v_count := v_count + maludb_core._enable_memory_schema_0802_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_0803_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_0810_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_0820_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_0830_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_0840_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_0850_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_0860_facade(p_schema);
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
