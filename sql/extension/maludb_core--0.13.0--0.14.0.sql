\echo Use "ALTER EXTENSION maludb_core UPDATE TO '0.14.0'" to load this file. \quit

-- =====================================================================
-- maludb_core 0.13.0 → 0.14.0
--
-- R1.1-16: Local ANN per compartment.
--
-- Adds a single-layer NSW (Navigable Small-World) graph stored as a
-- single BYTEA blob per compartment, plus the delta + tombstone +
-- rebuild lifecycle described in
-- docs/research/2026-05-06-compartmentalized-vector-search.md §10-§14.
--
-- Scope decisions (2026-05-13):
--   * Single-layer NSW, not multilevel HNSW. Functionally similar at
--     moderate compartment sizes; ~half the code. R1.1-16.1 may
--     upgrade to multilevel HNSW.
--   * Single BYTEA blob per compartment (transcript §7 hybrid). One
--     row read serves the whole search; no per-edge SQL round-trip.
--   * Full lifecycle: delta search merged into top-K, tombstones
--     filtered, ann_rebuild() drains delta + clears tombstones.
--
-- Tables:
--   malu$ann_index          — one row per compartment with an ANN built
--   malu$ann_delta          — chunks added since last build
--   malu$vector_tombstone   — chunks marked for filtering on search
--
-- Search path when search_mode='local_ann':
--   1. ann_search over graph in malu$ann_index.graph_bytes
--   2. exact search over delta chunks not yet in graph
--   3. filter out tombstones from both
--   4. merge by distance + return top K
-- =====================================================================

CREATE OR REPLACE FUNCTION maludb_core_version() RETURNS text
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$ SELECT '0.14.0'::text $body$;

-- ---------------------------------------------------------------------
-- malu$ann_index — graph blob + parameters per compartment
-- ---------------------------------------------------------------------
CREATE TABLE malu$ann_index (
    compartment_id       bigint PRIMARY KEY
        REFERENCES malu$vector_compartment(compartment_id) ON DELETE CASCADE,
    algorithm            text   NOT NULL DEFAULT 'nsw'
        CHECK (algorithm IN ('nsw','hnsw')),
    distance_metric      text   NOT NULL
        CHECK (distance_metric IN ('cosine','l2','inner_product')),
    m                    integer NOT NULL DEFAULT 16
        CHECK (m > 0 AND m <= 256),
    ef_construction      integer NOT NULL DEFAULT 64
        CHECK (ef_construction > 0 AND ef_construction <= 4096),
    ef_search_default    integer NOT NULL DEFAULT 32
        CHECK (ef_search_default > 0 AND ef_search_default <= 4096),
    embedding_dim        integer NOT NULL,
    graph_bytes          bytea  NOT NULL,
    vector_count_at_build bigint NOT NULL DEFAULT 0,
    status               text   NOT NULL DEFAULT 'ready'
        CHECK (status IN ('building','ready','stale','rebuilding','disabled')),
    built_at             timestamptz NOT NULL DEFAULT now(),
    last_rebuilt_at      timestamptz
);

CREATE INDEX malu$ann_index_status_idx ON malu$ann_index(status);

-- ---------------------------------------------------------------------
-- malu$ann_delta — chunks inserted since last build. Search merges
-- these with the graph results so new vectors are immediately
-- findable.
-- ---------------------------------------------------------------------
CREATE TABLE malu$ann_delta (
    compartment_id   bigint NOT NULL
        REFERENCES malu$vector_compartment(compartment_id) ON DELETE CASCADE,
    chunk_id         bigint NOT NULL
        REFERENCES malu$vector_chunk(chunk_id) ON DELETE CASCADE,
    created_at       timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (compartment_id, chunk_id)
);

CREATE INDEX malu$ann_delta_compartment_idx ON malu$ann_delta(compartment_id);

-- ---------------------------------------------------------------------
-- malu$vector_tombstone — chunks to filter out on search. We don't
-- physically delete chunks (graph references would break); instead
-- mark them tombstoned and let ann_rebuild() clear them next time.
-- ---------------------------------------------------------------------
CREATE TABLE malu$vector_tombstone (
    chunk_id    bigint PRIMARY KEY
        REFERENCES malu$vector_chunk(chunk_id) ON DELETE CASCADE,
    deleted_at  timestamptz NOT NULL DEFAULT now()
);

