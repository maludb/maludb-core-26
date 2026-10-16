\echo Use "ALTER EXTENSION maludb_core UPDATE TO '0.72.0'" to load this file. \quit

-- =====================================================================
-- maludb_core 0.71.0 -> 0.72.0
--
-- Schema memory enablement:
--   * opt-in schema-local MALUDB facade generation
--   * owner_schema audit fixes for schema-visible objects
--   * document/source tagging and raw ingestion inbox
--   * subject type and subject/verb organization
--   * pool-scoped retrieval surfaces
-- =====================================================================

CREATE OR REPLACE FUNCTION maludb_core_version() RETURNS text
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$ SELECT '0.72.0'::text $body$;

CREATE TABLE malu$enabled_schema (
    schema_name        name PRIMARY KEY,
    enabled_version    text NOT NULL,
    enabled_at         timestamptz NOT NULL DEFAULT now(),
    enabled_by         name NOT NULL DEFAULT current_user,
    last_refreshed_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE malu$enabled_schema_object (
    schema_name   name NOT NULL REFERENCES malu$enabled_schema(schema_name) ON DELETE CASCADE,
    object_name   name NOT NULL,
    object_kind   text NOT NULL CHECK (object_kind IN ('view','function','trigger')),
    object_purpose text NOT NULL,
    created_at    timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (schema_name, object_name, object_kind)
);

GRANT SELECT ON malu$enabled_schema, malu$enabled_schema_object TO
    maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;

ALTER TABLE malu$svpor_subject
    ADD COLUMN subject_type text NOT NULL DEFAULT 'concept';

CREATE INDEX malu$svpor_subject_type_idx
    ON malu$svpor_subject(owner_schema, subject_type, canonical_name);

ALTER EXTENSION maludb_core DROP FUNCTION register_svpor_subject(text, text[], text);
DROP FUNCTION register_svpor_subject(text, text[], text);

CREATE FUNCTION register_svpor_subject(
    p_canonical_name text,
    p_aliases        text[] DEFAULT ARRAY[]::text[],
    p_description    text   DEFAULT NULL,
    p_subject_type   text   DEFAULT 'concept'
) RETURNS bigint
LANGUAGE plpgsql
AS $body$
DECLARE v_id bigint;
BEGIN
    INSERT INTO malu$svpor_subject (canonical_name, aliases, description, subject_type)
    VALUES (
        p_canonical_name,
        COALESCE(p_aliases, ARRAY[]::text[]),
        p_description,
        COALESCE(NULLIF(p_subject_type, ''), 'concept')
    )
    ON CONFLICT (owner_schema, canonical_name) DO UPDATE
        SET aliases      = COALESCE((SELECT array_agg(DISTINCT a)
                                     FROM unnest(malu$svpor_subject.aliases || COALESCE(EXCLUDED.aliases, ARRAY[]::text[])) AS a),
                                    ARRAY[]::text[]),
            description  = COALESCE(EXCLUDED.description, malu$svpor_subject.description),
            subject_type = EXCLUDED.subject_type
    RETURNING subject_id INTO v_id;
    RETURN v_id;
END;
$body$;

REVOKE ALL ON FUNCTION register_svpor_subject(text, text[], text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION register_svpor_subject(text, text[], text, text) TO
    maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;

ALTER TABLE malu$source_package
    ADD CONSTRAINT malu$source_package_owner_id_type_key
    UNIQUE (owner_schema, source_package_id, source_type);

CREATE TABLE malu$document (
    document_id        bigserial PRIMARY KEY,
    owner_schema       name NOT NULL DEFAULT current_schema(),
    source_package_id  bigint,
    title              text NOT NULL,
    source_type        text NOT NULL REFERENCES malu$source_type(source_type),
    media_type         text,
    primary_project_id bigint REFERENCES malu$svpor_subject(subject_id) ON DELETE SET NULL,
    lifecycle_state    text NOT NULL DEFAULT 'active'
        CHECK (lifecycle_state IN ('active','processing','processed','archived','tombstoned')),
    metadata_jsonb     jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at         timestamptz NOT NULL DEFAULT now(),
    updated_at         timestamptz NOT NULL DEFAULT now(),
    UNIQUE (owner_schema, document_id),
    FOREIGN KEY (owner_schema, source_package_id, source_type)
        REFERENCES malu$source_package(owner_schema, source_package_id, source_type)
);
CREATE INDEX malu$document_owner_idx ON malu$document(owner_schema, created_at DESC);
CREATE INDEX malu$document_source_idx ON malu$document(source_package_id) WHERE source_package_id IS NOT NULL;

ALTER TABLE malu$document ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_owner ON malu$document
    USING (owner_schema = current_schema())
    WITH CHECK (owner_schema = current_schema());

CREATE TABLE malu$document_tag (
    tag_id          bigserial PRIMARY KEY,
    owner_schema    name NOT NULL DEFAULT current_schema(),
    document_id     bigint NOT NULL,
    tag_kind        text NOT NULL
        CHECK (tag_kind IN ('project','subject','verb','event','stakeholder','skill','workflow','freeform')),
    tag_value       text NOT NULL,
    tag_object_type text,
    tag_object_id   bigint,
    provenance      text NOT NULL DEFAULT 'provided'
        CHECK (provenance IN ('provided','suggested','accepted','rejected')),
    confidence      numeric(5,4) CHECK (confidence IS NULL OR confidence BETWEEN 0 AND 1),
    metadata_jsonb  jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at      timestamptz NOT NULL DEFAULT now(),
    UNIQUE (document_id, tag_kind, tag_value, provenance),
    FOREIGN KEY (owner_schema, document_id)
        REFERENCES malu$document(owner_schema, document_id) ON DELETE CASCADE
);
CREATE INDEX malu$document_tag_lookup_idx ON malu$document_tag(owner_schema, tag_kind, tag_value);
CREATE INDEX malu$document_tag_document_idx ON malu$document_tag(document_id);

ALTER TABLE malu$document_tag ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_owner ON malu$document_tag
    USING (owner_schema = current_schema())
    WITH CHECK (owner_schema = current_schema());

CREATE TABLE malu$raw_ingest (
    ingest_id     bigserial PRIMARY KEY,
    owner_schema  name NOT NULL DEFAULT current_schema(),
    source_type   text NOT NULL,
    source_name   text,
    payload_jsonb jsonb,
    content_text  text,
    content_bytes bytea,
    content_hash  text,
    state         text NOT NULL DEFAULT 'received'
        CHECK (state IN ('received','queued','processing','processed','partially_applied','applied','failed','ignored')),
    received_at   timestamptz NOT NULL DEFAULT now(),
    processed_at  timestamptz,
    last_error    text,
    context_jsonb jsonb NOT NULL DEFAULT '{}'::jsonb,
    CHECK (payload_jsonb IS NOT NULL OR content_text IS NOT NULL OR content_bytes IS NOT NULL),
    UNIQUE (owner_schema, ingest_id)
);
CREATE INDEX malu$raw_ingest_owner_state_idx ON malu$raw_ingest(owner_schema, state, received_at DESC);
CREATE INDEX malu$raw_ingest_hash_idx ON malu$raw_ingest(content_hash) WHERE content_hash IS NOT NULL;

ALTER TABLE malu$raw_ingest ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_owner ON malu$raw_ingest
    USING (owner_schema = current_schema())
    WITH CHECK (owner_schema = current_schema());

CREATE TABLE malu$ingest_extraction (
    extraction_id       bigserial PRIMARY KEY,
    owner_schema        name NOT NULL DEFAULT current_schema(),
    ingest_id           bigint NOT NULL,
    derived_object_type text NOT NULL,
    derived_object_id   bigint,
    extraction_state    text NOT NULL DEFAULT 'suggested'
        CHECK (extraction_state IN ('suggested','accepted','rejected','applied')),
    confidence          numeric(5,4) CHECK (confidence IS NULL OR confidence BETWEEN 0 AND 1),
    payload_jsonb       jsonb,
    created_at          timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (owner_schema, ingest_id)
        REFERENCES malu$raw_ingest(owner_schema, ingest_id) ON DELETE CASCADE
);
CREATE INDEX malu$ingest_extraction_ingest_idx ON malu$ingest_extraction(ingest_id);
CREATE INDEX malu$ingest_extraction_owner_state_idx ON malu$ingest_extraction(owner_schema, extraction_state);

ALTER TABLE malu$ingest_extraction ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_owner ON malu$ingest_extraction
    USING (owner_schema = current_schema())
    WITH CHECK (owner_schema = current_schema());

GRANT SELECT, INSERT, UPDATE, DELETE ON
    malu$document, malu$document_tag, malu$raw_ingest, malu$ingest_extraction
TO maludb_memory_admin, maludb_memory_executor;
GRANT SELECT ON
    malu$document, malu$document_tag, malu$raw_ingest, malu$ingest_extraction
TO maludb_memory_auditor;
GRANT USAGE, SELECT ON SEQUENCE
    malu$document_document_id_seq,
    malu$document_tag_tag_id_seq,
    malu$raw_ingest_ingest_id_seq,
    malu$ingest_extraction_extraction_id_seq
TO maludb_memory_admin, maludb_memory_executor;

DO $body$
DECLARE
    v_constraint name;
BEGIN
    FOR v_constraint IN
        SELECT c.conname
      FROM pg_catalog.pg_constraint c
     WHERE c.conrelid = 'maludb_core.malu$active_memory_pool_member'::regclass
       AND c.contype = 'c'
       AND (
           c.conname = 'malu$active_memory_pool_member_member_kind_check'
           OR (
               pg_catalog.pg_get_constraintdef(c.oid) LIKE '%member_kind%'
               AND pg_catalog.pg_get_constraintdef(c.oid) NOT LIKE '%member_object_id%'
           )
       )
    LOOP
        EXECUTE format('ALTER TABLE maludb_core.malu$active_memory_pool_member DROP CONSTRAINT %I', v_constraint);
    END LOOP;
END;
$body$;

ALTER TABLE malu$active_memory_pool_member
    ADD CONSTRAINT malu$active_memory_pool_member_kind_check
    CHECK (member_kind IN
           ('observation','pending_claim','memory','fact','episode_object',
            'workflow_trace','skill','source_reference','project','subject',
            'verb','subject_verb','document','mcp_server','mcp_tool','raw_ingest'));

ALTER TABLE malu$active_memory_pool
    ADD CONSTRAINT malu$active_memory_pool_owner_pool_id_key
    UNIQUE (owner_schema, pool_id);

ALTER TABLE malu$active_memory_pool_member
    ADD CONSTRAINT malu$active_memory_pool_member_owner_member_id_key
    UNIQUE (owner_schema, member_id);

ALTER TABLE malu$active_memory_pool_member
    ADD CONSTRAINT malu$active_memory_pool_member_owner_pool_fk
    FOREIGN KEY (owner_schema, pool_id)
        REFERENCES malu$active_memory_pool(owner_schema, pool_id) ON DELETE CASCADE;

ALTER TABLE malu$active_memory_pool_member
    ADD CONSTRAINT malu$active_memory_pool_member_owner_promoted_from_fk
    FOREIGN KEY (owner_schema, promoted_from_member_id)
        REFERENCES malu$active_memory_pool_member(owner_schema, member_id) ON DELETE SET NULL;

CREATE TABLE malu$active_memory_pool_tag (
    tag_id       bigserial PRIMARY KEY,
    owner_schema name NOT NULL DEFAULT current_schema(),
    pool_id      bigint NOT NULL,
    tag_kind     text NOT NULL,
    tag_value    text NOT NULL,
    created_at   timestamptz NOT NULL DEFAULT now(),
    UNIQUE (pool_id, tag_kind, tag_value),
    FOREIGN KEY (owner_schema, pool_id)
        REFERENCES malu$active_memory_pool(owner_schema, pool_id) ON DELETE CASCADE
);
CREATE INDEX malu$active_memory_pool_tag_lookup_idx
    ON malu$active_memory_pool_tag(owner_schema, tag_kind, tag_value);

ALTER TABLE malu$active_memory_pool_tag ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_owner ON malu$active_memory_pool_tag
    USING (owner_schema = current_schema())
    WITH CHECK (owner_schema = current_schema());

CREATE TABLE malu$active_memory_pool_access (
    access_id    bigserial PRIMARY KEY,
    owner_schema name NOT NULL DEFAULT current_schema(),
    pool_id      bigint NOT NULL,
    grantee_role name NOT NULL,
    access_level text NOT NULL CHECK (access_level IN ('read','write','manage','execute')),
    granted_by   name NOT NULL DEFAULT current_user,
    granted_at   timestamptz NOT NULL DEFAULT now(),
    revoked_at   timestamptz,
    FOREIGN KEY (owner_schema, pool_id)
        REFERENCES malu$active_memory_pool(owner_schema, pool_id) ON DELETE CASCADE
);
CREATE UNIQUE INDEX malu$active_memory_pool_access_active_uq
    ON malu$active_memory_pool_access(owner_schema, pool_id, grantee_role, access_level)
    WHERE revoked_at IS NULL;
CREATE INDEX malu$active_memory_pool_access_lookup_idx
    ON malu$active_memory_pool_access(owner_schema, grantee_role, access_level)
    WHERE revoked_at IS NULL;

ALTER TABLE malu$active_memory_pool_access ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_owner ON malu$active_memory_pool_access
    USING (owner_schema = current_schema())
    WITH CHECK (owner_schema = current_schema());

GRANT SELECT, INSERT, UPDATE, DELETE ON
    malu$active_memory_pool_tag, malu$active_memory_pool_access
TO maludb_memory_admin, maludb_memory_executor;
GRANT SELECT ON
    malu$active_memory_pool_tag, malu$active_memory_pool_access
TO maludb_memory_auditor;
GRANT USAGE, SELECT ON SEQUENCE
    malu$active_memory_pool_tag_tag_id_seq,
    malu$active_memory_pool_access_access_id_seq
TO maludb_memory_admin, maludb_memory_executor;

ALTER TABLE malu$mc2db_server
    ADD COLUMN IF NOT EXISTS owner_schema name NOT NULL DEFAULT current_schema();
ALTER TABLE malu$mc2db_tool
    ADD COLUMN IF NOT EXISTS owner_schema name NOT NULL DEFAULT current_schema();
ALTER TABLE malu$mc2db_prompt
    ADD COLUMN IF NOT EXISTS owner_schema name NOT NULL DEFAULT current_schema();
ALTER TABLE malu$mc2db_resource
    ADD COLUMN IF NOT EXISTS owner_schema name NOT NULL DEFAULT current_schema();

UPDATE malu$mc2db_server SET owner_schema = 'maludb_core'
 WHERE owner_schema IS NULL OR owner_schema = '';
UPDATE malu$mc2db_tool SET owner_schema = 'maludb_core'
 WHERE owner_schema IS NULL OR owner_schema = '';
UPDATE malu$mc2db_prompt SET owner_schema = 'maludb_core'
 WHERE owner_schema IS NULL OR owner_schema = '';
UPDATE malu$mc2db_resource SET owner_schema = 'maludb_core'
 WHERE owner_schema IS NULL OR owner_schema = '';

CREATE INDEX IF NOT EXISTS malu$mc2db_server_owner_idx
    ON malu$mc2db_server(owner_schema, server_name);
CREATE INDEX IF NOT EXISTS malu$mc2db_tool_owner_idx
    ON malu$mc2db_tool(owner_schema, server_id, tool_name);
CREATE INDEX IF NOT EXISTS malu$mc2db_prompt_owner_idx
    ON malu$mc2db_prompt(owner_schema, server_id, prompt_name);
CREATE INDEX IF NOT EXISTS malu$mc2db_resource_owner_idx
    ON malu$mc2db_resource(owner_schema, server_id, uri_template);

ALTER TABLE malu$mc2db_server
    DROP CONSTRAINT IF EXISTS "malu$mc2db_server_server_name_key";
ALTER TABLE malu$mc2db_server
    ADD CONSTRAINT malu$mc2db_server_owner_server_id_key
    UNIQUE (owner_schema, server_id);
ALTER TABLE malu$mc2db_server
    ADD CONSTRAINT malu$mc2db_server_owner_server_name_key
    UNIQUE (owner_schema, server_name);
ALTER TABLE malu$mc2db_tool
    ADD CONSTRAINT malu$mc2db_tool_owner_tool_id_key
    UNIQUE (owner_schema, tool_id);
ALTER TABLE malu$mc2db_prompt
    ADD CONSTRAINT malu$mc2db_prompt_owner_prompt_id_key
    UNIQUE (owner_schema, prompt_id);
ALTER TABLE malu$mc2db_resource
    ADD CONSTRAINT malu$mc2db_resource_owner_resource_id_key
    UNIQUE (owner_schema, resource_id);

ALTER TABLE malu$mc2db_tool
    ADD CONSTRAINT malu$mc2db_tool_owner_server_fk
    FOREIGN KEY (owner_schema, server_id)
        REFERENCES malu$mc2db_server(owner_schema, server_id) ON DELETE CASCADE;
ALTER TABLE malu$mc2db_prompt
    ADD CONSTRAINT malu$mc2db_prompt_owner_server_fk
    FOREIGN KEY (owner_schema, server_id)
        REFERENCES malu$mc2db_server(owner_schema, server_id) ON DELETE CASCADE;
ALTER TABLE malu$mc2db_resource
    ADD CONSTRAINT malu$mc2db_resource_owner_server_fk
    FOREIGN KEY (owner_schema, server_id)
        REFERENCES malu$mc2db_server(owner_schema, server_id) ON DELETE CASCADE;
ALTER TABLE malu$mc2db_invocation
    ADD CONSTRAINT malu$mc2db_invocation_owner_tool_fk
    FOREIGN KEY (owner_schema, tool_id)
        REFERENCES malu$mc2db_tool(owner_schema, tool_id) ON DELETE SET NULL (tool_id);

DO $body$
DECLARE
    v_table text;
BEGIN
    FOREACH v_table IN ARRAY ARRAY[
        'malu$mc2db_server',
        'malu$mc2db_tool',
        'malu$mc2db_prompt',
        'malu$mc2db_resource'
    ] LOOP
        EXECUTE format('ALTER TABLE maludb_core.%I ENABLE ROW LEVEL SECURITY', v_table);
        IF NOT EXISTS (
            SELECT 1
              FROM pg_catalog.pg_policies
             WHERE schemaname = 'maludb_core'
               AND tablename = v_table
               AND policyname = 'tenant_owner'
        ) THEN
            EXECUTE format(
                'CREATE POLICY tenant_owner ON maludb_core.%I USING (owner_schema = current_schema()) WITH CHECK (owner_schema = current_schema())',
                v_table
            );
        END IF;
    END LOOP;
END;
$body$;

ALTER TABLE malu$prompt_template
    ADD COLUMN IF NOT EXISTS owner_schema name NOT NULL DEFAULT current_schema();
ALTER TABLE malu$prompt_render
    ADD COLUMN IF NOT EXISTS owner_schema name NOT NULL DEFAULT current_schema();
ALTER TABLE malu$model_alias
    ADD COLUMN IF NOT EXISTS owner_schema name NOT NULL DEFAULT current_schema();
ALTER TABLE malu$model_request
    ADD COLUMN IF NOT EXISTS owner_schema name NOT NULL DEFAULT current_schema();
ALTER TABLE malu$model_response
    ADD COLUMN IF NOT EXISTS owner_schema name NOT NULL DEFAULT current_schema();
ALTER TABLE malu$session
    ADD COLUMN IF NOT EXISTS owner_schema name NOT NULL DEFAULT current_schema();
ALTER TABLE malu$session_context
    ADD COLUMN IF NOT EXISTS owner_schema name NOT NULL DEFAULT current_schema();

UPDATE malu$prompt_template SET owner_schema = 'maludb_core'
 WHERE owner_schema IS NULL OR owner_schema = '';
UPDATE malu$prompt_render SET owner_schema = 'maludb_core'
 WHERE owner_schema IS NULL OR owner_schema = '';
UPDATE malu$model_alias SET owner_schema = 'maludb_core'
 WHERE owner_schema IS NULL OR owner_schema = '';
UPDATE malu$model_request SET owner_schema = 'maludb_core'
 WHERE owner_schema IS NULL OR owner_schema = '';
UPDATE malu$model_response SET owner_schema = 'maludb_core'
 WHERE owner_schema IS NULL OR owner_schema = '';
UPDATE malu$session SET owner_schema = 'maludb_core'
 WHERE owner_schema IS NULL OR owner_schema = '';
UPDATE malu$session_context SET owner_schema = 'maludb_core'
 WHERE owner_schema IS NULL OR owner_schema = '';

CREATE INDEX IF NOT EXISTS malu$prompt_template_owner_idx
    ON malu$prompt_template(owner_schema, template_name, template_version);
CREATE INDEX IF NOT EXISTS malu$prompt_render_owner_idx
    ON malu$prompt_render(owner_schema, created_at DESC);
CREATE INDEX IF NOT EXISTS malu$model_alias_owner_idx
    ON malu$model_alias(owner_schema, alias_name);
CREATE INDEX IF NOT EXISTS malu$model_request_owner_idx
    ON malu$model_request(owner_schema, submitted_at DESC);
CREATE INDEX IF NOT EXISTS malu$model_response_owner_idx
    ON malu$model_response(owner_schema, finished_at DESC);
CREATE INDEX IF NOT EXISTS malu$session_owner_idx
    ON malu$session(owner_schema, created_at DESC);
CREATE INDEX IF NOT EXISTS malu$session_context_owner_idx
    ON malu$session_context(owner_schema, session_id, ordinal);

ALTER TABLE malu$prompt_template
    DROP CONSTRAINT IF EXISTS "malu$prompt_template_template_name_template_version_key";
ALTER TABLE malu$model_alias
    DROP CONSTRAINT IF EXISTS "malu$model_alias_alias_name_key";
ALTER TABLE malu$prompt_template
    ADD CONSTRAINT malu$prompt_template_owner_template_id_key
    UNIQUE (owner_schema, template_id);
ALTER TABLE malu$prompt_template
    ADD CONSTRAINT malu$prompt_template_owner_template_name_version_key
    UNIQUE (owner_schema, template_name, template_version);
ALTER TABLE malu$prompt_render
    ADD CONSTRAINT malu$prompt_render_owner_render_id_key
    UNIQUE (owner_schema, render_id);
ALTER TABLE malu$model_alias
    ADD CONSTRAINT malu$model_alias_owner_alias_id_key
    UNIQUE (owner_schema, alias_id);
ALTER TABLE malu$model_alias
    ADD CONSTRAINT malu$model_alias_owner_alias_name_key
    UNIQUE (owner_schema, alias_name);
ALTER TABLE malu$model_request
    ADD CONSTRAINT malu$model_request_owner_request_id_key
    UNIQUE (owner_schema, request_id);
ALTER TABLE malu$session
    ADD CONSTRAINT malu$session_owner_session_id_key
    UNIQUE (owner_schema, session_id);

ALTER TABLE malu$session
    ADD CONSTRAINT malu$session_owner_model_alias_fk
    FOREIGN KEY (owner_schema, model_alias_id)
        REFERENCES malu$model_alias(owner_schema, alias_id) ON DELETE SET NULL (model_alias_id);
ALTER TABLE malu$session
    ADD CONSTRAINT malu$session_owner_prompt_template_fk
    FOREIGN KEY (owner_schema, prompt_template_id)
        REFERENCES malu$prompt_template(owner_schema, template_id) ON DELETE SET NULL (prompt_template_id);
ALTER TABLE malu$session_context
    ADD CONSTRAINT malu$session_context_owner_session_fk
    FOREIGN KEY (owner_schema, session_id)
        REFERENCES malu$session(owner_schema, session_id) ON DELETE CASCADE;
ALTER TABLE malu$prompt_render
    ADD CONSTRAINT malu$prompt_render_owner_template_fk
    FOREIGN KEY (owner_schema, template_id)
        REFERENCES malu$prompt_template(owner_schema, template_id) ON DELETE RESTRICT;
ALTER TABLE malu$prompt_render
    ADD CONSTRAINT malu$prompt_render_owner_session_fk
    FOREIGN KEY (owner_schema, session_id)
        REFERENCES malu$session(owner_schema, session_id) ON DELETE CASCADE;
ALTER TABLE malu$model_request
    ADD CONSTRAINT malu$model_request_owner_session_fk
    FOREIGN KEY (owner_schema, session_id)
        REFERENCES malu$session(owner_schema, session_id) ON DELETE SET NULL (session_id);
ALTER TABLE malu$model_request
    ADD CONSTRAINT malu$model_request_owner_prompt_render_fk
    FOREIGN KEY (owner_schema, prompt_render_id)
        REFERENCES malu$prompt_render(owner_schema, render_id) ON DELETE SET NULL (prompt_render_id);
ALTER TABLE malu$model_request
    ADD CONSTRAINT malu$model_request_owner_model_alias_fk
    FOREIGN KEY (owner_schema, alias_id)
        REFERENCES malu$model_alias(owner_schema, alias_id) ON DELETE RESTRICT;
ALTER TABLE malu$model_response
    ADD CONSTRAINT malu$model_response_owner_request_fk
    FOREIGN KEY (owner_schema, request_id)
        REFERENCES malu$model_request(owner_schema, request_id) ON DELETE CASCADE;

ALTER TABLE malu$source_package
    ADD CONSTRAINT malu$source_package_owner_source_id_key
    UNIQUE (owner_schema, source_package_id);
ALTER TABLE malu$svpor_subject
    ADD CONSTRAINT malu$svpor_subject_owner_subject_id_key
    UNIQUE (owner_schema, subject_id);
ALTER TABLE malu$claim
    ADD CONSTRAINT malu$claim_owner_claim_id_key
    UNIQUE (owner_schema, claim_id);
ALTER TABLE malu$fact
    ADD CONSTRAINT malu$fact_owner_fact_id_key
    UNIQUE (owner_schema, fact_id);
ALTER TABLE malu$memory
    ADD CONSTRAINT malu$memory_owner_memory_id_key
    UNIQUE (owner_schema, memory_id);
ALTER TABLE malu$episode_object
    ADD CONSTRAINT malu$episode_object_owner_episode_id_key
    UNIQUE (owner_schema, episode_id);
ALTER TABLE malu$memory_detail_object
    ADD CONSTRAINT malu$memory_detail_object_owner_mdo_id_key
    UNIQUE (owner_schema, mdo_id);

ALTER TABLE malu$document
    ADD CONSTRAINT malu$document_owner_primary_project_fk
    FOREIGN KEY (owner_schema, primary_project_id)
        REFERENCES malu$svpor_subject(owner_schema, subject_id)
        ON DELETE SET NULL (primary_project_id);
ALTER TABLE malu$claim
    ADD CONSTRAINT malu$claim_owner_source_package_fk
    FOREIGN KEY (owner_schema, source_package_id)
        REFERENCES malu$source_package(owner_schema, source_package_id)
        ON DELETE SET NULL (source_package_id);
ALTER TABLE malu$fact
    ADD CONSTRAINT malu$fact_owner_supersedes_fact_fk
    FOREIGN KEY (owner_schema, supersedes_fact_id)
        REFERENCES malu$fact(owner_schema, fact_id)
        ON DELETE SET NULL (supersedes_fact_id);
ALTER TABLE malu$memory
    ADD CONSTRAINT malu$memory_owner_consolidated_into_fk
    FOREIGN KEY (owner_schema, consolidated_into_memory_id)
        REFERENCES malu$memory(owner_schema, memory_id)
        ON DELETE SET NULL (consolidated_into_memory_id);
ALTER TABLE malu$memory_detail_object
    ADD CONSTRAINT malu$memory_detail_object_owner_parent_fk
    FOREIGN KEY (owner_schema, parent_mdo_id)
        REFERENCES malu$memory_detail_object(owner_schema, mdo_id)
        ON DELETE CASCADE;
ALTER TABLE malu$memory_detail_object
    ADD CONSTRAINT malu$memory_detail_object_owner_memory_fk
    FOREIGN KEY (owner_schema, memory_id)
        REFERENCES malu$memory(owner_schema, memory_id)
        ON DELETE CASCADE;
ALTER TABLE malu$memory_detail_object
    ADD CONSTRAINT malu$memory_detail_object_owner_episode_fk
    FOREIGN KEY (owner_schema, episode_id)
        REFERENCES malu$episode_object(owner_schema, episode_id)
        ON DELETE CASCADE;

ALTER TABLE malu$skill_package
    ADD CONSTRAINT malu$skill_package_owner_skill_id_key
    UNIQUE (owner_schema, skill_id);
ALTER TABLE malu$skill_state
    ADD CONSTRAINT malu$skill_state_owner_state_id_key
    UNIQUE (owner_schema, state_id);
ALTER TABLE malu$skill_state
    ADD CONSTRAINT malu$skill_state_owner_skill_state_id_key
    UNIQUE (owner_schema, skill_id, state_id);
ALTER TABLE malu$skill_execution_record
    ADD CONSTRAINT malu$skill_execution_record_owner_execution_id_key
    UNIQUE (owner_schema, execution_id);
ALTER TABLE malu$skill_execution_step
    ADD CONSTRAINT malu$skill_execution_step_owner_exec_step_id_key
    UNIQUE (owner_schema, exec_step_id);

ALTER TABLE malu$skill_state
    ADD CONSTRAINT malu$skill_state_owner_skill_fk
    FOREIGN KEY (owner_schema, skill_id)
        REFERENCES malu$skill_package(owner_schema, skill_id) ON DELETE CASCADE;
ALTER TABLE malu$skill_transition
    ADD CONSTRAINT malu$skill_transition_owner_skill_fk
    FOREIGN KEY (owner_schema, skill_id)
        REFERENCES malu$skill_package(owner_schema, skill_id) ON DELETE CASCADE;
ALTER TABLE malu$skill_transition
    ADD CONSTRAINT malu$skill_transition_owner_from_state_fk
    FOREIGN KEY (owner_schema, skill_id, from_state_id)
        REFERENCES malu$skill_state(owner_schema, skill_id, state_id) ON DELETE CASCADE;
ALTER TABLE malu$skill_transition
    ADD CONSTRAINT malu$skill_transition_owner_to_state_fk
    FOREIGN KEY (owner_schema, skill_id, to_state_id)
        REFERENCES malu$skill_state(owner_schema, skill_id, state_id) ON DELETE CASCADE;
ALTER TABLE malu$skill_execution_record
    ADD CONSTRAINT malu$skill_execution_record_owner_skill_fk
    FOREIGN KEY (owner_schema, skill_id)
        REFERENCES malu$skill_package(owner_schema, skill_id) ON DELETE RESTRICT;
ALTER TABLE malu$skill_execution_record
    ADD CONSTRAINT malu$skill_execution_record_owner_current_state_fk
    FOREIGN KEY (owner_schema, skill_id, current_state_id)
        REFERENCES malu$skill_state(owner_schema, skill_id, state_id) ON DELETE SET NULL (current_state_id);
ALTER TABLE malu$skill_execution_record
    ADD CONSTRAINT malu$skill_execution_record_owner_pool_fk
    FOREIGN KEY (owner_schema, active_pool_id)
        REFERENCES malu$active_memory_pool(owner_schema, pool_id) ON DELETE SET NULL (active_pool_id);
ALTER TABLE malu$skill_execution_record
    ADD CONSTRAINT malu$skill_execution_record_owner_source_fk
    FOREIGN KEY (owner_schema, source_context_id)
        REFERENCES malu$source_package(owner_schema, source_package_id) ON DELETE SET NULL (source_context_id);
ALTER TABLE malu$skill_execution_step
    ADD CONSTRAINT malu$skill_execution_step_owner_execution_fk
    FOREIGN KEY (owner_schema, execution_id)
        REFERENCES malu$skill_execution_record(owner_schema, execution_id) ON DELETE CASCADE;
ALTER TABLE malu$skill_execution_step
    ADD CONSTRAINT malu$skill_execution_step_owner_state_fk
    FOREIGN KEY (owner_schema, state_id)
        REFERENCES malu$skill_state(owner_schema, state_id) ON DELETE RESTRICT;

ALTER TABLE malu$workflow_trace
    ADD CONSTRAINT malu$workflow_trace_owner_trace_id_key
    UNIQUE (owner_schema, trace_id);
ALTER TABLE malu$workflow_step
    ADD CONSTRAINT malu$workflow_step_owner_step_id_key
    UNIQUE (owner_schema, step_id);
ALTER TABLE malu$workflow_cluster
    ADD CONSTRAINT malu$workflow_cluster_owner_cluster_id_key
    UNIQUE (owner_schema, cluster_id);

ALTER TABLE malu$workflow_trace
    ADD CONSTRAINT malu$workflow_trace_owner_episode_fk
    FOREIGN KEY (owner_schema, episode_id)
        REFERENCES malu$episode_object(owner_schema, episode_id) ON DELETE CASCADE;
ALTER TABLE malu$workflow_step
    ADD CONSTRAINT malu$workflow_step_owner_trace_fk
    FOREIGN KEY (owner_schema, trace_id)
        REFERENCES malu$workflow_trace(owner_schema, trace_id) ON DELETE CASCADE;
ALTER TABLE malu$workflow_step
    ADD CONSTRAINT malu$workflow_step_owner_evidence_source_fk
    FOREIGN KEY (owner_schema, evidence_source_id)
        REFERENCES malu$source_package(owner_schema, source_package_id) ON DELETE SET NULL (evidence_source_id);
ALTER TABLE malu$workflow_step
    ADD CONSTRAINT malu$workflow_step_owner_evidence_mdo_fk
    FOREIGN KEY (owner_schema, evidence_mdo_id)
        REFERENCES malu$memory_detail_object(owner_schema, mdo_id) ON DELETE SET NULL (evidence_mdo_id);
ALTER TABLE malu$workflow_step
    ADD CONSTRAINT malu$workflow_step_owner_predecessor_fk
    FOREIGN KEY (owner_schema, predecessor_step_id)
        REFERENCES malu$workflow_step(owner_schema, step_id) ON DELETE SET NULL (predecessor_step_id);
ALTER TABLE malu$workflow_step
    ADD CONSTRAINT malu$workflow_step_owner_caused_by_step_fk
    FOREIGN KEY (owner_schema, caused_by_step_id)
        REFERENCES malu$workflow_step(owner_schema, step_id) ON DELETE SET NULL (caused_by_step_id);
ALTER TABLE malu$workflow_step
    ADD CONSTRAINT malu$workflow_step_owner_caused_by_evidence_fk
    FOREIGN KEY (owner_schema, caused_by_evidence_source_id)
        REFERENCES malu$source_package(owner_schema, source_package_id) ON DELETE SET NULL (caused_by_evidence_source_id);
ALTER TABLE malu$workflow_cluster_member
    ADD CONSTRAINT malu$workflow_cluster_member_owner_cluster_fk
    FOREIGN KEY (owner_schema, cluster_id)
        REFERENCES malu$workflow_cluster(owner_schema, cluster_id) ON DELETE CASCADE;
ALTER TABLE malu$workflow_cluster_member
    ADD CONSTRAINT malu$workflow_cluster_member_owner_trace_fk
    FOREIGN KEY (owner_schema, trace_id)
        REFERENCES malu$workflow_trace(owner_schema, trace_id) ON DELETE CASCADE;
ALTER TABLE malu$workflow_candidate
    ADD CONSTRAINT malu$workflow_candidate_owner_cluster_fk
    FOREIGN KEY (owner_schema, cluster_id)
        REFERENCES malu$workflow_cluster(owner_schema, cluster_id) ON DELETE CASCADE;

GRANT SELECT, INSERT, UPDATE, DELETE ON
    malu$mc2db_server,
    malu$mc2db_tool,
    malu$mc2db_prompt,
    malu$mc2db_resource
TO maludb_memory_admin, maludb_memory_executor;
GRANT SELECT ON
    malu$mc2db_server,
    malu$mc2db_tool,
    malu$mc2db_prompt,
    malu$mc2db_resource
TO maludb_memory_auditor;
GRANT USAGE, SELECT ON SEQUENCE
    malu$prompt_template_template_id_seq,
    malu$prompt_render_render_id_seq,
    malu$model_alias_alias_id_seq,
    malu$model_request_request_id_seq,
    malu$model_response_response_id_seq,
    malu$session_session_id_seq,
    malu$session_context_context_id_seq,
    malu$mc2db_server_server_id_seq,
    malu$mc2db_tool_tool_id_seq,
    malu$mc2db_prompt_prompt_id_seq,
    malu$mc2db_resource_resource_id_seq
TO maludb_memory_admin, maludb_memory_executor;

CREATE FUNCTION _memory_schema_assert_manageable(p_schema name) RETURNS void
LANGUAGE plpgsql
AS $body$
DECLARE
    v_owner oid;
BEGIN
    IF p_schema IS NULL THEN
        RAISE EXCEPTION 'enable_memory_schema: schema is required'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;
    IF p_schema IN ('pg_catalog','information_schema','maludb_core','mc2db') OR p_schema LIKE 'pg_%' THEN
        RAISE EXCEPTION 'enable_memory_schema: refusing system schema %', p_schema
            USING ERRCODE = 'invalid_parameter_value';
    END IF;
    SELECT nspowner INTO v_owner
      FROM pg_catalog.pg_namespace
     WHERE nspname = p_schema;
    IF v_owner IS NULL THEN
        RAISE EXCEPTION 'enable_memory_schema: schema % does not exist', p_schema
            USING ERRCODE = 'invalid_schema_name';
    END IF;
    IF NOT has_schema_privilege(session_user, p_schema, 'CREATE') THEN
        RAISE EXCEPTION 'enable_memory_schema: % lacks CREATE on schema %', session_user, p_schema
            USING ERRCODE = 'insufficient_privilege';
    END IF;
END;
$body$;

REVOKE ALL ON FUNCTION _memory_schema_assert_manageable(name) FROM PUBLIC;

CREATE FUNCTION _memory_schema_assert_object_slot(
    p_schema name,
    p_object name,
    p_kind   text
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
DECLARE
    v_exists boolean := false;
BEGIN
    PERFORM maludb_core._memory_schema_assert_manageable(p_schema);

    IF p_kind = 'view' THEN
        SELECT EXISTS (
            SELECT 1
              FROM pg_catalog.pg_class c
              JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
             WHERE n.nspname = p_schema
               AND c.relname = p_object
               AND c.relkind = 'v'
        ) INTO v_exists;
    ELSIF p_kind = 'function' THEN
        SELECT EXISTS (
            SELECT 1
              FROM pg_catalog.pg_proc p
              JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
             WHERE n.nspname = p_schema
               AND p.proname = p_object
        ) INTO v_exists;
    ELSE
        RAISE EXCEPTION 'enable_memory_schema: unsupported object kind % for %.%',
            p_kind, p_schema, p_object
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    IF v_exists
       AND NOT EXISTS (
            SELECT 1
              FROM maludb_core.malu$enabled_schema_object o
             WHERE o.schema_name = p_schema
               AND o.object_name = p_object
               AND o.object_kind = p_kind
       )
    THEN
        RAISE EXCEPTION 'enable_memory_schema: refusing to replace unmanaged % %.%',
            p_kind, p_schema, p_object
            USING ERRCODE = 'duplicate_object';
    END IF;
END;
$body$;

REVOKE ALL ON FUNCTION _memory_schema_assert_object_slot(name, name, text) FROM PUBLIC;

CREATE FUNCTION _upload_document_for_schema(
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
    p_metadata_jsonb jsonb  DEFAULT '{}'::jsonb
) RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
DECLARE
    v_source_type text := COALESCE(NULLIF(p_source_type, ''), 'document');
    v_source_id   bigint;
    v_doc_id      bigint;
    v_hash        text;
    v_size        bigint;
    v_bytes       bytea;
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
        (owner_schema, source_package_id, title, source_type, media_type, metadata_jsonb)
    VALUES
        (p_owner_schema, v_source_id, p_title, v_source_type, p_media_type,
         COALESCE(p_metadata_jsonb, '{}'::jsonb))
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

REVOKE ALL ON FUNCTION _upload_document_for_schema(name, text, text, text, jsonb, text, text[], text[], text[], text[], jsonb) FROM PUBLIC;

CREATE FUNCTION upload_document(
    p_title          text,
    p_content_text   text,
    p_source_type    text   DEFAULT 'document',
    p_content_jsonb  jsonb  DEFAULT NULL,
    p_media_type     text   DEFAULT NULL,
    p_projects       text[] DEFAULT ARRAY[]::text[],
    p_subjects       text[] DEFAULT ARRAY[]::text[],
    p_verbs          text[] DEFAULT ARRAY[]::text[],
    p_events         text[] DEFAULT ARRAY[]::text[],
    p_metadata_jsonb jsonb  DEFAULT '{}'::jsonb
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
        p_metadata_jsonb
    )
$body$;

REVOKE ALL ON FUNCTION upload_document(text, text, text, jsonb, text, text[], text[], text[], text[], jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION upload_document(text, text, text, jsonb, text, text[], text[], text[], text[], jsonb)
TO maludb_memory_admin, maludb_memory_executor;

CREATE OR REPLACE FUNCTION _assert_pool_writable(p_pool_id bigint) RETURNS void
LANGUAGE plpgsql
AS $body$
DECLARE v_state text;
BEGIN
    SELECT lifecycle_state INTO v_state
      FROM maludb_core.malu$active_memory_pool
     WHERE pool_id = p_pool_id;
    IF v_state IS NULL THEN
        RAISE EXCEPTION 'active_memory_pool % not found', p_pool_id
            USING ERRCODE = 'no_data_found';
    END IF;
    IF v_state <> 'active' THEN
        RAISE EXCEPTION 'active_memory_pool % is %, not writable', p_pool_id, v_state
            USING ERRCODE = 'object_not_in_prerequisite_state';
    END IF;
END;
$body$;

CREATE OR REPLACE FUNCTION _assert_pool_capacity(p_pool_id bigint) RETURNS void
LANGUAGE plpgsql
AS $body$
DECLARE
    v_cap     integer;
    v_current integer;
BEGIN
    SELECT max_member_count INTO v_cap
      FROM maludb_core.malu$active_memory_pool
     WHERE pool_id = p_pool_id;
    IF v_cap IS NULL THEN
        RETURN;
    END IF;

    SELECT count(*) INTO v_current
      FROM maludb_core.malu$active_memory_pool_member
     WHERE pool_id = p_pool_id;
    IF v_current >= v_cap THEN
        RAISE EXCEPTION 'active_memory_pool % at capacity (% / %)',
            p_pool_id, v_current, v_cap
            USING ERRCODE = 'cardinality_violation';
    END IF;
END;
$body$;

CREATE OR REPLACE FUNCTION pool_add_reference(
    p_pool_id            bigint,
    p_member_kind        text,
    p_member_object_type text,
    p_member_object_id   bigint,
    p_confidence         numeric DEFAULT NULL,
    p_provenance         jsonb   DEFAULT NULL,
    p_access_label       text    DEFAULT NULL,
    p_account_id         bigint  DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql
AS $body$
DECLARE
    v_schema name := pg_catalog.current_schema();
    v_id     bigint;
BEGIN
    PERFORM maludb_core._assert_pool_writable(p_pool_id);
    PERFORM maludb_core._assert_pool_capacity(p_pool_id);

    IF p_member_kind = 'observation' THEN
        RAISE EXCEPTION 'pool_add_reference: use pool_add_observation for observations'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    INSERT INTO maludb_core.malu$active_memory_pool_member
        (owner_schema, pool_id, member_kind, member_object_type, member_object_id,
         confidence, provenance, access_label, added_account_id)
    VALUES
        (v_schema, p_pool_id, p_member_kind, p_member_object_type, p_member_object_id,
         p_confidence, p_provenance, p_access_label, p_account_id)
    RETURNING member_id INTO v_id;

    PERFORM maludb_core.audit_event(
        'pool_reference_added',
        p_member_object_type,
        p_member_object_id,
        pg_catalog.jsonb_build_object(
            'pool_id', p_pool_id,
            'member_id', v_id,
            'member_kind', p_member_kind
        )
    );
    RETURN v_id;
END;
$body$;

CREATE FUNCTION pool_add_named_member(
    p_pool_name   text,
    p_member_kind text,
    p_member_name text,
    p_confidence  numeric DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql
AS $body$
DECLARE
    v_schema      name := current_schema();
    v_kind        text := pg_catalog.lower(pg_catalog.btrim(p_member_kind));
    v_name        text := pg_catalog.btrim(p_member_name);
    v_pool_id     bigint;
    v_object_type text;
    v_object_id   bigint;
BEGIN
    IF p_pool_name IS NULL OR pg_catalog.btrim(p_pool_name) = '' THEN
        RAISE EXCEPTION 'pool_add_named_member: pool_name is required'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;
    IF v_kind IS NULL OR v_kind = '' THEN
        RAISE EXCEPTION 'pool_add_named_member: member_kind is required'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;
    IF v_name IS NULL OR v_name = '' THEN
        RAISE EXCEPTION 'pool_add_named_member: member_name is required'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    SELECT pool_id INTO v_pool_id
      FROM maludb_core.malu$active_memory_pool
     WHERE owner_schema = v_schema
       AND pool_name = p_pool_name;
    IF v_pool_id IS NULL THEN
        RAISE EXCEPTION 'pool_add_named_member: pool % not found in schema %', p_pool_name, v_schema
            USING ERRCODE = 'no_data_found';
    END IF;

    IF v_kind = 'project' THEN
        SELECT subject_id INTO v_object_id
          FROM maludb_core.malu$svpor_subject
         WHERE owner_schema = v_schema
           AND canonical_name = v_name
           AND subject_type = 'project'
         ORDER BY subject_id
         LIMIT 1;
        v_object_type := 'subject';
    ELSIF v_kind = 'subject' THEN
        SELECT subject_id INTO v_object_id
          FROM maludb_core.malu$svpor_subject
         WHERE owner_schema = v_schema
           AND canonical_name = v_name
         ORDER BY subject_id
         LIMIT 1;
        v_object_type := 'subject';
    ELSIF v_kind = 'verb' THEN
        SELECT verb_id INTO v_object_id
          FROM maludb_core.malu$svpor_verb
         WHERE owner_schema = v_schema
           AND canonical_name = v_name
         ORDER BY verb_id
         LIMIT 1;
        v_object_type := 'verb';
    ELSIF v_kind = 'document' THEN
        SELECT document_id INTO v_object_id
          FROM maludb_core.malu$document
         WHERE owner_schema = v_schema
           AND title = v_name
         ORDER BY document_id
         LIMIT 1;
        v_object_type := 'document';
    ELSIF v_kind = 'skill' THEN
        SELECT skill_id INTO v_object_id
          FROM maludb_core.malu$skill_package
         WHERE owner_schema = v_schema
           AND skill_name = v_name
         ORDER BY updated_at DESC, skill_id DESC
         LIMIT 1;
        v_object_type := 'skill';
    ELSIF v_kind = 'memory' THEN
        SELECT memory_id INTO v_object_id
          FROM maludb_core.malu$memory
         WHERE owner_schema = v_schema
           AND title = v_name
         ORDER BY memory_id
         LIMIT 1;
        v_object_type := 'memory';
    ELSE
        RAISE EXCEPTION 'pool_add_named_member: unsupported named member_kind %', p_member_kind
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    IF v_object_id IS NULL THEN
        RAISE EXCEPTION 'pool_add_named_member: % named % not found in schema %', v_kind, v_name, v_schema
            USING ERRCODE = 'no_data_found';
    END IF;

    RETURN maludb_core.pool_add_reference(
        v_pool_id,
        v_kind,
        v_object_type,
        v_object_id,
        p_confidence,
        jsonb_build_object('named_member', v_name),
        NULL,
        NULL
    );
END;
$body$;

REVOKE ALL ON FUNCTION pool_add_named_member(text, text, text, numeric) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pool_add_named_member(text, text, text, numeric)
TO maludb_memory_admin, maludb_memory_executor;

CREATE OR REPLACE FUNCTION text_search(
    p_query         text,
    p_object_types  text[] DEFAULT ARRAY['claim','fact','memory','episode_object'],
    p_limit         integer DEFAULT 20
) RETURNS TABLE (
    object_type        text,
    object_id          bigint,
    title_or_subject   text,
    snippet            text,
    rank               real
) LANGUAGE plpgsql STABLE
AS $body$
DECLARE
    v_tsq tsquery := pg_catalog.websearch_to_tsquery('english', p_query);
BEGIN
    RETURN QUERY
        SELECT * FROM (
            SELECT 'claim'::text,
                   c.claim_id,
                   COALESCE(c.subject, c.verb, '?')::text,
                   pg_catalog.left(COALESCE(c.statement_text, ''), 240)::text,
                   pg_catalog.ts_rank(c.fts_tsv, v_tsq)
            FROM maludb_core.malu$claim c
            WHERE 'claim' = ANY(p_object_types)
              AND c.fts_tsv @@ v_tsq
            UNION ALL
            SELECT 'fact'::text,
                   f.fact_id,
                   COALESCE(f.subject, f.verb, '?')::text,
                   pg_catalog.left(COALESCE(f.statement_text, ''), 240)::text,
                   pg_catalog.ts_rank(f.fts_tsv, v_tsq)
            FROM maludb_core.malu$fact f
            WHERE 'fact' = ANY(p_object_types)
              AND f.fts_tsv @@ v_tsq
            UNION ALL
            SELECT 'memory'::text,
                   m.memory_id,
                   COALESCE(m.title, m.memory_kind, '?')::text,
                   pg_catalog.left(COALESCE(m.summary, ''), 240)::text,
                   pg_catalog.ts_rank(m.fts_tsv, v_tsq)
            FROM maludb_core.malu$memory m
            WHERE 'memory' = ANY(p_object_types)
              AND m.fts_tsv @@ v_tsq
            UNION ALL
            SELECT 'episode_object'::text,
                   e.episode_id,
                   COALESCE(e.title, e.episode_kind, '?')::text,
                   pg_catalog.left(COALESCE(e.summary, ''), 240)::text,
                   pg_catalog.ts_rank(e.fts_tsv, v_tsq)
            FROM maludb_core.malu$episode_object e
            WHERE 'episode_object' = ANY(p_object_types)
              AND e.fts_tsv @@ v_tsq
        ) hits(object_type, object_id, title_or_subject, snippet, rank)
        ORDER BY rank DESC NULLS LAST, object_id
        LIMIT p_limit;
END;
$body$;

CREATE FUNCTION pool_search(
    p_pool_name      text,
    p_query_text     text DEFAULT NULL,
    p_limit          integer DEFAULT 20,
    p_allow_fallback boolean DEFAULT false
) RETURNS TABLE (
    object_type      text,
    object_id        bigint,
    title_or_subject text,
    snippet          text,
    rank             real,
    source           text
) LANGUAGE plpgsql STABLE
AS $body$
DECLARE
    v_schema name := current_schema();
    v_pool_id bigint;
    v_limit integer := GREATEST(COALESCE(p_limit, 20), 0);
    v_rows integer := 0;
BEGIN
    IF v_limit = 0 THEN
        RETURN;
    END IF;

    SELECT pool_id INTO v_pool_id
      FROM maludb_core.malu$active_memory_pool
     WHERE owner_schema = v_schema
       AND pool_name = p_pool_name;
    IF v_pool_id IS NULL THEN
        RAISE EXCEPTION 'pool_search: pool % not found in schema %', p_pool_name, v_schema
            USING ERRCODE = 'no_data_found';
    END IF;

    IF p_query_text IS NOT NULL AND pg_catalog.btrim(p_query_text) <> '' THEN
        RETURN QUERY
        WITH scoped AS (
            SELECT 'claim'::text AS scoped_type, c.claim_id AS scoped_id
              FROM maludb_core.malu$active_memory_pool_member m
              JOIN maludb_core.malu$claim c
                ON c.owner_schema = v_schema
               AND c.claim_id = m.member_object_id
             WHERE m.owner_schema = v_schema
               AND m.pool_id = v_pool_id
               AND (m.member_object_type = 'claim' OR m.member_kind = 'pending_claim')
            UNION ALL
            SELECT 'fact'::text AS scoped_type, f.fact_id AS scoped_id
              FROM maludb_core.malu$active_memory_pool_member m
              JOIN maludb_core.malu$fact f
                ON f.owner_schema = v_schema
               AND f.fact_id = m.member_object_id
             WHERE m.owner_schema = v_schema
               AND m.pool_id = v_pool_id
               AND (m.member_object_type = 'fact' OR m.member_kind = 'fact')
            UNION ALL
            SELECT 'memory'::text AS scoped_type, mem.memory_id AS scoped_id
              FROM maludb_core.malu$active_memory_pool_member m
              JOIN maludb_core.malu$memory mem
                ON mem.owner_schema = v_schema
               AND mem.memory_id = m.member_object_id
             WHERE m.owner_schema = v_schema
               AND m.pool_id = v_pool_id
               AND (m.member_object_type = 'memory' OR m.member_kind = 'memory')
            UNION ALL
            SELECT 'episode_object'::text AS scoped_type, ep.episode_id AS scoped_id
              FROM maludb_core.malu$active_memory_pool_member m
              JOIN maludb_core.malu$episode_object ep
                ON ep.owner_schema = v_schema
               AND ep.episode_id = m.member_object_id
             WHERE m.owner_schema = v_schema
               AND m.pool_id = v_pool_id
               AND (m.member_object_type = 'episode_object' OR m.member_kind = 'episode_object')
        )
        SELECT r.object_type,
               r.object_id,
               r.title_or_subject,
               r.snippet,
               r.rank,
               'text_search'::text AS source
          FROM maludb_core.text_search(
                   p_query_text,
                   ARRAY['claim','fact','memory','episode_object']::text[],
                   v_limit * 5
               ) AS r
          JOIN scoped s
            ON s.scoped_type = r.object_type
           AND s.scoped_id = r.object_id
         ORDER BY r.rank DESC NULLS LAST, r.object_type, r.object_id
         LIMIT v_limit;

        GET DIAGNOSTICS v_rows = ROW_COUNT;
        IF v_rows > 0 OR NOT p_allow_fallback THEN
            RETURN;
        END IF;
    ELSIF NOT p_allow_fallback THEN
        RETURN;
    END IF;

    RETURN QUERY
    WITH scoped AS (
        SELECT 'claim'::text AS scoped_type,
               c.claim_id AS scoped_id,
               c.subject::text AS title_or_subject,
               c.statement_text::text AS snippet,
               m.added_at
          FROM maludb_core.malu$active_memory_pool_member m
          JOIN maludb_core.malu$claim c
            ON c.owner_schema = v_schema
           AND c.claim_id = m.member_object_id
         WHERE m.owner_schema = v_schema
           AND m.pool_id = v_pool_id
           AND (m.member_object_type = 'claim' OR m.member_kind = 'pending_claim')
        UNION ALL
        SELECT 'fact'::text AS scoped_type,
               f.fact_id AS scoped_id,
               f.subject::text AS title_or_subject,
               f.statement_text::text AS snippet,
               m.added_at
          FROM maludb_core.malu$active_memory_pool_member m
          JOIN maludb_core.malu$fact f
            ON f.owner_schema = v_schema
           AND f.fact_id = m.member_object_id
         WHERE m.owner_schema = v_schema
           AND m.pool_id = v_pool_id
           AND (m.member_object_type = 'fact' OR m.member_kind = 'fact')
        UNION ALL
        SELECT 'memory'::text AS scoped_type,
               mem.memory_id AS scoped_id,
               mem.title::text AS title_or_subject,
               mem.summary::text AS snippet,
               m.added_at
          FROM maludb_core.malu$active_memory_pool_member m
          JOIN maludb_core.malu$memory mem
            ON mem.owner_schema = v_schema
           AND mem.memory_id = m.member_object_id
         WHERE m.owner_schema = v_schema
           AND m.pool_id = v_pool_id
           AND (m.member_object_type = 'memory' OR m.member_kind = 'memory')
        UNION ALL
        SELECT 'episode_object'::text AS scoped_type,
               ep.episode_id AS scoped_id,
               ep.title::text AS title_or_subject,
               ep.summary::text AS snippet,
               m.added_at
          FROM maludb_core.malu$active_memory_pool_member m
          JOIN maludb_core.malu$episode_object ep
            ON ep.owner_schema = v_schema
           AND ep.episode_id = m.member_object_id
         WHERE m.owner_schema = v_schema
           AND m.pool_id = v_pool_id
           AND (m.member_object_type = 'episode_object' OR m.member_kind = 'episode_object')
    )
    SELECT s.scoped_type,
           s.scoped_id,
           COALESCE(s.title_or_subject, s.scoped_type || ':' || s.scoped_id::text)::text,
           COALESCE(s.snippet, '')::text,
           0::real,
           'pool_member'::text
      FROM scoped s
     ORDER BY s.added_at, s.scoped_type, s.scoped_id
     LIMIT v_limit;
END;
$body$;

REVOKE ALL ON FUNCTION pool_search(text, text, integer, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pool_search(text, text, integer, boolean)
TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;

CREATE FUNCTION vector_search_by_tags(
    p_namespace       text DEFAULT 'default',
    p_subject         text DEFAULT NULL,
    p_verb            text DEFAULT NULL,
    p_query_embedding malu_vector DEFAULT NULL,
    p_limit           integer DEFAULT 20,
    p_metric          text DEFAULT NULL
) RETURNS TABLE (
    chunk_id        bigint,
    source_text     text,
    distance        double precision,
    similarity      double precision,
    rank_no         integer,
    compartment_id  bigint,
    subject_name    text,
    verb_name       text
) LANGUAGE plpgsql STABLE
SECURITY DEFINER
AS $body$
#variable_conflict use_column
DECLARE
    v_schema      name := pg_catalog.current_schema();
    v_namespace   text := COALESCE(p_namespace, 'default');
    v_limit       integer := GREATEST(COALESCE(p_limit, 20), 0);
    v_search_path text := pg_catalog.current_setting('search_path');
BEGIN
    IF p_query_embedding IS NULL THEN
        RAISE EXCEPTION 'vector_search_by_tags: query embedding is required'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;
    IF p_subject IS NULL AND p_verb IS NULL THEN
        RAISE EXCEPTION 'vector_search_by_tags: subject or verb is required'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;
    IF v_limit = 0 THEN
        RETURN;
    END IF;

    PERFORM pg_catalog.set_config('search_path', 'pg_catalog, maludb_core, pg_temp', true);

    BEGIN
        RETURN QUERY
        WITH matching_compartments AS (
            SELECT c.compartment_id,
                   s.subject_name,
                   v.verb_name
              FROM maludb_core.malu$vector_compartment c
              JOIN maludb_core.malu$vector_subject s
                ON s.owner_schema = c.owner_schema
               AND s.namespace = c.namespace
               AND s.subject_id = c.subject_id
              JOIN maludb_core.malu$vector_verb v
                ON v.owner_schema = c.owner_schema
               AND v.namespace = c.namespace
               AND v.verb_id = c.verb_id
             WHERE c.owner_schema = v_schema
               AND c.namespace = v_namespace
               AND (p_subject IS NULL OR s.subject_name = p_subject)
               AND (p_verb IS NULL OR v.verb_name = p_verb)
        ),
        compartment_hits AS (
            SELECT h.chunk_id AS hit_chunk_id,
                   h.source_text AS hit_source_text,
                   h.distance AS hit_distance,
                   h.similarity AS hit_similarity,
                   mc.compartment_id AS hit_compartment_id,
                   mc.subject_name AS hit_subject_name,
                   mc.verb_name AS hit_verb_name
              FROM matching_compartments mc
              CROSS JOIN LATERAL maludb_core.exact_vector_search_sql(
                  mc.compartment_id,
                  p_query_embedding,
                  v_limit,
                  p_metric
              ) AS h
        ),
        ranked_hits AS (
            SELECT h.hit_chunk_id,
                   h.hit_source_text,
                   h.hit_distance,
                   h.hit_similarity,
                   ROW_NUMBER() OVER (
                       ORDER BY h.hit_distance ASC,
                                h.hit_compartment_id ASC,
                                h.hit_chunk_id ASC
                   )::integer AS global_rank_no,
                   h.hit_compartment_id,
                   h.hit_subject_name,
                   h.hit_verb_name
              FROM compartment_hits h
        )
        SELECT r.hit_chunk_id,
               r.hit_source_text,
               r.hit_distance,
               r.hit_similarity,
               r.global_rank_no,
               r.hit_compartment_id,
               r.hit_subject_name,
               r.hit_verb_name
          FROM ranked_hits r
         WHERE r.global_rank_no <= v_limit
         ORDER BY r.global_rank_no;

        PERFORM pg_catalog.set_config('search_path', v_search_path, true);
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_catalog.set_config('search_path', v_search_path, true);
        RAISE;
    END;
END;
$body$;

REVOKE ALL ON FUNCTION vector_search_by_tags(text, text, text, malu_vector, integer, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION vector_search_by_tags(text, text, text, malu_vector, integer, text)
TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;

CREATE FUNCTION _memory_schema_record_object(
    p_schema name,
    p_object name,
    p_kind text,
    p_purpose text
) RETURNS void
LANGUAGE sql
AS $body$
    INSERT INTO malu$enabled_schema_object(schema_name, object_name, object_kind, object_purpose)
    VALUES (p_schema, p_object, p_kind, p_purpose)
    ON CONFLICT (schema_name, object_name, object_kind)
DO UPDATE SET object_purpose = EXCLUDED.object_purpose;
$body$;

REVOKE ALL ON FUNCTION _memory_schema_record_object(name, name, text, text) FROM PUBLIC;

CREATE FUNCTION _register_vector_compartment_for_schema(
    p_owner_schema     name,
    p_namespace        text,
    p_subject_name     text,
    p_verb_name        text,
    p_embedding_dim    integer,
    p_embedding_model  text,
    p_distance_metric  text DEFAULT 'cosine'
) RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
DECLARE
    v_subject_id     bigint;
    v_verb_id        bigint;
    v_compartment_id bigint;
    v_distance_metric text := COALESCE(NULLIF(p_distance_metric, ''), 'cosine');
BEGIN
    PERFORM maludb_core._memory_schema_assert_manageable(p_owner_schema);

    INSERT INTO maludb_core.malu$vector_subject(owner_schema, namespace, subject_name)
    VALUES (p_owner_schema, p_namespace, p_subject_name)
    ON CONFLICT (owner_schema, namespace, subject_name)
        DO UPDATE SET subject_name = EXCLUDED.subject_name
    RETURNING subject_id INTO v_subject_id;

    INSERT INTO maludb_core.malu$vector_verb(owner_schema, namespace, verb_name)
    VALUES (p_owner_schema, p_namespace, p_verb_name)
    ON CONFLICT (owner_schema, namespace, verb_name)
        DO UPDATE SET verb_name = EXCLUDED.verb_name
    RETURNING verb_id INTO v_verb_id;

    INSERT INTO maludb_core.malu$vector_compartment
        (owner_schema, namespace, subject_id, verb_id,
         embedding_dim, embedding_model, distance_metric)
    VALUES
        (p_owner_schema, p_namespace, v_subject_id, v_verb_id,
         p_embedding_dim, p_embedding_model, v_distance_metric)
    ON CONFLICT (owner_schema, namespace, subject_id, verb_id)
        DO UPDATE SET updated_at = now()
    RETURNING compartment_id INTO v_compartment_id;

    RETURN v_compartment_id;
END;
$body$;

REVOKE ALL ON FUNCTION _register_vector_compartment_for_schema(name, text, text, text, integer, text, text) FROM PUBLIC;

CREATE FUNCTION _enable_memory_schema_subject_facade(p_schema name) RETURNS integer
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
               created_at
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
               created_at
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
               created_at
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
               created_at
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

REVOKE ALL ON FUNCTION _enable_memory_schema_subject_facade(name) FROM PUBLIC;

CREATE FUNCTION _enable_memory_schema_core_facade(p_schema name) RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
DECLARE
    v_count integer := 0;
BEGIN
    PERFORM maludb_core._memory_schema_assert_manageable(p_schema);

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_source_package', 'view');
    EXECUTE format($sql$
        CREATE OR REPLACE VIEW %I.maludb_source_package AS
        SELECT source_package_id,
               source_type,
               content_bytes,
               content_text,
               content_jsonb,
               content_hash,
               content_size,
               media_type,
               origin_jsonb,
               captured_at,
               ingested_at,
               retention_class,
               legal_hold,
               legal_hold_reason,
               retain_until,
               sensitivity,
               sealed_at,
               archived_at,
               tombstoned_at,
               created_at,
               updated_at
          FROM maludb_core.malu$source_package
         WHERE owner_schema = %L
        WITH LOCAL CHECK OPTION
    $sql$, p_schema, p_schema);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON %I.maludb_source_package TO maludb_memory_admin, maludb_memory_executor', p_schema);
    EXECUTE format('GRANT SELECT ON %I.maludb_source_package TO maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_source_package', 'view', 'Schema-local source package facade.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_claim', 'view');
    EXECUTE format($sql$
        CREATE OR REPLACE VIEW %I.maludb_claim AS
        SELECT claim_id,
               subject,
               verb,
               predicate,
               object_value,
               relationship,
               statement_text,
               statement_jsonb,
               source_package_id,
               source_locator,
               asserted_at,
               retracted_at,
               retraction_reason,
               sensitivity,
               created_at
          FROM maludb_core.malu$claim
         WHERE owner_schema = %L
        WITH LOCAL CHECK OPTION
    $sql$, p_schema, p_schema);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON %I.maludb_claim TO maludb_memory_admin, maludb_memory_executor', p_schema);
    EXECUTE format('GRANT SELECT ON %I.maludb_claim TO maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_claim', 'view', 'Schema-local claim facade.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_fact', 'view');
    EXECUTE format($sql$
        CREATE OR REPLACE VIEW %I.maludb_fact AS
        SELECT fact_id,
               subject,
               verb,
               predicate,
               object_value,
               relationship,
               statement_text,
               statement_jsonb,
               verification_scope,
               verification_method,
               verified_at,
               supersedes_fact_id,
               superseded_at,
               sensitivity,
               lifecycle_state,
               created_at
          FROM maludb_core.malu$fact
         WHERE owner_schema = %L
        WITH LOCAL CHECK OPTION
    $sql$, p_schema, p_schema);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON %I.maludb_fact TO maludb_memory_admin, maludb_memory_executor', p_schema);
    EXECUTE format('GRANT SELECT ON %I.maludb_fact TO maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_fact', 'view', 'Schema-local fact facade.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_memory', 'view');
    EXECUTE format($sql$
        CREATE OR REPLACE VIEW %I.maludb_memory AS
        SELECT memory_id,
               memory_kind,
               title,
               summary,
               payload_jsonb,
               occurred_at,
               occurred_until,
               recorded_at,
               sensitivity,
               lifecycle_state,
               consolidated_into_memory_id,
               created_at,
               updated_at
          FROM maludb_core.malu$memory
         WHERE owner_schema = %L
        WITH LOCAL CHECK OPTION
    $sql$, p_schema, p_schema);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON %I.maludb_memory TO maludb_memory_admin, maludb_memory_executor', p_schema);
    EXECUTE format('GRANT SELECT ON %I.maludb_memory TO maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_memory', 'view', 'Schema-local memory facade.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_memory_detail', 'view');
    EXECUTE format($sql$
        CREATE OR REPLACE VIEW %I.maludb_memory_detail AS
        SELECT mdo_id,
               parent_mdo_id,
               memory_id,
               episode_id,
               detail_kind,
               ordinal,
               title,
               body_text,
               body_jsonb,
               sensitivity,
               created_at
          FROM maludb_core.malu$memory_detail_object
         WHERE owner_schema = %L
           AND mdo_kind = 'memory_detail'
        WITH LOCAL CHECK OPTION
    $sql$, p_schema, p_schema);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON %I.maludb_memory_detail TO maludb_memory_admin, maludb_memory_executor', p_schema);
    EXECUTE format('GRANT SELECT ON %I.maludb_memory_detail TO maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_memory_detail', 'view', 'Schema-local memory detail object facade.');
    v_count := v_count + 1;

    RETURN v_count;
END;
$body$;

REVOKE ALL ON FUNCTION _enable_memory_schema_core_facade(name) FROM PUBLIC;

CREATE FUNCTION _enable_memory_schema_ingest_facade(p_schema name) RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
DECLARE
    v_count integer := 0;
BEGIN
    PERFORM maludb_core._memory_schema_assert_manageable(p_schema);

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_document', 'view');
    EXECUTE format($sql$
        CREATE OR REPLACE VIEW %I.maludb_document WITH (security_invoker = true) AS
        SELECT document_id,
               source_package_id,
               title,
               source_type,
               media_type,
               primary_project_id,
               lifecycle_state,
               metadata_jsonb,
               created_at,
               updated_at
          FROM maludb_core.malu$document
         WHERE owner_schema = %L
        WITH LOCAL CHECK OPTION
    $sql$, p_schema, p_schema);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON %I.maludb_document TO maludb_memory_admin, maludb_memory_executor', p_schema);
    EXECUTE format('GRANT SELECT ON %I.maludb_document TO maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_document', 'view', 'Schema-local document registry facade.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_document_tag', 'view');
    EXECUTE format($sql$
        CREATE OR REPLACE VIEW %I.maludb_document_tag WITH (security_invoker = true) AS
        SELECT tag_id,
               document_id,
               tag_kind,
               tag_value,
               tag_object_type,
               tag_object_id,
               provenance,
               confidence,
               metadata_jsonb,
               created_at
          FROM maludb_core.malu$document_tag
         WHERE owner_schema = %L
        WITH LOCAL CHECK OPTION
    $sql$, p_schema, p_schema);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON %I.maludb_document_tag TO maludb_memory_admin, maludb_memory_executor', p_schema);
    EXECUTE format('GRANT SELECT ON %I.maludb_document_tag TO maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_document_tag', 'view', 'Schema-local document tag facade.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_document_suggested_tag', 'view');
    EXECUTE format($sql$
        CREATE OR REPLACE VIEW %I.maludb_document_suggested_tag WITH (security_invoker = true) AS
        SELECT tag_id,
               document_id,
               tag_kind,
               tag_value,
               tag_object_type,
               tag_object_id,
               provenance,
               confidence,
               metadata_jsonb,
               created_at
          FROM maludb_core.malu$document_tag
         WHERE owner_schema = %L
           AND provenance = 'suggested'
    $sql$, p_schema, p_schema);
    EXECUTE format('GRANT SELECT ON %I.maludb_document_suggested_tag TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_document_suggested_tag', 'view', 'Schema-local suggested document tag facade.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_raw_ingest', 'view');
    EXECUTE format($sql$
        CREATE OR REPLACE VIEW %I.maludb_raw_ingest WITH (security_invoker = true) AS
        SELECT ingest_id,
               source_type,
               source_name,
               payload_jsonb,
               content_text,
               content_bytes,
               content_hash,
               state,
               received_at,
               processed_at,
               last_error,
               context_jsonb
          FROM maludb_core.malu$raw_ingest
         WHERE owner_schema = %L
        WITH LOCAL CHECK OPTION
    $sql$, p_schema, p_schema);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON %I.maludb_raw_ingest TO maludb_memory_admin, maludb_memory_executor', p_schema);
    EXECUTE format('GRANT SELECT ON %I.maludb_raw_ingest TO maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_raw_ingest', 'view', 'Schema-local raw ingest facade.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_unapplied_ingest', 'view');
    EXECUTE format($sql$
        CREATE OR REPLACE VIEW %I.maludb_unapplied_ingest WITH (security_invoker = true) AS
        SELECT r.ingest_id,
               r.source_type,
               r.source_name,
               r.payload_jsonb,
               r.content_text,
               r.content_bytes,
               r.content_hash,
               r.state,
               r.received_at,
               r.processed_at,
               r.last_error,
               r.context_jsonb
          FROM maludb_core.malu$raw_ingest r
         WHERE r.owner_schema = %L
           AND r.state IN ('received','queued','processing','processed','partially_applied','failed')
           AND NOT EXISTS (
               SELECT 1
                 FROM maludb_core.malu$ingest_extraction e
                WHERE e.ingest_id = r.ingest_id
                  AND e.owner_schema = r.owner_schema
                  AND e.extraction_state IN ('accepted','applied')
           )
    $sql$, p_schema, p_schema);
    EXECUTE format('GRANT SELECT ON %I.maludb_unapplied_ingest TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_unapplied_ingest', 'view', 'Schema-local unapplied raw ingest facade.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_upload_document', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_upload_document(
            p_title text,
            p_content_text text,
            p_source_type text DEFAULT 'document',
            p_content_jsonb jsonb DEFAULT NULL,
            p_media_type text DEFAULT NULL,
            p_projects text[] DEFAULT ARRAY[]::text[],
            p_subjects text[] DEFAULT ARRAY[]::text[],
            p_verbs text[] DEFAULT ARRAY[]::text[],
            p_events text[] DEFAULT ARRAY[]::text[],
            p_metadata_jsonb jsonb DEFAULT '{}'::jsonb
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
                p_metadata_jsonb
            )
        $facade$
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_upload_document(text, text, text, jsonb, text, text[], text[], text[], text[], jsonb) FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_upload_document(text, text, text, jsonb, text, text[], text[], text[], text[], jsonb) TO maludb_memory_admin, maludb_memory_executor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_upload_document', 'function', 'Schema-local document upload facade.');
    v_count := v_count + 1;

    RETURN v_count;
END;
$body$;

REVOKE ALL ON FUNCTION _enable_memory_schema_ingest_facade(name) FROM PUBLIC;

CREATE FUNCTION _enable_memory_schema_pool_facade(p_schema name) RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
DECLARE
    v_count integer := 0;
BEGIN
    PERFORM maludb_core._memory_schema_assert_manageable(p_schema);

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_memory_pool', 'view');
    EXECUTE format($sql$
        CREATE OR REPLACE VIEW %I.maludb_memory_pool WITH (security_invoker = true) AS
        SELECT pool_id,
               pool_name,
               creation_kind,
               created_by,
               task_objective,
               authorized_partitions,
               confidence_floor,
               validity_start,
               validity_end,
               max_member_count,
               lifecycle_state,
               sealed_at,
               archived_at,
               tombstoned_at,
               created_at,
               updated_at
          FROM maludb_core.malu$active_memory_pool
         WHERE owner_schema = %L
        WITH LOCAL CHECK OPTION
    $sql$, p_schema, p_schema);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON %I.maludb_memory_pool TO maludb_memory_admin, maludb_memory_executor', p_schema);
    EXECUTE format('GRANT SELECT ON %I.maludb_memory_pool TO maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_memory_pool', 'view', 'Schema-local active memory pool facade.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_memory_pool_member', 'view');
    EXECUTE format($sql$
        CREATE OR REPLACE VIEW %I.maludb_memory_pool_member WITH (security_invoker = true) AS
        SELECT member_id,
               pool_id,
               member_kind,
               member_object_type,
               member_object_id,
               payload_jsonb,
               confidence,
               staleness,
               access_label,
               provenance,
               added_by,
               added_account_id,
               added_at,
               promoted_from_member_id,
               promoted_to_object_type,
               promoted_to_object_id,
               promoted_at
          FROM maludb_core.malu$active_memory_pool_member
         WHERE owner_schema = %L
        WITH LOCAL CHECK OPTION
    $sql$, p_schema, p_schema);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON %I.maludb_memory_pool_member TO maludb_memory_admin, maludb_memory_executor', p_schema);
    EXECUTE format('GRANT SELECT ON %I.maludb_memory_pool_member TO maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_memory_pool_member', 'view', 'Schema-local active memory pool member facade.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_memory_pool_tag', 'view');
    EXECUTE format($sql$
        CREATE OR REPLACE VIEW %I.maludb_memory_pool_tag WITH (security_invoker = true) AS
        SELECT tag_id,
               pool_id,
               tag_kind,
               tag_value,
               created_at
          FROM maludb_core.malu$active_memory_pool_tag
         WHERE owner_schema = %L
        WITH LOCAL CHECK OPTION
    $sql$, p_schema, p_schema);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON %I.maludb_memory_pool_tag TO maludb_memory_admin, maludb_memory_executor', p_schema);
    EXECUTE format('GRANT SELECT ON %I.maludb_memory_pool_tag TO maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_memory_pool_tag', 'view', 'Schema-local active memory pool tag facade.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_memory_pool_access', 'view');
    EXECUTE format($sql$
        CREATE OR REPLACE VIEW %I.maludb_memory_pool_access WITH (security_invoker = true) AS
        SELECT access_id,
               pool_id,
               grantee_role,
               access_level,
               granted_by,
               granted_at,
               revoked_at
          FROM maludb_core.malu$active_memory_pool_access
         WHERE owner_schema = %L
        WITH LOCAL CHECK OPTION
    $sql$, p_schema, p_schema);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON %I.maludb_memory_pool_access TO maludb_memory_admin, maludb_memory_executor', p_schema);
    EXECUTE format('GRANT SELECT ON %I.maludb_memory_pool_access TO maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_memory_pool_access', 'view', 'Schema-local active memory pool access facade.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_pool_subject', 'view');
    EXECUTE format($sql$
        CREATE OR REPLACE VIEW %I.maludb_pool_subject WITH (security_invoker = true) AS
        SELECT p.pool_id,
               p.pool_name,
               m.member_id,
               m.member_kind,
               m.confidence,
               s.subject_id,
               s.subject_type,
               s.canonical_name,
               s.aliases,
               s.description,
               m.added_at
          FROM maludb_core.malu$active_memory_pool p
          JOIN maludb_core.malu$active_memory_pool_member m
            ON m.owner_schema = p.owner_schema
           AND m.pool_id = p.pool_id
           AND m.member_kind IN ('project','subject')
           AND m.member_object_type = 'subject'
          JOIN maludb_core.malu$svpor_subject s
            ON s.owner_schema = p.owner_schema
           AND s.subject_id = m.member_object_id
         WHERE p.owner_schema = %L
    $sql$, p_schema, p_schema);
    EXECUTE format('GRANT SELECT ON %I.maludb_pool_subject TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_pool_subject', 'view', 'Schema-local pool subject read facade.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_pool_verb', 'view');
    EXECUTE format($sql$
        CREATE OR REPLACE VIEW %I.maludb_pool_verb WITH (security_invoker = true) AS
        SELECT p.pool_id,
               p.pool_name,
               m.member_id,
               m.confidence,
               v.verb_id,
               v.canonical_name,
               v.aliases,
               v.description,
               m.added_at
          FROM maludb_core.malu$active_memory_pool p
          JOIN maludb_core.malu$active_memory_pool_member m
            ON m.owner_schema = p.owner_schema
           AND m.pool_id = p.pool_id
           AND m.member_kind = 'verb'
           AND m.member_object_type = 'verb'
          JOIN maludb_core.malu$svpor_verb v
            ON v.owner_schema = p.owner_schema
           AND v.verb_id = m.member_object_id
         WHERE p.owner_schema = %L
    $sql$, p_schema, p_schema);
    EXECUTE format('GRANT SELECT ON %I.maludb_pool_verb TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_pool_verb', 'view', 'Schema-local pool verb read facade.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_pool_subject_verb', 'view');
    EXECUTE format($sql$
        CREATE OR REPLACE VIEW %I.maludb_pool_subject_verb WITH (security_invoker = true) AS
        SELECT p.pool_id,
               p.pool_name,
               m.member_id,
               m.confidence,
               c.compartment_id,
               c.namespace,
               s.subject_name,
               v.verb_name,
               c.embedding_dim,
               c.embedding_model,
               c.distance_metric,
               c.vector_count,
               c.search_mode,
               c.ann_index_status,
               m.added_at
          FROM maludb_core.malu$active_memory_pool p
          JOIN maludb_core.malu$active_memory_pool_member m
            ON m.owner_schema = p.owner_schema
           AND m.pool_id = p.pool_id
           AND m.member_kind = 'subject_verb'
           AND m.member_object_type = 'vector_compartment'
          JOIN maludb_core.malu$vector_compartment c
            ON c.owner_schema = p.owner_schema
           AND c.compartment_id = m.member_object_id
          JOIN maludb_core.malu$vector_subject s
            ON s.owner_schema = c.owner_schema
           AND s.namespace = c.namespace
           AND s.subject_id = c.subject_id
          JOIN maludb_core.malu$vector_verb v
            ON v.owner_schema = c.owner_schema
           AND v.namespace = c.namespace
           AND v.verb_id = c.verb_id
         WHERE p.owner_schema = %L
    $sql$, p_schema, p_schema);
    EXECUTE format('GRANT SELECT ON %I.maludb_pool_subject_verb TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_pool_subject_verb', 'view', 'Schema-local pool subject/verb read facade.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_pool_skill', 'view');
    EXECUTE format($sql$
        CREATE OR REPLACE VIEW %I.maludb_pool_skill WITH (security_invoker = true) AS
        SELECT p.pool_id,
               p.pool_name,
               m.member_id,
               m.confidence,
               s.skill_id,
               s.skill_name,
               s.version,
               s.description,
               s.packaging_kind,
               s.enabled,
               m.added_at
          FROM maludb_core.malu$active_memory_pool p
          JOIN maludb_core.malu$active_memory_pool_member m
            ON m.owner_schema = p.owner_schema
           AND m.pool_id = p.pool_id
           AND m.member_kind = 'skill'
           AND m.member_object_type = 'skill'
          JOIN maludb_core.malu$skill_package s
            ON s.owner_schema = p.owner_schema
           AND s.skill_id = m.member_object_id
         WHERE p.owner_schema = %L
    $sql$, p_schema, p_schema);
    EXECUTE format('GRANT SELECT ON %I.maludb_pool_skill TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_pool_skill', 'view', 'Schema-local pool skill read facade.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_pool_document', 'view');
    EXECUTE format($sql$
        CREATE OR REPLACE VIEW %I.maludb_pool_document WITH (security_invoker = true) AS
        SELECT p.pool_id,
               p.pool_name,
               m.member_id,
               m.confidence,
               d.document_id,
               d.source_package_id,
               d.title,
               d.source_type,
               d.media_type,
               d.primary_project_id,
               d.lifecycle_state,
               d.metadata_jsonb,
               m.added_at
          FROM maludb_core.malu$active_memory_pool p
          JOIN maludb_core.malu$active_memory_pool_member m
            ON m.owner_schema = p.owner_schema
           AND m.pool_id = p.pool_id
           AND m.member_kind = 'document'
           AND m.member_object_type = 'document'
          JOIN maludb_core.malu$document d
            ON d.owner_schema = p.owner_schema
           AND d.document_id = m.member_object_id
         WHERE p.owner_schema = %L
    $sql$, p_schema, p_schema);
    EXECUTE format('GRANT SELECT ON %I.maludb_pool_document TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_pool_document', 'view', 'Schema-local pool document read facade.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_pool_presence', 'view');
    EXECUTE format($sql$
        CREATE OR REPLACE VIEW %I.maludb_pool_presence WITH (security_invoker = true) AS
        SELECT p.pool_id,
               p.pool_name,
               pr.presence_id,
               pr.participant_kind,
               pr.participant_ref,
               pr.role,
               pr.declared_task,
               pr.cursor_jsonb,
               pr.last_seen_at,
               pr.left_at
          FROM maludb_core.malu$active_memory_pool p
          JOIN maludb_core.malu$pool_presence pr
            ON pr.owner_schema = p.owner_schema
           AND pr.pool_id = p.pool_id
         WHERE p.owner_schema = %L
    $sql$, p_schema, p_schema);
    EXECUTE format('GRANT SELECT ON %I.maludb_pool_presence TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_pool_presence', 'view', 'Schema-local pool presence read facade.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_pool_add_named_member', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_pool_add_named_member(
            p_pool_name text,
            p_member_kind text,
            p_member_name text,
            p_confidence numeric DEFAULT NULL
        ) RETURNS bigint
        LANGUAGE sql
        SECURITY INVOKER
        SET search_path = %I, maludb_core, pg_temp
        AS $facade$
            SELECT maludb_core.pool_add_named_member(
                p_pool_name,
                p_member_kind,
                p_member_name,
                p_confidence
            )
        $facade$
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_pool_add_named_member(text, text, text, numeric) FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_pool_add_named_member(text, text, text, numeric) TO maludb_memory_admin, maludb_memory_executor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_pool_add_named_member', 'function', 'Schema-local named pool member helper.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_pool_search', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_pool_search(
            p_pool_name text,
            p_query_text text DEFAULT NULL,
            p_limit integer DEFAULT 20,
            p_allow_fallback boolean DEFAULT false
        ) RETURNS TABLE (
            object_type text,
            object_id bigint,
            title_or_subject text,
            snippet text,
            rank real,
            source text
        )
        LANGUAGE sql
        STABLE
        SECURITY INVOKER
        SET search_path = %I, maludb_core, pg_temp
        AS $facade$
            SELECT *
            FROM maludb_core.pool_search(
                p_pool_name,
                p_query_text,
                p_limit,
                p_allow_fallback
            )
        $facade$
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_pool_search(text, text, integer, boolean) FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_pool_search(text, text, integer, boolean) TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_pool_search', 'function', 'Schema-local pool text search helper.');
    v_count := v_count + 1;

    RETURN v_count;
END;
$body$;

REVOKE ALL ON FUNCTION _enable_memory_schema_pool_facade(name) FROM PUBLIC;

CREATE FUNCTION _enable_memory_schema_ai_facade(p_schema name) RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
DECLARE
    v_count integer := 0;
BEGIN
    PERFORM maludb_core._memory_schema_assert_manageable(p_schema);

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_prompt', 'view');
    EXECUTE format($sql$
        CREATE OR REPLACE VIEW %I.maludb_prompt AS
        SELECT template_id,
               template_name,
               template_version,
               owner_account_id,
               body,
               system_template,
               developer_template,
               user_template,
               variables,
               enabled,
               created_at
          FROM maludb_core.malu$prompt_template
         WHERE owner_schema = %L
        WITH LOCAL CHECK OPTION
    $sql$, p_schema, p_schema);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON %I.maludb_prompt TO maludb_memory_admin, maludb_memory_executor', p_schema);
    EXECUTE format('GRANT SELECT ON %I.maludb_prompt TO maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_prompt', 'view', 'Schema-local prompt template facade.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_prompt_render', 'view');
    EXECUTE format($sql$
        CREATE OR REPLACE VIEW %I.maludb_prompt_render AS
        SELECT render_id,
               template_id,
               session_id,
               account_id,
               variables,
               rendered_prompt,
               prompt_hash,
               context_block_count,
               context_hash,
               created_at
          FROM maludb_core.malu$prompt_render
         WHERE owner_schema = %L
        WITH LOCAL CHECK OPTION
    $sql$, p_schema, p_schema);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON %I.maludb_prompt_render TO maludb_memory_admin, maludb_memory_executor', p_schema);
    EXECUTE format('GRANT SELECT ON %I.maludb_prompt_render TO maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_prompt_render', 'view', 'Schema-local prompt render facade.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_llm_provider', 'view');
    EXECUTE format($sql$
        CREATE OR REPLACE VIEW %I.maludb_llm_provider AS
        SELECT provider_id,
               provider_name,
               provider_kind,
               adapter_name,
               data_sensitivity,
               enabled,
               created_at
          FROM maludb_core.malu_provider_public
    $sql$, p_schema);
    EXECUTE format('GRANT SELECT ON %I.maludb_llm_provider TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_llm_provider', 'view', 'Schema-local public LLM provider facade.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_llm_model', 'view');
    EXECUTE format($sql$
        CREATE OR REPLACE VIEW %I.maludb_llm_model AS
        SELECT alias_id,
               alias_name,
               provider_id,
               model_identifier,
               model_path,
               model_hash,
               quantization,
               context_length,
               gpu_placement,
               runtime_params,
               license_metadata,
               enabled,
               created_at
          FROM maludb_core.malu$model_alias
         WHERE owner_schema = %L
        WITH LOCAL CHECK OPTION
    $sql$, p_schema, p_schema);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON %I.maludb_llm_model TO maludb_memory_admin, maludb_memory_executor', p_schema);
    EXECUTE format('GRANT SELECT ON %I.maludb_llm_model TO maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_llm_model', 'view', 'Schema-local LLM model alias facade.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_llm_request', 'view');
    EXECUTE format($sql$
        CREATE OR REPLACE VIEW %I.maludb_llm_request AS
        SELECT request_id,
               session_id,
               prompt_render_id,
               alias_id,
               account_id,
               rendered_prompt,
               prompt_hash,
               generation_params,
               timeout_ms,
               cancel_requested,
               status,
               submitted_at,
               started_at,
               finished_at
          FROM maludb_core.malu$model_request
         WHERE owner_schema = %L
        WITH LOCAL CHECK OPTION
    $sql$, p_schema, p_schema);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON %I.maludb_llm_request TO maludb_memory_admin, maludb_memory_executor', p_schema);
    EXECUTE format('GRANT SELECT ON %I.maludb_llm_request TO maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_llm_request', 'view', 'Schema-local LLM request facade.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_llm_response', 'view');
    EXECUTE format($sql$
        CREATE OR REPLACE VIEW %I.maludb_llm_response AS
        SELECT response_id,
               request_id,
               status,
               output_text,
               output_hash,
               output_json,
               tool_calls,
               finish_reason,
               raw_provider_response,
               prompt_tokens,
               completion_tokens,
               latency_ms,
               error_class,
               user_safe_error,
               adapter_name,
               finished_at
          FROM maludb_core.malu$model_response
         WHERE owner_schema = %L
        WITH LOCAL CHECK OPTION
    $sql$, p_schema, p_schema);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON %I.maludb_llm_response TO maludb_memory_admin, maludb_memory_executor', p_schema);
    EXECUTE format('GRANT SELECT ON %I.maludb_llm_response TO maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_llm_response', 'view', 'Schema-local LLM response facade.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_skill', 'view');
    EXECUTE format($sql$
        CREATE OR REPLACE VIEW %I.maludb_skill WITH (security_invoker = true) AS
        SELECT skill_id,
               skill_name,
               version,
               description,
               packaging_kind,
               applicability_jsonb,
               precondition_jsonb,
               enabled,
               created_at,
               updated_at
          FROM maludb_core.malu$skill_package
         WHERE owner_schema = %L
        WITH LOCAL CHECK OPTION
    $sql$, p_schema, p_schema);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON %I.maludb_skill TO maludb_memory_admin, maludb_memory_executor', p_schema);
    EXECUTE format('GRANT SELECT ON %I.maludb_skill TO maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_skill', 'view', 'Schema-local skill package facade.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_skill_state', 'view');
    EXECUTE format($sql$
        CREATE OR REPLACE VIEW %I.maludb_skill_state WITH (security_invoker = true) AS
        SELECT state_id,
               skill_id,
               state_name,
               state_kind,
               step_jsonb,
               validation_jsonb
          FROM maludb_core.malu$skill_state
         WHERE owner_schema = %L
        WITH LOCAL CHECK OPTION
    $sql$, p_schema, p_schema);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON %I.maludb_skill_state TO maludb_memory_admin, maludb_memory_executor', p_schema);
    EXECUTE format('GRANT SELECT ON %I.maludb_skill_state TO maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_skill_state', 'view', 'Schema-local skill state facade.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_skill_transition', 'view');
    EXECUTE format($sql$
        CREATE OR REPLACE VIEW %I.maludb_skill_transition WITH (security_invoker = true) AS
        SELECT transition_id,
               skill_id,
               from_state_id,
               to_state_id,
               on_outcome,
               guard_jsonb,
               ordinal
          FROM maludb_core.malu$skill_transition
         WHERE owner_schema = %L
        WITH LOCAL CHECK OPTION
    $sql$, p_schema, p_schema);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON %I.maludb_skill_transition TO maludb_memory_admin, maludb_memory_executor', p_schema);
    EXECUTE format('GRANT SELECT ON %I.maludb_skill_transition TO maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_skill_transition', 'view', 'Schema-local skill transition facade.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_skill_execution', 'view');
    EXECUTE format($sql$
        CREATE OR REPLACE VIEW %I.maludb_skill_execution WITH (security_invoker = true) AS
        SELECT execution_id,
               skill_id,
               account_id,
               actor_role,
               active_pool_id,
               task_objective,
               authorized_partitions,
               source_context_id,
               environment,
               technology_stack,
               bound_at,
               started_at,
               completed_at,
               current_state_id,
               final_outcome,
               step_count,
               emitted_claim_ids,
               audit_jsonb
          FROM maludb_core.malu$skill_execution_record
         WHERE owner_schema = %L
        WITH LOCAL CHECK OPTION
    $sql$, p_schema, p_schema);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE ON %I.maludb_skill_execution TO maludb_memory_admin, maludb_memory_executor', p_schema);
    EXECUTE format('GRANT SELECT ON %I.maludb_skill_execution TO maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_skill_execution', 'view', 'Schema-local skill execution facade.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_workflow_trace', 'view');
    EXECUTE format($sql$
        CREATE OR REPLACE VIEW %I.maludb_workflow_trace WITH (security_invoker = true) AS
        SELECT trace_id,
               episode_id,
               subject_class,
               action_class,
               outcome,
               environment,
               tool_stack,
               exception_pattern,
               confidence,
               step_count,
               positive_evidence,
               security_domain,
               payload_jsonb,
               extracted_at
          FROM maludb_core.malu$workflow_trace
         WHERE owner_schema = %L
        WITH LOCAL CHECK OPTION
    $sql$, p_schema, p_schema);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON %I.maludb_workflow_trace TO maludb_memory_admin, maludb_memory_executor', p_schema);
    EXECUTE format('GRANT SELECT ON %I.maludb_workflow_trace TO maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_workflow_trace', 'view', 'Schema-local workflow trace facade.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_workflow_step', 'view');
    EXECUTE format($sql$
        CREATE OR REPLACE VIEW %I.maludb_workflow_step WITH (security_invoker = true) AS
        SELECT step_id,
               trace_id,
               step_idx,
               action_class,
               subject,
               object_value,
               actor,
               tool,
               started_at,
               ended_at,
               outcome,
               evidence_source_id,
               evidence_mdo_id,
               exception_text,
               predecessor_step_id,
               caused_by_step_id,
               caused_by_evidence_source_id,
               payload_jsonb
          FROM maludb_core.malu$workflow_step
         WHERE owner_schema = %L
        WITH LOCAL CHECK OPTION
    $sql$, p_schema, p_schema);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON %I.maludb_workflow_step TO maludb_memory_admin, maludb_memory_executor', p_schema);
    EXECUTE format('GRANT SELECT ON %I.maludb_workflow_step TO maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_workflow_step', 'view', 'Schema-local workflow step facade.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_workflow_candidate', 'view');
    EXECUTE format($sql$
        CREATE OR REPLACE VIEW %I.maludb_workflow_candidate WITH (security_invoker = true) AS
        SELECT candidate_id,
               cluster_id,
               name,
               description,
               step_template,
               review_status,
               review_notes,
               reviewed_by,
               reviewed_at,
               provenance,
               positive_evidence_count,
               negative_evidence_count,
               created_at,
               updated_at
          FROM maludb_core.malu$workflow_candidate
         WHERE owner_schema = %L
        WITH LOCAL CHECK OPTION
    $sql$, p_schema, p_schema);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE ON %I.maludb_workflow_candidate TO maludb_memory_admin, maludb_memory_executor', p_schema);
    EXECUTE format('GRANT SELECT ON %I.maludb_workflow_candidate TO maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_workflow_candidate', 'view', 'Schema-local workflow candidate facade.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_mcp_server', 'view');
    EXECUTE format($sql$
        CREATE OR REPLACE VIEW %I.maludb_mcp_server WITH (security_invoker = true) AS
        SELECT server_id,
               server_name,
               title,
               description,
               protocol_versions,
               default_risk_class,
               enabled,
               created_at
          FROM maludb_core.malu$mc2db_server
         WHERE owner_schema = %L
        WITH LOCAL CHECK OPTION
    $sql$, p_schema, p_schema);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON %I.maludb_mcp_server TO maludb_memory_admin, maludb_memory_executor', p_schema);
    EXECUTE format('GRANT SELECT ON %I.maludb_mcp_server TO maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_mcp_server', 'view', 'Schema-local MCP server facade.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_mcp_tool', 'view');
    EXECUTE format($sql$
        CREATE OR REPLACE VIEW %I.maludb_mcp_tool WITH (security_invoker = true) AS
        SELECT tool_id,
               server_id,
               tool_name,
               title,
               description,
               implementation_type,
               input_schema,
               output_schema,
               risk_class,
               read_only,
               require_confirmation,
               timeout_ms,
               max_input_bytes,
               max_output_bytes,
               allow_network,
               required_privileges,
               enabled,
               created_at
          FROM maludb_core.malu$mc2db_tool
         WHERE owner_schema = %L
        WITH LOCAL CHECK OPTION
    $sql$, p_schema, p_schema);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON %I.maludb_mcp_tool TO maludb_memory_admin, maludb_memory_executor', p_schema);
    EXECUTE format('GRANT SELECT ON %I.maludb_mcp_tool TO maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_mcp_tool', 'view', 'Schema-local MCP tool facade.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_mcp_prompt', 'view');
    EXECUTE format($sql$
        CREATE OR REPLACE VIEW %I.maludb_mcp_prompt WITH (security_invoker = true) AS
        SELECT prompt_id,
               server_id,
               prompt_name,
               title,
               description,
               input_schema,
               function_signature,
               enabled,
               created_at
          FROM maludb_core.malu$mc2db_prompt
         WHERE owner_schema = %L
        WITH LOCAL CHECK OPTION
    $sql$, p_schema, p_schema);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON %I.maludb_mcp_prompt TO maludb_memory_admin, maludb_memory_executor', p_schema);
    EXECUTE format('GRANT SELECT ON %I.maludb_mcp_prompt TO maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_mcp_prompt', 'view', 'Schema-local MCP prompt facade.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_mcp_resource', 'view');
    EXECUTE format($sql$
        CREATE OR REPLACE VIEW %I.maludb_mcp_resource WITH (security_invoker = true) AS
        SELECT resource_id,
               server_id,
               uri_template,
               title,
               description,
               mime_type,
               function_signature,
               enabled,
               created_at
          FROM maludb_core.malu$mc2db_resource
         WHERE owner_schema = %L
        WITH LOCAL CHECK OPTION
    $sql$, p_schema, p_schema);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON %I.maludb_mcp_resource TO maludb_memory_admin, maludb_memory_executor', p_schema);
    EXECUTE format('GRANT SELECT ON %I.maludb_mcp_resource TO maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_mcp_resource', 'view', 'Schema-local MCP resource facade.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_mcp_invocation', 'view');
    EXECUTE format($sql$
        CREATE OR REPLACE VIEW %I.maludb_mcp_invocation WITH (security_invoker = true) AS
        SELECT call_id,
               tool_id,
               tool_name,
               implementation_type,
               request_user,
               database_role,
               input_hash,
               output_hash,
               success,
               error_code,
               error_message,
               external_exit_code,
               external_stderr,
               started_at,
               finished_at,
               duration_ms
          FROM maludb_core.malu$mc2db_invocation
         WHERE owner_schema = %L
    $sql$, p_schema, p_schema);
    EXECUTE format('GRANT SELECT ON %I.maludb_mcp_invocation TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_mcp_invocation', 'view', 'Schema-local MCP invocation audit facade.');
    v_count := v_count + 1;

    RETURN v_count;
END;
$body$;

REVOKE ALL ON FUNCTION _enable_memory_schema_ai_facade(name) FROM PUBLIC;

CREATE FUNCTION enable_memory_schema(p_schema name DEFAULT current_schema())
RETURNS TABLE(schema_name name, enabled_version text, object_count integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
DECLARE
    v_count integer := 0;
BEGIN
    PERFORM maludb_core._memory_schema_assert_manageable(p_schema);

    INSERT INTO maludb_core.malu$enabled_schema(schema_name, enabled_version, enabled_by)
    VALUES (p_schema, '0.72.0', session_user)
    ON CONFLICT ON CONSTRAINT malu$enabled_schema_pkey DO UPDATE
       SET enabled_version   = EXCLUDED.enabled_version,
           last_refreshed_at = now();

    v_count := v_count + maludb_core._enable_memory_schema_subject_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_core_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_ingest_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_pool_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_ai_facade(p_schema);

    schema_name := p_schema;
    enabled_version := '0.72.0';
    object_count := v_count;
    RETURN NEXT;
END;
$body$;

REVOKE ALL ON FUNCTION enable_memory_schema(name) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION enable_memory_schema(name) TO maludb_memory_admin, maludb_memory_executor;
