# Planning Handoff: Subject / Verb / Predicate Extraction for Memory Database Ingestion

## Purpose of This Document

This document summarizes the refined design discussion for using an AI-assisted extraction layer before embedding documents or document chunks into the memory database.

The goal is to give coding agents enough context to evaluate whether this planned extraction layer maps cleanly onto the existing database structures already designed for the memory database.

The coding agent should review this document against the current relational, vector, graph, and temporal data structures and return the requested mapping information, gaps, and implementation recommendations so the design conversation can continue.

---

## System Context

The memory database combines:

- Relational database structures
- Vector search
- Graph relationships
- Temporal/event-oriented storage

The database is intended to load, maintain, and retrieve memories and events.

A key design goal is to **compartmentalize vector searches** so the system does not always search the entire vector corpus. Instead, the system should use extracted subject and verb information to narrow the vector search space before semantic search is performed.

For example, if a query is related to an Oracle upgrade, the system should be able to limit vector search to memory chunks associated with:

```text
subject = Oracle 21c / Oracle Database
verb = upgrade
```

This extraction is an add-on to the embedding strategy. It determines the subject and verb before or during embedding so that:

- The subject can become a graph node.
- The verb can become a graph edge or edge type.
- The predicate can become attributes on the edge.
- The same relationship can also be represented relationally so first-pass filtering does not require graph traversal.

---

## Refined Problem Statement

The task is not ordinary grammatical subject/verb/predicate parsing.

In a sentence such as:

```text
We performed the Oracle 21c upgrade on Sunday March 30 at 11 pm.
```

The grammatical subject is:

```text
We
```

But the memory-database subject is:

```text
Oracle 21c
```

The system should extract the **operationally meaningful target entity**, not necessarily the grammatical subject.

The extraction task should therefore be defined as:

> Convert unstructured document chunks into canonical graph-indexable memory event proposals before embedding, so vector search can be partitioned by subject and verb.

The extraction layer should identify:

```text
subject = the target entity, object, system, process, person, document, project, or concept the memory applies to
verb = the canonical action or relationship connecting the memory to the subject
predicate = typed attributes that qualify the relationship or event
```

---

## Example Extraction

Input text:

```text
We performed the Oracle 21c upgrade on Sunday March 30 at 11 pm.
```

Expected conceptual extraction:

```json
{
  "subject": "Oracle 21c",
  "verb": "upgrade",
  "predicate": {
    "status": "completed",
    "action_form": "performed",
    "date_text": "Sunday March 30",
    "time_text": "11 pm",
    "normalized_time": "23:00:00",
    "timezone": "America/Chicago"
  }
}
```

In graph form:

```text
[Oracle 21c] --UPGRADE--> [Memory/Event/Chunk]
```

The edge would carry attributes such as:

```json
{
  "status": "completed",
  "performed_at": "2025-03-30T23:00:00-05:00",
  "source": "document chunk",
  "confidence": 0.94
}
```

In relational form, the same relationship should be queryable without graph traversal:

```text
chunk_id | subject_id | verb_id | predicate_json | confidence
```

---

## Core Design Principle

The model should not own the memory structure.

The database should own:

- Canonical subjects
- Canonical verbs
- Subject aliases
- Verb aliases
- Entity resolution
- Edge identity
- Temporal normalization policy
- Confidence policy
- Vector partitioning rules
- Graph materialization rules

The AI model should act as an **edge proposal engine**.

The model helps infer:

- What entity the chunk is about
- What action or relationship is described
- What attributes qualify the action
- How confident the system should be

The database then decides whether to:

- Accept the proposal
- Reject it
- Store it as low-confidence
- Route it for human review
- Escalate it to a stronger model
- Attach it to an existing subject/verb
- Create a new subject/verb candidate

---

## Recommended Extraction Output Shape

The extractor should return an array of candidate edges because a single chunk may contain multiple events.

Example input:

```text
We upgraded Oracle 21c on Sunday, restarted the billing API, and postponed the reporting migration.
```

