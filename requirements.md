# MaluDB — Requirements

This document is the authoritative roadmap requirements specification for **MaluDB**, the memory DBMS for long-term institutional memory, human–AI knowledge sharing, and contextual recall. It is the canonical statement of what the implementation must satisfy.

MaluDB is a **database management system for long-term institutional memory, human-AI knowledge sharing, and contextual recall**. It treats memories as first-class data objects governed by a single coherent DBMS rather than glued together from polyglot stores. The initial implementation language is **C**. The base platform is **PostgreSQL 17** on **Ubuntu 24.04 LTS**. The system extends PostgreSQL through C extensions, in-database SQL/PL/pgSQL objects, and external services where appropriate; it does not fork PostgreSQL in R1.0.

The default operator experience is an integrated MaluDB installation: installing MaluDB installs, configures, and manages the required PostgreSQL base, PostgreSQL extensions, MaluDB extension objects, and MaluDB services together. PostgreSQL remains the upstream PGDG PostgreSQL package foundation, not a forked or private embedded storage engine.

Normative language is intentional: **MUST** defines requirements required for conformance, **SHOULD** defines expected behavior with documented exceptions, and **MAY** defines permitted implementation choices. When this document turns white-paper concepts into implementation requirements, it should prefer concrete acceptance criteria, staged delivery, and physical PostgreSQL constraints over broad conceptual restatement.

---

## 1. Scope

### 1.1 Version Release 1.0 scope

In this document, **Version Release 1.0** or **R1.0** means the first releasable MaluDB DBMS slice. R1.0 is intentionally narrower than the complete institutional-memory roadmap: it proves the PostgreSQL foundation, DB-managed model sessions, short-term session context, and a database-native MCP-compatible listener.

R1.0 MUST include:

- The core PostgreSQL engine foundation: PostgreSQL 17 from PGDG, pgvector, `maludb_core`, PGXS build, packaging, CI, catalog scaffolding, and vector demonstration objects.
- A DB-owned **Session Context** structure for short-term user/model session memory, including ordered context blocks, prompt-template bindings, token/context-window policy, hashes, lifecycle state, and audit metadata.
- A model runtime/gateway that lets local models access the database through governed SQL/session APIs, with `llama.cpp` / `libllama` as the first reference local runtime unless dependency review selects an equivalent.
- Cloud model calls through the same session/request/response process as local models, so model provider choice does not change prompt rendering, session context, audit, or database access paths.
- MC2DB as an early database listener extension surface: a configurable MCP-compatible network listener, defaulting to `https://localhost:5329`, that accepts MCP-shaped input, performs lifecycle/tool/prompt/resource handling, and dispatches authorized database operations.
- An integrated installation and service layout that presents PostgreSQL, MaluDB extension objects, the model gateway, and the MC2DB listener as one managed DBMS release.

R1.0 explicitly does not need the full memory object model, bitemporal truth, long-term memory ingestion, workflow extraction, skill execution, local memory nodes, or hybrid retrieval planner. Those remain roadmap features after R1.0.

### 1.2 Roadmap scope after R1.0

After R1.0, the roadmap expands toward the full MaluDB memory DBMS:

- A governed object model for **source packages, claims, facts, Episode Objects, memories, Memory Detail Objects, workflow traces, generalized workflows, procedural memories, skills, and relationships**.
- **Bitemporal** valid-time and transaction-time semantics with explicit supersession, contradiction, and staleness state.
- A **derivation ledger** that traces every derived object back to its source evidence and the model/parser/policy/human action that produced it.
- A **verbatim source archive** that preserves raw inputs (documents, tickets, transcripts, logs, API payloads) when policy and retention permit.
- **Confidence and precision** stored as separate MAUT-weighted aggregates with their per-category breakdowns, weights, and evaluator versions.
- **Lifecycle, salience, reinforcement, decay, consolidation, archival movement, retention, legal hold, and policy-governed pruning** as explicit operations rather than implicit retrieval-ranking behavior.
- A **Subject-Verb-Predicate-Object-Relationship** organization layer that participates in indexing, retrieval planning, and embedding inputs.
- **Recursive Memory Detail Objects** addressable independently of their parent memory.
- **Hybrid retrieval** spanning relational/catalog filters, full-text search, graph traversal, temporal constraints, vector similarity, and recursive detail expansion, planned as a **search path** rather than a fixed pipeline.
- An **authorization model** that scopes grants to subjects, verbs, topics, projects, partitions, source types, workflows, and active memory pools — not only tables and collections.
- **Active Memory Pools**: scoped, low-latency working sets shared by humans and AI agents during a task.
- **Local Memory Nodes**: offline/edge subsets that synchronize back to the Enterprise Memory Core under governance.
- Retrospective and continuous ingestion of heterogeneous institutional sources, including documents, conversations, tickets, logs, database records, API payloads, and event/time-series data.
- A **Workflow Extraction Engine** that proposes candidate workflow traces and generalized workflows from Episode Objects and source evidence, reviewable rather than auto-promoted.
- A **Skill Runtime** that executes governed skill packages or competency packages as state machines with audit records.
- A **Model Registry** for embedding models, extraction models, rerankers, summarizers, with version-aware migration support.
- **Replay semantics**: reconstruct the historical, current-valid, transaction-time, or full bitemporal view of an Episode Object under the requesting account's privileges.
- Driver/API access for at minimum **C, Python, Node.js, and PHP** clients.

### 1.3 Out of scope (R1.0 and roadmap, may be added later)

- Active-active replication, distributed consensus, multi-master clustering, cross-region failover.
- A causal-inference subsystem (the system stores typed causal edges with metadata; it does not yet derive causal chains, evaluate interventions, or answer counterfactuals automatically).
- A bespoke storage engine. R1.0 builds on PostgreSQL's existing storage; a custom WAL/MVCC engine is a deferred decision.
- Automatic promotion of any model output to fact or memory without provenance, evidence linkage, and policy-controlled review.
- Treating any AI-generated output as authoritative truth.

### 1.4 Non-goals

- Replacing authoritative source systems (email, ticketing, source control, observability, transactional DBs). Those remain systems of record; MaluDB preserves, links, interprets, and recalls knowledge derived from them.
- Storing every transient message or intermediate thought without curation, validation, and lifecycle policy.

### 1.5 Version 3 — Platform Ergonomics

**Version 3** (or **V3**) is the post-`v2.0.0-alpha` release that turns the shipped memory DBMS into a self-hostable platform with the developer and operator ergonomics expected of a modern data product. V3 takes Supabase's *platform-coherence* lesson — one curated stack of HTTP APIs, identity, storage, realtime, jobs, observability, and environment tooling — and applies it to the MaluDB memory model. V3 does **not** clone Supabase's product surface and does **not** revise the memory model, provenance, bitemporal discipline, three-stage authorization, or atomic multi-model writes that the rest of this document specifies.

The authoritative V3 ticket-level requirements and implementation plan are captured in §1.5, §8, and §9 of this document. This is the canonical V3 roadmap and is updated when V3 scope changes.

V3 MUST deliver, at minimum:

- **First-party API credentials** (personal and service tokens, JWT verification) with the same RLS-bound account binding for SQL, MC2DB, and the new REST gateway. Out of scope for V3: password login, email OTP, magic links, social OAuth, enterprise SSO, MFA, Web3 login, CAPTCHA.
- **A governed secret store** with at-rest encryption or external resolver, rotation, versioning, last-used metadata, and audit. Provider/tool secrets MUST NOT be exposed through ordinary SQL views.
- **A curated REST API gateway** over stable functions — not generic CRUD over private `malu$` tables — with OpenAPI generation, structured SQLSTATE-mapped error codes, and the same authorization gates as SQL and MC2DB.
- **A verbatim source archive v1** with immutable hash-verified object catalog, local-filesystem and S3-compatible adapters, signed download URLs, retention class, legal-hold state, and a promotion path into Source Packages, Claims, and Derivation Ledger entries.
- **A durable job queue** for ingestion, embedding, re-derivation, broker-audit, lifecycle, ANN rebuild, and notification fanout, with visibility timeout, retry, dead-letter, idempotency, priority, and account-isolated visibility.
- **A scheduler** for lifecycle sweeps, embedding refresh, ANN rebuilds, backup checks, capability probes, queue reapers, and source connector polls.
- **A memory-native realtime event stream** (SSE or WebSocket) with authorized subscriptions and replayable events for model requests, MC2DB tool calls, active pool changes, claim promotion, episode replay completion, queue state, source ingest progress, and audit alerts. **Active memory pool presence** participants MUST be tracked under the same authorization rules.
- **Vector and retrieval ergonomics**: metadata filters on compartment search without bypassing SVPOR, an explicit decision between upgrading local NSW to multilevel HNSW or delegating large compartments to pgvector HNSW (with exact search preserved for validation/tests), bulk import/export, recall/latency benchmarks, and a public retrieval endpoint with explicit envelope/debug surfaces. **Embedding jobs** MUST queue through the V3 queue and produce SVPOR-framed text plus Derivation Ledger entries.
- **A first-party `maludb` CLI** that calls the stable SQL/HTTP/MC2DB APIs (rather than duplicating business logic), supports human and JSON output, and emits audit for every state-changing command. **SDK parity** across C/Python/Node.js/PHP with generated OpenAPI/JSON schema types and typed token configuration.
- **Self-hosted preview environments** for migration-driven, data-minimized previews of the database, services, RLS, REST, MC2DB, queues, cron, and retrieval. No production data by default; optional anonymized seed export with policy hooks and audit.
- **Expanded metrics** covering extension/migration state, MC2DB and REST request lanes, model queue depth/latency/tokens/cost, queue depth/retry/DLQ/lease age, cron success/failure/duration, source archive bytes and verification, vector index status, retrieval candidate counts, and active pool/event-stream subscriptions. **Log drains** MUST batch PostgreSQL/audit/model/MC2DB/REST/broker logs to HTTP/file/S3/OTLP with redaction rules and V3-secrets-backed destination credentials. **Backup and PITR** MUST ship a manifest covering DB dump/basebackup, WAL archive, `/etc/maludb`, source archive, model configs, TLS, tool binaries, and broker configs, with a CLI verification path. **Read replicas** are documented for read-heavy retrieval; write endpoints MUST NOT route to replicas.

V3 explicitly does NOT scope: a full email/password/OAuth/SSO/MFA identity provider, a global edge function network, CDN-backed public asset hosting and image transformations, a Supabase Studio equivalent, billing/organizations/spend caps/hosted project lifecycle, a generic GraphQL API over all MaluDB tables, an extension marketplace, or active-active replication.

V3 release tagging targets `v3.0.0` once every V3 ticket in §9 Stages 8–15 reaches its acceptance criteria; alpha/beta tags MAY be issued per stage.

### 1.6 Version 4 — PageIndex and ChatIndex

**Version 4** (or **V4**) is the post-`v3.x` track that adds **PageIndex** and **ChatIndex** as governed memory surfaces over the Verbatim Source Archive. PageIndex is a tree-of-summaries with LLM-guided descent over a single text-bearing Source Package; ChatIndex is the analogous tree over a chat-transcript Source Package with incremental-append semantics. V4 does **not** revise the memory model, provenance, bitemporal discipline, three-stage authorization, or atomic multi-model writes that the rest of this document specifies.

