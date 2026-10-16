\set ECHO all
\pset format unaligned
SET client_min_messages = WARNING;

CREATE EXTENSION IF NOT EXISTS maludb_core CASCADE;
SET search_path TO maludb_core, public;

DROP SCHEMA IF EXISTS semantic_entity_a CASCADE;
DROP ROLE IF EXISTS semantic_entity_user;
CREATE ROLE semantic_entity_user NOLOGIN;
GRANT maludb_memory_executor TO semantic_entity_user;
GRANT USAGE ON SCHEMA maludb_core TO semantic_entity_user;
CREATE SCHEMA semantic_entity_a AUTHORIZATION semantic_entity_user;

SET ROLE semantic_entity_user;
SET search_path TO semantic_entity_a, maludb_core, public;

SELECT object_count > 0 AS enabled
FROM maludb_core.enable_memory_schema();

-- ---------------------------------------------------------------------
-- 1. One ingest call builds the graph AND feeds the dirty queue: the
--    0.95.0 triggers mark every touched subject/verb/statement, with no
--    change to the extraction JSON contract.
-- ---------------------------------------------------------------------
SELECT maludb_memory_ingest_extraction($json$
{
  "document": {"title": "Sunday maintenance log",
               "content_text": "We performed the Oracle 21c upgrade; it depends on the billing API.",
               "document_type": "log"},
  "subjects": [
    {"key": "ora", "name": "Oracle Database 21c", "type": "software",
     "aliases": ["Oracle 21c"],
     "attributes": [{"attr_name": "version", "value_text": "21c"}]},
    {"key": "billing", "name": "Billing API", "type": "software"},
    {"key": "upg", "name": "Oracle 21c upgrade", "type": "maintenance_window",
     "occurred_at": "2026-03-30T23:00:00+00",
     "attributes": [{"attr_name": "duration_minutes", "value_numeric": 90}]}
  ],
  "edges": [
    {"subject": "upg", "verb": "upgrade", "object": "ora",
     "attributes": [{"attr_name": "status", "value_text": "completed"}],
     "source_span": "We performed the Oracle 21c upgrade", "confidence": 0.94}
  ],
  "relationships": [
    {"from": "ora", "to": "billing", "relationship_type": "depends_on"}
  ]
}
$json$::jsonb) AS report \gset

SELECT (:'report'::jsonb -> 'created' ->> 'subjects')::int      AS subjects_created,
       (:'report'::jsonb -> 'created' ->> 'edges')::int         AS edges_created,
       (:'report'::jsonb -> 'created' ->> 'relationships')::int AS rels_created,
       jsonb_array_length(:'report'::jsonb -> 'skipped')        AS skipped;

SELECT (:'report'::jsonb -> 'ids' ->> 'ora')::bigint     AS ora_id \gset
SELECT (:'report'::jsonb -> 'ids' ->> 'billing')::bigint AS billing_id \gset
SELECT (:'report'::jsonb -> 'ids' ->> 'upg')::bigint     AS upg_id \gset

-- The ingest dirtied 3 subjects, the edge, and the verbs (the auto-created
-- 'upgrade' plus the 6 enablement-seeded defaults).
SELECT object_kind, count(*) AS pending
FROM maludb_embedding_dirty
GROUP BY object_kind
ORDER BY object_kind;

-- ---------------------------------------------------------------------
-- 2. Cards are deterministic, name-first, content-dominant; the hash is
--    stable across calls.
-- ---------------------------------------------------------------------
SELECT maludb_core.subject_card_text(:ora_id) AS ora_card;

SELECT maludb_core.subject_card_text(:upg_id) AS event_card;

SELECT s.statement_id AS stmt_id
FROM maludb_core.malu$svpor_statement s
JOIN maludb_core.malu$svpor_verb v ON v.verb_id = s.verb_id
WHERE s.owner_schema = 'semantic_entity_a'
  AND v.canonical_name = 'upgrade' \gset

