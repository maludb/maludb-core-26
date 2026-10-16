# Agent-skill distribution (0.97.0)

MaluDB stores [Claude Agent Skills](https://agentskills.io) — directory
bundles of `SKILL.md` (YAML frontmatter + markdown instructions) plus
optional `scripts/`, `references/`, and `assets/` — as **immutable,
multi-file, distributable artifacts**. The database is the distribution
point: developers push skills from their machines, teammates discover them
by subject/verb/keyword, and pull reconstructs the working directory
faithfully (relative paths, executable bits, per-file hashes).

The stack has three layers:

| Layer | Repo | Role |
|---|---|---|
| `maludb_core` 0.97.0 | this repo | schema, registration, lineage, discovery |
| API server | `maludb-python-api-server` | `/v1/skills/ingest`, `/v1/skills/{id}/bundle`, LLM extraction, materiality judgment |
| `malu` CLI | `maludb-terminal` | `skill push / push-all / list / pull`, local frontmatter parsing |

No LLM runs in the CLI or the database — extraction happens in the API
server (the same Path-B division of labor as document ingest).

## The model

**A skill version is immutable.** Once registered (a row in
`malu$skill_package` with `bundle_hash` set), its content columns
(`markdown`, `bundle_hash`, `frontmatter_jsonb`, `skill_name`) reject
UPDATE — a trigger enforces this below the API. Changing a skill means
re-uploading it, which registers a **new row** whose `source_owner_schema`
/ `source_skill_id` point at the version it was modified from. Lifecycle
columns (`enabled`, `visibility`, `description`) stay mutable.

**Lineage is a strictly divergent DAG.** Versions never merge. Forks
across schemas (`maludb_skill_fork` / `POST /v1/skills/{id}/duplicate`)
carry the same lineage columns, so "who authored this, who modified it,
what changed at each hop" is queryable provenance — which matters, because
bundles contain scripts an agent will execute.

**Materially different versions coexist; trivial revisions supersede.**
On upload, the server compares the new bundle against its parent:

1. *Deterministic screens*: a changed frontmatter `description`,
   `when_to_use`, `allowed-tools`, `disallowed-tools`, or `compatibility`,
   or any added/removed/edited file other than `SKILL.md`, is **material**
   — both versions stay visible side by side.
2. *Whitespace-only* `SKILL.md` changes are **non-material** — the parent
   is superseded (`enabled = false`, dropping it out of search, payloads,
   and forkability; the row itself is retained).
3. *Gray zone* (body text changed, nothing else): an LLM judge compares
   the two instruction sets when a model is configured; otherwise the
   revision defaults to material, so nothing is hidden wrongly.

The caller can always override (`materially_different` in the API,
`--supersede` in the CLI).

**Identity is the bundle hash**, not the SKILL.md hash: sha256 over the
sorted `"<file sha256>  <relative_path>\n"` lines. A script edit changes
the skill's behavior without touching SKILL.md — the bundle hash sees it.
Re-pushing an unchanged bundle is an idempotent no-op. The version label
defaults to frontmatter `metadata.version`, falling back to the hash
prefix; collisions get a `+<hash8>` suffix.

## Schema (0.97.0)

- `malu$skill_package` + `bundle_hash`, `frontmatter_jsonb` — content
  identity. NULL on hand-curated skills, which keep their editable
  behavior.
- `malu$skill_file` — the bundle manifest: one row per file
  (`relative_path` with absolute/`..` paths rejected, `is_executable`,
  `file_hash`, `file_size`), content stored as content-hash-deduplicated
  `malu$source_package` rows (source type `skill_file`).
- `'skill'` entity subject type — each registered skill is also a graph
  subject, so extraction can wire `skill --extract--> "pdf file"` edges
  and the 0.95.0 entity-card embedding rail covers skills automatically.
- `maludb_skill_register(...)` (per-schema facade) — one-call
  registration: dedupe, version derivation, lineage stamping, discovery
  tags (`malu$skill_keyword/subject/verb`, provenance `'extracted'`),
  bundle linking, supersession.
- `get_skill` payload gains a `files` array; the `maludb_skill` facade
  exposes the new columns; new `maludb_skill_file` view.
- `fork_skill` now copies `markdown` + the bundle (re-anchoring file
  content in the target schema) — before 0.97.0 forks silently lost the
  skill body.

Re-run `enable_memory_schema('<tenant>')` after upgrading. In
`maludb_public`, skill writes remain curator-only.

## End-to-end flow

```
~/.claude/skills/pdf-processing/          malu skill push pdf-processing
├── SKILL.md            ──parse frontmatter──►  POST /v1/skills/ingest
├── scripts/extract.py                          │ 1. recompute bundle hash; dedupe
└── references/...                              │ 2. resolve parent (same name) + materiality
                                                │ 3. extract subjects/verbs/keywords
                                                │    (LLM w/ catalog prompt, or deterministic)
                                                │ 4. maludb_memory_ingest_extraction
                                                │    (SKILL.md document + skill graph subject)
                                                │ 5. files -> skill_file source packages
                                                └ 6. maludb_skill_register

malu skill list --verb extract            GET /v1/skills?verb=...  -> maludb_skill_search
malu skill pull pdf-processing            GET /v1/skills/{id}/bundle -> reconstruct dir
```

CLI quick reference:

```bash
malu skill push <dir> [--model chatgpt-4o] [--supersede] [--preview] [--json]
malu skill push-all [--root <dir>]      # scans ~/.claude/skills, ./.claude/skills
malu skill list [--query q] [--subject s] [--verb v]
malu skill pull <name|id> [--dest dir] [--force]
```

The skill-specific extraction prompt ships with the API server
(`config/prompts/skill-extract.system.txt`, placeholders
`{{ENTITY_TYPES}}`/`{{EVENT_KINDS}}` rendered from the live subject-type
catalog); register it for a model via `POST /v1/model-prompts`. Without a
model, the deterministic fallback indexes the skill from its name and
frontmatter description only (keywords + the skill subject; no guessed
verbs).

## Querying skills directly (SQL)

Beyond the CLI/API, the three lifecycle operations are plain SQL facades
that `enable_memory_schema()` installs into a tenant schema (run
`SET search_path TO <schema>, maludb_core, public` first):

- **Load** — `maludb_skill_register(p_skill_name, p_markdown, p_bundle_hash,
  p_description, p_frontmatter, p_version, p_keywords, p_subjects, p_verbs,
  p_files, ...)`. The DB does **not** derive tags from the markdown — supply
  good `p_subjects`/`p_verbs`/`p_keywords` or discovery falls back to
  full-text only.
- **Find** — `maludb_skill_search(p_query, p_subject, p_verb,
  p_query_embedding, p_limit, p_include_public)` — ranked, returning `score`
  and `match_reasons` over the subject (+100) / verb (+80) / keyword (+40) /
  full-text (+10) / embedding facets.
- **Query** — `maludb_skill_get(p_owner_schema, p_skill_id)` → a JSONB
  `payload` (skill row + `markdown`, keywords, subjects, verbs, `files`,
  access policy). Browse unranked via the `maludb_skill` view.

From outside an enabled schema, call `maludb_core.find_skill(...)` /
`maludb_core.get_skill(owner_schema, skill_id, requesting_schema)` directly.

Worked examples — load → find → query, with prerequisites, visibility, and
gotchas — live in the first-party skill bundles under
[`maludb_skills/`](../maludb_skills/), starting with
[`using-maludb-skills`](../maludb_skills/using-maludb-skills/SKILL.md).
Discovery tags are kept fresh by the background reindex
([`skill-reindex.md`](skill-reindex.md)).
