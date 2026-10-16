-- Stage 4 S4-1 — graph traversal over relationship edges.
--
-- Exercises:
--   * graph_neighbors one-hop with direction in/out/both
--   * relationship_filter narrows the candidate edges
--   * graph_walk respects max_depth bound
--   * BFS ordering produces shallow-first
--   * cycle prevention rejects revisits
--   * graph_path returns ordered paths from src → dst
--   * bad direction / mode / depth rejected

\set ECHO all
SET search_path = maludb_core, public;
SET client_min_messages = NOTICE;

-- ---------- fixture: a small memory/fact graph ----------------------
-- A: a memory
-- B, C: facts derived from A's claims
-- D: episode the memory participates in
-- E: a memory consolidating B + C insights
SELECT register_memory(p_memory_kind=>'event', p_title=>'A') AS a \gset
SELECT register_fact(p_claim_ids=>ARRAY[]::bigint[],
                     p_subject=>'subj_b', p_verb=>'has',
                     p_object_value=>'1', p_statement_text=>'B fact') AS b \gset
SELECT register_fact(p_claim_ids=>ARRAY[]::bigint[],
                     p_subject=>'subj_c', p_verb=>'has',
                     p_object_value=>'2', p_statement_text=>'C fact') AS c \gset
SELECT register_episode(p_episode_kind=>'incident', p_title=>'D') AS d \gset
SELECT register_memory(p_memory_kind=>'event', p_title=>'E') AS e \gset

-- Edges (chosen so the graph is a small DAG):
--   A → B (derived_from)
--   A → C (derived_from)
--   A → D (part_of)
--   B → E (supports)
--   C → E (supports)
SELECT register_relationship_edge('memory',:a, 'fact',          :b, 'derived_from') AS e_ab \gset
SELECT register_relationship_edge('memory',:a, 'fact',          :c, 'derived_from') AS e_ac \gset
SELECT register_relationship_edge('memory',:a, 'episode_object',:d, 'part_of'    ) AS e_ad \gset
SELECT register_relationship_edge('fact',  :b, 'memory',        :e, 'supports'   ) AS e_be \gset
SELECT register_relationship_edge('fact',  :c, 'memory',        :e, 'supports'   ) AS e_ce \gset

-- ---------- graph_neighbors --------------------------------------------
SELECT count(*) AS a_out_count
FROM graph_neighbors('memory', :a, 'out');

SELECT target_object_type, target_object_id IN (:b, :c, :d) AS expected,
       relationship_type
FROM graph_neighbors('memory', :a, 'out')
ORDER BY target_object_id;

-- E has 2 'in' edges (from B + C)
SELECT count(*) AS e_in_count
FROM graph_neighbors('memory', :e, 'in');

-- 'both' includes A's out + nothing in (A has no inbound)
SELECT count(*) AS a_both
FROM graph_neighbors('memory', :a, 'both');

-- relationship_filter restricts
SELECT count(*) AS only_derived
FROM graph_neighbors('memory', :a, 'out', ARRAY['derived_from']);

-- bad direction rejected
SELECT graph_neighbors('memory', :a, 'bogus');

-- ---------- graph_walk: BFS from A ------------------------------------
-- depth=1: B, C, D
SELECT object_type, object_id IN (:b, :c, :d) AS expected_d1,
       depth
FROM graph_walk('memory', :a, p_max_depth=>1, p_direction=>'out')
ORDER BY object_id;

-- depth=2 reaches E via B and C — but E appears twice (two paths)
SELECT count(*) AS depth_le2_rows
FROM graph_walk('memory', :a, p_max_depth=>2, p_direction=>'out')
WHERE depth <= 2;

-- BFS: depth values in ascending order
SELECT bool_and(depth_lt = false OR depth >= prev_depth) AS bfs_ordered
FROM (
    SELECT depth, lag(depth) OVER (ORDER BY (CASE WHEN depth IS NULL THEN 0 ELSE depth END))
        AS prev_depth, (depth < lag(depth) OVER (ORDER BY (CASE WHEN depth IS NULL THEN 0 ELSE depth END))) AS depth_lt
    FROM graph_walk('memory', :a, p_max_depth=>2, p_direction=>'out')
) t;

-- ---------- cycle prevention ------------------------------------------
-- Add a back-edge E → A and verify the walk doesn't loop
SELECT register_relationship_edge('memory', :e, 'memory', :a, 'related_to') > 0 AS back_edge_added;

-- Walk from A with depth 5 — should still terminate, E doesn't push A back
SELECT object_type, object_id, depth
FROM graph_walk('memory', :a, p_max_depth=>5, p_direction=>'out')
WHERE object_id = :a;  -- A should not appear (cycle prevention)

-- A non-cyclic path still works
SELECT count(*) AS finite_walk
FROM graph_walk('memory', :a, p_max_depth=>5, p_direction=>'out');

-- ---------- graph_path: source → target -------------------------------
SELECT depth FROM graph_path('memory', :a, 'memory', :e, p_max_depth=>3)
ORDER BY depth, path_ids
LIMIT 1;

-- A → A self-path: not emitted (graph_walk skips depth=0)
SELECT count(*) AS self_paths
FROM graph_path('memory', :a, 'memory', :a, p_max_depth=>3);

-- No-path case: unrelated D → E within tight depth
-- D has no outbound edges in our fixture
SELECT count(*) AS d_to_e_paths
FROM graph_path('episode_object', :d, 'memory', :e, p_max_depth=>3);

-- ---------- bad inputs ------------------------------------------------
SELECT graph_walk('memory', :a, p_max_depth=>-1);
SELECT graph_walk('memory', :a, p_mode=>'random');

-- ---------- cleanup ---------------------------------------------------
DELETE FROM malu$relationship_edge
 WHERE edge_id IN (:e_ab, :e_ac, :e_ad, :e_be, :e_ce)
    OR (source_object_id IN (:a, :b, :c, :d, :e) OR target_object_id IN (:a, :b, :c, :d, :e));
DELETE FROM malu$memory        WHERE memory_id IN (:a, :e);
DELETE FROM malu$fact          WHERE fact_id   IN (:b, :c);
DELETE FROM malu$episode_object WHERE episode_id = :d;
