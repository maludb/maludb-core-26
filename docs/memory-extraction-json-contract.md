# Memory-Extraction JSON Contract

> **0.95.0 note (no contract change):** the deferred embedding worker is now
> defined at the **entity** level — see
> [semantic-entity-embeddings.md](semantic-entity-embeddings.md). The ingest
> still accepts **no embedding fields** (deliberate: a pipeline-computed
> vector is a mention-level view; entity vectors are rendered from merged DB
> state and refreshed via a trigger-fed dirty queue that this ingest feeds
> automatically). The chunk-compartment rail (`maludb_memory_search`) is
> **frozen/deprecated**; its span worker will not be built. Each edge's
> `source_span` now **accretes** into `metadata_jsonb.source_spans[]`
> (newest first, deduped, capped at 8) instead of last-writer-wins.
>
> **Status: REVISED for 0.94.0 (BREAKING) — 2026-06-07.** Episodes were folded
> into subjects ("a standup meeting is an event"): the `episodes[]` section is
> **removed and rejected** by the ingest, and events are now `subjects[]`
> entries carrying `occurred_at` / `occurred_until`. A stale extractor fails
> fast (`invalid_parameter_value`) instead of silently dropping events. The
> 0.92.0 shape of this contract is in git history.
>
> Earlier locked decisions still hold: C = v1 is the full core (claims/facts
> fast-follow); D = provenance `accepted`; E = event dedup on
> `(kind, title, occurred_at)`; hints are NOT a DB concept (the external
> extractor bakes them into explicit subjects/edges). This document defines the
> single JSON object the project ingests to create memory structures. The LLM
> that produces this object runs **outside** the project; the project receives
> the object and materializes it.
>
> Scope set by the requirements conversation: the project does **not** call any
> LLM, run prompts, manage a queue, or hold model config. Everything arrives as
> one JSON object in this format. Embeddings are **deferred** to a separate
> background worker — this ingest builds graph structures only.

---

## 1. What the ingest does (and does not)

**Does:** create/merge subjects (nodes) — including **events**, which are
subjects with a temporal sidecar — verbs, edges (statements), node attributes,
edge attributes, subject↔subject relationships, external reference pointers,
and (optionally) the source document — all from one JSON object, in one
transaction (per item; see §7 skip-bad-item).

**Does not:** call an LLM, compute embeddings, run prompts, dedup by fuzzy
matching, or require human review. Names are trusted: the external extractor was
given the canonical match-list, so the DB resolves a subject/verb by exact
canonical name or alias and **only creates a new one if it isn't already
present**.

**Deferred (separate worker, not this contract):** embeddings — and since
0.95.0 the worker's DB side exists at the **entity** level: every
subject/verb/edge this ingest touches is marked in a dirty queue
(`maludb_embedding_dirty`), an external worker claims deterministic entity
*cards* (`maludb_embedding_dirty_claim`) and posts vectors back
(`maludb_embedding_complete`). Search/jumps run over those entity vectors
(`maludb_semantic_search`, `similar_to` traversal). The former plan — embed
each `source_span` into a `(subject, verb)` chunk compartment — is
**retired**: `maludb_memory_search` and the compartment tables stay
installed but frozen and deprecated.

---

## 2. Top-level object

```json
{
  "document":      { ... },      // optional — create the source doc in the same call
  "source":        { "kind": "document", "id": 1234 },  // optional — anchor to an EXISTING object instead
  "subjects":      [ <subject> ],   // entities AND events
  "verbs":         [ <verb> ],   // optional — only to set aliases/type/description explicitly
  "edges":         [ <edge> ],
  "relationships": [ <relationship> ],
  "claims":        [ <claim> ],  // ⚠ DECISION C — fast-follow
  "facts":         [ <fact> ]    // ⚠ DECISION C
}
```

- All sections are optional; an object may contain only `subjects`, only
  `edges`, etc.
- **`episodes` is rejected (0.94.0).** Emitting it raises
  `invalid_parameter_value` so the caller knows to upgrade, rather than the
  events being silently dropped.
- **The source anchor** is either `document` (created now) or `source` (an
  existing `(kind, id)`). Edges/relationships reference it with the reserved key
  `"$source"`. If neither is present, edges that reference `"$source"` are
  skipped (recorded as skipped — see §7).

---

## 3. Subjects (entities and events)

```json
{
  "key": "oracle21c",                       // REQUIRED — unique within this object; how edges refer to it
  "name": "Oracle Database 21c",            // REQUIRED — canonical_name (exact-match resolve/create)
  "type": "software",                       // subject_type picker; default "other" ("event" for events)
  "aliases": ["Oracle 21c", "the database"],// merged into the node on match
  "attributes": [ <attribute> ],            // NODE attributes -> attributes on the subject
  "ref": { "source": "cmdb", "entity": "servers", "key": "srv-100" }  // optional external pointer
}
```

