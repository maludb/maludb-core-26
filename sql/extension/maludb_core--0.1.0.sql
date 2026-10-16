\echo Use "CREATE EXTENSION maludb_core" to load this file. \quit

-- =====================================================================
-- maludb_core 0.1.0 — Release 1.0 Stage 1 substrate
--
-- Lays down the maludb_core schema, catalog scaffolding, the vector
-- demonstration table, and the stage-boundary assertion helper. The
-- governed memory object model (sources, claims, facts, episodes,
-- memories, MDOs, derivation ledger) belongs to Stage 2+ and MUST NOT
-- ship from this script.
-- =====================================================================

-- The extension's schema is created automatically because the control
-- file declares schema = 'maludb_core' on a non-relocatable extension.
-- Object names follow the malu$<name> convention from CLAUDE.md.

-- ---------------------------------------------------------------------
-- Version metadata
-- ---------------------------------------------------------------------
CREATE FUNCTION maludb_core_version() RETURNS text
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$ SELECT '0.1.0'::text $body$;

CREATE FUNCTION maludb_core_release() RETURNS text
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$ SELECT 'R1.0 Stage 1 substrate'::text $body$;

-- ---------------------------------------------------------------------
-- Identity and partitioning scaffolding
-- ---------------------------------------------------------------------
CREATE TABLE malu$account (
    account_id   bigserial PRIMARY KEY,
    account_name text NOT NULL UNIQUE,
    account_kind text NOT NULL
        CHECK (account_kind IN
              ('human','service','agent','application',
               'mcp_client','mc2db_client','local_node','admin')),
    enabled      boolean NOT NULL DEFAULT true,
    description  text,
    created_at   timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE malu$role (
    role_id     bigserial PRIMARY KEY,
    role_name   text NOT NULL UNIQUE,
    description text,
    created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE malu$account_role (
    account_id bigint NOT NULL REFERENCES malu$account(account_id) ON DELETE CASCADE,
    role_id    bigint NOT NULL REFERENCES malu$role(role_id)       ON DELETE CASCADE,
    granted_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (account_id, role_id)
);

CREATE TABLE malu$partition (
    partition_id    bigserial PRIMARY KEY,
    partition_name  text NOT NULL UNIQUE,
    security_domain text,
    description     text,
    created_at      timestamptz NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------
-- Type registries (Tier-A placeholders; Stage 2+ seeds the real types)
--
-- The `stage` column lets the boundary check identify any rows that
-- would imply Stage N+1 features are active.
-- ---------------------------------------------------------------------
CREATE TABLE malu$object_type (
    object_type text PRIMARY KEY,
    stage       smallint NOT NULL,
    description text
);

CREATE TABLE malu$relationship_type (
    relationship_type text PRIMARY KEY,
    stage             smallint NOT NULL,
    description       text,
    inverse_of        text REFERENCES malu$relationship_type(relationship_type)
);

CREATE TABLE malu$source_type (
    source_type text PRIMARY KEY,
    stage       smallint NOT NULL,
    description text
);

-- ---------------------------------------------------------------------
-- Model gateway scaffolding (Stage 1.5 fills in real seeding)
-- ---------------------------------------------------------------------
CREATE TABLE malu$model_provider (
    provider_id       bigserial PRIMARY KEY,
    provider_name     text NOT NULL UNIQUE,
    provider_kind     text NOT NULL CHECK (provider_kind IN
        ('cloud_api','local_http','local_socket','local_runtime',
         'shell_adapter','stub')),
    adapter_name      text,
    secret_ref        text,
    data_sensitivity  text,
    enabled           boolean NOT NULL DEFAULT true,
    created_at        timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE malu$model_alias (
    alias_id          bigserial PRIMARY KEY,
    alias_name        text NOT NULL UNIQUE,
    provider_id       bigint NOT NULL REFERENCES malu$model_provider(provider_id) ON DELETE RESTRICT,
    model_identifier  text NOT NULL,
    model_path        text,
    model_hash        text,
    quantization      text,
    context_length    integer,
    gpu_placement     text,
    runtime_params    jsonb,
    license_metadata  jsonb,
    enabled           boolean NOT NULL DEFAULT true,
    created_at        timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE malu$prompt_template (
    template_id         bigserial PRIMARY KEY,
    template_name       text NOT NULL,
    template_version    integer NOT NULL DEFAULT 1,
    owner_account_id    bigint REFERENCES malu$account(account_id) ON DELETE SET NULL,
    body                text NOT NULL,
    system_template     text,
    developer_template  text,
    user_template       text,
    variables           jsonb,
    enabled             boolean NOT NULL DEFAULT true,
    created_at          timestamptz NOT NULL DEFAULT now(),
    UNIQUE (template_name, template_version)
);

CREATE TABLE malu$session (
    session_id          bigserial PRIMARY KEY,
    account_id          bigint NOT NULL REFERENCES malu$account(account_id),
    model_alias_id      bigint REFERENCES malu$model_alias(alias_id),
    prompt_template_id  bigint REFERENCES malu$prompt_template(template_id),
    lifecycle_state     text NOT NULL DEFAULT 'open'
        CHECK (lifecycle_state IN ('open','closed','errored')),
    token_budget        integer,
    created_at          timestamptz NOT NULL DEFAULT now(),
    closed_at           timestamptz
);

-- ---------------------------------------------------------------------
-- Session Context (Phase R1.0-4)
--
-- Short-term ordered context blocks bound to one session. Each block
-- carries a content hash so prompt-render output is reproducible from
-- the same template+variables+context. Session Context is NOT long-term
-- memory and MUST NOT promote to facts/claims/memories without going
-- through Stage 2+ promotion paths (which do not exist in R1.0).
-- ---------------------------------------------------------------------
CREATE TABLE malu$session_context (
    context_id      bigserial PRIMARY KEY,
    session_id      bigint NOT NULL REFERENCES malu$session(session_id) ON DELETE CASCADE,
    ordinal         integer NOT NULL CHECK (ordinal > 0),
    role            text,
    content_text    text,
    content_jsonb   jsonb,
    content_hash    text NOT NULL,
    source_label    text,
    sensitivity     text NOT NULL DEFAULT 'internal'
        CHECK (sensitivity IN ('public','internal','restricted','prohibited')),
    token_estimate  integer,
    created_at      timestamptz NOT NULL DEFAULT now(),
    UNIQUE (session_id, ordinal),
    CHECK (content_text IS NOT NULL OR content_jsonb IS NOT NULL)
);

-- ---------------------------------------------------------------------
-- Prompt render artifact (Phase R1.0-4)
--
-- One row per render_prompt() call. Captures the literal rendered text,
-- a SHA256 of that text, the variables used, and a hash chain of
-- context blocks consumed. Replaying the same template + variables +
-- context state MUST produce the same prompt_hash; that property is
-- what the test suite enforces.
-- ---------------------------------------------------------------------
CREATE TABLE malu$prompt_render (
    render_id            bigserial PRIMARY KEY,
    template_id          bigint NOT NULL REFERENCES malu$prompt_template(template_id) ON DELETE RESTRICT,
    session_id           bigint REFERENCES malu$session(session_id) ON DELETE CASCADE,
    account_id           bigint REFERENCES malu$account(account_id) ON DELETE SET NULL,
    variables            jsonb NOT NULL DEFAULT '{}'::jsonb,
    rendered_prompt      text NOT NULL,
    prompt_hash          text NOT NULL,
    context_block_count  integer NOT NULL DEFAULT 0,
    context_hash         text,
    created_at           timestamptz NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------
-- Model request / response (Phase R1.0-3)
--
-- Local and cloud models share this request/response shape. The
-- maludb_modeld service contract polls pending rows and writes responses
-- back; the deterministic stub adapter (mc_stub_process) does the same
-- thing in-database for tests. prompt_render_id is now a real FK to
-- malu$prompt_render (added in R1.0-4); rendered_prompt is still carried
-- inline so the R1.0-3 literal-prompt path keeps working.
-- ---------------------------------------------------------------------
CREATE TABLE malu$model_request (
    request_id         bigserial PRIMARY KEY,
    session_id         bigint REFERENCES malu$session(session_id) ON DELETE SET NULL,
    prompt_render_id   bigint REFERENCES malu$prompt_render(render_id) ON DELETE SET NULL,
    alias_id           bigint NOT NULL REFERENCES malu$model_alias(alias_id) ON DELETE RESTRICT,
    account_id         bigint REFERENCES malu$account(account_id) ON DELETE SET NULL,
    rendered_prompt    text NOT NULL,
    prompt_hash        text NOT NULL,
    generation_params  jsonb NOT NULL DEFAULT '{}'::jsonb,
    timeout_ms         integer NOT NULL DEFAULT 30000
        CHECK (timeout_ms > 0),
    cancel_requested   boolean NOT NULL DEFAULT false,
    status             text NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending','running','succeeded','failed','cancelled','timeout')),
    submitted_at       timestamptz NOT NULL DEFAULT now(),
    started_at         timestamptz,
    finished_at        timestamptz
);

CREATE INDEX malu$model_request_status_idx
    ON malu$model_request (status, submitted_at)
    WHERE status IN ('pending','running');

CREATE TABLE malu$model_response (
    response_id            bigserial PRIMARY KEY,
    request_id             bigint NOT NULL UNIQUE
        REFERENCES malu$model_request(request_id) ON DELETE CASCADE,
    status                 text NOT NULL
        CHECK (status IN ('succeeded','failed','cancelled','timeout')),
    output_text            text,
    output_hash            text,
    output_json            jsonb,
    tool_calls             jsonb,
    finish_reason          text,
    raw_provider_response  jsonb,
    prompt_tokens          integer,
    completion_tokens      integer,
    latency_ms             integer,
    error_class            text,
    user_safe_error        text,
    adapter_name           text NOT NULL,
    finished_at            timestamptz NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------
-- MC2DB listener configuration (Stage 1.6 fills in tools/profiles)
-- ---------------------------------------------------------------------
CREATE TABLE malu$listener_config (
    listener_id              bigserial PRIMARY KEY,
    listener_name            text NOT NULL UNIQUE,
    bind_host                text NOT NULL DEFAULT '127.0.0.1',
    bind_port                integer NOT NULL DEFAULT 5329,
    tls_enabled              boolean NOT NULL DEFAULT false,
    tls_cert_path            text,
    tls_key_path             text,
    mc2db_protocol_versions  text[] NOT NULL DEFAULT ARRAY['2025-11-25'],
    default_risk_class       text NOT NULL DEFAULT 'read_only',
    default_timeout_ms       integer NOT NULL DEFAULT 30000,
    default_max_input_bytes  integer NOT NULL DEFAULT 262144,
    default_max_output_bytes integer NOT NULL DEFAULT 1048576,
    enabled                  boolean NOT NULL DEFAULT true,
    created_at               timestamptz NOT NULL DEFAULT now(),
    CHECK (bind_port > 0 AND bind_port < 65536),
    CHECK (default_risk_class IN
        ('read_only','evidence_producing','state_changing','external_effect','administrative'))
);

-- ---------------------------------------------------------------------
-- MC2DB catalog (Phase R1.0-6)
--
-- Database-native MCP-compatible registry. Server profiles group tools,
-- prompts, and resources. Every tool row carries an implementation_type
-- so the listener's dispatcher is polymorphic from day one. R1.0
-- dispatches sql_function only; external_exec, mcp_proxy, and
-- http_endpoint registrations are catalog-modeled now and dispatch
-- in R1.1 with no schema migration. Per-type metadata lives in
-- companion tables so the parent stays normalized.
--
-- See: release-1.0-requirements.md §9 (and §9.1 for the external-tool
-- I/O contract), mc2db-white-paper.md §5.2 / §6 / §7.
-- ---------------------------------------------------------------------

CREATE TABLE malu$mc2db_server (
    server_id          bigserial PRIMARY KEY,
    server_name        text NOT NULL UNIQUE,
    title              text,
    description        text,
    protocol_versions  text[] NOT NULL DEFAULT ARRAY['2025-11-25'],
    default_risk_class text NOT NULL DEFAULT 'read_only',
    enabled            boolean NOT NULL DEFAULT true,
    created_at         timestamptz NOT NULL DEFAULT now(),
    CHECK (default_risk_class IN
        ('read_only','evidence_producing','state_changing','external_effect','administrative'))
);

CREATE TABLE malu$mc2db_tool (
    tool_id              bigserial PRIMARY KEY,
    server_id            bigint NOT NULL REFERENCES malu$mc2db_server(server_id) ON DELETE CASCADE,
    tool_name            text NOT NULL,
    title                text,
    description          text NOT NULL,
    implementation_type  text NOT NULL,
    input_schema         jsonb NOT NULL DEFAULT '{}'::jsonb,
    output_schema        jsonb,
    risk_class           text NOT NULL DEFAULT 'read_only',
    read_only            boolean NOT NULL DEFAULT true,
    require_confirmation boolean NOT NULL DEFAULT false,
    timeout_ms           integer NOT NULL DEFAULT 10000,
    max_input_bytes      integer NOT NULL DEFAULT 262144,
    max_output_bytes     integer NOT NULL DEFAULT 1048576,
    allow_network        boolean NOT NULL DEFAULT false,
    required_privileges  text[] NOT NULL DEFAULT ARRAY[]::text[],
    enabled              boolean NOT NULL DEFAULT true,
    created_at           timestamptz NOT NULL DEFAULT now(),
    UNIQUE (server_id, tool_name),
    CHECK (implementation_type IN
        ('sql_function','external_exec','mcp_proxy','http_endpoint')),
    CHECK (risk_class IN
        ('read_only','evidence_producing','state_changing','external_effect','administrative')),
    CHECK (timeout_ms > 0),
    CHECK (max_input_bytes > 0),
    CHECK (max_output_bytes > 0)
);

CREATE TABLE malu$mc2db_tool_sql_function (
    tool_id            bigint PRIMARY KEY REFERENCES malu$mc2db_tool(tool_id) ON DELETE CASCADE,
    function_signature regprocedure NOT NULL,
    transaction_mode   text NOT NULL DEFAULT 'read_committed',
    set_role_name      name,
    pinned_search_path text NOT NULL DEFAULT 'maludb_core, pg_catalog',
    CHECK (transaction_mode IN ('read_committed','repeatable_read','serializable'))
);

CREATE TABLE malu$mc2db_tool_external_exec (
    tool_id        bigint PRIMARY KEY REFERENCES malu$mc2db_tool(tool_id) ON DELETE CASCADE,
    command_path   text NOT NULL,
    argv_template  jsonb NOT NULL DEFAULT '[]'::jsonb,
    working_dir    text,
    run_as_user    text,
    input_mode     text NOT NULL DEFAULT 'stdin_json',
    output_mode    text NOT NULL DEFAULT 'stdout_json',
    environment    jsonb NOT NULL DEFAULT '{}'::jsonb,
    CHECK (command_path LIKE '/%'),
    CHECK (input_mode IN ('stdin_json','argv_json','env_json')),
    CHECK (output_mode IN ('stdout_json'))
);

CREATE TABLE malu$mc2db_tool_mcp_proxy (
    tool_id            bigint PRIMARY KEY REFERENCES malu$mc2db_tool(tool_id) ON DELETE CASCADE,
    remote_server_name text NOT NULL,
    remote_tool_name   text NOT NULL,
    transport_type     text NOT NULL,
    endpoint_url       text,
    command_path       text,
    argv               jsonb NOT NULL DEFAULT '[]'::jsonb,
    CHECK (transport_type IN ('stdio','http')),
    CHECK (
        (transport_type = 'http'  AND endpoint_url IS NOT NULL) OR
        (transport_type = 'stdio' AND command_path IS NOT NULL)
    )
);

CREATE TABLE malu$mc2db_tool_http_endpoint (
    tool_id  bigint PRIMARY KEY REFERENCES malu$mc2db_tool(tool_id) ON DELETE CASCADE
);

CREATE TABLE malu$mc2db_prompt (
    prompt_id          bigserial PRIMARY KEY,
    server_id          bigint NOT NULL REFERENCES malu$mc2db_server(server_id) ON DELETE CASCADE,
    prompt_name        text NOT NULL,
    title              text,
    description        text,
    input_schema       jsonb,
    function_signature regprocedure,
    enabled            boolean NOT NULL DEFAULT true,
    created_at         timestamptz NOT NULL DEFAULT now(),
    UNIQUE (server_id, prompt_name)
);

CREATE TABLE malu$mc2db_resource (
    resource_id        bigserial PRIMARY KEY,
    server_id          bigint NOT NULL REFERENCES malu$mc2db_server(server_id) ON DELETE CASCADE,
    uri_template       text NOT NULL,
    title              text,
    description        text,
    mime_type          text NOT NULL DEFAULT 'application/json',
    function_signature regprocedure,
    enabled            boolean NOT NULL DEFAULT true,
    created_at         timestamptz NOT NULL DEFAULT now(),
    UNIQUE (server_id, uri_template)
);

CREATE TABLE malu$mc2db_invocation (
    call_id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tool_id              bigint REFERENCES malu$mc2db_tool(tool_id) ON DELETE SET NULL,
    tool_name            text NOT NULL,
    implementation_type  text NOT NULL,
    request_user         text,
    database_role        name,
    input_hash           bytea,
    output_hash          bytea,
    success              boolean NOT NULL,
    error_code           text,
    error_message        text,
    external_exit_code   integer,
    external_stderr      text,
    started_at           timestamptz NOT NULL DEFAULT now(),
    finished_at          timestamptz,
    duration_ms          integer
);

CREATE INDEX malu$mc2db_invocation_tool_idx
    ON malu$mc2db_invocation(tool_id, started_at DESC);

-- ---------------------------------------------------------------------
-- Vector demonstration table — proves pgvector is wired through the
-- maludb_core install path. Small dimension on purpose; this is not a
-- production embedding column.
-- ---------------------------------------------------------------------
CREATE TABLE malu$vector_demo (
    demo_id    bigserial PRIMARY KEY,
    label      text NOT NULL,
    embedding  vector(8) NOT NULL,
    payload    jsonb,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX malu$vector_demo_embedding_hnsw
    ON malu$vector_demo
    USING hnsw (embedding vector_cosine_ops);

-- ---------------------------------------------------------------------
-- Stage boundary assertion
--
-- Returns one row per Stage 2+ governed-object table that has slipped
-- into the maludb_core schema. Stage 1 builds and tests MUST keep this
-- result set empty.
-- ---------------------------------------------------------------------
CREATE FUNCTION stage_boundary_violations()
RETURNS TABLE(object_kind text, object_name text, stage smallint)
LANGUAGE sql STABLE
AS $body$
    WITH forbidden(name, stage) AS (
        VALUES
            ('malu$source_package'::text,        2::smallint),
            ('malu$source_reference',            2),
            ('malu$claim',                       2),
            ('malu$fact',                        2),
            ('malu$episode_object',              2),
            ('malu$memory',                      2),
            ('malu$memory_detail_object',        2),
            ('malu$relationship_edge',           2),
            ('malu$derivation_ledger',           2),
            ('malu$governed_object',             2),
            ('malu$verbatim_archive',            2),
            ('malu$valid_time_window',           3),
            ('malu$transaction_time_window',     3),
            ('malu$supersession_edge',           3),
            ('malu$svpor_subject',               3),
            ('malu$svpor_verb',                  3),
            ('malu$svpor_predicate',             3),
            ('malu$maut_score',                  3),
            ('malu$workflow_trace',              5),
            ('malu$generalized_workflow',        5),
            ('malu$procedural_memory_object',    5),
            ('malu$skill_package',               5),
            ('malu$competency_package',          5),
            ('malu$active_memory_pool',          5),
            ('malu$episode_replay',              5),
            ('malu$local_memory_node',           6),
            ('malu$node_sync_record',            6)
    )
    SELECT 'table'::text, c.relname::text, f.stage
    FROM pg_catalog.pg_class c
    JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
    JOIN forbidden f ON f.name = c.relname
    WHERE n.nspname = 'maludb_core'
      AND c.relkind IN ('r','p','v','m')
    ORDER BY f.stage, c.relname;
$body$;

-- ---------------------------------------------------------------------
-- Type registry seeds — name only the type, plus the stage at which it
-- becomes a real, populated catalog. Stage 1 readers can introspect
-- the roadmap; Stage 2+ install scripts replace the placeholders.
-- ---------------------------------------------------------------------
INSERT INTO malu$object_type(object_type, stage, description) VALUES
    ('account',              1, 'Identity for human, service, agent, application, MCP/MC2DB client, or local node.'),
    ('partition',            1, 'Project, security domain, or retention partition.'),
    ('model_provider',       1, 'Local, cloud, or stub model provider registry entry.'),
    ('model_alias',          1, 'Named model with provider-side identifier and runtime metadata.'),
    ('prompt_template',      1, 'Versioned prompt template stored in PostgreSQL.'),
    ('session',              1, 'Governed model session bound to an account and model alias.'),
    ('listener_config',      1, 'MC2DB listener bind/TLS configuration.'),
    ('source_package',       2, 'Stage 2 placeholder. Verbatim source ingestion artifact.'),
    ('claim',                2, 'Stage 2 placeholder. Extracted assertion with source references.'),
    ('fact',                 2, 'Stage 2 placeholder. Verified claim accepted within a defined scope.'),
    ('episode_object',       2, 'Stage 2 placeholder. Specific remembered episode.'),
    ('memory',               2, 'Stage 2 placeholder. Contextual memory record.'),
    ('memory_detail_object', 2, 'Stage 2 placeholder. Recursively addressable memory detail.'),
    ('workflow_trace',       5, 'Stage 5 placeholder. Observed step sequence for one episode.'),
    ('generalized_workflow', 5, 'Stage 5 placeholder. Repeatable process pattern.'),
    ('skill_package',        5, 'Stage 5 placeholder. Governed procedural-memory bundle.'),
    ('active_memory_pool',   5, 'Stage 5 placeholder. Scoped working set for a task.'),
    ('local_memory_node',    6, 'Stage 6 placeholder. Offline/edge subset.'),
    ('model_request',        1, 'Pending/running/finished request to a model alias.'),
    ('model_response',       1, 'Recorded model output for a model_request.'),
    ('session_context',      1, 'Ordered short-term context block bound to a session.'),
    ('prompt_render',        1, 'Rendered-prompt artifact with hash chain over context.'),
    ('mc2db_server',         1, 'MC2DB server profile grouping tools, prompts, and resources.'),
    ('mc2db_tool',           1, 'MC2DB tool registry row with implementation_type polymorphism.'),
    ('mc2db_prompt',         1, 'MC2DB prompt definition exposed via tool discovery.'),
    ('mc2db_resource',       1, 'MC2DB resource definition exposed via tool discovery.'),
    ('mc2db_invocation',     1, 'MC2DB tool call audit row.');

INSERT INTO malu$relationship_type(relationship_type, stage, description) VALUES
    ('supports',     2, 'Stage 2 placeholder. Object A supports object B (claim/fact/memory).'),
    ('contradicts',  2, 'Stage 2 placeholder. Object A contradicts object B.'),
    ('supersedes',   3, 'Stage 3 placeholder. Bitemporal supersession edge.'),
    ('derived_from', 2, 'Stage 2 placeholder. Object A was derived from object B.'),
    ('verified_by',  2, 'Stage 2 placeholder. Object A was verified by actor/process B.'),
    ('caused_by',    3, 'Stage 3 placeholder. Causal edge — requires evidence beyond ordering.'),
    ('depends_on',   2, 'Stage 2 placeholder. Object A depends on object B.'),
    ('part_of',      2, 'Stage 2 placeholder. Object A is part of object B.'),
    ('has_detail',   2, 'Stage 2 placeholder. Object A has memory-detail object B.'),
    ('related_to',   2, 'Stage 2 placeholder. Generic relationship.');

INSERT INTO malu$source_type(source_type, stage, description) VALUES
    ('document',        2, 'Stage 2 placeholder. Document source (PDF, DOCX, Markdown, etc.).'),
    ('conversation',    2, 'Stage 2 placeholder. Chat/transcript/meeting source.'),
    ('ticket',          2, 'Stage 2 placeholder. Ticketing system record.'),
    ('log',             2, 'Stage 2 placeholder. System or application log entry.'),
    ('database_record', 2, 'Stage 2 placeholder. Row from an external system of record.'),
    ('api_payload',     2, 'Stage 2 placeholder. API request/response capture.'),
    ('source_control',  2, 'Stage 2 placeholder. Commit, PR, or repository event.'),
    ('observability',   2, 'Stage 2 placeholder. Metric, trace, or span.'),
    ('event_stream',    2, 'Stage 2 placeholder. Time-series or event-stream record.');

-- =====================================================================
-- Model gateway API surface (Phase R1.0-3)
--
-- Stable SQL functions that the Stage 1.5 maludb_modeld service and the
-- in-database stub adapter both target. Callers should not write to the
-- request/response tables directly; these functions own the status
-- transitions and audit-relevant fields.
-- =====================================================================

CREATE FUNCTION register_model_provider(
    p_name             text,
    p_kind             text,
    p_adapter_name     text DEFAULT NULL,
    p_secret_ref       text DEFAULT NULL,
    p_data_sensitivity text DEFAULT 'internal'
) RETURNS bigint
LANGUAGE plpgsql
AS $body$
DECLARE
    v_id bigint;
BEGIN
    IF p_kind NOT IN ('cloud_api','local_http','local_socket','local_runtime',
                      'shell_adapter','stub') THEN
        RAISE EXCEPTION
          'invalid provider kind: % (expected one of cloud_api, local_http, local_socket, local_runtime, shell_adapter, stub)',
          p_kind
            USING ERRCODE = 'check_violation';
    END IF;
    INSERT INTO malu$model_provider
           (provider_name, provider_kind, adapter_name, secret_ref, data_sensitivity)
    VALUES (p_name,        p_kind,        p_adapter_name, p_secret_ref, p_data_sensitivity)
    RETURNING provider_id INTO v_id;
    RETURN v_id;
END;
$body$;

CREATE FUNCTION register_model_alias(
    p_alias            text,
    p_provider         text,
    p_model_identifier text,
    p_model_path       text DEFAULT NULL,
    p_model_hash       text DEFAULT NULL,
    p_quantization     text DEFAULT NULL,
    p_context_length   integer DEFAULT NULL,
    p_runtime_params   jsonb DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql
AS $body$
DECLARE
    v_provider_id bigint;
    v_alias_id    bigint;
BEGIN
    SELECT provider_id INTO v_provider_id
    FROM malu$model_provider
    WHERE provider_name = p_provider;
    IF v_provider_id IS NULL THEN
        RAISE EXCEPTION 'unknown provider: %', p_provider
            USING ERRCODE = 'foreign_key_violation';
    END IF;
    INSERT INTO malu$model_alias
           (alias_name, provider_id, model_identifier,
            model_path, model_hash, quantization, context_length, runtime_params)
    VALUES (p_alias,    v_provider_id, p_model_identifier,
            p_model_path, p_model_hash, p_quantization, p_context_length, p_runtime_params)
    RETURNING alias_id INTO v_alias_id;
    RETURN v_alias_id;
END;
$body$;

CREATE FUNCTION submit_request(
    p_alias_name        text,
    p_rendered_prompt   text,
    p_account_name      text DEFAULT NULL,
    p_session_id        bigint DEFAULT NULL,
    p_generation_params jsonb DEFAULT '{}'::jsonb,
    p_timeout_ms        integer DEFAULT 30000
) RETURNS bigint
LANGUAGE plpgsql
AS $body$
DECLARE
    v_alias_id   bigint;
    v_account_id bigint;
    v_request_id bigint;
    v_hash       text;
BEGIN
    SELECT alias_id INTO v_alias_id
    FROM malu$model_alias
    WHERE alias_name = p_alias_name
      AND enabled = true;
    IF v_alias_id IS NULL THEN
        RAISE EXCEPTION 'unknown or disabled alias: %', p_alias_name
            USING ERRCODE = 'foreign_key_violation';
    END IF;

    IF p_account_name IS NOT NULL THEN
        SELECT account_id INTO v_account_id
        FROM malu$account
        WHERE account_name = p_account_name;
        IF v_account_id IS NULL THEN
            RAISE EXCEPTION 'unknown account: %', p_account_name
                USING ERRCODE = 'foreign_key_violation';
        END IF;
    END IF;

    v_hash := encode(sha256(p_rendered_prompt::bytea), 'hex');

    INSERT INTO malu$model_request
           (alias_id, account_id, session_id, rendered_prompt, prompt_hash,
            generation_params, timeout_ms)
    VALUES (v_alias_id, v_account_id, p_session_id, p_rendered_prompt, v_hash,
            COALESCE(p_generation_params, '{}'::jsonb), p_timeout_ms)
    RETURNING request_id INTO v_request_id;

    RETURN v_request_id;
END;
$body$;

CREATE FUNCTION request_status(p_request_id bigint)
RETURNS text
LANGUAGE sql STABLE
AS $body$
    SELECT status FROM malu$model_request WHERE request_id = p_request_id;
$body$;

CREATE FUNCTION cancel_request(p_request_id bigint)
RETURNS text
LANGUAGE plpgsql
AS $body$
DECLARE
    v_status text;
BEGIN
    UPDATE malu$model_request
       SET cancel_requested = true,
           status = CASE WHEN status = 'pending' THEN 'cancelled' ELSE status END,
           finished_at = CASE WHEN status = 'pending' THEN now() ELSE finished_at END
     WHERE request_id = p_request_id
    RETURNING status INTO v_status;
    IF v_status IS NULL THEN
        RAISE EXCEPTION 'unknown request: %', p_request_id
            USING ERRCODE = 'no_data_found';
    END IF;
    RETURN v_status;
END;
$body$;

CREATE FUNCTION get_response(p_request_id bigint)
RETURNS TABLE (
    response_id        bigint,
    request_id         bigint,
    status             text,
    output_text        text,
    output_hash        text,
    prompt_tokens      integer,
    completion_tokens  integer,
    latency_ms         integer,
    error_class        text,
    user_safe_error    text,
    adapter_name       text,
    finished_at        timestamptz
)
LANGUAGE sql STABLE
AS $body$
    SELECT response_id, request_id, status, output_text, output_hash,
           prompt_tokens, completion_tokens, latency_ms,
           error_class, user_safe_error, adapter_name, finished_at
    FROM malu$model_response
    WHERE request_id = p_request_id;
$body$;

-- ---------------------------------------------------------------------
-- Deterministic stub adapter (Phase R1.0-3)
--
-- Drives status transitions pending → running → succeeded and writes a
-- response row whose output is exactly 'MALUDB_STUB_REPLY:' || prompt_hash.
-- This is the in-database equivalent of what maludb_modeld will do for
-- providers of kind 'stub'; tests use it to exercise the contract without
-- a real model runtime.
-- ---------------------------------------------------------------------
CREATE FUNCTION mc_stub_process(p_request_id bigint)
RETURNS bigint
LANGUAGE plpgsql
AS $body$
DECLARE
    v_req         malu$model_request%ROWTYPE;
    v_output      text;
    v_output_hash text;
    v_response_id bigint;
BEGIN
    SELECT * INTO v_req FROM malu$model_request WHERE request_id = p_request_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'unknown request: %', p_request_id
            USING ERRCODE = 'no_data_found';
    END IF;

    SELECT response_id INTO v_response_id
    FROM malu$model_response WHERE request_id = p_request_id;
    IF v_response_id IS NOT NULL THEN
        RETURN v_response_id;
    END IF;

    IF v_req.cancel_requested THEN
        UPDATE malu$model_request
           SET status = 'cancelled', finished_at = COALESCE(finished_at, now())
         WHERE request_id = p_request_id;
        INSERT INTO malu$model_response
               (request_id, status, adapter_name, error_class, user_safe_error)
        VALUES (p_request_id, 'cancelled', 'stub', 'cancelled',
                'request cancelled before stub adapter ran')
        RETURNING response_id INTO v_response_id;
        RETURN v_response_id;
    END IF;

    IF v_req.status <> 'pending' THEN
        RAISE EXCEPTION 'request % is not pending (status=%)', p_request_id, v_req.status
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    UPDATE malu$model_request
       SET status = 'running', started_at = now()
     WHERE request_id = p_request_id;

    v_output      := 'MALUDB_STUB_REPLY:' || v_req.prompt_hash;
    v_output_hash := encode(sha256(v_output::bytea), 'hex');

    INSERT INTO malu$model_response
           (request_id, status, output_text, output_hash, finish_reason,
            prompt_tokens, completion_tokens, latency_ms, adapter_name)
    VALUES (p_request_id, 'succeeded', v_output, v_output_hash, 'stop',
            (length(v_req.rendered_prompt) + 3) / 4,
            (length(v_output) + 3) / 4,
            0, 'stub')
    RETURNING response_id INTO v_response_id;

    UPDATE malu$model_request
       SET status = 'succeeded', finished_at = now()
     WHERE request_id = p_request_id;

    RETURN v_response_id;
END;
$body$;

-- ---------------------------------------------------------------------
-- Provider-secret hygiene
--
-- model_provider_public exposes provider rows without secret_ref so
-- ordinary callers can list providers without the gateway's secret
-- references leaking through user-facing reads. The view explicitly
-- excludes secret_ref by column list rather than by row-policy so the
-- column is unreachable, not just filtered.
-- ---------------------------------------------------------------------
CREATE VIEW model_provider_public AS
    SELECT provider_id, provider_name, provider_kind, adapter_name,
           data_sensitivity, enabled, created_at
    FROM malu$model_provider;

-- =====================================================================
-- Session, context, template, and prompt-render APIs (Phase R1.0-4)
--
-- These functions own the lifecycle of:
--   - prompt templates (versioned)
--   - sessions (account-bound, optionally pinned to a model alias and template)
--   - session context (ordered, hashed, append/read/clear)
--   - prompt renders (deterministic substitution + context hash chain)
--   - submit-via-render (ties prompt_render rows to model_request rows)
-- =====================================================================

CREATE FUNCTION register_prompt_template(
    p_name                text,
    p_body                text,
    p_owner_account       text DEFAULT NULL,
    p_variables           jsonb DEFAULT NULL,
    p_version             integer DEFAULT NULL,
    p_system_template     text DEFAULT NULL,
    p_developer_template  text DEFAULT NULL,
    p_user_template       text DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql
AS $body$
DECLARE
    v_owner_id bigint;
    v_version  integer;
    v_id       bigint;
BEGIN
    IF p_owner_account IS NOT NULL THEN
        SELECT account_id INTO v_owner_id
        FROM malu$account WHERE account_name = p_owner_account;
        IF v_owner_id IS NULL THEN
            RAISE EXCEPTION 'unknown account: %', p_owner_account
                USING ERRCODE = 'foreign_key_violation';
        END IF;
    END IF;

    IF p_version IS NULL THEN
        SELECT COALESCE(MAX(template_version), 0) + 1 INTO v_version
        FROM malu$prompt_template WHERE template_name = p_name;
    ELSE
        v_version := p_version;
    END IF;

    INSERT INTO malu$prompt_template
           (template_name, template_version, owner_account_id, body,
            system_template, developer_template, user_template, variables)
    VALUES (p_name, v_version, v_owner_id, p_body,
            p_system_template, p_developer_template, p_user_template, p_variables)
    RETURNING template_id INTO v_id;
    RETURN v_id;
END;
$body$;

CREATE FUNCTION start_session(
    p_account_name      text,
    p_alias_name        text DEFAULT NULL,
    p_template_name     text DEFAULT NULL,
    p_template_version  integer DEFAULT NULL,
    p_token_budget      integer DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql
AS $body$
DECLARE
    v_account_id  bigint;
    v_alias_id    bigint;
    v_template_id bigint;
    v_session_id  bigint;
BEGIN
    SELECT account_id INTO v_account_id
    FROM malu$account WHERE account_name = p_account_name;
    IF v_account_id IS NULL THEN
        RAISE EXCEPTION 'unknown account: %', p_account_name
            USING ERRCODE = 'foreign_key_violation';
    END IF;

    IF p_alias_name IS NOT NULL THEN
        SELECT alias_id INTO v_alias_id
        FROM malu$model_alias
        WHERE alias_name = p_alias_name AND enabled = true;
        IF v_alias_id IS NULL THEN
            RAISE EXCEPTION 'unknown or disabled alias: %', p_alias_name
                USING ERRCODE = 'foreign_key_violation';
        END IF;
    END IF;

    IF p_template_name IS NOT NULL THEN
        IF p_template_version IS NULL THEN
            SELECT template_id INTO v_template_id
            FROM malu$prompt_template
            WHERE template_name = p_template_name AND enabled = true
            ORDER BY template_version DESC
            LIMIT 1;
        ELSE
            SELECT template_id INTO v_template_id
            FROM malu$prompt_template
            WHERE template_name = p_template_name
              AND template_version = p_template_version;
        END IF;
        IF v_template_id IS NULL THEN
            RAISE EXCEPTION 'unknown prompt template: % (version %)',
                p_template_name, COALESCE(p_template_version::text, 'latest')
                USING ERRCODE = 'foreign_key_violation';
        END IF;
    END IF;

    INSERT INTO malu$session
           (account_id, model_alias_id, prompt_template_id, token_budget)
    VALUES (v_account_id, v_alias_id, v_template_id, p_token_budget)
    RETURNING session_id INTO v_session_id;
    RETURN v_session_id;
END;
$body$;

CREATE FUNCTION close_session(
    p_session_id bigint,
    p_state      text DEFAULT 'closed'
) RETURNS text
LANGUAGE plpgsql
AS $body$
DECLARE
    v_status text;
BEGIN
    IF p_state NOT IN ('closed','errored') THEN
        RAISE EXCEPTION 'invalid close state: % (expected closed or errored)', p_state
            USING ERRCODE = 'check_violation';
    END IF;
    UPDATE malu$session
       SET lifecycle_state = p_state,
           closed_at       = COALESCE(closed_at, now())
     WHERE session_id = p_session_id
    RETURNING lifecycle_state INTO v_status;
    IF v_status IS NULL THEN
        RAISE EXCEPTION 'unknown session: %', p_session_id
            USING ERRCODE = 'no_data_found';
    END IF;
    RETURN v_status;
END;
$body$;

CREATE FUNCTION append_context(
    p_session_id     bigint,
    p_role           text DEFAULT NULL,
    p_content_text   text DEFAULT NULL,
    p_content_jsonb  jsonb DEFAULT NULL,
    p_source_label   text DEFAULT NULL,
    p_sensitivity    text DEFAULT 'internal',
    p_token_estimate integer DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql
AS $body$
DECLARE
    v_ordinal   integer;
    v_canonical text;
    v_hash      text;
    v_id        bigint;
BEGIN
    IF p_content_text IS NULL AND p_content_jsonb IS NULL THEN
        RAISE EXCEPTION 'append_context requires p_content_text or p_content_jsonb'
            USING ERRCODE = 'check_violation';
    END IF;

    PERFORM 1 FROM malu$session WHERE session_id = p_session_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'unknown session: %', p_session_id
            USING ERRCODE = 'no_data_found';
    END IF;

    SELECT COALESCE(MAX(ordinal), 0) + 1 INTO v_ordinal
    FROM malu$session_context WHERE session_id = p_session_id;

    v_canonical := COALESCE(p_role, '') || '|' ||
                   COALESCE(p_content_text, p_content_jsonb::text);
    v_hash := encode(sha256(v_canonical::bytea), 'hex');

    INSERT INTO malu$session_context
           (session_id, ordinal, role, content_text, content_jsonb,
            content_hash, source_label, sensitivity, token_estimate)
    VALUES (p_session_id, v_ordinal, p_role, p_content_text, p_content_jsonb,
            v_hash, p_source_label, p_sensitivity, p_token_estimate)
    RETURNING context_id INTO v_id;
    RETURN v_id;
END;
$body$;

CREATE FUNCTION read_context(p_session_id bigint)
RETURNS TABLE (
    context_id     bigint,
    ordinal        integer,
    role           text,
    content_text   text,
    content_jsonb  jsonb,
    content_hash   text,
    source_label   text,
    sensitivity    text,
    token_estimate integer,
    created_at     timestamptz
)
LANGUAGE sql STABLE
AS $body$
    SELECT context_id, ordinal, role, content_text, content_jsonb,
           content_hash, source_label, sensitivity, token_estimate, created_at
    FROM malu$session_context
    WHERE session_id = p_session_id
    ORDER BY ordinal;
$body$;

CREATE FUNCTION clear_context(p_session_id bigint) RETURNS integer
LANGUAGE plpgsql
AS $body$
DECLARE
    v_count integer;
BEGIN
    DELETE FROM malu$session_context WHERE session_id = p_session_id;
    GET DIAGNOSTICS v_count = ROW_COUNT;
    RETURN v_count;
END;
$body$;

-- ---------------------------------------------------------------------
-- render_prompt: deterministic substitution + ordered context append
--
-- Variables are substituted in alphabetical key order. The template can
-- reference variables using either {{<name>}} (Jinja-style) or :<name>
-- (psql-style, terminated by a non-word character). Both syntaxes
-- resolve from the same variables jsonb and produce identical
-- prompt_hash for equivalent input. R1.0-6.5 widened render_prompt to
-- handle both syntaxes plus the three-channel template format
-- (system_template / developer_template / user_template); when any
-- channel column is non-null the channels are rendered as the base
-- text, otherwise the legacy body column is used.
-- ---------------------------------------------------------------------

-- _render_compose: build the base text from a malu$prompt_template row.
-- Returns the channel-composed text when any channel is non-null; falls
-- back to body otherwise. Pure function — no side effects.
CREATE FUNCTION _render_compose(p_template malu$prompt_template) RETURNS text
LANGUAGE sql IMMUTABLE
AS $body$
    SELECT CASE
        WHEN p_template.system_template IS NOT NULL
          OR p_template.developer_template IS NOT NULL
          OR p_template.user_template IS NOT NULL THEN
            concat_ws(E'\n\n',
                CASE WHEN p_template.system_template IS NOT NULL
                     THEN 'SYSTEM:'    || E'\n' || p_template.system_template END,
                CASE WHEN p_template.developer_template IS NOT NULL
                     THEN 'DEVELOPER:' || E'\n' || p_template.developer_template END,
                CASE WHEN p_template.user_template IS NOT NULL
                     THEN 'USER:'      || E'\n' || p_template.user_template END)
        ELSE p_template.body
    END;
$body$;

-- _render_substitute: apply {{var}} and :var substitution to text.
-- Variables are applied in alphabetical key order; both syntaxes use
-- the same value for a given key.
CREATE FUNCTION _render_substitute(p_text text, p_variables jsonb) RETURNS text
LANGUAGE plpgsql IMMUTABLE
AS $body$
DECLARE
    v_text text := p_text;
    v_var  record;
BEGIN
    FOR v_var IN
        SELECT key, value
        FROM jsonb_each_text(COALESCE(p_variables, '{}'::jsonb))
        ORDER BY key
    LOOP
        v_text := replace(v_text, '{{' || v_var.key || '}}', v_var.value);
        v_text := regexp_replace(
            v_text,
            ':' || regexp_replace(v_var.key, '([\\.^$*+?()\[\]{}|])', '\\\1', 'g') || '\M',
            replace(v_var.value, '\', '\\'),
            'g');
    END LOOP;
    RETURN v_text;
END;
$body$;

-- _render_core: full rendering pipeline returning the rendered text,
-- prompt hash, context info, and the resolved template id. Pure
-- function — no INSERT. Used by both render_prompt and preview_prompt.
CREATE FUNCTION _render_core(
    p_session_id        bigint,
    p_template_name     text,
    p_template_version  integer,
    p_variables         jsonb,
    OUT template_id          bigint,
    OUT rendered_prompt      text,
    OUT prompt_hash          text,
    OUT context_hash         text,
    OUT context_block_count  integer
)
LANGUAGE plpgsql
AS $body$
DECLARE
    v_template      malu$prompt_template%ROWTYPE;
    v_body          text;
    v_context_text  text;
BEGIN
    PERFORM 1 FROM malu$session WHERE session_id = p_session_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'unknown session: %', p_session_id
            USING ERRCODE = 'no_data_found';
    END IF;

    IF p_template_version IS NULL THEN
        SELECT * INTO v_template
        FROM malu$prompt_template
        WHERE template_name = p_template_name AND enabled = true
        ORDER BY template_version DESC
        LIMIT 1;
    ELSE
        SELECT * INTO v_template
        FROM malu$prompt_template
        WHERE template_name = p_template_name
          AND template_version = p_template_version;
    END IF;
    IF v_template.template_id IS NULL THEN
        RAISE EXCEPTION 'unknown prompt template: % (version %)',
            p_template_name, COALESCE(p_template_version::text, 'latest')
            USING ERRCODE = 'no_data_found';
    END IF;

    v_body := _render_substitute(_render_compose(v_template),
                                 COALESCE(p_variables, '{}'::jsonb));

    SELECT
        string_agg(
            COALESCE(role, '') || ': ' ||
            COALESCE(content_text, content_jsonb::text),
            E'\n'
            ORDER BY ordinal
        ),
        encode(sha256(string_agg(content_hash, '|' ORDER BY ordinal)::bytea), 'hex'),
        count(*)::integer
    INTO v_context_text, context_hash, context_block_count
    FROM malu$session_context
    WHERE session_id = p_session_id;

    rendered_prompt := v_body || COALESCE(E'\n\n' || v_context_text, '');
    prompt_hash     := encode(sha256(rendered_prompt::bytea), 'hex');
    template_id     := v_template.template_id;
    context_block_count := COALESCE(context_block_count, 0);
END;
$body$;

-- preview_prompt: dry-run companion. Same inputs as render_prompt;
-- returns the rendered text + hashes WITHOUT inserting a row.
CREATE FUNCTION preview_prompt(
    p_session_id        bigint,
    p_template_name     text,
    p_template_version  integer DEFAULT NULL,
    p_variables         jsonb DEFAULT '{}'::jsonb
) RETURNS TABLE(
    rendered_prompt      text,
    prompt_hash          text,
    context_hash         text,
    context_block_count  integer
)
LANGUAGE plpgsql
AS $body$
DECLARE
    v_core record;
BEGIN
    SELECT * INTO v_core FROM _render_core(p_session_id, p_template_name,
                                           p_template_version, p_variables);
    rendered_prompt     := v_core.rendered_prompt;
    prompt_hash         := v_core.prompt_hash;
    context_hash        := v_core.context_hash;
    context_block_count := v_core.context_block_count;
    RETURN NEXT;
END;
$body$;

CREATE FUNCTION render_prompt(
    p_session_id        bigint,
    p_template_name     text,
    p_template_version  integer DEFAULT NULL,
    p_variables         jsonb DEFAULT '{}'::jsonb
) RETURNS bigint
LANGUAGE plpgsql
AS $body$
DECLARE
    v_core       record;
    v_account_id bigint;
    v_render_id  bigint;
BEGIN
    SELECT * INTO v_core FROM _render_core(p_session_id, p_template_name,
                                           p_template_version, p_variables);

    SELECT account_id INTO v_account_id
    FROM malu$session WHERE session_id = p_session_id;

    INSERT INTO malu$prompt_render
           (template_id, session_id, account_id, variables,
            rendered_prompt, prompt_hash, context_block_count, context_hash)
    VALUES (v_core.template_id, p_session_id, v_account_id,
            COALESCE(p_variables, '{}'::jsonb),
            v_core.rendered_prompt, v_core.prompt_hash,
            v_core.context_block_count, v_core.context_hash)
    RETURNING render_id INTO v_render_id;
    RETURN v_render_id;
END;
$body$;

-- ---------------------------------------------------------------------
-- submit_render: tie a malu$prompt_render to a malu$model_request.
--
-- This is the front-door path for R1.0-5 and beyond. The R1.0-3
-- literal-prompt path (submit_request) keeps working unchanged.
-- ---------------------------------------------------------------------
CREATE FUNCTION submit_render(
    p_render_id         bigint,
    p_alias_name        text,
    p_account_name      text DEFAULT NULL,
    p_generation_params jsonb DEFAULT '{}'::jsonb,
    p_timeout_ms        integer DEFAULT 30000
) RETURNS bigint
LANGUAGE plpgsql
AS $body$
DECLARE
    v_render     malu$prompt_render%ROWTYPE;
    v_alias_id   bigint;
    v_account_id bigint;
    v_request_id bigint;
BEGIN
    SELECT * INTO v_render
    FROM malu$prompt_render WHERE render_id = p_render_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'unknown render: %', p_render_id
            USING ERRCODE = 'no_data_found';
    END IF;

    SELECT alias_id INTO v_alias_id
    FROM malu$model_alias
    WHERE alias_name = p_alias_name AND enabled = true;
    IF v_alias_id IS NULL THEN
        RAISE EXCEPTION 'unknown or disabled alias: %', p_alias_name
            USING ERRCODE = 'foreign_key_violation';
    END IF;

    IF p_account_name IS NOT NULL THEN
        SELECT account_id INTO v_account_id
        FROM malu$account WHERE account_name = p_account_name;
        IF v_account_id IS NULL THEN
            RAISE EXCEPTION 'unknown account: %', p_account_name
                USING ERRCODE = 'foreign_key_violation';
        END IF;
    END IF;

    INSERT INTO malu$model_request
           (alias_id, account_id, session_id, prompt_render_id,
            rendered_prompt, prompt_hash,
            generation_params, timeout_ms)
    VALUES (v_alias_id,
            COALESCE(v_account_id, v_render.account_id),
            v_render.session_id, p_render_id,
            v_render.rendered_prompt, v_render.prompt_hash,
            COALESCE(p_generation_params, '{}'::jsonb), p_timeout_ms)
    RETURNING request_id INTO v_request_id;
    RETURN v_request_id;
END;
$body$;

-- =====================================================================
-- model_run_audit (Phase R1.0-5)
--
-- One row per prompt_render, joined to its session, account, template,
-- request, response, and adapter. Reconstructs the full execution
-- record for any render in a single SELECT — the foundation that
-- R1.0-6 MC2DB audit tools build on.
-- =====================================================================
CREATE VIEW model_run_audit AS
SELECT
    pr.render_id,
    pr.session_id,
    s.lifecycle_state         AS session_state,
    s.created_at              AS session_started_at,
    s.closed_at               AS session_closed_at,
    s.account_id,
    a.account_name,
    pr.template_id,
    pt.template_name,
    pt.template_version,
    pr.variables              AS render_variables,
    pr.prompt_hash,
    pr.context_hash,
    pr.context_block_count,
    pr.created_at             AS rendered_at,
    mr.request_id,
    mr.alias_id,
    ma.alias_name,
    mp.provider_kind,
    mp.provider_name,
    mr.status                 AS request_status,
    mr.cancel_requested,
    mr.submitted_at,
    mr.started_at,
    mr.finished_at            AS request_finished_at,
    mres.response_id,
    mres.status               AS response_status,
    mres.output_hash,
    mres.finish_reason,
    mres.adapter_name,
    mres.prompt_tokens,
    mres.completion_tokens,
    mres.latency_ms,
    mres.error_class,
    mres.user_safe_error,
    mres.finished_at          AS response_finished_at
FROM malu$prompt_render pr
LEFT JOIN malu$session         s    ON s.session_id    = pr.session_id
LEFT JOIN malu$account         a    ON a.account_id    = s.account_id
LEFT JOIN malu$prompt_template pt   ON pt.template_id  = pr.template_id
LEFT JOIN malu$model_request   mr   ON mr.prompt_render_id = pr.render_id
LEFT JOIN malu$model_alias     ma   ON ma.alias_id     = mr.alias_id
LEFT JOIN malu$model_provider  mp   ON mp.provider_id  = ma.provider_id
LEFT JOIN malu$model_response  mres ON mres.request_id = mr.request_id;

-- =====================================================================
-- run_session_step (Phase R1.0-5)
--
-- One-call convenience: render_prompt + submit_render + (synchronous
-- stub processing when the alias resolves to a provider of kind 'stub').
-- For local/cloud providers, response_id is returned NULL and the
-- maludb_modeld service writes the response asynchronously.
-- =====================================================================
CREATE FUNCTION run_session_step(
    p_session_id        bigint,
    p_template_name     text,
    p_alias_name        text,
    p_variables         jsonb DEFAULT '{}'::jsonb,
    p_template_version  integer DEFAULT NULL,
    p_account_name      text DEFAULT NULL,
    p_generation_params jsonb DEFAULT '{}'::jsonb,
    p_timeout_ms        integer DEFAULT 30000
) RETURNS TABLE (
    render_id   bigint,
    request_id  bigint,
    response_id bigint
)
LANGUAGE plpgsql
AS $body$
DECLARE
    v_render_id     bigint;
    v_request_id    bigint;
    v_response_id   bigint;
    v_provider_kind text;
BEGIN
    v_render_id := render_prompt(p_session_id, p_template_name,
                                  p_template_version, p_variables);

    v_request_id := submit_render(v_render_id, p_alias_name,
                                   p_account_name, p_generation_params,
                                   p_timeout_ms);

    SELECT mp.provider_kind INTO v_provider_kind
    FROM malu$model_alias ma
    JOIN malu$model_provider mp ON mp.provider_id = ma.provider_id
    WHERE ma.alias_name = p_alias_name;

    IF v_provider_kind = 'stub' THEN
        v_response_id := mc_stub_process(v_request_id);
    ELSE
        v_response_id := NULL;
    END IF;

    render_id   := v_render_id;
    request_id  := v_request_id;
    response_id := v_response_id;
    RETURN NEXT;
END;
$body$;

-- =====================================================================
-- MC2DB schema (Phase R1.0-6)
--
-- Public API surface for MC2DB. Catalog and audit live in maludb_core
-- under the malu$mc2db_* prefix; user-facing functions and the active
-- response context live in the mc2db schema. Separation keeps the
-- registration APIs independently grantable from the rest of the
-- maludb_core surface.
--
-- Active response context:
--   The listener calls mc2db._begin_request(...) before dispatching a
--   tool, which inserts a row into the session-local mc2db._active_request
--   table (created on demand). The tool's body calls mc2db.put_object,
--   put_text, or put_error to push payload into that row. The listener
--   calls mc2db._end_request() to read and clear. Calling any put_*
--   without an active row raises MC2DB_NO_ACTIVE_REQUEST so ordinary
--   SQL sessions cannot pretend to push data to MCP clients.
-- =====================================================================

CREATE SCHEMA mc2db;

GRANT USAGE ON SCHEMA mc2db TO PUBLIC;

-- ---------------------------------------------------------------------
-- _ensure_active_table — creates the session-local single-row holder.
-- Listener and tests call this before _begin_request. ON COMMIT PRESERVE
-- ROWS so the row spans statements within one transaction; the temp
-- table itself disappears at session end.
-- ---------------------------------------------------------------------
CREATE FUNCTION mc2db._ensure_active_table() RETURNS void
LANGUAGE plpgsql
AS $body$
BEGIN
    IF to_regclass('pg_temp.mc2db_active_request') IS NULL THEN
        CREATE TEMP TABLE mc2db_active_request (
            call_id     uuid PRIMARY KEY,
            tool_name   text NOT NULL,
            payload     jsonb,
            text_blocks jsonb NOT NULL DEFAULT '[]'::jsonb,
            error_code  text,
            error_msg   text,
            started_at  timestamptz NOT NULL DEFAULT now()
        ) ON COMMIT PRESERVE ROWS;
    END IF;
END;
$body$;

CREATE FUNCTION mc2db._begin_request(p_call_id uuid, p_tool_name text)
RETURNS void
LANGUAGE plpgsql
AS $body$
BEGIN
    PERFORM mc2db._ensure_active_table();
    IF EXISTS (SELECT 1 FROM pg_temp.mc2db_active_request) THEN
        RAISE EXCEPTION 'MC2DB_REQUEST_ALREADY_ACTIVE: an MC2DB request is already in progress in this session';
    END IF;
    INSERT INTO pg_temp.mc2db_active_request(call_id, tool_name)
    VALUES (p_call_id, p_tool_name);
END;
$body$;

CREATE FUNCTION mc2db._end_request()
RETURNS TABLE(call_id uuid, tool_name text, payload jsonb,
              text_blocks jsonb, error_code text, error_msg text)
LANGUAGE plpgsql
AS $body$
BEGIN
    PERFORM mc2db._ensure_active_table();
    RETURN QUERY
        SELECT r.call_id, r.tool_name, r.payload, r.text_blocks,
               r.error_code, r.error_msg
        FROM pg_temp.mc2db_active_request r;
    DELETE FROM pg_temp.mc2db_active_request;
END;
$body$;

CREATE FUNCTION mc2db._require_active() RETURNS void
LANGUAGE plpgsql
AS $body$
BEGIN
    PERFORM mc2db._ensure_active_table();
    IF NOT EXISTS (SELECT 1 FROM pg_temp.mc2db_active_request) THEN
        RAISE EXCEPTION 'MC2DB_NO_ACTIVE_REQUEST: mc2db.put_* may only be called inside an active MC2DB request context';
    END IF;
END;
$body$;

CREATE PROCEDURE mc2db.put_object(payload jsonb)
LANGUAGE plpgsql
AS $body$
BEGIN
    PERFORM mc2db._require_active();
    UPDATE pg_temp.mc2db_active_request
       SET payload = put_object.payload;
END;
$body$;

CREATE PROCEDURE mc2db.put_text(text_value text, annotations jsonb DEFAULT '{}'::jsonb)
LANGUAGE plpgsql
AS $body$
BEGIN
    PERFORM mc2db._require_active();
    UPDATE pg_temp.mc2db_active_request
       SET text_blocks = text_blocks || jsonb_build_array(
           jsonb_build_object('type', 'text',
                              'text', text_value,
                              'annotations', COALESCE(annotations, '{}'::jsonb)));
END;
$body$;

CREATE PROCEDURE mc2db.put_error(message text, details jsonb DEFAULT '{}'::jsonb)
LANGUAGE plpgsql
AS $body$
DECLARE
    v_code text;
BEGIN
    PERFORM mc2db._require_active();
    v_code := COALESCE(details->>'code', 'TOOL_ERROR');
    UPDATE pg_temp.mc2db_active_request
       SET error_code = v_code,
           error_msg  = message,
           payload    = jsonb_build_object(
               'isError', true,
               'content', jsonb_build_array(
                   jsonb_build_object('type', 'text', 'text', message)),
               'structuredContent', jsonb_build_object(
                   'error', jsonb_build_object(
                       'code', v_code,
                       'message', message,
                       'details', details)));
END;
$body$;

CREATE PROCEDURE mc2db.flush()
LANGUAGE plpgsql
AS $body$
BEGIN
    PERFORM mc2db._require_active();
    -- R1.0: streaming is not implemented; flush is a no-op that still
    -- enforces the active-context rule. R1.1 listeners may hook this
    -- to drain partial results to the wire.
END;
$body$;

-- =====================================================================
-- Registration APIs (Phase R1.0-6)
-- =====================================================================

CREATE FUNCTION mc2db.create_server(
    name              text,
    title             text DEFAULT NULL,
    description       text DEFAULT NULL,
    protocol_versions text[] DEFAULT ARRAY['2025-11-25'],
    default_risk_class text DEFAULT 'read_only'
) RETURNS bigint
LANGUAGE plpgsql
AS $body$
DECLARE
    v_server_id bigint;
BEGIN
    INSERT INTO maludb_core.malu$mc2db_server(
        server_name, title, description, protocol_versions, default_risk_class)
    VALUES (name, title, description, protocol_versions, default_risk_class)
    RETURNING server_id INTO v_server_id;
    RETURN v_server_id;
END;
$body$;

CREATE FUNCTION mc2db.register_tool(
    server_name          text,
    tool_name            text,
    description          text,
    implementation_type  text,
    input_schema         jsonb DEFAULT '{}'::jsonb,
    output_schema        jsonb DEFAULT NULL,
    title                text DEFAULT NULL,
    risk_class           text DEFAULT 'read_only',
    read_only            boolean DEFAULT true,
    require_confirmation boolean DEFAULT false,
    timeout_ms           integer DEFAULT 10000,
    max_input_bytes      integer DEFAULT 262144,
    max_output_bytes     integer DEFAULT 1048576,
    allow_network        boolean DEFAULT false,
    required_privileges  text[] DEFAULT ARRAY[]::text[],
    impl_metadata        jsonb DEFAULT '{}'::jsonb
) RETURNS bigint
LANGUAGE plpgsql
AS $body$
DECLARE
    v_server_id bigint;
    v_tool_id   bigint;
    v_keys      text[];
    v_allowed   text[];
BEGIN
    SELECT server_id INTO v_server_id
      FROM maludb_core.malu$mc2db_server
     WHERE malu$mc2db_server.server_name = register_tool.server_name;
    IF v_server_id IS NULL THEN
        RAISE EXCEPTION 'MC2DB_SERVER_NOT_FOUND: %', server_name;
    END IF;

    IF implementation_type NOT IN
       ('sql_function','external_exec','mcp_proxy','http_endpoint') THEN
        RAISE EXCEPTION 'MC2DB_BAD_IMPL_TYPE: %', implementation_type;
    END IF;

    v_keys := ARRAY(SELECT jsonb_object_keys(impl_metadata));

    v_allowed := CASE implementation_type
        WHEN 'sql_function'  THEN ARRAY['function_signature','transaction_mode',
                                        'set_role_name','pinned_search_path']
        WHEN 'external_exec' THEN ARRAY['command_path','argv_template','working_dir',
                                        'run_as_user','input_mode','output_mode',
                                        'environment']
        WHEN 'mcp_proxy'     THEN ARRAY['remote_server_name','remote_tool_name',
                                        'transport_type','endpoint_url',
                                        'command_path','argv']
        WHEN 'http_endpoint' THEN ARRAY[]::text[]
    END;

    IF EXISTS (
        SELECT 1 FROM unnest(v_keys) k
        WHERE k <> ALL (v_allowed)
    ) THEN
        RAISE EXCEPTION
          'MC2DB_IMPL_METADATA_MISMATCH: implementation_type=% does not accept keys %',
          implementation_type,
          (SELECT array_agg(k) FROM unnest(v_keys) k WHERE k <> ALL (v_allowed));
    END IF;

    INSERT INTO maludb_core.malu$mc2db_tool(
        server_id, tool_name, title, description, implementation_type,
        input_schema, output_schema, risk_class, read_only,
        require_confirmation, timeout_ms, max_input_bytes,
        max_output_bytes, allow_network, required_privileges)
    VALUES (
        v_server_id, tool_name, title, description, implementation_type,
        input_schema, output_schema, risk_class, read_only,
        require_confirmation, timeout_ms, max_input_bytes,
        max_output_bytes, allow_network, required_privileges)
    RETURNING tool_id INTO v_tool_id;

    IF implementation_type = 'sql_function' THEN
        IF impl_metadata ? 'function_signature' = false THEN
            RAISE EXCEPTION
              'MC2DB_IMPL_METADATA_MISSING: sql_function requires function_signature';
        END IF;
        INSERT INTO maludb_core.malu$mc2db_tool_sql_function(
            tool_id, function_signature, transaction_mode,
            set_role_name, pinned_search_path)
        VALUES (
            v_tool_id,
            (impl_metadata->>'function_signature')::regprocedure,
            COALESCE(impl_metadata->>'transaction_mode', 'read_committed'),
            NULLIF(impl_metadata->>'set_role_name','')::name,
            COALESCE(impl_metadata->>'pinned_search_path','maludb_core, pg_catalog'));

    ELSIF implementation_type = 'external_exec' THEN
        IF impl_metadata ? 'command_path' = false THEN
            RAISE EXCEPTION
              'MC2DB_IMPL_METADATA_MISSING: external_exec requires command_path';
        END IF;
        INSERT INTO maludb_core.malu$mc2db_tool_external_exec(
            tool_id, command_path, argv_template, working_dir,
            run_as_user, input_mode, output_mode, environment)
        VALUES (
            v_tool_id,
            impl_metadata->>'command_path',
            COALESCE(impl_metadata->'argv_template','[]'::jsonb),
            impl_metadata->>'working_dir',
            impl_metadata->>'run_as_user',
            COALESCE(impl_metadata->>'input_mode','stdin_json'),
            COALESCE(impl_metadata->>'output_mode','stdout_json'),
            COALESCE(impl_metadata->'environment','{}'::jsonb));

    ELSIF implementation_type = 'mcp_proxy' THEN
        IF impl_metadata ? 'remote_server_name' = false
           OR impl_metadata ? 'remote_tool_name' = false
           OR impl_metadata ? 'transport_type'   = false THEN
            RAISE EXCEPTION
              'MC2DB_IMPL_METADATA_MISSING: mcp_proxy requires remote_server_name, remote_tool_name, transport_type';
        END IF;
        INSERT INTO maludb_core.malu$mc2db_tool_mcp_proxy(
            tool_id, remote_server_name, remote_tool_name, transport_type,
            endpoint_url, command_path, argv)
        VALUES (
            v_tool_id,
            impl_metadata->>'remote_server_name',
            impl_metadata->>'remote_tool_name',
            impl_metadata->>'transport_type',
            impl_metadata->>'endpoint_url',
            impl_metadata->>'command_path',
            COALESCE(impl_metadata->'argv','[]'::jsonb));

    ELSIF implementation_type = 'http_endpoint' THEN
        INSERT INTO maludb_core.malu$mc2db_tool_http_endpoint(tool_id)
        VALUES (v_tool_id);
    END IF;

    RETURN v_tool_id;
END;
$body$;

CREATE FUNCTION mc2db.register_prompt(
    server_name        text,
    prompt_name        text,
    description        text DEFAULT NULL,
    title              text DEFAULT NULL,
    input_schema       jsonb DEFAULT NULL,
    function_signature text DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql
AS $body$
DECLARE
    v_server_id bigint;
    v_prompt_id bigint;
BEGIN
    SELECT server_id INTO v_server_id
      FROM maludb_core.malu$mc2db_server
     WHERE malu$mc2db_server.server_name = register_prompt.server_name;
    IF v_server_id IS NULL THEN
        RAISE EXCEPTION 'MC2DB_SERVER_NOT_FOUND: %', server_name;
    END IF;
    INSERT INTO maludb_core.malu$mc2db_prompt(
        server_id, prompt_name, title, description, input_schema, function_signature)
    VALUES (
        v_server_id, prompt_name, title, description, input_schema,
        NULLIF(function_signature,'')::regprocedure)
    RETURNING prompt_id INTO v_prompt_id;
    RETURN v_prompt_id;
END;
$body$;

CREATE FUNCTION mc2db.register_resource(
    server_name        text,
    uri_template       text,
    description        text DEFAULT NULL,
    title              text DEFAULT NULL,
    mime_type          text DEFAULT 'application/json',
    function_signature text DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql
AS $body$
DECLARE
    v_server_id   bigint;
    v_resource_id bigint;
BEGIN
    SELECT server_id INTO v_server_id
      FROM maludb_core.malu$mc2db_server
     WHERE malu$mc2db_server.server_name = register_resource.server_name;
    IF v_server_id IS NULL THEN
        RAISE EXCEPTION 'MC2DB_SERVER_NOT_FOUND: %', server_name;
    END IF;
    INSERT INTO maludb_core.malu$mc2db_resource(
        server_id, uri_template, title, description, mime_type, function_signature)
    VALUES (
        v_server_id, uri_template, title, description, mime_type,
        NULLIF(function_signature,'')::regprocedure)
    RETURNING resource_id INTO v_resource_id;
    RETURN v_resource_id;
END;
$body$;

-- =====================================================================
-- R1.0-8: minimal database-native tool surface
--
-- The "maludb.r10" server profile holds the eleven tools required by
-- release-1.0-requirements.md §9 plus two catalog-only exemplars
-- (external_exec, mcp_proxy) that prove the polymorphic catalog works
-- end-to-end. All eleven dispatch as sql_function under the listener;
-- the two exemplars are catalog-modeled but R1.0 dispatches reject
-- them with IMPL_TYPE_NOT_AVAILABLE per §10.
--
-- Each tool function:
--   - takes (args jsonb, context jsonb)
--   - runs SECURITY INVOKER under the listener's PG role
--   - validates required args; emits errors via mc2db.put_error
--   - emits success via mc2db.put_object with content + structuredContent
--   - delegates to existing maludb_core APIs (start_session, append_context,
--     render_prompt, submit_render, etc.) rather than touching tables
--     directly. The tools are governed wrappers, not raw catalog access.
-- =====================================================================

-- ---------------------------------------------------------------------
-- maludb.health  — liveness + version probe (no inputs)
-- ---------------------------------------------------------------------
CREATE FUNCTION r10_health(args jsonb, context jsonb) RETURNS void
LANGUAGE plpgsql SECURITY INVOKER
AS $body$
BEGIN
    CALL mc2db.put_object(jsonb_build_object(
        'content', jsonb_build_array(
            jsonb_build_object('type','text','text','ok')),
        'structuredContent', jsonb_build_object(
            'status',  'ok',
            'version', maludb_core_version(),
            'release', maludb_core_release(),
            'now',     now()),
        'isError', false));
END;
$body$;

-- ---------------------------------------------------------------------
-- maludb.catalog.describe — list MaluDB-owned catalog tables
-- args: { schema?: text, name_pattern?: text }
-- ---------------------------------------------------------------------
CREATE FUNCTION r10_catalog_describe(args jsonb, context jsonb) RETURNS void
LANGUAGE plpgsql SECURITY INVOKER
AS $body$
DECLARE
    v_schema text := COALESCE(args->>'schema', 'maludb_core');
    v_pat    text := COALESCE(args->>'name_pattern', 'malu$%');
    v_tables jsonb;
BEGIN
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'schema',     n.nspname,
        'name',       c.relname,
        'kind',       CASE c.relkind WHEN 'r' THEN 'table'
                                     WHEN 'v' THEN 'view'
                                     WHEN 'm' THEN 'matview'
                                     WHEN 'p' THEN 'partitioned_table'
                                     ELSE c.relkind::text END,
        'description', obj_description(c.oid, 'pg_class')) ORDER BY c.relname),
        '[]'::jsonb)
    INTO v_tables
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = v_schema
      AND c.relkind IN ('r','v','m','p')
      AND c.relname LIKE v_pat;

    CALL mc2db.put_object(jsonb_build_object(
        'content', jsonb_build_array(jsonb_build_object('type','text',
            'text', format('found %s objects in %s', jsonb_array_length(v_tables), v_schema))),
        'structuredContent', jsonb_build_object(
            'schema', v_schema,
            'tables', v_tables),
        'isError', false));
END;
$body$;

-- ---------------------------------------------------------------------
-- maludb.models.list — list registered model aliases (no secrets)
-- args: { provider_kind?: text, enabled_only?: bool }
-- ---------------------------------------------------------------------
CREATE FUNCTION r10_models_list(args jsonb, context jsonb) RETURNS void
LANGUAGE plpgsql SECURITY INVOKER
AS $body$
DECLARE
    v_kind   text := args->>'provider_kind';
    v_only   bool := COALESCE((args->>'enabled_only')::bool, true);
    v_models jsonb;
BEGIN
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'alias_name',       a.alias_name,
        'provider_name',    p.provider_name,
        'provider_kind',    p.provider_kind,
        'model_identifier', a.model_identifier,
        'context_length',   a.context_length,
        'enabled',          a.enabled) ORDER BY a.alias_name),
        '[]'::jsonb)
    INTO v_models
    FROM malu$model_alias a
    JOIN model_provider_public p ON p.provider_id = a.provider_id
    WHERE (NOT v_only OR a.enabled)
      AND (v_kind IS NULL OR p.provider_kind = v_kind);

    CALL mc2db.put_object(jsonb_build_object(
        'content', jsonb_build_array(jsonb_build_object('type','text',
            'text', format('%s model alias(es)', jsonb_array_length(v_models)))),
        'structuredContent', jsonb_build_object('aliases', v_models),
        'isError', false));
END;
$body$;

-- ---------------------------------------------------------------------
-- maludb.prompts.list — list registered prompt templates
-- args: { name_pattern?: text, latest_only?: bool }
-- ---------------------------------------------------------------------
CREATE FUNCTION r10_prompts_list(args jsonb, context jsonb) RETURNS void
LANGUAGE plpgsql SECURITY INVOKER
AS $body$
DECLARE
    v_pat       text := COALESCE(args->>'name_pattern', '%');
    v_latest    bool := COALESCE((args->>'latest_only')::bool, false);
    v_prompts   jsonb;
BEGIN
    IF v_latest THEN
        SELECT COALESCE(jsonb_agg(row_to_jsonb(t) ORDER BY t.template_name),
                        '[]'::jsonb)
        INTO v_prompts
        FROM (
            SELECT DISTINCT ON (template_name)
                template_id, template_name, template_version,
                (system_template IS NOT NULL OR developer_template IS NOT NULL
                                            OR user_template IS NOT NULL) AS has_channels,
                enabled
            FROM malu$prompt_template
            WHERE template_name LIKE v_pat
            ORDER BY template_name, template_version DESC
        ) t;
    ELSE
        SELECT COALESCE(jsonb_agg(jsonb_build_object(
            'template_id',      template_id,
            'template_name',    template_name,
            'template_version', template_version,
            'has_channels',     (system_template IS NOT NULL
                              OR developer_template IS NOT NULL
                              OR user_template IS NOT NULL),
            'enabled',          enabled) ORDER BY template_name, template_version),
            '[]'::jsonb)
        INTO v_prompts
        FROM malu$prompt_template
        WHERE template_name LIKE v_pat;
    END IF;

    CALL mc2db.put_object(jsonb_build_object(
        'content', jsonb_build_array(jsonb_build_object('type','text',
            'text', format('%s prompt template(s)', jsonb_array_length(v_prompts)))),
        'structuredContent', jsonb_build_object('templates', v_prompts),
        'isError', false));
END;
$body$;

-- ---------------------------------------------------------------------
-- maludb.sessions.create
-- args: { account_name: text, alias_name?: text, template_name?: text,
--         template_version?: int, token_budget?: int }
-- ---------------------------------------------------------------------
CREATE FUNCTION r10_sessions_create(args jsonb, context jsonb) RETURNS void
LANGUAGE plpgsql SECURITY INVOKER
AS $body$
DECLARE
    v_account  text := args->>'account_name';
    v_session  bigint;
BEGIN
    IF v_account IS NULL OR v_account = '' THEN
        CALL mc2db.put_error('account_name is required',
            jsonb_build_object('code','BAD_INPUT'));
        RETURN;
    END IF;
    v_session := start_session(
        v_account,
        args->>'alias_name',
        args->>'template_name',
        NULLIF(args->>'template_version','')::int,
        NULLIF(args->>'token_budget','')::int);
    CALL mc2db.put_object(jsonb_build_object(
        'content', jsonb_build_array(jsonb_build_object('type','text',
            'text', format('session %s opened for %s', v_session, v_account))),
        'structuredContent', jsonb_build_object('session_id', v_session),
        'isError', false));
END;
$body$;

-- ---------------------------------------------------------------------
-- maludb.sessions.get
-- args: { session_id: int }
-- ---------------------------------------------------------------------
CREATE FUNCTION r10_sessions_get(args jsonb, context jsonb) RETURNS void
LANGUAGE plpgsql SECURITY INVOKER
AS $body$
DECLARE
    v_id    bigint := NULLIF(args->>'session_id','')::bigint;
    v_row   jsonb;
BEGIN
    IF v_id IS NULL THEN
        CALL mc2db.put_error('session_id is required',
            jsonb_build_object('code','BAD_INPUT'));
        RETURN;
    END IF;
    SELECT to_jsonb(s) || jsonb_build_object(
        'account_name',  a.account_name,
        'alias_name',    ma.alias_name,
        'template_name', pt.template_name)
    INTO v_row
    FROM malu$session s
    LEFT JOIN malu$account         a  ON a.account_id   = s.account_id
    LEFT JOIN malu$model_alias     ma ON ma.alias_id    = s.model_alias_id
    LEFT JOIN malu$prompt_template pt ON pt.template_id = s.prompt_template_id
    WHERE s.session_id = v_id;
    IF v_row IS NULL THEN
        CALL mc2db.put_error(format('session %s not found', v_id),
            jsonb_build_object('code','NOT_FOUND'));
        RETURN;
    END IF;
    CALL mc2db.put_object(jsonb_build_object(
        'content', jsonb_build_array(jsonb_build_object('type','text',
            'text', format('session %s state=%s', v_id, v_row->>'lifecycle_state'))),
        'structuredContent', jsonb_build_object('session', v_row),
        'isError', false));
END;
$body$;

-- ---------------------------------------------------------------------
-- maludb.context.append
-- args: { session_id: int, role?: text, content_text?: text,
--         content_jsonb?: jsonb, source_label?: text,
--         sensitivity?: text, token_estimate?: int }
-- ---------------------------------------------------------------------
CREATE FUNCTION r10_context_append(args jsonb, context jsonb) RETURNS void
LANGUAGE plpgsql SECURITY INVOKER
AS $body$
DECLARE
    v_session bigint := NULLIF(args->>'session_id','')::bigint;
    v_text    text   := args->>'content_text';
    v_json    jsonb  := args->'content_jsonb';
    v_id      bigint;
    v_ord     integer;
BEGIN
    IF v_session IS NULL THEN
        CALL mc2db.put_error('session_id is required',
            jsonb_build_object('code','BAD_INPUT'));
        RETURN;
    END IF;
    IF v_text IS NULL AND v_json IS NULL THEN
        CALL mc2db.put_error('content_text or content_jsonb is required',
            jsonb_build_object('code','BAD_INPUT'));
        RETURN;
    END IF;
    v_id := append_context(
        v_session,
        args->>'role',
        v_text,
        v_json,
        args->>'source_label',
        COALESCE(args->>'sensitivity','internal'),
        NULLIF(args->>'token_estimate','')::int);
    SELECT ordinal INTO v_ord FROM malu$session_context WHERE context_id = v_id;
    CALL mc2db.put_object(jsonb_build_object(
        'content', jsonb_build_array(jsonb_build_object('type','text',
            'text', format('appended ordinal=%s context_id=%s', v_ord, v_id))),
        'structuredContent', jsonb_build_object(
            'context_id', v_id, 'ordinal', v_ord),
        'isError', false));
END;
$body$;

-- ---------------------------------------------------------------------
-- maludb.context.read
-- args: { session_id: int }
-- ---------------------------------------------------------------------
CREATE FUNCTION r10_context_read(args jsonb, context jsonb) RETURNS void
LANGUAGE plpgsql SECURITY INVOKER
AS $body$
DECLARE
    v_session bigint := NULLIF(args->>'session_id','')::bigint;
    v_blocks  jsonb;
BEGIN
    IF v_session IS NULL THEN
        CALL mc2db.put_error('session_id is required',
            jsonb_build_object('code','BAD_INPUT'));
        RETURN;
    END IF;
    PERFORM 1 FROM malu$session WHERE session_id = v_session;
    IF NOT FOUND THEN
        CALL mc2db.put_error(format('session %s not found', v_session),
            jsonb_build_object('code','NOT_FOUND'));
        RETURN;
    END IF;
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'ordinal',       ordinal,
        'role',          role,
        'content_text',  content_text,
        'content_jsonb', content_jsonb,
        'source_label',  source_label,
        'sensitivity',   sensitivity,
        'content_hash',  content_hash,
        'created_at',    created_at) ORDER BY ordinal),
        '[]'::jsonb)
    INTO v_blocks
    FROM malu$session_context
    WHERE session_id = v_session;
    CALL mc2db.put_object(jsonb_build_object(
        'content', jsonb_build_array(jsonb_build_object('type','text',
            'text', format('%s context block(s)', jsonb_array_length(v_blocks)))),
        'structuredContent', jsonb_build_object(
            'session_id', v_session,
            'blocks',     v_blocks),
        'isError', false));
END;
$body$;

-- ---------------------------------------------------------------------
-- maludb.prompts.render
-- args: { session_id: int, template_name: text,
--         template_version?: int, variables?: jsonb }
-- ---------------------------------------------------------------------
CREATE FUNCTION r10_prompts_render(args jsonb, context jsonb) RETURNS void
LANGUAGE plpgsql SECURITY INVOKER
AS $body$
DECLARE
    v_session bigint := NULLIF(args->>'session_id','')::bigint;
    v_name    text   := args->>'template_name';
    v_render  bigint;
    v_row     malu$prompt_render%ROWTYPE;
BEGIN
    IF v_session IS NULL OR v_name IS NULL OR v_name = '' THEN
        CALL mc2db.put_error('session_id and template_name are required',
            jsonb_build_object('code','BAD_INPUT'));
        RETURN;
    END IF;
    v_render := render_prompt(
        v_session, v_name,
        NULLIF(args->>'template_version','')::int,
        COALESCE(args->'variables', '{}'::jsonb));
    SELECT * INTO v_row FROM malu$prompt_render WHERE render_id = v_render;
    CALL mc2db.put_object(jsonb_build_object(
        'content', jsonb_build_array(jsonb_build_object('type','text',
            'text', format('rendered render_id=%s prompt_hash=%s',
                           v_render, v_row.prompt_hash))),
        'structuredContent', jsonb_build_object(
            'render_id',           v_render,
            'prompt_hash',         v_row.prompt_hash,
            'context_hash',        v_row.context_hash,
            'context_block_count', v_row.context_block_count,
            'rendered_prompt',     v_row.rendered_prompt),
        'isError', false));
END;
$body$;

-- ---------------------------------------------------------------------
-- maludb.models.submit
-- args: { render_id: int, alias_name: text,
--         account_name?: text, generation_params?: jsonb,
--         timeout_ms?: int }
-- Returns response_id when the alias resolves to a stub provider; else
-- the request is queued and response_id is null (maludb_modeld picks
-- it up).
-- ---------------------------------------------------------------------
CREATE FUNCTION r10_models_submit(args jsonb, context jsonb) RETURNS void
LANGUAGE plpgsql SECURITY INVOKER
AS $body$
DECLARE
    v_render bigint := NULLIF(args->>'render_id','')::bigint;
    v_alias  text   := args->>'alias_name';
    v_request bigint;
    v_kind    text;
    v_response bigint := NULL;
BEGIN
    IF v_render IS NULL OR v_alias IS NULL OR v_alias = '' THEN
        CALL mc2db.put_error('render_id and alias_name are required',
            jsonb_build_object('code','BAD_INPUT'));
        RETURN;
    END IF;
    v_request := submit_render(
        v_render, v_alias,
        args->>'account_name',
        COALESCE(args->'generation_params', '{}'::jsonb),
        COALESCE(NULLIF(args->>'timeout_ms','')::int, 30000));
    SELECT mp.provider_kind INTO v_kind
    FROM malu$model_alias ma
    JOIN malu$model_provider mp ON mp.provider_id = ma.provider_id
    WHERE ma.alias_name = v_alias;
    IF v_kind = 'stub' THEN
        v_response := mc_stub_process(v_request);
    END IF;
    CALL mc2db.put_object(jsonb_build_object(
        'content', jsonb_build_array(jsonb_build_object('type','text',
            'text', format('submitted request_id=%s%s',
                           v_request,
                           CASE WHEN v_response IS NULL THEN ' (deferred to maludb_modeld)'
                                ELSE format(' response_id=%s', v_response) END))),
        'structuredContent', jsonb_build_object(
            'request_id',  v_request,
            'response_id', v_response,
            'provider_kind', v_kind),
        'isError', false));
END;
$body$;

-- ---------------------------------------------------------------------
-- maludb.responses.get
-- args: { request_id: int }
-- ---------------------------------------------------------------------
CREATE FUNCTION r10_responses_get(args jsonb, context jsonb) RETURNS void
LANGUAGE plpgsql SECURITY INVOKER
AS $body$
DECLARE
    v_request bigint := NULLIF(args->>'request_id','')::bigint;
    v_row     jsonb;
BEGIN
    IF v_request IS NULL THEN
        CALL mc2db.put_error('request_id is required',
            jsonb_build_object('code','BAD_INPUT'));
        RETURN;
    END IF;
    SELECT to_jsonb(r) INTO v_row
    FROM malu$model_response r
    WHERE r.request_id = v_request;
    IF v_row IS NULL THEN
        CALL mc2db.put_object(jsonb_build_object(
            'content', jsonb_build_array(jsonb_build_object('type','text',
                'text', format('no response yet for request_id=%s', v_request))),
            'structuredContent', jsonb_build_object(
                'request_id', v_request,
                'pending',    true),
            'isError', false));
        RETURN;
    END IF;
    CALL mc2db.put_object(jsonb_build_object(
        'content', jsonb_build_array(jsonb_build_object('type','text',
            'text', format('response %s status=%s',
                           v_row->>'response_id', v_row->>'status'))),
        'structuredContent', jsonb_build_object(
            'response',   v_row,
            'pending',    false),
        'isError', false));
END;
$body$;

-- ---------------------------------------------------------------------
-- Server profile + tool registrations
-- ---------------------------------------------------------------------
SELECT mc2db.create_server(
    'maludb.r10',
    'MaluDB R1.0',
    'Minimum tool surface for Release 1.0 (R1.0-8)');

SELECT mc2db.register_tool(
    server_name => 'maludb.r10', tool_name => 'maludb.health',
    description => 'Liveness, version, and release probe.',
    implementation_type => 'sql_function',
    input_schema  => '{"type":"object","properties":{},"additionalProperties":false}'::jsonb,
    output_schema => '{"type":"object","required":["status","version","release"]}'::jsonb,
    impl_metadata => jsonb_build_object('function_signature',
        'maludb_core.r10_health(jsonb, jsonb)'));

SELECT mc2db.register_tool(
    server_name => 'maludb.r10', tool_name => 'maludb.catalog.describe',
    description => 'Describe MaluDB-owned catalog tables and views.',
    implementation_type => 'sql_function',
    input_schema  => '{"type":"object","properties":{
        "schema":{"type":"string"},"name_pattern":{"type":"string"}}}'::jsonb,
    output_schema => '{"type":"object","required":["schema","tables"]}'::jsonb,
    impl_metadata => jsonb_build_object('function_signature',
        'maludb_core.r10_catalog_describe(jsonb, jsonb)'));

SELECT mc2db.register_tool(
    server_name => 'maludb.r10', tool_name => 'maludb.models.list',
    description => 'List registered model aliases (without secrets).',
    implementation_type => 'sql_function',
    input_schema  => '{"type":"object","properties":{
        "provider_kind":{"type":"string"},
        "enabled_only":{"type":"boolean"}}}'::jsonb,
    output_schema => '{"type":"object","required":["aliases"]}'::jsonb,
    impl_metadata => jsonb_build_object('function_signature',
        'maludb_core.r10_models_list(jsonb, jsonb)'));

SELECT mc2db.register_tool(
    server_name => 'maludb.r10', tool_name => 'maludb.prompts.list',
    description => 'List registered prompt templates.',
    implementation_type => 'sql_function',
    input_schema  => '{"type":"object","properties":{
        "name_pattern":{"type":"string"},
        "latest_only":{"type":"boolean"}}}'::jsonb,
    output_schema => '{"type":"object","required":["templates"]}'::jsonb,
    impl_metadata => jsonb_build_object('function_signature',
        'maludb_core.r10_prompts_list(jsonb, jsonb)'));

