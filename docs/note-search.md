# Note retrieval by subject/verb (0.98.0)

Notes ingested through the memory pipeline ("Install Ubuntu 24.04 Server in
the Chicago Datacenter on June 11, 2026") decompose into graph subjects,
verbs, and SVO statements. 0.98.0 walks that graph back to the source
documents: **give me the notes whose extracted edges mention `ubuntu` and an
install-like verb**.

The stack has three layers:

| Layer | Repo | Role |
|---|---|---|
| `maludb_core` 0.98.0 | this repo | `maludb_note_search` + `maludb_note_query_parse` tenant facades |
| API server | `maludb-python-api-server` | `GET /v1/memory/notes`, LLM fallback for verbless free text |
| `maludb` CLI | `maludb-terminal` | `maludb get note` |

All search logic lives in the core facade so every API server (python, lamp,
fastify) stays a thin wrapper.

## maludb_note_search

```sql
SELECT * FROM maludb_note_search(
    p_subject_like => ARRAY['ubuntu'],   -- ILIKE patterns, OR-any
    p_verb_like    => 'installation',    -- fuzzy verb match
    p_verb_exact   => NULL,              -- exact canonical/alias match (wins over like)
    p_source_type  => 'note',            -- default scope
    p_all_sources  => false,             -- widen to every document kind
    p_limit        => 20,
    p_offset       => 0);
```

Returns one row **per document** (`LIMIT` means notes, not edges):
`document_id, title, source_type, snippet, created_at, match_count,
matched_edges` — `matched_edges` is a jsonb array of
`{statement_id, subject_name, verb_name, object_name, confidence,
match_via, matched_endpoint}`.

Matching rules:

- **Subjects** match `canonical_name` or any alias with `ILIKE '%pat%'`,
  against **both** statement endpoints — the ingest-edge rail writes
  `document --verb--> subject`, so the entity you search for is usually the
  *object* of the statement.
- **`p_verb_like`** is bidirectional containment: the verb name (or an
  alias) contains the query, **or the query contains the verb name** — so
  `'installation'` finds the verb `'install'`. Known limit: dropped-`e`
  gerunds (`'upgrading'` does not contain `'upgrade'`) need a verb alias or
  the server-side LLM fallback.
- **`p_verb_exact`** matches the canonical name or an alias
  case-insensitively, nothing else.
- Documents are reached over **both rails**: statements whose endpoint kind
  is `'document'` (the `$source` anchor used by
  `maludb_memory_ingest_extraction`), and the `malu$vector_chunk`
  `statement_id`/`document_id` soft ref stamped by embedded
  `maludb_memory_ingest_edge` calls.

Read-only: `maludb_memory_admin`, `maludb_memory_executor`, and
`maludb_memory_auditor` all have EXECUTE.

## maludb_note_query_parse

The deterministic half of free-text search (`maludb get note "Install
Ubuntu"`):

```sql
SELECT maludb_note_query_parse('Install Ubuntu');
-- {"verb": "install", "verb_id": 42, "matched_token": "install",
--  "subject_tokens": ["ubuntu"], "tokens": ["install", "ubuntu"]}
```

Tokenizes the query, drops a small stopword set, and scores tokens against
the tenant verb catalog: exact canonical/alias match beats containment, and
containment requires a 4+ character token (`'in'` never claims
`'install'`). The winning token becomes the verb filter; the leftover
tokens become subject patterns. Verbless queries return `verb: null` — the
API server may then fall back to a per-user LLM parse (`query_parse` task);
the database never calls a model.

## Upgrade

```sql
ALTER EXTENSION maludb_core UPDATE TO '0.98.0';
SELECT * FROM enable_memory_schema('<tenant>');  -- object_count 149 -> 151
```

Caveat for pre-0.98.0 data: API servers used to ingest CLI notes with
`source_type = 'document'`, so older notes only surface with
`p_all_sources => true` until backfilled.
