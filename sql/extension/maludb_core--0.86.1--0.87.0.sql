\echo Use "ALTER EXTENSION maludb_core UPDATE TO '0.87.0'" to load this file. \quit

-- =====================================================================
-- maludb_core 0.86.1 -> 0.87.0
--
-- Documents join the unified property graph.
--
-- Before this release, uploading a document with
-- maludb_upload_document(..., p_projects => ARRAY['MIST']) recorded the
-- project relationship only as a soft text tag in malu$document_tag
-- (tag_kind='project', tag_value='MIST') -- a string, not a subject id.
-- malu$document.primary_project_id (a real FK) stayed NULL, no
-- svpor_statement edge was created, and the document was therefore
-- invisible to maludb_graph_walk / maludb_graph_neighbors / maludb_edge.
-- You could traverse from a project to its people/sprints/tasks/meetings
-- but not to its documents.
--
-- Fix: resolve project/subject tags to subjects (creating the subject if
-- absent), record the resolved id on the tag (tag_object_id), set
-- primary_project_id from the first project, and create a real
-- svpor_statement edge `document --verb--> subject`
-- (project => 'concerns', subject => 'mentions', stakeholder =>
-- 'involves'). 'document' is already a valid svpor_statement endpoint and
-- malu$edge_unified already surfaces svpor_statement, so the document
-- becomes reachable by the existing traversal with no edge-view change --
-- it joins the graph the same way an episode or person does.
--
--   _document_graph_link(...)              -- resolve a tag -> subject + edge
--   _upload_document_for_schema(...)       -- now links on upload
--   maludb_document_graph_backfill()       -- connect already-uploaded docs
--
-- The soft tags are kept (now carrying tag_object_id), so the document
-- tag UI and provenance flow are unchanged. Verbs concerns/mentions/
-- involves are seeded per schema.
-- =====================================================================

CREATE OR REPLACE FUNCTION maludb_core.maludb_core_version() RETURNS text
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$ SELECT '0.87.0'::text $body$;

-- index supporting reverse lookup from a resolved tag to its document
CREATE INDEX IF NOT EXISTS malu$document_tag_object_idx
    ON maludb_core.malu$document_tag(owner_schema, tag_object_type, tag_object_id)
    WHERE tag_object_id IS NOT NULL;

-- ===== _document_graph_link -- resolve one tag to a subject + edge ====
-- SECURITY DEFINER, writes with explicit p_owner_schema (NOT
-- current_schema), so it is correct whether called from the DEFINER
-- upload path (current_schema = maludb_core there) or the backfill.
-- Idempotent: subject resolved by canonical_name, edge ON CONFLICT DO
-- NOTHING, tag_object_id set only when changed. Returns the subject id
-- (NULL for an empty value or an unsupported tag kind).
CREATE FUNCTION maludb_core._document_graph_link(
    p_owner_schema name,
    p_document_id  bigint,
    p_tag_kind     text,
    p_tag_value    text,
    p_provenance   text DEFAULT 'provided'
) RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
DECLARE
    v_value        text := pg_catalog.btrim(COALESCE(p_tag_value, ''));
    v_subject_type text;
    v_verb         text;
    v_subject_id   bigint;
    v_verb_id      bigint;
    v_prov         text := COALESCE(NULLIF(pg_catalog.btrim(p_provenance), ''), 'provided');
