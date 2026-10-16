\echo Use "ALTER EXTENSION maludb_core UPDATE TO '0.79.0'" to load this file. \quit

-- =====================================================================
-- maludb_core 0.78.0 -> 0.79.0
--
-- Consolidate subject relationships into a SINGLE object.
--
-- 0.78.0 modelled relationships as two things: a symmetric "these two
-- are linked" header (maludb_related_subject) with a trigger-synced
-- relationship_type, plus directed, dated edges (maludb_related_subject
-- _edge) governed by a relationship-type catalog. That split made the
-- common case -- "A is <type> of B from D1 to D2" -- awkward to store
-- and query.
--
-- 0.79.0 keeps only the directed, dated relationship and exposes it as
-- maludb_subject_relationship:
--   * relationship_type is now free text and required (NOT NULL); the
--     malu$svpor_relationship_type catalog and its FK are removed.
--   * the symmetric malu$svpor_subject_relationship table and its
--     maludb_related_subject view + add/list/delete helpers are removed
--     (no data migration), along with the header auto-sync trigger.
--   * the directed rows recorded in 0.78.0 are preserved (storage table
--     malu$svpor_subject_relationship_edge is kept; only the catalog FK
--     is dropped).
--   * schema-local facade is one view, maludb_subject_relationship
--     (plain INSERT/SELECT/UPDATE/DELETE), plus a point-in-time reader
--     maludb_subject_relationships(subject, as_of, type, direction).
-- =====================================================================

CREATE OR REPLACE FUNCTION maludb_core.maludb_core_version() RETURNS text
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$ SELECT '0.79.0'::text $body$;

-- ---------- drop the header auto-sync; relabel only touches edges -----
DROP TRIGGER IF EXISTS svpor_relationship_edge_sync_header_tg
    ON maludb_core.malu$svpor_subject_relationship_edge;

CREATE OR REPLACE FUNCTION maludb_core._svpor_subject_relationship_refresh_label_tg() RETURNS trigger
LANGUAGE plpgsql
AS $body$
BEGIN
    UPDATE maludb_core.malu$svpor_subject_relationship_edge
       SET from_subject_label = NEW.canonical_name
     WHERE owner_schema = NEW.owner_schema
       AND from_subject_id = NEW.subject_id;

    UPDATE maludb_core.malu$svpor_subject_relationship_edge
       SET to_subject_label = NEW.canonical_name
     WHERE owner_schema = NEW.owner_schema
       AND to_subject_id = NEW.subject_id;

    RETURN NEW;
END;
$body$;

-- ---------- relationship_type becomes free text (drop catalog FK) -----
ALTER TABLE maludb_core.malu$svpor_subject_relationship_edge
    DROP CONSTRAINT malu$svpor_subject_relationship_edge_type_fk;

-- ---------- remove obsolete schema-local facades in every tenant ------
DO $mig$
DECLARE
    r record;
BEGIN
    FOR r IN SELECT schema_name FROM maludb_core.malu$enabled_schema LOOP
        EXECUTE format('DROP VIEW IF EXISTS %I.maludb_related_subject CASCADE', r.schema_name);
        EXECUTE format('DROP VIEW IF EXISTS %I.maludb_related_subject_edge CASCADE', r.schema_name);
        EXECUTE format('DROP VIEW IF EXISTS %I.maludb_relationship_type CASCADE', r.schema_name);
        EXECUTE format('DROP FUNCTION IF EXISTS %I.maludb_related_subject_add(bigint,bigint,text,jsonb)', r.schema_name);
        EXECUTE format('DROP FUNCTION IF EXISTS %I.maludb_related_subjects(bigint)', r.schema_name);
        EXECUTE format('DROP FUNCTION IF EXISTS %I.maludb_related_subject_delete(bigint,bigint)', r.schema_name);
        EXECUTE format('DROP FUNCTION IF EXISTS %I.maludb_relationship_type_add(text,text,text)', r.schema_name);
        EXECUTE format('DROP FUNCTION IF EXISTS %I.maludb_related_subject_edge_add(bigint,bigint,text,timestamptz,timestamptz,text,jsonb)', r.schema_name);
        EXECUTE format('DROP FUNCTION IF EXISTS %I.maludb_related_subject_edges(bigint,timestamptz,text,text)', r.schema_name);
        EXECUTE format('DROP FUNCTION IF EXISTS %I.maludb_related_subject_edge_close(bigint,timestamptz)', r.schema_name);
        EXECUTE format('DROP FUNCTION IF EXISTS %I.maludb_related_subject_edge_delete(bigint)', r.schema_name);
    END LOOP;

    DELETE FROM maludb_core.malu$enabled_schema_object
     WHERE object_name IN (
        'maludb_related_subject', 'maludb_related_subject_add',
        'maludb_related_subjects', 'maludb_related_subject_delete',
        'maludb_relationship_type', 'maludb_relationship_type_add',
        'maludb_related_subject_edge', 'maludb_related_subject_edge_add',
        'maludb_related_subject_edges', 'maludb_related_subject_edge_close',
        'maludb_related_subject_edge_delete');
