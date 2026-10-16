# Sub-agent task: close the "documents aren't in the graph" gap in maludb_core

## Your role

You are working in the git repo at `/home/maludb/maludb-public`, a PostgreSQL
extension called **maludb_core** (a memory/knowledge-graph engine). The current
installed `default_version` is **0.86.1**
(`sql/extension/maludb_core--0.86.1.sql`). Deliver in **two phases**:

1. **PROPOSE** — write a short design proposal (options + a recommendation +
   tradeoffs). Stop and surface it. Do **not** write SQL yet.
2. **IMPLEMENT** — only after the proposal is accepted, build it as a new
   version delta with tests.

Treat the install script as ground truth; if anything below disagrees with the
DDL, the DDL wins and you should flag it.

---

## The gap (what to fix)

maludb_core models relationships as a **typed property graph**. There are two
edge stores, unified by the view `maludb_core.malu$edge_unified` and traversed by
`maludb_graph_neighbors` / `maludb_graph_walk` / the `maludb_edge` view:

- `malu$svpor_statement` — verb-typed SVO edges (subject→verb→object), e.g.
  `Ed —develops→ MIST`, `Sprint —part_of→ MIST`.
- `malu$relationship_edge` — the lineage edge graph.

**A document does NOT join the graph the way every other object does.** When you
upload a requirements doc with `maludb_upload_document(..., p_projects =>
ARRAY['MIST'])`, the project relationship is recorded only as a **soft text tag**
in `malu$document_tag` (`tag_kind='project'`, `tag_value='MIST'` — a *string*,
not a subject id). Consequences, all verified live:

- `malu$document.primary_project_id` (a real FK to `malu$svpor_subject`) is left
  **NULL** — `upload_document` never resolves the name to a subject id.
- No `malu$svpor_statement` edge is created for the document.
- Therefore the document is **invisible to `graph_walk` / `graph_neighbors` /
  `maludb_edge`** — you cannot traverse from MIST to its requirements doc, even
  though you can traverse from MIST to its people, sprints, tasks, and meetings.

This is the inconsistency to remove: **a document should be reachable from its
project (and other subjects) through the unified graph, efficiently**, the same
way an episode or person is.

---

## Verified facts (use these; don't re-derive)

**`malu$document`** (facade `maludb_document`): columns include `document_id`,
`owner_schema`, `source_package_id`, `title`, `source_type`, `document_type`,
**`primary_project_id`** (FK → `malu$svpor_subject(subject_id)`, `ON DELETE SET
NULL`, currently never populated by upload), `lifecycle_state`, `metadata_jsonb`.
Content lives out in `malu$source_package` / `malu$source_content`.

**`malu$document_tag`** — the soft link table. Columns:
`tag_id, owner_schema, document_id, tag_kind, tag_value,`
**`tag_object_type`, `tag_object_id`** (both nullable, **currently always NULL**),
`provenance, confidence, metadata_jsonb, created_at`.
- `tag_kind` CHECK: `project, subject, verb, event, stakeholder, skill, workflow,
  freeform, document_type`.
- `provenance` CHECK: `provided, suggested, accepted, rejected`.
- UNIQUE `(document_id, tag_kind, tag_value, provenance)`; lookup index
  `(owner_schema, tag_kind, tag_value)`.
- **Note the latent design:** `tag_object_type` / `tag_object_id` are an
  already-present structural pointer the upload path never fills in. That is
  likely the cleanest hook — a tag that resolves to a real `(kind,id)` could be
  promoted into / unioned as a graph edge.

**Statement endpoints already allow documents.** The `malu$svpor_statement` table
CHECK accepts `subject_kind`/`object_kind` IN `('subject','verb','document',
'episode_object','memory','source_package','claim','fact',
'memory_detail_object')`, and `_svpor_statement_assert_endpoint` has a working
`WHEN 'document'` branch. So `document —verb→ subject(MIST)` is a legal statement
**today** — nothing structural blocks it; the upload path just doesn't create it.
(In the MIST e2e test, meeting *minutes* are linked exactly this way:
`document —generated_by→ episode_object`.)

**Verb vocabulary.** `documented` exists as a seeded verb **type**
(`malu$svpor_verb_type`, semantic_class `documentation`) but there is **no seeded
verb** for "this document describes/documents X". Only `attended`,
`generated_by`, `made_during` ship as seeded verbs. (Recurring gotcha: a verb
*type* is not a verb. A new verb must be registered, or seeded by this change.)

**`malu$edge_unified`** is a plain `UNION ALL` of two SELECTs — one over
`malu$svpor_statement` (`edge_store='svpor_statement'`), one over
`malu$relationship_edge` (`edge_store='relationship_edge'`), projecting
`(edge_store, edge_id, source_kind, source_id, rel, target_kind, target_id,
confidence, provenance)`, filtered `WHERE owner_schema=...`. Adding a third
member to this union is a viable design lever.

