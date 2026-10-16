---
name: using-maludb-skills
description: >-
  Load, find, and query agent skills stored in a MaluDB (maludb_core) database.
  Use when you need to register a SKILL.md bundle into the knowledge graph,
  search for an existing skill by subject/verb/keyword or semantic match, or
  fetch a skill's markdown and files so it can be used. Covers the
  maludb_skill_register / maludb_skill_search / maludb_skill_get facades, the
  SVPOR discovery-tag scoring model, visibility and search_path rules, and the
  background reindex that keeps tags fresh.
version: 1.0.0
---

# Using skills in MaluDB

MaluDB stores Claude Agent Skills as **immutable, multi-file artifacts** and
makes them discoverable through the knowledge graph. Three operations cover the
whole lifecycle:

| Operation | Facade | Purpose |
|---|---|---|
| **Load** | `maludb_skill_register(...)` | register a SKILL.md bundle + its discovery tags |
| **Find** | `maludb_skill_search(...)` | ranked discovery by subject / verb / keyword / text / vector |
| **Query** | `maludb_skill_get(owner_schema, skill_id)` | pull the full skill (markdown, files, policy) so it can be used |

All three are **per-schema facades** that `enable_memory_schema()` installs into
your tenant schema; the underlying engine lives in `maludb_core`.

## Prerequisites

```sql
-- 1. The schema must have been enabled once (creates the facades):
SELECT maludb_core.enable_memory_schema('myschema');

-- 2. Every session: put your schema + maludb_core on the search_path.
SET search_path TO myschema, maludb_core, public;
```

- **Roles.** The facades are granted to `maludb_memory_admin`,
  `maludb_memory_executor`, and `maludb_memory_auditor`. Reading (find/query)
  works for `auditor` (read-only); loading needs `executor`/`admin`.
- **Visibility.** You can see skills in your own schema, `public` skills in
  `maludb_public` (when `p_include_public => true`), and skills explicitly
  granted to your role. Anything else is invisible — `maludb_skill_get` on a
  skill you can't see returns no rows.
- **search_path is the #1 footgun.** If your schema + `maludb_core` aren't on
  it, you'll get `relation "maludb_skill" does not exist`. Persist it with
  `ALTER ROLE <role> SET search_path TO <schema>, maludb_core, public`.

## How discovery works (the model)

A skill is a row in `malu$skill_package` (name, version, `markdown`,
`bundle_hash`, frontmatter, visibility). It becomes **findable** through
discovery-tag edges into the SVPOR graph, which `maludb_skill_search` scores:

| Facet | Source | Weight |
|---|---|---|
| Subject exact match | `malu$skill_subject` | +100 |
| Verb exact match | `malu$skill_verb` | +80 |
| Keyword match | `malu$skill_keyword` | +40 |
| Full-text (name + description) | `malu$skill_package` | +10 |
| Embedding cosine similarity | `malu$skill_embedding` | +[0..1] |

The high-weight facets only fire if the skill was tagged with good
subjects/verbs at load time — so **tag quality determines discoverability**.

## 1. Load a skill into the database

```sql
-- maludb_skill_register(
--   p_skill_name, p_markdown, p_bundle_hash,
--   p_description, p_frontmatter, p_version,
--   p_keywords, p_subjects, p_verbs, p_files,
--   p_parent_owner_schema, p_parent_skill_id,
--   p_materially_different, p_enabled)
SELECT maludb_skill_register(
    p_skill_name  => 'pdf-invoice-extractor',
    p_markdown    => $md$# PDF invoice extractor
Extract line items and totals from PDF invoices.$md$,
    p_bundle_hash => encode(sha256(convert_to('pdf-invoice-extractor@1.0.0','utf8')), 'hex'),
    p_description => 'Extract line items and totals from PDF invoices.',
    p_keywords    => ARRAY['pdf','invoice','accounts payable'],
    p_subjects    => '[{"name":"invoice"},{"name":"PDF document"}]'::jsonb,
    p_verbs       => '[{"name":"extract"}]'::jsonb
);
-- returns jsonb: {"skill_id":42,"skill_name":"...","version":"...","reused":false,"tags":{...}}
```

Key points:

- **`p_bundle_hash`** must be 64 lowercase hex (a SHA256). It is the content
  identity: re-registering the same name + hash is an idempotent no-op
  (`reused: true`). In production the API computes it over the sorted file
  hashes of the bundle; the `encode(sha256(...))` above is fine for a
  single-file/manual register.