GRANT SELECT ON malu$ann_index, malu$ann_delta, malu$vector_tombstone TO
    maludb_llm_admin,
    maludb_llm_prompt_author,
    maludb_llm_prompt_approver,
    maludb_llm_model_admin,
    maludb_llm_executor,
    maludb_llm_auditor;
GRANT INSERT, UPDATE, DELETE ON malu$ann_index, malu$ann_delta, malu$vector_tombstone TO
    maludb_llm_admin;
GRANT INSERT, UPDATE, DELETE ON malu$ann_delta, malu$vector_tombstone TO
    maludb_llm_executor;

-- ---------------------------------------------------------------------
-- C functions backing the NSW algorithm.
--
--   maludb_ann_build_c(compartment_id, m, ef_construct, metric)
--     → bytea (the graph blob)
--   maludb_ann_search_c(graph, query, k, ef_search, metric)
--     → TABLE(chunk_id, distance, similarity, rank_no)
-- ---------------------------------------------------------------------
CREATE FUNCTION maludb_ann_build_c(
    p_compartment_id bigint,
    p_m              integer,
    p_ef_construct   integer,
    p_metric         text
) RETURNS bytea
    AS 'MODULE_PATHNAME', 'maludb_ann_build_c'
    LANGUAGE C STABLE STRICT;

CREATE FUNCTION maludb_ann_search_c(
    p_graph          bytea,
    p_query          malu_vector,
    p_limit          integer,
    p_ef_search      integer,
    p_metric         text
) RETURNS TABLE (
    chunk_id    bigint,
    distance    double precision,
    similarity  double precision,
    rank_no     integer
)
    AS 'MODULE_PATHNAME', 'maludb_ann_search_c'
    LANGUAGE C STABLE PARALLEL SAFE;

-- ---------------------------------------------------------------------
-- ann_build: builds the NSW graph for a compartment and inserts/replaces
-- the malu$ann_index row. Sets compartment.search_mode='local_ann' so
-- exact_vector_search_sql routes through ANN going forward.
-- ---------------------------------------------------------------------
CREATE FUNCTION ann_build(
    p_compartment_id  bigint,
    p_m               integer DEFAULT 16,
    p_ef_construction integer DEFAULT 64,
    p_ef_search       integer DEFAULT 32
) RETURNS bigint
LANGUAGE plpgsql
AS $body$
DECLARE
    v_compart  malu$vector_compartment%ROWTYPE;
    v_graph    bytea;
    v_count    bigint;
BEGIN
    SELECT * INTO v_compart FROM malu$vector_compartment
     WHERE compartment_id = p_compartment_id;
    IF v_compart.compartment_id IS NULL THEN
        RAISE EXCEPTION 'unknown compartment_id: %', p_compartment_id
            USING ERRCODE = 'no_data_found';
    END IF;

    UPDATE malu$vector_compartment SET ann_index_status = 'building',
                                       updated_at       = now()
     WHERE compartment_id = p_compartment_id;

    v_graph := maludb_ann_build_c(
        p_compartment_id, p_m, p_ef_construction, v_compart.distance_metric);

    SELECT count(*) INTO v_count FROM malu$vector_chunk
     WHERE compartment_id = p_compartment_id
       AND chunk_id NOT IN (SELECT chunk_id FROM malu$vector_tombstone);

    INSERT INTO malu$ann_index
        (compartment_id, distance_metric, m, ef_construction, ef_search_default,
         embedding_dim, graph_bytes, vector_count_at_build, status, built_at)
    VALUES
        (p_compartment_id, v_compart.distance_metric, p_m,
         p_ef_construction, p_ef_search,
         v_compart.embedding_dim, v_graph, v_count, 'ready', now())
    ON CONFLICT (compartment_id) DO UPDATE
       SET distance_metric        = EXCLUDED.distance_metric,
           m                      = EXCLUDED.m,
           ef_construction        = EXCLUDED.ef_construction,
           ef_search_default      = EXCLUDED.ef_search_default,
           embedding_dim          = EXCLUDED.embedding_dim,
           graph_bytes            = EXCLUDED.graph_bytes,
           vector_count_at_build  = EXCLUDED.vector_count_at_build,
           status                 = 'ready',
           last_rebuilt_at        = now();

    -- Draining delta because everything is now in the graph.
    DELETE FROM malu$ann_delta WHERE compartment_id = p_compartment_id;

    UPDATE malu$vector_compartment
       SET search_mode      = 'local_ann',
           ann_index_status = 'ready',
           updated_at       = now()
     WHERE compartment_id = p_compartment_id;

    RETURN v_count;
