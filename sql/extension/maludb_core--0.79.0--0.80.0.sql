\echo Use "ALTER EXTENSION maludb_core UPDATE TO '0.80.0'" to load this file. \quit

-- =====================================================================
-- maludb_core 0.79.0 -> 0.80.0
--
-- API enablement: bug fixes + unlink/delete/link helpers + project
-- archive + notes issue-state + skill/document body exposure.
--
--   A. Bug fixes
--      A1. Pin search_path on the 6 _payload_validate_* trigger fns so
--          memory/fact/claim/episode/source_package/memory_detail are
--          writable regardless of the caller's search_path.
--      A2. Grant the document inner helpers so quick_add_note /
--          upload_document work for tenant roles.
--   B. Unlink / delete helpers
--      maludb_subject_verb_unlink, maludb_svpor_relationship_delete,
--      maludb_pool_remove_named_member.
--   C. maludb_subject_verb_link(subject_id, verb_id) with baked-in
--      embedding defaults (namespace 'default', 1536, cosine).
--   D. Project archive: archived_at on subjects + project_archive /
--      project_unarchive.
--   E. Notes issue-state: issue_closed_at on malu$memory.
--   F. Expose skill markdown body + document body_text (read).
--
-- The schema-local facades (new functions + the widened views) are
-- (re)built by _enable_memory_schema_080_facade; existing schemas pick
-- them up by re-running enable_memory_schema().
-- =====================================================================

CREATE OR REPLACE FUNCTION maludb_core.maludb_core_version() RETURNS text
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$ SELECT '0.80.0'::text $body$;

-- ===== A1. payload-validation triggers resolve maludb_core anywhere ===
ALTER FUNCTION maludb_core._payload_validate_memory()         SET search_path = pg_catalog, maludb_core, pg_temp;
ALTER FUNCTION maludb_core._payload_validate_episode()        SET search_path = pg_catalog, maludb_core, pg_temp;
ALTER FUNCTION maludb_core._payload_validate_mdo()            SET search_path = pg_catalog, maludb_core, pg_temp;
ALTER FUNCTION maludb_core._payload_validate_claim()          SET search_path = pg_catalog, maludb_core, pg_temp;
ALTER FUNCTION maludb_core._payload_validate_fact()           SET search_path = pg_catalog, maludb_core, pg_temp;
ALTER FUNCTION maludb_core._payload_validate_source_package() SET search_path = pg_catalog, maludb_core, pg_temp;

-- ===== A2. let tenant roles reach the document inner helpers ==========
GRANT EXECUTE ON FUNCTION maludb_core._upload_document_for_schema(name, text, text, text, jsonb, text, text[], text[], text[], text[], jsonb)
    TO maludb_memory_admin, maludb_memory_executor;
GRANT EXECUTE ON FUNCTION maludb_core._insert_document_svpor_hints_for_schema(name, bigint, jsonb)
    TO maludb_memory_admin, maludb_memory_executor;

