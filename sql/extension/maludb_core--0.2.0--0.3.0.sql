\echo Use "ALTER EXTENSION maludb_core UPDATE TO '0.3.0'" to load this file. \quit

-- =====================================================================
-- maludb_core 0.2.0 → 0.3.0
--
-- R1.1-7: LLM-specific role and permission model with row-level
-- security. Adds six functional roles and turns RLS on for the
-- LLM-tenancy tables (prompt_template, session, session_context,
-- prompt_render, model_request, model_response, model_provider,
-- model_alias).
--
-- Tenancy binding is GUC-primary with a session_user fallback:
--   1. If `maludb_core.current_account_id` GUC is set, use it.
--   2. Else if `session_user` matches a row in `malu$account`,
--      use that account_id.
--   3. Else `current_account_id()` returns NULL → user sees no rows.
--
-- Service / superuser roles bypass RLS:
--   - maludb_llm_admin (BYPASSRLS) — full ALL access
--   - maludb_llm_auditor (BYPASSRLS) — SELECT-only across the surface
--
-- Operator follow-up after upgrade (NOT performed by this script):
--   GRANT maludb_llm_executor    TO maludb_mc2dbd;
--   GRANT maludb_llm_admin       TO maludb_modeld;   -- needs cross-tenant view
--   (or whatever roles the bootstrap created for the service users)
--
-- Apply with:
--   ALTER EXTENSION maludb_core UPDATE TO '0.3.0';
-- =====================================================================

-- ---------------------------------------------------------------------
-- Version bump
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION maludb_core_version() RETURNS text
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$ SELECT '0.3.0'::text $body$;

-- ---------------------------------------------------------------------
-- Roles. NOLOGIN — these are group roles that operators GRANT to the
-- actual login roles (humans, service accounts, mc2dbd, modeld, etc).
-- BYPASSRLS only where the role is meant to operate across tenants.
-- ---------------------------------------------------------------------
DO $body$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'maludb_llm_admin') THEN
        CREATE ROLE maludb_llm_admin NOLOGIN BYPASSRLS;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'maludb_llm_prompt_author') THEN
        CREATE ROLE maludb_llm_prompt_author NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'maludb_llm_prompt_approver') THEN
        CREATE ROLE maludb_llm_prompt_approver NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'maludb_llm_model_admin') THEN
        CREATE ROLE maludb_llm_model_admin NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'maludb_llm_executor') THEN
        CREATE ROLE maludb_llm_executor NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'maludb_llm_auditor') THEN
        CREATE ROLE maludb_llm_auditor NOLOGIN BYPASSRLS;
    END IF;
END;
$body$;

-- ---------------------------------------------------------------------
-- Tenancy helper. GUC-primary; session_user → account_name fallback.
--
-- SECURITY DEFINER so RLS-restricted roles can resolve their own
-- tenant without needing SELECT on `malu$account`. SET search_path is
-- pinned to avoid the classic definer-function hijack via a
-- caller-controlled search_path. STABLE: result is consistent within a
-- single query.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION current_account_id() RETURNS bigint
    LANGUAGE plpgsql STABLE PARALLEL SAFE
    SECURITY DEFINER
    SET search_path = pg_catalog, maludb_core
    AS $body$
DECLARE
    v_guc text;
    v_id  bigint;
BEGIN
    v_guc := current_setting('maludb_core.current_account_id', true);
    IF v_guc IS NOT NULL AND v_guc <> '' THEN
        BEGIN
            RETURN v_guc::bigint;
        EXCEPTION WHEN invalid_text_representation THEN
            RETURN NULL;
        END;
    END IF;
    SELECT account_id INTO v_id
    FROM malu$account
    WHERE account_name = session_user
      AND enabled;
    RETURN v_id;
END;
$body$;

GRANT EXECUTE ON FUNCTION current_account_id() TO
    maludb_llm_admin, maludb_llm_prompt_author, maludb_llm_prompt_approver,
    maludb_llm_model_admin, maludb_llm_executor, maludb_llm_auditor;

COMMENT ON FUNCTION current_account_id() IS
    'Returns the account_id for the current session. Reads the '
    '`maludb_core.current_account_id` GUC first; falls back to the row in '
    '`malu$account` whose account_name matches session_user. Returns NULL '
    'when neither path matches — RLS policies treat NULL as no-tenant and '
    'filter out all rows (fail-closed).';

-- ---------------------------------------------------------------------
-- Schema-level USAGE grants. Without USAGE on the schema, the role
-- cannot even resolve table names; the table-level grants below would
-- be inert.
-- ---------------------------------------------------------------------
GRANT USAGE ON SCHEMA maludb_core TO
    maludb_llm_admin,
    maludb_llm_prompt_author,
    maludb_llm_prompt_approver,
    maludb_llm_model_admin,
    maludb_llm_executor,
    maludb_llm_auditor;