SELECT maludb_core.statement_card_text(:stmt_id) AS edge_card;

SELECT (SELECT content_hash FROM maludb_embedding_card('subject', :ora_id))
     = (SELECT content_hash FROM maludb_embedding_card('subject', :ora_id)) AS hash_stable;

-- ---------------------------------------------------------------------
-- 3. Worker protocol with synthetic 4-d vectors: claim, complete,
--    no-op hash skip, generation race.
-- ---------------------------------------------------------------------
SELECT count(*) AS claimable
FROM maludb_embedding_dirty_claim(NULL, 100);

-- complete each entity (worker side: vector arrives from outside)
SELECT maludb_embedding_complete('subject', :ora_id,
    (SELECT generation FROM maludb_embedding_dirty WHERE object_kind = 'subject' AND object_id = :ora_id),
    maludb_core.vector_from_real_array(ARRAY[1,0,0,0]::real[])::bytea, 4,
    'entity-v1', 'demo-4d',
    (SELECT content_hash FROM maludb_embedding_card('subject', :ora_id))) > 0 AS ora_embedded;

SELECT maludb_embedding_complete('subject', :billing_id,
    (SELECT generation FROM maludb_embedding_dirty WHERE object_kind = 'subject' AND object_id = :billing_id),
    maludb_core.vector_from_real_array(ARRAY[0.9,0.1,0,0]::real[])::bytea, 4,
    'entity-v1', 'demo-4d',
    (SELECT content_hash FROM maludb_embedding_card('subject', :billing_id))) > 0 AS billing_embedded;

SELECT maludb_embedding_complete('subject', :upg_id,
    (SELECT generation FROM maludb_embedding_dirty WHERE object_kind = 'subject' AND object_id = :upg_id),
    maludb_core.vector_from_real_array(ARRAY[0,1,0,0]::real[])::bytea, 4,
    'entity-v1', 'demo-4d',
    (SELECT content_hash FROM maludb_embedding_card('subject', :upg_id))) > 0 AS upg_embedded;

-- Drain every pending verb through the worker loop in one pass.
SELECT count(*) AS verbs_drained
FROM (
    SELECT maludb_embedding_complete('verb', c.object_id, c.generation,
               maludb_core.vector_from_real_array(ARRAY[0,0,1,0]::real[])::bytea, 4,
               'entity-v1', 'demo-4d', c.content_hash)
    FROM maludb_embedding_dirty_claim(ARRAY['verb'], 10) c
) t;

SELECT maludb_embedding_complete('svpor_statement', :stmt_id,
    (SELECT generation FROM maludb_embedding_dirty WHERE object_kind = 'svpor_statement' AND object_id = :stmt_id),
    maludb_core.vector_from_real_array(ARRAY[0,0,0,1]::real[])::bytea, 4,
    'entity-v1', 'demo-4d',
    (SELECT content_hash FROM maludb_embedding_card('svpor_statement', :stmt_id))) > 0 AS edge_embedded;

SELECT count(*) AS dirty_after_completes
FROM maludb_embedding_dirty;

-- An unchanged card never reaches the embedding model: requeue marks all
-- subjects, claim hash-skips them and the queue drains to zero.
SELECT maludb_embedding_requeue_all('subject') AS requeued;

SELECT count(*) AS claimed_after_requeue
FROM maludb_embedding_dirty_claim(ARRAY['subject'], 10);

SELECT count(*) AS dirty_after_noop_claim
FROM maludb_embedding_dirty
WHERE object_kind = 'subject';

-- Generation race: a mid-embed accretion survives a stale complete.
SELECT maludb_core.register_svpor_attribute('subject', :ora_id, 'owner_team',
    p_value_text => 'DBA') > 0 AS attr1_applied;

SELECT generation AS ora_gen
FROM maludb_embedding_dirty
WHERE object_kind = 'subject' AND object_id = :ora_id \gset

