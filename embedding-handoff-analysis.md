# Embedding Handoff — Coding-Agent Analysis & Gap Report

> **Reviewed against:** `sql/extension/maludb_core--0.87.0.sql` (the installed
> `default_version`, per `maludb_core.control`). Where this doc and the DDL
> disagree, the DDL wins. Companion reading: [`embedding-handoff.md`](embedding-handoff.md)
> (the design brief this answers), [`SVPOR_ERD.md`](SVPOR_ERD.md),
> [`end-to-end.md`](end-to-end.md).
> **Date:** 2026-06-01.

---

## 0. Executive summary — read this first

**The good news is bigger than expected.** The handoff describes a system that
"compartmentalizes vector search by subject and verb so it never searches the
whole corpus," backed by a canonical subject/verb graph, an edge store with typed
predicate attributes, temporal validity, confidence, and a model-as-proposal /
database-as-source-of-truth split. **MaluDB already contains a working
implementation of essentially every one of those pieces.** Almost nothing in the
brief is structurally impossible today.

**The bad news is one specific, load-bearing gap.** MaluDB has grown **two
unconnected subject/verb namespaces**, plus **two unconnected vector stores**, and
**no extraction orchestrator** to tie text → edges → embeddings together. The
parts exist as three islands:

| Island | Tables | What it is |
|---|---|---|
| **A. Canonical SVO graph** | `malu$svpor_subject`, `malu$svpor_verb`, `malu$svpor_statement`, `malu$svpor_attribute` | The real knowledge graph: canonical subjects/verbs (with aliases & types), the polymorphic SVO edge with valid-time/confidence/provenance, and a *typed attribute store* that is the handoff's "predicate." |
| **B. Compartmentalized chunk vectors** | `malu$vector_subject`, `malu$vector_verb`, `malu$vector_compartment`, `malu$vector_chunk` | **Exactly the handoff's "compartment by subject+verb" idea, already built.** A compartment is keyed `(owner_schema, namespace, subject_id, verb_id)` and holds embedded text chunks. `vector_search_by_tags(namespace, subject, verb, query)` restricts search to matching compartments. |
| **C. Object embeddings** | `malu$object_embedding` (+ `semantic_search()`) | Embeds a *graph object* `(object_kind, object_id)` — subject, document, episode, even a `svpor_statement` — and `semantic_search` returns `(object_kind, object_id)` so you can hop straight into `graph_walk`. This is the "semantic entry → graph" rail. |

**The load-bearing gap: A, B, and C do not share identity.**

1. **The compartment's `subject_id`/`verb_id` are NOT the graph's `subject_id`/`verb_id`.**
   `malu$vector_subject`/`malu$vector_verb` are a *separate flat text registry*
   (keyed by `subject_name`/`verb_name`), with **no FK, join, or resolver** linking
   them to `malu$svpor_subject`/`malu$svpor_verb`. (Confirmed: zero cross-references
   in the DDL.) So "compartmentalize by subject_id and verb_id" works today only by
   *string convention* — if your ingest writes the same text into both registries.
2. **A `malu$vector_chunk` has no pointer back to its document, statement, or edge.**
   Its only context is the compartment it sits in. You cannot currently go
   chunk → statement → subject, or document → its chunks.
3. **There is no in-database extraction pipeline.** Nothing converts a text chunk
   into candidate `subject/verb/predicate` edges. The architecture *deliberately*
   expects an external model to do that and **propose** results into two existing
   staging tables (`malu$pending_claim`, `malu$document_svpor_hint`) — but the
   promotion-and-embed glue from those staging rows into A+B+C is not written.

So the recommendation is **not "build the schema"** — most of it exists. It is
**"build the spine that unifies the three islands at ingest time,"** plus a thin
set of additive columns/resolvers. Details below.

---

## 1. Existing schema mapping

Format per the brief (`Concept / Existing object / Status / Notes`).