-- ---------------------------------------------------------------------
-- Table-level grants per role.
--
-- The matrix:
--                            tmpl  ses  sctx ren  req  res  prov alia
--   admin                    ALL   ALL  ALL  ALL  ALL  ALL  ALL  ALL
--   prompt_author            CRUD  -    -    R    R    R    R    R
--   prompt_approver          RU    -    -    -    -    -    R    R
--   model_admin              R     -    -    -    -    -    CRUD CRUD
--   executor                 R     CRUD CRUD CRUD CRUD R    R    R
--   auditor                  R     R    R    R    R    R    R    R
--
-- (R = SELECT, CRUD = SELECT+INSERT+UPDATE+DELETE, RU = SELECT+UPDATE)
-- ---------------------------------------------------------------------

-- All LLM roles get read access to the identity reference tables.
-- malu$account / malu$role / malu$account_role are not row-filtered;
-- identity metadata is cluster-wide reference data. Grants only —
-- mutation stays restricted to the admin role.
GRANT SELECT ON malu$account, malu$role, malu$account_role TO
    maludb_llm_admin,
    maludb_llm_prompt_author,
    maludb_llm_prompt_approver,
    maludb_llm_model_admin,
    maludb_llm_executor,
    maludb_llm_auditor;
GRANT INSERT, UPDATE, DELETE ON malu$account, malu$role, malu$account_role
    TO maludb_llm_admin;

-- admin: ALL on everything LLM-related
GRANT ALL ON
    malu$prompt_template, malu$session, malu$session_context,
    malu$prompt_render, malu$model_request, malu$model_response,
    malu$model_provider, malu$model_alias
TO maludb_llm_admin;

-- prompt_author: CRUD on prompt_template; read on related (no direct
-- access to `malu$model_provider` — only the public view, so secret_ref
-- is never reachable).
GRANT SELECT, INSERT, UPDATE, DELETE ON malu$prompt_template TO maludb_llm_prompt_author;
GRANT SELECT ON
    malu$session, malu$session_context, malu$prompt_render,
    malu$model_request, malu$model_response,
    malu$model_alias
TO maludb_llm_prompt_author;

-- prompt_approver: SELECT + UPDATE on prompt_template (for R1.1-6 status transitions)
GRANT SELECT, UPDATE ON malu$prompt_template TO maludb_llm_prompt_approver;
GRANT SELECT ON malu$model_alias TO maludb_llm_prompt_approver;

-- model_admin: CRUD on provider + alias
GRANT SELECT, INSERT, UPDATE, DELETE ON malu$model_provider, malu$model_alias
    TO maludb_llm_model_admin;
GRANT SELECT ON malu$prompt_template TO maludb_llm_model_admin;

-- executor: run sessions, render prompts, submit requests
GRANT SELECT ON malu$prompt_template, malu$model_alias TO maludb_llm_executor;
GRANT SELECT, INSERT, UPDATE, DELETE ON
    malu$session, malu$session_context, malu$prompt_render, malu$model_request
TO maludb_llm_executor;
GRANT SELECT ON malu$model_response TO maludb_llm_executor;

-- All LLM roles need sequence USAGE on the tables they can INSERT into.
-- Granting ALL SEQUENCES is broader than strictly necessary (covers
-- non-LLM tables like vector_*) but avoids brittleness around the
-- $-containing default sequence names.
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA maludb_core TO
    maludb_llm_admin,
    maludb_llm_prompt_author,
    maludb_llm_model_admin,
    maludb_llm_executor;

-- auditor: SELECT everywhere LLM-related (BYPASSRLS = sees all tenants)
GRANT SELECT ON
    malu$prompt_template, malu$session, malu$session_context,
    malu$prompt_render, malu$model_request, malu$model_response,
    malu$model_provider, malu$model_alias
TO maludb_llm_auditor;

-- ---------------------------------------------------------------------
-- A view that hides the sensitive `secret_ref` column on
-- `malu$model_provider`. Most callers should go through this view;
-- only model_admin and BYPASSRLS roles get direct table SELECT.
-- ---------------------------------------------------------------------
CREATE VIEW malu_provider_public AS
SELECT provider_id, provider_name, provider_kind, adapter_name,
       data_sensitivity, enabled, created_at
FROM malu$model_provider;

GRANT SELECT ON malu_provider_public TO
    maludb_llm_prompt_author,
    maludb_llm_prompt_approver,
    maludb_llm_executor,
    maludb_llm_auditor,
    maludb_llm_model_admin,
    maludb_llm_admin;

