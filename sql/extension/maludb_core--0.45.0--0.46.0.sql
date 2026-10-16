\echo Use "ALTER EXTENSION maludb_core UPDATE TO '0.46.0'" to load this file. \quit

-- =====================================================================
-- maludb_core 0.45.0 → 0.46.0
--
-- Stage 11 / V3-CRON-01: scheduler.
--
-- Native PL/pgSQL scheduler that complements V3-QUEUE-01. Schedules
-- can either:
--   * Enqueue a job onto a named V3-QUEUE-01 queue (preferred), or
--   * Run an inline SQL string (operator-supplied, narrowly granted).
--
-- The scheduler itself does NOT spin a background worker; that's the
-- job of an operator-managed cron tick (V3-OBS-01 / V3-LOG-01 will
-- provide one once those land). Until then, an operator can call
-- `schedule_tick()` from `pg_cron` or a one-line `psql` loop.
--
-- pg_cron remains a future swap target — its table shape is similar
-- enough that a follow-up migration could delegate without breaking
-- the SQL contract here.
--
-- Cron expression support: the standard 5-field syntax
-- `minute hour day-of-month month day-of-week`, plus the `@hourly`,
-- `@daily`, `@weekly`, `@monthly`, `@yearly` aliases. Each field
-- accepts:
--   *               — any value
--   N               — literal
--   N-M             — range
--   N,M,K           — set
--   STAR/N          — step  (every Nth)
--
-- Apply with:
--   ALTER EXTENSION maludb_core UPDATE TO '0.46.0';
-- =====================================================================

CREATE OR REPLACE FUNCTION maludb_core_version() RETURNS text
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$ SELECT '0.46.0'::text $body$;

-- ---------------------------------------------------------------------
-- malu$schedule
-- ---------------------------------------------------------------------
CREATE TABLE malu$schedule (
    schedule_id    bigserial PRIMARY KEY,
    name           text       NOT NULL,
    cron_expr      text       NOT NULL,
    action_kind    text       NOT NULL CHECK (action_kind IN ('enqueue','sql')),
    action_payload jsonb      NOT NULL,
    -- action_kind='enqueue' expects {"queue":"<name>","payload":<jsonb>}
    -- action_kind='sql'     expects {"sql":"<statement>"} (admin-only)
    description    text,
    enabled        boolean    NOT NULL DEFAULT true,
    next_run_at    timestamptz,
    last_run_at    timestamptz,
    last_error     text,
    owner_schema   name       NOT NULL DEFAULT current_schema(),
    created_at     timestamptz NOT NULL DEFAULT now(),
    retired_at     timestamptz,
    UNIQUE (owner_schema, name)
);
CREATE INDEX malu$schedule_next_run_idx
    ON malu$schedule(next_run_at)
    WHERE enabled AND retired_at IS NULL;
CREATE INDEX malu$schedule_owner_idx
    ON malu$schedule(owner_schema, enabled, retired_at);

-- ---------------------------------------------------------------------
-- malu$schedule_run — run history.
-- ---------------------------------------------------------------------
CREATE TABLE malu$schedule_run (
    run_id        bigserial PRIMARY KEY,
    schedule_id   bigint    NOT NULL REFERENCES malu$schedule(schedule_id) ON DELETE CASCADE,
    started_at    timestamptz NOT NULL DEFAULT now(),
    finished_at   timestamptz,
    status        text      NOT NULL CHECK (status IN ('running','succeeded','failed')),
    detail_jsonb  jsonb,
    error_text    text
);
CREATE INDEX malu$schedule_run_schedule_idx
    ON malu$schedule_run(schedule_id, started_at DESC);

-- ---------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------
ALTER TABLE malu$schedule ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_owner ON malu$schedule
    USING      (owner_schema = current_schema())
    WITH CHECK (owner_schema = current_schema());

ALTER TABLE malu$schedule_run ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_via_schedule ON malu$schedule_run
    USING (
        EXISTS (
            SELECT 1 FROM malu$schedule s
            WHERE s.schedule_id  = malu$schedule_run.schedule_id
              AND s.owner_schema = current_schema()
        )
    )
    WITH CHECK (
        EXISTS (
            SELECT 1 FROM malu$schedule s
            WHERE s.schedule_id  = malu$schedule_run.schedule_id
              AND s.owner_schema = current_schema()
        )
    );

