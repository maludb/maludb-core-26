\echo Use "ALTER EXTENSION maludb_core UPDATE TO '0.91.0'" to load this file. \quit

-- =====================================================================
-- maludb_core 0.90.0 -> 0.91.0
--
-- Per-tenant, zero-admin model-gateway self-service.
--
-- State going in: malu$model_alias is ALREADY per-tenant (owner_schema +
-- UNIQUE(owner_schema, alias_name); the global alias_name unique was dropped
-- in the 0.89-era migration). But malu$model_provider is still GLOBAL (no
-- owner_schema, global UNIQUE provider_name), and register_model_provider /
-- register_model_alias are SECURITY INVOKER gated by the maludb_llm_model_admin
-- RLS policy -- so a tenant role cannot register its own provider/alias
-- without an admin granting it the broad (cross-tenant) gateway-admin role.
--
-- This release:
--   1. Finishes the per-tenant migration for malu$model_provider
--      (owner_schema + per-(owner_schema, provider_name) uniqueness).
--   2. Makes register_model_alias resolve its provider within the caller's
--      schema (falling back to the shared 'maludb_core' namespace), now that
--      provider names are only per-tenant unique.
--   3. Adds owner_schema-scoped SECURITY DEFINER registration helpers and
--      exposes them through enable_memory_schema as schema-local facades
--      (maludb_register_model_provider / maludb_register_model_alias) + read
--      views (maludb_model_provider / maludb_model_alias). The facades run as
--      the extension owner -- so they get through the admin-only RLS gate --
--      but are HARD-SCOPED to owner_schema = the enabling schema (baked at
--      enablement, never caller-supplied): a tenant can only ever see/write
--      its OWN provider/alias rows. No broad maludb_llm_model_admin grant and
--      NO secret decryption (secret_ref is stored, never resolved here --
--      Path B keeps the token app-side).
--
-- Out of scope (deliberate): the legacy async submit_request() resolves an
-- alias by bare alias_name; that became potentially ambiguous when the global
-- alias_name unique was dropped in 0.89 and is unchanged here.
--
-- Existing schemas pick up the facades by re-running
-- maludb_core.enable_memory_schema().
-- =====================================================================

CREATE OR REPLACE FUNCTION maludb_core.maludb_core_version() RETURNS text
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$ SELECT '0.91.0'::text $body$;

-- ===== 1. finish the per-tenant migration for malu$model_provider ====
ALTER TABLE maludb_core.malu$model_provider
    ADD COLUMN IF NOT EXISTS owner_schema name;
UPDATE maludb_core.malu$model_provider
    SET owner_schema = 'maludb_core'
  WHERE owner_schema IS NULL OR owner_schema = '';
ALTER TABLE maludb_core.malu$model_provider
    ALTER COLUMN owner_schema SET NOT NULL;
ALTER TABLE maludb_core.malu$model_provider
    ALTER COLUMN owner_schema SET DEFAULT current_schema();

CREATE INDEX IF NOT EXISTS malu$model_provider_owner_idx
    ON maludb_core.malu$model_provider(owner_schema, provider_name);

-- Drop the global provider_name unique (auto-named *_provider_name_key) and
-- any other single-column unique on provider_name, then add the per-tenant
-- composite. Robust to constraint-name drift.
ALTER TABLE maludb_core.malu$model_provider
    DROP CONSTRAINT IF EXISTS "malu$model_provider_provider_name_key";
DO $mig$
DECLARE
    v_con text;
BEGIN
    -- drop any leftover UNIQUE constraint that covers exactly (provider_name)
    FOR v_con IN
        SELECT c.conname
          FROM pg_constraint c
         WHERE c.conrelid = 'maludb_core.malu$model_provider'::regclass
           AND c.contype = 'u'
           AND c.conkey = ARRAY[(SELECT attnum FROM pg_attribute
                                  WHERE attrelid = c.conrelid AND attname = 'provider_name')]
    LOOP
        EXECUTE format('ALTER TABLE maludb_core.malu$model_provider DROP CONSTRAINT %I', v_con);
    END LOOP;

    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
         WHERE conrelid = 'maludb_core.malu$model_provider'::regclass
           AND conname  = 'malu$model_provider_owner_provider_name_key'
    ) THEN
        ALTER TABLE maludb_core.malu$model_provider
            ADD CONSTRAINT malu$model_provider_owner_provider_name_key
            UNIQUE (owner_schema, provider_name);
    END IF;
END
$mig$;

