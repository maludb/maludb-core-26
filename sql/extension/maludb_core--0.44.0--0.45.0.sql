\echo Use "ALTER EXTENSION maludb_core UPDATE TO '0.45.0'" to load this file. \quit

-- =====================================================================
-- maludb_core 0.44.0 → 0.45.0
--
-- Stage 11 / V3-QUEUE-01: durable job queue.
--
-- One queue abstraction the V3 stages will share — ingestion,
-- embedding, re-derivation, broker-audit ingest, lifecycle sweeps,
-- ANN rebuilds, notification fanout. Native PostgreSQL implementation
-- using FOR UPDATE SKIP LOCKED lease semantics; the pgmq adoption
-- door is left open (the table shape mirrors pgmq closely enough that
-- a future migration could swap the implementation without breaking
-- the SQL contract).
--
-- Shape:
--   malu$queue         — one row per named queue. Default visibility,
--                        max retries, optional DLQ target.
--   malu$queue_job     — append-only job log. status in
--                        {pending, leased, completed, failed, dead}.
--   malu$queue_lease   — one row per actively leased job, with
--                        worker_id, leased_at, expires_at.
--
-- Doctrine:
--   * Workers acquire leases atomically via SELECT ... FOR UPDATE
--     SKIP LOCKED inside queue_lease(); no two workers can lease the
--     same job.
--   * Visibility expiry: queue_reap_expired_leases() returns expired
--     leases to pending. Operators schedule this through V3-CRON-01.
--   * Idempotency: UNIQUE (queue_id, idempotency_key) WHERE
--     idempotency_key IS NOT NULL. A second enqueue with the same
--     key returns the existing job_id instead of erroring.
--   * Dead-letter: queue_nack auto-promotes to status='dead' once
--     attempts > queue.max_retries. If a DLQ is configured, the
--     payload is enqueued onto it.
--   * RLS owner_schema-bound across all three tables.
--
-- Apply with:
--   ALTER EXTENSION maludb_core UPDATE TO '0.45.0';
-- =====================================================================

CREATE OR REPLACE FUNCTION maludb_core_version() RETURNS text
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$ SELECT '0.45.0'::text $body$;

-- ---------------------------------------------------------------------
-- maludb_queue_worker — NOLOGIN role granted INSERT/UPDATE/SELECT on
-- the queue catalog. Operators GRANT it to the service login roles
-- that run queue workers (embedding workers, ingestion workers, etc.).
-- ---------------------------------------------------------------------
DO $body$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'maludb_queue_worker') THEN
        CREATE ROLE maludb_queue_worker NOLOGIN;
    END IF;
END;
$body$;
GRANT USAGE ON SCHEMA maludb_core TO maludb_queue_worker;

-- ---------------------------------------------------------------------
-- malu$queue
-- ---------------------------------------------------------------------
CREATE TABLE malu$queue (
    queue_id              bigserial PRIMARY KEY,
    name                  text       NOT NULL,
    default_visibility_ms integer    NOT NULL DEFAULT 30000 CHECK (default_visibility_ms > 0),
    max_retries           smallint   NOT NULL DEFAULT 3     CHECK (max_retries >= 0),
    dlq_queue_id          bigint     REFERENCES malu$queue(queue_id) ON DELETE SET NULL,
    description           text,
    owner_schema          name       NOT NULL DEFAULT current_schema(),
    created_at            timestamptz NOT NULL DEFAULT now(),
    retired_at            timestamptz,
    UNIQUE (owner_schema, name),
    CHECK (dlq_queue_id IS NULL OR dlq_queue_id <> queue_id)
);
CREATE INDEX malu$queue_owner_idx ON malu$queue(owner_schema) WHERE retired_at IS NULL;

