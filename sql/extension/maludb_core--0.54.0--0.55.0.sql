\echo Use "ALTER EXTENSION maludb_core UPDATE TO '0.55.0'" to load this file. \quit

-- =====================================================================
-- maludb_core 0.54.0 → 0.55.0
--
-- Stage 15 / V3-LOG-01: log drain catalog.
--
-- Records the destination configurations for the future log-drain
-- service that tails PostgreSQL / audit / model / MC2DB / REST /
-- broker logs and batches them to HTTP, file, S3-compatible, or
-- OTLP-HTTP destinations. Destination credentials are referenced by
-- malu$secret name; the catalog never stores plaintext.
--
-- Apply with:
--   ALTER EXTENSION maludb_core UPDATE TO '0.55.0';
-- =====================================================================

CREATE OR REPLACE FUNCTION maludb_core_version() RETURNS text
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$ SELECT '0.55.0'::text $body$;

-- ---------------------------------------------------------------------
-- malu$log_drain
-- ---------------------------------------------------------------------
CREATE TABLE malu$log_drain (
    drain_id          bigserial PRIMARY KEY,
    name              text       NOT NULL,
    kind              text       NOT NULL CHECK (kind IN ('http','file','s3','otlp_http')),
    destination       jsonb      NOT NULL,
    destination_secret_ref text,
    source_streams    text[]     NOT NULL DEFAULT ARRAY[]::text[],
    -- source_streams entries: 'pg_log','audit_event','mc2db_invocation',
    -- 'rest_invocation','model_gateway','broker','secret_use'.
    redaction_rules   jsonb      NOT NULL DEFAULT '[]'::jsonb,
    enabled           boolean    NOT NULL DEFAULT true,
    batch_size        integer    NOT NULL DEFAULT 100 CHECK (batch_size > 0),
    flush_interval_ms integer    NOT NULL DEFAULT 5000 CHECK (flush_interval_ms > 0),
    owner_schema      name       NOT NULL DEFAULT current_schema(),
    created_at        timestamptz NOT NULL DEFAULT now(),
    retired_at        timestamptz,
    UNIQUE (owner_schema, name)
);
CREATE INDEX malu$log_drain_owner_idx
    ON malu$log_drain(owner_schema, enabled) WHERE retired_at IS NULL;

-- ---------------------------------------------------------------------
-- malu$log_drain_run — append-only run history.
-- ---------------------------------------------------------------------
CREATE TABLE malu$log_drain_run (
    run_id      bigserial PRIMARY KEY,
    drain_id    bigint     NOT NULL REFERENCES malu$log_drain(drain_id) ON DELETE CASCADE,
    started_at  timestamptz NOT NULL DEFAULT now(),
    finished_at timestamptz,
    batches     integer    NOT NULL DEFAULT 0,
    bytes       bigint     NOT NULL DEFAULT 0,
    records     integer    NOT NULL DEFAULT 0,
    errors      integer    NOT NULL DEFAULT 0,
    last_error  text
);
CREATE INDEX malu$log_drain_run_drain_idx
    ON malu$log_drain_run(drain_id, started_at DESC);

-- ---------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------
ALTER TABLE malu$log_drain ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_owner ON malu$log_drain
    USING      (owner_schema = current_schema())
    WITH CHECK (owner_schema = current_schema());

ALTER TABLE malu$log_drain_run ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_via_drain ON malu$log_drain_run
    USING (
        EXISTS (SELECT 1 FROM malu$log_drain d
                WHERE d.drain_id = malu$log_drain_run.drain_id
                  AND d.owner_schema = current_schema()))
    WITH CHECK (
        EXISTS (SELECT 1 FROM malu$log_drain d
                WHERE d.drain_id = malu$log_drain_run.drain_id
                  AND d.owner_schema = current_schema()));

GRANT SELECT, INSERT, UPDATE, DELETE ON malu$log_drain, malu$log_drain_run TO maludb_memory_admin;
GRANT SELECT, INSERT, UPDATE         ON malu$log_drain, malu$log_drain_run TO maludb_memory_executor;
GRANT SELECT                          ON malu$log_drain, malu$log_drain_run TO maludb_memory_auditor;
GRANT USAGE, SELECT ON SEQUENCE malu$log_drain_drain_id_seq          TO maludb_memory_admin, maludb_memory_executor;
GRANT USAGE, SELECT ON SEQUENCE malu$log_drain_run_run_id_seq        TO maludb_memory_admin, maludb_memory_executor;

-- =====================================================================
-- log_drain_set — UPSERT a drain.
-- =====================================================================
CREATE FUNCTION log_drain_set(
    p_name              text,
    p_kind              text,
    p_destination       jsonb,
    p_source_streams    text[],
    p_destination_secret_ref text DEFAULT NULL,
    p_redaction_rules   jsonb   DEFAULT '[]'::jsonb,
    p_batch_size        integer DEFAULT 100,
    p_flush_interval_ms integer DEFAULT 5000
) RETURNS bigint
    LANGUAGE plpgsql VOLATILE
    AS $body$
