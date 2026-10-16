\echo Use "ALTER EXTENSION maludb_core UPDATE TO '0.49.0'" to load this file. \quit

-- =====================================================================
-- maludb_core 0.48.0 → 0.49.0
--
-- Stage 13 / V3-REALTIME-01 (catalog): memory event stream.
--
-- Adds the durable backbone for realtime delivery:
--   malu$event              — append-only, monotonic event_id is the
--                             cursor. Carries event_kind, account,
--                             partition, active_pool, object_ref,
--                             scope, transaction_time, payload.
--   malu$event_subscription — per-account subscription state with
--                             filter set (kinds[], partitions[],
--                             active_pool) and persistent cursor.
--   malu$event_delivery     — append-only delivery audit per
--                             subscription.
--
-- emit_event NOTIFY-s on channel `maludb_event` so the future
-- maludb-realtimed service can use LISTEN for low-latency wakeups
-- instead of polling. The payload is the bigint event_id as text.
--
-- Stage 13 retrofits the V3-shipped write paths (auth_token,
-- secret_*, source_object_register, queue_enqueue, schedule_run_*)
-- to emit events in `0.48.0 -> 0.49.0` only; the Stage 2-7 register_*
-- functions stay untouched (a Stage 13 follow-up extends them).
--
-- Apply with:
--   ALTER EXTENSION maludb_core UPDATE TO '0.49.0';
-- =====================================================================

CREATE OR REPLACE FUNCTION maludb_core_version() RETURNS text
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$ SELECT '0.49.0'::text $body$;

-- ---------------------------------------------------------------------
-- malu$event — the durable event log. event_id is BIGSERIAL and is
-- the cursor; every subscriber persists a "last-acked" event_id.
-- ---------------------------------------------------------------------
CREATE TABLE malu$event (
    event_id          bigserial PRIMARY KEY,
    event_kind        text       NOT NULL,
    account_id        bigint     REFERENCES malu$account(account_id) ON DELETE SET NULL,
    partition         text,
    active_pool_id    bigint,
    object_type       text,
    object_id         bigint,
    scope             jsonb,
    transaction_time  timestamptz NOT NULL DEFAULT now(),
    payload           jsonb      NOT NULL DEFAULT '{}'::jsonb,
    owner_schema      name       NOT NULL DEFAULT current_schema()
);
CREATE INDEX malu$event_kind_idx     ON malu$event(event_kind, event_id DESC);
CREATE INDEX malu$event_account_idx  ON malu$event(account_id, event_id DESC) WHERE account_id IS NOT NULL;
CREATE INDEX malu$event_owner_idx    ON malu$event(owner_schema, event_id DESC);
CREATE INDEX malu$event_object_idx   ON malu$event(object_type, object_id, event_id DESC) WHERE object_id IS NOT NULL;

-- ---------------------------------------------------------------------
-- malu$event_subscription — per-subscriber state.
-- ---------------------------------------------------------------------
CREATE TABLE malu$event_subscription (
    subscription_id bigserial PRIMARY KEY,
    name            text,
    account_id      bigint     REFERENCES malu$account(account_id) ON DELETE CASCADE,
    kinds           text[]     NOT NULL DEFAULT ARRAY[]::text[],
    partitions      text[]     NOT NULL DEFAULT ARRAY[]::text[],
    active_pool_id  bigint,
    cursor          bigint     NOT NULL DEFAULT 0,
    last_seen_at    timestamptz,
    owner_schema    name       NOT NULL DEFAULT current_schema(),
    created_at      timestamptz NOT NULL DEFAULT now(),
    retired_at      timestamptz
);
CREATE INDEX malu$event_subscription_owner_idx
    ON malu$event_subscription(owner_schema, account_id) WHERE retired_at IS NULL;