The authoritative V4 ticket-level plan, including per-ticket deliverables, migration assignments, acceptance criteria, license decisions, and open questions, lives in [`version4-pageindex-plan.md`](version4-pageindex-plan.md). The conceptual reference for PageIndex / ChatIndex lives in [`docs/pageindex/PageIndex_Technology_Guide.md`](docs/pageindex/PageIndex_Technology_Guide.md). This document remains the canonical roadmap and is updated when V4 scope changes; the V4 plan MUST NOT drift from §1.6 and §9 Stages 16+.

V4 MUST deliver, at minimum:

- **PageIndex tree catalog** with one tree per Source Package per build generation, addressable by stable `tree_id`. Nodes specialize `malu$memory_detail_object` via an `mdo_kind` discriminator (`'memory_detail'` | `'page_index_node'` | `'chat_index_topic'` | `'chat_index_message'`). The discriminator MUST default to `'memory_detail'` so existing MDO consumers behave unchanged.
- **ChatIndex tree catalog** with topic and message node kinds, incremental append, a current-node pointer, and the upstream rule that new topics branch only from the current node or one of its ancestors.
- **Deterministic structure pass** for boundary decisions. PDF outline parsing, markdown header parsing, plain-text degenerate trees, and chat message-author/timestamp boundaries MUST be deterministic. Re-deriving a tree under a new model alias MUST change summaries, not boundaries.
- **LLM-driven summarization pass** through the existing model gateway with pinned model alias and prompt-template version, recorded per node in the Derivation Ledger.
- **`pypdf` (BSD-3-Clause) as the bundled default PDF parser** behind a pluggable parser interface. AGPL parsers (`PyMuPDF`) MAY be plugged in by operators who accept those terms but MUST NOT be bundled in the redistributed product. Vision / image-only PDFs are explicitly out of V4 scope.
- **Two-stage retrieval integration.** The Stage-4 retrieval planner MUST be extended with a `tree_descent` search path. Tree descent is invoked only when the resolved Source Package set has trees; it does not replace any existing retrieval path. The descent prompt is constructed from the authz-filtered candidate set, the LLM's choice is re-checked before traversal, and result assembly redacts unauthorized leaves.
- **Chunker handoff.** The V3-EMBED-01 chunker MUST, when invoked with a `precomputed_boundaries_from_tree_id` argument, produce vector chunks aligned 1:1 with tree leaves. V4 MUST NOT introduce a second chunker.
- **Supersession on re-derivation.** A re-derived tree under a new model alias transitions the prior tree to `build_status = 'superseded'`, opens a fresh row, and writes a `supersedes` edge. Leaf ranges remain valid across the supersession; only summaries change.
- **MC2DB, REST, CLI, and SDK parity** for tree build, append (ChatIndex), descent, listing, and root-summary inspection. All surfaces share the V3-AUTH-01 token model and the same authorization gates as direct SQL.
- **Provenance coverage.** Every internal-node summary, every leaf summary, every structure-pass run, and every ChatIndex append MUST write a `malu$derivation_ledger` entry.
- **No new C-level or PostgreSQL-extension dependency.** `maludb_core.control` `requires` is unchanged. The only new runtime dependency in the redistributed product is `pypdf`, consumed by the new `maludb-pageindexd` service.

V4 explicitly does NOT scope: vision / image-only PDF ingestion, OCR pipelines, AGPL parsers in the bundled product, an AMP-retire → ChatIndex automation, a GraphQL surface over trees, or a project-wide retrofit of the Oracle USER/ALL/DBA tier-view convention (V4 follows V3 RLS-on-base-tables practice; see `version4-pageindex-plan.md` §10.11).

V4 release tagging targets `v4.0.0` once every V4 ticket in §9 Stages 16+ reaches its acceptance criteria; alpha/beta tags MAY be issued per stage.

---

## 2. Target Platform

| Item | Target |
|---|---|
| OS | Ubuntu 24.04 LTS (Noble Numbat), x86_64 and arm64 |
| Database | PostgreSQL 17 from the **PGDG apt repository** (`apt.postgresql.org`), installed and configured by the default MaluDB installation bundle |
| Language (server-side extensions) | C, **C11** standard |
| Language (in-DB stored procedures) | SQL, PL/pgSQL; PL/Python sandboxed where required |
| Model runtime | `llama.cpp` / `libllama` is the first local reference candidate; cloud model providers use the same MaluDB session/request/response contract through provider adapters |
| Compiler | gcc 13.x default; Clang 18 for sanitizer/static-analysis builds |
| Build system | **PGXS Makefile** for extensions; `pg_buildext` / `dh_make_pgxs` for Debian packaging |
| LLVM JIT | LLVM 18 (Ubuntu 24.04 default) |
| License | **PostgreSQL License** (BSD-style) for own code; permissive deps only |

PG 16 must build cleanly through the same matrix to support migration. PostgreSQL 18 is now an official supported PostgreSQL release series; PG 18 compatibility is a CI target once PGDG `noble` packages and required extension packages are validated. The product baseline and minimum supported runtime remain PG 17 until the project explicitly decides to bump them.

The default installation MUST NOT require operators to provision PostgreSQL manually before installing MaluDB. MaluDB packages, containers, or deployment bundles MUST declare, install, configure, and validate the required PostgreSQL base and PostgreSQL extensions as part of the MaluDB install path. An advanced installation mode MAY target an existing compatible PostgreSQL cluster when the operator explicitly chooses that mode.

---

## 3. Functional Requirements

### 3.1 Memory Object Model

The DBMS MUST provide first-class object types with stable identifiers, version history, lifecycle state, and access-control metadata for each of the following:

| Object | Purpose |
|---|---|
| **Source Package** | Verbatim raw input (document, transcript, ticket, log, API payload) with timestamp, hash, retention class, and origin. |
| **Claim** | An assertion extracted from a source. May be unverified, contradicted, partially true, or imprecise. Always linked to one or more source references with offsets. |
| **Fact** | A claim, or set of claims, accepted as true within a defined scope according to verification rules. |
| **Episode Object** | The concrete DBMS representation of a specific remembered episode (installation, outage, decision, migration, etc.). Binds source evidence, structure, time, relationships, security labels, and lifecycle state. |
| **Memory** | A contextual record of an event, decision, discovery, lesson, dependency, or change. May aggregate multiple facts, claims, and Episode Objects. |
| **Memory Detail Object** | Addressable child or linked object representing a step, substep, parameter, command, validation, exception, source excerpt, or evidence item. Recursively containable. |
| **Workflow Trace** | The observed sequence of steps for one Episode Object/case. |
| **Generalized Workflow** | A repeatable process pattern derived from one or more traces. |
| **Procedural Memory Object** | Capability-oriented how-to knowledge for performing, adapting, validating, and repairing work. Distinct from a Workflow. |
| **Skill Package** | Governed, evidence-backed procedural memory packaged for reuse with execution policy and audit records. |
| **Competency Package** | Governed bundle of one or more procedural memories or skills representing a validated operational capability for humans or AI agents. |
| **Relationship Edge** | Typed edge between any two governed objects (e.g., `supports`, `contradicts`, `supersedes`, `derived_from`, `verified_by`, `caused_by`, `depends_on`, `part_of`, `related_to`, `before`, `after`, `inside`, `with`, `from`, `has_detail`, `contains`). |

Every object MUST carry: stable ID, version, lifecycle state (`current`, `historical`, `stale`, `superseded`, `contradicted`, `consolidated`, `decayed`, `archived`, `retired`), partition membership, security labels, derivation ledger reference, and bitemporal fields (see §3.4).
Objects used in retrieval MUST also expose current-applicability and salience metadata sufficient for the retrieval coordinator to distinguish historical truth from operational guidance.

### 3.2 Subject-Verb-Predicate-Object-Relationship (SVPOR) Organization

The DBMS MUST organize memory objects under a grammar-inspired semantic frame:

- **Subject** — primary entity (person, project, system, organization, customer, place, AI agent, document, application).
- **Verb** — action class or state (`installed`, `decided`, `discovered`, `failed`, `approved`, `migrated`, `learned`, `verified`, …).
- **Predicate** — structured semantic frame (purpose, rationale, outcome, actor, role, reason, environment, event_date, …).
- **Object** — the thing acted on or remembered. May carry a payload (summary + structured fields + embeddings) and may itself be another entity.
- **Relationship** — typed graph edge between objects (broader than English prepositions; see §3.1).

The SVPOR frame MUST be:

1. **An organizing/routing index**: the retrieval planner uses it to compartmentalize search before more expensive operations.
2. **A grant target**: privileges may be granted on subjects, verbs, topics, predicates, and relationship types.
3. **An embedding input**: when a memory chunk, source excerpt, workflow trace, or summary is embedded, the relevant subject, verb, predicate, and object frame MUST be incorporated into the embedded text. Query-time retrieval MUST use the same frame when extractable from the prompt or hints.

### 3.3 Confidence and Precision (MAUT-based)

The DBMS MUST model **confidence** and **precision** as **separate dimensions**, each computed via **Multi-Attribute Utility Theory (MAUT)** weighted aggregates with normalized category scores in `[0,1]` and weights summing to 1.

**Fact confidence** categories: extraction, source, evidence, truth, verification.
**Fact precision** categories: temporal, entity, relationship, location, semantic, scope.
**Memory confidence** categories: supporting facts, claim consistency, source diversity, inference, temporal coherence, contradiction status, staleness status.
**Memory precision** dimensions: temporal, actor, entity, causal, decision, procedural, contextual.
**Workflow confidence** factors: supporting memory count, outcome quality, source diversity, step consistency, evidence strength, contradiction status, current validity.
**Workflow precision** dimensions: step specificity, ordering precision, actor/tool/environment precision, input/output precision, validation precision, exception-path precision.
**Procedural-memory confidence** MUST NOT be copied from its supporting workflows; it MUST be evaluated against supporting outcomes, operational diversity, exception coverage, validation checks, and current applicability.
**Procedural-memory precision** MUST describe how specifically the DBMS can apply the retained know-how, including preconditions, decision branches, tool versions, safety limits, fallback paths, and evidence links.

For every score the DBMS MUST persist, queryable at read time:
- The aggregate score.
- The per-category subscores.
- The weights used.
- The evaluator (model version, prompt template, policy version, or human reviewer ID) responsible for each subscore.
- The supporting evidence references used in the computation.

Weights MUST be policy-configurable by schema, partition, source class, fact type, memory type, and workflow family.

### 3.4 Bitemporal Model

Every governed memory object MUST carry the following temporal fields:

- `event_time` — when the remembered event occurred, if known.
- `valid_time_start` / `valid_time_end` — the period in which the assertion applies to the represented world.
- `transaction_time_start` / `transaction_time_end` — when the DBMS recorded, accepted, revised, or retired this version.
- `source_time` — timestamp supplied by the original source.
- `verification_time` — when the system, policy, or human verifier accepted/rejected/revised the object.
- `stale_after` — time or condition after which the object MUST be reviewed before operational use.