-- ===== D/E/F. new base columns =======================================
-- D: project archive state on subjects.
ALTER TABLE maludb_core.malu$svpor_subject ADD COLUMN archived_at timestamptz;
-- E: notes issue-closed state on memories.
ALTER TABLE maludb_core.malu$memory         ADD COLUMN issue_closed_at timestamptz;
-- F: skill markdown/body content. malu$skill_package had no body column at
-- all (despite the request's premise), so add one; exposed via maludb_skill.
ALTER TABLE maludb_core.malu$skill_package  ADD COLUMN markdown text;

-- ===== C. subject<->verb link (baked embedding defaults) =============
CREATE FUNCTION maludb_core._link_subject_verb_for_schema(
    p_schema     name,
    p_subject_id bigint,
    p_verb_id    bigint
) RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
DECLARE
    v_sname text;
    v_vname text;
BEGIN
    PERFORM maludb_core._memory_schema_assert_manageable(p_schema);

    SELECT canonical_name INTO v_sname
      FROM maludb_core.malu$svpor_subject
     WHERE owner_schema = p_schema AND subject_id = p_subject_id;
    SELECT canonical_name INTO v_vname
      FROM maludb_core.malu$svpor_verb
     WHERE owner_schema = p_schema AND verb_id = p_verb_id;

    IF v_sname IS NULL OR v_vname IS NULL THEN
        RAISE EXCEPTION 'subject_id % or verb_id % not found in schema %',
            p_subject_id, p_verb_id, p_schema
            USING ERRCODE = 'foreign_key_violation';
    END IF;

    RETURN maludb_core._register_vector_compartment_for_schema(
        p_schema, 'default', v_sname, v_vname, 1536, 'text-embedding-3-small', 'cosine');
END;
$body$;
REVOKE ALL ON FUNCTION maludb_core._link_subject_verb_for_schema(name, bigint, bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core._link_subject_verb_for_schema(name, bigint, bigint)
    TO maludb_memory_admin, maludb_memory_executor;

-- ===== B1. subject<->verb unlink =====================================
CREATE FUNCTION maludb_core._unlink_subject_verb_for_schema(
    p_schema     name,
    p_subject_id bigint,
    p_verb_id    bigint
) RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
DECLARE
    v_sname text;
    v_vname text;
    v_count integer;
BEGIN
    PERFORM maludb_core._memory_schema_assert_manageable(p_schema);

    SELECT canonical_name INTO v_sname
      FROM maludb_core.malu$svpor_subject
     WHERE owner_schema = p_schema AND subject_id = p_subject_id;
    SELECT canonical_name INTO v_vname
      FROM maludb_core.malu$svpor_verb
     WHERE owner_schema = p_schema AND verb_id = p_verb_id;

    IF v_sname IS NULL OR v_vname IS NULL THEN
        RAISE EXCEPTION 'subject_id % or verb_id % not found in schema %',
            p_subject_id, p_verb_id, p_schema
            USING ERRCODE = 'foreign_key_violation';
    END IF;

    DELETE FROM maludb_core.malu$vector_compartment c
     USING maludb_core.malu$vector_subject s, maludb_core.malu$vector_verb v
     WHERE c.owner_schema = p_schema AND c.namespace = 'default'
       AND s.owner_schema = p_schema AND s.namespace = 'default'
       AND s.subject_name = v_sname AND c.subject_id = s.subject_id
       AND v.owner_schema = p_schema AND v.namespace = 'default'
       AND v.verb_name = v_vname AND c.verb_id = v.verb_id;
    GET DIAGNOSTICS v_count = ROW_COUNT;
    RETURN v_count;
END;
$body$;
REVOKE ALL ON FUNCTION maludb_core._unlink_subject_verb_for_schema(name, bigint, bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core._unlink_subject_verb_for_schema(name, bigint, bigint)
    TO maludb_memory_admin, maludb_memory_executor;

-- ===== B2. object-graph relationship delete ==========================
CREATE FUNCTION maludb_core.delete_svpor_relationship(
    p_source_kind       text,
    p_source_id         bigint,
    p_target_kind       text,
    p_target_id         bigint,
    p_relationship_type text DEFAULT NULL
) RETURNS integer
LANGUAGE plpgsql
SECURITY INVOKER
AS $body$
DECLARE
    v_schema name := current_schema();
    v_count  integer;
BEGIN
    DELETE FROM maludb_core.malu$relationship_edge e
     WHERE e.owner_schema = v_schema
       AND e.source_object_type = p_source_kind
       AND e.source_object_id   = p_source_id
       AND e.target_object_type = p_target_kind
       AND e.target_object_id   = p_target_id
       AND (p_relationship_type IS NULL OR e.relationship_type = p_relationship_type);
    GET DIAGNOSTICS v_count = ROW_COUNT;
    RETURN v_count;
END;
$body$;
REVOKE ALL ON FUNCTION maludb_core.delete_svpor_relationship(text, bigint, text, bigint, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core.delete_svpor_relationship(text, bigint, text, bigint, text)
    TO maludb_memory_admin, maludb_memory_executor;

-- ===== B3. pool remove named member ==================================
CREATE FUNCTION maludb_core._pool_remove_named_member_for_schema(
    p_schema      name,
    p_pool_name   text,
    p_member_kind text,
    p_member_name text
) RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
DECLARE
    v_pool_id     bigint;
    v_kind        text := pg_catalog.lower(pg_catalog.btrim(p_member_kind));
    v_name        text := pg_catalog.btrim(p_member_name);
    v_object_type text;
    v_object_id   bigint;
    v_count       integer;
BEGIN
    PERFORM maludb_core._memory_schema_assert_manageable(p_schema);

    SELECT pool_id INTO v_pool_id
      FROM maludb_core.malu$active_memory_pool
     WHERE owner_schema = p_schema AND pool_name = p_pool_name;
    IF v_pool_id IS NULL THEN
        RAISE EXCEPTION 'pool_remove_named_member: pool % not found in schema %', p_pool_name, p_schema
            USING ERRCODE = 'no_data_found';
    END IF;

    IF v_kind = 'project' THEN
        SELECT subject_id INTO v_object_id FROM maludb_core.malu$svpor_subject
         WHERE owner_schema = p_schema AND canonical_name = v_name AND subject_type = 'project'
         ORDER BY subject_id LIMIT 1;
        v_object_type := 'subject';
    ELSIF v_kind = 'subject' THEN
        SELECT subject_id INTO v_object_id FROM maludb_core.malu$svpor_subject
         WHERE owner_schema = p_schema AND canonical_name = v_name
         ORDER BY subject_id LIMIT 1;
        v_object_type := 'subject';
    ELSIF v_kind = 'verb' THEN
        SELECT verb_id INTO v_object_id FROM maludb_core.malu$svpor_verb
         WHERE owner_schema = p_schema AND canonical_name = v_name
         ORDER BY verb_id LIMIT 1;
        v_object_type := 'verb';
    ELSIF v_kind = 'document' THEN
        SELECT document_id INTO v_object_id FROM maludb_core.malu$document
         WHERE owner_schema = p_schema AND title = v_name
         ORDER BY document_id LIMIT 1;
        v_object_type := 'document';
    ELSIF v_kind = 'skill' THEN
        SELECT skill_id INTO v_object_id FROM maludb_core.malu$skill_package
         WHERE owner_schema = p_schema AND skill_name = v_name
         ORDER BY updated_at DESC, skill_id DESC LIMIT 1;
        v_object_type := 'skill';
    ELSIF v_kind = 'memory' THEN
        SELECT memory_id INTO v_object_id FROM maludb_core.malu$memory
         WHERE owner_schema = p_schema AND title = v_name
         ORDER BY memory_id LIMIT 1;
        v_object_type := 'memory';
    ELSE
        RAISE EXCEPTION 'pool_remove_named_member: unsupported named member_kind %', p_member_kind
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    IF v_object_id IS NULL THEN
        RAISE EXCEPTION 'pool_remove_named_member: % named % not found in schema %', v_kind, v_name, p_schema
            USING ERRCODE = 'no_data_found';
    END IF;

    DELETE FROM maludb_core.malu$active_memory_pool_member
     WHERE owner_schema = p_schema
       AND pool_id = v_pool_id
       AND member_kind = v_kind
       AND member_object_type = v_object_type
       AND member_object_id = v_object_id;
    GET DIAGNOSTICS v_count = ROW_COUNT;
    RETURN v_count;
END;
$body$;
REVOKE ALL ON FUNCTION maludb_core._pool_remove_named_member_for_schema(name, text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core._pool_remove_named_member_for_schema(name, text, text, text)
    TO maludb_memory_admin, maludb_memory_executor;

-- ===== D. project archive / unarchive ================================
CREATE FUNCTION maludb_core.project_archive(p_project_id bigint) RETURNS boolean
LANGUAGE plpgsql
SECURITY INVOKER
AS $body$
DECLARE
    v_schema name := current_schema();
    v_count  integer;
BEGIN
    UPDATE maludb_core.malu$svpor_subject
       SET archived_at = now()
     WHERE owner_schema = v_schema AND subject_id = p_project_id
       AND subject_type = 'project' AND archived_at IS NULL;
    GET DIAGNOSTICS v_count = ROW_COUNT;

    IF v_count = 0 AND NOT EXISTS (
        SELECT 1 FROM maludb_core.malu$svpor_subject
         WHERE owner_schema = v_schema AND subject_id = p_project_id AND subject_type = 'project'
    ) THEN
        RAISE EXCEPTION 'project % not found in schema %', p_project_id, v_schema
            USING ERRCODE = 'foreign_key_violation';
    END IF;

    RETURN v_count > 0;   -- true = archived now; false = already archived
END;
$body$;
REVOKE ALL ON FUNCTION maludb_core.project_archive(bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core.project_archive(bigint)
    TO maludb_memory_admin, maludb_memory_executor;

CREATE FUNCTION maludb_core.project_unarchive(p_project_id bigint) RETURNS boolean
LANGUAGE plpgsql
SECURITY INVOKER
AS $body$
DECLARE
    v_schema name := current_schema();
    v_count  integer;
BEGIN
    UPDATE maludb_core.malu$svpor_subject
       SET archived_at = NULL
     WHERE owner_schema = v_schema AND subject_id = p_project_id
       AND subject_type = 'project' AND archived_at IS NOT NULL;
    GET DIAGNOSTICS v_count = ROW_COUNT;

    IF v_count = 0 AND NOT EXISTS (
        SELECT 1 FROM maludb_core.malu$svpor_subject
         WHERE owner_schema = v_schema AND subject_id = p_project_id AND subject_type = 'project'
    ) THEN
        RAISE EXCEPTION 'project % not found in schema %', p_project_id, v_schema
            USING ERRCODE = 'foreign_key_violation';
    END IF;

    RETURN v_count > 0;   -- true = unarchived now; false = not archived
END;
$body$;
REVOKE ALL ON FUNCTION maludb_core.project_unarchive(bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core.project_unarchive(bigint)
    TO maludb_memory_admin, maludb_memory_executor;

-- ===== schema-local facade: new helpers + widened views ==============
CREATE FUNCTION maludb_core._enable_memory_schema_080_facade(p_schema name) RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
DECLARE
    v_count integer := 0;
BEGIN
    PERFORM maludb_core._memory_schema_assert_manageable(p_schema);

    -- ---- widen existing views (already managed: re-create, no recount) ----
    EXECUTE format($sql$
        CREATE OR REPLACE VIEW %I.maludb_subject AS
        SELECT subject_id, subject_type, canonical_name, aliases, description,
               created_at, classifier_md, archived_at
          FROM maludb_core.malu$svpor_subject
         WHERE owner_schema = %L
        WITH LOCAL CHECK OPTION
    $sql$, p_schema, p_schema);

    EXECUTE format($sql$
        CREATE OR REPLACE VIEW %I.maludb_project AS
        SELECT subject_id, subject_type, canonical_name, aliases, description,
               created_at, classifier_md, archived_at
          FROM %I.maludb_subject
         WHERE subject_type = 'project'
        WITH LOCAL CHECK OPTION
    $sql$, p_schema, p_schema);

    EXECUTE format($sql$
        CREATE OR REPLACE VIEW %I.maludb_person AS
        SELECT subject_id, subject_type, canonical_name, aliases, description,
               created_at, classifier_md, archived_at
          FROM %I.maludb_subject
         WHERE subject_type = 'person'
        WITH LOCAL CHECK OPTION
    $sql$, p_schema, p_schema);

    EXECUTE format($sql$
        CREATE OR REPLACE VIEW %I.maludb_stakeholder AS
        SELECT subject_id, subject_type, canonical_name, aliases, description,
               created_at, classifier_md, archived_at
          FROM %I.maludb_subject
         WHERE subject_type = 'stakeholder'
        WITH LOCAL CHECK OPTION
    $sql$, p_schema, p_schema);

    EXECUTE format($sql$
        CREATE OR REPLACE VIEW %I.maludb_memory AS
        SELECT memory_id, memory_kind, title, summary, payload_jsonb,
               occurred_at, occurred_until, recorded_at, sensitivity,
               lifecycle_state, consolidated_into_memory_id,
               created_at, updated_at, issue_closed_at
          FROM maludb_core.malu$memory
         WHERE owner_schema = %L
        WITH LOCAL CHECK OPTION
    $sql$, p_schema, p_schema);

    EXECUTE format($sql$
        CREATE OR REPLACE VIEW %I.maludb_skill WITH (security_invoker = true) AS
        SELECT skill_id, skill_name, version, description, packaging_kind,
               applicability_jsonb, precondition_jsonb, enabled, created_at,
               updated_at, visibility, source_owner_schema, source_skill_id,
               forked_at, owner_schema, markdown
          FROM maludb_core.malu$skill_package
         WHERE owner_schema = %L
        WITH LOCAL CHECK OPTION
    $sql$, p_schema, p_schema);

    EXECUTE format($sql$
        CREATE OR REPLACE VIEW %I.maludb_document WITH (security_invoker = true) AS
        SELECT d.document_id, d.source_package_id, d.title, d.source_type,
               d.media_type, d.primary_project_id, d.lifecycle_state,
               d.metadata_jsonb, d.created_at, d.updated_at,
               (SELECT sp.content_text
                  FROM maludb_core.malu$source_package sp
                 WHERE sp.owner_schema = d.owner_schema
                   AND sp.source_package_id = d.source_package_id
                   AND sp.source_type = d.source_type) AS body_text
          FROM maludb_core.malu$document d
         WHERE d.owner_schema = %L
        WITH LOCAL CHECK OPTION
    $sql$, p_schema, p_schema);

    -- ---- new helper functions (counted) ----
    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_subject_verb_link', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_subject_verb_link(p_subject_id bigint, p_verb_id bigint)
        RETURNS bigint LANGUAGE sql SECURITY DEFINER
        SET search_path = pg_catalog, maludb_core, pg_temp
        AS $facade$ SELECT maludb_core._link_subject_verb_for_schema(%L::name, p_subject_id, p_verb_id) $facade$
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_subject_verb_link(bigint, bigint) FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_subject_verb_link(bigint, bigint) TO maludb_memory_admin, maludb_memory_executor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_subject_verb_link', 'function', 'Schema-local subject<->verb link (compartment) with default embedding config.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_subject_verb_unlink', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_subject_verb_unlink(p_subject_id bigint, p_verb_id bigint)
        RETURNS integer LANGUAGE sql SECURITY DEFINER
        SET search_path = pg_catalog, maludb_core, pg_temp
        AS $facade$ SELECT maludb_core._unlink_subject_verb_for_schema(%L::name, p_subject_id, p_verb_id) $facade$
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_subject_verb_unlink(bigint, bigint) FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_subject_verb_unlink(bigint, bigint) TO maludb_memory_admin, maludb_memory_executor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_subject_verb_unlink', 'function', 'Schema-local subject<->verb unlink.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_svpor_relationship_delete', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_svpor_relationship_delete(
            p_source_kind text, p_source_id bigint,
            p_target_kind text, p_target_id bigint,
            p_relationship_type text DEFAULT NULL
        ) RETURNS integer LANGUAGE sql SECURITY INVOKER
        SET search_path = %I, maludb_core, pg_temp
        AS $facade$ SELECT maludb_core.delete_svpor_relationship(
            p_source_kind, p_source_id, p_target_kind, p_target_id, p_relationship_type) $facade$
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_svpor_relationship_delete(text, bigint, text, bigint, text) FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_svpor_relationship_delete(text, bigint, text, bigint, text) TO maludb_memory_admin, maludb_memory_executor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_svpor_relationship_delete', 'function', 'Schema-local object-graph relationship delete.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_pool_remove_named_member', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_pool_remove_named_member(
            p_pool_name text, p_member_kind text, p_member_name text
        ) RETURNS integer LANGUAGE sql SECURITY DEFINER
        SET search_path = pg_catalog, maludb_core, pg_temp
        AS $facade$ SELECT maludb_core._pool_remove_named_member_for_schema(%L::name, p_pool_name, p_member_kind, p_member_name) $facade$
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_pool_remove_named_member(text, text, text) FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_pool_remove_named_member(text, text, text) TO maludb_memory_admin, maludb_memory_executor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_pool_remove_named_member', 'function', 'Schema-local pool named-member removal.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_project_archive', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_project_archive(p_project_id bigint)
        RETURNS boolean LANGUAGE sql SECURITY INVOKER
        SET search_path = %I, maludb_core, pg_temp
        AS $facade$ SELECT maludb_core.project_archive(p_project_id) $facade$
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_project_archive(bigint) FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_project_archive(bigint) TO maludb_memory_admin, maludb_memory_executor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_project_archive', 'function', 'Schema-local project archive.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_project_unarchive', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_project_unarchive(p_project_id bigint)
        RETURNS boolean LANGUAGE sql SECURITY INVOKER
        SET search_path = %I, maludb_core, pg_temp
        AS $facade$ SELECT maludb_core.project_unarchive(p_project_id) $facade$
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_project_unarchive(bigint) FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_project_unarchive(bigint) TO maludb_memory_admin, maludb_memory_executor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_project_unarchive', 'function', 'Schema-local project unarchive.');
    v_count := v_count + 1;

    RETURN v_count;
END;
$body$;

REVOKE ALL ON FUNCTION maludb_core._enable_memory_schema_080_facade(name) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core._enable_memory_schema_080_facade(name)
    TO maludb_memory_admin, maludb_memory_executor;

-- ===== wire the new builder in (must run last) =======================
CREATE OR REPLACE FUNCTION maludb_core.enable_memory_schema(p_schema name DEFAULT current_schema())
RETURNS TABLE(schema_name name, enabled_version text, object_count integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
DECLARE
    v_enabled_version text := maludb_core.maludb_core_version();
    v_count integer := 0;
BEGIN
    IF p_schema IS NULL THEN
        p_schema := current_schema();
    END IF;

    PERFORM maludb_core._memory_schema_assert_manageable(p_schema);

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