**An event is a subject with a time.** Adding `occurred_at` (and optionally
`occurred_until` and `description`) makes the entry an event:

```json
{
  "key": "upg",
  "name": "Oracle 21c upgrade",
  "type": "maintenance_window",             // the EVENT KIND — becomes the subject_type
  "occurred_at": "2026-03-30T23:00:00-05:00",
  "occurred_until": null,
  "description": "Production upgrade window",
  "attributes": [ { "attr_name": "duration_minutes", "value_numeric": 90 } ]
}
```

| Field | MaluDB mapping |
|---|---|
| `name`, `type`, `aliases` | subject upsert on `(owner_schema, canonical_name)`; aliases merged |
| `occurred_at` / `occurred_until` (events) | the episode **sidecar** (`malu$episode_object`) — created automatically; the mint trigger supplies the subject identity |
| `description` (events) | the sidecar summary + the subject description |
| `attributes[]` | node attributes **on the subject** (for events too) |
| `ref` | stored as a reference attribute (`ref_source/ref_entity/ref_key`) on the node |

Event mechanics (0.94.0):

- The minted subject's `subject_type` **is the event kind** (`type`, slugged:
  `standup_meeting`, `deployment`, …; default `event`). Unknown kinds are
  auto-registered in the advisory picker.
- The canonical name is **`<name> (YYYY-MM-DD)`** (UTC date of `occurred_at`),
  falling back to `<name> [#<episode_id>]` without a timestamp or on a same-day
  collision. The raw `name` is kept as an alias. The KNOWN_SUBJECTS list shown
  to the extractor contains these dated names — reuse them exactly to resolve
  an existing occurrence.
- **Dedup (DECISION E):** re-ingesting the same `(type, name, occurred_at)`
  resolves to the existing event instead of creating a duplicate.
- Resolution never *mutates*: if `name` resolves to an existing non-event
  subject, the entry resolves to it and **no sidecar is added**.

`key` is a local handle used only inside this object; it is **not** stored.

---

## 4. Verbs (optional)

Only needed to register aliases / type / description. A verb named in an edge but
absent here is auto-created by canonical name.

```json
{ "name": "upgrade", "type": "updated", "aliases": ["upgraded","performed upgrade"], "description": "…" }
```
→ `register_svpor_verb`. **Rule (locked earlier):** verbs stay small/canonical;
status / timing / "performed" live in **edge attributes**, not in the verb.

---

## 5. Edges (statements) and Relationships

### 5a. Edge = a verb-typed SVO statement

```json
{
  "subject": "oracle21c",        // a subject key (entity OR event), or "$source"
  "verb": "upgrade",
  "object": "$source",           // key or "$source"; if omitted -> "$source"
  "attributes": [ <attribute> ], // EDGE attributes (the "predicate": status, event_at, …)
  "valid_from": "2026-03-30T23:00:00-05:00",
  "valid_to": null,
  "source_span": "We performed the Oracle 21c upgrade on Sunday March 30 at 11 pm",
  "confidence": 0.94
}
```

| Field | MaluDB mapping |
|---|---|
| endpoints + `verb` | SVO statement (idempotent on the SVO identity) |
| `attributes[]` | edge attributes on the statement |
| `source_span`, `confidence` | carried in the statement `metadata_jsonb` / `confidence`; `source_span` holds the latest span and (0.95.0) accretes into `metadata_jsonb.source_spans[]` — per-mention verbatim history (newest first, deduped, cap 8) |

Since 0.94.0 **event keys resolve to `subject` endpoints** — there is no
separate episode addressing in this contract. (`episode_object` remains a
legal legacy endpoint kind in the schema for pre-0.94 rows, but the ingest no
longer emits it.)

### 5b. Relationship = subject↔subject typed temporal edge

For the directed, typed, valid-time subject relationship layer (distinct from
SVO statements):

```json
{ "from": "oracle21c", "to": "billing", "relationship_type": "depends_on",
  "valid_from": "2026-01-01T00:00:00Z", "valid_to": null }
```

Because events are subjects, **events can participate in relationships** as of
0.94.0 (e.g. *upgrade-window → about → Oracle Database 21c*).

---

## 6. Shared `<attribute>` object

Used by subjects (including events) and edges. Exactly one `value_*` per
attribute.