-- ===== 2. provider lookup in register_model_alias becomes schema-aware =
-- Provider names are now only per-tenant unique, so resolve within the
-- caller's schema first, then fall back to the shared 'maludb_core'
-- namespace (preserves existing admin/global workflows). INVOKER + the
-- existing admin RLS gate are unchanged.
CREATE OR REPLACE FUNCTION maludb_core.register_model_alias(
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
      FROM maludb_core.malu$model_provider
     WHERE provider_name = p_provider AND owner_schema = current_schema();
    IF v_provider_id IS NULL THEN
        SELECT provider_id INTO v_provider_id
          FROM maludb_core.malu$model_provider
         WHERE provider_name = p_provider AND owner_schema = 'maludb_core';
    END IF;
    IF v_provider_id IS NULL THEN
        RAISE EXCEPTION 'unknown provider: %', p_provider
            USING ERRCODE = 'foreign_key_violation';
    END IF;
    INSERT INTO maludb_core.malu$model_alias
           (alias_name, provider_id, model_identifier,
            model_path, model_hash, quantization, context_length, runtime_params)
    VALUES (p_alias,    v_provider_id, p_model_identifier,
            p_model_path, p_model_hash, p_quantization, p_context_length, p_runtime_params)
    RETURNING alias_id INTO v_alias_id;
    RETURN v_alias_id;
END;
$body$;

-- ===== 3a. owner_schema-scoped registration helpers (DEFINER) ========
-- These run as the extension owner (so they get through the admin-only RLS
-- on the gateway tables) but write ONLY the owner_schema passed in by the
-- schema-local facade, which bakes current_schema() -- never a caller value.
CREATE FUNCTION maludb_core._register_model_provider_for_schema(
    p_owner_schema     name,
    p_name             text,
    p_kind             text,
    p_adapter_name     text DEFAULT NULL,
    p_secret_ref       text DEFAULT NULL,
    p_data_sensitivity text DEFAULT 'internal'
) RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
DECLARE
    v_id   bigint;
    v_name text := btrim(COALESCE(p_name, ''));
BEGIN
    PERFORM maludb_core._memory_schema_assert_manageable(p_owner_schema);
    IF v_name = '' THEN
        RAISE EXCEPTION 'register_model_provider: provider name is required'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;
    IF p_kind NOT IN ('cloud_api','local_http','local_socket','local_runtime',
                      'shell_adapter','stub') THEN
        RAISE EXCEPTION 'invalid provider kind: % (expected cloud_api, local_http, local_socket, local_runtime, shell_adapter, stub)', p_kind
            USING ERRCODE = 'check_violation';
    END IF;

    INSERT INTO maludb_core.malu$model_provider
           (owner_schema, provider_name, provider_kind, adapter_name, secret_ref, data_sensitivity)
    VALUES (p_owner_schema, v_name, p_kind, p_adapter_name, p_secret_ref,
            COALESCE(p_data_sensitivity, 'internal'))
    ON CONFLICT (owner_schema, provider_name) DO UPDATE SET
        provider_kind    = EXCLUDED.provider_kind,
        adapter_name     = EXCLUDED.adapter_name,
        secret_ref       = EXCLUDED.secret_ref,
        data_sensitivity = EXCLUDED.data_sensitivity,
        enabled          = true
    RETURNING provider_id INTO v_id;

    RETURN v_id;
END;
$body$;
REVOKE ALL ON FUNCTION maludb_core._register_model_provider_for_schema(name, text, text, text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core._register_model_provider_for_schema(name, text, text, text, text, text)
    TO maludb_memory_admin, maludb_memory_executor;

CREATE FUNCTION maludb_core._register_model_alias_for_schema(
    p_owner_schema     name,
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
SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
DECLARE
    v_provider_id bigint;
    v_alias_id    bigint;
    v_alias       text := btrim(COALESCE(p_alias, ''));
BEGIN
    PERFORM maludb_core._memory_schema_assert_manageable(p_owner_schema);
    IF v_alias = '' OR btrim(COALESCE(p_provider, '')) = ''
       OR btrim(COALESCE(p_model_identifier, '')) = '' THEN
        RAISE EXCEPTION 'register_model_alias: alias, provider and model_identifier are required'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    -- strictly the tenant's OWN provider (no cross-schema fallback: a tenant
    -- registers its own provider first).
    SELECT provider_id INTO v_provider_id
      FROM maludb_core.malu$model_provider
     WHERE owner_schema = p_owner_schema AND provider_name = btrim(p_provider);
    IF v_provider_id IS NULL THEN
        RAISE EXCEPTION 'register_model_alias: unknown provider % in schema % (register it with maludb_register_model_provider first)', p_provider, p_owner_schema
            USING ERRCODE = 'foreign_key_violation';
    END IF;

    INSERT INTO maludb_core.malu$model_alias
           (owner_schema, alias_name, provider_id, model_identifier,
            model_path, model_hash, quantization, context_length, runtime_params)
    VALUES (p_owner_schema, v_alias, v_provider_id, p_model_identifier,
            p_model_path, p_model_hash, p_quantization, p_context_length, p_runtime_params)
    ON CONFLICT (owner_schema, alias_name) DO UPDATE SET
        provider_id      = EXCLUDED.provider_id,
        model_identifier = EXCLUDED.model_identifier,
        model_path       = EXCLUDED.model_path,
        model_hash       = EXCLUDED.model_hash,
        quantization     = EXCLUDED.quantization,
        context_length   = EXCLUDED.context_length,
        runtime_params   = EXCLUDED.runtime_params,
        enabled          = true
    RETURNING alias_id INTO v_alias_id;

    RETURN v_alias_id;
END;
$body$;
REVOKE ALL ON FUNCTION maludb_core._register_model_alias_for_schema(name, text, text, text, text, text, text, integer, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core._register_model_alias_for_schema(name, text, text, text, text, text, text, integer, jsonb)
    TO maludb_memory_admin, maludb_memory_executor;

-- ===== 3b. schema-local facade builder ==============================
CREATE FUNCTION maludb_core._enable_memory_schema_0910_facade(p_schema name) RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
DECLARE
    v_count integer := 0;
BEGIN
    PERFORM maludb_core._memory_schema_assert_manageable(p_schema);

    -- maludb_register_model_provider(...) -> provider_id (own schema only)
    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_register_model_provider', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_register_model_provider(
            p_name text, p_kind text, p_adapter_name text DEFAULT NULL,
            p_secret_ref text DEFAULT NULL, p_data_sensitivity text DEFAULT 'internal'
        ) RETURNS bigint LANGUAGE sql SECURITY DEFINER
        SET search_path = pg_catalog, maludb_core, pg_temp
        AS $facade$ SELECT maludb_core._register_model_provider_for_schema(
            %L::name, p_name, p_kind, p_adapter_name, p_secret_ref, p_data_sensitivity) $facade$
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_register_model_provider(text, text, text, text, text) FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_register_model_provider(text, text, text, text, text) TO maludb_memory_admin, maludb_memory_executor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_register_model_provider', 'function', 'Self-service per-tenant model provider registration (own schema only).');
    v_count := v_count + 1;

    -- maludb_register_model_alias(...) -> alias_id (own schema only)
    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_register_model_alias', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_register_model_alias(
            p_alias text, p_provider text, p_model_identifier text,
            p_model_path text DEFAULT NULL, p_model_hash text DEFAULT NULL,
            p_quantization text DEFAULT NULL, p_context_length integer DEFAULT NULL,
            p_runtime_params jsonb DEFAULT NULL
        ) RETURNS bigint LANGUAGE sql SECURITY DEFINER
        SET search_path = pg_catalog, maludb_core, pg_temp
        AS $facade$ SELECT maludb_core._register_model_alias_for_schema(
            %L::name, p_alias, p_provider, p_model_identifier,
            p_model_path, p_model_hash, p_quantization, p_context_length, p_runtime_params) $facade$
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_register_model_alias(text, text, text, text, text, text, integer, jsonb) FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_register_model_alias(text, text, text, text, text, text, integer, jsonb) TO maludb_memory_admin, maludb_memory_executor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_register_model_alias', 'function', 'Self-service per-tenant model alias registration (own schema only).');
    v_count := v_count + 1;

    -- read views (owner-rights: NOT security_invoker, so they read the
    -- admin-RLS'd tables as the extension owner, filtered to THIS schema).
    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_model_provider', 'view');
    EXECUTE format($sql$
        CREATE OR REPLACE VIEW %I.maludb_model_provider AS
        SELECT provider_id, provider_name, provider_kind, adapter_name,
               secret_ref, data_sensitivity, enabled, created_at
          FROM maludb_core.malu$model_provider
         WHERE owner_schema = %L
    $sql$, p_schema, p_schema);
    EXECUTE format('GRANT SELECT ON %I.maludb_model_provider TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_model_provider', 'view', 'This schema''s model providers.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_model_alias', 'view');
    EXECUTE format($sql$
        CREATE OR REPLACE VIEW %I.maludb_model_alias AS
        SELECT a.alias_id, a.alias_name, a.provider_id, p.provider_name,
               a.model_identifier, a.context_length, a.runtime_params,
               a.enabled, a.created_at
          FROM maludb_core.malu$model_alias a
          LEFT JOIN maludb_core.malu$model_provider p ON p.provider_id = a.provider_id
         WHERE a.owner_schema = %L
    $sql$, p_schema, p_schema);
    EXECUTE format('GRANT SELECT ON %I.maludb_model_alias TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_model_alias', 'view', 'This schema''s model aliases.');
    v_count := v_count + 1;

    RETURN v_count;
END;
$body$;

REVOKE ALL ON FUNCTION maludb_core._enable_memory_schema_0910_facade(name) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core._enable_memory_schema_0910_facade(name)
    TO maludb_memory_admin, maludb_memory_executor;

-- ===== wire the 0910 facade into enable_memory_schema ================
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
