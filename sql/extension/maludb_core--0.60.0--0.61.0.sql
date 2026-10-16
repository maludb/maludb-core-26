-- =====================================================================
-- maludb_core 0.60.0 -> 0.61.0  (v3.1 Stage E — V3-LOG-02 storage hooks)
--
-- Adds the catalog hooks the maludb-logsd service runner needs:
--   * malu$log_drain.cursor_jsonb — per-stream cursor map
--   * log_drain_advance_cursor(drain_id, stream, last_id)
--   * log_drain_fetch_batch(drain_id, stream, limit) -> (record_id, payload)
--
-- Supported streams in this migration: 'audit' (malu$audit_event) and
-- 'realtime_event' (malu$event). Queue / mc2db / postgres streams are
-- followup tickets and will raise an explicit error from
-- log_drain_fetch_batch for now.
--
-- Apply with:
--   ALTER EXTENSION maludb_core UPDATE TO '0.61.0';
-- =====================================================================

CREATE OR REPLACE FUNCTION maludb_core_version() RETURNS text
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$ SELECT '0.61.0'::text $body$;

-- ---------------------------------------------------------------------
-- 1. cursor_jsonb column on malu$log_drain.
-- ---------------------------------------------------------------------
ALTER TABLE malu$log_drain
    ADD COLUMN IF NOT EXISTS cursor_jsonb jsonb NOT NULL DEFAULT '{}'::jsonb;

-- ---------------------------------------------------------------------
-- 2. log_drain_advance_cursor — set the last delivered id for a stream.
--    Idempotent; only moves the cursor forward.
-- ---------------------------------------------------------------------
CREATE FUNCTION log_drain_advance_cursor(
    p_drain_id bigint,
    p_stream   text,
    p_last_id  bigint
) RETURNS bigint
LANGUAGE plpgsql VOLATILE AS $body$
#variable_conflict use_column
DECLARE
    v_existing bigint;
    v_new      bigint;
BEGIN
    SELECT COALESCE((cursor_jsonb ->> p_stream)::bigint, 0)
      INTO v_existing
      FROM malu$log_drain
     WHERE drain_id = p_drain_id;
    IF v_existing IS NULL THEN
        RAISE EXCEPTION 'log_drain_advance_cursor: drain % not found', p_drain_id
            USING ERRCODE = 'no_data_found';
    END IF;
    v_new := GREATEST(v_existing, p_last_id);
    UPDATE malu$log_drain
       SET cursor_jsonb = jsonb_set(cursor_jsonb, ARRAY[p_stream], to_jsonb(v_new))
     WHERE drain_id = p_drain_id;
    RETURN v_new;
END;
$body$;
REVOKE EXECUTE ON FUNCTION log_drain_advance_cursor(bigint, text, bigint) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION log_drain_advance_cursor(bigint, text, bigint) TO
    maludb_memory_admin, maludb_memory_executor;

-- ---------------------------------------------------------------------
-- 3. log_drain_fetch_batch — pull the next N rows for a stream.
--    Returns (record_id, payload jsonb). Payload shape is stream-specific
--    but always includes 'event_kind' for routing/filtering.
-- ---------------------------------------------------------------------
CREATE FUNCTION log_drain_fetch_batch(
    p_drain_id bigint,
    p_stream   text,
    p_limit    integer DEFAULT 100
) RETURNS TABLE (record_id bigint, payload jsonb)
LANGUAGE plpgsql STABLE AS $body$
#variable_conflict use_column
DECLARE
    v_cursor bigint;
BEGIN
    IF p_limit IS NULL OR p_limit <= 0 THEN
        RAISE EXCEPTION 'log_drain_fetch_batch: limit must be > 0'
            USING ERRCODE = 'check_violation';
    END IF;

    SELECT COALESCE((cursor_jsonb ->> p_stream)::bigint, 0)
      INTO v_cursor
      FROM malu$log_drain
     WHERE drain_id = p_drain_id;
    IF v_cursor IS NULL THEN
        RAISE EXCEPTION 'log_drain_fetch_batch: drain % not found', p_drain_id
            USING ERRCODE = 'no_data_found';
    END IF;

    IF p_stream = 'audit' THEN
        RETURN QUERY
        SELECT a.event_id,
               jsonb_build_object(
                 'stream',             'audit',
                 'event_id',           a.event_id,
                 'event_kind',         a.event_kind,
                 'target_object_type', a.target_object_type,
                 'target_object_id',   a.target_object_id,
                 'event_jsonb',        a.event_jsonb,
                 'error_text',         a.error_text,
                 'occurred_at',        a.occurred_at,
                 'actor_role',         a.actor_role,
                 'owner_schema',       a.owner_schema)
          FROM malu$audit_event a
         WHERE a.event_id > v_cursor
         ORDER BY a.event_id
         LIMIT p_limit;
    ELSIF p_stream = 'realtime_event' THEN
        RETURN QUERY
        SELECT e.event_id,
               jsonb_build_object(
                 'stream',           'realtime_event',
                 'event_id',         e.event_id,
                 'event_kind',       e.event_kind,
                 'account_id',       e.account_id,
                 'active_pool_id',   e.active_pool_id,
                 'object_type',      e.object_type,
                 'object_id',        e.object_id,
                 'partition',        e.partition,
                 'scope',            e.scope,
                 'payload',          e.payload,
                 'transaction_time', e.transaction_time)
          FROM malu$event e
         WHERE e.event_id > v_cursor
         ORDER BY e.event_id
         LIMIT p_limit;
    ELSE
        RAISE EXCEPTION 'log_drain_fetch_batch: stream % not yet supported (audit / realtime_event only in 0.61.0)', p_stream
            USING ERRCODE = 'feature_not_supported';
    END IF;
END;
$body$;
REVOKE EXECUTE ON FUNCTION log_drain_fetch_batch(bigint, text, integer) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION log_drain_fetch_batch(bigint, text, integer) TO
    maludb_memory_admin, maludb_memory_executor;