SELECT maludb_core.register_svpor_attribute('subject', :ora_id, 'license_state',
    p_value_text => 'active') > 0 AS attr2_applied;

-- complete with the STALE generation: vector stored, queue row survives
SELECT maludb_embedding_complete('subject', :ora_id, :ora_gen,
    maludb_core.vector_from_real_array(ARRAY[1,0,0,0]::real[])::bytea, 4,
    'entity-v1', 'demo-4d', NULL) > 0 AS stale_complete_stored;

SELECT count(*) AS ora_still_dirty
FROM maludb_embedding_dirty
WHERE object_kind = 'subject' AND object_id = :ora_id;

-- finish the cycle with the current generation
SELECT maludb_embedding_complete('subject', :ora_id,
    (SELECT generation FROM maludb_embedding_dirty WHERE object_kind = 'subject' AND object_id = :ora_id),
    maludb_core.vector_from_real_array(ARRAY[1,0,0,0]::real[])::bytea, 4,
    'entity-v1', 'demo-4d',
    (SELECT content_hash FROM maludb_embedding_card('subject', :ora_id))) > 0 AS fresh_complete;

SELECT count(*) AS dirty_drained
FROM maludb_embedding_dirty;

-- ---------------------------------------------------------------------
-- 4. Materialized semantic edges: ora [1,0,0,0] and billing [0.9,0.1,0,0]
--    sit at cosine ~0.99 (over the 0.80 threshold); the event [0,1,0,0]
--    is orthogonal and gets no edges. Reciprocals are upserted.
-- ---------------------------------------------------------------------
SELECT object_kind,
       source_id = :ora_id     AS from_ora,
       source_id = :billing_id AS from_billing,
       target_id = :ora_id     AS to_ora,
       target_id = :billing_id AS to_billing,
       similarity > 0.98       AS sim_high
FROM maludb_semantic_edge
ORDER BY source_id, target_id;

-- Query-time hop agrees (and the event stays below the floor).
SELECT neighbor_id = :billing_id AS billing_is_neighbor,
       similarity > 0.98 AS sim_high,
       label
FROM maludb_semantic_neighbors('subject', :ora_id, 5, 0.5);

-- ---------------------------------------------------------------------
-- 5. Traversal: jumps are OPT-IN. A NULL rel_filter walk stays purely
--    structural (bit-identical to 0.94.0 behavior); naming 'similar_to'
--    traverses the jump; structural rels and jumps compose in one walk.
-- ---------------------------------------------------------------------
SELECT count(*) AS semantic_edges_in_default_walk
FROM maludb_graph_walk('subject', :ora_id, 2, 'both', NULL)
WHERE edge_store = 'semantic_edge';

SELECT object_id = :billing_id AS jumped_to_billing, rel, edge_store, depth
FROM maludb_graph_walk('subject', :ora_id, 1, 'out', ARRAY['similar_to']);

-- Arm-3 gap fix: the ingested relationships[] edge is finally walkable.
SELECT object_id = :billing_id AS reached_billing, rel, edge_store
FROM maludb_graph_walk('subject', :ora_id, 1, 'out', ARRAY['depends_on']);

-- Structural hop + semantic jump in one cycle-safe walk:
-- event --upgrade--> ora --similar_to--> billing.
SELECT label, rel, edge_store, depth
FROM maludb_graph_walk('subject', :upg_id, 2, 'out', ARRAY['upgrade','similar_to'])
ORDER BY depth, label;

