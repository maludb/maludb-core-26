\echo Use "ALTER EXTENSION maludb_core UPDATE TO '0.76.1'" to load this file. \quit

-- =====================================================================
-- maludb_core 0.76.0 -> 0.76.1
--
-- Keep schema-local maludb_verb refresh idempotent after 0.75 type columns.
-- =====================================================================

CREATE OR REPLACE FUNCTION maludb_core.maludb_core_version() RETURNS text
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$ SELECT '0.76.1'::text $body$;

CREATE OR REPLACE FUNCTION maludb_core._enable_memory_schema_subject_facade(p_schema name) RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
DECLARE
    v_count integer := 0;
BEGIN
    PERFORM maludb_core._memory_schema_assert_manageable(p_schema);

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_subject', 'view');
    EXECUTE format($sql$
        CREATE OR REPLACE VIEW %I.maludb_subject AS
        SELECT subject_id,
               subject_type,
               canonical_name,
               aliases,
               description,
               created_at
          FROM maludb_core.malu$svpor_subject
         WHERE owner_schema = %L
        WITH LOCAL CHECK OPTION
    $sql$, p_schema, p_schema);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON %I.maludb_subject TO maludb_memory_admin, maludb_memory_executor', p_schema);
    EXECUTE format('GRANT SELECT ON %I.maludb_subject TO maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_subject', 'view', 'Schema-local SVPOR subject facade.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_verb', 'view');
    EXECUTE format($sql$
        CREATE OR REPLACE VIEW %I.maludb_verb AS
        SELECT verb_id,
               canonical_name,
               aliases,
               description,
               created_at,
               verb_type,
               search_phrases
          FROM maludb_core.malu$svpor_verb
         WHERE owner_schema = %L
        WITH LOCAL CHECK OPTION
    $sql$, p_schema, p_schema);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON %I.maludb_verb TO maludb_memory_admin, maludb_memory_executor', p_schema);
    EXECUTE format('GRANT SELECT ON %I.maludb_verb TO maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_verb', 'view', 'Schema-local SVPOR verb facade.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_subject_verb', 'view');
    EXECUTE format($sql$
        CREATE OR REPLACE VIEW %I.maludb_subject_verb AS
        SELECT c.compartment_id,
               c.namespace,
               s.subject_name,
               v.verb_name,
               c.embedding_dim,
               c.embedding_model,
               c.distance_metric,
               c.vector_count,
               c.search_mode,
               c.ann_index_status,
               c.created_at,
               c.updated_at
          FROM maludb_core.malu$vector_compartment c
          JOIN maludb_core.malu$vector_subject s
            ON s.owner_schema = c.owner_schema
           AND s.namespace = c.namespace
           AND s.subject_id = c.subject_id
          JOIN maludb_core.malu$vector_verb v
            ON v.owner_schema = c.owner_schema
           AND v.namespace = c.namespace
           AND v.verb_id = c.verb_id
         WHERE c.owner_schema = %L
    $sql$, p_schema, p_schema);
    EXECUTE format('GRANT SELECT ON %I.maludb_subject_verb TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_subject_verb', 'view', 'Schema-local vector subject/verb compartment facade.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_project', 'view');
    EXECUTE format($sql$
        CREATE OR REPLACE VIEW %I.maludb_project AS
        SELECT subject_id,
               subject_type,
               canonical_name,
               aliases,
               description,
               created_at
          FROM %I.maludb_subject
         WHERE subject_type = 'project'
        WITH LOCAL CHECK OPTION
    $sql$, p_schema, p_schema);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON %I.maludb_project TO maludb_memory_admin, maludb_memory_executor', p_schema);
    EXECUTE format('GRANT SELECT ON %I.maludb_project TO maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_project', 'view', 'Schema-local project subject convenience facade.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_stakeholder', 'view');
    EXECUTE format($sql$
        CREATE OR REPLACE VIEW %I.maludb_stakeholder AS
        SELECT subject_id,
               subject_type,
               canonical_name,
               aliases,
               description,
               created_at
          FROM %I.maludb_subject
         WHERE subject_type = 'stakeholder'
        WITH LOCAL CHECK OPTION
    $sql$, p_schema, p_schema);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON %I.maludb_stakeholder TO maludb_memory_admin, maludb_memory_executor', p_schema);
    EXECUTE format('GRANT SELECT ON %I.maludb_stakeholder TO maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_stakeholder', 'view', 'Schema-local stakeholder subject convenience facade.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_subject_verb_create', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_subject_verb_create(
            p_namespace text,
            p_subject_name text,
            p_verb_name text,
            p_embedding_dim integer,
            p_embedding_model text,
            p_distance_metric text DEFAULT 'cosine'
        ) RETURNS bigint
        LANGUAGE sql
        SECURITY DEFINER
        SET search_path = pg_catalog, maludb_core, pg_temp
        AS $facade$
            SELECT maludb_core._register_vector_compartment_for_schema(
                %L::name,
                p_namespace,
                p_subject_name,
                p_verb_name,
                p_embedding_dim,
                p_embedding_model,
                p_distance_metric
            )
        $facade$
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_subject_verb_create(text, text, text, integer, text, text) FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_subject_verb_create(text, text, text, integer, text, text) TO maludb_memory_admin, maludb_memory_executor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_subject_verb_create', 'function', 'Schema-local vector compartment creation facade.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_vector_search', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_vector_search(
            p_namespace text DEFAULT 'default',
            p_subject text DEFAULT NULL,
            p_verb text DEFAULT NULL,
            p_query_embedding maludb_core.malu_vector DEFAULT NULL,
            p_limit integer DEFAULT 20,
            p_metric text DEFAULT NULL
        ) RETURNS TABLE (
            chunk_id        bigint,
            source_text     text,
            distance        double precision,
            similarity      double precision,
            rank_no         integer,
            compartment_id  bigint,
            subject_name    text,
            verb_name       text
        )
        LANGUAGE sql
        STABLE
        SECURITY INVOKER
        SET search_path = %I, maludb_core, pg_temp
        AS $facade$
            SELECT *
            FROM maludb_core.vector_search_by_tags(
                p_namespace,
                p_subject,
                p_verb,
                p_query_embedding,
                p_limit,
                p_metric
            )
        $facade$
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_vector_search(text, text, text, maludb_core.malu_vector, integer, text) FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_vector_search(text, text, text, maludb_core.malu_vector, integer, text) TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_vector_search', 'function', 'Schema-local vector tag search helper.');
    v_count := v_count + 1;

    RETURN v_count;
END;
$body$;

REVOKE ALL ON FUNCTION maludb_core._enable_memory_schema_subject_facade(name) FROM PUBLIC;