SELECT mc2db.register_tool(
    server_name => 'maludb.r10', tool_name => 'maludb.sessions.create',
    description => 'Open a model session bound to an account.',
    implementation_type => 'sql_function',
    input_schema  => '{"type":"object",
        "properties":{
            "account_name":{"type":"string"},
            "alias_name":{"type":"string"},
            "template_name":{"type":"string"},
            "template_version":{"type":"integer"},
            "token_budget":{"type":"integer"}},
        "required":["account_name"]}'::jsonb,
    output_schema => '{"type":"object","required":["session_id"]}'::jsonb,
    read_only     => false,
    impl_metadata => jsonb_build_object('function_signature',
        'maludb_core.r10_sessions_create(jsonb, jsonb)'));

SELECT mc2db.register_tool(
    server_name => 'maludb.r10', tool_name => 'maludb.sessions.get',
    description => 'Read session metadata.',
    implementation_type => 'sql_function',
    input_schema  => '{"type":"object",
        "properties":{"session_id":{"type":"integer"}},
        "required":["session_id"]}'::jsonb,
    output_schema => '{"type":"object","required":["session"]}'::jsonb,
    impl_metadata => jsonb_build_object('function_signature',
        'maludb_core.r10_sessions_get(jsonb, jsonb)'));

SELECT mc2db.register_tool(
    server_name => 'maludb.r10', tool_name => 'maludb.context.append',
    description => 'Append a Session Context block.',
    implementation_type => 'sql_function',
    input_schema  => '{"type":"object",
        "properties":{
            "session_id":{"type":"integer"},
            "role":{"type":"string"},
            "content_text":{"type":"string"},
            "content_jsonb":{"type":"object"},
            "source_label":{"type":"string"},
            "sensitivity":{"type":"string"},
            "token_estimate":{"type":"integer"}},
        "required":["session_id"]}'::jsonb,
    output_schema => '{"type":"object","required":["context_id","ordinal"]}'::jsonb,
    read_only     => false,
    impl_metadata => jsonb_build_object('function_signature',
        'maludb_core.r10_context_append(jsonb, jsonb)'));

