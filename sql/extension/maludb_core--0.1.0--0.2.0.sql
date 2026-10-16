\echo Use "ALTER EXTENSION maludb_core UPDATE TO '0.2.0'" to load this file. \quit

-- =====================================================================
-- maludb_core 0.1.0 → 0.2.0
--
-- Anchors the R1.1 alpha additions that landed after R1.0 sign-off:
--   R1.1-12 — compartmentalized vector substrate (Stage 1.7)
--   R1.1-13 — C top-K heap exact vector search
--   R1.1-14 — vector search observability + maludb.memory.search.exact
--
-- Purely additive against the R1.0 baseline. No object renames, no
-- destructive changes. Apply with:
--
--   ALTER EXTENSION maludb_core UPDATE TO '0.2.0';
-- =====================================================================

-- ---------------------------------------------------------------------
-- Bump the version-reporting function. pg_extension.extversion is
-- managed by PG from the control file; this function is how
-- maludb.health and other callers read the same string back. The
-- release-line string (maludb_core_release) stays at "R1.0 Stage 1
-- substrate" — 0.2.0 is still inside the R1.0 release line; it just
-- carries the R1.1 alpha additions ahead of the v1.0.0-rc1 tag.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION maludb_core_version() RETURNS text
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$ SELECT '0.2.0'::text $body$;

-- ---------------------------------------------------------------------
-- New Stage 1.7 object_type seeds. The base R1.0 install closes its
-- object_type INSERT with `mc2db_invocation`; we add a follow-on
-- INSERT for the four vector_* types here.
-- ---------------------------------------------------------------------
INSERT INTO malu$object_type(object_type, stage, description) VALUES
    ('vector_subject',       1, 'Stage 1.7. Compartment-routing subject (instance, per-tenant).'),
    ('vector_verb',          1, 'Stage 1.7. Compartment-routing verb (instance, per-tenant).'),
    ('vector_compartment',   1, 'Stage 1.7. (subject, verb) routing compartment for vector search.'),
    ('vector_chunk',         1, 'Stage 1.7. BYTEA-packed float32 embedding bound to a compartment.');

-- =====================================================================
-- R1.1-12: Compartmentalized vector search — catalog + BYTEA storage
--
-- Stage 1.7 vector substrate. Tables sit beneath the Stage 2+ memory
-- object model and are deliberately distinct from malu$svpor_*
-- (Stage 3 semantic SVPOR) and malu$verb_type / malu$source_type
-- (Stage 1 type registries). Design from
-- docs/research/2026-05-06-compartmentalized-vector-search.md.
--
-- Doctrine: relational filter first. Exact vector scoring second.
-- Top-K third. Compartment = (owner_schema, namespace, subject_id,
-- verb_id) and is the primary access path; vectors are ranked
-- INSIDE a resolved compartment, never across the whole table.
-- Embeddings stored as BYTEA-packed little-endian float32 (length
-- divisible by 4). pgvector dependency stays for the malu$vector_demo
-- legacy smoke table from R1.0-1; new path is BYTEA-only.
-- =====================================================================

CREATE TABLE malu$vector_subject (
    subject_id     bigserial PRIMARY KEY,
    owner_schema   name NOT NULL DEFAULT current_schema(),
    namespace      text NOT NULL,
    subject_name   text NOT NULL,
    description    text,
    created_at     timestamptz NOT NULL DEFAULT now(),
    UNIQUE (owner_schema, namespace, subject_name)
);

CREATE TABLE malu$vector_verb (
    verb_id        bigserial PRIMARY KEY,
    owner_schema   name NOT NULL DEFAULT current_schema(),
    namespace      text NOT NULL,
    verb_name      text NOT NULL,
    description    text,
    created_at     timestamptz NOT NULL DEFAULT now(),
    UNIQUE (owner_schema, namespace, verb_name)
);

