-- V3-QUEUE-01 — durable job queue regression coverage.
--
-- Exercises: queue_register / queue_enqueue (incl. idempotency) /
-- queue_lease (FOR UPDATE SKIP LOCKED batch) / queue_ack /
-- queue_nack (retry + DLQ promotion) / queue_reap_expired_leases /
-- queue_stats / RLS / audit.

SET search_path TO maludb_core, public;

-- ---------------------------------------------------------------------
-- Setup. The test uses a worker login role granted maludb_queue_worker
-- to exercise lease/ack/nack under RLS.
-- ---------------------------------------------------------------------
DO $body$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'queue_test_user') THEN
        CREATE ROLE queue_test_user LOGIN;
    END IF;
END;
$body$;
GRANT maludb_memory_executor TO queue_test_user;
GRANT maludb_queue_worker    TO queue_test_user;

-- ---------------------------------------------------------------------
-- Test 1: register a primary queue and its DLQ. DLQ must be registered
-- first so the primary can reference it by name.
-- ---------------------------------------------------------------------
SELECT queue_register('q_smoke_dlq', 60000, 0, NULL, 'V3-QUEUE-01 dead-letter target')
    AS dlq_id \gset reg_

SELECT queue_register('q_smoke', 5000, 2, 'q_smoke_dlq', 'V3-QUEUE-01 primary')
    AS queue_id \gset reg_

SELECT :'reg_queue_id'::bigint > 0    AS primary_assigned,
       :'reg_dlq_id'::bigint   > 0    AS dlq_assigned;

-- Re-registering is idempotent (UPSERT).
SELECT queue_register('q_smoke', 5000, 2, 'q_smoke_dlq')
    = :'reg_queue_id'::bigint AS reregister_same_id;

-- ---------------------------------------------------------------------
-- Test 2: enqueue three jobs; one carries an idempotency_key.
-- ---------------------------------------------------------------------
SELECT queue_enqueue('q_smoke', '{"task":"a"}'::jsonb)              AS job_a \gset e_
SELECT queue_enqueue('q_smoke', '{"task":"b"}'::jsonb, 'dedup-1')   AS job_b \gset e_
SELECT queue_enqueue('q_smoke', '{"task":"c"}'::jsonb, NULL, 5)     AS job_c \gset e_

-- Idempotent re-enqueue with the same key returns job_b's id, no new row.
SELECT queue_enqueue('q_smoke', '{"task":"b-dup"}'::jsonb, 'dedup-1')
       = :'e_job_b'::bigint AS dedup_returns_existing;

SELECT count(*) AS total_jobs FROM malu$queue_job WHERE queue_id = :'reg_queue_id'::bigint;

-- ---------------------------------------------------------------------
-- Test 3: lease a batch of 2 jobs. Higher-priority job_c wins first.
-- ---------------------------------------------------------------------
SELECT job_id, payload, attempts
FROM queue_lease('q_smoke', 'worker-1', 2)
ORDER BY job_id;

-- After the lease, two leases exist and two jobs are leased.
SELECT count(*) AS active_leases FROM malu$queue_lease;
SELECT status, count(*) FROM malu$queue_job
WHERE queue_id = :'reg_queue_id'::bigint
GROUP BY status ORDER BY status;

-- ---------------------------------------------------------------------
-- Test 4: ack job_a explicitly. Targeting by id makes the test
-- deterministic — multiple leases acquired in the same queue_lease()
-- call share a `leased_at` timestamp, so ordering by leased_at alone
-- isn't a stable selector.
-- ---------------------------------------------------------------------
SELECT queue_ack(:'e_job_a'::bigint) AS ack_ok;

-- ---------------------------------------------------------------------
-- Test 5: nack job_c twice. With max_retries=2 the second nack
-- (v_job.attempts becomes 2 after the re-lease) promotes the job to
-- 'dead' and copies the payload onto the DLQ.
-- ---------------------------------------------------------------------
SELECT queue_nack(:'e_job_c'::bigint, 'attempt-1 failed') AS first_nack_outcome;

