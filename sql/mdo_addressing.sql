-- Stage 2 S2-4 — recursive Memory Detail Object addressing.
--
-- Exercises:
--   * mdo_uri generated column — stable, unique
--   * mdo_resolve(uri) round-trip + malformed-URI rejection
--   * mdo_ancestors walks parent chain depth-first
--   * mdo_descendants with max_depth bound
--   * mdo_root identifies the top-level memory/episode/orphan
--   * mdo_subtree_json renders a depth-limited tree

\set ECHO all
SET search_path = maludb_core, public;
SET client_min_messages = NOTICE;

-- ---------- fixture: an episode with a 3-level MDO chain --------------
SELECT register_episode(
    p_episode_kind => 'migration',
    p_title        => 'S2-4 test episode',
    p_summary      => 'Three-level MDO tree under one episode.'
) AS episode_id \gset

SELECT register_memory_detail(
    p_detail_kind => 'step',
    p_episode_id  => :episode_id,
    p_ordinal     => 1,
    p_title       => 'Step 1: backup'
) AS step1 \gset

SELECT register_memory_detail(
    p_detail_kind   => 'substep',
    p_parent_mdo_id => :step1,
    p_ordinal       => 1,
    p_title         => 'Substep 1.1: pg_dump'
) AS sub1_1 \gset

SELECT register_memory_detail(
    p_detail_kind   => 'validation',
    p_parent_mdo_id => :sub1_1,
    p_ordinal       => 1,
    p_title         => 'Validate dump file'
) AS val1_1_1 \gset

SELECT register_memory_detail(
    p_detail_kind   => 'substep',
    p_parent_mdo_id => :step1,
    p_ordinal       => 2,
    p_title         => 'Substep 1.2: verify backup'
) AS sub1_2 \gset

SELECT register_memory_detail(
    p_detail_kind => 'step',
    p_episode_id  => :episode_id,
    p_ordinal     => 2,
    p_title       => 'Step 2: migrate'
) AS step2 \gset

-- A standalone MDO with NO parent_mdo / memory / episode would be
-- rejected at register; we already proved that in memory_object_model.
-- Here we just verify the chain is intact.

SELECT count(*) AS mdos_in_episode
FROM malu$memory_detail_object
WHERE episode_id = :episode_id OR mdo_id IN
    (SELECT mdo_id FROM mdo_descendants(:step1));

-- ---------- mdo_uri: stable, unique ----------------------------------
SELECT mdo_id, mdo_uri
FROM malu$memory_detail_object
WHERE mdo_id IN (:step1, :sub1_1, :val1_1_1)
ORDER BY mdo_id;

-- URI for our step1 row should match the generated form.
SELECT mdo_uri = 'mdo://' || current_schema() || '/' || :step1::text AS uri_matches
FROM malu$memory_detail_object WHERE mdo_id = :step1;

-- ---------- mdo_resolve: URI round-trip ------------------------------
SELECT mdo_resolve('mdo://' || current_schema() || '/' || :step1::text) = :step1
       AS round_trip;

DO $$ BEGIN
    PERFORM mdo_resolve('not-a-uri');
    RAISE EXCEPTION 'should have rejected malformed URI';
EXCEPTION WHEN invalid_parameter_value THEN
    RAISE NOTICE 'OK: malformed URI rejected';
END $$;

DO $$ BEGIN
    PERFORM mdo_resolve('mdo://' || current_schema() || '/9999999');
    RAISE EXCEPTION 'should have rejected unknown MDO id';
EXCEPTION WHEN no_data_found THEN
    RAISE NOTICE 'OK: unknown MDO URI rejected';
END $$;

-- ---------- mdo_ancestors: walk upward -------------------------------
SELECT depth, detail_kind, title
FROM mdo_ancestors(:val1_1_1)
ORDER BY depth;

-- Top-level step1 has depth 0 only when called on itself.
SELECT count(*) AS step1_ancestors_count
FROM mdo_ancestors(:step1);

-- ---------- mdo_descendants: walk downward ---------------------------
SELECT depth, ordinal_path, detail_kind, title
FROM mdo_descendants(:step1)
ORDER BY ordinal_path, mdo_id;

-- depth-limited: only direct children
SELECT count(*) AS depth_one_subtree
FROM mdo_descendants(:step1, p_max_depth => 1);

-- the full subtree is bigger
SELECT count(*) AS full_subtree
FROM mdo_descendants(:step1);

-- ---------- mdo_root: chain to the top -------------------------------
SELECT (mdo_root(:val1_1_1)).root_kind AS root_kind,
       (mdo_root(:val1_1_1)).root_id   AS root_id,
       array_length((mdo_root(:val1_1_1)).mdo_chain, 1) AS chain_depth;

-- the root_id should be our episode
SELECT (mdo_root(:val1_1_1)).root_id = :episode_id AS root_matches_episode;

-- top-most element of the chain should be step1 (the MDO directly
-- attached to the episode)
SELECT (mdo_root(:val1_1_1)).mdo_chain[1] = :step1 AS chain_top_is_step1;

-- ---------- mdo_subtree_json: tree-shaped output ---------------------
-- root node carries identity + children array
SELECT
    j ->> 'mdo_id' = :step1::text                     AS root_id_matches,
    j ->> 'detail_kind'                                AS root_kind,
    jsonb_array_length(j -> 'children') > 0            AS has_children,
    -- first child carries ordinal=1
    (j -> 'children' -> 0) ->> 'ordinal' = '1'         AS first_child_ordinal_ok
FROM (SELECT mdo_subtree_json(:step1) AS j) t;

-- depth-bounded tree
SELECT jsonb_array_length(
    (mdo_subtree_json(:step1, p_max_depth => 0)) -> 'children'
) AS depth_zero_children;

-- ---------- cleanup --------------------------------------------------
DELETE FROM malu$memory_detail_object
 WHERE mdo_id IN (:step1, :step2, :sub1_1, :sub1_2, :val1_1_1)
    OR episode_id = :episode_id;
DELETE FROM malu$episode_object WHERE episode_id = :episode_id;
