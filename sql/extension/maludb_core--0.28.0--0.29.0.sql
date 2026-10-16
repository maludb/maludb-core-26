\echo Use "ALTER EXTENSION maludb_core UPDATE TO '0.29.0'" to load this file. \quit

-- =====================================================================
-- maludb_core 0.28.0 → 0.29.0
--
-- Stage 4 — Native FTS + pg_trgm (S4-2).
--
-- Per requirements.md §9 Stage 4: "Native FTS (tsvector) + pg_trgm".
--
-- Adds generated tsvector columns + GIN indexes on the four textual
-- tables (claim, fact, memory, episode_object), pg_trgm fuzzy-match
-- indexes on the same fields, and a uniform text_search wrapper
-- that returns hits across object types ordered by ts_rank.
--
-- Search dictionary: 'english'. Operators can swap to a different
-- text-search configuration by recreating the generated columns;
-- the helpers reference 'english' explicitly so behaviour stays
-- deterministic across cluster locales.
-- =====================================================================

CREATE OR REPLACE FUNCTION maludb_core_version() RETURNS text
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$ SELECT '0.29.0'::text $body$;

-- pg_trgm is declared in the control-file 'requires' clause so PG
-- pulls it in automatically before this upgrade runs. CREATE
-- EXTENSION inside an extension script is "nested" creation and
-- fails when the dep isn't already present.

-- =====================================================================
-- Generated tsvector columns + GIN indexes
--
-- Each table's tsvector blends:
--   * SVPOR frame (subject, verb, predicate, object_value) — weighted A
--   * statement / title — weighted A
--   * summary / payload_jsonb string values — weighted B
--
-- setweight() lets ts_rank prefer matches in the SVPOR frame over
-- matches in the long-form payload.
-- =====================================================================

ALTER TABLE malu$claim
    ADD COLUMN fts_tsv tsvector GENERATED ALWAYS AS (
        setweight(to_tsvector('english',
            COALESCE(subject, '') || ' ' ||
            COALESCE(verb, '')    || ' ' ||
            COALESCE(predicate, '') || ' ' ||
            COALESCE(object_value, '') || ' ' ||
            COALESCE(statement_text, '')), 'A')
    ) STORED;
CREATE INDEX malu$claim_fts_gin ON malu$claim USING gin (fts_tsv);
CREATE INDEX malu$claim_subject_trgm
    ON malu$claim USING gin (subject gin_trgm_ops) WHERE subject IS NOT NULL;
CREATE INDEX malu$claim_statement_trgm
    ON malu$claim USING gin (statement_text gin_trgm_ops)
    WHERE statement_text IS NOT NULL;

ALTER TABLE malu$fact
    ADD COLUMN fts_tsv tsvector GENERATED ALWAYS AS (
        setweight(to_tsvector('english',
            COALESCE(subject, '') || ' ' ||
            COALESCE(verb, '')    || ' ' ||
            COALESCE(predicate, '') || ' ' ||
            COALESCE(object_value, '') || ' ' ||
            COALESCE(statement_text, '')), 'A')
    ) STORED;
CREATE INDEX malu$fact_fts_gin ON malu$fact USING gin (fts_tsv);
CREATE INDEX malu$fact_subject_trgm
    ON malu$fact USING gin (subject gin_trgm_ops) WHERE subject IS NOT NULL;
CREATE INDEX malu$fact_statement_trgm
    ON malu$fact USING gin (statement_text gin_trgm_ops)
    WHERE statement_text IS NOT NULL;

ALTER TABLE malu$memory
    ADD COLUMN fts_tsv tsvector GENERATED ALWAYS AS (
        setweight(to_tsvector('english',
            COALESCE(title, '') || ' ' || COALESCE(memory_kind, '')), 'A')
        ||
        setweight(to_tsvector('english', COALESCE(summary, '')), 'B')
        ||
        setweight(jsonb_to_tsvector('english',
            COALESCE(payload_jsonb, '{}'::jsonb), '["string"]'), 'B')
    ) STORED;
CREATE INDEX malu$memory_fts_gin ON malu$memory USING gin (fts_tsv);
CREATE INDEX malu$memory_title_trgm
    ON malu$memory USING gin (title gin_trgm_ops) WHERE title IS NOT NULL;

ALTER TABLE malu$episode_object
    ADD COLUMN fts_tsv tsvector GENERATED ALWAYS AS (
        setweight(to_tsvector('english',
            COALESCE(title, '') || ' ' || COALESCE(episode_kind, '')), 'A')
        ||
        setweight(to_tsvector('english', COALESCE(summary, '')), 'B')
        ||
        setweight(jsonb_to_tsvector('english',
            COALESCE(payload_jsonb, '{}'::jsonb), '["string"]'), 'B')
    ) STORED;
