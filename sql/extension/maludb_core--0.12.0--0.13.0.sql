\echo Use "ALTER EXTENSION maludb_core UPDATE TO '0.13.0'" to load this file. \quit

-- =====================================================================
-- maludb_core 0.12.0 → 0.13.0
--
-- R1.1-15: Parallel exact vector search.
--
-- Adds a parallel-safe custom aggregate `topk_vector_search` whose
-- INTERNAL state is a bounded top-K max-heap (src/maludb_topk.c).
-- PG's parallel-aware aggregate machinery splits the
-- malu$vector_chunk scan across worker backends; each maintains its
-- own heap; the COMBINEFUNC merges worker heaps into the leader.
--
-- The exact_vector_search_sql dispatcher checks
-- malu$vector_compartment.search_mode:
--   - 'exact'           → existing single-process C heap (R1.1-13)
--   - 'exact_parallel'  → new aggregate path (this phase)
--   - 'local_ann'       → reserved for R1.1-16 (raises until then)
-- =====================================================================

CREATE OR REPLACE FUNCTION maludb_core_version() RETURNS text
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$ SELECT '0.13.0'::text $body$;

-- ---------------------------------------------------------------------
-- C functions backing the aggregate. Internal state is opaque
-- (LANGUAGE C with INTERNAL stype); serial/deserial round-trip the
-- state through bytea at worker boundaries.
-- ---------------------------------------------------------------------
CREATE FUNCTION topk_vector_sfunc(
    state        internal,
    embedding    malu_vector,
    chunk_id     bigint,
    source_text  text,
    query        malu_vector,
    k            integer,
    metric       text
) RETURNS internal
    AS 'MODULE_PATHNAME', 'maludb_topk_vector_sfunc'
    LANGUAGE C IMMUTABLE PARALLEL SAFE;

CREATE FUNCTION topk_vector_combine(internal, internal) RETURNS internal
    AS 'MODULE_PATHNAME', 'maludb_topk_vector_combine'
    LANGUAGE C IMMUTABLE PARALLEL SAFE;

CREATE FUNCTION topk_vector_serialize(internal) RETURNS bytea
    AS 'MODULE_PATHNAME', 'maludb_topk_vector_serialize'
    LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE FUNCTION topk_vector_deserialize(bytea, internal) RETURNS internal
    AS 'MODULE_PATHNAME', 'maludb_topk_vector_deserialize'
    LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE FUNCTION topk_vector_finalize(internal) RETURNS jsonb
    AS 'MODULE_PATHNAME', 'maludb_topk_vector_finalize'
    LANGUAGE C IMMUTABLE PARALLEL SAFE;

-- ---------------------------------------------------------------------
-- The aggregate. Returns a jsonb array of top-K entries
-- (sorted by distance ascending). exact_vector_search_parallel_c()
-- below fans this out into the standard search result rowtype.
-- ---------------------------------------------------------------------
CREATE AGGREGATE topk_vector_search(
    embedding    malu_vector,
    chunk_id     bigint,
    source_text  text,
    query        malu_vector,
    k            integer,
    metric       text
) (
    SFUNC        = topk_vector_sfunc,
    STYPE        = internal,
    COMBINEFUNC  = topk_vector_combine,
    SERIALFUNC   = topk_vector_serialize,
    DESERIALFUNC = topk_vector_deserialize,
    FINALFUNC    = topk_vector_finalize,
    PARALLEL     = SAFE
);

-- ---------------------------------------------------------------------
-- exact_vector_search_parallel_c: SQL wrapper. The aggregate runs over
-- malu$vector_chunk filtered by compartment_id (relational filter
-- first), and we unpack the resulting jsonb into the standard result
-- rowtype.
-- ---------------------------------------------------------------------
CREATE FUNCTION exact_vector_search_parallel_c(
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
) LANGUAGE plpgsql STABLE
AS $body$
DECLARE
    v_compart  malu$vector_compartment%ROWTYPE;
    v_metric   text;
    v_qnorm    malu_vector;
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
    v_qnorm  := vector_normalize(p_query);

    RETURN QUERY
        WITH agg AS (
            SELECT topk_vector_search(
                       c.embedding, c.chunk_id, c.source_text,
                       v_qnorm, p_limit, v_metric) AS j
            FROM malu$vector_chunk c
            WHERE c.compartment_id = p_compartment_id
        ),
        rows AS (
            SELECT e
            FROM   agg, jsonb_array_elements(agg.j) e
        )
        SELECT (e->>'chunk_id')::bigint,
               e->>'source_text',
               (e->>'distance')::double precision,
               (e->>'similarity')::double precision,
               (e->>'rank_no')::integer
        FROM   rows
        ORDER BY (e->>'rank_no')::integer;
END;
$body$;

-- ---------------------------------------------------------------------
-- exact_vector_search_sql: dispatcher that honours
-- malu$vector_compartment.search_mode.
--
-- Behaviour table:
--   search_mode='exact'           → exact_vector_search_c (R1.1-13)
--   search_mode='exact_parallel'  → exact_vector_search_parallel_c
--   search_mode='local_ann'       → raises (reserved for R1.1-16)
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

    IF v_compart.search_mode = 'exact_parallel' THEN
        RETURN QUERY
            SELECT * FROM exact_vector_search_parallel_c(
                p_compartment_id, p_query, p_limit, v_metric);
    ELSIF v_compart.search_mode = 'local_ann' THEN
        RAISE EXCEPTION
          'SEARCH_MODE_UNAVAILABLE: local_ann is reserved for R1.1-16 and not yet implemented'
          USING ERRCODE = 'feature_not_supported';
    ELSE
        RETURN QUERY
            SELECT * FROM exact_vector_search_c(
                p_compartment_id, vector_normalize(p_query), p_limit, v_metric);
    END IF;
END;
$body$;
