\echo Use "ALTER EXTENSION maludb_core UPDATE TO '0.88.0'" to load this file. \quit

-- =====================================================================
-- maludb_core 0.87.0 -> 0.88.0
--
-- Subject/verb-compartmentalized memory search: the embedding rail joins
-- the canonical SVPOR graph.
--
-- Background. maludb_core already had every piece of a
-- "compartmentalize the vector search by subject+verb" design, but as
-- three disconnected islands:
--   (A) the canonical SVO graph  -- malu$svpor_subject/_verb/_statement
--       + the typed edge-attribute store malu$svpor_attribute;
--   (B) compartmentalized chunk vectors -- malu$vector_compartment
--       (keyed (owner_schema, namespace, subject_id, verb_id)) +
--       malu$vector_chunk, searched by vector_search_by_tags();
--   (C) object embeddings -- malu$object_embedding + semantic_search().
-- The load-bearing gap was that (B)'s subject_id/verb_id pointed at a
-- SEPARATE text registry (malu$vector_subject/_verb) with NO link to the
-- graph in (A). "Compartmentalize by subject_id/verb_id" therefore worked
-- only by string convention, and a retrieved chunk had no pointer back to
-- its edge or document.
--
-- This release binds (B) to (A) and adds the ingest+search spine:
--   * malu$vector_subject.svpor_subject_id  (FK -> malu$svpor_subject)
--   * malu$vector_verb.svpor_verb_id        (FK -> malu$svpor_verb)
--   * malu$vector_chunk.statement_id        (FK -> malu$svpor_statement)
--   * malu$vector_chunk.document_id          (soft ref, repo style)
--   * _vector_compartment_for_svpor(...)     -- graph ids -> compartment,
--       deriving the routing tags from the canonical_name and recording
--       the graph link on the routing rows (keeps the canonical graph the
--       single source of truth; no drift).
--   * _memory_ingest_edge_for_schema(...)    -- the ingestion contract:
--       resolve subject/verb (alias-aware, create if absent) -> upsert the
--       SVO edge -> apply the predicate as typed edge attributes -> embed
--       the per-edge span into the graph-aligned compartment, stamping the
--       chunk with statement_id/document_id.
--   * _memory_search_for_schema(...)         -- pre-filtered compartment
--       ANN that returns statement_id (one relational hop to subject/verb;
--       no graph traversal on the first pass).
--   * per-tenant facades maludb_memory_ingest_edge / maludb_memory_search
--       (built by enable_memory_schema; re-enable-safe).
--
-- Design decisions locked for this pass (see embedding-handoff-analysis.md):
--   - Extraction stays EXTERNAL (a strong cloud model first); the DB
--     exposes a contract, not an orchestrator.
--   - Canonical verb is the edge + compartment key; status/actuality/
--     timing are predicate EDGE ATTRIBUTES (e.g. verb 'upgrade', not
--     'performed_upgrade').
--   - Embed PER-EDGE SPAN (N edges in a chunk -> N compartment placements).
--   - document_id is a soft reference (no FK), matching the document-tag
--     style; statement_id keeps its FK.
--   - Fuzzy/candidate resolution is deferred (Tier 2): a strong cloud model
--     emits near-canonical surface forms, so exact + alias resolution is
--     sufficient here. resolve_*-style fuzzy linking comes later.
--
-- Backward compatible: all new columns are nullable; no existing function
-- signature changes; new functions only. Existing schemas pick up the
-- facades by re-running maludb_core.enable_memory_schema().
-- =====================================================================

CREATE OR REPLACE FUNCTION maludb_core.maludb_core_version() RETURNS text
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$ SELECT '0.88.0'::text $body$;

-- =====================================================================
-- 1. Bind the vector routing registry + chunks to the canonical graph.
--    All columns nullable -> existing rows keep working with NULL links.
-- =====================================================================
ALTER TABLE maludb_core.malu$vector_subject
    ADD COLUMN IF NOT EXISTS svpor_subject_id bigint;
ALTER TABLE maludb_core.malu$vector_verb
    ADD COLUMN IF NOT EXISTS svpor_verb_id bigint;