CREATE INDEX malu$episode_fts_gin ON malu$episode_object USING gin (fts_tsv);
CREATE INDEX malu$episode_title_trgm
    ON malu$episode_object USING gin (title gin_trgm_ops) WHERE title IS NOT NULL;

-- =====================================================================
-- text_search — uniform cross-object FTS. Returns ranked hits ordered
-- by ts_rank DESC. p_object_types filters which tables to scan.
-- =====================================================================
CREATE FUNCTION text_search(
    p_query         text,
    p_object_types  text[] DEFAULT ARRAY['claim','fact','memory','episode_object'],
    p_limit         integer DEFAULT 20
) RETURNS TABLE (
    object_type        text,
    object_id          bigint,
    title_or_subject   text,
    snippet            text,
    rank               real
) LANGUAGE plpgsql STABLE
AS $body$
DECLARE
    v_tsq tsquery := websearch_to_tsquery('english', p_query);
BEGIN
    RETURN QUERY
        SELECT * FROM (
            SELECT 'claim'::text,
                   c.claim_id,
                   COALESCE(c.subject, c.verb, '?')::text,
                   left(COALESCE(c.statement_text, ''), 240)::text,
                   ts_rank(c.fts_tsv, v_tsq)
            FROM malu$claim c
            WHERE 'claim' = ANY(p_object_types)
              AND c.fts_tsv @@ v_tsq
            UNION ALL
            SELECT 'fact'::text,
                   f.fact_id,
                   COALESCE(f.subject, f.verb, '?')::text,
                   left(COALESCE(f.statement_text, ''), 240)::text,
                   ts_rank(f.fts_tsv, v_tsq)
            FROM malu$fact f
            WHERE 'fact' = ANY(p_object_types)
              AND f.fts_tsv @@ v_tsq
            UNION ALL
            SELECT 'memory'::text,
                   m.memory_id,
                   COALESCE(m.title, m.memory_kind, '?')::text,
                   left(COALESCE(m.summary, ''), 240)::text,
                   ts_rank(m.fts_tsv, v_tsq)
            FROM malu$memory m
            WHERE 'memory' = ANY(p_object_types)
              AND m.fts_tsv @@ v_tsq
            UNION ALL
            SELECT 'episode_object'::text,
                   e.episode_id,
                   COALESCE(e.title, e.episode_kind, '?')::text,
                   left(COALESCE(e.summary, ''), 240)::text,
                   ts_rank(e.fts_tsv, v_tsq)
            FROM malu$episode_object e
            WHERE 'episode_object' = ANY(p_object_types)
              AND e.fts_tsv @@ v_tsq
        ) hits(object_type, object_id, title_or_subject, snippet, rank)
        ORDER BY rank DESC NULLS LAST, object_id
        LIMIT p_limit;
END;
$body$;

-- =====================================================================
-- fuzzy_subject_match — pg_trgm similarity over the subject column on
-- claim + fact. Useful for "find all claims about a-similar-thing" UX
-- when the caller doesn't know the exact spelling.
-- =====================================================================
CREATE FUNCTION fuzzy_subject_match(
    p_needle    text,
    p_threshold real    DEFAULT 0.3,
    p_object_types text[] DEFAULT ARRAY['claim','fact'],
    p_limit     integer DEFAULT 50
) RETURNS TABLE (
    object_type   text,
    object_id     bigint,
    subject       text,
    similarity    real
) LANGUAGE plpgsql STABLE
AS $body$
BEGIN
    RETURN QUERY
        SELECT * FROM (
            SELECT 'claim'::text, c.claim_id, c.subject,
                   similarity(c.subject, p_needle)
            FROM malu$claim c
            WHERE 'claim' = ANY(p_object_types)
              AND c.subject IS NOT NULL
              AND c.subject % p_needle
              AND similarity(c.subject, p_needle) >= p_threshold
            UNION ALL
            SELECT 'fact'::text, f.fact_id, f.subject,
                   similarity(f.subject, p_needle)
            FROM malu$fact f
            WHERE 'fact' = ANY(p_object_types)
              AND f.subject IS NOT NULL
              AND f.subject % p_needle
              AND similarity(f.subject, p_needle) >= p_threshold
        ) hits(object_type, object_id, subject, similarity)
        ORDER BY similarity DESC, hits.subject
        LIMIT p_limit;
END;
$body$;

GRANT EXECUTE ON FUNCTION
    text_search(text, text[], integer),
    fuzzy_subject_match(text, real, text[], integer)
TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;