Retrieval MUST expose **explicit query modes**: `current_valid`, `historical_valid`, `as_of_transaction_time`, and `bitemporal_audit`. The default for end-user queries is `current_valid`.

Corrections MUST NOT overwrite history. The **Temporal Supersession Engine** closes prior valid-time windows, creates supersession edges, preserves the prior transaction-time record, updates staleness, and notifies derived artifacts (embeddings, workflow summaries, active pools, skill packages) that they may need review or rebuild.

Implementation guidance: `tstzrange` columns + `EXCLUDE USING gist (... WITH &&)` for non-overlap, optionally layered with the `periods` extension for ergonomics. Native SQL:2011 system-versioned tables are not yet in PostgreSQL — do not depend on them.

### 3.5 Derivation Ledger

The DBMS MUST maintain a **Derivation Ledger** as a first-class auditable structure linking, in both directions:

- source package → claim
- claim → fact
- fact / claim → Episode Object
- Episode Object → workflow trace
- workflow traces → generalized workflow
- workflows + memories → procedural memory
- procedural memory → skill package
- any object → embedding, summary, model-generated artifact

Each ledger entry MUST record: the parser, model, prompt template, policy version, verifier or human action that produced or revised the derived object; input hashes; transaction time; resulting object identifiers; and re-derivation eligibility.

The ledger MUST support **replay**: re-deriving any descendant from its source evidence under a chosen model/template/policy version, while preserving the prior derivation as historical record.

### 3.6 Verbatim Source Archive

Where policy, law, and retention permit, the DBMS MUST preserve raw source artifacts (documents, transcripts, tickets, logs, API payloads, screenshots, attachments) in immutable, addressable, hash-verified form. Source packages MUST be re-ingestible: future extraction, summarization, embedding, or workflow-mining models can operate on the original evidence without losing traceability to earlier derivations.

Lifecycle states for source packages: `held` (under legal/retention hold), `active`, `archived`, `pruned` (only when policy permits).

Source references MUST be precise enough for humans and AI agents to inspect the original basis of a claim or derived object. The reference model MUST support document identifiers, timestamps, authorship, page numbers, message IDs, transcript offsets, byte or line offsets, API record IDs, and source-specific cursors where applicable.

### 3.7 Recursive Detail and Memory Detail Objects

Memory Detail Objects MUST be:

- Addressable and queryable independently of their parent.
- Recursively containable (a detail may contain or link to other details).
- Reusable across memories, workflows, skills, and subjects via relationship edges (the same "uploaded ISO to Proxmox" detail may appear in many parent memories).

Retrieval MUST support **progressive expansion**: callers may request the parent only, the first level of details, all details to a specified depth, only details related to a subject or exception, or only the evidence behind a specific step.

### 3.8 Workflow Extraction Engine

The Workflow Extraction Engine is a required governed subsystem (not an optional summarization step). It MUST:

1. Select project/subject/action class/time window/source types/security domain to analyze.
2. Group events into candidate cases.
3. Extract steps from tickets, logs, transcripts, commands, documents, and Episode Objects with source links preserved.
4. Normalize wording into common action classes, objects, actors, tools, outcomes.
5. Order steps using event time + source time + transaction time, preserving uncertainty.
6. Construct per-case workflow traces with actors, inputs, outputs, evidence, confidence, and exceptions.
7. Cluster similar traces by subject type, action class, outcome, environment, tool stack, and exception pattern.
8. Propose **candidate** generalized workflows with provenance and review status. Candidates MUST NOT overwrite or auto-promote existing workflows or procedural memories.
9. Preserve **both positive and negative evidence** (failed/partial traces are first-class outputs).
10. Separate temporal sequence from causal assertion. A `caused_by` edge requires evidence beyond mere ordering.

### 3.9 Skill Runtime

Skill Packages MUST execute as governed state machines, not as free-form prompts. The runtime MUST:

- Bind the current account (human, agent, application, MCP server), active memory pool, task objective, authorized partitions, and source context.
- Enforce skill **applicability conditions** (project, environment, technology stack, time window, governing policy).
- Check **preconditions**, load only authorized memories and workflows, execute or present steps, evaluate validation checks, branch on known exceptions, and emit new claims/traces/procedural-memory updates.
- Produce an **auditable execution record** for every run, usable for conformance, refinement, staleness review, and incident investigation.

Packaging is allowed in multiple formats (system prompts, Markdown procedures, MCP tool definitions, application plugins) but the runtime contract is uniform.

### 3.10 Model Runtime, Cloud Providers, and Session Context

The DBMS MUST provide an early model runtime extension surface so MaluDB can run local and cloud model sessions before the full memory object model, retrieval planner, active pools, and skill runtime are complete.

The initial implementation SHOULD compile and package `llama.cpp` / `libllama` as the first reference local runtime unless dependency review selects an equivalent local backend. The PostgreSQL extension build itself MUST remain PGXS-based; model runtime support MAY be built and packaged as a companion MaluDB service binary plus SQL extension surface. Running inference inside ordinary PostgreSQL backend processes is NOT the default design and requires an explicit physical-design exception covering memory contexts, threading, GPU/accelerator ownership, cancellation, crash isolation, and resource governance.

The model runtime MUST:

- Expose SQL-visible catalog objects for model providers, local model definitions, cloud model definitions, runtime capabilities, prompt templates, prompt versions, user sessions, Session Context blocks, rendered prompt hashes, runtime requests, and runtime responses.
- Allow a user, application, or agent to start a governed model session bound to an account, role set, optional partition, model provider, model alias, prompt template, and context policy.
- Query prompt templates and approved context fragments from PostgreSQL, render them into a model prompt under a deterministic template version, and submit the prompt to the model gateway.
- Maintain **Session Context** state in PostgreSQL, including owner, model provider, model version, prompt template version, context window policy, token budget, accumulated context block hashes, request/response hashes, timestamps, and lifecycle state.
- Support an initial context path that pushes explicit database context directly into the prompt without requiring Stage 2+ memory objects.
- Keep future context-loading hooks for authorized memories, workflows, skills, active memory pools, and MC2DB resources, but leave those hooks inactive until their stages exist.
- Record every model execution with model identity, prompt template identity, rendered prompt hash, context block hashes, output hash, policy version, account identity, and transaction time.
- Enforce result-size limits, statement/request timeouts, model availability checks, and cancellation semantics.
- Never require model weights to be stored in PostgreSQL; model files MAY be registered by path, hash, license metadata, quantization, and deployment location.
- Support cloud model providers through the same session, prompt rendering, request, response, audit, and policy tables used for local models. Cloud provider secrets MUST NOT be exposed to SQL callers and MUST be resolved only by the governed model gateway.
- Normalize local and cloud responses into the same response records, including provider, model identity, status, token counts where available, latency, output hash, error class, and policy outcome.

The first session API SHOULD support operations equivalent to:

- Register or update a versioned prompt template.
- Register a local or cloud model alias and runtime endpoint, local service identity, or provider adapter.
- Start a session for an account, provider, and model alias.
- Append or replace a context block sourced from PostgreSQL.
- Render the prompt from template plus current context.
- Submit the rendered prompt to the model gateway.
- Store and retrieve the response under audit.

### 3.11 MC2DB: Model Context to Database

The DBMS MUST support **MC2DB** as an early Release 1.0 database listener extension surface. MC2DB exposes governed database capabilities directly to LLMs and AI agents without requiring a separate handwritten MCP server for each database tool.

MC2DB MUST:

- Expose a configurable MCP-compatible HTTPS listener, defaulting to `https://localhost:5329` for local development.
- Listen on a network port and accept input shaped like an MCP server, including initialization/lifecycle messages, capability negotiation, tool/resource/prompt discovery, and tool calls.
- Expose MCP-compatible tools, resources, and prompts from PostgreSQL catalog metadata.
- Support named logical MC2DB server profiles backed by database catalog entries rather than separate handwritten server processes.
- Allow SQL, PL/pgSQL, and C-backed PostgreSQL functions to be registered as model-callable tools.
- Provide package-like PL/pgSQL APIs in the `mc2db` schema, including `mc2db.put_object(jsonb)`, for stored procedures to push MCP-shaped JSON into the active MC2DB response context.
- Validate tool input and output schemas before returning results to a model.
- Filter tool discovery by authenticated account, delegated agent chain, active memory pool, partitions, semantic privileges, and tool policy.
- Execute registered database tools through PostgreSQL transactions with pinned `search_path`, statement timeouts, role/account context, RLS, and memory-specific authorization.
- Record tool invocation metadata, argument hashes, result hashes, tool definition version, function signature, policy version, account identity, and transaction time.
- In R1.0, expose core database/Session Context tools such as health, catalog inspection, prompt listing, provider/model listing, session creation/lookup, context append/read, prompt rendering, model request submission, and response lookup. Later stages add memory, workflow, skill, and retrieval tools.
- Route durable outputs through the same audit rules as other R1.0 model/session artifacts; after the memory object model exists, outputs that become durable evidence MUST use Source Package, Claim, Derivation Ledger, and promotion rules.
- Distinguish protocol errors from tool execution errors so LLM clients can self-correct when safe.

The default R1.0 implementation SHOULD be a generic MaluDB-managed listener backed by PostgreSQL, not a separate MCP server per tool. `mc2db.put_object` and related package-like APIs write to the active MC2DB request context; they MUST NOT open arbitrary network sockets from PL/pgSQL. A PostgreSQL background-worker listener MAY be explored later, but backend processes MUST NOT execute arbitrary external tools. Model inference follows the model runtime requirements in §3.10.

### 3.12 Active Memory Pools and Local Memory Nodes

**Active Memory Pools** MUST:
- Be created from a prompt, API call, MCP request, or structured query.
- Materialize a scoped working set (memories, facts, workflows, skills, source references, pending claims) bounded by authorization, partitions, confidence thresholds, and validity windows.
- Support concurrent reads and writes by humans and AI agents, with every write attributed to an account.
- Preserve provenance, source pointers, confidence, precision, staleness, and access labels — they are not opaque caches.
- Support a promotion path: active observations → pending claims → verified facts → Episode Objects / workflow traces / procedural-memory updates / skill refinements.
- Expose real-time channels (HTTP API, WebSocket, or direct TCP) under the same identity, partition, and provenance rules as durable storage.

**Local Memory Nodes** MUST:
- Hold selected memories, pending claims, source snippets, task context, and synchronization metadata.
- Operate offline and synchronize back to the Enterprise Memory Core under governance — submitting new claims, Episode Objects, source packages, conflict records, deletions/tombstones, workflow updates, and promotion candidates.
- Never act as authoritative sources of record on their own.

### 3.13 Episode Replay Semantics

Replay MUST reconstruct an authorized, time-aware view of an Episode Object from durable evidence and derivation records. A replay must be able to answer:

1. What happened according to the current accepted view?
2. What evidence supports that view?
3. What did the DBMS believe at a prior transaction time?
4. What later sources or memories changed the interpretation?

