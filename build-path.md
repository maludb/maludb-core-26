# MaluDB Build Path

This is a living build path for MaluDB. It records the staged implementation order, verification gates, and reusable prompts needed to build the DBMS through the PostgreSQL extension, memory object model, retrieval layer, model integration, MCP interface, and hardening work.

The build path is subordinate to `requirements.md`. If this file conflicts with `requirements.md`, update this file or raise the conflict.

## 1. Operating Rules

- Stay inside the current stage unless the prompt explicitly expands scope.
- Do not install Stage N+1 objects in Stage N extension SQL.
- Use PGXS, not Meson or CMake.
- Use PostgreSQL 17 from PGDG as the baseline runtime.
- Keep PG 16 compatibility and add PG 18 compatibility when dependencies validate.
- Use PostgreSQL backend APIs in C code: `palloc`, `ereport`, PostgreSQL transaction APIs, PostgreSQL version macros.
- Do not perform model inference, external MCP tool execution, external network calls, or arbitrary process execution inside ordinary PostgreSQL backend processes. The early model runtime is a governed companion service plus SQL/session extension surface; MC2DB is a governed listener extension/service; MC2DB stored procedures may emit only to the active MC2DB response context through package-like APIs such as `mc2db.put_object`.
- Preserve provenance for every derived object.
- Wrap multi-model writes in PostgreSQL transactions.
- Add focused regression tests for every schema or behavior change.
- Update `requirements.md`, `design-notes.md`, and this file when scope or design changes.

## 2. Source Documents

Read these before changing code or requirements:

- `AGENTS.md`: repository rules, stack, staging boundaries, testing expectations.
- `white-paper.md`: conceptual reference.
- `requirements.md`: authoritative implementation requirements.
- `release-1.0-requirements.md`: narrowed requirements for the first field-testable release.
- `release-1.0-build-plan.md`: detailed Release 1.0 implementation plan.
- `design-notes.md`: architectural design decisions and open questions.
- `mc2db-white-paper.md`: MC2DB concept paper for database-native MCP-compatible listeners and stored-procedure tools.
- `docs/design/svpor-schema.md`: Stage 3 SVPOR design-on-paper; do not install in Stage 1.
- `Makefile`, `maludb_core.control`, `sql/extension/maludb_core--0.1.0.sql`, `src/maludb_core.c`, `sql/load.sql`, `expected/load.out`: current Stage 1 extension scaffold.

## 3. Verification Commands

Use the narrowest verification command that proves the change, then broaden confidence when the stage is ready.

```bash
make PG_CONFIG=/usr/lib/postgresql/17/bin/pg_config
sudo --preserve-env make installcheck PG_CONFIG=/usr/lib/postgresql/17/bin/pg_config
make COPT="-fsanitize=address,undefined -fno-omit-frame-pointer -O1 -g" PG_CONFIG=/usr/lib/postgresql/17/bin/pg_config
scan-build-18 make PG_CONFIG=/usr/lib/postgresql/17/bin/pg_config
clang-tidy-18 src/*.c -- $(/usr/lib/postgresql/17/bin/pg_config --cflags) -I$(/usr/lib/postgresql/17/bin/pg_config --includedir-server)
git diff --check
```

For docs-only changes, `git diff --check` plus a targeted traceability scan is sufficient unless the doc changes implementation behavior.

## 4. Stage Gates

