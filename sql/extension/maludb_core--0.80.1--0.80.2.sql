\echo Use "ALTER EXTENSION maludb_core UPDATE TO '0.80.2'" to load this file. \quit

-- =====================================================================
-- maludb_core 0.80.1 -> 0.80.2
--
-- Closes the last two API-project requests (db-requirements.md §1.2, §6):
--
--   §1.2  register_svpor_relationship is now idempotent and FK-validates
--         its endpoints. The create side previously inserted a fresh edge
--         every call and never checked that the subject/verb existed
--         (malu$relationship_edge has no real FK to the SVPOR tables), so
--         the API had to dedupe + existence-check itself. Now an identical
--         (source, target, relationship_type) edge in the same tenant is
--         returned as-is, and a dangling endpoint raises foreign_key_violation.
--
--   §6    New schema-local maludb_register_episode(...) facade: a thin,
--         search-path-safe wrapper over maludb_core.register_episode so the
--         REST endpoint can drop its `SET LOCAL search_path` dance. It is
--         SECURITY INVOKER with `SET search_path = <schema>, maludb_core,
--         pg_temp` -- NOT security definer -- so episodes stay tenant-owned
--         (current_schema() and RLS resolve to the caller's schema, exactly
--         as the direct register_episode call does today).
--
-- Also hardens 0.80.1's enable_memory_schema idempotency fix: 0.80.1 dropped
-- maludb_subject / maludb_memory / maludb_skill / maludb_document
-- unconditionally up front, which silently destroyed a tenant's own
-- same-named view and defeated the "refuse to replace an unmanaged view"
-- guard. enable_memory_schema now drops those four views only when they are
-- extension-managed (recorded in malu$enabled_schema_object), so re-enable
-- stays idempotent while an unmanaged collision is still refused.
--
-- Existing schemas pick up maludb_register_episode by re-running
-- maludb_core.enable_memory_schema(); the register_svpor_relationship fix is
-- in the shared core function and applies immediately.
-- =====================================================================

CREATE OR REPLACE FUNCTION maludb_core.maludb_core_version() RETURNS text
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$ SELECT '0.80.2'::text $body$;

