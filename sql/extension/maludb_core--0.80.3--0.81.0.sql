\echo Use "ALTER EXTENSION maludb_core UPDATE TO '0.81.0'" to load this file. \quit

-- =====================================================================
-- maludb_core 0.80.3 -> 0.81.0
--
-- Documents serve two purposes in MaluDB: verbatim sources for derived
-- memories (SVPOR/extraction pipeline) and standalone artifacts the user
-- can browse and cite (page-index / chat-index search and view). To make
-- the latter useful, the UI needs a single short label per document --
-- "Meeting Transcript", "Change Request", "White Paper", etc.
--
-- This release adds three pieces:
--
--   1. A free-text `document_type` column on `malu$document`. Nullable, no
--      FK, no CHECK -- it is a tag-style attribute, not an enforced enum.
--      The UI reads it as the primary type label.
--
--   2. A per-schema `malu$document_type` lookup table that holds the
--      "common document types" each tenant wants to expose in the picker.
--      The lookup is advisory only: nothing prevents `upload_document`
--      from writing a brand-new document_type string that is not yet in
--      the lookup. Uniqueness is case-insensitive (LOWER(document_type))
--      so "Transcript" and "transcript" cannot both seed the picker.
--
--   3. A `document_type` value in the `malu$document_tag.tag_kind` CHECK
--      list so secondary type tags can accumulate alongside the primary
--      column without abusing 'freeform'.
--
-- `upload_document(...)` and the schema-local `maludb_upload_document(...)`
-- gain an 11th argument `p_document_type text DEFAULT NULL`, appended at
-- the end so existing 10-arg positional callers keep working.
--
-- A new `_enable_memory_schema_0810_facade(p_schema)` builder:
--   - creates the writable `maludb_document_type` view,
--   - seeds a small starter list of common types via INSERT ON CONFLICT
--     DO NOTHING (idempotent; tenant edits survive re-enable),
--   - re-issues the widened `maludb_document` view with `document_type`
--     appended at the end (CREATE OR REPLACE VIEW tolerates appended
--     columns), and
--   - re-issues `maludb_upload_document` with the new 11-arg signature.
--
-- Existing schemas pick up the new objects by re-running
-- `maludb_core.enable_memory_schema()`.
-- =====================================================================

CREATE OR REPLACE FUNCTION maludb_core.maludb_core_version() RETURNS text
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$ SELECT '0.81.0'::text $body$;

-- ===== 1. malu$document: add document_type =========================
ALTER TABLE maludb_core.malu$document
    ADD COLUMN IF NOT EXISTS document_type text;

-- ===== 2. malu$document_tag: extend tag_kind ========================
ALTER TABLE maludb_core.malu$document_tag
    DROP CONSTRAINT IF EXISTS malu$document_tag_tag_kind_check;
ALTER TABLE maludb_core.malu$document_tag
    ADD  CONSTRAINT malu$document_tag_tag_kind_check
    CHECK (tag_kind IN
        ('project','subject','verb','event','stakeholder','skill',
         'workflow','freeform','document_type'));

-- ===== 3. malu$document_type: per-schema lookup =====================
CREATE TABLE IF NOT EXISTS maludb_core.malu$document_type (
    document_type_id  bigserial PRIMARY KEY,
    owner_schema      name NOT NULL DEFAULT current_schema(),
    document_type     text NOT NULL,
    description       text,
    display_order     integer,
    created_at        timestamptz NOT NULL DEFAULT now(),
    UNIQUE (owner_schema, document_type)
);

-- Case-insensitive uniqueness for the picker -- "Transcript" and
-- "transcript" are the same entry. The plain UNIQUE above keeps
-- exact-case uniqueness as a belt-and-suspenders guard.
CREATE UNIQUE INDEX IF NOT EXISTS malu$document_type_owner_lower_idx
    ON maludb_core.malu$document_type(owner_schema, lower(document_type));

CREATE INDEX IF NOT EXISTS malu$document_type_owner_order_idx
    ON maludb_core.malu$document_type(owner_schema, display_order, document_type);