| Stage | Gate |
|---:|---|
| 1 | Fresh Ubuntu 24.04 install path can install PostgreSQL 17, pgvector, and `maludb_core`; `CREATE EXTENSION` works; vector insert/search works through MaluDB-owned schema; no Stage 2+ objects are installed; regression and sanitizer builds pass. |
| 1.5 | Model gateway package builds or installs; local/cloud model aliases can be registered; a prompt template can be registered; a user session can start; explicit Session Context can be rendered into a prompt; a model request/response is recorded; no Stage 2+ memory objects are installed. |
| 1.6 | MC2DB listener starts on a configured network port; MCP-shaped initialization/discovery/tool-call flows work; R1.0 database tools can read/write Session Context and submit model requests; no Stage 2+ memory objects are installed. |
| 2 | Source packages, claims, facts, Episode Objects, memories, Memory Detail Objects, relationship edges, verbatim archive metadata, and derivation ledger schema exist with atomic insert APIs and regression coverage. |
| 3 | Bitemporal windows, Temporal Supersession Engine, SVPOR routing, MAUT scoring, lifecycle, salience, and invalidation hooks exist with history-preserving corrections. |
| 4 | Retrieval planner builds envelopes, accepts query hints, coordinates relational/FTS/graph/vector/detail paths, and enforces authorization at planning, expansion, and assembly. |
| 5 | Workflow extraction, skill runtime, active memory pools, and Episode replay work as governed subsystems with audit records. |
| 6 | Local nodes, model registry migration behavior, advanced MC2DB memory tools, external MCP broker/reference service, and drivers are implemented. |
| 7 | Packaging, docs, security review, performance work, and public-alpha readiness are complete. |

Version Release 1.0 consists of Stages 1, 1.5, and 1.6. Use `release-1.0-build-plan.md` as the primary execution plan for that release. Later stages build the long-term memory DBMS on top of that first release.

In other words, Release 1.0 hardens Stage 1 into a field-testable DBMS release: core PostgreSQL, GPU-ready local model runtime, Session Context, and MC2DB listener.

## 5. Stage 1 Build Path

Goal: create a working PostgreSQL extension substrate that proves pgvector, packaging, regression tests, and catalog scaffolding without implementing memory semantics.

Tasks:

- Harden the PGXS extension skeleton.
- Add dependency validation for `vector` where the Stage 1 demo needs it.
- Add catalog scaffolding tables only: accounts, partitions, object-type registry, source-type registry, relationship-type registry, model registry stubs.
- Add a demonstration table with at least one `vector` column in the `maludb_core` schema.
- Add regression tests for extension load, catalog reads, vector insert/query, and Stage 1 boundary checks.
- Add ASan/UBSan, `clang-tidy`, and `scan-build` targets or CI jobs.
- Add packaging/bootstrap path that installs PostgreSQL 17 and required extension packages on Ubuntu 24.04.
- Keep all memory-specific objects out of Stage 1.

Prompt:

```text
We are in Stage 1 of MaluDB. Read AGENTS.md, requirements.md, design-notes.md, and the current extension files. Implement only the PostgreSQL + pgvector relational foundation. Do not implement model runtime/session APIs, Session Context, MC2DB listener APIs, sources, claims, facts, Episode Objects, memories, Memory Detail Objects, SVPOR, bitemporal columns, derivation ledger, retrieval planner, workflows, skills, active pools, local nodes, or MCP runtime.

Goal: make the maludb_core PGXS extension installable and testable on PostgreSQL 17 with pgvector.

Required changes:
- Update `sql/extension/maludb_core--0.1.0.sql` to create only Stage 1 catalog scaffolding and a vector demonstration table in the maludb_core schema.
- Add dependency checks or actionable failure behavior for pgvector.
- Update sql/load.sql and expected/load.out to test extension load, catalog scaffolding reads, vector insert/query, and absence of Stage 2+ governed memory objects.
- Keep C code minimal unless PostgreSQL backend behavior is required.
- Do not modify white-paper.md.

Verification:
- make PG_CONFIG=/usr/lib/postgresql/17/bin/pg_config
- sudo --preserve-env make installcheck PG_CONFIG=/usr/lib/postgresql/17/bin/pg_config
- git diff --check

Before finishing, summarize which requirements.md Stage 1 bullets are satisfied and which remain open.
```

## 5.1 Stage 1.5 Build Path

