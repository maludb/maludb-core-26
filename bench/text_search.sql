-- pgbench script: cross-object FTS workload.
--
-- Each transaction picks a random bench token and runs text_search
-- across all four object kinds, limit 20.

\set token_idx random(0, 199)
SET search_path = maludb_core, public;

SELECT count(*)
FROM text_search('bench_subject_' || :token_idx,
                 ARRAY['claim','fact','memory','episode_object']::text[],
                 20);
