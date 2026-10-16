-- pgbench script: graph_walk workload over the bench claim graph.
--
-- Each transaction picks a random bench claim_id and runs graph_walk
-- in BFS mode with depth 2.

\set claim_offset random(1, 1000)
SET search_path = maludb_core, public;

WITH starting AS (
    SELECT claim_id FROM malu$claim
     WHERE subject LIKE 'bench\_%' ESCAPE '\'
     ORDER BY claim_id
     OFFSET :claim_offset - 1
     LIMIT 1
)
SELECT count(*)
FROM starting s, graph_walk('claim', s.claim_id, 2, 'both', NULL, 'bfs') g;
