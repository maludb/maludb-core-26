# Schema Memory Enablement Design

## Purpose

MaluDB should behave like a normal PostgreSQL extension for ordinary schemas. A schema is not assumed to be a memory schema when it is created. The schema owner opts in by running one extension function or script that creates a schema-local MALUDB surface over shared `maludb_core` storage.

The enabled schema should feel natural to PostgreSQL users:

```sql
SET search_path TO zozocal, maludb_core, public;

SELECT * FROM maludb_subject;
SELECT * FROM maludb_document_search(p_project => 'zozocal');
SELECT * FROM maludb_pool_search(p_pool_name => 'zozocal-coding-agent', p_query_text => 'schema views');
```

The core design remains centralized storage in `maludb_core`, protected by `owner_schema` and RLS. The new work is a schema-local facade, owner-schema audit pass, and missing first-class objects needed for practical memory use.

## Goals

- Provide explicit opt-in schema enablement through `maludb_core.enable_memory_schema(...)`.
- Create schema-local views and helper functions with user-facing names like `maludb_subject`, `maludb_claim`, `maludb_document`, and `maludb_memory_pool`.
- Let schema owners organize memory by subject type, subject, verb, event, tag, project, skill, document, and shared memory pool.
- Support raw ingestion for data that arrived but has not been processed into claims, facts, memories, documents, workflows, or skills.
- Support document/source upload with optional context and later model-detected suggested tags.
- Support compartmentalized vector search by subject, verb, subject+verb, document tags, pool membership, and combinations of those filters.
- Make prompts, LLMs, skills, workflows, MCP/MC2DB objects, and related operational data visible through schema-local objects where they are tenant-owned.
- Add or validate `owner_schema` on every schema-visible object family before exposing it through the facade.

## Non-Goals

- No automatic event trigger on `CREATE SCHEMA`.
- No assumption that every schema wants MALUDB memory objects.
- No caching layer for memory pools in this phase.
- No full automatic tag acceptance. Model-discovered tags remain suggestions until accepted by a user or policy.
- No migration to per-tenant physical tables. Storage remains shared in `maludb_core`.

## Current State

The current extension already uses the right storage pattern for many governed objects:

- Tables such as `malu$claim`, `malu$fact`, `malu$memory`, `malu$source_package`, `malu$svpor_subject`, `malu$svpor_verb`, `malu$active_memory_pool`, `malu$workflow_trace`, and `malu$skill_package` carry `owner_schema name NOT NULL DEFAULT current_schema()`.
- RLS policies commonly use `owner_schema = current_schema()`.
- If a caller uses `SET search_path TO zozocal, maludb_core, public`, existing registration functions write rows owned by `zozocal`.
- No code creates tenant-local views/functions automatically or on demand.
- Several clients and services pin `search_path` to `maludb_core, public`, which makes new rows owned by `maludb_core` instead of the tenant schema.

The implementation must preserve the working owner-schema model while giving users a clear schema-local API.

## Enablement API

Add an idempotent extension function:

```sql
SELECT maludb_core.enable_memory_schema();
SELECT maludb_core.enable_memory_schema('zozocal'::name);
```

Behavior:

- Validate that the target schema exists.
- Validate that the caller owns the schema or has sufficient privilege to create objects in it.
- Create or replace schema-local views and helper functions.
- Avoid destructive changes to user objects. If a conflicting object exists and is not managed by MALUDB, raise a clear error.
- Record enablement metadata in `maludb_core`, including schema name, enabled version, enabled_at, enabled_by, and last_refreshed_at.
- Be safe to rerun after extension upgrades.

Ship an operator-friendly wrapper script that invokes the function:

```bash
psql -d mydb -v schema=zozocal -f sql/enable-memory-schema.sql
```

The script is a convenience wrapper, not the authoritative implementation. The extension function is authoritative.

## Schema-Local Naming

The schema-local surface uses plain, stable names:

