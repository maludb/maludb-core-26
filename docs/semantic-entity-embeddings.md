# Semantic Entity Embeddings — the 0.95.0 "Semantic Spine"

> **Status: SHIPPED in 0.95.0 (DB side) — 2026-06-07.** Subjects, verbs and
> edges (SVO statements) are the vector layer. Their embeddings are rendered
> from **merged database state** by deterministic in-DB *card* functions and
> computed by an **external worker** (the DB never calls a model) via a
> trigger-fed dirty queue. Vectors land in the 0.86.0 object-embedding rail
> (`malu$object_embedding` + `semantic_search`), which was designed for
> exactly this — *vector hit → `(object_kind, object_id)` → graph walk* —
> and had never been populated. Similarity also materializes as opt-in
> traversal **jump edges**. The retrieval front door and the worker daemon
> are 0.96.0 (see §9).

---

## 1. Concept and rationale

Documents are extracted (externally) into subjects, verbs, edges and
attributes; attributes **accrete** onto the same deduped entities across
documents. 0.95.0 makes those merged entities the unit of similarity:

1. **Routing** — a query embedding finds the right subjects/verbs/edges by
   meaning, replacing the fail-closed exact-canonical-name lookup of
   `maludb_memory_search` and subsuming the long-deferred Tier-2 fuzzy
   resolver + fallback ladder.
2. **Jumps** — traversal can hop between *similar* subjects or *similar*
   statements (semantic adjacency), a relation the structural graph cannot
   express: "incidents like this one", "upgrades like that upgrade".
3. **Economics** — the entity corpus grows with **distinct knowledge**
   (subjects upsert by canonical name; statements by SVO identity), not with
   mention count. 100 documents mentioning one upgrade are 100 chunks in a
   chunk store but **one** edge vector here, re-rendered as its attributes
   accrete. Deep memories get *more* findable with age (richer cards), not
   less.

### Why three rails became one

| Rail | Born | 0.95.0 role |
|---|---|---|
| A: SVPOR graph (`malu$svpor_*`) | 0.79–0.83 | Source of truth; feeds the cards |
| B: chunk compartments (`malu$vector_compartment/_chunk`, `maludb_memory_search`) | 0.88.0 | **FROZEN** — installed, answers over existing data, never populated by a worker; deprecated in docs |
| C: object embeddings (`malu$object_embedding`, `semantic_search`) | 0.86.0 | **THE vector layer** — now populated with entity cards |

The chunk rail's per-`(subject, verb)` pre-filtering solved a real problem
(never scan the whole corpus) but required the caller to know exact
canonical names, fragmented silently when extractors minted near-duplicate
subjects, and its span-embedding worker was never built. The entity corpus
is small and deduped enough that one scan per query replaces the entire
routing problem — and `semantic_search` already returns graph entry points.

---

## 2. Mention vs. entity — why the extraction contract did NOT change

A vector computed by the extraction pipeline reflects **one document's view**
of an entity (a *mention*). It is stale the moment the next document accretes
an attribute, and the `register_object_embedding` upsert would make the last
document win. Entity vectors must be rendered from the **merged** row +
attribute state — which only the database has. Therefore:

- the extraction JSON contract is **unchanged** (no embedding fields);
- ingest writes mark a dirty queue via triggers (every write path is
  covered: one-call ingest, facade views, `register_*` functions);
- an external worker re-renders and re-embeds on its own cadence.

The 0.92.0 contract sentence "embeddings are deferred to a separate
background worker" is now literally true — at the entity level.

---

## 3. Cards — deterministic embedding inputs

The DB owns rendering; the worker owns embedding. Renders are **name-first
and content-dominant** (the structural prefix is dwarfed by attribute lines,
so vectors cluster by content with a mild type/name pull), UTC-pinned, and
ordered (`ORDER BY attr_name`) so the same state always yields the same
bytes — and the same `sha256` content hash.

- `subject_card_text(subject_id)`
  ```
  Oracle 21c upgrade (2026-03-30)
  type: maintenance_window | aliases: Oracle 21c upgrade
  occurred: 2026-03-30T23:00:00Z
  duration_minutes: 90
  ```
  (canonical name / type+aliases / description / `occurred:` line from the
  episode sidecar / one line per node attribute.)