```
Concept: subject_node
Existing: malu$svpor_subject (facade maludb_subject) — subject_id, owner_schema,
          canonical_name, aliases text[], subject_type (FK→malu$svpor_subject_type),
          description, archived_at.
Status:   already exists (no parent_subject_id column — see Missing #1)
Notes:    Canonical entity node. subject_type picker is FK-enforced; seeded types
          include project, person, ai_agent, equipment, software, network, event,
          process, workflow, time_period, other (+ legacy concept/stakeholder).

Concept: subject_alias
Existing: malu$svpor_subject.aliases (text[], GIN-indexed) + resolve_svpor_subject(text)
          + register_svpor_subject(name, aliases[], desc, type) [upsert, merges aliases]
Status:   already exists — but EXACT-match only
Notes:    resolve_svpor_subject does `canonical_name = p_text OR p_text = ANY(aliases)`.
          No fuzzy / pg_trgm / embedding entity-linking, even though pg_trgm is a
          required extension. "the database" → "Oracle 21c" will NOT resolve unless
          literally registered as an alias. See §3 and Missing #6.

Concept: verb_type (canonical verb vocab)
Existing: malu$svpor_verb (facade maludb_verb) — canonical_name, aliases text[],
          verb_type (FK→malu$svpor_verb_type), search_phrases text[]
Status:   already exists
Notes:    Only attended/generated_by/made_during ship as seeded *verbs*; 0.87.0
          also seeds concerns/mentions/involves for document links. Everything else
          is registered per-tenant (register_svpor_verb upserts, merges aliases).

Concept: verb_alias
Existing: malu$svpor_verb.aliases (text[]) + resolve_svpor_verb(text)
Status:   already exists — EXACT-match only (same limitation as subject aliases)

Concept: verb_family
Existing: malu$svpor_verb_type.semantic_class
          (action|state|event|decision|communication|verification|failure|planning|
           documentation|other)
Status:   partially exists
Notes:    This is a *fixed 10-value taxonomy on the verb TYPE*, not a free "family"
          and not used for vector compartmenting. The handoff's
          "verb_family = maintenance_change" has no home today. See Missing #4.

Concept: memory_chunk
Existing: malu$vector_chunk (chunk_id, compartment_id FK, source_text, embedding bytea,
          embedding_dim, embedding_model, embedding_norm, importance_score, created_at)
          + document body in malu$source_package / malu$source_content
Status:   partially exists
Notes:    A chunk = text+embedding inside ONE compartment. It has NO link to its
          document, its svpor_statement, or its subject_id/verb_id in the graph.
          Document upload does NOT chunk or embed (see §4). This is the key gap.

Concept: memory_edge
Existing: malu$svpor_statement (facade maludb_svpor_statement) — subject_kind/id,
          verb_id, object_kind/id, predicate_id, valid_from, valid_to, confidence,
          provenance, source_package_id, metadata_jsonb
Status:   already exists (rich)
Notes:    This IS the handoff's memory_edge, and it is more capable than the brief's
          sketch: bitemporal valid-time, confidence, provenance lifecycle, optional
          predicate FK, source linkage, free metadata. Endpoints are polymorphic;
          'document' and 'episode_object' are legal kinds, so document→verb→subject
          and team→performed→event are both expressible.

Concept: predicate attributes  (the handoff's "predicate {status, date_text, ...}")
Existing: malu$svpor_attribute with target_kind='svpor_statement' (edge attributes)
          — typed columns value_timestamp, value_range (tstzrange), value_numeric,
          value_text, value_jsonb, unit, confidence, provenance, valid_from/to,
          ref_source/ref_entity/ref_key, metadata_jsonb
Status:   already exists — and this is the RIGHT home for the handoff's predicate
Notes:    ⚠️ Naming collision. The handoff's "predicate" ≠ malu$svpor_predicate
          (that's a thin controlled-vocab slot, predicate_id, rarely used). The
          handoff's predicate = typed key/value qualifiers on the edge, which is
          exactly the ATTRIBUTE store. status/actuality/owner/version → value_text;
          performed_at/event_time_* → value_timestamp/value_range; counts → numeric.
          Per-field confidence/provenance/valid-time come free (one row per field).

Concept: memory_embedding  (chunk + edge + subject_id + verb_id)
Existing: SPLIT across two stores, neither of which carries all four:
          - malu$vector_chunk: has subject/verb (as compartment TEXT tags), embedding,
            source_text — but no edge_id and no graph subject_id.
          - malu$object_embedding: object_kind/object_id (can be 'svpor_statement'),
            embedding, embedding_space, source_field, provenance — but no compartment,
            no subject_id/verb_id filter.
Status:   partially exists — THE central gap
Notes:    No single row ties (chunk_text, edge/statement, graph subject_id, graph
          verb_id, embedding). See Missing #2 and §4.

Concept: document
Existing: malu$document (facade maludb_document) + maludb_upload_document(...) ;
          content in malu$source_package; soft tags in malu$document_tag
Status:   already exists
Notes:    primary_project_id is a real FK→malu$svpor_subject, populated by 0.87.0.

Concept: graph node
Existing: polymorphic kinds: subject, verb, document, episode_object, memory,
          source_package, claim, fact, memory_detail_object
Status:   already exists

Concept: graph edge
Existing: malu$edge_unified = UNION ALL of malu$svpor_statement (verb-typed SVO)
          and malu$relationship_edge (lineage). Facade view maludb_edge; traversal
          maludb_graph_neighbors / maludb_graph_walk.
Status:   already exists
Notes:    Resolving labels and walking both stores is one call. First-pass filtering
          does NOT require traversal — you can query malu$svpor_statement relationally
          by (object_id, verb_id) etc. (see §5).

Concept: temporal event
Existing: malu$episode_object (occurred_at, occurred_until, episode_kind, payload_jsonb,
          sensitivity, lifecycle_state) + valid_from/valid_to on statements + value_range
          on attributes
Status:   already exists (normalized time only — see §6)

Concept: confidence score
Existing: numeric(5,4) [0..1] on malu$svpor_statement, malu$svpor_attribute,
          malu$pending_claim, malu$document_svpor_hint, malu$document_tag,
          malu$relationship_edge
Status:   already exists (per-edge and per-attribute; NOT per-candidate — see §7)

Concept: source span
Existing: malu$pending_claim.source_locator (jsonb) + statement_text;
          malu$svpor_statement.source_package_id (+ metadata_jsonb)
Status:   partially exists
Notes:    No first-class char-offset "source_span" column on the statement/edge.
          Spans live structured on the *proposal* (pending_claim.source_locator) and
          can be copied into metadata_jsonb on promotion. See Missing #8.

Concept: extraction model metadata
Existing: malu$pending_claim.proposed_by (text); ingest_claim_atomic(...,
          p_model_request_id, p_parser_name); malu$model_request/_response/_alias
          (the in-DB model gateway). NOT present as columns on svpor_statement/attribute.
Status:   partially exists
Notes:    Model/version is captured at the claim-ingest layer, not on the graph edge.
          On statements/attributes the only home today is metadata_jsonb. See Missing #9.
```

---

## 2. Missing structures

Ordered by importance. "Missing" = not representable cleanly today.

1. **Graph-id ↔ vector-compartment identity bridge** *(the big one)*. The vector
   compartment's `subject_id`/`verb_id` point at `malu$vector_subject`/`_verb`, a
   separate text registry with **no link** to `malu$svpor_subject`/`_verb`. There
   is no resolver "given graph subject_id X + verb_id Y, get/create the compartment."
2. **`malu$vector_chunk` ↔ source linkage.** No `document_id`, no `statement_id`,
   no `(object_kind, object_id)` on the chunk row. A chunk is an orphan inside its
   compartment.
3. **An extraction orchestrator.** No function does text → candidate edges. (By
   design — the model proposes externally — but the *landing + promotion* glue from
   `malu$pending_claim` / `malu$document_svpor_hint` into statements+attributes+
   embeddings is also absent.)