-- ---------------------------------------------------------------------
-- malu$event_delivery — one row per (subscription, event) delivery.
-- ---------------------------------------------------------------------
CREATE TABLE malu$event_delivery (
    delivery_id     bigserial PRIMARY KEY,
    subscription_id bigint     NOT NULL REFERENCES malu$event_subscription(subscription_id) ON DELETE CASCADE,
    event_id        bigint     NOT NULL REFERENCES malu$event(event_id) ON DELETE CASCADE,
    delivered_at    timestamptz NOT NULL DEFAULT now(),
    status          text       NOT NULL DEFAULT 'delivered' CHECK (status IN ('delivered','acked','failed')),
    UNIQUE (subscription_id, event_id)
);
CREATE INDEX malu$event_delivery_sub_idx ON malu$event_delivery(subscription_id, delivered_at DESC);

-- ---------------------------------------------------------------------
-- RLS — owner_schema-bound across all three tables. Delivery rows
-- inherit from their parent subscription.
-- ---------------------------------------------------------------------
ALTER TABLE malu$event ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_owner ON malu$event
    USING      (owner_schema = current_schema())
    WITH CHECK (owner_schema = current_schema());

ALTER TABLE malu$event_subscription ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_owner ON malu$event_subscription
    USING      (owner_schema = current_schema())
    WITH CHECK (owner_schema = current_schema());

ALTER TABLE malu$event_delivery ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_via_subscription ON malu$event_delivery
    USING (
        EXISTS (
            SELECT 1 FROM malu$event_subscription s
            WHERE s.subscription_id = malu$event_delivery.subscription_id
              AND s.owner_schema    = current_schema()
        )
    )
    WITH CHECK (
        EXISTS (
            SELECT 1 FROM malu$event_subscription s
            WHERE s.subscription_id = malu$event_delivery.subscription_id
              AND s.owner_schema    = current_schema()
        )
    );

GRANT SELECT, INSERT, UPDATE, DELETE ON malu$event, malu$event_subscription, malu$event_delivery TO maludb_memory_admin;
GRANT SELECT, INSERT, UPDATE         ON malu$event, malu$event_subscription, malu$event_delivery TO maludb_memory_executor;
GRANT SELECT                          ON malu$event, malu$event_subscription, malu$event_delivery TO maludb_memory_auditor;

GRANT USAGE, SELECT ON SEQUENCE malu$event_event_id_seq                       TO maludb_memory_admin, maludb_memory_executor;
GRANT USAGE, SELECT ON SEQUENCE malu$event_subscription_subscription_id_seq   TO maludb_memory_admin, maludb_memory_executor;
GRANT USAGE, SELECT ON SEQUENCE malu$event_delivery_delivery_id_seq           TO maludb_memory_admin, maludb_memory_executor;

-- =====================================================================
-- emit_event — append a row to malu$event and NOTIFY the realtime
-- channel. Returns the new event_id (= cursor position).
-- =====================================================================
CREATE FUNCTION emit_event(
    p_event_kind     text,
    p_payload        jsonb       DEFAULT '{}'::jsonb,
    p_account_id     bigint      DEFAULT NULL,
    p_partition      text        DEFAULT NULL,
    p_active_pool_id bigint      DEFAULT NULL,
    p_object_type    text        DEFAULT NULL,
    p_object_id      bigint      DEFAULT NULL,
    p_scope          jsonb       DEFAULT NULL
) RETURNS bigint
    LANGUAGE plpgsql VOLATILE
    AS $body$
#variable_conflict use_column
DECLARE v_id bigint;
BEGIN
    INSERT INTO malu$event
        (event_kind, account_id, partition, active_pool_id,
         object_type, object_id, scope, payload)
    VALUES
        (p_event_kind, p_account_id, p_partition, p_active_pool_id,
         p_object_type, p_object_id, p_scope, p_payload)
    RETURNING event_id INTO v_id;

    -- NOTIFY payload is the event_id as text. Subscribers LISTEN on
    -- 'maludb_event' and wake to fetch new rows past their cursor.
    PERFORM pg_notify('maludb_event', v_id::text);
    RETURN v_id;
END;
$body$;
REVOKE EXECUTE ON FUNCTION emit_event(text, jsonb, bigint, text, bigint, text, bigint, jsonb) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION emit_event(text, jsonb, bigint, text, bigint, text, bigint, jsonb) TO
    maludb_memory_admin, maludb_memory_executor;

