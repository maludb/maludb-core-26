# Note Document SVPOR Hints Release Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the first release slices for note-as-document SVPOR hints, governed subject/verb identifier vocabularies, and SVPOR relationship/search phrase support.

**Architecture:** Notes remain `malu$document` rows with `source_type = 'note'`; promotion to `malu$memory` happens later and reads the document plus its hints. Individual hints stay in `malu$document_tag`, while explicit combinations live in a new `malu$document_svpor_hint` table. Subject and verb identifiers use governed type registries so UI labels such as `Project`, `AI Agent`, and `Installed` normalize to stable lowercase slugs for search and routing. Relationship edges can connect subjects and verbs directly, while natural-language phrases such as `Server Configuration` remain search phrases for canonical verbs such as `configured`.

**Tech Stack:** PostgreSQL extension SQL, PL/pgSQL, pg_regress, MaluDB REST endpoint catalog.

---

## Release Coordination

This plan starts the next schema/process release after `0.74.0`. Use `0.75.0` for this first implementation pass unless the release number changes before execution. When new release items are discovered, add new numbered tasks before the final release integration task and keep each item testable on its own.

## File Structure

- Modify: `maludb_core.control` to bump `default_version`.
- Modify: `Makefile` to add the new upgrade script and regression test.
- Create: `sql/extension/maludb_core--0.74.0--0.75.0.sql` for upgrade-only DDL/functions/catalog registrations.
- Create: `sql/extension/maludb_core--0.75.0.sql` as the full install script generated from `0.74.0` plus the upgrade script.
- Create: `sql/document_note_svpor_hints.sql` for regression coverage.
- Create: `expected/document_note_svpor_hints.out` after the implementation passes.
- Create: `sql/svpor_identifier_types.sql` for subject/verb type vocabulary regression coverage.
- Create: `expected/svpor_identifier_types.out` after the implementation passes.
- Create: `sql/svpor_relationship_search_phrases.sql` for subject/verb relationship and verb search phrase regression coverage.
- Create: `expected/svpor_relationship_search_phrases.out` after the implementation passes.
- Modify: `services/maludb-restd/tests/test_smoke.py` to verify the seeded REST catalog has the typed endpoints for note creation and document reads.

### Task 1: Write Failing Regression Coverage

**Files:**
- Create: `sql/document_note_svpor_hints.sql`
- Modify: `Makefile`

- [ ] **Step 1: Add the regression test name**

In `Makefile`, append `document_note_svpor_hints` to the end of the `REGRESS = ...` list after `role_onboarding`.

- [ ] **Step 2: Create `sql/document_note_svpor_hints.sql`**

```sql
\set ECHO all
\pset format unaligned
SET client_min_messages = WARNING;
CREATE EXTENSION IF NOT EXISTS maludb_core CASCADE;

SET search_path TO maludb_core, public;

DROP SCHEMA IF EXISTS note_hint_a CASCADE;
DROP ROLE IF EXISTS note_hint_user;

CREATE ROLE note_hint_user NOLOGIN;
GRANT maludb_memory_executor TO note_hint_user;
GRANT USAGE ON SCHEMA maludb_core TO note_hint_user;
CREATE SCHEMA note_hint_a AUTHORIZATION note_hint_user;

SET ROLE note_hint_user;
SET search_path TO note_hint_a, maludb_core, public;

SELECT object_count > 0 AS enabled
FROM maludb_core.enable_memory_schema();

SELECT maludb_quick_add_note(
    p_title => 'multi hint note',
    p_body_text => 'Remember to test notes as documents before promotion.',
    p_projects => ARRAY['Project A', 'Project B'],
    p_subjects => ARRAY['Subject A', 'Subject B'],
    p_verbs => ARRAY['decided', 'verified'],
    p_svpor_frames => jsonb_build_array(
        jsonb_build_object('project', 'Project A', 'subject', 'Subject A', 'verb', 'decided'),
        jsonb_build_object('project', 'Project B', 'subject', 'Subject B', 'verb', 'verified'),
        jsonb_build_object('subject', 'Subject A', 'verb', 'verified')
    ),
    p_metadata_jsonb => jsonb_build_object('origin', 'quick_add')
) AS document_id \gset

SELECT source_type, title, media_type, metadata_jsonb ->> 'origin' AS origin
FROM maludb_document
WHERE document_id = :document_id;

SELECT tag_kind, array_agg(tag_value ORDER BY tag_value) AS values
FROM maludb_document_tag
WHERE document_id = :document_id
GROUP BY tag_kind
ORDER BY tag_kind;

SELECT project_name, subject_name, verb_name, provenance
FROM maludb_document_svpor_hint
WHERE document_id = :document_id
ORDER BY hint_id;

SELECT maludb_document_get(:document_id)::jsonb ? 'document' AS has_document,
       jsonb_array_length(maludb_document_get(:document_id)::jsonb -> 'tags') AS tag_count,
       jsonb_array_length(maludb_document_get(:document_id)::jsonb -> 'svpor_hints') AS frame_count;

RESET ROLE;
SET search_path TO maludb_core, public;

DELETE FROM malu$document_svpor_hint WHERE owner_schema = 'note_hint_a';
DELETE FROM malu$document_tag WHERE owner_schema = 'note_hint_a';
DELETE FROM malu$document WHERE owner_schema = 'note_hint_a';
DELETE FROM malu$source_package WHERE owner_schema = 'note_hint_a';
DELETE FROM malu$enabled_schema_object WHERE schema_name = 'note_hint_a';
DELETE FROM malu$enabled_schema WHERE schema_name = 'note_hint_a';
DROP SCHEMA note_hint_a CASCADE;
DROP OWNED BY note_hint_user;
DROP ROLE note_hint_user;
```

- [ ] **Step 3: Run the test and verify it fails for the missing API**

Run: `make installcheck REGRESS=document_note_svpor_hints`

Expected: `document_note_svpor_hints` fails with an error that `maludb_quick_add_note` does not exist.

- [ ] **Step 4: Commit the failing test**

```bash
git add Makefile sql/document_note_svpor_hints.sql
git commit -m "test: cover note document SVPOR hints"
```

### Task 2: Add Core Table and Note Source Type

**Files:**
- Create: `sql/extension/maludb_core--0.74.0--0.75.0.sql`

- [ ] **Step 1: Create the upgrade script header and version function**

```sql
\echo Use "ALTER EXTENSION maludb_core UPDATE TO '0.75.0'" to load this file. \quit

-- ---------------------------------------------------------------------
-- maludb_core 0.74.0 -> 0.75.0
-- Note documents with explicit SVPOR hint frames.
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION maludb_core.maludb_core_version() RETURNS text
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$ SELECT '0.75.0'::text $body$;
```

- [ ] **Step 2: Seed the note source type**

Add this after the version function:

```sql
INSERT INTO maludb_core.malu$source_type(source_type, stage, description)
VALUES ('note', 2, 'End-user quick-added note stored as a document source.')
ON CONFLICT (source_type) DO UPDATE
    SET stage = EXCLUDED.stage,
        description = EXCLUDED.description;
```

- [ ] **Step 3: Create `malu$document_svpor_hint`**

Add this DDL:

```sql
CREATE TABLE maludb_core.malu$document_svpor_hint (
    hint_id            bigserial PRIMARY KEY,
    owner_schema       name NOT NULL DEFAULT current_schema(),
    document_id        bigint NOT NULL,
    project_subject_id bigint REFERENCES maludb_core.malu$svpor_subject(subject_id) ON DELETE SET NULL,
    project_name       text,
    subject_id         bigint REFERENCES maludb_core.malu$svpor_subject(subject_id) ON DELETE SET NULL,
    subject_name       text,
    verb_id            bigint REFERENCES maludb_core.malu$svpor_verb(verb_id) ON DELETE SET NULL,
    verb_name          text,
    provenance         text NOT NULL DEFAULT 'provided'
        CHECK (provenance IN ('provided','suggested','accepted','rejected')),
    confidence         numeric(5,4) CHECK (confidence IS NULL OR confidence BETWEEN 0 AND 1),
    metadata_jsonb     jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at         timestamptz NOT NULL DEFAULT now(),
    CHECK (
        project_subject_id IS NOT NULL OR NULLIF(project_name, '') IS NOT NULL OR
        subject_id IS NOT NULL OR NULLIF(subject_name, '') IS NOT NULL OR
        verb_id IS NOT NULL OR NULLIF(verb_name, '') IS NOT NULL
    ),
    FOREIGN KEY (owner_schema, document_id)
        REFERENCES maludb_core.malu$document(owner_schema, document_id) ON DELETE CASCADE
);

CREATE INDEX malu$document_svpor_hint_document_idx
    ON maludb_core.malu$document_svpor_hint(document_id);
CREATE INDEX malu$document_svpor_hint_lookup_idx
    ON maludb_core.malu$document_svpor_hint(owner_schema, project_name, subject_name, verb_name);

ALTER TABLE maludb_core.malu$document_svpor_hint ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_owner ON maludb_core.malu$document_svpor_hint
    USING (owner_schema = current_schema())
    WITH CHECK (owner_schema = current_schema());

GRANT SELECT ON maludb_core.malu$document_svpor_hint TO
    maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;
GRANT INSERT, UPDATE, DELETE ON maludb_core.malu$document_svpor_hint TO
    maludb_memory_admin, maludb_memory_executor;
GRANT USAGE, SELECT ON SEQUENCE maludb_core.malu$document_svpor_hint_hint_id_seq TO
    maludb_memory_admin, maludb_memory_executor;
```