```text
maludb_subject_type
maludb_subject
maludb_project
maludb_stakeholder
maludb_system
maludb_service
maludb_document_subject
maludb_verb
maludb_event
maludb_subject_verb
maludb_source_package
maludb_document
maludb_document_tag
maludb_document_suggested_tag
maludb_raw_ingest
maludb_unapplied_ingest
maludb_claim
maludb_fact
maludb_memory
maludb_memory_detail
maludb_embedding_compartment
maludb_embedding_chunk
maludb_memory_pool
maludb_memory_pool_member
maludb_memory_pool_access
maludb_prompt
maludb_prompt_render
maludb_llm_provider
maludb_llm_model
maludb_llm_request
maludb_llm_response
maludb_skill
maludb_skill_state
maludb_skill_transition
maludb_skill_execution
maludb_workflow_trace
maludb_workflow_step
maludb_workflow_candidate
maludb_mcp_server
maludb_mcp_tool
maludb_mcp_prompt
maludb_mcp_resource
maludb_mcp_invocation
```

Views should hide `owner_schema` by default where it adds noise, but advanced/admin views can expose it.

## Owner Schema Audit

Before a core object family becomes schema-visible, it must pass this audit:

- Has `owner_schema name NOT NULL DEFAULT current_schema()` where rows are tenant-owned.
- Has RLS enabled.
- Has policies that bind visibility and writes to `owner_schema = current_schema()` or a justified equivalent.
- Has grants to the relevant MALUDB roles.
- Has tests showing tenant A cannot see tenant B rows unless explicitly granted.
- Has schema-local views created by `enable_memory_schema`.

Some existing tables are global or account-oriented. They must either remain global and not appear in schema-local views, or gain owner-schema semantics in a migration before exposure.

## Subject Organization

Users should not have to think only in generic subjects. The design introduces subject types and typed convenience views.

Subject types are schema-visible taxonomy rows:

```text
project
stakeholder
person
organization
system
service
database
document
incident
decision
concept
unknown
undefined
```

Examples:

```sql
INSERT INTO maludb_project(name, aliases)
VALUES ('zozocal migration', ARRAY['zozocal']);

INSERT INTO maludb_stakeholder(name, aliases)
VALUES ('database operations', ARRAY['dbops']);

SELECT * FROM maludb_subject WHERE subject_type = 'project';
```

Typed views insert into the same core subject registry with the appropriate `subject_type`. The migration will add `subject_type text NOT NULL DEFAULT 'concept'` to the subject registry exposed as `maludb_subject`.

`unknown` and `undefined` are valid subject buckets. They support low-context ingestion and later classification.

## Verbs, Events, And Subject-Verb Compartments

Verbs represent actions, predicates, event classes, or memory-routing dimensions. Users can create verbs directly:

```sql
INSERT INTO maludb_verb(canonical_name, aliases)
VALUES ('incident', ARRAY['outage', 'failure']);
```

`maludb_subject_verb` is the user-facing bridge between memory organization and vector compartments:

```sql
INSERT INTO maludb_subject_verb(
    namespace,
    subject_name,
    verb_name,
    embedding_dim,
    embedding_model,
    distance_metric
)
VALUES ('default', 'postgres_pool', 'incident', 1536, 'text-embedding-model', 'cosine');
```

Under the hood this maps to the existing `malu$vector_subject`, `malu$vector_verb`, and `malu$vector_compartment` path. Subject typing stays on the user-facing subject registry; vector subjects remain the routing names used by compartments.

## Embeddings And Vector Search

The current vector model is:

```text
owner_schema + namespace + subject + verb -> vector compartment -> vector chunks
```

The schema-local design exposes:

```sql
SELECT * FROM maludb_embedding_compartment;
SELECT * FROM maludb_embedding_chunk;
```

Add schema-local search functions:

```sql
SELECT * FROM maludb_vector_search(
    p_namespace => 'default',
    p_subject => 'postgres_pool',
    p_verb => 'incident',
    p_query_embedding => :embedding,
    p_limit => 20
);
```

Search behavior:

- `subject + verb`: search the exact matching compartment.
- `subject only`: search all compartments for that subject and merge top-K.
- `verb only`: search all compartments for that verb and merge top-K.
- `project`, `event`, `document`, or pool filters: first resolve candidate compartments/documents, then search within those candidates.
- No filters: reject by default unless the caller explicitly opts into broad schema search.

This keeps embedding search bounded and explainable.

## Documents And Flexible Tagging

The system ingests more than traditional documents: PDFs, Markdown, emails, chat logs, SMS texts, meeting transcripts, prompt sessions, source control events, observability payloads, and API captures.

