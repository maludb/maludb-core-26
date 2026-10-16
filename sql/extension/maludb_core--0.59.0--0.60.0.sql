-- =====================================================================
-- maludb_core 0.59.0 -> 0.60.0  (v3.1 Stage C — V3-PRESENCE-02)
--
-- Adds an optional TTL to malu$pool_presence rows and a sweeper
-- function that auto-marks expired rows as left.
--
-- Why: long-running active memory pools accumulate stale presence
-- rows (humans whose tab closed, agents whose host died) that never
-- emit an explicit presence_leave. Without TTL, presence_list()
-- continues to report them as active forever.
--
-- Design:
--   * malu$pool_presence gains ttl_seconds (nullable). NULL preserves
--     today's behavior (no auto-expiry) — existing rows are unchanged.
--   * presence_update takes an optional p_ttl_seconds; supplying it
--     stamps the row with that TTL on each touch.
--   * presence_sweep() finds rows whose last_seen_at + ttl_seconds is
--     in the past and (a) sets left_at = now(), (b) inserts a 'leave'
--     event with reason='ttl_expired', (c) emits the realtime event,
--     (d) records an audit row. Returns the number of rows swept.
--     Idempotent and authorization-aware (RLS still applies — it
--     only sweeps rows the caller can see, but is intended to be
--     called by maludb_memory_admin which has BYPASSRLS).
--
-- Apply with:
--   ALTER EXTENSION maludb_core UPDATE TO '0.60.0';
-- =====================================================================

CREATE OR REPLACE FUNCTION maludb_core_version() RETURNS text
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$ SELECT '0.60.0'::text $body$;

-- ---------------------------------------------------------------------
-- 1. Column. nullable; NULL = no TTL.
-- ---------------------------------------------------------------------
ALTER TABLE malu$pool_presence
    ADD COLUMN IF NOT EXISTS ttl_seconds integer
    CHECK (ttl_seconds IS NULL OR ttl_seconds > 0);

-- ---------------------------------------------------------------------
-- 2. presence_update — accepts an optional TTL.
--    Backward-compatible: the prior 6-arg signature is dropped and
--    replaced by a 7-arg one with p_ttl_seconds defaulting to NULL.
--    Callers using positional args continue to work because all
--    prior args keep their positions and the new one is at the tail.
-- ---------------------------------------------------------------------
DROP FUNCTION presence_update(bigint, text, text, text, text, jsonb);

CREATE FUNCTION presence_update(
    p_pool_id          bigint,
    p_participant_kind text,
    p_participant_ref  text,
    p_role             text DEFAULT NULL,
    p_declared_task    text DEFAULT NULL,
    p_cursor_jsonb     jsonb DEFAULT NULL,
    p_ttl_seconds      integer DEFAULT NULL
) RETURNS bigint
    LANGUAGE plpgsql VOLATILE
    AS $body$
#variable_conflict use_column
DECLARE
    v_pid    bigint;
    v_kind   text;
    v_was    boolean;