ALTER TABLE maludb_core.malu$document_type ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
          FROM pg_catalog.pg_policy p
          JOIN pg_catalog.pg_class c ON c.oid = p.polrelid
          JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
         WHERE n.nspname = 'maludb_core'
           AND c.relname = 'malu$document_type'
           AND p.polname = 'tenant_owner'
    ) THEN
        EXECUTE 'CREATE POLICY tenant_owner ON maludb_core.malu$document_type
                 USING (owner_schema = current_schema())
                 WITH CHECK (owner_schema = current_schema())';
    END IF;
END$$;

GRANT SELECT, INSERT, UPDATE, DELETE ON maludb_core.malu$document_type
    TO maludb_memory_admin, maludb_memory_executor;
GRANT SELECT ON maludb_core.malu$document_type TO maludb_memory_auditor;
GRANT USAGE, SELECT ON SEQUENCE maludb_core.malu$document_type_document_type_id_seq
    TO maludb_memory_admin, maludb_memory_executor;

-- ===== 4. upload_document: append p_document_type ===================
-- The 11th argument is appended at the end so existing 10-arg positional
-- callers (REST/CLI/SDK) keep binding to the same function via the new
-- default. The old signatures must be dropped explicitly because the new
-- definitions are distinct overloads, not in-place replacements.

DROP FUNCTION IF EXISTS maludb_core.upload_document(
    text, text, text, jsonb, text, text[], text[], text[], text[], jsonb);
DROP FUNCTION IF EXISTS maludb_core._upload_document_for_schema(
    name, text, text, text, jsonb, text, text[], text[], text[], text[], jsonb);

