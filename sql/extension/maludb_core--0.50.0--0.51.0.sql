\echo Use "ALTER EXTENSION maludb_core UPDATE TO '0.51.0'" to load this file. \quit

-- =====================================================================
-- maludb_core 0.50.0 → 0.51.0
--
-- Stage 14 / V3-VEC-01 (catalog): vector index status + metadata filter.
--
-- Adds two surfaces to the existing Stage 1.7 vector substrate:
--
--   1. `metadata jsonb` column on malu$vector_chunk + a
--      `search_memory_filter(...)` helper that combines the auth-aware
--      compartment search with a jsonb-contains filter (`@>`). The
--      filter is applied AFTER the existing three-stage authorization
--      gate inside the retrieval coordinator, never as a substitute.
--
--   2. `malu$vector_index_status` — one row per compartment with an
--      index built (or scheduled). Records kind in {exact, nsw,
--      hnsw_local, hnsw_pgvector}, build_started_at, build_finished_at,
--      delta_count, tombstone_count, last_rebuild_at, recall_sample.
--      `vector_index_status()` returns the matrix for the CLI and
--      Stage 15's V3-OBS-01 metrics scrape.
--
-- The HNSW upgrade decision (multilevel-NSW vs pgvector HNSW) is
-- deferred to a Stage 14 follow-up; the catalog supports either path
-- once the implementation lands.
--
-- Apply with:
--   ALTER EXTENSION maludb_core UPDATE TO '0.51.0';
-- =====================================================================

CREATE OR REPLACE FUNCTION maludb_core_version() RETURNS text
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$ SELECT '0.51.0'::text $body$;

-- ---------------------------------------------------------------------
-- malu$vector_chunk.metadata — jsonb attached to every chunk so the
-- post-authorization metadata_filter can `@>` against it.
-- ---------------------------------------------------------------------
ALTER TABLE malu$vector_chunk
    ADD COLUMN metadata jsonb NOT NULL DEFAULT '{}'::jsonb;

CREATE INDEX malu$vector_chunk_metadata_gin
    ON malu$vector_chunk USING gin (metadata jsonb_path_ops);