- `statement_card_text(statement_id)`
  ```
  [svpor] Oracle 21c upgrade (2026-03-30) · upgrade = Oracle Database 21c
  status: completed
  "We performed the Oracle 21c upgrade"
  ```
  (`svpor_frame_text` headline / edge attributes / `valid:` line / latest
  verbatim span as lexical grounding.)
- `verb_card_text(verb_id)` — name, type, aliases, description (routing
  corpus).
- `embedding_card(kind, id) → (card_text, content_hash)` — dispatcher; no
  row when the object is gone.
- `embed_render_version()` — bump on format changes **and** move to a new
  `embedding_space` (`entity-v1` → `entity-v2`): never mix render versions
  inside one space. `semantic_search` filters by space, so this is
  enforceable today.

## 4. Freshness — the dirty queue

`malu$embedding_dirty` holds one row per stale `(kind, id)`; re-dirtying
bumps a `generation` counter instead of adding rows, so N writes collapse
into one pending job and staleness is observable (`max(dirty_since)`).
AFTER triggers populate it from `malu$svpor_subject`, `malu$svpor_verb`,
`malu$svpor_statement`, `malu$svpor_attribute` (accretion is exactly what
invalidates a card) and `malu$episode_object` (the `occurred:` line).
Deletes **purge**: queue row, entity-card vectors, and semantic edges go
with the object — no orphan vectors polluting `semantic_search`.

## 5. Worker protocol (per-tenant facades)

```
loop:
  rows = SELECT * FROM maludb_embedding_dirty_claim(NULL, 64)   -- SKIP LOCKED;
         -- unchanged cards (stored content_hash matches) and vanished
         -- objects are completed in-claim and never returned
  if not rows: sleep(backoff); continue
  vecs = embedding_api.batch([r.card_text for r in rows])       -- ONE model per space
  for r, v in zip(rows, vecs):
      SELECT maludb_embedding_complete(
          r.object_kind, r.object_id, r.generation,
          float32_le_bytes(v), dim, 'entity-v1', MODEL, r.content_hash)
```

`maludb_embedding_complete` stores the vector (with the hash of the text
that was actually embedded), retires the queue row **iff the generation is
unchanged** (a mid-embed accretion survives and re-embeds next cycle), and
refreshes the node's semantic edges — jump freshness rides the embed queue.
`maludb_embedding_requeue_all()` / `maludb_embedding_backfill()` cover
model/render migrations and first runs. The 0.94.0→0.95.0 migration seeds
the queue with every existing entity.

## 6. Semantic edges — opt-in traversal jumps

`malu$semantic_edge` materializes each embedded node's top-k same-kind
neighbors (cosine, default k=5, floor 0.80, reciprocal rows upserted) —
derived data, bulk-replaced on refresh, deliberately not in the assertion
stores. It surfaces as arm 4 of `malu$edge_unified` (rel `similar_to` for
subjects, `similar_statement` for statements, confidence = similarity,
provenance `derived`), so `uedge_neighbors` / `uedge_walk` jump with zero
signature change:

```sql
-- pure structural walk: bit-identical to 0.94.0 (jumps are OPT-IN)
SELECT * FROM maludb_graph_walk('subject', 44, 2, 'both', NULL);
-- structural hop + semantic jump in one cycle-safe walk
SELECT * FROM maludb_graph_walk('subject', 44, 2, 'out',
                                ARRAY['upgrade','similar_to']);
```

The guard exists because a NULL `rel_filter` means "any rel": without it,
k-per-node kNN edges would multiply a depth-4 frontier by up to k⁴ and add
semantic wormholes to every existing structural query. Jumps are a
deliberate `ARRAY['similar_to']` choice. `maludb_semantic_neighbors()` is
the query-time (always-fresh, O(corpus)) variant for ad-hoc use.

