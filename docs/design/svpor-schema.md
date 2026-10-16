# SVPOR schema design

**Stage:** 3 (per `requirements.md` §9). This document is design-on-paper. **Do not** install any of this DDL into the Stage 1 `sql/extension/maludb_core--0.1.0.sql`. Stage 3 will translate this into versioned extension upgrade scripts.

**Sources:** `white-paper.md` §5 (SVPOR), `requirements.md` §3.1 (object model), §3.2 (SVPOR), §3.3 (MAUT), §3.4 (bitemporal), §3.5 (derivation ledger), §4.5 (authorization-aware retrieval), §5 (security), §9 (phased plan).

## 1. Two tiers

| Tier | Contents | Mutability | Tenant ownership |
|---|---|---|---|
| **A — System catalog** | SVPOR taxonomies and platform metadata | Seeded by extension; pragmatic DML by `malu_dba`; structural changes via versioned `maludb_core--X.Y--X.Z.sql` upgrade scripts only | Not tenant-owned |
| **B — Governed objects** | All instance data: subjects, memories, predicate values, edges, details, plus the Stage-2 object types | Full CRUD by tenants through `MALU_USER_<x>` views | Each row tagged with `owner_schema` |

## 2. Naming and access conventions

See `CLAUDE.md` → "Naming and access conventions" for the canonical rules. Quick reference:

- Base tables: `malu$<name>` (private — no `PUBLIC` grants).
- Views: `MALU_USER_<x>` (own-schema CRUD), `MALU_ALL_<x>` (own + granted, read), `MALU_DBA_<x>` (full, `malu_dba` only).
- Tenant ≡ PG schema. Each Tier-B row carries `owner_schema name NOT NULL DEFAULT current_schema()`.
- Function bodies use **tagged** dollar quotes (`$body$ ... $body$`), never bare `$$ ... $$`, because `$` appears in identifiers.

## 3. Required PG extensions

`pgvector`, `btree_gist` (mixed-type `EXCLUDE` constraints), `pg_trgm` (subject fuzzy match), `pgcrypto` if `gen_random_uuid()` isn't core for the target PG version.

## 4. Tier A — System catalog

Type registries that govern the SVPOR vocabulary. Seeded at `CREATE EXTENSION` time; rows are reference data shared across all tenants.

```sql
CREATE TABLE malu$object_type (
    object_type_id   int  PRIMARY KEY,
    name             text UNIQUE NOT NULL,
    description      text NOT NULL
);

CREATE TABLE malu$subject_type (
    subject_type_id  int  PRIMARY KEY,
    name             text UNIQUE NOT NULL,
    parent_id        int  REFERENCES malu$subject_type,
    description      text NOT NULL
);

CREATE TABLE malu$verb_type (
    verb_type_id     int  PRIMARY KEY,
    name             text UNIQUE NOT NULL,
    semantic_class   text NOT NULL
        CHECK (semantic_class IN ('event','state','observation','derivation')),
    parent_id        int  REFERENCES malu$verb_type,
    description      text NOT NULL
);

CREATE TABLE malu$predicate_type (
    predicate_type_id int  PRIMARY KEY,
    name              text UNIQUE NOT NULL,
    value_kind        text NOT NULL
        CHECK (value_kind IN ('text','identifier_ref','timestamp','tstzrange','numeric','enum','json')),
    description       text NOT NULL
);

CREATE TABLE malu$relationship_type (
    relationship_type_id int  PRIMARY KEY,
    name                 text UNIQUE NOT NULL,
    category             text NOT NULL CHECK (category IN
        ('association','causal','temporal','containment','provenance','governance','procedural')),
    is_directed          bool NOT NULL DEFAULT true,
    inverse_id           int  REFERENCES malu$relationship_type,
    requires_evidence    bool NOT NULL DEFAULT false,
    description          text NOT NULL
);

CREATE TABLE malu$model_registry (
    model_id            int  PRIMARY KEY,
    name                text NOT NULL,
    version             text NOT NULL,
    role                text NOT NULL
        CHECK (role IN ('embedding','extraction','summarization','classification','verification')),
    embedding_dim       int,
    parameters          jsonb NOT NULL DEFAULT '{}',
    UNIQUE (name, version, role)
);

CREATE TABLE malu$tenant (
    schema_name           name PRIMARY KEY,
    display_name          text,
    default_partition_id  int,
    retention_class       text,
    created_at            timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE malu$tenant_member (
    schema_name     name NOT NULL REFERENCES malu$tenant,
    role_name       name NOT NULL,
    role_in_tenant  text NOT NULL CHECK (role_in_tenant IN ('owner','member','reader')),
    PRIMARY KEY (schema_name, role_name)
);
```