-- event_subscribe — UPSERT a subscription by name (per tenant).
CREATE FUNCTION event_subscribe(
    p_name           text,
    p_account_id     bigint  DEFAULT NULL,
    p_kinds          text[]  DEFAULT ARRAY[]::text[],
    p_partitions     text[]  DEFAULT ARRAY[]::text[],
    p_active_pool_id bigint  DEFAULT NULL,
    p_start_cursor   bigint  DEFAULT 0
) RETURNS bigint
    LANGUAGE plpgsql VOLATILE
    AS $body$
#variable_conflict use_column
DECLARE v_id bigint;
BEGIN
    INSERT INTO malu$event_subscription
        (name, account_id, kinds, partitions, active_pool_id, cursor)
    VALUES
        (p_name, p_account_id, p_kinds, p_partitions, p_active_pool_id, p_start_cursor)
    RETURNING subscription_id INTO v_id;
    RETURN v_id;
END;
$body$;
REVOKE EXECUTE ON FUNCTION event_subscribe(text, bigint, text[], text[], bigint, bigint) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION event_subscribe(text, bigint, text[], text[], bigint, bigint) TO
    maludb_memory_admin, maludb_memory_executor;

-- event_fetch_batch — return up to p_limit events past the cursor
-- matching the subscription's filter. Does NOT advance the cursor;
-- callers ack via event_ack(subscription_id, last_event_id) after
-- successful delivery. This makes at-least-once delivery the
-- default semantics.
CREATE FUNCTION event_fetch_batch(
    p_subscription_id bigint,
    p_limit           integer DEFAULT 100
) RETURNS TABLE (
    event_id          bigint,
    event_kind        text,
    account_id        bigint,
    partition         text,
    active_pool_id    bigint,
    object_type       text,
    object_id         bigint,
    scope             jsonb,
    transaction_time  timestamptz,
    payload           jsonb
) LANGUAGE plpgsql STABLE
    AS $body$
#variable_conflict use_column
DECLARE v_sub malu$event_subscription%ROWTYPE;
BEGIN
    SELECT * INTO v_sub FROM malu$event_subscription WHERE subscription_id = p_subscription_id;
    IF v_sub.subscription_id IS NULL THEN
        RAISE EXCEPTION 'event_fetch_batch: subscription % not found', p_subscription_id
            USING ERRCODE = 'no_data_found';
    END IF;

    RETURN QUERY
    SELECT e.event_id, e.event_kind, e.account_id, e.partition,
           e.active_pool_id, e.object_type, e.object_id, e.scope,
           e.transaction_time, e.payload
      FROM malu$event e
     WHERE e.event_id > v_sub.cursor
       AND (cardinality(v_sub.kinds)      = 0 OR e.event_kind = ANY(v_sub.kinds))
       AND (cardinality(v_sub.partitions) = 0 OR e.partition  = ANY(v_sub.partitions))
       AND (v_sub.active_pool_id IS NULL OR e.active_pool_id  = v_sub.active_pool_id)
       AND (v_sub.account_id     IS NULL OR e.account_id      = v_sub.account_id OR e.account_id IS NULL)
     ORDER BY e.event_id
     LIMIT GREATEST(p_limit, 1);
END;
$body$;
REVOKE EXECUTE ON FUNCTION event_fetch_batch(bigint, integer) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION event_fetch_batch(bigint, integer) TO
    maludb_memory_admin, maludb_memory_executor;

-- event_ack — advance the subscription's cursor and record delivery
-- rows for every event between the old and new cursors.
CREATE FUNCTION event_ack(p_subscription_id bigint, p_through_event_id bigint)
    RETURNS integer
    LANGUAGE plpgsql VOLATILE
    AS $body$
#variable_conflict use_column
DECLARE
    v_old_cursor bigint;
    v_n          integer;