SELECT mc2db.register_tool(
    server_name => 'maludb.r10', tool_name => 'maludb.context.read',
    description => 'Read all Session Context blocks for a session.',
    implementation_type => 'sql_function',
    input_schema  => '{"type":"object",
        "properties":{"session_id":{"type":"integer"}},
        "required":["session_id"]}'::jsonb,
    output_schema => '{"type":"object","required":["session_id","blocks"]}'::jsonb,
    impl_metadata => jsonb_build_object('function_signature',
        'maludb_core.r10_context_read(jsonb, jsonb)'));

SELECT mc2db.register_tool(
    server_name => 'maludb.r10', tool_name => 'maludb.prompts.render',
    description => 'Render a prompt template + Session Context into a malu$prompt_render row.',
    implementation_type => 'sql_function',
    input_schema  => '{"type":"object",
        "properties":{
            "session_id":{"type":"integer"},
            "template_name":{"type":"string"},
            "template_version":{"type":"integer"},
            "variables":{"type":"object"}},
        "required":["session_id","template_name"]}'::jsonb,
    output_schema => '{"type":"object","required":["render_id","prompt_hash"]}'::jsonb,
    read_only     => false,
    impl_metadata => jsonb_build_object('function_signature',
        'maludb_core.r10_prompts_render(jsonb, jsonb)'));

