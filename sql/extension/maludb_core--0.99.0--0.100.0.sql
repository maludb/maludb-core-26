\echo Use "ALTER EXTENSION maludb_core UPDATE TO '0.100.0'" to load this file. \quit

-- =====================================================================
-- maludb_core 0.99.0 -> 0.100.0  --  document/note reindex protocol
--
-- A document's (or note's) SVPOR extraction -- the subjects/verbs/SVO
-- statements that maludb_memory_ingest_extraction minted from its text --
-- is written ONCE, at ingest, from whatever the external API server's
-- extractor produced. It rots the same two ways a skill's tags do:
--   1. the SVPOR vocabulary keeps growing, so an old document never
--      links to subjects/verbs minted after it was ingested; and
--   2. a weak first extraction freezes a poor graph in place (missing
--      or wrong edges), degrading note_search / graph traversal.
--
-- This release ships the DATABASE half of a background reindex that
-- re-derives a document's graph footprint against the CURRENT graph --
-- the documents/notes analogue of the 0.99.0 skill reindex. As always,
-- core never calls a model; it exposes a claim -> apply contract an
-- external worker drives:
--
--     loop:
--       rows = maludb_memory_reindex_claim(limit, max_age, source_types)
--       for r in rows:
--           extraction = model.extract(r.content_text, current_registry)  -- worker
--           maludb_memory_reindex_apply(r.document_id, extraction, MODEL)
--
-- WHY THIS IS SAFE WITHOUT TOUCHING THE INGEST PATH
--   _memory_ingest_extraction_for_schema is already idempotent on
--   re-run for the SAME document: subjects/verbs upsert by
--   canonical_name, SVO statements upsert by their (subject,verb,object)
--   identity, attributes upsert by (target,attr_name) via
--   _memory_apply_attributes_for_schema, and relationship inserts are
--   wrapped in a per-row exception handler (duplicates are skipped, not
--   raised). The ONLY non-idempotent part is the 'document' section,
--   which mints a NEW document row. So apply strips 'document' and
--   passes p_source_id = the existing document, so every "$source" edge
--   re-links to it -- no duplicate document, no core change.
--
--   1. malu$document gains last_indexed / last_indexed_model (the
--      watermark that stops repeat work + the hook for migrating to a
--      cheaper model later), mirroring malu$skill_package.
--   2. _document_reindex_claim_for_schema: registry-aware staleness scan
--      (never indexed / older than p_max_age / older than the newest
--      subject|verb's created_at). Returns the document's stored text so
--      the worker can re-extract it. Only re-extractable rows (non-NULL
--      content_text, not archived/tombstoned) are claimed.
--   3. _document_reindex_apply_for_schema: REPLACE the document's
--      "$source"-anchored statement footprint (statements with the
--      document as an endpoint), then re-ingest the fresh extraction
--      with the 'document' section stripped and p_source_id pinned.
--      Shared subjects/verbs merge (never deleted); embeddings refresh
--      for free because the 0.95.0 dirty-queue triggers fire on the
--      replaced statements / merged subjects. Stamps last_indexed.
--      (LIMIT of v1: subject<->subject edges and relationships are not
--      individually attributable to a document, so they merge/refresh
--      rather than being replaced. Chunk re-embedding for the chunked
--      ingest path is a later phase.)
--   4. Tenant facades maludb_memory_reindex_claim (read-only -> auditor)
--      + maludb_memory_reindex_apply (write; curator-only in
--      maludb_public) via a new _01000 builder. The builder creates only
--      the two objects it introduces. Tenants pick them up by re-running
--      enable_memory_schema().
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Watermark columns on the document.
-- ---------------------------------------------------------------------
ALTER TABLE maludb_core.malu$document
    ADD COLUMN IF NOT EXISTS last_indexed       timestamptz,
    ADD COLUMN IF NOT EXISTS last_indexed_model text;

-- ---------------------------------------------------------------------
-- 2. _document_reindex_claim_for_schema. SECURITY DEFINER bypasses RLS,
--    so every tenant table carries an explicit owner_schema predicate.
--    The registry watermark is max(created_at) over this tenant's
--    subjects and verbs (NULL when the graph is empty).
-- ---------------------------------------------------------------------
CREATE FUNCTION maludb_core._document_reindex_claim_for_schema(
    p_schema       name,
    p_limit        integer  DEFAULT 32,
    p_max_age      interval DEFAULT '30 days',
    p_source_types text[]   DEFAULT NULL
) RETURNS TABLE (
    document_id        bigint,
    source_type        text,
    title              text,
    media_type         text,
    document_type      text,
    content_text       text,
    last_indexed       timestamptz,
    last_indexed_model text
) LANGUAGE plpgsql STABLE
SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
#variable_conflict use_column
DECLARE
    v_limit     integer := LEAST(GREATEST(COALESCE(p_limit, 32), 1), 500);
    v_cutoff    timestamptz := CASE WHEN p_max_age IS NULL THEN NULL ELSE now() - p_max_age END;
    v_watermark timestamptz;
BEGIN
    PERFORM maludb_core._memory_schema_assert_manageable(p_schema);

    SELECT max(c) INTO v_watermark
      FROM (
        SELECT max(created_at) AS c FROM maludb_core.malu$svpor_subject WHERE owner_schema = p_schema
        UNION ALL
        SELECT max(created_at)      FROM maludb_core.malu$svpor_verb    WHERE owner_schema = p_schema
      ) w;

    RETURN QUERY
    SELECT d.document_id, d.source_type, d.title, d.media_type, d.document_type,
           sp.content_text, d.last_indexed, d.last_indexed_model
      FROM maludb_core.malu$document d
      JOIN maludb_core.malu$source_package sp
        ON sp.source_package_id = d.source_package_id
     WHERE d.owner_schema = p_schema
       AND d.lifecycle_state NOT IN ('archived', 'tombstoned')
       AND sp.content_text IS NOT NULL
       AND btrim(sp.content_text) <> ''
       AND (p_source_types IS NULL OR d.source_type = ANY (p_source_types))
       AND (d.last_indexed IS NULL
            OR (v_cutoff    IS NOT NULL AND d.last_indexed < v_cutoff)
            OR (v_watermark IS NOT NULL AND d.last_indexed < v_watermark))
     ORDER BY d.last_indexed NULLS FIRST, d.document_id
     LIMIT v_limit;
END;
$body$;

REVOKE ALL ON FUNCTION maludb_core._document_reindex_claim_for_schema(name, integer, interval, text[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core._document_reindex_claim_for_schema(name, integer, interval, text[])
    TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;

-- ---------------------------------------------------------------------
-- 3. _document_reindex_apply_for_schema. Replace the document's
--    "$source"-anchored statement footprint, then re-ingest the fresh
--    extraction (idempotent for everything except the 'document'
--    section, which we strip; p_source_id pins "$source" to the existing
--    document so no duplicate is created). Stamps last_indexed.
-- ---------------------------------------------------------------------
CREATE FUNCTION maludb_core._document_reindex_apply_for_schema(
    p_schema      name,
    p_document_id bigint,
    p_extraction  jsonb,
    p_model       text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
DECLARE
    v_model       text := NULLIF(btrim(COALESCE(p_model, '')), '');
    v_source_type text;
    v_clean       jsonb;
    v_report      jsonb;
    d_stmts       integer := 0;
BEGIN
    PERFORM maludb_core._memory_schema_assert_manageable(p_schema);

    SELECT source_type INTO v_source_type
      FROM maludb_core.malu$document
     WHERE owner_schema = p_schema AND document_id = p_document_id
     FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'document_reindex_apply: document % not found in schema %', p_document_id, p_schema
            USING ERRCODE = 'P0002';
    END IF;

    -- Replace the prior footprint: statements with this document as an
    -- endpoint (the "$source --verb--> subject" edges the extractor emits).
    -- Shared subjects/verbs are NOT deleted -- they merge on re-ingest.
    WITH d AS (
        DELETE FROM maludb_core.malu$svpor_statement
         WHERE owner_schema = p_schema
           AND ((subject_kind = 'document' AND subject_id = p_document_id)
                OR (object_kind = 'document' AND object_id = p_document_id))
        RETURNING 1)
    SELECT count(*) INTO d_stmts FROM d;

    -- Re-ingest everything but the document section. p_source_kind is the
    -- $source ANCHOR endpoint kind, which is always 'document' (the
    -- malu$document row; note-vs-document is its source_type, not the
    -- statement endpoint kind) -- this is what note_search walks. p_source_id
    -- pins "$source" to this document, so no duplicate document is created.
    v_clean  := COALESCE(p_extraction, '{}'::jsonb) - 'document';
    v_report := maludb_core._memory_ingest_extraction_for_schema(
                    p_owner_schema => p_schema,
                    p_extraction   => v_clean,
                    p_source_kind  => 'document',
                    p_source_id    => p_document_id,
                    p_provenance   => 'accepted');

    UPDATE maludb_core.malu$document
       SET last_indexed       = now(),
           last_indexed_model = v_model,
           updated_at         = now()
     WHERE owner_schema = p_schema AND document_id = p_document_id;

    RETURN jsonb_build_object(
        'document_id',        p_document_id,
        'source_type',        v_source_type,
        'last_indexed_model', v_model,
        'statements_replaced', d_stmts,
        'ingest',             v_report);
END;
$body$;

REVOKE ALL ON FUNCTION maludb_core._document_reindex_apply_for_schema(name, bigint, jsonb, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core._document_reindex_apply_for_schema(name, bigint, jsonb, text)
    TO maludb_memory_admin, maludb_memory_executor;

-- ---------------------------------------------------------------------
-- 4. 01000 facade builder: maludb_memory_reindex_claim (read-only) +
--    maludb_memory_reindex_apply (write). maludb_public keeps the
--    curator-only write posture of the other public-write facades.
-- ---------------------------------------------------------------------
CREATE FUNCTION maludb_core._enable_memory_schema_01000_facade(p_schema name) RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
DECLARE
    v_count integer := 0;
BEGIN
    PERFORM maludb_core._memory_schema_assert_manageable(p_schema);

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_memory_reindex_claim', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_memory_reindex_claim(
            p_limit        integer  DEFAULT 32,
            p_max_age      interval DEFAULT '30 days',
            p_source_types text[]   DEFAULT NULL
        ) RETURNS TABLE (
            document_id        bigint,
            source_type        text,
            title              text,
            media_type         text,
            document_type      text,
            content_text       text,
            last_indexed       timestamptz,
            last_indexed_model text
        )
        LANGUAGE SQL STABLE
        SECURITY DEFINER
        SET search_path = pg_catalog, maludb_core, pg_temp
        AS $fn$
            SELECT * FROM maludb_core._document_reindex_claim_for_schema(
                %L::name, p_limit, p_max_age, p_source_types)
        $fn$;
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_memory_reindex_claim(integer, interval, text[]) FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_memory_reindex_claim(integer, interval, text[]) TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_memory_reindex_claim', 'function', 'Schema-local stalest-first scan of documents/notes due for SVPOR reindexing.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_memory_reindex_apply', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_memory_reindex_apply(
            p_document_id bigint,
            p_extraction  jsonb,
            p_model       text DEFAULT NULL
        ) RETURNS jsonb
        LANGUAGE SQL
        SECURITY DEFINER
        SET search_path = pg_catalog, maludb_core, pg_temp
        AS $fn$
            SELECT maludb_core._document_reindex_apply_for_schema(
                %L::name, p_document_id, p_extraction, p_model)
        $fn$;
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_memory_reindex_apply(bigint, jsonb, text) FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_memory_reindex_apply(bigint, jsonb, text) TO maludb_memory_admin, maludb_memory_executor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_memory_reindex_apply', 'function', 'Schema-local replace-footprint document/note SVPOR reindex apply.');
    v_count := v_count + 1;

    IF p_schema = 'maludb_public' THEN
        EXECUTE format('REVOKE EXECUTE ON FUNCTION %I.maludb_memory_reindex_apply(bigint, jsonb, text) FROM maludb_memory_executor', p_schema);
        EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_memory_reindex_apply(bigint, jsonb, text) TO maludb_skill_curator', p_schema);
    END IF;

    RETURN v_count;
END;
$body$;

REVOKE ALL ON FUNCTION maludb_core._enable_memory_schema_01000_facade(name) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core._enable_memory_schema_01000_facade(name)
    TO maludb_memory_admin, maludb_memory_executor;

-- ---------------------------------------------------------------------
-- 5. Wire the 01000 facade into enable_memory_schema. Functions only --
--    the drop-first view list is untouched.
-- ---------------------------------------------------------------------
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

    FOREACH v_view IN ARRAY ARRAY['maludb_subject','maludb_memory','maludb_skill','maludb_document','maludb_svpor_attribute','maludb_episode','maludb_episode_with_attributes','maludb_subject_type']::name[]
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
    v_count := v_count + maludb_core._enable_memory_schema_0880_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_0890_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_0900_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_0910_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_0920_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_0940_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_0950_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_0960_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_0970_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_0980_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_0990_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_01000_facade(p_schema);
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

-- ---------------------------------------------------------------------
-- 6. Version stamp.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION maludb_core.maludb_core_version() RETURNS text
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$ SELECT '0.100.0'::text $body$;
