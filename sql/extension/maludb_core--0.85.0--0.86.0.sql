\echo Use "ALTER EXTENSION maludb_core UPDATE TO '0.86.0'" to load this file. \quit

-- =====================================================================
-- maludb_core 0.85.0 -> 0.86.0
--
-- Two coupled rails that share one contract -- the (object_kind,
-- object_id) handle:
--
--   (A) Unified graph traversal. The episode/PM relationships live in
--       malu$svpor_statement (verb-typed SVO edges) while lineage lives
--       in malu$relationship_edge; the existing graph_* functions only
--       walked the latter. This release adds a normalized edge view
--       (malu$edge_unified) over BOTH stores and traversal functions
--       (uedge_neighbors / uedge_walk) over it, so a single walk from a
--       sprint reaches its meetings, developers, documents, decisions,
--       and their neighbors, to any depth -- regardless of which store
--       the edge lives in or which direction it points.
--
--   (B) Semantic entry. A vector-search hit becomes a graph entry point
--       by resolving to an (object_kind, object_id). malu$object_embedding
--       stores an embedding per graph object (keyed by object_kind,
--       object_id, embedding_space, source_field, sub_key -- so a subject's
--       markdown, an episode's title+summary, and many chunks of a
--       document can all be indexed), and semantic_search(query_embedding,
--       ...) returns (object_kind, object_id, score). Then
--       "vector hit -> traverse" is semantic_search(...) -> graph_walk(...).
--
--       Consistent with the rest of MaluDB, the database does NOT compute
--       embeddings: callers/the embedding pipeline supply precomputed
--       vectors (bytea); this layer stores them, scans with the existing
--       bytea distance functions, and returns object handles.
--
-- Existing schemas pick up the new objects by re-running
-- maludb_core.enable_memory_schema().
-- =====================================================================

CREATE OR REPLACE FUNCTION maludb_core.maludb_core_version() RETURNS text
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$ SELECT '0.86.0'::text $body$;

-- ===== A1. unified edge view (svpor_statement + relationship_edge) ===
CREATE OR REPLACE VIEW maludb_core.malu$edge_unified AS
    SELECT 'svpor_statement'::text AS edge_store,
           s.statement_id          AS edge_id,
           s.owner_schema,
           s.subject_kind          AS source_kind,
           s.subject_id            AS source_id,
           v.canonical_name        AS rel,
           s.object_kind           AS target_kind,
           s.object_id             AS target_id,
           s.confidence,
           s.provenance
      FROM maludb_core.malu$svpor_statement s
      LEFT JOIN maludb_core.malu$svpor_verb v
        ON v.owner_schema = s.owner_schema AND v.verb_id = s.verb_id
    UNION ALL
    SELECT 'relationship_edge'::text,
           e.edge_id,
           e.owner_schema,
           e.source_object_type,
           e.source_object_id,
           e.relationship_type,
           e.target_object_type,
           e.target_object_id,
           e.confidence,
           NULL::text
      FROM maludb_core.malu$relationship_edge e;

GRANT SELECT ON maludb_core.malu$edge_unified
    TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;

-- ===== A2. uedge_neighbors -- one hop over the unified graph =========
CREATE FUNCTION maludb_core.uedge_neighbors(
    p_kind text, p_id bigint, p_direction text DEFAULT 'both', p_rel_filter text[] DEFAULT NULL
) RETURNS TABLE(
    neighbor_kind text, neighbor_id bigint, rel text, edge_store text,
    confidence numeric, provenance text, label text)
LANGUAGE plpgsql STABLE SECURITY INVOKER
AS $body$
BEGIN
    IF p_direction NOT IN ('out','in','both') THEN
        RAISE EXCEPTION 'uedge_neighbors: bad direction %', p_direction USING ERRCODE='invalid_parameter_value';
    END IF;
    RETURN QUERY
        SELECT e.target_kind, e.target_id, e.rel, e.edge_store, e.confidence, e.provenance,
               maludb_core._svpor_endpoint_label(e.target_kind, e.target_id)
          FROM maludb_core.malu$edge_unified e
         WHERE e.owner_schema = current_schema()
           AND p_direction IN ('out','both')
           AND e.source_kind = p_kind AND e.source_id = p_id
           AND (p_rel_filter IS NULL OR cardinality(p_rel_filter)=0 OR e.rel = ANY(p_rel_filter))
        UNION ALL
        SELECT e.source_kind, e.source_id, e.rel, e.edge_store, e.confidence, e.provenance,
               maludb_core._svpor_endpoint_label(e.source_kind, e.source_id)
          FROM maludb_core.malu$edge_unified e
         WHERE e.owner_schema = current_schema()
           AND p_direction IN ('in','both')
           AND e.target_kind = p_kind AND e.target_id = p_id
           AND (p_rel_filter IS NULL OR cardinality(p_rel_filter)=0 OR e.rel = ANY(p_rel_filter));