- [ ] **Step 4: Run the failing regression again**

Run: `make installcheck REGRESS=document_note_svpor_hints`

Expected: the test still fails because `maludb_quick_add_note` is not defined yet.

- [ ] **Step 5: Commit the table slice**

```bash
git add sql/extension/maludb_core--0.74.0--0.75.0.sql
git commit -m "feat: add document SVPOR hint table"
```

### Task 3: Add Note Upload and Frame Writers

**Files:**
- Modify: `sql/extension/maludb_core--0.74.0--0.75.0.sql`

- [ ] **Step 1: Add a helper that inserts explicit frame hints**

Append this function:

```sql
CREATE FUNCTION maludb_core._insert_document_svpor_hints_for_schema(
    p_owner_schema name,
    p_document_id bigint,
    p_svpor_frames jsonb DEFAULT '[]'::jsonb
) RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
DECLARE
    v_frame jsonb;
    v_count integer := 0;
BEGIN
    PERFORM maludb_core._memory_schema_assert_manageable(p_owner_schema);

    IF p_svpor_frames IS NULL THEN
        RETURN 0;
    END IF;
    IF jsonb_typeof(p_svpor_frames) <> 'array' THEN
        RAISE EXCEPTION 'svpor_frames must be a JSON array'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    FOR v_frame IN SELECT value FROM jsonb_array_elements(p_svpor_frames)
    LOOP
        IF jsonb_typeof(v_frame) <> 'object' THEN
            RAISE EXCEPTION 'each svpor frame must be a JSON object'
                USING ERRCODE = 'invalid_parameter_value';
        END IF;

        INSERT INTO maludb_core.malu$document_svpor_hint(
            owner_schema, document_id,
            project_subject_id, project_name,
            subject_id, subject_name,
            verb_id, verb_name,
            provenance, confidence, metadata_jsonb
        )
        VALUES (
            p_owner_schema, p_document_id,
            NULLIF(v_frame ->> 'project_id', '')::bigint,
            NULLIF(btrim(v_frame ->> 'project'), ''),
            NULLIF(v_frame ->> 'subject_id', '')::bigint,
            NULLIF(btrim(v_frame ->> 'subject'), ''),
            NULLIF(v_frame ->> 'verb_id', '')::bigint,
            NULLIF(btrim(v_frame ->> 'verb'), ''),
            COALESCE(NULLIF(v_frame ->> 'provenance', ''), 'provided'),
            NULLIF(v_frame ->> 'confidence', '')::numeric,
            COALESCE(v_frame -> 'metadata', '{}'::jsonb)
        );
        v_count := v_count + 1;
    END LOOP;

    RETURN v_count;
END;
$body$;

REVOKE ALL ON FUNCTION maludb_core._insert_document_svpor_hints_for_schema(name, bigint, jsonb) FROM PUBLIC;
```

- [ ] **Step 2: Add `quick_add_note`**

Append this function:

```sql
CREATE FUNCTION maludb_core.quick_add_note(
    p_title text,
    p_body_text text,
    p_projects text[] DEFAULT ARRAY[]::text[],
    p_subjects text[] DEFAULT ARRAY[]::text[],
    p_verbs text[] DEFAULT ARRAY[]::text[],
    p_svpor_frames jsonb DEFAULT '[]'::jsonb,
    p_metadata_jsonb jsonb DEFAULT '{}'::jsonb
) RETURNS bigint
LANGUAGE plpgsql
SECURITY INVOKER
AS $body$
DECLARE
    v_document_id bigint;
BEGIN
    v_document_id := maludb_core.upload_document(
        p_title => p_title,
        p_content_text => p_body_text,
        p_source_type => 'note',
        p_content_jsonb => NULL,
        p_media_type => 'text/plain',
        p_projects => p_projects,
        p_subjects => p_subjects,
        p_verbs => p_verbs,
        p_events => ARRAY[]::text[],
        p_metadata_jsonb => COALESCE(p_metadata_jsonb, '{}'::jsonb)
    );

    PERFORM maludb_core._insert_document_svpor_hints_for_schema(
        current_schema()::name,
        v_document_id,
        COALESCE(p_svpor_frames, '[]'::jsonb)
    );

    RETURN v_document_id;
END;
$body$;

REVOKE ALL ON FUNCTION maludb_core.quick_add_note(text, text, text[], text[], text[], jsonb, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core.quick_add_note(text, text, text[], text[], text[], jsonb, jsonb)
TO maludb_memory_admin, maludb_memory_executor;
```

- [ ] **Step 3: Run the regression**

Run: `make installcheck REGRESS=document_note_svpor_hints`

Expected: the test fails because schema-local `maludb_quick_add_note`, `maludb_document_svpor_hint`, and `maludb_document_get` are not available yet.

- [ ] **Step 4: Commit the note writer slice**

```bash
git add sql/extension/maludb_core--0.74.0--0.75.0.sql
git commit -m "feat: add quick note document writer"
```

### Task 4: Add Schema-Local Facades and Document Payload Reads

**Files:**
- Modify: `sql/extension/maludb_core--0.74.0--0.75.0.sql`

- [ ] **Step 1: Replace `_enable_memory_schema_ingest_facade`**

Copy the current `CREATE FUNCTION _enable_memory_schema_ingest_facade(p_schema name)` body from `sql/extension/maludb_core--0.74.0.sql`, change the declaration to `CREATE OR REPLACE FUNCTION`, then add these objects before its `RETURN v_count;`:

```sql
    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_document_svpor_hint', 'view');
    EXECUTE format($sql$
        CREATE OR REPLACE VIEW %I.maludb_document_svpor_hint WITH (security_invoker = true) AS
        SELECT hint_id,
               document_id,
               project_subject_id,
               project_name,
               subject_id,
               subject_name,
               verb_id,
               verb_name,
               provenance,
               confidence,
               metadata_jsonb,
               created_at
          FROM maludb_core.malu$document_svpor_hint
         WHERE owner_schema = %L
        WITH LOCAL CHECK OPTION
    $sql$, p_schema, p_schema);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON %I.maludb_document_svpor_hint TO maludb_memory_admin, maludb_memory_executor', p_schema);
    EXECUTE format('GRANT SELECT ON %I.maludb_document_svpor_hint TO maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_document_svpor_hint', 'view', 'Schema-local document SVPOR hint facade.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_quick_add_note', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_quick_add_note(
            p_title text,
            p_body_text text,
            p_projects text[] DEFAULT ARRAY[]::text[],
            p_subjects text[] DEFAULT ARRAY[]::text[],
            p_verbs text[] DEFAULT ARRAY[]::text[],
            p_svpor_frames jsonb DEFAULT '[]'::jsonb,
            p_metadata_jsonb jsonb DEFAULT '{}'::jsonb
        ) RETURNS bigint
        LANGUAGE sql
        SECURITY INVOKER
        SET search_path = %I, maludb_core, pg_temp
        AS $facade$
            SELECT maludb_core.quick_add_note(
                p_title, p_body_text, p_projects, p_subjects, p_verbs,
                p_svpor_frames, p_metadata_jsonb
            )
        $facade$
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_quick_add_note(text, text, text[], text[], text[], jsonb, jsonb) FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_quick_add_note(text, text, text[], text[], text[], jsonb, jsonb) TO maludb_memory_admin, maludb_memory_executor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_quick_add_note', 'function', 'Schema-local quick note upload facade.');
    v_count := v_count + 1;
```

- [ ] **Step 2: Add `document_get`**

Append this function after the facade replacement:

```sql
CREATE FUNCTION maludb_core.document_get(p_document_id bigint)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY INVOKER
AS $body$
    SELECT jsonb_build_object(
        'document', to_jsonb(d),
        'tags', COALESCE((
            SELECT jsonb_agg(to_jsonb(t) ORDER BY t.tag_kind, t.tag_value, t.tag_id)
              FROM maludb_core.malu$document_tag t
             WHERE t.owner_schema = d.owner_schema
               AND t.document_id = d.document_id
        ), '[]'::jsonb),
        'svpor_hints', COALESCE((
            SELECT jsonb_agg(to_jsonb(h) ORDER BY h.hint_id)
              FROM maludb_core.malu$document_svpor_hint h
             WHERE h.owner_schema = d.owner_schema
               AND h.document_id = d.document_id
        ), '[]'::jsonb)
    )
    FROM maludb_core.malu$document d
    WHERE d.owner_schema = current_schema()
      AND d.document_id = p_document_id
$body$;

REVOKE ALL ON FUNCTION maludb_core.document_get(bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core.document_get(bigint)
TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;
```

- [ ] **Step 3: Add schema-local `maludb_document_get` to the facade function**

Add this before `RETURN v_count;` in the replaced `_enable_memory_schema_ingest_facade`:

```sql
    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_document_get', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_document_get(p_document_id bigint)
        RETURNS jsonb
        LANGUAGE sql
        STABLE
        SECURITY INVOKER
        SET search_path = %I, maludb_core, pg_temp
        AS $facade$
            SELECT maludb_core.document_get(p_document_id)
        $facade$
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_document_get(bigint) FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_document_get(bigint) TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_document_get', 'function', 'Schema-local document payload reader.');
    v_count := v_count + 1;
```

- [ ] **Step 4: Run the regression**

Run: `make installcheck REGRESS=document_note_svpor_hints`

Expected: the test passes or fails only because `expected/document_note_svpor_hints.out` has not been created.

- [ ] **Step 5: Commit the facade/read slice**

```bash
git add sql/extension/maludb_core--0.74.0--0.75.0.sql
git commit -m "feat: expose note document SVPOR hints"
```

### Task 5: Register REST Endpoints

**Files:**
- Modify: `sql/extension/maludb_core--0.74.0--0.75.0.sql`
- Modify: `services/maludb-restd/tests/test_smoke.py`

- [ ] **Step 1: Add endpoint catalog rows**

Append this SQL:

```sql
SELECT rest_register_endpoint(
    'POST', '/v3/note',
    'quick_add_note(text,text,text[],text[],text[],jsonb,jsonb)'::regprocedure,
    'Quick-add a note as a document with SVPOR hints.',
    ARRAY['document.write']::text[], 'state_changing', '{}'::jsonb, true,
    30000, 1048576, 65536,
    jsonb_build_array(
        _v3_api_arg('p_title',          'text'),
        _v3_api_arg('p_body_text',      'text'),
        _v3_api_arg('p_projects',       'text[]', false),
        _v3_api_arg('p_subjects',       'text[]', false),
        _v3_api_arg('p_verbs',          'text[]', false),
        _v3_api_arg('p_svpor_frames',   'jsonb',  false),
        _v3_api_arg('p_metadata_jsonb', 'jsonb',  false)));

SELECT rest_register_endpoint(
    'GET', '/v3/document',
    'document_get(bigint)'::regprocedure,
    'Read a document with tags and SVPOR hints.',
    ARRAY['document.read']::text[], 'read_only', '{}'::jsonb, true,
    30000, 1048576, 65536,
    jsonb_build_array(
        _v3_api_arg('p_document_id', 'bigint', true, 'query')));
```

- [ ] **Step 2: Add REST smoke catalog checks**

In `services/maludb-restd/tests/test_smoke.py`, add a test after the typed-arg memory test:

```python
    def test_09_note_document_endpoints_are_registered(self):
        with _conn() as c, c.cursor() as cur:
            cur.execute("SET search_path TO maludb_core, public")
            cur.execute(
                """
                SELECT method, path
                FROM rest_list_endpoints(true)
                WHERE path IN ('/v3/note', '/v3/document')
                ORDER BY path, method
                """
            )
            rows = cur.fetchall()
        self.assertEqual(rows, [("GET", "/v3/document"), ("POST", "/v3/note")])
```

Rename the current `test_09_typed_arg_missing_required` to `test_10_typed_arg_missing_required`.

- [ ] **Step 3: Run focused REST smoke tests**

Run: `python3 -m unittest services.maludb-restd.tests.test_smoke -v`

Expected: either all REST smoke tests pass, or the environment reports a missing running REST service/database. If the service is unavailable, record that in the final implementation notes and rely on pg_regress for database verification.

- [ ] **Step 4: Commit the REST slice**

```bash
git add sql/extension/maludb_core--0.74.0--0.75.0.sql services/maludb-restd/tests/test_smoke.py
git commit -m "feat: register note document REST endpoints"
```

### Task 6: Write Failing Coverage for Subject and Verb Types

**Files:**
- Create: `sql/svpor_identifier_types.sql`
- Modify: `Makefile`

- [ ] **Step 1: Add the regression test name**

In `Makefile`, append `svpor_identifier_types` to the end of the `REGRESS = ...` list after `document_note_svpor_hints`.

- [ ] **Step 2: Create `sql/svpor_identifier_types.sql`**

```sql
\set ECHO all
\pset format unaligned
SET client_min_messages = WARNING;
CREATE EXTENSION IF NOT EXISTS maludb_core CASCADE;

SET search_path TO maludb_core, public;

DROP SCHEMA IF EXISTS svpor_type_a CASCADE;
DROP ROLE IF EXISTS svpor_type_user;

CREATE ROLE svpor_type_user NOLOGIN;
GRANT maludb_memory_executor TO svpor_type_user;
GRANT USAGE ON SCHEMA maludb_core TO svpor_type_user;
CREATE SCHEMA svpor_type_a AUTHORIZATION svpor_type_user;

SET ROLE svpor_type_user;
SET search_path TO svpor_type_a, maludb_core, public;

SELECT object_count > 0 AS enabled
FROM maludb_core.enable_memory_schema();

SELECT subject_type, display_name
FROM maludb_subject_type
WHERE subject_type IN (
    'project','person','ai_agent','equipment','software','network',
    'event','process','workflow','time_period','other'
)
ORDER BY sort_order;

SELECT verb_type, display_name, semantic_class
FROM maludb_verb_type
WHERE verb_type IN (
    'installed','attended','configured','verified','decided',
    'resolved','failed','documented','migrated','deployed'
)
ORDER BY sort_order;

INSERT INTO maludb_subject(subject_type, canonical_name, aliases)
VALUES ('AI Agent', 'Ops Assistant', ARRAY['ops-ai'])
RETURNING subject_type, canonical_name;

INSERT INTO maludb_subject(subject_type, canonical_name)
VALUES ('Time Period', '2026 Q2')
RETURNING subject_type, canonical_name;

INSERT INTO maludb_verb(verb_type, canonical_name, aliases)
VALUES ('Installed', 'Installed', ARRAY['installed on'])
RETURNING verb_type, canonical_name;

INSERT INTO maludb_verb(verb_type, canonical_name)
VALUES ('Attended', 'Attended')
RETURNING verb_type, canonical_name;

SELECT subject_type, canonical_name
FROM maludb_subject
WHERE canonical_name IN ('Ops Assistant', '2026 Q2')
ORDER BY canonical_name;

SELECT verb_type, canonical_name
FROM maludb_verb
WHERE canonical_name IN ('Installed', 'Attended')
ORDER BY canonical_name;

RESET ROLE;
SET search_path TO maludb_core, public;

DELETE FROM malu$svpor_verb WHERE owner_schema = 'svpor_type_a';
DELETE FROM malu$svpor_subject WHERE owner_schema = 'svpor_type_a';
DELETE FROM malu$enabled_schema_object WHERE schema_name = 'svpor_type_a';
DELETE FROM malu$enabled_schema WHERE schema_name = 'svpor_type_a';
DROP SCHEMA svpor_type_a CASCADE;
DROP OWNED BY svpor_type_user;
DROP ROLE svpor_type_user;
```

- [ ] **Step 3: Run the test and verify it fails for missing type facades**

Run: `make installcheck REGRESS=svpor_identifier_types`

Expected: `svpor_identifier_types` fails because `maludb_subject_type`, `maludb_verb_type`, or `maludb_verb.verb_type` does not exist.

- [ ] **Step 4: Commit the failing test**

```bash
git add Makefile sql/svpor_identifier_types.sql
git commit -m "test: cover SVPOR subject and verb types"
```

### Task 7: Add Governed Subject and Verb Type Registries

**Files:**
- Modify: `sql/extension/maludb_core--0.74.0--0.75.0.sql`

- [ ] **Step 1: Add registry tables and seed values**