-- ---------------------------------------------------------------------
-- malu$queue_job
-- ---------------------------------------------------------------------
CREATE TABLE malu$queue_job (
    job_id           bigserial PRIMARY KEY,
    queue_id         bigint    NOT NULL REFERENCES malu$queue(queue_id) ON DELETE CASCADE,
    payload          jsonb     NOT NULL,
    idempotency_key  text,
    priority         smallint  NOT NULL DEFAULT 0,
    account_id       bigint,
    owner_schema     name      NOT NULL DEFAULT current_schema(),
    status           text      NOT NULL DEFAULT 'pending' CHECK (status IN
                        ('pending','leased','completed','failed','dead')),
    enqueued_at      timestamptz NOT NULL DEFAULT now(),
    visible_at       timestamptz NOT NULL DEFAULT now(),
    attempts         smallint  NOT NULL DEFAULT 0,
    last_error       text,
    last_state_change_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX malu$queue_job_idempotency_idx
    ON malu$queue_job(queue_id, idempotency_key)
    WHERE idempotency_key IS NOT NULL;
CREATE INDEX malu$queue_job_pending_idx
    ON malu$queue_job(queue_id, priority DESC, visible_at, job_id)
    WHERE status = 'pending';
CREATE INDEX malu$queue_job_status_idx
    ON malu$queue_job(queue_id, status);
CREATE INDEX malu$queue_job_owner_idx
    ON malu$queue_job(owner_schema, queue_id, status);

-- ---------------------------------------------------------------------
-- malu$queue_lease
-- ---------------------------------------------------------------------
CREATE TABLE malu$queue_lease (
    lease_id    bigserial PRIMARY KEY,
    job_id      bigint    NOT NULL UNIQUE REFERENCES malu$queue_job(job_id) ON DELETE CASCADE,
    worker_id   text      NOT NULL,
    leased_at   timestamptz NOT NULL DEFAULT now(),
    expires_at  timestamptz NOT NULL
);
CREATE INDEX malu$queue_lease_expires_idx ON malu$queue_lease(expires_at);
CREATE INDEX malu$queue_lease_worker_idx  ON malu$queue_lease(worker_id, leased_at DESC);

-- ---------------------------------------------------------------------
-- RLS — every queue table owner_schema-bound. Lease rows inherit from
-- their parent job's owner_schema.
-- ---------------------------------------------------------------------
ALTER TABLE malu$queue ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_owner ON malu$queue
    USING      (owner_schema = current_schema())
    WITH CHECK (owner_schema = current_schema());

ALTER TABLE malu$queue_job ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_owner ON malu$queue_job
    USING      (owner_schema = current_schema())
    WITH CHECK (owner_schema = current_schema());

ALTER TABLE malu$queue_lease ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_via_job ON malu$queue_lease
    USING (
        EXISTS (
            SELECT 1 FROM malu$queue_job j
            WHERE j.job_id       = malu$queue_lease.job_id
              AND j.owner_schema = current_schema()
        )
    )
    WITH CHECK (
        EXISTS (
            SELECT 1 FROM malu$queue_job j
            WHERE j.job_id       = malu$queue_lease.job_id
              AND j.owner_schema = current_schema()
        )
    );

-- ---------------------------------------------------------------------
-- Grants. Admin gets full; executor enqueues + reads (no direct DLQ
-- promotion or lease mutation); auditor reads; queue_worker leases /
-- acks / nacks.
-- ---------------------------------------------------------------------
GRANT SELECT, INSERT, UPDATE, DELETE ON malu$queue, malu$queue_job, malu$queue_lease TO
    maludb_memory_admin, maludb_queue_worker;
GRANT SELECT, INSERT ON malu$queue, malu$queue_job TO
    maludb_memory_executor;
GRANT SELECT ON malu$queue, malu$queue_job, malu$queue_lease TO
    maludb_memory_auditor;

GRANT USAGE, SELECT ON SEQUENCE malu$queue_queue_id_seq      TO maludb_memory_admin, maludb_memory_executor;
GRANT USAGE, SELECT ON SEQUENCE malu$queue_job_job_id_seq    TO maludb_memory_admin, maludb_memory_executor, maludb_queue_worker;
GRANT USAGE, SELECT ON SEQUENCE malu$queue_lease_lease_id_seq TO maludb_memory_admin, maludb_queue_worker;

-- =====================================================================
-- Public API
-- =====================================================================

-- queue_register — UPSERT a named queue.
CREATE FUNCTION queue_register(
    p_name                   text,
    p_default_visibility_ms  integer DEFAULT 30000,
    p_max_retries            integer DEFAULT 3,
    p_dlq_name               text    DEFAULT NULL,
    p_description            text    DEFAULT NULL
) RETURNS bigint
    LANGUAGE plpgsql VOLATILE
    AS $body$
#variable_conflict use_column
DECLARE
    v_dlq_id bigint;
    v_id     bigint;
BEGIN
    IF p_dlq_name IS NOT NULL THEN
        SELECT q.queue_id INTO v_dlq_id
          FROM malu$queue q
         WHERE q.name = p_dlq_name;
        IF v_dlq_id IS NULL THEN
            RAISE EXCEPTION 'queue_register: DLQ queue % not found', p_dlq_name
                USING ERRCODE = 'no_data_found';
        END IF;
    END IF;

    INSERT INTO malu$queue(name, default_visibility_ms, max_retries, dlq_queue_id, description)
    VALUES (p_name, p_default_visibility_ms, p_max_retries, v_dlq_id, p_description)
    ON CONFLICT (owner_schema, name) DO UPDATE
        SET default_visibility_ms = EXCLUDED.default_visibility_ms,
            max_retries           = EXCLUDED.max_retries,
            dlq_queue_id          = EXCLUDED.dlq_queue_id,
            description           = EXCLUDED.description,
            retired_at            = NULL
    RETURNING queue_id INTO v_id;

    PERFORM audit_event(
        'queue_register', 'malu$queue', v_id,
        jsonb_build_object('name', p_name, 'default_visibility_ms', p_default_visibility_ms,
                           'max_retries', p_max_retries, 'dlq', p_dlq_name),
        NULL);
    RETURN v_id;
END;
$body$;
REVOKE EXECUTE ON FUNCTION queue_register(text, integer, integer, text, text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION queue_register(text, integer, integer, text, text) TO
    maludb_memory_admin, maludb_memory_executor;

-- queue_enqueue — push a payload onto the named queue. Returns the
-- job_id. If an idempotency_key is supplied and a non-retired job
-- with that key already exists, returns its existing job_id and does
-- not insert a duplicate.
CREATE FUNCTION queue_enqueue(
    p_queue_name      text,
    p_payload         jsonb,
    p_idempotency_key text        DEFAULT NULL,
    p_priority        integer     DEFAULT 0,
    p_visible_at      timestamptz DEFAULT NULL,
    p_account_id      bigint      DEFAULT NULL
) RETURNS bigint
    LANGUAGE plpgsql VOLATILE
    AS $body$
#variable_conflict use_column
DECLARE
    v_queue_id bigint;
    v_existing bigint;
    v_id       bigint;
BEGIN
    SELECT q.queue_id INTO v_queue_id
      FROM malu$queue q
     WHERE q.name = p_queue_name AND q.retired_at IS NULL;
    IF v_queue_id IS NULL THEN
        RAISE EXCEPTION 'queue_enqueue: queue % not found or retired', p_queue_name
            USING ERRCODE = 'no_data_found';
    END IF;

    IF p_idempotency_key IS NOT NULL THEN
        SELECT j.job_id INTO v_existing
          FROM malu$queue_job j
         WHERE j.queue_id        = v_queue_id
           AND j.idempotency_key = p_idempotency_key;
        IF v_existing IS NOT NULL THEN
            RETURN v_existing;
        END IF;
    END IF;

    INSERT INTO malu$queue_job
        (queue_id, payload, idempotency_key, priority, visible_at, account_id)
    VALUES
        (v_queue_id, p_payload, p_idempotency_key, p_priority::smallint,
         COALESCE(p_visible_at, now()), p_account_id)
    RETURNING job_id INTO v_id;

    PERFORM audit_event(
        'queue_enqueue', 'malu$queue_job', v_id,
        jsonb_build_object('queue', p_queue_name, 'priority', p_priority,
                           'idempotency_key', p_idempotency_key),
        NULL);
    RETURN v_id;
END;
$body$;
REVOKE EXECUTE ON FUNCTION queue_enqueue(text, jsonb, text, integer, timestamptz, bigint) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION queue_enqueue(text, jsonb, text, integer, timestamptz, bigint) TO
    maludb_memory_admin, maludb_memory_executor, maludb_queue_worker;

-- queue_lease — atomically claim up to `p_batch` pending jobs. Uses
-- FOR UPDATE SKIP LOCKED so concurrent workers see different rows.
-- Each leased job moves to status='leased' with a malu$queue_lease
-- row holding the worker_id and visibility expiry.
CREATE FUNCTION queue_lease(
    p_queue_name     text,
    p_worker_id      text,
    p_batch          integer DEFAULT 1,
    p_visibility_ms  integer DEFAULT NULL
) RETURNS TABLE (job_id bigint, payload jsonb, attempts integer, enqueued_at timestamptz)
    LANGUAGE plpgsql VOLATILE
    AS $body$
#variable_conflict use_column
DECLARE
    v_queue       malu$queue%ROWTYPE;
    v_vis_ms      integer;
BEGIN
    SELECT * INTO v_queue FROM malu$queue WHERE name = p_queue_name AND retired_at IS NULL;
    IF v_queue.queue_id IS NULL THEN
        RAISE EXCEPTION 'queue_lease: queue % not found or retired', p_queue_name
            USING ERRCODE = 'no_data_found';
    END IF;
    v_vis_ms := COALESCE(p_visibility_ms, v_queue.default_visibility_ms);

    RETURN QUERY
    WITH candidates AS (
        SELECT j.job_id
          FROM malu$queue_job j
         WHERE j.queue_id = v_queue.queue_id
           AND j.status   = 'pending'
           AND j.visible_at <= now()
         ORDER BY j.priority DESC, j.visible_at, j.job_id
         LIMIT GREATEST(p_batch, 1)
         FOR UPDATE SKIP LOCKED
    ),
    leased AS (
        UPDATE malu$queue_job j
           SET status               = 'leased',
               attempts             = j.attempts + 1,
               last_state_change_at = now()
          FROM candidates c
         WHERE j.job_id = c.job_id
        RETURNING j.job_id, j.payload, j.attempts, j.enqueued_at
    ),
    leases AS (
        INSERT INTO malu$queue_lease(job_id, worker_id, expires_at)
        SELECT l.job_id, p_worker_id, now() + (v_vis_ms || ' ms')::interval
          FROM leased l
        RETURNING job_id
    )
    SELECT l.job_id, l.payload, l.attempts::integer, l.enqueued_at FROM leased l;
END;
$body$;
REVOKE EXECUTE ON FUNCTION queue_lease(text, text, integer, integer) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION queue_lease(text, text, integer, integer) TO
    maludb_memory_admin, maludb_queue_worker;

-- queue_ack — mark a leased job completed and release its lease.
CREATE FUNCTION queue_ack(p_job_id bigint)
    RETURNS boolean
    LANGUAGE plpgsql VOLATILE
    AS $body$
#variable_conflict use_column
DECLARE v_was_leased boolean;
BEGIN
    DELETE FROM malu$queue_lease WHERE job_id = p_job_id;

    UPDATE malu$queue_job
       SET status = 'completed',
           last_state_change_at = now(),
           last_error = NULL
     WHERE job_id = p_job_id
       AND status = 'leased'
    RETURNING true INTO v_was_leased;

    IF v_was_leased THEN
        PERFORM audit_event('queue_ack', 'malu$queue_job', p_job_id, NULL, NULL);
        RETURN true;
    END IF;
    RETURN false;
END;
$body$;
REVOKE EXECUTE ON FUNCTION queue_ack(bigint) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION queue_ack(bigint) TO
    maludb_memory_admin, maludb_queue_worker;

-- queue_nack — fail a leased job. Increments attempts; if it now
-- exceeds the queue's max_retries, marks the job 'dead' and (when a
-- DLQ is configured) enqueues the payload onto the DLQ.
CREATE FUNCTION queue_nack(p_job_id bigint, p_error_text text DEFAULT NULL)
    RETURNS text
    LANGUAGE plpgsql VOLATILE
    AS $body$
#variable_conflict use_column
DECLARE
    v_job      malu$queue_job%ROWTYPE;
    v_queue    malu$queue%ROWTYPE;
    v_dlq_name text;
    v_outcome  text;
BEGIN
    SELECT * INTO v_job FROM malu$queue_job WHERE job_id = p_job_id;
    IF v_job.job_id IS NULL THEN
        RAISE EXCEPTION 'queue_nack: job % not found', p_job_id
            USING ERRCODE = 'no_data_found';
    END IF;
    IF v_job.status <> 'leased' THEN
        RAISE EXCEPTION 'queue_nack: job % is not leased (status=%)',
            p_job_id, v_job.status
            USING ERRCODE = 'object_not_in_prerequisite_state';
    END IF;

    SELECT * INTO v_queue FROM malu$queue WHERE queue_id = v_job.queue_id;

    DELETE FROM malu$queue_lease WHERE job_id = p_job_id;

    IF v_job.attempts >= v_queue.max_retries THEN
        UPDATE malu$queue_job
           SET status               = 'dead',
               last_error           = p_error_text,
               last_state_change_at = now()
         WHERE job_id = p_job_id;
        v_outcome := 'dead';

        IF v_queue.dlq_queue_id IS NOT NULL THEN
            SELECT q.name INTO v_dlq_name FROM malu$queue q WHERE q.queue_id = v_queue.dlq_queue_id;
            PERFORM queue_enqueue(
                v_dlq_name,
                jsonb_build_object(
                    'source_queue', v_queue.name,
                    'source_job_id', p_job_id,
                    'last_error',   p_error_text,
                    'payload',      v_job.payload),
                NULL, 0, NULL, NULL);
        END IF;
    ELSE
        UPDATE malu$queue_job
           SET status               = 'pending',
               last_error           = p_error_text,
               visible_at           = now(),
               last_state_change_at = now()
         WHERE job_id = p_job_id;
        v_outcome := 'pending';
    END IF;

    PERFORM audit_event('queue_nack', 'malu$queue_job', p_job_id,
        jsonb_build_object('outcome', v_outcome, 'attempts', v_job.attempts,
                           'max_retries', v_queue.max_retries,
                           'dlq', v_dlq_name),
        p_error_text);
    RETURN v_outcome;
END;
$body$;
REVOKE EXECUTE ON FUNCTION queue_nack(bigint, text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION queue_nack(bigint, text) TO
    maludb_memory_admin, maludb_queue_worker;

-- queue_reap_expired_leases — reclaim leases past their expires_at
-- back to pending; returns the count.
CREATE FUNCTION queue_reap_expired_leases()
    RETURNS integer
    LANGUAGE plpgsql VOLATILE
    AS $body$
#variable_conflict use_column
DECLARE v_n integer;
BEGIN
    WITH expired AS (
        SELECT job_id FROM malu$queue_lease WHERE expires_at <= now()
    ),
    deleted_leases AS (
        DELETE FROM malu$queue_lease l USING expired e
         WHERE l.job_id = e.job_id
        RETURNING l.job_id
    ),
    revived AS (
        UPDATE malu$queue_job j
           SET status               = 'pending',
               visible_at           = now(),
               last_state_change_at = now()
          FROM deleted_leases d
         WHERE j.job_id = d.job_id
           AND j.status = 'leased'
        RETURNING j.job_id
    )
    SELECT count(*)::integer INTO v_n FROM revived;

    IF v_n > 0 THEN
        PERFORM audit_event('queue_reap', 'malu$queue_lease', NULL,
            jsonb_build_object('reclaimed', v_n), NULL);
    END IF;
    RETURN v_n;
END;
$body$;
REVOKE EXECUTE ON FUNCTION queue_reap_expired_leases() FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION queue_reap_expired_leases() TO
    maludb_memory_admin, maludb_queue_worker;

-- queue_stats — operator-facing depth + retry view.
CREATE FUNCTION queue_stats()
    RETURNS TABLE (
        queue_name  text,
        pending     bigint,
        leased      bigint,
        completed   bigint,
        failed      bigint,
        dead        bigint
    ) LANGUAGE plpgsql STABLE
    AS $body$
#variable_conflict use_column
BEGIN
    RETURN QUERY
    SELECT q.name,
           count(*) FILTER (WHERE j.status = 'pending'),
           count(*) FILTER (WHERE j.status = 'leased'),
           count(*) FILTER (WHERE j.status = 'completed'),
           count(*) FILTER (WHERE j.status = 'failed'),
           count(*) FILTER (WHERE j.status = 'dead')
      FROM malu$queue q
      LEFT JOIN malu$queue_job j ON j.queue_id = q.queue_id
     WHERE q.retired_at IS NULL
     GROUP BY q.name
     ORDER BY q.name;
END;
$body$;
REVOKE EXECUTE ON FUNCTION queue_stats() FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION queue_stats() TO
    maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor,
    maludb_queue_worker;
