# SVPOR — Entity-Relationship Diagrams

> Source of truth: `sql/extension/maludb_core--0.83.0.sql` (full install script).
> The `malu$` prefix is dropped from entity names for readability; all storage
> tables live in `maludb_core`. Facade views/functions are created per-tenant
> inside each memory-enabled user schema by `enable_memory_schema(...)`.

**Line legend (both diagrams)**

- **Solid line** = DB-enforced FOREIGN KEY.
- **Dashed line** = soft reference with NO DB-level FK — either a polymorphic
  `(kind, id)` pointer (validated only in the write facades) or a view→table proxy.

---

## 1. Storage model (`malu$svpor_*` and supporting tables)

```mermaid
erDiagram
    %% ---------- triple vocabularies (the S, V, P of SVPOR) ----------
    svpor_subject {
        bigint  subject_id PK
        name    owner_schema
        text    canonical_name
        text    aliases "text[]"
        text    subject_type FK
        text    description
    }
    svpor_verb {
        bigint  verb_id PK
        name    owner_schema
        text    canonical_name
        text    aliases "text[]"
        text    verb_type FK
        text    search_phrases "text[]"
        text    description
    }
    svpor_predicate {
        bigint  predicate_id PK
        name    owner_schema
        text    canonical_name
        text    aliases "text[]"
        text    description
    }

    %% ---------- advisory type pickers ----------
    svpor_subject_type {
        text    subject_type PK
        text    display_name
        int     sort_order
        bool    system_defined
    }
    svpor_verb_type {
        text    verb_type PK
        text    display_name
        text    semantic_class
        int     sort_order
    }

    %% ---------- the polymorphic SVO assertion bridge ----------
    svpor_statement {
        bigint      statement_id PK
        name        owner_schema
        text        subject_kind "poly"
        bigint      subject_id   "poly"
        bigint      verb_id FK
        text        object_kind  "poly"
        bigint      object_id    "poly"
        bigint      predicate_id FK
        timestamptz valid_from
        timestamptz valid_to
        numeric     confidence
        text        provenance "provided|suggested|accepted|rejected"
        bigint      source_package_id FK
    }

    %% ---------- attribute store (nodes AND edges) + template ----------
    svpor_attribute {
        bigint      attribute_id PK
        name        owner_schema
        text        target_kind "poly (incl. svpor_statement)"
        bigint      target_id   "poly"
        text        attr_name
        timestamptz value_timestamp
        tstzrange   value_range
        numeric     value_numeric
        text        value_text
        jsonb       value_jsonb
        text        provenance
        numeric     confidence
    }
    attribute_template {
        bigint  template_id PK
        name    owner_schema
        text    applies_to "subject_type|verb|document_type|episode_type"
        text    type_value
        text    attr_name
        text    value_type
        text    requirement
    }

    %% ---------- subject-to-subject relationship layer ----------
    svpor_relationship_type {
        name    owner_schema PK
        text    relationship_type PK
        text    inverse_relationship_type FK
    }
    svpor_subject_relationship {
        name    owner_schema PK
        bigint  subject_a_id PK "FK, a<b"
        bigint  subject_b_id PK "FK"
        text    label
    }
    svpor_subject_relationship_edge {
        name        owner_schema PK
        bigint      edge_id PK
        bigint      from_subject_id FK
        bigint      to_subject_id FK
        text        relationship_type FK
        timestamptz valid_from
        timestamptz valid_to
        tstzrange   valid_range "generated"
    }

    %% ---------- LLM-staged hint (transcript -> suggested frames) ----------
    document_svpor_hint {
        bigint  hint_id PK
        bigint  document_id FK
        bigint  project_subject_id FK
        bigint  subject_id FK
        bigint  verb_id FK
        text    provenance
        numeric confidence
    }

    %% ---------- abstraction: the polymorphic (kind,id) target set ----------
    polymorphic_target {
        text kind "subject | verb | document"
        text _    "episode_object | memory | source_package"
        text __   "claim | fact | memory_detail_object"
    }

    %% ===== enforced foreign keys (solid) =====
    svpor_subject_type ||--o{ svpor_subject : "subject_type"
    svpor_verb_type    ||--o{ svpor_verb    : "verb_type"

    svpor_verb      ||--o{ svpor_statement : "verb_id (the V)"
    svpor_predicate |o--o{ svpor_statement : "predicate_id (the P)"

    svpor_subject ||--o{ svpor_subject_relationship : "subject_a_id"
    svpor_subject ||--o{ svpor_subject_relationship : "subject_b_id"

    svpor_relationship_type ||--o{ svpor_subject_relationship_edge : "relationship_type"
    svpor_subject           ||--o{ svpor_subject_relationship_edge : "from_subject_id"
    svpor_subject           ||--o{ svpor_subject_relationship_edge : "to_subject_id"
    svpor_relationship_type |o--o{ svpor_relationship_type         : "inverse_of"

    svpor_subject ||--o{ document_svpor_hint : "subject / project_subject"
    svpor_verb    ||--o{ document_svpor_hint : "verb_id"

    %% ===== polymorphic (kind,id) soft references — NO db-level FK (dashed) =====
    polymorphic_target ||..o{ svpor_statement : "subject (kind,id)"
    polymorphic_target ||..o{ svpor_statement : "object (kind,id)"
    polymorphic_target ||..o{ svpor_attribute : "target (kind,id)"
    svpor_statement    ||..o{ svpor_attribute : "edge attributes (target_kind='svpor_statement')"
    svpor_subject_type |o..o{ attribute_template : "applies_to/type_value (advisory)"
```

