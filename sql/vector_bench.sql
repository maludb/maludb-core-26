-- V3-VEC-02 — vector_index_record recall_sample slot smoke.
--
-- The Python harness scripts/maludb-bench-vector writes a JSON
-- recall summary into malu$vector_index_status.recall_sample via
-- vector_index_record. This test just confirms the catalog accepts
-- the round-trip and the row surfaces via vector_index_status().

SET search_path TO maludb_core, public;

-- Setup: a compartment to anchor the index status row.
SELECT register_vector_subject('vbench', 'bench_subject');
SELECT register_vector_verb   ('vbench', 'bench_verb');
SELECT register_vector_compartment('vbench', 'bench_subject', 'bench_verb',
                                    8, 'bench-model') AS compartment_id \gset c_

-- Record a synthetic bench result. The harness produces the same
-- jsonb shape end-to-end.
SELECT vector_index_record(
    :'c_compartment_id'::bigint,
    'exact',
    true,
    0,
    0,
    jsonb_build_object(
        'corpus',          64,
        'dim',              8,
        'queries',          8,
        'k',               10,
        'exact_median_ms', 1.32,
        'exact_p95_ms',    2.91,
        'match_min',       10,
        'match_max',       10)) AS status_id \gset s_

-- vector_index_status surfaces the row with the recall summary.
SELECT kind,
       (recall_sample ->> 'corpus')::int AS corpus,
       (recall_sample ->> 'match_min')::int AS match_min,
       (recall_sample ->> 'match_max')::int AS match_max
FROM vector_index_status()
WHERE compartment_id = :'c_compartment_id'::bigint;

-- Cleanup.
DELETE FROM malu$vector_index_status WHERE compartment_id = :'c_compartment_id'::bigint;
DELETE FROM malu$vector_chunk        WHERE compartment_id = :'c_compartment_id'::bigint;
DELETE FROM malu$vector_compartment  WHERE compartment_id = :'c_compartment_id'::bigint;
DELETE FROM malu$vector_verb         WHERE namespace='vbench';
DELETE FROM malu$vector_subject      WHERE namespace='vbench';
DELETE FROM malu$audit_event         WHERE event_kind LIKE 'vector_%';