-- Re-lease. job_c (priority=5) wins over job_b (priority=0) for the
-- batch-of-one slot. attempts on job_c becomes 2.
SELECT job_id, attempts FROM queue_lease('q_smoke', 'worker-1', 1);

SELECT queue_nack(:'e_job_c'::bigint, 'attempt-2 still failed') AS second_nack_outcome;

-- job_c is now dead and its payload has been copied onto the DLQ.
SELECT status FROM malu$queue_job WHERE job_id = :'e_job_c'::bigint;

SELECT count(*) AS dlq_depth FROM malu$queue_job
WHERE queue_id = :'reg_dlq_id'::bigint;

-- ---------------------------------------------------------------------
-- Test 6: queue_stats summary across the two queues.
-- ---------------------------------------------------------------------
SELECT queue_name, pending, leased, completed, failed, dead
FROM queue_stats()
WHERE queue_name IN ('q_smoke', 'q_smoke_dlq')
ORDER BY queue_name;

-- ---------------------------------------------------------------------
-- Test 7: lease-expiry reap.
-- ---------------------------------------------------------------------
-- Enqueue a new job and lease it; force the lease into the past.
SELECT queue_enqueue('q_smoke', '{"task":"reap-me"}'::jsonb) AS reap_job \gset e_

WITH leased AS (
    SELECT job_id FROM queue_lease('q_smoke', 'worker-reap', 1)
)
SELECT count(*) AS leased_for_reap FROM leased;

UPDATE malu$queue_lease SET expires_at = now() - interval '1 minute';

SELECT queue_reap_expired_leases() AS reclaimed;

-- After reap, that job should be back to pending.
SELECT status FROM malu$queue_job WHERE job_id = :'e_reap_job'::bigint;

-- ---------------------------------------------------------------------
-- Test 8: RLS isolation. queue_test_user (granted memory_executor +
-- queue_worker) using the maludb_core search_path sees rows owned by
-- 'maludb_core' (the schema all of the test rows were INSERTed under,
-- since this test's top-level `SET search_path TO maludb_core, public`
-- makes current_schema()='maludb_core'). When the test_user binds its
-- search_path to a non-maludb_core schema, current_schema() flips and
-- the rows disappear.
-- ---------------------------------------------------------------------
SET ROLE queue_test_user;
SET search_path TO maludb_core, public;

SELECT count(*) > 0 AS sees_test_jobs
FROM malu$queue_job
WHERE queue_id = :'reg_queue_id'::bigint;

SET search_path TO public, pg_catalog;
SELECT count(*) AS sees_nothing
FROM maludb_core.malu$queue_job
WHERE queue_id = :'reg_queue_id'::bigint;

RESET ROLE;
SET search_path TO maludb_core, public;

-- ---------------------------------------------------------------------
-- Test 9: audit_event coverage.
-- ---------------------------------------------------------------------
SELECT event_kind, count(*) AS n
FROM malu$audit_event
WHERE event_kind LIKE 'queue_%'
GROUP BY event_kind
ORDER BY event_kind;

-- ---------------------------------------------------------------------
-- Cleanup.
-- ---------------------------------------------------------------------
DELETE FROM malu$queue_lease WHERE job_id IN (
    SELECT job_id FROM malu$queue_job WHERE queue_id IN (:'reg_queue_id'::bigint, :'reg_dlq_id'::bigint));
DELETE FROM malu$queue_job   WHERE queue_id IN (:'reg_queue_id'::bigint, :'reg_dlq_id'::bigint);
UPDATE malu$queue SET dlq_queue_id = NULL WHERE queue_id IN (:'reg_queue_id'::bigint, :'reg_dlq_id'::bigint);
DELETE FROM malu$queue       WHERE queue_id IN (:'reg_queue_id'::bigint, :'reg_dlq_id'::bigint);
DELETE FROM malu$audit_event WHERE event_kind LIKE 'queue_%';

REVOKE maludb_memory_executor FROM queue_test_user;
REVOKE maludb_queue_worker    FROM queue_test_user;
DROP ROLE queue_test_user;