Named edges in `malu$relationship_type` from white paper §5.5: `supports`, `contradicts`, `supersedes`, `derived_from`, `verified_by`, `caused_by`, `depends_on`, `part_of`, `related_to`, `before`, `after`, `inside`, `with`, `from`, `has_detail`, `contains`, `because_of`, `about`. Stored as data, not enum values, so governance can extend the taxonomy without DDL.

## 5. Tier B — Governed objects

### 5.1 Polymorphic anchor

```sql
CREATE TABLE malu$governed_object (
    object_id      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    object_type_id int  NOT NULL REFERENCES malu$object_type,
    owner_schema   name NOT NULL DEFAULT current_schema(),
    created_at     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX malu$governed_object_owner_idx
    ON malu$governed_object (owner_schema, object_type_id);
```

Every governed-object row in this tier has a row here. `owner_schema` is denormalized onto each child instance table (see §5.3) so per-tenant views remain simply-updatable. A trigger or deferred CHECK keeps the two copies in sync.

### 5.2 Subject instances

```sql
CREATE TABLE malu$subject (
    subject_id        uuid PRIMARY KEY REFERENCES malu$governed_object(object_id),
    subject_type_id   int  NOT NULL REFERENCES malu$subject_type,
    owner_schema      name NOT NULL DEFAULT current_schema(),
    canonical_name    text NOT NULL,
    aliases           text[] NOT NULL DEFAULT '{}',
    external_id       text,
    valid_time        tstzrange NOT NULL DEFAULT tstzrange(now(), null, '[)'),
    transaction_time  tstzrange NOT NULL DEFAULT tstzrange(now(), null, '[)'),
    lifecycle_state   text NOT NULL DEFAULT 'current',
    security_label    text NOT NULL,
    partition_id      int,
    derivation_id     uuid NOT NULL,
    EXCLUDE USING gist (owner_schema   WITH =,
                        subject_type_id WITH =,
                        canonical_name  WITH =,
                        valid_time      WITH &&)
);
CREATE INDEX malu$subject_aliases_gin ON malu$subject USING gin (aliases);
CREATE INDEX malu$subject_name_trgm   ON malu$subject USING gin (canonical_name gin_trgm_ops);
CREATE INDEX malu$subject_valid_time  ON malu$subject USING gist (valid_time);
```

### 5.3 Memory

```sql
CREATE TABLE malu$memory (
    memory_id          uuid PRIMARY KEY REFERENCES malu$governed_object(object_id),
    owner_schema       name NOT NULL DEFAULT current_schema(),
    primary_subject_id uuid NOT NULL REFERENCES malu$subject(subject_id),
    verb_type_id       int  NOT NULL REFERENCES malu$verb_type,
    summary            text NOT NULL,
    payload            jsonb NOT NULL DEFAULT '{}',
    embedding          vector,
    embedded_text      text,
    embedding_model_id int  REFERENCES malu$model_registry,
    event_time         timestamptz,
    valid_time         tstzrange NOT NULL DEFAULT tstzrange(now(), null, '[)'),
    transaction_time   tstzrange NOT NULL DEFAULT tstzrange(now(), null, '[)'),
    source_time        timestamptz,
    verification_time  timestamptz,
    stale_after        timestamptz,
    confidence_score   numeric(5,4) CHECK (confidence_score BETWEEN 0 AND 1),
    precision_score    numeric(5,4) CHECK (precision_score  BETWEEN 0 AND 1),
    lifecycle_state    text NOT NULL DEFAULT 'current'
        CHECK (lifecycle_state IN
        ('current','historical','stale','superseded','contradicted','consolidated','decayed','archived','retired')),
    security_label     text NOT NULL,
    partition_id       int,
    derivation_id      uuid NOT NULL
);

CREATE INDEX malu$memory_subj_verb     ON malu$memory (primary_subject_id, verb_type_id);
CREATE INDEX malu$memory_verb          ON malu$memory (verb_type_id);
CREATE INDEX malu$memory_event_time    ON malu$memory USING brin (event_time);
CREATE INDEX malu$memory_valid_time    ON malu$memory USING gist (valid_time);
CREATE INDEX malu$memory_xact_time     ON malu$memory USING gist (transaction_time);
CREATE INDEX malu$memory_payload       ON malu$memory USING gin (payload jsonb_path_ops);
CREATE INDEX malu$memory_summary_fts   ON malu$memory USING gin (to_tsvector('english', summary));
CREATE INDEX malu$memory_current       ON malu$memory (owner_schema, primary_subject_id, verb_type_id)
    WHERE lifecycle_state = 'current';
-- HNSW index per embedding_model_id will be created when the embedding column has a fixed dim per model;
-- defer until the model registry is populated and partitioning strategy is decided.
```