Goal: add the first DB-managed model runtime path without introducing memory objects. This stage proves that MaluDB can compile or install a local runtime such as `llama.cpp`, call approved cloud models through the same process, maintain model sessions in PostgreSQL, pull prompt templates and explicit Session Context from the database, render a prompt, and record a model response.

Tasks:

- Add a `maludb_model` SQL/session surface or equivalent `maludb_core` schema slice for model providers, local/cloud model aliases, prompt templates, sessions, Session Context blocks, runtime requests, and runtime responses.
- Add packaging/build support for `llama.cpp` / `libllama` or a selected equivalent local runtime as a governed MaluDB companion service, plus a provider-adapter path for cloud models through the same model gateway.
- Keep PostgreSQL extension builds PGXS-based; do not switch the extension to CMake/Meson because the local runtime has its own build.
- Add SQL APIs for registering a local or cloud model alias, registering a versioned prompt template, starting a session, appending explicit Session Context, rendering a prompt, submitting a request, and reading a response.
- Add a runtime service contract that can be implemented with a real local runtime or a deterministic test stub.
- Record account identity, model alias/version, prompt template version, context block hashes, rendered prompt hash, request parameters, response hash, status, latency, and audit metadata.
- Add regression tests proving prompt-template versioning, session creation, context rendering, request/response recording, cancellation/error states, and absence of Stage 2+ governed memory objects.

Prompt:

```text
We are in Stage 1.5 of MaluDB. Read AGENTS.md, requirements.md section 3.10, design-notes.md section 8, and the current Stage 1 extension files. Implement only the model runtime/session substrate and Session Context. Do not implement MC2DB, sources, claims, facts, Episode Objects, memories, Memory Detail Objects, SVPOR, bitemporal columns, derivation ledger, retrieval planner, workflows, skills, active pools, local nodes, or external MCP runtime.

Goal: make MaluDB able to start a local or cloud model session, read a prompt template and explicit Session Context from PostgreSQL, render the prompt, submit it to one model gateway contract, and store response metadata.

Required changes:
- Add catalog tables or stable views/functions for model providers, local/cloud model aliases, prompt templates, prompt template versions, model sessions, Session Context blocks, runtime requests, and runtime responses.
- Add SQL APIs equivalent to register_model_provider, register_model_alias, register_prompt_template, start_session, append_context, render_prompt, submit_prompt, and get_response.
- Add a governed `maludb_modeld` service contract for local `llama.cpp` / `libllama` execution and cloud provider adapters. A deterministic test stub is acceptable for regression tests if real model execution is not available in CI.
- Keep model inference out of ordinary PostgreSQL backend processes. SQL functions may create durable requests and read durable responses; they must not open arbitrary network sockets or hold local model state.
- Do not store model weights or cloud provider secrets in PostgreSQL user-visible tables. Register model file paths, hashes, quantization, license/provider metadata, context limits, and deployment location; resolve secrets only inside the governed model gateway.
- Add tests for prompt rendering determinism, account-bound session creation, context block hashing, runtime request lifecycle, response recording, timeout/cancellation state, and absence of Stage 2+ governed memory objects.
- Do not modify white-paper.md.

Verification:
- make PG_CONFIG=/usr/lib/postgresql/17/bin/pg_config
- sudo --preserve-env make installcheck PG_CONFIG=/usr/lib/postgresql/17/bin/pg_config
- Run local runtime service-contract tests or the deterministic runtime stub tests.
- git diff --check

Before finishing, summarize which requirements.md Stage 1.5 bullets are satisfied and which remain open.
```

## 5.2 Stage 1.6 Build Path

Goal: add the MC2DB database listener immediately after the model runtime. This stage proves that the DBMS can listen on a network port, accept MCP-shaped input, expose R1.0 database tools, and let local or cloud models access Session Context and model requests through a governed listener.

Tasks:

- Add a `maludb_mc2db` SQL surface or equivalent schema slice for listener configuration, logical server profiles, R1.0 tools, prompts, resources, schemas, risk classes, privileges, and invocation records.
- Add a managed `maludb_mc2dbd` listener service or equivalent listener extension package that defaults to `https://localhost:5329`.
- Implement the MCP-compatible request shape for initialization, capability negotiation, tool/resource/prompt discovery, tool calls, protocol errors, and tool execution errors.
- Add R1.0 tools for health, catalog inspection, prompt listing, model provider listing, session creation/lookup, Session Context append/read, prompt rendering, model request submission, and response lookup.
- Add `mc2db.create_server`, `mc2db.register_tool`, `mc2db.register_prompt`, `mc2db.register_resource`, `mc2db.put_object`, `mc2db.put_text`, `mc2db.put_error`, and `mc2db.flush` or equivalent SQL APIs.
- Keep listener socket handling and cloud/network calls out of ordinary PostgreSQL backend processes. Stored procedures emit only to the active MC2DB response context.
- Add service tests for listener startup, MCP-shaped initialize/discovery/call flows, authorized and unauthorized tool discovery, stored-procedure invocation, Session Context operations, model request submission, audit records, and absence of Stage 2+ governed memory objects.

Prompt:

```text
We are in Stage 1.6 of MaluDB. Read AGENTS.md, release-1.0-requirements.md, release-1.0-build-plan.md, requirements.md section 3.11, design-notes.md section 9, mc2db-white-paper.md, and the Stage 1.5 model/session code. Implement only the MC2DB R1.0 listener and database-native R1.0 tools. Do not implement sources, claims, facts, Episode Objects, memories, Memory Detail Objects, SVPOR, bitemporal columns, derivation ledger, retrieval planner, workflows, skills, active pools, local nodes, advanced memory retrieval tools, or external MCP broker runtime.

Goal: make the DBMS expose an MCP-compatible listener, default https://localhost:5329, that can accept MCP-shaped input and call authorized R1.0 database tools for Session Context and model requests.

Required changes:
- Add catalog tables or stable views/functions for listener configuration, logical MC2DB server profiles, tools, prompts, resources, JSON schemas, risk classes, required privileges, rate limits, and invocation records.
- Add a managed listener service or extension package that binds the configured network port and implements MCP-shaped initialize, discovery, and tool-call request handling.
- Add R1.0 database-native tools for health, catalog inspection, prompt listing, provider listing, session create/read, Session Context append/read, prompt render, model request submit, and response read.
- Add SQL APIs equivalent to mc2db.create_server, mc2db.register_tool, mc2db.register_prompt, mc2db.register_resource, mc2db.put_object, mc2db.put_text, mc2db.put_error, and mc2db.flush.
- Enforce authentication, authorization-filtered discovery, pinned search_path, statement timeout, input/output schema validation, protocol/tool error separation, and invocation audit.
- Keep network listener sockets out of ordinary PostgreSQL backend processes unless an explicit background-worker design has been approved.
- Do not modify white-paper.md.

Verification:
- make PG_CONFIG=/usr/lib/postgresql/17/bin/pg_config
- sudo --preserve-env make installcheck PG_CONFIG=/usr/lib/postgresql/17/bin/pg_config
- Run service-level MC2DB listener tests for initialize, tools/list, tools/call, unauthorized filtering, Session Context operations, and model request submission.
- git diff --check

Before finishing, summarize which requirements.md Stage 1.6 bullets are satisfied and which remain open.
```

## 6. Stage 2 Build Path

Goal: introduce the first memory-specific durable object model and source evidence foundation.

Tasks:

- Add source package schema with hash, origin, source references, retention, legal hold, and archive placement metadata.
- Add claim, fact, Episode Object, memory, Memory Detail Object, and relationship edge tables.
- Add the governed-object anchor and stable identifiers.
- Add derivation ledger schema and write API for source -> claim, claim -> fact, fact/claim -> memory, and object -> artifact.
- Add atomic insertion functions for multi-object writes.
- Configure `pgaudit` and `pg_stat_statements` expectations.
- Add regression tests for object insertion, source references, derivation rows, relationship edges, and rollback safety.

