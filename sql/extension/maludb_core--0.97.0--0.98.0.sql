\echo Use "ALTER EXTENSION maludb_core UPDATE TO '0.98.0'" to load this file. \quit

-- =====================================================================
-- maludb_core 0.97.0 -> 0.98.0  --  note retrieval by subject/verb
--
-- Notes ingested through the memory pipeline are decomposed into
-- subjects, verbs, and SVO statements, but nothing walks that graph
-- back to the source documents. This release adds relational note
-- retrieval -- "give me the notes whose extracted edges mention
-- ubuntu and an install-like verb" -- as a one-call tenant facade so
-- every API server (python/lamp/fastify) stays a thin wrapper:
--
--   1. _note_search_for_schema: filter statements by subject-name
--      patterns (ILIKE over canonical_name + aliases, matched against
--      BOTH statement endpoints -- _memory_ingest_edge_for_schema
--      writes document --verb--> subject, so the searched entity is
--      usually the OBJECT endpoint) and by verb (exact canonical/alias
--      match, or "verb-like" bidirectional containment so the query
--      'installation' finds the verb 'install'). Statements reach
--      their source documents over BOTH rails: the vector-chunk soft
--      ref (statement_id/document_id stamped by embedded ingest_edge
--      calls) and statements whose endpoint kind is 'document' (the
--      $source anchor used by maludb_memory_ingest_extraction and by
--      embedding-less ingest_edge calls). One row per document --
--      LIMIT means "20 notes", not "20 edges" -- with the matching
--      edges aggregated as jsonb. Default scope is source_type
--      'note'; p_all_sources widens to every document kind.
--   2. _note_query_parse_for_schema: the deterministic half of
--      free-text search ("Install Ubuntu"). Tokenize, drop stopwords,
--      and match tokens against the tenant verb catalog (exact
--      canonical/alias match beats containment; containment requires
--      a 4+ character token so 'in' never claims 'install'). The
--      winning token becomes the verb filter, the leftover tokens
--      become subject patterns. Lives in core so all servers share
--      identical parse semantics; the LLM fallback for verbless
--      queries stays server-side (core has no model access).
--   3. Tenant facades maludb_note_search / maludb_note_query_parse
--      via a new _0980 builder (read-only -> auditor gets EXECUTE,
--      mirroring maludb_memory_search). The builder creates ONLY the
--      two objects it introduces -- no CREATE OR REPLACE of earlier
--      facades, no re-grants (the 0.97.0 maludb_skill lesson).
--      Tenants pick the functions up by re-running
--      enable_memory_schema().
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. _note_search_for_schema. SECURITY DEFINER bypasses RLS, so every
--    tenant table carries an explicit owner_schema predicate.
--    malu$vector_chunk has no owner_schema; its soft document_id ref
--    is tenant-safe because the statement it hangs off and the
--    document it points at are both owner_schema-checked.
-- ---------------------------------------------------------------------
CREATE FUNCTION maludb_core._note_search_for_schema(
    p_schema        name,
    p_subject_like  text[]  DEFAULT NULL,
    p_verb_like     text    DEFAULT NULL,
    p_verb_exact    text    DEFAULT NULL,
    p_source_type   text    DEFAULT 'note',
    p_all_sources   boolean DEFAULT false,
    p_limit         integer DEFAULT 20,
    p_offset        integer DEFAULT 0
) RETURNS TABLE (
    document_id   bigint,
    title         text,
    source_type   text,
    snippet       text,
    created_at    timestamptz,
    match_count   integer,
    matched_edges jsonb
) LANGUAGE plpgsql STABLE
SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
#variable_conflict use_column
DECLARE
    v_subject_like text[];
    v_verb_like    text := NULLIF(btrim(COALESCE(p_verb_like, '')), '');
    v_verb_exact   text := NULLIF(btrim(COALESCE(p_verb_exact, '')), '');
    v_source_type  text := COALESCE(NULLIF(btrim(COALESCE(p_source_type, '')), ''), 'note');
    v_limit        integer := LEAST(GREATEST(COALESCE(p_limit, 20), 1), 200);
    v_offset       integer := GREATEST(COALESCE(p_offset, 0), 0);
    v_has_subject  boolean;
    v_has_verb     boolean;
