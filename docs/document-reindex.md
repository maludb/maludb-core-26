# Document/note reindex protocol (0.100.0)

A document's (or note's) SVPOR extraction — the subjects, verbs, and SVO
statements `maludb_memory_ingest_extraction` minted from its text — is written
once, at ingest, from whatever the API server's extractor produced. It rots
the same two ways a skill's discovery tags do (see
[skill-reindex.md](skill-reindex.md)):

1. **The graph grows.** New subjects/verbs are minted after a document was
   ingested, so an old document never links to vocabulary that didn't exist
   when it was indexed.
2. **The first extraction was weak.** A poor first pass freezes a thin or
   wrong graph in place, degrading `note_search` and graph traversal.

0.100.0 ships the **database half** of a background reindex that re-derives a
document's graph footprint against the *current* graph — the documents/notes
analogue of the 0.99.0 skill reindex. As everywhere in MaluDB, **core never
calls a model**; it exposes a `claim → apply` contract an external worker drives.

| Layer | Repo | Role |
|---|---|---|
| `maludb_core` 0.100.0 | this repo | `last_indexed` watermark, `maludb_memory_reindex_claim`, `maludb_memory_reindex_apply` |
| reindex worker | `maludb-python-api-server` | poll → re-extract with a model → apply (**not yet built — Phase 1 PR 2**) |
| embedding worker | `maludb-python-api-server` | drains the 0.95.0 entity-card queue (**not yet built — Phase 2**) |

## What core added

`malu$document` gains `last_indexed` / `last_indexed_model` (the watermark that
stops repeat work + the hook for migrating to a cheaper model later), mirroring
`malu$skill_package`.

## The worker loop

```text
loop:
    rows = maludb_memory_reindex_claim(limit := 32, max_age := '30 days', source_types := NULL)
    if not rows: sleep(backoff); continue
    for r in rows:
        extraction = model.extract(r.content_text, current_registry)   # worker side
        maludb_memory_reindex_apply(r.document_id, extraction, MODEL_ID)
```

### `maludb_memory_reindex_claim(p_limit, p_max_age, p_source_types)`
Read-only (auditor has EXECUTE). Returns the stalest documents first with the
stored text the worker needs to re-extract:
`document_id, source_type, title, media_type, document_type, content_text,
last_indexed, last_indexed_model`.

A row is claimed when it is not archived/tombstoned, has non-empty
`content_text`, optionally matches `p_source_types` (e.g. `ARRAY['note']`), and
any of: `last_indexed IS NULL`, `last_indexed < now() - p_max_age`, or
`last_indexed <` the **registry watermark** — `max(created_at)` over this
tenant's `malu$svpor_subject` / `malu$svpor_verb` (the "subjects added later"
signal). Plain ranked scan; no queue, no locks.

### `maludb_memory_reindex_apply(p_document_id, p_extraction, p_model)`
A write (executor; **curator-only in `maludb_public`**). In one transaction:

1. **Replace the footprint** — delete the document's `$source`-anchored
   statements (those with the document as an endpoint, `subject_kind`/
   `object_kind = 'document'`). Shared subjects/verbs are **never** deleted.
2. **Re-ingest** the extraction with the `document` section **stripped** and
   `p_source_kind='document'`, `p_source_id=<this document>` — so every
   `$source` edge re-links to the existing document (no duplicate document is
   created). This is safe because `_memory_ingest_extraction_for_schema` is
   idempotent on re-run: subjects/verbs upsert by `canonical_name`, statements
   upsert by their `(subject,verb,object)` identity, attributes upsert by
   `attr_name`, and relationship inserts are caught per-row.
3. **Stamp** `last_indexed` / `last_indexed_model`.

Returns `{document_id, source_type, last_indexed_model, statements_replaced, ingest}`.

**Embeddings refresh for free**: the replaced statements and merged subjects fire
the 0.95.0 `malu$embedding_dirty` triggers, queuing the affected entity cards.
What actually re-embeds them is the embedding worker (Phase 2) — until it runs,
the cards sit queued; nothing breaks.

## Limitations (v1)
- **Footprint is `$source`-anchored.** Subject↔subject edges and relationships
  aren't individually attributable to a document, so they *merge/refresh* on
  re-ingest rather than being replaced. The extractor anchors the bulk of a
  document's edges to `$source`, so this covers the common case.
- **Chunked-ingest documents** (the `POST /v1/memory/documents` path, which
  chunks text and embeds per edge) are re-indexed here only via the
  full-extraction footprint; re-chunking + per-edge re-embedding is a later
  phase.
- **No model is called by core.** Re-extraction and embedding both live in the
  external worker(s).
