\echo Use "ALTER EXTENSION maludb_core UPDATE TO '0.90.0'" to load this file. \quit

-- =====================================================================
-- maludb_core 0.89.0 -> 0.90.0
--
-- Two-way binding between a relational record and a MaluDB graph object,
-- as a focused pair of helpers over the 0.84.0 external-reference
-- attribute store (malu$svpor_attribute.ref_source/ref_entity/ref_key):
--
--   maludb_link_create(target_kind, target_id, source, entity, key, ...)
--       -> writes the graph->external back-pointer (a reference attribute)
--          on an EXISTING node/edge; returns the link's attribute_id.
--   maludb_link_resolve(source, entity, key)
--       -> reverse lookup: the MaluDB object(s) that reference an external
--          record, backed by malu$svpor_attribute_ref_idx (owner_schema,
--          ref_source, ref_entity, ref_key). Returns rows.
--
-- The two-way relationship is two cooperating soft pointers -- hard FK in
-- NEITHER direction (maludb_core is its own RLS-scoped schema, and the
-- external table may live in another schema / database / system):
--   * relational -> graph : a plain bigint column on the app's OWN table
--                           (projects.subject_id, tasks.statement_id),
--                           written by the app with the id it already has.
--                           This is the fast forward path used by every
--                           "find related memories" button; it never joins
--                           the attribute store, and memory_search does not
--                           read it either.
--   * graph -> relational : the reference attribute these helpers manage
--                           (the reverse index + display-time resolution).
--
-- These are link-ONLY: they do not create the node. The single-POST
-- "create the node + write the back-pointer" flow is one transaction in
-- the app/API:
--   BEGIN;
--     id := <schema>.register_svpor_subject(...);   -- or _statement_create
--     <schema>.maludb_link_create('subject', id, 'pm','projects','42', ...);
--   COMMIT;                          -- then store id in projects.subject_id
--
-- maludb_link_create is a thin wrapper over register_svpor_attribute
-- (0.84.0): it REQUIRES the (source, entity, key) triplet -- that is what
-- makes it a link and not a generic attribute -- maps p_label -> value_text
-- (cached display label) and p_snapshot -> value_jsonb (cached snapshot),
-- and inherits target validation + the (owner_schema, target_kind,
-- target_id, attr_name) upsert. The default attr_name 'external_ref' covers
-- the common single-link case; pass a distinct attr_name (e.g. 'hr_person',
-- 'jira_epic') to attach more than one external link to the same object.
--
-- provenance defaults to 'provided' (an app-authoritative link). An agent
-- proposing a match passes 'suggested'; a human later flips it to
-- 'accepted' via the existing maludb_svpor_attribute_set_provenance facade.
--
-- Additive: two new functions + two schema-local facades. No model or
-- table changes. Existing schemas pick up the facades by re-running
-- maludb_core.enable_memory_schema().
-- =====================================================================

CREATE OR REPLACE FUNCTION maludb_core.maludb_core_version() RETURNS text
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$ SELECT '0.90.0'::text $body$;