CREATE TABLE malu$vector_compartment (
    compartment_id    bigserial PRIMARY KEY,
    owner_schema      name NOT NULL DEFAULT current_schema(),
    namespace         text NOT NULL,
    subject_id        bigint NOT NULL REFERENCES malu$vector_subject(subject_id) ON DELETE RESTRICT,
    verb_id           bigint NOT NULL REFERENCES malu$vector_verb(verb_id)       ON DELETE RESTRICT,
    embedding_dim     integer NOT NULL,
    embedding_model   text    NOT NULL,
    distance_metric   text    NOT NULL DEFAULT 'cosine'
        CHECK (distance_metric IN ('cosine','l2','inner_product')),
    vector_count      bigint  NOT NULL DEFAULT 0,
    search_mode       text    NOT NULL DEFAULT 'exact'
        CHECK (search_mode IN ('exact','exact_parallel','local_ann')),
    ann_index_status  text    NOT NULL DEFAULT 'none'
        CHECK (ann_index_status IN ('none','building','ready','stale','rebuilding','disabled')),
    created_at        timestamptz NOT NULL DEFAULT now(),
    updated_at        timestamptz NOT NULL DEFAULT now(),
    UNIQUE (owner_schema, namespace, subject_id, verb_id)
);

CREATE TABLE malu$vector_chunk (
    chunk_id         bigserial PRIMARY KEY,
    compartment_id   bigint NOT NULL
        REFERENCES malu$vector_compartment(compartment_id) ON DELETE CASCADE,
    source_text      text NOT NULL,
    embedding        bytea NOT NULL,
    embedding_dim    integer NOT NULL,
    embedding_model  text NOT NULL,
    embedding_norm   double precision,
    importance_score numeric(6,3),
    created_at       timestamptz NOT NULL DEFAULT now(),
    CHECK (octet_length(embedding) = embedding_dim * 4),
    CHECK (embedding_dim > 0)
);

CREATE INDEX malu$vector_chunk_compartment_idx
    ON malu$vector_chunk(compartment_id);

-- =====================================================================
-- C distance helpers (LANGUAGE C, defined in src/maludb_vector.c)
-- =====================================================================
CREATE FUNCTION vector_from_real_array(real[]) RETURNS bytea
    AS 'MODULE_PATHNAME', 'maludb_vector_from_real_array'
    LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE FUNCTION vector_to_real_array(bytea) RETURNS real[]
    AS 'MODULE_PATHNAME', 'maludb_vector_to_real_array'
    LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE FUNCTION vector_dims(bytea) RETURNS integer
    AS 'MODULE_PATHNAME', 'maludb_vector_dims'
    LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE FUNCTION vector_norm(bytea) RETURNS double precision
    AS 'MODULE_PATHNAME', 'maludb_vector_norm'
    LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE FUNCTION vector_dot_product(bytea, bytea) RETURNS double precision
    AS 'MODULE_PATHNAME', 'maludb_vector_dot_product'
    LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE FUNCTION vector_l2_squared(bytea, bytea) RETURNS double precision
    AS 'MODULE_PATHNAME', 'maludb_vector_l2_squared'
    LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE FUNCTION vector_normalize(bytea) RETURNS bytea
    AS 'MODULE_PATHNAME', 'maludb_vector_normalize'
    LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

-- =====================================================================
-- PL/pgSQL distance wrappers — convert C primitives into the metrics
-- a search planner uses. cosine assumes vectors may not be normalized;
-- the search hot path uses inner_product on pre-normalized chunks.
-- =====================================================================
CREATE FUNCTION cosine_distance(a bytea, b bytea) RETURNS double precision
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

CREATE FUNCTION l2_squared_distance(a bytea, b bytea) RETURNS double precision
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
AS $body$ SELECT vector_l2_squared(a, b) $body$;

CREATE FUNCTION inner_product(a bytea, b bytea) RETURNS double precision
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
AS $body$ SELECT vector_dot_product(a, b) $body$;

