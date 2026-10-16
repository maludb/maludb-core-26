# MaluDB Version 4 — PageIndex / ChatIndex Track

Draft: 2026-05-14
Rebased: 2026-05-14 — §4.1 migration baseline moved from `0.57.0` (v3.0.0 RC) to `0.64.0` (v3.1.0 shipped); §V4-PAGEINDEX-01 tier-view block aligned with shipped V3 reality (RLS-on-base-tables; tier views are deferred — see §10.11).

This document is the **implementation plan** for the first Version 4 track: PageIndex and ChatIndex as governed memory surfaces over the existing Verbatim Source Archive. It is the operational companion to:

- [`requirements.md`](requirements.md) — canonical roadmap; V4 will add a §1.6 / §9 Stages 16+ block when this plan is accepted.
- [`docs/pageindex/PageIndex_Technology_Guide.md`](docs/pageindex/PageIndex_Technology_Guide.md) — conceptual brief.
- Upstream references: `https://github.com/VectifyAI/PageIndex` (MIT), `https://github.com/VectifyAI/ChatIndex` (Apache-2.0).

V4 normative scope decisions live here. The implementation plan in §8 says **how, in what order, in which files, against which migration versions, and against which tests**. When this plan and `requirements.md` disagree, `requirements.md` wins for normative scope; this document is updated to match.

---

## 0. Position in the roadmap

V4 begins **after** the `v3.0.0` GA field-test on a fresh Ubuntu 24.04 VM. The V3 Stage 15 follow-ups (`maludb-logsd` runner, `maludb backup` / `env` / `log-drain` CLI families, PgBouncer + HAProxy samples) may overlap with V4 if they are not blocking GA, but no V4 migration begins until `v3.0.0` is tagged.

Gating sequence:

```
v3.0.0-rc.1   (current)
       │
       ▼
       RC field-test on a fresh Ubuntu 24.04 host
       │
       ▼
v3.0.0   GA
       │
       ▼
       V4 begins  ───────► v4.0.0-alpha.1 (V4-DOC-01 + V4-PAGEINDEX-01)
```

V4 inherits and must preserve every V3 acceptance criterion. No V4 migration may regress an R1.0/R1.1 or Stage 2–15 acceptance check.

---

## 1. Source inputs and prior decisions

- Local: `docs/pageindex/PageIndex_Technology_Guide.md`, `20260514-status.md`, `requirements.md`, `version3-requirements.md`, `version3-plan.md`.
- Upstream:
  - `https://github.com/VectifyAI/PageIndex` — Python, MIT. Tree-of-summaries with LLM-guided descent for document retrieval. Nodes carry `{title, node_id, start_index, end_index, summary, nodes[]}`.
  - `https://github.com/VectifyAI/ChatIndex` — Python, Apache-2.0. Extension of PageIndex for ongoing conversations. `TopicNode {topic_name, summary, start_index, end_index, children, sub_node_count}` and `MessageNode {system_message, user_message, assistant_message, message_index}`. Tree grows incrementally; new topics branch only from the current node or its ancestors.

PageIndex's "vectorless" framing in the upstream guide refers to navigation, not discovery. MaluDB's two-stage retrieval restores SVPOR-framed embeddings as the discovery layer.

---

## 2. Design decisions locked during the V4 feasibility exploration

The following decisions are settled and bake into the catalog and surface design below. They are not revisited inside V4 implementation tickets.

1. **Two-stage retrieval.** Vector / SVPOR / FTS / catalog filters find the candidate Source Packages within a project/subject partition. The PageIndex or ChatIndex tree, when present, is a *second-pass* index used for in-document navigation. Tree traversal is one additional path in the Stage 4 retrieval planner, not a replacement for any existing path.
2. **Trees are derived artifacts of Source Packages.** A PageIndex or ChatIndex tree is the same status of object as a `malu$vector_chunk` row or a Derivation Ledger entry — derived from a Source Package by a governed pipeline. They are not first-class memory objects.
3. **Tree nodes specialize `malu$memory_detail_object` (MDO).** A new `mdo_kind` discriminator column distinguishes existing memory details (`'memory_detail'`) from PageIndex nodes (`'page_index_node'`) and ChatIndex nodes (`'chat_index_topic'`, `'chat_index_message'`). Existing MDO consumers (workflow extraction, memory replay, retrieval expansion) filter `WHERE mdo_kind = 'memory_detail'` and are otherwise unchanged.
4. **Chunk boundaries align with tree leaf boundaries (1:1).** The deterministic structure-analysis pass produces leaf ranges. Both the V3-EMBED-01 chunker (extended with a "use precomputed boundaries" mode) and the V4 tree builder consume the same ranges, recorded once in `malu$source_object_reference`. A vector hit on a chunk maps deterministically to a tree leaf and vice versa.
5. **Structure analysis is deterministic; only summarization uses the LLM.** PDF outline (`/Outlines`) parsing, markdown header parsing, chat message-author boundaries, and time-gap topic candidates are deterministic. Summaries (per leaf and per internal node) call the model gateway with a pinned model alias and prompt template version. Re-deriving a tree under a newer model changes summaries, not boundaries; existing `malu$vector_chunk` rows and source references remain valid.
6. **`pypdf` is the default v1 PDF parser, behind a pluggable parser interface.** BSD-3-Clause, pure Python, available in apt as `python3-pypdf`. An in-house parser is deferred to V4's open decisions; AGPL parsers (`PyMuPDF`) and hosted vision parsers may be plugged in by operators who accept those terms, but are not bundled.
7. **Vision PDFs are out of V4 scope.** Scanned / image-only PDFs are explicitly deferred. Text-bearing PDFs only.
8. **ChatIndex boundary with Active Memory Pools.** AMPs are live working sets. ChatIndex is a retrospective tree over a *retired* AMP transcript (or any chat transcript ingested as a Source Object). V4 does not change AMP behavior. A future ticket may add an "AMP retire → ChatIndex build" automation; that is out of V4 v1 scope.

