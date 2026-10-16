\echo Use "ALTER EXTENSION maludb_core UPDATE TO '0.92.0'" to load this file. \quit

-- =====================================================================
-- maludb_core 0.91.0 -> 0.92.0
--
-- One-call memory ingestion from an extraction JSON object.
--
-- The project does NOT run any LLM. An external extractor produces a single
-- JSON object (the contract in docs/memory-extraction-json-contract.md) and
-- this release materializes ALL of its memory structures in one call:
--   * subjects (nodes) + node attributes + external ref pointers
--   * verbs
--   * episodes (all kinds) + episode attributes
--   * edges (verb-typed SVO statements) + edge attributes
--   * subject<->subject relationships (the directed/temporal layer)
--   * optionally the source document itself
--
-- Decisions locked with the requirements (see the contract doc):
--   C  v1 is the full core; claims/facts are a fast-follow (NOT here).
--   D  provenance defaults to 'accepted' (API-extracted, no human review).
--   E  episodes dedup on (episode_kind, title, occurred_at).
--   Names are TRUSTED: the extractor had the canonical match-list, so the DB
--   resolves a subject/verb by exact canonical_name or alias and creates one
--   only if absent (no fuzzy matching, no dedup beyond exact identity).
--   Embeddings are DEFERRED (a separate worker); each edge keeps its
--   source_span in metadata so the worker can embed it later. Hints are not a
--   DB concept -- the extractor bakes them into explicit subjects/edges.
--
-- Bad items are SKIPPED, not fatal: each subject/episode/edge/relationship is
-- applied in its own subtransaction; a failure drops that one item and is
-- recorded in the returned report's "skipped" list.
--
-- New surface (per-tenant facade via enable_memory_schema, re-enable-safe):
--   maludb_memory_ingest_extraction(p_extraction jsonb,
--       p_source_kind text='document', p_source_id bigint=NULL,
--       p_provenance text='accepted') RETURNS jsonb   -- the report
--
-- Backward compatible: new functions only; existing schemas pick up the
-- facade by re-running maludb_core.enable_memory_schema().
-- =====================================================================

CREATE OR REPLACE FUNCTION maludb_core.maludb_core_version() RETURNS text
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$ SELECT '0.92.0'::text $body$;