BEGIN
    SELECT cursor INTO v_old_cursor
      FROM malu$event_subscription
     WHERE subscription_id = p_subscription_id
     FOR UPDATE;
    IF v_old_cursor IS NULL THEN
        RAISE EXCEPTION 'event_ack: subscription % not found', p_subscription_id
            USING ERRCODE = 'no_data_found';
    END IF;
    IF p_through_event_id <= v_old_cursor THEN
        RETURN 0;
    END IF;

    WITH ins AS (
        INSERT INTO malu$event_delivery(subscription_id, event_id, status)
        SELECT p_subscription_id, e.event_id, 'acked'
          FROM malu$event e
         WHERE e.event_id > v_old_cursor
           AND e.event_id <= p_through_event_id
        ON CONFLICT (subscription_id, event_id) DO UPDATE
            SET delivered_at = now(),
                status       = 'acked'
        RETURNING 1
    )
    SELECT count(*)::integer INTO v_n FROM ins;

    UPDATE malu$event_subscription
       SET cursor       = p_through_event_id,
           last_seen_at = now()
     WHERE subscription_id = p_subscription_id;

    RETURN v_n;
END;
$body$;
REVOKE EXECUTE ON FUNCTION event_ack(bigint, bigint) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION event_ack(bigint, bigint) TO
    maludb_memory_admin, maludb_memory_executor;

-- event_list_subscriptions — enumeration for the CLI / metrics.
CREATE FUNCTION event_list_subscriptions(p_include_retired boolean DEFAULT false)
    RETURNS TABLE (
        subscription_id bigint,
        name            text,
        account_id      bigint,
        kinds           text[],
        partitions      text[],
        active_pool_id  bigint,
        cursor          bigint,
        last_seen_at    timestamptz,
        retired_at      timestamptz
    ) LANGUAGE plpgsql STABLE
    AS $body$
#variable_conflict use_column
BEGIN
    RETURN QUERY
    SELECT s.subscription_id, s.name, s.account_id, s.kinds, s.partitions,
           s.active_pool_id, s.cursor, s.last_seen_at, s.retired_at
      FROM malu$event_subscription s
     WHERE (p_include_retired OR s.retired_at IS NULL)
     ORDER BY s.subscription_id;
END;
$body$;
REVOKE EXECUTE ON FUNCTION event_list_subscriptions(boolean) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION event_list_subscriptions(boolean) TO
    maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;

-- =====================================================================
-- V3-REALTIME-01b — retrofit the V3-shipped write paths to emit
-- events alongside their existing audit_event call. Stage 2-7
-- register_* functions remain untouched (Stage 13 follow-up).
-- =====================================================================

CREATE OR REPLACE FUNCTION auth_token_create(
    p_account_id    bigint,
    p_kind          text,
    p_label         text             DEFAULT NULL,
    p_scopes        text[]           DEFAULT ARRAY[]::text[],
    p_allowed_cidrs inet[]           DEFAULT NULL,
    p_expires_at    timestamptz      DEFAULT NULL
) RETURNS TABLE (token_id bigint, plaintext_token text)
    LANGUAGE plpgsql VOLATILE
    SECURITY DEFINER
    SET search_path = pg_catalog, maludb_core
    AS $body$
DECLARE
    v_caller bigint := current_account_id();
    v_random bytea;
    v_plain  text;
    v_hash   bytea;
    v_id     bigint;