END;
$body$;

-- ---------------------------------------------------------------------
-- ann_rebuild: alias for ann_build (idempotent). Provided as a distinct
-- name so operators can wire monitoring against the rebuild lifecycle.
-- Also clears tombstones since rebuilt graph no longer references them.
-- ---------------------------------------------------------------------
CREATE FUNCTION ann_rebuild(
    p_compartment_id bigint
) RETURNS bigint
LANGUAGE plpgsql
AS $body$
DECLARE
    v_idx malu$ann_index%ROWTYPE;
    v_built bigint;
BEGIN
    SELECT * INTO v_idx FROM malu$ann_index
     WHERE compartment_id = p_compartment_id;
    IF v_idx.compartment_id IS NULL THEN
        RAISE EXCEPTION 'no ANN index for compartment %; call ann_build() first',
            p_compartment_id
            USING ERRCODE = 'no_data_found';
    END IF;

    v_built := ann_build(p_compartment_id, v_idx.m, v_idx.ef_construction,
                         v_idx.ef_search_default);
    DELETE FROM malu$vector_tombstone
     WHERE chunk_id IN (
         SELECT chunk_id FROM malu$vector_chunk
          WHERE compartment_id = p_compartment_id);
    RETURN v_built;
END;
$body$;

-- ---------------------------------------------------------------------
-- ann_status: per-compartment lifecycle snapshot. Reports counts that
-- drive the rebuild-trigger heuristics from transcript §14.
-- ---------------------------------------------------------------------
CREATE FUNCTION ann_status(p_compartment_id bigint) RETURNS TABLE (
    compartment_id          bigint,
    algorithm               text,
    distance_metric         text,
    m                       integer,
    ef_search_default       integer,
    embedding_dim           integer,
    graph_byte_size         integer,
    vector_count_at_build   bigint,
    delta_count             bigint,
    tombstone_count         bigint,
    status                  text,
    built_at                timestamptz,
    last_rebuilt_at         timestamptz
) LANGUAGE sql STABLE
AS $body$
    SELECT
        i.compartment_id,
        i.algorithm,
        i.distance_metric,
        i.m,
        i.ef_search_default,
        i.embedding_dim,
        octet_length(i.graph_bytes)::integer,
        i.vector_count_at_build,
        (SELECT count(*) FROM malu$ann_delta d
          WHERE d.compartment_id = i.compartment_id),
        (SELECT count(*) FROM malu$vector_tombstone t
          JOIN malu$vector_chunk c ON c.chunk_id = t.chunk_id
          WHERE c.compartment_id = i.compartment_id),
        i.status,
        i.built_at,
        i.last_rebuilt_at
    FROM malu$ann_index i
    WHERE i.compartment_id = p_compartment_id;
$body$;

-- ---------------------------------------------------------------------
-- register_vector_chunk: when an ANN index exists for the compartment,
-- new inserts go into the delta buffer.
-- ---------------------------------------------------------------------
DROP FUNCTION register_vector_chunk(bigint, text, malu_vector, text);