BEGIN
    PERFORM 1 FROM malu$active_memory_pool WHERE pool_id = p_pool_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'presence_update: pool % not found or not visible to caller', p_pool_id
            USING ERRCODE = 'no_data_found';
    END IF;

    IF p_ttl_seconds IS NOT NULL AND p_ttl_seconds <= 0 THEN
        RAISE EXCEPTION 'presence_update: ttl_seconds must be > 0'
            USING ERRCODE = 'check_violation';
    END IF;

    SELECT presence_id, (left_at IS NULL) INTO v_pid, v_was
      FROM malu$pool_presence
     WHERE pool_id          = p_pool_id
       AND participant_kind = p_participant_kind
       AND participant_ref  = p_participant_ref;

    IF v_pid IS NULL THEN
        INSERT INTO malu$pool_presence
            (pool_id, participant_kind, participant_ref, role, declared_task, cursor_jsonb, ttl_seconds)
        VALUES
            (p_pool_id, p_participant_kind, p_participant_ref, p_role, p_declared_task, p_cursor_jsonb, p_ttl_seconds)
        RETURNING presence_id INTO v_pid;
        v_kind := 'join';
    ELSE
        UPDATE malu$pool_presence
           SET role          = COALESCE(p_role,          role),
               declared_task = COALESCE(p_declared_task, declared_task),
               cursor_jsonb  = COALESCE(p_cursor_jsonb,  cursor_jsonb),
               ttl_seconds   = COALESCE(p_ttl_seconds,   ttl_seconds),
               last_seen_at  = now(),
               left_at       = NULL
         WHERE presence_id = v_pid;
        v_kind := CASE WHEN v_was THEN 'update' ELSE 'join' END;
    END IF;

    INSERT INTO malu$pool_presence_event(presence_id, kind, detail_jsonb)
    VALUES (v_pid, v_kind,
            jsonb_build_object('role', p_role, 'declared_task', p_declared_task,
                               'cursor', p_cursor_jsonb,
                               'ttl_seconds', p_ttl_seconds));

    PERFORM emit_event(
        'pool_presence_' || v_kind,
        jsonb_build_object('presence_id', v_pid,
                           'pool_id', p_pool_id,
                           'participant_kind', p_participant_kind,
                           'participant_ref',  p_participant_ref,
                           'role',             p_role,
                           'declared_task',    p_declared_task,
                           'ttl_seconds',      p_ttl_seconds),
        NULL, NULL, p_pool_id, 'malu$pool_presence', v_pid, NULL);

    PERFORM audit_event('pool_presence_' || v_kind, 'malu$pool_presence', v_pid,
        jsonb_build_object('pool_id', p_pool_id,
                           'participant_kind', p_participant_kind,
                           'participant_ref', p_participant_ref,
                           'ttl_seconds', p_ttl_seconds),
        NULL);

    RETURN v_pid;
END;
$body$;
REVOKE EXECUTE ON FUNCTION presence_update(bigint, text, text, text, text, jsonb, integer) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION presence_update(bigint, text, text, text, text, jsonb, integer) TO
    maludb_memory_admin, maludb_memory_executor;

-- ---------------------------------------------------------------------
-- 3. presence_sweep — mark TTL-expired rows as left.
--    Returns the number of rows swept. Callable as part of a cron
--    schedule (V3-CRON-01) or invoked manually by an admin.
-- ---------------------------------------------------------------------
CREATE FUNCTION presence_sweep()
    RETURNS bigint
    LANGUAGE plpgsql VOLATILE
    AS $body$
#variable_conflict use_column
DECLARE
    v_row malu$pool_presence%ROWTYPE;
    v_n   bigint := 0;
BEGIN
    FOR v_row IN
        SELECT * FROM malu$pool_presence
         WHERE left_at IS NULL
           AND ttl_seconds IS NOT NULL
           AND last_seen_at + make_interval(secs => ttl_seconds) < now()
         FOR UPDATE
    LOOP
        UPDATE malu$pool_presence
           SET left_at = now()
         WHERE presence_id = v_row.presence_id;

        INSERT INTO malu$pool_presence_event(presence_id, kind, detail_jsonb)
        VALUES (v_row.presence_id, 'leave',
                jsonb_build_object('reason', 'ttl_expired',
                                   'ttl_seconds', v_row.ttl_seconds,
                                   'last_seen_at', v_row.last_seen_at));

        PERFORM emit_event(
            'pool_presence_leave',
            jsonb_build_object('presence_id', v_row.presence_id,
                               'pool_id',     v_row.pool_id,
                               'participant_kind', v_row.participant_kind,
                               'participant_ref',  v_row.participant_ref,
                               'reason',           'ttl_expired',
                               'ttl_seconds',      v_row.ttl_seconds),
            NULL, NULL, v_row.pool_id, 'malu$pool_presence', v_row.presence_id, NULL);

        PERFORM audit_event('pool_presence_leave', 'malu$pool_presence', v_row.presence_id,
            jsonb_build_object('pool_id', v_row.pool_id,
                               'reason',  'ttl_expired',
                               'ttl_seconds', v_row.ttl_seconds),
            NULL);

        v_n := v_n + 1;
    END LOOP;

    RETURN v_n;
END;
$body$;
REVOKE EXECUTE ON FUNCTION presence_sweep() FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION presence_sweep() TO
    maludb_memory_admin, maludb_memory_executor;