---

## 3. Conceptual model

### 3.1 Object surface seen by operators and SDK users

- **PageIndex** — a navigable tree built from a text-bearing Source Package (PDF, markdown, plain text). One tree per Source Package per build generation.
- **ChatIndex** — a navigable tree built from a chat-transcript Source Package. Supports incremental append as new messages arrive on the same transcript.

Both are referenced by stable `tree_id` and addressable through the same retrieval planner.

### 3.2 Storage shape

```
malu$source_object              ← raw bytes (Stage 12, V3-STOR-01)
     │
     ▼ promote
malu$source_package             ← claims, facts, vector chunks (Stage 2)
     │
     ├── malu$vector_chunk      ← SVPOR-framed embeddings (Stage 14, V3-EMBED-01)
     │        │
     │        └── malu$source_object_reference  (byte/page/timestamp anchors)
     │                       ▲
     │                       │  same reference row, 1:1
     │                       │
     └── malu$page_index_tree  ← V4 header table (one row per build)
              │   (or malu$chat_index_tree)
              ▼
         malu$memory_detail_object (mdo_kind = 'page_index_node' | 'chat_index_topic' | 'chat_index_message')
              │  tree_id, node_kind, title, summary
              │  parent_mdo_id (recursive)
              ▼
         malu$source_object_reference  (leaf anchors only)
```

### 3.3 Promotion path

```
source_object_promote_to_source_package(source_object_id, ...)
                                          │
                                          ▼
source_package_promote_to_page_index(source_package_id, builder_options)
                                          │
                                          ▼
                              malu$page_index_tree (build_status = 'pending')
                                          │
                                          ▼  enqueue on V3-QUEUE-01
                                   builder worker
                                          │
                                          ▼  deterministic structure pass
                                   leaf ranges (written to malu$source_object_reference)
                                          │
                                          ▼  LLM summarization per node
                                   malu$memory_detail_object rows + malu$derivation_ledger
                                          │
                                          ▼  emit_event() on malu$event (V3-REALTIME-01)
                              malu$page_index_tree (build_status = 'ready')
```

ChatIndex follows the same shape; the builder honors incremental append semantics (see V4-CHATINDEX-02).

---

## 4. Versioning, migration, tag strategy

### 4.1 Extension migration assignments

V4 picks up at `0.64.0` (the shipped v3.1.0 baseline). The original V4 draft reserved `0.57.0`–`0.62.0`, but the v3.1.0 follow-up release consumed migrations `0.57.0 → 0.64.0` (Stage A V3-EMBED-02, Stage B V3-REALTIME-02a, Stage C V3-PRESENCE-02, Stage E V3-LOG-02, Stage F V3-API-02, Stage H V3-AUTH-02, Stage I V3-SECRET-02; non-migration v3.1 stages V3-VEC-02 / V3-CRON-02 / V3-QUEUE-02 / V3-OPS-01 also shipped under the v3.1.0 tag). All V4 migration files follow the existing `maludb_core--X.Y.0--X.(Y+1).0.sql` convention.

| Migration | Ticket | Purpose |
|---|---|---|
| `0.64.0 → 0.65.0` | V4-PAGEINDEX-01 | `malu$page_index_tree`, `mdo_kind` discriminator on `malu$memory_detail_object`, page-index columns (`tree_id`, `node_kind`, `title`, `summary`), RLS on the new tables, `derived_object_type` CHECK extension for `'page_index_tree'` / `'page_index_node'` |
| `0.65.0 → 0.66.0` | V4-PAGEINDEX-02 | `source_package_promote_to_page_index`, `page_index_builder_enqueue`, structure-pass audit, builder status helpers |
| `0.66.0 → 0.67.0` | V4-PAGEINDEX-03 | Retrieval planner: new intent values, new search-path enum value `tree_descent`, `malu$retrieval_envelope` columns for descent trail, three-stage authz on tree traversal |
| `0.67.0 → 0.68.0` | V4-CHATINDEX-01 | `malu$chat_index_tree`, additional `mdo_kind` values (`'chat_index_topic'`, `'chat_index_message'`), chat-specific leaf-payload columns on MDO, RLS, `derived_object_type` CHECK extension for chat node kinds |
| `0.68.0 → 0.69.0` | V4-CHATINDEX-02 | Incremental append helpers, `chat_index_append_messages`, current-node pointer, ancestor-branch validation |

