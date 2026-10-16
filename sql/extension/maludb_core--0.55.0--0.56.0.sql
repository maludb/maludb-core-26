\echo Use "ALTER EXTENSION maludb_core UPDATE TO '0.56.0'" to load this file. \quit

-- =====================================================================
-- maludb_core 0.55.0 → 0.56.0
--
-- Stage 15 / V3-BACKUP-01: backup manifest + verification catalog.
--
-- The CLI's `maludb db backup` has emitted a sidecar manifest.json
-- since Stage 10. This migration adds the durable catalog so that
-- multiple manifests across a host's history are queryable, can
-- carry verification status, and can feed observability.
--
-- malu$backup_manifest enumerates every artifact that a full
-- maludb backup must capture:
--   * postgres_state_uri    (pg_dump | pg_basebackup)
--   * wal_archive_uri       (WAL archive base path)
--   * etc_maludb_uri        (/etc/maludb config tree)
--   * source_archive_manifest_uri (per V3-STOR-01)
--   * model_configs_uri     (provider/alias catalogs export)
--   * tls_uri               (TLS material)
--   * tool_binaries_uri     (external_exec helpers)
--   * broker_configs_uri    (mcp-broker config tree)
--
-- malu$backup_verification records the result of a restore-check.
--
-- Apply with:
--   ALTER EXTENSION maludb_core UPDATE TO '0.56.0';
-- =====================================================================

CREATE OR REPLACE FUNCTION maludb_core_version() RETURNS text
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$ SELECT '0.56.0'::text $body$;