Expected output:

```json
{
  "candidate_edges": [
    {
      "subject_text": "Oracle 21c",
      "subject_type": "database_software",
      "subject_candidates": [
        {
          "subject_id": 44,
          "canonical_name": "Oracle Database 21c",
          "confidence": 0.91
        },
        {
          "subject_id": 12,
          "canonical_name": "Oracle Database",
          "confidence": 0.74
        }
      ],
      "verb_candidates": [
        {
          "verb_id": 7,
          "canonical": "upgrade",
          "confidence": 0.96
        }
      ],
      "predicate": {
        "status": "completed",
        "actuality": "actual",
        "date_text": "Sunday",
        "normalized_datetime": null
      },
      "source_span": "upgraded Oracle 21c on Sunday",
      "confidence": 0.94
    },
    {
      "subject_text": "billing API",
      "subject_type": "application_service",
      "verb_candidates": [
        {
          "canonical": "restart",
          "confidence": 0.95
        }
      ],
      "predicate": {
        "status": "completed",
        "actuality": "actual"
      },
      "source_span": "restarted the billing API",
      "confidence": 0.93
    },
    {
      "subject_text": "reporting migration",
      "subject_type": "project_or_process",
      "verb_candidates": [
        {
          "canonical": "migrate",
          "confidence": 0.84
        }
      ],
      "predicate": {
        "status": "postponed",
        "actuality": "planned_or_deferred"
      },
      "source_span": "postponed the reporting migration",
      "confidence": 0.88
    }
  ]
}
```

---

## Important Verb Design Decision

Avoid making the verb too specific.

Prefer:

```text
verb = upgrade
```

with predicate attributes:

```json
{
  "status": "completed",
  "actuality": "actual",
  "action_form": "performed"
}
```

Instead of using overly specific verbs such as:

```text
performed_upgrade
planned_upgrade
failed_upgrade
delayed_upgrade
completed_upgrade
rollback_upgrade
```

The reason is that the verb should act as a durable vector-search compartment. If the verb vocabulary becomes too granular, related memories may be fragmented across too many small compartments.

Recommended pattern:

```text
subject = Oracle 21c
verb = upgrade
predicate.status = completed / planned / failed / rolled_back / delayed
predicate.actuality = actual / planned / hypothetical / negated
```

This allows searches for Oracle upgrades to include completed, planned, failed, and rolled-back upgrade memories as needed.

---

## Candidate Subject Types

Initial subject types may include:

```text
person
organization
system
database
application
server
document
process
project
event
decision
claim
requirement
configuration
environment
service
ticket
contract
```

These should be validated against the existing schema.

---

## Candidate Verb Families

Initial canonical verbs or verb families may include:

```text
create
read
update
delete
approve
reject
plan
perform
complete
fail
delay
rollback
migrate
upgrade
install
configure
restart
diagnose
observe
decide
claim
support
contradict
transfer
schedule
cancel
review
summarize
test
deploy
patch
renew
archive
restore
```

These should be validated against the existing schema and any existing action, relation, or event-type tables.

---

## Predicate Attribute Categories

Predicate attributes should remain flexible but typed where possible.

Common predicate fields may include:

```text
status
actuality
tense
date_text
time_text
normalized_datetime
event_time_start
event_time_end
timezone
environment
version
previous_version
new_version
owner
actor
team
ticket_number
document_reference
reason
result
risk
dependency
location
confidence
source_span
```

The coding agent should determine whether the existing design already has structures for these attributes or whether they should live in JSON, typed columns, temporal tables, or related child tables.

---

## Proposed Pipeline

The ingestion pipeline should be evaluated against the existing architecture.

```text
Raw document
  ↓
Chunking
  ↓
Event candidate detection
  ↓
Subject/entity extraction
  ↓
Subject canonicalization / node resolution
  ↓
Verb/action classification
  ↓
Predicate attribute extraction
  ↓
Date/time/version normalization
  ↓
Relational edge-index insert
  ↓
Graph materialization
  ↓
Vector embedding with subject/verb metadata
```