SELECT mc2db.register_tool(
    server_name => 'maludb.r10', tool_name => 'maludb.models.submit',
    description => 'Submit a render to the model gateway. Returns response_id when the alias resolves to a stub provider; otherwise queued for maludb_modeld.',
    implementation_type => 'sql_function',
    input_schema  => '{"type":"object",
        "properties":{
            "render_id":{"type":"integer"},
            "alias_name":{"type":"string"},
            "account_name":{"type":"string"},
            "generation_params":{"type":"object"},
            "timeout_ms":{"type":"integer"}},
        "required":["render_id","alias_name"]}'::jsonb,
    output_schema => '{"type":"object","required":["request_id"]}'::jsonb,
    read_only     => false,
    risk_class    => 'state_changing',
    impl_metadata => jsonb_build_object('function_signature',
        'maludb_core.r10_models_submit(jsonb, jsonb)'));

SELECT mc2db.register_tool(
    server_name => 'maludb.r10', tool_name => 'maludb.responses.get',
    description => 'Read a model response by request_id. Returns pending=true when not yet written.',
    implementation_type => 'sql_function',
    input_schema  => '{"type":"object",
        "properties":{"request_id":{"type":"integer"}},
        "required":["request_id"]}'::jsonb,
    output_schema => '{"type":"object","required":["pending"]}'::jsonb,
    impl_metadata => jsonb_build_object('function_signature',
        'maludb_core.r10_responses_get(jsonb, jsonb)'));

