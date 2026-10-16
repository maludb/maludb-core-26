# API-server sync: maludb_core 0.94.0 + 0.95.0

How to bring the external API servers (the GPT-4o extraction worker, and any
embedding worker) in line with extension builds **0.94.0** and **0.95.0**.
Both shipped together under release tag **v4.3.0** (extension
`default_version` 0.95.0), but for sync purposes they split cleanly:

| Build | Extractor impact | What changed |
|---|---|---|
| **0.94.0** | **BREAKING** — must update in lockstep | Episodes folded into subjects; `episodes[]` removed from the ingest contract and the GPT-4o prompt. |
| **0.95.0** | **None** | Extraction JSON contract and prompt are unchanged. Adds a *new, optional* embedding-worker protocol. |

Authoritative sources in this repo: `docs/extraction-prompt-gpt-4o.md`,
`docs/memory-extraction-json-contract.md`,
`docs/semantic-entity-embeddings.md`, and the `0.94.0` / `0.95.0` sections of
`CHANGELOG.md`. The 0.94.0 fold lives in
`sql/extension/maludb_core--0.93.0--0.94.0.sql`; the 0.95.0 semantic spine in
`sql/extension/maludb_core--0.94.0--0.95.0.sql`.

---

## 0.94.0 — Episodes became a type of subject (extractor BREAKING)

A discrete occurrence (meeting, deployment, incident, task, …) is no longer a
separate `episodes[]` entry. It is now a **`subjects[]` entry that carries a
time**. `maludb_memory_ingest_extraction` **rejects** any payload containing
`episodes[]` with a hard error — a stale extractor fails fast instead of
silently dropping events:

```
memory_ingest_extraction: the episodes[] section was removed in 0.94.0;
emit events as subjects[] entries with occurred_at/occurred_until
```

> Where this lives: the schema change (`ALTER TABLE malu$episode_object ADD
> COLUMN subject_id`, the subject-minting `BEFORE INSERT` trigger, the
> backfill of pre-0.94.0 episodes, and the ingest rework) is entirely in the
> `0.93.0 → 0.94.0` migration. 0.93.0 was an unrelated repair release; the
> typed-subject infrastructure itself predates this (~0.75.0). 0.94.0 is when
> *episodes* were folded onto it.

### Contract changes (`docs/memory-extraction-json-contract.md`, 0.94.0 revision)

- An event is a `subjects[]` entry with:
  - `occurred_at` (required — this is what makes the subject an event),
  - `occurred_until` (optional end),
  - `description` (optional one-liner),
  - `type` = the event **kind** (see kind list below).
- Event keys resolve to **subject** endpoints in `edges[]`, and events may now
  appear in `relationships[]` (subject↔subject).
- Event dedup stays `(kind, title, occurred_at)`; the `malu$episode_object`
  sidecar is created automatically by the ingest.
- Canonical event names are minted **server-side** as `"<title> (YYYY-MM-DD)"`
  (UTC date of `occurred_at`). The extractor must **not** append the date.
- The ingest **report drops the `episode_attributes` counter** — event
  attributes are now ordinary node attributes. Remove any API-side reader of
  that field.

### Extraction prompt changes (`docs/extraction-prompt-gpt-4o.md`)

Update the API server's GPT-4o SYSTEM prompt to the 0.94.0 revision. The
material changes:

| Area | Before (≤0.92.0 prompt) | After (0.94.0 prompt) |
|---|---|---|
| Event section | "EVENTS BECOME EPISODES" | "EVENTS ARE SUBJECTS WITH A TIME" |
| Event shape | `episodes[]` entry with `kind` / `title` / `summary` | `subjects[]` entry with `type` = kind, `occurred_at` / `occurred_until`, optional `description` |
| Event kinds | `Meeting, Daily Standup, Review, Retrospective, 1:1, Incident, Planning, Project, Task, Sprint` (TitleCase) | `meeting, daily_standup, review, retrospective, one_on_one, incident, planning, project, task, sprint, deployment, maintenance_window` (lowercase snake_case) |
| Subject `type` list | included a bare `event` | bare `event` removed; the event kinds are used instead |
| `key` rule | "every subject **and episode** a unique key" | "every **subject** a unique key" |
| Event time | in a `value_timestamp` attribute (`event_at`) | in the subject's own `occurred_at` / `occurred_until`; *other* times still go in `value_timestamp` attributes |
| Companion text attr | `event_at_text` | `occurred_at_text` |
| KNOWN_SUBJECTS | subjects only | now also lists event subjects with **dated** canonical names, e.g. `"Oracle 21c upgrade (2026-03-30)"`; reuse the EXACT dated name for the same occurrence |
| Naming | n/a | `name` is the short title only; do **not** append the date (the system adds it) |
| HINTS edges | `episode --part_of--> project`, `person --performed--> episode`, … | `event --part_of--> project`, `person --performed--> event`, `event --located_in--> …` |
| `relationships[]` | subject↔subject only | subject↔subject, **events included** |
| Structured-output schema | arrays `subjects/verbs/episodes/edges/relationships` | `episodes` dropped → `subjects/verbs/edges/relationships`; `occurred_at`/`occurred_until`/`description` added to `subjects` as EVENTS-ONLY fields |