GRANT SELECT, INSERT, UPDATE, DELETE ON malu$schedule, malu$schedule_run TO maludb_memory_admin;
GRANT SELECT, INSERT, UPDATE         ON malu$schedule, malu$schedule_run TO maludb_memory_executor;
GRANT SELECT                          ON malu$schedule, malu$schedule_run TO maludb_memory_auditor;

GRANT USAGE, SELECT ON SEQUENCE malu$schedule_schedule_id_seq TO maludb_memory_admin, maludb_memory_executor;
GRANT USAGE, SELECT ON SEQUENCE malu$schedule_run_run_id_seq  TO maludb_memory_admin, maludb_memory_executor;

-- =====================================================================
-- Cron expression evaluator (PL/pgSQL).
-- =====================================================================

-- _cron_expand_field — parse a single cron field into the integer set
-- of allowed values. Returns NULL if the field cannot be parsed.
CREATE FUNCTION _cron_expand_field(p_field text, p_min integer, p_max integer)
    RETURNS integer[]
    LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE
    AS $body$
DECLARE
    v_out       integer[] := ARRAY[]::integer[];
    v_token     text;
    v_step      integer;
    v_lo        integer;
    v_hi        integer;
    v_range_lo  integer;
    v_range_hi  integer;
    v_pair      text[];
    v_i         integer;
BEGIN
    FOREACH v_token IN ARRAY string_to_array(p_field, ',') LOOP
        v_step := 1;
        IF position('/' IN v_token) > 0 THEN
            v_pair := string_to_array(v_token, '/');
            v_token := v_pair[1];
            v_step  := v_pair[2]::integer;
            IF v_step <= 0 THEN RETURN NULL; END IF;
        END IF;

        IF v_token = '*' THEN
            v_range_lo := p_min;
            v_range_hi := p_max;
        ELSIF position('-' IN v_token) > 0 THEN
            v_pair := string_to_array(v_token, '-');
            v_range_lo := v_pair[1]::integer;
            v_range_hi := v_pair[2]::integer;
        ELSE
            v_range_lo := v_token::integer;
            v_range_hi := v_range_lo;
        END IF;

        IF v_range_lo < p_min OR v_range_hi > p_max OR v_range_lo > v_range_hi THEN
            RETURN NULL;
        END IF;

        v_i := v_range_lo;
        WHILE v_i <= v_range_hi LOOP
            v_out := v_out || v_i;
            v_i := v_i + v_step;
        END LOOP;
    END LOOP;

    -- Deduplicate + sort via SELECT DISTINCT.
    SELECT array_agg(v ORDER BY v)
      INTO v_out
      FROM (SELECT DISTINCT unnest(v_out) AS v) s;
    RETURN v_out;
EXCEPTION WHEN others THEN
    RETURN NULL;
END;
$body$;
REVOKE EXECUTE ON FUNCTION _cron_expand_field(text, integer, integer) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION _cron_expand_field(text, integer, integer) TO
    maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;

-- cron_next_after — return the first time >= p_after that matches
-- the cron expression. Raises if the expression is invalid.
CREATE FUNCTION cron_next_after(p_expr text, p_after timestamptz)
    RETURNS timestamptz
    LANGUAGE plpgsql STABLE PARALLEL SAFE
    AS $body$
DECLARE
    v_expr     text := trim(lower(p_expr));
    v_parts    text[];
    v_minutes  integer[];
    v_hours    integer[];
    v_doms     integer[];
    v_months   integer[];
    v_dows     integer[];
    v_now      timestamptz := date_trunc('minute', p_after) + interval '1 minute';
    v_attempts integer := 0;