-- =====================================================================
-- Registration APIs — idempotent for catalog rows; chunk normalizes
-- the embedding at insert and bumps the parent compartment's
-- vector_count. Operators MUST register subject/verb/compartment before
-- inserting chunks.
-- =====================================================================
CREATE FUNCTION register_vector_subject(p_namespace text, p_subject_name text)
RETURNS bigint LANGUAGE plpgsql AS $body$
DECLARE v_id bigint;
BEGIN
    INSERT INTO malu$vector_subject(namespace, subject_name)
         VALUES (p_namespace, p_subject_name)
    ON CONFLICT (owner_schema, namespace, subject_name)
        DO UPDATE SET subject_name = EXCLUDED.subject_name
        RETURNING subject_id INTO v_id;
    RETURN v_id;
END;
$body$;

CREATE FUNCTION register_vector_verb(p_namespace text, p_verb_name text)
RETURNS bigint LANGUAGE plpgsql AS $body$
DECLARE v_id bigint;
BEGIN
    INSERT INTO malu$vector_verb(namespace, verb_name)
         VALUES (p_namespace, p_verb_name)
    ON CONFLICT (owner_schema, namespace, verb_name)
        DO UPDATE SET verb_name = EXCLUDED.verb_name
        RETURNING verb_id INTO v_id;
    RETURN v_id;
END;
$body$;

CREATE FUNCTION register_vector_compartment(
    p_namespace        text,
    p_subject_name     text,
    p_verb_name        text,
    p_embedding_dim    integer,
    p_embedding_model  text,
    p_distance_metric  text DEFAULT 'cosine'
) RETURNS bigint
LANGUAGE plpgsql
AS $body$
DECLARE
    v_subject_id     bigint := register_vector_subject(p_namespace, p_subject_name);
    v_verb_id        bigint := register_vector_verb(p_namespace, p_verb_name);
    v_compartment_id bigint;
BEGIN
    INSERT INTO malu$vector_compartment
        (namespace, subject_id, verb_id,
         embedding_dim, embedding_model, distance_metric)
    VALUES
        (p_namespace, v_subject_id, v_verb_id,
         p_embedding_dim, p_embedding_model, p_distance_metric)
    ON CONFLICT (owner_schema, namespace, subject_id, verb_id)
        DO UPDATE SET updated_at = now()
        RETURNING compartment_id INTO v_compartment_id;
    RETURN v_compartment_id;
END;
$body$;