Prompt:

```text
We are starting Stage 2 of MaluDB. Read AGENTS.md, requirements.md sections 3.1, 3.5, 3.6, 3.7, 5, 6.2, and 9; read design-notes.md; review docs/design/svpor-schema.md only as design context. Stay inside Stage 2.

Goal: add the memory object model and verbatim source/archive metadata without implementing Stage 3 bitemporal behavior, SVPOR routing, MAUT scoring, retrieval planning, workflows, skills, active pools, local nodes, or MCP runtime.

Required changes:
- Add versioned extension upgrade scripts for Stage 2 schema.
- Add source packages, source references, claims, facts, Episode Objects, memories, Memory Detail Objects, relationship edges, governed-object anchors, and derivation ledger tables.
- Add write APIs that wrap multi-object insertion in one PostgreSQL transaction.
- Preserve stable IDs, lifecycle state, partition/security metadata, and derivation references.
- Add regression tests for insert, rollback, derivation linkage, recursive details, relationship edges, and source-reference precision.
- Do not modify white-paper.md unless explicitly instructed.

Verification:
- make PG_CONFIG=/usr/lib/postgresql/17/bin/pg_config
- sudo --preserve-env make installcheck PG_CONFIG=/usr/lib/postgresql/17/bin/pg_config
- git diff --check

Report any conflict between requirements.md and existing code before changing the requirement or code.
```

## 7. Stage 3 Build Path

Goal: make memory temporally disciplined, semantically organized, scored, and lifecycle-aware.

Tasks:

- Add bitemporal columns and `tstzrange` representations where required.
- Add GiST exclusion constraints with `btree_gist`.
- Add Temporal Supersession Engine APIs.
- Add SVPOR system catalog tables and routing indexes.
- Add MAUT score tables, weights, evaluator metadata, and aggregate functions.
- Add lifecycle and salience policy tables.
- Add invalidation queues for embeddings, summaries, workflows, active pools, and skills.

Prompt:

```text
We are starting Stage 3 of MaluDB. Read AGENTS.md, requirements.md sections 3.2, 3.3, 3.4, 3.14, 6.2, and 9; read design-notes.md; read docs/design/svpor-schema.md carefully. Stay inside Stage 3.

Goal: add bitemporal behavior, SVPOR organization, MAUT confidence/precision scoring, lifecycle, salience, and supersession without implementing the Stage 4 retrieval planner or Stage 5 workflow/skill runtimes.

Required changes:
- Add bitemporal valid-time and transaction-time columns using tstzrange where appropriate.
- Add non-overlap constraints using btree_gist/GiST where logical validity requires it.
- Add Temporal Supersession Engine functions that close prior windows, create supersedes edges, preserve history, and enqueue derived-artifact invalidations.
- Add SVPOR registries, normalized predicate values, relationship categories, and routing indexes.
- Add MAUT score schema with per-category subscores, weights, evaluator metadata, aggregate computation, and policy-configurable weights.
- Add lifecycle/salience/reinforcement/decay/consolidation metadata.
- Add regression tests proving corrections do not overwrite history.

Verification:
- make PG_CONFIG=/usr/lib/postgresql/17/bin/pg_config
- sudo --preserve-env make installcheck PG_CONFIG=/usr/lib/postgresql/17/bin/pg_config
- Run targeted tests for supersession and MAUT aggregate behavior.
- git diff --check
```

## 8. Stage 4 Build Path

Goal: implement authorization-aware hybrid retrieval.

Tasks:

- Add retrieval envelope schema/API.
- Add cue extraction and query-hint structures.
- Add search-path planning functions.
- Integrate relational filters, FTS, temporal indexes, recursive detail expansion, relationship traversal, and scoped vector search.
- Add authorization gates at planning, candidate expansion, and result assembly.
- Add result packages that include objects, evidence links, confidence, precision, validity, permissions, and recursive depth.

