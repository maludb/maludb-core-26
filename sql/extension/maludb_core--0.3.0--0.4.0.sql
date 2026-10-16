\echo Use "ALTER EXTENSION maludb_core UPDATE TO '0.4.0'" to load this file. \quit

-- =====================================================================
-- maludb_core 0.3.0 → 0.4.0
--
-- R1.1-3: http_endpoint dispatcher.
--
-- 0.1.0 left `malu$mc2db_tool_http_endpoint` as a placeholder
-- (tool_id only); this upgrade fills in the columns the listener
-- needs to make a real HTTP call. Companion code lives in
-- mc2dbd/src/http_endpoint.c.
--
-- Schema additions are nullable on the way in (so existing rows from
-- the placeholder era survive an ALTER without backfill); validation
-- moves into mc2db.register_tool and the dispatcher, both of which
-- reject rows that don't carry an endpoint_url.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Version bump
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION maludb_core_version() RETURNS text
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$ SELECT '0.4.0'::text $body$;

-- ---------------------------------------------------------------------
-- http_endpoint metadata. Nullable on add; populated by register_tool.
-- ---------------------------------------------------------------------
ALTER TABLE malu$mc2db_tool_http_endpoint
    ADD COLUMN endpoint_url    text,
    ADD COLUMN http_method     text NOT NULL DEFAULT 'POST',
    ADD COLUMN static_headers  jsonb NOT NULL DEFAULT '{}'::jsonb,
    ADD COLUMN auth_type       text NOT NULL DEFAULT 'none',
    ADD COLUMN auth_token      text;

ALTER TABLE malu$mc2db_tool_http_endpoint
    ADD CONSTRAINT malu$mc2db_tool_http_endpoint_method_check
        CHECK (http_method IN ('GET','POST','PUT','PATCH','DELETE')),
    ADD CONSTRAINT malu$mc2db_tool_http_endpoint_auth_check
        CHECK (auth_type IN ('none','bearer','basic'));

-- ---------------------------------------------------------------------
-- register_tool: accept http_endpoint metadata and route into the
-- new columns. Replaces the placeholder INSERT.
--
-- IMPORTANT: parameter order and types must match the 0.1.0 signature
-- exactly so CREATE OR REPLACE actually replaces the existing function
-- rather than creating a new overload (PG matches function identity by
-- (name, parameter-types-in-order), not by names).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION mc2db.register_tool(
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
        WHEN 'http_endpoint' THEN ARRAY['endpoint_url','http_method',
                                        'static_headers','auth_type','auth_token']
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
        IF impl_metadata ? 'endpoint_url' = false
           OR coalesce(impl_metadata->>'endpoint_url','') = '' THEN
            RAISE EXCEPTION
              'MC2DB_IMPL_METADATA_MISSING: http_endpoint requires endpoint_url';
        END IF;
        INSERT INTO maludb_core.malu$mc2db_tool_http_endpoint(
            tool_id, endpoint_url, http_method,
            static_headers, auth_type, auth_token)
        VALUES (
            v_tool_id,
            impl_metadata->>'endpoint_url',
            COALESCE(impl_metadata->>'http_method','POST'),
            COALESCE(impl_metadata->'static_headers','{}'::jsonb),
            COALESCE(impl_metadata->>'auth_type','none'),
            NULLIF(impl_metadata->>'auth_token',''));
    END IF;

    RETURN v_tool_id;
END;
$body$;