END;
$body$;
REVOKE ALL ON FUNCTION maludb_core.uedge_neighbors(text, bigint, text, text[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core.uedge_neighbors(text, bigint, text, text[])
    TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;

-- ===== A3. uedge_walk -- multi-hop, depth-bounded, cycle-safe ========
-- The recursive term joins malu$edge_unified directly to the working
-- table (no subquery reference to the recursive CTE, which Postgres
-- forbids); a single join with an OR handles both directions, and the
-- neighbor end is selected per-edge by CASE. Cycle prevention via a
-- 'kind:id' path array.
CREATE FUNCTION maludb_core.uedge_walk(
    p_kind text, p_id bigint, p_max_depth integer DEFAULT 4,
    p_direction text DEFAULT 'both', p_rel_filter text[] DEFAULT NULL
) RETURNS TABLE(
    object_kind text, object_id bigint, depth integer, rel text, edge_store text,
    label text, path text[])
LANGUAGE plpgsql STABLE SECURITY INVOKER
AS $body$
BEGIN
    IF p_direction NOT IN ('out','in','both') THEN
        RAISE EXCEPTION 'uedge_walk: bad direction %', p_direction USING ERRCODE='invalid_parameter_value';
    END IF;
    RETURN QUERY
    WITH RECURSIVE walk AS (
        SELECT p_kind AS object_kind, p_id AS object_id, 0 AS depth,
               NULL::text AS rel, NULL::text AS edge_store,
               ARRAY[p_kind || ':' || p_id::text] AS path
        UNION ALL
        SELECT
            CASE WHEN e.source_kind = w.object_kind AND e.source_id = w.object_id
                 THEN e.target_kind ELSE e.source_kind END,
            CASE WHEN e.source_kind = w.object_kind AND e.source_id = w.object_id
                 THEN e.target_id ELSE e.source_id END,
            w.depth + 1, e.rel, e.edge_store,
            w.path || (CASE WHEN e.source_kind = w.object_kind AND e.source_id = w.object_id
                            THEN e.target_kind || ':' || e.target_id::text
                            ELSE e.source_kind || ':' || e.source_id::text END)
        FROM walk w
        JOIN maludb_core.malu$edge_unified e
          ON e.owner_schema = current_schema()
         AND (
              (p_direction IN ('out','both') AND e.source_kind = w.object_kind AND e.source_id = w.object_id)
              OR
              (p_direction IN ('in','both')  AND e.target_kind = w.object_kind AND e.target_id = w.object_id)
             )
         AND (p_rel_filter IS NULL OR cardinality(p_rel_filter)=0 OR e.rel = ANY(p_rel_filter))
        WHERE w.depth < p_max_depth
          AND NOT (
              (CASE WHEN e.source_kind = w.object_kind AND e.source_id = w.object_id
                    THEN e.target_kind || ':' || e.target_id::text
                    ELSE e.source_kind || ':' || e.source_id::text END) = ANY(w.path))
    )
    SELECT w.object_kind, w.object_id, w.depth, w.rel, w.edge_store,
           maludb_core._svpor_endpoint_label(w.object_kind, w.object_id) AS label, w.path
      FROM walk w
     WHERE w.depth > 0;
END;
$body$;
REVOKE ALL ON FUNCTION maludb_core.uedge_walk(text, bigint, integer, text, text[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core.uedge_walk(text, bigint, integer, text, text[])
    TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;

-- ===== B1. malu$object_embedding -- embedding per graph object =======
CREATE TABLE IF NOT EXISTS maludb_core.malu$object_embedding (
    object_embedding_id bigserial PRIMARY KEY,
    owner_schema        name NOT NULL DEFAULT current_schema(),
    object_kind         text NOT NULL,
    object_id           bigint NOT NULL,
    embedding_space     text NOT NULL,
    source_field        text NOT NULL DEFAULT 'default',  -- 'markdown' | 'title_summary' | 'chunk' | ...
    sub_key             text NOT NULL DEFAULT '',          -- e.g. chunk ordinal; '' for single-valued
    embedding           bytea NOT NULL,
    embedding_dim       integer NOT NULL CHECK (embedding_dim > 0),
    embedding_model     text,
    provenance          text NOT NULL DEFAULT 'provided'
        CHECK (provenance IN ('provided','suggested','accepted','rejected')),
    created_at          timestamptz NOT NULL DEFAULT now(),
    CHECK (octet_length(embedding) = embedding_dim * 4),
    CHECK (object_kind IN
        ('subject','verb','document','episode_object','memory',
         'source_package','claim','fact','memory_detail_object','svpor_statement')),
    UNIQUE (owner_schema, object_kind, object_id, embedding_space, source_field, sub_key)
);
CREATE INDEX IF NOT EXISTS malu$object_embedding_scan_idx
    ON maludb_core.malu$object_embedding(owner_schema, embedding_space, object_kind);
CREATE INDEX IF NOT EXISTS malu$object_embedding_target_idx
    ON maludb_core.malu$object_embedding(owner_schema, object_kind, object_id);

ALTER TABLE maludb_core.malu$object_embedding ENABLE ROW LEVEL SECURITY;
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_catalog.pg_policy p
          JOIN pg_catalog.pg_class c ON c.oid = p.polrelid
          JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
         WHERE n.nspname='maludb_core' AND c.relname='malu$object_embedding' AND p.polname='tenant_owner'
    ) THEN
        EXECUTE 'CREATE POLICY tenant_owner ON maludb_core.malu$object_embedding
                 USING (owner_schema = current_schema())
                 WITH CHECK (owner_schema = current_schema())';
    END IF;
END$$;

GRANT SELECT, INSERT, UPDATE, DELETE ON maludb_core.malu$object_embedding
    TO maludb_memory_admin, maludb_memory_executor;
GRANT SELECT ON maludb_core.malu$object_embedding TO maludb_memory_auditor;
GRANT USAGE, SELECT ON SEQUENCE maludb_core.malu$object_embedding_object_embedding_id_seq
    TO maludb_memory_admin, maludb_memory_executor;

-- ===== B2. register_object_embedding -- upsert a precomputed vector ==
CREATE FUNCTION maludb_core.register_object_embedding(
    p_object_kind     text,
    p_object_id       bigint,
    p_embedding       bytea,
    p_embedding_dim   integer,
    p_embedding_space text,
    p_embedding_model text DEFAULT NULL,
    p_source_field    text DEFAULT 'default',
    p_sub_key         text DEFAULT '',
    p_provenance      text DEFAULT 'provided'
) RETURNS bigint
LANGUAGE plpgsql
SECURITY INVOKER
AS $body$
DECLARE
    v_schema name := current_schema();
    v_kind   text := lower(btrim(COALESCE(p_object_kind, '')));
    v_id     bigint;
BEGIN
    IF p_object_id IS NULL OR p_embedding IS NULL OR p_embedding_dim IS NULL
       OR COALESCE(btrim(p_embedding_space),'') = '' THEN
        RAISE EXCEPTION 'register_object_embedding: object_id, embedding, embedding_dim and embedding_space are required'
            USING ERRCODE='invalid_parameter_value';
    END IF;
    IF octet_length(p_embedding) <> p_embedding_dim * 4 THEN
        RAISE EXCEPTION 'register_object_embedding: embedding byte length % does not match dim %',
            octet_length(p_embedding), p_embedding_dim USING ERRCODE='invalid_parameter_value';
    END IF;

    PERFORM maludb_core._svpor_attribute_assert_target(v_schema, v_kind, p_object_id);

    INSERT INTO maludb_core.malu$object_embedding
        (owner_schema, object_kind, object_id, embedding_space, source_field, sub_key,
         embedding, embedding_dim, embedding_model, provenance)
    VALUES
        (v_schema, v_kind, p_object_id, p_embedding_space,
         COALESCE(NULLIF(btrim(p_source_field),''),'default'), COALESCE(p_sub_key,''),
         p_embedding, p_embedding_dim, p_embedding_model,
         COALESCE(NULLIF(btrim(p_provenance),''),'provided'))
    ON CONFLICT (owner_schema, object_kind, object_id, embedding_space, source_field, sub_key)
    DO UPDATE SET
        embedding       = EXCLUDED.embedding,
        embedding_dim   = EXCLUDED.embedding_dim,
        embedding_model = EXCLUDED.embedding_model,
        provenance      = EXCLUDED.provenance
    RETURNING object_embedding_id INTO v_id;

    RETURN v_id;
END;
$body$;
REVOKE ALL ON FUNCTION maludb_core.register_object_embedding(text, bigint, bytea, integer, text, text, text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core.register_object_embedding(text, bigint, bytea, integer, text, text, text, text, text)
    TO maludb_memory_admin, maludb_memory_executor;

-- ===== B3. semantic_search -- similarity scan -> object handles ======
CREATE FUNCTION maludb_core.semantic_search(
    p_query_embedding bytea,
    p_object_kinds    text[]  DEFAULT NULL,
    p_k               integer DEFAULT 10,
    p_embedding_space text    DEFAULT NULL,
    p_metric          text    DEFAULT 'cosine'
) RETURNS TABLE(
    object_kind text, object_id bigint, source_field text, sub_key text,
    score double precision, label text)
LANGUAGE plpgsql STABLE SECURITY INVOKER
AS $body$
DECLARE
    v_dim    integer;
    v_metric text := lower(COALESCE(p_metric, 'cosine'));
BEGIN
    IF p_query_embedding IS NULL THEN
        RAISE EXCEPTION 'semantic_search: query embedding is required' USING ERRCODE='invalid_parameter_value';
    END IF;
    IF v_metric NOT IN ('cosine','l2','inner_product') THEN
        RAISE EXCEPTION 'semantic_search: metric must be cosine/l2/inner_product' USING ERRCODE='invalid_parameter_value';
    END IF;
    v_dim := octet_length(p_query_embedding) / 4;

    RETURN QUERY
        SELECT oe.object_kind, oe.object_id, oe.source_field, oe.sub_key,
               -- raw-float bytea is binary-compatible with malu_vector (CAST
               -- ... WITHOUT FUNCTION); the distance primitives are
               -- malu_vector-typed, so cast both operands at compare time.
               CASE v_metric
                   WHEN 'cosine'        THEN 1.0 - maludb_core.cosine_distance(oe.embedding::maludb_core.malu_vector, p_query_embedding::maludb_core.malu_vector)
                   WHEN 'inner_product' THEN maludb_core.vector_dot_product(oe.embedding::maludb_core.malu_vector, p_query_embedding::maludb_core.malu_vector)
                   ELSE                      - maludb_core.vector_l2_squared(oe.embedding::maludb_core.malu_vector, p_query_embedding::maludb_core.malu_vector)
               END AS score,
               maludb_core._svpor_endpoint_label(oe.object_kind, oe.object_id) AS label
          FROM maludb_core.malu$object_embedding oe
         WHERE oe.owner_schema = current_schema()
           AND oe.embedding_dim = v_dim
           AND (p_embedding_space IS NULL OR oe.embedding_space = p_embedding_space)
           AND (p_object_kinds IS NULL OR cardinality(p_object_kinds)=0 OR oe.object_kind = ANY(p_object_kinds))
         ORDER BY score DESC
         LIMIT GREATEST(COALESCE(p_k, 10), 1);
END;
$body$;
REVOKE ALL ON FUNCTION maludb_core.semantic_search(bytea, text[], integer, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core.semantic_search(bytea, text[], integer, text, text)
    TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;

-- ===== schema-local facade builder ==================================
CREATE FUNCTION maludb_core._enable_memory_schema_0860_facade(p_schema name) RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
DECLARE
    v_count integer := 0;
BEGIN
    PERFORM maludb_core._memory_schema_assert_manageable(p_schema);

    -- unified edge view (read-only) ---------------------------------
    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_edge', 'view');
    EXECUTE format($sql$
        CREATE OR REPLACE VIEW %I.maludb_edge WITH (security_invoker = true) AS
        SELECT edge_store, edge_id, source_kind, source_id, rel,
               target_kind, target_id, confidence, provenance
          FROM maludb_core.malu$edge_unified
         WHERE owner_schema = %L
    $sql$, p_schema, p_schema);
    EXECUTE format('GRANT SELECT ON %I.maludb_edge TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_edge', 'view', 'Unified relationship/SVO edge view.');
    v_count := v_count + 1;

    -- graph_neighbors / graph_walk ----------------------------------
    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_graph_neighbors', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_graph_neighbors(
            p_kind text, p_id bigint, p_direction text DEFAULT 'both', p_rel_filter text[] DEFAULT NULL)
        RETURNS TABLE(neighbor_kind text, neighbor_id bigint, rel text, edge_store text,
                      confidence numeric, provenance text, label text)
        LANGUAGE sql STABLE SECURITY INVOKER
        SET search_path = %I, maludb_core, pg_temp
        AS $facade$ SELECT * FROM maludb_core.uedge_neighbors(p_kind, p_id, p_direction, p_rel_filter) $facade$
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_graph_neighbors(text, bigint, text, text[]) FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_graph_neighbors(text, bigint, text, text[]) TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_graph_neighbors', 'function', 'One-hop neighbors over the unified graph.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_graph_walk', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_graph_walk(
            p_kind text, p_id bigint, p_max_depth integer DEFAULT 4,
            p_direction text DEFAULT 'both', p_rel_filter text[] DEFAULT NULL)
        RETURNS TABLE(object_kind text, object_id bigint, depth integer, rel text,
                      edge_store text, label text, path text[])
        LANGUAGE sql STABLE SECURITY INVOKER
        SET search_path = %I, maludb_core, pg_temp
        AS $facade$ SELECT * FROM maludb_core.uedge_walk(p_kind, p_id, p_max_depth, p_direction, p_rel_filter) $facade$
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_graph_walk(text, bigint, integer, text, text[]) FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_graph_walk(text, bigint, integer, text, text[]) TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_graph_walk', 'function', 'Multi-hop traversal over the unified graph.');
    v_count := v_count + 1;

    -- object_embedding writable view + register + semantic_search ----
    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_object_embedding', 'view');
    EXECUTE format($sql$
        CREATE OR REPLACE VIEW %I.maludb_object_embedding WITH (security_invoker = true) AS
        SELECT object_embedding_id, object_kind, object_id, embedding_space, source_field, sub_key,
               embedding, embedding_dim, embedding_model, provenance, created_at
          FROM maludb_core.malu$object_embedding
         WHERE owner_schema = %L
        WITH LOCAL CHECK OPTION
    $sql$, p_schema, p_schema);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON %I.maludb_object_embedding TO maludb_memory_admin, maludb_memory_executor', p_schema);
    EXECUTE format('GRANT SELECT ON %I.maludb_object_embedding TO maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_object_embedding', 'view', 'Schema-local object embedding store.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_register_object_embedding', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_register_object_embedding(
            p_object_kind text, p_object_id bigint, p_embedding bytea, p_embedding_dim integer,
            p_embedding_space text, p_embedding_model text DEFAULT NULL,
            p_source_field text DEFAULT 'default', p_sub_key text DEFAULT '', p_provenance text DEFAULT 'provided')
        RETURNS bigint LANGUAGE sql SECURITY INVOKER
        SET search_path = %I, maludb_core, pg_temp
        AS $facade$ SELECT maludb_core.register_object_embedding(
            p_object_kind, p_object_id, p_embedding, p_embedding_dim, p_embedding_space,
            p_embedding_model, p_source_field, p_sub_key, p_provenance) $facade$
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_register_object_embedding(text, bigint, bytea, integer, text, text, text, text, text) FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_register_object_embedding(text, bigint, bytea, integer, text, text, text, text, text) TO maludb_memory_admin, maludb_memory_executor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_register_object_embedding', 'function', 'Schema-local object embedding upsert.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_semantic_search', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_semantic_search(
            p_query_embedding bytea, p_object_kinds text[] DEFAULT NULL, p_k integer DEFAULT 10,
            p_embedding_space text DEFAULT NULL, p_metric text DEFAULT 'cosine')
        RETURNS TABLE(object_kind text, object_id bigint, source_field text, sub_key text,
                      score double precision, label text)
        LANGUAGE sql STABLE SECURITY INVOKER
        SET search_path = %I, maludb_core, pg_temp
        AS $facade$ SELECT * FROM maludb_core.semantic_search(p_query_embedding, p_object_kinds, p_k, p_embedding_space, p_metric) $facade$
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_semantic_search(bytea, text[], integer, text, text) FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_semantic_search(bytea, text[], integer, text, text) TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_semantic_search', 'function', 'Schema-local semantic search returning object handles.');
    v_count := v_count + 1;

    RETURN v_count;
END;
$body$;

REVOKE ALL ON FUNCTION maludb_core._enable_memory_schema_0860_facade(name) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core._enable_memory_schema_0860_facade(name)
    TO maludb_memory_admin, maludb_memory_executor;

-- ===== wire the 0860 facade into enable_memory_schema ===============
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
