# MaluDB — Executive Summary

> Current release: **v4.3.0** · extension `maludb_core` **0.95.0** · 2026-06-07

## What MaluDB is

MaluDB is a **memory database management system**: a platform for long-term
institutional memory, human–AI knowledge sharing, and contextual recall, in
which memories are first-class, governed data objects rather than rows in an
application database or chunks in a vector store. It ships as a single
PostgreSQL 17 extension (`maludb_core`) plus a small set of companion
services, packaged for Ubuntu 24.04 LTS, with a CLI and SDKs for C, Python,
Node.js, and PHP.

The defining commitment, stated in our design notes, is that **MaluDB is a
PostgreSQL-based memory DBMS, not a vector store with metadata**. If durable
memory truth, authorization, identity, provenance, temporal validity, or
query visibility depends on something, PostgreSQL owns the authoritative
record. External services — model gateways, archives, MCP listeners,
embedding workers — compute and cache, but never become independent systems
of record.

## The memory model: relational and graph by construction

Knowledge enters MaluDB through a deliberately narrow contract: an external
LLM (never the database) converts a document into **one JSON object** —
subjects, verbs, edges, relationships, attributes — and one SQL call
materializes it atomically. From that point on, memory is *structured*:

- **Subjects** are canonical entities — people, systems, projects, and (since
  0.94.0) **events**, which are simply subjects with a temporal sidecar
  (`occurred_at`), so a maintenance window or a standup participates in the
  graph like any entity.
- **Verbs** are small canonical action classes (`upgrade`, not
  `performed_upgrade`); nuance lives in attributes, keeping the vocabulary
  stable.
- **Edges** are verb-typed subject–verb–object statements with provenance,
  confidence, and bitemporal validity; **relationships** are typed
  subject↔subject edges (`depends_on`, `supports`, `supersedes`, …).
- **Typed attributes** accrete onto both nodes and edges across documents —
  one value per `(target, attr_name)`, typed columns
  (text/numeric/timestamp/range/jsonb), all indexed.
- **Provenance and time are mandatory**: every derivation writes a ledger
  entry (inputs, hashes, model and policy versions); corrections supersede,
  never overwrite; valid-time and transaction-time are tracked separately.

Identity is deduplicated at write time — subjects upsert by canonical name,
edges by SVO identity — so the knowledge base grows with **distinct facts**,
not with mention volume. A hundred documents about the same upgrade produce
one richer edge, not a hundred fragments.

## Retrieval philosophy: relational and graph first, vectors only where necessary

This is the architectural choice that most distinguishes MaluDB. Our
requirements state it directly: *the DBMS must treat an incoming query as a
request to build a retrieval plan, not as text to send directly to a vector
index* (requirements.md §4.1), and *global vector search is the fallback, not
the default* (§4.3).

### The rails, in priority order

The retrieval planner classifies a query's intent before choosing a path,
and the paths are ranked:

1. **Relational/catalog filters** — entity IDs, status, confidence floors
   (MAUT-scored), partition membership. Exact, indexed, auditable.
2. **Typed-attribute predicates** — `status = 'failed'`,
   `duration_minutes > 60`, GiST-indexed time ranges. One SQL predicate, no
   approximation.
3. **Graph traversal** — `graph_walk` / `graph_neighbors` / `graph_path`
   over the unified edge view: cycle-safe, depth-bounded, relationship-typed
   structural navigation. This is the primary way recall *expands*.
4. **Temporal indexes** — the event sidecar's `occurred_at` index and
   bitemporal columns answer "what happened in March" as a range scan.
5. **Full-text search** — generated tsvectors over verbatim source content
   for lexical recall the extractor didn't structure.
6. **Vector similarity — scoped, last** — and only for the query classes
   where meaning genuinely outruns structure.

### Where vectors earn their place (and where they are banned)

The 0.95.0 "semantic spine" defines the vector layer's *entire* job in three
narrow capabilities:

| Query class | Rail | Why |
|---|---|---|
| Paraphrase routing — "the payments backend" → `Billing API` | entity-card vectors | names and aliases can't enumerate every phrasing; this is the **entry point**, after which retrieval is relational/graph again |
| Analogy — "incidents like this one" | materialized `similar_to` neighbors | comparing accreted attribute profiles is inexpressible as a predicate |
| Cross-cohort discovery — "what breaks when we upgrade databases" | **opt-in** semantic jumps inside a structural walk | bridges entities no asserted edge connects |
| Temporal — "what happened in March" | `occurred_at` index — **never cosine** | date tokens are noise to embedding models |
| Status/negation — "which upgrades **failed**" | typed attributes — **never cosine** | `failed` vs `completed` differ by one token (~0.95 cosine); a predicate is exact |
| Verbatim detail — "11:00 pm or 11:30?" | typed attrs → accreted `source_spans[]` → FTS | precision lives in structure and verbatim text, not in vectors |

Three design decisions keep vectors contained:

1. **Vectors describe entities, not text fragments.** Embeddings are computed
   from deterministic in-database "cards" rendered from the *merged*
   relational state of a subject or edge (name, type, aliases, accreted
   attributes) — so the vector corpus is as small and deduplicated as the
   graph itself, and a vector hit resolves immediately to a governed
   `(object_kind, object_id)` graph handle. The earlier chunk-compartment
   rail (per-mention text embeddings) was **frozen in 0.95.0, never
   populated**: the relational dedup made it unnecessary.
2. **Similarity is opt-in in traversal.** Worker-maintained top-k
   `similar_to` edges exist in the graph, but a walk only follows them when
   the caller names them explicitly (`rel_filter => ARRAY['similar_to']`).
   Every structural query stays deterministic by default; semantic
   "wormholes" never silently contaminate lineage, dependency, or audit
   walks.
3. **The database never computes embeddings.** An external worker claims
   stale entities from a trigger-fed dirty queue, embeds their cards, and
   posts vectors back. No model calls in the transaction path; ingest
   latency, correctness, and recovery are pure-PostgreSQL properties.

### Why this posture

- **Determinism and auditability** — predicates, joins, and walks explain
  *why* a memory was recalled; provenance and three-stage authorization
  (plan → expand → assemble, enforced under row-level security at each step)
  apply uniformly. Cosine scores explain nothing and are hard to govern.
- **Exactness where it matters** — temporal, status, and identity questions
  have exact answers; approximating them with similarity is a regression.
- **Economics** — deduplicated entities mean the one vector corpus we do
  maintain grows with knowledge, not document volume, and most queries never
  touch it.
- **Durability of recall** — an aging memory gains attributes and therefore
  *more* relational handles and a richer card; recall improves with age
  instead of decaying with vocabulary drift.

## Platform surface (beyond the memory core)

| Component | Role |
|---|---|
| **PageIndex / ChatIndex** (V4) | tree-of-summaries with LLM-guided descent over the verbatim source archive; incremental append for chat transcripts |
| **MC2DB** (`maludb_mc2dbd`) | database-native MCP listener exposing governed tools/prompts/resources with schema validation and full call logging |
| **Model gateway** (`maludb_modeld`) | governed model request/response queue dispatching to local llama.cpp or cloud providers; pins model alias, template version, budgets |
| **REST + realtime** (`maludb-restd`, `maludb-realtimed`) | curated REST over stable SQL functions; SSE event stream — same RLS/authz gates as SQL |
| **Substrate** | secret store (encrypted, rotated, audited), durable queue, cron scheduler, hash-verified verbatim archive with retention/legal hold |
| **Clients** | `maludb` CLI; C/Python/Node.js/PHP SDKs validated against the live extension |

Multi-tenancy is uniform: every governed table carries `owner_schema` with
row-level security; tenant facades are created per schema by one call.

## Status and direction

Stages 1–7 (memory core), 8–15 (V3 platform: identity, REST/CLI/SDKs,
queue/cron, archive, realtime, observability), and 16+ (V4
PageIndex/ChatIndex) are shipped; the test suite stands at 89 `pg_regress`
targets on PostgreSQL 17, with fresh-install ≡ upgrade-chain equivalence
verified on every release. Next (0.96.0+): the `maludb-embedd` worker daemon
that puts production vectors through the semantic spine, a single retrieval
front door (`maludb_memory_query`) that packages the routing ladder above,
and ANN over the entity corpus if measured scale ever demands it — adopted,
like every vector feature here, only when the relational and graph rails
have done all they can.

---

*Deeper reading:* `README.md` (status), `design-notes.md` (doctrine),
`requirements.md` §4 (retrieval planning), `docs/semantic-entity-embeddings.md`
(the 0.95.0 vector boundary), `docs/memory-extraction-json-contract.md`
(ingest contract), `SVPOR_ERD.md` (schema).
