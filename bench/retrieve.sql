-- pgbench script: end-to-end execute_retrieval workload.
--
-- Each transaction picks a random bench cue and runs the full
-- retrieval orchestrator (planner → strategy dispatch → assembly
-- filter + audit emission).

\set token_idx random(0, 199)
SET search_path = maludb_core, public;

SELECT count(*)
FROM execute_retrieval(
    ROW('bench_subject_' || :token_idx,
        ARRAY['claim','fact','memory','episode_object']::text[],
        NULL, NULL, NULL, NULL)::malu$retrieval_envelope_t,
    NULL, 20);