- **`p_subjects` / `p_verbs`** are JSONB arrays of `{"name": ..., "id"?: ...,
  "weight"?: ...}`; **`p_keywords`** is `text[]`. These are what make the skill
  findable. **The database does not derive them from the markdown** — the
  caller (normally the API server's LLM extraction step) must supply good tags,
  or discovery degrades to the +10 full-text fallback.
- **`p_files`** (optional) is a JSONB array of bundle-manifest entries; each
  references a `malu$source_package` row already holding the file bytes.
- **Immutability.** Once `bundle_hash` is set, the content columns
  (`markdown`, `bundle_hash`, `frontmatter_jsonb`, `skill_name`) are frozen by a
  trigger — change a skill by registering a **new** version (link it to its
  parent via `p_parent_owner_schema`/`p_parent_skill_id`). Lifecycle columns
  (`enabled`, `visibility`, `description`) stay mutable.

## 2. Find a skill

```sql
-- maludb_skill_search(p_query, p_subject, p_verb, p_query_embedding,
--                     p_limit, p_include_public)  -- all optional
SELECT skill_id, owner_schema, skill_name, version,
       score, match_reasons, subjects, verbs, keywords
FROM maludb_skill_search(
    p_query   => 'accounts payable',
    p_subject => 'invoice',
    p_verb    => 'extract',
    p_limit   => 10,
    p_include_public => true
)
ORDER BY score DESC;
```

- Use whichever facets you have — subject only, keyword only, or a vector:
  ```sql
  SELECT skill_name, score, match_reasons FROM maludb_skill_search(p_subject => 'invoice');
  SELECT skill_name, score FROM maludb_skill_search(
      p_query_embedding => '[0.1,0.2,...]'::maludb_core.malu_vector, p_limit => 5);
  ```
- **`match_reasons`** (e.g. `{subject,verb}`) tells you which facets fired —
  use it to confirm the high-weight tags matched rather than the text fallback.
- The result gives you `owner_schema` + `skill_id`, which you pass to step 3.

Plain browse (no ranking) via the view:

```sql
SELECT skill_id, skill_name, version, visibility, enabled, last_indexed
FROM maludb_skill
WHERE enabled
ORDER BY updated_at DESC;
```

## 3. Query a skill so it can be used

```sql
-- maludb_skill_get(p_owner_schema, p_skill_id) -> one jsonb `payload`
SELECT payload FROM maludb_skill_get('myschema', 42);
```

The `payload` bundles everything needed to use the skill: `skill` (the row,
including `markdown`, `bundle_hash`, `frontmatter_jsonb`, `last_indexed`),
`keywords`, `subjects`, `verbs`, `files` (the bundle manifest),
`states`/`transitions`, and `access_policy`. Pull specific fields:

```sql
SELECT payload->'skill'->>'skill_name'        AS name,
       payload->'skill'->>'markdown'          AS body,        -- the instructions
       payload->'files'                        AS files,       -- manifest to reconstruct the bundle
       payload->'access_policy'->>'is_public'  AS is_public
FROM maludb_skill_get('maludb_public', 42);
```

Typical end-to-end flow: **search** → take the top result's `owner_schema` +
`skill_id` → **get** → use `payload->'skill'->>'markdown'` (and reconstruct any
files from `payload->'files'`).

## Keeping discovery fresh (reindex)

Discovery tags can go stale (new subjects/verbs get minted later, or the first
extraction was weak). A background worker re-derives them via the
`maludb_skill_reindex_claim` → `maludb_skill_reindex_apply` contract — see
[`docs/skill-reindex.md`](../../docs/skill-reindex.md). As a querying user you
don't call these; just know that `last_indexed` on a skill reflects the last
time its tags were refreshed.

## Calling from outside an enabled schema

If you're an admin querying another tenant (no per-schema facade in scope), call
the core functions directly with explicit schema arguments:

```sql
SELECT * FROM maludb_core.find_skill(
    p_query => 'invoice', p_subject => 'invoice', p_verb => 'extract',
    p_query_embedding => NULL,
    p_owner_schema => 'myschema', p_limit => 10, p_include_public => true);

SELECT payload FROM maludb_core.get_skill('myschema', 42, 'myschema');
```

## Gotchas

- **search_path** must include your schema + `maludb_core` (see Prerequisites).
- **Tag quality is everything** — a skill loaded with no/weak subjects & verbs
  is only findable by the +10 full-text fallback. Supply real graph tags at
  register time.
- **Visibility is enforced** at both search and get; a skill you can't see
  simply doesn't appear.
- **Skills are immutable once registered** — to "edit" a skill, register a new
  version linked to its parent; don't try to UPDATE content columns.
- The agent/MCP equivalents of these operations are the `r10_skill_find` /
  `r10_skill_get` tools on the `maludb.r10` MCP server.
