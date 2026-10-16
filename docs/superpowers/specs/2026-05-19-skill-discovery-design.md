# Skill Discovery Design

**Date:** 2026-05-19

## Goal

MaluDB skills need to be discoverable by humans, LLM agents, MCP servers, and
API clients without requiring callers to already know exact skill names. The
initial build should support manual curation through subjects, verbs, keywords,
and optional description embeddings. Model-curated tags and keywords are a
future extension and are intentionally out of scope for the first build.

The discovery model must work with schema-local memory enablement. A caller
should see skills owned by the active schema, skills explicitly shared with the
caller, and read-only public skills owned by a curated public schema.

Implementation target: a new extension migration after `0.72.0`, expected to
be `0.72.0 -> 0.73.0` unless another migration lands first.

## Existing Context

`malu$skill_package` is the canonical skill package table. It is owner-scoped
with `owner_schema`, `skill_name`, `version`, `description`,
`packaging_kind`, `applicability_jsonb`, `precondition_jsonb`, and `enabled`.
Schema memory enablement exposes tenant-owned rows through `maludb_skill`,
plus related skill state, transition, and execution facades.

MaluDB also has owner-scoped subject and verb registries, vector compartments,
memory pools, MCP catalog tables, and schema-local facades. The skill discovery
build should use those patterns instead of creating an unrelated search model.

## Design Summary

Use a hybrid registry design:

- Keep `malu$skill_package` as the canonical skill definition anchor.
- Add normalized discovery tables for manual subjects, verbs, and keywords.
- Add a skill embedding table for optional skill-description embeddings.
- Add public/shared/private visibility rules.
- Add a reserved public owner schema, `maludb_public`, for curated read-only
  skills.
- Add two-step APIs:
  - `find_skill` returns lightweight search metadata and match reasons.
  - `get_skill` returns the full executable skill definition after selection.
- Add a fork API so tenant schemas can copy public/shared skills and customize
  their own versions.

## Visibility Model

Skill discovery combines three result sources:

1. **Current schema skills**
   Rows where `owner_schema = current_schema()` or the schema passed to a
   schema-local wrapper. These are writable through that schema's facades.

2. **Shared skills**
   Rows made visible through explicit `malu$skill_access` grants. Memory-pool
   membership can influence ranking when the selected pool contains a skill,
   but pool membership is not the primary access-control mechanism in the first
   build.

3. **Public skills**
   Rows where `owner_schema = 'maludb_public'`. These are searchable and
   readable by everyone with MaluDB memory executor/auditor access, but writable
   only by MaluDB admins or a dedicated curator role.

`maludb_public` is a real PostgreSQL schema name and a real `owner_schema`
value. The underlying rows still live in `maludb_core` tables.

## Canonical Tables

### Skill Package Additions

Add minimal fields to `malu$skill_package`:

```text
visibility          text not null default 'private'
source_owner_schema name
source_skill_id     bigint
forked_at           timestamptz
```

Valid `visibility` values:

```text
private
shared
public
```

Rules:

- `public` is valid only when `owner_schema = 'maludb_public'`, unless a later
  release introduces public namespaces outside that schema.
- Forked skills keep lineage through `source_owner_schema`, `source_skill_id`,
  and `forked_at`.
- Skill versions remain scoped by `(owner_schema, skill_name, version)`.

### `malu$skill_keyword`

Manual keyword tags for discovery.

```text
keyword_id    bigserial primary key
owner_schema  name not null
skill_id      bigint not null
keyword       text not null
weight        numeric not null default 1.0
provenance    text not null default 'manual'
created_at    timestamptz not null default now()
```

Constraints:

- Foreign key `(owner_schema, skill_id)` to `malu$skill_package`.
- Unique `(owner_schema, skill_id, lower(keyword))`.
- `provenance = 'manual'` in the first build.
- Future allowed provenance values can include `model_suggested`,
  `model_accepted`, and `imported`, but they should not affect initial search.

### `malu$skill_subject`