V4-DOC-01, V4-PARSER-01, V4-MC2DB-01, V4-REST-01, V4-CLI-01, and V4-SDK-01 do not own migrations.

`maludb_core.control` updates `comment = …` once at Stage 16 to reflect V4 surfaces and never embeds ticket IDs; `default_version` advances as each migration lands.

### 4.2 Tag plan

| Tag | Trigger |
|---|---|
| `v4.0.0-alpha.1` | V4-DOC-01 + V4-PAGEINDEX-01 (catalog only) |
| `v4.0.0-alpha.2` | V4-PARSER-01 + V4-PAGEINDEX-02 (promotion + builder worker) |
| `v4.0.0-alpha.3` | V4-PAGEINDEX-03 (retrieval planner integration) + first CLI / MC2DB surface for PageIndex |
| `v4.0.0-alpha.4` | V4-CHATINDEX-01 + V4-CHATINDEX-02 |
| `v4.0.0-beta.1` | All surfaces (MC2DB, REST, CLI, SDK) complete for PageIndex + ChatIndex |
| `v4.0.0-rc.1` | Acceptance suite green; bench fixtures published |
| `v4.0.0` | RC field-test on a fresh Ubuntu 24.04 host |

---

## 5. Dependency graph

```
V4-DOC-01
   │
   ▼
V4-PAGEINDEX-01 ──► V4-PARSER-01
   │                    │
   ▼                    ▼
V4-PAGEINDEX-02 ◄───────┘
   │
   ▼
V4-PAGEINDEX-03 ──► V4-MC2DB-01 ──► V4-REST-01 ──► V4-CLI-01 ──► V4-SDK-01
   │
   ▼
V4-CHATINDEX-01
   │
   ▼
V4-CHATINDEX-02
```

Edges are hard prerequisites. The MC2DB/REST/CLI/SDK surfaces grow over multiple stages; the arrows reflect "first reach parity for PageIndex," with ChatIndex parity added when V4-CHATINDEX-02 lands.

---

## 6. License and dependency gate

V4 adds one runtime dependency to the default redistributed product:

| Candidate | Used by | License | V4 decision |
|---|---|---|---|
| `pypdf` | V4-PARSER-01 default PDF parser | BSD-3-Clause | **Adopt.** Pure Python, available as `python3-pypdf` in Ubuntu 24.04, no transitive runtime deps beyond stdlib on Python 3.10+. Added to `services/maludb-pageindexd/requirements.txt` and to `debian/control` for the new service `.deb`. |
| `pdfminer.six` | Optional alternate parser | MIT | **Allowed as a swap target via V4-PARSER-01's pluggable interface.** Not bundled by default. |
| `PyMuPDF` (`fitz`) | Optional alternate parser | AGPL-3.0 / commercial | **Not bundled.** Operators may plug in their own instance if they accept AGPL terms or hold a commercial license. The default redistributed product MUST NOT link or require it. |
| In-house PDF parser | Future V4+ replacement of `pypdf` | PostgreSQL License | **Deferred** — see §10 open decisions. Honest LoE is 5–8 weeks for ~80% coverage, 3–4 months for ~95%. Not in scope for v4.0.0 GA. |

No new C-level extension dependency. No new PostgreSQL extension dependency. `maludb_core.control` `requires` list is unchanged.

---

## 7. Doctrine V4 must preserve

The system's nine foundational invariants apply unchanged. The V4-specific applications:

1. **Corrections never silently overwrite history.** A re-derived tree under a new model alias closes the prior tree (`build_status = 'superseded'`) and opens a new `malu$page_index_tree` row; node-level changes go through the Temporal Supersession Engine.
2. **Provenance is mandatory.** Every internal node summary, every leaf summary, every structure-analysis decision, and every incremental ChatIndex append writes a `malu$derivation_ledger` entry with model alias, prompt template, input hash, output hash, and policy version.
3. **Three-stage authz on tree traversal.** Planning chooses *which trees* are visible based on Source Package authz. Candidate expansion (the LLM picking a child) sees only authorized siblings — the descent prompt is constructed from filtered candidates. Result assembly redacts unauthorized leaves before returning.
4. **Atomic multi-model writes.** A tree-build transaction writes header status, node rows, derivation ledger entries, source-reference anchors, and an event-stream emission as one commit.
5. **External services not systems of record.** The builder worker runs as a service (`services/maludb-pageindexd/` or extends an existing worker pool); durable state flows through PostgreSQL.
6. **SVPOR everywhere.** Tree-node summaries, when embedded for cross-document discovery, are SVPOR-framed: `subject = <document subject>`, `verb = 'summarizes'`, `object = <section title path>`, predicate fields drawn from the heading lineage.
7. **Stage discipline.** V4-PAGEINDEX-03 does not anticipate V4-CHATINDEX-02 changes. V4-CHATINDEX-02 does not add columns that V4-PAGEINDEX-03 should have added.

---

## 8. Per-ticket implementation plans

Each ticket plan uses the same fields as `version3-plan.md` §5:

- **Stage / Migration** — where the ticket lands.
- **Catalog & schema** — new `malu$` tables, columns, views, RLS policies.
- **C / extension** — backend code in `src/`.
- **Service binaries** — new or extended services in `services/`.
- **SQL APIs** — `maludb_core` schema functions exposed to operators.
- **REST / CLI / SDK** — external surfaces.
- **Tests** — pg_regress, isolation, service-level smoke.
- **Audit / authz / provenance** — what gets recorded, where authorization checks fire.
- **Acceptance** — verifiable exit criteria.
- **Open decisions** — what is still being chosen.

### V4-DOC-01 — V4 scope statement and authoritative-document update

- **Stage / Migration**: Stage 16 — no migration.
- **Files**:
  - `requirements.md` — add §1.6 *Version 4 — PageIndex and ChatIndex* (analogous to §1.5 V3) and §9 Stage 16 (or split as Stages 16–18 if scope grows).
  - `CLAUDE.md` — add this doc to *Authoritative documents*, update *Status* line, update *Staging strategy* to reflect Stages 16+ in progress.
  - `AGENTS.md` — mirror the CLAUDE.md updates.
  - `README.md` — add a *Version 4 Preview* section once Stage 16 closes.
  - `scripts/maludb-check-doc-consistency` — extend to know about the V4 default version and tag.
- **Acceptance**: doc-consistency gate green on the new V4 baseline; a reader following only `docs/user-manual.md` plus this plan can enumerate every V4 ticket and surface.
- **Open decisions**: whether to split this into `version4-pageindex-requirements.md` plus `version4-pageindex-plan.md` once a second V4 theme is proposed.

### V4-PAGEINDEX-01 — Tree catalog and MDO specialization

- **Stage / Migration**: Stage 17 — `0.64.0 → 0.65.0`.
- **Catalog & schema**:
  - `malu$page_index_tree` (tree_id PK, source_package_id FK, model_alias_id FK, prompt_template_id FK, parser_kind ENUM `pdf|markdown|plain_text`, build_status ENUM `pending|building|ready|stale|superseded|failed`, build_started_at, build_finished_at, superseded_by FK, owner_schema, bitemporal columns per §3.4).
  - `malu$memory_detail_object` extended:
    - `mdo_kind text NOT NULL DEFAULT 'memory_detail' CHECK (mdo_kind IN ('memory_detail','page_index_node','chat_index_topic','chat_index_message'))`
    - `tree_id bigint REFERENCES malu$page_index_tree`
    - `node_kind text CHECK (node_kind IN ('internal','leaf'))`
    - `summary text` (the LLM-generated abstract per node)
    - Tree nodes reuse the existing Stage-2 `title text` column for the section / topic name; the V4 migration does NOT add a second `title` column.
    - Composite check: `(mdo_kind = 'memory_detail' AND tree_id IS NULL AND node_kind IS NULL) OR (mdo_kind <> 'memory_detail' AND tree_id IS NOT NULL AND node_kind IS NOT NULL)`
  - `malu$derivation_ledger` `derived_object_type` CHECK extended to accept `'page_index_tree'` and `'page_index_node'`.
  - **Access model — RLS on base tables, matching V3 practice.** V3 ships row-level security on `malu$<x>` base tables and has not landed the Oracle USER/ALL/DBA tier-view trio described in `CLAUDE.md` and `docs/design/svpor-schema.md`. V4 follows V3: `malu$page_index_tree` and the new MDO columns are protected by RLS tied to the underlying Source Package's `owner_schema` and `malu$object_grant` entries — no `MALU_USER_*` / `MALU_ALL_*` / `MALU_DBA_*` views are introduced for tree or node access. Existing MDO callers continue to query `malu$memory_detail_object` directly; the new `mdo_kind` column defaults to `'memory_detail'` so their expected outputs are unchanged. The project-wide tier-view retrofit remains a deferred decision (§10.11).
- **C / extension**: none. Pure SQL migration.
- **Service binaries**: none in this ticket.
- **SQL APIs**: `page_index_tree_register(...)` (header row, status=`pending`), `page_index_tree_mark_building`, `page_index_tree_mark_ready`, `page_index_tree_mark_failed`, `page_index_tree_supersede`.
- **Tests**:
  - `sql/page_index_catalog.sql` + `expected/page_index_catalog.out` — 8 cases: tree register / status transitions / RLS isolation across tenants / MDO discriminator filtering (raw-table queries with explicit `mdo_kind = 'memory_detail'` predicate behave as before) / existing MDO consumer behavior unchanged when the discriminator defaults to `'memory_detail'` / supersession edge created on re-derivation / `derived_object_type` accepts `'page_index_tree'` and `'page_index_node'` / stage-boundary check that no V4-PAGEINDEX-02+ objects are referenced (no `source_package_promote_to_page_index`, no `page_index_builder_enqueue`).
  - Existing `sql/mdo_addressing.sql` re-runs unchanged against the bumped extension to assert the new discriminator does not change existing behavior. No edits to its expected output.
- **Audit / authz / provenance**: every status transition writes `malu$audit_event`. RLS reuses the Source Package gates.
- **Acceptance**: a tree row can be created in `pending` status against an arbitrary Source Package; MDO nodes can be inserted under it with the new discriminator; existing MDO consumers' expected outputs are unchanged; pg_regress passes on PG 17.
- **Open decisions**: whether `node_kind` belongs on every MDO row (cheap, NULLable) or only on page-index/chat-index rows (cleaner, requires partial constraint). Plan ships the former. The project-wide tier-view convention retrofit (`MALU_USER_*` / `MALU_ALL_*` / `MALU_DBA_*` over `malu$<x>` base tables) is **not** a V4 dependency; it remains deferred (§10.11) and would land as a separate refactor stage if pursued.

