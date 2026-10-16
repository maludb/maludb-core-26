-- =====================================================================
-- maludb_core 0.61.0 -> 0.62.0  (v3.1 Stage F — V3-API-02)
--
-- Adds typed argument schemas to malu$rest_endpoint and seeds the
-- curated v3 REST surface. Closes the V3-API-01b follow-up note.
--
-- arg_schema is a JSON array. Each element describes one SQL
-- parameter (PL/pgSQL function arg) and how the dispatcher should
-- source its value from the HTTP request:
--
--   [
--     { "name":  "p_memory_kind",
--       "type":  "text" | "bigint" | "integer" | "boolean"
--                | "numeric" | "jsonb" | "text[]" | "bytea_hex"
--                | "timestamptz",
--       "in":    "body" | "query",
--       "required": true | false,
--       "default":  <value> | null
--     },
--     ...
--   ]
--
-- The dispatcher calls the handler with named args:
--   SELECT <handler>(<name> := $1, <name> := $2, ...)
-- so positional ordering inside arg_schema is not load-bearing.
--
-- Apply with:
--   ALTER EXTENSION maludb_core UPDATE TO '0.62.0';
-- =====================================================================

CREATE OR REPLACE FUNCTION maludb_core_version() RETURNS text
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$ SELECT '0.62.0'::text $body$;

-- ---------------------------------------------------------------------
-- 1. arg_schema column.
-- ---------------------------------------------------------------------
ALTER TABLE malu$rest_endpoint
    ADD COLUMN IF NOT EXISTS arg_schema jsonb NOT NULL DEFAULT '[]'::jsonb;

-- ---------------------------------------------------------------------
-- 2. Replace rest_register_endpoint to accept arg_schema. The prior
--    11-arg signature is dropped; a new 12-arg form with p_arg_schema
--    defaulting to '[]'::jsonb keeps existing callers working.
-- ---------------------------------------------------------------------
DROP FUNCTION rest_register_endpoint(text, text, regprocedure, text,
                                     text[], text, jsonb, boolean,
                                     integer, integer, integer);

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
    p_max_output_bytes  integer      DEFAULT 10485760,
    p_arg_schema        jsonb        DEFAULT '[]'::jsonb
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
    IF jsonb_typeof(p_arg_schema) <> 'array' THEN
        RAISE EXCEPTION 'rest_register_endpoint: arg_schema must be a JSON array'
            USING ERRCODE = 'check_violation';
    END IF;

    INSERT INTO malu$rest_endpoint
        (method, path, handler_function, description,
         required_scopes, risk_class, openapi_spec, auth_required,
         timeout_ms, max_input_bytes, max_output_bytes,
         version_introduced, arg_schema)
    VALUES
        (p_method, p_path, p_handler, p_description,
         p_required_scopes, p_risk_class, p_openapi_spec, p_auth_required,
         p_timeout_ms, p_max_input_bytes, p_max_output_bytes,
         maludb_core_version(), p_arg_schema)
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
            arg_schema         = EXCLUDED.arg_schema,
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
            'scopes', to_jsonb(p_required_scopes),
            'arg_schema', p_arg_schema),
        NULL);
    RETURN v_id;
END;
$body$;
REVOKE EXECUTE ON FUNCTION rest_register_endpoint(text, text, regprocedure, text,
    text[], text, jsonb, boolean, integer, integer, integer, jsonb) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION rest_register_endpoint(text, text, regprocedure, text,
    text[], text, jsonb, boolean, integer, integer, integer, jsonb) TO
    maludb_memory_admin;

-- ---------------------------------------------------------------------
-- 3. Seed the curated v3 endpoint set. ~20 endpoints across memory
--    model / retrieval / auth / secret / queue / cron / realtime /
--    observability. Each row uses ON CONFLICT to be idempotent.
-- ---------------------------------------------------------------------

