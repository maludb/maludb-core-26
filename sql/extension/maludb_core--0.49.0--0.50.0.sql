\echo Use "ALTER EXTENSION maludb_core UPDATE TO '0.50.0'" to load this file. \quit

-- =====================================================================
-- maludb_core 0.49.0 → 0.50.0
--
-- Stage 13 / V3-PRESENCE-01: active memory pool presence.
--
-- Tracks human / agent / tool participants attached to a malu$active_memory_pool.
-- Presence transitions emit V3-REALTIME-01 events so subscribed
-- clients see joins / updates / leaves in real time.
--
-- Apply with:
--   ALTER EXTENSION maludb_core UPDATE TO '0.50.0';
-- =====================================================================

CREATE OR REPLACE FUNCTION maludb_core_version() RETURNS text
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$ SELECT '0.50.0'::text $body$;

-- ---------------------------------------------------------------------
-- malu$pool_presence — one row per (pool, participant). UPSERT on
-- (pool_id, participant_kind, participant_ref).
-- ---------------------------------------------------------------------
CREATE TABLE malu$pool_presence (
    presence_id      bigserial PRIMARY KEY,
    pool_id          bigint    NOT NULL REFERENCES malu$active_memory_pool(pool_id) ON DELETE CASCADE,
    participant_kind text      NOT NULL CHECK (participant_kind IN ('human','agent','tool')),
    participant_ref  text      NOT NULL,
    role             text,
    declared_task    text,
    cursor_jsonb     jsonb,
    last_seen_at     timestamptz NOT NULL DEFAULT now(),
    left_at          timestamptz,
    owner_schema     name      NOT NULL DEFAULT current_schema(),
    UNIQUE (pool_id, participant_kind, participant_ref)
);
CREATE INDEX malu$pool_presence_pool_idx
    ON malu$pool_presence(pool_id, last_seen_at DESC) WHERE left_at IS NULL;

-- ---------------------------------------------------------------------
-- malu$pool_presence_event — append-only log of join / update / leave.
-- ---------------------------------------------------------------------
CREATE TABLE malu$pool_presence_event (
    event_id     bigserial PRIMARY KEY,
    presence_id  bigint    NOT NULL REFERENCES malu$pool_presence(presence_id) ON DELETE CASCADE,
    kind         text      NOT NULL CHECK (kind IN ('join','update','leave')),
    event_time   timestamptz NOT NULL DEFAULT now(),
    detail_jsonb jsonb
);
CREATE INDEX malu$pool_presence_event_presence_idx
    ON malu$pool_presence_event(presence_id, event_time DESC);

-- ---------------------------------------------------------------------
-- RLS — owner_schema-bound. Presence-event rows inherit from parent.
-- ---------------------------------------------------------------------
ALTER TABLE malu$pool_presence ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_owner ON malu$pool_presence
    USING      (owner_schema = current_schema())
    WITH CHECK (owner_schema = current_schema());

ALTER TABLE malu$pool_presence_event ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_via_presence ON malu$pool_presence_event
    USING (
        EXISTS (
            SELECT 1 FROM malu$pool_presence p
            WHERE p.presence_id  = malu$pool_presence_event.presence_id
              AND p.owner_schema = current_schema()
        )
    )
    WITH CHECK (
        EXISTS (
            SELECT 1 FROM malu$pool_presence p
            WHERE p.presence_id  = malu$pool_presence_event.presence_id
              AND p.owner_schema = current_schema()
        )
    );

GRANT SELECT, INSERT, UPDATE, DELETE ON malu$pool_presence, malu$pool_presence_event TO maludb_memory_admin;
GRANT SELECT, INSERT, UPDATE         ON malu$pool_presence, malu$pool_presence_event TO maludb_memory_executor;
GRANT SELECT                          ON malu$pool_presence, malu$pool_presence_event TO maludb_memory_auditor;

GRANT USAGE, SELECT ON SEQUENCE malu$pool_presence_presence_id_seq      TO maludb_memory_admin, maludb_memory_executor;
GRANT USAGE, SELECT ON SEQUENCE malu$pool_presence_event_event_id_seq   TO maludb_memory_admin, maludb_memory_executor;

-- =====================================================================
-- Public API
-- =====================================================================

CREATE FUNCTION presence_update(
    p_pool_id          bigint,
    p_participant_kind text,
    p_participant_ref  text,
    p_role             text DEFAULT NULL,
    p_declared_task    text DEFAULT NULL,
    p_cursor_jsonb     jsonb DEFAULT NULL
) RETURNS bigint
    LANGUAGE plpgsql VOLATILE
    AS $body$
#variable_conflict use_column
DECLARE
    v_pid    bigint;
    v_kind   text;
    v_was    boolean;