ALTER TABLE maludb_core.malu$vector_chunk
    ADD COLUMN IF NOT EXISTS statement_id bigint,
    ADD COLUMN IF NOT EXISTS document_id  bigint;

-- Foreign keys (ON DELETE SET NULL) -- guarded so the delta is safe to
-- re-source. document_id is intentionally a SOFT reference (no FK).
DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'malu$vector_subject_svpor_fk') THEN
        ALTER TABLE maludb_core.malu$vector_subject
            ADD CONSTRAINT malu$vector_subject_svpor_fk
            FOREIGN KEY (svpor_subject_id)
            REFERENCES maludb_core.malu$svpor_subject(subject_id) ON DELETE SET NULL;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'malu$vector_verb_svpor_fk') THEN
        ALTER TABLE maludb_core.malu$vector_verb
            ADD CONSTRAINT malu$vector_verb_svpor_fk
            FOREIGN KEY (svpor_verb_id)
            REFERENCES maludb_core.malu$svpor_verb(verb_id) ON DELETE SET NULL;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'malu$vector_chunk_statement_fk') THEN
        ALTER TABLE maludb_core.malu$vector_chunk
            ADD CONSTRAINT malu$vector_chunk_statement_fk
            FOREIGN KEY (statement_id)
            REFERENCES maludb_core.malu$svpor_statement(statement_id) ON DELETE SET NULL;
    END IF;
END
$do$;

-- One routing-tag row per graph subject/verb per (owner_schema, namespace):
-- keeps the graph<->compartment mapping 1:1 so the resolver can upsert
-- deterministically.
CREATE UNIQUE INDEX IF NOT EXISTS malu$vector_subject_svpor_uidx
    ON maludb_core.malu$vector_subject(owner_schema, namespace, svpor_subject_id)
    WHERE svpor_subject_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS malu$vector_verb_svpor_uidx
    ON maludb_core.malu$vector_verb(owner_schema, namespace, svpor_verb_id)
    WHERE svpor_verb_id IS NOT NULL;
-- Reverse lookups: chunk -> edge, chunk -> document.
CREATE INDEX IF NOT EXISTS malu$vector_chunk_statement_idx
    ON maludb_core.malu$vector_chunk(statement_id) WHERE statement_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS malu$vector_chunk_document_idx
    ON maludb_core.malu$vector_chunk(document_id) WHERE document_id IS NOT NULL;

-- =====================================================================
-- 2. _vector_compartment_for_svpor -- map graph ids to a compartment.
--    Derives the routing tags from the canonical_name of the graph rows
--    and records the graph link back onto the routing registry rows, so
--    the canonical SVPOR graph stays the single source of truth.
--    SECURITY DEFINER, explicit owner_schema (house style for _for_schema).
-- =====================================================================
CREATE FUNCTION maludb_core._vector_compartment_for_svpor(
    p_owner_schema    name,
    p_subject_id      bigint,
    p_verb_id         bigint,
    p_embedding_dim   integer,
    p_embedding_model text,
    p_namespace       text DEFAULT 'default',
    p_distance_metric text DEFAULT 'cosine'
) RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
DECLARE
    v_namespace      text := COALESCE(NULLIF(p_namespace, ''), 'default');
    v_metric         text := COALESCE(NULLIF(p_distance_metric, ''), 'cosine');
    v_subj_canon     text;
    v_verb_canon     text;
    v_compartment_id bigint;