-- Helper: build a single arg spec.
CREATE OR REPLACE FUNCTION _v3_api_arg(
    p_name text, p_type text, p_required boolean DEFAULT true,
    p_in   text DEFAULT 'body', p_default jsonb DEFAULT 'null'::jsonb)
    RETURNS jsonb
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$
    SELECT jsonb_build_object(
        'name',     p_name,
        'type',     p_type,
        'in',       p_in,
        'required', p_required,
        'default',  p_default)
$body$;

-- Memory model surface (Stage 2-3) -----------------------------------
SELECT rest_register_endpoint(
    'POST', '/v3/source', 'register_source_package(text,bytea,text,jsonb,text,jsonb,timestamptz,text,text)'::regprocedure,
    'Register a Source Package (verbatim archive).',
    ARRAY['source.write']::text[], 'state_changing', '{}'::jsonb, true,
    30000, 8388608, 1048576,
    jsonb_build_array(
        _v3_api_arg('p_source_type',     'text'),
        _v3_api_arg('p_content_bytes',   'bytea_hex',   false),
        _v3_api_arg('p_content_text',    'text',        false),
        _v3_api_arg('p_content_jsonb',   'jsonb',       false),
        _v3_api_arg('p_media_type',      'text',        false),
        _v3_api_arg('p_origin_jsonb',    'jsonb',       false),
        _v3_api_arg('p_captured_at',     'timestamptz', false),
        _v3_api_arg('p_retention_class', 'text',        false),
        _v3_api_arg('p_sensitivity',     'text',        false)));

SELECT rest_register_endpoint(
    'POST', '/v3/claim', 'register_claim(text,text,text,text,text,text,jsonb,bigint,jsonb,text)'::regprocedure,
    'Register a Claim.',
    ARRAY['claim.write']::text[], 'state_changing', '{}'::jsonb, true,
    30000, 1048576, 65536,
    jsonb_build_array(
        _v3_api_arg('p_subject',           'text',  false),
        _v3_api_arg('p_verb',              'text',  false),
        _v3_api_arg('p_predicate',         'text',  false),
        _v3_api_arg('p_object_value',      'text',  false),
        _v3_api_arg('p_relationship',      'text',  false),
        _v3_api_arg('p_statement_text',    'text',  false),
        _v3_api_arg('p_statement_jsonb',   'jsonb', false),
        _v3_api_arg('p_source_package_id', 'bigint',false),
        _v3_api_arg('p_source_locator',    'jsonb', false),
        _v3_api_arg('p_sensitivity',       'text',  false)));

SELECT rest_register_endpoint(
    'POST', '/v3/fact', 'register_fact(bigint[],text,text,text,text,text,text,jsonb,text,text,text)'::regprocedure,
    'Register a verified Fact.',
    ARRAY['fact.write']::text[], 'state_changing', '{}'::jsonb, true,
    30000, 1048576, 65536,
    jsonb_build_array(
        _v3_api_arg('p_claim_ids',           'bigint[]'),
        _v3_api_arg('p_subject',             'text',  false),
        _v3_api_arg('p_verb',                'text',  false),
        _v3_api_arg('p_predicate',           'text',  false),
        _v3_api_arg('p_object_value',        'text',  false),
        _v3_api_arg('p_relationship',        'text',  false),
        _v3_api_arg('p_statement_text',      'text',  false),
        _v3_api_arg('p_statement_jsonb',     'jsonb', false),
        _v3_api_arg('p_verification_scope',  'text',  false),
        _v3_api_arg('p_verification_method', 'text',  false),
        _v3_api_arg('p_sensitivity',         'text',  false)));

SELECT rest_register_endpoint(
    'POST', '/v3/memory', 'register_memory(text,text,text,jsonb,timestamptz,timestamptz,text)'::regprocedure,
    'Register a Memory.',
    ARRAY['memory.write']::text[], 'state_changing', '{}'::jsonb, true,
    30000, 1048576, 65536,
    jsonb_build_array(
        _v3_api_arg('p_memory_kind',     'text'),
        _v3_api_arg('p_title',           'text',        false),
        _v3_api_arg('p_summary',         'text',        false),
        _v3_api_arg('p_payload_jsonb',   'jsonb',       false),
        _v3_api_arg('p_occurred_at',     'timestamptz', false),
        _v3_api_arg('p_occurred_until',  'timestamptz', false),
        _v3_api_arg('p_sensitivity',     'text',        false)));

