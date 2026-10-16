-- R1.1-15: Parallel exact vector search.
--
-- Exercises:
--   * search_mode='exact'           → single-process C heap (R1.1-13)
--   * search_mode='exact_parallel'  → custom aggregate path (this phase)
--   * search_mode='local_ann'       → raises feature_not_supported
--   * results identical across both backends (rank + chunk_id agreement)
--   * topk_vector_search aggregate is parallel-safe (verified via
--     pg_proc.proparallel + force_parallel_mode catalog inspection)

\set ECHO all
SET search_path = maludb_core, public;
SET client_min_messages = NOTICE;

-- ---------- fixture ----------------------------------------------------
SELECT register_vector_compartment(
    p_namespace       => 'r115',
    p_subject_name    => 'docs',
    p_verb_name       => 'ranked',
    p_embedding_dim   => 4,
    p_embedding_model => 'r115-test-4d',
    p_distance_metric => 'cosine'
) AS compartment_id \gset

-- Insert 8 chunks pointing in varying directions.
SELECT register_vector_chunk(
    :compartment_id, 'A_x_aligned',
    vector_from_real_array('{0.95,0.10,0.05,0.05}'::real[])) > 0;
SELECT register_vector_chunk(
    :compartment_id, 'B_x_aligned_2',
    vector_from_real_array('{0.85,0.15,0.20,0.10}'::real[])) > 0;
SELECT register_vector_chunk(
    :compartment_id, 'C_y_aligned',
    vector_from_real_array('{0.10,0.95,0.05,0.05}'::real[])) > 0;
SELECT register_vector_chunk(
    :compartment_id, 'D_z_aligned',
    vector_from_real_array('{0.10,0.10,0.90,0.10}'::real[])) > 0;
SELECT register_vector_chunk(
    :compartment_id, 'E_w_aligned',
    vector_from_real_array('{0.05,0.05,0.10,0.95}'::real[])) > 0;
SELECT register_vector_chunk(
    :compartment_id, 'F_x_slight',
    vector_from_real_array('{0.70,0.30,0.10,0.05}'::real[])) > 0;
SELECT register_vector_chunk(
    :compartment_id, 'G_xy_mix',
    vector_from_real_array('{0.60,0.60,0.05,0.10}'::real[])) > 0;
SELECT register_vector_chunk(
    :compartment_id, 'H_random',
    vector_from_real_array('{0.30,0.40,0.50,0.45}'::real[])) > 0;

SELECT vector_count, search_mode
FROM malu$vector_compartment WHERE compartment_id = :compartment_id;

-- ---------- search_mode='exact' (default): single-process ------------
SELECT chunk_id, source_text, rank_no
FROM exact_vector_search_sql(
    :compartment_id,
    '[0.99, 0.10, 0.05, 0.05]'::malu_vector,
    4, 'cosine')
ORDER BY rank_no;

-- ---------- switch to exact_parallel and confirm same ranking --------
UPDATE malu$vector_compartment SET search_mode='exact_parallel'
WHERE compartment_id = :compartment_id;

SELECT chunk_id, source_text, rank_no
FROM exact_vector_search_sql(
    :compartment_id,
    '[0.99, 0.10, 0.05, 0.05]'::malu_vector,
    4, 'cosine')
ORDER BY rank_no;

-- ---------- ranking parity: single-process == parallel ---------------
-- Force back to 'exact' to capture the single-process baseline; then
-- 'exact_parallel' for the worker path. Compare chunk_id arrays.
UPDATE malu$vector_compartment SET search_mode='exact'
WHERE compartment_id = :compartment_id;

CREATE TEMP TABLE _exact_run AS
SELECT array_agg(chunk_id ORDER BY rank_no) AS ids
FROM exact_vector_search_sql(
    :compartment_id,
    '[0.99, 0.10, 0.05, 0.05]'::malu_vector,
    6, 'cosine');

UPDATE malu$vector_compartment SET search_mode='exact_parallel'
WHERE compartment_id = :compartment_id;

CREATE TEMP TABLE _parallel_run AS
SELECT array_agg(chunk_id ORDER BY rank_no) AS ids
FROM exact_vector_search_sql(
    :compartment_id,
    '[0.99, 0.10, 0.05, 0.05]'::malu_vector,
    6, 'cosine');

SELECT (e.ids = p.ids) AS rankings_identical
FROM _exact_run e, _parallel_run p;

-- ---------- aggregate metadata: parallel-safe ------------------------
SELECT proparallel
FROM   pg_proc
WHERE  proname = 'topk_vector_finalize';

SELECT proparallel
FROM   pg_proc
WHERE  proname = 'topk_vector_sfunc';

-- aggregate definition itself
SELECT a.aggcombinefn::regprocedure IS NOT NULL AS has_combine,
       a.aggserialfn::regprocedure  IS NOT NULL AS has_serial,
       a.aggdeserialfn::regprocedure IS NOT NULL AS has_deserial
FROM   pg_aggregate a
JOIN   pg_proc p ON p.oid = a.aggfnoid
WHERE  p.proname = 'topk_vector_search';

-- ---------- search_mode='local_ann' before ann_build → raises -------
-- (R1.1-16 wired the ANN path; an unbuilt compartment now reports
-- missing malu$ann_index rather than feature_not_supported.)
UPDATE malu$vector_compartment SET search_mode='local_ann'
WHERE compartment_id = :compartment_id;

DO $$ BEGIN
    PERFORM * FROM exact_vector_search_sql(
        (SELECT compartment_id FROM malu$vector_compartment WHERE namespace='r115' LIMIT 1),
        '[0.99, 0.10, 0.05, 0.05]'::malu_vector, 4, 'cosine');
    RAISE EXCEPTION 'should have raised no_data_found';
EXCEPTION WHEN no_data_found THEN
    RAISE NOTICE 'OK: local_ann without ann_build raises no_data_found';
END $$;

-- restore for cleanup
UPDATE malu$vector_compartment SET search_mode='exact'
WHERE compartment_id = :compartment_id;

-- ---------- cleanup --------------------------------------------------
DROP TABLE _exact_run;
DROP TABLE _parallel_run;
DELETE FROM malu$vector_chunk WHERE compartment_id = :compartment_id;
DELETE FROM malu$vector_compartment WHERE compartment_id = :compartment_id;
DELETE FROM malu$vector_subject WHERE namespace='r115';
DELETE FROM malu$vector_verb    WHERE namespace='r115';