BEGIN
    PERFORM maludb_core._memory_schema_assert_manageable(p_schema);

    SELECT array_agg(pat) INTO v_subject_like
      FROM (SELECT NULLIF(btrim(p), '') AS pat
              FROM unnest(COALESCE(p_subject_like, ARRAY[]::text[])) AS p) t
     WHERE pat IS NOT NULL;
    v_has_subject := v_subject_like IS NOT NULL AND cardinality(v_subject_like) > 0;
    v_has_verb    := v_verb_exact IS NOT NULL OR v_verb_like IS NOT NULL;

    IF NOT v_has_subject AND NOT v_has_verb THEN
        RAISE EXCEPTION 'note_search: at least one of subject_like, verb_like, verb_exact is required'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    RETURN QUERY
    WITH matched_verbs AS (
        -- exact wins over like: when both are supplied only the exact
        -- branch runs (documented contract).
        SELECT v.verb_id
          FROM maludb_core.malu$svpor_verb v
         WHERE v.owner_schema = p_schema
           AND CASE
               WHEN v_verb_exact IS NOT NULL THEN
                    lower(v.canonical_name) = lower(v_verb_exact)
                 OR EXISTS (SELECT 1 FROM unnest(v.aliases) a
                             WHERE lower(a) = lower(v_verb_exact))
               ELSE
                    v.canonical_name ILIKE '%' || v_verb_like || '%'
                 OR v_verb_like ILIKE '%' || v.canonical_name || '%'
                 OR EXISTS (SELECT 1 FROM unnest(v.aliases) a
                             WHERE a ILIKE '%' || v_verb_like || '%'
                                OR v_verb_like ILIKE '%' || a || '%')
               END
    ),
    matched_subjects AS (
        SELECT s.subject_id
          FROM maludb_core.malu$svpor_subject s
         WHERE s.owner_schema = p_schema
           AND EXISTS (SELECT 1 FROM unnest(v_subject_like) pat
                        WHERE s.canonical_name ILIKE '%' || pat || '%'
                           OR EXISTS (SELECT 1 FROM unnest(s.aliases) a
                                       WHERE a ILIKE '%' || pat || '%'))
    ),
    stmts AS (
        SELECT st.statement_id
          FROM maludb_core.malu$svpor_statement st
         WHERE st.owner_schema = p_schema
           AND (NOT v_has_verb
                OR st.verb_id IN (SELECT mv.verb_id FROM matched_verbs mv))
           AND (NOT v_has_subject
                OR (st.subject_kind = 'subject'
                    AND st.subject_id IN (SELECT ms.subject_id FROM matched_subjects ms))
                OR (st.object_kind = 'subject'
                    AND st.object_id IN (SELECT ms.subject_id FROM matched_subjects ms)))
    ),
    doc_links AS (
        -- both statement->document rails; a statement linked over both
        -- collapses to one row (min() prefers 'statement_endpoint').
        SELECT l.doc_id, l.statement_id, min(l.match_via) AS match_via
          FROM (
            SELECT vc.document_id AS doc_id, s.statement_id,
                   'vector_chunk'::text AS match_via
              FROM stmts s
              JOIN maludb_core.malu$vector_chunk vc ON vc.statement_id = s.statement_id
             WHERE vc.document_id IS NOT NULL
            UNION ALL
            SELECT CASE WHEN st.subject_kind = 'document' THEN st.subject_id
                        ELSE st.object_id END,
                   st.statement_id,
                   'statement_endpoint'::text
              FROM stmts s
              JOIN maludb_core.malu$svpor_statement st ON st.statement_id = s.statement_id
             WHERE st.owner_schema = p_schema
               AND (st.subject_kind = 'document' OR st.object_kind = 'document')
          ) l
         GROUP BY l.doc_id, l.statement_id
    ),
    edge_detail AS (
        SELECT dl.doc_id, dl.statement_id, dl.match_via,
               st.confidence,
               CASE st.subject_kind
                    WHEN 'subject'  THEN subj_s.canonical_name
                    WHEN 'document' THEN 'document:' || st.subject_id
                    ELSE st.subject_kind || ':' || st.subject_id END AS subject_name,
               vb.canonical_name AS verb_name,
               CASE st.object_kind
                    WHEN 'subject'  THEN obj_s.canonical_name
                    WHEN 'document' THEN 'document:' || st.object_id
                    ELSE st.object_kind || ':' || st.object_id END AS object_name,
               CASE WHEN NOT v_has_subject THEN NULL
                    WHEN st.subject_kind = 'subject'
                     AND st.subject_id IN (SELECT ms.subject_id FROM matched_subjects ms)
                    THEN 'subject' ELSE 'object' END AS matched_endpoint
          FROM doc_links dl
          JOIN maludb_core.malu$svpor_statement st
            ON st.statement_id = dl.statement_id AND st.owner_schema = p_schema
          JOIN maludb_core.malu$svpor_verb vb
            ON vb.verb_id = st.verb_id AND vb.owner_schema = p_schema
          LEFT JOIN maludb_core.malu$svpor_subject subj_s
            ON st.subject_kind = 'subject' AND subj_s.subject_id = st.subject_id
           AND subj_s.owner_schema = p_schema
          LEFT JOIN maludb_core.malu$svpor_subject obj_s
            ON st.object_kind = 'subject' AND obj_s.subject_id = st.object_id
           AND obj_s.owner_schema = p_schema
    )
    SELECT d.document_id,
           d.title,
           d.source_type,
           left(sp.content_text, 240) AS snippet,
           d.created_at,
           count(DISTINCT ed.statement_id)::integer AS match_count,
           jsonb_agg(DISTINCT jsonb_strip_nulls(jsonb_build_object(
               'statement_id',     ed.statement_id,
               'subject_name',     ed.subject_name,
               'verb_name',        ed.verb_name,
               'object_name',      ed.object_name,
               'confidence',       ed.confidence,
               'match_via',        ed.match_via,
               'matched_endpoint', ed.matched_endpoint))) AS matched_edges
      FROM edge_detail ed
      JOIN maludb_core.malu$document d
        ON d.document_id = ed.doc_id AND d.owner_schema = p_schema
      LEFT JOIN maludb_core.malu$source_package sp
        ON sp.source_package_id = d.source_package_id AND sp.owner_schema = p_schema
     WHERE p_all_sources OR d.source_type = v_source_type
     GROUP BY d.document_id, d.title, d.source_type, sp.content_text, d.created_at
     ORDER BY d.created_at DESC, d.document_id DESC
     LIMIT v_limit OFFSET v_offset;