END;
$mig$;

-- ---------- new core point-in-time reader -----------------------------
CREATE FUNCTION maludb_core.list_svpor_subject_relationships(
    p_subject_id        bigint,
    p_as_of             timestamptz DEFAULT NULL,
    p_relationship_type text DEFAULT NULL,
    p_direction         text DEFAULT 'both'
) RETURNS TABLE (
    relationship_id    bigint,
    from_subject_id    bigint,
    from_subject_name  text,
    to_subject_id      bigint,
    to_subject_name    text,
    relationship_type  text,
    label              text,
    valid_from         timestamptz,
    valid_to           timestamptz,
    is_current         boolean,
    metadata_jsonb     jsonb,
    created_at         timestamptz
) LANGUAGE plpgsql
STABLE
SECURITY INVOKER
AS $body$
DECLARE
    v_schema name := current_schema();
    v_dir    text := lower(COALESCE(p_direction, 'both'));
BEGIN
    IF v_dir NOT IN ('from', 'to', 'both') THEN
        RAISE EXCEPTION 'direction must be one of from, to, both'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM maludb_core.malu$svpor_subject s
         WHERE s.owner_schema = v_schema
           AND s.subject_id = p_subject_id
    ) THEN
        RAISE EXCEPTION 'subject % does not exist in schema %', p_subject_id, v_schema
            USING ERRCODE = 'foreign_key_violation';
    END IF;

    RETURN QUERY
    SELECT e.edge_id,
           e.from_subject_id, e.from_subject_label,
           e.to_subject_id,   e.to_subject_label,
           e.relationship_type, e.label,
           e.valid_from, e.valid_to,
           maludb_core.is_currently_valid(e.valid_from, e.valid_to),
           e.metadata_jsonb, e.created_at
      FROM maludb_core.malu$svpor_subject_relationship_edge e
     WHERE e.owner_schema = v_schema
       AND ((v_dir IN ('from', 'both') AND e.from_subject_id = p_subject_id)
         OR (v_dir IN ('to',   'both') AND e.to_subject_id   = p_subject_id))
       AND (p_relationship_type IS NULL OR e.relationship_type = p_relationship_type)
       AND (p_as_of IS NULL OR maludb_core.is_valid_at(e.valid_from, e.valid_to, p_as_of))
     ORDER BY e.from_subject_id, e.to_subject_id, e.valid_from NULLS FIRST, e.edge_id;
END;
$body$;

