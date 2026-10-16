SET search_path TO maludb_core, public;

-- =======================================================================
-- R1.1-12: Compartmentalized vector search — pg_regress coverage.
-- BYTEA round-trip, distance helpers, compartment registry, exact search.
-- 4-dim test vectors keep the expected output legible.
-- =======================================================================

-- 1. BYTEA round-trip: real[] → bytea → real[]
SELECT vector_dims(vector_from_real_array('{1,0,0,0}'::real[])) AS d4,
       vector_dims(vector_from_real_array('{1,0,0,0,0,0,0,0}'::real[])) AS d8;

-- vector_to_real_array recovers the values
SELECT vector_to_real_array(vector_from_real_array('{1,2,3,4}'::real[])) AS roundtrip;

-- 2. Distance primitives on raw vectors
WITH a AS (SELECT vector_from_real_array('{3,4,0,0}'::real[]) AS v),
     b AS (SELECT vector_from_real_array('{0,0,3,4}'::real[]) AS v),
     c AS (SELECT vector_from_real_array('{3,4,0,0}'::real[]) AS v)
SELECT
    round(vector_norm((SELECT v FROM a))::numeric, 4)              AS norm_a,
    round(vector_dot_product((SELECT v FROM a), (SELECT v FROM b))::numeric, 4) AS dot_ab,
    round(vector_dot_product((SELECT v FROM a), (SELECT v FROM c))::numeric, 4) AS dot_ac,
    round(vector_l2_squared ((SELECT v FROM a), (SELECT v FROM b))::numeric, 4) AS l2sq_ab,
    round(vector_l2_squared ((SELECT v FROM a), (SELECT v FROM c))::numeric, 4) AS l2sq_ac;

-- 3. Normalize: |normalize(v)| = 1
SELECT round(vector_norm(vector_normalize(vector_from_real_array('{3,4,0,0}'::real[])))::numeric, 6)
       AS unit_norm;

-- 4. Compartment registration is idempotent
SELECT register_vector_subject('r112','widgets')   AS subject_id_first;
SELECT register_vector_subject('r112','widgets')   AS subject_id_second;  -- same ID
SELECT register_vector_verb('r112','described')    AS verb_id_first;
SELECT register_vector_verb('r112','described')    AS verb_id_second;     -- same ID

SELECT register_vector_compartment(
    p_namespace       => 'r112',
    p_subject_name    => 'widgets',
    p_verb_name       => 'described',
    p_embedding_dim   => 4,
    p_embedding_model => 'r112-test-4d',
    p_distance_metric => 'cosine'
) AS compartment_id \gset

-- 5. Insert four chunks with semantic distance: chunks A and A' point
-- toward [1,0,0,0]; B points toward [0,1,0,0]; C is orthogonal-ish.
SELECT register_vector_chunk(
    :compartment_id, 'A: aligned with x',
    vector_from_real_array('{0.95,0.10,0.05,0.05}'::real[])) AS chunk_A;
SELECT register_vector_chunk(
    :compartment_id, 'A_prime: also aligned with x',
    vector_from_real_array('{0.85,0.15,0.20,0.10}'::real[])) AS chunk_A_prime;
SELECT register_vector_chunk(
    :compartment_id, 'B: aligned with y',
    vector_from_real_array('{0.10,0.95,0.05,0.05}'::real[])) AS chunk_B;
SELECT register_vector_chunk(
    :compartment_id, 'C: aligned with z',
    vector_from_real_array('{0.10,0.10,0.90,0.10}'::real[])) AS chunk_C;

-- vector_count auto-incremented
SELECT vector_count FROM malu$vector_compartment WHERE compartment_id = :compartment_id;

-- 6. Exact search with cosine — query is heavy on x-axis; A and A_prime
-- should rank ahead of B and C.
SELECT source_text, rank_no
FROM exact_vector_search_sql(
    :compartment_id,
    vector_from_real_array('{0.99,0.10,0.05,0.05}'::real[]),
    4, 'cosine')
ORDER BY rank_no;

-- 7. Same query via the high-level wrapper
SELECT source_text, rank_no, compartment_id
FROM search_memory_exact(
    'r112', 'widgets', 'described',
    vector_from_real_array('{0.99,0.10,0.05,0.05}'::real[]),
    4, 'cosine')
ORDER BY rank_no;

-- 8. l2 metric — same ranking expected here (closer in cosine
-- generally implies closer in L2 for normalized vectors)
SELECT source_text, rank_no
FROM exact_vector_search_sql(
    :compartment_id,
    vector_from_real_array('{0.99,0.10,0.05,0.05}'::real[]),
    4, 'l2')
ORDER BY rank_no;

-- 9. Dim mismatch raises check_violation
SELECT register_vector_chunk(
    :compartment_id, 'wrong dim',
    vector_from_real_array('{1,0,0,0,0,0,0,0}'::real[]));

-- 10. Search with unknown compartment raises no_data_found
SELECT * FROM exact_vector_search_sql(
    99999, vector_from_real_array('{1,0,0,0}'::real[]), 1, 'cosine');

-- 11. Wrapper with unknown compartment also raises no_data_found
SELECT * FROM search_memory_exact(
    'r112', 'no-such-subject', 'described',
    vector_from_real_array('{1,0,0,0}'::real[]), 1, 'cosine');

-- 12. Stage boundary still clean (vector tables are Stage 1.7,
-- whitelisted in stage_boundary.sql, no Stage 2+ tables present)
SELECT count(*) AS stage_boundary_violations
  FROM stage_boundary_violations();

-- 13. R1.1-13 cross-validation: C top-K heap and PL/pgSQL fallback
-- produce identical chunk_id ordering on the same compartment + query.
WITH c_run AS (
    SELECT array_agg(chunk_id ORDER BY rank_no) AS ids,
           array_agg(rank_no  ORDER BY rank_no) AS ranks
    FROM exact_vector_search_sql(
        :compartment_id,
        vector_from_real_array('{0.99,0.10,0.05,0.05}'::real[]),
        4, 'cosine')
), p_run AS (
    SELECT array_agg(chunk_id ORDER BY rank_no) AS ids,
           array_agg(rank_no  ORDER BY rank_no) AS ranks
    FROM exact_vector_search_plpgsql(
        :compartment_id,
        vector_from_real_array('{0.99,0.10,0.05,0.05}'::real[]),
        4, 'cosine')
)
SELECT
    (c_run.ids   = p_run.ids)   AS ids_match,
    (c_run.ranks = p_run.ranks) AS ranks_match
FROM c_run, p_run;