BEGIN
    IF v_expr = '@hourly' THEN v_expr := '0 * * * *';
    ELSIF v_expr = '@daily'   THEN v_expr := '0 0 * * *';
    ELSIF v_expr = '@weekly'  THEN v_expr := '0 0 * * 0';
    ELSIF v_expr = '@monthly' THEN v_expr := '0 0 1 * *';
    ELSIF v_expr = '@yearly' OR v_expr = '@annually' THEN v_expr := '0 0 1 1 *';
    END IF;

    v_parts := regexp_split_to_array(v_expr, '\s+');
    IF array_length(v_parts, 1) <> 5 THEN
        RAISE EXCEPTION 'cron_next_after: expression % is not 5 fields', p_expr
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    v_minutes := _cron_expand_field(v_parts[1],  0, 59);
    v_hours   := _cron_expand_field(v_parts[2],  0, 23);
    v_doms    := _cron_expand_field(v_parts[3],  1, 31);
    v_months  := _cron_expand_field(v_parts[4],  1, 12);
    v_dows    := _cron_expand_field(v_parts[5],  0,  6);

    IF v_minutes IS NULL OR v_hours IS NULL OR v_doms IS NULL
       OR v_months IS NULL OR v_dows IS NULL THEN
        RAISE EXCEPTION 'cron_next_after: cannot parse %', p_expr
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    -- Walk minute-by-minute up to 4 years out (catches every yearly
    -- cron). 60 * 24 * 366 * 4 ≈ 2.1M iterations worst-case; the loop
    -- skips ahead in days when month/dom/dow miss, so the common case
    -- is much smaller.
    WHILE v_attempts < 366 * 4 LOOP
        IF extract(month  from v_now)::int = ANY(v_months)
           AND (extract(day    from v_now)::int = ANY(v_doms))
           AND (extract(dow    from v_now)::int = ANY(v_dows))
           AND (extract(hour   from v_now)::int = ANY(v_hours))
           AND (extract(minute from v_now)::int = ANY(v_minutes)) THEN
            RETURN v_now;
        END IF;
        v_now := v_now + interval '1 minute';
        v_attempts := v_attempts + 1;
        -- Skip to next day if month/dom/dow fail; cheaper than minute
        -- ticks across a whole month.
        IF extract(hour from v_now)::int = 0
           AND extract(minute from v_now)::int = 0 THEN
            IF NOT (extract(month from v_now)::int = ANY(v_months)
                    AND extract(day from v_now)::int = ANY(v_doms)
                    AND extract(dow from v_now)::int = ANY(v_dows)) THEN
                v_now := v_now + interval '1 day' - interval '1 second';
                v_now := date_trunc('day', v_now) + interval '1 day';
            END IF;
        END IF;
    END LOOP;

    RAISE EXCEPTION 'cron_next_after: no match within 4 years for %', p_expr
        USING ERRCODE = 'no_data_found';
END;
$body$;
REVOKE EXECUTE ON FUNCTION cron_next_after(text, timestamptz) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION cron_next_after(text, timestamptz) TO
    maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;

-- =====================================================================
-- Public schedule API
-- =====================================================================

-- schedule_create — UPSERT a named schedule. action_kind dictates
-- action_payload shape (see CHECK at the top).
CREATE FUNCTION schedule_create(
    p_name          text,
    p_cron_expr     text,
    p_action_kind   text,
    p_action_payload jsonb,
    p_description   text DEFAULT NULL,
    p_enabled       boolean DEFAULT true
) RETURNS bigint
    LANGUAGE plpgsql VOLATILE
    AS $body$
#variable_conflict use_column
DECLARE
    v_next timestamptz;
    v_id   bigint;
BEGIN
    IF p_action_kind NOT IN ('enqueue','sql') THEN
        RAISE EXCEPTION 'schedule_create: action_kind must be enqueue or sql'
            USING ERRCODE = 'check_violation';
    END IF;
    IF p_action_kind = 'enqueue' THEN
        IF NOT (p_action_payload ? 'queue') THEN
            RAISE EXCEPTION 'schedule_create: enqueue action needs {"queue": "<name>", "payload": ...}'
                USING ERRCODE = 'check_violation';
        END IF;
    ELSIF p_action_kind = 'sql' THEN
        IF NOT (p_action_payload ? 'sql') THEN
            RAISE EXCEPTION 'schedule_create: sql action needs {"sql": "<statement>"}'
                USING ERRCODE = 'check_violation';
        END IF;
    END IF;

    -- Validate the cron expression and compute the first run.
    v_next := cron_next_after(p_cron_expr, now());

    INSERT INTO malu$schedule
        (name, cron_expr, action_kind, action_payload, description, enabled, next_run_at)
    VALUES
        (p_name, p_cron_expr, p_action_kind, p_action_payload, p_description, p_enabled, v_next)
    ON CONFLICT (owner_schema, name) DO UPDATE
        SET cron_expr      = EXCLUDED.cron_expr,
            action_kind    = EXCLUDED.action_kind,
            action_payload = EXCLUDED.action_payload,
            description    = EXCLUDED.description,
            enabled        = EXCLUDED.enabled,
            next_run_at    = EXCLUDED.next_run_at,
            retired_at     = NULL
    RETURNING schedule_id INTO v_id;

    PERFORM audit_event('schedule_create', 'malu$schedule', v_id,
        jsonb_build_object('name', p_name, 'cron_expr', p_cron_expr,
                           'action_kind', p_action_kind, 'next_run_at', v_next),
        NULL);
    RETURN v_id;