CREATE FUNCTION register_vector_chunk(
    p_compartment_id  bigint,
    p_source_text     text,
    p_embedding       bytea,
    p_embedding_model text DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql
AS $body$
DECLARE
    v_dim       integer := vector_dims(p_embedding);
    v_normed    bytea   := vector_normalize(p_embedding);
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

-- =====================================================================
-- exact_vector_search_sql / _plpgsql / _c — exact compartment scan
-- with top-K result. The SQL-callable name is exact_vector_search_sql;
-- it dispatches to the C implementation (exact_vector_search_c) by
-- default. The PL/pgSQL implementation is retained as
-- exact_vector_search_plpgsql for cross-validation in tests and
-- as a fallback if the C function is unavailable. R1.1-13.
-- =====================================================================

-- C implementation: bounded top-K max-heap; O(N·log K) time, O(K) memory.
CREATE FUNCTION exact_vector_search_c(
    p_compartment_id bigint,
    p_query          bytea,
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

-- Public name dispatches to C. Same signature as the PL/pgSQL prototype.
CREATE FUNCTION exact_vector_search_sql(
    p_compartment_id bigint,
    p_query          bytea,
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

-- PL/pgSQL fallback / cross-validation implementation.
CREATE FUNCTION exact_vector_search_plpgsql(
    p_compartment_id bigint,
    p_query          bytea,
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
    v_query   bytea;
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
    p_query          bytea,
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

-- =====================================================================
-- R1.1-14: vector search observability + MC2DB tool
--
-- - Stats view: aggregate vector_count + per-compartment query
--   counters from the audit table.
-- - explain_vector_search(): planner rationale for a given lookup.
-- - r10_memory_search_exact: PL/pgSQL wrapper for the MC2DB tool that
--   accepts a query text alongside the embedding (caller does the
--   embedding render externally for now; R1.2 may add an in-DB
--   embedding model registry).
-- - mc2db.register_tool() entry: maludb.memory.search.exact.
-- =====================================================================

CREATE VIEW malu$vector_compartment_stats AS
SELECT
    c.compartment_id,
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
FROM malu$vector_compartment c
JOIN malu$vector_subject s ON s.subject_id = c.subject_id
JOIN malu$vector_verb    v ON v.verb_id    = c.verb_id;

CREATE FUNCTION explain_vector_search(
    p_namespace text,
    p_subject   text,
    p_verb      text
) RETURNS TABLE (
    compartment_id    bigint,
    namespace         text,
    subject_name      text,
    verb_name         text,
    embedding_dim     integer,
    embedding_model   text,
    distance_metric   text,
    vector_count      bigint,
    search_mode       text,
    recommended_mode  text,
    ann_index_status  text
) LANGUAGE sql STABLE
AS $body$
    SELECT
        c.compartment_id,
        c.namespace,
        s.subject_name,
        v.verb_name,
        c.embedding_dim,
        c.embedding_model,
        c.distance_metric,
        c.vector_count,
        c.search_mode,
        CASE
            WHEN c.vector_count <    10000 THEN 'exact'
            WHEN c.vector_count <   250000 THEN 'exact_or_ann'
            ELSE                                'local_ann'
        END                              AS recommended_mode,
        c.ann_index_status
    FROM malu$vector_compartment c
    JOIN malu$vector_subject s ON s.subject_id = c.subject_id
    JOIN malu$vector_verb    v ON v.verb_id    = c.verb_id
    WHERE c.namespace    = p_namespace
      AND s.subject_name = p_subject
      AND v.verb_name    = p_verb;
$body$;

CREATE FUNCTION r10_memory_search_exact(args jsonb, context jsonb) RETURNS void
LANGUAGE plpgsql SECURITY INVOKER
AS $body$
DECLARE
    v_namespace  text  := args->>'namespace';
    v_subject    text  := args->>'subject';
    v_verb       text  := args->>'verb';
    v_query_b64  text  := args->>'query_embedding_b64';
    v_limit      int   := COALESCE((args->>'limit')::int, 10);
    v_metric     text  := args->>'metric';
    v_query      bytea;
    v_results    jsonb;
    v_compartment bigint;
BEGIN
    IF v_namespace IS NULL OR v_subject IS NULL OR v_verb IS NULL OR v_query_b64 IS NULL THEN
        CALL mc2db.put_error('namespace, subject, verb, and query_embedding_b64 are required',
            jsonb_build_object('code','BAD_INPUT'));
        RETURN;
    END IF;

    v_query := decode(v_query_b64, 'base64');

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

SELECT mc2db.register_tool(
    server_name => 'maludb.r10',
    tool_name   => 'maludb.memory.search.exact',
    description => 'Compartment-first exact vector search. Resolves (namespace, subject, verb) to a vector compartment, then ranks by distance. Caller supplies a base64-encoded BYTEA-packed float32 query embedding.',
    implementation_type => 'sql_function',
    input_schema => '{"type":"object",
        "properties":{
            "namespace":{"type":"string"},
            "subject":{"type":"string"},
            "verb":{"type":"string"},
            "query_embedding_b64":{"type":"string",
                "description":"base64-encoded BYTEA-packed little-endian float32 vector"},
            "limit":{"type":"integer","minimum":1,"maximum":1000},
            "metric":{"type":"string","enum":["cosine","l2","inner_product"]}},
        "required":["namespace","subject","verb","query_embedding_b64"]}'::jsonb,
    output_schema => '{"type":"object",
        "required":["compartment_id","results"]}'::jsonb,
    impl_metadata => jsonb_build_object('function_signature',
        'maludb_core.r10_memory_search_exact(jsonb, jsonb)'));

