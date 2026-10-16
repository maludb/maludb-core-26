-- Deterministic benchmark fixture.
--
-- Seeds malu$claim / malu$fact / malu$memory / malu$episode_object /
-- malu$relationship_edge with ~1000 / 300 / 200 / 100 / 1500 rows
-- respectively under a dedicated bench subject namespace ('bench_*').
-- All rows owned by the calling schema; safe to re-run (TRUNCATE
-- first within the bench namespace).

SET search_path = maludb_core, public;
SET client_min_messages = WARNING;

-- ---------- clean prior fixture (idempotent re-seed) ----------------
DELETE FROM malu$relationship_edge
 WHERE source_object_type IN ('claim','fact','memory','episode_object')
   AND source_object_id IN (
       SELECT claim_id FROM malu$claim WHERE subject LIKE 'bench\_%' ESCAPE '\'
       UNION SELECT fact_id  FROM malu$fact  WHERE subject LIKE 'bench\_%' ESCAPE '\'
       UNION SELECT memory_id FROM malu$memory WHERE title LIKE 'bench\_%' ESCAPE '\'
       UNION SELECT episode_id FROM malu$episode_object WHERE title LIKE 'bench\_%' ESCAPE '\'
   );
DELETE FROM malu$fact_claim
 WHERE fact_id IN (SELECT fact_id FROM malu$fact WHERE subject LIKE 'bench\_%' ESCAPE '\');
DELETE FROM malu$claim          WHERE subject LIKE 'bench\_%' ESCAPE '\';
DELETE FROM malu$fact           WHERE subject LIKE 'bench\_%' ESCAPE '\';
DELETE FROM malu$memory         WHERE title   LIKE 'bench\_%' ESCAPE '\';
DELETE FROM malu$episode_object WHERE title   LIKE 'bench\_%' ESCAPE '\';

-- ---------- claims --------------------------------------------------
INSERT INTO malu$claim (subject, verb, object_value, statement_text, sensitivity)
SELECT
    'bench_subject_' || (n % 200),
    (ARRAY['observed','reported','detected','verified','exceeded','restarted'])[(n % 6) + 1],
    'bench_object_' || (n % 50),
    'bench claim ' || n || ': system event in '
        || (ARRAY['prod','staging','ci','edge'])[(n % 4) + 1]
        || ' with severity ' || (ARRAY['low','medium','high','critical'])[(n % 4) + 1],
    'internal'
FROM generate_series(1, 1000) n;

-- ---------- facts (one per ~3 claims) -------------------------------
INSERT INTO malu$fact (subject, verb, object_value, statement_text,
                       verification_scope, verification_method, sensitivity)
SELECT
    'bench_subject_' || (n % 200),
    'verified_' || (ARRAY['root_cause','effect','remediation','followup'])[(n % 4) + 1],
    'bench_object_' || (n % 50),
    'bench fact ' || n || ': verification of cluster state ' || (n % 100),
    'manual', 'oncall_review', 'internal'
FROM generate_series(1, 300) n;

-- ---------- memories ------------------------------------------------
INSERT INTO malu$memory (memory_kind, title, summary, payload_jsonb)
SELECT
    (ARRAY['lesson','observation','reference','procedure'])[(n % 4) + 1],
    'bench_memory_' || n,
    'bench memory summary ' || n || ' covering subject ' || (n % 200),
    jsonb_build_object('tags', jsonb_build_array(
        'bench', 'cluster_' || (n % 50), 'severity_' || (n % 4)))
FROM generate_series(1, 200) n;

-- ---------- episodes ------------------------------------------------
INSERT INTO malu$episode_object (episode_kind, title, summary, payload_jsonb,
                                  occurred_at)
SELECT
    (ARRAY['incident','deploy','observation','maintenance'])[(n % 4) + 1],
    'bench_episode_' || n,
    'bench episode summary ' || n,
    jsonb_build_object('subject_class', 'bench_subject_' || (n % 200),
                       'environment', (ARRAY['prod','staging'])[(n % 2) + 1]),
    now() - (n || ' hours')::interval
FROM generate_series(1, 100) n;

-- ---------- relationship edges (graph fixture) ----------------------
-- Connect each claim to ~1-2 facts and each memory to ~3 claims.
INSERT INTO malu$relationship_edge
    (relationship_type, source_object_type, source_object_id,
     target_object_type, target_object_id)
SELECT 'supports', 'fact', f.fact_id, 'claim', c.claim_id
FROM (SELECT fact_id, ROW_NUMBER() OVER () AS rn FROM malu$fact
       WHERE subject LIKE 'bench\_%' ESCAPE '\') f
JOIN (SELECT claim_id, ROW_NUMBER() OVER () AS rn FROM malu$claim
       WHERE subject LIKE 'bench\_%' ESCAPE '\') c
  ON f.rn = c.rn;

INSERT INTO malu$relationship_edge
    (relationship_type, source_object_type, source_object_id,
     target_object_type, target_object_id)
SELECT 'derived_from', 'memory', m.memory_id, 'claim', c.claim_id
FROM (SELECT memory_id, ROW_NUMBER() OVER () AS rn FROM malu$memory
       WHERE title LIKE 'bench\_%' ESCAPE '\') m
JOIN (SELECT claim_id, ROW_NUMBER() OVER () AS rn FROM malu$claim
       WHERE subject LIKE 'bench\_%' ESCAPE '\') c
  ON c.rn % 200 = m.rn - 1
WHERE m.rn <= 200;

-- ---------- report --------------------------------------------------
SELECT
    (SELECT count(*) FROM malu$claim          WHERE subject LIKE 'bench\_%' ESCAPE '\') AS claims,
    (SELECT count(*) FROM malu$fact           WHERE subject LIKE 'bench\_%' ESCAPE '\') AS facts,
    (SELECT count(*) FROM malu$memory         WHERE title   LIKE 'bench\_%' ESCAPE '\') AS memories,
    (SELECT count(*) FROM malu$episode_object WHERE title   LIKE 'bench\_%' ESCAPE '\') AS episodes,
    (SELECT count(*) FROM malu$relationship_edge
       WHERE source_object_type IN ('fact','memory')
         AND target_object_type = 'claim') AS edges;

ANALYZE malu$claim;
ANALYZE malu$fact;
ANALYZE malu$memory;
ANALYZE malu$episode_object;
ANALYZE malu$relationship_edge;