-- =====================================================================
-- 1. Attribute applier -- typed attribute upsert with EXPLICIT owner_schema
--    (reused for node, episode, and edge attributes; the public
--    attributes_apply is current_schema()-bound and can't be used here).
-- =====================================================================
CREATE OR REPLACE FUNCTION maludb_core._memory_apply_attributes_for_schema(
    p_owner_schema       name,
    p_target_kind        text,
    p_target_id          bigint,
    p_attributes         jsonb,
    p_default_provenance text DEFAULT 'accepted'
) RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
DECLARE
    v_count integer := 0;
BEGIN
    IF p_attributes IS NULL OR jsonb_typeof(p_attributes) <> 'array' THEN
        RETURN 0;
    END IF;

    INSERT INTO maludb_core.malu$svpor_attribute
        (owner_schema, target_kind, target_id, attr_name,
         value_timestamp, value_range, value_numeric, value_text, value_jsonb,
         unit, provenance, confidence, valid_from, valid_to, metadata_jsonb,
         ref_source, ref_entity, ref_key)
    SELECT p_owner_schema, p_target_kind, p_target_id,
           btrim(e ->> 'attr_name'),
           (e ->> 'value_timestamp')::timestamptz,
           (e ->> 'value_range')::tstzrange,
           (e ->> 'value_numeric')::numeric,
           e ->> 'value_text',
           e -> 'value_jsonb',
           e ->> 'unit',
           COALESCE(e ->> 'provenance', p_default_provenance),
           (e ->> 'confidence')::numeric,
           (e ->> 'valid_from')::timestamptz,
           (e ->> 'valid_to')::timestamptz,
           COALESCE(e -> 'metadata_jsonb', '{}'::jsonb),
           e ->> 'ref_source', e ->> 'ref_entity', e ->> 'ref_key'
      FROM jsonb_array_elements(p_attributes) AS e
     WHERE COALESCE(btrim(e ->> 'attr_name'), '') <> ''
    ON CONFLICT (owner_schema, target_kind, target_id, attr_name)
    DO UPDATE SET
        value_timestamp = EXCLUDED.value_timestamp,
        value_range     = EXCLUDED.value_range,
        value_numeric   = EXCLUDED.value_numeric,
        value_text      = EXCLUDED.value_text,
        value_jsonb     = EXCLUDED.value_jsonb,
        unit            = EXCLUDED.unit,
        provenance      = EXCLUDED.provenance,
        confidence      = EXCLUDED.confidence,
        valid_from      = EXCLUDED.valid_from,
        valid_to        = EXCLUDED.valid_to,
        metadata_jsonb  = EXCLUDED.metadata_jsonb,
        ref_source      = EXCLUDED.ref_source,
        ref_entity      = EXCLUDED.ref_entity,
        ref_key         = EXCLUDED.ref_key;

    GET DIAGNOSTICS v_count = ROW_COUNT;
    RETURN v_count;
END;
$body$;
REVOKE ALL ON FUNCTION maludb_core._memory_apply_attributes_for_schema(name, text, bigint, jsonb, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core._memory_apply_attributes_for_schema(name, text, bigint, jsonb, text)
    TO maludb_memory_admin, maludb_memory_executor;

-- =====================================================================
-- 2. _memory_ingest_extraction_for_schema -- materialize the whole object.
--    SECURITY DEFINER, explicit owner_schema throughout. Per-item
--    subtransactions => skip-the-bad-item. Returns a JSON report.
-- =====================================================================
CREATE OR REPLACE FUNCTION maludb_core._memory_ingest_extraction_for_schema(
    p_owner_schema name,
    p_extraction   jsonb,
    p_source_kind  text   DEFAULT 'document',
    p_source_id    bigint DEFAULT NULL,
    p_provenance   text   DEFAULT 'accepted'
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
DECLARE
    v_prov         text := COALESCE(NULLIF(btrim(p_provenance), ''), 'accepted');
    v_src_kind     text := lower(btrim(COALESCE(p_source_kind, '')));
    v_src_id       bigint := p_source_id;
    v_doc          jsonb;
    v_ids          jsonb := '{}'::jsonb;   -- key -> id
    v_kinds        jsonb := '{}'::jsonb;   -- key -> kind
    v_skipped      jsonb := '[]'::jsonb;
    r              record;
    v_key          text;
    v_name         text;
    v_id           bigint;
    v_existing     bigint;
    v_idx          integer;
    -- counters
    c_subj_c integer := 0; c_subj_r integer := 0;
    c_verb_c integer := 0; c_verb_r integer := 0;
    c_epi_c  integer := 0; c_epi_r  integer := 0;
    c_edges  integer := 0; c_rels   integer := 0;
    c_nattr  integer := 0; c_eattr  integer := 0; c_epattr integer := 0;
    -- edge resolution
    v_sk text; v_si bigint; v_ok text; v_oi bigint; v_vid bigint; v_stmt bigint;
    v_ref text; v_okind text;
BEGIN
    PERFORM maludb_core._memory_schema_assert_manageable(p_owner_schema);

    IF p_extraction IS NULL OR jsonb_typeof(p_extraction) <> 'object' THEN
        RAISE EXCEPTION 'memory_ingest_extraction: p_extraction must be a JSON object'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;
    IF v_prov NOT IN ('provided','suggested','accepted','rejected') THEN
        RAISE EXCEPTION 'memory_ingest_extraction: bad provenance %', v_prov
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    -- ---- source anchor: create the document, or use the passed source -----
    v_doc := p_extraction -> 'document';
    IF v_doc IS NOT NULL AND jsonb_typeof(v_doc) = 'object' THEN
        v_src_id := maludb_core._upload_document_for_schema(
            p_owner_schema,
            v_doc ->> 'title',
            v_doc ->> 'content_text',
            COALESCE(NULLIF(v_doc ->> 'source_type', ''), 'document'),
            CASE WHEN jsonb_typeof(v_doc -> 'content_jsonb') = 'object' THEN v_doc -> 'content_jsonb' ELSE NULL END,
            v_doc ->> 'media_type',
            ARRAY[]::text[], ARRAY[]::text[], ARRAY[]::text[], ARRAY[]::text[],
            COALESCE(v_doc -> 'metadata', '{}'::jsonb),
            v_doc ->> 'document_type');
        v_src_kind := 'document';
    END IF;

    -- ---- subjects ---------------------------------------------------------
    FOR r IN SELECT val, (ord - 1) AS idx
               FROM jsonb_array_elements(COALESCE(p_extraction -> 'subjects', '[]'::jsonb)) WITH ORDINALITY AS t(val, ord)
    LOOP
        BEGIN
            v_key  := r.val ->> 'key';
            v_name := btrim(COALESCE(r.val ->> 'name', ''));
            IF COALESCE(btrim(v_key), '') = '' OR v_name = '' THEN
                v_skipped := v_skipped || jsonb_build_object('section','subjects','index',r.idx,'reason','missing key or name');
                CONTINUE;
            END IF;

            SELECT subject_id INTO v_id
              FROM maludb_core.malu$svpor_subject
             WHERE owner_schema = p_owner_schema
               AND (canonical_name = v_name OR v_name = ANY(aliases))
             ORDER BY (canonical_name = v_name) DESC
             LIMIT 1;

            IF v_id IS NULL THEN
                INSERT INTO maludb_core.malu$svpor_subject (owner_schema, canonical_name, subject_type, aliases)
                VALUES (p_owner_schema, v_name,
                        maludb_core._normalize_svpor_subject_type(COALESCE(NULLIF(btrim(r.val ->> 'type'), ''), 'other')),
                        CASE WHEN jsonb_typeof(r.val -> 'aliases') = 'array'
                             THEN ARRAY(SELECT jsonb_array_elements_text(r.val -> 'aliases')) ELSE ARRAY[]::text[] END)
                RETURNING subject_id INTO v_id;
                c_subj_c := c_subj_c + 1;
            ELSE
                IF jsonb_typeof(r.val -> 'aliases') = 'array' THEN
                    UPDATE maludb_core.malu$svpor_subject s
                       SET aliases = (SELECT array_agg(DISTINCT a)
                                        FROM unnest(s.aliases || ARRAY(SELECT jsonb_array_elements_text(r.val -> 'aliases'))) a)
                     WHERE s.owner_schema = p_owner_schema AND s.subject_id = v_id;
                END IF;
                c_subj_r := c_subj_r + 1;
            END IF;

            c_nattr := c_nattr + maludb_core._memory_apply_attributes_for_schema(
                           p_owner_schema, 'subject', v_id, r.val -> 'attributes', v_prov);

            -- external ref pointer (sugar) -> a single reference attribute
            IF jsonb_typeof(r.val -> 'ref') = 'object' THEN
                c_nattr := c_nattr + maludb_core._memory_apply_attributes_for_schema(
                    p_owner_schema, 'subject', v_id,
                    jsonb_build_array(jsonb_build_object(
                        'attr_name', 'external_ref',
                        'value_text', COALESCE(r.val -> 'ref' ->> 'key', v_name),
                        'ref_source', r.val -> 'ref' ->> 'source',
                        'ref_entity', r.val -> 'ref' ->> 'entity',
                        'ref_key',    r.val -> 'ref' ->> 'key')),
                    v_prov);
            END IF;

            v_ids   := jsonb_set(v_ids,   ARRAY[v_key], to_jsonb(v_id));
            v_kinds := jsonb_set(v_kinds, ARRAY[v_key], to_jsonb('subject'::text));
        EXCEPTION WHEN OTHERS THEN
            v_skipped := v_skipped || jsonb_build_object('section','subjects','index',r.idx,'reason',left(SQLERRM,300));
        END;
    END LOOP;

    -- ---- verbs (explicit registration; edges also auto-create) ------------
    FOR r IN SELECT val, (ord - 1) AS idx
               FROM jsonb_array_elements(COALESCE(p_extraction -> 'verbs', '[]'::jsonb)) WITH ORDINALITY AS t(val, ord)
    LOOP
        BEGIN
            v_name := btrim(COALESCE(r.val ->> 'name', ''));
            IF v_name = '' THEN
                v_skipped := v_skipped || jsonb_build_object('section','verbs','index',r.idx,'reason','missing name');
                CONTINUE;
            END IF;
            SELECT verb_id INTO v_id FROM maludb_core.malu$svpor_verb
             WHERE owner_schema = p_owner_schema AND canonical_name = v_name;
            IF v_id IS NULL THEN
                INSERT INTO maludb_core.malu$svpor_verb (owner_schema, canonical_name, verb_type, aliases, description)
                VALUES (p_owner_schema, v_name,
                        maludb_core._normalize_svpor_verb_type(NULLIF(btrim(r.val ->> 'type'), ''), v_name),
                        CASE WHEN jsonb_typeof(r.val -> 'aliases') = 'array'
                             THEN ARRAY(SELECT jsonb_array_elements_text(r.val -> 'aliases')) ELSE ARRAY[]::text[] END,
                        r.val ->> 'description')
                RETURNING verb_id INTO v_id;
                c_verb_c := c_verb_c + 1;
            ELSE
                c_verb_r := c_verb_r + 1;
            END IF;
        EXCEPTION WHEN OTHERS THEN
            v_skipped := v_skipped || jsonb_build_object('section','verbs','index',r.idx,'reason',left(SQLERRM,300));
        END;
    END LOOP;

    -- ---- episodes (dedup on kind+title+occurred_at) -----------------------
    FOR r IN SELECT val, (ord - 1) AS idx
               FROM jsonb_array_elements(COALESCE(p_extraction -> 'episodes', '[]'::jsonb)) WITH ORDINALITY AS t(val, ord)
    LOOP
        BEGIN
            v_key  := r.val ->> 'key';
            v_name := btrim(COALESCE(r.val ->> 'title', ''));
            IF COALESCE(btrim(v_key), '') = '' OR v_name = '' OR COALESCE(btrim(r.val ->> 'kind'), '') = '' THEN
                v_skipped := v_skipped || jsonb_build_object('section','episodes','index',r.idx,'reason','missing key, kind, or title');
                CONTINUE;
            END IF;

            SELECT episode_id INTO v_id
              FROM maludb_core.malu$episode_object
             WHERE owner_schema = p_owner_schema
               AND episode_kind = btrim(r.val ->> 'kind')
               AND title = v_name
               AND occurred_at IS NOT DISTINCT FROM (r.val ->> 'occurred_at')::timestamptz;

            IF v_id IS NULL THEN
                INSERT INTO maludb_core.malu$episode_object
                    (owner_schema, episode_kind, title, summary, occurred_at, occurred_until)
                VALUES (p_owner_schema, btrim(r.val ->> 'kind'), v_name, r.val ->> 'summary',
                        (r.val ->> 'occurred_at')::timestamptz, (r.val ->> 'occurred_until')::timestamptz)
                RETURNING episode_id INTO v_id;
                c_epi_c := c_epi_c + 1;
            ELSE
                c_epi_r := c_epi_r + 1;
            END IF;

            c_epattr := c_epattr + maludb_core._memory_apply_attributes_for_schema(
                            p_owner_schema, 'episode_object', v_id, r.val -> 'attributes', v_prov);

            v_ids   := jsonb_set(v_ids,   ARRAY[v_key], to_jsonb(v_id));
            v_kinds := jsonb_set(v_kinds, ARRAY[v_key], to_jsonb('episode_object'::text));
        EXCEPTION WHEN OTHERS THEN
            v_skipped := v_skipped || jsonb_build_object('section','episodes','index',r.idx,'reason',left(SQLERRM,300));
        END;
    END LOOP;

    -- ---- edges (verb-typed SVO statements) --------------------------------
    FOR r IN SELECT val, (ord - 1) AS idx
               FROM jsonb_array_elements(COALESCE(p_extraction -> 'edges', '[]'::jsonb)) WITH ORDINALITY AS t(val, ord)
    LOOP
        BEGIN
            -- subject endpoint
            v_ref := COALESCE(r.val ->> 'subject', '$source');
            IF v_ref = '$source' THEN
                v_sk := v_src_kind; v_si := v_src_id;
            ELSIF v_ids ? v_ref THEN
                v_sk := v_kinds ->> v_ref; v_si := (v_ids ->> v_ref)::bigint;
            ELSE
                v_sk := NULL; v_si := NULL;
            END IF;

            -- object endpoint (default $source)
            v_ref := COALESCE(r.val ->> 'object', '$source');
            IF v_ref = '$source' THEN
                v_ok := v_src_kind; v_oi := v_src_id;
            ELSIF v_ids ? v_ref THEN
                v_ok := v_kinds ->> v_ref; v_oi := (v_ids ->> v_ref)::bigint;
            ELSE
                v_ok := NULL; v_oi := NULL;
            END IF;

            IF v_si IS NULL OR v_oi IS NULL THEN
                v_skipped := v_skipped || jsonb_build_object('section','edges','index',r.idx,
                    'reason','unresolved endpoint (unknown key or no source anchor)');
                CONTINUE;
            END IF;

            v_name := btrim(COALESCE(r.val ->> 'verb', ''));
            IF v_name = '' THEN
                v_skipped := v_skipped || jsonb_build_object('section','edges','index',r.idx,'reason','missing verb');
                CONTINUE;
            END IF;
            SELECT verb_id INTO v_vid FROM maludb_core.malu$svpor_verb
             WHERE owner_schema = p_owner_schema AND (canonical_name = v_name OR v_name = ANY(aliases))
             ORDER BY (canonical_name = v_name) DESC LIMIT 1;
            IF v_vid IS NULL THEN
                INSERT INTO maludb_core.malu$svpor_verb (owner_schema, canonical_name)
                VALUES (p_owner_schema, v_name) RETURNING verb_id INTO v_vid;
                c_verb_c := c_verb_c + 1;
            END IF;

            INSERT INTO maludb_core.malu$svpor_statement
                (owner_schema, subject_kind, subject_id, verb_id, object_kind, object_id,
                 valid_from, valid_to, confidence, provenance, metadata_jsonb)
            VALUES
                (p_owner_schema, v_sk, v_si, v_vid, v_ok, v_oi,
                 (r.val ->> 'valid_from')::timestamptz, (r.val ->> 'valid_to')::timestamptz,
                 (r.val ->> 'confidence')::numeric, v_prov,
                 jsonb_strip_nulls(jsonb_build_object('source_span', NULLIF(btrim(COALESCE(r.val ->> 'source_span','')), ''))))
            ON CONFLICT (owner_schema, subject_kind, subject_id, verb_id, object_kind, object_id)
            DO UPDATE SET
                confidence     = COALESCE(EXCLUDED.confidence, malu$svpor_statement.confidence),
                provenance     = EXCLUDED.provenance,
                valid_from     = COALESCE(EXCLUDED.valid_from, malu$svpor_statement.valid_from),
                valid_to       = COALESCE(EXCLUDED.valid_to,   malu$svpor_statement.valid_to),
                metadata_jsonb = malu$svpor_statement.metadata_jsonb || EXCLUDED.metadata_jsonb
            RETURNING statement_id INTO v_stmt;

            c_edges := c_edges + 1;
            c_eattr := c_eattr + maludb_core._memory_apply_attributes_for_schema(
                           p_owner_schema, 'svpor_statement', v_stmt, r.val -> 'attributes', v_prov);
        EXCEPTION WHEN OTHERS THEN
            v_skipped := v_skipped || jsonb_build_object('section','edges','index',r.idx,'reason',left(SQLERRM,300));
        END;
    END LOOP;

    -- ---- relationships (subject<->subject directed/temporal layer) --------
    FOR r IN SELECT val, (ord - 1) AS idx
               FROM jsonb_array_elements(COALESCE(p_extraction -> 'relationships', '[]'::jsonb)) WITH ORDINALITY AS t(val, ord)
    LOOP
        BEGIN
            v_ref  := r.val ->> 'from';
            v_okind:= r.val ->> 'to';
            v_name := btrim(COALESCE(r.val ->> 'relationship_type', ''));
            IF NOT (v_ids ? COALESCE(v_ref,'')) OR NOT (v_ids ? COALESCE(v_okind,'')) OR v_name = '' THEN
                v_skipped := v_skipped || jsonb_build_object('section','relationships','index',r.idx,'reason','unknown from/to key or missing relationship_type');
                CONTINUE;
            END IF;
            IF (v_kinds ->> v_ref) <> 'subject' OR (v_kinds ->> v_okind) <> 'subject' THEN
                v_skipped := v_skipped || jsonb_build_object('section','relationships','index',r.idx,'reason','relationship endpoints must be subjects');
                CONTINUE;
            END IF;
            v_si := (v_ids ->> v_ref)::bigint;
            v_oi := (v_ids ->> v_okind)::bigint;

            -- The directed subject-relationship edge stores relationship_type as
            -- free text in the live schema (no per-schema relationship_type FK);
            -- labels are NOT NULL, so resolve them from the subjects.
            INSERT INTO maludb_core.malu$svpor_subject_relationship_edge
                (owner_schema, from_subject_id, to_subject_id, from_subject_label, to_subject_label,
                 relationship_type, valid_from, valid_to)
            VALUES (p_owner_schema, v_si, v_oi,
                    (SELECT canonical_name FROM maludb_core.malu$svpor_subject WHERE owner_schema=p_owner_schema AND subject_id=v_si),
                    (SELECT canonical_name FROM maludb_core.malu$svpor_subject WHERE owner_schema=p_owner_schema AND subject_id=v_oi),
                    v_name, (r.val ->> 'valid_from')::timestamptz, (r.val ->> 'valid_to')::timestamptz);
            c_rels := c_rels + 1;
        EXCEPTION WHEN OTHERS THEN
            v_skipped := v_skipped || jsonb_build_object('section','relationships','index',r.idx,'reason',left(SQLERRM,300));
        END;
    END LOOP;

    RETURN jsonb_build_object(
        'source',   jsonb_strip_nulls(jsonb_build_object('kind', v_src_kind, 'id', v_src_id)),
        'created',  jsonb_build_object('subjects', c_subj_c, 'verbs', c_verb_c, 'episodes', c_epi_c,
                                       'edges', c_edges, 'relationships', c_rels,
                                       'node_attributes', c_nattr, 'edge_attributes', c_eattr,
                                       'episode_attributes', c_epattr),
        'resolved', jsonb_build_object('subjects', c_subj_r, 'verbs', c_verb_r, 'episodes', c_epi_r),
        'ids',      v_ids,
        'skipped',  v_skipped);
END;
$body$;
REVOKE ALL ON FUNCTION maludb_core._memory_ingest_extraction_for_schema(name, jsonb, text, bigint, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core._memory_ingest_extraction_for_schema(name, jsonb, text, bigint, text)
    TO maludb_memory_admin, maludb_memory_executor;

-- =====================================================================
-- 3. 0.92.0 schema-local facade builder.
-- =====================================================================
CREATE OR REPLACE FUNCTION maludb_core._enable_memory_schema_0920_facade(p_schema name) RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
DECLARE
    v_count integer := 0;
BEGIN
    PERFORM maludb_core._memory_schema_assert_manageable(p_schema);

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_memory_ingest_extraction', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_memory_ingest_extraction(
            p_extraction  jsonb,
            p_source_kind text   DEFAULT 'document',
            p_source_id   bigint DEFAULT NULL,
            p_provenance  text   DEFAULT 'accepted'
        ) RETURNS jsonb
        LANGUAGE sql SECURITY DEFINER
        SET search_path = pg_catalog, maludb_core, pg_temp
        AS $facade$
            SELECT maludb_core._memory_ingest_extraction_for_schema(
                %L::name, p_extraction, p_source_kind, p_source_id, p_provenance)
        $facade$
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_memory_ingest_extraction(jsonb, text, bigint, text) FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_memory_ingest_extraction(jsonb, text, bigint, text) TO maludb_memory_admin, maludb_memory_executor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_memory_ingest_extraction', 'function', 'Materialize subjects/verbs/episodes/edges/attrs/relationships from one extraction JSON object.');
    v_count := v_count + 1;

    RETURN v_count;
END;
$body$;

REVOKE ALL ON FUNCTION maludb_core._enable_memory_schema_0920_facade(name) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core._enable_memory_schema_0920_facade(name)
    TO maludb_memory_admin, maludb_memory_executor;

-- =====================================================================
-- 4. Wire the 0920 facade into enable_memory_schema.
-- =====================================================================
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
    v_count := v_count + maludb_core._enable_memory_schema_0880_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_0890_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_0900_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_0910_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_0920_facade(p_schema);
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
