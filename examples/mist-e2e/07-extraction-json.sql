-- =====================================================================
-- 07-extraction-json.sql — acceptance test for one-call memory ingestion
-- from an extraction JSON object (docs/memory-extraction-json-contract.md).
--
-- Updated for the 0.94.0 fold (episodes became typed event SUBJECTS — the
-- episodes[] section was REMOVED) and 0.96.0 (event kinds are first-class
-- subject types): an event is a subjects[] entry carrying occurred_at, and
-- its "type" is the event KIND — here the seeded 0.96.0 kind
-- `maintenance_window`.
--
-- Run AFTER bringing a DB up to >= 0.96.0:
--   psql -v ON_ERROR_STOP=1 -d <db> -f 07-extraction-json.sql
--
-- Self-contained: own schema `extract_json`. No LLM is involved — we hand
-- the contract object straight to maludb_memory_ingest_extraction.
-- =====================================================================

\set ON_ERROR_STOP on

DROP SCHEMA IF EXISTS extract_json CASCADE;
CREATE SCHEMA extract_json;
SET search_path = extract_json, maludb_core, public;

\echo == enable memory (expect enabled_version 0.96.0) ==
SELECT * FROM maludb_core.enable_memory_schema('extract_json');

-- ---------------------------------------------------------------------
-- One object → document + 4 subjects (3 entities — one with a node
-- attribute + external ref — and 1 EVENT subject carrying occurred_at and
-- a node attribute) + 3 edges (incl. one EDGE attribute) + 1 subject
-- relationship + one deliberately-bad edge (unknown object key) to prove
-- skip-the-bad-item. Provenance defaults to 'accepted'.
-- ---------------------------------------------------------------------
\echo == ingest one extraction object (capture the report) ==
SELECT jsonb_pretty(extract_json.maludb_memory_ingest_extraction($json${
  "document": { "title": "Sunday maintenance log",
                "content_text": "We performed the Oracle 21c upgrade for the Drajeo project on Sunday March 30 at 11 pm; it depends on the billing API.",
                "document_type": "log" },
  "subjects": [
    { "key": "oracle21c", "name": "Oracle Database 21c", "type": "software",
      "aliases": ["Oracle 21c"],
      "attributes": [ { "attr_name": "version", "value_text": "21c" } ],
      "ref": { "source": "cmdb", "entity": "servers", "key": "srv-100" } },
    { "key": "billing", "name": "Billing API", "type": "software" },
    { "key": "drajeo",  "name": "Drajeo",       "type": "project" },
    { "key": "upg", "name": "Oracle 21c upgrade", "type": "maintenance_window",
      "occurred_at": "2026-03-30T23:00:00-05:00",
      "description": "Production upgrade window",
      "attributes": [ { "attr_name": "duration_minutes", "value_numeric": 90, "unit": "minutes" } ] }
  ],
  "edges": [
    { "subject": "upg", "verb": "upgrade", "object": "oracle21c",
      "attributes": [ { "attr_name": "status", "value_text": "completed" } ],
      "source_span": "We performed the Oracle 21c upgrade ... 11 pm", "confidence": 0.94 },
    { "subject": "upg", "verb": "part_of", "object": "drajeo" },
    { "subject": "upg", "verb": "generated_by", "object": "$source" },
    { "subject": "upg", "verb": "noted", "object": "ghost" }
  ],
  "relationships": [
    { "from": "oracle21c", "to": "billing", "relationship_type": "depends_on" }
  ]
}$json$::jsonb));

-- =====================================================================
-- ASSERT A — the report: created counts + one skipped edge (the ghost ref).
-- =====================================================================
\echo == ASSERT A: report counts (re-run into a temp to read fields) ==
WITH rep AS (
  SELECT extract_json.maludb_memory_ingest_extraction($json${
    "subjects":[{"key":"x","name":"Probe Subject","type":"other"}],
    "edges":[{"subject":"x","verb":"probe","object":"$source"},
             {"subject":"x","verb":"probe","object":"missingkey"}],
    "source":{"kind":"document","id":null}
  }$json$::jsonb) AS r
)
SELECT (r->'created'->>'subjects')::int AS subjects_created,
       (r->'created'->>'edges')::int    AS edges_created,
       jsonb_array_length(r->'skipped') AS skipped_count,
       r->'skipped'->0->>'reason'       AS first_skip_reason
