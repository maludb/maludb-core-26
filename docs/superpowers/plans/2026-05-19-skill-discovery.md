# Skill Discovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build manual skill discovery so users, LLM agents, MCP clients, and API clients can find, inspect, and fork schema-owned, shared, and public MaluDB skills.

**Architecture:** Add a `0.72.0 -> 0.73.0` extension migration that keeps `malu$skill_package` as the canonical skill anchor, adds normalized manual discovery tables, adds optional skill-description embeddings, and exposes two-step search/get plus fork APIs. Schema-local enablement is extended with skill discovery facades and wrappers, while `maludb_public` acts as a curated read-only public skill owner.

**Tech Stack:** PostgreSQL extension SQL migrations, PL/pgSQL, RLS, `malu_vector`, pg_regress SQL tests, Makefile PGXS packaging, MC2DB tool registration, docs.

---

## File Structure

- Create: `sql/extension/maludb_core--0.72.0--0.73.0.sql`  
  Adds version bump, skill discovery tables, public visibility rules, discovery APIs, schema-local wrappers, and MC2DB tool registrations.

- Create/Update: `sql/extension/maludb_core--0.73.0.sql`  
  Generated full install snapshot after implementation.

- Modify: `maludb_core.control`  
  Bumps `default_version` to `0.73.0`.

- Modify: `Makefile`  
  Adds the `0.72.0--0.73.0` migration, the `0.73.0` snapshot, and new regression tests.

- Create: `sql/skill_discovery.sql`  
  Regression test for manual skill keywords, subjects, verbs, search ranking, public skill visibility, access grants, and read-only public protections.

- Create: `expected/skill_discovery.out`  
  Expected output for `skill_discovery.sql`.

- Create: `sql/skill_discovery_fork.sql`  
  Regression test for public/shared skill fork behavior, copied tags/states/transitions, lineage, and full `get_skill` payload.

- Create: `expected/skill_discovery_fork.out`  
  Expected output for `skill_discovery_fork.sql`.

- Modify: `docs/user-manual.md`, `docs/admin-guide.md`, `docs/getting-started.md`, `README.md`, `CHANGELOG.md`  
  Documents skill discovery, public skills, two-step find/get flow, and fork flow.

---

### Task 1: Extension Version Scaffold

**Files:**
- Create: `sql/extension/maludb_core--0.72.0--0.73.0.sql`
- Modify: `maludb_core.control`
- Modify: `Makefile`

- [ ] **Step 1: Create the migration scaffold**

Create `sql/extension/maludb_core--0.72.0--0.73.0.sql`:

```sql
\echo Use "ALTER EXTENSION maludb_core UPDATE TO '0.73.0'" to load this file. \quit

-- =====================================================================
-- maludb_core 0.72.0 -> 0.73.0
--
-- Skill discovery:
--   * manual subject, verb, and keyword tags for skills
--   * optional skill-description embeddings
--   * private/shared/public skill visibility
--   * maludb_public read-only public skills
--   * find/get/fork skill APIs
-- =====================================================================

CREATE OR REPLACE FUNCTION maludb_core_version() RETURNS text
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$ SELECT '0.73.0'::text $body$;
```

- [ ] **Step 2: Bump control version**

Modify `maludb_core.control`:

```diff
-default_version = '0.72.0'
+default_version = '0.73.0'
```

- [ ] **Step 3: Update Makefile DATA**

Modify the `DATA` list so the tail contains:

```make
              sql/extension/maludb_core--0.71.0--0.72.0.sql \
              sql/extension/maludb_core--0.72.0--0.73.0.sql \
              sql/extension/maludb_core--0.73.0.sql
```

- [ ] **Step 4: Commit scaffold**

```bash
git add Makefile maludb_core.control sql/extension/maludb_core--0.72.0--0.73.0.sql
git commit -m "feat: scaffold skill discovery migration"
```

---

### Task 2: Failing Skill Discovery Regression

**Files:**
- Create: `sql/skill_discovery.sql`
- Create: `expected/skill_discovery.out`
- Modify: `Makefile`

- [ ] **Step 1: Add regression names to Makefile**

Append the new tests after the schema memory tests:

```make
schema_memory_enablement schema_memory_ingestion schema_memory_pool_search skill_discovery skill_discovery_fork
```

- [ ] **Step 2: Create `sql/skill_discovery.sql`**

Create a regression that proves the behavior before implementation:

```sql
\set ECHO all
\pset format unaligned
SET client_min_messages = NOTICE;
CREATE EXTENSION IF NOT EXISTS maludb_core CASCADE;

SET search_path TO maludb_core, public;

DROP SCHEMA IF EXISTS skill_a CASCADE;
DROP SCHEMA IF EXISTS skill_b CASCADE;
DROP SCHEMA IF EXISTS maludb_public CASCADE;
DROP ROLE IF EXISTS skill_user_a;
DROP ROLE IF EXISTS skill_user_b;
DROP ROLE IF EXISTS maludb_skill_curator;

CREATE ROLE skill_user_a NOLOGIN;
CREATE ROLE skill_user_b NOLOGIN;
CREATE ROLE maludb_skill_curator NOLOGIN;
GRANT maludb_memory_executor TO skill_user_a, skill_user_b;
GRANT maludb_memory_admin TO maludb_skill_curator;
GRANT USAGE ON SCHEMA maludb_core TO skill_user_a, skill_user_b, maludb_skill_curator;

CREATE SCHEMA skill_a AUTHORIZATION skill_user_a;
CREATE SCHEMA skill_b AUTHORIZATION skill_user_b;
CREATE SCHEMA maludb_public AUTHORIZATION maludb_skill_curator;

SELECT object_count >= 48 AS public_enabled
FROM maludb_core.enable_memory_schema('maludb_public');

SELECT object_count >= 56 AS skill_a_enabled
FROM maludb_core.enable_memory_schema('skill_a');

SELECT object_count >= 56 AS skill_b_enabled
FROM maludb_core.enable_memory_schema('skill_b');

SET ROLE skill_user_a;
SET search_path TO skill_a, maludb_core, public;

INSERT INTO maludb_subject(subject_type, canonical_name)
VALUES ('document', 'meeting transcript');

INSERT INTO maludb_verb(canonical_name)
VALUES ('extract');

INSERT INTO maludb_skill(skill_name, version, description, packaging_kind)
VALUES (
    'meeting_action_item_extractor',
    '1.0.0',
    'Extract action items from meeting transcripts.',
    'markdown'
)
RETURNING skill_name, version;

INSERT INTO maludb_skill_subject(skill_id, subject_name, weight)
SELECT skill_id, 'meeting transcript', 1.0
FROM maludb_skill
WHERE skill_name = 'meeting_action_item_extractor';

INSERT INTO maludb_skill_verb(skill_id, verb_name, weight)
SELECT skill_id, 'extract', 1.0
FROM maludb_skill
WHERE skill_name = 'meeting_action_item_extractor';

INSERT INTO maludb_skill_keyword(skill_id, keyword, weight)
SELECT skill_id, 'action items', 1.0
FROM maludb_skill
WHERE skill_name = 'meeting_action_item_extractor';

SELECT skill_name, owner_schema, array_to_string(keywords, ',') AS keywords
FROM maludb_skill_search(
    p_query => 'find action items',
    p_subject => 'meeting transcript',
    p_verb => 'extract',
    p_limit => 10
)
ORDER BY score DESC, skill_name;

RESET ROLE;
SET ROLE maludb_skill_curator;
SET search_path TO maludb_public, maludb_core, public;

INSERT INTO maludb_skill(skill_name, version, description, packaging_kind, visibility)
VALUES (
    'public_summary_skill',
    '1.0.0',
    'Summarize public documents for general use.',
    'markdown',
    'public'
)
RETURNING skill_name, visibility;

INSERT INTO maludb_skill_keyword(skill_id, keyword, weight)
SELECT skill_id, 'summarize', 1.0
FROM maludb_skill
WHERE skill_name = 'public_summary_skill';

RESET ROLE;
SET ROLE skill_user_a;
SET search_path TO skill_a, maludb_core, public;

SELECT skill_name, owner_schema, is_public
FROM maludb_skill_search(
    p_query => 'summarize',
    p_limit => 10,
    p_include_public => true
)
ORDER BY is_public DESC, skill_name;

RESET ROLE;
SET ROLE skill_user_b;
SET search_path TO maludb_public, maludb_core, public;

DO $body$
BEGIN
    BEGIN
        INSERT INTO maludb_skill(skill_name, version, description, packaging_kind, visibility)
        VALUES ('blocked_public_write', '1.0.0', 'should fail', 'markdown', 'public');
        RAISE EXCEPTION 'non-curator public skill write was not blocked';
    EXCEPTION WHEN insufficient_privilege OR check_violation OR with_check_option_violation THEN
        RAISE NOTICE 'OK: non-curator public skill write blocked';
    END;
END;
$body$;

RESET ROLE;
SET search_path TO maludb_core, public;
DROP SCHEMA skill_a CASCADE;
DROP SCHEMA skill_b CASCADE;
DROP SCHEMA maludb_public CASCADE;
DROP OWNED BY skill_user_a;
DROP OWNED BY skill_user_b;
DROP OWNED BY maludb_skill_curator;
DROP ROLE skill_user_a;
DROP ROLE skill_user_b;
DROP ROLE maludb_skill_curator;
```

- [ ] **Step 3: Create initial expected file**

Create `expected/skill_discovery.out` from the failing run after the implementation exists. For the red phase, an empty file is acceptable:

```bash
: > expected/skill_discovery.out
```

- [ ] **Step 4: Run red test**

Use a database with the current extension and local migration applied:

```bash
make PG_CONFIG=/usr/lib/postgresql/17/bin/pg_config
/usr/lib/postgresql/17/lib/pgxs/src/test/regress/pg_regress \
  --use-existing --dbname=contrib_regression --inputdir=. --outputdir=/tmp/skill-red \
  skill_discovery
```

Expected: FAIL with missing relation/function errors for `maludb_skill_keyword`, `maludb_skill_subject`, `maludb_skill_verb`, or `maludb_skill_search`.

- [ ] **Step 5: Commit failing test**

```bash
git add Makefile sql/skill_discovery.sql expected/skill_discovery.out
git commit -m "test: cover manual skill discovery"
```

---

### Task 3: Skill Discovery Tables And Visibility

**Files:**
- Modify: `sql/extension/maludb_core--0.72.0--0.73.0.sql`
- Modify: `sql/skill_discovery.sql`

- [ ] **Step 1: Add `maludb_skill_curator` role**

Append to the migration:

```sql
DO $body$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'maludb_skill_curator') THEN
        CREATE ROLE maludb_skill_curator;
    END IF;
END;
$body$;
```

- [ ] **Step 2: Add package visibility and lineage columns**

Append:

```sql
ALTER TABLE malu$skill_package
    ADD COLUMN visibility text NOT NULL DEFAULT 'private'
        CHECK (visibility IN ('private','shared','public')),
    ADD COLUMN source_owner_schema name,
    ADD COLUMN source_skill_id bigint,
    ADD COLUMN forked_at timestamptz;

ALTER TABLE malu$skill_package
    ADD CONSTRAINT malu$skill_package_public_owner_ck
    CHECK (visibility <> 'public' OR owner_schema = 'maludb_public');

ALTER TABLE malu$skill_package
    ADD CONSTRAINT malu$skill_package_source_fk
    FOREIGN KEY (source_owner_schema, source_skill_id)
    REFERENCES malu$skill_package(owner_schema, skill_id)
    ON DELETE SET NULL (source_owner_schema, source_skill_id);
```

- [ ] **Step 3: Add discovery tables**

Append:

```sql
CREATE TABLE malu$skill_keyword (
    keyword_id   bigserial PRIMARY KEY,
    owner_schema name NOT NULL DEFAULT current_schema(),
    skill_id     bigint NOT NULL,
    keyword      text NOT NULL,
    weight       numeric NOT NULL DEFAULT 1.0,
    provenance   text NOT NULL DEFAULT 'manual'
        CHECK (provenance IN ('manual')),
    created_at   timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (owner_schema, skill_id)
        REFERENCES malu$skill_package(owner_schema, skill_id) ON DELETE CASCADE
);
CREATE UNIQUE INDEX malu$skill_keyword_owner_skill_keyword_key
    ON malu$skill_keyword(owner_schema, skill_id, lower(keyword));
CREATE INDEX malu$skill_keyword_lookup_idx
    ON malu$skill_keyword(owner_schema, lower(keyword));

CREATE TABLE malu$skill_subject (
    skill_subject_id bigserial PRIMARY KEY,
    owner_schema     name NOT NULL DEFAULT current_schema(),
    skill_id         bigint NOT NULL,
    subject_id       bigint,
    subject_name     text NOT NULL,
    weight           numeric NOT NULL DEFAULT 1.0,
    provenance       text NOT NULL DEFAULT 'manual'
        CHECK (provenance IN ('manual')),
    created_at       timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (owner_schema, skill_id)
        REFERENCES malu$skill_package(owner_schema, skill_id) ON DELETE CASCADE,
    FOREIGN KEY (owner_schema, subject_id)
        REFERENCES malu$svpor_subject(owner_schema, subject_id) ON DELETE SET NULL (subject_id)
);
CREATE UNIQUE INDEX malu$skill_subject_owner_skill_subject_key
    ON malu$skill_subject(owner_schema, skill_id, lower(subject_name));
CREATE INDEX malu$skill_subject_lookup_idx
    ON malu$skill_subject(owner_schema, lower(subject_name));

CREATE TABLE malu$skill_verb (
    skill_verb_id bigserial PRIMARY KEY,
    owner_schema  name NOT NULL DEFAULT current_schema(),
    skill_id      bigint NOT NULL,
    verb_id       bigint,
    verb_name     text NOT NULL,
    weight        numeric NOT NULL DEFAULT 1.0,
    provenance    text NOT NULL DEFAULT 'manual'
        CHECK (provenance IN ('manual')),
    created_at    timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (owner_schema, skill_id)
        REFERENCES malu$skill_package(owner_schema, skill_id) ON DELETE CASCADE,
    FOREIGN KEY (owner_schema, verb_id)
        REFERENCES malu$svpor_verb(owner_schema, verb_id) ON DELETE SET NULL (verb_id)
);
CREATE UNIQUE INDEX malu$skill_verb_owner_skill_verb_key
    ON malu$skill_verb(owner_schema, skill_id, lower(verb_name));
CREATE INDEX malu$skill_verb_lookup_idx
    ON malu$skill_verb(owner_schema, lower(verb_name));
```

- [ ] **Step 4: Add embedding and access tables**

Append:

```sql
CREATE TABLE malu$skill_embedding (
    embedding_id     bigserial PRIMARY KEY,
    owner_schema     name NOT NULL DEFAULT current_schema(),
    skill_id         bigint NOT NULL,
    embedding_model  text NOT NULL,
    embedding_dim    integer NOT NULL,
    embedding        malu_vector NOT NULL,
    source_text_hash text NOT NULL,
    source_text_kind text NOT NULL DEFAULT 'description',
    created_at       timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (owner_schema, skill_id)
        REFERENCES malu$skill_package(owner_schema, skill_id) ON DELETE CASCADE
);
CREATE INDEX malu$skill_embedding_owner_skill_idx
    ON malu$skill_embedding(owner_schema, skill_id);

CREATE TABLE malu$skill_access (
    access_id     bigserial PRIMARY KEY,
    owner_schema  name NOT NULL DEFAULT current_schema(),
    skill_id      bigint NOT NULL,
    grantee_role  name NOT NULL,
    access_level  text NOT NULL DEFAULT 'read'
        CHECK (access_level IN ('read','fork')),
    created_at    timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (owner_schema, skill_id)
        REFERENCES malu$skill_package(owner_schema, skill_id) ON DELETE CASCADE,
    UNIQUE (owner_schema, skill_id, grantee_role, access_level)
);
CREATE INDEX malu$skill_access_grantee_idx
    ON malu$skill_access(grantee_role, owner_schema, skill_id);
```

- [ ] **Step 5: Enable RLS and grants**

Append:

```sql
ALTER TABLE malu$skill_keyword ENABLE ROW LEVEL SECURITY;
ALTER TABLE malu$skill_subject ENABLE ROW LEVEL SECURITY;
ALTER TABLE malu$skill_verb ENABLE ROW LEVEL SECURITY;
ALTER TABLE malu$skill_embedding ENABLE ROW LEVEL SECURITY;
ALTER TABLE malu$skill_access ENABLE ROW LEVEL SECURITY;

CREATE POLICY tenant_owner ON malu$skill_keyword
    USING (owner_schema = current_schema() OR owner_schema = 'maludb_public')
    WITH CHECK (owner_schema = current_schema());
CREATE POLICY tenant_owner ON malu$skill_subject
    USING (owner_schema = current_schema() OR owner_schema = 'maludb_public')
    WITH CHECK (owner_schema = current_schema());
CREATE POLICY tenant_owner ON malu$skill_verb
    USING (owner_schema = current_schema() OR owner_schema = 'maludb_public')
    WITH CHECK (owner_schema = current_schema());
CREATE POLICY tenant_owner ON malu$skill_embedding
    USING (owner_schema = current_schema() OR owner_schema = 'maludb_public')
    WITH CHECK (owner_schema = current_schema());
CREATE POLICY tenant_owner ON malu$skill_access
    USING (owner_schema = current_schema() OR owner_schema = 'maludb_public')
    WITH CHECK (owner_schema = current_schema());

GRANT SELECT, INSERT, UPDATE, DELETE ON
    malu$skill_keyword,
    malu$skill_subject,
    malu$skill_verb,
    malu$skill_embedding,
    malu$skill_access
TO maludb_memory_admin, maludb_memory_executor;

GRANT SELECT ON
    malu$skill_keyword,
    malu$skill_subject,
    malu$skill_verb,
    malu$skill_embedding,
    malu$skill_access
TO maludb_memory_auditor;

GRANT USAGE, SELECT ON SEQUENCE
    malu$skill_keyword_keyword_id_seq,
    malu$skill_subject_skill_subject_id_seq,
    malu$skill_verb_skill_verb_id_seq,
    malu$skill_embedding_embedding_id_seq,
    malu$skill_access_access_id_seq
TO maludb_memory_admin, maludb_memory_executor;
```

- [ ] **Step 6: Run red-to-green partial test**

```bash
make PG_CONFIG=/usr/lib/postgresql/17/bin/pg_config
/usr/lib/postgresql/17/lib/pgxs/src/test/regress/pg_regress \
  --use-existing --dbname=contrib_regression --inputdir=. --outputdir=/tmp/skill-tables \
  skill_discovery
```

Expected: table/facade errors are reduced; missing `maludb_skill_search` is still expected until Task 5.

- [ ] **Step 7: Commit tables**

```bash
git add sql/extension/maludb_core--0.72.0--0.73.0.sql sql/skill_discovery.sql
git commit -m "feat: add skill discovery tables"
```

---