Prompt:

```text
We are starting Stage 4 of MaluDB. Read AGENTS.md, requirements.md section 4, design-notes.md sections on PostgreSQL ownership, SVPOR, and MCP boundaries, and all Stage 1-3 extension upgrade scripts. Stay inside Stage 4.

Goal: build the retrieval planner and hybrid recall path. Do not implement Workflow Extraction Engine, Skill Runtime, Active Memory Pool manager, Local Memory Nodes, MC2DB, or external MCP reference service yet.

Required changes:
- Add retrieval envelope types/tables/functions.
- Add query hint validation.
- Add search-path planning for specific recall, evidence queries, procedural queries, date-sensitive queries, graph/dependency queries, and scoped exploratory search.
- Coordinate relational/catalog, FTS, graph/recursive CTE, temporal, vector, and recursive-detail paths.
- Enforce authorization during planning, candidate expansion, and result assembly.
- Add regression tests proving unauthorized rows do not leak through vector, graph, FTS, or detail expansion.

Verification:
- make PG_CONFIG=/usr/lib/postgresql/17/bin/pg_config
- sudo --preserve-env make installcheck PG_CONFIG=/usr/lib/postgresql/17/bin/pg_config
- Add targeted authorization-leak tests.
- git diff --check
```

## 9. Stage 5 Build Path

Goal: turn memories into operational knowledge and active task context.

Tasks:

- Add initial Workflow Extraction Engine schema and service contract.
- Add candidate workflow versioning, review status, positive/negative evidence, variants, exceptions, and conformance metadata.
- Add Skill Runtime state-machine schema.
- Add active memory pool schema, membership, promotion path, and real-time service contract.
- Add Episode replay API.

Prompt:

```text
We are starting Stage 5 of MaluDB. Read AGENTS.md, requirements.md sections 3.8, 3.9, 3.12, 3.13, 6, and 9; read design-notes.md. Stay inside Stage 5.

Goal: add governed workflow extraction, skill runtime records, active memory pools, and Episode replay. Do not implement local-node sync, model migration adapters, MC2DB, external MCP reference service, or language drivers yet.

Required changes:
- Add workflow trace and generalized workflow candidate schemas if not already complete.
- Add Workflow Extraction Engine service contract and durable job/result tables.
- Add Skill Package execution state-machine schema and audit records.
- Add Active Memory Pool durable state, membership, loaded-object metadata, pending observations, and promotion records.
- Add Episode replay functions that reconstruct current-valid, historical, transaction-time, and bitemporal views under authorization.
- Add regression tests for candidate workflow review, skill execution records, active-pool writes, promotion path, and replay modes.

Verification:
- make PG_CONFIG=/usr/lib/postgresql/17/bin/pg_config
- sudo --preserve-env make installcheck PG_CONFIG=/usr/lib/postgresql/17/bin/pg_config
- Run targeted replay and active-pool authorization tests.
- git diff --check
```

## 10. Stage 6 Build Path

Goal: add local nodes, model registry migration behavior, advanced MC2DB memory tools, external MCP reference services, and client access.

Tasks:

- Add Local Memory Node sync schema and conflict/tombstone records.
- Complete Model Registry rollout and embedding migration behavior.
- Extend the Stage 1.5 model runtime with advanced capability negotiation for tool calling, reasoning mode declaration, streaming, and optional embeddings.
- Extend the Stage 1.6 MC2DB listener with memory retrieval, workflow, skill, local-node, and governed memory-write tools.
- Add external MCP tool broker service, invocation records, and reference MCP integration for non-database tools.
- Add C, Python, Node.js, and PHP driver surfaces or API bindings.

Prompt:

```text
We are starting Stage 6 of MaluDB. Read AGENTS.md, requirements.md sections 3.10, 3.11, 3.12, 4, 6, 7.4, 8, and 9; read design-notes.md sections on model runtime, MC2DB, and MCP; read mc2db-white-paper.md. Stay inside Stage 6.

Goal: add local-node sync, model registry migration behavior, advanced model capability negotiation, advanced MC2DB memory tools, external MCP reference service, and driver/API surface. Do not add active-active replication, distributed consensus, custom storage engine, or automatic promotion of model outputs.

Required changes:
- Add Local Memory Node registry, sync sessions, conflict records, tombstones, and promotion candidates.
- Add Model Registry migration records for blue-green indexes, dual-space routing, adapter alignment, and staged re-embedding.
- Extend the Stage 1.5 model runtime/session contract with capabilities for structured output, tool calling, reasoning mode declaration, streaming, optional embeddings, and MC2DB/external-MCP tool manifest translation.
- Extend the Stage 1.6 MC2DB catalog and listener with memory retrieval, workflow, skill, local-node, and governed memory-write tools/resources/prompts.
- Add invocation ledger tables for MC2DB calls and external MCP broker calls.
- Add an external MCP broker/service outside PostgreSQL backend processes for non-database tools.
- Add initial driver/API examples for C, Python, Node.js, and PHP or document narrowed first-driver scope if full driver coverage is deferred.
- Add tests for advanced MC2DB memory-tool discovery/filtering/invocation, external MCP broker policy, local-node sync conflict records, advanced model capability negotiation, and model migration state.

Verification:
- make PG_CONFIG=/usr/lib/postgresql/17/bin/pg_config
- sudo --preserve-env make installcheck PG_CONFIG=/usr/lib/postgresql/17/bin/pg_config
- Run service-level tests for advanced MC2DB memory tools, external MCP broker policy, and advanced model capability negotiation.
- git diff --check
```

## 10.1 Advanced MC2DB Memory Tool Prompt

Use this prompt when adding later memory-aware MC2DB tools after Release 1.0. The first database-native MC2DB tools are part of `release-1.0-build-plan.md` Phase R1.0-8.

```text
We are implementing an advanced memory-aware MC2DB database-native tool in MaluDB Stage 6. Read AGENTS.md, release-1.0-requirements.md for the existing listener/tool baseline, requirements.md section 3.11, design-notes.md section 9, mc2db-white-paper.md, and the current MC2DB catalog/listener code.

Task: add one database-backed MC2DB memory/retrieval/workflow/skill tool implemented as a PostgreSQL stored procedure. This tool must not require a handwritten MCP server. The MaluDB MC2DB listener should expose it at the configured MCP-compatible listener address, default `https://localhost:5329`.

Required behavior:
- Register the tool through `mc2db.register_tool` or the current equivalent SQL API.
- Attach the tool to a logical MC2DB server profile created through `mc2db.create_server` or the current equivalent SQL API.
- Define input and output JSON schemas.
- Implement the tool routine with signature `(args jsonb, context jsonb)`.
- Use `SECURITY INVOKER` by default.
- Pin or verify safe `search_path` behavior.
- Enforce row-level security and memory-specific authorization.
- Emit MCP-shaped JSON with `content`, optional `structuredContent`, and `isError` through `mc2db.put_object`; do not open sockets or bypass the active MC2DB response context from PL/pgSQL.
- Record invocation metadata, argument hash, result hash, tool definition version, policy version, account identity, and transaction time.
- Preserve provenance and derivation linkage when the result becomes durable memory evidence.
- Add regression tests for authorized discovery, unauthorized discovery filtering, valid invocation, `mc2db.put_object` outside-active-context failure, invalid input schema, output schema validation, and audit row creation.