-- ===== §1.2. idempotent, FK-validating SVPOR relationship create ======
CREATE OR REPLACE FUNCTION maludb_core.register_svpor_relationship(
    p_source_kind text,
    p_source_id bigint,
    p_target_kind text,
    p_target_id bigint,
    p_relationship_type text,
    p_label text DEFAULT NULL,
    p_edge_jsonb jsonb DEFAULT NULL,
    p_confidence numeric DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql
SECURITY INVOKER
AS $body$
DECLARE
    v_source_kind text := lower(btrim(COALESCE(p_source_kind, '')));
    v_target_kind text := lower(btrim(COALESCE(p_target_kind, '')));
    v_schema      name := current_schema();
    v_edge_id     bigint;
BEGIN
    IF v_source_kind NOT IN ('subject','verb') OR v_target_kind NOT IN ('subject','verb') THEN
        RAISE EXCEPTION 'SVPOR relationships support only subject and verb endpoints'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    -- FK-validate both endpoints exist in this tenant's SVPOR graph. The
    -- polymorphic edge table carries no real FK to malu$svpor_subject /
    -- malu$svpor_verb, so a dangling id would otherwise be recorded as an
    -- orphan edge. RLS already scopes these tables to current_schema();
    -- the explicit owner_schema predicate keeps the intent obvious.
    IF (v_source_kind = 'subject'
            AND NOT EXISTS (SELECT 1 FROM maludb_core.malu$svpor_subject
                             WHERE owner_schema = v_schema AND subject_id = p_source_id))
       OR (v_source_kind = 'verb'
            AND NOT EXISTS (SELECT 1 FROM maludb_core.malu$svpor_verb
                             WHERE owner_schema = v_schema AND verb_id = p_source_id)) THEN
        RAISE EXCEPTION 'SVPOR source % % not found in schema %', v_source_kind, p_source_id, v_schema
            USING ERRCODE = 'foreign_key_violation';
    END IF;

    IF (v_target_kind = 'subject'
            AND NOT EXISTS (SELECT 1 FROM maludb_core.malu$svpor_subject
                             WHERE owner_schema = v_schema AND subject_id = p_target_id))
       OR (v_target_kind = 'verb'
            AND NOT EXISTS (SELECT 1 FROM maludb_core.malu$svpor_verb
                             WHERE owner_schema = v_schema AND verb_id = p_target_id)) THEN
        RAISE EXCEPTION 'SVPOR target % % not found in schema %', v_target_kind, p_target_id, v_schema
            USING ERRCODE = 'foreign_key_violation';
    END IF;

    -- Idempotent: an identical (source, target, relationship_type) edge in
    -- this tenant is returned as-is rather than duplicated. label / edge_jsonb
    -- / confidence are not part of the identity -- a repeated link is the
    -- same link.
    SELECT e.edge_id INTO v_edge_id
      FROM maludb_core.malu$relationship_edge e
     WHERE e.owner_schema       = v_schema
       AND e.source_object_type = v_source_kind
       AND e.source_object_id   = p_source_id
       AND e.target_object_type = v_target_kind
       AND e.target_object_id   = p_target_id
       AND e.relationship_type  = p_relationship_type
     ORDER BY e.edge_id
     LIMIT 1;
    IF v_edge_id IS NOT NULL THEN
        RETURN v_edge_id;
    END IF;

    RETURN maludb_core.register_relationship_edge(
        v_source_kind,
        p_source_id,
        v_target_kind,
        p_target_id,
        p_relationship_type,
        p_label,
        COALESCE(p_edge_jsonb, '{}'::jsonb),
        p_confidence
    );
END;
$body$;

REVOKE ALL ON FUNCTION maludb_core.register_svpor_relationship(text, bigint, text, bigint, text, text, jsonb, numeric) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core.register_svpor_relationship(text, bigint, text, bigint, text, text, jsonb, numeric)
    TO maludb_memory_admin, maludb_memory_executor;

-- ===== §6. schema-local facade: search-path-safe episode writer ========
CREATE FUNCTION maludb_core._enable_memory_schema_0802_facade(p_schema name) RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
DECLARE
    v_count integer := 0;
BEGIN
    PERFORM maludb_core._memory_schema_assert_manageable(p_schema);

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_register_episode', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_register_episode(
            p_episode_kind   text,
            p_title          text,
            p_summary        text DEFAULT NULL,
            p_payload_jsonb  jsonb DEFAULT '{}'::jsonb,
            p_occurred_at    timestamptz DEFAULT NULL,
            p_occurred_until timestamptz DEFAULT NULL,
            p_sensitivity    text DEFAULT 'internal'
        ) RETURNS bigint
        LANGUAGE sql
        SECURITY INVOKER
        SET search_path = %I, maludb_core, pg_temp
        AS $facade$
            SELECT maludb_core.register_episode(
                p_episode_kind, p_title, p_summary, p_payload_jsonb,
                p_occurred_at, p_occurred_until, p_sensitivity
            )
        $facade$
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_register_episode(text, text, text, jsonb, timestamptz, timestamptz, text) FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_register_episode(text, text, text, jsonb, timestamptz, timestamptz, text) TO maludb_memory_admin, maludb_memory_executor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_register_episode', 'function', 'Schema-local search-path-safe episode writer.');
    v_count := v_count + 1;

    RETURN v_count;
END;
$body$;

REVOKE ALL ON FUNCTION maludb_core._enable_memory_schema_0802_facade(name) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core._enable_memory_schema_0802_facade(name)
    TO maludb_memory_admin, maludb_memory_executor;

-- ===== wire the new builder in (must run last) =======================
-- Same body as 0.80.1 (keeps the up-front view drops that make re-enable
-- idempotent) plus the 0802 builder call.
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

    -- Drop the views the 0.80 facade widens, so the base builders can
    -- recreate them without hitting "cannot drop columns from view" on
    -- re-enable -- but ONLY when they are extension-managed (recorded in
    -- malu$enabled_schema_object). A same-named view a tenant created
    -- themselves is left in place so the base builder's
    -- _memory_schema_assert_object_slot still refuses to replace it,
    -- instead of silently dropping it. (0.80.1 dropped these
    -- unconditionally, which defeated that guard.) CASCADE on
    -- maludb_subject also drops the dependent maludb_project /
    -- maludb_person / maludb_stakeholder views, which the subject facade
    -- recreates.
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