-- ---------------------------------------------------------------------
-- malu$backup_manifest
-- ---------------------------------------------------------------------
CREATE TABLE malu$backup_manifest (
    manifest_id              bigserial PRIMARY KEY,
    label                    text,
    postgres_state_kind      text       NOT NULL CHECK (postgres_state_kind IN ('dump','basebackup')),
    postgres_state_uri       text       NOT NULL,
    wal_archive_uri          text,
    etc_maludb_uri           text,
    source_archive_manifest_uri text,
    model_configs_uri        text,
    tls_uri                  text,
    tool_binaries_uri        text,
    broker_configs_uri       text,
    extension_version        text       NOT NULL,
    hash_summary             jsonb      NOT NULL DEFAULT '{}'::jsonb,
    owner_schema             name       NOT NULL DEFAULT current_schema(),
    created_at               timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX malu$backup_manifest_owner_idx
    ON malu$backup_manifest(owner_schema, created_at DESC);

-- ---------------------------------------------------------------------
-- malu$backup_verification
-- ---------------------------------------------------------------------
CREATE TABLE malu$backup_verification (
    verification_id bigserial PRIMARY KEY,
    manifest_id     bigint     NOT NULL REFERENCES malu$backup_manifest(manifest_id) ON DELETE CASCADE,
    started_at      timestamptz NOT NULL DEFAULT now(),
    finished_at     timestamptz,
    status          text       NOT NULL CHECK (status IN ('running','passed','failed')) DEFAULT 'running',
    errors_jsonb    jsonb,
    notes           text
);
CREATE INDEX malu$backup_verification_manifest_idx
    ON malu$backup_verification(manifest_id, started_at DESC);

ALTER TABLE malu$backup_manifest ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_owner ON malu$backup_manifest
    USING      (owner_schema = current_schema())
    WITH CHECK (owner_schema = current_schema());

ALTER TABLE malu$backup_verification ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_via_manifest ON malu$backup_verification
    USING (
        EXISTS (SELECT 1 FROM malu$backup_manifest m
                WHERE m.manifest_id = malu$backup_verification.manifest_id
                  AND m.owner_schema = current_schema()))
    WITH CHECK (
        EXISTS (SELECT 1 FROM malu$backup_manifest m
                WHERE m.manifest_id = malu$backup_verification.manifest_id
                  AND m.owner_schema = current_schema()));

GRANT SELECT, INSERT, UPDATE, DELETE ON malu$backup_manifest, malu$backup_verification TO maludb_memory_admin;
GRANT SELECT, INSERT, UPDATE         ON malu$backup_manifest, malu$backup_verification TO maludb_memory_executor;
GRANT SELECT                          ON malu$backup_manifest, malu$backup_verification TO maludb_memory_auditor;

GRANT USAGE, SELECT ON SEQUENCE malu$backup_manifest_manifest_id_seq         TO maludb_memory_admin, maludb_memory_executor;
GRANT USAGE, SELECT ON SEQUENCE malu$backup_verification_verification_id_seq TO maludb_memory_admin, maludb_memory_executor;

-- =====================================================================
-- backup_manifest_record — records a manifest. The CLI/operator
-- prepares URIs + hashes; PG stores the catalog.
-- =====================================================================
CREATE FUNCTION backup_manifest_record(
    p_label                  text,
    p_postgres_state_kind    text,
    p_postgres_state_uri     text,
    p_hash_summary           jsonb,
    p_wal_archive_uri        text DEFAULT NULL,
    p_etc_maludb_uri         text DEFAULT NULL,
    p_source_archive_manifest_uri text DEFAULT NULL,
    p_model_configs_uri      text DEFAULT NULL,
    p_tls_uri                text DEFAULT NULL,
    p_tool_binaries_uri      text DEFAULT NULL,
    p_broker_configs_uri     text DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql VOLATILE AS $body$
#variable_conflict use_column
DECLARE v_id bigint;
BEGIN
    INSERT INTO malu$backup_manifest
        (label, postgres_state_kind, postgres_state_uri, hash_summary,
         wal_archive_uri, etc_maludb_uri, source_archive_manifest_uri,
         model_configs_uri, tls_uri, tool_binaries_uri, broker_configs_uri,
         extension_version)
    VALUES
        (p_label, p_postgres_state_kind, p_postgres_state_uri, p_hash_summary,
         p_wal_archive_uri, p_etc_maludb_uri, p_source_archive_manifest_uri,
         p_model_configs_uri, p_tls_uri, p_tool_binaries_uri, p_broker_configs_uri,
         maludb_core_version())
    RETURNING manifest_id INTO v_id;

    PERFORM audit_event('backup_manifest_record', 'malu$backup_manifest', v_id,
        jsonb_build_object('label', p_label, 'kind', p_postgres_state_kind,
                           'extension_version', maludb_core_version()),
        NULL);
    RETURN v_id;
END;
$body$;

CREATE FUNCTION backup_verification_record(
    p_manifest_id bigint,
    p_status      text,
    p_errors      jsonb DEFAULT NULL,
    p_notes       text  DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql VOLATILE AS $body$
#variable_conflict use_column
DECLARE v_id bigint;
BEGIN
    INSERT INTO malu$backup_verification
        (manifest_id, finished_at, status, errors_jsonb, notes)
    VALUES
        (p_manifest_id, now(), p_status, p_errors, p_notes)
    RETURNING verification_id INTO v_id;
    PERFORM audit_event('backup_verification_record', 'malu$backup_verification', v_id,
        jsonb_build_object('manifest_id', p_manifest_id, 'status', p_status),
        NULL);
    RETURN v_id;
END;
$body$;

CREATE FUNCTION backup_manifest_latest()
    RETURNS TABLE (
        manifest_id          bigint,
        label                text,
        postgres_state_kind  text,
        postgres_state_uri   text,
        extension_version    text,
        created_at           timestamptz,
        last_verification    text,
        last_verification_at timestamptz
    ) LANGUAGE plpgsql STABLE AS $body$
#variable_conflict use_column
BEGIN
    RETURN QUERY
    SELECT m.manifest_id, m.label, m.postgres_state_kind, m.postgres_state_uri,
           m.extension_version, m.created_at,
           v.status, v.finished_at
      FROM malu$backup_manifest m
      LEFT JOIN LATERAL (
            SELECT status, finished_at FROM malu$backup_verification vv
             WHERE vv.manifest_id = m.manifest_id
             ORDER BY vv.started_at DESC LIMIT 1
      ) v ON true
     ORDER BY m.created_at DESC
     LIMIT 1;
END;
$body$;

REVOKE EXECUTE ON FUNCTION backup_manifest_record(text, text, text, jsonb, text, text, text, text, text, text, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION backup_verification_record(bigint, text, jsonb, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION backup_manifest_latest() FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION backup_manifest_record(text, text, text, jsonb, text, text, text, text, text, text, text) TO maludb_memory_admin, maludb_memory_executor;
GRANT  EXECUTE ON FUNCTION backup_verification_record(bigint, text, jsonb, text) TO maludb_memory_admin, maludb_memory_executor;
GRANT  EXECUTE ON FUNCTION backup_manifest_latest() TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;