Replay output MUST identify which source packages were inspected, which derived objects were included or hidden by policy, which temporal mode was used, and whether the replay is `historical`, `current_valid`, `as_of_transaction_time`, or `full_bitemporal`.

### 3.14 Lifecycle, Salience, and Consolidation

The DBMS MUST treat lifecycle management as governed data behavior, not merely retrieval ranking. Memories, facts, Episode Objects, workflow traces, procedural memories, skills, and derived artifacts MUST support explicit lifecycle transitions for staleness, supersession, contradiction, consolidation, decay, archival movement, retirement, legal hold, and pruning.

Salience and reinforcement MUST be tracked separately from confidence, precision, and temporal validity. A highly reinforced memory may still be stale or unauthorized; a low-salience memory may remain historically true and evidence-critical. Retrieval, active-pool loading, workflow extraction, and skill execution MUST account for salience without allowing it to bypass authorization, validity, confidence, precision, provenance, or retention policy.

Consolidation MUST preserve links to the source memories, facts, claims, source packages, workflow traces, and derivation ledger entries that supported the consolidated object. Pruning is permitted only through policy-controlled workflows that preserve required audit, legal-hold, provenance, and tombstone records.

### 3.15 Ingestion and Source Connectors

The DBMS MUST support both retrospective ingest of legacy artifacts and continuous ingest from active systems. Required source classes include documents, conversations, tickets, logs, database records, API payloads, source-control events, observability events, and time-series or event streams.

Ingestion connectors MUST produce Source Packages and candidate Claims, not unreviewed Facts or Memories. Each ingest result MUST carry source identity, source time, capture time, actor or system identity when known, content hash, retention class, security labels, partition membership, and source-specific resume/checkpoint metadata. Deterministic parsers, schema-driven extractors, and model-assisted extraction MAY all be used, but every derived output MUST have Derivation Ledger coverage and source references precise enough for replay.

---

## 4. Retrieval Requirements

### 4.1 Search Path Planning

The DBMS MUST treat an incoming query as a request to **build a retrieval plan**, not as text to send directly to a vector index.

The planner MUST construct a **retrieval envelope** containing: authenticated account, roles, active memory pool, application context, agent delegation chain, allowed partitions, current task, query text, and structured fields supplied by the caller.

The planner MUST extract candidate retrieval cues — subject, verb/action class, object type, topic, time range, relationship hints, desired answer shape, evidence requirement, confidence threshold, precision requirement, recursive detail depth — and classify the likely intent. Initial path selection rules:

| Intent | Initial Path |
|---|---|
| Specific recall | subject + verb + temporal + catalog → graph/vector expansion |
| "Why" / "how do we know" | derivation ledger + evidence + supporting/contradicting edges |
| "How do we perform this task" | workflows → generalized workflows → procedural memory → skills + recursive detail |
| Date-sensitive | temporal indexes + bitemporal validity |
| Dependency/cause/relationship | graph traversal |
| Broad exploratory | scoped semantic search inside authorized partitions |

The plan MAY adapt: gather candidates from cheapest/most-precise indexes, then expand into graph, recursive detail, vector, source inspection, or workflow lookup as needed. Authorization, validity, confidence, precision, and provenance MUST be checked before result assembly.

### 4.2 Query Hints

The DBMS MUST accept an optional structured **query hint** package (intent, preferred_paths, subject, object_type, time_mode, detail_depth, evidence shape, minimum_confidence, partitions). Hints guide planning. Hints MUST NOT override security, access control, validity rules, provenance requirements, or DBMS safeguards. The system is free to ignore or downgrade a hint when it conflicts with policy or inferred intent.

### 4.3 Hybrid Recall

The retrieval engine MUST coordinate across:

- Relational/catalog filters (entity IDs, source IDs, fact IDs, workflow IDs, status, confidence/precision thresholds, partition membership, model version).
- Full-text search (`tsvector`/`tsquery` + GIN; `pg_trgm` for fuzzy match).
- Graph traversal over typed relationship edges.
- Temporal indexes (event_time, valid_time, transaction_time, verification_time, stale_after).
- Vector similarity search (pgvector, HNSW or IVFFlat) **scoped by subject, verb, predicate, object, project, or time partition** — global vector search is the fallback, not the default.
- Recursive detail expansion.

Result packages — not just ranked text — MUST include the underlying objects, source references, workflow steps, recursive depth used, confidence/precision/validity, permissions consulted, and links to evidence.

### 4.4 Pre-loaded / Cached Search Contexts

The DBMS MUST support pre-loaded subject-, topic-, or task-scoped buffer pools to bring high-value context close to active humans and agents. Pre-load operations use the same governed retrieval model as ordinary search and preserve all metadata; they are caches, not ungoverned shortcuts.

### 4.5 Authorization-aware Retrieval

Authorization MUST be evaluated:

1. During retrieval **planning** (path selection, partition restriction).
2. During **candidate expansion** (vector, graph, FTS each filter pre-rank).
3. During **result assembly** (final policy check, evidence redaction where required).

The system MUST NOT leak unauthorized information through vector similarity, graph traversal, summaries, relationship expansion, or active pool loading.

---

## 5. Security and Governance

### 5.1 Accounts

Every actor MUST have an account:

- Human users
- Applications
- Service accounts
- AI agents (with delegation chains)
- MCP servers
- MC2DB clients and delegated model sessions
- Local memory nodes
- Administrative processes

Authentication MUST support: password, certificate, SCRAM, SSO/OIDC, API keys bound to a single account, and short-lived tokens for agent delegation.

### 5.2 Privileges

Privileges MUST apply to memory-specific objects and **semantic slices**, not only to tables and collections. Grantable scopes include:

- Subject (e.g., `Server X`, `Project Y`)
- Verb / action class (e.g., `decided`, `installed`)
- Topic (e.g., `authentication in PHP systems`)
- Project / Partition
- Source type (e.g., `email`, `ticket`)
- Workflow / generalized workflow / skill
- Active memory pool
- Relationship type
- MC2DB server profile / database-native tool

Built-in roles MUST include at least baseline patterns analogous to `CONNECT`, `RESOURCE`, `DBA`, plus memory-specific roles for `MEMORY_READ`, `MEMORY_WRITE`, `EVIDENCE_INSPECT`, `WORKFLOW_PROMOTE`, `SKILL_EXECUTE`, `MODEL_REGISTRY_ADMIN`, `AUDIT_VIEW`. Custom roles MUST be supported.

### 5.3 Audit and Observability

The DBMS MUST record: who accessed/changed/verified/promoted/synchronized/exported/deleted/derived governed objects; ingestion jobs; model executions and their prompt/template/policy versions; MC2DB tool discovery and invocation events; external MCP broker calls; index rebuilds; archive recalls; synchronization events; recovery operations; quality and performance metrics; and traces.

Recommended baseline: `pgaudit` + `pg_stat_statements` + logical decoding to an append-only sink for compliance-grade trails.

### 5.4 Backup and Recovery

Backup MUST prioritize **durable assets that cannot be cheaply regenerated**:

- Verbatim source packages
- Catalog metadata
- Access-control state
- Human verification decisions
- Derivation ledger
- Transaction logs / WAL
- Memory objects, facts, claims, governance records

**Derived artifacts** (embeddings, vector indexes, summaries, routing structures) MAY be excluded from full backups if they can be rebuilt from source data and metadata. Tested rebuild ordering, restore validation, and audit records of the models/templates/source snapshots used during recovery are required.

### 5.5 Privacy, Retention, Legal Hold

The DBMS MUST support: retention policies per partition / source class / object type; legal holds that prevent pruning regardless of policy; per-subject erasure workflows that respect immutable evidentiary requirements (e.g., redaction with audit, not silent deletion).

---

## 6. Architectural Subsystems

| Subsystem | Responsibility |
|---|---|
| **Enterprise Memory Core** | Durable system of record for all governed objects, catalog, audit, model registry. |
| **Local Memory Node** | Offline/edge subset; synchronizes under governance. |
| **Active Memory Pool Manager** | Scoped working-memory lifecycle; real-time channels; promotion path. |
| **Temporal Supersession Engine** | Bitemporal window management, supersession, contradiction, staleness propagation, downstream invalidation. |
| **Security-Aware Retrieval Coordinator** | Builds retrieval envelopes, plans search paths, enforces authorization at planning/expansion/assembly. |
| **Transaction & WAL Manager** | Multi-model transaction boundary across object metadata, source links, graph edges, temporal windows, FTS, vector indexes, workflow records, audit logs. R1.0 and later stages leverage PostgreSQL's WAL/MVCC; partial commits are forbidden. |
| **Source Ingestion Service** | Converts external artifacts, active streams, and connector checkpoints into Source Packages and candidate Claims with retention, security, source-reference, and ledger metadata. |
| **Lifecycle and Salience Manager** | Applies staleness, reinforcement, decay, consolidation, archive, retention, legal-hold, pruning, and downstream invalidation policy. |
| **Workflow Extraction Engine** | Process-mining over Episode Objects; produces candidate traces and generalized workflows for review. |
| **Skill Runtime** | Governed state-machine execution of skill packages with audit records. |
| **Model Session Runtime** | DB-managed model execution surface that reads prompt templates and Session Context from PostgreSQL, maintains user/model session state, and invokes local `llama.cpp` or approved cloud providers through one governed gateway. |
| **MC2DB Listener** | Database-native MCP-compatible network listener generated from PostgreSQL catalog metadata and stored procedures; exposes governed database tools/resources/prompts to LLMs. |
| **Model Registry** | Embedding/extraction/reranker/summarizer model identity, version, dimensions, embedding space, prompt-template policy, evaluation status, rollout state, derived-artifact map. Supports blue-green indexes, dual-space query routing, adapter alignment, staged background re-embedding. |
| **System Catalog** | Central metadata: users, roles, privileges, schemas, partitions, object types, relationship types, retention policies, source types, model versions, index definitions, active pools, local nodes, archive tiers, rebuild state, operational statistics. Readable through SQL and governed APIs. |
| **Derivation Ledger Service** | Lineage, replay, audit. |
| **Verbatim Source Archive Service** | Immutable hash-verified storage with tiered hot/warm/cold/archived placement. |
| **Driver / API Surface** | C, Python, Node.js, PHP drivers; SQL interface; prompt-plus retrieval API; MCP integration. |

### 6.1 Process Architecture

MaluDB R1.0 and the later roadmap MUST use PostgreSQL as the authoritative transaction, storage, and query-execution boundary. Relational data, temporal records, relationship edges, full-text indexes, vector columns, pgvector indexes, catalog state, audit records, and derivation metadata live in PostgreSQL and participate in PostgreSQL WAL/MVCC semantics.

The default deployment MUST NOT split SQL storage and vector search into separate databases. Vector search is database work: pgvector runs inside PostgreSQL backend processes and is planned/executed through PostgreSQL queries, indexes, partitions, and access-control checks. Embedding generation is model work: embedding models run in governed worker processes or approved external model services and write vectors back to PostgreSQL through audited transactions.

Default process roles:

| Process / Service | Default placement | Responsibility |
|---|---|---|
| PostgreSQL server | Integrated MaluDB-managed PostgreSQL cluster | SQL engine, transactions, WAL/MVCC, storage, catalog, FTS, temporal indexes, relationship tables, pgvector storage/search, audit tables. |
| MaluDB C extension | Loaded into PostgreSQL backend processes | Server-side functions, type support, validation, catalog helpers, transaction-safe write APIs, optional background-worker hooks. |
| PostgreSQL background workers | PostgreSQL process space when required | Internal maintenance that benefits from database locality, such as invalidation queues, rebuild scheduling, lightweight asynchronous jobs, and cache coordination. |
| Embedding workers | Separate governed MaluDB service processes | Generate embeddings from source excerpts, memory chunks, workflow traces, summaries, and query packages using model-registry policy; write results and ledger entries back to PostgreSQL. |
| Model gateway (`maludb_modeld`, with local `maludb_llmd` worker where needed) | Separate governed MaluDB service process plus SQL extension surface | Runs local chat/completion sessions through `llama.cpp` or an approved equivalent runtime and cloud model sessions through provider adapters; pulls prompt templates and Session Context from PostgreSQL; writes requests/responses and audit metadata back through PostgreSQL; does not become a durable system of record. |
| Source ingestion workers | Separate governed MaluDB service processes | Read external systems and streams, preserve source packages, emit candidate claims, maintain connector checkpoints, and write only through PostgreSQL-backed audited transactions. |
| Extraction / summarization / workflow-mining workers | Separate governed MaluDB service processes | Produce claims, facts, summaries, workflow traces, candidate generalized workflows, and derived artifacts for review; preserve source links and derivation records. |
| Retrieval API / MC2DB listener | R1.0 governed MaluDB listener extension/service backed by PostgreSQL | Expose prompt/Session Context access and MCP-compatible database-native tools/resources/prompts at a configured HTTPS listener address such as `https://localhost:5329`, while delegating durable reads/writes and policy checks to PostgreSQL-backed MaluDB functions. |
| Active Memory Pool manager | Separate governed MaluDB service process backed by PostgreSQL | Manage low-latency task context, WebSocket or equivalent real-time channels, concurrent human/agent access, and promotion paths. |
| Skill Runtime | Separate governed MaluDB service process by default | Execute skill state machines, especially when actions may call external tools or applications; persist execution records and derived observations through PostgreSQL transactions. |
| Local Memory Node sync service | Separate governed MaluDB service process | Synchronize offline/edge subsets back to the Enterprise Memory Core with conflict records, tombstones, source packages, claims, and promotion candidates. |
| Verbatim archive service | Separate governed service or storage adapter with PostgreSQL catalog authority | Store immutable source blobs and tiered archive objects; PostgreSQL stores authoritative metadata, hashes, retention state, and access policy. |

External MaluDB services MUST NOT become independent systems of record. They MAY perform model execution, long-running extraction, real-time coordination, synchronization, archive placement, and effectful skill execution, but durable state changes MUST flow through PostgreSQL transactions and, for derived objects, Derivation Ledger entries. Any operation that cannot be made atomic with the relevant PostgreSQL state MUST document the failure mode, reconciliation behavior, and audit trail.

### 6.2 Physical Implementation Requirements

The physical implementation MUST stay aligned with the staged roadmap. Stage 1 implementation artifacts MUST establish the PostgreSQL extension, build, packaging, CI, and pgvector substrate only. Stage 1.5 may add the model runtime extension surface, Session Context catalog, local/cloud provider adapters, and service packaging without installing Stage 2+ governed memory objects. Stage 1.6 may add the MC2DB network listener extension surface and R1.0 database tools without installing Stage 2+ governed memory objects. Design DDL or design notes for Stage 2+ objects MAY live under `docs/design/`, but they MUST NOT be installed by the Stage 1 extension SQL scripts.

The PostgreSQL extension MUST use PGXS and versioned extension artifacts: `maludb_core.control`, `maludb_core--X.Y.Z.sql`, `maludb_core--X.Y.Z--X.Y.Z.sql` upgrade scripts, and a C module built from `src/`. The extension MUST install into the extension-owned `maludb_core` schema, be non-relocatable by default, and expose stable SQL functions/views rather than requiring tenants to write directly to private base tables.

Required PostgreSQL extensions and packages MUST be declared, installed, and validated by the packaging or bootstrap path. When an extension object depends on another PostgreSQL extension such as `vector`, `btree_gist`, `pg_trgm`, `pgaudit`, or `pg_partman`, MaluDB MUST either declare the dependency in extension/package metadata or fail during installation with an actionable diagnostic. The default installer MUST validate `PG_CONFIG`, server major version, cluster encoding/collation, required extension availability, and the ability to run `CREATE EXTENSION maludb_core`.

Stage 1 database objects are limited to catalog scaffolding, extension metadata, and demonstration objects needed to prove vector storage/search through the MaluDB-owned schema. Memory-specific objects such as sources, claims, facts, Episode Objects, memories, Memory Detail Objects, bitemporal windows, derivation ledger tables, SVPOR routing tables, retrieval planner tables, active pools, local nodes, workflows, procedural memories, and skills MUST wait for their assigned stages.

C backend code MUST use PostgreSQL memory, error, transaction, and version-compatibility APIs. Backend code MUST NOT use mutable process-lifetime global state for tenant, account, session, or request data; `malloc`/`free`; external network calls; model inference; arbitrary tool execution; or non-PostgreSQL threading primitives inside PostgreSQL backend processes unless an explicit design document justifies the boundary and failure mode. Compiling and packaging model runtimes or MC2DB as part of MaluDB means governed companion services plus SQL/session/listener extension surfaces by default, not unbounded inference or arbitrary socket handling inside ordinary PostgreSQL backend processes. Shared memory and background-worker setup MUST follow PostgreSQL preload hook requirements.

Every schema-bearing change after the initial extension version MUST be delivered as a versioned extension upgrade script with regression coverage. Test fixtures MUST verify extension load/unload, dependency validation, catalog visibility, vector insert/query behavior, and that Stage N install scripts do not create Stage N+1 governed objects.

---

## 7. Non-Functional Requirements

### 7.1 Performance Targets (initial; refine after benchmarking)

- Single-subject scoped semantic search over a partition with 10⁷ memories: p95 < 200 ms with HNSW.
- Active memory pool load (subject-scoped, depth-1 expansion, ≤ 5,000 objects): p95 < 1 s.
- Episode replay (current_valid, no full audit): p95 < 500 ms.
- Workflow Extraction Engine MAY run asynchronously; SLAs are batch-oriented.

### 7.2 Scalability

The system MUST partition by subject, project, security domain, time range, workflow, source domain, retention policy, and active pool. Cross-partition queries MUST be explicit about authorization and result assembly.

The architecture MUST not preclude future horizontal distribution. Active-active replication is out of scope for R1.0, but partitioning, the catalog, and the WAL/transaction model MUST remain compatible with a future distributed deployment.

### 7.3 Reliability

- ACID guarantees inside the Enterprise Memory Core: full PostgreSQL semantics.
- Multi-model writes (object + source links + graph edges + temporal windows + FTS + vectors + audit) MUST be atomic. Partial writes MUST be impossible.
- Critical promotion and supersession operations MUST run at stronger isolation than low-risk maintenance.

### 7.4 Embedding Lifecycle

- Multi-view embedding policies MUST be configurable. Embedding budgets, lazy/deferred embedding, compact routing vectors, partition-specific embedding scopes, and rebuild prioritization are required.
- High-value active partitions MAY receive richer embeddings; cold historical partitions MAY rely on fewer embeddings until queried, restored, or selected for reprocessing.
- Embedding model migrations MUST avoid long downtime: blue-green indexes, dual-space query routing during transition, adapter-based alignment between embedding spaces, or staged background re-embedding are all acceptable.

### 7.5 Operability

- All subsystems MUST emit structured logs and metrics (Prometheus-compatible).
- The system catalog MUST expose statistics about predefined slices (subjects, verbs, topics, projects, security domains, active pools, time partitions).
- Health, readiness, and liveness endpoints MUST be exposed for each long-running service.

---

## 8. Technology Stack and Dependencies

| Layer | Choice | License | Notes |
|---|---|---|---|
| Database core | **PostgreSQL 17** (PGDG) | PostgreSQL License | Installed/configured by the default MaluDB bundle. PG 16 compatibility required; PG 18 compatibility tracked and added to CI when dependencies validate. No PostgreSQL fork in R1.0. |
| Vector | **pgvector** ≥ 0.8 | MIT | HNSW + IVFFlat, halfvec. Default vector engine; runs inside PostgreSQL, not as a separate vector database process. |
| Graph | **Apache AGE** ≥ 1.5 (Cypher) | Apache 2.0 | Used only where Cypher is needed and the target PG major is supported; recursive CTEs are preferred for moderate graphs and as the fallback. |
| Temporal | Native `tstzrange` + GIST exclusion; optionally `periods` extension | PostgreSQL / MIT | `temporal_tables` is unmaintained — do not use. |
| Partitioning | Native declarative partitioning + `pg_partman` | PostgreSQL | Avoids TimescaleDB TSL license. |
| FTS | Native `tsvector` + GIN; `pg_trgm` for fuzzy | PostgreSQL | `pg_search` (ParadeDB, AGPL) considered later if BM25 ranking required. |
| JSON | `JSONB` + `pg_jsonschema` | PostgreSQL / Apache 2.0 | For validated documents. |
| Audit | `pgaudit` + `pg_stat_statements` + WAL streaming | PostgreSQL | Logical decoding to immutable sink for compliance. |
| ML/embedding | Governed MaluDB worker services + pgvector storage; `pg_vectorize` for managed refresh | PostgreSQL | Embedding/model execution runs outside PostgreSQL by default and writes audited results back through SQL. `PostgresML` only if in-DB inference is a hard requirement. |
| Replication | Native logical replication; `pglogical` for selective use | PostgreSQL | Citus deferred (AGPL). |
| Build | **PGXS** Makefile; `pg_buildext` / `dh_make_pgxs` for `.deb` | — | Meson-for-extensions is experimental — not adopted in R1.0. |
| CI | GitHub Actions matrix on `ubuntu-24.04`, PG 16/17/18 | — | PG 17 is blocking for Stage 1; PG 16 compatibility is blocking once supported artifacts exist; PG 18 may be allowed to start as non-blocking until dependency packages validate. ASan/UBSan job; `clang-tidy` and `scan-build` jobs. |

**Avoid:**
- `pg_embedding` (Neon) — archived.
- `temporal_tables` — unmaintained.
- `ZomboDB` — heavy operational cost unless Elasticsearch is already deployed.
- TimescaleDB **TSL features** — license incompatibility for our redistribution model. Apache-2.0 core only is acceptable; using TSL features is not.

**License watchlist:** TimescaleDB TSL, Citus AGPL, ParadeDB AGPL.

**License contamination:** Linking GPL code into our `.so` is prohibited unless the entire derived work can be released under PostgreSQL License terms. LGPL is acceptable when dynamically linked with notices preserved.

