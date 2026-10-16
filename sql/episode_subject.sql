\set ECHO all
\pset format unaligned
SET client_min_messages = WARNING;

CREATE EXTENSION IF NOT EXISTS maludb_core CASCADE;
SET search_path TO maludb_core, public;

DROP SCHEMA IF EXISTS episode_subject_a CASCADE;
DROP ROLE IF EXISTS episode_subject_user;
CREATE ROLE episode_subject_user NOLOGIN;
GRANT maludb_memory_executor TO episode_subject_user;
GRANT USAGE ON SCHEMA maludb_core TO episode_subject_user;
CREATE SCHEMA episode_subject_a AUTHORIZATION episode_subject_user;

SET ROLE episode_subject_user;
SET search_path TO episode_subject_a, maludb_core, public;

SELECT object_count > 0 AS enabled
FROM maludb_core.enable_memory_schema();

-- Enablement registered the episode facade objects.
SELECT object_name, object_kind
FROM maludb_core.malu$enabled_schema_object
WHERE schema_name = 'episode_subject_a'
  AND object_name IN ('maludb_episode', 'maludb_register_episode')
ORDER BY object_name;

-- Registering an episode mints a subject as its identity: the kind is the
-- subject_type, the canonical name carries the UTC occurrence date, and the
-- raw title becomes an alias.
SELECT maludb_register_episode(
           'deployment', 'Deploy v2 rollout', 'Rolled out v2',
           '{"env": "prod"}'::jsonb,
           '2026-06-01 10:00+00'::timestamptz,
           '2026-06-01 11:00+00'::timestamptz) AS episode_id \gset

SELECT subject_id IS NOT NULL AS has_subject,
       canonical_name = 'Deploy v2 rollout (2026-06-01)' AS canonical_name_dated,
       episode_kind,
       title,
       payload_jsonb ->> 'env' AS env,
       lifecycle_state
FROM maludb_episode
WHERE episode_id = :episode_id;

SELECT subject_id AS episode_subject_id
FROM maludb_episode
WHERE episode_id = :episode_id \gset

SELECT subject_type,
       'Deploy v2 rollout' = ANY (aliases) AS title_aliased
FROM maludb_subject
WHERE subject_id = :episode_subject_id;

-- 'deployment' is a seeded event-kind subject_type (system_defined = true
-- since 0.96.0); the episode resolves to it rather than auto-registering.
SELECT subject_type, system_defined
FROM maludb_core.malu$svpor_subject_type
WHERE subject_type = 'deployment';

-- The event subject participates in the subject-relationship layer.
INSERT INTO maludb_subject(subject_type, canonical_name)
VALUES ('person', 'Operator Pat')
RETURNING subject_id AS pat_id \gset

INSERT INTO maludb_subject_relationship
    (from_subject_id, to_subject_id, relationship_type, label)
VALUES (:pat_id, :episode_subject_id, 'performed', 'pat ran the deploy');

SELECT from_subject_label,
       to_subject_label = 'Deploy v2 rollout (2026-06-01)' AS event_is_target,
       relationship_type
FROM maludb_subject_relationship
WHERE from_subject_id = :pat_id;

-- The core register path (no facade) also mints: no occurred_at, so the
-- name disambiguates with the episode id and the kind still types it.
SELECT maludb_core.register_episode('meeting', 'Standup') AS episode2_id \gset

SELECT count(*) AS standup_subjects
FROM maludb_subject
WHERE canonical_name = 'Standup [#' || :episode2_id || ']'
  AND subject_type = 'meeting';