The key point is that subject and verb extraction happen before or alongside embedding so the resulting embedding can be stored with routing metadata.

---

## Vector Search Compartment Strategy

The system should support multiple levels of filtering so an incorrect or overly narrow subject/verb assignment does not make relevant information invisible.

Recommended search levels:

```text
Exact:
  subject_id = Oracle 21c
  verb_id = upgrade

Parent:
  subject_id = Oracle Database
  verb_id = upgrade

Broader:
  subject_family = database
  verb_family = maintenance_change

Fallback:
  global memory search
```

The coding agent should check whether the current design supports:

- Parent/child subject hierarchy
- Verb families
- Subject aliases
- Verb aliases
- Multiple candidate subject/verb pairs per chunk
- Low-confidence alternate classifications
- Global fallback embeddings
- Filtering vector searches by subject_id and verb_id

---

## Relational Representation

A possible relational structure for discussion:

```sql
subject_node (
  subject_id,
  canonical_name,
  subject_type,
  parent_subject_id,
  created_at
);

subject_alias (
  alias_id,
  subject_id,
  alias_text,
  confidence
);

verb_type (
  verb_id,
  canonical_verb,
  verb_family,
  description
);

verb_alias (
  alias_id,
  verb_id,
  alias_text
);

memory_chunk (
  chunk_id,
  document_id,
  chunk_text,
  chunk_hash,
  created_at
);

memory_edge (
  edge_id,
  chunk_id,
  subject_id,
  verb_id,
  status,
  actuality,
  event_time_start,
  event_time_end,
  predicate_json,
  source_span,
  extraction_model,
  confidence
);

memory_embedding (
  embedding_id,
  chunk_id,
  edge_id,
  subject_id,
  verb_id,
  embedding_model,
  vector,
  created_at
);
```

This is not necessarily a replacement for the current schema. It is a conceptual structure the coding agent should map to the already-designed data structures.

---

## Graph Representation

The graph representation can be materialized from relational rows.

Basic form:

```text
[Subject Node] --[Verb Edge + Predicate Attributes]--> [Memory/Event/Chunk Node]
```

Example:

```text
[Oracle Database 21c] --[UPGRADE {status: completed, performed_at: ...}]--> [Chunk 81237]
```

Alternative richer event graph form, if needed later:

```text
[Team] --PERFORMED--> [Upgrade Event] --TARGETED--> [Oracle Database 21c]
```

For first-pass search optimization, the relational form is more important because it allows fast filtering without requiring graph traversal.

---

## Model Strategy

The preferred production direction is a controlled hybrid pipeline rather than a single unconstrained LLM.

Potential components:

```text
1. Subject/entity extractor
2. Subject alias resolver / entity linker
3. Verb/action classifier
4. Predicate attribute extractor
5. Deterministic normalizers
6. Confidence scoring
7. Optional stronger-model fallback for ambiguous cases
```

The model should output candidate edge proposals. Database logic should resolve, validate, and persist them.

Small local models, fine-tuned extractors, or classifier-style models may be preferred for production ingestion. A stronger cloud or local LLM can be used as a teacher, evaluator, fallback, or labeling assistant, but should not be treated as the owner of the data structure.

---

## Design Questions for the Coding Agent

Please compare this planned extraction and routing layer to the current data structures and answer the following.

### 1. Existing Schema Mapping

For each conceptual object below, identify the existing table, struct, class, or module that already represents it.

```text
subject_node
subject_alias
verb_type
verb_alias
memory_chunk
memory_edge
predicate attributes
memory_embedding
document
graph node
graph edge
temporal event
confidence score
source span
extraction model metadata
```

Return the mapping in this format:

```text
Concept: subject_node
Existing object/table: ...
Status: already exists / partially exists / missing
Notes: ...
```

### 2. Missing Structures

Identify any missing structures required to support this design.

Specifically check for:

```text
subject hierarchy
subject aliases
verb aliases
verb families
many candidate edges per chunk
multiple subjects per chunk
multiple verbs per chunk
predicate_json or equivalent
typed temporal fields
confidence tracking
source_span tracking
model/extractor version tracking
vector partition metadata
fallback/global vector search
```

### 3. Subject and Verb Resolution

Explain how the current system resolves or could resolve:

```text
"Oracle 21c"
"Oracle Database 21c"
"production Oracle database"
"the database"
```

to the same or related subject nodes.

Also explain how the current system resolves or could resolve:

```text
performed upgrade
upgraded
completed upgrade
planned upgrade
rolled back upgrade
```

to a canonical verb such as:

```text
upgrade
```

with predicate/status attributes.

### 4. Embedding and Vector Search Fit

Determine where subject_id and verb_id should be attached in the vector storage path.

Questions:

```text
Does the embedding table/index already support metadata filters?
Can embeddings be filtered by subject_id?
Can embeddings be filtered by verb_id?
Can embeddings be filtered by subject_family or verb_family?
Can a chunk have multiple embeddings tied to different extracted edges?
Should the system embed the whole chunk once or embed each edge-specific source span separately?
Is there a global fallback embedding for each chunk?
```

### 5. Graph Fit

Determine whether the graph model supports:

```text
subject as node
verb as edge type or edge label
predicate as edge attributes
chunk/event/memory as a target node
relational row as source of graph materialization
```

Also identify whether graph traversal is required for first-pass search, or whether the relational index can serve that purpose.

### 6. Temporal Fit

Determine whether the system already supports:

```text
event_time_start
event_time_end
normalized_datetime
date_text
time_text
timezone
temporal uncertainty
date contradictions
past/planned/future status
```

Example issue:

```text
"Sunday March 30" and "2026/03/30" may conflict because March 30, 2026 was a Monday.
```

The system should be able to preserve literal source text and normalized interpretation, and ideally flag contradictions.

### 7. Confidence and Review Workflow

Determine whether the system supports:

```text
confidence per extracted edge
confidence per subject resolution
confidence per verb resolution
confidence per predicate field
low-confidence routing
human review
model fallback
audit trail of accepted/rejected extraction proposals
```

### 8. Recommended Implementation Location

Identify where in the current codebase this extraction stage should be inserted.

Potential locations:

```text
before embedding
during chunk ingestion
after chunking but before vector insert
as an asynchronous enrichment job
as a reprocessing job for existing chunks
```

Explain which location best fits the current architecture.

### 9. Return a Concrete Gap Analysis

Please return a table with:

```text
Requirement
Existing support
Missing pieces
Recommended change
Risk level
```

### 10. Return a Minimal Implementation Plan

Please propose the smallest implementation that validates the design.

Minimum viable flow:

```text
input chunk
extract candidate subject/verb/predicate
resolve subject against existing or candidate subject table
resolve verb against existing or candidate verb table
insert relational memory edge
attach subject_id and verb_id to embedding metadata
materialize or queue graph edge
run filtered vector search by subject_id + verb_id
```

---

## Information to Bring Back to the Design Conversation

After reviewing the existing code and schema, return the following summary:

```text
1. Current schema objects that already map to this design.
2. Missing schema objects or columns.
3. Whether subject/verb metadata can be attached to vector embeddings today.
4. Whether one chunk can produce multiple subject/verb edges today.
5. Whether graph edges can be materialized from relational records today.
6. Whether temporal attributes are already modeled adequately.
7. Whether aliases and canonicalization are already supported.
8. Where the extraction stage should be inserted in the ingestion pipeline.
9. Minimal code changes required for a prototype.
10. Risks or design conflicts with the current architecture.
```

---

## Working Thesis

The extraction layer should be treated as a schema-constrained event and relationship proposal engine.

It converts document chunks into canonical subject/verb graph-edge candidates before embedding, allowing the memory database to store vectors in searchable compartments aligned with relational and graph structures.

The database remains the source of truth. The model proposes structure; the database resolves, validates, stores, indexes, and materializes it.