END;
$body$;
REVOKE EXECUTE ON FUNCTION schedule_create(text, text, text, jsonb, text, boolean) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION schedule_create(text, text, text, jsonb, text, boolean) TO
    maludb_memory_admin, maludb_memory_executor;

-- schedule_enable / _disable
CREATE FUNCTION schedule_enable(p_name text) RETURNS boolean
    LANGUAGE plpgsql VOLATILE
    AS $body$
#variable_conflict use_column
DECLARE v_id bigint; v_was boolean;
BEGIN
    SELECT schedule_id, enabled INTO v_id, v_was
      FROM malu$schedule WHERE name = p_name;
    IF v_id IS NULL THEN
        RAISE EXCEPTION 'schedule_enable: schedule % not found', p_name
            USING ERRCODE = 'no_data_found';
    END IF;
    UPDATE malu$schedule
       SET enabled     = true,
           next_run_at = cron_next_after(cron_expr, now()),
           retired_at  = NULL
     WHERE schedule_id = v_id;
    PERFORM audit_event('schedule_enable', 'malu$schedule', v_id,
        jsonb_build_object('was_enabled', v_was), NULL);
    RETURN NOT v_was;
END;
$body$;
REVOKE EXECUTE ON FUNCTION schedule_enable(text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION schedule_enable(text) TO maludb_memory_admin, maludb_memory_executor;

CREATE FUNCTION schedule_disable(p_name text, p_reason text DEFAULT NULL) RETURNS boolean
    LANGUAGE plpgsql VOLATILE
    AS $body$
#variable_conflict use_column
DECLARE v_id bigint; v_was boolean;
BEGIN
    SELECT schedule_id, enabled INTO v_id, v_was
      FROM malu$schedule WHERE name = p_name;
    IF v_id IS NULL THEN
        RAISE EXCEPTION 'schedule_disable: schedule % not found', p_name
            USING ERRCODE = 'no_data_found';
    END IF;
    UPDATE malu$schedule
       SET enabled = false,
           next_run_at = NULL
     WHERE schedule_id = v_id;
    PERFORM audit_event('schedule_disable', 'malu$schedule', v_id,
        jsonb_build_object('was_enabled', v_was, 'reason', p_reason), NULL);
    RETURN v_was;
END;
$body$;
REVOKE EXECUTE ON FUNCTION schedule_disable(text, text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION schedule_disable(text, text) TO maludb_memory_admin, maludb_memory_executor;

-- schedule_list — enumeration for the CLI / metrics.
CREATE FUNCTION schedule_list(p_include_disabled boolean DEFAULT false)
    RETURNS TABLE (
        schedule_id  bigint,
        name         text,
        cron_expr    text,
        action_kind  text,
        enabled      boolean,
        next_run_at  timestamptz,
        last_run_at  timestamptz,
        last_error   text
    ) LANGUAGE plpgsql STABLE
    AS $body$
#variable_conflict use_column
BEGIN
    RETURN QUERY
    SELECT s.schedule_id, s.name, s.cron_expr, s.action_kind, s.enabled,
           s.next_run_at, s.last_run_at, s.last_error
      FROM malu$schedule s
     WHERE (p_include_disabled OR (s.enabled AND s.retired_at IS NULL))
     ORDER BY s.name;
END;
$body$;
REVOKE EXECUTE ON FUNCTION schedule_list(boolean) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION schedule_list(boolean) TO
    maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;

-- _schedule_execute_action — runs an action_payload under the
-- schedule's owner. enqueue is the safe path; sql requires the caller
-- to be maludb_memory_admin (BYPASSRLS) since arbitrary SQL is a
-- privilege concern. The CHECK is enforced via has_role.
CREATE FUNCTION _schedule_execute_action(
    p_schedule_id bigint,
    p_action_kind text,
    p_payload     jsonb
) RETURNS jsonb
    LANGUAGE plpgsql VOLATILE
    AS $body$
#variable_conflict use_column
DECLARE
    v_qname  text;
    v_q_pay  jsonb;
    v_sql    text;
    v_jid    bigint;
BEGIN
    IF p_action_kind = 'enqueue' THEN
        v_qname := p_payload ->> 'queue';
        v_q_pay := COALESCE(p_payload -> 'payload', '{}'::jsonb);
        v_jid   := queue_enqueue(v_qname, v_q_pay, NULL, 0, NULL, NULL);
        RETURN jsonb_build_object('action', 'enqueue', 'queue', v_qname, 'job_id', v_jid);
    ELSIF p_action_kind = 'sql' THEN
        IF NOT pg_has_role(session_user, 'maludb_memory_admin', 'MEMBER') THEN
            RAISE EXCEPTION '_schedule_execute_action: sql action requires maludb_memory_admin'
                USING ERRCODE = 'insufficient_privilege';
        END IF;
        v_sql := p_payload ->> 'sql';
        EXECUTE v_sql;
        RETURN jsonb_build_object('action', 'sql', 'executed', true);
    ELSE
        RAISE EXCEPTION '_schedule_execute_action: unknown action_kind %', p_action_kind
            USING ERRCODE = 'invalid_parameter_value';
    END IF;
END;
$body$;
REVOKE EXECUTE ON FUNCTION _schedule_execute_action(bigint, text, jsonb) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION _schedule_execute_action(bigint, text, jsonb) TO
    maludb_memory_admin, maludb_memory_executor;

-- schedule_run_now — invoke a schedule immediately, regardless of
-- next_run_at. Records a malu$schedule_run row.
CREATE FUNCTION schedule_run_now(p_name text) RETURNS bigint
    LANGUAGE plpgsql VOLATILE
    AS $body$
#variable_conflict use_column
DECLARE
    v_sched malu$schedule%ROWTYPE;
    v_run_id bigint;
    v_detail jsonb;
BEGIN
    SELECT * INTO v_sched FROM malu$schedule WHERE name = p_name AND retired_at IS NULL;
    IF v_sched.schedule_id IS NULL THEN
        RAISE EXCEPTION 'schedule_run_now: schedule % not found', p_name
            USING ERRCODE = 'no_data_found';
    END IF;

    INSERT INTO malu$schedule_run(schedule_id, status)
    VALUES (v_sched.schedule_id, 'running')
    RETURNING run_id INTO v_run_id;

    BEGIN
        v_detail := _schedule_execute_action(v_sched.schedule_id,
                                             v_sched.action_kind,
                                             v_sched.action_payload);
        UPDATE malu$schedule_run
           SET finished_at  = now(),
               status       = 'succeeded',
               detail_jsonb = v_detail
         WHERE run_id = v_run_id;
        UPDATE malu$schedule
           SET last_run_at = now(),
               last_error  = NULL
         WHERE schedule_id = v_sched.schedule_id;
        PERFORM audit_event('schedule_run_succeeded', 'malu$schedule', v_sched.schedule_id,
            v_detail, NULL);
    EXCEPTION WHEN others THEN
        UPDATE malu$schedule_run
           SET finished_at = now(),
               status      = 'failed',
               error_text  = SQLERRM
         WHERE run_id = v_run_id;
        UPDATE malu$schedule
           SET last_run_at = now(),
               last_error  = SQLERRM
         WHERE schedule_id = v_sched.schedule_id;
        PERFORM audit_event('schedule_run_failed', 'malu$schedule', v_sched.schedule_id,
            jsonb_build_object('error', SQLERRM), SQLERRM);
        RAISE;
    END;

    RETURN v_run_id;
END;
$body$;
REVOKE EXECUTE ON FUNCTION schedule_run_now(text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION schedule_run_now(text) TO maludb_memory_admin, maludb_memory_executor;

-- schedule_tick — operator-callable. Runs every enabled schedule whose
-- next_run_at <= now(), advances next_run_at, returns the count fired.
-- Designed to be called from pg_cron or an external clock.
CREATE FUNCTION schedule_tick() RETURNS integer
    LANGUAGE plpgsql VOLATILE
    AS $body$
#variable_conflict use_column
DECLARE
    r record;
    v_count integer := 0;
BEGIN
    FOR r IN
        SELECT schedule_id, name, cron_expr
          FROM malu$schedule
         WHERE enabled
           AND retired_at IS NULL
           AND next_run_at IS NOT NULL
           AND next_run_at <= now()
         ORDER BY next_run_at
    LOOP
        BEGIN
            PERFORM schedule_run_now(r.name);
        EXCEPTION WHEN others THEN
            -- schedule_run_now already recorded the failure; keep
            -- ticking the rest of the queue.
            NULL;
        END;
        UPDATE malu$schedule
           SET next_run_at = cron_next_after(r.cron_expr, now())
         WHERE schedule_id = r.schedule_id;
        v_count := v_count + 1;
    END LOOP;
    RETURN v_count;
END;
$body$;
REVOKE EXECUTE ON FUNCTION schedule_tick() FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION schedule_tick() TO maludb_memory_admin, maludb_memory_executor;