Append this SQL after the note-document DDL in the upgrade script:

```sql
CREATE TABLE maludb_core.malu$svpor_subject_type (
    subject_type   text PRIMARY KEY,
    display_name   text NOT NULL,
    description    text,
    sort_order     integer NOT NULL,
    system_defined boolean NOT NULL DEFAULT true,
    created_at     timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE maludb_core.malu$svpor_verb_type (
    verb_type      text PRIMARY KEY,
    display_name   text NOT NULL,
    semantic_class text NOT NULL DEFAULT 'action'
        CHECK (semantic_class IN ('action','state','event','decision','communication','verification','failure','planning','documentation','other')),
    description    text,
    sort_order     integer NOT NULL,
    system_defined boolean NOT NULL DEFAULT true,
    created_at     timestamptz NOT NULL DEFAULT now()
);

INSERT INTO maludb_core.malu$svpor_subject_type(subject_type, display_name, description, sort_order) VALUES
    ('project',     'Project',     'Project, program, initiative, or engagement.', 10),
    ('person',      'Person',      'Human actor, stakeholder, customer, operator, or participant.', 20),
    ('ai_agent',    'AI Agent',    'Autonomous or assisted AI agent identity.', 30),
    ('equipment',   'Equipment',   'Physical device, machine, server, appliance, or tool.', 40),
    ('software',    'Software',    'Application, service, package, library, or software component.', 50),
    ('network',     'Network',     'Network, subnet, route, connection, or communications domain.', 60),
    ('event',       'Event',       'Incident, meeting, deployment, outage, milestone, or occurrence.', 70),
    ('process',     'Process',     'Business, operational, or technical process.', 80),
    ('workflow',    'Workflow',    'Repeatable ordered activity or procedure.', 90),
    ('time_period', 'Time Period', 'Date, range, quarter, sprint, release window, or named period.', 100),
    ('other',       'Other',       'Fallback subject type when no more specific type applies.', 900),
    ('stakeholder', 'Stakeholder', 'Legacy compatibility type for existing stakeholder facades.', 910),
    ('concept',     'Concept',     'Legacy compatibility type for pre-typed SVPOR subjects.', 920)
ON CONFLICT (subject_type) DO UPDATE
    SET display_name = EXCLUDED.display_name,
        description = EXCLUDED.description,
        sort_order = EXCLUDED.sort_order,
        system_defined = true;

INSERT INTO maludb_core.malu$svpor_verb_type(verb_type, display_name, semantic_class, description, sort_order) VALUES
    ('installed',    'Installed',    'action',        'Installed equipment, software, services, or configuration.', 10),
    ('configured',   'Configured',   'action',        'Configured settings, infrastructure, accounts, or policies.', 20),
    ('attended',     'Attended',     'event',         'Attended a meeting, event, review, or session.', 30),
    ('created',      'Created',      'action',        'Created an object, record, artifact, account, or environment.', 40),
    ('updated',      'Updated',      'action',        'Updated an existing object, record, artifact, or configuration.', 50),
    ('removed',      'Removed',      'action',        'Removed, deleted, retired, or decommissioned something.', 60),
    ('migrated',     'Migrated',     'action',        'Moved data, services, systems, or users between states or platforms.', 70),
    ('deployed',     'Deployed',     'action',        'Deployed a release, service, configuration, or artifact.', 80),
    ('tested',       'Tested',       'verification',  'Tested behavior, performance, integration, or acceptance.', 90),
    ('verified',     'Verified',     'verification',  'Verified a result, state, fact, or requirement.', 100),
    ('approved',     'Approved',     'decision',      'Approved a request, decision, change, or artifact.', 110),
    ('rejected',     'Rejected',     'decision',      'Rejected a request, decision, change, or artifact.', 120),
    ('decided',      'Decided',      'decision',      'Recorded a decision or selected an option.', 130),
    ('discovered',   'Discovered',   'event',         'Discovered a fact, condition, issue, or opportunity.', 140),
    ('observed',     'Observed',     'event',         'Observed a state, behavior, symptom, metric, or outcome.', 150),
    ('reported',     'Reported',     'communication', 'Reported status, findings, incidents, or results.', 160),
    ('requested',    'Requested',    'communication', 'Requested work, approval, information, or action.', 170),
    ('assigned',     'Assigned',     'planning',      'Assigned ownership, work, responsibility, or routing.', 180),
    ('scheduled',    'Scheduled',    'planning',      'Scheduled an event, job, meeting, release, or activity.', 190),
    ('completed',    'Completed',    'state',         'Completed work, a process, a workflow, or an event.', 200),
    ('failed',       'Failed',       'failure',       'Failed a check, operation, deployment, process, or expectation.', 210),
    ('blocked',      'Blocked',      'state',         'Blocked progress, access, workflow, or execution.', 220),
    ('resolved',     'Resolved',     'state',         'Resolved an incident, task, ticket, defect, or issue.', 230),
    ('documented',   'Documented',   'documentation', 'Documented knowledge, procedure, decision, or evidence.', 240),
    ('learned',      'Learned',      'documentation', 'Captured a lesson, insight, or retained know-how.', 250),
    ('connected',    'Connected',    'action',        'Connected systems, people, services, networks, or records.', 260),
    ('disconnected', 'Disconnected', 'action',        'Disconnected systems, people, services, networks, or records.', 270),
    ('started',      'Started',      'event',         'Started a service, task, event, workflow, or period.', 280),
    ('stopped',      'Stopped',      'event',         'Stopped a service, task, event, workflow, or period.', 290),
    ('other',        'Other',        'other',         'Fallback verb type when no more specific verb applies.', 900)
ON CONFLICT (verb_type) DO UPDATE
    SET display_name = EXCLUDED.display_name,
        semantic_class = EXCLUDED.semantic_class,
        description = EXCLUDED.description,
        sort_order = EXCLUDED.sort_order,
        system_defined = true;

GRANT SELECT ON maludb_core.malu$svpor_subject_type, maludb_core.malu$svpor_verb_type TO
    maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;
GRANT INSERT, UPDATE, DELETE ON maludb_core.malu$svpor_subject_type, maludb_core.malu$svpor_verb_type TO
    maludb_memory_admin;
```

- [ ] **Step 2: Add normalization helpers**

Append this SQL:

```sql
CREATE FUNCTION maludb_core._svpor_slug(p_value text) RETURNS text
LANGUAGE sql IMMUTABLE
AS $body$
    SELECT NULLIF(
        regexp_replace(
            regexp_replace(lower(btrim(COALESCE(p_value, ''))), '[^a-z0-9]+', '_', 'g'),
            '^_+|_+$', '', 'g'
        ),
        ''
    )
$body$;

CREATE FUNCTION maludb_core._normalize_svpor_subject_type(p_value text) RETURNS text
LANGUAGE plpgsql STABLE
AS $body$
DECLARE
    v_slug text := COALESCE(maludb_core._svpor_slug(p_value), 'other');
    v_type text;
BEGIN
    SELECT subject_type INTO v_type
      FROM maludb_core.malu$svpor_subject_type
     WHERE subject_type = v_slug
        OR lower(display_name) = lower(btrim(COALESCE(p_value, '')))
     ORDER BY CASE WHEN subject_type = v_slug THEN 0 ELSE 1 END
     LIMIT 1;

    IF v_type IS NULL THEN
        RAISE EXCEPTION 'unknown subject_type %. Register it in malu$svpor_subject_type first', p_value
            USING ERRCODE = 'invalid_parameter_value';
    END IF;
    RETURN v_type;
END;
$body$;

CREATE FUNCTION maludb_core._normalize_svpor_verb_type(p_value text, p_fallback_text text DEFAULT NULL) RETURNS text
LANGUAGE plpgsql STABLE
AS $body$
DECLARE
    v_input text := COALESCE(NULLIF(p_value, ''), p_fallback_text, 'other');
    v_slug text := COALESCE(maludb_core._svpor_slug(v_input), 'other');
    v_type text;
BEGIN
    SELECT verb_type INTO v_type
      FROM maludb_core.malu$svpor_verb_type
     WHERE verb_type = v_slug
        OR lower(display_name) = lower(btrim(COALESCE(v_input, '')))
     ORDER BY CASE WHEN verb_type = v_slug THEN 0 ELSE 1 END
     LIMIT 1;

    IF v_type IS NULL AND p_value IS NULL THEN
        RETURN 'other';
    END IF;
    IF v_type IS NULL THEN
        RAISE EXCEPTION 'unknown verb_type %. Register it in malu$svpor_verb_type first', p_value
            USING ERRCODE = 'invalid_parameter_value';
    END IF;
    RETURN v_type;
END;
$body$;
```