SELECT rest_register_endpoint(
    'POST', '/v3/episode', 'register_episode(text,text,text,jsonb,timestamptz,timestamptz,text)'::regprocedure,
    'Register an Episode.',
    ARRAY['episode.write']::text[], 'state_changing', '{}'::jsonb, true,
    30000, 1048576, 65536,
    jsonb_build_array(
        _v3_api_arg('p_episode_kind',    'text'),
        _v3_api_arg('p_title',           'text'),
        _v3_api_arg('p_summary',         'text',        false),
        _v3_api_arg('p_payload_jsonb',   'jsonb',       false),
        _v3_api_arg('p_occurred_at',     'timestamptz', false),
        _v3_api_arg('p_occurred_until',  'timestamptz', false),
        _v3_api_arg('p_sensitivity',     'text',        false)));

SELECT rest_register_endpoint(
    'POST', '/v3/memory-detail', 'register_memory_detail(text,bigint,bigint,bigint,integer,text,text,jsonb,text)'::regprocedure,
    'Register a Memory Detail Object.',
    ARRAY['memory.write']::text[], 'state_changing', '{}'::jsonb, true,
    30000, 1048576, 65536,
    jsonb_build_array(
        _v3_api_arg('p_detail_kind',   'text'),
        _v3_api_arg('p_parent_mdo_id', 'bigint',  false),
        _v3_api_arg('p_memory_id',     'bigint',  false),
        _v3_api_arg('p_episode_id',    'bigint',  false),
        _v3_api_arg('p_ordinal',       'integer', false),
        _v3_api_arg('p_title',         'text',    false),
        _v3_api_arg('p_body_text',     'text',    false),
        _v3_api_arg('p_body_jsonb',    'jsonb',   false),
        _v3_api_arg('p_sensitivity',   'text',    false)));

SELECT rest_register_endpoint(
    'POST', '/v3/relationship', 'register_relationship_edge(text,bigint,text,bigint,text,text,jsonb,numeric)'::regprocedure,
    'Register a relationship edge.',
    ARRAY['memory.write']::text[], 'state_changing', '{}'::jsonb, true,
    30000, 1048576, 65536,
    jsonb_build_array(
        _v3_api_arg('p_source_object_type', 'text'),
        _v3_api_arg('p_source_object_id',   'bigint'),
        _v3_api_arg('p_target_object_type', 'text'),
        _v3_api_arg('p_target_object_id',   'bigint'),
        _v3_api_arg('p_relationship_type',  'text'),
        _v3_api_arg('p_label',              'text',    false),
        _v3_api_arg('p_edge_jsonb',         'jsonb',   false),
        _v3_api_arg('p_confidence',         'numeric', false)));

-- Auth + secret (Stage 9) ---------------------------------------------
SELECT rest_register_endpoint(
    'POST', '/v3/auth/token/create', 'auth_token_create(bigint,text,text,text[],inet[],timestamptz)'::regprocedure,
    'Mint a new auth token; returns plaintext only once.',
    ARRAY['auth.admin']::text[], 'administrative', '{}'::jsonb, true,
    10000, 65536, 65536,
    jsonb_build_array(
        _v3_api_arg('p_account_id',    'bigint'),
        _v3_api_arg('p_kind',          'text'),
        _v3_api_arg('p_label',         'text',        false),
        _v3_api_arg('p_scopes',        'text[]',      false),
        _v3_api_arg('p_allowed_cidrs', 'text[]',      false),
        _v3_api_arg('p_expires_at',    'timestamptz', false)));