### Task 4: Schema-Local Discovery Facades

**Files:**
- Modify: `sql/extension/maludb_core--0.72.0--0.73.0.sql`
- Modify: `sql/skill_discovery.sql`

- [ ] **Step 1: Extend `maludb_skill` facade columns**

In `_enable_memory_schema_ai_facade`, change the `maludb_skill` view select list to include:

```sql
visibility,
source_owner_schema,
source_skill_id,
forked_at,
```

The view must continue filtering:

```sql
WHERE owner_schema = %L
WITH LOCAL CHECK OPTION
```

- [ ] **Step 2: Add discovery metadata facades**

Append this pattern inside `_enable_memory_schema_ai_facade` after `maludb_skill`:

```sql
PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_skill_keyword', 'view');
EXECUTE format($sql$
    CREATE OR REPLACE VIEW %I.maludb_skill_keyword WITH (security_invoker = true) AS
    SELECT keyword_id, skill_id, keyword, weight, provenance, created_at
      FROM maludb_core.malu$skill_keyword
     WHERE owner_schema = %L
    WITH LOCAL CHECK OPTION
$sql$, p_schema, p_schema);
EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON %I.maludb_skill_keyword TO maludb_memory_admin, maludb_memory_executor', p_schema);
EXECUTE format('GRANT SELECT ON %I.maludb_skill_keyword TO maludb_memory_auditor', p_schema);
PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_skill_keyword', 'view', 'Schema-local skill keyword discovery facade.');
v_count := v_count + 1;
```

Repeat the same structure for:

```text
maludb_skill_subject
maludb_skill_verb
maludb_skill_embedding
maludb_skill_access
```

Use each table's column list from Task 3, excluding `owner_schema`.

- [ ] **Step 3: Add public schema read-only grants**

After creating each discovery facade, add conditional grants:

```sql
IF p_schema = 'maludb_public' THEN
    EXECUTE format('REVOKE INSERT, UPDATE, DELETE ON %I.maludb_skill FROM maludb_memory_executor', p_schema);
    EXECUTE format('REVOKE INSERT, UPDATE, DELETE ON %I.maludb_skill_keyword FROM maludb_memory_executor', p_schema);
    EXECUTE format('REVOKE INSERT, UPDATE, DELETE ON %I.maludb_skill_subject FROM maludb_memory_executor', p_schema);
    EXECUTE format('REVOKE INSERT, UPDATE, DELETE ON %I.maludb_skill_verb FROM maludb_memory_executor', p_schema);
    EXECUTE format('REVOKE INSERT, UPDATE, DELETE ON %I.maludb_skill_embedding FROM maludb_memory_executor', p_schema);
    EXECUTE format('REVOKE INSERT, UPDATE, DELETE ON %I.maludb_skill_access FROM maludb_memory_executor', p_schema);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON %I.maludb_skill TO maludb_skill_curator', p_schema);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON %I.maludb_skill_keyword TO maludb_skill_curator', p_schema);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON %I.maludb_skill_subject TO maludb_skill_curator', p_schema);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON %I.maludb_skill_verb TO maludb_skill_curator', p_schema);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON %I.maludb_skill_embedding TO maludb_skill_curator', p_schema);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON %I.maludb_skill_access TO maludb_skill_curator', p_schema);
END IF;
```

- [ ] **Step 4: Verify facade count**

Update the regression assertions in `sql/skill_discovery.sql`:

```sql
SELECT object_count >= 56 AS skill_a_enabled
FROM maludb_core.enable_memory_schema('skill_a');
```

Adjust the minimum upward if the actual object count is higher.

- [ ] **Step 5: Commit facades**

```bash
git add sql/extension/maludb_core--0.72.0--0.73.0.sql sql/skill_discovery.sql
git commit -m "feat: expose skill discovery facades"
```

---

### Task 5: Lightweight Skill Search API

**Files:**
- Modify: `sql/extension/maludb_core--0.72.0--0.73.0.sql`
- Modify: `sql/skill_discovery.sql`
- Update: `expected/skill_discovery.out`

- [ ] **Step 1: Add access helper**

Append:

```sql
CREATE FUNCTION _skill_is_visible(
    p_owner_schema name,
    p_skill_id bigint,
    p_requesting_schema name,
    p_include_public boolean DEFAULT true
) RETURNS boolean
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
    SELECT EXISTS (
        SELECT 1
          FROM maludb_core.malu$skill_package s
         WHERE s.owner_schema = p_owner_schema
           AND s.skill_id = p_skill_id
           AND s.enabled
           AND (
                s.owner_schema = p_requesting_schema
             OR (p_include_public AND s.owner_schema = 'maludb_public' AND s.visibility = 'public')
             OR EXISTS (
                    SELECT 1
                      FROM maludb_core.malu$skill_access a
                     WHERE a.owner_schema = s.owner_schema
                       AND a.skill_id = s.skill_id
                       AND pg_has_role(current_user, a.grantee_role, 'member')
                       AND a.access_level IN ('read','fork')
                )
           )
    )
$body$;

REVOKE ALL ON FUNCTION _skill_is_visible(name, bigint, name, boolean) FROM PUBLIC;
```

- [ ] **Step 2: Add `find_skill`**

Append:

```sql
CREATE FUNCTION find_skill(
    p_query text DEFAULT NULL,
    p_subject text DEFAULT NULL,
    p_verb text DEFAULT NULL,
    p_query_embedding malu_vector DEFAULT NULL,
    p_owner_schema name DEFAULT current_schema(),
    p_limit integer DEFAULT 20,
    p_include_public boolean DEFAULT true
) RETURNS TABLE (
    owner_schema name,
    skill_id bigint,
    skill_name text,
    version text,
    description text,
    visibility text,
    subjects text[],
    verbs text[],
    keywords text[],
    score numeric,
    match_reasons text[],
    is_public boolean,
    is_forkable boolean,
    source_owner_schema name,
    source_skill_id bigint,
    updated_at timestamptz
)
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
WITH visible_skills AS (
    SELECT s.*
      FROM maludb_core.malu$skill_package s
     WHERE maludb_core._skill_is_visible(s.owner_schema, s.skill_id, p_owner_schema, p_include_public)
),
tagged AS (
    SELECT s.owner_schema,
           s.skill_id,
           array_remove(array_agg(DISTINCT ss.subject_name), NULL) AS subjects,
           array_remove(array_agg(DISTINCT sv.verb_name), NULL) AS verbs,
           array_remove(array_agg(DISTINCT sk.keyword), NULL) AS keywords
      FROM visible_skills s
      LEFT JOIN maludb_core.malu$skill_subject ss
        ON ss.owner_schema = s.owner_schema
       AND ss.skill_id = s.skill_id
      LEFT JOIN maludb_core.malu$skill_verb sv
        ON sv.owner_schema = s.owner_schema
       AND sv.skill_id = s.skill_id
      LEFT JOIN maludb_core.malu$skill_keyword sk
        ON sk.owner_schema = s.owner_schema
       AND sk.skill_id = s.skill_id
     GROUP BY s.owner_schema, s.skill_id
),
scored AS (
    SELECT s.owner_schema,
           s.skill_id,
           s.skill_name,
           s.version,
           s.description,
           s.visibility,
           COALESCE(t.subjects, ARRAY[]::text[]) AS subjects,
           COALESCE(t.verbs, ARRAY[]::text[]) AS verbs,
           COALESCE(t.keywords, ARRAY[]::text[]) AS keywords,
           (
               CASE WHEN p_subject IS NOT NULL AND p_subject = ANY(COALESCE(t.subjects, ARRAY[]::text[])) THEN 40 ELSE 0 END
             + CASE WHEN p_verb IS NOT NULL AND p_verb = ANY(COALESCE(t.verbs, ARRAY[]::text[])) THEN 40 ELSE 0 END
             + CASE WHEN p_query IS NOT NULL AND EXISTS (
                    SELECT 1 FROM unnest(COALESCE(t.keywords, ARRAY[]::text[])) k
                    WHERE lower(k) = lower(p_query) OR lower(p_query) LIKE '%' || lower(k) || '%'
               ) THEN 20 ELSE 0 END
             + CASE WHEN p_query IS NOT NULL AND (
                    to_tsvector('simple', COALESCE(s.skill_name,'') || ' ' || COALESCE(s.description,'')) @@ plainto_tsquery('simple', p_query)
               ) THEN 10 ELSE 0 END
           )::numeric AS score,
           array_remove(ARRAY[
               CASE WHEN p_subject IS NOT NULL AND p_subject = ANY(COALESCE(t.subjects, ARRAY[]::text[])) THEN 'subject' END,
               CASE WHEN p_verb IS NOT NULL AND p_verb = ANY(COALESCE(t.verbs, ARRAY[]::text[])) THEN 'verb' END,
               CASE WHEN p_query IS NOT NULL AND EXISTS (
                    SELECT 1 FROM unnest(COALESCE(t.keywords, ARRAY[]::text[])) k
                    WHERE lower(k) = lower(p_query) OR lower(p_query) LIKE '%' || lower(k) || '%'
               ) THEN 'keyword' END,
               CASE WHEN p_query IS NOT NULL AND (
                    to_tsvector('simple', COALESCE(s.skill_name,'') || ' ' || COALESCE(s.description,'')) @@ plainto_tsquery('simple', p_query)
               ) THEN 'text' END
           ], NULL) AS match_reasons,
           (s.owner_schema = 'maludb_public' AND s.visibility = 'public') AS is_public,
           (
               s.owner_schema = 'maludb_public'
            OR EXISTS (
                   SELECT 1 FROM maludb_core.malu$skill_access a
                    WHERE a.owner_schema = s.owner_schema
                      AND a.skill_id = s.skill_id
                      AND pg_has_role(current_user, a.grantee_role, 'member')
                      AND a.access_level = 'fork'
               )
           ) AS is_forkable,
           s.source_owner_schema,
           s.source_skill_id,
           s.updated_at
      FROM visible_skills s
      LEFT JOIN tagged t
        ON t.owner_schema = s.owner_schema
       AND t.skill_id = s.skill_id
)
SELECT *
  FROM scored
 WHERE score > 0
    OR (p_query IS NULL AND p_subject IS NULL AND p_verb IS NULL)
 ORDER BY score DESC, is_public DESC, updated_at DESC, skill_name
 LIMIT GREATEST(COALESCE(p_limit, 20), 1)
$body$;

REVOKE ALL ON FUNCTION find_skill(text, text, text, malu_vector, name, integer, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION find_skill(text, text, text, malu_vector, name, integer, boolean)
TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;
```

- [ ] **Step 3: Add schema-local wrapper**

In `_enable_memory_schema_ai_facade`, add:

```sql
PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_skill_search', 'function');
EXECUTE format($sql$
    CREATE OR REPLACE FUNCTION %I.maludb_skill_search(
        p_query text DEFAULT NULL,
        p_subject text DEFAULT NULL,
        p_verb text DEFAULT NULL,
        p_query_embedding maludb_core.malu_vector DEFAULT NULL,
        p_limit integer DEFAULT 20,
        p_include_public boolean DEFAULT true
    ) RETURNS TABLE (
        owner_schema name,
        skill_id bigint,
        skill_name text,
        version text,
        description text,
        visibility text,
        subjects text[],
        verbs text[],
        keywords text[],
        score numeric,
        match_reasons text[],
        is_public boolean,
        is_forkable boolean,
        source_owner_schema name,
        source_skill_id bigint,
        updated_at timestamptz
    )
    LANGUAGE SQL
    SECURITY DEFINER
    SET search_path = pg_catalog, maludb_core, pg_temp
    AS $fn$
        SELECT *
          FROM maludb_core.find_skill(
              p_query,
              p_subject,
              p_verb,
              p_query_embedding,
              %L::name,
              p_limit,
              p_include_public
          )
    $fn$;
$sql$, p_schema, p_schema);
EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_skill_search(text, text, text, maludb_core.malu_vector, integer, boolean) TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor', p_schema);
PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_skill_search', 'function', 'Schema-local skill discovery search wrapper.');
v_count := v_count + 1;
```

- [ ] **Step 4: Generate expected output**

Run:

```bash
/usr/lib/postgresql/17/lib/pgxs/src/test/regress/pg_regress \
  --use-existing --dbname=contrib_regression --inputdir=. --outputdir=/tmp/skill-search \
  skill_discovery
cp /tmp/skill-search/results/skill_discovery.out expected/skill_discovery.out
perl -0pi -e 's/[ \t]+$//mg' expected/skill_discovery.out
```

- [ ] **Step 5: Verify search test passes**

```bash
/usr/lib/postgresql/17/lib/pgxs/src/test/regress/pg_regress \
  --use-existing --dbname=contrib_regression --inputdir=. --outputdir=/tmp/skill-search-2 \
  skill_discovery
```