REVOKE ALL ON FUNCTION maludb_core.list_svpor_subject_relationships(bigint, timestamptz, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core.list_svpor_subject_relationships(bigint, timestamptz, text, text)
TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;

-- ---------- 0.76 related-subject facade builder becomes a no-op -------
CREATE OR REPLACE FUNCTION maludb_core._enable_memory_schema_076_facade(p_schema name) RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
BEGIN
    -- The symmetric related-subject facade was removed in 0.79.0; its
    -- objects are now part of the single maludb_subject_relationship
    -- facade built by _enable_memory_schema_078_facade.
    PERFORM p_schema;
    RETURN 0;
END;
$body$;

-- ---------- single relationship facade (directed, typed, dated) -------
CREATE OR REPLACE FUNCTION maludb_core._enable_memory_schema_078_facade(p_schema name) RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
DECLARE
    v_count integer := 0;
BEGIN
    PERFORM maludb_core._memory_schema_assert_manageable(p_schema);

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_subject_relationship', 'view');
    EXECUTE format($sql$
        CREATE OR REPLACE VIEW %I.maludb_subject_relationship WITH (security_invoker = true) AS
        SELECT edge_id AS relationship_id,
               from_subject_id,
               to_subject_id,
               from_subject_label,
               to_subject_label,
               relationship_type,
               label,
               valid_from,
               valid_to,
               metadata_jsonb,
               created_at
          FROM maludb_core.malu$svpor_subject_relationship_edge
         WHERE owner_schema = %L
        WITH LOCAL CHECK OPTION
    $sql$, p_schema, p_schema);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON %I.maludb_subject_relationship TO maludb_memory_admin, maludb_memory_executor', p_schema);
    EXECUTE format('GRANT SELECT ON %I.maludb_subject_relationship TO maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_subject_relationship', 'view', 'Schema-local directed, typed, dated subject relationship.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_subject_relationships', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_subject_relationships(
            p_subject_id bigint,
            p_as_of timestamptz DEFAULT NULL,
            p_relationship_type text DEFAULT NULL,
            p_direction text DEFAULT 'both'
        ) RETURNS TABLE (
            relationship_id bigint,
            from_subject_id bigint,
            from_subject_name text,
            to_subject_id bigint,
            to_subject_name text,
            relationship_type text,
            label text,
            valid_from timestamptz,
            valid_to timestamptz,
            is_current boolean,
            metadata_jsonb jsonb,
            created_at timestamptz
        )
        LANGUAGE sql
        STABLE
        SECURITY INVOKER
        SET search_path = %I, maludb_core, pg_temp
        AS $facade$
            SELECT *
              FROM maludb_core.list_svpor_subject_relationships(
                  p_subject_id, p_as_of, p_relationship_type, p_direction)
        $facade$
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_subject_relationships(bigint, timestamptz, text, text) FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_subject_relationships(bigint, timestamptz, text, text) TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_subject_relationships', 'function', 'Schema-local subject-relationship reader (point-in-time).');
    v_count := v_count + 1;

    RETURN v_count;
END;
$body$;

-- ---------- drop the removed core functions ---------------------------
ALTER EXTENSION maludb_core DROP FUNCTION maludb_core.add_svpor_related_subject(bigint, bigint, text, jsonb);
DROP FUNCTION maludb_core.add_svpor_related_subject(bigint, bigint, text, jsonb);
ALTER EXTENSION maludb_core DROP FUNCTION maludb_core.list_svpor_related_subjects(bigint);
DROP FUNCTION maludb_core.list_svpor_related_subjects(bigint);
ALTER EXTENSION maludb_core DROP FUNCTION maludb_core.delete_svpor_related_subject(bigint, bigint);
DROP FUNCTION maludb_core.delete_svpor_related_subject(bigint, bigint);

ALTER EXTENSION maludb_core DROP FUNCTION maludb_core.register_svpor_relationship_type(text, text, text);
DROP FUNCTION maludb_core.register_svpor_relationship_type(text, text, text);

ALTER EXTENSION maludb_core DROP FUNCTION maludb_core.add_svpor_relationship_edge(bigint, bigint, text, timestamptz, timestamptz, text, jsonb);
DROP FUNCTION maludb_core.add_svpor_relationship_edge(bigint, bigint, text, timestamptz, timestamptz, text, jsonb);
ALTER EXTENSION maludb_core DROP FUNCTION maludb_core.close_svpor_relationship_edge(bigint, timestamptz);
DROP FUNCTION maludb_core.close_svpor_relationship_edge(bigint, timestamptz);
ALTER EXTENSION maludb_core DROP FUNCTION maludb_core.list_svpor_relationship_edges(bigint, timestamptz, text, text);
DROP FUNCTION maludb_core.list_svpor_relationship_edges(bigint, timestamptz, text, text);
ALTER EXTENSION maludb_core DROP FUNCTION maludb_core.delete_svpor_relationship_edge(bigint);
DROP FUNCTION maludb_core.delete_svpor_relationship_edge(bigint);

ALTER EXTENSION maludb_core DROP FUNCTION maludb_core._svpor_relationship_edge_sync_header_tg();
DROP FUNCTION maludb_core._svpor_relationship_edge_sync_header_tg();
ALTER EXTENSION maludb_core DROP FUNCTION maludb_core._svpor_sync_relationship_header(name, bigint, bigint);
DROP FUNCTION maludb_core._svpor_sync_relationship_header(name, bigint, bigint);

-- ---------- drop the removed storage (symmetric pair + type catalog) --
-- The symmetric table is dropped with its data (no migration). Dropping
-- it removes the dependent maludb_related_subject views in any tenant
-- that still has them; the per-tenant cleanup above already removed the
-- managed copies.
ALTER EXTENSION maludb_core DROP TABLE maludb_core.malu$svpor_subject_relationship;
DROP TABLE maludb_core.malu$svpor_subject_relationship CASCADE;

ALTER EXTENSION maludb_core DROP FUNCTION maludb_core._svpor_subject_relationship_set_labels_tg();
DROP FUNCTION maludb_core._svpor_subject_relationship_set_labels_tg();

ALTER EXTENSION maludb_core DROP TABLE maludb_core.malu$svpor_relationship_type;
DROP TABLE maludb_core.malu$svpor_relationship_type CASCADE;