**`malu$document_svpor_hint`** already implements a "suggested frames awaiting
promotion to statements" pattern (provenance `provided|suggested|accepted|
rejected`) — precedent for a promotion-style solution if you go that way.

---

## Candidate approaches (evaluate these; propose your own if better)

1. **Upload creates a real statement.** When `p_projects`/`p_subjects` resolve to
   an existing subject, also insert `document —<verb>→ subject` into
   `malu$svpor_statement` (plus keep the soft tag for *unresolved* names). Needs a
   verb — seed one (e.g. `documents`/`describes`, or reuse the `documented` type).
   Pro: documents become first-class graph edges, zero traversal changes. Con:
   name→id resolution policy (what if 0 or >1 subjects match? what provenance?).

2. **Promote the latent tag columns + union them into the graph.** Populate
   `tag_object_type`/`tag_object_id` on upload when the name resolves, and add a
   third `UNION ALL` member to `malu$edge_unified` that surfaces resolvable
   document tags as edges (`edge_store='document_tag'`). Pro: reuses existing
   columns, no new statement rows, keeps soft + structural in one place. Con:
   widens the unified-edge contract; dedup vs. approach 1.

3. **Populate `primary_project_id` + surface it.** Resolve the first project name
   to its subject id, set the FK, and union "document→primary_project" into the
   graph. Pro: smallest write. Con: only one project, doesn't generalize to
   subjects/events.

4. **Explicit promotion function.** A `maludb_document_link(document_id,
   target_kind, target_id, verb)` (and/or a tag→statement promoter mirroring the
   svpor_hint flow). Pro: explicit, no magic in upload. Con: extra step; doesn't
   fix existing/default uploads.

A hybrid is likely best (e.g. upload resolves names → statements when
unambiguous, falls back to soft tag when not; traversal then "just works").
Your proposal should pick one and justify it.

## Hard requirements / conventions the solution MUST follow

- **Ship as a new version delta**, do not edit `maludb_core--0.86.1.sql`. Create
  `sql/extension/maludb_core--0.86.1--0.87.0.sql` (header line:
  `\echo Use "ALTER EXTENSION maludb_core UPDATE TO '0.87.0'" to load this file. \quit`),
  bump `default_version` in `maludb_core.control`, bump the
  `maludb_core_version()` function return, add the file to `DATA` in the
  `Makefile`, and add a `CHANGELOG.md` entry. (Check how 0.86.0→0.86.1 did all of
  this and mirror it exactly.)
- **Idempotent & re-enable-safe.** Anything created per-tenant must be (re)created
  by `enable_memory_schema`; existing schemas pick up the change by re-running it.
  Seeds use `ON CONFLICT DO NOTHING`. Watch the known re-enable hazard (0.86.1
  itself was a fix for a view that couldn't be re-widened — don't reintroduce
  that class of bug).
- **Respect the soft-picker philosophy.** Names that don't resolve must NOT hard-
  fail an upload; fall back to the existing soft tag. No new hard FK that would
  reject a free-text project name.
- **RLS / tenancy.** Everything is `owner_schema`-scoped with RLS; new rows set
  `owner_schema`, new reads filter by it. Facades are `security_invoker` views /
  `SET search_path` functions granted to `maludb_memory_admin/_executor`
  (`_auditor` for read).
- **Backward compatible.** Don't change existing function signatures; add
  optional args (DEFAULT) or new functions. Existing positional callers of
  `upload_document` must keep working.
- **Provenance-aware** (agent-ready): derived/auto-resolved links should carry a
  provenance marker consistent with the rest of the model.

## How to test (a harness already exists)

A working end-to-end fixture is in `examples/mist-e2e/`:
`00-bootstrap-0.86.1.sh` builds a throwaway DB `mist_e2e` at 0.86.1 (server ships
0.82.0, so it creates the extension then applies delta scripts — extend this to
apply your 0.87.0 delta too); `01-part1.sql` + `02-part2.sql` load the MIST
project, people, sprints, tasks, and a meeting-minutes document. psql binaries are
under `/usr/lib/postgresql/17/bin`; server on `:5432`; no passwordless sudo and
the PG sharedir is root-owned, so do **not** `make install` — apply deltas by
piping the delta SQL (minus its `\quit` guard) into `psql -d mist_e2e`.

Your acceptance test must demonstrate: after uploading a requirements document
for project **MIST** (`maludb_upload_document(..., p_projects => ARRAY['MIST'])`),
a `maludb_graph_walk` / `maludb_graph_neighbors` from the MIST subject **reaches
that document** (and `maludb_edge` shows the edge), while an upload naming a
*non-existent* project still succeeds and still records the soft tag. Also confirm
re-running `enable_memory_schema` on an already-enabled schema stays clean.

## Deliverables

- **Phase 1:** a proposal (chosen approach, why, the verb/resolution/provenance
  decisions, what `enable_memory_schema` and `malu$edge_unified` changes are
  needed, and the migration/version-bump checklist). Surface it; wait.
- **Phase 2 (after approval):** the 0.87.0 delta + control/version/Makefile/
  CHANGELOG bumps + an acceptance SQL script under `examples/mist-e2e/` proving
  the document is now graph-reachable, with the live psql output captured.