4. **Verb families / subject families for search breadth.** `verb_type.semantic_class`
   exists but isn't a free family and isn't a vector-search key. No subject family at all.
5. **Subject hierarchy (parent/child).** No `parent_subject_id`. Hierarchy is only
   expressible as a `part_of` SVO statement or a `malu$svpor_subject_relationship_edge`
   — fine for traversal, but the handoff's cheap "parent compartment" search level
   has no relational shortcut.
6. **Fuzzy / candidate entity linking.** Alias resolution is exact-match. No
   ranked `subject_candidates[]` with confidence (the handoff's output shape), no
   trigram/embedding linker. pg_trgm is installed but unused for this.
7. **Document auto-chunking + auto-embedding.** `maludb_upload_document` stores the
   whole body and creates graph tags/edges, but never chunks or embeds. Chunking +
   `register_vector_chunk` is a separate manual step with no document back-reference.
8. **First-class `source_span` on the edge.** Exists on the proposal, not the statement.
9. **Model/extractor version on the edge.** Lives on the claim layer / metadata_jsonb,
   not as columns on `svpor_statement` / `svpor_attribute`.
10. **Global vector fallback over chunks.** `vector_search_by_tags` *requires*
    subject or verb (raises if both NULL). True "search everything" exists only via
    `semantic_search` over `malu$object_embedding` (object embeddings), not over chunks.

What is **NOT** missing (already present, contrary to what a fresh design might assume):
multi-edge-per-chunk, multi-subject/verb per chunk, predicate_json equivalent (typed
attribute store), typed temporal fields, confidence tracking, provenance/review
lifecycle, alias columns, the proposal staging tables, filtering vectors by
subject+verb (by name), and document-in-graph reachability (0.87.0).

---

## 3. Subject & verb resolution (today vs. needed)

**Subjects.** `resolve_svpor_subject('Oracle 21c')` returns a `subject_id` iff
`'Oracle 21c'` is a canonical name or an exact member of some subject's `aliases[]`.
So to make all of `"Oracle 21c"`, `"Oracle Database 21c"`, `"production Oracle
database"`, `"the database"` resolve to one node, you must **pre-register them as
aliases** (e.g. `register_svpor_subject('Oracle Database 21c', ARRAY['Oracle 21c',
'production Oracle database','the database'], ...)`). There is **no fuzzy match and
no automatic linking** — `"the database"` will silently fail to resolve if not an
alias. The handoff's ranked `subject_candidates[]` (multiple ids with confidences)
has no schema home; resolution returns a single best id or NULL.

> **Gap:** entity linking. Recommend a `resolve_svpor_subject_fuzzy(text)` returning
> `(subject_id, score)` rows using `pg_trgm` similarity over canonical_name+aliases
> (and optionally `malu$object_embedding` cosine over subject embeddings for semantic
> linking), so the extractor's text can be matched to ranked candidates.

**Verbs.** Same mechanism: `resolve_svpor_verb('upgraded')` resolves only if
`'upgraded'` is the canonical name or an alias of canonical `upgrade`. The handoff's
recommended pattern — small canonical verb + status/actuality on the predicate — is
*exactly* MaluDB's locked "small verbs + attribute on the edge" rule (see
`end-to-end.md` §5). So `performed upgrade / planned upgrade / rolled back upgrade`
should all → verb `upgrade` with `role`/`status`/`actuality` carried as **edge
attributes** (`target_kind='svpor_statement'`). To make the variants resolve, seed:
`register_svpor_verb('upgrade', ARRAY['upgraded','performed upgrade','completed
upgrade','planned upgrade','rolled back upgrade'], verb_type=>'updated')`.

---

## 4. Embedding & vector-search fit

| Handoff question | Answer |
|---|---|
| Does the embedding store support metadata filters? | **Two stores, two answers.** `malu$vector_chunk` is filtered by **compartment** = `(namespace, subject_name, verb_name)` via `vector_search_by_tags`. `malu$object_embedding` is filtered by `object_kind[]` + `embedding_space` via `semantic_search`. |
| Filter by `subject_id`? | **By NAME, in a separate registry, yes; by graph `subject_id`, no.** Compartments key off `malu$vector_subject.subject_id`, which is *not* the graph subject id. |
| Filter by `verb_id`? | Same as above — by `verb_name` only. |
| Filter by `subject_family` / `verb_family`? | **No.** No family keying in the vector layer. |
| Multiple embeddings per chunk for different edges? | Not in `vector_chunk` (one compartment per chunk). `malu$object_embedding` allows many embeddings per object via `(embedding_space, source_field, sub_key)` — so a `svpor_statement` can have several. |
| Embed whole chunk once, or per edge-span? | Both are *possible*; neither is *wired*. Today you'd `register_vector_chunk` once per chunk into a compartment, and/or `register_object_embedding('svpor_statement', id, ...)` per edge. No code chooses. |
| Global fallback embedding per chunk? | **Chunks: no** (`vector_search_by_tags` requires subject or verb). **Objects: yes** (`semantic_search` with no kind filter searches everything). |

**Where `subject_id`/`verb_id` should attach.** The clean answer is to **drive the
vector compartment off the canonical graph ids**, not a parallel text registry. Two
viable shapes:

- **(Recommended) Make `malu$vector_subject`/`_verb` *projections* of the graph.**
  At ingest, resolve the canonical graph `subject_id`/`verb_id` first, then derive
  the compartment's `subject_name`/`verb_name` from the *canonical_name* of those
  graph rows (deterministically), so the two namespaces stay in lockstep. Add a
  `statement_id` (and/or `document_id`) column to `malu$vector_chunk` so a chunk
  knows which edge it embeds. Then "filter vector search by graph subject_id+verb_id"
  becomes: look up canonical names → `vector_search_by_tags`.
- **(Alternative) Lean on `malu$object_embedding`.** Embed each promoted
  `svpor_statement` as an object (`object_kind='svpor_statement'`). `semantic_search`
  returns the statement id; join to `malu$svpor_statement` to filter by `subject_id`/
  `verb_id` *relationally* after the ANN step. Simpler (no compartment plumbing) but
  loses pre-filtered compartment partitioning — you filter after search, not before.