#variable_conflict use_column
DECLARE v_id bigint;
BEGIN
    IF p_kind NOT IN ('http','file','s3','otlp_http') THEN
        RAISE EXCEPTION 'log_drain_set: kind must be http/file/s3/otlp_http'
            USING ERRCODE = 'check_violation';
    END IF;
    IF cardinality(p_source_streams) = 0 THEN
        RAISE EXCEPTION 'log_drain_set: at least one source_stream required'
            USING ERRCODE = 'check_violation';
    END IF;

    INSERT INTO malu$log_drain
        (name, kind, destination, source_streams,
         destination_secret_ref, redaction_rules,
         batch_size, flush_interval_ms)
    VALUES
        (p_name, p_kind, p_destination, p_source_streams,
         p_destination_secret_ref, p_redaction_rules,
         p_batch_size, p_flush_interval_ms)
    ON CONFLICT (owner_schema, name) DO UPDATE
        SET kind                    = EXCLUDED.kind,
            destination             = EXCLUDED.destination,
            source_streams          = EXCLUDED.source_streams,
            destination_secret_ref  = EXCLUDED.destination_secret_ref,
            redaction_rules         = EXCLUDED.redaction_rules,
            batch_size              = EXCLUDED.batch_size,
            flush_interval_ms       = EXCLUDED.flush_interval_ms,
            retired_at              = NULL
    RETURNING drain_id INTO v_id;

    PERFORM audit_event('log_drain_set', 'malu$log_drain', v_id,
        jsonb_build_object('name', p_name, 'kind', p_kind,
                           'source_streams', to_jsonb(p_source_streams),
                           'has_secret_ref', p_destination_secret_ref IS NOT NULL),
        NULL);
    RETURN v_id;
END;
$body$;
REVOKE EXECUTE ON FUNCTION log_drain_set(text, text, jsonb, text[], text, jsonb, integer, integer) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION log_drain_set(text, text, jsonb, text[], text, jsonb, integer, integer) TO
    maludb_memory_admin, maludb_memory_executor;

CREATE FUNCTION log_drain_enable(p_name text)  RETURNS boolean
LANGUAGE plpgsql VOLATILE AS $body$
#variable_conflict use_column
DECLARE v_id bigint; v_was boolean;
BEGIN
    SELECT drain_id, enabled INTO v_id, v_was FROM malu$log_drain WHERE name = p_name;
    IF v_id IS NULL THEN RAISE EXCEPTION 'log_drain_enable: % not found', p_name USING ERRCODE='no_data_found'; END IF;
    UPDATE malu$log_drain SET enabled = true, retired_at = NULL WHERE drain_id = v_id;
    PERFORM audit_event('log_drain_enable', 'malu$log_drain', v_id,
        jsonb_build_object('was_enabled', v_was), NULL);
    RETURN NOT v_was;
END;
$body$;

CREATE FUNCTION log_drain_disable(p_name text, p_reason text DEFAULT NULL)  RETURNS boolean
LANGUAGE plpgsql VOLATILE AS $body$
#variable_conflict use_column
DECLARE v_id bigint; v_was boolean;
BEGIN
    SELECT drain_id, enabled INTO v_id, v_was FROM malu$log_drain WHERE name = p_name;
    IF v_id IS NULL THEN RAISE EXCEPTION 'log_drain_disable: % not found', p_name USING ERRCODE='no_data_found'; END IF;
    UPDATE malu$log_drain SET enabled = false WHERE drain_id = v_id;
    PERFORM audit_event('log_drain_disable', 'malu$log_drain', v_id,
        jsonb_build_object('was_enabled', v_was, 'reason', p_reason), NULL);
    RETURN v_was;
END;
$body$;

CREATE FUNCTION log_drain_list(p_include_disabled boolean DEFAULT false)
RETURNS TABLE (drain_id bigint, name text, kind text, source_streams text[], enabled boolean, retired_at timestamptz)
LANGUAGE plpgsql STABLE AS $body$
#variable_conflict use_column
BEGIN
    RETURN QUERY
    SELECT d.drain_id, d.name, d.kind, d.source_streams, d.enabled, d.retired_at
      FROM malu$log_drain d
     WHERE (p_include_disabled OR (d.enabled AND d.retired_at IS NULL))
     ORDER BY d.name;
END;
$body$;

CREATE FUNCTION log_drain_record_run(
    p_drain_id  bigint,
    p_batches   integer,
    p_bytes     bigint,
    p_records   integer,
    p_errors    integer DEFAULT 0,
    p_last_error text   DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql VOLATILE AS $body$
#variable_conflict use_column
DECLARE v_id bigint;
BEGIN
    INSERT INTO malu$log_drain_run(drain_id, finished_at, batches, bytes, records, errors, last_error)
    VALUES (p_drain_id, now(), p_batches, p_bytes, p_records, p_errors, p_last_error)
    RETURNING run_id INTO v_id;
    RETURN v_id;
END;
$body$;

REVOKE EXECUTE ON FUNCTION log_drain_enable(text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION log_drain_disable(text, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION log_drain_list(boolean) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION log_drain_record_run(bigint, integer, bigint, integer, integer, text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION log_drain_enable(text)                                                TO maludb_memory_admin, maludb_memory_executor;
GRANT  EXECUTE ON FUNCTION log_drain_disable(text, text)                                         TO maludb_memory_admin, maludb_memory_executor;
GRANT  EXECUTE ON FUNCTION log_drain_list(boolean)                                               TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;
GRANT  EXECUTE ON FUNCTION log_drain_record_run(bigint, integer, bigint, integer, integer, text) TO maludb_memory_admin, maludb_memory_executor;