BEGIN
    -- Verify the pool exists and the caller is allowed to see it
    -- (RLS would have hidden it otherwise; this gives a cleaner error).
    PERFORM 1 FROM malu$active_memory_pool WHERE pool_id = p_pool_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'presence_update: pool % not found or not visible to caller', p_pool_id
            USING ERRCODE = 'no_data_found';
    END IF;

    SELECT presence_id, (left_at IS NULL) INTO v_pid, v_was
      FROM malu$pool_presence
     WHERE pool_id          = p_pool_id
       AND participant_kind = p_participant_kind
       AND participant_ref  = p_participant_ref;

    IF v_pid IS NULL THEN
        INSERT INTO malu$pool_presence
            (pool_id, participant_kind, participant_ref, role, declared_task, cursor_jsonb)
        VALUES
            (p_pool_id, p_participant_kind, p_participant_ref, p_role, p_declared_task, p_cursor_jsonb)
        RETURNING presence_id INTO v_pid;
        v_kind := 'join';
    ELSE
        UPDATE malu$pool_presence
           SET role          = COALESCE(p_role,          role),
               declared_task = COALESCE(p_declared_task, declared_task),
               cursor_jsonb  = COALESCE(p_cursor_jsonb,  cursor_jsonb),
               last_seen_at  = now(),
               left_at       = NULL
         WHERE presence_id = v_pid;
        v_kind := CASE WHEN v_was THEN 'update' ELSE 'join' END;
    END IF;

    INSERT INTO malu$pool_presence_event(presence_id, kind, detail_jsonb)
    VALUES (v_pid, v_kind,
            jsonb_build_object('role', p_role, 'declared_task', p_declared_task,
                               'cursor', p_cursor_jsonb));

    PERFORM emit_event(
        'pool_presence_' || v_kind,
        jsonb_build_object('presence_id', v_pid,
                           'pool_id', p_pool_id,
                           'participant_kind', p_participant_kind,
                           'participant_ref',  p_participant_ref,
                           'role',             p_role,
                           'declared_task',    p_declared_task),
        NULL, NULL, p_pool_id, 'malu$pool_presence', v_pid, NULL);

    PERFORM audit_event('pool_presence_' || v_kind, 'malu$pool_presence', v_pid,
        jsonb_build_object('pool_id', p_pool_id,
                           'participant_kind', p_participant_kind,
                           'participant_ref', p_participant_ref),
        NULL);

    RETURN v_pid;
END;
$body$;
REVOKE EXECUTE ON FUNCTION presence_update(bigint, text, text, text, text, jsonb) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION presence_update(bigint, text, text, text, text, jsonb) TO
    maludb_memory_admin, maludb_memory_executor;

CREATE FUNCTION presence_leave(
    p_pool_id          bigint,
    p_participant_kind text,
    p_participant_ref  text,
    p_reason           text DEFAULT NULL
) RETURNS boolean
    LANGUAGE plpgsql VOLATILE
    AS $body$
#variable_conflict use_column
DECLARE
    v_pid bigint;
    v_was boolean;
BEGIN
    SELECT presence_id, (left_at IS NULL) INTO v_pid, v_was
      FROM malu$pool_presence
     WHERE pool_id          = p_pool_id
       AND participant_kind = p_participant_kind
       AND participant_ref  = p_participant_ref;
    IF v_pid IS NULL OR NOT v_was THEN
        RETURN false;
    END IF;
    UPDATE malu$pool_presence SET left_at = now() WHERE presence_id = v_pid;

    INSERT INTO malu$pool_presence_event(presence_id, kind, detail_jsonb)
    VALUES (v_pid, 'leave', jsonb_build_object('reason', p_reason));

    PERFORM emit_event(
        'pool_presence_leave',
        jsonb_build_object('presence_id', v_pid, 'pool_id', p_pool_id,
                           'participant_kind', p_participant_kind,
                           'participant_ref',  p_participant_ref,
                           'reason', p_reason),
        NULL, NULL, p_pool_id, 'malu$pool_presence', v_pid, NULL);

    PERFORM audit_event('pool_presence_leave', 'malu$pool_presence', v_pid,
        jsonb_build_object('pool_id', p_pool_id, 'reason', p_reason), NULL);
    RETURN true;
END;
$body$;
REVOKE EXECUTE ON FUNCTION presence_leave(bigint, text, text, text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION presence_leave(bigint, text, text, text) TO
    maludb_memory_admin, maludb_memory_executor;

CREATE FUNCTION presence_list(p_pool_id bigint, p_include_left boolean DEFAULT false)
    RETURNS TABLE (
        presence_id      bigint,
        participant_kind text,
        participant_ref  text,
        role             text,
        declared_task    text,
        last_seen_at     timestamptz,
        left_at          timestamptz
    ) LANGUAGE plpgsql STABLE
    AS $body$
#variable_conflict use_column
BEGIN
    RETURN QUERY
    SELECT p.presence_id, p.participant_kind, p.participant_ref, p.role,
           p.declared_task, p.last_seen_at, p.left_at
      FROM malu$pool_presence p
     WHERE p.pool_id = p_pool_id
       AND (p_include_left OR p.left_at IS NULL)
     ORDER BY p.last_seen_at DESC;
END;
$body$;
REVOKE EXECUTE ON FUNCTION presence_list(bigint, boolean) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION presence_list(bigint, boolean) TO
    maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;