-- ===== link_create -- write the graph->external back-pointer ========
CREATE FUNCTION maludb_core.link_create(
    p_target_kind text,
    p_target_id   bigint,
    p_ref_source  text,
    p_ref_entity  text,
    p_ref_key     text,
    p_attr_name   text    DEFAULT 'external_ref',
    p_label       text    DEFAULT NULL,
    p_snapshot    jsonb   DEFAULT NULL,
    p_provenance  text    DEFAULT 'provided',
    p_confidence  numeric DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql
SECURITY INVOKER
AS $body$
DECLARE
    v_source text := NULLIF(btrim(COALESCE(p_ref_source, '')), '');
    v_entity text := NULLIF(btrim(COALESCE(p_ref_entity, '')), '');
    v_key    text := NULLIF(btrim(COALESCE(p_ref_key,    '')), '');
    v_attr   text := COALESCE(NULLIF(btrim(COALESCE(p_attr_name, '')), ''), 'external_ref');
BEGIN
    IF v_source IS NULL OR v_entity IS NULL OR v_key IS NULL THEN
        RAISE EXCEPTION 'link_create: ref_source, ref_entity and ref_key are all required'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    -- target existence, the (owner_schema, target_kind, target_id, attr_name)
    -- upsert, and the returned attribute_id are all handled by
    -- register_svpor_attribute (0.84.0), which is SECURITY INVOKER and scopes
    -- by current_schema() -- preserved through the schema-local facade.
    RETURN maludb_core.register_svpor_attribute(
        p_target_kind => p_target_kind,
        p_target_id   => p_target_id,
        p_attr_name   => v_attr,
        p_value_text  => p_label,
        p_value_jsonb => p_snapshot,
        p_provenance  => p_provenance,
        p_confidence  => p_confidence,
        p_ref_source  => v_source,
        p_ref_entity  => v_entity,
        p_ref_key     => v_key);
END;
$body$;
REVOKE ALL ON FUNCTION maludb_core.link_create(text, bigint, text, text, text, text, text, jsonb, text, numeric) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core.link_create(text, bigint, text, text, text, text, text, jsonb, text, numeric)
    TO maludb_memory_admin, maludb_memory_executor;

-- ===== link_resolve -- reverse lookup: external record -> object(s) =
-- SECURITY INVOKER, scopes by current_schema() (like attributes_jsonb). The
-- (owner_schema, ref_source, ref_entity, ref_key) partial index backs the
-- lookup. ref_entity is an OPTIONAL filter (NULL -> match any entity); a
-- single external record may be referenced by more than one object (e.g.
-- under different attr_names), so this returns a set.
CREATE FUNCTION maludb_core.link_resolve(
    p_ref_source text,
    p_ref_entity text DEFAULT NULL,
    p_ref_key    text DEFAULT NULL
) RETURNS TABLE(
    target_kind  text,
    target_id    bigint,
    attr_name    text,
    attribute_id bigint,
    label        text,
    provenance   text,
    confidence   numeric
)
LANGUAGE plpgsql STABLE
SECURITY INVOKER
AS $body$
DECLARE
    v_source text := NULLIF(btrim(COALESCE(p_ref_source, '')), '');
    v_entity text := NULLIF(btrim(COALESCE(p_ref_entity, '')), '');
    v_key    text := NULLIF(btrim(COALESCE(p_ref_key,    '')), '');
BEGIN
    IF v_source IS NULL OR v_key IS NULL THEN
        RAISE EXCEPTION 'link_resolve: ref_source and ref_key are required'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    RETURN QUERY
        SELECT a.target_kind, a.target_id, a.attr_name, a.attribute_id,
               a.value_text AS label, a.provenance, a.confidence
          FROM maludb_core.malu$svpor_attribute a
         WHERE a.owner_schema = current_schema()
           AND a.ref_source = v_source
           AND a.ref_key    = v_key
           AND (v_entity IS NULL OR a.ref_entity = v_entity)
         ORDER BY a.target_kind, a.target_id, a.attr_name;
END;
$body$;
REVOKE ALL ON FUNCTION maludb_core.link_resolve(text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core.link_resolve(text, text, text)
    TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;

-- ===== 0.90.0 schema-local facade builder ===========================
CREATE FUNCTION maludb_core._enable_memory_schema_0900_facade(p_schema name) RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
DECLARE
    v_count integer := 0;
BEGIN
    PERFORM maludb_core._memory_schema_assert_manageable(p_schema);

    -- maludb_link_create(...) -> attribute_id (the link record id)
    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_link_create', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_link_create(
            p_target_kind text, p_target_id bigint,
            p_ref_source text, p_ref_entity text, p_ref_key text,
            p_attr_name text DEFAULT 'external_ref', p_label text DEFAULT NULL,
            p_snapshot jsonb DEFAULT NULL, p_provenance text DEFAULT 'provided',
            p_confidence numeric DEFAULT NULL
        ) RETURNS bigint LANGUAGE sql SECURITY INVOKER
        SET search_path = %I, maludb_core, pg_temp
        AS $facade$ SELECT maludb_core.link_create(
            p_target_kind, p_target_id, p_ref_source, p_ref_entity, p_ref_key,
            p_attr_name, p_label, p_snapshot, p_provenance, p_confidence) $facade$
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_link_create(text, bigint, text, text, text, text, text, jsonb, text, numeric) FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_link_create(text, bigint, text, text, text, text, text, jsonb, text, numeric) TO maludb_memory_admin, maludb_memory_executor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_link_create', 'function', 'Bind a graph object to an external relational record (writes the reverse-pointer reference attribute).');
    v_count := v_count + 1;

    -- maludb_link_resolve(...) -> the object(s) for an external record
    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_link_resolve', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_link_resolve(
            p_ref_source text, p_ref_entity text DEFAULT NULL, p_ref_key text DEFAULT NULL
        ) RETURNS TABLE(
            target_kind text, target_id bigint, attr_name text, attribute_id bigint,
            label text, provenance text, confidence numeric
        ) LANGUAGE sql STABLE SECURITY INVOKER
        SET search_path = %I, maludb_core, pg_temp
        AS $facade$ SELECT * FROM maludb_core.link_resolve(p_ref_source, p_ref_entity, p_ref_key) $facade$
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_link_resolve(text, text, text) FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_link_resolve(text, text, text) TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_link_resolve', 'function', 'Reverse lookup: MaluDB object(s) bound to an external relational record.');
    v_count := v_count + 1;

    RETURN v_count;
END;
$body$;

REVOKE ALL ON FUNCTION maludb_core._enable_memory_schema_0900_facade(name) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core._enable_memory_schema_0900_facade(name)
    TO maludb_memory_admin, maludb_memory_executor;

-- ===== wire the 0900 facade into enable_memory_schema ===============
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
    v_count := v_count + maludb_core._enable_memory_schema_0870_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_0880_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_0890_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_0900_facade(p_schema);
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
