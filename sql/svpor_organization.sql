-- Stage 3 S3-3 — SVPOR organization layer.
--
-- Exercises:
--   * register_svpor_subject / _verb / _predicate upsert + alias merge
--   * resolve_svpor_* via canonical or alias
--   * auto-resolve trigger on claim / fact INSERT + UPDATE
--   * routing index used for (subject, verb) lookup
--   * svpor_frame_text embedding-prefix shape
--   * malu$claim_svpor_resolved view surfaces canonical name

\set ECHO all
SET search_path = maludb_core, public;
SET client_min_messages = NOTICE;

-- ---------- register: subject + verb + predicate -------------------
SELECT register_svpor_subject(
    p_canonical_name => 'postgres_pool',
    p_aliases        => ARRAY['pg_pool','db_pool','connection_pool']
) AS subj_id \gset

SELECT register_svpor_verb(
    p_canonical_name => 'has_size',
    p_aliases        => ARRAY['size','sized_to','max_size']
) AS verb_id \gset

SELECT register_svpor_predicate(
    p_canonical_name => 'max',
    p_aliases        => ARRAY['upper_bound','cap']
) AS pred_id \gset

-- Re-register with new aliases — aliases array is merged
SELECT register_svpor_subject(
    p_canonical_name => 'postgres_pool',
    p_aliases        => ARRAY['rds_pool']
) AS subj_id_again \gset
SELECT :subj_id = :subj_id_again AS subj_id_stable;
SELECT aliases @> ARRAY['pg_pool','rds_pool']::text[] AS aliases_merged
FROM malu$svpor_subject WHERE subject_id = :subj_id;

-- ---------- resolve via canonical + alias --------------------------
SELECT resolve_svpor_subject('postgres_pool') = :subj_id AS canonical_hit;
SELECT resolve_svpor_subject('pg_pool')       = :subj_id AS alias_hit;
SELECT resolve_svpor_subject('unknown_subj')  IS NULL    AS miss;

SELECT resolve_svpor_verb('max_size') = :verb_id  AS verb_alias_hit;
SELECT resolve_svpor_predicate('cap') = :pred_id  AS pred_alias_hit;

-- ---------- auto-resolve trigger on claim --------------------------
SELECT register_claim(
    p_subject        => 'pg_pool',
    p_verb           => 'max_size',
    p_predicate      => 'cap',
    p_object_value   => '40',
    p_statement_text => 'pool cap raised to 40'
) AS claim_a \gset

SELECT svpor_subject_id = :subj_id  AS subj_resolved,
       svpor_verb_id    = :verb_id  AS verb_resolved,
       svpor_predicate_id = :pred_id AS pred_resolved
FROM malu$claim WHERE claim_id = :claim_a;

-- Update text — trigger re-resolves the affected column
UPDATE malu$claim
   SET subject = 'unknown_subj', svpor_subject_id = NULL
 WHERE claim_id = :claim_a;

SELECT svpor_subject_id IS NULL AS subj_unresolved
FROM malu$claim WHERE claim_id = :claim_a;

-- Restore + register the alias retroactively — re-resolve
UPDATE malu$svpor_subject
   SET aliases = aliases || 'unknown_subj'::text
 WHERE subject_id = :subj_id;

UPDATE malu$claim SET svpor_subject_id = NULL
 WHERE claim_id = :claim_a;        -- prep
UPDATE malu$claim SET subject = 'unknown_subj'    -- trigger fires
 WHERE claim_id = :claim_a;

SELECT svpor_subject_id = :subj_id AS subj_re_resolved
FROM malu$claim WHERE claim_id = :claim_a;

-- ---------- fact auto-resolve --------------------------------------
SELECT register_fact(
    p_claim_ids => ARRAY[]::bigint[],
    p_subject   => 'connection_pool',
    p_verb      => 'has_size',
    p_predicate => 'max',
    p_object_value => '40',
    p_statement_text => 'verified pool max=40'
) AS fact_a \gset

SELECT svpor_subject_id = :subj_id AS subj_ok,
       svpor_verb_id    = :verb_id AS verb_ok,
       svpor_predicate_id = :pred_id AS pred_ok
FROM malu$fact WHERE fact_id = :fact_a;

-- ---------- routing index — explain that the partial index is used
-- (We don't assert plan text here; just verify the index exists.)
SELECT indexname FROM pg_indexes
WHERE schemaname = 'maludb_core'
  AND tablename IN ('malu$claim','malu$fact')
  AND indexname LIKE '%svpor_routing%'
ORDER BY indexname;

-- ---------- svpor_frame_text shape --------------------------------
SELECT svpor_frame_text('pg_pool','has_size','max','40')
       AS full_frame;
SELECT svpor_frame_text('pg_pool','has_size')
       AS minimal_frame;
SELECT svpor_frame_text(NULL, 'has_size')
       AS subject_missing;

-- ---------- resolved view ------------------------------------------
SELECT subject_canonical, verb_canonical, predicate_canonical, object_value
FROM malu$claim_svpor_resolved WHERE claim_id = :claim_a;

SELECT subject_canonical, verb_canonical, predicate_canonical, lifecycle_state
FROM malu$fact_svpor_resolved WHERE fact_id = :fact_a;

-- ---------- stage_boundary: svpor_* names no longer forbidden ------
SELECT count(*) AS svpor_violations
FROM stage_boundary_violations() WHERE object_name LIKE 'malu$svpor_%';

-- ---------- cleanup ------------------------------------------------
DELETE FROM malu$fact  WHERE fact_id  = :fact_a;
DELETE FROM malu$claim WHERE claim_id = :claim_a;
DELETE FROM malu$svpor_predicate WHERE predicate_id = :pred_id;
DELETE FROM malu$svpor_verb      WHERE verb_id      = :verb_id;
DELETE FROM malu$svpor_subject   WHERE subject_id   = :subj_id;