If the API server enforces output with JSON-schema structured outputs
(`response_format: { "type": "json_schema", … }`), **regenerate the schema**:
remove the `episodes` array; add the three event fields to the `subjects`
object.

---

## 0.95.0 — Semantic spine (no extractor change; new optional worker)

> **The extraction JSON contract and the GPT-4o prompt do NOT change in
> 0.95.0.** The migration header states it explicitly, and the prompt doc was
> not touched. An extractor running the 0.94.0 prompt is correct on 0.95.0.

0.95.0 makes subjects / verbs / edges the vector layer, embedded by an
**external worker** — *the database never calls a model*. This is only
relevant to the API servers if they are to produce embeddings.

### Why the extractor can't do it

An extractor-computed vector is a **mention** embedding (one document's view,
stale on the next attribute accretion). Entity vectors must be re-rendered
from **merged** state, so ingest writes just mark a dirty queue via triggers
and the worker re-embeds. Hence: no contract change, but a new worker loop.

### Worker protocol (per-tenant facades)

The DB enqueues changed entities into `malu$embedding_dirty` (PK-coalesced,
with a `generation` counter; the migration seeds it with every existing
entity). A worker drives:

1. **`maludb_embedding_dirty_claim`** — `FOR UPDATE SKIP LOCKED`; returns the
   deterministic card text + a sha256 content hash. Hash-unchanged and
   vanished objects auto-complete inside the claim.
2. compute the embedding for the returned card text (your model call);
3. **`maludb_embedding_complete`** — store the vector, retire the queue row,
   refresh similarity jumps. **`maludb_embedding_dirty_complete`** is
   `generation`-checked, so an edit that lands mid-embed survives (re-queues
   rather than being lost).
4. Maintenance: **`maludb_embedding_requeue_all`**,
   **`maludb_embedding_backfill`**. Card text is rendered by
   `maludb_embedding_card` (+ `subject_card_text` / `verb_card_text` /
   `statement_card_text`).

Vectors land in the existing `malu$object_embedding` rail (now carries
`content_hash`). Similarity surfaces as **opt-in** `similar_to` /
`similar_statement` traversal jumps — `uedge_neighbors` / `uedge_walk`
traverse them **only** when the caller names them in `p_rel_filter`. A
NULL/empty filter keeps every structural walk bit-identical to 0.94.0.

### Status: worker is not shipped yet

The bundled `services/maludb-embedd` daemon is **deferred to 0.96.0+**. So
0.95.0 ships the in-DB protocol but no worker. Until something drives the
claim→embed→complete loop, entities simply sit queued — **nothing breaks**,
and similarity jumps are absent (they're opt-in anyway). If you want
similarity live now, the API server implements that loop. Design:
`docs/semantic-entity-embeddings.md`.

### Related fix worth knowing

0.95.0 closes a gap where extractor-emitted `relationships[]` (written since
0.92.0) were never unioned into graph walks (`malu$edge_unified` arm 3). They
are now visible in traversal. If any API path relied on those appearing in
walks, this is the build where they start to.

---

## Sync checklist

**0.94.0 (required, in lockstep):**
- [ ] Swap the GPT-4o SYSTEM prompt to the 0.94.0 revision (table above).
- [ ] Stop emitting `episodes[]`; emit events as dated `subjects[]` with
      `occurred_at` (+ `occurred_until` / `description`) and `type` = kind.
- [ ] Feed event subjects into `KNOWN_SUBJECTS` with their dated canonical
      names so the model reuses them instead of minting duplicates.
- [ ] Drop any reader of the ingest report's `episode_attributes` field.
- [ ] If using structured outputs, regenerate the JSON schema (no `episodes`;
      new event fields on `subjects`).

**0.95.0 (optional, additive):**
- [ ] Decide whether the API servers should run the embedding worker now.
- [ ] If yes: implement the `maludb_embedding_dirty_claim` →
      `maludb_embedding_complete` loop.
- [ ] If no: nothing to do — it's opt-in and queues harmlessly until a worker
      runs.
