# MaluDB Front-End Template — PHP + Bootstrap 5 + HTMX (Direct PDO)

A starter template for building server-driven web front-ends on top of **MaluDB**, using **PHP** on the back end, **Bootstrap 5** for responsive component-based UI, and **HTMX** for dynamic, partial-page interactivity.

This template connects to MaluDB **directly over the PostgreSQL wire protocol using PHP's PDO driver** (`ext-pdo` + `ext-pdo_pgsql`) — it calls MaluDB's SQL / PL-pgSQL functions in-database. There is **no REST/API layer** in this template. (A separate sibling template targets the same UI stack but connects through the `maludb-restd` HTTP API instead — use that one when your front end can't open a direct database connection.)

Screens that browse, search, and curate memory render as Bootstrap-styled HTML fragments served straight from PHP; HTMX swaps them into the page on demand. The result is a fast, accessible, progressively-enhanced UI with no heavy client-side framework to maintain.

## Why this stack fits MaluDB

MaluDB is a *retrieval-and-provenance* system: most screens are searches, graph traversals, and record reviews that map naturally to "ask the database, render the result." PHP + PDO calls MaluDB's functions directly — `text_search`, `execute_retrieval`, `replay_episode`, the `register_*` ingest helpers — and HTMX turns the responses into small, attribute-driven round-trips: live search, expanding an episode into its supporting evidence, paging a traversal, confirming a correction. Because the connection is a plain PostgreSQL session, the app runs under a real database role and inherits MaluDB's row-level-security and authorization model for free.

---

## About MaluDB (the platform)

**MaluDB is a memory DBMS** — a database purpose-built for long-term institutional memory, human–AI knowledge sharing, and contextual recall. It is written in **C as a set of PostgreSQL extensions** (the `maludb_core` extension plus companion daemons) and ships as a single managed installation on **Ubuntu 24.04 LTS** with **PostgreSQL 17**, bundling `pgvector`, `pgaudit`, and `pg_partman` so operators don't provision PostgreSQL by hand.

Rather than storing rows you overwrite, MaluDB stores *what was claimed, by whom, from what evidence, and when it was believed true* — and never silently discards a prior belief.

### The memory object model

Knowledge flows through a typed pipeline, each stage carrying provenance:

- **Source Packages** — durable byte blobs of evidence (a log excerpt, a ticket comment, a chat transcript, a metric snapshot), content-hashed on ingest.
- **Claims** — single propositions (subject · verb · object) that each cite a source.
- **Facts** — verified consolidations of one or more claims, recorded with a verification scope and method.
- **Episodes** — coherent events that happened, with ordered **Memory Detail Objects** (steps, observations) attached.
- **Memories** and typed **Relationship Edges** — the consolidated, interconnected graph the system recalls from.

### Core capabilities

- **Bitemporal truth** — every fact carries both *valid time* (when it was true in the world) and *transaction time* (when the database believed it), so you can ask "what did we believe an hour ago?"
- **Temporal Supersession Engine** — corrections never overwrite history. A correction closes the prior valid window, opens a new version, and records an explicit supersession edge.
- **Mandatory provenance** — every derived object has a Derivation Ledger entry; no row exists without a traceable origin.
- **SVPOR registries** — Subject / Verb / Predicate / Object / Relationship organization for a consistent, queryable vocabulary across the graph.
- **MAUT confidence scoring** — multi-attribute utility scoring for confidence and precision on recalled knowledge.
- **Lifecycle, decay, and legal hold** — governed retention rather than ad-hoc deletes.
- **Hybrid retrieval** — recursive-CTE graph traversal, PostgreSQL full-text search, `pg_trgm` fuzzy matching, and `pgvector` semantic search, behind a **retrieval planner** with query hints.
- **Authorization-aware retrieval** — access is checked at three points (planning, expansion, assembly), never only at the final answer.
- **Workflow Extraction Engine & Skill Runtime** — governed extraction of structured memory and a discoverable, state-machine skill catalog.
- **Active Memory Pools, Episode Replay, Local Node sync, and a Model Registry** — for working-set management, time-travel reconstruction of events, edge nodes that propose rather than write, and blue-green model routing.
- **In-database model gateway** — per-tenant model configuration drives memory extraction and embedding from inside the database.

### Multi-tenancy and schema-local memory

MaluDB never modifies ordinary PostgreSQL schemas automatically. An application opts a schema into the memory facades explicitly — `GRANT maludb_user TO <role>`, then `SELECT maludb_core.enable_memory_schema()` — giving each tenant its own role-scoped, RLS-aware view of the memory surface. Read-only consumers get `maludb_read`. Because this template connects as a real database role, those grants *are* the app's permission model.

### How this template connects

```php
// PHP 8.2+, ext-pdo + ext-pdo_pgsql
$pdo = new PDO('pgsql:host=/var/run/postgresql;dbname=mydb', $user, $pass, [
    PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
]);

// Run under the tenant role and put the memory facades on the search path.
$pdo->exec("SET ROLE app_tenant");
$pdo->exec("SET search_path TO app_tenant, maludb_core, public");

// Full-text search -> render the rows as an HTMX partial.
$stmt = $pdo->prepare(
    "SELECT object_type, object_id, title_or_subject, rank
       FROM text_search(:q, ARRAY['claim','fact','memory','episode_object'])
      ORDER BY rank DESC"
);
$stmt->execute([':q' => $query]);
$rows = $stmt->fetchAll(PDO::FETCH_ASSOC);
```

You can call MaluDB's functions through raw PDO as above, or use the published **`maludb/client`** Composer package (`composer require maludb/client`), which is itself a thin PDO/`pdo_pgsql` wrapper around the same SQL surface — no API server involved either way.

**Requirements:** PHP ≥ 8.2 with `ext-pdo`, `ext-pdo_pgsql`, and `ext-json`; network/socket access to a PostgreSQL 17 instance that has `maludb_core` installed and a tenant schema enabled.

### Architecture at a glance

```
Browser --HTMX--> PHP back end (Bootstrap 5 views) --PDO / pgsql--> PostgreSQL 17
                                                                       |
                                              SET ROLE <tenant>  -  RLS-enforced
                                                                       v
                                              maludb_core extension (in-database)
                                   memory model - bitemporal - provenance - retrieval
                                                                       ^
                                              maludb_modeld - pgvector  (in-DB services)

  (No REST hop — the PHP process holds a direct PostgreSQL session.
   See the sibling API template for the maludb-restd / HTTP variant.)
```