### 8.1 V3 dependency candidates

The following dependencies are evaluated for V3 (§1.5, §9 Stages 8–15). Each MUST pass license, operational, and packaging review before adoption. If a candidate fails review, V3 MUST ship a MaluDB-native equivalent that satisfies the same normative requirements.

| Candidate | Used for | License | V3 decision gate |
|---|---|---|---|
| `pg_cron` | V3-CRON-01 scheduler | PostgreSQL | Adopt if packaging on PG 16/17/18 and PGDG availability are acceptable; otherwise MaluDB-native schedule table + worker. |
| `pgmq` | V3-QUEUE-01 durable job queue | PostgreSQL | Adopt if packaging and RLS integration are acceptable; otherwise MaluDB-native queue table with visibility leases. |
| PostgREST | V3-API-01 curated REST gateway | MIT | Adopt only if endpoint catalog can be expressed as functions/views without exposing private `malu$` tables; otherwise ship a small custom Go/Rust/Node gateway. |
| `pg_graphql` | GraphQL surface | Apache 2.0 | Deferred from V3 unless a customer requires it; optional plugin later. |
| `pgsodium` / Vault-style | V3-SECRET-01 secret store | PostgreSQL / mixed | Adopt only if license and key-management model fit MaluDB redistribution; otherwise file-backed development resolver + pluggable production resolver. |
| PgBouncer | V3-API-01 / V3-OBS-01 connection pooling profile | ISC | Document and package a pooling profile; not linked into the extension. |
| MinIO / S3-compatible client | V3-STOR-01 source archive S3 adapter | Apache 2.0 / mixed | Use AWS SDK or `s3cmd`/`mc` only as an external dependency of the archive service; never linked into the extension `.so`. |
| OTLP HTTP client | V3-LOG-01 log drains | Apache 2.0 | Adopt the OpenTelemetry HTTP exporter for the log-drain service; no GPL-only telemetry libs in the extension. |

No GPL-only or AGPL dependency may be linked into the extension `.so` or required by the default redistributed product. A V3 dependency that pulls a GPL transitive runtime MUST be packaged as a separately-installable service, not as a default install dependency.

---

## 9. Phased Implementation Plan

The roadmap is intentionally narrow at the start. Each stage delivers something usable and testable before scope expands. **Do not implement Stage N+1 features inside Stage N** even when the requirements above call for them — early stages establish the substrate; later stages layer the memory semantics on top.

For Release 1.0, Stage 1 is hardened into three implementation phases: Stage 1 core PostgreSQL substrate, Stage 1.5 model runtime and Session Context, and Stage 1.6 MC2DB network listener. Together these constitute the first field-testable release.

### Stage 1 — Memory Core framework (PostgreSQL + pgvector relational foundation)

**Goal:** a working database that can store relational data with vector columns, plus the dev/build/test/packaging substrate that all later stages will use. No memory-specific object model yet.

In scope:
- PG 17 dev environment on Ubuntu 24.04 with PGDG.
- pgvector installed and verified end-to-end (HNSW + IVFFlat indexes, distance operators).
- A `maludb_core` extension skeleton built with PGXS, installable as a `.deb` via `pg_buildext`.
- Default MaluDB installation packaging that installs and configures PostgreSQL 17 from PGDG, pgvector, required PostgreSQL extension packages, and `maludb_core` together on a fresh Ubuntu 24.04 host.
- Bootstrap logic that initializes or selects the managed PostgreSQL cluster, validates `PG_CONFIG`, installs required extensions, runs `CREATE EXTENSION maludb_core`, and verifies vector search through the MaluDB-owned schema.
- A baseline relational schema for the catalog scaffolding the rest of the system will rely on (accounts, partitions, object-type registry, source-type registry, relationship-type registry, model registry stubs). Tables only — no business logic, no MAUT scoring, no bitemporal columns yet.
- A simple "memory record" demonstration table with at least one `vector` column to prove pgvector is wired up correctly through the extension's install path.
- `pg_regress` harness with smoke tests covering: extension load, table creation, vector insert/query, basic catalog reads.
- ASan/UBSan debug build target.
- `clang-tidy` and `scan-build` jobs.
- GitHub Actions matrix on `ubuntu-24.04` × PG 16/17, with PG 18 added as a compatibility target once required dependency packages validate.
- Stage-boundary tests proving Stage 1 does not install Stage 2+ memory objects.
- License declaration (PostgreSQL License), DCO, repository conventions, CLAUDE.md, requirements.md.

Explicitly NOT in Stage 1:
- Model runtime/session APIs and Session Context (Stage 1.5).
- MC2DB network listener and database-native MCP tools (Stage 1.6).
- Sources, claims, facts, Episode Objects, memories, Memory Detail Objects (Stage 2).
- Verbatim source archive (Stage 2).
- Bitemporal columns and the Temporal Supersession Engine (Stage 3).
- SVPOR organization layer (Stage 3).
- Derivation Ledger (Stage 2/3).
- Confidence/precision MAUT scoring (Stage 3).
- Retrieval planner / query hints / hybrid recall (Stage 4).
- Active Memory Pools, Local Memory Nodes, Skill Runtime, Workflow Extraction Engine (Stages 4–5).

Stage 1 done when: a fresh Ubuntu 24.04 box can install MaluDB through the default package/bundle path, which installs and configures PostgreSQL 17 + pgvector + `maludb_core`; run `CREATE EXTENSION maludb_core`; insert and similarity-search a vector through a `maludb_core`-owned table; prove no Stage 2+ governed memory objects are installed; and pass the regression suite under both default and ASan builds. The developer path MUST still support explicit `PG_CONFIG` builds across PG 16 and PG 17, with PG 18 added as a compatibility target once dependency packages validate.

### Stage 1.5 — Model runtime extension and Session Context

**Goal:** compile/package the first model runtime path and prove that MaluDB can start a governed user session, read a prompt template and Session Context directly from PostgreSQL, render the prompt, invoke a local or cloud model through one gateway, and store the response metadata. This stage still does not install Stage 2+ memory objects.

- `llama.cpp` / `libllama` reference runtime package, or an equivalent local runtime approved through dependency and license review.
- Model provider registry rows for local and cloud providers, model aliases, runtime capabilities, context limits, quantization or provider metadata, model-file path/hash metadata where applicable, and deployment location.
- Prompt template catalog with versioning, arguments, context policies, and rendered prompt hashing.
- User/model session tables with account binding, lifecycle state, context-window policy, token budget, context block references, request/response metadata, and audit hooks.
- SQL APIs for registering prompts/models, starting sessions, appending explicit context blocks, rendering prompts from database state, submitting requests, and retrieving responses.
- Runtime request/response queue or service contract for `maludb_modeld` and local `maludb_llmd` workers where needed, with cancellation, timeout, result-size, provider-secret, and model-availability behavior.
- Regression tests for prompt template versioning, session creation, context rendering, request recording, response recording, and proof that no Stage 2+ governed memory objects are installed.

Stage 1.5 done when: the default MaluDB install can build or install the model gateway and local runtime package, register local and cloud model aliases, create a prompt template, start a session for a database account, push explicit Session Context into the rendered prompt, invoke or mock the model gateway through the governed service contract, store response/audit metadata, and pass regression tests without introducing memory-object tables.

### Stage 1.6 — MC2DB network listener extension

**Goal:** build the database-native listener immediately after the model runtime so local and cloud models can access governed database capabilities through MCP-compatible input. This stage still does not install Stage 2+ memory objects.

- MC2DB listener extension package and managed listener service, defaulting to `https://localhost:5329`.
- MCP-compatible lifecycle, initialization, capability negotiation, tool/list, tool/call, prompt/resource discovery shape, protocol errors, and tool errors.
- MC2DB catalog tables for R1.0 logical server profiles, listener configuration, database-native tools, prompts, resources, input/output schemas, risk class, required privileges, and rate limits.
- R1.0 database-native tools for health, catalog inspection, prompt listing, provider/model listing, session creation/lookup, Session Context append/read, prompt rendering, model request submission, and model response lookup.
- SQL/PL/pgSQL registration APIs such as `mc2db.create_server`, `mc2db.register_tool`, `mc2db.register_prompt`, and `mc2db.register_resource`.
- Package-like output APIs such as `mc2db.put_object`, `mc2db.put_text`, `mc2db.put_error`, and `mc2db.flush` for stored procedures to emit to the active listener context.
- Authentication, authorization filtering, pinned `search_path`, statement timeouts, request context binding, invocation audit, and schema validation.
- Regression and service tests proving listener startup, MCP-shaped initialization, authorized tool discovery, unauthorized filtering, stored-procedure invocation, `mc2db.put_object` response emission, and no Stage 2+ governed memory objects.

Stage 1.6 done when: a local or cloud model client can connect to the MC2DB listener at the configured address, complete the MCP-style initialization/discovery flow, call an authorized R1.0 database tool, update or read Session Context, submit a model request through the shared model gateway, receive an MCP-shaped result, and produce audit records.

### Stage 2 — Memory object model and verbatim storage

**Goal:** internal layout of memories, documents, and verbatim source storage. The substrate from Stage 1 gets the first memory-specific object types.

- Schema for source packages, claims, facts, Episode Objects, memories, Memory Detail Objects, relationship edges.
- Verbatim Source Archive: immutable hash-verified storage, tiered placement, retention/legal-hold metadata.
- Retrospective and continuous ingestion contracts for source packages, candidate claims, source references, connector checkpoints, and source-specific offsets.
- Document/JSON layout for memory payloads (`JSONB` + `pg_jsonschema`).
- Derivation Ledger schema + write API (without the MAUT scoring and supersession behavior — those land in Stage 3).
- C extension functions that enforce multi-model atomicity for object insertion.
- `pgaudit` + `pg_stat_statements` configured.

### Stage 3 — Bitemporal core, SVPOR, MAUT scoring

- Bitemporal columns (`event_time`, `valid_time_*`, `transaction_time_*`, `source_time`, `verification_time`, `stale_after`) using `tstzrange` + GIST exclusion.
- Temporal Supersession Engine: validity-window closure, supersession edges, staleness propagation, downstream invalidation hooks.
- SVPOR organization layer + routing indexes; SVPOR participation in embedding inputs.
- MAUT-based confidence and precision: per-category subscore tables, weights, evaluator metadata, aggregate computation functions.
- Lifecycle and salience policy: reinforcement events, decay, consolidation, archive movement, retention, legal-hold enforcement, pruning/tombstone records.

### Stage 4 — Retrieval, hybrid search, query hints

- Apache AGE for graph traversal (or recursive CTE fallback) integrated.
- Native FTS (`tsvector`) + `pg_trgm`.
- Retrieval planner: envelope, cue extraction, intent classification, search-path selection.
- Query-hint API.
- Authorization-aware retrieval at planning, expansion, and assembly.

### Stage 5 — Workflow Extraction, Skills, Active Memory Pools

- Initial Workflow Extraction Engine.
- Skill Runtime as a governed state machine.
- Active Memory Pool manager + WebSocket channel.
- Episode replay API.

