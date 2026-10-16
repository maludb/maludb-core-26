# MaluDB End-to-End Test — The "MIST" Project

> **Status:** living document. Built and maintained against the installed
> extension `maludb_core` **default_version 0.86.1**
> (`sql/extension/maludb_core--0.86.1.sql`).
> Every function/view signature below was extracted from that script — if a
> call here does not match the DDL, the DDL wins and this doc is the bug.

## 1. Why this document exists

We want a *single, realistic, end-to-end scenario* that we drive through MaluDB
from an empty schema to a queryable knowledge graph, so we can feel — not just
assert — **how hard it is to load data and run the queries a real app would
run.** The friction we hit here is the product feedback loop.

The scenario is a software project called **MIST**:

- MIST started **March 23, 2013** and is **ongoing**.
- On the **first day** the team was:
  | Person   | Role on day one              |
  |----------|------------------------------|
  | Dave     | Project Manager              |
  | Ed       | Oracle DBA *and* Oracle Developer |
  | Joe      | Programmer                   |
  | Deb      | Programmer                   |
  | Leticia  | Programmer                   |

This first pass loads exactly that — the project, the people, and the
first-day org chart — and then runs a "query gauntlet" against it. **Part II**
([§12 onward](#part-ii--pass-2--hierarchy-meetings-and-time)) extends MIST with
sprints, tasks, meetings, and staffing changes, which is where the *temporal*
parts of the model start to earn their keep.

> **Pass status — EXECUTED LIVE 2026-05-31.** Both passes were run end to end
> against a real `maludb_core` **0.86.1** database (PostgreSQL 17). All result
> tables below are **observed output**, not predictions. The live run found and
> fixed several doc bugs — the SQL here is the corrected, working version; see
> §10 and §18 for what broke. The one environment wrinkle: the server shipped
> the extension at **0.82.0**, so 0.86.1 had to be brought up first (see
> [§3](#3-prerequisites)).

---

## 2. Mapping the scenario onto the MaluDB model

This is the important part: MaluDB has no `projects` table, no `employees`
table, no `assignments` table. It has a **typed property graph** expressed as
SVPOR (Subject–Verb–Predicate–Object, with Relationships). So before we write a
line of SQL we decide what each real-world thing *becomes*.

| Real-world thing | MaluDB representation | Why |
|---|---|---|
| **MIST** (the project) | a **subject**, `subject_type = 'project'` | A project is a durable *entity* other things relate to. The `subject_type` picker already seeds `'project'`. (It is **not** its own polymorphic kind — see the note below.) |
| **Dave, Ed, Joe, Deb, Leticia** | **subjects**, `subject_type = 'person'` | People are entities too; `'person'` is a seeded subject type. |
| **"Dave manages MIST"**, etc. | an **SVO statement** (`malu$svpor_statement`): `subject(Dave) —verb(manages)→ subject(MIST)` | Role assignments are *relationships between two entities*. The verb carries the relationship; the statement carries **valid-time**. |
| **The exact job title** ("Programmer", "Oracle DBA") | an **attribute on the edge** (`target_kind = 'svpor_statement'`), `attr_name = 'role_title'` | A title is a *property of the assignment*, not a new entity and not a verb. MaluDB attributes attach to edges as well as nodes. |
| **"started 2013-03-23 / ongoing"** | **attributes on the MIST subject**: `start_date` (timestamp), `status` (text) | Dates/status are scalar *properties* of the project node, not verbs or subjects. |
| **"on the first day"** | `valid_from = 2013-03-23` on each role statement; a **kickoff episode** anchors the date | Every role assertion is bitemporal — it became true on day one and is still true (`valid_to = NULL`). |
| **The kickoff itself** | an **episode** (`malu$episode_object`), `episode_kind = 'Planning'`, `occurred_at = 2013-03-23` | Events/occurrences are episodes; the seeded `episode_type` picker has `'Planning'`. People `attended` it (a seeded verb). |

### The one rule that trips everyone up

> **`subject_kind` in a statement is the *table kind*, not the `subject_type`.**

Every person and the project are rows in `malu$svpor_subject`, so in a statement
they are **all `'subject'`**. `subject_type` (`'person'` / `'project'`) is a
*column on the subject row*, not the statement's polymorphic kind. The valid
statement endpoint kinds are fixed by the core (verified in
`_svpor_statement_assert_endpoint` and the table CHECK):

```
subject · verb · document · episode_object · memory ·
source_package · claim · fact · memory_detail_object
```

There is no `'person'` or `'project'` kind. So "Dave manages MIST" is

```
subject_kind='subject'  →  verb='manages'  →  object_kind='subject'
```

Getting this wrong is the single most likely first-day mistake, which is itself
a finding (see [§10](#10-findings--the-difficulty-report)).

---

## 3. Prerequisites

```sql
-- The extension must be installed in the database (one-time, as superuser):
CREATE EXTENSION IF NOT EXISTS maludb_core CASCADE;   -- CASCADE pulls in vector, btree_gist, pg_trgm, pgcrypto
```

> **Live-run note (version skew).** On the test box the server shipped the
> extension at `default_version = 0.82.0`, which predates the whole
> attribute/graph-walk/object_get surface this doc uses. Because the compiled
> `.so` already matched 0.86.1, the fix was to create the extension at the
> available base version and apply the repo's official delta scripts:
> ```bash
> psql -d mist_e2e -c "CREATE EXTENSION maludb_core CASCADE;"   # lands 0.82.0
> for d in 0.82.0--0.83.0 0.83.0--0.84.0 0.84.0--0.85.0 \
>          0.85.0--0.86.0 0.86.0--0.86.1; do
>   sed '/\\quit/d' sql/extension/maludb_core--$d.sql | psql -d mist_e2e
> done
> ```
> If your server already advertises 0.86.1, a plain `CREATE EXTENSION` (or
> `ALTER EXTENSION maludb_core UPDATE`) is enough. Verify with
> `SELECT extversion FROM pg_extension WHERE extname='maludb_core';`.

All the friendly `maludb_*` views/functions used below do **not** exist until a
schema has *memory enabled*. We do that in Step 1. The facades are granted to
the `maludb_memory_admin` / `maludb_memory_executor` roles, so the role running
this script must be a member of one of them (a writer needs
`maludb_memory_executor`).

---

## 4. Step 1 — Create the schema and enable memory

```sql
CREATE SCHEMA IF NOT EXISTS mist;

-- Put the tenant schema first so current_schema() = 'mist' for every default.
SET search_path = mist, maludb_core, public;

-- Build the full per-tenant facade API (views + functions) inside `mist`.
SELECT * FROM maludb_core.enable_memory_schema('mist');
--  schema_name | enabled_version | object_count
-- -------------+-----------------+--------------
--  mist        | 0.86.1          |          (n)
```

`enable_memory_schema` is **idempotent** — re-running it after an extension
upgrade is how a schema picks up new objects (that's exactly the 0.86.1 fix:
re-enable no longer chokes on the widened `maludb_svpor_attribute` view).

> From here on, every `mist.maludb_*` object exists. `search_path` keeps
> `current_schema()` = `'mist'`, so `owner_schema` defaults and RLS scoping all
> resolve to this tenant automatically.

---

## 5. Step 2 — Register the vocabulary (verbs)

MaluDB seeds a few verbs on enable — `attended`, `generated_by`, `made_during`
— which we reuse for the kickoff. For the org chart we register three role verbs.
Writing through the `maludb_verb` facade view is the tenant-scoped path; the
`verb_type` is advisory.

```sql
INSERT INTO mist.maludb_verb (canonical_name, verb_type, aliases, description) VALUES
  ('manages',     'assigned', ARRAY['leads','runs'],                 'Person has management responsibility for a thing.'),
  ('administers', 'other',    ARRAY['dba_for','database_admin_for'], 'Person is the database/system administrator for a thing.'),
  ('develops',    'created',  ARRAY['programs','codes_for'],         'Person writes/maintains code for a thing.')
ON CONFLICT DO NOTHING;
```

> ### 🔒 LOCKED DECISION — "small verbs + role on the edge"
>
> **Model a relationship as a small set of canonical verbs, and carry the
> specific role/title as an *edge attribute* (`role_title`) — never one verb per
> job title.** ("Oracle Developer" and "Programmer" are the same relationship,
> `develops`, distinguished only by their `role_title`.) So Dave is `manages`,
> Ed is both `administers` and `develops`, and Joe/Deb/Leticia are `develops`.
>
> - **Why:** keeps the verb vocabulary small, so `graph_neighbors` /
>   `graph_walk` rel-filters stay meaningful and the graph isn't polluted with
>   one edge type per HR title. Titles are *properties of an assignment*, not new
>   relationship types.
> - **Trade-off accepted:** the "team with titles" read (Q3) must hand-join the
>   edge attribute. Logged as finding #3 / backlog candidate.
> - **Rule going forward:** add a new verb only for a genuinely new
>   *relationship*; express variants of the same relationship as edge attributes.
>
> *Locked 2026-05-31. Applies to every later pass.*

---

## 6. Step 3 — Create the subjects (project + people)

We load everything in a single `DO` block, because this is how an application or
migration actually wires it up: insert a row, capture its generated id, use that
id in the next insert. (The query section afterwards is plain copy-paste SQL.)

```sql
DO $$
DECLARE
    v_mist    bigint;
    v_dave    bigint;
    v_ed      bigint;
    v_joe     bigint;
    v_deb     bigint;
    v_leticia bigint;
BEGIN
    -- The project, as a subject of type 'project'.
    INSERT INTO mist.maludb_subject (canonical_name, subject_type, description)
    VALUES ('MIST', 'project', 'The MIST software project; started 2013-03-23, ongoing.')
    RETURNING subject_id INTO v_mist;

    -- The five people, as subjects of type 'person'.
    INSERT INTO mist.maludb_subject (canonical_name, subject_type, description)
         VALUES ('Dave',    'person', 'MIST project manager (day one).')        RETURNING subject_id INTO v_dave;
    INSERT INTO mist.maludb_subject (canonical_name, subject_type, description)
         VALUES ('Ed',      'person', 'MIST Oracle DBA and Oracle developer.')  RETURNING subject_id INTO v_ed;
    INSERT INTO mist.maludb_subject (canonical_name, subject_type, description)
         VALUES ('Joe',     'person', 'MIST programmer (day one).')             RETURNING subject_id INTO v_joe;
    INSERT INTO mist.maludb_subject (canonical_name, subject_type, description)
         VALUES ('Deb',     'person', 'MIST programmer (day one).')             RETURNING subject_id INTO v_deb;
    INSERT INTO mist.maludb_subject (canonical_name, subject_type, description)
         VALUES ('Leticia', 'person', 'MIST programmer (day one).')            RETURNING subject_id INTO v_leticia;

    RAISE NOTICE 'MIST=% Dave=% Ed=% Joe=% Deb=% Leticia=%',
        v_mist, v_dave, v_ed, v_joe, v_deb, v_leticia;
END $$;
```

> **Idempotency note (corrected after live run — §10.6).** A *plain* `INSERT`
> through the `maludb_subject` view does **not** upsert: re-running it raises
> `duplicate key value violates unique constraint
> "malu$svpor_subject_owner_schema_canonical_name_key"`. And the view doesn't
> expose `owner_schema`, so you can't write `ON CONFLICT (owner_schema,
> canonical_name)` either. To make a load re-runnable: start from a fresh schema,
> add a bare `ON CONFLICT DO NOTHING` then `SELECT` the id (see Priya in §15), or
> call `maludb_core.register_svpor_subject(...)`, whose core upsert *is*
> idempotent on `(owner_schema, canonical_name)`.

---

## 7. Step 4 — Project attributes (start date, status)

The project's *properties* — when it started, its status — are attributes on the
MIST subject. We use the 0.84.0 **single-call bulk apply**, which is what a POST
handler would do: one JSON array, one round trip.

```sql
SELECT mist.maludb_attributes_apply(
    'subject',
    (SELECT subject_id FROM mist.maludb_subject WHERE canonical_name = 'MIST'),
    $json$[
        {"attr_name": "start_date", "value_timestamp": "2013-03-23T00:00:00Z"},
        {"attr_name": "status",     "value_text": "ongoing"}
    ]$json$::jsonb
);
-- returns the count of attributes applied (2)
```

Optionally register a small **template** so an app can render a project form and
so `attribute_check` knows what "complete" means for a project:

```sql
SELECT mist.maludb_attribute_template_create(
    p_applies_to => 'subject_type', p_type_value => 'project',
    p_attr_name  => 'start_date',   p_value_type => 'timestamp',
    p_requirement => 'required',    p_label => 'Start Date', p_display_order => 10);

SELECT mist.maludb_attribute_template_create(
    p_applies_to => 'subject_type', p_type_value => 'project',
    p_attr_name  => 'status',       p_value_type => 'text',
    p_requirement => 'recommended', p_label => 'Status', p_display_order => 20);

SELECT mist.maludb_attribute_template_create(
    p_applies_to => 'subject_type', p_type_value => 'project',
    p_attr_name  => 'end_date',     p_value_type => 'timestamp',
    p_requirement => 'optional',    p_label => 'End Date', p_display_order => 30);
```

---

## 8. Step 5 — The first-day org chart (role statements + titles)

Each role is an SVO statement `person —verb→ MIST`, stamped with
`p_valid_from = '2013-03-23'` (became true on day one) and `p_valid_to = NULL`
(still true). Immediately after creating each, we attach the exact `role_title`
as an **edge attribute** (`target_kind = 'svpor_statement'`).

```sql
DO $$
DECLARE
    v_mist bigint := (SELECT subject_id FROM mist.maludb_subject WHERE canonical_name = 'MIST');
    v_stmt bigint;
    r RECORD;
BEGIN
    FOR r IN
        SELECT * FROM (VALUES
            ('Dave',    'manages',     'Project Manager'),
            ('Ed',      'administers', 'Oracle DBA'),
            ('Ed',      'develops',    'Oracle Developer'),
            ('Joe',     'develops',    'Programmer'),
            ('Deb',     'develops',    'Programmer'),
            ('Leticia', 'develops',    'Programmer')
        ) AS t(person, verb, title)
    LOOP
        -- Create (or upsert) the relationship, valid from the first day, ongoing.
        v_stmt := mist.maludb_svpor_statement_create(
            p_subject_kind => 'subject',
            p_subject_id   => (SELECT subject_id FROM mist.maludb_subject WHERE canonical_name = r.person),
            p_verb_id      => (SELECT verb_id    FROM mist.maludb_verb    WHERE canonical_name = r.verb),
            p_object_kind  => 'subject',
            p_object_id    => v_mist,
            p_valid_from   => '2013-03-23T00:00:00Z'::timestamptz,
            p_valid_to     => NULL,
            p_provenance   => 'provided'
        );

        -- Attach the exact job title as an attribute ON THE EDGE.
        PERFORM mist.maludb_svpor_attribute_create(
            p_target_kind => 'svpor_statement',
            p_target_id   => v_stmt,
            p_attr_name   => 'role_title',
            p_value_text  => r.title
        );
    END LOOP;
END $$;
```

> **Why Ed is two rows.** Ed holds two distinct relationships to MIST
> (`administers` *and* `develops`), so he gets two statements — correctly, since
> the statement identity is `(subject, verb, object)`. Each carries its own
> `role_title`. This is the model handling a real "one person, two hats" case
> without a special column.

### The kickoff episode (anchors "the first day")

```sql
DO $$
DECLARE
    v_kickoff bigint;
    r RECORD;
BEGIN
    v_kickoff := mist.maludb_register_episode(
        p_episode_kind => 'Planning',
        p_title        => 'MIST Project Kickoff',
        p_summary      => 'Day-one kickoff: project chartered, roles assigned.',
        p_occurred_at  => '2013-03-23T00:00:00Z'::timestamptz
    );

    -- Everyone attended the kickoff: subject —attended→ episode_object.
    FOR r IN SELECT canonical_name FROM mist.maludb_subject WHERE subject_type = 'person'
    LOOP
        PERFORM mist.maludb_svpor_statement_create(
            p_subject_kind => 'subject',
            p_subject_id   => (SELECT subject_id FROM mist.maludb_subject WHERE canonical_name = r.canonical_name),
            p_verb_id      => (SELECT verb_id    FROM mist.maludb_verb    WHERE canonical_name = 'attended'),  -- seeded verb
            p_object_kind  => 'episode_object',
            p_object_id    => v_kickoff,
            p_valid_from   => '2013-03-23T00:00:00Z'::timestamptz
        );
    END LOOP;
END $$;
```

At this point the graph for day one is fully loaded:

```
            ┌─────────── attended ──────────┐
            ▼                                │
   (episode) MIST Kickoff            Dave ─ manages ───────┐
   2013-03-23                        Ed   ─ administers ───┤
            ▲  ▲  ▲  ▲  ▲            Ed   ─ develops ──────┤
            │  │  │  │  │            Joe  ─ develops ──────┤──► (subject) MIST
          Dave Ed Joe Deb Leticia   Deb  ─ develops ──────┤      type=project
                                     Leticia ─ develops ──┘      start_date=2013-03-23
                                       (each role edge has a       status=ongoing
                                        role_title attribute)
```

---

## 9. The query gauntlet — *testing the difficulty*

This is the point of the whole exercise. The same question ("who's on MIST and
what do they do?") is asked several ways, from most painful to most ergonomic.

### Q1 — Raw statement read (the painful path)

What you write if you think in tables. The statement table stores **ids and
kinds**, so every human-readable field is a join, and you must remember the
endpoint orientation (people are the *subject*, MIST is the *object*).

```sql
SELECT  s_subj.canonical_name      AS person,
        v.canonical_name           AS relationship,
        st.valid_from,
        st.valid_to
FROM    mist.maludb_svpor_statement st
JOIN    mist.maludb_verb            v      ON v.verb_id        = st.verb_id
JOIN    mist.maludb_subject         s_subj ON s_subj.subject_id = st.subject_id
JOIN    mist.maludb_subject         s_obj  ON s_obj.subject_id  = st.object_id
WHERE   st.subject_kind = 'subject'
  AND   st.object_kind  = 'subject'
  AND   s_obj.canonical_name = 'MIST'
ORDER BY person;
```

### Q2 — One-hop neighbors (the ergonomic path)

The 0.86.0 unified-graph layer resolves labels for you and walks **both** edge
stores. People point *at* MIST, so from MIST they are **incoming** edges.

```sql
SELECT label AS person, rel AS relationship, edge_store
FROM   mist.maludb_graph_neighbors(
           p_kind      => 'subject',
           p_id        => (SELECT subject_id FROM mist.maludb_subject WHERE canonical_name = 'MIST'),
           p_direction => 'in')
ORDER  BY person;
```

One call, names resolved, no orientation bookkeeping. Filter to just developers:

```sql
SELECT label
FROM   mist.maludb_graph_neighbors(
           'subject',
           (SELECT subject_id FROM mist.maludb_subject WHERE canonical_name = 'MIST'),
           'in',
           ARRAY['develops']);     -- p_rel_filter: rel = verb canonical_name
```

### Q3 — Team **with exact titles** (edge attributes)

The title lives on the edge, so we join the statement to its attribute. This is
the genuinely awkward query — the answer to "is the data model easy to query?"
is "mostly, until you need an edge property."

```sql
SELECT  person.canonical_name  AS person,
        v.canonical_name       AS relationship,
        attr.value_text        AS role_title
FROM    mist.maludb_svpor_statement st
JOIN    mist.maludb_subject  person ON person.subject_id = st.subject_id
JOIN    mist.maludb_verb     v      ON v.verb_id         = st.verb_id
LEFT JOIN mist.maludb_svpor_attribute attr
       ON attr.target_kind = 'svpor_statement'
      AND attr.target_id   = st.statement_id
      AND attr.attr_name   = 'role_title'
WHERE   st.object_kind = 'subject'
  AND   st.object_id   = (SELECT subject_id FROM mist.maludb_subject WHERE canonical_name = 'MIST')
  AND   v.canonical_name IN ('manages','administers','develops')   -- exclude 'attended' edges
ORDER BY role_title, person;
```

Observed result (live — matches the prediction exactly):

| person  | relationship | role_title       |
|---------|--------------|------------------|
| Ed      | administers  | Oracle DBA       |
| Ed      | develops     | Oracle Developer |
| Dave    | manages      | Project Manager  |
| Deb     | develops     | Programmer       |
| Joe     | develops     | Programmer       |
| Leticia | develops     | Programmer       |

### Q4 — The project as one object (bundled read)

What a detail page actually wants: the node plus all its attributes in one JSON,
no joins.

```sql
SELECT jsonb_pretty(
    mist.maludb_object_get('subject',
        (SELECT subject_id FROM mist.maludb_subject WHERE canonical_name = 'MIST')));
-- { "kind": "subject", "id": ...,
--   "object":     { "canonical_name": "MIST", "subject_type": "project", ... },
--   "attributes": { "start_date": {...}, "status": {"value":"ongoing", ...} } }
```

### Q5 — Walk the whole MIST neighborhood

Depth-bounded, cycle-safe, across both edge stores. From MIST this reaches the
people (incoming role edges) and, transitively, the kickoff they attended.

```sql
SELECT object_kind, label, depth, rel, edge_store, path
FROM   mist.maludb_graph_walk(
           p_kind      => 'subject',
           p_id        => (SELECT subject_id FROM mist.maludb_subject WHERE canonical_name = 'MIST'),
           p_max_depth => 3,
           p_direction => 'both')
ORDER  BY depth, label;
```

**Observed (live): 36 rows — bigger than you'd expect, and that's the lesson.**
Depth 1 = the 6 role edges to people. Depth 2 = all 5 people →`attended`→ Kickoff.
Depth 3 = from the Kickoff *back out* to every co-attendee, so each person is
re-reached via every other person's attendance edge (≈5×5). The walk is
cycle-safe but **not node-deduplicated** — a single shared episode is a hub that
makes the whole team mutually reachable in 3 hops, inflating the result
combinatorially. In a real query you'd bound depth, filter `rel`, or
`DISTINCT ON (object_id)`. See finding §10.7.

### Q6 — Completeness check (advisory)

Did we fill in everything a `project` is *supposed* to have, per the templates
from Step 4?

```sql
SELECT mist.maludb_attribute_check('subject',
    (SELECT subject_id FROM mist.maludb_subject WHERE canonical_name = 'MIST'));
-- start_date present, status present → no required attributes missing.
-- (end_date is 'optional', so its absence is fine.)
```

### Q7 — "As of the first day" (temporal)

Because every role carries `valid_from`/`valid_to`, we can ask the org chart *as
of any date*. Today this returns the same six rows; it becomes interesting the
moment someone joins or leaves (next steps).

```sql
WITH as_of AS (SELECT '2013-03-23'::timestamptz AS t)
SELECT person.canonical_name AS person, v.canonical_name AS relationship
FROM   mist.maludb_svpor_statement st
JOIN   mist.maludb_subject person ON person.subject_id = st.subject_id
JOIN   mist.maludb_verb    v      ON v.verb_id         = st.verb_id
CROSS JOIN as_of
WHERE  st.object_id   = (SELECT subject_id FROM mist.maludb_subject WHERE canonical_name = 'MIST')
  AND  st.object_kind = 'subject'
  AND  v.canonical_name IN ('manages','administers','develops')
  AND  st.valid_from <= as_of.t
  AND  (st.valid_to IS NULL OR st.valid_to > as_of.t)
ORDER BY person;
```

---

## 10. Findings — the difficulty report

Running the gauntlet against a freshly loaded MIST surfaced these:

1. **`subject_kind` vs `subject_type` is the #1 trap.** A "project" and a
   "person" are both `subject_kind='subject'`; their type is a *column*. Loaders
   that pass `'project'`/`'person'` as the statement kind get
   `unsupported endpoint kind` from `_svpor_statement_assert_endpoint`. The
   mapping table in §2 exists specifically to pre-empt this.
2. **Loading is comfortable; node-only reading is comfortable.** Subjects,
   attributes (`attributes_apply` one-shot), episodes, and `object_get` all read
   cleanly. `graph_neighbors`/`graph_walk` make relationship reads pleasant and
   label-resolved.
3. **Edge-property queries are the rough edge.** Q3 (titles on edges) is the
   only query that feels heavy — you hand-join `maludb_svpor_attribute` on
   `(target_kind='svpor_statement', target_id=statement_id)` and must also
   exclude unrelated verbs (`attended`). A future `graph_neighbors` variant that
   folds in edge attributes (or an `edge_get(statement_id)` bundler mirroring
   `object_get`) would remove it. **← product backlog candidate.**
4. **Orientation is on the caller.** "People relate *to* MIST" means MIST's
   teammates are `direction => 'in'`. Easy to invert by accident; the typed
   `rel`/`label` output makes the mistake obvious at least.
5. **Verb-vs-attribute is a real modeling decision.** Collapsing four roles to
   three verbs + a `role_title` attribute kept the vocab clean and Q2's
   `rel_filter` meaningful, at the cost of Q3's complexity. The reverse choice
   (one verb per title) would make Q3 trivial and Q2 noisy. Worth documenting as
   guidance.

*The following surfaced only when the script actually ran (2026-05-31):*

6. **Writing vocab through the facade views has a sharp `ON CONFLICT` edge.**
   Subjects and verbs are written by `INSERT`ing into the `maludb_subject` /
   `maludb_verb` **views** (there is no `maludb_register_subject`/`_verb`
   facade). The views don't expose `owner_schema`, so the natural
   `ON CONFLICT (owner_schema, canonical_name)` fails with `column "owner_schema"
   does not exist`, **and** a plain re-`INSERT` fails on the underlying unique
   index `malu$svpor_subject_owner_schema_canonical_name_key`. You must use a
   *bare* `ON CONFLICT DO NOTHING` (no target) — which resolves to the hidden
   index — or call the core `register_svpor_subject/verb()` upsert. This bit
   every load step on the first run; the §5/§6/§13/§15 code is the corrected form.
7. **`graph_walk` enumerates *paths*, not *nodes*, and shared hubs explode the
   row count.** The depth-3 walk from MIST returned **36 rows**, not the dozen
   you'd sketch, because the shared Kickoff episode makes all five attendees
   mutually reachable at depth 3 (≈n²). It's cycle-safe (no infinite loop) but
   not node-deduplicated. Real callers should bound depth, pass a `rel_filter`,
   or `DISTINCT ON (object_id)`; a `distinct_nodes => true` option would help.
8. **Everything else worked first try.** Once the `ON CONFLICT` form was fixed,
   `attributes_apply`, `object_get`, `attribute_check`, `register_episode`,
   `graph_neighbors`, and the temporal `valid_from/valid_to` queries all returned
   correct results unchanged — Q1, Q2, Q3, Q4, Q6, Q7 matched the predicted
   tables exactly.

---

## 11. Part I → Part II roadmap

Part I covered **project + first-day team** — the static org chart. Part II
(below) exercises the rest of the model and, crucially, the *temporal*
machinery, all in the same `mist` schema:

- **Hierarchy** (§13): Sprints and Tasks as **episodes** linked under MIST with a
  registered `part_of` verb.
- **Meetings** (§14): `'Daily Standup'` / `'Review'` episodes with `attended`
  edges and a document `generated_by` them.
- **Staffing changes** (§15): the real temporal test — Joe leaves, Priya joins,
  via `valid_to` / new `valid_from`.
- **External HR linkage** (§16): `ref_source`/`ref_entity`/`ref_key` attributes.
- **Temporal re-gauntlet** (§17) and **Part II findings** (§18).

---

# Part II — Pass 2 — hierarchy, meetings, and time

> Everything below assumes Part I has been loaded into `mist` and
> `SET search_path = mist, maludb_core, public;` is in effect.

## 12. What Pass 2 adds (and how it maps)

| New real-world thing | MaluDB representation | Notes |
|---|---|---|
| **Sprint 1** ("MIST Sprint 1", 2-week iteration) | **episode**, `episode_kind='Sprint'` | Seeded `episode_type` `'Sprint'` brings its own attribute templates (planned start/end, story points). |
| **A Task** ("Build login screen") | **episode**, `episode_kind='Task'` | Templates: planned start/end, percent_complete, priority. |
| **"Sprint 1 is part of MIST"**, **"Task is part of Sprint 1"** | **SVO statements** with a **registered `part_of` verb**: `episode —part_of→ episode/subject` | ⚠️ `part_of` is **not** a seeded SVPOR verb — only a lineage relationship_type. We must register it. `episode_object` is a valid endpoint kind on both ends. |
| **Daily standup / sprint review** | **episodes**, `episode_kind='Daily Standup'` / `'Review'` | People `attended`; documents `generated_by`. |
| **Planned vs actual dates** | episode `occurred_at`/`occurred_until` = **actual**; `planned_start_date`/`planned_end_date` **attributes** = baseline | The split is deliberate — see [[attribute-template-design]]. |
| **Joe leaves / Priya joins** | `valid_to` set on Joe's `develops` edge; a new `develops` statement for Priya with a later `valid_from` | Statements are append-and-close, never deleted — that's what makes §17's "as of" queries diverge. |
| **Link a person to the HR system** | external-reference **attribute** on the person subject | `ref_source='hr', ref_entity='employees', ref_key=...`; pointer only, no data copied. |

The **locked rule from §5 still holds**: `part_of`, `attended`, `generated_by`
are genuine *relationships* → verbs; everything scalar (dates, points, %, title)
→ attributes.

---

## 13. Step 6 — Sprints and Tasks (episodes + `part_of` hierarchy)

First register the two new verbs the hierarchy needs. **Neither is a seeded
verb** — `assigned` exists only as a seeded verb *type*, not as a verb (only
`attended`/`generated_by`/`made_during` are seeded verbs). Naming the verb
`assigned` lets it auto-classify to the `'assigned'` verb type.

```sql
INSERT INTO mist.maludb_verb (canonical_name, verb_type, aliases, description) VALUES
  ('part_of',  'other',    ARRAY['belongs_to','child_of'], 'Object A is a structural part of object B.'),
  ('assigned', 'assigned', ARRAY['assigned_to','owns'],    'Person is assigned to a task or piece of work.')
ON CONFLICT DO NOTHING;
```

Now create Sprint 1 and a Task as episodes, attach their planned-window
attributes in the same POST (via `maludb_attributes_apply`), and wire the
hierarchy with `part_of` statements. Sprint 1 ran 2013-03-25 → 2013-04-05.

```sql
DO $$
DECLARE
    v_mist   bigint := (SELECT subject_id FROM mist.maludb_subject WHERE canonical_name = 'MIST');
    v_part   bigint := (SELECT verb_id    FROM mist.maludb_verb    WHERE canonical_name = 'part_of');
    v_sprint bigint;
    v_task   bigint;
BEGIN
    -- Sprint 1 (actual window in occurred_at/until).
    v_sprint := mist.maludb_register_episode(
        p_episode_kind => 'Sprint',
        p_title        => 'MIST Sprint 1',
        p_summary      => 'First two-week iteration.',
        p_occurred_at  => '2013-03-25T00:00:00Z'::timestamptz,
        p_occurred_until => '2013-04-05T00:00:00Z'::timestamptz);

    PERFORM mist.maludb_attributes_apply('episode_object', v_sprint, $json$[
        {"attr_name":"planned_start_date","value_timestamp":"2013-03-25T00:00:00Z"},
        {"attr_name":"planned_end_date","value_timestamp":"2013-04-05T00:00:00Z"},
        {"attr_name":"estimated_story_points","value_numeric":21,"unit":"points"}
    ]$json$::jsonb);

    -- A Task inside the sprint.
    v_task := mist.maludb_register_episode(
        p_episode_kind => 'Task',
        p_title        => 'Build login screen',
        p_summary      => 'Implement the MIST login UI + auth wiring.',
        p_occurred_at  => '2013-03-25T00:00:00Z'::timestamptz);

    PERFORM mist.maludb_attributes_apply('episode_object', v_task, $json$[
        {"attr_name":"planned_start_date","value_timestamp":"2013-03-25T00:00:00Z"},
        {"attr_name":"planned_end_date","value_timestamp":"2013-03-29T00:00:00Z"},
        {"attr_name":"percent_complete","value_numeric":0,"unit":"percent"},
        {"attr_name":"priority","value_text":"high"}
    ]$json$::jsonb);

    -- Hierarchy: Sprint 1 —part_of→ MIST ; Task —part_of→ Sprint 1.
    PERFORM mist.maludb_svpor_statement_create(
        p_subject_kind => 'episode_object', p_subject_id => v_sprint,
        p_verb_id      => v_part,
        p_object_kind  => 'subject',        p_object_id  => v_mist,
        p_valid_from   => '2013-03-25T00:00:00Z'::timestamptz);

    PERFORM mist.maludb_svpor_statement_create(
        p_subject_kind => 'episode_object', p_subject_id => v_task,
        p_verb_id      => v_part,
        p_object_kind  => 'episode_object', p_object_id  => v_sprint,
        p_valid_from   => '2013-03-25T00:00:00Z'::timestamptz);

    -- Assign the task to a developer: Joe —assigned→ Task (verb registered above).
    PERFORM mist.maludb_svpor_statement_create(
        p_subject_kind => 'subject',
        p_subject_id   => (SELECT subject_id FROM mist.maludb_subject WHERE canonical_name = 'Joe'),
        p_verb_id      => (SELECT verb_id FROM mist.maludb_verb WHERE canonical_name = 'assigned'),
        p_object_kind  => 'episode_object', p_object_id => v_task,
        p_valid_from   => '2013-03-25T00:00:00Z'::timestamptz);
END $$;
```

> **Both `part_of` and `assigned` were registered in the step above.** Only
> `attended`/`generated_by`/`made_during` ship as seeded verbs; `assigned` is a
> seeded verb *type*, which is a different thing (see finding §18.1).

---

## 14. Step 7 — A meeting and its generated document

Daily standups and reviews are episodes; attendance and artifacts are edges. We
also create a `document` so we can show the `generated_by` lineage edge.

> **Doc bug found live (§18.7).** There is **no** `maludb_register_document`.
> The real document write facade is **`maludb_upload_document`**, with a much
> richer signature than a simple title/body:
> `maludb_upload_document(p_title, p_content_text, p_source_type DEFAULT 'document',
> p_content_jsonb, p_media_type, p_projects, p_subjects, p_verbs, p_events,
> p_metadata_jsonb, p_document_type)`. The `p_document_type` is the soft-picker
> tag (e.g. `'Minutes'`). It returns the new `document_id`.

```sql
DO $$
DECLARE
    v_review bigint;
    v_doc    bigint;
    v_genby  bigint := (SELECT verb_id FROM mist.maludb_verb WHERE canonical_name = 'generated_by');  -- seeded
    v_att    bigint := (SELECT verb_id FROM mist.maludb_verb WHERE canonical_name = 'attended');      -- seeded
    r RECORD;
BEGIN
    v_review := mist.maludb_register_episode(
        p_episode_kind => 'Review',
        p_title        => 'MIST Sprint 1 Review',
        p_summary      => 'Demoed login screen; accepted 18 of 21 points.',
        p_occurred_at  => '2013-04-05T15:00:00Z'::timestamptz);

    PERFORM mist.maludb_attributes_apply('episode_object', v_review, $json$[
        {"attr_name":"duration_minutes","value_numeric":60,"unit":"minutes"}
    ]$json$::jsonb);

    -- The whole team attended the review.
    FOR r IN SELECT subject_id FROM mist.maludb_subject WHERE subject_type = 'person'
    LOOP
        PERFORM mist.maludb_svpor_statement_create(
            p_subject_kind => 'subject',        p_subject_id => r.subject_id,
            p_verb_id      => v_att,
            p_object_kind  => 'episode_object', p_object_id  => v_review,
            p_valid_from   => '2013-04-05T15:00:00Z'::timestamptz);
    END LOOP;

    -- Minutes document, generated by the review.
    v_doc := mist.maludb_upload_document(
        p_title         => 'Sprint 1 Review — Minutes',
        p_content_text  => 'Attendees: Dave, Ed, Joe, Deb, Leticia. Outcome: 18/21 accepted.',
        p_source_type   => 'document',
        p_document_type => 'Minutes');

    PERFORM mist.maludb_svpor_statement_create(
        p_subject_kind => 'document',       p_subject_id => v_doc,
        p_verb_id      => v_genby,
        p_object_kind  => 'episode_object', p_object_id  => v_review,
        p_valid_from   => '2013-04-05T15:00:00Z'::timestamptz);
END $$;
```

> The `generated_by` statement (document → episode) is the part that matters for
> the graph; it's identical regardless of how the document row was created.

---

## 15. Step 8 — Staffing changes (the real temporal test)

This is the whole reason the model carries valid-time. **Nothing is deleted.**
On **2013-06-30 Joe leaves**; on **2013-07-01 Priya joins** as a programmer.

```sql
-- 1) Close Joe's developer role as of his last day. Sets valid_to; the row stays.
SELECT mist.maludb_svpor_statement_close(
    (SELECT st.statement_id
       FROM mist.maludb_svpor_statement st
       JOIN mist.maludb_verb v ON v.verb_id = st.verb_id
      WHERE st.subject_id = (SELECT subject_id FROM mist.maludb_subject WHERE canonical_name = 'Joe')
        AND st.object_id  = (SELECT subject_id FROM mist.maludb_subject WHERE canonical_name = 'MIST')
        AND v.canonical_name = 'develops'),
    '2013-06-30T00:00:00Z'::timestamptz);

-- 2) Priya joins as a subject, then gets a develops role valid from her start.
DO $$
DECLARE
    v_priya bigint;
    v_stmt  bigint;
BEGIN
    -- NB: a conflict target referencing owner_schema is impossible through the
    -- view (it doesn't expose that column). So: bare DO NOTHING, then SELECT.
    INSERT INTO mist.maludb_subject (canonical_name, subject_type, description)
    VALUES ('Priya', 'person', 'MIST programmer (joined 2013-07-01).')
    ON CONFLICT DO NOTHING;
    SELECT subject_id INTO v_priya FROM mist.maludb_subject WHERE canonical_name = 'Priya';

    v_stmt := mist.maludb_svpor_statement_create(
        p_subject_kind => 'subject', p_subject_id => v_priya,
        p_verb_id      => (SELECT verb_id FROM mist.maludb_verb WHERE canonical_name = 'develops'),
        p_object_kind  => 'subject', p_object_id  => (SELECT subject_id FROM mist.maludb_subject WHERE canonical_name = 'MIST'),
        p_valid_from   => '2013-07-01T00:00:00Z'::timestamptz);

    PERFORM mist.maludb_svpor_attribute_create(
        p_target_kind => 'svpor_statement', p_target_id => v_stmt,
        p_attr_name   => 'role_title', p_value_text => 'Programmer');
END $$;
```

---

## 16. Step 9 — External HR linkage (pointer-only reference attribute)

Link each person to the real HR record without copying any HR fields. The
reference is just an attribute whose value is a pointer (`ref_source` /
`ref_entity` / `ref_key`); MaluDB stores the pointer and an optional cached
display label, nothing else.

```sql
-- Example: point Ed's subject at hr.employees row 'E-100'.
SELECT mist.maludb_svpor_attribute_create(
    p_target_kind => 'subject',
    p_target_id   => (SELECT subject_id FROM mist.maludb_subject WHERE canonical_name = 'Ed'),
    p_attr_name   => 'hr_employee',
    p_value_text  => 'Ed Honour',          -- cached display label only
    p_ref_source  => 'hr',
    p_ref_entity  => 'employees',
    p_ref_key     => 'E-100');
```

Reverse lookup ("which graph node is HR employee E-100?") rides the index on
`(owner_schema, ref_source, ref_entity, ref_key)`:

```sql
SELECT target_kind, target_id, value_text AS cached_label
FROM   mist.maludb_svpor_attribute
WHERE  ref_source = 'hr' AND ref_entity = 'employees' AND ref_key = 'E-100';
```

---

## 17. The temporal re-gauntlet

Now the "as of date" query from Q7 returns **different org charts on different
dates** — the payoff of append-and-close.

### Q8 — MIST developers as of three dates

```sql
-- Reusable: who 'develops' MIST as of :as_of ?
WITH params AS (SELECT $1::timestamptz AS as_of)
SELECT p.canonical_name AS developer
FROM   mist.maludb_svpor_statement st
JOIN   mist.maludb_subject p ON p.subject_id = st.subject_id
JOIN   mist.maludb_verb    v ON v.verb_id    = st.verb_id
CROSS JOIN params
WHERE  st.object_id   = (SELECT subject_id FROM mist.maludb_subject WHERE canonical_name = 'MIST')
  AND  st.object_kind = 'subject'
  AND  v.canonical_name = 'develops'
  AND  st.valid_from <= params.as_of
  AND  (st.valid_to IS NULL OR st.valid_to > params.as_of)
ORDER BY developer;
```

**Observed (live) — the org chart genuinely differs by date:**

| `:as_of`       | Developers (observed)                   |
|----------------|-----------------------------------------|
| `2013-03-23`   | Deb, Ed, Joe, Leticia                   |
| `2013-06-30`   | Deb, Ed, Leticia *(Joe closed that day)*|
| `2013-07-01`   | Deb, Ed, Leticia, Priya                 |

(Dave is absent by design — he `manages`, not `develops`. This is the payoff of
append-and-close: the same query, three dates, three different teams.)

### Q9 — Sprint contents via the hierarchy walk

From MIST, walk `part_of` **incoming** edges to reach sprints, then tasks:

```sql
SELECT object_kind, label, depth, rel, path
FROM   mist.maludb_graph_walk(
           'subject',
           (SELECT subject_id FROM mist.maludb_subject WHERE canonical_name = 'MIST'),
           4, 'in', ARRAY['part_of'])
ORDER  BY depth, label;
-- depth 1: episode "MIST Sprint 1"   (Sprint —part_of→ MIST)
-- depth 2: episode "Build login screen" (Task —part_of→ Sprint 1)
```

### Q10 — A task as one object (node + attributes), and the sprint aggregate

```sql
-- Task detail: planned window, %complete, priority, all inline.
SELECT jsonb_pretty(mist.maludb_object_get('episode_object', :task_id));

-- Sprint aggregate. Observed top-level keys: {episode, statements, details}.
-- Attendees/decisions/linked docs ride in `statements` (the SVO edges).
-- NOTE (live): episode_get does NOT include attributes — use object_get for
-- planned dates / story points / % complete. See finding §18.8.
SELECT jsonb_pretty(mist.maludb_episode_get(:sprint_id));
```

**Observed (live).** `object_get('episode_object', task)` returned the task row
**plus** its four attributes (`planned_start_date`, `planned_end_date`,
`percent_complete`, `priority`) **and** its two statements (`part_of` Sprint 1,
`assigned` Joe) — a complete one-call detail payload. `episode_get(sprint)`
returned only `{episode, statements, details}` (no `attributes` key) — the gap
captured in §18.8.

### Q11 — Planned vs actual (attribute meets episode column)

```sql
SELECT  e.title,
        e.occurred_at                        AS actual_start,
        e.occurred_until                     AS actual_end,
        ps.value_timestamp                   AS planned_start,
        pe.value_timestamp                   AS planned_end
FROM    mist.maludb_episode e
LEFT JOIN mist.maludb_svpor_attribute ps
       ON ps.target_kind='episode_object' AND ps.target_id=e.episode_id AND ps.attr_name='planned_start_date'
LEFT JOIN mist.maludb_svpor_attribute pe
       ON pe.target_kind='episode_object' AND pe.target_id=e.episode_id AND pe.attr_name='planned_end_date'
WHERE   e.episode_kind IN ('Sprint','Task')
ORDER BY actual_start;
```

---

## 18. Part II findings

1. **`part_of` not being seeded is a sharp edge.** `attended`/`generated_by`/
   `made_during` are seeded but the most common structural verb, `part_of`, is
   not — it exists only as a lineage relationship_type. A loader that assumes it
   exists gets an endpoint/verb-lookup miss. **← seed `part_of` as an SVPOR verb,
   or document the gap.** (Backlog candidate.)
2. **Planned-vs-actual split works but needs the two-source join (Q11).** Actual
   lives in episode columns, planned in attributes. Correct and flexible, but
   every "are we on schedule?" query joins the attribute table twice. A
   `*_with_attributes` view over `maludb_episode` would flatten this.
3. **Append-and-close is the model's best moment (Q8).** Closing Joe's statement
   instead of deleting it makes time-travel queries fall out for free, and the
   history is auditable. This is where SVPOR clearly beats a plain
   `assignments` table.
4. **Hierarchy traversal is clean (Q9).** `graph_walk(..., 'in', ARRAY['part_of'])`
   returns the sprint→task tree with paths in one call across episode/subject
   kinds — no recursive CTE hand-rolling. Strong.
5. **Edge-attribute friction (finding #3, Part I) recurs** for Priya's new
   `role_title` and any future edge property — reinforcing the `edge_get`
   backlog item rather than adding a new concern.
6. **Verb *type* vs verb is an easy confusion.** `assigned` is a seeded verb
   *type* (`malu$svpor_verb_type`) but **not** a seeded verb — the type catalog
   has 30 entries while only 3 verbs ship. A loader that assumes "the type
   exists, so the verb exists" gets a NULL `verb_id`. Both `part_of` and
   `assigned` had to be registered. Worth either seeding a PM-oriented verb set
   or documenting the type-vs-verb distinction prominently.

*Findings 1, 4, 5, 6 were confirmed in the live run. Two more came out of it:*

7. **The document write facade is `maludb_upload_document`, not
   `maludb_register_document`** — the latter does not exist at all. The real
   signature is the rich `(p_title, p_content_text, p_source_type, p_content_jsonb,
   p_media_type, p_projects, p_subjects, p_verbs, p_events, p_metadata_jsonb,
   p_document_type)`; it returns a `document_id` and even takes inline
   subject/verb/event arrays so a document can be cross-linked at upload time.
   The original §14 draft invented a `register_document(title, body)` that failed
   immediately. (Fixed in §14.)
8. **`episode_get` bundles `{episode, statements, details}` — but NOT
   attributes.** Q10b confirmed the top-level keys are exactly `details`,
   `episode`, `statements`. Attendees/decisions/linked docs come through
   `statements` (the SVO edges), which is great — but planned dates, story points,
   and % complete (which are *attributes*) are absent. For the full picture use
   `object_get('episode_object', id)`, which *does* fold attributes in (Q10).
   Worth aligning the two, or documenting that `object_get` is the richer call.

---

## 19. Next steps

- ✅ ~~Execute live; replace predictions with observed output.~~ **Done** — all
  result tables above are real psql output (2026-05-31). Runnable scripts live in
  [`examples/mist-e2e/`](examples/mist-e2e/).
- ✅ ~~Confirm the document write facade.~~ **Done** — it is `maludb_upload_document`,
  not `maludb_register_document` (§14, §18.7).
- **Pass 3 ideas:** blocked/resolved task state transitions — register `blocked`
  and `resolved` **verbs** first (they ship as seeded verb *types* only, same gap
  as `part_of`/`assigned`), then model transitions as more closing statements; a
  second sprint to make the Q9 `part_of` walk a real multi-branch tree; semantic
  entry (`register_object_embedding` + `semantic_search`) so "find the login work"
  resolves to an `(object_kind, object_id)` and then `graph_walk`s — exercising
  the 0.86.0 semantic rail end to end.
- **Productize the backlog findings:** an `edge_get(statement_id)` bundler (§10.3),
  an attributes-bundling episode view (§18.2 / §18.8), `graph_walk` node-dedup
  (§10.7), and a seeded PM verb set so `part_of`/`assigned`/`blocked`/`resolved`
  aren't manual every time (§18.6).

---

## Appendix — verified surface used by this test (0.86.1)

| Object | Signature (key args) |
|---|---|
| `maludb_core.enable_memory_schema` | `(p_schema name DEFAULT current_schema()) → TABLE(schema_name, enabled_version, object_count)` |
| `maludb_subject` (view) | `subject_id, subject_type, canonical_name, aliases, description, created_at, classifier_md` |
| `maludb_verb` (view) | `verb_id, canonical_name, aliases, description, created_at, verb_type, search_phrases, classifier_md` |
| `maludb_svpor_statement_create` | `(p_subject_kind, p_subject_id, p_verb_id, p_object_kind, p_object_id, p_predicate_id=NULL, p_valid_from=NULL, p_valid_to=NULL, p_confidence=NULL, p_provenance='provided', p_source_package_id=NULL, p_metadata_jsonb='{}') → bigint` |
| `maludb_svpor_statement_close` | `(p_statement_id, p_valid_to DEFAULT now()) → boolean` |
| `maludb_svpor_attribute_create` | `(p_target_kind, p_target_id, p_attr_name, p_value_timestamp=NULL, p_value_range=NULL, p_value_numeric=NULL, p_value_text=NULL, p_value_jsonb=NULL, p_unit=NULL, p_provenance='provided', p_confidence=NULL, p_valid_from=NULL, p_valid_to=NULL, p_metadata_jsonb='{}', p_ref_source=NULL, p_ref_entity=NULL, p_ref_key=NULL) → bigint` |
| `maludb_attributes_apply` | `(p_target_kind, p_target_id, p_attributes jsonb) → integer` — array of `{attr_name, value_*?, unit?, provenance?, confidence?, valid_from?, valid_to?, ref_*?}` |
| `maludb_object_get` | `(p_target_kind, p_target_id) → jsonb` |
| `maludb_register_episode` | `(p_episode_kind, p_title, p_summary=NULL, p_payload_jsonb='{}', p_occurred_at=NULL, p_occurred_until=NULL, p_sensitivity='internal', p_provenance='provided') → bigint` |
| `maludb_attribute_template_create` | `(p_applies_to, p_type_value, p_attr_name, p_value_type, p_requirement='optional', p_label=NULL, p_description=NULL, p_unit=NULL, p_allowed_values=NULL, p_default_value=NULL, p_display_order=NULL) → bigint` |
| `maludb_attribute_check` | `(p_target_kind, p_target_id) → jsonb` |
| `maludb_graph_neighbors` | `(p_kind, p_id, p_direction='both', p_rel_filter text[]=NULL) → TABLE(neighbor_kind, neighbor_id, rel, edge_store, confidence, provenance, label)` |
| `maludb_graph_walk` | `(p_kind, p_id, p_max_depth=4, p_direction='both', p_rel_filter text[]=NULL) → TABLE(object_kind, object_id, depth, rel, edge_store, label, path)` |
| `maludb_edge` (view) | `edge_store, edge_id, source_kind, source_id, rel, target_kind, target_id, confidence, provenance` |
| Valid statement endpoint kinds | `subject, verb, document, episode_object, memory, source_package, claim, fact, memory_detail_object` |
| Seeded SVPOR verbs | `attended, generated_by, made_during` |
| Verbs **registered by this test** | `manages, administers, develops` (Part I); `part_of, assigned` (Part II — **not seeded** as verbs, see finding §18.1) |
| Seeded verb *types* (used) | `assigned, created, other`, … (30 total) — a verb *type* is not a verb; the `assigned` verb must still be registered |
| Seeded `subject_type` (used) | `project, person` (+ ai_agent, equipment, software, …) |
| Seeded `episode_type` (used) | `Planning, Sprint, Task, Review` (+ Meeting, Daily Standup, Retrospective, 1:1, Incident, Project) |
| Seeded attribute templates (used) | Sprint: `planned_start_date, planned_end_date, estimated_story_points`; Task: `planned_start_date, planned_end_date, percent_complete, priority`; Meeting: `duration_minutes` |