### Notes (storage)

- **V is always a hard FK** (`verb_id → svpor_verb`); **S and O are polymorphic**;
  **P is an optional FK** (`predicate_id → svpor_predicate`). That asymmetry is the
  core of the `svpor_statement` bridge.
- `polymorphic_target` is **not a table** — it abstracts the allowed `*_kind`
  vocabulary: `subject, verb, document, episode_object, memory, source_package,
  claim, fact, memory_detail_object`. Because `subject`/`verb` are valid kinds, a
  statement can point back at the vocab tables.
- `svpor_attribute.target_kind` also accepts `'svpor_statement'`, so attributes
  attach to **edges** as well as nodes.
- `subject_type`/`verb_type` are FK-enforced against the pickers (defaults
  `'concept'`/`'other'`); `attribute_template` matches them by **advisory text**
  (`type_value`), not FK.
- `svpor_subject_relationship` is the *undirected* pair (with a
  `subject_a_id < subject_b_id` constraint); `svpor_subject_relationship_edge` is
  the *directed, typed, valid-time* subject↔subject edge.

---

## 2. Facade layer (`maludb_*` views) → storage

Per-tenant `security_invoker` views, scoped `WHERE owner_schema = current_schema()`.
Four are **writable** 1:1 passthroughs (`WITH LOCAL CHECK OPTION`, paired with
`*_create` / `*_delete` functions); `maludb_svpor_relationship` is **read-only**
and is a *slice of the unified graph*, not of `svpor_subject_relationship_edge`.

```mermaid
erDiagram
    %% ---------- facade views (public per-schema API) ----------
    maludb_svpor_statement {
        bigint  statement_id
        text    subject_kind
        bigint  subject_id
        bigint  verb_id
        text    object_kind
        bigint  object_id
        bigint  predicate_id
        text    provenance
        numeric confidence
    }
    maludb_svpor_attribute {
        bigint  attribute_id
        text    target_kind
        bigint  target_id
        text    attr_name
        text    provenance
        numeric confidence
    }
    maludb_attribute_template {
        bigint  template_id
        text    applies_to
        text    type_value
        text    attr_name
        text    value_type
        text    requirement
    }
    maludb_svpor_relationship {
        bigint  edge_id
        text    source_kind
        bigint  source_id
        text    source_name
        text    relationship_type
        text    target_kind
        bigint  target_id
        text    target_name
    }
    maludb_document_svpor_hint {
        bigint  hint_id
        bigint  document_id
        bigint  project_subject_id
        bigint  subject_id
        bigint  verb_id
        text    provenance
    }

    %% ---------- backing storage ----------
    svpor_statement {
        bigint statement_id PK
    }
    svpor_attribute {
        bigint attribute_id PK
    }
    attribute_template {
        bigint template_id PK
    }
    document_svpor_hint {
        bigint hint_id PK
    }
    relationship_edge {
        bigint edge_id PK
        name   owner_schema
        text   relationship_type FK
        text   source_object_type "subject|verb|... governed"
        bigint source_object_id
        text   target_object_type "subject|verb|... governed"
        bigint target_object_id
        numeric confidence
    }
    relationship_type {
        text relationship_type PK
        text inverse_of FK
    }
    svpor_subject {
        bigint subject_id PK
    }
    svpor_verb {
        bigint verb_id PK
    }

    %% ===== view proxies its backing table (dashed) =====
    maludb_svpor_statement     ||..|| svpor_statement     : "writable passthrough"
    maludb_svpor_attribute     ||..|| svpor_attribute     : "writable passthrough"
    maludb_attribute_template  ||..|| attribute_template  : "writable passthrough"
    maludb_document_svpor_hint ||..|| document_svpor_hint : "writable passthrough"
    maludb_svpor_relationship  ||..o{ relationship_edge   : "read-only, subject/verb endpoints"
    maludb_svpor_relationship  }o..o{ svpor_subject       : "join -> source/target_name"
    maludb_svpor_relationship  }o..o{ svpor_verb          : "join -> source/target_name"

    %% ===== unified graph's own enforced FK (solid) =====
    relationship_type ||--o{ relationship_edge : "relationship_type"
    relationship_type |o--o{ relationship_type : "inverse_of"
```

### Notes (facades)

- **`maludb_svpor_statement`** → `malu$svpor_statement`. Writers:
  `maludb_svpor_statement_create / _close / _delete / _set_provenance`.
- **`maludb_svpor_attribute`** → `malu$svpor_attribute`. Writers:
  `maludb_svpor_attribute_create / _delete` (create is an upsert on
  `(target_kind, target_id, attr_name)`).
- **`maludb_attribute_template`** → `malu$attribute_template` (advisory catalog).
- **`maludb_document_svpor_hint`** → `malu$document_svpor_hint` (LLM-staged
  `provided|suggested|accepted|rejected` frames awaiting promotion to statements).
- **`maludb_svpor_relationship`** → a **read-only** view over the *unified*
  `malu$relationship_edge` graph, filtered to `source/target_object_type IN
  ('subject','verb')` and LEFT-JOINed to `svpor_subject` / `svpor_verb` to resolve
  `source_name` / `target_name`. Writes go through the
  `maludb_svpor_relationship_create` **function** (which inserts into
  `relationship_edge`), not through the view. Note its `relationship_type` FK is the
  **global** `malu$relationship_type` vocab — distinct from the per-schema
  `malu$svpor_relationship_type` used by `svpor_subject_relationship_edge` in
  diagram 1.