### V4-PARSER-01 — Pluggable parser interface, pypdf default

- **Stage / Migration**: Stage 17 — no migration.
- **Files**:
  - `services/maludb-pageindexd/src/maludb_pageindexd/parsers/__init__.py` — `PageIndexPdfParser` Protocol with `extract_outline(path) -> list[OutlineEntry]` and `extract_text_by_page(path) -> list[PageText]`.
  - `services/maludb-pageindexd/src/maludb_pageindexd/parsers/pypdf_parser.py` — default implementation using `pypdf`.
  - `services/maludb-pageindexd/src/maludb_pageindexd/parsers/markdown_parser.py` — markdown header parser (stdlib only).
  - `services/maludb-pageindexd/src/maludb_pageindexd/parsers/plain_text_parser.py` — fallback for plain text.
  - `services/maludb-pageindexd/requirements.txt` — adds `pypdf>=4.0`.
  - `debian/maludb-pageindexd.install` — packages the service.
- **Catalog & schema**: none.
- **Tests**:
  - `services/maludb-pageindexd/tests/test_pypdf_parser.py` — outline extraction on three reference PDFs (one with embedded outline, one heading-detected, one degenerate single-page).
  - `services/maludb-pageindexd/tests/test_markdown_parser.py` — three reference markdown docs.
- **Acceptance**: parser interface is implementation-agnostic; `pypdf` default returns deterministic outline + page-text on the reference corpus; swap to `pdfminer.six` (operator-installed) requires no code change beyond a config entry.
- **Open decisions**: whether the markdown parser uses stdlib-only line parsing or a small markdown library (recommend stdlib to keep zero net deps).

### V4-PAGEINDEX-02 — Promotion path and builder worker

- **Stage / Migration**: Stage 17 — `0.65.0 → 0.66.0`.
- **Catalog & schema**:
  - `malu$structure_pass_audit` (audit_id PK, tree_id FK, parser_kind, parser_version, started_at, finished_at, outline_node_count, leaf_count, deterministic_inputs_hash, outcome ENUM `ok|partial|failed`).
  - `malu$source_object_reference` already exists from V3-STOR-01; no schema change. The V4 builder writes one reference row per leaf range.
- **C / extension**: none.
- **Service binaries**:
  - `services/maludb-pageindexd/` v0.1.0. Stdlib Python + `psycopg` + `pypdf`. Polls the `pageindex_build` queue (registered via V3-QUEUE-01), runs the deterministic structure pass, calls `maludb_modeld` for per-node summarization, writes node rows + ledger entries + reference rows + status transitions in one transaction per node batch.
- **SQL APIs**:
  - `source_package_promote_to_page_index(source_package_id, parser_kind, model_alias, prompt_template, builder_options jsonb)` — inserts `malu$page_index_tree` row in `pending` status, enqueues a `pageindex_build` job on V3-QUEUE-01, returns `tree_id`.
  - `page_index_record_structure_pass(tree_id, ...)` — called by the worker after the deterministic pass.
  - `page_index_record_node(tree_id, parent_mdo_id, node_kind, title, summary, source_reference_id, model_alias, prompt_template, input_hash, output_hash)` — atomic node insert + ledger entry.
  - `page_index_chunker_handoff(tree_id) RETURNS TABLE (leaf_mdo_id, source_reference_id)` — returns leaf ranges so the V3-EMBED-01 chunker can run in "use precomputed boundaries" mode.
- **V3-EMBED-01 extension**: small. `embedding_enqueue` gains an optional `precomputed_boundaries_from_tree_id` argument; the chunker, when invoked with that argument, reads leaf ranges from `page_index_chunker_handoff(tree_id)` instead of running its own splitter.
- **REST / CLI / SDK**: see V4-MC2DB-01 / V4-CLI-01.
- **Tests**:
  - `sql/page_index_promote.sql` — 6 cases: promote a fixture Source Package / re-promote produces supersession edge / structure-pass audit row created / leaf ranges match across calls / unauthorized Source Package rejected / atomicity check (a forced builder failure rolls back).
  - `services/maludb-pageindexd/tests/test_builder.py` — 4 service-level cases against the live extension: end-to-end build, idempotent retry, model failure → builder marks `failed` + DLQ, structure-pass determinism on the same PDF.
- **Audit / authz / provenance**: every node row writes a Derivation Ledger entry. The structure-pass audit is its own row. The promotion call writes a `malu$audit_event` row.
- **Acceptance**: a fixture PDF promotes to a complete tree under a pinned model alias; re-promoting under the same alias produces an identical leaf-range set; re-promoting under a *new* alias produces a superseded prior tree and a fresh tree with new summaries but identical leaf ranges; chunker handoff produces vector chunks aligned 1:1 with leaves.
- **Open decisions**: builder concurrency (one tree at a time per service vs node-level parallelism). Plan ships single-threaded per tree for v1.

### V4-PAGEINDEX-03 — Retrieval planner integration