BEGIN
    PERFORM maludb_core._memory_schema_assert_manageable(p_owner_schema);

    SELECT canonical_name INTO v_subj_canon
      FROM maludb_core.malu$svpor_subject
     WHERE owner_schema = p_owner_schema AND subject_id = p_subject_id;
    SELECT canonical_name INTO v_verb_canon
      FROM maludb_core.malu$svpor_verb
     WHERE owner_schema = p_owner_schema AND verb_id = p_verb_id;

    IF v_subj_canon IS NULL OR v_verb_canon IS NULL THEN
        RAISE EXCEPTION '_vector_compartment_for_svpor: unknown subject_id % / verb_id % in schema %',
            p_subject_id, p_verb_id, p_owner_schema
            USING ERRCODE = 'no_data_found';
    END IF;

    -- reuse the tenant-correct compartment primitive (upserts subject/verb
    -- routing rows by name, then the compartment).
    v_compartment_id := maludb_core._register_vector_compartment_for_schema(
        p_owner_schema, v_namespace, v_subj_canon, v_verb_canon,
        p_embedding_dim, p_embedding_model, v_metric);

    -- stamp the graph link onto the routing rows (idempotent).
    UPDATE maludb_core.malu$vector_subject
       SET svpor_subject_id = p_subject_id
     WHERE owner_schema = p_owner_schema
       AND namespace = v_namespace
       AND subject_name = v_subj_canon
       AND svpor_subject_id IS DISTINCT FROM p_subject_id;

    UPDATE maludb_core.malu$vector_verb
       SET svpor_verb_id = p_verb_id
     WHERE owner_schema = p_owner_schema
       AND namespace = v_namespace
       AND verb_name = v_verb_canon
       AND svpor_verb_id IS DISTINCT FROM p_verb_id;

    RETURN v_compartment_id;