Manual subject tags for discovery.

```text
skill_subject_id bigserial primary key
owner_schema     name not null
skill_id         bigint not null
subject_id       bigint
subject_name     text not null
weight           numeric not null default 1.0
provenance       text not null default 'manual'
created_at       timestamptz not null default now()
```

Rules:

- Prefer `subject_id` when the subject exists in `malu$svpor_subject`.
- Keep `subject_name` denormalized for stable display and import workflows.
- Foreign key `(owner_schema, skill_id)` to `malu$skill_package`.
- Composite foreign key `(owner_schema, subject_id)` to `malu$svpor_subject`
  when `subject_id` is present.

### `malu$skill_verb`

Manual verb tags for discovery.

```text
skill_verb_id bigserial primary key
owner_schema  name not null
skill_id      bigint not null
verb_id       bigint
verb_name     text not null
weight        numeric not null default 1.0
provenance    text not null default 'manual'
created_at    timestamptz not null default now()
```

Rules mirror `malu$skill_subject`, using `malu$svpor_verb`.

### `malu$skill_embedding`

Optional description embeddings for semantic discovery.

```text
embedding_id      bigserial primary key
owner_schema      name not null
skill_id          bigint not null
embedding_model   text not null
embedding_dim     integer not null
embedding         malu_vector not null
source_text_hash  text not null
source_text_kind  text not null default 'description'
created_at        timestamptz not null default now()
```

Rules:

- Embeddings are optional. A skill remains searchable by subject, verb,
  keyword, and full-text even when no embedding exists.
- A skill can have multiple embeddings if different models or source text kinds
  are used.
- The first build stores embeddings directly here. A later build can bridge to
  existing vector compartments if we want unified vector routing for skills.

### `malu$skill_access`

Explicit shared-skill visibility.

```text
access_id     bigserial primary key
owner_schema  name not null
skill_id      bigint not null
grantee_role  name not null
access_level  text not null default 'read'
created_at    timestamptz not null default now()
```

Valid access levels:

```text
read
execute
fork
admin
```

The first build should use `read` and `fork`. `execute` and `admin` are
reserved for later runtime policy integration.

Access rows never grant write access to the source skill package. Customization
requires `fork_skill`, which creates a tenant-owned copy.

## Search API

### `find_skill`

Core function:

```sql
maludb_core.find_skill(
    p_query text DEFAULT NULL,
    p_subject text DEFAULT NULL,
    p_verb text DEFAULT NULL,
    p_query_embedding maludb_core.malu_vector DEFAULT NULL,
    p_owner_schema name DEFAULT current_schema(),
    p_limit integer DEFAULT 20,
    p_include_public boolean DEFAULT true
)
```

Schema-local wrapper:

```sql
maludb_skill_search(
    p_query text DEFAULT NULL,
    p_subject text DEFAULT NULL,
    p_verb text DEFAULT NULL,
    p_query_embedding maludb_core.malu_vector DEFAULT NULL,
    p_limit integer DEFAULT 20,
    p_include_public boolean DEFAULT true
)
```

Returned columns:

```text
owner_schema
skill_id
skill_name
version
description
visibility
subjects
verbs
keywords
score
match_reasons
is_public
is_forkable
source_owner_schema
source_skill_id
updated_at
```

Ranking order:

1. Exact subject and verb match.
2. Subject-only or verb-only match.
3. Keyword match.
4. Full-text match over `skill_name` and `description`.
5. Embedding similarity when both `p_query_embedding` and a skill embedding are
   present.
6. Enabled skills before disabled skills.
7. Newer `updated_at` as a tie-breaker.

Manual tags are the only tag rows used in the first build.

### `get_skill`

Core function:

```sql
maludb_core.get_skill(
    p_owner_schema name,
    p_skill_id bigint,
    p_requesting_schema name DEFAULT current_schema()
)
```

Schema-local wrapper:

```sql
maludb_skill_get(
    p_owner_schema name,
    p_skill_id bigint
)
```