A free byproduct: near-duplicate subjects the extractor minted ("Billing
API" vs "billing-svc") sit at ≥0.95 similarity — the semantic edge both
bridges the split at query time and doubles as a standing merge-candidate
report.

**Gap fixed in the same view change (arm 3):** the 0.92.0 ingest writes
`relationships[]` to `malu$svpor_subject_relationship_edge`, which was never
unioned into `malu$edge_unified` — ingested subject↔subject relationships
were invisible to walks. They now traverse as edge_store
`subject_relationship`.

## 7. Verbatim-recall compensation

Entity recall is bounded by extraction completeness — prose the extractor
never structured is invisible to entity vectors. Compensations:

- the statement upsert now **accretes** `metadata_jsonb.source_spans[]`
  (newest first, deduped per span+document, capped at 8) instead of
  keeping only the latest span (`source_span` remains, and grounds the
  card);
- document full text stays in `malu$document` (FTS-able);
- the frozen chunk rail still answers over any pre-existing chunk data.

## 8. Query-class routing (which rail answers what)

| Query class | Example | Rail |
|---|---|---|
| Paraphrase lookup / routing | "when did we move off the old Oracle version" | entity cards (`semantic_search`) |
| Aggregate "what do we know about X" | "what do we know about billing" | entity card → `object_get` + walk |
| Analogy | "incidents like this one" | `similar_to` jump / `maludb_semantic_neighbors` |
| Cross-cohort discovery | "what breaks when we upgrade databases" | jumps + structural walk composed |
| Temporal | "what happened in March" | episode sidecar (`occurred_at` index), **never cosine** (dated names are cosine-noise) |
| Status / negation | "which upgrades FAILED" | typed attribute store (`attr_name`/`value_text` indexes), **never cosine** (one-token render difference ≈ 0.95 cosine) |
| Verbatim detail | "11:00 pm or 11:30 pm?" | typed attrs if extracted; else `source_spans[]`; else document FTS |

## 9. Deferred to 0.96.0+

- **Worker daemon** `services/maludb-embedd` (peer of maludb-modeld;
  systemd unit) implementing §5 against a real embedding API.
- **Retrieval front door** `maludb_memory_query(query_embedding, …)` —
  seeds from `semantic_search`, expands via `uedge_walk`, returns
  `object_get` bundles; `maludb_resolve_subject` ladder (exact → alias →
  semantic).
- **Introspection**: pending counts / max-lag / embedded-totals view.
- **Scale**: `semantic_search` is a sequential scan — fine for deduped
  entity corpora (tens of ms at ~10k rows); pressure valve is the existing
  C `topk_vector_search` aggregate, then HNSW over `malu$object_embedding`
  (reuse `src/maludb_ann.c`), gated on measured latency.
- **Empirical eval** on the MIST corpus: hit@5/MRR per rail per query
  class, pairwise-cosine template-dominance check (incl. the
  failed-vs-completed pair), staleness curve.

## 10. Surface added in 0.95.0

Core: `subject_card_text`, `verb_card_text`, `statement_card_text`,
`embedding_card`, `embed_render_version`, `malu$embedding_dirty` (+5
trigger sets, `_embedding_dirty_mark/_purge`), `embedding_dirty_claim`,
`embedding_dirty_complete`, `embedding_complete`, `embedding_requeue_all`,
`embedding_backfill`, `malu$object_embedding.content_hash` (+10-arg
`register_object_embedding` overload), `malu$semantic_edge`,
`semantic_edges_refresh(_all)`, `uedge_semantic_neighbors`,
`malu$edge_unified` arms 3+4, the uedge semantic guard, and
`_statement_spans_accrete`.

Per-tenant facades (re-run `enable_memory_schema()` to pick up):
`maludb_embedding_dirty` (view), `maludb_semantic_edge` (view),
`maludb_embedding_card`, `maludb_embedding_dirty_claim`,
`maludb_embedding_dirty_complete`, `maludb_embedding_complete`,
`maludb_embedding_requeue_all`, `maludb_embedding_backfill`,
`maludb_semantic_edges_refresh(_all)`, `maludb_semantic_neighbors`.

Test: `sql/semantic_entity.sql` (cards, queue, worker protocol incl. hash
skip + generation race, semantic edges, opt-in jumps, arm-3 fix, span
accretion, delete purge).
