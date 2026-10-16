# Getting started with MaluDB

This tutorial walks one full ingestion → claim → fact → episode →
replay cycle end-to-end. By the end you'll have:

- registered a source package and two raw claims,
- verified the claims into a fact,
- recorded an episode with two steps,
- queried the result via FTS, retrieval planner, and graph traversal,
- replayed the episode at "current valid" and at a prior transaction
  time.

Time budget: about 15 minutes. Prerequisites: a maludb_core
extension installed via [`docs/install.md`](install.md) and an empty
target database.

## 0. Create a database and enable the extension

```bash
sudo -u postgres createdb tutorial
sudo -u postgres psql -d tutorial -c "CREATE EXTENSION maludb_core CASCADE"
```

The `CASCADE` pulls in `vector`, `btree_gist`, and `pg_trgm`
automatically.

To use MaluDB like a standard PostgreSQL schema, opt an application schema into
the memory facades:

```sql
-- Run this connected to the database where maludb_core is installed
-- (`psql -d tutorial` or `\c tutorial`). The extension is per-database:
-- running this from the default `postgres` database "succeeds" through the
-- GRANT/SET steps and then fails with
-- ERROR: schema "maludb_core" does not exist.
CREATE USER app;
GRANT maludb_user TO app;
CREATE SCHEMA app AUTHORIZATION app;
SET ROLE app;
SET search_path TO app, maludb_core, public;
SELECT * FROM maludb_core.enable_memory_schema();
SELECT * FROM maludb_subject;
RESET ROLE;
SET search_path = maludb_core, public;
```

The schema-local surface includes skill discovery. After `enable_memory_schema`,
tenant users can add manual skill keywords and search their own plus public
skills:

```sql
SET ROLE app;
SET search_path TO app, maludb_core, public;

INSERT INTO maludb_skill(skill_name, version, description, packaging_kind)
VALUES ('meeting_action_item_extractor', '1.0.0',
        'Extract action items from meeting transcripts.', 'markdown');

INSERT INTO maludb_skill_keyword(skill_id, keyword)
SELECT skill_id, 'action items'
FROM maludb_skill
WHERE skill_name = 'meeting_action_item_extractor';

SELECT skill_name, owner_schema, match_reasons
FROM maludb_skill_search(
    p_query => 'extract action items',
    p_subject => 'meeting transcript',
    p_verb => 'extract'
);
```

## 1. Record the source

Start an interactive `psql` session against the tutorial database and
set the schema search path. Keep this `psql` session open for steps 1
through 6; the later SQL snippets are meant to be pasted at the
`tutorial=>` prompt.

```bash
psql -d tutorial
```

```sql
SET search_path = maludb_core, public;
```

Every claim must point back to evidence. Start by registering the
source package the claim will cite. A "source package" is any
durable byte blob — a log excerpt, a ticket comment, a chat
transcript, a metric snapshot.

```sql
SELECT register_source_package(
    p_source_type   => 'log',
    p_content_text  => 'oncall-bot: 14:22Z api-gateway 5xx 18%/min for 60s',
    p_origin_jsonb  => jsonb_build_object('uri','log://oncall-bot/2026-05-13')
) AS sp_id;
```

`sp_id` will be `1` on a fresh database. Note the source package
content hash + size are computed automatically; tombstoning a source
package later is a single update that doesn't break references.

## 2. Raise two raw claims

A "claim" is a single proposition with a subject + verb + object.
Multiple claims can support one fact.

```sql
SELECT register_claim(
    p_subject => 'api_gateway',
    p_verb    => 'observed',
    p_object_value => '5xx_burst',
    p_statement_text => 'Initial 5xx surge at 14:22Z.',
    p_source_package_id => 1
) AS claim_a;

SELECT register_claim(
    p_subject => 'api_gateway',
    p_verb    => 'timed_out',
    p_object_value => 'health_probe',
    p_statement_text => 'Health probe exceeded 2s window.',
    p_source_package_id => 1
) AS claim_b;
```

## 3. Verify into a fact

A fact is a verified consolidation of one or more claims. Verifying
means an actor with appropriate role applied a verification method.

```sql
SELECT register_fact(
    p_claim_ids => ARRAY[1, 2]::bigint[],
    p_subject => 'api_gateway',
    p_verb    => 'incident',
    p_object_value => 'latency_breach',
    p_statement_text => 'Latency SLO breach root cause identified.',
    p_verification_scope  => 'manual',
    p_verification_method => 'oncall_review'
) AS fact_id;
```

The fact-claim linkage rows in `malu$fact_claim` make it cheap to
trace evidence later.

## 4. Capture the episode

An episode is the *event* — a coherent thing that happened. Steps
attach as Memory Detail Objects.

```sql
SELECT register_episode(
    p_episode_kind => 'incident',
    p_title        => 'api-gateway outage 2026-05-13',
    p_summary      => 'Two-step rolling deploy with one validation failure.',
    p_payload_jsonb => jsonb_build_object(
        'subject_class','api_gateway','environment','prod')
) AS episode_id;

INSERT INTO malu$memory_detail_object
    (episode_id, detail_kind, ordinal, title, body_jsonb)
VALUES
    (1, 'step', 1, 'shift_traffic',
     jsonb_build_object('action_class','traffic_shift','actor','release-bot',
                        'tool','kubectl','outcome','success')),
    (1, 'step', 2, 'health_check',
     jsonb_build_object('action_class','health_probe','actor','ci',
                        'tool','curl','outcome','failure',
                        'exception','LatencySLOBreach'));
```

## 5. Query it back

### Full-text search

```sql
SELECT object_type, object_id, title_or_subject, rank
FROM text_search('latency breach', ARRAY['claim','fact','memory','episode_object'])
ORDER BY rank DESC;
```

### Retrieval planner

```sql
SELECT *
FROM execute_retrieval(
    ROW('api_gateway latency',
        ARRAY['claim','fact','episode_object']::text[],
        NULL, NULL, NULL, NULL)::malu$retrieval_envelope_t,
    NULL, 10);
```

This is the full S4-5 orchestrator: planning-time authz pruning,
strategy dispatch, assembly-time tombstone + confidence-floor
filtering, audit emission.

### Episode replay

```sql
SELECT replay_episode(1, 'current_valid') -> 'supporting_evidence';
```

The envelope answers the four §3.13 questions:

- `what_happened` — the current accepted view.
- `supporting_evidence` — claims + facts cited.
- `prior_belief` — only set for `as_of_transaction_time` / `full_bitemporal`.
- `later_changes` — supersessions / retractions / valid-window closures
  since the episode.

```sql
-- Time-travel: what did the DBMS believe an hour ago?
SELECT replay_episode(1, 'as_of_transaction_time', now() - interval '1 hour') -> 'prior_belief';
```

## 6. Correct a fact without overwriting history

Suppose the fact's `object_value` should be `pool_exhaustion`, not
`latency_breach`. Don't UPDATE — use the supersession engine:

```sql
SELECT correct_fact(
    p_fact_id => 1,
    p_new_object_value => 'pool_exhaustion',
    p_reason => 'oncall determined connection pool exhaustion'
);
```

This closes the prior valid window, opens a new version, and
records a `malu$supersession_edge` of kind `correction`. The
replay envelope's `later_changes` will surface the supersession.

## 7. What's next

- [docs/admin-guide.md](admin-guide.md) — day-2 operations: backups,
  retention, audit query patterns, lifecycle policy.
- [docs/bench-baseline.md](bench-baseline.md) — performance baseline.
- [examples/](../examples/) — additional scenarios (skill execution,
  pool promotion, local-node sync).
