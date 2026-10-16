# SVPOR Related Subjects Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add explicit, canonical, symmetric Subject-to-Subject related-subject storage and schema-local APIs for V4 desktop sync.

**Architecture:** Keep general graph edges in `malu$relationship_edge`, but add a dedicated `malu$svpor_subject_relationship` table for pair uniqueness, direct subject FKs, cascade delete, label preservation, and idempotent pair writes. Tenant schemas receive facades through `enable_memory_schema()`.

**Tech Stack:** PostgreSQL extension SQL, PGXS regression tests, schema-local MaluDB facade generation.

---

### Task 1: Regression Coverage

**Files:**
- Create: `sql/svpor_related_subjects.sql`
- Create: `expected/svpor_related_subjects.out`
- Modify: `Makefile`

- [ ] **Step 1: Write the failing regression**

Create `sql/svpor_related_subjects.sql` with a tenant schema, three subjects, related-subject creates from both directions, self-link rejection, missing-subject rejection, deterministic listing, label refresh, delete, and cascade checks.

- [ ] **Step 2: Wire the regression**

Add `svpor_related_subjects` to `REGRESS` in `Makefile`.

- [ ] **Step 3: Verify RED**

Run:

```bash
make installcheck REGRESS=svpor_related_subjects
```

Expected on an installed `0.75.0` extension: failure because `maludb_related_subject_add` does not exist.

### Task 2: Extension DDL

**Files:**
- Create: `sql/extension/maludb_core--0.75.0--0.76.0.sql`
- Create: `sql/extension/maludb_core--0.76.0.sql`
- Modify: `maludb_core.control`
- Modify: `Makefile`

- [ ] **Step 1: Bump extension version**

Set `default_version = '0.76.0'` in `maludb_core.control`, add both new extension SQL files to `DATA`, and make `maludb_core_version()` return `0.76.0`.

- [ ] **Step 2: Add core table**

Add `malu$svpor_subject_relationship` with primary key `(owner_schema, subject_a_id, subject_b_id)`, check `subject_a_id < subject_b_id`, FK cascades to `malu$svpor_subject(owner_schema, subject_id)`, label columns, `label`, `metadata_jsonb`, and `created_at`.

- [ ] **Step 3: Add label triggers**

Add an insert/update trigger to populate `subject_a_label` and `subject_b_label`, plus an `AFTER UPDATE OF canonical_name` trigger on `malu$svpor_subject` to refresh denormalized labels.

- [ ] **Step 4: Add public functions**

Add `add_svpor_related_subject(bigint,bigint,text,jsonb)`, `list_svpor_related_subjects(bigint)`, and `delete_svpor_related_subject(bigint,bigint)`. The writer/deleter must canonicalize with `LEAST/GREATEST`, reject self-links, and return deterministic rows.

- [ ] **Step 5: Add schema-local facades**

Extend `enable_memory_schema()` with `maludb_related_subject`, `maludb_related_subject_add`, `maludb_related_subjects`, and `maludb_related_subject_delete`.

### Task 3: Expected Outputs and Verification

**Files:**
- Modify: `expected/load.out`
- Modify: `expected/catalog.out`
- Modify: `expected/schema_memory_enablement.out`
- Modify: `expected/svpor_related_subjects.out`

- [ ] **Step 1: Generate/adjust expected output**

Update expected version output to `0.76.0`, catalog table counts, and schema object counts.

- [ ] **Step 2: Run focused verification**

Run:

```bash
make
make installcheck REGRESS="svpor_related_subjects schema_memory_enablement load catalog"
git diff --check
```

Expected: build and whitespace checks pass; installcheck passes where the installed extension files are available.

## Self-Review

- Spec coverage: pair uniqueness, canonical symmetric storage, self-link prevention, tenant scoping, FK cascade, label preservation/refresh, idempotent create, deterministic lookup, and absent delete behavior all map to Tasks 1 and 2.
- Placeholder scan: no task requires unspecified API names; the public and tenant function names are fixed.
- Type consistency: this core extension uses `owner_schema` instead of edge V4 `tenant_id/user_id`; V4 sync can map tenant/user scope onto schema-local facades.