CREATE FUNCTION maludb_core._upload_document_for_schema(
    p_owner_schema   name,
    p_title          text,
    p_content_text   text,
    p_source_type    text   DEFAULT 'document',
    p_content_jsonb  jsonb  DEFAULT NULL,
    p_media_type     text   DEFAULT NULL,
    p_projects       text[] DEFAULT ARRAY[]::text[],
    p_subjects       text[] DEFAULT ARRAY[]::text[],
    p_verbs          text[] DEFAULT ARRAY[]::text[],
    p_events         text[] DEFAULT ARRAY[]::text[],
    p_metadata_jsonb jsonb  DEFAULT '{}'::jsonb,
    p_document_type  text   DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
DECLARE
    v_source_type    text := COALESCE(NULLIF(p_source_type, ''), 'document');
    v_document_type  text := NULLIF(pg_catalog.btrim(COALESCE(p_document_type, '')), '');
    v_source_id      bigint;
    v_doc_id         bigint;
    v_hash           text;
    v_size           bigint;
    v_bytes          bytea;
BEGIN
    PERFORM maludb_core._memory_schema_assert_manageable(p_owner_schema);

    IF p_title IS NULL OR pg_catalog.btrim(p_title) = '' THEN
        RAISE EXCEPTION 'upload_document: title is required'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    IF p_content_text IS NULL AND p_content_jsonb IS NULL THEN
        RAISE EXCEPTION 'register_source_package: one of content_bytes / _text / _jsonb is required'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    IF p_content_text IS NOT NULL THEN
        v_bytes := pg_catalog.convert_to(p_content_text, 'UTF8');
    ELSE
        v_bytes := pg_catalog.convert_to(p_content_jsonb::text, 'UTF8');
    END IF;

    v_hash := pg_catalog.encode(public.digest(v_bytes, 'sha256'), 'hex');
    v_size := pg_catalog.octet_length(v_bytes);

    INSERT INTO maludb_core.malu$source_package
        (owner_schema, source_type, content_text, content_jsonb,
         content_hash, content_size, media_type)
    VALUES
        (p_owner_schema, v_source_type, p_content_text, p_content_jsonb,
         v_hash, v_size, p_media_type)
    RETURNING source_package_id INTO v_source_id;

    INSERT INTO maludb_core.malu$document
        (owner_schema, source_package_id, title, source_type, media_type,
         document_type, metadata_jsonb)
    VALUES
        (p_owner_schema, v_source_id, p_title, v_source_type, p_media_type,
         v_document_type, COALESCE(p_metadata_jsonb, '{}'::jsonb))
    RETURNING document_id INTO v_doc_id;

    INSERT INTO maludb_core.malu$document_tag(owner_schema, document_id, tag_kind, tag_value, provenance)
    SELECT p_owner_schema, v_doc_id, 'project', tag_value, 'provided'
      FROM (SELECT DISTINCT pg_catalog.btrim(x) AS tag_value
              FROM pg_catalog.unnest(COALESCE(p_projects, ARRAY[]::text[])) AS x) AS tags
     WHERE tag_value <> '';

    INSERT INTO maludb_core.malu$document_tag(owner_schema, document_id, tag_kind, tag_value, provenance)
    SELECT p_owner_schema, v_doc_id, 'subject', tag_value, 'provided'
      FROM (SELECT DISTINCT pg_catalog.btrim(x) AS tag_value
              FROM pg_catalog.unnest(COALESCE(p_subjects, ARRAY[]::text[])) AS x) AS tags
     WHERE tag_value <> '';

    INSERT INTO maludb_core.malu$document_tag(owner_schema, document_id, tag_kind, tag_value, provenance)
    SELECT p_owner_schema, v_doc_id, 'verb', tag_value, 'provided'
      FROM (SELECT DISTINCT pg_catalog.btrim(x) AS tag_value
              FROM pg_catalog.unnest(COALESCE(p_verbs, ARRAY[]::text[])) AS x) AS tags
     WHERE tag_value <> '';

    INSERT INTO maludb_core.malu$document_tag(owner_schema, document_id, tag_kind, tag_value, provenance)
    SELECT p_owner_schema, v_doc_id, 'event', tag_value, 'provided'
      FROM (SELECT DISTINCT pg_catalog.btrim(x) AS tag_value
              FROM pg_catalog.unnest(COALESCE(p_events, ARRAY[]::text[])) AS x) AS tags
     WHERE tag_value <> '';

    RETURN v_doc_id;
END;
$body$;

REVOKE ALL ON FUNCTION maludb_core._upload_document_for_schema(
    name, text, text, text, jsonb, text, text[], text[], text[], text[], jsonb, text)
    FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core._upload_document_for_schema(
    name, text, text, text, jsonb, text, text[], text[], text[], text[], jsonb, text)
    TO maludb_memory_admin, maludb_memory_executor;

CREATE FUNCTION maludb_core.upload_document(
    p_title          text,
    p_content_text   text,
    p_source_type    text   DEFAULT 'document',
    p_content_jsonb  jsonb  DEFAULT NULL,
    p_media_type     text   DEFAULT NULL,
    p_projects       text[] DEFAULT ARRAY[]::text[],
    p_subjects       text[] DEFAULT ARRAY[]::text[],
    p_verbs          text[] DEFAULT ARRAY[]::text[],
    p_events         text[] DEFAULT ARRAY[]::text[],
    p_metadata_jsonb jsonb  DEFAULT '{}'::jsonb,
    p_document_type  text   DEFAULT NULL
) RETURNS bigint
LANGUAGE sql
SECURITY INVOKER
AS $body$
    SELECT maludb_core._upload_document_for_schema(
        current_schema()::name,
        p_title,
        p_content_text,
        p_source_type,
        p_content_jsonb,
        p_media_type,
        p_projects,
        p_subjects,
        p_verbs,
        p_events,
        p_metadata_jsonb,
        p_document_type
    )
$body$;

REVOKE ALL ON FUNCTION maludb_core.upload_document(
    text, text, text, jsonb, text, text[], text[], text[], text[], jsonb, text)
    FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core.upload_document(
    text, text, text, jsonb, text, text[], text[], text[], text[], jsonb, text)
    TO maludb_memory_admin, maludb_memory_executor;

-- ===== 5. 0.81.0 schema-local facade builder ========================
CREATE FUNCTION maludb_core._enable_memory_schema_0810_facade(p_schema name) RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
DECLARE
    v_count integer := 0;
BEGIN
    PERFORM maludb_core._memory_schema_assert_manageable(p_schema);

    -- ---- maludb_document_type: writable per-schema lookup ----------
    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_document_type', 'view');
    EXECUTE format($sql$
        CREATE OR REPLACE VIEW %I.maludb_document_type WITH (security_invoker = true) AS
        SELECT document_type_id,
               document_type,
               description,
               display_order,
               created_at
          FROM maludb_core.malu$document_type
         WHERE owner_schema = %L
        WITH LOCAL CHECK OPTION
    $sql$, p_schema, p_schema);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON %I.maludb_document_type TO maludb_memory_admin, maludb_memory_executor', p_schema);
    EXECUTE format('GRANT SELECT ON %I.maludb_document_type TO maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_document_type', 'view', 'Schema-local document type lookup facade.');
    v_count := v_count + 1;

    -- ---- starter seed of common document types ---------------------
    -- ON CONFLICT DO NOTHING: idempotent on re-enable. Tenants are free
    -- to delete or rename these; we will not re-add anything they
    -- removed unless the lower(document_type) slot is empty.
    EXECUTE format($sql$
        INSERT INTO maludb_core.malu$document_type
            (owner_schema, document_type, description, display_order)
        VALUES
            (%L, 'Meeting Notes',     'Notes captured during a meeting.',                 10),
            (%L, 'Meeting Transcript','Verbatim transcript of a meeting or call.',        20),
            (%L, 'Email',             'Email message or thread.',                         30),
            (%L, 'Report',            'Analytical or status report.',                     40),
            (%L, 'White Paper',       'Long-form explanatory document.',                  50),
            (%L, 'Specification',     'Technical specification or design document.',      60),
            (%L, 'Change Request',    'Proposed change with rationale and scope.',        70),
            (%L, 'Decision Memo',     'Captured decision with options and rationale.',    80),
            (%L, 'Proposal',          'Proposal seeking approval or funding.',            90),
            (%L, 'Contract',          'Executed or draft contractual document.',         100)
        ON CONFLICT DO NOTHING
    $sql$,
        p_schema, p_schema, p_schema, p_schema, p_schema,
        p_schema, p_schema, p_schema, p_schema, p_schema);

    -- ---- maludb_document: re-widen with document_type --------------
    -- Same column list as the 0.80 widened view, with document_type
    -- appended at the end so CREATE OR REPLACE VIEW accepts it without
    -- a drop. The 0.80.1 conditional-drop in enable_memory_schema only
    -- fires when the view is extension-managed, so an unmanaged
    -- collision still raises.
    EXECUTE format($sql$
        CREATE OR REPLACE VIEW %I.maludb_document WITH (security_invoker = true) AS
        SELECT d.document_id, d.source_package_id, d.title, d.source_type,
               d.media_type, d.primary_project_id, d.lifecycle_state,
               d.metadata_jsonb, d.created_at, d.updated_at,
               (SELECT sp.content_text
                  FROM maludb_core.malu$source_package sp
                 WHERE sp.owner_schema = d.owner_schema
                   AND sp.source_package_id = d.source_package_id
                   AND sp.source_type = d.source_type) AS body_text,
               d.document_type
          FROM maludb_core.malu$document d
         WHERE d.owner_schema = %L
        WITH LOCAL CHECK OPTION
    $sql$, p_schema, p_schema);

    -- ---- maludb_upload_document: new 11-arg signature --------------
    -- Drop the previous 10-arg signature explicitly: the new function
    -- has a different parameter list and would otherwise live alongside
    -- the old as a second overload.
    EXECUTE format('DROP FUNCTION IF EXISTS %I.maludb_upload_document(text, text, text, jsonb, text, text[], text[], text[], text[], jsonb)', p_schema);
    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_upload_document', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_upload_document(
            p_title          text,
            p_content_text   text,
            p_source_type    text   DEFAULT 'document',
            p_content_jsonb  jsonb  DEFAULT NULL,
            p_media_type     text   DEFAULT NULL,
            p_projects       text[] DEFAULT ARRAY[]::text[],
            p_subjects       text[] DEFAULT ARRAY[]::text[],
            p_verbs          text[] DEFAULT ARRAY[]::text[],
            p_events         text[] DEFAULT ARRAY[]::text[],
            p_metadata_jsonb jsonb  DEFAULT '{}'::jsonb,
            p_document_type  text   DEFAULT NULL
        ) RETURNS bigint
        LANGUAGE sql
        SECURITY DEFINER
        SET search_path = pg_catalog, maludb_core, pg_temp
        AS $facade$
            SELECT maludb_core._upload_document_for_schema(
                %L::name,
                p_title,
                p_content_text,
                p_source_type,
                p_content_jsonb,
                p_media_type,
                p_projects,
                p_subjects,
                p_verbs,
                p_events,
                p_metadata_jsonb,
                p_document_type
            )
        $facade$
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_upload_document(text, text, text, jsonb, text, text[], text[], text[], text[], jsonb, text) FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_upload_document(text, text, text, jsonb, text, text[], text[], text[], text[], jsonb, text) TO maludb_memory_admin, maludb_memory_executor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_upload_document', 'function', 'Schema-local document upload facade.');
    v_count := v_count + 1;

    RETURN v_count;