Verification:
- make PG_CONFIG=/usr/lib/postgresql/17/bin/pg_config
- sudo --preserve-env make installcheck PG_CONFIG=/usr/lib/postgresql/17/bin/pg_config
- Run service-level MC2DB listener tests if the listener exists.
- git diff --check
```

## 11. Stage 7 Build Path

Goal: harden, document, package, benchmark, and prepare public alpha.

Tasks:

- Add performance benchmarks and tuning notes.
- Complete Debian packaging with `pg_buildext`.
- Run security review for RLS, semantic-slice grants, pgaudit, model/tool boundaries, and MCP broker.
- Complete deployment guide and examples.
- Add recovery/rebuild documentation for embeddings, indexes, summaries, and routing structures.
- Add public-alpha checklist.

Prompt:

```text
We are starting Stage 7 hardening for MaluDB. Read AGENTS.md, requirements.md sections 5, 7, 8, and 9; read design-notes.md and all current implementation docs.

Goal: prepare MaluDB for public alpha by hardening packaging, security, recovery, performance, and documentation. Do not expand functional scope unless a hardening task exposes a blocking requirement gap.

Required changes:
- Add or update performance benchmarks for retrieval, active-pool load, Episode replay, and vector search.
- Finalize Debian packaging and install documentation.
- Review RLS, grants, semantic-slice authorization, pgaudit, MCP/tool boundaries, and local model execution boundaries.
- Document backup, restore, and rebuild order for source packages, catalog, ledger, embeddings, vector indexes, summaries, and routing structures.
- Add public-alpha operational guide and examples.

Verification:
- Full PG 17 regression suite.
- ASan/UBSan build and installcheck.
- clang-tidy and scan-build with no new warnings.
- Packaging install on fresh Ubuntu 24.04.
- git diff --check
```

## 12. Review Prompts

Use these prompts between implementation passes.

Requirements review:

```text
Review the current changes against requirements.md and white-paper.md. Do not modify files yet. Identify conflicts, missing requirements, stage-boundary violations, and places where implementation has drifted from the white paper. Prioritize issues by severity and cite exact file paths.
```

Stage-boundary review:

```text
Review the current branch for Stage N boundary violations. Check extension SQL, tests, docs, and services. Identify any Stage N+1 concepts that were installed, tested as production behavior, or made required too early. Do not change files; report findings first.
```

Security and authorization review:

```text
Review retrieval, source inspection, vector search, graph traversal, active-pool loading, MCP tool calls, and result assembly for authorization leaks. Verify checks happen during planning, candidate expansion, and result assembly. Report concrete findings with file paths and suggested fixes.
```

Provenance review:

```text
Review all derived-object writes in this change. Confirm every source-to-claim, claim-to-fact, fact-to-memory, memory-to-workflow, workflow-to-skill, embedding, summary, model output, MC2DB tool result, and external MCP tool result has Derivation Ledger coverage or a documented reason it is not durable derived data.
```

Docs sync review:

```text
Review requirements.md, design-notes.md, build-path.md, README.md, and docs/design/* for inconsistencies introduced by this change. Do not rewrite broad sections. Propose minimal edits that keep the docs aligned with the implemented stage.
```

## 13. Prompt Template for New Work

Use this as the default starting prompt for future implementation tasks:

```text
We are working on MaluDB in Stage [N]. Read AGENTS.md, requirements.md, design-notes.md, build-path.md, and any relevant docs/design files. Stay strictly inside Stage [N].

Task: [specific task]

Constraints:
- Do not modify white-paper.md.
- Do not implement Stage [N+1] features.
- Use PGXS and PostgreSQL extension conventions.
- Use PostgreSQL backend APIs in C code.
- Preserve provenance, authorization, bitemporal discipline, and atomicity where this task touches them.
- Update requirements.md/design-notes.md/build-path.md only if this task changes scope or design.

Expected output:
- Minimal focused code/docs changes.
- Regression tests or a documented reason tests are not applicable.
- Verification commands run and results summarized.
```

## 14. Current Next Step

The immediate next engineering step is still Stage 1: turn the existing extension skeleton into a PostgreSQL + pgvector foundation with catalog scaffolding, vector demonstration table, stage-boundary tests, and install/bootstrap validation. Stage 2+ design can continue in documents, but it must not ship through `sql/extension/maludb_core--0.1.0.sql` until the Stage 1 gate is met.
