-- V3-VEC-01 — vector metadata filter + index status regression coverage.

SET search_path TO maludb_core, public;

-- ---------------------------------------------------------------------
-- Setup: a tiny 3-d compartment with metadata-tagged chunks.
-- ---------------------------------------------------------------------
SELECT register_vector_compartment('v3_vec', 'subj', 'verb', 3, 'demo-3d', 'cosine') AS compartment_id \gset c_

INSERT INTO malu$vector_chunk (compartment_id, source_text, embedding, embedding_dim, embedding_model, metadata)
VALUES
    (:'c_compartment_id'::bigint, 'doc-en', vector_from_real_array(ARRAY[1.0, 0.0, 0.0]::real[]), 3, 'demo-3d',
     jsonb_build_object('language','en','domain','ops')),
    (:'c_compartment_id'::bigint, 'doc-de', vector_from_real_array(ARRAY[0.95, 0.05, 0.0]::real[]), 3, 'demo-3d',
     jsonb_build_object('language','de','domain','ops')),
    (:'c_compartment_id'::bigint, 'doc-en-sec', vector_from_real_array(ARRAY[0.9, 0.1, 0.0]::real[]), 3, 'demo-3d',
     jsonb_build_object('language','en','domain','security'));

UPDATE malu$vector_compartment SET vector_count = 3 WHERE compartment_id = :'c_compartment_id'::bigint;

-- ---------------------------------------------------------------------
-- Test 1: search_memory_filter applies metadata @> filter.
-- {"language":"en"} matches doc-en + doc-en-sec; doc-de is excluded.
-- ---------------------------------------------------------------------
SELECT source_text, metadata ->> 'language' AS lang
FROM search_memory_filter('v3_vec', 'subj', 'verb',
    vector_from_real_array(ARRAY[1.0, 0.0, 0.0]::real[]),
    jsonb_build_object('language','en'),
    10)
ORDER BY source_text;

-- {"language":"en","domain":"security"} narrows further.
SELECT source_text
FROM search_memory_filter('v3_vec', 'subj', 'verb',
    vector_from_real_array(ARRAY[1.0, 0.0, 0.0]::real[]),
    jsonb_build_object('language','en','domain','security'),
    10);

-- ---------------------------------------------------------------------
-- Test 2: vector_index_record + vector_index_status.
-- ---------------------------------------------------------------------
SELECT vector_index_record(:'c_compartment_id'::bigint, 'exact', true, 0, 0,
                           jsonb_build_object('recall_at_5', 1.0)) AS status_id \gset s_

SELECT kind, delta_count, tombstone_count
FROM malu$vector_index_status
WHERE compartment_id = :'c_compartment_id'::bigint;

SELECT compartment_id, kind, vector_count, delta_count, tombstone_count
FROM vector_index_status()
WHERE compartment_id = :'c_compartment_id'::bigint;

-- ---------------------------------------------------------------------
-- Test 3: audit + emit_event landed.
-- ---------------------------------------------------------------------
SELECT event_kind, count(*) AS n FROM malu$audit_event
WHERE event_kind = 'vector_index_record'
GROUP BY event_kind;

SELECT event_kind, count(*) AS n FROM malu$event
WHERE event_kind = 'vector_index_record'
GROUP BY event_kind;

-- ---------------------------------------------------------------------
-- Cleanup.
-- ---------------------------------------------------------------------
DELETE FROM malu$vector_index_status WHERE compartment_id = :'c_compartment_id'::bigint;
DELETE FROM malu$vector_chunk        WHERE compartment_id = :'c_compartment_id'::bigint;
DELETE FROM malu$vector_compartment  WHERE compartment_id = :'c_compartment_id'::bigint;
DELETE FROM malu$audit_event         WHERE event_kind = 'vector_index_record';
DELETE FROM malu$event               WHERE event_kind = 'vector_index_record';
