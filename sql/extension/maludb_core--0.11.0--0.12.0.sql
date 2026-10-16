\echo Use "ALTER EXTENSION maludb_core UPDATE TO '0.12.0'" to load this file. \quit

-- =====================================================================
-- maludb_core 0.11.0 → 0.12.0
--
-- R1.1-17: Custom malu_vector PG type.
--
-- Replaces BYTEA-as-vector with a real custom varlena type. Storage
-- is binary-compatible with bytea (same varlena header, same float32
-- payload), so a WITHOUT FUNCTION cast suffices in both directions
-- and the ALTER TABLE ... TYPE ... USING is a catalog-only operation
-- (no row rewrite).
--
-- Text I/O matches pgvector's vector(N) format: "[f1, f2, ...]".
-- Binary I/O is the raw float32 payload (same as bytea_send/recv on
-- the same bytes).
--
-- All R1.1-12/13/14 C entry points (maludb_vector_*, maludb_search_*)
-- already use VARSIZE_ANY_EXHDR + VARDATA_ANY, which apply to any
-- varlena type. Only the SQL declarations swap from bytea to
-- malu_vector; the C objects are unchanged.
-- =====================================================================

CREATE OR REPLACE FUNCTION maludb_core_version() RETURNS text
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$ SELECT '0.12.0'::text $body$;

-- ---------------------------------------------------------------------
-- I/O functions (C, defined in src/maludb_type.c). Use the shell-type
-- pattern: declare the I/O functions first with stand-in types, then
-- CREATE TYPE binds them. PostgreSQL requires this dance because the
-- IN function references the type that doesn't exist yet.
-- ---------------------------------------------------------------------
CREATE TYPE malu_vector;  -- shell

CREATE FUNCTION malu_vector_in(cstring) RETURNS malu_vector
    AS 'MODULE_PATHNAME', 'maludb_vector_in'
    LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE FUNCTION malu_vector_out(malu_vector) RETURNS cstring
    AS 'MODULE_PATHNAME', 'maludb_vector_out'
    LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE FUNCTION malu_vector_recv(internal) RETURNS malu_vector
    AS 'MODULE_PATHNAME', 'maludb_vector_recv'
    LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE FUNCTION malu_vector_send(malu_vector) RETURNS bytea
    AS 'MODULE_PATHNAME', 'maludb_vector_send'
    LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE TYPE malu_vector (
    INPUT          = malu_vector_in,
    OUTPUT         = malu_vector_out,
    RECEIVE        = malu_vector_recv,
    SEND           = malu_vector_send,
    INTERNALLENGTH = VARIABLE,
    STORAGE        = extended,
    ALIGNMENT      = int4
);

COMMENT ON TYPE malu_vector IS
    'R1.1-17 custom varlena vector type. Binary-compatible with bytea '
    '(WITHOUT FUNCTION cast in both directions). Text format: "[f1, f2, ...]".';

-- ---------------------------------------------------------------------
-- Binary-compatible casts. WITHOUT FUNCTION = zero-cost reinterpret.
-- Both directions are ASSIGNMENT context (not IMPLICIT) so the type
-- system doesn't auto-cast in ambiguous expressions, but explicit
-- ::malu_vector / ::bytea casts and column-type changes work.
-- ---------------------------------------------------------------------
CREATE CAST (bytea       AS malu_vector) WITHOUT FUNCTION AS ASSIGNMENT;
CREATE CAST (malu_vector AS bytea)       WITHOUT FUNCTION AS ASSIGNMENT;

-- octet_length overload — needed by the malu$vector_chunk CHECK constraint
-- that ALTER COLUMN preserves below. Delegates through the binary cast.
CREATE FUNCTION octet_length(malu_vector) RETURNS integer
    LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
    AS $body$ SELECT octet_length($1::bytea) $body$;

-- ---------------------------------------------------------------------
-- Swap vector primitive function signatures from bytea → malu_vector.
-- We DROP+CREATE because PG matches function identity by argument
-- types; CREATE OR REPLACE with a different type creates an overload.
--
-- The C entry points (maludb_vector_dot_product, etc.) are unchanged
-- — they read varlena bytes generically.
-- ---------------------------------------------------------------------
DROP FUNCTION vector_from_real_array(real[]);
DROP FUNCTION vector_to_real_array(bytea);
DROP FUNCTION vector_dims(bytea);
DROP FUNCTION vector_norm(bytea);
DROP FUNCTION vector_dot_product(bytea, bytea);
DROP FUNCTION vector_l2_squared(bytea, bytea);
DROP FUNCTION vector_normalize(bytea);

