-- V3-PRESENCE-01 — pool presence regression coverage.

SET search_path TO maludb_core, public;

-- ---------------------------------------------------------------------
-- Setup. Create an active memory pool.
-- ---------------------------------------------------------------------
SELECT create_active_memory_pool('presence_smoke_pool', 'sql') AS pool_id \gset p_

-- ---------------------------------------------------------------------
-- Test 1: join (first presence_update for a fresh participant).
-- ---------------------------------------------------------------------
SELECT presence_update(:'p_pool_id'::bigint, 'human', 'alice', 'reviewer', 'review run #42')
    AS alice_pid \gset pr_

SELECT participant_kind, participant_ref, role, declared_task
FROM malu$pool_presence WHERE presence_id = :'pr_alice_pid'::bigint;

-- A join event lands on malu$pool_presence_event and on malu$event.
SELECT kind FROM malu$pool_presence_event
WHERE presence_id = :'pr_alice_pid'::bigint
ORDER BY event_id DESC LIMIT 1;

SELECT event_kind FROM malu$event
WHERE event_kind = 'pool_presence_join' AND object_id = :'pr_alice_pid'::bigint
ORDER BY event_id DESC LIMIT 1;

-- ---------------------------------------------------------------------
-- Test 2: update (subsequent presence_update for the same participant).
-- ---------------------------------------------------------------------
SELECT presence_update(:'p_pool_id'::bigint, 'human', 'alice', NULL, 'review run #43')
    = :'pr_alice_pid'::bigint AS reused_presence_row;

SELECT declared_task FROM malu$pool_presence WHERE presence_id = :'pr_alice_pid'::bigint;

SELECT kind FROM malu$pool_presence_event
WHERE presence_id = :'pr_alice_pid'::bigint
ORDER BY event_id DESC LIMIT 1;

-- ---------------------------------------------------------------------
-- Test 3: a second participant joins.
-- ---------------------------------------------------------------------
SELECT presence_update(:'p_pool_id'::bigint, 'agent', 'agent-007', 'planner', 'plan ablation')
    AS agent_pid \gset pr_

SELECT count(*) AS active_participants
FROM presence_list(:'p_pool_id'::bigint)
WHERE left_at IS NULL;

-- ---------------------------------------------------------------------
-- Test 4: leave.
-- ---------------------------------------------------------------------
SELECT presence_leave(:'p_pool_id'::bigint, 'human', 'alice', 'session end') AS was_present;

SELECT left_at IS NOT NULL AS marked_left
FROM malu$pool_presence WHERE presence_id = :'pr_alice_pid'::bigint;

SELECT count(*) AS active_after_leave
FROM presence_list(:'p_pool_id'::bigint)
WHERE left_at IS NULL;

SELECT kind FROM malu$pool_presence_event
WHERE presence_id = :'pr_alice_pid'::bigint
ORDER BY event_id DESC LIMIT 1;

-- ---------------------------------------------------------------------
-- Test 5: presence transitions emit malu$event rows that a subscriber
-- can fetch.
-- ---------------------------------------------------------------------
SELECT event_kind, count(*) AS n
FROM malu$event
WHERE event_kind LIKE 'pool_presence_%' AND active_pool_id = :'p_pool_id'::bigint
GROUP BY event_kind
ORDER BY event_kind;

-- ---------------------------------------------------------------------
-- Test 6 (V3-PRESENCE-02): TTL + sweeper.
--   * Join 'bot-cleanup' with ttl_seconds=60.
--   * Backdate last_seen_at so the TTL is already expired.
--   * presence_sweep() returns 1 (this row).
--   * The row is now marked left_at, with reason='ttl_expired' on
--     the trailing pool_presence_event row.
--   * A second sweep is a no-op.
-- ---------------------------------------------------------------------
SELECT presence_update(:'p_pool_id'::bigint, 'agent', 'bot-cleanup',
                       'cleanup', 'sweep tester', NULL, 60)
    AS sweepable_pid \gset pr_

SELECT ttl_seconds FROM malu$pool_presence
WHERE presence_id = :'pr_sweepable_pid'::bigint;

UPDATE malu$pool_presence
   SET last_seen_at = now() - interval '5 minutes'
 WHERE presence_id = :'pr_sweepable_pid'::bigint;

SELECT presence_sweep() AS swept;

SELECT left_at IS NOT NULL AS marked_left
FROM malu$pool_presence WHERE presence_id = :'pr_sweepable_pid'::bigint;

SELECT kind, detail_jsonb ->> 'reason' AS reason
FROM malu$pool_presence_event
WHERE presence_id = :'pr_sweepable_pid'::bigint
ORDER BY event_id DESC LIMIT 1;

SELECT presence_sweep() AS swept_again;

-- ---------------------------------------------------------------------
-- Cleanup.
-- ---------------------------------------------------------------------
DELETE FROM malu$pool_presence_event WHERE presence_id IN
    (SELECT presence_id FROM malu$pool_presence WHERE pool_id = :'p_pool_id'::bigint);
DELETE FROM malu$pool_presence  WHERE pool_id = :'p_pool_id'::bigint;
DELETE FROM malu$event          WHERE active_pool_id = :'p_pool_id'::bigint OR event_kind LIKE 'pool_presence_%';
DELETE FROM malu$audit_event    WHERE event_kind LIKE 'pool_presence_%';
DELETE FROM malu$active_memory_pool WHERE pool_id = :'p_pool_id'::bigint;
