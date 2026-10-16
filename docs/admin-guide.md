# MaluDB admin guide

Day-2 operations for an installed MaluDB cluster. Assumes you've
followed [docs/install.md](install.md) and have the extension
running.

## 1. Roles at a glance

The `maludb_memory_*` role family slices capability semantically
rather than by schema:

| Role | What it can do |
|---|---|
| `maludb_memory_admin` | Full CRUD on every governed table; can grant cross-tenant access via `malu$object_grant`. |
| `maludb_memory_executor` | Default authenticated role. CRUD on its own tenant's rows; SELECT via `MALU_ALL_*` views on other tenants where granted. |
| `maludb_memory_auditor` | Read-only across all governed tables for compliance review. |
| `maludb_memory_dba` | `BYPASSRLS`; system-level operations. **Do not assign to humans by default.** |
| `maludb_skill_curator` | Curates public skills in `maludb_public`; use for trusted maintainers only. |

Most operators should grant the user-facing convenience roles instead of the
internal `maludb_memory_*` roles:

| Role | Use |
|---|---|
| `maludb_read` | Read schema-local MaluDB views and read-only search wrappers. |
| `maludb_user` | Normal read/write use; maps to the memory executor role. |
| `maludb_admin` | Trusted admin delegation. |
| `maludb` | Short alias for `maludb_user` only on installs where that role name is not already occupied by an operator login. |

The model/LLM tier has a parallel `maludb_llm_*` family covering
prompts, providers, and the model gateway.

Grant a real PG user a tenant role:

```sql
CREATE USER app;
GRANT maludb_user TO app;
CREATE SCHEMA app AUTHORIZATION app;
SET ROLE app;
SET search_path TO app, maludb_core, public;
SELECT * FROM maludb_core.enable_memory_schema();
```

Scripted onboarding can use:

```bash
psql -d maludb -v role=app -v access=write -f sql/grant-memory-access.sql
```

After login, the schema owner should keep `search_path` in that order so
schema-local facades such as `maludb_subject`, `maludb_document`, and
`maludb_memory_pool` resolve before the shared extension schema.

Public skill discovery uses the reserved `maludb_public` schema. Create it like
any other memory-enabled schema, grant `maludb_skill_curator` only to trusted
curators, and insert public rows through the schema-local `maludb_skill`,
`maludb_skill_subject`, `maludb_skill_verb`, and `maludb_skill_keyword`
facades. Tenant searches include public skills by default.

## 2. Backups

MaluDB is a plain PostgreSQL database. Use whatever you already use.
Two notes:

1. `malu$verbatim_archive` can grow large. Keep it in the same
   logical backup; restore is meaningless without it.
2. `malu$source_package.content_bytes` is bytea. The deduplication
   via `content_hash` survives backup/restore.

A simple full-cluster nightly:

```bash
sudo -u postgres pg_basebackup -D /backups/$(date +%F) \
    -Ft -z -P --wal-method=stream
```

For per-database logical backups:

```bash
sudo -u postgres pg_dump -Fc -d maludb -f /backups/maludb-$(date +%F).dump
```

## 3. Retention + lifecycle

The Stage 3 lifecycle engine handles retention via policy. Policies
live in `malu$lifecycle_policy` and run via `apply_lifecycle_state`:

```sql
-- Retire facts whose subject hasn't been reinforced in 180 days.
INSERT INTO malu$lifecycle_policy
    (policy_name, target_object_type, criterion_jsonb, target_state)
VALUES ('stale_facts', 'fact',
    jsonb_build_object('reinforcement_age_days', 180),
    'retired');

-- Periodically (e.g. nightly cron):
SELECT *
FROM retention_candidates('fact', 180);

-- Per-row: stage by stage.
SELECT apply_lifecycle_state('fact', 42, 'retired', 'stale_facts');
```

**Legal hold gates everything.** `apply_lifecycle_state` refuses
terminal transitions on rows with an active `malu$legal_hold` entry.
Operators MUST release the hold first:

```sql
SELECT legal_hold_release(hold_id, 'matter closed');
```

## 4. Audit query patterns

Every governance action writes a `malu$audit_event` row. Common
queries:

```sql
-- Recent corrections, by tenant:
SELECT occurred_at, owner_schema, target_object_id, event_jsonb
FROM malu$audit_event
WHERE event_kind = 'correct_fact'
ORDER BY occurred_at DESC LIMIT 50;

-- Skill executions that emitted claims:
SELECT er.execution_id, er.skill_id,
       cardinality(er.emitted_claim_ids) AS claims_emitted
FROM malu$skill_execution_record er
WHERE cardinality(er.emitted_claim_ids) > 0
ORDER BY er.bound_at DESC;

-- Local-node submissions awaiting decision:
SELECT submission_id, submission_kind, submitted_at, node_id
FROM malu$node_sync_record WHERE status = 'pending'
ORDER BY submitted_at;

-- Workflow candidates needing review:
SELECT candidate_id, name, positive_evidence_count, negative_evidence_count
FROM malu$workflow_candidate WHERE review_status = 'proposed'
ORDER BY created_at;
```

The `pgaudit` extension layers OS-level audit logs alongside
`malu$audit_event`. Confirm it's preloaded:

```bash
sudo -u postgres psql -tAc "SHOW shared_preload_libraries"
```

Should include `pgaudit`. If empty, see
[docs/security-review.md](security-review.md) finding #3.

## 5. Vacuum + analyze

The `malu$audit_event`, `malu$episode_replay`, and
`malu$model_request` tables grow monotonically. Autovacuum keeps up
fine on small/medium clusters, but on busy hosts add manual
`VACUUM ANALYZE` to a nightly job. The bitemporal GiST indexes on
`malu$fact`, `malu$claim`, `malu$memory`, `malu$episode_object`
benefit from a weekly `REINDEX` if you have heavy supersession
traffic.

## 6. Extension upgrades

Migrations land as `maludb_core--X.Y.0--X.(Y+1).0.sql` files. To
upgrade an existing database:

```bash
# After `sudo apt upgrade maludb` lands the new files:
sudo -u postgres psql -d maludb -c \
    "ALTER EXTENSION maludb_core UPDATE TO '0.74.0'"
```

The migration chain handles incremental upgrades. Always run on
test before prod.

## 7. Monitoring

A Prometheus scrape target is published by the MC2DB listener; see
[docs/monitoring.md](monitoring.md). Key metrics:

- `maludb_audit_event_total` — count by event_kind.
- `maludb_retrieval_executed_total` — count by mode + temporal_mode.
- `maludb_skill_execution_finalised_total` — by final_outcome.
- `maludb_node_submission_total` — by status.
- `maludb_index_migration_status` — gauge per migration_id.

## 8. Common operational tasks

### Re-embed under a new model

The Stage 6 blue-green flow handles this without downtime:

```sql
SELECT propose_index_migration(
    p_source_space_id => 1,  -- current active space
    p_target_space_id => 2,  -- new model's space
    p_index_kind => 'hnsw');

-- Build the shadow index out-of-band, then:
SELECT advance_index_migration(<migration_id>, 'shadow_building');
SELECT advance_index_migration(<migration_id>, 'dual_serve', 10);  -- 10% target
-- Increase weight over time:
SELECT advance_index_migration(<migration_id>, 'dual_serve', 50);
SELECT advance_index_migration(<migration_id>, 'cutover');
SELECT advance_index_migration(<migration_id>, 'cleanup');
SELECT advance_index_migration(<migration_id>, 'done');
```

`route_query('embedding')` returns the live routing decision at
each stage. See `examples/04-model-blue-green.sql`.

### Revoke a compromised local node

```sql
SELECT revoke_local_node(node_id, 'fingerprint mismatch on rekey');
```

After revoke, all subsequent `node_submit` calls from that node
raise `object_not_in_prerequisite_state`. Existing pending
submissions remain for forensic review; the operator can
`node_reject` them with a reason.
