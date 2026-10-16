\echo Use "ALTER EXTENSION maludb_core UPDATE TO '0.44.0'" to load this file. \quit

-- =====================================================================
-- maludb_core 0.43.0 → 0.44.0
--
-- Stage 10 / V3-API-01 (catalog only): curated REST gateway catalog
-- and invocation audit.
--
-- Adds the catalog the future `maludb-restd` Go service will consume:
-- one row per stable HTTP endpoint, naming the SQL/PL/pgSQL function
-- the gateway is allowed to dispatch to, the required token scopes,
-- the risk class, OpenAPI fragment, and per-call resource limits.
-- Every dispatched request lands a `malu$rest_invocation` row, the
-- HTTP analogue of `malu$mc2db_invocation`.
--
-- This migration is **SQL surface only**. The Go service itself
-- (V3-API-01b) consumes the catalog through these helpers and writes
-- audit rows via `rest_log_invocation`. The CLI (V3-CLI-01) and SDK
-- parity work (V3-SDK-01) follow after V3-API-01b.
--
-- Doctrine:
--   * No generic CRUD over private `malu$` tables; endpoints can
--     only target functions registered through `rest_register_endpoint`.
--   * Authentication uses the V3-AUTH-01 token model. Scopes recorded
--     on the endpoint row are checked by the gateway before dispatch.
--   * `malu$rest_invocation` is the sibling of `malu$mc2db_invocation`
--     and shares its append-only / per-tenant RLS contract.
--   * `rest_openapi_spec()` returns the OpenAPI 3.1 document the
--     gateway serves at `GET /openapi.json`; assembled from the
--     catalog so the spec never drifts from the dispatcher.
--
-- Apply with:
--   ALTER EXTENSION maludb_core UPDATE TO '0.44.0';
-- =====================================================================

CREATE OR REPLACE FUNCTION maludb_core_version() RETURNS text
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$ SELECT '0.44.0'::text $body$;

-- ---------------------------------------------------------------------
-- maludb_rest_dispatcher — NOLOGIN role granted INSERT on
-- malu$rest_invocation. Operators GRANT maludb_rest_dispatcher TO the
-- service login role that runs maludb-restd; the service inherits no
-- table read privileges beyond what its tenant role already has, so
-- RLS still governs visibility.
-- ---------------------------------------------------------------------
DO $body$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'maludb_rest_dispatcher') THEN
        CREATE ROLE maludb_rest_dispatcher NOLOGIN;
    END IF;
END;
$body$;
GRANT USAGE ON SCHEMA maludb_core TO maludb_rest_dispatcher;

-- ---------------------------------------------------------------------
-- malu$rest_endpoint — one row per curated REST endpoint. handler_function
-- is regprocedure so the catalog refuses to accept a non-existent
-- target — same property `malu$mc2db_tool_sql_function` already
-- relies on.
-- ---------------------------------------------------------------------
CREATE TABLE malu$rest_endpoint (
    endpoint_id        bigserial PRIMARY KEY,
    path               text       NOT NULL,
    method             text       NOT NULL CHECK (method IN
                          ('GET','POST','PUT','PATCH','DELETE')),
    handler_function   regprocedure NOT NULL,
    description        text,
    auth_required      boolean    NOT NULL DEFAULT true,
    required_scopes    text[]     NOT NULL DEFAULT ARRAY[]::text[],
    risk_class         text       NOT NULL DEFAULT 'read_only' CHECK (risk_class IN
                          ('read_only','evidence_producing','state_changing',
                           'external_effect','administrative')),
    openapi_spec       jsonb      NOT NULL DEFAULT '{}'::jsonb,
    timeout_ms         integer    NOT NULL DEFAULT 30000 CHECK (timeout_ms > 0),
    max_input_bytes    integer    NOT NULL DEFAULT 1048576 CHECK (max_input_bytes > 0),
    max_output_bytes   integer    NOT NULL DEFAULT 10485760 CHECK (max_output_bytes > 0),
    enabled            boolean    NOT NULL DEFAULT true,
    version_introduced text       NOT NULL DEFAULT '0.44.0',
    owner_schema       name       NOT NULL DEFAULT current_schema(),
    created_at         timestamptz NOT NULL DEFAULT now(),
    retired_at         timestamptz,
    UNIQUE (owner_schema, method, path)
);
CREATE INDEX malu$rest_endpoint_enabled_idx
    ON malu$rest_endpoint(method, path) WHERE enabled AND retired_at IS NULL;