-- ---------------------------------------------------------------------
-- 6. source_spans[] accretion: a second mention of the same SVO edge
--    keeps BOTH verbatim spans (newest first); 'source_span' stays the
--    latest. The helper dedupes repeats and caps the history.
-- ---------------------------------------------------------------------
SELECT maludb_memory_ingest_extraction($json$
{
  "document": {"title": "Postmortem", "content_text": "Upgrade window ran 90 minutes.",
               "document_type": "log"},
  "subjects": [
    {"key": "ora", "name": "Oracle Database 21c", "type": "software"},
    {"key": "upg", "name": "Oracle 21c upgrade", "type": "maintenance_window",
     "occurred_at": "2026-03-30T23:00:00+00"}
  ],
  "edges": [
    {"subject": "upg", "verb": "upgrade", "object": "ora",
     "source_span": "upgrade window ran 90 minutes"}
  ]
}
$json$::jsonb) -> 'created' ->> 'edges' AS edges_second_mention;

SELECT metadata_jsonb ->> 'source_span' AS latest_span,
       jsonb_array_length(metadata_jsonb -> 'source_spans') AS span_count,
       metadata_jsonb -> 'source_spans' -> 0 ->> 'span' AS newest_span,
       metadata_jsonb -> 'source_spans' -> 1 ->> 'span' AS oldest_span
FROM maludb_core.malu$svpor_statement
WHERE statement_id = :stmt_id;

SELECT jsonb_array_length(maludb_core._statement_spans_accrete(
           maludb_core._statement_spans_accrete(NULL, 'same span', 1),
           'same span', 1)) AS dedupe_keeps_one;

WITH RECURSIVE acc(i, spans) AS (
    SELECT 1, maludb_core._statement_spans_accrete(NULL, 'span 1', 1)
    UNION ALL
    SELECT i + 1, maludb_core._statement_spans_accrete(spans, 'span ' || (i + 1), 1)
    FROM acc WHERE i < 10
)
SELECT jsonb_array_length(spans) AS capped_at,
       spans -> 0 ->> 'span' AS newest_kept
FROM acc WHERE i = 10;

-- ---------------------------------------------------------------------
-- 7. Deleting an entity purges its queue row, its entity-card vector and
--    its semantic edges (no orphans polluting semantic_search).
-- ---------------------------------------------------------------------
DELETE FROM maludb_subject WHERE subject_id = :billing_id;

SELECT count(*) AS billing_vectors
FROM maludb_object_embedding
WHERE object_kind = 'subject' AND object_id = :billing_id;

SELECT count(*) AS billing_semantic_edges
FROM maludb_semantic_edge
WHERE source_id = :billing_id OR target_id = :billing_id;

SELECT count(*) AS billing_dirty_rows
FROM maludb_embedding_dirty
WHERE object_kind = 'subject' AND object_id = :billing_id;

-- ---------------------------------------------------------------------
-- cleanup
-- ---------------------------------------------------------------------
RESET ROLE;
SET search_path TO maludb_core, public;

DELETE FROM malu$semantic_edge WHERE owner_schema = 'semantic_entity_a';
DELETE FROM malu$embedding_dirty WHERE owner_schema = 'semantic_entity_a';
DELETE FROM malu$object_embedding WHERE owner_schema = 'semantic_entity_a';
DELETE FROM malu$svpor_subject_relationship_edge WHERE owner_schema = 'semantic_entity_a';
DELETE FROM malu$svpor_statement WHERE owner_schema = 'semantic_entity_a';
DELETE FROM malu$svpor_attribute WHERE owner_schema = 'semantic_entity_a';
DELETE FROM malu$episode_object WHERE owner_schema = 'semantic_entity_a';
DELETE FROM malu$svpor_verb WHERE owner_schema = 'semantic_entity_a';
DELETE FROM malu$svpor_subject WHERE owner_schema = 'semantic_entity_a';
DELETE FROM malu$document WHERE owner_schema = 'semantic_entity_a';
DELETE FROM malu$enabled_schema_object WHERE schema_name = 'semantic_entity_a';
DELETE FROM malu$enabled_schema WHERE schema_name = 'semantic_entity_a';
DROP SCHEMA semantic_entity_a CASCADE;
DROP OWNED BY semantic_entity_user;
DROP ROLE semantic_entity_user;
