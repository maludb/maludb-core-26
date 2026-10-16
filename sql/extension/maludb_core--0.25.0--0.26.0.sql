\echo Use "ALTER EXTENSION maludb_core UPDATE TO '0.26.0'" to load this file. \quit

-- =====================================================================
-- maludb_core 0.25.0 → 0.26.0
--
-- Stage 3 — MAUT confidence + precision (S3-4).
--
-- Per requirements.md §3.3: Multi-Attribute Utility Theory (MAUT)
-- based confidence and precision. Memory confidence categories:
--   supporting_facts, claim_consistency, source_diversity,
--   inference, temporal_coherence, contradiction_status,
--   staleness_status
--
-- And §9 Stage 3: "MAUT-based confidence and precision: per-category
-- subscore tables, weights, evaluator metadata, aggregate computation
-- functions."
--
-- Schema:
--   * malu$maut_weight — per-tenant weight policy
--                        keyed by (target_object_type, category).
--   * malu$maut_score  — per-object subscore rows with evaluator
--                        metadata + evidence.
--
-- Functions:
--   * apply_default_weights(target_object_type) — seed neutral
--     weights for a tenant; idempotent.
--   * set_maut_score(...) — upsert by
--     (target_object_type, target_object_id, category).
--   * maut_aggregate_confidence(type, id) → numeric in [0, 1].
--     Weighted sum of available subscores normalised by the sum of
--     weights for categories that have scores. Categories with no
--     subscore are skipped (don't drag the aggregate down toward 0).
--
-- Defaults are policy-configurable per the §10 deferred decisions:
--   "Exact MAUT default weights per object type (must be policy-
--    configurable from day one, but the defaults need tuning data)."
-- =====================================================================

CREATE OR REPLACE FUNCTION maludb_core_version() RETURNS text
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$ SELECT '0.26.0'::text $body$;

-- =====================================================================
-- malu$maut_weight
-- =====================================================================
CREATE TABLE malu$maut_weight (
    weight_id           bigserial PRIMARY KEY,
    owner_schema        name NOT NULL DEFAULT current_schema(),
    target_object_type  text NOT NULL,
    category            text NOT NULL,
    weight              numeric(5,4) NOT NULL
        CHECK (weight >= 0 AND weight <= 1),
    enabled             boolean NOT NULL DEFAULT true,
    description         text,
    created_at          timestamptz NOT NULL DEFAULT now(),
    updated_at          timestamptz NOT NULL DEFAULT now(),
    CHECK (target_object_type IN ('claim','fact','memory','episode_object')),
    CHECK (category IN (
        'supporting_facts','claim_consistency','source_diversity',
        'inference','temporal_coherence','contradiction_status',
        'staleness_status')),
    UNIQUE (owner_schema, target_object_type, category)
);

ALTER TABLE malu$maut_weight ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_owner ON malu$maut_weight
    USING (owner_schema = current_schema())
    WITH CHECK (owner_schema = current_schema());

GRANT SELECT ON malu$maut_weight TO
    maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;
GRANT INSERT, UPDATE, DELETE ON malu$maut_weight TO
    maludb_memory_admin, maludb_memory_executor;
GRANT USAGE, SELECT ON SEQUENCE malu$maut_weight_weight_id_seq TO
    maludb_memory_admin, maludb_memory_executor;

-- =====================================================================
-- malu$maut_score
--
-- One row per (object, category) per tenant. Re-evaluation upserts.
-- evidence jsonb is free-form (e.g., {"supporting_count": 5,
-- "source_oids": [...]}); evaluator_meta tracks the actor identity
-- separately so the evidence column stays evaluator-agnostic.
-- =====================================================================
CREATE TABLE malu$maut_score (
    score_id            bigserial PRIMARY KEY,
    owner_schema        name NOT NULL DEFAULT current_schema(),
    target_object_type  text NOT NULL,
    target_object_id    bigint NOT NULL,
    category            text NOT NULL,
    subscore            numeric(5,4) NOT NULL
        CHECK (subscore >= 0 AND subscore <= 1),
    evaluator_name      text NOT NULL,
    evaluator_kind      text NOT NULL DEFAULT 'manual'
        CHECK (evaluator_kind IN ('manual','automated','model','external')),
    evaluator_meta      jsonb,
    evidence            jsonb,
    evaluated_at        timestamptz NOT NULL DEFAULT now(),
    CHECK (target_object_type IN ('claim','fact','memory','episode_object')),
    CHECK (category IN (
        'supporting_facts','claim_consistency','source_diversity',
        'inference','temporal_coherence','contradiction_status',
        'staleness_status')),
    UNIQUE (owner_schema, target_object_type, target_object_id, category)
);
CREATE INDEX malu$maut_score_object_idx
    ON malu$maut_score (target_object_type, target_object_id);