- **Stage / Migration**: Stage 18 — `0.66.0 → 0.67.0`.
- **Catalog & schema**:
  - `malu$retrieval_envelope` (from V3-RET-01) gains columns: `tree_descent_used boolean`, `tree_descent_path jsonb` (ordered list of `{tree_id, node_mdo_id, model_choice, reason}` for debug mode), `tree_descent_authz_rejections int`.
  - `malu$retrieval_decision_audit` gains a new `stage` value `'tree_descent'`.
  - The planner's intent classifier gains two intents: `'structured_doc_qa'` and `'long_chat_recall'`.
- **C / extension**: none.
- **Service binaries**: none new; `maludb-restd` and the planner SQL functions are extended.
- **SQL APIs**:
  - `retrieve_with_envelope(...)` extended to detect when the resolved Source Package set contains trees and to invoke `tree_descent_retrieve(envelope_id, tree_id, descent_options)`.
  - `tree_descent_retrieve(envelope_id, tree_id, descent_options jsonb) RETURNS TABLE (...)` — calls `maludb_modeld` with a descent prompt template; the candidate set passed to the LLM is **already authz-filtered**; the LLM choice is checked against the filtered set before descending; assembly redacts unauthorized leaves.
  - `tree_descent_prompt_template_v1` — seeded prompt template versioned in `malu$prompt_template`.
- **Tests**:
  - `sql/retrieval_envelope.sql` extended — 5 new cases: intent classification routes `structured_doc_qa` to tree descent / descent records per-step decisions / unauthorized siblings never appear in the descent prompt / descent_path is populated in debug mode / vector chunk hit feeds into descent at the matching leaf (Mode B from the design conversation).
  - Isolation test: concurrent tree supersession during an in-flight descent returns a stable result and records the descent against the pre-supersession `tree_id`.
- **Audit / authz / provenance**: every model invocation inside a descent records a Derivation Ledger entry (kind `retrieval_summary`). Every descent step writes a `malu$retrieval_decision_audit` row with `stage='tree_descent'`.
- **Acceptance**: a `structured_doc_qa` intent on a project with PageIndex trees produces a descent trail in debug mode; non-auditors do not see the trail; unauthorized leaves are not returned; three-stage authz is enforced.
- **Open decisions**: prompt template wording (will iterate post-alpha.3); whether the descent uses `top_p` / temperature-0 by default (recommend temperature-0 for stability).

### V4-CHATINDEX-01 — Chat tree catalog

- **Stage / Migration**: Stage 19 — `0.67.0 → 0.68.0`.
- **Catalog & schema**:
  - `malu$chat_index_tree` (tree_id PK, source_package_id FK, model_alias_id FK, prompt_template_id FK, build_status ENUM as above, current_node_mdo_id bigint REFERENCES `malu$memory_detail_object`, max_children int DEFAULT 10, sub_node_count int DEFAULT 0, ...).
  - Existing `malu$memory_detail_object` extended with chat-specific columns (NULLable unless `mdo_kind IN ('chat_index_topic','chat_index_message')`):
    - `topic_name text`
    - `system_message text`
    - `user_message text`
    - `assistant_message text`
    - `message_index int`
  - `malu$derivation_ledger` `derived_object_type` CHECK extended to accept `'chat_index_tree'`, `'chat_index_topic'`, `'chat_index_message'`.
  - **Access model**: RLS on `malu$chat_index_tree` and on the new MDO columns via the Source Package's `owner_schema` and `malu$object_grant`. No tier views introduced — same posture as V4-PAGEINDEX-01.
- **C / extension**: none.
- **Service binaries**: `services/maludb-pageindexd/` extended (or split into `services/maludb-chatindexd/` if the worker code diverges enough — recommend keeping one service for v1).
- **SQL APIs**: `source_package_promote_to_chat_index(...)`, `chat_index_record_topic(...)`, `chat_index_record_message(...)`.
- **Tests**: `sql/chat_index_catalog.sql` — 6 cases mirroring V4-PAGEINDEX-01 plus message/topic shape validation.
- **Audit / authz / provenance**: same as PageIndex.
- **Acceptance**: a fixture chat transcript Source Package promotes to a complete chat tree; topic and message nodes carry the right payload columns; views isolate per tier.
- **Open decisions**: chat transcript ingestion format (JSON Lines vs MaluDB-native message object). Plan ships JSON Lines as the v1 ingest shape, mapped to Source Object on capture.

### V4-CHATINDEX-02 — Incremental append

- **Stage / Migration**: Stage 19 — `0.68.0 → 0.69.0`.
- **Catalog & schema**:
  - `malu$chat_index_tree.current_node_mdo_id` becomes load-bearing.
  - `malu$chat_index_append_audit` (append_id PK, tree_id FK, appended_at, message_index_first, message_index_last, opened_new_topic boolean, ancestor_branch_used boolean, decision_reason text).
- **SQL APIs**:
  - `chat_index_append_messages(tree_id, messages jsonb)` — appends one or more messages, decides whether they extend the current leaf or open a new topic node from the current node or an ancestor. Enforces the "new topics branch only from current node or its ancestors" rule.
  - `chat_index_close_topic(tree_id, topic_node_mdo_id)` — manual override; admin-only.