The first preserves the handoff's "narrow the search space *before* semantic search"
goal; the second is faster to prototype. A hybrid is fine: object-embeddings for the
global fallback rail, compartments for the hot exact/parent paths.

---

## 5. Graph fit

All five graph requirements are met:

- **subject as node** — `malu$svpor_subject` (kind `'subject'`). ✅
- **verb as edge label** — `malu$svpor_statement.verb_id` → `verb.canonical_name`
  surfaces as `rel` in `malu$edge_unified`. ✅
- **predicate as edge attributes** — `malu$svpor_attribute` with
  `target_kind='svpor_statement'`. ✅
- **chunk/event/memory as target node** — `episode_object`, `memory`, `document`,
  `source_package` are all legal statement endpoints. ✅ (A raw `vector_chunk` is
  *not* a graph kind — see Missing #2; embed the chunk as an object or hang it off a
  statement instead.)
- **relational row materializes the graph** — `malu$edge_unified` is literally a view
  over the relational statement/relationship rows; `graph_neighbors`/`graph_walk`
  read it. ✅

**Is traversal required for first-pass search? No.** You can filter relationally:
`SELECT ... FROM malu$svpor_statement WHERE object_id = :oracle AND verb_id = :upgrade`.
That's the handoff's "relational edge-index" — it already exists as the statement
table with its `(owner_schema, subject_kind, subject_id, verb_id, object_kind,
object_id)` unique index plus supporting indexes. Traversal is for multi-hop only.

---

## 6. Temporal fit