-- ---------------------------------------------------------------------
-- Catalog-only exemplars for the deferred implementation types.
-- The R1.0 listener rejects calls to these with IMPL_TYPE_NOT_AVAILABLE
-- per release-1.0-requirements.md §10. R1.1-1 and R1.1-2 wire them.
-- ---------------------------------------------------------------------
SELECT mc2db.register_tool(
    server_name => 'maludb.r10', tool_name => 'maludb.r10.external_exec_demo',
    description => 'Catalog-only external_exec exemplar — R1.0 rejects with IMPL_TYPE_NOT_AVAILABLE.',
    implementation_type => 'external_exec',
    input_schema  => '{"type":"object"}'::jsonb,
    output_schema => '{"type":"object"}'::jsonb,
    impl_metadata => jsonb_build_object(
        'command_path',  '/usr/local/maludb/tools/exec_demo.py',
        'argv_template', '[]'::jsonb,
        'environment',   '{}'::jsonb));

SELECT mc2db.register_tool(
    server_name => 'maludb.r10', tool_name => 'maludb.r10.mcp_proxy_demo',
    description => 'Catalog-only mcp_proxy exemplar — R1.0 rejects with IMPL_TYPE_NOT_AVAILABLE.',
    implementation_type => 'mcp_proxy',
    input_schema  => '{"type":"object"}'::jsonb,
    output_schema => '{"type":"object"}'::jsonb,
    impl_metadata => jsonb_build_object(
        'remote_server_name', 'docs',
        'remote_tool_name',   'search',
        'transport_type',     'http',
        'endpoint_url',       'http://127.0.0.1:6000'));