CREATE FUNCTION vector_from_real_array(real[]) RETURNS malu_vector
    AS 'MODULE_PATHNAME', 'maludb_vector_from_real_array'
    LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE FUNCTION vector_to_real_array(malu_vector) RETURNS real[]
    AS 'MODULE_PATHNAME', 'maludb_vector_to_real_array'
    LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE FUNCTION vector_dims(malu_vector) RETURNS integer
    AS 'MODULE_PATHNAME', 'maludb_vector_dims'
    LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE FUNCTION vector_norm(malu_vector) RETURNS double precision
    AS 'MODULE_PATHNAME', 'maludb_vector_norm'
    LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE FUNCTION vector_dot_product(malu_vector, malu_vector) RETURNS double precision
    AS 'MODULE_PATHNAME', 'maludb_vector_dot_product'
    LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE FUNCTION vector_l2_squared(malu_vector, malu_vector) RETURNS double precision
    AS 'MODULE_PATHNAME', 'maludb_vector_l2_squared'
    LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE FUNCTION vector_normalize(malu_vector) RETURNS malu_vector
    AS 'MODULE_PATHNAME', 'maludb_vector_normalize'
    LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

-- ---------------------------------------------------------------------
-- PL/pgSQL distance wrappers — same DROP+CREATE dance.
-- ---------------------------------------------------------------------
DROP FUNCTION cosine_distance(bytea, bytea);
DROP FUNCTION l2_squared_distance(bytea, bytea);
DROP FUNCTION inner_product(bytea, bytea);

CREATE FUNCTION cosine_distance(a malu_vector, b malu_vector) RETURNS double precision
LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE
AS $body$
DECLARE
    na double precision := vector_norm(a);
    nb double precision := vector_norm(b);
BEGIN
    IF na = 0 OR nb = 0 THEN RETURN 1.0; END IF;
    RETURN 1.0 - (vector_dot_product(a, b) / (na * nb));
END;
$body$;

CREATE FUNCTION l2_squared_distance(a malu_vector, b malu_vector) RETURNS double precision
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
AS $body$ SELECT vector_l2_squared(a, b) $body$;

CREATE FUNCTION inner_product(a malu_vector, b malu_vector) RETURNS double precision
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
AS $body$ SELECT vector_dot_product(a, b) $body$;

-- ---------------------------------------------------------------------
-- Swap the malu$vector_chunk.embedding column type to malu_vector.
-- Binary layout is identical to bytea, so the USING cast is a no-op
-- on the data side; only pg_attribute changes.
-- ---------------------------------------------------------------------
ALTER TABLE malu$vector_chunk
    ALTER COLUMN embedding TYPE malu_vector USING embedding::malu_vector;

-- octet_length still works on malu_vector via the implicit varlena
-- interpretation, so the existing CHECK constraint stays meaningful.

-- ---------------------------------------------------------------------
-- Re-declare the search functions (exact + planner + tool) with
-- malu_vector signatures. The C entry point for exact_vector_search_c
-- is unchanged.
-- ---------------------------------------------------------------------
DROP FUNCTION search_memory_exact(text, text, text, bytea, integer, text);
DROP FUNCTION exact_vector_search_sql(bigint, bytea, integer, text);
DROP FUNCTION exact_vector_search_plpgsql(bigint, bytea, integer, text);
DROP FUNCTION exact_vector_search_c(bigint, bytea, integer, text);

CREATE FUNCTION exact_vector_search_c(
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
)
AS 'MODULE_PATHNAME', 'maludb_exact_vector_search_c'
LANGUAGE C STABLE PARALLEL SAFE;

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
    RETURN QUERY
        SELECT * FROM exact_vector_search_c(
            p_compartment_id, vector_normalize(p_query), p_limit, v_metric);
END;
$body$;

