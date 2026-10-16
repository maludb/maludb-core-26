\echo Use "ALTER EXTENSION maludb_core UPDATE TO '0.22.0'" to load this file. \quit

-- =====================================================================
-- maludb_core 0.21.0 → 0.22.0
--
-- Stage 2 — pgaudit + pg_stat_statements wiring (S2-9).
--
-- Closes Stage 2. Per requirements.md §9: "pgaudit +
-- pg_stat_statements configured."
--
-- The two extensions both require shared_preload_libraries entries.
-- This migration cannot CREATE EXTENSION on a cluster that hasn't
-- been preloaded, so we ship:
--
--   1. audit_status() — reports per-extension presence + preload
--      state so operators can verify their cluster config.
--   2. pgaudit_recommended_settings() — returns the postgresql.conf
--      lines operators need to add (and the corresponding
--      shared_preload_libraries entries).
--   3. malu$audit_event — SQL-queryable governance audit. pgaudit
--      writes OS-level logs for compliance; malu$audit_event gives
--      ops + UX a row-level view of who did what to which Stage 2
--      object when.
--   4. audit_event(...) helper that retrofitted lifecycle functions
--      (seal/unseal/tombstone/grant/revoke) call to record their
--      transitions.
--   5. malu$query_stats view — created only when pg_stat_statements
--      is actually installed (DO block guards the CREATE).
-- =====================================================================

CREATE OR REPLACE FUNCTION maludb_core_version() RETURNS text
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$ SELECT '0.22.0'::text $body$;

