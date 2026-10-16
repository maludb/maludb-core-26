# Skill reindex protocol (0.99.0)

A skill's discovery tags — the rows in `malu$skill_subject`,
`malu$skill_verb`, `malu$skill_keyword` that make `find_skill` fire its
high-weight facets — are written **once**, at registration, from whatever
the API server's extractor produced (see
[agent-skills.md](agent-skills.md)). That snapshot rots two ways:

1. **The graph grows.** New subjects and verbs are minted after a skill
   was loaded. An old skill never links to vocabulary that did not exist
   when it was registered.
2. **The first extraction was weak.** If the extractor did a poor job at
   load time, the thin tag set is frozen in place and discovery silently
   degrades to the `+10` full-text fallback (the `+100` subject / `+80`
   verb facets never fire).

0.99.0 ships the **database half** of a background *reindex* that
re-derives those tags against the current graph. As everywhere else in
MaluDB, **core never calls a model** — it exposes a `claim → apply`
contract that an external worker drives.

| Layer | Repo | Role |
|---|---|---|
| `maludb_core` 0.99.0 | this repo | `last_indexed` watermark, `maludb_skill_reindex_claim`, `maludb_skill_reindex_apply` |
| reindex worker | `maludb-python-api-server` | poll → re-extract with the best model → apply (**not yet built**) |

This mirrors how 0.95.0 shipped the embedding dirty-queue protocol with
the worker deferred: the in-DB contract lands first; until something
drives the loop, skills simply keep their load-time tags — nothing breaks.

## What core added

`malu$skill_package` gains two lifecycle columns (both untouched by the
0.97.0 content-immutability guard, which only freezes `markdown` /
`bundle_hash` / `frontmatter_jsonb` / `skill_name`):

| Column | Meaning |
|---|---|
| `last_indexed` | timestamp of the last successful reindex; `NULL` = never indexed (highest priority). The watermark that stops repeat work. |
| `last_indexed_model` | which model produced the current tags. The hook for migrating to a cheaper model later: a future sweep can re-pick rows tagged by a superseded model. |

## The worker loop

```text
loop:
    rows = maludb_skill_reindex_claim(limit := 32, max_age := '30 days')
    if not rows:
        sleep(backoff); continue
    for r in rows:
        # worker side — the only place a model runs
        tags = model.extract(r.markdown, current_registry := load_subject_verb_catalog())
        maludb_skill_reindex_apply(
            r.skill_id,
            subjects := tags.subjects,   # [{"name": "...", "id": <optional>, "weight": <optional>}]
            verbs    := tags.verbs,      # same shape
            keywords := tags.keywords,   # text[]
            model    := MODEL_ID)        # recorded as last_indexed_model
```

Start with the best available model to prove the loop produces good tags;
refine toward a cheaper/faster model over time and use `last_indexed_model`
to force a re-sweep of anything the old model touched.

### `maludb_skill_reindex_claim(p_limit, p_max_age, p_only_registered)`

Read-only (auditor role has EXECUTE). Returns the **stalest skills first**
with everything the worker needs — the body, frontmatter, and the *current*
tag set so the model can see what already exists:

`skill_id, skill_name, version, description, markdown, frontmatter_jsonb,
bundle_hash, last_indexed, last_indexed_model, current_subjects,
current_verbs, current_keywords`

A skill is claimed when it is `enabled` and (by default) has a
`bundle_hash`, and any of:

- `last_indexed IS NULL` (never indexed), or
- `last_indexed < now() - p_max_age` (periodic refresh; default 30 days), or
- `last_indexed < ` the **registry watermark** — `max(created_at)` over
  this tenant's `malu$svpor_subject` and `malu$svpor_verb`.

| Param | Default | Notes |
|---|---|---|
| `p_limit` | `32` | clamped to `[1, 500]` |
| `p_max_age` | `'30 days'` | `NULL` disables the periodic clause |
| `p_only_registered` | `true` | `false` also sweeps non-bundle skills |

**Watermark caveat:** `created_at` catches subject/verb *additions*. Edits
to an existing subject's aliases/description are not timestamped on those
tables, so they are picked up by the periodic `p_max_age` clause rather
than instantly.

It is a plain ranked scan — no queue, no locks. `apply` stamps
`last_indexed` and is idempotent, so overlapping sweeps merely redo
equivalent work.

### `maludb_skill_reindex_apply(p_skill_id, p_subjects, p_verbs, p_keywords, p_model)`

A write (executor role; **curator-only in `maludb_public`**, matching the
`maludb_skill_register` posture). **Replace-extracted**, in one
transaction:

1. delete the skill's `provenance='extracted'` subject/verb/keyword rows;
2. rewrite them from the fresh extraction (same name→id resolution as
   registration — a supplied `id` is honoured only if it still resolves in
   this tenant's registry, else stored as a name-only tag);
3. stamp `last_indexed = now()` and `last_indexed_model`.

`provenance='manual'` curator tags are **never** touched. Because apply can
remove tags, it corrects a bad initial load — not just augment it. Returns:

```json
{
  "skill_id": 42,
  "last_indexed_model": "claude-opus-4-8",
  "replaced": { "subjects": 1, "verbs": 1, "keywords": 1 },
  "written":  { "subjects": 1, "verbs": 1, "keywords": 1 }
}
```

## Out of scope (this release)

- The worker itself (model calls) — built in the API-server session.
- Re-minting the skill-as-entity `'skill'` subject — idempotent, a worker
  concern via `maludb_memory_ingest_extraction`.
- `malu$skill_embedding` refresh — belongs to the
  [semantic-entity embedding queue](semantic-entity-embeddings.md), not here.
- A trigger-fed dirty queue — the cron staleness scan is intentional;
  `last_indexed` leaves room to add a queue later without changing this
  facade contract.