-- ---------------------------------------------------------------------
-- malu$vector_index_status — per-compartment index health.
-- ---------------------------------------------------------------------
CREATE TABLE malu$vector_index_status (
    status_id            bigserial PRIMARY KEY,
    compartment_id       bigint    NOT NULL UNIQUE REFERENCES malu$vector_compartment(compartment_id) ON DELETE CASCADE,
    kind                 text      NOT NULL CHECK (kind IN
                            ('exact','nsw','hnsw_local','hnsw_pgvector')),
    build_started_at     timestamptz,
    build_finished_at    timestamptz,
    last_rebuild_at      timestamptz,
    delta_count          bigint    NOT NULL DEFAULT 0,
    tombstone_count      bigint    NOT NULL DEFAULT 0,
    recall_sample        jsonb,
    owner_schema         name      NOT NULL DEFAULT current_schema(),
    created_at           timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX malu$vector_index_status_kind_idx
    ON malu$vector_index_status(owner_schema, kind);

ALTER TABLE malu$vector_index_status ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_owner ON malu$vector_index_status
    USING      (owner_schema = current_schema())
    WITH CHECK (owner_schema = current_schema());

GRANT SELECT, INSERT, UPDATE, DELETE ON malu$vector_index_status TO maludb_memory_admin;
GRANT SELECT, INSERT, UPDATE         ON malu$vector_index_status TO maludb_memory_executor;
GRANT SELECT                          ON malu$vector_index_status TO maludb_memory_auditor;

GRANT USAGE, SELECT ON SEQUENCE malu$vector_index_status_status_id_seq TO
    maludb_memory_admin, maludb_memory_executor;

-- =====================================================================
-- vector_index_record — record/refresh a per-compartment status row.
-- Called by ann_build / ann_rebuild and by future HNSW-builders.
-- =====================================================================
CREATE FUNCTION vector_index_record(
    p_compartment_id      bigint,
    p_kind                text,
    p_build_finished      boolean DEFAULT true,
    p_delta_count         bigint  DEFAULT 0,
    p_tombstone_count     bigint  DEFAULT 0,
    p_recall_sample       jsonb   DEFAULT NULL
) RETURNS bigint
    LANGUAGE plpgsql VOLATILE
    AS $body$
#variable_conflict use_column
DECLARE v_id bigint;
BEGIN
    IF p_kind NOT IN ('exact','nsw','hnsw_local','hnsw_pgvector') THEN
        RAISE EXCEPTION 'vector_index_record: kind must be exact/nsw/hnsw_local/hnsw_pgvector'
            USING ERRCODE = 'check_violation';
    END IF;

    INSERT INTO malu$vector_index_status
        (compartment_id, kind, build_started_at, build_finished_at,
         last_rebuild_at, delta_count, tombstone_count, recall_sample)
    VALUES
        (p_compartment_id, p_kind, now(),
         CASE WHEN p_build_finished THEN now() ELSE NULL END,
         CASE WHEN p_build_finished THEN now() ELSE NULL END,
         p_delta_count, p_tombstone_count, p_recall_sample)
    ON CONFLICT (compartment_id) DO UPDATE
        SET kind              = EXCLUDED.kind,
            build_started_at  = COALESCE(EXCLUDED.build_started_at, malu$vector_index_status.build_started_at),
            build_finished_at = CASE WHEN p_build_finished THEN now()
                                     ELSE malu$vector_index_status.build_finished_at END,
            last_rebuild_at   = CASE WHEN p_build_finished THEN now()
                                     ELSE malu$vector_index_status.last_rebuild_at END,
            delta_count       = EXCLUDED.delta_count,
            tombstone_count   = EXCLUDED.tombstone_count,
            recall_sample     = COALESCE(EXCLUDED.recall_sample, malu$vector_index_status.recall_sample)
    RETURNING status_id INTO v_id;

    PERFORM audit_event('vector_index_record', 'malu$vector_index_status', v_id,
        jsonb_build_object('compartment_id', p_compartment_id, 'kind', p_kind,
                           'delta_count', p_delta_count,
                           'tombstone_count', p_tombstone_count,
                           'build_finished', p_build_finished),
        NULL);
    PERFORM emit_event('vector_index_record',
        jsonb_build_object('compartment_id', p_compartment_id, 'kind', p_kind),
        NULL, NULL, NULL, 'malu$vector_index_status', v_id, NULL);
    RETURN v_id;
END;
$body$;
REVOKE EXECUTE ON FUNCTION vector_index_record(bigint, text, boolean, bigint, bigint, jsonb) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION vector_index_record(bigint, text, boolean, bigint, bigint, jsonb) TO
    maludb_memory_admin, maludb_memory_executor;

CREATE FUNCTION vector_index_status()
    RETURNS TABLE (
        compartment_id   bigint,
        namespace        text,
        subject          text,
        verb             text,
        kind             text,
        vector_count     bigint,
        delta_count      bigint,
        tombstone_count  bigint,
        last_rebuild_at  timestamptz,
        rebuild_age_sec  bigint
    ) LANGUAGE plpgsql STABLE
    AS $body$
#variable_conflict use_column
BEGIN
    RETURN QUERY
    SELECT c.compartment_id,
           c.namespace,
           s.subject_name,
           v.verb_name,
           COALESCE(st.kind, c.search_mode),
           c.vector_count,
           COALESCE(st.delta_count, 0),
           COALESCE(st.tombstone_count, 0),
           st.last_rebuild_at,
           CASE WHEN st.last_rebuild_at IS NULL THEN NULL
                ELSE EXTRACT(EPOCH FROM (now() - st.last_rebuild_at))::bigint
           END
      FROM malu$vector_compartment c
      JOIN malu$vector_subject     s ON s.subject_id = c.subject_id
      JOIN malu$vector_verb        v ON v.verb_id    = c.verb_id
      LEFT JOIN malu$vector_index_status st ON st.compartment_id = c.compartment_id
     ORDER BY c.namespace, s.subject_name, v.verb_name;
END;
$body$;
REVOKE EXECUTE ON FUNCTION vector_index_status() FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION vector_index_status() TO
    maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;

-- =====================================================================
-- search_memory_filter — search_memory_exact + jsonb metadata filter.
-- The filter is `metadata @> p_metadata_filter` so callers can pass
-- partial documents (e.g. {"language":"en","domain":"ops"}).
-- =====================================================================
CREATE FUNCTION search_memory_filter(
    p_namespace        text,
    p_subject          text,
    p_verb             text,
    p_query            malu_vector,
    p_metadata_filter  jsonb,
    p_limit            integer DEFAULT 10,
    p_metric           text    DEFAULT NULL
) RETURNS TABLE (
    chunk_id     bigint,
    source_text  text,
    distance     double precision,
    similarity   double precision,
    rank_no      integer,
    metadata     jsonb
) LANGUAGE plpgsql STABLE
    AS $body$
#variable_conflict use_column
BEGIN
    -- Two-stage: pull up to 4x the requested limit from the existing
    -- auth-aware search, then re-rank/filter by metadata containment.
    -- The 4x overfetch is a heuristic; rebuild candidate pruning is a
    -- Stage 14 follow-up if the filter shape proves selective.
    RETURN QUERY
    WITH hits AS (
        SELECT h.chunk_id, h.source_text, h.distance, h.similarity, h.rank_no
          FROM search_memory_exact(p_namespace, p_subject, p_verb,
                                   p_query, p_limit * 4, p_metric) h
    )
    SELECT h.chunk_id, h.source_text, h.distance, h.similarity,
           ROW_NUMBER() OVER (ORDER BY h.distance ASC, h.chunk_id ASC)::integer,
           c.metadata
      FROM hits h
      JOIN malu$vector_chunk c ON c.chunk_id = h.chunk_id
     WHERE p_metadata_filter IS NULL
        OR c.metadata @> p_metadata_filter
     ORDER BY h.distance ASC, h.chunk_id ASC
     LIMIT p_limit;
END;
$body$;
REVOKE EXECUTE ON FUNCTION search_memory_filter(text, text, text, malu_vector, jsonb, integer, text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION search_memory_filter(text, text, text, malu_vector, jsonb, integer, text) TO
    maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;