`embedding` is declared `vector` (no fixed dim). Per-model HNSW indexes attach later when each model's dim is registered.

### 5.4 Predicate values (normalized)

```sql
CREATE TABLE malu$memory_predicate_value (
    memory_id           uuid NOT NULL REFERENCES malu$memory ON DELETE CASCADE,
    predicate_type_id   int  NOT NULL REFERENCES malu$predicate_type,
    ordinality          int  NOT NULL DEFAULT 1,
    owner_schema        name NOT NULL DEFAULT current_schema(),
    value_text          text,
    value_object_id     uuid REFERENCES malu$governed_object(object_id),
    value_timestamp     timestamptz,
    value_range         tstzrange,
    value_numeric       numeric,
    value_json          jsonb,
    PRIMARY KEY (memory_id, predicate_type_id, ordinality)
);
CREATE INDEX malu$mpv_text ON malu$memory_predicate_value (predicate_type_id, value_text)
    WHERE value_text IS NOT NULL;
CREATE INDEX malu$mpv_obj  ON malu$memory_predicate_value (predicate_type_id, value_object_id)
    WHERE value_object_id IS NOT NULL;
```

### 5.5 Memory Detail Object (recursive)

```sql
CREATE TABLE malu$memory_detail_object (
    detail_id           uuid PRIMARY KEY REFERENCES malu$governed_object(object_id),
    owner_schema        name NOT NULL DEFAULT current_schema(),
    parent_memory_id    uuid REFERENCES malu$memory(memory_id),
    parent_detail_id    uuid REFERENCES malu$memory_detail_object(detail_id),
    CHECK ((parent_memory_id IS NULL) <> (parent_detail_id IS NULL)),
    ordinality          int NOT NULL,
    summary             text NOT NULL,
    payload             jsonb NOT NULL DEFAULT '{}',
    embedding           vector,
    valid_time          tstzrange NOT NULL DEFAULT tstzrange(now(), null, '[)'),
    transaction_time    tstzrange NOT NULL DEFAULT tstzrange(now(), null, '[)'),
    lifecycle_state     text NOT NULL DEFAULT 'current',
    security_label      text NOT NULL,
    derivation_id       uuid NOT NULL
);
CREATE INDEX malu$mdo_parent_memory ON malu$memory_detail_object (parent_memory_id, ordinality);
CREATE INDEX malu$mdo_parent_detail ON malu$memory_detail_object (parent_detail_id, ordinality);
```

Reuse across memories is via `malu$relationship_edge` (`has_detail`, `contains`), not row duplication.

### 5.6 Relationship edges

```sql
CREATE TABLE malu$relationship_edge (
    edge_id              uuid PRIMARY KEY REFERENCES malu$governed_object(object_id),
    owner_schema         name NOT NULL DEFAULT current_schema(),
    from_object_id       uuid NOT NULL REFERENCES malu$governed_object,
    to_object_id         uuid NOT NULL REFERENCES malu$governed_object,
    relationship_type_id int  NOT NULL REFERENCES malu$relationship_type,
    causal_mechanism     text,
    causal_status        text CHECK (causal_status IN ('asserted','inferred','disputed','verified')),
    confidence_score     numeric(5,4),
    valid_time           tstzrange NOT NULL DEFAULT tstzrange(now(), null, '[)'),
    transaction_time     tstzrange NOT NULL DEFAULT tstzrange(now(), null, '[)'),
    lifecycle_state      text NOT NULL DEFAULT 'current',
    derivation_id        uuid NOT NULL,
    EXCLUDE USING gist (
        from_object_id       WITH =,
        to_object_id         WITH =,
        relationship_type_id WITH =,
        valid_time           WITH &&
    )
);
CREATE INDEX malu$edge_from       ON malu$relationship_edge (from_object_id, relationship_type_id);
CREATE INDEX malu$edge_to         ON malu$relationship_edge (to_object_id,   relationship_type_id);
CREATE INDEX malu$edge_valid_time ON malu$relationship_edge USING gist (valid_time);
```

A cross-tenant edge is owned by the recording schema; visibility on the other side requires `malu$object_grant` entries on both endpoints (see §7).

## 6. Views — three access tiers

For each Tier-B base table:

```sql
CREATE VIEW malu_user_memory
WITH (security_invoker = true, check_option = local) AS
SELECT *
FROM   malu$memory
WHERE  owner_schema = current_schema();

CREATE VIEW malu_all_memory
WITH (security_invoker = true) AS
SELECT m.*
FROM   malu$memory m
WHERE  m.lifecycle_state = 'current'
  AND  now() <@ m.valid_time
  AND  ( m.owner_schema IN
            (SELECT schema_name FROM malu$tenant_member WHERE role_name = current_user)
        OR EXISTS (
            SELECT 1 FROM malu$object_grant g
            WHERE  g.object_id    = m.memory_id
              AND  g.grantee_role = current_user
              AND  g.privilege    = 'SELECT'
              AND  now() <@ g.valid_time) );

CREATE VIEW malu_dba_memory
WITH (security_invoker = true) AS
SELECT * FROM malu$memory;
```

