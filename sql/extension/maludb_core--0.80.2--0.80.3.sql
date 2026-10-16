\echo Use "ALTER EXTENSION maludb_core UPDATE TO '0.80.3'" to load this file. \quit

-- =====================================================================
-- maludb_core 0.80.3 -> 0.80.3
--
-- Search-path-safe schema-local facades for editing an existing typed,
-- dated subject<->subject relationship:
--
--   maludb_subject_relationship_close(p_relationship_id, p_valid_to)
--       sets valid_to (e.g. now() for "expire now" or a chosen date);
--       returns true if changed
--   maludb_subject_relationship_delete(p_relationship_id)
--       removes the edge (for relationships entered by mistake); returns
--       the row count
--   maludb_subject_relationship_set_type(p_relationship_id, p_relationship_type)
--       edits relationship_type; returns true if changed
--
-- The writable maludb_subject_relationship view already supports the same
-- operations via plain UPDATE / DELETE; these facades are the parallel
-- search-path-safe call path mirroring maludb_register_episode and
-- maludb_svpor_relationship_create.
--
-- All three are SECURITY INVOKER (RLS + tenant ownership preserved) with
-- `SET search_path = <schema>, maludb_core, pg_temp`. They write directly
-- to maludb_core.malu$svpor_subject_relationship_edge (executor already
-- has CRUD + RLS scopes by owner_schema = current_schema()) rather than
-- wrapping a separate core helper -- the 0.79.0 consolidation deliberately
-- dropped close / delete / list / add_svpor_relationship_edge in favor of
-- the view, and resurrecting them would fight that decision.
-- =====================================================================

CREATE OR REPLACE FUNCTION maludb_core.maludb_core_version() RETURNS text
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$ SELECT '0.80.3'::text $body$;

-- ===== schema-local facades ==========================================
CREATE FUNCTION maludb_core._enable_memory_schema_0803_facade(p_schema name) RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
DECLARE
    v_count integer := 0;
BEGIN
    PERFORM maludb_core._memory_schema_assert_manageable(p_schema);

    -- close (set valid_to; expire now or at a chosen date) -------------
    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_subject_relationship_close', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_subject_relationship_close(
            p_relationship_id bigint,
            p_valid_to        timestamptz DEFAULT now()
        ) RETURNS boolean
        LANGUAGE plpgsql
        SECURITY INVOKER
        SET search_path = %I, maludb_core, pg_temp
        AS $facade$
        DECLARE
            v_schema name := current_schema();
        BEGIN
            IF p_relationship_id IS NULL OR p_valid_to IS NULL THEN
                RAISE EXCEPTION 'relationship_id and valid_to are required'
                    USING ERRCODE = 'invalid_parameter_value';
            END IF;
            UPDATE maludb_core.malu$svpor_subject_relationship_edge
               SET valid_to = p_valid_to
             WHERE owner_schema = v_schema
               AND edge_id = p_relationship_id
               AND valid_to IS DISTINCT FROM p_valid_to;
            RETURN FOUND;
        END;
        $facade$
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_subject_relationship_close(bigint, timestamptz) FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_subject_relationship_close(bigint, timestamptz) TO maludb_memory_admin, maludb_memory_executor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_subject_relationship_close', 'function', 'Schema-local subject<->subject relationship close (set valid_to).');
    v_count := v_count + 1;

    -- delete (relationship entered by mistake) -------------------------
    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_subject_relationship_delete', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_subject_relationship_delete(
            p_relationship_id bigint
        ) RETURNS integer
        LANGUAGE plpgsql
        SECURITY INVOKER
        SET search_path = %I, maludb_core, pg_temp
        AS $facade$
        DECLARE
            v_schema name := current_schema();
            v_count  integer;
        BEGIN
            IF p_relationship_id IS NULL THEN
                RAISE EXCEPTION 'relationship_id is required'
                    USING ERRCODE = 'invalid_parameter_value';
            END IF;
            DELETE FROM maludb_core.malu$svpor_subject_relationship_edge
             WHERE owner_schema = v_schema
               AND edge_id = p_relationship_id;
            GET DIAGNOSTICS v_count = ROW_COUNT;
            RETURN v_count;
        END;
        $facade$
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_subject_relationship_delete(bigint) FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_subject_relationship_delete(bigint) TO maludb_memory_admin, maludb_memory_executor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_subject_relationship_delete', 'function', 'Schema-local subject<->subject relationship delete.');
    v_count := v_count + 1;

    -- set_type (edit relationship_type) --------------------------------
    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_subject_relationship_set_type', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_subject_relationship_set_type(
            p_relationship_id   bigint,
            p_relationship_type text
        ) RETURNS boolean
        LANGUAGE plpgsql
        SECURITY INVOKER
        SET search_path = %I, maludb_core, pg_temp
        AS $facade$
        DECLARE
            v_schema name := current_schema();
        BEGIN
            IF p_relationship_id IS NULL OR p_relationship_type IS NULL OR btrim(p_relationship_type) = '' THEN
                RAISE EXCEPTION 'relationship_id and non-empty relationship_type are required'
                    USING ERRCODE = 'invalid_parameter_value';
            END IF;
            UPDATE maludb_core.malu$svpor_subject_relationship_edge
               SET relationship_type = p_relationship_type
             WHERE owner_schema = v_schema
               AND edge_id = p_relationship_id
               AND relationship_type IS DISTINCT FROM p_relationship_type;
            RETURN FOUND;
        END;
        $facade$
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_subject_relationship_set_type(bigint, text) FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_subject_relationship_set_type(bigint, text) TO maludb_memory_admin, maludb_memory_executor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_subject_relationship_set_type', 'function', 'Schema-local subject<->subject relationship_type edit.');
    v_count := v_count + 1;

    RETURN v_count;
END;
$body$;

REVOKE ALL ON FUNCTION maludb_core._enable_memory_schema_0803_facade(name) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core._enable_memory_schema_0803_facade(name)
    TO maludb_memory_admin, maludb_memory_executor;

-- ===== wire the new builder in (must run last) =======================
-- Same body as 0.80.2 (keeps the conditional managed-view drop that
-- preserves the unmanaged-view safety guard) plus the 0803 builder call.
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

    -- Drop the 0.80 facade-widened views up front so the base builders
    -- recreate them cleanly on re-enable (CREATE OR REPLACE VIEW cannot
    -- shrink a widened view), but ONLY when extension-managed. A tenant's
    -- own same-named view is left in place so the base builder's
    -- _memory_schema_assert_object_slot still refuses to replace it.
    FOREACH v_view IN ARRAY ARRAY['maludb_subject','maludb_memory','maludb_skill','maludb_document']::name[]
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
