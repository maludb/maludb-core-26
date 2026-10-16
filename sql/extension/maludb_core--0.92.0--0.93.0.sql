\echo Use "ALTER EXTENSION maludb_core UPDATE TO '0.93.0'" to load this file. \quit

-- =====================================================================
-- maludb_core 0.92.0 -> 0.93.0
--
-- Repair release: restore the full malu$derivation_ledger
-- derived_object_type CHECK list.
--
-- The 0.81.0 -> 0.82.0 migration rebuilt this CHECK from a stale copy of
-- the list when it registered 'svpor_statement': it silently dropped
-- 'retrieval_summary' (added in 0.66.0) and 'chat_index_tree' /
-- 'chat_index_topic' / 'chat_index_message' (added in 0.67.0/0.68.0).
-- Every install at >= 0.82.0 has since rejected PageIndex
-- retrieval-summary and ChatIndex topic/message ledger rows
-- (record_derivation raises check_violation, breaking
-- retrieve_with_envelope_tree, chat_index_record_topic and
-- chat_index_append_messages).
--
-- This release rebuilds the CHECK as the union of every type ever
-- registered. No data backfill is needed: the broken paths failed loudly,
-- so no rows were written with out-of-list types.
-- =====================================================================

CREATE OR REPLACE FUNCTION maludb_core.maludb_core_version() RETURNS text
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$ SELECT '0.93.0'::text $body$;

ALTER TABLE maludb_core.malu$derivation_ledger
    DROP CONSTRAINT malu$derivation_ledger_derived_object_type_check;
ALTER TABLE maludb_core.malu$derivation_ledger
    ADD CONSTRAINT malu$derivation_ledger_derived_object_type_check
    CHECK (derived_object_type IN (
        'source_package',
        'claim',
        'fact',
        'memory',
        'episode_object',
        'memory_detail_object',
        'relationship_edge',
        'embedding',
        'page_index_tree',
        'page_index_node',
        'retrieval_summary',
        'chat_index_tree',
        'chat_index_topic',
        'chat_index_message',
        'svpor_statement'
    ));

-- =====================================================================
-- Fresh-install repairs: converge the cumulative bundle with the
-- upgrade chain (found by scripts/maludb-ext-snapshot.sql).
--
-- 1. The cumulative bundles 0.81.0+ folded the malu$document_type
--    table in WITHOUT the GRANTs the 0.80.3 -> 0.81.0 delta ships, so
--    a fresh bundle install left tenants unable to read or write the
--    document-type picker. Re-issue them (idempotent on upgraded DBs).
-- 2. The bundles also carried a paraphrased copy of
--    _enable_memory_schema_0810_facade (comment-only drift). Re-emit
--    the canonical chain text so both install paths are identical.
-- =====================================================================

GRANT SELECT, INSERT, UPDATE, DELETE ON maludb_core.malu$document_type
    TO maludb_memory_admin, maludb_memory_executor;
GRANT SELECT ON maludb_core.malu$document_type TO maludb_memory_auditor;
GRANT USAGE, SELECT ON SEQUENCE maludb_core.malu$document_type_document_type_id_seq
    TO maludb_memory_admin, maludb_memory_executor;

CREATE OR REPLACE FUNCTION maludb_core._enable_memory_schema_0810_facade(p_schema name) RETURNS integer
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