FROM rep;
-- EXPECT: subjects_created 1, edges_created 0 (no source anchor → both edges
-- reference $source/missing → skipped), skipped_count 2.

-- =====================================================================
-- ASSERT B — entity structures landed from the main object.
-- =====================================================================
\echo == ASSERT B: subjects + node attribute + external ref ==
SELECT s.canonical_name, s.subject_type,
       a.attr_name, a.value_text, a.ref_source, a.ref_entity, a.ref_key
FROM   maludb_core.malu$svpor_subject s
LEFT JOIN maludb_core.malu$svpor_attribute a
       ON a.target_kind='subject' AND a.target_id=s.subject_id
WHERE  s.owner_schema='extract_json' AND s.canonical_name IN ('Oracle Database 21c','Billing API','Drajeo')
ORDER  BY s.canonical_name, a.attr_name;
-- EXPECT: Oracle Database 21c has version=21c and external_ref(cmdb/servers/srv-100).

-- =====================================================================
-- ASSERT C — the EVENT is a subject (subject_type = the event kind) with a
-- temporal sidecar and a NODE attribute (event attributes are node
-- attributes since 0.94.0).
-- =====================================================================
\echo == ASSERT C: event subject (kind=maintenance_window) + sidecar + node attribute ==
SELECT s.canonical_name, s.subject_type,
       e.episode_kind, e.occurred_at,
       a.attr_name, a.value_numeric, a.unit
FROM   maludb_core.malu$episode_object e
JOIN   maludb_core.malu$svpor_subject s
       ON s.owner_schema=e.owner_schema AND s.subject_id=e.subject_id
LEFT JOIN maludb_core.malu$svpor_attribute a
       ON a.target_kind='subject' AND a.target_id=s.subject_id AND a.attr_name='duration_minutes'
WHERE  e.owner_schema='extract_json' AND e.title='Oracle 21c upgrade';
-- EXPECT: canonical_name 'Oracle 21c upgrade (2026-03-31)' (events are dated
-- by the UTC date of occurred_at — 23:00-05:00 is 04:00 next day UTC),
-- subject_type maintenance_window, episode_kind maintenance_window,
-- duration_minutes=90.

-- =====================================================================
-- ASSERT D — edges from the event SUBJECT (events resolve as subject
-- endpoints since 0.94.0), incl. the edge attribute, via the graph.
-- =====================================================================
\echo == ASSERT D: edges out of the event subject ==
SELECT rel, neighbor_kind, label
FROM   extract_json.maludb_graph_neighbors(
           'subject',
           (SELECT e.subject_id FROM maludb_core.malu$episode_object e
             WHERE e.owner_schema='extract_json' AND e.title='Oracle 21c upgrade'),
           'out')
ORDER  BY rel;
-- EXPECT: generated_by→document, part_of→Drajeo, upgrade→Oracle Database 21c
-- (the "noted→ghost" edge was skipped).

-- =====================================================================
-- ASSERT E — subject relationship (depends_on).
-- =====================================================================
\echo == ASSERT E: subject relationship (depends_on) ==
SELECT r.relationship_type, r.from_subject_label, r.to_subject_label
FROM   maludb_core.malu$svpor_subject_relationship_edge r
WHERE  r.owner_schema='extract_json';
-- EXPECT: depends_on  Oracle Database 21c → Billing API

-- =====================================================================
-- ASSERT F — re-ingesting the SAME object is idempotent: the event dedups
-- on (kind, title, occurred_at) and the entities resolve by canonical name.
-- =====================================================================
\echo == ASSERT F: re-ingesting the SAME object is idempotent (event deduped, no new subjects) ==
SELECT (extract_json.maludb_memory_ingest_extraction($json${
  "subjects":[
    {"key":"oracle21c","name":"Oracle Database 21c","type":"software"},
    {"key":"upg","name":"Oracle 21c upgrade","type":"maintenance_window","occurred_at":"2026-03-30T23:00:00-05:00"}
  ]
}$json$::jsonb))->'resolved' AS resolved_second_time;
-- EXPECT: {"subjects":2,...,"episodes":1} — both subjects resolved (incl. the
-- event) and the event sidecar resolved; nothing created.

\echo == DONE ==