For each Tier-A base table (system tables): only `malu_all_<x>` (read) and `malu_dba_<x>` (DML); no `malu_user_<x>`.

`MALU_USER_<x>` is simply-updatable: tenants get full CRUD without any DDL grants on base tables. `check_option = local` prevents UPDATE/INSERT from smuggling rows into other tenants.

## 7. Roles, grants, and the row-grant table

```sql
CREATE ROLE malu_user  NOINHERIT;
CREATE ROLE malu_admin INHERIT IN ROLE malu_user;
CREATE ROLE malu_dba   BYPASSRLS;

REVOKE ALL ON malu$memory FROM PUBLIC;
GRANT SELECT, INSERT, UPDATE, DELETE ON malu_user_memory TO malu_user;
GRANT SELECT                          ON malu_all_memory  TO malu_user;
GRANT SELECT, INSERT, UPDATE, DELETE ON malu_dba_memory   TO malu_dba;

CREATE TABLE malu$object_grant (
    object_id     uuid NOT NULL REFERENCES malu$governed_object,
    grantee_role  name NOT NULL,
    privilege     text NOT NULL CHECK (privilege IN ('SELECT','UPDATE','DELETE')),
    granted_by    name NOT NULL DEFAULT current_user,
    valid_time    tstzrange NOT NULL DEFAULT tstzrange(now(), null, '[)'),
    PRIMARY KEY (object_id, grantee_role, privilege, valid_time)
);
```

DDL on `malu$<x>` is reserved to the extension owner role; tenants and `malu_dba` cannot `ALTER TABLE`, `DROP TABLE`, or `CREATE INDEX` directly. Schema evolution happens through versioned `maludb_core--X.Y--X.Z.sql` upgrade scripts run during `ALTER EXTENSION maludb_core UPDATE`.

## 8. Authorization-aware retrieval

`requirements.md` §4.5 demands the auth check at three points: planning, candidate expansion, result assembly. The `MALU_*` views provide the **assembly-time** filter. Planning and expansion will live in the retrieval planner (Stage 4). To get defense-in-depth, enable PG row-level security on the base tables alongside the views, with policies that mirror the `MALU_ALL_<x>` filter, so any path that bypasses the views (planner internal queries, vector-only searches) still gets row-filtered.

## 9. Bitemporal supersession

Per `requirements.md` §3.4, corrections never overwrite — they close the prior `valid_time_end`, open a new version, and create a `supersedes` edge. The Temporal Supersession Engine (Stage 3) owns this flow; application code must call its API rather than directly mutating temporal columns. The `EXCLUDE USING gist` on `malu$relationship_edge` and `malu$subject` is what enforces no two simultaneous live versions of the same logical thing.

## 10. Out of scope here, but follows the same pattern

These will be added in Stage 2 / Stage 3 with the same shape (FK to `malu$governed_object`, denormalized `owner_schema`, three-tier views, bitemporal + lifecycle + derivation columns):

`malu$source_package`, `malu$claim`, `malu$fact`, `malu$episode_object`, `malu$workflow_trace`, `malu$generalized_workflow`, `malu$procedural_memory_object`, `malu$skill_package`, `malu$derivation_ledger`, `malu$maut_score` (per-category subscores + weights + evaluator per `requirements.md` §3.3).

## 11. Open items

- **Per-row vs per-table grants**: `malu$object_grant` provides per-row sharing; native PG grants are table-only. Both are present (defense-in-depth), but we may want a stored-procedure surface that wraps `INSERT INTO malu$object_grant` so tenants don't see the table directly.
- **Embedding lifecycle**: `malu$memory.embedding` has no fixed dim. Strategy options: one HNSW index per model (per-model partial indexes), or one column per model (heavier but simpler indexing). Decide alongside `malu$model_registry` rollout.
- **Partitioning**: `malu$memory` and `malu$relationship_edge` will need declarative partitioning on `event_time` or `partition_id` once volume justifies it. `pg_partman` is in the install bundle.
- **Causal edges**: §3.5 of the white paper expects causal-mechanism, evidence, and counterfactual metadata. `malu$relationship_edge` carries the basics; the full causal-edge schema may want its own subtable.
- **System-table writes by `malu_dba`**: pragmatic per the locked decisions, but every such DML should land an audit row. Decide where that audit lives — probably a Stage-2 `malu$audit_event` table that `pgaudit` complements rather than replaces.