BEGIN
    IF v_caller IS NOT NULL AND v_caller <> p_account_id THEN
        RAISE EXCEPTION 'auth_token_create: caller account % cannot issue tokens for account %',
            v_caller, p_account_id
            USING ERRCODE = 'insufficient_privilege';
    END IF;
    IF p_kind NOT IN ('personal','service') THEN
        RAISE EXCEPTION 'auth_token_create: token_kind must be personal or service'
            USING ERRCODE = 'check_violation';
    END IF;

    v_random := public.gen_random_bytes(32);
    v_plain  := __auth_token_encode(v_random);
    v_hash   := __auth_token_hash(v_plain);

    INSERT INTO malu$auth_token
        (account_id, token_hash, token_kind, label, scopes,
         allowed_cidrs, expires_at)
    VALUES
        (p_account_id, v_hash, p_kind, p_label, p_scopes,
         p_allowed_cidrs, p_expires_at)
    RETURNING malu$auth_token.token_id INTO v_id;

    PERFORM audit_event(
        'auth_token_create',
        'malu$auth_token',
        v_id,
        jsonb_build_object(
            'account_id', p_account_id,
            'token_kind', p_kind,
            'label',      p_label,
            'expires_at', p_expires_at,
            'scopes',     to_jsonb(p_scopes),
            'has_cidr',   p_allowed_cidrs IS NOT NULL),
        NULL);

    PERFORM emit_event(
        'auth_token_create',
        jsonb_build_object('token_id', v_id, 'token_kind', p_kind, 'label', p_label),
        p_account_id, NULL, NULL, 'malu$auth_token', v_id, NULL);

    token_id         := v_id;
    plaintext_token  := v_plain;
    RETURN NEXT;
END;
$body$;

CREATE OR REPLACE FUNCTION queue_enqueue(
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

    PERFORM emit_event(
        'queue_enqueue',
        jsonb_build_object('queue', p_queue_name, 'job_id', v_id, 'priority', p_priority),
        p_account_id, NULL, NULL, 'malu$queue_job', v_id, NULL);

    RETURN v_id;
END;
$body$;

CREATE OR REPLACE FUNCTION source_object_register(
    p_adapter_name    text,
    p_adapter_uri     text,
    p_content_hash    bytea,
    p_byte_length     bigint,
    p_media_type      text          DEFAULT NULL,
    p_source_time     timestamptz   DEFAULT NULL,
    p_retention_class text          DEFAULT 'standard',
    p_sensitivity     text          DEFAULT 'internal',
    p_partition       text          DEFAULT NULL
) RETURNS bigint
    LANGUAGE plpgsql VOLATILE
    AS $body$
#variable_conflict use_column
DECLARE
    v_adapter_id bigint;
    v_existing   bigint;
    v_id         bigint;
BEGIN
    IF octet_length(p_content_hash) <> 32 THEN
        RAISE EXCEPTION 'source_object_register: content_hash must be 32 bytes (raw SHA-256)'
            USING ERRCODE = 'check_violation';
    END IF;

    SELECT adapter_id INTO v_adapter_id
      FROM malu$storage_adapter
     WHERE name = p_adapter_name AND retired_at IS NULL;
    IF v_adapter_id IS NULL THEN
        RAISE EXCEPTION 'source_object_register: adapter % not found or retired', p_adapter_name
            USING ERRCODE = 'no_data_found';
    END IF;

    SELECT object_id INTO v_existing
      FROM malu$source_object
     WHERE content_hash = p_content_hash
       AND retired_at IS NULL;
    IF v_existing IS NOT NULL THEN
        RETURN v_existing;
    END IF;

    INSERT INTO malu$source_object
        (content_hash, byte_length, media_type, source_time,
         retention_class, sensitivity, partition,
         adapter_id, adapter_uri)
    VALUES
        (p_content_hash, p_byte_length, p_media_type, p_source_time,
         p_retention_class, p_sensitivity, p_partition,
         v_adapter_id, p_adapter_uri)
    RETURNING object_id INTO v_id;

    PERFORM audit_event('source_object_register', 'malu$source_object', v_id,
        jsonb_build_object(
            'adapter',         p_adapter_name,
            'adapter_uri',     p_adapter_uri,
            'content_hash',    encode(p_content_hash, 'hex'),
            'byte_length',     p_byte_length,
            'media_type',      p_media_type,
            'retention_class', p_retention_class,
            'sensitivity',     p_sensitivity,
            'partition',       p_partition),
        NULL);

    PERFORM emit_event(
        'source_object_register',
        jsonb_build_object('adapter', p_adapter_name, 'object_id', v_id,
                           'content_hash', encode(p_content_hash, 'hex'),
                           'byte_length', p_byte_length),
        NULL, p_partition, NULL, 'malu$source_object', v_id, NULL);

    RETURN v_id;
END;
$body$;