BEGIN
    IF v_value = '' THEN
        RETURN NULL;
    END IF;

    CASE p_tag_kind
        WHEN 'project'     THEN v_subject_type := 'project'; v_verb := 'concerns';
        WHEN 'stakeholder' THEN v_subject_type := 'person';  v_verb := 'involves';
        WHEN 'subject'     THEN v_subject_type := 'concept'; v_verb := 'mentions';
        ELSE
            RETURN NULL;   -- only subject-like tag kinds become graph edges
    END CASE;

    -- resolve or create the subject (do not override an existing type)
    SELECT subject_id INTO v_subject_id
      FROM maludb_core.malu$svpor_subject
     WHERE owner_schema = p_owner_schema AND canonical_name = v_value;
    IF v_subject_id IS NULL THEN
        INSERT INTO maludb_core.malu$svpor_subject(owner_schema, canonical_name, subject_type)
        VALUES (p_owner_schema, v_value, v_subject_type)
        RETURNING subject_id INTO v_subject_id;
    END IF;

    -- resolve or create the verb
    SELECT verb_id INTO v_verb_id
      FROM maludb_core.malu$svpor_verb
     WHERE owner_schema = p_owner_schema AND canonical_name = v_verb;
    IF v_verb_id IS NULL THEN
        INSERT INTO maludb_core.malu$svpor_verb(owner_schema, canonical_name)
        VALUES (p_owner_schema, v_verb)
        RETURNING verb_id INTO v_verb_id;
    END IF;

    -- the edge: document --verb--> subject (idempotent on the SVO identity)
    INSERT INTO maludb_core.malu$svpor_statement
        (owner_schema, subject_kind, subject_id, verb_id, object_kind, object_id, provenance)
    VALUES
        (p_owner_schema, 'document', p_document_id, v_verb_id, 'subject', v_subject_id, v_prov)
    ON CONFLICT (owner_schema, subject_kind, subject_id, verb_id, object_kind, object_id) DO NOTHING;

    -- record the resolved object on the soft tag
    UPDATE maludb_core.malu$document_tag
       SET tag_object_type = 'subject', tag_object_id = v_subject_id
     WHERE owner_schema = p_owner_schema
       AND document_id = p_document_id
       AND tag_kind = p_tag_kind
       AND tag_value = v_value
       AND tag_object_id IS DISTINCT FROM v_subject_id;

    RETURN v_subject_id;
