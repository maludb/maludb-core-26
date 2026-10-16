# Schema Memory Enablement Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build opt-in schema memory enablement so a normal PostgreSQL schema can expose tenant-local MALUDB memory, ingestion, document, embedding, AI-object, and memory-pool surfaces backed by shared `maludb_core` storage.

**Architecture:** Add a new `0.71.0 -> 0.72.0` extension migration that introduces schema enablement metadata, owner-schema fixes, raw/document/pool support tables, and `enable_memory_schema(name DEFAULT current_schema())`. The enablement function creates schema-local views and helper wrappers that filter shared core tables by the enabled schema. Regression tests prove opt-in behavior, tenant isolation, document/raw ingestion workflows, vector search by subject/verb/pool, and memory pool scoping.

**Tech Stack:** PostgreSQL extension SQL migrations, PL/pgSQL, pg_regress SQL tests, Makefile PGXS extension packaging, shell docs/scripts, PHP/Python/Node/C client search-path updates.

---

## File Structure

- Create: `sql/extension/maludb_core--0.71.0--0.72.0.sql`  
  Adds the new extension migration: version bump, metadata tables, owner-schema columns/policies, raw/document/tag tables, pool extensions, schema-enable function, facade DDL generator, and helper search/upload APIs.

- Modify: `sql/extension/maludb_core--0.72.0.sql`  
  Generated final install snapshot after implementation. Build this by appending the new migration to the previous snapshot using the repository's established snapshot style.

- Modify: `maludb_core.control`  
  Bumps `default_version` from `0.71.0` to `0.72.0`.

- Modify: `Makefile`  
  Adds the new migration to `DATA`, changes the snapshot file from `0.71.0.sql` to `0.72.0.sql`, and appends new regression tests to `REGRESS`.

- Create: `sql/schema_memory_enablement.sql`  
  Regression test for explicit opt-in schema enablement, facade view creation, idempotency, basic DML through schema-local views, and no automatic schema modification.

- Create: `expected/schema_memory_enablement.out`  
  Expected pg_regress output for schema enablement.

- Create: `sql/schema_memory_ingestion.sql`  
  Regression test for raw ingest, unapplied ingest, document upload, document tags, suggested tags, and extraction state changes.

- Create: `expected/schema_memory_ingestion.out`  
  Expected pg_regress output for ingestion/document behavior.

- Create: `sql/schema_memory_pool_search.sql`  
  Regression test for memory pool access, pool members, pool-scoped vector search, and fallback refusal.

- Create: `expected/schema_memory_pool_search.out`  
  Expected pg_regress output for pool search behavior.

- Create: `sql/enable-memory-schema.sql`  
  Operator wrapper script that calls `maludb_core.enable_memory_schema(:'schema')`.

- Modify: `docs/user-manual.md`, `docs/admin-guide.md`, `docs/getting-started.md`, `README.md`  
  Documents schema enablement, search path, document/raw ingest, vector subject/verb search, and memory pools.

- Modify: `drivers/php/src/Client.php`, `drivers/python/src/maludb/client.py`, `drivers/nodejs/src/client.ts`, `drivers/c/src/maludb.c`, `cli/maludb/src/maludb_cli/db.py`  
  Adds tenant schema/search-path support without breaking default system behavior.

---

### Task 1: Extension Version Scaffold

**Files:**
- Create: `sql/extension/maludb_core--0.71.0--0.72.0.sql`
- Modify: `maludb_core.control`
- Modify: `Makefile`

- [ ] **Step 1: Write the migration scaffold**

Create `sql/extension/maludb_core--0.71.0--0.72.0.sql` with this initial content:

```sql
\echo Use "ALTER EXTENSION maludb_core UPDATE TO '0.72.0'" to load this file. \quit

-- =====================================================================
-- maludb_core 0.71.0 -> 0.72.0
--
-- Schema memory enablement:
--   * opt-in schema-local MALUDB facade generation
--   * owner_schema audit fixes for schema-visible objects
--   * document/source tagging and raw ingestion inbox
--   * subject type and subject/verb organization
--   * pool-scoped retrieval surfaces
-- =====================================================================

CREATE OR REPLACE FUNCTION maludb_core_version() RETURNS text
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$ SELECT '0.72.0'::text $body$;
```

- [ ] **Step 2: Update control default version**

Modify `maludb_core.control`:

```diff
-default_version = '0.71.0'
+default_version = '0.72.0'
```

- [ ] **Step 3: Update Makefile DATA**

Modify `Makefile` so `DATA` includes the new migration and new snapshot:

```diff
-              sql/extension/maludb_core--0.70.0--0.71.0.sql \
-              sql/extension/maludb_core--0.71.0.sql
+              sql/extension/maludb_core--0.70.0--0.71.0.sql \
+              sql/extension/maludb_core--0.71.0--0.72.0.sql \
+              sql/extension/maludb_core--0.72.0.sql
```

- [ ] **Step 4: Run syntax checks on touched SQL**

Run:

```bash
make clean
make PG_CONFIG=/usr/lib/postgresql/17/bin/pg_config
```

Expected: compile succeeds and PGXS packages the new SQL migration path.

- [ ] **Step 5: Commit scaffold**

```bash
git add Makefile maludb_core.control sql/extension/maludb_core--0.71.0--0.72.0.sql
git commit -m "feat: scaffold schema memory enablement migration"
```

---

### Task 2: Failing Schema Enablement Regression Test

**Files:**
- Create: `sql/schema_memory_enablement.sql`
- Create: `expected/schema_memory_enablement.out`
- Modify: `Makefile`

- [ ] **Step 1: Add the failing regression test**

Create `sql/schema_memory_enablement.sql`:

```sql
\set ECHO all
SET search_path TO maludb_core, public;
SET client_min_messages = NOTICE;

DROP ROLE IF EXISTS sme_user_a;
DROP ROLE IF EXISTS sme_user_b;
DROP SCHEMA IF EXISTS sme_a CASCADE;
DROP SCHEMA IF EXISTS sme_b CASCADE;

CREATE ROLE sme_user_a NOLOGIN;
CREATE ROLE sme_user_b NOLOGIN;
GRANT maludb_memory_executor TO sme_user_a, sme_user_b;
GRANT USAGE ON SCHEMA maludb_core TO sme_user_a, sme_user_b;

CREATE SCHEMA sme_a AUTHORIZATION sme_user_a;
CREATE SCHEMA sme_b AUTHORIZATION sme_user_b;

SELECT count(*) AS a_pre_enable_objects
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'sme_a'
  AND c.relname LIKE 'maludb_%';

SET ROLE sme_user_a;
SET search_path TO sme_a, maludb_core, public;

SELECT maludb_core.enable_memory_schema() IS NOT NULL AS enable_returns_row;
SELECT maludb_core.enable_memory_schema() IS NOT NULL AS enable_is_idempotent;

SELECT bool_and(c.relname IS NOT NULL) AS core_facades_created
FROM unnest(ARRAY[
    'maludb_subject',
    'maludb_verb',
    'maludb_subject_verb',
    'maludb_claim',
    'maludb_fact',
    'maludb_memory',
    'maludb_source_package',
    'maludb_document',
    'maludb_raw_ingest',
    'maludb_memory_pool'
]) AS expected(relname)
LEFT JOIN pg_class c
       ON c.relname = expected.relname
LEFT JOIN pg_namespace n
       ON n.oid = c.relnamespace
      AND n.nspname = 'sme_a';

INSERT INTO maludb_subject(subject_type, canonical_name, aliases)
VALUES ('project', 'schema memory enablement', ARRAY['sme'])
RETURNING subject_type, canonical_name;

SELECT owner_schema, subject_type, canonical_name
FROM maludb_core.malu$svpor_subject
WHERE canonical_name = 'schema memory enablement';

INSERT INTO maludb_verb(canonical_name, aliases)
VALUES ('documents', ARRAY['doc'])
RETURNING canonical_name;

INSERT INTO maludb_subject_verb(namespace, subject_name, verb_name, embedding_dim, embedding_model)
VALUES ('default', 'schema memory enablement', 'documents', 4, 'sme-test-4d')
RETURNING namespace, subject_name, verb_name, embedding_dim;

SELECT owner_schema, namespace, vector_count
FROM maludb_core.malu$vector_compartment
WHERE namespace = 'default'
  AND owner_schema = 'sme_a';

RESET ROLE;
SET ROLE sme_user_b;
SET search_path TO sme_b, maludb_core, public;

SELECT count(*) AS b_pre_enable_subject_count
FROM maludb_core.malu$svpor_subject
WHERE canonical_name = 'schema memory enablement';

RESET ROLE;
SET search_path TO maludb_core, public;

DROP SCHEMA sme_a CASCADE;
DROP SCHEMA sme_b CASCADE;
DROP ROLE sme_user_a;
DROP ROLE sme_user_b;
```

- [ ] **Step 2: Add initial expected output**

Create `expected/schema_memory_enablement.out` by running pg_regress after implementation. For the failing-test step, create a minimal file with the command echo only so the test is present in git:

```text
\set ECHO all
SET search_path TO maludb_core, public;
```

