\echo Use "ALTER EXTENSION maludb_core UPDATE TO '0.77.0'" to load this file. \quit

-- =====================================================================
-- maludb_core 0.76.1 -> 0.77.0
--
-- Add classifier_md to SVPOR subjects and verbs. The column holds the
-- markdown a classifier uses to decide whether a subject or verb is
-- referenced in a document or text being processed.
--
--   * malu$svpor_subject.classifier_md / malu$svpor_verb.classifier_md
--   * register_svpor_subject / register_svpor_verb gain p_classifier_md
--   * surfaced through the schema-local facades that derive from the two
--     tables: maludb_subject, maludb_verb, and the subject-filter views
--     maludb_project, maludb_person, maludb_stakeholder
-- =====================================================================

CREATE OR REPLACE FUNCTION maludb_core.maludb_core_version() RETURNS text
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$ SELECT '0.77.0'::text $body$;

-- ---------- storage ---------------------------------------------------
ALTER TABLE maludb_core.malu$svpor_subject
    ADD COLUMN classifier_md text;

ALTER TABLE maludb_core.malu$svpor_verb
    ADD COLUMN classifier_md text;

-- ---------- maintenance procedures ------------------------------------
ALTER EXTENSION maludb_core DROP FUNCTION register_svpor_subject(text, text[], text, text);
DROP FUNCTION register_svpor_subject(text, text[], text, text);