ALTER TABLE malu$maut_score ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_owner ON malu$maut_score
    USING (owner_schema = current_schema())
    WITH CHECK (owner_schema = current_schema());

GRANT SELECT ON malu$maut_score TO
    maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;
GRANT INSERT, UPDATE, DELETE ON malu$maut_score TO
    maludb_memory_admin, maludb_memory_executor;
GRANT USAGE, SELECT ON SEQUENCE malu$maut_score_score_id_seq TO
    maludb_memory_admin, maludb_memory_executor;

-- =====================================================================
-- apply_default_weights — seed neutral weights for a tenant + object
-- type. Returns count of rows inserted (0 if all already present).
-- Defaults are intentionally not equal across categories: stronger
-- evidential categories (supporting_facts, source_diversity,
-- claim_consistency) carry more weight than inference / temporal
-- coherence to match the spec's emphasis on "verification rules"
-- over speculative scoring.
-- =====================================================================
CREATE FUNCTION apply_default_weights(p_target_object_type text)
RETURNS integer
LANGUAGE plpgsql
AS $body$
DECLARE
    v_count integer := 0;
    pair    record;
BEGIN
    FOR pair IN
        SELECT category, weight FROM (
            VALUES
                ('supporting_facts',     0.20::numeric),
                ('claim_consistency',    0.15::numeric),
                ('source_diversity',     0.15::numeric),
                ('inference',            0.10::numeric),
                ('temporal_coherence',   0.15::numeric),
                ('contradiction_status', 0.15::numeric),
                ('staleness_status',     0.10::numeric)
        ) AS v(category, weight)
    LOOP
        INSERT INTO malu$maut_weight
            (target_object_type, category, weight, description)
        VALUES (p_target_object_type, pair.category, pair.weight,
                'default neutral weight')
        ON CONFLICT (owner_schema, target_object_type, category) DO NOTHING;
        IF FOUND THEN v_count := v_count + 1; END IF;
    END LOOP;
    RETURN v_count;
END;
$body$;