CREATE INDEX malu$rest_endpoint_handler_idx
    ON malu$rest_endpoint(handler_function);
COMMENT ON TABLE malu$rest_endpoint IS
    'V3-API-01: curated REST endpoint catalog. handler_function is the '
    'only SQL surface the gateway is allowed to dispatch to; private '
    'malu$ tables are never reachable through the REST API.';

-- ---------------------------------------------------------------------
-- malu$rest_invocation — append-only HTTP audit. Mirrors the shape of
-- malu$mc2db_invocation (call_id uuid PK, started/finished, hashes,
-- error fields) and adds HTTP-specific columns (method, path,
-- status_code, latency_ms, source_ip).
-- ---------------------------------------------------------------------
CREATE TABLE malu$rest_invocation (
    call_id        uuid       PRIMARY KEY DEFAULT public.gen_random_uuid(),
    endpoint_id    bigint     REFERENCES malu$rest_endpoint(endpoint_id) ON DELETE SET NULL,
    account_id     bigint     REFERENCES malu$account(account_id)        ON DELETE SET NULL,
    token_id       bigint     REFERENCES malu$auth_token(token_id)       ON DELETE SET NULL,
    method         text       NOT NULL,
    path           text       NOT NULL,
    request_user   text,
    source_ip      inet,
    request_hash   bytea,
    response_hash  bytea,
    status_code    smallint,
    latency_ms     integer,
    started_at     timestamptz NOT NULL DEFAULT now(),
    finished_at    timestamptz,
    success        boolean    NOT NULL,
    error_code     text,
    error_message  text,
    owner_schema   name       NOT NULL DEFAULT current_schema()
);
CREATE INDEX malu$rest_invocation_endpoint_idx
    ON malu$rest_invocation(endpoint_id, started_at DESC);
CREATE INDEX malu$rest_invocation_account_idx
    ON malu$rest_invocation(account_id, started_at DESC) WHERE account_id IS NOT NULL;
CREATE INDEX malu$rest_invocation_owner_idx
    ON malu$rest_invocation(owner_schema, started_at DESC);

-- ---------------------------------------------------------------------
-- RLS — both tables owner_schema-bound. maludb-restd inherits no
-- BYPASSRLS; the dispatcher binds the request to the tenant role
-- before INSERTing.
-- ---------------------------------------------------------------------
ALTER TABLE malu$rest_endpoint ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_owner ON malu$rest_endpoint
    USING      (owner_schema = current_schema())
    WITH CHECK (owner_schema = current_schema());

ALTER TABLE malu$rest_invocation ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_owner ON malu$rest_invocation
    USING      (owner_schema = current_schema())
    WITH CHECK (owner_schema = current_schema());

-- ---------------------------------------------------------------------
-- Grants. Endpoint catalog: admin + executor write; auditor read.
-- Invocation: admin/auditor/executor read; rest_dispatcher inserts.
-- ---------------------------------------------------------------------
GRANT SELECT, INSERT, UPDATE ON malu$rest_endpoint TO
    maludb_memory_admin, maludb_memory_executor;
GRANT SELECT ON malu$rest_endpoint TO
    maludb_memory_auditor, maludb_rest_dispatcher;

GRANT SELECT ON malu$rest_invocation TO
    maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor,
    maludb_rest_dispatcher;
GRANT INSERT ON malu$rest_invocation TO
    maludb_memory_admin, maludb_rest_dispatcher;

GRANT USAGE, SELECT ON SEQUENCE malu$rest_endpoint_endpoint_id_seq TO
    maludb_memory_admin, maludb_memory_executor;

-- =====================================================================
-- Public API
-- =====================================================================

-- rest_register_endpoint — UPSERT. Returns the endpoint_id. Validates
-- the handler_function exists (regprocedure cast enforces this at
-- parse time) and that risk_class is in the allowed set.
CREATE FUNCTION rest_register_endpoint(
    p_method            text,
    p_path              text,
    p_handler           regprocedure,
    p_description       text         DEFAULT NULL,
    p_required_scopes   text[]       DEFAULT ARRAY[]::text[],
    p_risk_class        text         DEFAULT 'read_only',
    p_openapi_spec      jsonb        DEFAULT '{}'::jsonb,
    p_auth_required     boolean      DEFAULT true,
    p_timeout_ms        integer      DEFAULT 30000,
    p_max_input_bytes   integer      DEFAULT 1048576,
    p_max_output_bytes  integer      DEFAULT 10485760
) RETURNS bigint
    LANGUAGE plpgsql VOLATILE
    AS $body$