END;
$body$;
REVOKE ALL ON FUNCTION maludb_core._vector_compartment_for_svpor(name, bigint, bigint, integer, text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core._vector_compartment_for_svpor(name, bigint, bigint, integer, text, text, text)
    TO maludb_memory_admin, maludb_memory_executor;

-- =====================================================================
-- 3. _memory_ingest_edge_for_schema -- the ingestion contract.
--    Accepts an external extractor's output for ONE candidate edge:
--      source(kind,id) --verb--> subject, with a typed predicate and an
--      optional precomputed per-edge-span embedding.
--    Resolve (alias-aware) or create subject/verb -> upsert the SVO edge
--    -> apply predicate as typed edge attributes -> embed the span into the
--    graph-aligned compartment, stamping the chunk with statement_id /
--    document_id. Returns the statement_id. Idempotent on the SVO identity.
--    SECURITY DEFINER, explicit owner_schema, raw upserts (house style:
--    register_svpor_statement/attributes_apply are current_schema()-bound,
--    so they are NOT reused here).
-- =====================================================================
CREATE FUNCTION maludb_core._memory_ingest_edge_for_schema(
    p_owner_schema     name,
    p_source_kind      text,
    p_source_id        bigint,
    p_subject_text     text,
    p_verb_text        text,
    p_predicate        jsonb       DEFAULT '[]'::jsonb,
    p_embedding        maludb_core.malu_vector DEFAULT NULL,
    p_embedding_model  text        DEFAULT NULL,
    p_subject_type     text        DEFAULT 'other',
    p_source_span      text        DEFAULT NULL,
    p_confidence       numeric     DEFAULT NULL,
    p_provenance       text        DEFAULT 'suggested',
    p_extraction_model text        DEFAULT NULL,
    p_namespace        text        DEFAULT 'default',
    p_document_id      bigint      DEFAULT NULL,
    p_valid_from       timestamptz DEFAULT NULL,
    p_valid_to         timestamptz DEFAULT NULL,
    p_distance_metric  text        DEFAULT 'cosine'
) RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
DECLARE
    v_source_kind   text := lower(btrim(COALESCE(p_source_kind, '')));
    v_prov          text := COALESCE(NULLIF(btrim(p_provenance), ''), 'suggested');
    v_subj          text := btrim(COALESCE(p_subject_text, ''));
    v_verb          text := btrim(COALESCE(p_verb_text, ''));
    v_subject_type  text := maludb_core._normalize_svpor_subject_type(
                                COALESCE(NULLIF(btrim(p_subject_type), ''), 'other'));
    v_subject_id    bigint;
    v_verb_id       bigint;
    v_statement_id  bigint;
    v_meta          jsonb;
    v_dim           integer;
    v_model         text;
    v_compartment_id bigint;
    v_chunk_id      bigint;
    v_span          text;
BEGIN
    PERFORM maludb_core._memory_schema_assert_manageable(p_owner_schema);

    IF v_subj = '' OR v_verb = '' THEN
        RAISE EXCEPTION 'memory_ingest_edge: subject and verb text are required'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;
    IF p_source_id IS NULL OR v_source_kind = '' THEN
        RAISE EXCEPTION 'memory_ingest_edge: source_kind and source_id are required'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;
    IF v_prov NOT IN ('provided','suggested','accepted','rejected') THEN
        RAISE EXCEPTION 'memory_ingest_edge: bad provenance %', v_prov
            USING ERRCODE = 'invalid_parameter_value';
    END IF;
    IF p_predicate IS NOT NULL AND jsonb_typeof(p_predicate) <> 'array' THEN
        RAISE EXCEPTION 'memory_ingest_edge: p_predicate must be a JSON array of attribute objects'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    -- the source endpoint must already exist in this tenant.
    PERFORM maludb_core._svpor_statement_assert_endpoint(p_owner_schema, v_source_kind, p_source_id);

    -- resolve (canonical or alias, exact) or create the subject.
    SELECT subject_id INTO v_subject_id
      FROM maludb_core.malu$svpor_subject
     WHERE owner_schema = p_owner_schema
       AND (canonical_name = v_subj OR v_subj = ANY(aliases))
     ORDER BY (canonical_name = v_subj) DESC
     LIMIT 1;
    IF v_subject_id IS NULL THEN
        INSERT INTO maludb_core.malu$svpor_subject(owner_schema, canonical_name, subject_type)
        VALUES (p_owner_schema, v_subj, v_subject_type)
        RETURNING subject_id INTO v_subject_id;
    END IF;

    -- resolve or create the verb.
    SELECT verb_id INTO v_verb_id
      FROM maludb_core.malu$svpor_verb
     WHERE owner_schema = p_owner_schema
       AND (canonical_name = v_verb OR v_verb = ANY(aliases))
     ORDER BY (canonical_name = v_verb) DESC
     LIMIT 1;
    IF v_verb_id IS NULL THEN
        INSERT INTO maludb_core.malu$svpor_verb(owner_schema, canonical_name)
        VALUES (p_owner_schema, v_verb)
        RETURNING verb_id INTO v_verb_id;
    END IF;

    -- edge provenance metadata (source span + extracting model), nulls dropped.
    v_meta := jsonb_strip_nulls(jsonb_build_object(
        'source_span',      NULLIF(btrim(COALESCE(p_source_span, '')), ''),
        'extraction_model', NULLIF(btrim(COALESCE(p_extraction_model, '')), '')));

    -- upsert the SVO edge: source --verb--> subject (idempotent on identity).
    INSERT INTO maludb_core.malu$svpor_statement
        (owner_schema, subject_kind, subject_id, verb_id, object_kind, object_id,
         valid_from, valid_to, confidence, provenance, metadata_jsonb)
    VALUES
        (p_owner_schema, v_source_kind, p_source_id, v_verb_id, 'subject', v_subject_id,
         p_valid_from, p_valid_to, p_confidence, v_prov, COALESCE(v_meta, '{}'::jsonb))
    ON CONFLICT (owner_schema, subject_kind, subject_id, verb_id, object_kind, object_id)
    DO UPDATE SET
        confidence     = COALESCE(EXCLUDED.confidence, malu$svpor_statement.confidence),
        provenance     = EXCLUDED.provenance,
        valid_from     = COALESCE(EXCLUDED.valid_from, malu$svpor_statement.valid_from),
        valid_to       = COALESCE(EXCLUDED.valid_to,   malu$svpor_statement.valid_to),
        metadata_jsonb = malu$svpor_statement.metadata_jsonb || EXCLUDED.metadata_jsonb
    RETURNING statement_id INTO v_statement_id;

    -- predicate -> typed edge attributes (upsert on attribute identity).
    IF p_predicate IS NOT NULL AND jsonb_typeof(p_predicate) = 'array' THEN
        INSERT INTO maludb_core.malu$svpor_attribute
            (owner_schema, target_kind, target_id, attr_name,
             value_timestamp, value_range, value_numeric, value_text, value_jsonb,
             unit, provenance, confidence, valid_from, valid_to, metadata_jsonb,
             ref_source, ref_entity, ref_key)
        SELECT p_owner_schema, 'svpor_statement', v_statement_id,
               btrim(e ->> 'attr_name'),
               (e ->> 'value_timestamp')::timestamptz,
               (e ->> 'value_range')::tstzrange,
               (e ->> 'value_numeric')::numeric,
               e ->> 'value_text',
               e -> 'value_jsonb',
               e ->> 'unit',
               COALESCE(e ->> 'provenance', v_prov),
               (e ->> 'confidence')::numeric,
               (e ->> 'valid_from')::timestamptz,
               (e ->> 'valid_to')::timestamptz,
               COALESCE(e -> 'metadata_jsonb', '{}'::jsonb),
               e ->> 'ref_source', e ->> 'ref_entity', e ->> 'ref_key'
          FROM jsonb_array_elements(p_predicate) AS e
         WHERE COALESCE(btrim(e ->> 'attr_name'), '') <> ''
        ON CONFLICT (owner_schema, target_kind, target_id, attr_name)
        DO UPDATE SET
            value_timestamp = EXCLUDED.value_timestamp,
            value_range     = EXCLUDED.value_range,
            value_numeric   = EXCLUDED.value_numeric,
            value_text      = EXCLUDED.value_text,
            value_jsonb     = EXCLUDED.value_jsonb,
            unit            = EXCLUDED.unit,
            provenance      = EXCLUDED.provenance,
            confidence      = EXCLUDED.confidence,
            valid_from      = EXCLUDED.valid_from,
            valid_to        = EXCLUDED.valid_to,
            metadata_jsonb  = EXCLUDED.metadata_jsonb,
            ref_source      = EXCLUDED.ref_source,
            ref_entity      = EXCLUDED.ref_entity,
            ref_key         = EXCLUDED.ref_key;
    END IF;

    -- embed the per-edge span into the graph-aligned compartment.
    IF p_embedding IS NOT NULL THEN
        v_dim   := maludb_core.vector_dims(p_embedding);
        v_model := COALESCE(NULLIF(btrim(COALESCE(p_embedding_model, '')), ''), 'unspecified');
        v_span  := COALESCE(NULLIF(btrim(COALESCE(p_source_span, '')), ''), '');

        v_compartment_id := maludb_core._vector_compartment_for_svpor(
            p_owner_schema, v_subject_id, v_verb_id, v_dim, v_model,
            p_namespace, p_distance_metric);

        v_chunk_id := maludb_core.register_vector_chunk(
            v_compartment_id, v_span, p_embedding, v_model);

        UPDATE maludb_core.malu$vector_chunk
           SET statement_id = v_statement_id,
               document_id  = p_document_id
         WHERE chunk_id = v_chunk_id;
    END IF;

    RETURN v_statement_id;
END;
$body$;
REVOKE ALL ON FUNCTION maludb_core._memory_ingest_edge_for_schema(name, text, bigint, text, text, jsonb, maludb_core.malu_vector, text, text, text, numeric, text, text, text, bigint, timestamptz, timestamptz, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core._memory_ingest_edge_for_schema(name, text, bigint, text, text, jsonb, maludb_core.malu_vector, text, text, text, numeric, text, text, text, bigint, timestamptz, timestamptz, text)
    TO maludb_memory_admin, maludb_memory_executor;

-- =====================================================================
-- 4. _memory_search_for_schema -- pre-filtered compartment ANN that also
--    returns statement_id / document_id (one relational hop to the edge;
--    no graph traversal on the first pass). Mirrors vector_search_by_tags'
--    compartment selection but scoped by an explicit owner_schema and joined
--    to the chunk's new graph links.
-- =====================================================================
CREATE FUNCTION maludb_core._memory_search_for_schema(
    p_owner_schema    name,
    p_namespace       text        DEFAULT 'default',
    p_subject         text        DEFAULT NULL,
    p_verb            text        DEFAULT NULL,
    p_query_embedding maludb_core.malu_vector DEFAULT NULL,
    p_limit           integer     DEFAULT 20,
    p_metric          text        DEFAULT NULL
) RETURNS TABLE (
    chunk_id      bigint,
    statement_id  bigint,
    document_id   bigint,
    source_text   text,
    distance      double precision,
    similarity    double precision,
    rank_no       integer,
    subject_name  text,
    verb_name     text
) LANGUAGE plpgsql STABLE
SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
#variable_conflict use_column
DECLARE
    v_namespace text    := COALESCE(p_namespace, 'default');
    v_limit     integer := GREATEST(COALESCE(p_limit, 20), 0);
BEGIN
    PERFORM maludb_core._memory_schema_assert_manageable(p_owner_schema);

    IF p_query_embedding IS NULL THEN
        RAISE EXCEPTION 'memory_search: query embedding is required'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;
    IF p_subject IS NULL AND p_verb IS NULL THEN
        RAISE EXCEPTION 'memory_search: subject or verb is required'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;
    IF v_limit = 0 THEN
        RETURN;
    END IF;

    RETURN QUERY
    WITH matching_compartments AS (
        SELECT c.compartment_id,
               s.subject_name,
               v.verb_name
          FROM maludb_core.malu$vector_compartment c
          JOIN maludb_core.malu$vector_subject s
            ON s.owner_schema = c.owner_schema
           AND s.namespace = c.namespace
           AND s.subject_id = c.subject_id
          JOIN maludb_core.malu$vector_verb v
            ON v.owner_schema = c.owner_schema
           AND v.namespace = c.namespace
           AND v.verb_id = c.verb_id
         WHERE c.owner_schema = p_owner_schema
           AND c.namespace = v_namespace
           AND (p_subject IS NULL OR s.subject_name = p_subject)
           AND (p_verb IS NULL OR v.verb_name = p_verb)
    ),
    compartment_hits AS (
        SELECT h.chunk_id      AS hit_chunk_id,
               h.source_text   AS hit_source_text,
               h.distance      AS hit_distance,
               h.similarity    AS hit_similarity,
               mc.compartment_id AS hit_compartment_id,
               mc.subject_name AS hit_subject_name,
               mc.verb_name    AS hit_verb_name
          FROM matching_compartments mc
          CROSS JOIN LATERAL maludb_core.exact_vector_search_sql(
              mc.compartment_id,
              p_query_embedding,
              v_limit,
              p_metric
          ) AS h
    ),
    ranked_hits AS (
        SELECT ch.hit_chunk_id,
               ch.hit_source_text,
               ch.hit_distance,
               ch.hit_similarity,
               ROW_NUMBER() OVER (
                   ORDER BY ch.hit_distance ASC,
                            ch.hit_compartment_id ASC,
                            ch.hit_chunk_id ASC
               )::integer AS hit_rank_no,
               ch.hit_subject_name,
               ch.hit_verb_name
          FROM compartment_hits ch
    )
    SELECT r.hit_chunk_id,
           vc.statement_id,
           vc.document_id,
           r.hit_source_text,
           r.hit_distance,
           r.hit_similarity,
           r.hit_rank_no,
           r.hit_subject_name,
           r.hit_verb_name
      FROM ranked_hits r
      JOIN maludb_core.malu$vector_chunk vc ON vc.chunk_id = r.hit_chunk_id
     WHERE r.hit_rank_no <= v_limit
     ORDER BY r.hit_rank_no;
END;
$body$;
REVOKE ALL ON FUNCTION maludb_core._memory_search_for_schema(name, text, text, text, maludb_core.malu_vector, integer, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core._memory_search_for_schema(name, text, text, text, maludb_core.malu_vector, integer, text)
    TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;

-- =====================================================================
-- 5. 0.88.0 schema-local facade builder -- maludb_memory_ingest_edge /
--    maludb_memory_search. Re-enable-safe (CREATE OR REPLACE on new names).
-- =====================================================================
CREATE FUNCTION maludb_core._enable_memory_schema_0880_facade(p_schema name) RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
DECLARE
    v_count integer := 0;
BEGIN
    PERFORM maludb_core._memory_schema_assert_manageable(p_schema);

    -- maludb_memory_ingest_edge(...): the per-tenant ingestion contract.
    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_memory_ingest_edge', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_memory_ingest_edge(
            p_source_kind      text,
            p_source_id        bigint,
            p_subject_text     text,
            p_verb_text        text,
            p_predicate        jsonb       DEFAULT '[]'::jsonb,
            p_embedding        maludb_core.malu_vector DEFAULT NULL,
            p_embedding_model  text        DEFAULT NULL,
            p_subject_type     text        DEFAULT 'other',
            p_source_span      text        DEFAULT NULL,
            p_confidence       numeric     DEFAULT NULL,
            p_provenance       text        DEFAULT 'suggested',
            p_extraction_model text        DEFAULT NULL,
            p_namespace        text        DEFAULT 'default',
            p_document_id      bigint      DEFAULT NULL,
            p_valid_from       timestamptz DEFAULT NULL,
            p_valid_to         timestamptz DEFAULT NULL,
            p_distance_metric  text        DEFAULT 'cosine'
        ) RETURNS bigint
        LANGUAGE sql
        SECURITY DEFINER
        SET search_path = pg_catalog, maludb_core, pg_temp
        AS $facade$
            SELECT maludb_core._memory_ingest_edge_for_schema(
                %L::name,
                p_source_kind, p_source_id, p_subject_text, p_verb_text,
                p_predicate, p_embedding, p_embedding_model, p_subject_type,
                p_source_span, p_confidence, p_provenance, p_extraction_model,
                p_namespace, p_document_id, p_valid_from, p_valid_to, p_distance_metric)
        $facade$
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_memory_ingest_edge(text, bigint, text, text, jsonb, maludb_core.malu_vector, text, text, text, numeric, text, text, text, bigint, timestamptz, timestamptz, text) FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_memory_ingest_edge(text, bigint, text, text, jsonb, maludb_core.malu_vector, text, text, text, numeric, text, text, text, bigint, timestamptz, timestamptz, text) TO maludb_memory_admin, maludb_memory_executor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_memory_ingest_edge', 'function', 'Ingestion contract: extracted edge -> statement + edge attributes + compartment embedding.');
    v_count := v_count + 1;

    -- maludb_memory_search(...): pre-filtered compartment search -> statement_id.
    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_memory_search', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_memory_search(
            p_query_embedding maludb_core.malu_vector DEFAULT NULL,
            p_subject         text    DEFAULT NULL,
            p_verb            text    DEFAULT NULL,
            p_namespace       text    DEFAULT 'default',
            p_limit           integer DEFAULT 20,
            p_metric          text    DEFAULT NULL
        ) RETURNS TABLE (
            chunk_id      bigint,
            statement_id  bigint,
            document_id   bigint,
            source_text   text,
            distance      double precision,
            similarity    double precision,
            rank_no       integer,
            subject_name  text,
            verb_name     text
        )
        LANGUAGE sql
        STABLE
        SECURITY DEFINER
        SET search_path = pg_catalog, maludb_core, pg_temp
        AS $facade$
            SELECT *
            FROM maludb_core._memory_search_for_schema(
                %L::name, p_namespace, p_subject, p_verb,
                p_query_embedding, p_limit, p_metric)
        $facade$
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_memory_search(maludb_core.malu_vector, text, text, text, integer, text) FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_memory_search(maludb_core.malu_vector, text, text, text, integer, text) TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_memory_search', 'function', 'Subject/verb pre-filtered compartment search returning statement_id.');
    v_count := v_count + 1;

    RETURN v_count;
END;
$body$;

REVOKE ALL ON FUNCTION maludb_core._enable_memory_schema_0880_facade(name) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core._enable_memory_schema_0880_facade(name)
    TO maludb_memory_admin, maludb_memory_executor;

-- =====================================================================
-- 6. Wire the 0880 facade into enable_memory_schema.
-- =====================================================================
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