- [ ] **Step 3: Wire the registries into existing subject and verb rows**

Append this SQL:

```sql
ALTER TABLE maludb_core.malu$svpor_subject
    ALTER COLUMN subject_type SET DEFAULT 'other';

UPDATE maludb_core.malu$svpor_subject
   SET subject_type = maludb_core._normalize_svpor_subject_type(subject_type);

ALTER TABLE maludb_core.malu$svpor_subject
    ADD CONSTRAINT malu$svpor_subject_subject_type_fk
    FOREIGN KEY (subject_type)
    REFERENCES maludb_core.malu$svpor_subject_type(subject_type);

ALTER TABLE maludb_core.malu$svpor_verb
    ADD COLUMN verb_type text NOT NULL DEFAULT 'other';

ALTER TABLE maludb_core.malu$svpor_verb
    ADD CONSTRAINT malu$svpor_verb_verb_type_fk
    FOREIGN KEY (verb_type)
    REFERENCES maludb_core.malu$svpor_verb_type(verb_type);

CREATE INDEX malu$svpor_verb_type_idx
    ON maludb_core.malu$svpor_verb(owner_schema, verb_type, canonical_name);
```

- [ ] **Step 4: Run the failing regression again**

Run: `make installcheck REGRESS=svpor_identifier_types`

Expected: the test still fails because schema-local type facades and updated `maludb_verb` view are not exposed yet.

- [ ] **Step 5: Commit the registry slice**

```bash
git add sql/extension/maludb_core--0.74.0--0.75.0.sql
git commit -m "feat: add SVPOR subject and verb type registries"
```

### Task 8: Expose Type-Aware Subject and Verb APIs

**Files:**
- Modify: `sql/extension/maludb_core--0.74.0--0.75.0.sql`

- [ ] **Step 1: Replace `register_svpor_subject` with normalized type handling**

Append this SQL:

```sql
CREATE OR REPLACE FUNCTION maludb_core.register_svpor_subject(
    p_canonical_name text,
    p_aliases        text[] DEFAULT ARRAY[]::text[],
    p_description    text   DEFAULT NULL,
    p_subject_type   text   DEFAULT 'other'
) RETURNS bigint
LANGUAGE plpgsql
AS $body$
DECLARE
    v_id bigint;
    v_subject_type text := maludb_core._normalize_svpor_subject_type(p_subject_type);
BEGIN
    INSERT INTO maludb_core.malu$svpor_subject (canonical_name, aliases, description, subject_type)
    VALUES (p_canonical_name, COALESCE(p_aliases, ARRAY[]::text[]), p_description, v_subject_type)
    ON CONFLICT (owner_schema, canonical_name) DO UPDATE
        SET aliases = (
                SELECT array_agg(DISTINCT a)
                FROM unnest(malu$svpor_subject.aliases || COALESCE(EXCLUDED.aliases, ARRAY[]::text[])) AS a
            ),
            description = COALESCE(EXCLUDED.description, malu$svpor_subject.description),
            subject_type = EXCLUDED.subject_type
    RETURNING subject_id INTO v_id;
    RETURN v_id;
END;
$body$;
```

- [ ] **Step 2: Replace `register_svpor_verb` with verb type handling**

Append this SQL:

```sql
ALTER EXTENSION maludb_core DROP FUNCTION maludb_core.register_svpor_verb(text, text[], text);
DROP FUNCTION maludb_core.register_svpor_verb(text, text[], text);

CREATE OR REPLACE FUNCTION maludb_core.register_svpor_verb(
    p_canonical_name text,
    p_aliases        text[] DEFAULT ARRAY[]::text[],
    p_description    text   DEFAULT NULL,
    p_verb_type      text   DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql
AS $body$
DECLARE
    v_id bigint;
    v_verb_type text := maludb_core._normalize_svpor_verb_type(p_verb_type, p_canonical_name);
BEGIN
    INSERT INTO maludb_core.malu$svpor_verb (canonical_name, aliases, description, verb_type)
    VALUES (p_canonical_name, COALESCE(p_aliases, ARRAY[]::text[]), p_description, v_verb_type)
    ON CONFLICT (owner_schema, canonical_name) DO UPDATE
        SET aliases = (
                SELECT array_agg(DISTINCT a)
                FROM unnest(malu$svpor_verb.aliases || COALESCE(EXCLUDED.aliases, ARRAY[]::text[])) AS a
            ),
            description = COALESCE(EXCLUDED.description, malu$svpor_verb.description),
            verb_type = EXCLUDED.verb_type
    RETURNING verb_id INTO v_id;
    RETURN v_id;
END;
$body$;

REVOKE ALL ON FUNCTION maludb_core.register_svpor_verb(text, text[], text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core.register_svpor_verb(text, text[], text, text) TO
    maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;
```

- [ ] **Step 3: Add normalization triggers for direct view inserts**

Append this SQL:

```sql
CREATE FUNCTION maludb_core._svpor_subject_normalize_type_tg() RETURNS trigger
LANGUAGE plpgsql
AS $body$
BEGIN
    NEW.subject_type := maludb_core._normalize_svpor_subject_type(NEW.subject_type);
    RETURN NEW;
END;
$body$;

CREATE TRIGGER svpor_subject_normalize_type_tg
    BEFORE INSERT OR UPDATE OF subject_type ON maludb_core.malu$svpor_subject
    FOR EACH ROW EXECUTE FUNCTION maludb_core._svpor_subject_normalize_type_tg();

CREATE FUNCTION maludb_core._svpor_verb_normalize_type_tg() RETURNS trigger
LANGUAGE plpgsql
AS $body$
BEGIN
    NEW.verb_type := maludb_core._normalize_svpor_verb_type(NEW.verb_type, NEW.canonical_name);
    RETURN NEW;
END;
$body$;

CREATE TRIGGER svpor_verb_normalize_type_tg
    BEFORE INSERT OR UPDATE OF verb_type, canonical_name ON maludb_core.malu$svpor_verb
    FOR EACH ROW EXECUTE FUNCTION maludb_core._svpor_verb_normalize_type_tg();
```

- [ ] **Step 4: Replace `_enable_memory_schema_subject_facade`**

Copy the current `CREATE FUNCTION _enable_memory_schema_subject_facade(p_schema name)` body from `sql/extension/maludb_core--0.74.0.sql`, change the declaration to `CREATE OR REPLACE FUNCTION`, and make these concrete changes:

```sql
    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_subject_type', 'view');
    EXECUTE format($sql$
        CREATE OR REPLACE VIEW %I.maludb_subject_type AS
        SELECT subject_type,
               display_name,
               description,
               sort_order,
               system_defined,
               created_at
          FROM maludb_core.malu$svpor_subject_type
    $sql$, p_schema);
    EXECUTE format('GRANT SELECT ON %I.maludb_subject_type TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_subject_type', 'view', 'Schema-local SVPOR subject type catalog facade.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_verb_type', 'view');
    EXECUTE format($sql$
        CREATE OR REPLACE VIEW %I.maludb_verb_type AS
        SELECT verb_type,
               display_name,
               semantic_class,
               description,
               sort_order,
               system_defined,
               created_at
          FROM maludb_core.malu$svpor_verb_type
    $sql$, p_schema);
    EXECUTE format('GRANT SELECT ON %I.maludb_verb_type TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_verb_type', 'view', 'Schema-local SVPOR verb type catalog facade.');
    v_count := v_count + 1;
```

In the `maludb_verb` view inside the copied function, include `verb_type` between `verb_id` and `canonical_name`:

```sql
        CREATE OR REPLACE VIEW %I.maludb_verb AS
        SELECT verb_id,
               verb_type,
               canonical_name,
               aliases,
               description,
               created_at
          FROM maludb_core.malu$svpor_verb
         WHERE owner_schema = %L
        WITH LOCAL CHECK OPTION
```

- [ ] **Step 5: Run the type regression**

Run: `make installcheck REGRESS=svpor_identifier_types`

Expected: the test passes or fails only because `expected/svpor_identifier_types.out` has not been created.

- [ ] **Step 6: Commit the type API slice**

```bash
git add sql/extension/maludb_core--0.74.0--0.75.0.sql
git commit -m "feat: expose typed SVPOR identifier catalogs"
```

### Task 8A: Add Person Subject Convenience Facade

**Files:**
- Modify: `sql/svpor_identifier_types.sql`
- Modify: `sql/svpor_relationship_search_phrases.sql`
- Modify: `sql/extension/maludb_core--0.74.0--0.75.0.sql`

- [ ] **Step 1: Extend identifier coverage for `maludb_person`**

In `sql/svpor_identifier_types.sql`, add this block after the `Time Period` insert:

```sql
INSERT INTO maludb_person(subject_type, canonical_name, aliases)
VALUES ('person', 'Person A', ARRAY['A. Person'])
RETURNING subject_type, canonical_name;

SELECT subject_type, canonical_name, aliases
FROM maludb_person
WHERE canonical_name = 'Person A';
```

- [ ] **Step 2: Update relationship coverage to use the person facade**

In `sql/svpor_relationship_search_phrases.sql`, replace the generic person insert:

```sql
INSERT INTO maludb_person(subject_type, canonical_name)
VALUES ('person', 'Person A')
RETURNING subject_id AS person_a_id \gset
```

with the dedicated facade insert:

```sql
INSERT INTO maludb_person(subject_type, canonical_name)
VALUES ('person', 'Person A')
RETURNING subject_id AS person_a_id \gset
```

- [ ] **Step 3: Run the identifier test and verify it fails for the missing facade**

Run: `make installcheck REGRESS=svpor_identifier_types`

Expected: `svpor_identifier_types` fails with `relation "maludb_person" does not exist`.

- [ ] **Step 4: Add the `maludb_person` view to the schema-local facade**

In `sql/extension/maludb_core--0.74.0--0.75.0.sql`, add this block inside `maludb_core._enable_memory_schema_075_facade(p_schema name)` before `RETURN v_count;`:

```sql
    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_person', 'view');
    EXECUTE format($sql$
        CREATE OR REPLACE VIEW %I.maludb_person AS
        SELECT subject_id,
               subject_type,
               canonical_name,
               aliases,
               description,
               created_at
          FROM %I.maludb_subject
         WHERE subject_type = 'person'
        WITH LOCAL CHECK OPTION
    $sql$, p_schema, p_schema);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON %I.maludb_person TO maludb_memory_admin, maludb_memory_executor', p_schema);
    EXECUTE format('GRANT SELECT ON %I.maludb_person TO maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_person', 'view', 'Schema-local person subject convenience facade.');
    v_count := v_count + 1;
```

This mirrors the existing `maludb_project` convention: callers insert through a subject-type-specific view and supply the normalized `subject_type` value that satisfies the `WITH LOCAL CHECK OPTION`.

- [ ] **Step 5: Run focused regressions**

Run:

```bash
make installcheck REGRESS=svpor_identifier_types
make installcheck REGRESS=svpor_relationship_search_phrases
```

Expected: each test passes or fails only because its expected output has not been regenerated.

- [ ] **Step 6: Commit the person facade slice**

```bash
git add sql/extension/maludb_core--0.74.0--0.75.0.sql sql/svpor_identifier_types.sql sql/svpor_relationship_search_phrases.sql
git commit -m "feat: expose person subject facade"
```

### Task 9: Write Failing Coverage for SVPOR Relationships and Verb Search Phrases

**Files:**
- Create: `sql/svpor_relationship_search_phrases.sql`
- Modify: `Makefile`

- [ ] **Step 1: Add the regression test name**

In `Makefile`, append `svpor_relationship_search_phrases` to the end of the `REGRESS = ...` list after `svpor_identifier_types`.

- [ ] **Step 2: Create `sql/svpor_relationship_search_phrases.sql`**

```sql
\set ECHO all
\pset format unaligned
SET client_min_messages = WARNING;
CREATE EXTENSION IF NOT EXISTS maludb_core CASCADE;

SET search_path TO maludb_core, public;

DROP SCHEMA IF EXISTS svpor_rel_a CASCADE;
DROP ROLE IF EXISTS svpor_rel_user;

CREATE ROLE svpor_rel_user NOLOGIN;
GRANT maludb_memory_executor TO svpor_rel_user;
GRANT USAGE ON SCHEMA maludb_core TO svpor_rel_user;
CREATE SCHEMA svpor_rel_a AUTHORIZATION svpor_rel_user;

SET ROLE svpor_rel_user;
SET search_path TO svpor_rel_a, maludb_core, public;

SELECT object_count > 0 AS enabled
FROM maludb_core.enable_memory_schema();

INSERT INTO maludb_project(canonical_name, aliases)
VALUES ('Project X', ARRAY['PX'])
RETURNING subject_id AS project_x_id \gset

INSERT INTO maludb_project(canonical_name)
VALUES ('Project Y')
RETURNING subject_id AS project_y_id \gset

INSERT INTO maludb_project(canonical_name)
VALUES ('Project Z')
RETURNING subject_id AS project_z_id \gset

INSERT INTO maludb_subject(subject_type, canonical_name)
VALUES ('Person', 'Person A')
RETURNING subject_id AS person_a_id \gset

INSERT INTO maludb_subject(subject_type, canonical_name)
VALUES ('Equipment', 'Server X')
RETURNING subject_id AS server_x_id \gset

INSERT INTO maludb_subject(subject_type, canonical_name)
VALUES ('Equipment', 'Server Y')
RETURNING subject_id AS server_y_id \gset

INSERT INTO maludb_subject(subject_type, canonical_name)
VALUES ('Software', 'Tech Stack C')
RETURNING subject_id AS tech_stack_c_id \gset

INSERT INTO maludb_verb(verb_type, canonical_name, aliases, search_phrases)
VALUES (
    'Configured',
    'Configured',
    ARRAY['configure','configuring','configuration','set up','setup'],
    ARRAY['Server Configuration','Configured Server','Configure Server','Server Setup']
)
RETURNING verb_id AS configured_id \gset

SELECT maludb_svpor_relationship_create('subject', :project_x_id, 'subject', :person_a_id, 'has_member') > 0 AS project_person_edge;
SELECT maludb_svpor_relationship_create('subject', :project_x_id, 'subject', :server_x_id, 'has_asset') > 0 AS project_server_edge;
SELECT maludb_svpor_relationship_create('subject', :project_x_id, 'subject', :tech_stack_c_id, 'uses') > 0 AS project_stack_edge;
SELECT maludb_svpor_relationship_create('subject', :person_a_id, 'subject', :project_y_id, 'assigned_to') > 0 AS person_project_y_edge;
SELECT maludb_svpor_relationship_create('subject', :person_a_id, 'subject', :project_z_id, 'assigned_to') > 0 AS person_project_z_edge;
SELECT maludb_svpor_relationship_create('verb', :configured_id, 'subject', :server_x_id, 'applies_to') > 0 AS configured_server_x_edge;
SELECT maludb_svpor_relationship_create('verb', :configured_id, 'subject', :server_y_id, 'applies_to') > 0 AS configured_server_y_edge;
SELECT maludb_svpor_relationship_create('verb', :configured_id, 'subject', :person_a_id, 'performed_by') > 0 AS configured_person_edge;

SELECT source_kind, source_name, relationship_type, target_kind, target_name
FROM maludb_svpor_relationship
WHERE source_name IN ('Project X', 'Person A', 'Configured')
ORDER BY source_name, relationship_type, target_name;

SELECT canonical_name, match_kind, matched_text
FROM maludb_verb_phrase_search('Server Configuration')
ORDER BY canonical_name;

SELECT canonical_name, match_kind, matched_text
FROM maludb_verb_phrase_search('Configured Server')
ORDER BY canonical_name;

RESET ROLE;
SET search_path TO maludb_core, public;

DELETE FROM malu$relationship_edge WHERE owner_schema = 'svpor_rel_a';
DELETE FROM malu$svpor_verb WHERE owner_schema = 'svpor_rel_a';
DELETE FROM malu$svpor_subject WHERE owner_schema = 'svpor_rel_a';
DELETE FROM malu$enabled_schema_object WHERE schema_name = 'svpor_rel_a';
DELETE FROM malu$enabled_schema WHERE schema_name = 'svpor_rel_a';
DROP SCHEMA svpor_rel_a CASCADE;
DROP OWNED BY svpor_rel_user;
DROP ROLE svpor_rel_user;
```

- [ ] **Step 3: Run the test and verify it fails for missing relationship/search APIs**

Run: `make installcheck REGRESS=svpor_relationship_search_phrases`

Expected: `svpor_relationship_search_phrases` fails because `maludb_svpor_relationship_create`, `maludb_svpor_relationship`, `maludb_verb.search_phrases`, or `maludb_verb_phrase_search` does not exist.

- [ ] **Step 4: Commit the failing test**

```bash
git add Makefile sql/svpor_relationship_search_phrases.sql
git commit -m "test: cover SVPOR relationships and verb search phrases"
```

### Task 10: Add Subject and Verb Relationship Support

**Files:**
- Modify: `sql/extension/maludb_core--0.74.0--0.75.0.sql`

- [ ] **Step 1: Seed relationship types used by project and verb relationships**

Append this SQL:

```sql
INSERT INTO maludb_core.malu$relationship_type(relationship_type, stage, description) VALUES
    ('has_member',   3, 'Subject A has subject B as a member or participant.'),
    ('has_asset',    3, 'Subject A has subject B as an owned, managed, or relevant asset.'),
    ('uses',         3, 'Subject A uses subject B.'),
    ('assigned_to',  3, 'Subject A is assigned to subject B.'),
    ('applies_to',   3, 'Verb A applies to subject B.'),
    ('performed_by', 3, 'Verb A is performed by subject B.')
ON CONFLICT (relationship_type) DO UPDATE
    SET stage = EXCLUDED.stage,
        description = EXCLUDED.description;
```

- [ ] **Step 2: Extend `malu$relationship_edge` object-type checks**

Append this SQL after relationship type seeding:

```sql
ALTER TABLE maludb_core.malu$relationship_edge
    DROP CONSTRAINT malu$relationship_edge_source_object_type_check;
ALTER TABLE maludb_core.malu$relationship_edge
    ADD CONSTRAINT malu$relationship_edge_source_object_type_check
    CHECK (source_object_type IN (
        'source_package','claim','fact','memory','episode_object',
        'memory_detail_object','page_index_tree','chat_index_tree',
        'subject','verb'
    ));

ALTER TABLE maludb_core.malu$relationship_edge
    DROP CONSTRAINT malu$relationship_edge_target_object_type_check;
ALTER TABLE maludb_core.malu$relationship_edge
    ADD CONSTRAINT malu$relationship_edge_target_object_type_check
    CHECK (target_object_type IN (
        'source_package','claim','fact','memory','episode_object',
        'memory_detail_object','page_index_tree','chat_index_tree',
        'subject','verb'
    ));
```

- [ ] **Step 3: Add a constrained SVPOR relationship writer**

Append this function:

```sql
CREATE FUNCTION maludb_core.register_svpor_relationship(
    p_source_kind text,
    p_source_id bigint,
    p_target_kind text,
    p_target_id bigint,
    p_relationship_type text,
    p_label text DEFAULT NULL,
    p_edge_jsonb jsonb DEFAULT NULL,
    p_confidence numeric DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql
SECURITY INVOKER
AS $body$
DECLARE
    v_source_kind text := lower(btrim(COALESCE(p_source_kind, '')));
    v_target_kind text := lower(btrim(COALESCE(p_target_kind, '')));
BEGIN
    IF v_source_kind NOT IN ('subject','verb') OR v_target_kind NOT IN ('subject','verb') THEN
        RAISE EXCEPTION 'SVPOR relationships support only subject and verb endpoints'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    RETURN maludb_core.register_relationship_edge(
        v_source_kind,
        p_source_id,
        v_target_kind,
        p_target_id,
        p_relationship_type,
        p_label,
        COALESCE(p_edge_jsonb, '{}'::jsonb),
        p_confidence
    );
END;
$body$;

REVOKE ALL ON FUNCTION maludb_core.register_svpor_relationship(text, bigint, text, bigint, text, text, jsonb, numeric) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core.register_svpor_relationship(text, bigint, text, bigint, text, text, jsonb, numeric)
TO maludb_memory_admin, maludb_memory_executor;
```

- [ ] **Step 4: Add schema-local relationship views and create function**

In the `CREATE OR REPLACE FUNCTION _enable_memory_schema_subject_facade(p_schema name)` body planned in Task 8, add these objects before `RETURN v_count;`:

```sql
    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_svpor_relationship', 'view');
    EXECUTE format($sql$
        CREATE OR REPLACE VIEW %I.maludb_svpor_relationship AS
        SELECT e.edge_id,
               e.source_object_type AS source_kind,
               e.source_object_id AS source_id,
               COALESCE(src_s.canonical_name, src_v.canonical_name) AS source_name,
               e.relationship_type,
               e.target_object_type AS target_kind,
               e.target_object_id AS target_id,
               COALESCE(tgt_s.canonical_name, tgt_v.canonical_name) AS target_name,
               e.label,
               e.edge_jsonb,
               e.confidence,
               e.created_at
          FROM maludb_core.malu$relationship_edge e
          LEFT JOIN maludb_core.malu$svpor_subject src_s
            ON e.source_object_type = 'subject'
           AND src_s.owner_schema = e.owner_schema
           AND src_s.subject_id = e.source_object_id
          LEFT JOIN maludb_core.malu$svpor_verb src_v
            ON e.source_object_type = 'verb'
           AND src_v.owner_schema = e.owner_schema
           AND src_v.verb_id = e.source_object_id
          LEFT JOIN maludb_core.malu$svpor_subject tgt_s
            ON e.target_object_type = 'subject'
           AND tgt_s.owner_schema = e.owner_schema
           AND tgt_s.subject_id = e.target_object_id
          LEFT JOIN maludb_core.malu$svpor_verb tgt_v
            ON e.target_object_type = 'verb'
           AND tgt_v.owner_schema = e.owner_schema
           AND tgt_v.verb_id = e.target_object_id
         WHERE e.owner_schema = %L
           AND e.source_object_type IN ('subject','verb')
           AND e.target_object_type IN ('subject','verb')
    $sql$, p_schema, p_schema);
    EXECUTE format('GRANT SELECT ON %I.maludb_svpor_relationship TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_svpor_relationship', 'view', 'Schema-local SVPOR subject/verb relationship facade.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_svpor_relationship_create', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_svpor_relationship_create(
            p_source_kind text,
            p_source_id bigint,
            p_target_kind text,
            p_target_id bigint,
            p_relationship_type text,
            p_label text DEFAULT NULL,
            p_edge_jsonb jsonb DEFAULT '{}'::jsonb,
            p_confidence numeric DEFAULT NULL
        ) RETURNS bigint
        LANGUAGE sql
        SECURITY INVOKER
        SET search_path = %I, maludb_core, pg_temp
        AS $facade$
            SELECT maludb_core.register_svpor_relationship(
                p_source_kind, p_source_id, p_target_kind, p_target_id,
                p_relationship_type, p_label, p_edge_jsonb, p_confidence
            )
        $facade$
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_svpor_relationship_create(text, bigint, text, bigint, text, text, jsonb, numeric) FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_svpor_relationship_create(text, bigint, text, bigint, text, text, jsonb, numeric) TO maludb_memory_admin, maludb_memory_executor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_svpor_relationship_create', 'function', 'Schema-local SVPOR relationship writer.');
    v_count := v_count + 1;
```

- [ ] **Step 5: Run relationship regression**

Run: `make installcheck REGRESS=svpor_relationship_search_phrases`

Expected: the relationship portions progress, and the test still fails because `search_phrases` and `maludb_verb_phrase_search` are not implemented yet.

- [ ] **Step 6: Commit the relationship slice**

```bash
git add sql/extension/maludb_core--0.74.0--0.75.0.sql
git commit -m "feat: support SVPOR subject and verb relationships"
```

### Task 11: Add Verb Search Phrases

**Files:**
- Modify: `sql/extension/maludb_core--0.74.0--0.75.0.sql`

- [ ] **Step 1: Add `search_phrases` to verbs**

Append this SQL:

```sql
ALTER TABLE maludb_core.malu$svpor_verb
    ADD COLUMN search_phrases text[] NOT NULL DEFAULT ARRAY[]::text[];

CREATE INDEX malu$svpor_verb_search_phrases_gin
    ON maludb_core.malu$svpor_verb USING gin (search_phrases);
```

- [ ] **Step 2: Replace `register_svpor_verb` with phrase support**

Append this SQL after the Task 8 `register_svpor_verb` replacement:

```sql
ALTER EXTENSION maludb_core DROP FUNCTION maludb_core.register_svpor_verb(text, text[], text, text);
DROP FUNCTION maludb_core.register_svpor_verb(text, text[], text, text);

CREATE OR REPLACE FUNCTION maludb_core.register_svpor_verb(
    p_canonical_name text,
    p_aliases text[] DEFAULT ARRAY[]::text[],
    p_description text DEFAULT NULL,
    p_verb_type text DEFAULT NULL,
    p_search_phrases text[] DEFAULT ARRAY[]::text[]
) RETURNS bigint
LANGUAGE plpgsql
AS $body$
DECLARE
    v_id bigint;
    v_verb_type text := maludb_core._normalize_svpor_verb_type(p_verb_type, p_canonical_name);
BEGIN
    INSERT INTO maludb_core.malu$svpor_verb (canonical_name, aliases, description, verb_type, search_phrases)
    VALUES (
        p_canonical_name,
        COALESCE(p_aliases, ARRAY[]::text[]),
        p_description,
        v_verb_type,
        COALESCE(p_search_phrases, ARRAY[]::text[])
    )
    ON CONFLICT (owner_schema, canonical_name) DO UPDATE
        SET aliases = (
                SELECT array_agg(DISTINCT a)
                FROM unnest(malu$svpor_verb.aliases || COALESCE(EXCLUDED.aliases, ARRAY[]::text[])) AS a
            ),
            search_phrases = (
                SELECT array_agg(DISTINCT p)
                FROM unnest(malu$svpor_verb.search_phrases || COALESCE(EXCLUDED.search_phrases, ARRAY[]::text[])) AS p
            ),
            description = COALESCE(EXCLUDED.description, malu$svpor_verb.description),
            verb_type = EXCLUDED.verb_type
    RETURNING verb_id INTO v_id;
    RETURN v_id;
END;
$body$;

REVOKE ALL ON FUNCTION maludb_core.register_svpor_verb(text, text[], text, text, text[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core.register_svpor_verb(text, text[], text, text, text[]) TO
    maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;
```