END;
$body$;

REVOKE ALL ON FUNCTION maludb_core._note_search_for_schema(name, text[], text, text, text, boolean, integer, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core._note_search_for_schema(name, text[], text, text, text, boolean, integer, integer)
    TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;

-- ---------------------------------------------------------------------
-- 2. _note_query_parse_for_schema. Deterministic, catalog-driven: the
--    verb list per tenant is small and enumerated, so a token scan
--    beats a model call for the common case. Scoring: exact
--    canonical/alias match = 2, bidirectional containment = 1 (4+
--    character tokens only); ties prefer the longer canonical name,
--    then the earlier token.
-- ---------------------------------------------------------------------
CREATE FUNCTION maludb_core._note_query_parse_for_schema(
    p_schema name,
    p_query  text
) RETURNS jsonb
LANGUAGE plpgsql STABLE
SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
DECLARE
    c_stopwords CONSTANT text[] := ARRAY[
        'a','an','the','to','of','for','on','in','at','by','with','and','or',
        'how','do','does','did','what','which','when','where','who',
        'i','we','my','our','me','was','is','are','were','be','been',
        'about','all','any','that','this','these','those','it','its'];
    v_tokens        text[];
    v_verb          text;
    v_verb_id       bigint;
    v_matched_token text;
    v_subject_toks  text[];
BEGIN
    PERFORM maludb_core._memory_schema_assert_manageable(p_schema);

    SELECT array_agg(tok ORDER BY ord) INTO v_tokens
      FROM (SELECT DISTINCT ON (tok) tok, ord
              FROM regexp_split_to_table(lower(COALESCE(p_query, '')), '[^[:alnum:]_-]+')
                   WITH ORDINALITY AS t(tok, ord)
             WHERE tok <> '' AND tok <> ALL (c_stopwords)
             ORDER BY tok, ord) dedup;

    IF v_tokens IS NULL THEN
        RETURN jsonb_build_object(
            'verb', NULL, 'verb_id', NULL, 'matched_token', NULL,
            'subject_tokens', '[]'::jsonb, 'tokens', '[]'::jsonb);
    END IF;

    SELECT v.canonical_name, v.verb_id, t.tok
      INTO v_verb, v_verb_id, v_matched_token
      FROM unnest(v_tokens) WITH ORDINALITY AS t(tok, ord)
      JOIN maludb_core.malu$svpor_verb v ON v.owner_schema = p_schema
     CROSS JOIN LATERAL (
        SELECT CASE
               WHEN lower(v.canonical_name) = t.tok
                 OR EXISTS (SELECT 1 FROM unnest(v.aliases) a WHERE lower(a) = t.tok)
               THEN 2
               WHEN length(t.tok) >= 4
                AND (v.canonical_name ILIKE '%' || t.tok || '%'
                  OR t.tok ILIKE '%' || v.canonical_name || '%'
                  OR EXISTS (SELECT 1 FROM unnest(v.aliases) a
                              WHERE a ILIKE '%' || t.tok || '%'
                                 OR t.tok ILIKE '%' || a || '%'))
               THEN 1
               END AS score
     ) sc
     WHERE sc.score IS NOT NULL
     ORDER BY sc.score DESC, length(v.canonical_name) DESC, t.ord ASC
     LIMIT 1;

    SELECT array_agg(tok) INTO v_subject_toks
      FROM unnest(v_tokens) AS tok
     WHERE v_matched_token IS NULL OR tok <> v_matched_token;

    RETURN jsonb_build_object(
        'verb',           v_verb,
        'verb_id',        v_verb_id,
        'matched_token',  v_matched_token,
        'subject_tokens', to_jsonb(COALESCE(v_subject_toks, ARRAY[]::text[])),
        'tokens',         to_jsonb(v_tokens));
END;
$body$;

REVOKE ALL ON FUNCTION maludb_core._note_query_parse_for_schema(name, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core._note_query_parse_for_schema(name, text)
    TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;

-- ---------------------------------------------------------------------
-- 3. 0980 facade builder: maludb_note_search + maludb_note_query_parse.
--    Both are read-only, so the auditor role gets EXECUTE (the
--    maludb_memory_search posture). The builder touches nothing that
--    earlier builders created.
-- ---------------------------------------------------------------------
CREATE FUNCTION maludb_core._enable_memory_schema_0980_facade(p_schema name) RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
DECLARE
    v_count integer := 0;
BEGIN
    PERFORM maludb_core._memory_schema_assert_manageable(p_schema);

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_note_search', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_note_search(
            p_subject_like text[]  DEFAULT NULL,
            p_verb_like    text    DEFAULT NULL,
            p_verb_exact   text    DEFAULT NULL,
            p_source_type  text    DEFAULT 'note',
            p_all_sources  boolean DEFAULT false,
            p_limit        integer DEFAULT 20,
            p_offset       integer DEFAULT 0
        ) RETURNS TABLE (
            document_id   bigint,
            title         text,
            source_type   text,
            snippet       text,
            created_at    timestamptz,
            match_count   integer,
            matched_edges jsonb
        )
        LANGUAGE SQL STABLE
        SECURITY DEFINER
        SET search_path = pg_catalog, maludb_core, pg_temp
        AS $fn$
            SELECT * FROM maludb_core._note_search_for_schema(
                %L::name,
                p_subject_like, p_verb_like, p_verb_exact,
                p_source_type, p_all_sources, p_limit, p_offset)
        $fn$;
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_note_search(text[], text, text, text, boolean, integer, integer) FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_note_search(text[], text, text, text, boolean, integer, integer) TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_note_search', 'function', 'Schema-local note retrieval by subject/verb over extracted SVO edges.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_note_query_parse', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_note_query_parse(
            p_query text
        ) RETURNS jsonb
        LANGUAGE SQL STABLE
        SECURITY DEFINER
        SET search_path = pg_catalog, maludb_core, pg_temp
        AS $fn$
            SELECT maludb_core._note_query_parse_for_schema(%L::name, p_query)
        $fn$;
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_note_query_parse(text) FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_note_query_parse(text) TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_note_query_parse', 'function', 'Schema-local deterministic free-text parse into verb + subject tokens.');
    v_count := v_count + 1;

    RETURN v_count;
END;
$body$;

REVOKE ALL ON FUNCTION maludb_core._enable_memory_schema_0980_facade(name) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core._enable_memory_schema_0980_facade(name)
    TO maludb_memory_admin, maludb_memory_executor;

-- ---------------------------------------------------------------------
-- 4. Wire the 0980 facade into enable_memory_schema. Functions only --
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
-- 5. Version stamp.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION maludb_core.maludb_core_version() RETURNS text
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$ SELECT '0.98.0'::text $body$;
