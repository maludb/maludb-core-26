-- V3-CRON-01 — scheduler regression coverage.
--
-- Exercises: cron_next_after (literal, range, step, aliases) /
-- schedule_create (enqueue + sql kinds) / schedule_enable /
-- schedule_disable / schedule_run_now / schedule_tick / audit.
--
-- Cron convention is *local time*; cron_next_after honors the
-- session's TimeZone. pg_regress defaults to PST8PDT, so we pin
-- UTC here to keep the literal expectations stable across runs.

SET search_path TO maludb_core, public;
SET TimeZone TO 'UTC';

-- ---------------------------------------------------------------------
-- Test 1: cron_next_after.
-- ---------------------------------------------------------------------
-- '0 0 * * *' at 2026-05-13 12:34:56 → next midnight.
SELECT cron_next_after('0 0 * * *', '2026-05-13 12:34:56+00')
    = '2026-05-14 00:00:00+00'::timestamptz AS daily_midnight;

-- '*/15 * * * *' next quarter hour after 12:34 → 12:45.
SELECT cron_next_after('*/15 * * * *', '2026-05-13 12:34:00+00')
    = '2026-05-13 12:45:00+00'::timestamptz AS every_15_min;

-- '@daily' alias.
SELECT cron_next_after('@daily', '2026-05-13 12:00:00+00')
    = '2026-05-14 00:00:00+00'::timestamptz AS alias_daily;

-- Range + comma list: minute 10 or 20 on hour 3.
SELECT cron_next_after('10,20 3 * * *', '2026-05-13 03:15:00+00')
    = '2026-05-13 03:20:00+00'::timestamptz AS list_minute_3am;

-- ---------------------------------------------------------------------
-- Test 2: schedule_create with action_kind='enqueue'. Targets a
-- queue from V3-QUEUE-01.
-- ---------------------------------------------------------------------
SELECT queue_register('cron_smoke_queue', 30000, 1) AS qid \gset q_

SELECT schedule_create(
    'cron_smoke_enqueue',
    '*/5 * * * *',
    'enqueue',
    jsonb_build_object(
        'queue', 'cron_smoke_queue',
        'payload', jsonb_build_object('task', 'lifecycle_sweep')),
    'V3-CRON-01 smoke (enqueue)') AS sid \gset s_

SELECT name, action_kind, enabled, next_run_at IS NOT NULL AS next_run_set
FROM malu$schedule WHERE schedule_id = :'s_sid'::bigint;

-- ---------------------------------------------------------------------
-- Test 3: schedule_run_now triggers the enqueue action; the queue
-- depth increments.
-- ---------------------------------------------------------------------
SELECT pending AS before_run FROM queue_stats() WHERE queue_name = 'cron_smoke_queue';

SELECT schedule_run_now('cron_smoke_enqueue') AS run_id \gset r_

SELECT pending AS after_run FROM queue_stats() WHERE queue_name = 'cron_smoke_queue';

SELECT status, detail_jsonb ? 'job_id' AS recorded_job_id
FROM malu$schedule_run WHERE run_id = :'r_run_id'::bigint;

-- ---------------------------------------------------------------------
-- Test 4: schedule_disable / schedule_enable cycle.
-- ---------------------------------------------------------------------
SELECT schedule_disable('cron_smoke_enqueue', 'test 4') AS was_enabled;
SELECT enabled, next_run_at IS NULL AS cleared
FROM malu$schedule WHERE schedule_id = :'s_sid'::bigint;

SELECT schedule_enable('cron_smoke_enqueue') AS reenabled;
SELECT enabled, next_run_at IS NOT NULL AS rescheduled
FROM malu$schedule WHERE schedule_id = :'s_sid'::bigint;

-- ---------------------------------------------------------------------
-- Test 5: schedule_tick fires schedules whose next_run_at <= now().
-- Force next_run_at into the past and confirm tick runs.
-- ---------------------------------------------------------------------
UPDATE malu$schedule
   SET next_run_at = now() - interval '1 minute'
 WHERE schedule_id = :'s_sid'::bigint;

SELECT schedule_tick() AS fired_count;

-- After the tick, next_run_at has advanced into the future.
SELECT next_run_at > now() AS rescheduled_to_future
FROM malu$schedule WHERE schedule_id = :'s_sid'::bigint;

-- ---------------------------------------------------------------------
-- Test 6: schedule_list filtering.
-- ---------------------------------------------------------------------
SELECT name, action_kind, enabled
FROM schedule_list()
WHERE name = 'cron_smoke_enqueue';

-- ---------------------------------------------------------------------
-- Test 7: audit_event coverage.
-- ---------------------------------------------------------------------
SELECT event_kind, count(*) AS n
FROM malu$audit_event
WHERE event_kind LIKE 'schedule_%'
GROUP BY event_kind
ORDER BY event_kind;

-- ---------------------------------------------------------------------
-- Cleanup.
-- ---------------------------------------------------------------------
DELETE FROM malu$schedule_run WHERE schedule_id = :'s_sid'::bigint;
DELETE FROM malu$schedule     WHERE schedule_id = :'s_sid'::bigint;

DELETE FROM malu$queue_lease WHERE job_id IN
    (SELECT job_id FROM malu$queue_job WHERE queue_id = :'q_qid'::bigint);
DELETE FROM malu$queue_job   WHERE queue_id = :'q_qid'::bigint;
DELETE FROM malu$queue       WHERE queue_id = :'q_qid'::bigint;

DELETE FROM malu$audit_event WHERE event_kind LIKE 'schedule_%' OR event_kind LIKE 'queue_%';