Expected: `All 1 tests passed.`

- [ ] **Step 6: Commit search API**

```bash
git add sql/extension/maludb_core--0.72.0--0.73.0.sql sql/skill_discovery.sql expected/skill_discovery.out
git commit -m "feat: add skill discovery search"
```

---

### Task 6: Full Skill Get And Fork API

**Files:**
- Modify: `sql/extension/maludb_core--0.72.0--0.73.0.sql`
- Create: `sql/skill_discovery_fork.sql`
- Create: `expected/skill_discovery_fork.out`
- Modify: `Makefile`

- [ ] **Step 1: Create fork regression**

Create `sql/skill_discovery_fork.sql`:

```sql
\set ECHO all
\pset format unaligned
SET client_min_messages = NOTICE;
CREATE EXTENSION IF NOT EXISTS maludb_core CASCADE;
SET search_path TO maludb_core, public;

DROP SCHEMA IF EXISTS fork_a CASCADE;
DROP SCHEMA IF EXISTS maludb_public CASCADE;
DROP ROLE IF EXISTS fork_user_a;
DROP ROLE IF EXISTS maludb_skill_curator;

CREATE ROLE fork_user_a NOLOGIN;
CREATE ROLE maludb_skill_curator NOLOGIN;
GRANT maludb_memory_executor TO fork_user_a;
GRANT maludb_memory_admin TO maludb_skill_curator;
GRANT USAGE ON SCHEMA maludb_core TO fork_user_a, maludb_skill_curator;

CREATE SCHEMA fork_a AUTHORIZATION fork_user_a;
CREATE SCHEMA maludb_public AUTHORIZATION maludb_skill_curator;
SELECT maludb_core.enable_memory_schema('fork_a') IS NOT NULL AS fork_schema_enabled;
SELECT maludb_core.enable_memory_schema('maludb_public') IS NOT NULL AS public_schema_enabled;

SET ROLE maludb_skill_curator;
SET search_path TO maludb_public, maludb_core, public;

INSERT INTO maludb_skill(skill_name, version, description, packaging_kind, visibility)
VALUES ('public_skill_to_fork', '1.0.0', 'A public skill that tenants can fork.', 'markdown', 'public')
RETURNING skill_id AS public_skill_id;

INSERT INTO maludb_skill_keyword(skill_id, keyword)
SELECT skill_id, 'public keyword'
FROM maludb_skill
WHERE skill_name = 'public_skill_to_fork';

INSERT INTO maludb_skill_state(skill_id, state_name, state_kind)
SELECT skill_id, 'start', 'start'
FROM maludb_skill
WHERE skill_name = 'public_skill_to_fork';

RESET ROLE;
SET ROLE fork_user_a;
SET search_path TO fork_a, maludb_core, public;

SELECT maludb_skill_fork(
    p_source_owner_schema => 'maludb_public',
    p_source_skill_id => (
        SELECT skill_id
        FROM maludb_core.malu$skill_package
        WHERE owner_schema = 'maludb_public'
          AND skill_name = 'public_skill_to_fork'
    ),
    p_new_skill_name => 'tenant_forked_skill'
) IS NOT NULL AS fork_created;

SELECT skill_name, source_owner_schema, source_skill_id IS NOT NULL AS has_source
FROM maludb_skill
WHERE skill_name = 'tenant_forked_skill';

SELECT keyword
FROM maludb_skill_keyword
WHERE skill_id = (SELECT skill_id FROM maludb_skill WHERE skill_name = 'tenant_forked_skill')
ORDER BY keyword;

SELECT payload ? 'skill' AS has_skill,
       payload ? 'keywords' AS has_keywords,
       payload ? 'states' AS has_states
FROM maludb_skill_get(
    p_owner_schema => 'fork_a',
    p_skill_id => (SELECT skill_id FROM maludb_skill WHERE skill_name = 'tenant_forked_skill')
) AS got(payload);

RESET ROLE;
SET search_path TO maludb_core, public;
DROP SCHEMA fork_a CASCADE;
DROP SCHEMA maludb_public CASCADE;
DROP OWNED BY fork_user_a;
DROP OWNED BY maludb_skill_curator;
DROP ROLE fork_user_a;
DROP ROLE maludb_skill_curator;
```

- [ ] **Step 2: Add `get_skill`**

Append:

```sql
CREATE FUNCTION get_skill(
    p_owner_schema name,
    p_skill_id bigint,
    p_requesting_schema name DEFAULT current_schema()
) RETURNS TABLE (payload jsonb)
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
    SELECT jsonb_build_object(
        'skill', to_jsonb(s),
        'keywords', COALESCE((
            SELECT jsonb_agg(to_jsonb(k) ORDER BY k.keyword)
              FROM maludb_core.malu$skill_keyword k
             WHERE k.owner_schema = s.owner_schema
               AND k.skill_id = s.skill_id
        ), '[]'::jsonb),
        'subjects', COALESCE((
            SELECT jsonb_agg(to_jsonb(subj) ORDER BY subj.subject_name)
              FROM maludb_core.malu$skill_subject subj
             WHERE subj.owner_schema = s.owner_schema
               AND subj.skill_id = s.skill_id
        ), '[]'::jsonb),
        'verbs', COALESCE((
            SELECT jsonb_agg(to_jsonb(v) ORDER BY v.verb_name)
              FROM maludb_core.malu$skill_verb v
             WHERE v.owner_schema = s.owner_schema
               AND v.skill_id = s.skill_id
        ), '[]'::jsonb),
        'states', COALESCE((
            SELECT jsonb_agg(to_jsonb(st) ORDER BY st.state_name)
              FROM maludb_core.malu$skill_state st
             WHERE st.owner_schema = s.owner_schema
               AND st.skill_id = s.skill_id
        ), '[]'::jsonb),
        'transitions', COALESCE((
            SELECT jsonb_agg(to_jsonb(tr) ORDER BY tr.ordinal, tr.transition_id)
              FROM maludb_core.malu$skill_transition tr
             WHERE tr.owner_schema = s.owner_schema
               AND tr.skill_id = s.skill_id
        ), '[]'::jsonb)
    ) AS payload
      FROM maludb_core.malu$skill_package s
     WHERE s.owner_schema = p_owner_schema
       AND s.skill_id = p_skill_id
       AND maludb_core._skill_is_visible(s.owner_schema, s.skill_id, p_requesting_schema, true)
$body$;

REVOKE ALL ON FUNCTION get_skill(name, bigint, name) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION get_skill(name, bigint, name)
TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;
```