- [ ] **Step 3: Add the test to REGRESS**

Modify `Makefile` and append `schema_memory_enablement` to the `REGRESS` list after `chat_index_append`.

- [ ] **Step 4: Run the new regression test and verify it fails**

Run:

```bash
make installcheck PG_CONFIG=/usr/lib/postgresql/17/bin/pg_config REGRESS=schema_memory_enablement
```

Expected: FAIL with an error containing `function maludb_core.enable_memory_schema() does not exist`.

- [ ] **Step 5: Commit the failing test**

```bash
git add Makefile sql/schema_memory_enablement.sql expected/schema_memory_enablement.out
git commit -m "test: cover opt-in schema memory enablement"
```

---

### Task 3: Enablement Metadata And Managed Object Registry

**Files:**
- Modify: `sql/extension/maludb_core--0.71.0--0.72.0.sql`
- Test: `sql/schema_memory_enablement.sql`

- [ ] **Step 1: Add metadata tables to the migration**

Append this SQL after the version function:

```sql
CREATE TABLE malu$enabled_schema (
    schema_name        name PRIMARY KEY,
    enabled_version    text NOT NULL,
    enabled_at         timestamptz NOT NULL DEFAULT now(),
    enabled_by         name NOT NULL DEFAULT current_user,
    last_refreshed_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE malu$enabled_schema_object (
    schema_name   name NOT NULL REFERENCES malu$enabled_schema(schema_name) ON DELETE CASCADE,
    object_name   name NOT NULL,
    object_kind   text NOT NULL CHECK (object_kind IN ('view','function','trigger')),
    object_purpose text NOT NULL,
    created_at    timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (schema_name, object_name, object_kind)
);

GRANT SELECT ON malu$enabled_schema, malu$enabled_schema_object TO
    maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;
```

- [ ] **Step 2: Add identifier and privilege helpers**

Append:

```sql
CREATE FUNCTION _memory_schema_assert_manageable(p_schema name) RETURNS void
LANGUAGE plpgsql
AS $body$
DECLARE
    v_owner oid;
BEGIN
    IF p_schema IS NULL THEN
        RAISE EXCEPTION 'enable_memory_schema: schema is required'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;
    IF p_schema IN ('pg_catalog','information_schema','maludb_core','mc2db') OR p_schema LIKE 'pg_%' THEN
        RAISE EXCEPTION 'enable_memory_schema: refusing system schema %', p_schema
            USING ERRCODE = 'invalid_parameter_value';
    END IF;
    SELECT nspowner INTO v_owner
      FROM pg_catalog.pg_namespace
     WHERE nspname = p_schema;
    IF v_owner IS NULL THEN
        RAISE EXCEPTION 'enable_memory_schema: schema % does not exist', p_schema
            USING ERRCODE = 'invalid_schema_name';
    END IF;
    IF NOT has_schema_privilege(session_user, p_schema, 'CREATE') THEN
        RAISE EXCEPTION 'enable_memory_schema: % lacks CREATE on schema %', session_user, p_schema
            USING ERRCODE = 'insufficient_privilege';
    END IF;
END;
$body$;

CREATE FUNCTION _memory_schema_record_object(
    p_schema name,
    p_object name,
    p_kind text,
    p_purpose text
) RETURNS void
LANGUAGE sql
AS $body$
    INSERT INTO malu$enabled_schema_object(schema_name, object_name, object_kind, object_purpose)
    VALUES (p_schema, p_object, p_kind, p_purpose)
    ON CONFLICT (schema_name, object_name, object_kind)
    DO UPDATE SET object_purpose = EXCLUDED.object_purpose;
$body$;
```

- [ ] **Step 3: Add the first enablement function stub**

Append:

```sql
CREATE FUNCTION enable_memory_schema(p_schema name DEFAULT current_schema())
RETURNS TABLE(schema_name name, enabled_version text, object_count integer)
LANGUAGE plpgsql
AS $body$
BEGIN
    PERFORM _memory_schema_assert_manageable(p_schema);

    INSERT INTO malu$enabled_schema(schema_name, enabled_version)
    VALUES (p_schema, '0.72.0')
    ON CONFLICT (schema_name) DO UPDATE
       SET enabled_version   = EXCLUDED.enabled_version,
           last_refreshed_at = now();

    schema_name := p_schema;
    enabled_version := '0.72.0';
    object_count := 0;
    RETURN NEXT;
END;
$body$;

GRANT EXECUTE ON FUNCTION enable_memory_schema(name) TO maludb_memory_admin, maludb_memory_executor;
```

- [ ] **Step 4: Run the schema enablement test**

Run:

```bash
make installcheck PG_CONFIG=/usr/lib/postgresql/17/bin/pg_config REGRESS=schema_memory_enablement
```

Expected: FAIL because facade objects such as `maludb_subject` do not exist.

- [ ] **Step 5: Commit metadata foundation**

```bash
git add sql/extension/maludb_core--0.71.0--0.72.0.sql
git commit -m "feat: add schema memory enablement metadata"
```

---

### Task 4: Subject, Verb, And Compartment Facade

**Files:**
- Modify: `sql/extension/maludb_core--0.71.0--0.72.0.sql`
- Test: `sql/schema_memory_enablement.sql`

- [ ] **Step 1: Add `subject_type` to the SVPOR subject registry**

Append before the enablement function:

```sql
ALTER TABLE malu$svpor_subject
    ADD COLUMN subject_type text NOT NULL DEFAULT 'concept';

CREATE INDEX malu$svpor_subject_type_idx
    ON malu$svpor_subject(owner_schema, subject_type, canonical_name);

DROP FUNCTION register_svpor_subject(text, text[], text);

CREATE FUNCTION register_svpor_subject(
    p_canonical_name text,
    p_aliases        text[] DEFAULT ARRAY[]::text[],
    p_description    text   DEFAULT NULL,
    p_subject_type   text   DEFAULT 'concept'
) RETURNS bigint
LANGUAGE plpgsql
AS $body$
DECLARE v_id bigint;
BEGIN
    INSERT INTO malu$svpor_subject (canonical_name, aliases, description, subject_type)
    VALUES (p_canonical_name, COALESCE(p_aliases, ARRAY[]::text[]), p_description, COALESCE(p_subject_type, 'concept'))
    ON CONFLICT (owner_schema, canonical_name) DO UPDATE
        SET aliases      = (SELECT array_agg(DISTINCT a)
                            FROM unnest(malu$svpor_subject.aliases || COALESCE(EXCLUDED.aliases, ARRAY[]::text[])) AS a),
            description  = COALESCE(EXCLUDED.description, malu$svpor_subject.description),
            subject_type = COALESCE(EXCLUDED.subject_type, malu$svpor_subject.subject_type)
    RETURNING subject_id INTO v_id;
    RETURN v_id;
END;
$body$;

GRANT EXECUTE ON FUNCTION register_svpor_subject(text, text[], text, text)
TO maludb_memory_admin, maludb_memory_executor;
```

- [ ] **Step 2: Add facade DDL helper for subject/verb views**

Append before `enable_memory_schema`:

```sql
CREATE FUNCTION _enable_memory_schema_subject_facade(p_schema name) RETURNS integer
LANGUAGE plpgsql
AS $body$
DECLARE v_count integer := 0;
BEGIN
    EXECUTE format('CREATE OR REPLACE VIEW %I.maludb_subject WITH (security_invoker = true) AS
        SELECT subject_id, subject_type, canonical_name, aliases, description, created_at
          FROM maludb_core.malu$svpor_subject
         WHERE owner_schema = %L
        WITH LOCAL CHECK OPTION', p_schema, p_schema);
    PERFORM _memory_schema_record_object(p_schema, 'maludb_subject', 'view', 'Schema-local subject registry');
    v_count := v_count + 1;

    EXECUTE format('CREATE OR REPLACE VIEW %I.maludb_verb WITH (security_invoker = true) AS
        SELECT verb_id, canonical_name, aliases, description, created_at
          FROM maludb_core.malu$svpor_verb
         WHERE owner_schema = %L
        WITH LOCAL CHECK OPTION', p_schema, p_schema);
    PERFORM _memory_schema_record_object(p_schema, 'maludb_verb', 'view', 'Schema-local verb registry');
    v_count := v_count + 1;

    EXECUTE format('CREATE OR REPLACE VIEW %I.maludb_subject_verb WITH (security_invoker = true) AS
        SELECT c.compartment_id, c.namespace, s.subject_name, v.verb_name,
               c.embedding_dim, c.embedding_model, c.distance_metric,
               c.vector_count, c.search_mode, c.ann_index_status, c.created_at, c.updated_at
          FROM maludb_core.malu$vector_compartment c
          JOIN maludb_core.malu$vector_subject s ON s.subject_id = c.subject_id
          JOIN maludb_core.malu$vector_verb v ON v.verb_id = c.verb_id
         WHERE c.owner_schema = %L', p_schema, p_schema);
    PERFORM _memory_schema_record_object(p_schema, 'maludb_subject_verb', 'view', 'Schema-local vector compartment registry');
    v_count := v_count + 1;

    EXECUTE format('CREATE OR REPLACE FUNCTION %I.maludb_subject_verb_create(
        p_namespace text,
        p_subject_name text,
        p_verb_name text,
        p_embedding_dim integer,
        p_embedding_model text,
        p_distance_metric text DEFAULT ''cosine''
    ) RETURNS bigint
    LANGUAGE sql
    AS $fn$
        SELECT maludb_core.register_vector_compartment(
            p_namespace, p_subject_name, p_verb_name,
            p_embedding_dim, p_embedding_model, p_distance_metric)
    $fn$', p_schema);
    PERFORM _memory_schema_record_object(p_schema, 'maludb_subject_verb_create', 'function', 'Schema-local vector compartment creator');
    v_count := v_count + 1;

    EXECUTE format('CREATE OR REPLACE VIEW %I.maludb_project WITH (security_invoker = true) AS
        SELECT subject_id, canonical_name AS name, aliases, description, created_at
          FROM maludb_core.malu$svpor_subject
         WHERE owner_schema = %L AND subject_type = ''project''
        WITH LOCAL CHECK OPTION', p_schema, p_schema);
    PERFORM _memory_schema_record_object(p_schema, 'maludb_project', 'view', 'Project subject convenience view');
    v_count := v_count + 1;

    EXECUTE format('CREATE OR REPLACE VIEW %I.maludb_stakeholder WITH (security_invoker = true) AS
        SELECT subject_id, canonical_name AS name, aliases, description, created_at
          FROM maludb_core.malu$svpor_subject
         WHERE owner_schema = %L AND subject_type = ''stakeholder''
        WITH LOCAL CHECK OPTION', p_schema, p_schema);
    PERFORM _memory_schema_record_object(p_schema, 'maludb_stakeholder', 'view', 'Stakeholder subject convenience view');
    v_count := v_count + 1;

    RETURN v_count;
END;
$body$;
```