Returned payload should include:

```text
skill package metadata
full description
packaging kind
applicability JSON
precondition JSON
subjects
verbs
keywords
states
transitions
related MCP server/tool/prompt/resource rows where owner/access allows it
visibility and access policy summary
lineage source
```

`get_skill` enforces stronger access than `find_skill`. Search metadata can be
broadly visible; the full package is returned only for current-schema, public,
or explicitly shared skills.

### `fork_skill`

Core function:

```sql
maludb_core.fork_skill(
    p_source_owner_schema name,
    p_source_skill_id bigint,
    p_target_owner_schema name DEFAULT current_schema(),
    p_new_skill_name text DEFAULT NULL,
    p_new_version text DEFAULT '1.0.0'
)
```

Schema-local wrapper:

```sql
maludb_skill_fork(
    p_source_owner_schema name,
    p_source_skill_id bigint,
    p_new_skill_name text DEFAULT NULL,
    p_new_version text DEFAULT '1.0.0'
)
```

Behavior:

- Requires the source skill to be public or explicitly forkable.
- Copies the skill package row into the target schema.
- Copies manual subject, verb, and keyword rows.
- Copies skill states and transitions.
- Records source lineage on the forked package.
- Does not copy embeddings by default unless the source text hash still matches.
  Prefer marking embedding regeneration as pending in a later embedding job
  workflow.

## Schema-Local Facades

`enable_memory_schema` should create or refresh:

```text
maludb_skill_keyword
maludb_skill_subject
maludb_skill_verb
maludb_skill_embedding
maludb_skill_access
maludb_skill_search(...)
maludb_skill_get(...)
maludb_skill_fork(...)
```

Normal tenant schemas get read/write access to their own discovery metadata.
`maludb_public` gets the same underlying structures, but non-curator roles see
public skills read-only through search/get APIs.

The migration must not rely only on schema-local view grants to protect
`maludb_public`. Public write protection must be enforced in base-table RLS,
security-definer API checks, or both, so a broadly granted memory role cannot
update public skills by changing `search_path`.

## Public Skills

Create a reserved public schema:

```text
maludb_public
```

The operator can enable it like any other schema:

```sql
CREATE SCHEMA maludb_public;
SELECT maludb_core.enable_memory_schema('maludb_public');
```

Recommended roles:

```text
maludb_skill_curator
```

Curators can insert/update public skill packages and discovery tags. Regular
memory executor/auditor roles can search and read public skill metadata and
full definitions, but cannot modify public rows.

If `enable_memory_schema('maludb_public')` creates writable-looking facades for
the curator role, non-curator roles still receive only read/search privileges
for that schema.

## MCP And API Usage

MCP/API clients should use the two-step flow:

1. Call `find_skill` with a natural-language query, optional subject, optional
   verb, optional embedding, and caller context.
2. Present or internally choose a result.
3. Call `get_skill` for the selected `(owner_schema, skill_id)`.
4. Optionally call `fork_skill` when the caller wants to customize a public or
   shared skill.

This keeps discovery fast and lightweight while preserving a clear boundary
between searchable metadata and executable skill definitions.

## Out Of Scope For First Build

- Model-suggested tags and keywords.
- Automatic tag acceptance/rejection workflow.
- Skill execution authorization beyond existing skill execution tables.
- Automatic embedding generation jobs.
- Cross-database skill sharing.
- Replacing existing skill state/transition/runtime tables.

## Acceptance Criteria

- A tenant can manually tag a skill with keywords, subjects, and verbs.
- A tenant can find a skill by subject, verb, keyword, text query, or embedding.
- A tenant can find both its own skills and public skills in one search call.
- A tenant cannot modify `maludb_public` skills without curator privileges.
- A tenant can fork a public skill into its own schema.
- The fork retains lineage to the public source.
- `find_skill` returns lightweight metadata only.
- `get_skill` returns the full usable skill definition after access checks.
- Existing `maludb_skill`, state, transition, and execution behavior remains
  compatible.