### Stage 6 — Local Memory Nodes, model migration, advanced MC2DB, driver surface

- Local Node sync protocol + conflict records.
- Model Registry with blue-green index migration, dual-space query routing, adapter-based alignment, and advanced local model capability negotiation.
- Drivers/SDKs for C, Python, Node.js, PHP.
- Advanced MC2DB tools/resources/prompts for memory retrieval, workflow, skills, local-node sync, and governed memory writes.
- External MCP broker/reference implementation for non-database tools.

### Stage 7 — Hardening

- Performance benchmarking and tuning.
- Security review (`pgaudit`, RLS, semantic-slice grants).
- Documentation, examples, deployment guide, deb packaging finalized via `pg_buildext`.
- Public alpha.

### Stages 8–15 — Version 3 platform ergonomics

Stages 8 through 15 implement Version 3 (§1.5). Each stage corresponds to one or more `V3-*` tickets with their own per-ticket deliverables and migration assignments. Stage-boundary discipline still applies: a Stage N+1 ticket MUST NOT install objects assigned to Stage N+2 even if the requirement is named in §1.5.

Doctrine that V3 stages MUST preserve:

1. Corrections never silently overwrite history; the Temporal Supersession Engine owns the transition.
2. Every derived V3 artifact (REST response transcript, queued job result, embedded vector, retrieval envelope, secret rotation event) MUST carry the appropriate audit and, where applicable, Derivation Ledger coverage.
3. Authorization is checked at planning, candidate expansion, and result assembly for any retrieval path V3 touches.
4. Multi-model writes inside a V3 ticket MUST be atomic across the PostgreSQL state V3 introduces (token + audit, queue + audit, source object + catalog hash + Derivation Ledger, etc.).
5. V3 services MUST NOT become independent systems of record. Durable state changes flow through PostgreSQL.

#### Stage 8 — Documentation reconciliation

- **V3-DOC-01**: reconcile `docs/user-manual.md` with `maludb_core.control`, `README.md`, `CHANGELOG.md`, and the migration chain; correct stale ANN/HNSW claims so the current implementation is described as it actually behaves (single-layer NSW today); add a "Current Version" section enumerating extension version, release tag, supported PostgreSQL majors, shipped services, and shipped SDKs.
- **V3-DOC-02**: declare V3 vs V2 scope boundaries in writing; cross-reference `version3-requirements.md` and `version3-plan.md` from this document and from `docs/user-manual.md`; assert that no V3 requirement contradicts provenance, bitemporal discipline, three-stage authorization, or atomic multi-model writes.

Stage 8 done when a reader following only `docs/user-manual.md` and this document can discover every v2 alpha surface plus every V3 ticket without encountering a conflicting version or vector-search claim.

#### Stage 9 — Identity and secrets

- **V3-AUTH-01**: personal and service tokens with hash storage, creation/last-used/expiry/revocation timestamps, optional IP/CIDR allow lists, JWT verification using configured signing keys, mapping from token subject to `malu$account` / PostgreSQL role / current schema / active pool / delegated agent chain, and audit rows for creation, use, failed verification, and revocation. MC2DB and the V3 REST gateway MUST share the same token model. Revocation MUST take effect without service restart.
- **V3-SECRET-01**: governed secret resolver for model providers, HTTP tools, external brokers, storage adapters, log drains, and backup destinations. Secret values are encrypted at rest or held outside PostgreSQL behind a resolver. Decryption paths are `SECURITY DEFINER`, narrowly granted, reviewed, and covered by tests. Rotation, versioning, last-used metadata, and audit are mandatory. File-backed development resolver plus pluggable production resolver.

Stage 9 done when MC2DB, REST, the model gateway, the broker, and the log-drain service all authenticate through the same account/token model with identical RLS behavior, and when no provider/tool secret is reachable through ordinary SQL views.

#### Stage 10 — REST gateway, CLI, and SDK parity

- **V3-API-01**: curated REST endpoints for health, version, account context, source ingest, claim/fact registration, retrieval, replay, pools, skills, local node submissions, model sessions, prompts, tools, queues, and cron. OpenAPI generated from the stable endpoint catalog. Invocation audit reuses `malu$mc2db_invocation` or a sibling HTTP audit table. Same account binding and RLS gates as SQL and MC2DB. Structured SQLSTATE-mapped error codes. No generic CRUD over private `malu$` tables; no anonymous browser access to memory data.
- **V3-CLI-01**: first-party `maludb` CLI with subcommands at least for `status`, `install doctor`, `db upgrade|backup|restore-check`, `auth token create|list|revoke`, `secret set|get-metadata|rotate`, `model list|register|probe`, `prompt list|render`, `tool list|call|register`, `source put|get|verify`, `retrieve`, `replay`, `queue list|drain|retry`, `cron list|enable|disable|run-now`, and `metrics scrape`. Every command calls a stable SQL/HTTP API. Human and JSON output. Every state-changing command emits audit.
- **V3-SDK-01**: C/Python/Node.js/PHP SDK parity for pool, skill, and node wrappers if not already complete at v2 GA. Generated OpenAPI and JSON schemas drive typed clients. Typed token/auth configuration in all SDKs.

Stage 10 done when REST, CLI, and SDKs all authenticate against the V3 identity model, every Stage 10 endpoint has OpenAPI coverage, and the CLI replaces the equivalent single-purpose shell scripts.

#### Stage 11 — Durable queue and scheduler

- **V3-QUEUE-01**: one queue abstraction for ingestion, embedding, re-derivation, model work, broker-audit ingest, lifecycle sweeps, ANN rebuilds, and notification fanout. Visibility timeout, retry count, dead-letter state, idempotency key, priority, tenant/account ownership, and audit are mandatory. Worker leases are transactionally acquired and safely released. RLS or equivalent enforces account-isolated visibility. CLI and SQL surfaces expose queue depth, retry failures, and dead letters.
- **V3-CRON-01**: scheduled jobs for lifecycle sweeps, embedding refresh, ANN rebuilds, backup checks, capability probes, queue reapers, and source connector polls. Schedule definition, owner, enabled state, next/last run, last error, and run history are persisted. Schedules MAY enqueue Stage 11 queue jobs rather than execute long work inline.

Stage 11 done when ingestion, embedding, lifecycle, ANN rebuild, and broker-audit work can run through the durable queue and scheduler, and the operator can inspect queue depth, retries, dead letters, schedule run history, and failures from SQL and CLI.

#### Stage 12 — Verbatim source archive v1

- **V3-STOR-01**: immutable source object catalog with content hash, media type, byte length, source time, capture time, retention class, legal hold, sensitivity, partition, and owning account/schema. Local-filesystem and S3-compatible adapters. Optional signed download URLs for authorized clients. Exact source references for byte offsets, line offsets, pages, timestamps, and source-specific cursors. Promotion path from stored object to Source Package, Claim, Fact, embedding, and Derivation Ledger entry. Restore verification MUST confirm object bytes match catalog hashes.

Stage 12 done when source objects can be stored, verified, restored, retrieved, and linked into Source Packages and Derivation Ledger entries with hash-consistent round-trips across the storage adapter set.

#### Stage 13 — Realtime and active-pool presence

- **V3-REALTIME-01**: SSE or WebSocket endpoint for authenticated clients with event types for model request status, model response ready, MC2DB tool call, active pool membership change, new observation, claim promotion, episode replay completion, queue job state, source ingest progress, and audit alert. Every event carries account, partition, active pool, object reference, event kind, transaction time, and authorization scope. Authorization is checked before subscription and before delivery. Events are replayable from a durable event table for at-least-once delivery.
- **V3-PRESENCE-01**: track human, agent, and tool participants attached to an active memory pool with last seen, declared task, role, and ephemeral cursor/state metadata. Presence MUST NOT bypass memory authorization.

Stage 13 done when realtime clients can subscribe to active pool and model/tool events without observing unauthorized data, replay missed events from the durable event table, and see presence reflect the same authorization gates as durable retrieval.

#### Stage 14 — Vector and retrieval ergonomics

- **V3-VEC-01**: metadata filters on vector compartment search without bypassing SVPOR or retrieval authorization. Explicit choice between upgrading local NSW to multilevel HNSW and delegating large-compartment ANN to pgvector HNSW, with exact search preserved for validation/tests/small compartments. Bulk vector import/export and rebuild commands. Recall/latency benchmark fixtures for exact, NSW/HNSW, and hybrid search. Audit and metrics for index build, search mode, recall sample, delta size, tombstone count, and rebuild age.
- **V3-EMBED-01**: embedding jobs queued through Stage 11 for source excerpts, memory chunks, workflow traces, summaries, and query envelopes. Every embedding output includes SVPOR frame text and a Derivation Ledger entry. Model alias, embedding space, vector dimension, prompt/template/policy, input hash, and output hash are recorded. Re-embedding supports dual-space routing and rollback.
- **V3-RET-01**: public retrieval endpoint exposed through REST and SDKs with an explicit retrieval envelope. Debug mode surfaces query hints, search path, authz decisions, candidate counts, temporal mode, and provenance summary. Default response is safe for end users and does not leak hidden candidate counts across partitions unless the caller has audit privileges.

Stage 14 done when retrieval ergonomics meet `requirements.md` §4 contracts, every embedding has Derivation Ledger coverage, benchmarks publish baseline recall/latency, and metadata filters are demonstrably enforced inside the authorization-aware retrieval coordinator.

#### Stage 15 — Production operations

- **V3-OBS-01**: Prometheus-compatible metrics covering extension version and migration state; MC2DB and REST request count/latency/failure/risk class/endpoint; model request queue depth/latency/tokens/cost/provider kind; queue depth/retry/dead-letter/worker lease age; cron run success/failure/duration; source archive bytes and verification failures; vector index status/delta/tombstone/rebuild age/search latency; retrieval candidate counts by stage and debug-only authz rejection counts; active pool membership and event-stream subscriptions.
- **V3-LOG-01**: log-drain service tails PostgreSQL/audit/model/MC2DB/REST/broker logs and batches them to HTTP, file, S3-compatible, and OTLP HTTP destinations. Redaction rules cover secrets, tokens, prompt text, source excerpts, and model outputs. Log-drain destination credentials resolve through V3-SECRET-01.
- **V3-BACKUP-01**: backup manifest covering database dump/basebackup, WAL archive, `/etc/maludb`, source archive objects, model configs, TLS material, tool binaries, and external broker configs. CLI verification checks extension version, catalog hashes, source archive hashes, and restore smoke tests. PITR runbook using PostgreSQL physical backup and WAL archiving. Documented restore order.
- **V3-ENV-01**: self-hosted preview environments built from migrations and seed files. Explicit "no production data by default" policy. Optional anonymized seed export with policy hooks and audit. Health-check gates for extension load, services, RLS, REST, MC2DB, queues, cron, and retrieval smoke. Migration diff/report before promotion.
- **V3-REPL-01**: documented support statement for PostgreSQL physical streaming replicas for read-heavy retrieval and analytics. REST and MC2DB write endpoints MUST NOT route to replicas. Realtime, queues, cron, and model workers run against primary unless an explicit design permits read-only use.

