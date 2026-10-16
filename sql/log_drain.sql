-- V3-LOG-01 — log drain catalog regression coverage.

SET search_path TO maludb_core, public;

-- ---------------------------------------------------------------------
-- Test 1: set, list, enable/disable cycle.
-- ---------------------------------------------------------------------
SELECT log_drain_set(
    'audit_to_s3', 's3',
    jsonb_build_object('bucket','maludb-logs','region','us-east-1','key_prefix','audit/'),
    ARRAY['audit_event','rest_invocation','mc2db_invocation']::text[],
    'logs_s3_creds',
    '[{"path":"$.payload.token","replace":"***"}]'::jsonb,
    200, 10000) AS drain_id \gset d_

SELECT name, kind, source_streams, enabled, retired_at IS NULL AS live
FROM malu$log_drain WHERE drain_id = :'d_drain_id'::bigint;

-- ---------------------------------------------------------------------
-- Test 2: kind validation.
-- ---------------------------------------------------------------------
DO $body$
BEGIN
    PERFORM log_drain_set('bogus', 'gopher',
        '{}'::jsonb, ARRAY['audit_event']::text[],
        NULL, '[]'::jsonb, 100, 5000);
    RAISE EXCEPTION 'accepted invalid kind (test 2 fail)';
EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'log_drain_set rejects invalid kind';
END;
$body$;

-- ---------------------------------------------------------------------
-- Test 3: at-least-one source_stream required.
-- ---------------------------------------------------------------------
DO $body$
BEGIN
    PERFORM log_drain_set('empty', 'file',
        jsonb_build_object('path','/var/log/maludb/foo.jsonl'),
        ARRAY[]::text[],
        NULL, '[]'::jsonb, 100, 5000);
    RAISE EXCEPTION 'accepted empty source_streams (test 3 fail)';
EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'log_drain_set rejects empty source_streams';
END;
$body$;

-- ---------------------------------------------------------------------
-- Test 4: disable then list (include_disabled).
-- ---------------------------------------------------------------------
SELECT log_drain_disable('audit_to_s3', 'test 4 disable') AS was_enabled;

SELECT count(*) AS visible_in_default
FROM log_drain_list()
WHERE name = 'audit_to_s3';

SELECT count(*) AS visible_with_disabled
FROM log_drain_list(true)
WHERE name = 'audit_to_s3';

-- ---------------------------------------------------------------------
-- Test 5: record a run.
-- ---------------------------------------------------------------------
SELECT log_drain_record_run(:'d_drain_id'::bigint, 3, 4096::bigint, 250, 0, NULL) AS run_id \gset r_

SELECT batches, bytes, records, errors
FROM malu$log_drain_run WHERE run_id = :'r_run_id'::bigint;

-- ---------------------------------------------------------------------
-- Test 6: audit coverage.
-- ---------------------------------------------------------------------
SELECT event_kind, count(*) AS n
FROM malu$audit_event WHERE event_kind LIKE 'log_drain_%'
GROUP BY event_kind ORDER BY event_kind;

-- ---------------------------------------------------------------------
-- Cleanup.
-- ---------------------------------------------------------------------
DELETE FROM malu$log_drain_run  WHERE drain_id = :'d_drain_id'::bigint;
DELETE FROM malu$log_drain      WHERE drain_id = :'d_drain_id'::bigint;
DELETE FROM malu$audit_event    WHERE event_kind LIKE 'log_drain_%';