CREATE FUNCTION exact_vector_search_plpgsql(
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
    v_metric  text;
    v_compart malu$vector_compartment%ROWTYPE;
    v_query   malu_vector;
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
    v_query  := vector_normalize(p_query);

    IF v_metric = 'cosine' THEN
        RETURN QUERY
            SELECT c.chunk_id, c.source_text,
                   1.0 - vector_dot_product(c.embedding, v_query) AS distance,
                         vector_dot_product(c.embedding, v_query) AS similarity,
                   ROW_NUMBER() OVER (
                       ORDER BY vector_dot_product(c.embedding, v_query) DESC
                   )::integer AS rank_no
              FROM malu$vector_chunk c
             WHERE c.compartment_id = p_compartment_id
             ORDER BY similarity DESC
             LIMIT p_limit;
    ELSIF v_metric = 'l2' THEN
        RETURN QUERY
            SELECT c.chunk_id, c.source_text,
                   vector_l2_squared(c.embedding, p_query)        AS distance,
                   -vector_l2_squared(c.embedding, p_query)       AS similarity,
                   ROW_NUMBER() OVER (
                       ORDER BY vector_l2_squared(c.embedding, p_query) ASC
                   )::integer AS rank_no
              FROM malu$vector_chunk c
             WHERE c.compartment_id = p_compartment_id
             ORDER BY distance ASC
             LIMIT p_limit;
    ELSIF v_metric = 'inner_product' THEN
        RETURN QUERY
            SELECT c.chunk_id, c.source_text,
                   -vector_dot_product(c.embedding, p_query)      AS distance,
                    vector_dot_product(c.embedding, p_query)      AS similarity,
                   ROW_NUMBER() OVER (
                       ORDER BY vector_dot_product(c.embedding, p_query) DESC
                   )::integer AS rank_no
              FROM malu$vector_chunk c
             WHERE c.compartment_id = p_compartment_id
             ORDER BY similarity DESC
             LIMIT p_limit;
    ELSE
        RAISE EXCEPTION 'unknown distance metric: %', v_metric
            USING ERRCODE = 'check_violation';
    END IF;
END;
$body$;

CREATE FUNCTION search_memory_exact(
    p_namespace      text,
    p_subject        text,
    p_verb           text,
    p_query          malu_vector,
    p_limit          integer DEFAULT 10,
    p_metric         text    DEFAULT NULL
) RETURNS TABLE (
    chunk_id        bigint,
    source_text     text,
    distance        double precision,
    similarity      double precision,
    rank_no         integer,
    compartment_id  bigint
) LANGUAGE plpgsql
AS $body$
DECLARE
    v_compartment_id bigint;
BEGIN
    SELECT c.compartment_id INTO v_compartment_id
      FROM malu$vector_compartment c
      JOIN malu$vector_subject s ON s.subject_id = c.subject_id
      JOIN malu$vector_verb    v ON v.verb_id    = c.verb_id
     WHERE c.namespace = p_namespace
       AND s.subject_name = p_subject
       AND v.verb_name    = p_verb
     LIMIT 1;
    IF v_compartment_id IS NULL THEN
        RAISE EXCEPTION 'no compartment for namespace=% subject=% verb=%',
            p_namespace, p_subject, p_verb
            USING ERRCODE = 'no_data_found';
    END IF;
    RETURN QUERY
        SELECT r.chunk_id, r.source_text, r.distance, r.similarity, r.rank_no,
               v_compartment_id
          FROM exact_vector_search_sql(v_compartment_id, p_query, p_limit, p_metric) r;
END;
$body$;

-- ---------------------------------------------------------------------
-- register_vector_chunk — accept malu_vector instead of bytea.
-- ---------------------------------------------------------------------
DROP FUNCTION register_vector_chunk(bigint, text, bytea, text);

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

    RETURN v_chunk_id;
END;
$body$;

-- ---------------------------------------------------------------------
-- r10_memory_search_exact wraps the MC2DB tool. The body decodes the
-- base64 query into bytea, then casts to malu_vector for the search.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION r10_memory_search_exact(args jsonb, context jsonb) RETURNS void
LANGUAGE plpgsql SECURITY INVOKER
AS $body$
DECLARE
    v_namespace  text  := args->>'namespace';
    v_subject    text  := args->>'subject';
    v_verb       text  := args->>'verb';
    v_query_b64  text  := args->>'query_embedding_b64';
    v_limit      int   := COALESCE((args->>'limit')::int, 10);
    v_metric     text  := args->>'metric';
    v_query      malu_vector;
    v_results    jsonb;
    v_compartment bigint;
BEGIN
    IF v_namespace IS NULL OR v_subject IS NULL OR v_verb IS NULL OR v_query_b64 IS NULL THEN
        CALL mc2db.put_error('namespace, subject, verb, and query_embedding_b64 are required',
            jsonb_build_object('code','BAD_INPUT'));
        RETURN;
    END IF;

    v_query := decode(v_query_b64, 'base64')::malu_vector;

    SELECT compartment_id INTO v_compartment FROM explain_vector_search(v_namespace, v_subject, v_verb);
    IF v_compartment IS NULL THEN
        CALL mc2db.put_error(format('no compartment for %s/%s/%s', v_namespace, v_subject, v_verb),
            jsonb_build_object('code','NOT_FOUND'));
        RETURN;
    END IF;

    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'chunk_id',    r.chunk_id,
        'source_text', r.source_text,
        'distance',    r.distance,
        'similarity',  r.similarity,
        'rank',        r.rank_no) ORDER BY r.rank_no), '[]'::jsonb)
    INTO v_results
    FROM search_memory_exact(v_namespace, v_subject, v_verb, v_query, v_limit, v_metric) r;

    CALL mc2db.put_object(jsonb_build_object(
        'content', jsonb_build_array(jsonb_build_object('type','text',
            'text', format('%s result(s) from compartment %s',
                           jsonb_array_length(v_results), v_compartment))),
        'structuredContent', jsonb_build_object(
            'compartment_id', v_compartment,
            'results',        v_results),
        'isError', false));
END;
$body$;