END;
$body$;

REVOKE ALL ON FUNCTION maludb_core._enable_memory_schema_0810_facade(name) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core._enable_memory_schema_0810_facade(name)
    TO maludb_memory_admin, maludb_memory_executor;

-- ===== 6. wire the 0810 facade into enable_memory_schema ============
-- Same body as 0.80.3 plus the 0810 builder call. The conditional
-- managed-view drop list stays as-is because we are appending to
-- maludb_document (CREATE OR REPLACE handles that) rather than reshaping
-- the column list.
CREATE OR REPLACE FUNCTION maludb_core.enable_memory_schema(p_schema name DEFAULT current_schema())
RETURNS TABLE(schema_name name, enabled_version text, object_count integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
DECLARE
    v_enabled_version text := maludb_core.maludb_core_version();
    v_count integer := 0;
    v_view  name;
BEGIN
    IF p_schema IS NULL THEN
        p_schema := current_schema();
    END IF;

    PERFORM maludb_core._memory_schema_assert_manageable(p_schema);

    FOREACH v_view IN ARRAY ARRAY['maludb_subject','maludb_memory','maludb_skill','maludb_document']::name[]
    LOOP
        IF EXISTS (
            SELECT 1 FROM maludb_core.malu$enabled_schema_object o
             WHERE o.schema_name = p_schema
               AND o.object_name = v_view
               AND o.object_kind = 'view'
        ) THEN
            EXECUTE format('DROP VIEW IF EXISTS %I.%I CASCADE', p_schema, v_view);
        END IF;
    END LOOP;

    INSERT INTO maludb_core.malu$enabled_schema(schema_name, enabled_version, enabled_by)
    VALUES (p_schema, v_enabled_version, session_user)
    ON CONFLICT ON CONSTRAINT malu$enabled_schema_pkey DO UPDATE
       SET enabled_version   = EXCLUDED.enabled_version,
           last_refreshed_at = now();

    v_count := v_count + maludb_core._enable_memory_schema_subject_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_core_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_ingest_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_pool_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_ai_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_075_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_076_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_078_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_080_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_0802_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_0803_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_0810_facade(p_schema);
    PERFORM maludb_core._grant_memory_schema_reader_access(p_schema);

    schema_name := p_schema;
    enabled_version := v_enabled_version;
    object_count := v_count;
    RETURN NEXT;
END;
$body$;

REVOKE ALL ON FUNCTION maludb_core.enable_memory_schema(name) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core.enable_memory_schema(name)
    TO maludb_memory_admin, maludb_memory_executor, maludb_user, maludb_admin;