-- =====================================================================
-- set_maut_score — upsert by (type, id, category). Updates score +
-- evaluator metadata + evidence atomically; evaluated_at refreshes.
-- =====================================================================
CREATE FUNCTION set_maut_score(
    p_target_object_type text,
    p_target_object_id   bigint,
    p_category           text,
    p_subscore           numeric,
    p_evaluator_name     text,
    p_evaluator_kind     text  DEFAULT 'manual',
    p_evaluator_meta     jsonb DEFAULT NULL,
    p_evidence           jsonb DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql
AS $body$
DECLARE v_id bigint;
BEGIN
    INSERT INTO malu$maut_score
        (target_object_type, target_object_id, category,
         subscore, evaluator_name, evaluator_kind,
         evaluator_meta, evidence)
    VALUES (p_target_object_type, p_target_object_id, p_category,
            p_subscore, p_evaluator_name, p_evaluator_kind,
            p_evaluator_meta, p_evidence)
    ON CONFLICT (owner_schema, target_object_type, target_object_id, category)
        DO UPDATE SET
            subscore        = EXCLUDED.subscore,
            evaluator_name  = EXCLUDED.evaluator_name,
            evaluator_kind  = EXCLUDED.evaluator_kind,
            evaluator_meta  = EXCLUDED.evaluator_meta,
            evidence        = EXCLUDED.evidence,
            evaluated_at    = now()
    RETURNING score_id INTO v_id;
    RETURN v_id;
END;
$body$;

-- =====================================================================
-- maut_aggregate_confidence — weighted sum of subscores normalised
-- by the total weight of categories that have a score. Categories
-- with no subscore are excluded (don't artificially deflate). Result
-- ∈ [0, 1], NULL when no subscores exist.
-- =====================================================================
CREATE FUNCTION maut_aggregate_confidence(
    p_target_object_type text,
    p_target_object_id   bigint
) RETURNS numeric
LANGUAGE sql STABLE
AS $body$
    SELECT CASE
        WHEN SUM(w.weight) IS NULL OR SUM(w.weight) = 0 THEN NULL
        ELSE LEAST(1.0::numeric,
                   ROUND(SUM(s.subscore * w.weight) / SUM(w.weight), 4))
    END
    FROM malu$maut_score s
    JOIN malu$maut_weight w
      ON w.target_object_type = s.target_object_type
     AND w.category           = s.category
     AND w.enabled            = true
    WHERE s.target_object_type = p_target_object_type
      AND s.target_object_id   = p_target_object_id;
$body$;

-- =====================================================================
-- maut_score_detail — per-category breakdown alongside weight,
-- so reviewers see what produced the aggregate.
-- =====================================================================
CREATE FUNCTION maut_score_detail(
    p_target_object_type text,
    p_target_object_id   bigint
) RETURNS TABLE (
    category            text,
    subscore            numeric,
    weight              numeric,
    weighted_contribution numeric,
    evaluator_name      text,
    evaluator_kind      text,
    evaluated_at        timestamptz
) LANGUAGE sql STABLE
AS $body$
    SELECT s.category,
           s.subscore,
           w.weight,
           ROUND(s.subscore * w.weight, 4) AS weighted_contribution,
           s.evaluator_name,
           s.evaluator_kind,
           s.evaluated_at
    FROM malu$maut_score s
    JOIN malu$maut_weight w
      ON w.target_object_type = s.target_object_type
     AND w.category           = s.category
     AND w.enabled            = true
    WHERE s.target_object_type = p_target_object_type
      AND s.target_object_id   = p_target_object_id
    ORDER BY w.weight DESC, s.category;
$body$;

-- =====================================================================
-- malu$maut_summary view — one row per (object, type) with the
-- aggregate confidence and the set of categories that have scores.
-- Useful for retrieval planners and confidence-gated lookups.
-- =====================================================================
CREATE VIEW malu$maut_summary AS
SELECT
    s.target_object_type,
    s.target_object_id,
    s.owner_schema,
    count(*)::integer                                  AS categories_scored,
    array_agg(s.category ORDER BY s.category)          AS scored_categories,
    maut_aggregate_confidence(s.target_object_type, s.target_object_id) AS aggregate_confidence,
    min(s.evaluated_at) AS earliest_eval,
    max(s.evaluated_at) AS latest_eval
FROM malu$maut_score s
GROUP BY s.target_object_type, s.target_object_id, s.owner_schema;

GRANT SELECT ON malu$maut_summary TO
    maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;

GRANT EXECUTE ON FUNCTION
    apply_default_weights(text),
    set_maut_score(text, bigint, text, numeric, text, text, jsonb, jsonb),
    maut_aggregate_confidence(text, bigint),
    maut_score_detail(text, bigint)
TO maludb_memory_admin, maludb_memory_executor;

-- =====================================================================
-- Stage_boundary update — malu$maut_score no longer reserved.
-- Stage 3 reservations are now exhausted; the forbidden list shifts
-- to Stage 5+/Stage 6+ placeholders.
-- =====================================================================
CREATE OR REPLACE FUNCTION stage_boundary_violations()
RETURNS TABLE(object_kind text, object_name text, stage smallint)
LANGUAGE sql STABLE
AS $body$
    WITH forbidden(name, stage) AS (
        VALUES
            ('malu$governed_object'::text,       2::smallint),
            ('malu$workflow_trace',              5),
            ('malu$generalized_workflow',        5),
            ('malu$procedural_memory_object',    5),
            ('malu$skill_package',               5),
            ('malu$competency_package',          5),
            ('malu$active_memory_pool',          5),
            ('malu$episode_replay',              5),
            ('malu$local_memory_node',           6),
            ('malu$node_sync_record',            6)
    )
    SELECT 'table'::text, c.relname::text, f.stage
    FROM pg_catalog.pg_class c
    JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
    JOIN forbidden f ON f.name = c.relname
    WHERE n.nspname = 'maludb_core'
      AND c.relkind IN ('r','p','v','m')
    ORDER BY f.stage, c.relname;
$body$;