- [ ] **Step 3: Add `fork_skill`**

Append:

```sql
CREATE FUNCTION fork_skill(
    p_source_owner_schema name,
    p_source_skill_id bigint,
    p_target_owner_schema name DEFAULT current_schema(),
    p_new_skill_name text DEFAULT NULL,
    p_new_version text DEFAULT '1.0.0'
) RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
DECLARE
    v_source malu$skill_package%ROWTYPE;
    v_new_skill_id bigint;
BEGIN
    SELECT * INTO v_source
      FROM maludb_core.malu$skill_package
     WHERE owner_schema = p_source_owner_schema
       AND skill_id = p_source_skill_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'fork_skill: source skill %.% not found', p_source_owner_schema, p_source_skill_id
            USING ERRCODE = 'P0002';
    END IF;

    IF NOT maludb_core._skill_is_visible(v_source.owner_schema, v_source.skill_id, p_target_owner_schema, true) THEN
        RAISE EXCEPTION 'fork_skill: source skill %.% is not visible', p_source_owner_schema, p_source_skill_id
            USING ERRCODE = '42501';
    END IF;

    IF NOT (
        v_source.owner_schema = 'maludb_public'
        OR EXISTS (
            SELECT 1
              FROM maludb_core.malu$skill_access a
             WHERE a.owner_schema = v_source.owner_schema
               AND a.skill_id = v_source.skill_id
               AND pg_has_role(current_user, a.grantee_role, 'member')
               AND a.access_level = 'fork'
        )
    ) THEN
        RAISE EXCEPTION 'fork_skill: source skill %.% is not forkable', p_source_owner_schema, p_source_skill_id
            USING ERRCODE = '42501';
    END IF;

    INSERT INTO maludb_core.malu$skill_package(
        owner_schema,
        skill_name,
        version,
        description,
        packaging_kind,
        applicability_jsonb,
        precondition_jsonb,
        enabled,
        visibility,
        source_owner_schema,
        source_skill_id,
        forked_at
    )
    VALUES (
        p_target_owner_schema,
        COALESCE(NULLIF(p_new_skill_name, ''), v_source.skill_name),
        COALESCE(NULLIF(p_new_version, ''), v_source.version),
        v_source.description,
        v_source.packaging_kind,
        v_source.applicability_jsonb,
        v_source.precondition_jsonb,
        v_source.enabled,
        'private',
        v_source.owner_schema,
        v_source.skill_id,
        now()
    )
    RETURNING skill_id INTO v_new_skill_id;

    INSERT INTO maludb_core.malu$skill_keyword(owner_schema, skill_id, keyword, weight, provenance)
    SELECT p_target_owner_schema, v_new_skill_id, keyword, weight, provenance
      FROM maludb_core.malu$skill_keyword
     WHERE owner_schema = v_source.owner_schema
       AND skill_id = v_source.skill_id;

    INSERT INTO maludb_core.malu$skill_subject(owner_schema, skill_id, subject_id, subject_name, weight, provenance)
    SELECT p_target_owner_schema, v_new_skill_id, NULL, subject_name, weight, provenance
      FROM maludb_core.malu$skill_subject
     WHERE owner_schema = v_source.owner_schema
       AND skill_id = v_source.skill_id;

    INSERT INTO maludb_core.malu$skill_verb(owner_schema, skill_id, verb_id, verb_name, weight, provenance)
    SELECT p_target_owner_schema, v_new_skill_id, NULL, verb_name, weight, provenance
      FROM maludb_core.malu$skill_verb
     WHERE owner_schema = v_source.owner_schema
       AND skill_id = v_source.skill_id;

    INSERT INTO maludb_core.malu$skill_state(owner_schema, skill_id, state_name, state_kind, step_jsonb, validation_jsonb)
    SELECT p_target_owner_schema, v_new_skill_id, state_name, state_kind, step_jsonb, validation_jsonb
      FROM maludb_core.malu$skill_state
     WHERE owner_schema = v_source.owner_schema
       AND skill_id = v_source.skill_id;

    RETURN v_new_skill_id;
END;
$body$;

REVOKE ALL ON FUNCTION fork_skill(name, bigint, name, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fork_skill(name, bigint, name, text, text)
TO maludb_memory_admin, maludb_memory_executor;
```

- [ ] **Step 4: Add wrappers**

In `_enable_memory_schema_ai_facade`, add wrappers:

```sql
CREATE OR REPLACE FUNCTION <schema>.maludb_skill_get(
    p_owner_schema name,
    p_skill_id bigint
) RETURNS TABLE (payload jsonb)
```

The body must call:

```sql
SELECT * FROM maludb_core.get_skill(p_owner_schema, p_skill_id, '<schema>'::name)
```

Add:

```sql
CREATE OR REPLACE FUNCTION <schema>.maludb_skill_fork(
    p_source_owner_schema name,
    p_source_skill_id bigint,
    p_new_skill_name text DEFAULT NULL,
    p_new_version text DEFAULT '1.0.0'
) RETURNS bigint
```

The body must call:

```sql
SELECT maludb_core.fork_skill(
    p_source_owner_schema,
    p_source_skill_id,
    '<schema>'::name,
    p_new_skill_name,
    p_new_version
)
```

- [ ] **Step 5: Generate expected output and verify fork test**

```bash
/usr/lib/postgresql/17/lib/pgxs/src/test/regress/pg_regress \
  --use-existing --dbname=contrib_regression --inputdir=. --outputdir=/tmp/skill-fork \
  skill_discovery_fork
cp /tmp/skill-fork/results/skill_discovery_fork.out expected/skill_discovery_fork.out
perl -0pi -e 's/[ \t]+$//mg' expected/skill_discovery_fork.out
/usr/lib/postgresql/17/lib/pgxs/src/test/regress/pg_regress \
  --use-existing --dbname=contrib_regression --inputdir=. --outputdir=/tmp/skill-fork-2 \
  skill_discovery_fork
```

Expected: `All 1 tests passed.`

- [ ] **Step 6: Commit get/fork API**

```bash
git add Makefile sql/extension/maludb_core--0.72.0--0.73.0.sql sql/skill_discovery_fork.sql expected/skill_discovery_fork.out
git commit -m "feat: add skill get and fork APIs"
```

---

### Task 7: MC2DB Tool Registrations