- [ ] **Step 3: Add phrase search function**

Append this SQL:

```sql
CREATE FUNCTION maludb_core.verb_phrase_search(p_query text)
RETURNS TABLE (
    verb_id bigint,
    canonical_name text,
    verb_type text,
    match_kind text,
    matched_text text
) LANGUAGE sql STABLE
AS $body$
    WITH q AS (
        SELECT lower(btrim(COALESCE(p_query, ''))) AS text
    ),
    matches AS (
        SELECT v.verb_id, v.canonical_name, v.verb_type, 'canonical'::text AS match_kind, v.canonical_name AS matched_text, 1 AS priority
          FROM maludb_core.malu$svpor_verb v, q
         WHERE lower(v.canonical_name) = q.text
        UNION ALL
        SELECT v.verb_id, v.canonical_name, v.verb_type, 'alias'::text, a.alias, 2
          FROM maludb_core.malu$svpor_verb v
          CROSS JOIN LATERAL unnest(v.aliases) AS a(alias), q
         WHERE lower(a.alias) = q.text
        UNION ALL
        SELECT v.verb_id, v.canonical_name, v.verb_type, 'search_phrase'::text, p.phrase, 3
          FROM maludb_core.malu$svpor_verb v
          CROSS JOIN LATERAL unnest(v.search_phrases) AS p(phrase), q
         WHERE lower(p.phrase) = q.text
    )
    SELECT verb_id, canonical_name, verb_type, match_kind, matched_text
      FROM matches
     ORDER BY priority, canonical_name, matched_text
$body$;

REVOKE ALL ON FUNCTION maludb_core.verb_phrase_search(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core.verb_phrase_search(text)
TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;
```

- [ ] **Step 4: Update schema-local verb facade and add phrase search wrapper**

In the `CREATE OR REPLACE FUNCTION _enable_memory_schema_subject_facade(p_schema name)` body planned in Task 8 and extended in Task 10:

Change the `maludb_verb` view to include `search_phrases`:

```sql
        CREATE OR REPLACE VIEW %I.maludb_verb AS
        SELECT verb_id,
               verb_type,
               canonical_name,
               aliases,
               search_phrases,
               description,
               created_at
          FROM maludb_core.malu$svpor_verb
         WHERE owner_schema = %L
        WITH LOCAL CHECK OPTION
```

Add this wrapper before `RETURN v_count;`:

```sql
    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_verb_phrase_search', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_verb_phrase_search(p_query text)
        RETURNS TABLE (
            verb_id bigint,
            canonical_name text,
            verb_type text,
            match_kind text,
            matched_text text
        )
        LANGUAGE sql
        STABLE
        SECURITY INVOKER
        SET search_path = %I, maludb_core, pg_temp
        AS $facade$
            SELECT *
            FROM maludb_core.verb_phrase_search(p_query)
        $facade$
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_verb_phrase_search(text) FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_verb_phrase_search(text) TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_verb_phrase_search', 'function', 'Schema-local verb phrase resolver.');
    v_count := v_count + 1;
```

- [ ] **Step 5: Run relationship and phrase regression**

Run: `make installcheck REGRESS=svpor_relationship_search_phrases`

Expected: the test passes or fails only because `expected/svpor_relationship_search_phrases.out` has not been created.

- [ ] **Step 6: Commit the phrase search slice**

```bash
git add sql/extension/maludb_core--0.74.0--0.75.0.sql
git commit -m "feat: add SVPOR verb search phrases"
```

### Task 12: Build Full Release Script and Verify

**Files:**
- Modify: `maludb_core.control`
- Modify: `Makefile`
- Create: `sql/extension/maludb_core--0.75.0.sql`
- Create: `expected/document_note_svpor_hints.out`
- Create: `expected/svpor_identifier_types.out`
- Create: `expected/svpor_relationship_search_phrases.out`

- [ ] **Step 1: Add the upgrade script to `Makefile`**

In the `DATA = ...` list, add:

```make
              sql/extension/maludb_core--0.74.0--0.75.0.sql \
              sql/extension/maludb_core--0.75.0.sql
```

Replace the old final `sql/extension/maludb_core--0.74.0.sql` line with `sql/extension/maludb_core--0.74.0.sql \` followed by the two new lines.

- [ ] **Step 2: Bump the control file**

Change `maludb_core.control`:

```ini
default_version = '0.75.0'
```

- [ ] **Step 3: Generate the full install script**

Run:

```bash
cp sql/extension/maludb_core--0.74.0.sql sql/extension/maludb_core--0.75.0.sql
sed -n '2,$p' sql/extension/maludb_core--0.74.0--0.75.0.sql >> sql/extension/maludb_core--0.75.0.sql
```

- [ ] **Step 4: Generate expected output**

Run:

```bash
make installcheck REGRESS=document_note_svpor_hints
cp results/document_note_svpor_hints.out expected/document_note_svpor_hints.out
make installcheck REGRESS=svpor_identifier_types
cp results/svpor_identifier_types.out expected/svpor_identifier_types.out
make installcheck REGRESS=svpor_relationship_search_phrases
cp results/svpor_relationship_search_phrases.out expected/svpor_relationship_search_phrases.out
make installcheck REGRESS="document_note_svpor_hints svpor_identifier_types svpor_relationship_search_phrases"
```

Expected: the final run reports `document_note_svpor_hints ... ok`, `svpor_identifier_types ... ok`, and `svpor_relationship_search_phrases ... ok`.

- [ ] **Step 5: Run broader verification**

Run:

```bash
make installcheck REGRESS="schema_memory_enablement rest_endpoint document_note_svpor_hints svpor_identifier_types svpor_relationship_search_phrases"
```

Expected: all five regression tests report `ok`.

- [ ] **Step 6: Run syntax checks for changed SQL**

Run:

```bash
make
```

Expected: extension builds without C or SQL packaging errors.

- [ ] **Step 7: Commit the release integration**

```bash
git add maludb_core.control Makefile sql/extension/maludb_core--0.74.0--0.75.0.sql sql/extension/maludb_core--0.75.0.sql sql/document_note_svpor_hints.sql expected/document_note_svpor_hints.out sql/svpor_identifier_types.sql expected/svpor_identifier_types.out sql/svpor_relationship_search_phrases.sql expected/svpor_relationship_search_phrases.out
git commit -m "feat: release note document SVPOR hints"
```

## Self-Review

- Spec coverage: Task 1 proves multiple projects, subjects, verbs, and explicit combinations on a note document. Tasks 2-4 implement storage, write API, schema-local views, and document reads. Task 5 exposes REST catalog entries. Task 6 proves typed subject/verb vocabulary behavior. Tasks 7-8 implement governed type registries and facades. Task 8A adds the `maludb_person` convenience facade for `subject_type = 'person'` and updates relationship coverage to create people through that end-user view. Task 9 proves subject/verb relationships and phrase search behavior. Task 10 implements SVPOR relationship edges and facades. Task 11 implements verb search phrases. Task 12 wires the release.
- Placeholder scan: this plan intentionally leaves no incomplete implementation steps for the approved first slice. Later release items should be appended as new tasks with their own tests and commands.
- Type consistency: public writer is `quick_add_note(text, text, text[], text[], text[], jsonb, jsonb)`, schema-local wrapper is `maludb_quick_add_note`, read helper is `document_get(bigint)`, schema-local wrapper is `maludb_document_get(bigint)`, SVPOR relationship writer is `register_svpor_relationship(text, bigint, text, bigint, text, text, jsonb, numeric)`, schema-local wrapper is `maludb_svpor_relationship_create`, and verb phrase resolver is `verb_phrase_search(text)` / `maludb_verb_phrase_search(text)`.