Stage 15 done when metrics and log drains expose enough signal to operate the system without reading PostgreSQL tables manually, backup/restore validation proves PostgreSQL state and source archive state remain hash-consistent, preview environments boot from migration + seed only, and the replica posture is documented.

V3 release is acceptable per `version3-requirements.md` §"V3 Acceptance Criteria" once every Stage 8–15 ticket reaches its acceptance criteria, `pg_regress` passes on PostgreSQL 17, V3 service/SDK smoke tests pass, and ASan/UBSan/`clang-tidy`/`scan-build` add no new warnings for C code touched by V3.

### Stages 16+ — Version 4 PageIndex / ChatIndex track

Stages 16 through 19 implement Version 4 (§1.6). Each stage corresponds to one or more `V4-*` tickets defined in [`version4-pageindex-plan.md`](version4-pageindex-plan.md), with per-ticket deliverables, migration assignments, acceptance criteria, and open decisions. Stage-boundary discipline still applies: a Stage N+1 ticket MUST NOT install objects assigned to Stage N+2.

Doctrine that V4 stages MUST preserve:

1. Corrections never silently overwrite history. A re-derived tree closes the prior tree (`build_status = 'superseded'`) and opens a new one through the Temporal Supersession Engine; leaf ranges are preserved across the supersession.
2. Every internal-node summary, leaf summary, structure-pass run, and ChatIndex append MUST write a Derivation Ledger entry. Trees and tree nodes MUST appear in the ledger's `derived_object_type` admission set.
3. Authorization is checked at planning, candidate expansion (LLM child choice from an authz-filtered set), and result assembly for any retrieval path V4 touches. The LLM never sees an unauthorized sibling.
4. Tree-build transactions are atomic across PostgreSQL state V4 introduces: header status, node rows, Derivation Ledger entries, source-reference anchors, and event-stream emissions commit together.
5. V4 services (the new builder worker and any future siblings) MUST NOT become independent systems of record. Durable state changes flow through PostgreSQL.

#### Stage 16 — V4 documentation reconciliation

- **V4-DOC-01**: add §1.6 *Version 4 — PageIndex and ChatIndex* to this document and the Stages 16+ block to §9; add [`version4-pageindex-plan.md`](version4-pageindex-plan.md) to `CLAUDE.md` and `AGENTS.md` authoritative-documents lists and update the project status / staging strategy in both. Extend `scripts/maludb-check-doc-consistency` to recognize V4 as the current track. A reader following only `docs/user-manual.md`, [`version4-pageindex-plan.md`](version4-pageindex-plan.md), and this document MUST be able to enumerate every V4 ticket and surface.

Stage 16 done when `scripts/maludb-check-doc-consistency` passes against the new V4 baseline, every authoritative-document list mentions [`version4-pageindex-plan.md`](version4-pageindex-plan.md), and §1.6 + §9 Stage 16+ are consistent with the V4 plan.

#### Stage 17 — PageIndex catalog, parser, and builder

- **V4-PAGEINDEX-01**: `malu$page_index_tree` header table, `mdo_kind` discriminator on `malu$memory_detail_object`, page-index node columns (`tree_id`, `node_kind`, `title`, `summary`), composite check binding tree-node rows to `tree_id`, RLS via the underlying Source Package's `owner_schema` / `malu$object_grant`, `malu$derivation_ledger.derived_object_type` extended to accept `'page_index_tree'` and `'page_index_node'`. No tier views introduced; access stays on RLS-on-base-tables consistent with V3.
- **V4-PARSER-01**: pluggable PDF / markdown / plain-text parser interface in `services/maludb-pageindexd/`, with `pypdf` as the bundled default. AGPL parsers are operator-pluggable but MUST NOT be bundled.
- **V4-PAGEINDEX-02**: `source_package_promote_to_page_index` promotion path, `page_index_builder_enqueue` enqueue helper on the V3-QUEUE-01 queue, `malu$structure_pass_audit` row per build, builder worker in `services/maludb-pageindexd/` that runs the deterministic structure pass then per-node LLM summarization, V3-EMBED-01 chunker handoff via `precomputed_boundaries_from_tree_id`.

Stage 17 done when a fixture PDF promotes to a complete tree under a pinned model alias, re-promoting under a new alias produces a supersession edge with identical leaf ranges but new summaries, and the chunker handoff produces vector chunks aligned 1:1 with tree leaves.

#### Stage 18 — PageIndex retrieval planner integration

- **V4-PAGEINDEX-03**: new retrieval-planner intents `'structured_doc_qa'` and `'long_chat_recall'`; new `tree_descent` value in the search-path enum; `malu$retrieval_envelope` columns for descent trail (`tree_descent_used`, `tree_descent_path`, `tree_descent_authz_rejections`); three-stage authorization on tree traversal; per-descent-step audit row in `malu$retrieval_decision_audit` with `stage='tree_descent'`.

Stage 18 done when `structured_doc_qa` intent routes to tree descent on Source Packages that have trees, the descent prompt never includes an unauthorized sibling, the LLM's choice is re-checked against the authz-filtered set before traversal, and unauthorized leaves are redacted at result assembly.

#### Stage 19 — ChatIndex

- **V4-CHATINDEX-01**: `malu$chat_index_tree` header table with `current_node_mdo_id` pointer; `mdo_kind` admits `'chat_index_topic'` and `'chat_index_message'`; chat-payload columns on `malu$memory_detail_object` (`topic_name`, `system_message`, `user_message`, `assistant_message`, `message_index`); `malu$derivation_ledger.derived_object_type` extended to accept `'chat_index_tree'`, `'chat_index_topic'`, `'chat_index_message'`.
- **V4-CHATINDEX-02**: `chat_index_append_messages` incremental append, enforcement of the "new topics branch only from current node or its ancestors" rule, idempotency on duplicate `message_index`, supersession on retroactive correction.

Stage 19 done when a chat transcript Source Package promotes to a complete chat tree, incremental append over many calls produces a tree byte-equivalent to a one-shot ingest of the same message sequence, and the ancestor-branch rule is enforced under concurrent appends.

#### Stages 16+ external surfaces

V4-MC2DB-01, V4-REST-01, V4-CLI-01, and V4-SDK-01 do not own migrations; they piggyback on the Stage 17–19 migrations and add MC2DB tools, REST endpoints, CLI subcommands, and SDK wrappers for PageIndex and ChatIndex build / append / ask / list operations. All surfaces share the V3-AUTH-01 token model and the same RLS posture as direct SQL.

V4 release is acceptable per [`version4-pageindex-plan.md`](version4-pageindex-plan.md) §12 once every Stage 16–19 ticket plus the external-surface tickets reach their acceptance criteria, `pg_regress` passes on PostgreSQL 17, V4 service / SDK smoke tests pass, and ASan/UBSan/`clang-tidy`/`scan-build` add no new warnings for C code touched by V4 (V4 currently introduces no new C code; this gate stays in place to catch incidental changes).

---

## 10. Deferred / Open Decisions

These are explicitly **not** decided in R1.0; the implementation MUST keep them open.

- Custom storage engine vs. pure PostgreSQL extension long-term.
- Distributed/horizontal scaling architecture (Citus vs. sharding plus federation vs. fork).
- Exact MAUT default weights per object type (must be policy-configurable from day one, but the defaults need tuning data).
- Default embedding model and dimension (decoupled from the system; lives in the Model Registry).
- Whether the first local model package links `libllama` directly into a local model worker or shells out to/controls an approved local runtime process; ordinary PostgreSQL backend inference remains deferred pending explicit design approval.
- Causal reasoning subsystem.
- Whether the Skill Runtime ever executes effectful tools directly or always delegates to an external agent harness (MCP).
- Whether MC2DB eventually exposes a local-only PostgreSQL background-worker HTTPS listener or remains a managed listener process backed by PostgreSQL.
- Whether to adopt `pg_search` (ParadeDB, AGPL) for BM25 ranking or stay on native FTS.
- Whether `extension_control_path` (PG 18) becomes a hard requirement (would bump min PG to 18).
- **V3-CRON-01**: adopt `pg_cron` or ship a MaluDB-native schedule table + worker.
- **V3-QUEUE-01**: adopt `pgmq` or ship a MaluDB-native queue table with visibility leases.
- **V3-API-01**: adopt PostgREST or ship a small custom REST gateway purpose-built for the curated catalog.
- **V3-SECRET-01**: adopt `pgsodium` / Vault-style encrypted storage or ship a file-backed development resolver plus a pluggable production resolver.
- **V3-VEC-01**: upgrade local NSW to multilevel HNSW inside MaluDB, or delegate indexed ANN on large compartments to `pgvector` HNSW while keeping exact search for small compartments and tests.
- **V3-REALTIME-01**: SSE versus WebSocket as the wire format (or both); event-table retention/compaction policy.
- **V3-STOR-01**: storage adapter precedence (local FS for dev, S3-compatible for production) and signed-URL TTL defaults.
- Whether V3 requires GraphQL (`pg_graphql`) for any first-party customer; deferred from V3 by default.

---

## 11. Glossary (canonical terms)

| Term | Meaning |
|---|---|
| **Episode Object** | DBMS object for a specific remembered episode, including evidence, time, actors, relationships, replay metadata. |
| **Memory Detail Object** | Addressable child/linked object representing a step, substep, parameter, command, validation, exception, source excerpt, or evidence item. |
| **Recursive Detail** | Ability to expand Memory Detail Objects only to the depth a task requires. |
| **Workflow Trace** | Observed step sequence from one Episode Object/case. |
| **Generalized Workflow** | Repeatable process pattern derived from multiple traces. |
| **Procedural Memory Object** | Capability-oriented how-to knowledge for performing, adapting, validating, and repairing work. |
| **Skill Package** | Governed procedural memory packaged for reuse by humans or AI agents with execution policy and audit records. |
| **Competency Package** | Governed capability bundle composed from procedural memories and/or skills, used to represent validated operational know-how. |
| **Active Memory Pool** | Scoped working-memory space for a task, project, incident, or collaboration session. |
| **Derivation Ledger** | Auditable lineage from source through claims, facts, memories, workflows, procedural memories, skills, and derived artifacts. |
| **Temporal Supersession Engine** | DBMS subsystem for valid-time/transaction-time windows, corrections, supersession, staleness, current validity. |
| **Security-Aware Retrieval Coordinator** | Subsystem that builds authorization context, prefilters retrieval, post-validates candidates, assembles policy-aware result packages. |
| **Transaction and WAL Manager** | Subsystem providing MVCC, global commit sequencing, isolation policy, crash recovery, internal multi-model atomicity. |
| **MC2DB** | Model Context to Database: database-native MCP-compatible listener generated from PostgreSQL catalog metadata and stored procedures. |
| **SVPOR** | Subject-Verb-Predicate-Object-Relationship organization model. |
| **MAUT** | Multi-Attribute Utility Theory — the weighted-aggregate scoring model used for confidence and precision. |

---

*This document is the canonical statement of MaluDB implementation requirements.*