- **Tests**:
  - `sql/chat_index_append.sql` — 7 cases: extend current leaf / open new topic from current node / open new topic from ancestor / reject branching from a non-ancestor / append idempotency on duplicate `message_index` / supersession on retroactive correction / RLS isolation.
  - Isolation test: two concurrent appends on the same tree are serialized.
- **Audit / authz / provenance**: every append writes `malu$chat_index_append_audit`. Each topic/message MDO insert writes a Derivation Ledger entry.
- **Acceptance**: a chat tree can ingest messages incrementally over many calls; the resulting tree is byte-equivalent to a one-shot ingest of the same message sequence; the ancestor-branch rule is enforced.
- **Open decisions**: TTL / inactivity timeout for the `current_node_mdo_id` pointer (does a long pause force a new topic? recommend no — let the next message's content drive the decision via the LLM).

### V4-MC2DB-01 — MC2DB tools

- **Stage / Migration**: piggybacks on existing migrations; no V4-MC2DB-01-owned migration.
- **Tools registered via `mc2db.register_tool`**:
  - `maludb.pageindex.build` — promote a Source Package to a PageIndex tree.
  - `maludb.pageindex.ask` — descent retrieval over a tree.
  - `maludb.pageindex.list` — list trees visible to the caller.
  - `maludb.pageindex.tree_summary` — return the root + first-level node titles + summaries.
  - `maludb.chatindex.build`, `.append`, `.ask`, `.list`.
- **Risk class**: `build`/`append` are `state_changing`; `ask`/`list`/`tree_summary` are `read_only`.
- **Tests**: extension of `mc2dbd/tests/run_all.sh` with end-to-end round-trips.
- **Acceptance**: MC2DB clients (any MCP-capable agent) can build, append, ask, and list trees under the same authz as direct SQL callers.

### V4-REST-01 — REST endpoints

- **Stage / Migration**: piggybacks; no migration. Catalog entries land via `rest_register_endpoint`.
- **Endpoints** (registered in `malu$rest_endpoint`):
  - `POST /pageindex/build`, `GET /pageindex/trees`, `GET /pageindex/trees/:tree_id`, `POST /pageindex/ask`.
  - `POST /chatindex/build`, `POST /chatindex/append`, `GET /chatindex/trees`, `POST /chatindex/ask`.
- **OpenAPI**: generated from the catalog.
- **Acceptance**: REST callers authenticate via V3-AUTH-01 tokens; behavior matches SQL and MC2DB.

### V4-CLI-01 — `maludb pageindex` and `maludb chatindex`

- **Stage / Migration**: piggybacks; no migration.
- **Subcommands**:
  - `maludb pageindex build <source_package_id> [--model-alias ...] [--parser pdf|markdown|plain_text]`
  - `maludb pageindex list [--project ...]`
  - `maludb pageindex show <tree_id> [--depth N]`
  - `maludb pageindex ask <tree_id> --query "..." [--debug]`
  - `maludb pageindex supersede <tree_id> --reason "..."`
  - `maludb chatindex build <source_package_id> ...`
  - `maludb chatindex append <tree_id> --messages-jsonl <path>`
  - `maludb chatindex ask <tree_id> --query "..."`
- **Acceptance**: CLI smoke tests pass; every state-changing command emits audit.

### V4-SDK-01 — SDK parity

- **Stage / Migration**: piggybacks; no migration.
- **C / Python / Node.js / PHP**: typed wrappers for `pageindex_build`, `pageindex_ask`, `pageindex_list`, `chatindex_build`, `chatindex_append`, `chatindex_ask`.
- **Generated OpenAPI/JSON schema** drives typed clients via the existing V3-SDK-01 pipeline.
- **Acceptance**: smoke tests pass in each language; OpenAPI types match REST surface.

---

## 9. Cross-cutting engineering rules

These apply across every V4 ticket; they are not optional.

1. **`mdo_kind` filter is mandatory on every MDO-touching code path.** Any code path that reads `malu$memory_detail_object` directly must filter `mdo_kind` to the values it expects. The default view is filtered; raw-table access requires an explicit filter.
2. **Deterministic structure pass is the contract.** The builder MUST NOT call the LLM for boundary decisions in PageIndex. ChatIndex topic-opening decisions MAY call the LLM, but the message-author and timestamp boundaries that anchor those decisions remain deterministic.
3. **Pin model alias + prompt template version on every tree.** Re-derivation under a new alias is a *new tree*, not an update to the old tree.
4. **Builder transactions commit per node batch, not per tree.** A failed batch puts the tree in `failed` with a recoverable cursor; resuming the same job is idempotent via the V3-QUEUE-01 idempotency key.
5. **Three-stage authz on tree descent is not optional.** The LLM never sees an unauthorized sibling. The descent prompt is constructed from the authz-filtered set; the choice is re-checked before traversal.
6. **V3-EMBED-01 chunker handoff is the only chunking path.** V4 must not introduce a second chunker.
7. **The `pypdf` dependency is the only new runtime dependency.** Anything else is operator-pluggable but not bundled.

---

## 10. Open decisions

Carry forward, do not retro-edit.

1. **In-house PDF parser** — deferred. Honest LoE 5–8 weeks for ~80% real-world coverage; security cost is real. Revisit if `pypdf` ever becomes blocking.
2. **Vision PDFs** — deferred. OCR via the existing model gateway is the most likely future path; not in V4 scope.
3. **AGPL parser (`PyMuPDF`) operator opt-in policy** — document the configuration in the admin guide; default deny.
4. **Builder concurrency model** — single-threaded per tree in v1; revisit if benchmark fixtures show contention bottlenecks.
5. **Chat transcript ingest format** — JSON Lines for v1; revisit if customers need OpenAI / Anthropic message-format adapters.
6. **`maludb-pageindexd` vs `maludb-chatindexd` service split** — one service for v1; revisit if worker code diverges.
7. **Descent prompt template wording** — first cut in V4-PAGEINDEX-03; iterate post-alpha.3 based on benchmark recall.
8. **AMP retire → ChatIndex automation** — out of v4.0.0 scope; could be a v4.1 or v5 ticket.
9. **Multilevel HNSW or pgvector delegation for node-summary embeddings** — defer to the existing V3-VEC-01 open decision; tree-node summaries are short and small in number, so the choice is unlikely to be load-bearing for V4.
10. **GraphQL surface over trees** — deferred (same posture as the V3 GraphQL decision).
11. **Project-wide tier-view retrofit (`MALU_USER_*` / `MALU_ALL_*` / `MALU_DBA_*` over `malu$<x>` base tables)** — deferred. The convention is documented in `CLAUDE.md` and `docs/design/svpor-schema.md` but has never landed in shipped migrations; V3 GA and v3.1.0 both ship RLS-on-base-tables. V4 follows that practice for `malu$page_index_tree`, `malu$chat_index_tree`, and the MDO discriminator columns. Retrofitting the trio across the existing object surface would be a multi-stage refactor; revisit only if a concrete operator need or a doctrine reaffirmation makes it load-bearing.

---

## 11. Risks

1. **`pypdf` PDF coverage on real-world institutional corpora.** Mitigation: ship a small fixture corpus (~20 PDFs spanning SEC filings, contracts, internal docs); CI runs the builder against each; failures surface before tag.
2. **LLM-driven descent latency.** A multi-step descent can be slow if each node requires a model call. Mitigation: descent prompt asks for *one* child choice per step; cap depth at a configurable value (default 6); benchmark p95 against fixture queries.
3. **Tree drift under model alias updates.** Mitigation: supersession edge + Derivation Ledger keeps the prior tree queryable; ALL retrieval against a tree records the resolved `tree_id` so audit can replay.
4. **MDO discriminator leakage.** A code path that forgets to filter `mdo_kind` could surface tree nodes as memory details. Mitigation: pg_regress isolation test enumerates every existing MDO view and confirms the filter; CI catches regressions.
5. **ChatIndex incremental append concurrency.** Two concurrent appends on the same tree must not interleave topic decisions. Mitigation: `SELECT … FOR UPDATE` on the tree header during append; serialize within a tree, parallel across trees.

---

## 12. V4-PageIndex / ChatIndex acceptance criteria

V4 PageIndex / ChatIndex is complete when:

1. `docs/user-manual.md`, `README.md`, `requirements.md`, and this plan agree on the shipped version, surface, and tag.
2. A fresh Ubuntu 24.04 host can install MaluDB, create the extension, start `maludb-pageindexd` alongside the V3 services, build a PageIndex tree from a fixture PDF, build a ChatIndex tree from a fixture transcript, and pass the V4 field test.
3. REST, MC2DB, CLI, and SDKs all authenticate against V3-AUTH-01 tokens for PageIndex and ChatIndex operations with identical RLS posture.
4. A re-derivation of a tree under a new model alias produces a supersession edge to the prior tree; leaf ranges are unchanged; summaries are new.
5. V3-EMBED-01 chunker, when invoked with `precomputed_boundaries_from_tree_id`, produces vector chunks aligned 1:1 with tree leaves.
6. Tree descent retrieval is authz-enforced at planning, candidate expansion, and result assembly; non-auditors do not see descent trails or unauthorized leaves; descent records appear in `malu$retrieval_decision_audit` with `stage='tree_descent'`.
7. Every tree node, structure-pass run, and ChatIndex append has a Derivation Ledger entry.
8. ChatIndex incremental append over many calls produces a tree byte-equivalent to a one-shot ingest of the same message sequence.
9. `pg_regress` passes on PostgreSQL 17; V4 service / SDK smoke tests pass; benchmark fixtures publish recall / latency baselines for the fixture PDF + chat corpora.
10. ASan / UBSan / `clang-tidy` / `scan-build` add no new warnings for any C code touched by V4. (V4 currently introduces no new C code; this criterion stays in place to catch incidental changes.)
11. The bundled `.deb` artifact set extends to include `maludb-pageindexd_X.Y.Z-1_amd64.deb` alongside the existing V3 packages.

---

*This document is updated when V4 scope changes. It is the single source of truth for V4 PageIndex / ChatIndex implementation. The conceptual reference for PageIndex remains `docs/pageindex/PageIndex_Technology_Guide.md` and the upstream repositories; this plan governs how those concepts land in MaluDB under the project's invariants.*