```json
{
  "attr_name": "event_at",
  "value_timestamp": "2026-03-30T23:00:00-05:00",
  "value_text": null, "value_numeric": null, "value_jsonb": null, "value_range": null,
  "unit": null,
  "confidence": null,
  "valid_from": null, "valid_to": null,
  "ref_source": null, "ref_entity": null, "ref_key": null
}
```
Maps 1:1 to a `attributes_apply` element (typed columns
`value_timestamp/value_text/value_numeric/value_jsonb/value_range`, `unit`,
`confidence`, valid-time, external `ref_*`).

---

## 7. Ingest semantics

- **Skip the bad item.** A malformed item, an edge referencing an unknown `key`,
  an unknown (non-event) subject type, etc. → that single item is skipped and
  recorded; the rest of the object still ingests. (Per-item subtransactions.)
- **Trust the names.** Resolve subject/verb by exact canonical name or alias;
  create only if absent. No fuzzy matching, no dedup beyond exact identity
  (plus the event triple of §3).
- **No review.** Everything lands live.
- **Order of operations:** document/source → subjects (entities + events) →
  verbs → edges → relationships → (claims → facts). So edges can resolve every
  `key`.
- **Idempotency:** subjects/verbs upsert by canonical name; events dedup on
  `(kind, title, occurred_at)`; statements upsert on SVO identity; attributes
  upsert on `(target, attr_name)`.
- **Embeddings:** never computed here (deferred worker).

### Return value (report)

```json
{
  "source": { "kind": "document", "id": 1234 },
  "created":  { "subjects": 3, "verbs": 1, "episodes": 1, "edges": 3, "relationships": 1,
                "node_attributes": 4, "edge_attributes": 5 },
  "resolved": { "subjects": 1, "verbs": 2, "episodes": 0 },
  "ids":      { "oracle21c": 44, "billing": 45, "upg": 46 },  // key -> SUBJECT id (events included)
  "skipped":  [ { "section": "edges", "index": 2, "reason": "unknown object key 'foo'" } ]
}
```

0.94.0 report changes: `created.episodes` / `resolved.episodes` count event
**sidecars** (an event also counts in `subjects`); the `episode_attributes`
counter is gone (event attributes are node attributes); `ids` maps event keys
to their **subject** id.

---

## 8. Ingest entry point (one call)

```
maludb_memory_ingest_extraction(
    p_extraction  jsonb,                       -- the object in this contract
    p_source_kind text   DEFAULT 'document',   -- used with p_source_id when no "document" block
    p_source_id   bigint DEFAULT NULL,
    p_provenance  text   DEFAULT 'accepted'    -- DECISION D (locked)
) RETURNS jsonb   -- the report in §7
```

The API server flow: upload raw text (or pass the `document` block) → call this
once with the LLM's JSON → done. No project-side LLM.

---

## 9. Worked example

Raw text: *"We performed the Oracle 21c upgrade for the Drajeo project on Sunday
March 30 at 11 pm; it depends on the billing API."* (hint: project = Drajeo)

```json
{
  "document": { "title": "Sunday maintenance log", "content_text": "We performed the Oracle 21c upgrade …", "document_type": "log" },
  "subjects": [
    { "key": "oracle21c", "name": "Oracle Database 21c", "type": "software",
      "aliases": ["Oracle 21c"],
      "attributes": [ { "attr_name": "version", "value_text": "21c" } ] },
    { "key": "billing", "name": "Billing API", "type": "software" },
    { "key": "drajeo", "name": "Drajeo", "type": "project" },      // from the hint, as an explicit subject
    { "key": "upg", "name": "Oracle 21c upgrade", "type": "maintenance_window",
      "occurred_at": "2026-03-30T23:00:00-05:00" }                 // the EVENT — a subject with a time
  ],
  "edges": [
    { "subject": "upg", "verb": "upgrade", "object": "oracle21c",
      "attributes": [ { "attr_name": "status", "value_text": "completed" } ],
      "source_span": "We performed the Oracle 21c upgrade … 11 pm", "confidence": 0.94 },
    { "subject": "upg", "verb": "part_of", "object": "drajeo" },   // the hint, as a real edge
    { "subject": "upg", "verb": "generated_by", "object": "$source" }
  ],
  "relationships": [
    { "from": "oracle21c", "to": "billing", "relationship_type": "depends_on" }
  ]
}
```
One call to `maludb_memory_ingest_extraction(…)` creates: the document, 4
subjects — one of them the event `Oracle 21c upgrade (2026-03-30)` with its
temporal sidecar — (+1 node attribute), the verbs `upgrade`/`part_of`/
`generated_by`, 3 edges (+1 edge attribute), and 1 subject relationship — and
returns the report in §7.