#variable_conflict use_column
DECLARE
    v_id      bigint;
    v_created boolean;
BEGIN
    IF p_method NOT IN ('GET','POST','PUT','PATCH','DELETE') THEN
        RAISE EXCEPTION 'rest_register_endpoint: method must be one of GET/POST/PUT/PATCH/DELETE'
            USING ERRCODE = 'check_violation';
    END IF;
    IF p_path NOT LIKE '/%' THEN
        RAISE EXCEPTION 'rest_register_endpoint: path must start with /'
            USING ERRCODE = 'check_violation';
    END IF;

    INSERT INTO malu$rest_endpoint
        (method, path, handler_function, description,
         required_scopes, risk_class, openapi_spec, auth_required,
         timeout_ms, max_input_bytes, max_output_bytes)
    VALUES
        (p_method, p_path, p_handler, p_description,
         p_required_scopes, p_risk_class, p_openapi_spec, p_auth_required,
         p_timeout_ms, p_max_input_bytes, p_max_output_bytes)
    ON CONFLICT (owner_schema, method, path) DO UPDATE
        SET handler_function   = EXCLUDED.handler_function,
            description        = EXCLUDED.description,
            required_scopes    = EXCLUDED.required_scopes,
            risk_class         = EXCLUDED.risk_class,
            openapi_spec       = EXCLUDED.openapi_spec,
            auth_required      = EXCLUDED.auth_required,
            timeout_ms         = EXCLUDED.timeout_ms,
            max_input_bytes    = EXCLUDED.max_input_bytes,
            max_output_bytes   = EXCLUDED.max_output_bytes,
            enabled            = true,
            retired_at         = NULL
    RETURNING endpoint_id, (xmax = 0) INTO v_id, v_created;

    PERFORM audit_event(
        CASE WHEN v_created THEN 'rest_endpoint_register' ELSE 'rest_endpoint_update' END,
        'malu$rest_endpoint',
        v_id,
        jsonb_build_object(
            'method', p_method,
            'path',   p_path,
            'handler', p_handler::text,
            'risk_class', p_risk_class,
            'auth_required', p_auth_required,
            'scopes', to_jsonb(p_required_scopes)),
        NULL);

    RETURN v_id;
END;
$body$;
REVOKE EXECUTE ON FUNCTION rest_register_endpoint(text, text, regprocedure, text, text[], text, jsonb, boolean, integer, integer, integer) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION rest_register_endpoint(text, text, regprocedure, text, text[], text, jsonb, boolean, integer, integer, integer) TO
    maludb_memory_admin, maludb_memory_executor;

-- rest_disable_endpoint — soft-disable. Reverses with
-- rest_register_endpoint (which clears retired_at and enabled=true).
CREATE FUNCTION rest_disable_endpoint(p_method text, p_path text, p_reason text DEFAULT NULL)
    RETURNS boolean
    LANGUAGE plpgsql VOLATILE
    AS $body$
#variable_conflict use_column
DECLARE
    v_id        bigint;
    v_was_open  boolean;
BEGIN
    SELECT endpoint_id, retired_at IS NULL AND enabled
      INTO v_id, v_was_open
      FROM malu$rest_endpoint
     WHERE method = p_method AND path = p_path;

    IF v_id IS NULL THEN
        RAISE EXCEPTION 'rest_disable_endpoint: no endpoint registered for % %', p_method, p_path
            USING ERRCODE = 'no_data_found';
    END IF;

    UPDATE malu$rest_endpoint
       SET enabled    = false,
           retired_at = COALESCE(retired_at, now())
     WHERE endpoint_id = v_id;

    PERFORM audit_event('rest_endpoint_disable', 'malu$rest_endpoint', v_id,
        jsonb_build_object('method',p_method,'path',p_path,'reason',p_reason,'was_active',v_was_open),
        NULL);

    RETURN v_was_open;