CREATE FUNCTION register_vector_chunk(
    p_compartment_id  bigint,
    p_source_text     text,
    p_embedding       malu_vector,
    p_embedding_model text DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql
AS $body$
DECLARE
    v_dim       integer := vector_dims(p_embedding);
    v_normed    malu_vector := vector_normalize(p_embedding);
    v_norm      double precision := vector_norm(p_embedding);
    v_compart   malu$vector_compartment%ROWTYPE;
    v_chunk_id  bigint;
    v_model     text;
    v_has_ann   boolean;
BEGIN
    SELECT * INTO v_compart FROM malu$vector_compartment
     WHERE compartment_id = p_compartment_id;
    IF v_compart.compartment_id IS NULL THEN
        RAISE EXCEPTION 'unknown compartment_id: %', p_compartment_id
            USING ERRCODE = 'no_data_found';
    END IF;
    IF v_dim <> v_compart.embedding_dim THEN
        RAISE EXCEPTION 'embedding_dim mismatch: chunk=% compartment=%',
            v_dim, v_compart.embedding_dim
            USING ERRCODE = 'check_violation';
    END IF;
    v_model := COALESCE(p_embedding_model, v_compart.embedding_model);

    INSERT INTO malu$vector_chunk
        (compartment_id, source_text, embedding,
         embedding_dim, embedding_model, embedding_norm)
    VALUES
        (p_compartment_id, p_source_text, v_normed,
         v_dim, v_model, v_norm)
    RETURNING chunk_id INTO v_chunk_id;

    UPDATE malu$vector_compartment
       SET vector_count = vector_count + 1,
           updated_at   = now()
     WHERE compartment_id = p_compartment_id;

    -- If an ANN index exists, mark the new chunk as delta. The
    -- search path will exact-search the delta until the next rebuild.
    SELECT EXISTS (SELECT 1 FROM malu$ann_index
                    WHERE compartment_id = p_compartment_id) INTO v_has_ann;
    IF v_has_ann THEN
        INSERT INTO malu$ann_delta (compartment_id, chunk_id)
        VALUES (p_compartment_id, v_chunk_id)
        ON CONFLICT DO NOTHING;
        UPDATE malu$vector_compartment
           SET ann_index_status = 'stale', updated_at = now()
         WHERE compartment_id = p_compartment_id;
    END IF;

    RETURN v_chunk_id;
END;
$body$;

-- ---------------------------------------------------------------------
-- tombstone_vector_chunk: mark a chunk for filtering on search. The
-- physical row stays so the ANN graph's edges don't dangle; ann_rebuild
-- will remove it next time.
-- ---------------------------------------------------------------------
CREATE FUNCTION tombstone_vector_chunk(p_chunk_id bigint) RETURNS void
LANGUAGE plpgsql
AS $body$
DECLARE
    v_compartment_id bigint;
BEGIN
    SELECT compartment_id INTO v_compartment_id
    FROM malu$vector_chunk WHERE chunk_id = p_chunk_id;
    IF v_compartment_id IS NULL THEN
        RAISE EXCEPTION 'unknown chunk_id: %', p_chunk_id
            USING ERRCODE = 'no_data_found';
    END IF;

    INSERT INTO malu$vector_tombstone (chunk_id)
    VALUES (p_chunk_id)
    ON CONFLICT DO NOTHING;

    UPDATE malu$vector_compartment
       SET ann_index_status = 'stale', updated_at = now()
     WHERE compartment_id = v_compartment_id
       AND EXISTS (SELECT 1 FROM malu$ann_index
                    WHERE compartment_id = v_compartment_id);
END;
$body$;

-- ---------------------------------------------------------------------
-- exact_vector_search_sql: rewire the local_ann branch to actually
-- search the ANN graph + merge delta + filter tombstones.
-- ---------------------------------------------------------------------
DROP FUNCTION exact_vector_search_sql(bigint, malu_vector, integer, text);

CREATE FUNCTION exact_vector_search_sql(
    p_compartment_id bigint,
    p_query          malu_vector,
    p_limit          integer DEFAULT 10,
    p_metric         text    DEFAULT NULL
) RETURNS TABLE (
    chunk_id     bigint,
    source_text  text,
    distance     double precision,
    similarity   double precision,
    rank_no      integer
) LANGUAGE plpgsql
AS $body$
DECLARE
    v_compart malu$vector_compartment%ROWTYPE;
    v_metric  text;
    v_idx     malu$ann_index%ROWTYPE;
BEGIN
    SELECT * INTO v_compart FROM malu$vector_compartment
     WHERE compartment_id = p_compartment_id;
    IF v_compart.compartment_id IS NULL THEN
        RAISE EXCEPTION 'unknown compartment_id: %', p_compartment_id
            USING ERRCODE = 'no_data_found';
    END IF;
    IF vector_dims(p_query) <> v_compart.embedding_dim THEN
        RAISE EXCEPTION 'query dim % does not match compartment dim %',
            vector_dims(p_query), v_compart.embedding_dim
            USING ERRCODE = 'check_violation';
    END IF;
    v_metric := COALESCE(p_metric, v_compart.distance_metric);

    IF v_compart.search_mode = 'local_ann' THEN
        SELECT * INTO v_idx FROM malu$ann_index
         WHERE compartment_id = p_compartment_id;
        IF v_idx.compartment_id IS NULL THEN
            RAISE EXCEPTION
              'compartment % has search_mode=local_ann but no malu$ann_index row; call ann_build()',
              p_compartment_id
              USING ERRCODE = 'no_data_found';
        END IF;

        -- Bare `chunk_id` / `distance` / `similarity` / `rank_no` are
        -- ambiguous inside this RETURNS TABLE body (they're also OUT
        -- variable names). All references must be qualified.
        RETURN QUERY
            WITH ann_hits AS (
                SELECT a.chunk_id AS cid, a.distance AS d, a.similarity AS s
                FROM   maludb_ann_search_c(
                           v_idx.graph_bytes,
                           vector_normalize(p_query),
                           p_limit * 2,                    -- over-fetch for tombstone filter
                           v_idx.ef_search_default,
                           v_metric) a
                WHERE  a.chunk_id NOT IN (SELECT t.chunk_id FROM malu$vector_tombstone t)
            ),
            delta_hits AS (
                SELECT c.chunk_id AS cid,
                       CASE v_metric
                         WHEN 'cosine'        THEN 1.0 - vector_dot_product(c.embedding, vector_normalize(p_query))
                         WHEN 'l2'            THEN vector_l2_squared(c.embedding, p_query)
                         WHEN 'inner_product' THEN -vector_dot_product(c.embedding, p_query)
                       END AS d,
                       CASE v_metric
                         WHEN 'cosine'        THEN vector_dot_product(c.embedding, vector_normalize(p_query))
                         WHEN 'l2'            THEN -vector_l2_squared(c.embedding, p_query)
                         WHEN 'inner_product' THEN vector_dot_product(c.embedding, p_query)
                       END AS s
                FROM   malu$ann_delta dlt
                JOIN   malu$vector_chunk c ON c.chunk_id = dlt.chunk_id
                WHERE  dlt.compartment_id = p_compartment_id
                  AND  c.chunk_id NOT IN (SELECT t.chunk_id FROM malu$vector_tombstone t)
            ),
            merged AS (
                SELECT cid, d, s FROM ann_hits
                UNION ALL
                SELECT cid, d, s FROM delta_hits
            ),
            ranked AS (
                SELECT mg.cid AS cid, mg.d AS d, mg.s AS s,
                       ROW_NUMBER() OVER (ORDER BY mg.d ASC, mg.cid ASC)::integer AS r
                FROM merged mg
            )
            SELECT r.cid,
                   vc.source_text,
                   r.d,
                   r.s,
                   r.r
            FROM ranked r
            JOIN malu$vector_chunk vc ON vc.chunk_id = r.cid
            WHERE r.r <= p_limit
            ORDER BY r.r;
        RETURN;
    ELSIF v_compart.search_mode = 'exact_parallel' THEN
        RETURN QUERY
            SELECT * FROM exact_vector_search_parallel_c(
                p_compartment_id, p_query, p_limit, v_metric);
    ELSE
        RETURN QUERY
            SELECT * FROM exact_vector_search_c(
                p_compartment_id, vector_normalize(p_query), p_limit, v_metric);
    END IF;
END;
$body$;

GRANT EXECUTE ON FUNCTION ann_build(bigint, integer, integer, integer),
                          ann_rebuild(bigint),
                          ann_status(bigint),
                          tombstone_vector_chunk(bigint)
TO maludb_llm_admin,
   maludb_llm_executor;