CREATE FUNCTION maludb_core.register_svpor_subject(
    p_canonical_name text,
    p_aliases        text[] DEFAULT ARRAY[]::text[],
    p_description    text   DEFAULT NULL,
    p_subject_type   text   DEFAULT 'other',
    p_classifier_md  text   DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql
AS $body$
DECLARE
    v_id bigint;
    v_subject_type text := maludb_core._normalize_svpor_subject_type(p_subject_type);
BEGIN
    INSERT INTO maludb_core.malu$svpor_subject (canonical_name, aliases, description, subject_type, classifier_md)
    VALUES (p_canonical_name, COALESCE(p_aliases, ARRAY[]::text[]), p_description, v_subject_type, p_classifier_md)
    ON CONFLICT (owner_schema, canonical_name) DO UPDATE
        SET aliases = (
                SELECT array_agg(DISTINCT a)
                FROM unnest(malu$svpor_subject.aliases || COALESCE(EXCLUDED.aliases, ARRAY[]::text[])) AS a
            ),
            description = COALESCE(EXCLUDED.description, malu$svpor_subject.description),
            subject_type = EXCLUDED.subject_type,
            classifier_md = COALESCE(EXCLUDED.classifier_md, malu$svpor_subject.classifier_md)
    RETURNING subject_id INTO v_id;
    RETURN v_id;
END;
$body$;

REVOKE ALL ON FUNCTION register_svpor_subject(text, text[], text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION register_svpor_subject(text, text[], text, text, text) TO
    maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;

ALTER EXTENSION maludb_core DROP FUNCTION register_svpor_verb(text, text[], text, text, text[]);
DROP FUNCTION register_svpor_verb(text, text[], text, text, text[]);

CREATE FUNCTION maludb_core.register_svpor_verb(
    p_canonical_name text,
    p_aliases text[] DEFAULT ARRAY[]::text[],
    p_description text DEFAULT NULL,
    p_verb_type text DEFAULT NULL,
    p_search_phrases text[] DEFAULT ARRAY[]::text[],
    p_classifier_md text DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql
AS $body$
DECLARE
    v_id bigint;
    v_verb_type text := maludb_core._normalize_svpor_verb_type(p_verb_type, p_canonical_name);
BEGIN
    INSERT INTO maludb_core.malu$svpor_verb (canonical_name, aliases, description, verb_type, search_phrases, classifier_md)
    VALUES (
        p_canonical_name,
        COALESCE(p_aliases, ARRAY[]::text[]),
        p_description,
        v_verb_type,
        COALESCE(p_search_phrases, ARRAY[]::text[]),
        p_classifier_md
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
            verb_type = EXCLUDED.verb_type,
            classifier_md = COALESCE(EXCLUDED.classifier_md, malu$svpor_verb.classifier_md)
    RETURNING verb_id INTO v_id;
    RETURN v_id;
END;
$body$;

REVOKE ALL ON FUNCTION register_svpor_verb(text, text[], text, text, text[], text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION register_svpor_verb(text, text[], text, text, text[], text) TO
    maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;

-- ---------- facade refresh (classifier_md surfaced in derived views) --

CREATE OR REPLACE FUNCTION maludb_core._enable_memory_schema_subject_facade(p_schema name) RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
DECLARE
    v_count integer := 0;
BEGIN
    PERFORM maludb_core._memory_schema_assert_manageable(p_schema);

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_subject', 'view');
    EXECUTE format($sql$
        CREATE OR REPLACE VIEW %I.maludb_subject AS
        SELECT subject_id,
               subject_type,
               canonical_name,
               aliases,
               description,
               created_at,
               classifier_md
          FROM maludb_core.malu$svpor_subject
         WHERE owner_schema = %L
        WITH LOCAL CHECK OPTION
    $sql$, p_schema, p_schema);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON %I.maludb_subject TO maludb_memory_admin, maludb_memory_executor', p_schema);
    EXECUTE format('GRANT SELECT ON %I.maludb_subject TO maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_subject', 'view', 'Schema-local SVPOR subject facade.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_verb', 'view');
    EXECUTE format($sql$
        CREATE OR REPLACE VIEW %I.maludb_verb AS
        SELECT verb_id,
               canonical_name,
               aliases,
               description,
               created_at,
               verb_type,
               search_phrases,
               classifier_md
          FROM maludb_core.malu$svpor_verb
         WHERE owner_schema = %L
        WITH LOCAL CHECK OPTION
    $sql$, p_schema, p_schema);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON %I.maludb_verb TO maludb_memory_admin, maludb_memory_executor', p_schema);
    EXECUTE format('GRANT SELECT ON %I.maludb_verb TO maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_verb', 'view', 'Schema-local SVPOR verb facade.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_subject_verb', 'view');
    EXECUTE format($sql$
        CREATE OR REPLACE VIEW %I.maludb_subject_verb AS
        SELECT c.compartment_id,
               c.namespace,
               s.subject_name,
               v.verb_name,
               c.embedding_dim,
               c.embedding_model,
               c.distance_metric,
               c.vector_count,
               c.search_mode,
               c.ann_index_status,
               c.created_at,
               c.updated_at
          FROM maludb_core.malu$vector_compartment c
          JOIN maludb_core.malu$vector_subject s
            ON s.owner_schema = c.owner_schema
           AND s.namespace = c.namespace
           AND s.subject_id = c.subject_id
          JOIN maludb_core.malu$vector_verb v
            ON v.owner_schema = c.owner_schema
           AND v.namespace = c.namespace
           AND v.verb_id = c.verb_id
         WHERE c.owner_schema = %L
    $sql$, p_schema, p_schema);
    EXECUTE format('GRANT SELECT ON %I.maludb_subject_verb TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_subject_verb', 'view', 'Schema-local vector subject/verb compartment facade.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_project', 'view');
    EXECUTE format($sql$
        CREATE OR REPLACE VIEW %I.maludb_project AS
        SELECT subject_id,
               subject_type,
               canonical_name,
               aliases,
               description,
               created_at,
               classifier_md
          FROM %I.maludb_subject
         WHERE subject_type = 'project'
        WITH LOCAL CHECK OPTION
    $sql$, p_schema, p_schema);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON %I.maludb_project TO maludb_memory_admin, maludb_memory_executor', p_schema);
    EXECUTE format('GRANT SELECT ON %I.maludb_project TO maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_project', 'view', 'Schema-local project subject convenience facade.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_stakeholder', 'view');
    EXECUTE format($sql$
        CREATE OR REPLACE VIEW %I.maludb_stakeholder AS
        SELECT subject_id,
               subject_type,
               canonical_name,
               aliases,
               description,
               created_at,
               classifier_md
          FROM %I.maludb_subject
         WHERE subject_type = 'stakeholder'
        WITH LOCAL CHECK OPTION
    $sql$, p_schema, p_schema);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON %I.maludb_stakeholder TO maludb_memory_admin, maludb_memory_executor', p_schema);
    EXECUTE format('GRANT SELECT ON %I.maludb_stakeholder TO maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_stakeholder', 'view', 'Schema-local stakeholder subject convenience facade.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_subject_verb_create', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_subject_verb_create(
            p_namespace text,
            p_subject_name text,
            p_verb_name text,
            p_embedding_dim integer,
            p_embedding_model text,
            p_distance_metric text DEFAULT 'cosine'
        ) RETURNS bigint
        LANGUAGE sql
        SECURITY DEFINER
        SET search_path = pg_catalog, maludb_core, pg_temp
        AS $facade$
            SELECT maludb_core._register_vector_compartment_for_schema(
                %L::name,
                p_namespace,
                p_subject_name,
                p_verb_name,
                p_embedding_dim,
                p_embedding_model,
                p_distance_metric
            )
        $facade$
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_subject_verb_create(text, text, text, integer, text, text) FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_subject_verb_create(text, text, text, integer, text, text) TO maludb_memory_admin, maludb_memory_executor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_subject_verb_create', 'function', 'Schema-local vector compartment creation facade.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_vector_search', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_vector_search(
            p_namespace text DEFAULT 'default',
            p_subject text DEFAULT NULL,
            p_verb text DEFAULT NULL,
            p_query_embedding maludb_core.malu_vector DEFAULT NULL,
            p_limit integer DEFAULT 20,
            p_metric text DEFAULT NULL
        ) RETURNS TABLE (
            chunk_id        bigint,
            source_text     text,
            distance        double precision,
            similarity      double precision,
            rank_no         integer,
            compartment_id  bigint,
            subject_name    text,
            verb_name       text
        )
        LANGUAGE sql
        STABLE
        SECURITY INVOKER
        SET search_path = %I, maludb_core, pg_temp
        AS $facade$
            SELECT *
            FROM maludb_core.vector_search_by_tags(
                p_namespace,
                p_subject,
                p_verb,
                p_query_embedding,
                p_limit,
                p_metric
            )
        $facade$
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_vector_search(text, text, text, maludb_core.malu_vector, integer, text) FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_vector_search(text, text, text, maludb_core.malu_vector, integer, text) TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_vector_search', 'function', 'Schema-local vector tag search helper.');
    v_count := v_count + 1;

    RETURN v_count;
END;
$body$;

REVOKE ALL ON FUNCTION maludb_core._enable_memory_schema_subject_facade(name) FROM PUBLIC;

CREATE OR REPLACE FUNCTION maludb_core._enable_memory_schema_075_facade(p_schema name) RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
DECLARE
    v_count integer := 0;
BEGIN
    PERFORM maludb_core._memory_schema_assert_manageable(p_schema);

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_subject_type', 'view');
    EXECUTE format($sql$
        CREATE OR REPLACE VIEW %I.maludb_subject_type AS
        SELECT subject_type, display_name, description, sort_order, system_defined, created_at
          FROM maludb_core.malu$svpor_subject_type
    $sql$, p_schema);
    EXECUTE format('GRANT SELECT ON %I.maludb_subject_type TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_subject_type', 'view', 'Schema-local SVPOR subject type catalog facade.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_verb_type', 'view');
    EXECUTE format($sql$
        CREATE OR REPLACE VIEW %I.maludb_verb_type AS
        SELECT verb_type, display_name, semantic_class, description, sort_order, system_defined, created_at
          FROM maludb_core.malu$svpor_verb_type
    $sql$, p_schema);
    EXECUTE format('GRANT SELECT ON %I.maludb_verb_type TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_verb_type', 'view', 'Schema-local SVPOR verb type catalog facade.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_verb', 'view');
    EXECUTE format($sql$
        CREATE OR REPLACE VIEW %I.maludb_verb AS
        SELECT verb_id,
               canonical_name,
               aliases,
               description,
               created_at,
               verb_type,
               search_phrases,
               classifier_md
          FROM maludb_core.malu$svpor_verb
         WHERE owner_schema = %L
        WITH LOCAL CHECK OPTION
    $sql$, p_schema, p_schema);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON %I.maludb_verb TO maludb_memory_admin, maludb_memory_executor', p_schema);
    EXECUTE format('GRANT SELECT ON %I.maludb_verb TO maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_verb', 'view', 'Schema-local type-aware SVPOR verb facade.');
    v_count := v_count + 1;

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

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_chat_session', 'view');
    EXECUTE format($sql$
        CREATE OR REPLACE VIEW %I.maludb_chat_session WITH (security_invoker = true) AS
        SELECT chat_session_id,
               account_id,
               model_session_id,
               document_id,
               source_package_id,
               chat_title,
               lifecycle_state,
               primary_project_subject_id,
               projects,
               subjects,
               verbs,
               svpor_frames,
               started_at,
               last_message_at,
               closed_at,
               message_count,
               metadata_jsonb
          FROM maludb_core.malu$chat_session
         WHERE owner_schema = %L
        WITH LOCAL CHECK OPTION
    $sql$, p_schema, p_schema);
    EXECUTE format('GRANT SELECT ON %I.maludb_chat_session TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_chat_session', 'view', 'Schema-local LLM chat session facade.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_chat_message', 'view');
    EXECUTE format($sql$
        CREATE OR REPLACE VIEW %I.maludb_chat_message WITH (security_invoker = true) AS
        SELECT chat_message_id,
               chat_session_id,
               ordinal,
               role,
               content_text,
               content_jsonb,
               content_hash,
               token_estimate,
               model_request_id,
               model_response_id,
               tool_call_id,
               source_locator,
               sensitivity,
               created_at,
               metadata_jsonb
          FROM maludb_core.malu$chat_message
         WHERE owner_schema = %L
        WITH LOCAL CHECK OPTION
    $sql$, p_schema, p_schema);
    EXECUTE format('GRANT SELECT ON %I.maludb_chat_message TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_chat_message', 'view', 'Schema-local LLM chat message facade.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_chat_start', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_chat_start(
            p_title text DEFAULT NULL,
            p_account_name text DEFAULT NULL,
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
            SELECT maludb_core.chat_start(
                p_title, p_account_name, p_projects, p_subjects, p_verbs,
                p_svpor_frames, p_metadata_jsonb
            )
        $facade$
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_chat_start(text, text, text[], text[], text[], jsonb, jsonb) FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_chat_start(text, text, text[], text[], text[], jsonb, jsonb) TO maludb_memory_admin, maludb_memory_executor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_chat_start', 'function', 'Schema-local LLM chat session creator.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_chat_append_message', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_chat_append_message(
            p_chat_session_id bigint,
            p_role text,
            p_content_text text DEFAULT NULL,
            p_content_jsonb jsonb DEFAULT NULL,
            p_metadata_jsonb jsonb DEFAULT '{}'::jsonb
        ) RETURNS bigint
        LANGUAGE sql
        SECURITY INVOKER
        SET search_path = %I, maludb_core, pg_temp
        AS $facade$
            SELECT maludb_core.chat_append_message(
                p_chat_session_id, p_role, p_content_text, p_content_jsonb, p_metadata_jsonb
            )
        $facade$
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_chat_append_message(bigint, text, text, jsonb, jsonb) FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_chat_append_message(bigint, text, text, jsonb, jsonb) TO maludb_memory_admin, maludb_memory_executor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_chat_append_message', 'function', 'Schema-local LLM chat message append API.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_chat_finalize', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_chat_finalize(p_chat_session_id bigint)
        RETURNS jsonb
        LANGUAGE sql
        SECURITY INVOKER
        SET search_path = %I, maludb_core, pg_temp
        AS $facade$
            SELECT maludb_core.chat_finalize(p_chat_session_id)
        $facade$
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_chat_finalize(bigint) FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_chat_finalize(bigint) TO maludb_memory_admin, maludb_memory_executor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_chat_finalize', 'function', 'Schema-local LLM chat document projection finalizer.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_chat_get', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_chat_get(p_chat_session_id bigint)
        RETURNS jsonb
        LANGUAGE sql
        STABLE
        SECURITY INVOKER
        SET search_path = %I, maludb_core, pg_temp
        AS $facade$
            SELECT maludb_core.chat_get(p_chat_session_id)
        $facade$
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_chat_get(bigint) FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_chat_get(bigint) TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_chat_get', 'function', 'Schema-local LLM chat reader.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_chat_messages', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_chat_messages(p_chat_session_id bigint)
        RETURNS TABLE (
            chat_message_id bigint,
            ordinal integer,
            role text,
            content_text text,
            content_jsonb jsonb,
            content_hash text,
            token_estimate integer,
            model_request_id bigint,
            model_response_id bigint,
            tool_call_id text,
            source_locator jsonb,
            sensitivity text,
            created_at timestamptz,
            metadata_jsonb jsonb
        )
        LANGUAGE sql
        STABLE
        SECURITY INVOKER
        SET search_path = %I, maludb_core, pg_temp
        AS $facade$
            SELECT *
            FROM maludb_core.chat_messages(p_chat_session_id)
        $facade$
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_chat_messages(bigint) FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_chat_messages(bigint) TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_chat_messages', 'function', 'Schema-local ordered LLM chat message reader.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_person', 'view');
    EXECUTE format($sql$
        CREATE OR REPLACE VIEW %I.maludb_person AS
        SELECT subject_id,
               subject_type,
               canonical_name,
               aliases,
               description,
               created_at,
               classifier_md
          FROM %I.maludb_subject
         WHERE subject_type = 'person'
        WITH LOCAL CHECK OPTION
    $sql$, p_schema, p_schema);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON %I.maludb_person TO maludb_memory_admin, maludb_memory_executor', p_schema);
    EXECUTE format('GRANT SELECT ON %I.maludb_person TO maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_person', 'view', 'Schema-local person subject convenience facade.');
    v_count := v_count + 1;

    RETURN v_count;
END;
$body$;

REVOKE ALL ON FUNCTION maludb_core._enable_memory_schema_075_facade(name) FROM PUBLIC;
