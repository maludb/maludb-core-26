-- Stage 3 S3-4 — MAUT confidence + precision.
--
-- Exercises:
--   * apply_default_weights seeds 7 categories + is idempotent
--   * set_maut_score upserts per (object, category)
--   * maut_aggregate_confidence weighted-sums available subscores
--     normalised by the sum of corresponding weights
--   * categories without scores are skipped (don't drag aggregate)
--   * disabling a weight removes it from the aggregate
--   * malu$maut_summary view + maut_score_detail breakdown
--   * CHECK constraints on subscore + weight bounds

\set ECHO all
SET search_path = maludb_core, public;
SET client_min_messages = NOTICE;

-- ---------- defaults --------------------------------------------------
SELECT apply_default_weights('fact')   AS fact_defaults_inserted;
SELECT apply_default_weights('claim')  AS claim_defaults_inserted;
SELECT apply_default_weights('fact')   AS fact_defaults_idempotent;

SELECT count(*) AS fact_weights, sum(weight)::numeric(6,4) AS total_weight
FROM malu$maut_weight WHERE target_object_type = 'fact';

-- ---------- target row to score --------------------------------------
SELECT register_fact(
    p_claim_ids => ARRAY[]::bigint[],
    p_subject   => 'service',
    p_verb      => 'has_status',
    p_object_value => 'healthy',
    p_statement_text => 'all-green on the dashboard'
) AS f_a \gset

-- aggregate is NULL when no subscores yet
SELECT maut_aggregate_confidence('fact', :f_a) AS pre_score;

-- ---------- set_maut_score (upsert) ----------------------------------
SELECT set_maut_score('fact', :f_a, 'supporting_facts', 0.90,
    p_evaluator_name => 'corroboration_v1',
    p_evaluator_kind => 'automated',
    p_evidence       => jsonb_build_object('supporting_count', 7)) > 0 AS sf_set;

SELECT set_maut_score('fact', :f_a, 'source_diversity', 0.60,
    p_evaluator_name => 'source_audit',
    p_evidence       => jsonb_build_object('distinct_sources', 3)) > 0 AS sd_set;

SELECT set_maut_score('fact', :f_a, 'claim_consistency', 0.95,
    p_evaluator_name => 'consistency_v2',
    p_evaluator_kind => 'model',
    p_evaluator_meta => jsonb_build_object('model','consistency-v2')) > 0 AS cc_set;

-- Re-evaluating the same category replaces the score
SELECT set_maut_score('fact', :f_a, 'supporting_facts', 0.85,
    p_evaluator_name => 'corroboration_v1',
    p_evaluator_kind => 'automated',
    p_evidence       => jsonb_build_object('supporting_count', 6)) > 0 AS sf_reset;

SELECT count(*) AS row_count, max(subscore) AS subscore_latest
FROM malu$maut_score
WHERE target_object_type = 'fact'
  AND target_object_id   = :f_a
  AND category           = 'supporting_facts';

-- ---------- aggregate weighted sum -----------------------------------
-- Expected:
--   supporting_facts:    0.85 × 0.20 = 0.17
--   source_diversity:    0.60 × 0.15 = 0.09
--   claim_consistency:   0.95 × 0.15 = 0.1425
--   sum_weighted = 0.4025
--   sum_weights  = 0.50
--   aggregate    = 0.4025 / 0.50 = 0.805
SELECT maut_aggregate_confidence('fact', :f_a) AS aggregate;

-- ---------- maut_score_detail breakdown -----------------------------
SELECT category, subscore, weight, weighted_contribution
FROM maut_score_detail('fact', :f_a)
ORDER BY weight DESC, category;

-- ---------- malu$maut_summary view ----------------------------------
SELECT target_object_type, target_object_id = :f_a AS object_matched,
       categories_scored, scored_categories,
       aggregate_confidence
FROM malu$maut_summary WHERE target_object_id = :f_a;

-- ---------- disable a weight, aggregate recomputes ------------------
UPDATE malu$maut_weight SET enabled = false
WHERE target_object_type = 'fact' AND category = 'source_diversity';

-- new aggregate excludes source_diversity weight + subscore:
--   sum_weighted = 0.17 + 0.1425 = 0.3125
--   sum_weights  = 0.20 + 0.15   = 0.35
--   aggregate    = 0.3125 / 0.35 = 0.8929 → rounded 0.8929
SELECT maut_aggregate_confidence('fact', :f_a) AS aggregate_after_disable;

-- re-enable for cleanup
UPDATE malu$maut_weight SET enabled = true
WHERE target_object_type = 'fact' AND category = 'source_diversity';

-- ---------- CHECK constraints ---------------------------------------
DO $$ BEGIN
    PERFORM set_maut_score('fact', 1, 'supporting_facts', 1.5,
                           p_evaluator_name => 'test');
    RAISE EXCEPTION 'should have rejected subscore > 1';
EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'OK: subscore upper bound enforced';
END $$;

DO $$ BEGIN
    INSERT INTO malu$maut_weight (target_object_type, category, weight)
    VALUES ('fact', 'inference', -0.1);
    RAISE EXCEPTION 'should have rejected negative weight';
EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'OK: weight lower bound enforced';
END $$;

DO $$ BEGIN
    PERFORM set_maut_score('fact', 1, 'unknown_category', 0.5,
                           p_evaluator_name => 'test');
    RAISE EXCEPTION 'should have rejected bad category';
EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'OK: bad category rejected';
END $$;

-- ---------- stage_boundary: maut_score no longer forbidden ----------
SELECT count(*) AS maut_violations
FROM stage_boundary_violations() WHERE object_name LIKE 'malu$maut_%';

-- ---------- cleanup -------------------------------------------------
DELETE FROM malu$maut_score
 WHERE target_object_type = 'fact' AND target_object_id = :f_a;
DELETE FROM malu$fact WHERE fact_id = :f_a;
-- Leave the default weights in place — they're tenant-level config.