-- Same-day same-title events keep per-occurrence identity: the second
-- one falls back to the [#id] suffix.
SELECT maludb_register_episode(
           'deployment', 'Deploy v2 rollout', 'Second attempt', '{}'::jsonb,
           '2026-06-01 22:00+00'::timestamptz) AS episode3_id \gset

SELECT canonical_name = 'Deploy v2 rollout [#' || :episode3_id || ']' AS same_day_suffixed
FROM maludb_episode
WHERE episode_id = :episode3_id;

-- The facade view stays writable; the mint trigger covers direct inserts.
-- (canonical_name is checked in a separate statement: the trigger's subject
-- insert is not yet visible to the INSERT's own RETURNING snapshot.)
INSERT INTO maludb_episode(episode_kind, title, occurred_at)
VALUES ('incident', 'Pager storm', '2026-06-02 03:00+00'::timestamptz);

SELECT canonical_name = 'Pager storm (2026-06-02)' AS view_insert_minted,
       subject_id IS NOT NULL AS has_subject
FROM maludb_episode
WHERE title = 'Pager storm';

SELECT count(*) AS pager_subjects_before_delete
FROM maludb_subject
WHERE canonical_name LIKE 'Pager storm%';

-- Deleting the body directly removes the identity too (no orphan subject).
DELETE FROM maludb_episode WHERE title = 'Pager storm';

SELECT count(*) AS pager_subjects_after_delete
FROM maludb_subject
WHERE canonical_name LIKE 'Pager storm%';

-- ---------------------------------------------------------------------
-- 0.94.0 ingest contract: events are subjects[] entries with occurred_at.
-- ---------------------------------------------------------------------
SELECT maludb_memory_ingest_extraction($json$
{
  "subjects": [
    {"key": "ora", "name": "Oracle Database 21c", "type": "software"},
    {"key": "upg", "name": "Oracle 21c upgrade", "type": "maintenance_window",
     "occurred_at": "2026-03-30T23:00:00+00", "description": "Production upgrade window",
     "attributes": [{"attr_name": "duration_minutes", "value_numeric": 90}]}
  ],
  "edges": [
    {"subject": "ora", "verb": "upgrade", "object": "upg", "source_span": "performed the upgrade"}
  ],
  "relationships": [
    {"from": "upg", "to": "ora", "relationship_type": "about"}
  ]
}
$json$::jsonb) AS report \gset

SELECT (:'report'::jsonb -> 'created' ->> 'subjects')::int  AS subjects_created,
       (:'report'::jsonb -> 'created' ->> 'episodes')::int  AS episodes_created,
       (:'report'::jsonb -> 'created' ->> 'edges')::int     AS edges_created,
       (:'report'::jsonb -> 'created' ->> 'relationships')::int AS rels_created,
       (:'report'::jsonb -> 'created' ->> 'node_attributes')::int AS node_attrs,
       jsonb_array_length(:'report'::jsonb -> 'skipped')    AS skipped;

-- The event landed as a dated subject with its sidecar...
SELECT canonical_name = 'Oracle 21c upgrade (2026-03-30)' AS event_named,
       episode_kind,
       occurred_at = '2026-03-30T23:00:00+00'::timestamptz AS occurred_at_ok
FROM maludb_episode
WHERE title = 'Oracle 21c upgrade';

-- ...the edge addresses SUBJECT endpoints (no episode_object addressing)...
SELECT s.subject_kind, s.object_kind
FROM maludb_core.malu$svpor_statement s
JOIN maludb_core.malu$svpor_verb v ON v.verb_id = s.verb_id
WHERE s.owner_schema = 'episode_subject_a'
  AND v.canonical_name = 'upgrade';

-- ...the event attribute is a node attribute on the subject...
SELECT a.target_kind, a.attr_name, a.value_numeric
FROM maludb_core.malu$svpor_attribute a
JOIN maludb_core.malu$svpor_subject s
  ON s.owner_schema = a.owner_schema AND s.subject_id = a.target_id
WHERE a.owner_schema = 'episode_subject_a'
  AND a.target_kind = 'subject'
  AND s.canonical_name = 'Oracle 21c upgrade (2026-03-30)';

-- ...and the event participates in relationships[] (subjects-only layer).
SELECT from_subject_label, to_subject_label, relationship_type
FROM maludb_core.malu$svpor_subject_relationship_edge
WHERE owner_schema = 'episode_subject_a'
  AND relationship_type = 'about'
  AND from_subject_label LIKE 'Oracle 21c upgrade%';

-- Re-ingesting the same occurrence dedups on (kind, title, occurred_at).
SELECT maludb_memory_ingest_extraction($json$
{
  "subjects": [
    {"key": "upg", "name": "Oracle 21c upgrade", "type": "maintenance_window",
     "occurred_at": "2026-03-30T23:00:00+00"}
  ]
}
$json$::jsonb) -> 'resolved' ->> 'episodes' AS episodes_resolved_on_reingest;

-- The removed episodes[] section fails fast (a stale extractor cannot
-- silently drop its events).
SELECT maludb_memory_ingest_extraction(
    '{"episodes": [{"key": "e1", "kind": "meeting", "title": "Old shape"}]}'::jsonb);

-- Deleting the subject row is the canonical delete path: the episode
-- body cascades away with it.
DELETE FROM maludb_subject WHERE subject_id = :episode_subject_id;

SELECT count(*) AS deploy_rows_after_delete
FROM maludb_episode
WHERE episode_id = :episode_id;

-- Re-enabling is idempotent: the facade slot stays singly registered.
SELECT object_count > 0 AS re_enabled
FROM maludb_core.enable_memory_schema();

SELECT count(*) AS episode_facade_records
FROM maludb_core.malu$enabled_schema_object
WHERE schema_name = 'episode_subject_a'
  AND object_name = 'maludb_episode';

RESET ROLE;
SET search_path TO maludb_core, public;

DELETE FROM malu$svpor_subject_relationship_edge WHERE owner_schema = 'episode_subject_a';
DELETE FROM malu$relationship_edge WHERE owner_schema = 'episode_subject_a';
DELETE FROM malu$svpor_statement WHERE owner_schema = 'episode_subject_a';
DELETE FROM malu$svpor_attribute WHERE owner_schema = 'episode_subject_a';
DELETE FROM malu$episode_object WHERE owner_schema = 'episode_subject_a';
DELETE FROM malu$svpor_verb WHERE owner_schema = 'episode_subject_a';
DELETE FROM malu$svpor_subject WHERE owner_schema = 'episode_subject_a';
DELETE FROM malu$enabled_schema_object WHERE schema_name = 'episode_subject_a';
DELETE FROM malu$enabled_schema WHERE schema_name = 'episode_subject_a';
DROP SCHEMA episode_subject_a CASCADE;
DROP OWNED BY episode_subject_user;
DROP ROLE episode_subject_user;