SELECT rest_register_endpoint(
    'POST', '/v3/auth/token/revoke', 'auth_token_revoke(bigint,text)'::regprocedure,
    'Revoke an auth token by id.',
    ARRAY['auth.admin']::text[], 'administrative', '{}'::jsonb, true,
    10000, 65536, 65536,
    jsonb_build_array(
        _v3_api_arg('p_token_id', 'bigint'),
        _v3_api_arg('p_reason',   'text', false)));

SELECT rest_register_endpoint(
    'POST', '/v3/secret/set', 'secret_set(text,text,text,text,integer)'::regprocedure,
    'Store an inline (AES-encrypted) secret value.',
    ARRAY['secret.admin']::text[], 'administrative', '{}'::jsonb, true,
    10000, 1048576, 65536,
    jsonb_build_array(
        _v3_api_arg('p_name',                 'text'),
        _v3_api_arg('p_kind',                 'text'),
        _v3_api_arg('p_value',                'text'),
        _v3_api_arg('p_description',          'text',    false),
        _v3_api_arg('p_rotation_policy_days', 'integer', false)));

SELECT rest_register_endpoint(
    'POST', '/v3/secret/metadata', 'secret_get_metadata(text)'::regprocedure,
    'Read secret metadata; never returns the value.',
    ARRAY['secret.read']::text[], 'read_only', '{}'::jsonb, true,
    10000, 65536, 65536,
    jsonb_build_array(
        _v3_api_arg('p_name', 'text')));

-- Queue + cron (Stage 11) ---------------------------------------------
SELECT rest_register_endpoint(
    'POST', '/v3/queue/enqueue', 'queue_enqueue(text,jsonb,text,integer,timestamptz,bigint)'::regprocedure,
    'Enqueue a job onto a named queue.',
    ARRAY['queue.write']::text[], 'state_changing', '{}'::jsonb, true,
    10000, 1048576, 65536,
    jsonb_build_array(
        _v3_api_arg('p_queue_name',      'text'),
        _v3_api_arg('p_payload',         'jsonb'),
        _v3_api_arg('p_idempotency_key', 'text',        false),
        _v3_api_arg('p_priority',        'integer',     false),
        _v3_api_arg('p_visible_at',      'timestamptz', false),
        _v3_api_arg('p_account_id',      'bigint',      false)));

SELECT rest_register_endpoint(
    'POST', '/v3/cron/run-now', 'schedule_run_now(text)'::regprocedure,
    'Execute a scheduled job immediately.',
    ARRAY['cron.admin']::text[], 'administrative', '{}'::jsonb, true,
    30000, 65536, 65536,
    jsonb_build_array(
        _v3_api_arg('p_name', 'text')));

-- Realtime (Stage 13) -------------------------------------------------
SELECT rest_register_endpoint(
    'POST', '/v3/event/emit', 'emit_event(text,jsonb,bigint,text,bigint,text,bigint,jsonb)'::regprocedure,
    'Append a row to malu$event and NOTIFY the realtime channel.',
    ARRAY['event.write']::text[], 'state_changing', '{}'::jsonb, true,
    10000, 1048576, 65536,
    jsonb_build_array(
        _v3_api_arg('p_event_kind',     'text'),
        _v3_api_arg('p_payload',        'jsonb',  false),
        _v3_api_arg('p_account_id',     'bigint', false),
        _v3_api_arg('p_partition',      'text',   false),
        _v3_api_arg('p_active_pool_id', 'bigint', false),
        _v3_api_arg('p_object_type',    'text',   false),
        _v3_api_arg('p_object_id',      'bigint', false),
        _v3_api_arg('p_scope',          'jsonb',  false)));

SELECT rest_register_endpoint(
    'POST', '/v3/event/subscribe', 'event_subscribe(text,bigint,text[],text[],bigint,bigint)'::regprocedure,
    'Create a durable event subscription.',
    ARRAY['event.read']::text[], 'state_changing', '{}'::jsonb, true,
    10000, 65536, 65536,
    jsonb_build_array(
        _v3_api_arg('p_name',           'text'),
        _v3_api_arg('p_account_id',     'bigint',   false),
        _v3_api_arg('p_kinds',          'text[]',   false),
        _v3_api_arg('p_partitions',     'text[]',   false),
        _v3_api_arg('p_active_pool_id', 'bigint',   false),
        _v3_api_arg('p_start_cursor',   'bigint',   false)));