A source can have zero or many tags:

- projects
- subjects
- verbs
- events
- stakeholders
- skills
- workflows
- free-form tags

Users can provide as much or as little context as they know.

Minimal upload:

```sql
SELECT maludb_upload_document(
    p_title => 'Meeting transcript',
    p_source_type => 'meeting_transcript',
    p_content_text => '...'
);
```

Rich upload:

```sql
SELECT maludb_upload_document(
    p_title => 'Cutover notes',
    p_source_type => 'document',
    p_content_text => '...',
    p_projects => ARRAY['zozocal migration'],
    p_subjects => ARRAY['postgres_pool', 'api_gateway'],
    p_verbs => ARRAY['risk', 'decision'],
    p_events => ARRAY['cutover_planning']
);
```

Tags have provenance:

```text
provided
suggested
accepted
rejected
```

Model extraction and embedding/pageindex processing can add suggested tags with confidence. Those suggestions become visible in `maludb_document_suggested_tag`.

Document search should prefer cheap relational filters first:

```sql
SELECT *
FROM maludb_document_search(
    p_project => 'zozocal migration',
    p_subject => 'postgres_pool',
    p_verb => 'risk'
);
```

If full-text, pageindex, or vector search is requested, the planner narrows candidates by tags first, then searches chunks or pageindex nodes.

## Raw Ingestion Inbox

Add a raw holding area for automatically captured data that has not been processed.

Use cases:

- coding tool prompts and responses
- MCP calls and tool outputs
- LLM requests and responses
- chat/session transcripts
- emails and SMS messages
- source control events
- observability events
- external API payloads

Schema-local views:

```sql
maludb_raw_ingest
maludb_unapplied_ingest
maludb_ingest_job
maludb_ingest_suggested_tag
maludb_ingest_extraction
```

Example:

```sql
INSERT INTO maludb_raw_ingest(source_type, source_name, payload_jsonb)
VALUES ('prompt_session', 'codex', '{"prompt":"...", "response":"..."}');

SELECT *
FROM maludb_unapplied_ingest
ORDER BY received_at DESC;
```

Raw ingest rows move through states:

```text
received
queued
processing
processed
partially_applied
applied
failed
ignored
```

`maludb_ingest_extraction` records what came out of each raw row:

- document
- source package
- claim
- fact
- memory
- pending claim
- workflow trace
- skill execution
- embedding job
- suggested tag

This lets users see that data arrived even before it has become memory.

## Prompts, LLMs, Skills, Workflows, And MCP

The schema enablement surface must expose tenant-owned operational AI objects:

- prompt templates and renders
- model providers, aliases, registry entries, requests, responses
- skills, skill states, transitions, executions, and execution steps
- workflow traces, workflow steps, workflow clusters, and workflow candidates
- MC2DB/MCP servers, tools, prompts, resources, and invocations

Each object family must pass the owner-schema audit first. If a table is currently global, the implementation must either keep it out of schema-local views or add `owner_schema` before exposing it.

These views support a practical workflow:

```sql
SELECT * FROM maludb_prompt;
SELECT * FROM maludb_llm_response ORDER BY finished_at DESC;
SELECT * FROM maludb_skill;
SELECT * FROM maludb_workflow_candidate WHERE review_status = 'proposed';
SELECT * FROM maludb_mcp_invocation ORDER BY started_at DESC;
```

## Shared Memory Pools

Shared memory pools focus agents and applications on a bounded working set.

A pool is tenant-owned, tagged, optionally shared, and can contain references to:

- subjects
- verbs
- subject-verb compartments
- projects
- documents
- source packages
- claims
- facts
- memories
- workflows
- skills
- MCP servers/tools
- raw observations

Schema-local views:

```sql
maludb_memory_pool
maludb_memory_pool_member
maludb_memory_pool_tag
maludb_memory_pool_access
maludb_pool_subject
maludb_pool_verb
maludb_pool_subject_verb
maludb_pool_skill
maludb_pool_document
maludb_pool_presence
```

Example:

```sql
INSERT INTO maludb_memory_pool(pool_name, description)
VALUES ('zozocal-coding-agent', 'Focused memory for Zozocal development');

INSERT INTO maludb_memory_pool_member(pool_name, member_kind, member_name)
VALUES
  ('zozocal-coding-agent', 'project', 'zozocal'),
  ('zozocal-coding-agent', 'subject', 'database schema'),
  ('zozocal-coding-agent', 'verb', 'migration'),
  ('zozocal-coding-agent', 'skill', 'schema-review');
```

Pool access is explicit:

```text
read
write
manage
execute
```

MCP/API calls can bind to a pool:

```sql
SELECT *
FROM maludb_pool_search(
    p_pool_name => 'zozocal-coding-agent',
    p_query_text => 'schema-local memory views',
    p_limit => 20
);
```

Pool search order:

1. Pool-scoped relational filters.
2. Pool-scoped subject/verb vector compartments.
3. Pool-scoped document/pageindex chunks.
4. Pool-scoped text search over claims, facts, memories, documents, workflows, and skills.
5. Optional fallback outside the pool only when explicitly requested.

Caching is out of scope for this phase. The pool is a scope definition and retrieval filter first.

## Client And Service Search Path

Clients and services that create tenant-owned data must not pin `search_path` to `maludb_core, public` only.

Tenant-aware clients should use:

```sql
SET search_path TO <tenant_schema>, maludb_core, public;
```

Service code that intentionally operates globally may keep a pinned system search path, but any tenant-bound call must set the tenant schema before invoking SECURITY INVOKER functions.

The implementation should update drivers, CLI, service docs, and examples to support a tenant schema option.

## Testing Strategy

Add regression coverage for:

- Enabling a schema creates the expected objects.
- Re-enabling the schema is idempotent.
- A normal schema has no MALUDB objects until enabled.
- `INSERT INTO zozocal.maludb_subject` creates a `zozocal`-owned core row.
- `SELECT * FROM zozocal.maludb_subject` only sees `zozocal` rows.
- Tenant A cannot see tenant B documents, raw ingest rows, pools, skills, prompts, or workflow rows.
- Subject-only, verb-only, and subject+verb vector search resolve the correct compartments.
- Minimal document upload lands in unknown/undefined context.
- Model-suggested tags remain suggestions until accepted.
- `maludb_unapplied_ingest` shows raw data before extraction and stops showing it after accepted outputs exist.
- Pool search only searches pool members unless fallback is explicitly requested.
- MCP/API pool binding uses pool scope before broader retrieval.
- Existing tests that pin `search_path = maludb_core, public` still pass where system behavior is intentional.

## Migration Shape

Implement as a new extension version:

```text
maludb_core--0.71.0--0.72.0.sql
```

Likely migration pieces:

- `malu$enabled_schema` metadata table.
- `enable_memory_schema(name DEFAULT current_schema())`.
- Owner-schema audit fixes for schema-visible object families.
- Missing raw ingest and document tag tables.
- Pool tag/access/member-kind extensions.
- Schema-local view/function generation.
- Grants and comments.
- Regression tests and docs.

The implementation plan should split owner-schema audit and schema-local facade generation into separate tasks so the migration can be reviewed safely.

## Design Decisions

- If the target schema already has an object named like a managed MALUDB facade object, enablement raises an error unless the object is already recorded as MALUDB-managed in `malu$enabled_schema_object`.
- Typed convenience views are always created for the seed subject types listed in this spec. Additional subject types can be queried through `maludb_subject` and can gain custom typed views in a later migration.
- The initial subject type seed list is `project`, `stakeholder`, `person`, `organization`, `system`, `service`, `database`, `document`, `incident`, `decision`, `concept`, `unknown`, and `undefined`.
- Add a first-class `malu$document` table with a foreign key to `malu$source_package`. `source_package` remains the immutable source artifact; `document` is the user-facing source record with title, source kind, lifecycle, and tag/search metadata.
- Global model provider rows stay system-level and are exposed read-only through schema-local views. Tenant-owned model aliases, model registry rows, requests, responses, prompts, skills, workflows, MC2DB/MCP servers, tools, prompts, resources, and invocations must carry `owner_schema` before they are writable through schema-local views.
- Pool membership is stored as canonical `member_kind`, `member_object_type`, and `member_object_id`. Schema-local insert helpers and updatable views resolve friendly names such as project, subject, verb, skill, and document into object IDs before writing pool members.