END;
$body$;
REVOKE EXECUTE ON FUNCTION rest_disable_endpoint(text, text, text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION rest_disable_endpoint(text, text, text) TO
    maludb_memory_admin, maludb_memory_executor;

-- rest_list_endpoints — enumeration for the gateway and the CLI.
-- Returns enabled endpoints by default; pass `false` to include
-- retired/disabled rows.
CREATE FUNCTION rest_list_endpoints(p_include_disabled boolean DEFAULT false)
    RETURNS TABLE (
        endpoint_id      bigint,
        method           text,
        path             text,
        handler_function text,
        description      text,
        auth_required    boolean,
        required_scopes  text[],
        risk_class       text,
        timeout_ms       integer,
        enabled          boolean
    ) LANGUAGE plpgsql STABLE
    AS $body$
#variable_conflict use_column
BEGIN
    RETURN QUERY
    SELECT e.endpoint_id,
           e.method,
           e.path,
           e.handler_function::text,
           e.description,
           e.auth_required,
           e.required_scopes,
           e.risk_class,
           e.timeout_ms,
           e.enabled
      FROM malu$rest_endpoint e
     WHERE (p_include_disabled OR (e.enabled AND e.retired_at IS NULL))
     ORDER BY e.path, e.method;
END;
$body$;
REVOKE EXECUTE ON FUNCTION rest_list_endpoints(boolean) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION rest_list_endpoints(boolean) TO
    maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor,
    maludb_rest_dispatcher;

-- rest_openapi_spec — assembles an OpenAPI 3.1 document from the
-- catalog. Per-endpoint `openapi_spec` jsonb is grouped under
-- paths[<path>][<method-lowercased>]. The info block names the
-- extension version so generated clients can pin against it.
--
-- Uses jsonb_object_agg twice (inner over methods per path, outer
-- over paths) because jsonb_set does not create intermediate path
-- elements even with create_missing=true.
CREATE FUNCTION rest_openapi_spec()
    RETURNS jsonb
    LANGUAGE plpgsql STABLE
    AS $body$
#variable_conflict use_column
DECLARE v_paths jsonb;
BEGIN
    SELECT COALESCE(jsonb_object_agg(p.path, p.methods), '{}'::jsonb)
      INTO v_paths
      FROM (
        SELECT path,
               jsonb_object_agg(lower(method), openapi_spec) AS methods
          FROM malu$rest_endpoint
         WHERE enabled AND retired_at IS NULL
         GROUP BY path
      ) p;

    RETURN jsonb_build_object(
        'openapi', '3.1.0',
        'info', jsonb_build_object(
            'title',       'MaluDB REST API',
            'version',     maludb_core_version(),
            'description', 'V3-API-01 curated REST gateway over governed memory, retrieval, model, and tool operations.'),
        'paths', v_paths);
END;
$body$;
REVOKE EXECUTE ON FUNCTION rest_openapi_spec() FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION rest_openapi_spec() TO
    maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor,
    maludb_rest_dispatcher;

-- rest_log_invocation — append-only audit helper called by the future
-- maludb-restd. Returns the call_id (uuid).
CREATE FUNCTION rest_log_invocation(
    p_endpoint_id   bigint,
    p_account_id    bigint,
    p_token_id      bigint,
    p_method        text,
    p_path          text,
    p_request_user  text,
    p_source_ip     inet,
    p_request_hash  bytea,
    p_response_hash bytea,
    p_status_code   smallint,
    p_latency_ms    integer,
    p_started_at    timestamptz,
    p_finished_at   timestamptz,
    p_success       boolean,
    p_error_code    text         DEFAULT NULL,
    p_error_message text         DEFAULT NULL
) RETURNS uuid
    LANGUAGE plpgsql VOLATILE
    AS $body$
#variable_conflict use_column
DECLARE v_id uuid;
BEGIN
    INSERT INTO malu$rest_invocation
        (endpoint_id, account_id, token_id, method, path, request_user,
         source_ip, request_hash, response_hash, status_code, latency_ms,
         started_at, finished_at, success, error_code, error_message)
    VALUES
        (p_endpoint_id, p_account_id, p_token_id, p_method, p_path, p_request_user,
         p_source_ip, p_request_hash, p_response_hash, p_status_code, p_latency_ms,
         p_started_at, p_finished_at, p_success, p_error_code, p_error_message)
    RETURNING call_id INTO v_id;
    RETURN v_id;
END;
$body$;
REVOKE EXECUTE ON FUNCTION rest_log_invocation(bigint, bigint, bigint, text, text, text, inet, bytea, bytea, smallint, integer, timestamptz, timestamptz, boolean, text, text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION rest_log_invocation(bigint, bigint, bigint, text, text, text, inet, bytea, bytea, smallint, integer, timestamptz, timestamptz, boolean, text, text) TO
    maludb_memory_admin, maludb_rest_dispatcher;