-- Observability + ops (Stage 15) --------------------------------------
SELECT rest_register_endpoint(
    'GET', '/v3/metrics', 'metrics_prometheus_scrape()'::regprocedure,
    'Prometheus text exposition for MaluDB internals.',
    ARRAY['metrics.read']::text[], 'read_only', '{}'::jsonb, true,
    10000, 1024, 16777216, '[]'::jsonb);

SELECT rest_register_endpoint(
    'POST', '/v3/backup/manifest', 'backup_manifest_record(text,text,text,jsonb,text,text,text,text,text,text,text)'::regprocedure,
    'Record a backup manifest.',
    ARRAY['backup.admin']::text[], 'administrative', '{}'::jsonb, true,
    30000, 1048576, 65536,
    jsonb_build_array(
        _v3_api_arg('p_label',                     'text'),
        _v3_api_arg('p_postgres_state_kind',       'text'),
        _v3_api_arg('p_postgres_state_uri',        'text'),
        _v3_api_arg('p_hash_summary',              'jsonb'),
        _v3_api_arg('p_wal_archive_uri',           'text', false),
        _v3_api_arg('p_etc_maludb_uri',            'text', false),
        _v3_api_arg('p_source_archive_manifest_uri','text', false),
        _v3_api_arg('p_model_configs_uri',         'text', false),
        _v3_api_arg('p_tls_uri',                   'text', false),
        _v3_api_arg('p_tool_binaries_uri',         'text', false),
        _v3_api_arg('p_broker_configs_uri',        'text', false)));

SELECT rest_register_endpoint(
    'POST', '/v3/preview-env/create', 'preview_env_create(text,text,jsonb,text,text)'::regprocedure,
    'Create a self-hosted preview environment row.',
    ARRAY['env.admin']::text[], 'administrative', '{}'::jsonb, true,
    10000, 1048576, 65536,
    jsonb_build_array(
        _v3_api_arg('p_name',            'text'),
        _v3_api_arg('p_base_migration',  'text'),
        _v3_api_arg('p_seed_policy',     'jsonb',  false),
        _v3_api_arg('p_anonymizer_ref',  'text',   false),
        _v3_api_arg('p_description',     'text',   false)));

SELECT rest_register_endpoint(
    'POST', '/v3/log-drain/set', 'log_drain_set(text,text,jsonb,text[],text,jsonb,integer,integer)'::regprocedure,
    'Register or replace a log drain.',
    ARRAY['log_drain.admin']::text[], 'administrative', '{}'::jsonb, true,
    10000, 1048576, 65536,
    jsonb_build_array(
        _v3_api_arg('p_name',                    'text'),
        _v3_api_arg('p_kind',                    'text'),
        _v3_api_arg('p_destination',             'jsonb'),
        _v3_api_arg('p_source_streams',          'text[]'),
        _v3_api_arg('p_destination_secret_ref',  'text',    false),
        _v3_api_arg('p_redaction_rules',         'jsonb',   false),
        _v3_api_arg('p_batch_size',              'integer', false),
        _v3_api_arg('p_flush_interval_ms',       'integer', false)));

SELECT rest_register_endpoint(
    'POST', '/v3/presence/sweep', 'presence_sweep()'::regprocedure,
    'Sweep TTL-expired presence rows.',
    ARRAY['presence.admin']::text[], 'administrative', '{}'::jsonb, true,
    30000, 1024, 65536, '[]'::jsonb);

-- ---------------------------------------------------------------------
-- 4. Cleanup the seed helper. It was a migration-local convenience.
-- ---------------------------------------------------------------------
DROP FUNCTION _v3_api_arg(text, text, boolean, text, jsonb);