END;
$body$;
REVOKE ALL ON FUNCTION maludb_core._document_graph_link(name, bigint, text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core._document_graph_link(name, bigint, text, text, text)
    TO maludb_memory_admin, maludb_memory_executor;

-- ===== _upload_document_for_schema -- link on upload =================
CREATE OR REPLACE FUNCTION maludb_core._upload_document_for_schema(
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
    v_source_type        text := COALESCE(NULLIF(p_source_type, ''), 'document');
    v_document_type      text := NULLIF(pg_catalog.btrim(COALESCE(p_document_type, '')), '');
    v_source_id          bigint;
    v_doc_id             bigint;
    v_hash               text;
    v_size               bigint;
    v_bytes              bytea;
    v_val                text;
    v_sid                bigint;
    v_primary_project_id bigint;
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

    -- ---- NEW: connect the document into the unified graph ----------
    -- project tags -> document --concerns--> subject (+ primary_project_id)
    FOR v_val IN
        SELECT DISTINCT pg_catalog.btrim(x)
          FROM pg_catalog.unnest(COALESCE(p_projects, ARRAY[]::text[])) AS x
         WHERE pg_catalog.btrim(x) <> ''
    LOOP
        v_sid := maludb_core._document_graph_link(p_owner_schema, v_doc_id, 'project', v_val, 'provided');
        IF v_primary_project_id IS NULL THEN
            v_primary_project_id := v_sid;
        END IF;
    END LOOP;

    -- subject tags -> document --mentions--> subject
    FOR v_val IN
        SELECT DISTINCT pg_catalog.btrim(x)
          FROM pg_catalog.unnest(COALESCE(p_subjects, ARRAY[]::text[])) AS x
         WHERE pg_catalog.btrim(x) <> ''
    LOOP
        PERFORM maludb_core._document_graph_link(p_owner_schema, v_doc_id, 'subject', v_val, 'provided');
    END LOOP;

    IF v_primary_project_id IS NOT NULL THEN
        UPDATE maludb_core.malu$document
           SET primary_project_id = v_primary_project_id
         WHERE owner_schema = p_owner_schema AND document_id = v_doc_id;
    END IF;

    RETURN v_doc_id;
END;
$body$;
REVOKE ALL ON FUNCTION maludb_core._upload_document_for_schema(name, text, text, text, jsonb, text, text[], text[], text[], text[], jsonb, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core._upload_document_for_schema(name, text, text, text, jsonb, text, text[], text[], text[], text[], jsonb, text)
    TO maludb_memory_admin, maludb_memory_executor;

-- ===== backfill already-uploaded documents ==========================
CREATE FUNCTION maludb_core._document_graph_backfill_for_schema(p_owner_schema name)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
DECLARE
    r       record;
    v_sid   bigint;
    v_count integer := 0;
BEGIN
    PERFORM maludb_core._memory_schema_assert_manageable(p_owner_schema);

    FOR r IN
        SELECT document_id, tag_kind, tag_value
          FROM maludb_core.malu$document_tag
         WHERE owner_schema = p_owner_schema
           AND tag_kind IN ('project','subject','stakeholder')
         ORDER BY document_id, tag_kind
    LOOP
        v_sid := maludb_core._document_graph_link(p_owner_schema, r.document_id, r.tag_kind, r.tag_value, 'provided');
        IF v_sid IS NOT NULL THEN
            v_count := v_count + 1;
            IF r.tag_kind = 'project' THEN
                UPDATE maludb_core.malu$document
                   SET primary_project_id = v_sid
                 WHERE owner_schema = p_owner_schema
                   AND document_id = r.document_id
                   AND primary_project_id IS NULL;
            END IF;
        END IF;
    END LOOP;

    RETURN v_count;
END;
$body$;
REVOKE ALL ON FUNCTION maludb_core._document_graph_backfill_for_schema(name) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core._document_graph_backfill_for_schema(name)
    TO maludb_memory_admin, maludb_memory_executor;

-- ===== 0.87.0 schema-local facade builder ===========================
CREATE FUNCTION maludb_core._enable_memory_schema_0870_facade(p_schema name) RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
DECLARE
    v_count integer := 0;
BEGIN
    PERFORM maludb_core._memory_schema_assert_manageable(p_schema);

    -- seed the document-link verbs (idempotent)
    EXECUTE format($sql$
        INSERT INTO maludb_core.malu$svpor_verb (owner_schema, canonical_name, description)
        VALUES
            (%L,'concerns','Document concerns a project or subject.'),
            (%L,'mentions','Document mentions a subject.'),
            (%L,'involves','Document involves a stakeholder.')
        ON CONFLICT (owner_schema, canonical_name) DO NOTHING
    $sql$, p_schema, p_schema, p_schema);

    -- maludb_document_graph_backfill(): connect this schema's existing docs
    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_document_graph_backfill', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_document_graph_backfill()
        RETURNS integer LANGUAGE sql SECURITY DEFINER
        SET search_path = %I, maludb_core, pg_temp
        AS $facade$ SELECT maludb_core._document_graph_backfill_for_schema(current_schema()) $facade$
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_document_graph_backfill() FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_document_graph_backfill() TO maludb_memory_admin, maludb_memory_executor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_document_graph_backfill', 'function', 'Connect already-uploaded documents into the unified graph.');
    v_count := v_count + 1;

    RETURN v_count;
END;
$body$;

REVOKE ALL ON FUNCTION maludb_core._enable_memory_schema_0870_facade(name) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core._enable_memory_schema_0870_facade(name)
    TO maludb_memory_admin, maludb_memory_executor;

-- ===== wire the 0870 facade into enable_memory_schema ===============
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

    FOREACH v_view IN ARRAY ARRAY['maludb_subject','maludb_memory','maludb_skill','maludb_document','maludb_svpor_attribute']::name[]
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
    v_count := v_count + maludb_core._enable_memory_schema_0820_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_0830_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_0840_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_0850_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_0860_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_0870_facade(p_schema);
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