-- =====================================================================
-- malu$audit_event
-- =====================================================================
CREATE TABLE malu$audit_event (
    event_id            bigserial PRIMARY KEY,
    owner_schema        name NOT NULL DEFAULT current_schema(),
    actor_role          name NOT NULL DEFAULT current_user,
    event_kind          text NOT NULL,
    target_object_type  text,
    target_object_id    bigint,
    event_jsonb         jsonb,
    error_text          text,
    occurred_at         timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX malu$audit_event_owner_kind_idx
    ON malu$audit_event(owner_schema, event_kind, occurred_at DESC);
CREATE INDEX malu$audit_event_target_idx
    ON malu$audit_event(target_object_type, target_object_id)
    WHERE target_object_id IS NOT NULL;

ALTER TABLE malu$audit_event ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_owner ON malu$audit_event
    USING (owner_schema = current_schema())
    WITH CHECK (owner_schema = current_schema());

GRANT SELECT ON malu$audit_event TO
    maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;
GRANT INSERT ON malu$audit_event TO
    maludb_memory_admin, maludb_memory_executor;
GRANT USAGE, SELECT ON SEQUENCE malu$audit_event_event_id_seq TO
    maludb_memory_admin, maludb_memory_executor;

-- ---------------------------------------------------------------------
-- audit_event — internal helper that all retrofitted lifecycle
-- functions call. SECURITY INVOKER so actor_role tracks the caller,
-- not the function owner.
-- ---------------------------------------------------------------------
CREATE FUNCTION audit_event(
    p_event_kind         text,
    p_target_object_type text   DEFAULT NULL,
    p_target_object_id   bigint DEFAULT NULL,
    p_event_jsonb        jsonb  DEFAULT NULL,
    p_error_text         text   DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql SECURITY INVOKER
AS $body$
DECLARE v_id bigint;
BEGIN
    INSERT INTO malu$audit_event
        (event_kind, target_object_type, target_object_id,
         event_jsonb, error_text)
    VALUES (p_event_kind, p_target_object_type, p_target_object_id,
            p_event_jsonb, p_error_text)
    RETURNING event_id INTO v_id;
    RETURN v_id;
END;
$body$;

-- =====================================================================
-- audit_status — reports the state of each governance/observability
-- extension. Operators check this once after install and after any
-- postgresql.conf change.
-- =====================================================================
CREATE FUNCTION audit_status() RETURNS TABLE (
    component  text,
    available  boolean,
    preloaded  boolean,
    installed  boolean,
    note       text
) LANGUAGE sql STABLE
AS $body$
    SELECT 'pg_stat_statements'::text,
           EXISTS (SELECT 1 FROM pg_available_extensions WHERE name='pg_stat_statements'),
           current_setting('shared_preload_libraries', true) LIKE '%pg_stat_statements%',
           EXISTS (SELECT 1 FROM pg_extension WHERE extname='pg_stat_statements'),
           CASE
             WHEN EXISTS (SELECT 1 FROM pg_extension WHERE extname='pg_stat_statements')
               THEN 'ready'
             WHEN current_setting('shared_preload_libraries', true) LIKE '%pg_stat_statements%'
               THEN 'preloaded; run CREATE EXTENSION pg_stat_statements'
             WHEN EXISTS (SELECT 1 FROM pg_available_extensions WHERE name='pg_stat_statements')
               THEN 'add to shared_preload_libraries + restart'
             ELSE 'install postgresql-NN-pg-stat-statements package'
           END
    UNION ALL
    SELECT 'pgaudit',
           EXISTS (SELECT 1 FROM pg_available_extensions WHERE name='pgaudit'),
           current_setting('shared_preload_libraries', true) LIKE '%pgaudit%',
           EXISTS (SELECT 1 FROM pg_extension WHERE extname='pgaudit'),
           CASE
             WHEN EXISTS (SELECT 1 FROM pg_extension WHERE extname='pgaudit')
               THEN 'ready'
             WHEN current_setting('shared_preload_libraries', true) LIKE '%pgaudit%'
               THEN 'preloaded; run CREATE EXTENSION pgaudit'
             WHEN EXISTS (SELECT 1 FROM pg_available_extensions WHERE name='pgaudit')
               THEN 'add to shared_preload_libraries + restart'
             ELSE 'install postgresql-NN-pgaudit package'
           END
    UNION ALL
    SELECT 'malu$audit_event',
           true, true,
           true,
           'SQL-side audit table: governance lifecycle events for ' ||
           'seal/unseal/tombstone/grant/revoke transitions';
$body$;

-- =====================================================================
-- pgaudit_recommended_settings — postgresql.conf lines operators
-- should add. Returned as a single text block so it can be piped
-- straight into a config-management tool.
-- =====================================================================
CREATE FUNCTION pgaudit_recommended_settings() RETURNS text
LANGUAGE sql IMMUTABLE
AS $body$
    SELECT $cfg$
# --- MaluDB Stage 2 S2-9 recommended postgresql.conf additions ---
# shared_preload_libraries must include both:
shared_preload_libraries = 'pg_stat_statements,pgaudit'

# pg_stat_statements: capture top-level + nested. Bump tracked-
# statement count for governance review.
pg_stat_statements.track = 'all'
pg_stat_statements.max  = 10000

# pgaudit: governance-grade log subset. Adjust per compliance
# requirements; 'role' captures GRANT/REVOKE for audit.
pgaudit.log = 'ddl,role,write'
pgaudit.log_relation = on
pgaudit.log_catalog  = off
pgaudit.log_parameter = off       # avoid leaking secrets to logs
pgaudit.log_statement_once = on
# --------------------------------------------------------------------
$cfg$::text;
$body$;

-- =====================================================================
-- malu$query_stats view — only created when pg_stat_statements is
-- actually installed in this database. Otherwise the migration
-- skips the CREATE and operators run CREATE OR REPLACE later via
-- maludb_core_attach_stat_statements_view().
-- =====================================================================
CREATE FUNCTION maludb_core_attach_stat_statements_view() RETURNS void
LANGUAGE plpgsql
AS $body$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname='pg_stat_statements') THEN
        RAISE NOTICE 'pg_stat_statements not installed; skipping malu$query_stats view';
        RETURN;
    END IF;

    EXECUTE $view$
        CREATE OR REPLACE VIEW malu$query_stats AS
        SELECT
            d.datname,
            r.rolname,
            s.queryid,
            s.calls,
            s.total_exec_time,
            s.mean_exec_time,
            s.rows AS total_rows,
            s.shared_blks_hit,
            s.shared_blks_read,
            substring(s.query, 1, 240) AS query_preview
        FROM pg_stat_statements s
        JOIN pg_database d ON d.oid = s.dbid
        JOIN pg_roles    r ON r.oid = s.userid
        WHERE current_setting('is_superuser') = 'on'
           OR r.rolname = current_user
    $view$;

    EXECUTE 'GRANT SELECT ON malu$query_stats TO ' ||
            'maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor';
END;
$body$;

-- Attempt the attach now; emits a notice on systems without the
-- extension preloaded and continues.
SELECT maludb_core_attach_stat_statements_view();

-- =====================================================================
-- Retrofit S2-2 + S2-5 lifecycle functions to call audit_event(). We
-- use CREATE OR REPLACE to update bodies; signatures are unchanged.
-- =====================================================================

-- ---- seal_source_package -------------------------------------------
CREATE OR REPLACE FUNCTION seal_source_package(
    p_source_package_id bigint,
    p_placement_tier    text DEFAULT 'inline',
    p_external_uri      text DEFAULT NULL,
    p_note              text DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql
AS $body$
DECLARE
    v_sp          malu$source_package%ROWTYPE;
    v_archive_id  bigint;
    v_size        bigint;
BEGIN
    SELECT * INTO v_sp FROM malu$source_package
     WHERE source_package_id = p_source_package_id;
    IF v_sp.source_package_id IS NULL THEN
        RAISE EXCEPTION 'unknown source_package_id: %', p_source_package_id
            USING ERRCODE = 'no_data_found';
    END IF;

    IF v_sp.sealed_at IS NOT NULL THEN
        SELECT archive_id INTO v_archive_id FROM malu$verbatim_archive
         WHERE source_package_id = p_source_package_id
           AND superseded_at IS NULL
         ORDER BY sealed_at DESC LIMIT 1;
        RETURN v_archive_id;
    END IF;

    UPDATE malu$source_package SET sealed_at = now()
     WHERE source_package_id = p_source_package_id;

    v_size := octet_length(_source_canonical_bytes(
                  v_sp.content_bytes, v_sp.content_text, v_sp.content_jsonb));

    INSERT INTO malu$verbatim_archive
        (source_package_id, placement_tier, content_size_archived,
         archive_hash, external_uri, note)
    VALUES (p_source_package_id, p_placement_tier, v_size,
            v_sp.content_hash, p_external_uri, p_note)
    RETURNING archive_id INTO v_archive_id;

    PERFORM audit_event('seal_source_package', 'source_package', p_source_package_id,
        jsonb_build_object('placement_tier', p_placement_tier,
                           'archive_id',     v_archive_id,
                           'external_uri',   p_external_uri));

    RETURN v_archive_id;
END;
$body$;

-- ---- unseal_source_package -----------------------------------------
CREATE OR REPLACE FUNCTION unseal_source_package(
    p_source_package_id bigint,
    p_reason            text
) RETURNS void
LANGUAGE plpgsql
AS $body$
BEGIN
    IF p_reason IS NULL OR p_reason = '' THEN
        RAISE EXCEPTION 'unseal_source_package: reason required'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    PERFORM 1 FROM malu$source_package
     WHERE source_package_id = p_source_package_id AND sealed_at IS NOT NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION
          'source_package_id=% is not currently sealed',
          p_source_package_id
          USING ERRCODE = 'object_not_in_prerequisite_state';
    END IF;

    UPDATE malu$verbatim_archive
       SET superseded_at = now()
     WHERE source_package_id = p_source_package_id
       AND superseded_at IS NULL;

    UPDATE malu$source_package SET sealed_at = NULL
     WHERE source_package_id = p_source_package_id;

    INSERT INTO malu$verbatim_archive
        (source_package_id, placement_tier, archive_hash, note, sealed_at, superseded_at)
    VALUES (p_source_package_id, 'inline',
            (SELECT content_hash FROM malu$source_package
              WHERE source_package_id = p_source_package_id),
            'unseal: ' || p_reason,
            now(), now());

    PERFORM audit_event('unseal_source_package', 'source_package', p_source_package_id,
        jsonb_build_object('reason', p_reason));
END;
$body$;

-- ---- tombstone_source_package --------------------------------------
CREATE OR REPLACE FUNCTION tombstone_source_package(
    p_source_package_id bigint,
    p_reason            text
) RETURNS void
LANGUAGE plpgsql
AS $body$
DECLARE
    v_sp malu$source_package%ROWTYPE;
BEGIN
    IF p_reason IS NULL OR p_reason = '' THEN
        RAISE EXCEPTION 'tombstone_source_package: reason required'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    SELECT * INTO v_sp FROM malu$source_package
     WHERE source_package_id = p_source_package_id;
    IF v_sp.source_package_id IS NULL THEN
        RAISE EXCEPTION 'unknown source_package_id: %', p_source_package_id
            USING ERRCODE = 'no_data_found';
    END IF;

    UPDATE malu$source_package
       SET sealed_at     = NULL,
           tombstoned_at = now()
     WHERE source_package_id = p_source_package_id;

    INSERT INTO malu$verbatim_archive
        (source_package_id, placement_tier, archive_hash, note, sealed_at, superseded_at)
    VALUES (p_source_package_id, 'inline', v_sp.content_hash,
            'tombstone: ' || p_reason, now(), now());

    IF NOT v_sp.legal_hold THEN
        UPDATE malu$source_package
           SET content_bytes = NULL,
               content_text  = NULL,
               content_jsonb = NULL
         WHERE source_package_id = p_source_package_id;
        UPDATE malu$source_package SET sealed_at = now()
         WHERE source_package_id = p_source_package_id;
        UPDATE malu$verbatim_archive
           SET superseded_at = now()
         WHERE source_package_id = p_source_package_id
           AND superseded_at    IS NULL
           AND placement_tier   IN ('inline','hot','warm');
    END IF;

    PERFORM audit_event('tombstone_source_package', 'source_package', p_source_package_id,
        jsonb_build_object('reason', p_reason, 'legal_hold', v_sp.legal_hold));
END;
$body$;

-- ---- grant_object_access -------------------------------------------
CREATE OR REPLACE FUNCTION grant_object_access(
    p_object_type      text,
    p_object_id        bigint,
    p_granted_to_schema name,
    p_grant_level      text       DEFAULT 'read',
    p_expires_at       timestamptz DEFAULT NULL,
    p_note             text       DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql
AS $body$
DECLARE
    v_id     bigint;
    v_exists boolean;
BEGIN
    IF p_grant_level NOT IN ('read','write','full') THEN
        RAISE EXCEPTION 'grant_object_access: bad level %', p_grant_level
            USING ERRCODE = 'invalid_parameter_value';
    END IF;
    IF p_granted_to_schema IS NULL OR p_granted_to_schema = current_schema() THEN
        RAISE EXCEPTION 'grant_object_access: must grant to a different schema'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    EXECUTE format(
        'SELECT EXISTS (SELECT 1 FROM maludb_core.%I WHERE %I = $1)',
        CASE p_object_type
            WHEN 'source_package'        THEN 'malu$source_package'
            WHEN 'claim'                 THEN 'malu$claim'
            WHEN 'fact'                  THEN 'malu$fact'
            WHEN 'memory'                THEN 'malu$memory'
            WHEN 'episode_object'        THEN 'malu$episode_object'
            WHEN 'memory_detail_object'  THEN 'malu$memory_detail_object'
            WHEN 'relationship_edge'     THEN 'malu$relationship_edge'
            WHEN 'derivation_ledger'     THEN 'malu$derivation_ledger'
        END,
        CASE p_object_type
            WHEN 'source_package'        THEN 'source_package_id'
            WHEN 'claim'                 THEN 'claim_id'
            WHEN 'fact'                  THEN 'fact_id'
            WHEN 'memory'                THEN 'memory_id'
            WHEN 'episode_object'        THEN 'episode_id'
            WHEN 'memory_detail_object'  THEN 'mdo_id'
            WHEN 'relationship_edge'     THEN 'edge_id'
            WHEN 'derivation_ledger'     THEN 'derivation_id'
        END
    ) INTO v_exists USING p_object_id;
    IF NOT v_exists THEN
        RAISE EXCEPTION 'grant_object_access: %s id=% not visible to current schema',
            p_object_type, p_object_id
            USING ERRCODE = 'no_data_found';
    END IF;

    UPDATE malu$object_grant
       SET grant_level = p_grant_level,
           expires_at  = p_expires_at,
           note        = COALESCE(p_note, note),
           granted_at  = now()
     WHERE object_type        = p_object_type
       AND object_id          = p_object_id
       AND granted_to_schema  = p_granted_to_schema
       AND revoked_at         IS NULL
     RETURNING grant_id INTO v_id;
    IF FOUND THEN
        PERFORM audit_event('grant_upgrade', p_object_type, p_object_id,
            jsonb_build_object('grant_id', v_id, 'granted_to', p_granted_to_schema,
                               'grant_level', p_grant_level));
        RETURN v_id;
    END IF;

    INSERT INTO malu$object_grant
        (object_type, object_id, granted_to_schema,
         grant_level, expires_at, note)
    VALUES (p_object_type, p_object_id, p_granted_to_schema,
            p_grant_level, p_expires_at, p_note)
    RETURNING grant_id INTO v_id;

    PERFORM audit_event('grant', p_object_type, p_object_id,
        jsonb_build_object('grant_id', v_id, 'granted_to', p_granted_to_schema,
                           'grant_level', p_grant_level));
    RETURN v_id;
END;
$body$;

-- ---- revoke_object_grant -------------------------------------------
CREATE OR REPLACE FUNCTION revoke_object_grant(
    p_grant_id bigint,
    p_reason   text DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql
AS $body$
DECLARE v_obj_type text; v_obj_id bigint;
BEGIN
    SELECT object_type, object_id INTO v_obj_type, v_obj_id
    FROM malu$object_grant WHERE grant_id = p_grant_id AND revoked_at IS NULL;

    UPDATE malu$object_grant
       SET revoked_at = now(),
           note       = COALESCE(note || E'\n', '') ||
                        'revoked: ' || COALESCE(p_reason, 'no reason given')
     WHERE grant_id = p_grant_id
       AND revoked_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'revoke_object_grant: grant_id=% not found or already revoked',
            p_grant_id
            USING ERRCODE = 'no_data_found';
    END IF;

    PERFORM audit_event('revoke', v_obj_type, v_obj_id,
        jsonb_build_object('grant_id', p_grant_id, 'reason', p_reason));
END;
$body$;

GRANT EXECUTE ON FUNCTION
    audit_event(text, text, bigint, jsonb, text),
    audit_status(),
    pgaudit_recommended_settings(),
    maludb_core_attach_stat_statements_view()
TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;