-- ---------------------------------------------------------------------
-- Row-level security policies.
--
-- Pattern: per-table ENABLE ROW LEVEL SECURITY, then one or more
-- permissive policies. Multiple permissive policies OR together.
--
-- Tenant rows: USING (account_id IS NULL OR account_id = current_account_id()).
-- Child rows (via session/request): USING ( parent EXISTS where parent
--   account matches ).
-- Catalog rows (provider, alias): readable by all SELECT-grantees;
--   writable only via a role check.
-- ---------------------------------------------------------------------

-- prompt_template — NULL owner = shared/global template
ALTER TABLE malu$prompt_template ENABLE ROW LEVEL SECURITY;
CREATE POLICY prompt_template_tenant
    ON malu$prompt_template
    USING (
        owner_account_id IS NULL
        OR owner_account_id = current_account_id()
    )
    WITH CHECK (
        owner_account_id IS NULL
        OR owner_account_id = current_account_id()
    );

-- session — must belong to current tenant
ALTER TABLE malu$session ENABLE ROW LEVEL SECURITY;
CREATE POLICY session_tenant
    ON malu$session
    USING (account_id = current_account_id())
    WITH CHECK (account_id = current_account_id());

-- session_context — visible iff parent session is visible
ALTER TABLE malu$session_context ENABLE ROW LEVEL SECURITY;
CREATE POLICY session_context_via_session
    ON malu$session_context
    USING (
        EXISTS (
            SELECT 1 FROM malu$session s
            WHERE s.session_id = malu$session_context.session_id
              AND s.account_id = current_account_id()
        )
    )
    WITH CHECK (
        EXISTS (
            SELECT 1 FROM malu$session s
            WHERE s.session_id = malu$session_context.session_id
              AND s.account_id = current_account_id()
        )
    );

-- prompt_render — NULL account = anonymous render (shared visibility)
ALTER TABLE malu$prompt_render ENABLE ROW LEVEL SECURITY;
CREATE POLICY prompt_render_tenant
    ON malu$prompt_render
    USING (account_id IS NULL OR account_id = current_account_id())
    WITH CHECK (account_id IS NULL OR account_id = current_account_id());

-- model_request — same shape as prompt_render
ALTER TABLE malu$model_request ENABLE ROW LEVEL SECURITY;
CREATE POLICY model_request_tenant
    ON malu$model_request
    USING (account_id IS NULL OR account_id = current_account_id())
    WITH CHECK (account_id IS NULL OR account_id = current_account_id());

-- model_response — visible iff parent request is visible
ALTER TABLE malu$model_response ENABLE ROW LEVEL SECURITY;
CREATE POLICY model_response_via_request
    ON malu$model_response
    USING (
        EXISTS (
            SELECT 1 FROM malu$model_request r
            WHERE r.request_id = malu$model_response.request_id
              AND (r.account_id IS NULL OR r.account_id = current_account_id())
        )
    )
    WITH CHECK (
        EXISTS (
            SELECT 1 FROM malu$model_request r
            WHERE r.request_id = malu$model_response.request_id
              AND (r.account_id IS NULL OR r.account_id = current_account_id())
        )
    );

-- model_provider — readable by anyone with SELECT grant; writable only
-- if the caller has the model_admin role. The sensitive `secret_ref`
-- column is hidden behind `malu_provider_public` (above), so even
-- though SELECT here returns rows, non-admins shouldn't be GRANT'd
-- table-level SELECT in the first place (only the view).
ALTER TABLE malu$model_provider ENABLE ROW LEVEL SECURITY;
CREATE POLICY model_provider_read
    ON malu$model_provider
    FOR SELECT
    USING (
        pg_has_role(current_user, 'maludb_llm_model_admin', 'USAGE')
        OR pg_has_role(current_user, 'maludb_llm_auditor', 'USAGE')
    );
CREATE POLICY model_provider_write
    ON malu$model_provider
    FOR ALL
    USING (pg_has_role(current_user, 'maludb_llm_model_admin', 'USAGE'))
    WITH CHECK (pg_has_role(current_user, 'maludb_llm_model_admin', 'USAGE'));

-- model_alias — readable by all SELECT-grantees; writable by model_admin.
ALTER TABLE malu$model_alias ENABLE ROW LEVEL SECURITY;
CREATE POLICY model_alias_read
    ON malu$model_alias
    FOR SELECT
    USING (true);
CREATE POLICY model_alias_write
    ON malu$model_alias
    FOR ALL
    USING (pg_has_role(current_user, 'maludb_llm_model_admin', 'USAGE'))
    WITH CHECK (pg_has_role(current_user, 'maludb_llm_model_admin', 'USAGE'));
