# Build: document/transcript → SVPO-extraction → vector-memory API (MaluDB 0.90.0)

> Hand-off prompt for the API coding agent. Deployed DB is maludb_core **0.90.0** on `zozocal`.
> **Decision: app-side model config + API-held token.** The in-DB model gateway is deployed but
> deliberately unused — `register_model_provider`/`register_model_alias` and secret resolution
> (`__secret_resolve`) are owner-only, so the gateway cannot back a self-service config endpoint
> nor hand the API the token. Also: `accepted` provenance, `document` source_type + advisory
> `document_type`, and a stub extractor/embedder for offline tests.

## Architecture (hard constraints — verified against the live DB)
- MaluDB is a PostgreSQL extension; persistence + search are **SQL function calls**.
- PostgreSQL **cannot make outbound HTTP calls**, so the **API server is the model worker**:
  your code calls the LLM and the embedding model, then writes results back via SQL.
- **Model config + auth token live in THIS API**, not in the DB. The in-DB gateway IS deployed
  (0.90.0) but `register_model_provider/alias` + `__secret_resolve` are owner-only, so config is
  app-side and the token stays in the API's own secret manager/env (never resolved DB-side).
- Embedding is **per-extracted-edge** and bound to a `(subject, verb)` compartment via
  `maludb_memory_ingest_edge`; `maludb_memory_search` pre-filters by subject/verb before the
  ANN. There is no separate generic chunk-vector store on this path — do not assume one.

## Connection, tenancy, roles
- A tenant = a PostgreSQL **schema** already initialized with `enable_memory_schema`.
- On every connection: `SET search_path = "<tenant_schema>", maludb_core, public;` then call
  the tenant facades unqualified (`maludb_upload_document`, `maludb_memory_ingest_edge`,
  `maludb_memory_search`).
- DB role: `zozocal` = `maludb_memory_executor` + `maludb_memory_reader` + `maludb_read`
  (write + search). **Do not** rely on `register_model_*` / `__secret_resolve` (owner-only) or
  the in-DB gateway facades (`maludb_memory_set_model_config`, `*_request_extraction`,
  `*_harvest_extractions`) — present on 0.90.0 but out of scope by decision.
- **Verify the exact live signatures before coding** (versions drift):
  `\df maludb_core.upload_document`, `\df <schema>.maludb_memory_ingest_edge`,
  `\df <schema>.maludb_memory_search`. Confirm `maludb_upload_document` has a `p_document_type`
  argument. Map SQL errors → HTTP: `invalid_parameter_value`→400, `foreign_key_violation`→404/409,
  `insufficient_privilege`→403.

## Vector format
Pass embeddings as `'[0.0123,-0.044,...]'::maludb_core.malu_vector`. **One embedding model +
fixed dimension per namespace** — record the model name on every ingest, and embed the search
query with the *same* model.

---

## A. Model config (app-side; no DB)
Store per-tenant (or per-namespace): provider kind, **LLM base_url**, **model id**, generation
params (e.g. temperature 0), embedding model + dimension, and the **auth token** (in your secret
manager — never in DB rows or logs). Expose simple CRUD in your API. This is ordinary app config;
MaluDB is not involved.

## B. Process a document/transcript
### B1. Upload → `document_id`
```sql
SELECT maludb_upload_document(
  p_title         => :title,
  p_content_text  => :raw_text,
  p_source_type   => 'document',          -- MUST be a seeded value; 'document' is valid
  p_media_type    => :media_type,
  p_metadata_jsonb=> :metadata_jsonb,
  p_document_type => :doc_type)            -- advisory free-text: 'transcript','meeting',...
  AS document_id;
```
### B2. Chunk `raw_text` **in code** (DB does not chunk)
Token/sentence-bounded chunks with overlap; keep each chunk's verbatim text.

### B3. Extract edges **in code** via the Extractor interface (see §D)
Per chunk, call the LLM with your prompt; require this JSON contract:
```json
{"candidate_edges":[
  {"subject_text":"Oracle 21c","subject_type":"software","verb_text":"upgrade",
   "predicate":[{"attr_name":"status","value_text":"completed"},
                {"attr_name":"event_at","value_timestamp":"2026-03-30T23:00:00-05:00"}],
   "source_span":"<verbatim span>","confidence":0.94}]}
```
Rules to bake into the prompt: **small canonical verbs** (`upgrade`, not `performed_upgrade`);
status/timing/role/detail go into `predicate` edge-attributes
(`value_text`/`value_timestamp`/`value_numeric`); `subject_type` free text, prefer
`person|software|project|...`.

### B4. Embed each edge **in code** via the Embedder interface (§D)
Embed each edge's `source_span` (fallback: the chunk) with the configured embedding model.

### B5. Ingest each edge → `statement_id`
```sql
SELECT maludb_memory_ingest_edge(
  p_source_kind      => 'document',
  p_source_id        => :document_id,
  p_subject_text     => :subject_text,
  p_verb_text        => :verb_text,
  p_predicate        => :predicate_jsonb_array,
  p_embedding        => :embedding_vector,     -- '[...]'::maludb_core.malu_vector
  p_embedding_model  => :embedding_model,
  p_subject_type     => :subject_type,
  p_source_span      => :source_span,
  p_confidence       => :confidence,
  p_provenance       => 'accepted',            -- trust the extractor (per decision)
  p_extraction_model => :model_id,
  p_namespace        => 'default',
  p_document_id      => :document_id) AS statement_id;
```
One call per edge; resolves/creates subject + verb, writes the SVPO statement, attaches predicate
items as typed edge-attributes, and places the embedding in the `(subject,verb)` compartment.
Wrap a document's edges in one transaction.

## C. Search
Embed the query string with the **same** embedding model, then:
```sql
SELECT * FROM maludb_memory_search(
  p_query_embedding => :query_vector,    -- '[...]'::maludb_core.malu_vector
  p_subject         => :subject_or_null, -- optional pre-filter
  p_verb            => :verb_or_null,     -- optional pre-filter
  p_namespace       => 'default',
  p_limit           => 20,
  p_metric          => 'cosine');
-- returns: chunk_id, statement_id, document_id, source_text, distance, similarity,
--          rank_no, subject_name, verb_name
```

## D. Extractor/Embedder interfaces + stub (testing)
Define two interfaces and inject them:
- `Extractor.extract(chunk_text, config) -> candidate_edges[]`
- `Embedder.embed(text, config) -> float[]`

Ship a **deterministic stub** for both (no network): the stub returns 1–2 fixed edges per chunk
(e.g. derived from keywords) and a fixed-dimension vector (e.g. a hashed/one-hot vector). This
makes upload→ingest→search testable offline/CI. The real LLM/embedding clients are alternate
implementations selected by config. (Mirrors how MaluDB's own acceptance test simulated the model.)

## Acceptance smoke test (with the stub)
Configure stub mode → upload a transcript (`source_type='document'`, `document_type='transcript'`)
→ run the pipeline → assert ≥1 `statement_id` returned → embed a query and assert
`maludb_memory_search` returns that edge, with subject/verb pre-filter narrowing results.

## Out of scope / don't
- Don't write to `malu$*` tables directly — only the `maludb_*` functions above.
- Don't store the token in MaluDB (you can't read it back) or log it.
- Don't assume the DB chunks text, calls the model, or embeds — all three are the API's job.
- The in-DB model gateway, async queue + harvest, and DB secret resolution are present on
  0.90.0 but **out of scope by decision** — config/token are app-side; provider/alias
  registration + secret resolution are owner-only. Do not build against them.