- [ ] **Step 3: Call subject facade helper from enablement**

Change the body of `enable_memory_schema`:

```sql
DECLARE
    v_count integer := 0;
BEGIN
    PERFORM _memory_schema_assert_manageable(p_schema);

    INSERT INTO malu$enabled_schema(schema_name, enabled_version)
    VALUES (p_schema, '0.72.0')
    ON CONFLICT (schema_name) DO UPDATE
       SET enabled_version   = EXCLUDED.enabled_version,
           last_refreshed_at = now();

    v_count := v_count + _enable_memory_schema_subject_facade(p_schema);

    schema_name := p_schema;
    enabled_version := '0.72.0';
    object_count := v_count;
    RETURN NEXT;
END;
```

- [ ] **Step 4: Update test to use the creator function**

In `sql/schema_memory_enablement.sql`, replace direct insert into `maludb_subject_verb` with:

```sql
SELECT maludb_subject_verb_create(
    'default', 'schema memory enablement', 'documents', 4, 'sme-test-4d'
) IS NOT NULL AS subject_verb_created;
```

- [ ] **Step 5: Run the schema enablement test**

Run:

```bash
make installcheck PG_CONFIG=/usr/lib/postgresql/17/bin/pg_config REGRESS=schema_memory_enablement
```

Expected: FAIL because claim/fact/memory/source/document/raw/pool facades do not exist yet.

- [ ] **Step 6: Commit subject facade**

```bash
git add sql/extension/maludb_core--0.71.0--0.72.0.sql sql/schema_memory_enablement.sql
git commit -m "feat: add schema-local subject and vector compartment facade"
```

---

### Task 5: Core Memory Object Facade

**Files:**
- Modify: `sql/extension/maludb_core--0.71.0--0.72.0.sql`
- Test: `sql/schema_memory_enablement.sql`

- [ ] **Step 1: Add facade helper for core memory objects**

Append:

```sql
CREATE FUNCTION _enable_memory_schema_core_facade(p_schema name) RETURNS integer
LANGUAGE plpgsql
AS $body$
DECLARE v_count integer := 0;
BEGIN
    EXECUTE format('CREATE OR REPLACE VIEW %I.maludb_source_package WITH (security_invoker = true) AS
        SELECT source_package_id, source_type, content_text, content_jsonb, content_hash,
               content_size, media_type, origin_jsonb, captured_at, ingested_at,
               retention_class, sensitivity, created_at, updated_at
          FROM maludb_core.malu$source_package
         WHERE owner_schema = %L
        WITH LOCAL CHECK OPTION', p_schema, p_schema);
    PERFORM _memory_schema_record_object(p_schema, 'maludb_source_package', 'view', 'Schema-local source packages');
    v_count := v_count + 1;

    EXECUTE format('CREATE OR REPLACE VIEW %I.maludb_claim WITH (security_invoker = true) AS
        SELECT claim_id, subject, verb, predicate, object_value, relationship,
               statement_text, statement_jsonb, source_package_id, source_locator,
               asserted_at, retracted_at, retraction_reason, sensitivity, created_at
          FROM maludb_core.malu$claim
         WHERE owner_schema = %L
        WITH LOCAL CHECK OPTION', p_schema, p_schema);
    PERFORM _memory_schema_record_object(p_schema, 'maludb_claim', 'view', 'Schema-local claims');
    v_count := v_count + 1;

    EXECUTE format('CREATE OR REPLACE VIEW %I.maludb_fact WITH (security_invoker = true) AS
        SELECT fact_id, subject, verb, predicate, object_value, relationship,
               statement_text, statement_jsonb, verification_scope, verification_method,
               verified_at, sensitivity, lifecycle_state, created_at
          FROM maludb_core.malu$fact
         WHERE owner_schema = %L
        WITH LOCAL CHECK OPTION', p_schema, p_schema);
    PERFORM _memory_schema_record_object(p_schema, 'maludb_fact', 'view', 'Schema-local facts');
    v_count := v_count + 1;

    EXECUTE format('CREATE OR REPLACE VIEW %I.maludb_memory WITH (security_invoker = true) AS
        SELECT memory_id, memory_kind, title, summary, payload_jsonb,
               occurred_at, occurred_until, recorded_at, sensitivity,
               lifecycle_state, created_at, updated_at
          FROM maludb_core.malu$memory
         WHERE owner_schema = %L
        WITH LOCAL CHECK OPTION', p_schema, p_schema);
    PERFORM _memory_schema_record_object(p_schema, 'maludb_memory', 'view', 'Schema-local memories');
    v_count := v_count + 1;

    EXECUTE format('CREATE OR REPLACE VIEW %I.maludb_memory_detail WITH (security_invoker = true) AS
        SELECT mdo_id, parent_mdo_id, memory_id, episode_id, detail_kind,
               ordinal, title, body_text, body_jsonb, sensitivity, created_at
          FROM maludb_core.malu$memory_detail_object
         WHERE owner_schema = %L
        WITH LOCAL CHECK OPTION', p_schema, p_schema);
    PERFORM _memory_schema_record_object(p_schema, 'maludb_memory_detail', 'view', 'Schema-local memory details');
    v_count := v_count + 1;

    RETURN v_count;
END;
$body$;
```

- [ ] **Step 2: Call core facade helper from enablement**

Add:

```sql
v_count := v_count + _enable_memory_schema_core_facade(p_schema);
```

immediately after `_enable_memory_schema_subject_facade(p_schema)`.

- [ ] **Step 3: Add a DML assertion to the regression test**

In `sql/schema_memory_enablement.sql`, after subject-verb creation, add:

```sql
INSERT INTO maludb_memory(memory_kind, title, summary)
VALUES ('lesson', 'schema facade lesson', 'tenant-local views write owner_schema correctly')
RETURNING memory_kind, title;

SELECT owner_schema, title
FROM maludb_core.malu$memory
WHERE title = 'schema facade lesson';
```

- [ ] **Step 4: Run test**

Run:

```bash
make installcheck PG_CONFIG=/usr/lib/postgresql/17/bin/pg_config REGRESS=schema_memory_enablement
```

Expected: FAIL because document/raw/pool facades do not exist yet.

- [ ] **Step 5: Commit core facade**

```bash
git add sql/extension/maludb_core--0.71.0--0.72.0.sql sql/schema_memory_enablement.sql
git commit -m "feat: add schema-local core memory facade"
```

---

### Task 6: Raw Ingest And Document Tables

**Files:**
- Modify: `sql/extension/maludb_core--0.71.0--0.72.0.sql`
- Create: `sql/schema_memory_ingestion.sql`
- Create: `expected/schema_memory_ingestion.out`
- Modify: `Makefile`

- [ ] **Step 1: Add document and raw ingest tables**

Append before facade helpers:

```sql
CREATE TABLE malu$document (
    document_id       bigserial PRIMARY KEY,
    owner_schema      name NOT NULL DEFAULT current_schema(),
    source_package_id bigint REFERENCES malu$source_package(source_package_id) ON DELETE SET NULL,
    title             text NOT NULL,
    source_type       text NOT NULL,
    media_type        text,
    primary_project_id bigint REFERENCES malu$svpor_subject(subject_id) ON DELETE SET NULL,
    lifecycle_state   text NOT NULL DEFAULT 'active'
        CHECK (lifecycle_state IN ('active','processing','processed','archived','tombstoned')),
    metadata_jsonb    jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at        timestamptz NOT NULL DEFAULT now(),
    updated_at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX malu$document_owner_idx ON malu$document(owner_schema, created_at DESC);
CREATE INDEX malu$document_source_idx ON malu$document(source_package_id) WHERE source_package_id IS NOT NULL;

ALTER TABLE malu$document ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_owner ON malu$document
    USING (owner_schema = current_schema())
    WITH CHECK (owner_schema = current_schema());

CREATE TABLE malu$document_tag (
    tag_id          bigserial PRIMARY KEY,
    owner_schema    name NOT NULL DEFAULT current_schema(),
    document_id     bigint NOT NULL REFERENCES malu$document(document_id) ON DELETE CASCADE,
    tag_kind        text NOT NULL CHECK (tag_kind IN ('project','subject','verb','event','stakeholder','skill','workflow','freeform')),
    tag_value       text NOT NULL,
    tag_object_type text,
    tag_object_id   bigint,
    provenance      text NOT NULL DEFAULT 'provided'
        CHECK (provenance IN ('provided','suggested','accepted','rejected')),
    confidence      numeric(5,4) CHECK (confidence IS NULL OR confidence BETWEEN 0 AND 1),
    created_at      timestamptz NOT NULL DEFAULT now(),
    UNIQUE (document_id, tag_kind, tag_value, provenance)
);
CREATE INDEX malu$document_tag_lookup_idx ON malu$document_tag(owner_schema, tag_kind, tag_value);

ALTER TABLE malu$document_tag ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_owner ON malu$document_tag
    USING (owner_schema = current_schema())
    WITH CHECK (owner_schema = current_schema());

CREATE TABLE malu$raw_ingest (
    ingest_id        bigserial PRIMARY KEY,
    owner_schema     name NOT NULL DEFAULT current_schema(),
    source_type      text NOT NULL,
    source_name      text,
    payload_jsonb    jsonb,
    content_text     text,
    content_bytes    bytea,
    content_hash     text,
    state            text NOT NULL DEFAULT 'received'
        CHECK (state IN ('received','queued','processing','processed','partially_applied','applied','failed','ignored')),
    received_at      timestamptz NOT NULL DEFAULT now(),
    processed_at     timestamptz,
    last_error       text,
    context_jsonb    jsonb NOT NULL DEFAULT '{}'::jsonb,
    CHECK (payload_jsonb IS NOT NULL OR content_text IS NOT NULL OR content_bytes IS NOT NULL)
);
CREATE INDEX malu$raw_ingest_owner_state_idx ON malu$raw_ingest(owner_schema, state, received_at DESC);

ALTER TABLE malu$raw_ingest ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_owner ON malu$raw_ingest
    USING (owner_schema = current_schema())
    WITH CHECK (owner_schema = current_schema());

CREATE TABLE malu$ingest_extraction (
    extraction_id      bigserial PRIMARY KEY,
    owner_schema       name NOT NULL DEFAULT current_schema(),
    ingest_id          bigint NOT NULL REFERENCES malu$raw_ingest(ingest_id) ON DELETE CASCADE,
    derived_object_type text NOT NULL,
    derived_object_id   bigint,
    extraction_state    text NOT NULL DEFAULT 'suggested'
        CHECK (extraction_state IN ('suggested','accepted','rejected','applied')),
    confidence          numeric(5,4) CHECK (confidence IS NULL OR confidence BETWEEN 0 AND 1),
    payload_jsonb       jsonb,
    created_at          timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX malu$ingest_extraction_ingest_idx ON malu$ingest_extraction(ingest_id);

ALTER TABLE malu$ingest_extraction ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_owner ON malu$ingest_extraction
    USING (owner_schema = current_schema())
    WITH CHECK (owner_schema = current_schema());

GRANT SELECT, INSERT, UPDATE, DELETE ON
    malu$document, malu$document_tag, malu$raw_ingest, malu$ingest_extraction
TO maludb_memory_admin, maludb_memory_executor;
GRANT SELECT ON
    malu$document, malu$document_tag, malu$raw_ingest, malu$ingest_extraction
TO maludb_memory_auditor;
GRANT USAGE, SELECT ON SEQUENCE
    malu$document_document_id_seq,
    malu$document_tag_tag_id_seq,
    malu$raw_ingest_ingest_id_seq,
    malu$ingest_extraction_extraction_id_seq
TO maludb_memory_admin, maludb_memory_executor;
```

- [ ] **Step 2: Add document upload function**

Append:

```sql
CREATE FUNCTION upload_document(
    p_title        text,
    p_source_type  text,
    p_content_text text DEFAULT NULL,
    p_content_jsonb jsonb DEFAULT NULL,
    p_media_type   text DEFAULT NULL,
    p_projects     text[] DEFAULT ARRAY[]::text[],
    p_subjects     text[] DEFAULT ARRAY[]::text[],
    p_verbs        text[] DEFAULT ARRAY[]::text[],
    p_events       text[] DEFAULT ARRAY[]::text[],
    p_metadata_jsonb jsonb DEFAULT '{}'::jsonb
) RETURNS bigint
LANGUAGE plpgsql
AS $body$
DECLARE
    v_source_id bigint;
    v_doc_id bigint;
    v_tag text;
BEGIN
    IF p_title IS NULL OR p_title = '' THEN
        RAISE EXCEPTION 'upload_document: title is required' USING ERRCODE = 'invalid_parameter_value';
    END IF;
    v_source_id := register_source_package(
        p_source_type => COALESCE(p_source_type, 'document'),
        p_content_text => p_content_text,
        p_content_jsonb => p_content_jsonb,
        p_media_type => p_media_type);

    INSERT INTO malu$document(source_package_id, title, source_type, media_type, metadata_jsonb)
    VALUES (v_source_id, p_title, COALESCE(p_source_type, 'document'), p_media_type, COALESCE(p_metadata_jsonb, '{}'::jsonb))
    RETURNING document_id INTO v_doc_id;

    FOREACH v_tag IN ARRAY COALESCE(p_projects, ARRAY[]::text[]) LOOP
        INSERT INTO malu$document_tag(document_id, tag_kind, tag_value, provenance)
        VALUES (v_doc_id, 'project', v_tag, 'provided');
    END LOOP;
    FOREACH v_tag IN ARRAY COALESCE(p_subjects, ARRAY[]::text[]) LOOP
        INSERT INTO malu$document_tag(document_id, tag_kind, tag_value, provenance)
        VALUES (v_doc_id, 'subject', v_tag, 'provided');
    END LOOP;
    FOREACH v_tag IN ARRAY COALESCE(p_verbs, ARRAY[]::text[]) LOOP
        INSERT INTO malu$document_tag(document_id, tag_kind, tag_value, provenance)
        VALUES (v_doc_id, 'verb', v_tag, 'provided');
    END LOOP;
    FOREACH v_tag IN ARRAY COALESCE(p_events, ARRAY[]::text[]) LOOP
        INSERT INTO malu$document_tag(document_id, tag_kind, tag_value, provenance)
        VALUES (v_doc_id, 'event', v_tag, 'provided');
    END LOOP;

    RETURN v_doc_id;
END;
$body$;

GRANT EXECUTE ON FUNCTION upload_document(text, text, text, jsonb, text, text[], text[], text[], text[], jsonb)
TO maludb_memory_admin, maludb_memory_executor;
```

- [ ] **Step 3: Add document/raw facade helper**

Append:

```sql
CREATE FUNCTION _enable_memory_schema_ingest_facade(p_schema name) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO maludb_core, pg_temp
AS $body$
DECLARE
    v_count integer := 0;
BEGIN
    EXECUTE format('CREATE OR REPLACE VIEW %I.maludb_document WITH (security_invoker = true) AS
        SELECT document_id, source_package_id, title, source_type, media_type,
               lifecycle_state, created_at, updated_at, metadata_jsonb
          FROM maludb_core.malu$document
         WHERE owner_schema = %L
         WITH LOCAL CHECK OPTION', p_schema, p_schema);
    PERFORM _memory_schema_record_object(p_schema, 'maludb_document', 'view', 'Schema-local document registry');
    v_count := v_count + 1;

    EXECUTE format('CREATE OR REPLACE VIEW %I.maludb_document_tag WITH (security_invoker = true) AS
        SELECT tag_id, document_id, tag_kind, tag_value, provenance, confidence, metadata_jsonb, created_at
          FROM maludb_core.malu$document_tag
         WHERE owner_schema = %L
         WITH LOCAL CHECK OPTION', p_schema, p_schema);
    PERFORM _memory_schema_record_object(p_schema, 'maludb_document_tag', 'view', 'Schema-local document tags');
    v_count := v_count + 1;

    EXECUTE format('CREATE OR REPLACE VIEW %I.maludb_document_suggested_tag WITH (security_invoker = true) AS
        SELECT tag_id, document_id, tag_kind, tag_value, confidence, metadata_jsonb, created_at
          FROM maludb_core.malu$document_tag
         WHERE owner_schema = %L
           AND provenance = ''suggested''', p_schema, p_schema);
    PERFORM _memory_schema_record_object(p_schema, 'maludb_document_suggested_tag', 'view', 'Schema-local suggested document tags');
    v_count := v_count + 1;

    EXECUTE format('CREATE OR REPLACE VIEW %I.maludb_raw_ingest WITH (security_invoker = true) AS
        SELECT ingest_id, source_type, source_name, payload_jsonb, received_at,
               state, error_text, metadata_jsonb
          FROM maludb_core.malu$raw_ingest
         WHERE owner_schema = %L
         WITH LOCAL CHECK OPTION', p_schema, p_schema);
    PERFORM _memory_schema_record_object(p_schema, 'maludb_raw_ingest', 'view', 'Schema-local raw ingest inbox');
    v_count := v_count + 1;

    EXECUTE format('CREATE OR REPLACE VIEW %I.maludb_unapplied_ingest WITH (security_invoker = true) AS
        SELECT r.ingest_id, r.source_type, r.source_name, r.payload_jsonb,
               r.received_at, r.state, r.error_text, r.metadata_jsonb
          FROM maludb_core.malu$raw_ingest r
         WHERE r.owner_schema = %L
           AND r.state IN (''received'',''queued'',''processing'',''processed'',''partially_applied'',''failed'')
           AND NOT EXISTS (
               SELECT 1 FROM maludb_core.malu$ingest_extraction e
                WHERE e.ingest_id = r.ingest_id
                  AND e.extraction_state IN (''accepted'',''applied'')
           )', p_schema, p_schema);
    PERFORM _memory_schema_record_object(p_schema, 'maludb_unapplied_ingest', 'view', 'Schema-local unapplied raw ingest');
    v_count := v_count + 1;

    EXECUTE format('CREATE OR REPLACE FUNCTION %I.maludb_upload_document(
        p_title text,
        p_body text DEFAULT NULL,
        p_source_type text DEFAULT ''document'',
        p_body_jsonb jsonb DEFAULT NULL,
        p_media_type text DEFAULT NULL,
        p_projects text[] DEFAULT NULL,
        p_subjects text[] DEFAULT NULL,
        p_verbs text[] DEFAULT NULL,
        p_events text[] DEFAULT NULL,
        p_metadata_jsonb jsonb DEFAULT NULL
    ) RETURNS bigint
    LANGUAGE sql
    AS $fn$
        SELECT maludb_core.upload_document(
            p_title, p_body, p_source_type, p_body_jsonb, p_media_type,
            p_projects, p_subjects, p_verbs, p_events, p_metadata_jsonb)
    $fn$', p_schema);
    PERFORM _memory_schema_record_object(p_schema, 'maludb_upload_document', 'function', 'Schema-local document upload helper');
    v_count := v_count + 1;

    RETURN v_count;
END;
$body$;

GRANT EXECUTE ON FUNCTION _enable_memory_schema_ingest_facade(name) TO maludb_memory_admin;
```

- [ ] **Step 4: Call the helper from enablement**

Add:

```sql
v_count := v_count + _enable_memory_schema_ingest_facade(p_schema);
```

- [ ] **Step 5: Add ingestion regression test**

Create `sql/schema_memory_ingestion.sql`:

```sql
\set ECHO all
SET search_path TO maludb_core, public;
SET client_min_messages = NOTICE;

DROP ROLE IF EXISTS smi_user;
DROP SCHEMA IF EXISTS smi CASCADE;
CREATE ROLE smi_user NOLOGIN;
GRANT maludb_memory_executor TO smi_user;
GRANT USAGE ON SCHEMA maludb_core TO smi_user;
CREATE SCHEMA smi AUTHORIZATION smi_user;

SET ROLE smi_user;
SET search_path TO smi, maludb_core, public;
SELECT maludb_core.enable_memory_schema() IS NOT NULL AS enabled;

INSERT INTO maludb_raw_ingest(source_type, source_name, payload_jsonb)
VALUES ('prompt_session', 'codex', '{"prompt":"p","response":"r"}')
RETURNING source_type, source_name, state;

SELECT count(*) AS unapplied_count_before
FROM maludb_unapplied_ingest;

SELECT maludb_upload_document(
    p_title => 'Cutover notes',
    p_source_type => 'document',
    p_content_text => 'Cutover notes mention postgres_pool risk.',
    p_projects => ARRAY['zozocal migration'],
    p_subjects => ARRAY['postgres_pool'],
    p_verbs => ARRAY['risk'],
    p_events => ARRAY['cutover_planning']
) IS NOT NULL AS document_uploaded;

SELECT title, source_type
FROM maludb_document
WHERE title = 'Cutover notes';

SELECT tag_kind, tag_value, provenance
FROM maludb_document_tag
ORDER BY tag_kind, tag_value;

INSERT INTO maludb_document_tag(document_id, tag_kind, tag_value, provenance, confidence)
SELECT document_id, 'subject', 'api_gateway', 'suggested', 0.82
FROM maludb_document WHERE title = 'Cutover notes';

SELECT tag_kind, tag_value, confidence
FROM maludb_document_suggested_tag;

RESET ROLE;
DROP SCHEMA smi CASCADE;
DROP ROLE smi_user;
```

- [ ] **Step 6: Add test to Makefile and run**

Add `schema_memory_ingestion` after `schema_memory_enablement` in `REGRESS`, then run:

```bash
make installcheck PG_CONFIG=/usr/lib/postgresql/17/bin/pg_config REGRESS=schema_memory_ingestion
```

Expected: PASS after expected file is generated from actual output.

- [ ] **Step 7: Commit ingestion/document support**

```bash
git add Makefile sql/extension/maludb_core--0.71.0--0.72.0.sql sql/schema_memory_ingestion.sql expected/schema_memory_ingestion.out
git commit -m "feat: add raw ingest and document schema facade"
```

---

### Task 7: Memory Pool Tags, Access, And Facade

**Files:**
- Modify: `sql/extension/maludb_core--0.71.0--0.72.0.sql`
- Create: `sql/schema_memory_pool_search.sql`
- Create: `expected/schema_memory_pool_search.out`
- Modify: `Makefile`

- [ ] **Step 1: Extend pool member kinds and add pool tag/access tables**

Append:

```sql
ALTER TABLE malu$active_memory_pool_member
    DROP CONSTRAINT "malu$active_memory_pool_member_member_kind_check";

ALTER TABLE malu$active_memory_pool_member
    ADD CONSTRAINT "malu$active_memory_pool_member_member_kind_check"
    CHECK (member_kind IN
        ('observation','pending_claim','memory','fact','episode_object',
         'workflow_trace','skill','source_reference','project','subject',
         'verb','subject_verb','document','mcp_server','mcp_tool','raw_ingest'));

CREATE TABLE malu$active_memory_pool_tag (
    tag_id       bigserial PRIMARY KEY,
    owner_schema name NOT NULL DEFAULT current_schema(),
    pool_id      bigint NOT NULL REFERENCES malu$active_memory_pool(pool_id) ON DELETE CASCADE,
    tag_kind     text NOT NULL,
    tag_value    text NOT NULL,
    created_at   timestamptz NOT NULL DEFAULT now(),
    UNIQUE (pool_id, tag_kind, tag_value)
);
ALTER TABLE malu$active_memory_pool_tag ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_owner ON malu$active_memory_pool_tag
    USING (owner_schema = current_schema())
    WITH CHECK (owner_schema = current_schema());

CREATE TABLE malu$active_memory_pool_access (
    access_id       bigserial PRIMARY KEY,
    owner_schema    name NOT NULL DEFAULT current_schema(),
    pool_id         bigint NOT NULL REFERENCES malu$active_memory_pool(pool_id) ON DELETE CASCADE,
    grantee_role    name NOT NULL,
    access_level    text NOT NULL CHECK (access_level IN ('read','write','manage','execute')),
    granted_by      name NOT NULL DEFAULT current_user,
    granted_at      timestamptz NOT NULL DEFAULT now(),
    revoked_at      timestamptz,
    UNIQUE (pool_id, grantee_role, access_level)
);
ALTER TABLE malu$active_memory_pool_access ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_owner ON malu$active_memory_pool_access
    USING (owner_schema = current_schema())
    WITH CHECK (owner_schema = current_schema());

GRANT SELECT, INSERT, UPDATE, DELETE ON
    malu$active_memory_pool_tag, malu$active_memory_pool_access
TO maludb_memory_admin, maludb_memory_executor;
GRANT SELECT ON malu$active_memory_pool_tag, malu$active_memory_pool_access
TO maludb_memory_auditor;
GRANT USAGE, SELECT ON SEQUENCE
    malu$active_memory_pool_tag_tag_id_seq,
    malu$active_memory_pool_access_access_id_seq
TO maludb_memory_admin, maludb_memory_executor;
```

- [ ] **Step 2: Add pool facade helper**

Append `_enable_memory_schema_pool_facade(p_schema name)` that creates views:

```text
maludb_memory_pool
maludb_memory_pool_member
maludb_memory_pool_tag
maludb_memory_pool_access
maludb_pool_subject
maludb_pool_verb
maludb_pool_subject_verb
maludb_pool_skill
maludb_pool_document
maludb_pool_presence
```

The `maludb_pool_subject` view must select from pool members with:

```sql
WHERE m.owner_schema = p_schema
  AND m.member_kind = 'subject'
```

The `maludb_pool_document` view must join `malu$document`:

```sql
FROM maludb_core.malu$active_memory_pool_member m
JOIN maludb_core.malu$document d
  ON d.document_id = m.member_object_id
WHERE m.owner_schema = p_schema
  AND m.member_kind = 'document'
```

- [ ] **Step 3: Add pool name helper functions**

Append:

```sql
CREATE FUNCTION pool_add_named_member(
    p_pool_name text,
    p_member_kind text,
    p_member_name text,
    p_confidence numeric DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql
AS $body$
DECLARE
    v_pool_id bigint;
    v_object_id bigint;
    v_object_type text;
BEGIN
    SELECT pool_id INTO v_pool_id FROM malu$active_memory_pool WHERE pool_name = p_pool_name;
    IF v_pool_id IS NULL THEN
        RAISE EXCEPTION 'pool_add_named_member: pool % not found', p_pool_name
            USING ERRCODE = 'no_data_found';
    END IF;

    IF p_member_kind IN ('project','subject') THEN
        SELECT subject_id INTO v_object_id
          FROM malu$svpor_subject
         WHERE canonical_name = p_member_name
         ORDER BY (subject_type = p_member_kind) DESC
         LIMIT 1;
        v_object_type := 'subject';
    ELSIF p_member_kind = 'verb' THEN
        SELECT verb_id INTO v_object_id FROM malu$svpor_verb WHERE canonical_name = p_member_name LIMIT 1;
        v_object_type := 'verb';
    ELSIF p_member_kind = 'document' THEN
        SELECT document_id INTO v_object_id FROM malu$document WHERE title = p_member_name LIMIT 1;
        v_object_type := 'document';
    ELSIF p_member_kind = 'skill' THEN
        SELECT skill_id INTO v_object_id FROM malu$skill_package WHERE skill_name = p_member_name LIMIT 1;
        v_object_type := 'skill';
    ELSE
        RAISE EXCEPTION 'pool_add_named_member: unsupported named kind %', p_member_kind
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    IF v_object_id IS NULL THEN
        RAISE EXCEPTION 'pool_add_named_member: % named % not found', p_member_kind, p_member_name
            USING ERRCODE = 'no_data_found';
    END IF;

    RETURN pool_add_reference(v_pool_id, p_member_kind, v_object_type, v_object_id, p_confidence);
END;
$body$;

GRANT EXECUTE ON FUNCTION pool_add_named_member(text, text, text, numeric)
TO maludb_memory_admin, maludb_memory_executor;
```

- [ ] **Step 4: Add pool search function**

Append:

```sql
CREATE FUNCTION pool_search(
    p_pool_name text,
    p_query_text text DEFAULT NULL,
    p_limit integer DEFAULT 20,
    p_allow_fallback boolean DEFAULT false
) RETURNS TABLE (
    object_type text,
    object_id bigint,
    title_or_subject text,
    snippet text,
    rank real,
    source text
)
LANGUAGE plpgsql STABLE
AS $body$
DECLARE
    v_pool_id bigint;
BEGIN
    SELECT pool_id INTO v_pool_id
      FROM malu$active_memory_pool
     WHERE pool_name = p_pool_name
       AND lifecycle_state = 'active';
    IF v_pool_id IS NULL THEN
        RAISE EXCEPTION 'pool_search: active pool % not found', p_pool_name
            USING ERRCODE = 'no_data_found';
    END IF;

    IF p_query_text IS NULL OR btrim(p_query_text) = '' THEN
        RETURN QUERY
        SELECT m.member_object_type, m.member_object_id,
               COALESCE(m.member_kind, '?')::text,
               left(COALESCE(m.payload_jsonb::text, ''), 240)::text,
               COALESCE(m.confidence, 0)::real,
               'pool_member'::text
          FROM malu$active_memory_pool_member m
         WHERE m.pool_id = v_pool_id
         ORDER BY m.added_at DESC
         LIMIT GREATEST(p_limit, 1);
        RETURN;
    END IF;

    RETURN QUERY
    SELECT h.object_type, h.object_id, h.title_or_subject, h.snippet, h.rank, 'pool_text_search'::text
      FROM text_search(p_query_text, ARRAY['claim','fact','memory','episode_object'], p_limit) h
     WHERE EXISTS (
        SELECT 1
          FROM malu$active_memory_pool_member m
         WHERE m.pool_id = v_pool_id
           AND m.member_object_type = h.object_type
           AND m.member_object_id = h.object_id)
     ORDER BY h.rank DESC
     LIMIT GREATEST(p_limit, 1);

    IF NOT FOUND AND p_allow_fallback THEN
        RETURN QUERY
        SELECT h.object_type, h.object_id, h.title_or_subject, h.snippet, h.rank, 'fallback_text_search'::text
          FROM text_search(p_query_text, ARRAY['claim','fact','memory','episode_object'], p_limit) h;
    END IF;
END;
$body$;

GRANT EXECUTE ON FUNCTION pool_search(text, text, integer, boolean)
TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;
```

- [ ] **Step 5: Call pool facade helper from enablement**

Add:

```sql
v_count := v_count + _enable_memory_schema_pool_facade(p_schema);
```

- [ ] **Step 6: Add pool regression test**

Create `sql/schema_memory_pool_search.sql`:

```sql
\set ECHO all
SET search_path TO maludb_core, public;
SET client_min_messages = NOTICE;

DROP ROLE IF EXISTS smp_user;
DROP SCHEMA IF EXISTS smp CASCADE;
CREATE ROLE smp_user NOLOGIN;
GRANT maludb_memory_executor TO smp_user;
GRANT USAGE ON SCHEMA maludb_core TO smp_user;
CREATE SCHEMA smp AUTHORIZATION smp_user;

SET ROLE smp_user;
SET search_path TO smp, maludb_core, public;
SELECT maludb_core.enable_memory_schema() IS NOT NULL AS enabled;

INSERT INTO maludb_subject(subject_type, canonical_name)
VALUES ('project', 'zozocal');
INSERT INTO maludb_verb(canonical_name) VALUES ('schema');
INSERT INTO maludb_memory(memory_kind, title, summary)
VALUES ('lesson', 'schema pool scoped memory', 'schema-local pool search should find this row');

INSERT INTO maludb_memory_pool(pool_name, task_objective)
VALUES ('zozocal-coding-agent', 'Focus on Zozocal schema work')
RETURNING pool_name;

SELECT pool_add_named_member('zozocal-coding-agent', 'project', 'zozocal') IS NOT NULL AS project_added;
SELECT pool_add_reference(
    (SELECT pool_id FROM maludb_memory_pool WHERE pool_name = 'zozocal-coding-agent'),
    'memory',
    'memory',
    (SELECT memory_id FROM maludb_memory WHERE title = 'schema pool scoped memory')
) IS NOT NULL AS memory_added;

SELECT member_kind, member_object_type
FROM maludb_memory_pool_member
ORDER BY member_kind;

SELECT object_type, title_or_subject, source
FROM maludb_pool_search('zozocal-coding-agent', 'schema-local pool', 10, false)
ORDER BY object_type, title_or_subject;

RESET ROLE;
DROP SCHEMA smp CASCADE;
DROP ROLE smp_user;
```

- [ ] **Step 7: Add test to Makefile and run**

Add `schema_memory_pool_search` after `schema_memory_ingestion`, then run:

```bash
make installcheck PG_CONFIG=/usr/lib/postgresql/17/bin/pg_config REGRESS=schema_memory_pool_search
```

Expected: PASS after expected file is generated from actual output.

- [ ] **Step 8: Commit pool support**

```bash
git add Makefile sql/extension/maludb_core--0.71.0--0.72.0.sql sql/schema_memory_pool_search.sql expected/schema_memory_pool_search.out
git commit -m "feat: add schema-local memory pool facade"
```

---

### Task 8: Vector Search Wrappers

**Files:**
- Modify: `sql/extension/maludb_core--0.71.0--0.72.0.sql`
- Test: `sql/schema_memory_enablement.sql`
- Test: `sql/schema_memory_pool_search.sql`

- [ ] **Step 1: Add `vector_search_by_tags`**

Append:

```sql
CREATE FUNCTION vector_search_by_tags(
    p_namespace text DEFAULT 'default',
    p_subject text DEFAULT NULL,
    p_verb text DEFAULT NULL,
    p_query_embedding malu_vector DEFAULT NULL,
    p_limit integer DEFAULT 20,
    p_metric text DEFAULT NULL
) RETURNS TABLE (
    chunk_id bigint,
    source_text text,
    distance double precision,
    similarity double precision,
    rank_no integer,
    compartment_id bigint,
    subject_name text,
    verb_name text
)
LANGUAGE plpgsql STABLE
AS $body$
BEGIN
    IF p_query_embedding IS NULL THEN
        RAISE EXCEPTION 'vector_search_by_tags: query embedding is required'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;
    IF p_subject IS NULL AND p_verb IS NULL THEN
        RAISE EXCEPTION 'vector_search_by_tags: subject or verb is required'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    RETURN QUERY
    WITH compartments AS (
        SELECT c.compartment_id, s.subject_name, v.verb_name
          FROM malu$vector_compartment c
          JOIN malu$vector_subject s ON s.subject_id = c.subject_id
          JOIN malu$vector_verb v ON v.verb_id = c.verb_id
         WHERE c.namespace = COALESCE(p_namespace, c.namespace)
           AND (p_subject IS NULL OR s.subject_name = p_subject)
           AND (p_verb IS NULL OR v.verb_name = p_verb)
    ), hits AS (
        SELECT r.chunk_id, r.source_text, r.distance, r.similarity,
               r.rank_no, c.compartment_id, c.subject_name, c.verb_name
          FROM compartments c
          CROSS JOIN LATERAL exact_vector_search_sql(c.compartment_id, p_query_embedding, p_limit, p_metric) r
    )
    SELECT h.chunk_id, h.source_text, h.distance, h.similarity,
           row_number() OVER (ORDER BY h.distance ASC, h.chunk_id)::integer AS rank_no,
           h.compartment_id, h.subject_name, h.verb_name
      FROM hits h
     ORDER BY h.distance ASC, h.chunk_id
     LIMIT GREATEST(p_limit, 1);
END;
$body$;

GRANT EXECUTE ON FUNCTION vector_search_by_tags(text, text, text, malu_vector, integer, text)
TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;
```

- [ ] **Step 2: Add schema-local wrapper from subject facade helper**

In `_enable_memory_schema_subject_facade`, create:

```sql
EXECUTE format('CREATE OR REPLACE FUNCTION %I.maludb_vector_search(
    p_namespace text DEFAULT ''default'',
    p_subject text DEFAULT NULL,
    p_verb text DEFAULT NULL,
    p_query_embedding maludb_core.malu_vector DEFAULT NULL,
    p_limit integer DEFAULT 20,
    p_metric text DEFAULT NULL
) RETURNS TABLE (
    chunk_id bigint,
    source_text text,
    distance double precision,
    similarity double precision,
    rank_no integer,
    compartment_id bigint,
    subject_name text,
    verb_name text
)
LANGUAGE sql
AS $fn$
    SELECT * FROM maludb_core.vector_search_by_tags(
        p_namespace, p_subject, p_verb, p_query_embedding, p_limit, p_metric)
$fn$', p_schema);
PERFORM _memory_schema_record_object(p_schema, 'maludb_vector_search', 'function', 'Schema-local subject/verb vector search helper');
```

- [ ] **Step 3: Add vector search assertions**

In `sql/schema_memory_enablement.sql`, after compartment creation, add:

```sql
SELECT maludb_core.register_vector_chunk(
    (SELECT compartment_id FROM maludb_core.malu$vector_compartment WHERE owner_schema = 'sme_a' LIMIT 1),
    'schema local chunk',
    maludb_core.vector_from_real_array('{1,0,0,0}'::real[])
) IS NOT NULL AS chunk_inserted;

SELECT source_text, subject_name, verb_name
FROM maludb_vector_search(
    p_subject => 'schema memory enablement',
    p_query_embedding => maludb_core.vector_from_real_array('{1,0,0,0}'::real[]),
    p_limit => 5
);
```

- [ ] **Step 4: Run tests**

Run:

```bash
make installcheck PG_CONFIG=/usr/lib/postgresql/17/bin/pg_config REGRESS='schema_memory_enablement schema_memory_pool_search'
```

Expected: PASS.

- [ ] **Step 5: Commit vector wrappers**

```bash
git add sql/extension/maludb_core--0.71.0--0.72.0.sql sql/schema_memory_enablement.sql expected/schema_memory_enablement.out
git commit -m "feat: add schema-local vector search wrappers"
```

---

### Task 9: AI Object Owner-Schema Audit And Facades

**Files:**
- Modify: `sql/extension/maludb_core--0.71.0--0.72.0.sql`
- Test: `sql/schema_memory_enablement.sql`

- [ ] **Step 1: Add owner_schema to tenant-visible MC2DB catalog tables**

Append:

```sql
ALTER TABLE malu$mc2db_server ADD COLUMN owner_schema name NOT NULL DEFAULT current_schema();
ALTER TABLE malu$mc2db_tool ADD COLUMN owner_schema name NOT NULL DEFAULT current_schema();
ALTER TABLE malu$mc2db_prompt ADD COLUMN owner_schema name NOT NULL DEFAULT current_schema();
ALTER TABLE malu$mc2db_resource ADD COLUMN owner_schema name NOT NULL DEFAULT current_schema();

UPDATE malu$mc2db_server SET owner_schema = 'maludb_core' WHERE owner_schema IS NULL;
UPDATE malu$mc2db_tool SET owner_schema = 'maludb_core' WHERE owner_schema IS NULL;
UPDATE malu$mc2db_prompt SET owner_schema = 'maludb_core' WHERE owner_schema IS NULL;
UPDATE malu$mc2db_resource SET owner_schema = 'maludb_core' WHERE owner_schema IS NULL;

ALTER TABLE malu$mc2db_server ENABLE ROW LEVEL SECURITY;
ALTER TABLE malu$mc2db_tool ENABLE ROW LEVEL SECURITY;
ALTER TABLE malu$mc2db_prompt ENABLE ROW LEVEL SECURITY;
ALTER TABLE malu$mc2db_resource ENABLE ROW LEVEL SECURITY;

CREATE POLICY tenant_owner ON malu$mc2db_server
    USING (owner_schema = current_schema())
    WITH CHECK (owner_schema = current_schema());
CREATE POLICY tenant_owner ON malu$mc2db_tool
    USING (owner_schema = current_schema())
    WITH CHECK (owner_schema = current_schema());
CREATE POLICY tenant_owner ON malu$mc2db_prompt
    USING (owner_schema = current_schema())
    WITH CHECK (owner_schema = current_schema());
CREATE POLICY tenant_owner ON malu$mc2db_resource
    USING (owner_schema = current_schema())
    WITH CHECK (owner_schema = current_schema());
```

- [ ] **Step 2: Review model/prompt/session tables**

Add owner-schema columns to the known tenant-owned model/prompt/session tables only when they lack them:

```sql
DO $body$
DECLARE
    v_table name;
BEGIN
    FOREACH v_table IN ARRAY ARRAY[
        'malu$prompt_template','malu$prompt_render','malu$model_alias',
        'malu$model_request','malu$model_response','malu$session','malu$session_context'
    ]::name[] LOOP
        IF to_regclass('maludb_core.' || quote_ident(v_table)) IS NOT NULL
           AND NOT EXISTS (
               SELECT 1
                 FROM pg_attribute
                WHERE attrelid = to_regclass('maludb_core.' || quote_ident(v_table))
                  AND attname = 'owner_schema'
                  AND NOT attisdropped
           ) THEN
            EXECUTE format('ALTER TABLE %I ADD COLUMN owner_schema name NOT NULL DEFAULT current_schema()', v_table);
            EXECUTE format('CREATE INDEX %I ON %I(owner_schema)', v_table || '_owner_schema_idx', v_table);
            EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', v_table);
            EXECUTE format('CREATE POLICY tenant_owner ON %I USING (owner_schema = current_schema()) WITH CHECK (owner_schema = current_schema())', v_table);
        END IF;
    END LOOP;
END;
$body$;
```

- [ ] **Step 3: Add AI facade helper**

Append `_enable_memory_schema_ai_facade(p_schema name)` that creates read/write views for tenant-owned tables and read-only provider view:

```text
maludb_prompt
maludb_prompt_render
maludb_llm_provider
maludb_llm_model
maludb_llm_request
maludb_llm_response
maludb_skill
maludb_skill_state
maludb_skill_transition
maludb_skill_execution
maludb_workflow_trace
maludb_workflow_step
maludb_workflow_candidate
maludb_mcp_server
maludb_mcp_tool
maludb_mcp_prompt
maludb_mcp_resource
maludb_mcp_invocation
```

All writable views must be created with `EXECUTE format(sql_text, p_schema, p_schema)`, filter with `WHERE owner_schema = %L`, pass `p_schema` as the `%L` argument, and include `WITH LOCAL CHECK OPTION`. `maludb_llm_provider` must use `model_provider_public` and be read-only.

- [ ] **Step 4: Call AI facade helper from enablement**

Add:

```sql
v_count := v_count + _enable_memory_schema_ai_facade(p_schema);
```

- [ ] **Step 5: Add smoke assertions**

In `sql/schema_memory_enablement.sql`, add:

```sql
SELECT count(*) >= 0 AS ai_facades_queryable
FROM maludb_skill;

SELECT count(*) >= 0 AS mcp_facades_queryable
FROM maludb_mcp_invocation;
```

- [ ] **Step 6: Run test**

Run:

```bash
make installcheck PG_CONFIG=/usr/lib/postgresql/17/bin/pg_config REGRESS=schema_memory_enablement
```

Expected: PASS.

- [ ] **Step 7: Commit AI facades**

```bash
git add sql/extension/maludb_core--0.71.0--0.72.0.sql sql/schema_memory_enablement.sql expected/schema_memory_enablement.out
git commit -m "feat: expose tenant AI objects through schema facade"
```

---

### Task 10: Operator Script And Documentation

**Files:**
- Create: `sql/enable-memory-schema.sql`
- Modify: `README.md`
- Modify: `docs/user-manual.md`
- Modify: `docs/admin-guide.md`
- Modify: `docs/getting-started.md`

- [ ] **Step 1: Create wrapper script**

Create `sql/enable-memory-schema.sql`:

```sql
\echo Enabling MaluDB memory schema :schema
SELECT *
FROM maludb_core.enable_memory_schema(:'schema'::name);
```

- [ ] **Step 2: Add README quickstart**

Add this snippet near the extension setup section in `README.md`:

```markdown
### Enable MaluDB memory in an application schema

MaluDB does not modify ordinary PostgreSQL schemas automatically. To opt a
schema into schema-local memory views:

```sql
CREATE SCHEMA zozocal AUTHORIZATION zozocal;
SET search_path TO zozocal, maludb_core, public;
SELECT * FROM maludb_core.enable_memory_schema();
SELECT * FROM maludb_subject;
```
```

- [ ] **Step 3: Add user manual section**

In `docs/user-manual.md`, add a section named `Schema Memory Enablement` with examples for:

```sql
SELECT maludb_core.enable_memory_schema('zozocal');
INSERT INTO zozocal.maludb_project(name) VALUES ('zozocal migration');
SELECT * FROM zozocal.maludb_unapplied_ingest;
SELECT * FROM zozocal.maludb_pool_search('zozocal-coding-agent', 'schema views', 20, false);
```

- [ ] **Step 4: Add admin guide section**

In `docs/admin-guide.md`, replace the current schema-only guidance with:

```sql
CREATE USER zozocal;
GRANT maludb_memory_executor TO zozocal;
CREATE SCHEMA zozocal AUTHORIZATION zozocal;
SET ROLE zozocal;
SET search_path TO zozocal, maludb_core, public;
SELECT * FROM maludb_core.enable_memory_schema();
```

- [ ] **Step 5: Run doc consistency check**

Run:

```bash
scripts/maludb-check-doc-consistency
```

Expected: PASS.

- [ ] **Step 6: Commit docs**

```bash
git add sql/enable-memory-schema.sql README.md docs/user-manual.md docs/admin-guide.md docs/getting-started.md
git commit -m "docs: describe schema memory enablement"
```

---

### Task 11: Tenant Search Path In Drivers And CLI

**Files:**
- Modify: `drivers/php/src/Client.php`
- Modify: `drivers/python/src/maludb/client.py`
- Modify: `drivers/nodejs/src/client.ts`
- Modify: `drivers/c/src/maludb.c`
- Modify: `cli/maludb/src/maludb_cli/db.py`
- Modify: `drivers/php/tests/SmokeTest.php`
- Modify: `drivers/python/tests/test_smoke.py`
- Modify: `drivers/nodejs/test/smoke.test.ts`
- Modify: `drivers/c/tests/smoke.c`
- Modify: `cli/maludb/tests/test_smoke.py`

- [ ] **Step 1: Add PHP tenant schema option**

Change `drivers/php/src/Client.php` constructor to accept an optional schema:

```php
public function __construct(PDO $pdo, ?string $schema = null)
{
    $this->raw = $pdo;
    $this->raw->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
    $searchPath = $schema === null || $schema === ''
        ? 'maludb_core, public'
        : self::quoteIdentifier($schema) . ', maludb_core, public';
    $this->raw->exec('SET search_path = ' . $searchPath);
}

private static function quoteIdentifier(string $identifier): string
{
    return '"' . str_replace('"', '""', $identifier) . '"';
}
```

Update `fromDsn` and `fromPdo` to accept `?string $schema = null` and pass it through.

- [ ] **Step 2: Add Python tenant schema option**

In `drivers/python/src/maludb/client.py`, add constructor/config support for `schema: str | None = None` and execute:

```python
if self.schema:
    cur.execute("SELECT set_config('search_path', %s, false)", (f'{self.schema}, maludb_core, public',))
else:
    cur.execute("SET search_path = maludb_core, public")
```

Use psycopg SQL identifier formatting if the client has a cursor-level SQL composition helper available; otherwise validate schema names with `^[A-Za-z_][A-Za-z0-9_]*$` before interpolation.

- [ ] **Step 3: Add Node tenant schema option**

In `drivers/nodejs/src/client.ts`, add `schema?: string` to the connection options and set:

```ts
const searchPath = options.schema
  ? `${quoteIdent(options.schema)}, maludb_core, public`
  : "maludb_core, public";
await client.query(`SET search_path = ${searchPath}`);
```

Add a local `quoteIdent` helper:

```ts
function quoteIdent(value: string): string {
  return `"${value.replace(/"/g, '""')}"`;
}
```

- [ ] **Step 4: Add C DSN schema parameter**

In `drivers/c/src/maludb.c`, add a new connect helper:

```c
maludb_t *maludb_connect_schema(const char *dsn, const char *schema)
```

Keep `maludb_connect` as a wrapper calling `maludb_connect_schema(dsn, NULL)`. Build the search path with quoted identifiers for non-null schema.

- [ ] **Step 5: Add CLI schema option**

In `cli/maludb/src/maludb_cli/db.py`, read `MALUDB_SCHEMA` or `args.schema` and set:

```python
schema = getattr(args, "schema", None) or os.environ.get("MALUDB_SCHEMA")
if schema:
    cur.execute("SELECT set_config('search_path', %s, false)", (f'{schema}, maludb_core, public',))
else:
    cur.execute("SET search_path TO maludb_core, public")
```

Add `--schema` to command parser construction where `--db` is defined.

- [ ] **Step 6: Run driver tests**

Run available smoke tests:

```bash
composer test
npm test --prefix drivers/nodejs
pytest drivers/python/tests
make PG_CONFIG=/usr/lib/postgresql/17/bin/pg_config
```

Expected: existing tests pass with default search path. The smoke tests assert that constructing a client with schema `driver_tenant` or setting `MALUDB_SCHEMA=driver_tenant` results in `SHOW search_path` beginning with `driver_tenant, maludb_core, public`.

- [ ] **Step 7: Commit driver updates**

```bash
git add drivers/php/src/Client.php drivers/python/src/maludb/client.py drivers/nodejs/src/client.ts drivers/c/src/maludb.c cli/maludb/src/maludb_cli/db.py drivers cli
git commit -m "feat: support tenant schema search path in clients"
```

---

### Task 12: Snapshot, Full Regression, And Release Metadata

**Files:**
- Create: `sql/extension/maludb_core--0.72.0.sql`
- Modify: `README.md`
- Modify: `docs/user-manual.md`
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Generate the 0.72.0 snapshot**

Create `sql/extension/maludb_core--0.72.0.sql` by copying `sql/extension/maludb_core--0.71.0.sql` and appending a section for `0.71.0--0.72.0.sql`, matching the existing snapshot format:

```text
-- ============================================================
-- Section: maludb_core--0.71.0--0.72.0.sql
-- ============================================================
```

Then paste the complete migration content below that section header.

- [ ] **Step 2: Update version docs**

Update these version references:

```text
README.md: Version 0.72.0
docs/user-manual.md: Extension default_version 0.72.0
CHANGELOG.md: add 0.72.0 entry for schema memory enablement
```

- [ ] **Step 3: Run full SQL tests**

Run:

```bash
make installcheck PG_CONFIG=/usr/lib/postgresql/17/bin/pg_config
```

Expected: all `REGRESS` tests pass, including:

```text
schema_memory_enablement
schema_memory_ingestion
schema_memory_pool_search
```

- [ ] **Step 4: Run validation scripts**

Run:

```bash
scripts/maludb-check-doc-consistency
scripts/maludb-validate
```

Expected: both pass.

- [ ] **Step 5: Check git diff for unrelated edits**

Run:

```bash
git status --short
git diff --stat
```

Expected: only files in this plan are modified.

- [ ] **Step 6: Commit release metadata and snapshot**

```bash
git add sql/extension/maludb_core--0.72.0.sql README.md docs/user-manual.md CHANGELOG.md
git commit -m "chore: update extension snapshot for schema memory enablement"
```

---

## Self-Review Checklist

- Spec coverage: Tasks cover explicit enablement, owner-schema audit, schema-local views, subject types, embeddings, documents/tags, raw ingest, AI objects, shared pools, driver search paths, tests, docs, and snapshot/version updates.
- Test coverage: Each subsystem has at least one pg_regress test, and driver changes have smoke-test commands.
- Type consistency: Function names use `enable_memory_schema`, `upload_document`, `vector_search_by_tags`, `pool_search`, and schema-local wrappers with `maludb_` prefixes consistently.
- Commit strategy: Every task ends with a focused commit.