| Field the handoff wants | MaluDB today |
|---|---|
| event_time_start / event_time_end | `episode_object.occurred_at` / `occurred_until`; `attribute.value_range` (tstzrange); statement `valid_from`/`valid_to` |
| normalized_datetime | `attribute.value_timestamp` (timestamptz) |
| date_text / time_text (literal source) | **Absent as typed columns.** Put literal text in `attribute.value_text` (e.g. `attr_name='event_date_text'`) or `metadata_jsonb`. |
| timezone | `timestamptz` stores an instant (UTC); the *original* offset/zone is not preserved separately — keep it in metadata if needed. |
| temporal uncertainty | `value_range` can express a window; otherwise metadata. |
| date contradictions ("Sun Mar 30" vs a date that's a Monday) | **No detection.** Nothing cross-checks literal vs normalized. You'd store both (`value_text` + `value_timestamp`) and add an app/trigger check. |
| past/planned/future status | Carry as an attribute, e.g. `actuality` ∈ {actual, planned, hypothetical, negated} and `status` ∈ {completed, planned, failed, ...} — matches the handoff's recommended predicate fields. |

Net: **valid-time and normalized event-time are solid; literal-text preservation and
contradiction flagging are not modeled** and would be additive (a couple of attribute
conventions + an optional validation function).

---

## 7. Confidence & review workflow

This is a **strong-fit** area — the "model proposes, database disposes" thesis is
already the architecture:

- **Proposal landing zones exist.** `malu$pending_claim` (subject/verb/predicate/
  object_value/relationship/statement_text + `source_locator` jsonb + `confidence` +
  `proposed_by` + `review_state` ∈ {pending, accepted, rejected, duplicate,
  superseded} + `reviewed_by`/`reviewed_at`/`review_note` + `promoted_claim_id`) is a
  ready-made **edge-proposal + human-review queue**. `malu$document_svpor_hint`
  (project/subject/verb ids+names, provenance, confidence) is the document-scoped
  equivalent.
- **Promotion functions exist.** `propose_pending_claim(...)` enqueues;
  `accept_pending_claim(..., p_reviewer, p_parser_name, p_verifier_name, ...)` promotes
  to a `malu$claim` with a ledger; `ingest_claim_atomic(...)` ingests pre-parsed SVOs
  (and *does* take `p_model_request_id`, `p_parser_name`).
- **Provenance lifecycle is uniform** — `provided | suggested | accepted | rejected`
  on statements, attributes, tags, hints; plus
  `svpor_statement_set_provenance()` / `svpor_attribute_set_provenance()` to flip state.
- **Confidence** is `numeric(5,4)` on every relevant row.

| Handoff requirement | Status |
|---|---|
| confidence per extracted edge | ✅ statement.confidence / pending_claim.confidence |
| confidence per predicate field | ✅ each attribute row has its own confidence |
| confidence per subject/verb resolution | ❌ resolvers return a single id, no score (Missing #6) |
| low-confidence routing | ⚠️ representable (gate on confidence + review_state) but no built-in router |
| human review | ✅ `malu$pending_claim.review_state` + accept/reject functions |
| model fallback / escalation | ⚠️ model gateway tables exist; no orchestration policy |
| audit trail of accept/reject | ✅ pending_claim (reviewed_by/at/note, promoted_claim_id) + claim ledger |

**Gap:** the document-hint → statement *promoter* is not written (hints are inserted
but nothing turns an `accepted` hint into a `svpor_statement`), and resolution-time
candidate confidence isn't captured.

---

## 8. Recommended implementation location

Map the handoff's pipeline onto the existing architecture:

```
Raw document        → maludb_upload_document  (EXISTS; stores body + tags + doc→graph edges)
Chunking            → NEW step (no in-DB chunker; app- or function-side)            ← add
Event candidate     ┐
Subject extraction  │ → EXTERNAL model (in-DB model gateway can host the call)      ← external
Verb classification │   emits candidate_edges JSON  (the handoff's output shape)
Predicate extraction┘
Land proposals      → propose_pending_claim(...) / insert malu$document_svpor_hint  (EXISTS)
Subject resolution  → resolve_svpor_subject + register_svpor_subject                (EXISTS; add fuzzy)
Verb resolution     → resolve_svpor_verb + register_svpor_verb                       (EXISTS)
Date/version norm   → deterministic, app- or function-side                          ← add
Relational edge ins → register_svpor_statement(document/episode → verb → subject)    (EXISTS)
Predicate attrs     → maludb_attributes_apply(target_kind='svpor_statement', ...)    (EXISTS)
Graph materializ.   → automatic (malu$edge_unified is a view)                        (EXISTS)
Vector embed + meta → register_vector_chunk into a compartment derived from the      ← GLUE MISSING
                      *canonical* subject/verb ids, AND/OR register_object_embedding(
                      'svpor_statement', id, ...)
```

**Best fit = an asynchronous enrichment job, after chunking, before/with vector
insert**, that runs *post-resolution* so the chunk lands in the correct, graph-aligned
compartment. Reasons: (1) extraction is model-bound and slow → don't block upload;
(2) the proposal tables (`pending_claim`/`document_svpor_hint`) are explicitly built
for async accumulation + review; (3) resolution must happen before embedding so
`subject_id`/`verb_id` are known. A **reprocessing variant** of the same job backfills
existing documents (mirrors the existing `maludb_document_graph_backfill()`).

Do **not** put extraction inside `upload_document` (keep upload synchronous and
cheap, as 0.87.0 intends).

---

## 9. Gap analysis

| Requirement | Existing support | Missing pieces | Recommended change | Risk |
|---|---|---|---|---|
| Compartmentalize vectors by subject+verb | `malu$vector_compartment` + `vector_search_by_tags` | compartment ids ≠ graph ids | Derive compartment subject/verb from canonical graph rows at ingest; add resolver `compartment_for_svpor(subject_id, verb_id, model, dim)` | **High** (core of the design) |
| Chunk → source/edge linkage | none | no FK on `vector_chunk` | Add nullable `document_id`, `statement_id` (or `(object_kind,object_id)`) to `malu$vector_chunk`; index them | **High** |
| Multiple candidate edges per chunk | statements (6-tuple unique), pending_claim, hints | — | none (works) | Low |
| Predicate as typed attributes | `malu$svpor_attribute` (edge attrs) | naming confusion w/ `svpor_predicate` | Document that predicate→attribute store; keep `predicate_id` for controlled relations only | Low |
| Subject/verb aliases | `aliases[]` + exact resolvers | no fuzzy / no candidate scores | Add `resolve_svpor_subject_fuzzy()` (pg_trgm + optional embedding); return ranked `(id, score)` | **Medium** |
| Subject hierarchy / parent search | `part_of` statements, relationship edges | no `parent_subject_id` shortcut | Either a `parent_subject_id` column OR a materialized `parent`-verb index; pick per query needs | Medium |
| Verb/subject families for breadth | `verb_type.semantic_class` | no family on subjects; not a vector key | Add advisory `subject_family`/`verb_family` columns (or reuse `subject_type`/`semantic_class`) and a family→compartment fan-out at search | Medium |
| Temporal: literal text + normalized + contradiction | valid-time, value_timestamp, value_range | no literal date_text col; no contradiction check | Convention: `*_text` (value_text) + normalized (value_timestamp); optional `validate_temporal()` flags mismatches into metadata | Medium |
| source_span on edge | pending_claim.source_locator | not on statement | Copy span into statement `metadata_jsonb` on promotion (no new column needed) | Low |
| extraction model/version on edge | claim layer, model gateway | not on statement/attribute | Store `{model, version, request_id}` in statement/attribute `metadata_jsonb`; or add columns if first-class | Low |
| Confidence per edge / per field | statement & attribute confidence | per-resolution-candidate score | Comes with fuzzy resolver above | Low |
| Human review / audit | pending_claim + provenance + ledger | hint→statement promoter not written | Add `promote_document_svpor_hint(hint_id)` mirroring accept_pending_claim | Medium |
| Global vector fallback | `semantic_search` over object embeddings | chunks can't search all compartments | Allow `vector_search_by_tags` with both NULL to fan over all compartments, OR route fallback through object embeddings | Medium |
| In-DB extraction orchestrator | model gateway tables, proposal tables | no text→edges pipeline | Build the async enrichment job (§8); extraction itself stays external | **High** (but additive) |
| Document auto chunk+embed | upload stores body + graph edges | no chunker / embedder in upload | New `enrich_document(document_id)` job: chunk → resolve → statement → embed | **High** |

No requirement was found to **conflict** with the current architecture. Every gap is
**additive** (new columns with defaults, new functions, new resolvers) — none requires
breaking an existing signature or table, consistent with the repo's
re-enable-safe / backward-compatible conventions.

---

## 10. Minimal implementation plan (smallest design-validating prototype)

Goal: prove `input chunk → resolve S/V/P → relational edge → embed with graph
subject_id/verb_id → filtered vector search` end-to-end in the existing `mist` schema.

**Step 0 — seed canonical vocab (manual, one-time).**
Register the demo subject + verb with aliases so resolution succeeds:
```
register_svpor_subject('Oracle Database 21c', ARRAY['Oracle 21c','the database'], 'Oracle DB', 'software');
register_svpor_verb('upgrade', ARRAY['upgraded','performed upgrade','rolled back upgrade'], 'maintenance', 'updated');
```

**Step 1 — one glue function** `memory_ingest_edge(...)` (new; the whole prototype):
given `(chunk_text, subject_text, verb_text, predicate jsonb, embedding, source_span,
confidence, model)` it:
1. `resolve_svpor_subject(subject_text)` → else `register_svpor_subject` (provenance suggested);
2. `resolve_svpor_verb(verb_text)` → else `register_svpor_verb`;
3. `register_svpor_statement(subject_kind=>'document', subject_id=>:doc, verb_id, object_kind=>'subject', object_id=>:subj, confidence, provenance, source_package_id, metadata_jsonb => {model, source_span})` → `statement_id`;
4. `maludb_attributes_apply('svpor_statement', statement_id, predicate)` for status/actuality/normalized_datetime/date_text/version/...;
5. derive/create the compartment from the **canonical** `subject.canonical_name` +
   `verb.canonical_name` (`register_vector_compartment(namespace, canon_subj, canon_verb, dim, model)`),
   then `register_vector_chunk(compartment_id, chunk_text, embedding)`; also
   `register_object_embedding('svpor_statement', statement_id, embedding, dim, embedding_space=>'edge')` for the fallback rail.

   *(Prototype shortcut: skip the new `vector_chunk.statement_id` column by relying on
   the object-embedding link; add the column in the production pass.)*

**Step 2 — filtered search** two ways:
- compartment pre-filter: `maludb_vector_search(namespace, 'Oracle Database 21c', 'upgrade', :query_emb)`;
- semantic→graph: `maludb_semantic_search(:query_emb, object_kinds=>ARRAY['svpor_statement'])`
  → take `object_id` → `maludb_graph_walk('subject', :subj, ...)`.

**Step 3 — assert** the query "Oracle upgrades" returns the chunk via the compartment
and the statement via semantic search, and that an unrelated query in a different
compartment does **not** surface it (proving compartmentalization).

This needs **one new function** and **zero schema changes** to demonstrate the
concept (using object-embeddings for the chunk↔edge link). The production version then
adds the `vector_chunk` linkage columns (Gap #2), the fuzzy resolver (Gap #6), the
async enrichment job (§8), and the hint promoter (§7).

---

## Information to bring back to the design conversation

1. **Schema objects that already map:** subjects/verbs/aliases/types, the SVO edge
   (`svpor_statement` with valid-time/confidence/provenance), the **typed attribute
   store** (= the handoff's "predicate"), documents, episodes, the unified graph +
   traversal, the **compartmentalized chunk vector store** (`vector_compartment`/
   `vector_chunk` + `vector_search_by_tags`), object embeddings + `semantic_search`,
   and the **proposal/review tables** (`pending_claim`, `document_svpor_hint`). ~90%
   of the brief already exists.
2. **Missing schema objects/columns:** graph-id↔compartment bridge; `vector_chunk`
   source/edge FK; verb/subject *families*; subject `parent_subject_id`; literal
   `date_text` + contradiction check; fuzzy resolver / candidate scores; (optional)
   `source_span` & model-version columns (metadata_jsonb suffices short-term).
3. **Subject/verb metadata on embeddings today:** yes, but by **text tag in a
   separate registry** (`vector_compartment`), not by graph `subject_id`/`verb_id`.
   Object embeddings link to graph objects but aren't compartment-filterable.
4. **One chunk → multiple edges today:** yes — multiple statements per subject/object,
   plus `pending_claim`/`hint` arrays. No structural blocker.
5. **Graph edges from relational rows today:** yes — `malu$edge_unified` is a view
   over the statement/relationship tables; nothing to materialize.
6. **Temporal adequacy:** valid-time + normalized event-time = solid; literal-text
   dates + contradiction flagging = not modeled (additive).
7. **Aliases & canonicalization today:** yes for storage + exact resolution; **no
   fuzzy/semantic linking** and no ranked candidates.
8. **Where extraction goes:** an **async enrichment job after chunking, before vector
   insert**, landing in `pending_claim`/`document_svpor_hint` then promoting to
   statements+attributes+embeddings. Not inside `upload_document`.
9. **Minimal prototype:** one `memory_ingest_edge()` glue function (resolve → statement
   → attributes → embed via canonical names + object-embedding), zero schema changes;
   verify with a compartment-filtered search vs. a global semantic search.
10. **Risks / conflicts:** none structural — every gap is additive and re-enable-safe.
    The real risk is **identity drift** between the two subject/verb namespaces and the
    two vector stores; the prototype must make the canonical graph the single source of
    truth and derive compartment tags from it, or the islands diverge under load.

---

# Decision & build plan (added 2026-06-01)

> Added after reviewing the two upstream design prompts that drive this work:
> **(P1)** "use an AI model to extract subject / verb / predicate from a chunk …
> find the smallest, most efficient model" and **(P2)** "compartmentalize vector
> searches by the subject/verb construct … determine subject+verb *before*
> embedding so the knowledge-graph relationship is defined — subject=node,
> verb=edge, predicate=edge attributes — and also defined relationally so no graph
> traversal is needed on the first pass."

## What the prompts settle

1. **Extraction lives outside the database.** Model selection (P1) is a separate
   track. The DB's job is to expose a clean **ingestion contract** that accepts the
   model's `{subject, verb, predicate}` output — *not* to run the extraction. This
   removes "in-DB extraction orchestrator" from the work list.
2. **Compartmentalized search is the deliverable** (P2). The relational first-pass
   already exists (`malu$svpor_statement` filtered by `(object_id, verb_id)`). The
   vector first-pass does **not**, because the compartment store can't be addressed
   by the graph's `subject_id`/`verb_id`. Closing that is the critical path.
3. **Canonical-verb rule is reaffirmed.** P1's example verb *"Performed Upgrade"*
   is modeled as canonical verb **`upgrade`** (the edge + the compartment key) with
   `status=completed` / `action_form=performed` as **predicate attributes**. This is
   the existing locked "small verbs + attributes on the edge" rule
   ([[mist-end-to-end-test]]) and is what keeps compartments from fragmenting.

## Decision: identity binding = FK columns + resolver helper

Chosen over the convention-only and object-embeddings-only alternatives because P2
demands *pre-filtered* compartment search (rules out object-embeddings-only, which
filters after the ANN) with the canonical graph as the **enforced** single source of
truth (rules out convention-only, which risks silent drift).

**Schema deltas (design intent — DDL is illustrative, not the final delta):**

```sql
-- Bind the vector routing registry to the canonical graph (nullable, backfillable).
ALTER TABLE maludb_core.malu$vector_subject
    ADD COLUMN svpor_subject_id bigint
        REFERENCES maludb_core.malu$svpor_subject(subject_id) ON DELETE SET NULL;
ALTER TABLE maludb_core.malu$vector_verb
    ADD COLUMN svpor_verb_id bigint
        REFERENCES maludb_core.malu$svpor_verb(verb_id) ON DELETE SET NULL;

-- Let a chunk name its edge and its source document (both nullable).
ALTER TABLE maludb_core.malu$vector_chunk
    ADD COLUMN statement_id bigint
        REFERENCES maludb_core.malu$svpor_statement(statement_id) ON DELETE SET NULL,
    ADD COLUMN document_id  bigint;   -- soft ref (matches existing soft-ref style)
```

Notes / safety:
- All four columns **nullable** → backward compatible; existing chunks/compartments
  keep working, and pre-0.88 rows simply have NULL graph links.
- New **partial unique** intent: at most one `vector_subject` per `svpor_subject_id`
  (and likewise for verbs) within `(owner_schema, namespace)`, so the mapping is 1:1
  and the resolver can upsert deterministically.
- `statement_id` FK on the chunk means a retrieved chunk → edge → `(subject_id,
  verb_id)` join is a single hop, satisfying P2's "relational, no traversal."

## The resolver helper

```
maludb_core._vector_compartment_for_svpor(
    p_subject_id   bigint,        -- canonical graph subject
    p_verb_id      bigint,        -- canonical graph verb
    p_embedding_dim integer,
    p_embedding_model text,
    p_namespace    text DEFAULT 'default',
    p_distance_metric text DEFAULT 'cosine'
) RETURNS bigint                  -- compartment_id
```

Behavior: look up `canonical_name` for the graph subject/verb → upsert a
`vector_subject`/`vector_verb` row carrying `svpor_subject_id`/`svpor_verb_id` and
that canonical name → `register_vector_compartment(...)` → return `compartment_id`.
Idempotent; one call per `(subject_id, verb_id, model, dim, namespace)`.

## The ingestion contract (what the external model feeds)

Mirrors the `candidate_edges` shape in `embedding-handoff.md`. One chunk → array of
candidate edges; the DB resolves, validates, persists, embeds.

```jsonc
// per candidate edge emitted by the extraction model
{
  "source_kind": "document",          // or 'episode_object' etc.
  "source_id": 1234,                  // the chunk's document/episode id
  "subject_text": "Oracle 21c",       // surface form; DB resolves to subject_id
  "subject_type": "software",
  "verb_text": "upgrade",             // CANONICAL verb (not 'performed upgrade')
  "predicate": {                      // -> edge attributes on the statement
    "status": "completed",
    "actuality": "actual",
    "action_form": "performed",
    "event_at": "2026-03-30T23:00:00-05:00",   // normalized -> value_timestamp
    "event_at_text": "Sunday March 30 at 11 pm",// literal  -> value_text
    "timezone": "America/Chicago"
  },
  "source_span": "performed the Oracle 21c upgrade on Sunday March 30 at 11 pm",
  "confidence": 0.94
}
```

```
maludb_<schema>.maludb_memory_ingest_edge(
    p_source_kind    text,         -- chunk's graph kind (e.g. 'document')
    p_source_id      bigint,
    p_subject_text   text,
    p_verb_text      text,
    p_predicate      jsonb,        -- typed -> maludb_attributes_apply on the edge
    p_embedding      <vector>,     -- precomputed by the external model
    p_subject_type   text  DEFAULT 'other',
    p_source_span    text  DEFAULT NULL,
    p_confidence     numeric DEFAULT NULL,
    p_provenance     text  DEFAULT 'suggested',
    p_namespace      text  DEFAULT 'default'
) RETURNS bigint                   -- statement_id
```

Steps it performs (all from existing primitives + the new helper):
1. resolve subject (`resolve_svpor_subject` → fuzzy → `register_svpor_subject` if new);
2. resolve verb (`resolve_svpor_verb` → `register_svpor_verb` if new);
3. `register_svpor_statement(source → verb → subject, confidence, provenance,
   metadata_jsonb => {source_span, extraction_model,…})` → `statement_id`;
4. `maludb_attributes_apply('svpor_statement', statement_id, p_predicate)` — predicate
   fields become typed edge attributes (`value_timestamp`/`value_text`/`value_numeric`);
5. `_vector_compartment_for_svpor(subject_id, verb_id, dim, model, namespace)` →
   `register_vector_chunk(compartment_id, span, embedding)` **with `statement_id`/
   `document_id` set**.

## The search facade (P2's call)

```
maludb_<schema>.maludb_memory_search(
    p_query_embedding <vector>,
    p_subject        text  DEFAULT NULL,   -- name OR resolvable id
    p_verb           text  DEFAULT NULL,
    p_namespace      text  DEFAULT 'default',
    p_limit          integer DEFAULT 20,
    p_fallback       boolean DEFAULT true  -- if compartment empty/unknown
) RETURNS TABLE(chunk_id bigint, statement_id bigint, source_text text,
                similarity double precision, subject text, verb text)
```

- Resolves subject/verb to the graph, maps to the compartment, runs the ANN
  **pre-filtered** to that compartment (wraps `vector_search_by_tags`).
- `p_fallback=true` and nothing resolves / compartment empty → degrade to
  `semantic_search` over `malu$object_embedding` (the global rail), flagged in output.
- Returns `statement_id` so the caller can pivot into `graph_walk` for context.

## Build tiers (for the implementation pass, when approved)

- **Tier 1 (the feature):** the three ALTERs above, `_vector_compartment_for_svpor`,
  `maludb_memory_ingest_edge`, `maludb_memory_search`; wire all into
  `enable_memory_schema` (re-enable-safe); version/Makefile/CHANGELOG bumps; an
  acceptance test under `examples/` proving (a) ingest a chunk for `Oracle 21c /
  upgrade`, (b) `maludb_memory_search` pre-filtered to that compartment returns it,
  (c) the same query under a different subject/verb does **not**, (d) `statement_id`
  on the chunk joins to `(subject_id, verb_id)` with no traversal.
- **Tier 2 (quality):** `resolve_svpor_subject_fuzzy()` (pg_trgm over
  canonical_name+aliases, ranked `(id, score)`); the global-fallback path; predicate
  attribute-name conventions documented as a template.
- **Tier 3 (defer):** date-contradiction check; `parent_subject_id` + verb/subject
  families for "parent/broader" search levels; first-class `source_span` / model-
  version columns (use `metadata_jsonb` until then).

## Resolved decisions (confirmed 2026-06-01)

1. **Embed per-edge span.** A chunk with N edges produces N compartment placements;
   each compartment stores the *edge-specific source span*, not the whole chunk.
   Keeps each compartment's vectors tight to its subject/verb.
2. **`document_id` is a soft reference (no FK).** Matches the existing document-tag
   style and avoids cross-store coupling. (`statement_id` keeps its FK.)
3. **Fuzzy resolver stays Tier 2 — P1 starts with a strong cloud model.** Because the
   initial extraction model is a strong cloud model, it emits clean, near-canonical
   surface forms (and can be prompted to return canonical names / choose from a
   supplied vocabulary), so exact-match `resolve_svpor_subject/_verb` is sufficient
   for Tier 1. `pg_trgm` fuzzy entity-linking is deferred to Tier 2, to be revisited
   if/when P1 moves to a smaller/local model whose surface forms are noisier.

   > **Guardrail for the MVP:** to limit near-duplicate canonical subjects even with a
   > strong model (e.g. "Oracle 21c" vs "Oracle Database 21c"), the ingest prompt
   > should be given the schema's existing subject/verb vocabulary as context and
   > asked to reuse a canonical name when one fits. New names still auto-register via
   > `register_svpor_subject/_verb`; periodic alias-merge cleanup is a Tier-2 chore.

## Status — Tier 1 SHIPPED as the 0.88.0 delta (verified live 2026-06-01)

Implemented in `sql/extension/maludb_core--0.87.0--0.88.0.sql` (+ generated full
install `maludb_core--0.88.0.sql`, control/Makefile/CHANGELOG bumps):

- Schema: `malu$vector_subject.svpor_subject_id`, `malu$vector_verb.svpor_verb_id`
  (FK), `malu$vector_chunk.statement_id` (FK) + `document_id` (soft ref) + indexes.
- `maludb_core._vector_compartment_for_svpor(...)` — graph ids → compartment.
- `maludb_core._memory_ingest_edge_for_schema(...)` + facade
  `maludb_memory_ingest_edge` — the ingestion contract.
- `maludb_core._memory_search_for_schema(...)` + facade `maludb_memory_search` —
  pre-filtered compartment ANN returning `statement_id`.
- Wired into `enable_memory_schema` (re-enable-safe).

**Verified** against PostgreSQL 17 (deltas 0.82.0→0.88.0 applied to a throwaway DB;
acceptance test `examples/mist-e2e/03-embedding.sql`). All 7 assertions passed:
(1) compartment search returns the Oracle chunk + `statement_id`; (2) the same query
in the billing compartment returns only the billing edge — **no cross-compartment
leak**; (3) chunk → edge → `(subject, verb)` in one relational hop; (4) predicate
stored as typed edge attributes (timestamp normalized `-05:00`→UTC, literal text
kept); (5) document graph-reachable from the subject; (6) edge-idempotent re-ingest;
(7) idempotent re-enable. One known caveat surfaced as designed: **chunks are not
deduplicated** — a re-ingest of the same edge adds another chunk (chunk-level dedup
is a Tier-2 item).

Still **deferred to Tier 2** (unchanged): `pg_trgm` fuzzy/candidate resolution,
global fallback to object embeddings, chunk dedup, date-contradiction checks,
subject hierarchy / verb-family search breadth.

## Status — 0.89.0: model gateway wired into extraction (verified live 2026-06-01)

The extraction step now goes through MaluDB's in-DB model gateway ("Option B").
Because PostgreSQL can't make an outbound API call inside a SQL function, the
wiring is **async / daemon-mediated**: `set config → request (enqueue) →
[daemon calls the model] → harvest`.

Shipped in `sql/extension/maludb_core--0.88.0--0.89.0.sql`:
- `malu$memory_extraction_config` (per-schema/namespace binding: extraction
  model alias + prompt template + embedding model + defaults) with
  `maludb_memory_set_model_config()` / `maludb_memory_model_config()` (the
  resolver exposes `secret_ref` + `base_url`, **never the secret value**).
- `malu$memory_extraction` (the pending-extraction queue) +
  `maludb_memory_request_extraction()` (render prompt → enqueue a
  `malu$model_request` against the bound alias, **explicit `owner_schema`** —
  the gateway is per-tenant: `malu$model_alias/_request/_response` are
  `owner_schema`-scoped with composite FKs) +
  `maludb_memory_harvest_extractions()` (parse the daemon's
  `{"candidate_edges":[…]}` response → `_memory_ingest_edge_for_schema` per
  edge, including the per-edge embedding).
- Gateway correctness fix: `submit_request` now hashes
  `convert_to(prompt,'UTF8')` instead of `prompt::bytea` (the latter throws on
  any backslash in the prompt).

**Verified** (deltas 0.82.0→0.89.0 on PG17; `examples/mist-e2e/04-extraction.sql`):
config bind + resolve → enqueue (pending row tied to the model request) →
simulated daemon response → harvest produced **2 edges** with typed predicate
attributes, and the compartment search returned each edge in its own
compartment (isolation held); re-harvest is a no-op. 0.88.0's `03-embedding.sql`
still passes (no regression).

**Daemon dependency:** no extraction daemon ships in this repo — the contract is
the `candidate_edges` response JSON; a `maludb_modeld`-style worker (or
pageindexd's `model_gateway.py` pattern) must drain `malu$model_request` and
write `malu$model_response`. Per-edge **embeddings ride in that response JSON**
(the DB still never generates embeddings).