**Files:**
- Modify: `sql/extension/maludb_core--0.72.0--0.73.0.sql`
- Modify: `sql/skill_discovery.sql`

- [ ] **Step 1: Register `maludb.skill.find`**

Append MC2DB registration blocks following the existing `register_mc2db_tool` pattern:

```sql
SELECT register_mc2db_tool(
    server_name => 'maludb.r10',
    tool_name => 'skill.find',
    description => 'Find visible MaluDB skills by query, subject, verb, keyword, or embedding.',
    implementation_type => 'sql_function',
    implementation_ref => 'maludb_core.find_skill',
    input_schema => '{"type":"object","properties":{
        "query":{"type":["string","null"]},
        "subject":{"type":["string","null"]},
        "verb":{"type":["string","null"]},
        "limit":{"type":"integer","minimum":1,"maximum":100},
        "include_public":{"type":"boolean"}
    }}'::jsonb,
    output_schema => '{"type":"object","required":["results"]}'::jsonb,
    risk_class => 'read',
    read_only => true
);
```

- [ ] **Step 2: Register `maludb.skill.get`**

Append:

```sql
SELECT register_mc2db_tool(
    server_name => 'maludb.r10',
    tool_name => 'skill.get',
    description => 'Return the full executable definition for one visible MaluDB skill.',
    implementation_type => 'sql_function',
    implementation_ref => 'maludb_core.get_skill',
    input_schema => '{"type":"object","required":["owner_schema","skill_id"],"properties":{
        "owner_schema":{"type":"string"},
        "skill_id":{"type":"integer"}
    }}'::jsonb,
    output_schema => '{"type":"object","required":["payload"]}'::jsonb,
    risk_class => 'read',
    read_only => true
);
```

- [ ] **Step 3: Register `maludb.skill.fork`**

Append:

```sql
SELECT register_mc2db_tool(
    server_name => 'maludb.r10',
    tool_name => 'skill.fork',
    description => 'Fork a public or explicitly forkable MaluDB skill into the caller schema.',
    implementation_type => 'sql_function',
    implementation_ref => 'maludb_core.fork_skill',
    input_schema => '{"type":"object","required":["source_owner_schema","source_skill_id"],"properties":{
        "source_owner_schema":{"type":"string"},
        "source_skill_id":{"type":"integer"},
        "new_skill_name":{"type":["string","null"]},
        "new_version":{"type":["string","null"]}
    }}'::jsonb,
    output_schema => '{"type":"object","required":["skill_id"]}'::jsonb,
    risk_class => 'write',
    read_only => false
);
```

- [ ] **Step 4: Add regression assertion**

In `sql/skill_discovery.sql`, add:

```sql
SELECT tool_name
FROM maludb_core.malu$mc2db_tool
WHERE tool_name IN ('skill.find', 'skill.get', 'skill.fork')
ORDER BY tool_name;
```

Expected rows:

```text
skill.find
skill.fork
skill.get
```

- [ ] **Step 5: Commit MC2DB registrations**

```bash
git add sql/extension/maludb_core--0.72.0--0.73.0.sql sql/skill_discovery.sql expected/skill_discovery.out
git commit -m "feat: expose skill discovery MC2DB tools"
```

---

### Task 8: Snapshot, Docs, And Full Regression

**Files:**
- Create: `sql/extension/maludb_core--0.73.0.sql`
- Modify: `README.md`
- Modify: `docs/user-manual.md`
- Modify: `docs/admin-guide.md`
- Modify: `docs/getting-started.md`
- Modify: `CHANGELOG.md`
- Modify: expected outputs touched by version/tool count changes

- [ ] **Step 1: Generate `0.73.0` snapshot**

Copy the existing snapshot and append the new migration in the repository's established style:

```bash
cp sql/extension/maludb_core--0.72.0.sql sql/extension/maludb_core--0.73.0.sql
cat sql/extension/maludb_core--0.72.0--0.73.0.sql >> sql/extension/maludb_core--0.73.0.sql
```

- [ ] **Step 2: Update version docs**

Update:

```text
README.md
docs/user-manual.md
CHANGELOG.md
```

Required content:

```text
Extension default_version: 0.73.0
Skill discovery: manual subject/verb/keyword discovery, public skills, find/get/fork APIs.
```

- [ ] **Step 3: Add user manual examples**

Add examples:

```sql
INSERT INTO maludb_skill(skill_name, version, description, packaging_kind)
VALUES ('meeting_action_item_extractor', '1.0.0', 'Extract action items from meeting transcripts.', 'markdown');

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

SELECT payload
FROM maludb_skill_get('maludb_public', 42);
```

- [ ] **Step 4: Run focused regressions**

```bash
make PG_CONFIG=/usr/lib/postgresql/17/bin/pg_config
/usr/lib/postgresql/17/lib/pgxs/src/test/regress/pg_regress \
  --use-existing --dbname=contrib_regression --inputdir=. --outputdir=/tmp/skill-final \
  skill_discovery skill_discovery_fork schema_memory_enablement schema_memory_pool_search
```

Expected: `All 4 tests passed.`

- [ ] **Step 5: Run full installcheck on a clean install host**

On a host where the new extension files are installed:

```bash
dropdb --if-exists contrib_regression
createdb contrib_regression
make installcheck PG_CONFIG=/usr/lib/postgresql/17/bin/pg_config
```

Expected: all regression tests pass.

- [ ] **Step 6: Run consistency checks**

```bash
git diff --check
scripts/maludb-check-doc-consistency
```

Expected:

```text
maludb-check-doc-consistency: OK
```

- [ ] **Step 7: Commit release updates**

```bash
git add Makefile maludb_core.control \
  sql/extension/maludb_core--0.72.0--0.73.0.sql \
  sql/extension/maludb_core--0.73.0.sql \
  README.md docs/user-manual.md docs/admin-guide.md docs/getting-started.md CHANGELOG.md \
  expected
git commit -m "chore: release skill discovery extension update"
```

---

## Self-Review Checklist

- Spec coverage: Tasks cover manual subjects, verbs, keywords, embeddings, public skills, shared access, find/get/fork, schema-local facades, MCP/API discovery, and docs.
- Placeholder scan: No task depends on an undefined file path or undefined API name.
- Type consistency: Function names are `find_skill`, `get_skill`, `fork_skill`, and schema-local wrappers are `maludb_skill_search`, `maludb_skill_get`, and `maludb_skill_fork`.
- Versioning: Plan targets `0.73.0` because `0.72.0` is already the schema memory enablement release.
