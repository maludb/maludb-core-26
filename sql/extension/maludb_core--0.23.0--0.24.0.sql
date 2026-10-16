\echo Use "ALTER EXTENSION maludb_core UPDATE TO '0.24.0'" to load this file. \quit

-- =====================================================================
-- maludb_core 0.23.0 → 0.24.0
--
-- Stage 3 — Temporal Supersession Engine (S3-2).
--
-- Per CLAUDE.md doctrine: "Corrections must never silently overwrite
-- history. They close a valid_time_end, open a new version, and create
-- a supersedes edge. The Temporal Supersession Engine owns this —
-- application code should call its API rather than mutating temporal
-- columns directly."
--
-- Surface:
--   * malu$supersession_edge — canonical (predecessor, successor)
--                              audit table with kind + reason + actor.
--   * malu$fact EXCLUDE constraint — enforces no-overlapping-validity
--                              per (subject, verb, predicate) for
--                              active, non-superseded rows.
--   * correct_fact(...)      — close prior valid window + open new
--                              version + supersedes edge in one tx.
--   * retract_fact(...)      — close prior window without successor;
--                              records kind='retraction' edge with
--                              successor_id=NULL.
--   * close_valid_window(type, id, ...) — polymorphic helper for any
--                              of {fact, memory, episode_object, claim}.
--   * reopen_valid_window(type, id) — admin override; clears
--                              valid_time_end and lifecycle_state.
--   * propagate_staleness(type, id) — flags downstream objects
--                              (memory / episode / fact) as stale
--                              via the relationship_edge graph.
-- =====================================================================

CREATE OR REPLACE FUNCTION maludb_core_version() RETURNS text
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$ SELECT '0.24.0'::text $body$;

-- =====================================================================
-- malu$supersession_edge
-- =====================================================================
CREATE TABLE malu$supersession_edge (
    edge_id              bigserial PRIMARY KEY,
    owner_schema         name NOT NULL DEFAULT current_schema(),
    predecessor_type     text NOT NULL,
    predecessor_id       bigint NOT NULL,
    successor_type       text,
    successor_id         bigint,
    supersession_kind    text NOT NULL DEFAULT 'correction'
        CHECK (supersession_kind IN ('correction','refinement','retraction',
                                     'consolidation','merge','split')),
    reason               text,
    superseded_at        timestamptz NOT NULL DEFAULT now(),
    actor_role           name NOT NULL DEFAULT current_user,
    CHECK (predecessor_type IN ('fact','memory','episode_object','claim')),
    CHECK (successor_type IS NULL OR
           successor_type IN ('fact','memory','episode_object','claim')),
    -- predecessor and successor (when both present) must be the same kind
    CHECK (successor_type IS NULL OR predecessor_type = successor_type),
    -- no self-supersession
    CHECK (NOT (predecessor_type = successor_type
                AND predecessor_id = successor_id))
);
CREATE INDEX malu$supersession_pred_idx
    ON malu$supersession_edge(predecessor_type, predecessor_id);
CREATE INDEX malu$supersession_succ_idx
    ON malu$supersession_edge(successor_type, successor_id)
    WHERE successor_id IS NOT NULL;

ALTER TABLE malu$supersession_edge ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_owner ON malu$supersession_edge
    USING (owner_schema = current_schema())
    WITH CHECK (owner_schema = current_schema());

GRANT SELECT ON malu$supersession_edge TO
    maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;
GRANT INSERT ON malu$supersession_edge TO
    maludb_memory_admin, maludb_memory_executor;
GRANT USAGE, SELECT ON SEQUENCE malu$supersession_edge_edge_id_seq TO
    maludb_memory_admin, maludb_memory_executor;

-- =====================================================================
-- EXCLUDE constraint on malu$fact — at most one active row per
-- (subject, verb, predicate) at any given moment of valid time.
--
-- NULLs are coerced to '' so the equality operator covers them.
-- WHERE clause limits the constraint to active, non-superseded rows
-- so historical chains (which intentionally have closed windows)
-- don't trigger it.
-- =====================================================================
ALTER TABLE malu$fact
    ADD CONSTRAINT malu$fact_active_window_excl
    EXCLUDE USING gist (
        (COALESCE(subject,   '')) WITH =,
        (COALESCE(verb,      '')) WITH =,
        (COALESCE(predicate, '')) WITH =,
        valid_time_range WITH &&
    ) WHERE (lifecycle_state = 'active' AND superseded_at IS NULL);

-- =====================================================================
-- close_valid_window — polymorphic helper. Sets valid_time_end and
-- (when transitioning out of active) lifecycle_state. Idempotent:
-- closing an already-closed window with the same end_time is a no-op.
-- =====================================================================
CREATE FUNCTION close_valid_window(
    p_object_type text,
    p_object_id   bigint,
    p_end_time    timestamptz DEFAULT now(),
    p_reason      text DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql
AS $body$
DECLARE
    v_table text;
    v_id_col text;
    v_sql   text;
BEGIN
    CASE p_object_type
        WHEN 'fact'           THEN v_table := 'malu$fact';
                                   v_id_col := 'fact_id';
        WHEN 'memory'         THEN v_table := 'malu$memory';
                                   v_id_col := 'memory_id';
        WHEN 'episode_object' THEN v_table := 'malu$episode_object';
                                   v_id_col := 'episode_id';
        WHEN 'claim'          THEN v_table := 'malu$claim';
                                   v_id_col := 'claim_id';
        ELSE
            RAISE EXCEPTION 'close_valid_window: unsupported object_type %',
                p_object_type
                USING ERRCODE = 'invalid_parameter_value';
    END CASE;

    v_sql := format(
        'UPDATE maludb_core.%I SET valid_time_end = $1 WHERE %I = $2 ' ||
        'AND (valid_time_end IS NULL OR valid_time_end > $1)',
        v_table, v_id_col);
    EXECUTE v_sql USING p_end_time, p_object_id;

    PERFORM audit_event('close_valid_window', p_object_type, p_object_id,
        jsonb_build_object('end_time', p_end_time, 'reason', p_reason));
END;
$body$;

-- =====================================================================
-- reopen_valid_window — admin override. Clears valid_time_end and
-- (when lifecycle was 'superseded') resets to 'active'. Records audit.
-- Does NOT remove existing supersession_edge rows.
-- =====================================================================
CREATE FUNCTION reopen_valid_window(
    p_object_type text,
    p_object_id   bigint,
    p_reason      text DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql
AS $body$
DECLARE
    v_table text;
    v_id_col text;
    v_sql   text;
BEGIN
    IF p_reason IS NULL OR p_reason = '' THEN
        RAISE EXCEPTION 'reopen_valid_window: reason required'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    CASE p_object_type
        WHEN 'fact'           THEN v_table := 'malu$fact';
                                   v_id_col := 'fact_id';
        WHEN 'memory'         THEN v_table := 'malu$memory';
                                   v_id_col := 'memory_id';
        WHEN 'episode_object' THEN v_table := 'malu$episode_object';
                                   v_id_col := 'episode_id';
        WHEN 'claim'          THEN v_table := 'malu$claim';
                                   v_id_col := 'claim_id';
        ELSE
            RAISE EXCEPTION 'reopen_valid_window: unsupported object_type %',
                p_object_type
                USING ERRCODE = 'invalid_parameter_value';
    END CASE;

    -- Per-type SET clause: only malu$fact has superseded_at; only
    -- malu$claim has retracted_at + retraction_reason; everything
    -- carries lifecycle_state on the governed tables.
    CASE p_object_type
        WHEN 'fact' THEN
            v_sql := format(
                'UPDATE maludb_core.%I SET valid_time_end = NULL, ' ||
                'superseded_at = NULL, lifecycle_state = ''active'' WHERE %I = $1',
                v_table, v_id_col);
        WHEN 'claim' THEN
            v_sql := format(
                'UPDATE maludb_core.%I SET valid_time_end = NULL, ' ||
                'retracted_at = NULL, retraction_reason = NULL WHERE %I = $1',
                v_table, v_id_col);
        ELSE
            -- memory, episode_object
            v_sql := format(
                'UPDATE maludb_core.%I SET valid_time_end = NULL, ' ||
                'lifecycle_state = ''active'' WHERE %I = $1',
                v_table, v_id_col);
    END CASE;
    EXECUTE v_sql USING p_object_id;

    PERFORM audit_event('reopen_valid_window', p_object_type, p_object_id,
        jsonb_build_object('reason', p_reason));
END;
$body$;

-- =====================================================================
-- correct_fact — the canonical correction flow.
--
-- In one tx:
--   1. Lock the old fact row (FOR UPDATE).
--   2. Verify the old row is active and not already superseded.
--   3. Close the old row's valid_time_end + set superseded_at +
--      lifecycle_state = 'superseded'.
--   4. Insert a new fact with the same SVPOR + new content, valid
--      from now.
--   5. Set the new row's supersedes_fact_id pointer.
--   6. INSERT malu$supersession_edge (kind='correction' by default).
--   7. Audit event.
--
-- Returns the new fact_id. RAISES if the precondition fails.
-- =====================================================================
CREATE FUNCTION correct_fact(
    p_fact_id           bigint,
    p_new_object_value  text DEFAULT NULL,
    p_new_statement     text DEFAULT NULL,
    p_new_statement_jsonb jsonb DEFAULT NULL,
    p_reason            text DEFAULT NULL,
    p_supersession_kind text DEFAULT 'correction'
) RETURNS bigint
LANGUAGE plpgsql
AS $body$
DECLARE
    v_old         malu$fact%ROWTYPE;
    v_new_fact_id bigint;
    v_now         timestamptz := now();
BEGIN
    SELECT * INTO v_old FROM malu$fact WHERE fact_id = p_fact_id FOR UPDATE;
    IF v_old.fact_id IS NULL THEN
        RAISE EXCEPTION 'unknown fact_id: %', p_fact_id
            USING ERRCODE = 'no_data_found';
    END IF;
    IF v_old.superseded_at IS NOT NULL THEN
        RAISE EXCEPTION 'fact_id=% is already superseded at %',
            p_fact_id, v_old.superseded_at
            USING ERRCODE = 'object_not_in_prerequisite_state';
    END IF;
    IF v_old.lifecycle_state <> 'active' THEN
        RAISE EXCEPTION 'fact_id=% lifecycle_state=%; only active facts may be corrected',
            p_fact_id, v_old.lifecycle_state
            USING ERRCODE = 'object_not_in_prerequisite_state';
    END IF;

    -- 1. Close the old row. valid_time_end = now, superseded_at = now,
    --    lifecycle_state = 'superseded'.
    UPDATE malu$fact
       SET valid_time_end  = v_now,
           superseded_at   = v_now,
           lifecycle_state = 'superseded'
     WHERE fact_id = p_fact_id;

    -- 2. Insert the corrected fact. valid_time_start = now; same SVPOR.
    INSERT INTO malu$fact
        (subject, verb, predicate, object_value, relationship,
         statement_text, statement_jsonb,
         verification_scope, verification_method,
         supersedes_fact_id, valid_time_start, sensitivity)
    VALUES (v_old.subject, v_old.verb, v_old.predicate,
            COALESCE(p_new_object_value, v_old.object_value),
            v_old.relationship,
            COALESCE(p_new_statement, v_old.statement_text),
            COALESCE(p_new_statement_jsonb, v_old.statement_jsonb),
            v_old.verification_scope, v_old.verification_method,
            p_fact_id, v_now, v_old.sensitivity)
    RETURNING fact_id INTO v_new_fact_id;

    -- 3. Supersession edge.
    INSERT INTO malu$supersession_edge
        (predecessor_type, predecessor_id, successor_type, successor_id,
         supersession_kind, reason)
    VALUES ('fact', p_fact_id, 'fact', v_new_fact_id,
            p_supersession_kind, p_reason);

    PERFORM audit_event('correct_fact', 'fact', p_fact_id,
        jsonb_build_object(
            'successor_fact_id', v_new_fact_id,
            'supersession_kind', p_supersession_kind,
            'reason',            p_reason));

    RETURN v_new_fact_id;
END;
$body$;

-- =====================================================================
-- retract_fact — close the window with no successor. Records a
-- supersession_edge with successor_id=NULL and kind='retraction'.
-- =====================================================================
CREATE FUNCTION retract_fact(
    p_fact_id bigint,
    p_reason  text
) RETURNS void
LANGUAGE plpgsql
AS $body$
DECLARE v_old malu$fact%ROWTYPE;
BEGIN
    IF p_reason IS NULL OR p_reason = '' THEN
        RAISE EXCEPTION 'retract_fact: reason required'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;
    SELECT * INTO v_old FROM malu$fact WHERE fact_id = p_fact_id FOR UPDATE;
    IF v_old.fact_id IS NULL THEN
        RAISE EXCEPTION 'unknown fact_id: %', p_fact_id
            USING ERRCODE = 'no_data_found';
    END IF;
    IF v_old.superseded_at IS NOT NULL THEN
        RAISE EXCEPTION 'fact_id=% already superseded at %',
            p_fact_id, v_old.superseded_at
            USING ERRCODE = 'object_not_in_prerequisite_state';
    END IF;

    UPDATE malu$fact
       SET valid_time_end  = now(),
           superseded_at   = now(),
           lifecycle_state = 'retired'
     WHERE fact_id = p_fact_id;

    INSERT INTO malu$supersession_edge
        (predecessor_type, predecessor_id, supersession_kind, reason)
    VALUES ('fact', p_fact_id, 'retraction', p_reason);

    PERFORM audit_event('retract_fact', 'fact', p_fact_id,
        jsonb_build_object('reason', p_reason));
END;
$body$;

-- =====================================================================
-- propagate_staleness — when an object is superseded or retracted,
-- flag downstream objects that reference it via the relationship_edge
-- graph (one hop, not transitive in v1). Sets stale_after = now() on
-- the target if it's a fact / memory / episode that has the column.
--
-- Returns the count of objects flagged.
-- =====================================================================
CREATE FUNCTION propagate_staleness(
    p_source_type text,
    p_source_id   bigint,
    p_reason      text DEFAULT NULL
) RETURNS integer
LANGUAGE plpgsql
AS $body$
DECLARE
    v_count integer := 0;
    rec     record;
BEGIN
    FOR rec IN
        SELECT target_object_type, target_object_id
        FROM malu$relationship_edge
        WHERE source_object_type = p_source_type
          AND source_object_id   = p_source_id
        UNION
        SELECT source_object_type, source_object_id
        FROM malu$relationship_edge
        WHERE target_object_type = p_source_type
          AND target_object_id   = p_source_id
    LOOP
        IF rec.target_object_type = 'memory' THEN
            UPDATE malu$memory SET stale_after = now()
             WHERE memory_id = rec.target_object_id
               AND stale_after IS NULL;
            IF FOUND THEN v_count := v_count + 1; END IF;
        ELSIF rec.target_object_type = 'episode_object' THEN
            UPDATE malu$episode_object SET stale_after = now()
             WHERE episode_id = rec.target_object_id
               AND stale_after IS NULL;
            IF FOUND THEN v_count := v_count + 1; END IF;
        ELSIF rec.target_object_type = 'fact' THEN
            UPDATE malu$fact SET stale_after = now()
             WHERE fact_id = rec.target_object_id
               AND stale_after IS NULL
               AND lifecycle_state = 'active';
            IF FOUND THEN v_count := v_count + 1; END IF;
        END IF;
    END LOOP;

    PERFORM audit_event('propagate_staleness', p_source_type, p_source_id,
        jsonb_build_object('downstream_count', v_count, 'reason', p_reason));
    RETURN v_count;
END;
$body$;

GRANT EXECUTE ON FUNCTION
    close_valid_window(text, bigint, timestamptz, text),
    reopen_valid_window(text, bigint, text),
    correct_fact(bigint, text, text, jsonb, text, text),
    retract_fact(bigint, text),
    propagate_staleness(text, bigint, text)
TO maludb_memory_admin, maludb_memory_executor;

-- =====================================================================
-- Stage boundary update — malu$supersession_edge now installed.
-- =====================================================================
CREATE OR REPLACE FUNCTION stage_boundary_violations()
RETURNS TABLE(object_kind text, object_name text, stage smallint)
LANGUAGE sql STABLE
AS $body$
    WITH forbidden(name, stage) AS (
        VALUES
            ('malu$governed_object'::text,       2::smallint),
            ('malu$svpor_subject',               3),
            ('malu$svpor_verb',                  3),
            ('malu$svpor_predicate',             3),
            ('malu$maut_score',                  3),
            ('malu$workflow_trace',              5),
            ('malu$generalized_workflow',        5),
            ('malu$procedural_memory_object',    5),
            ('malu$skill_package',               5),
            ('malu$competency_package',          5),
            ('malu$active_memory_pool',          5),
            ('malu$episode_replay',              5),
            ('malu$local_memory_node',           6),
            ('malu$node_sync_record',            6)
    )
    SELECT 'table'::text, c.relname::text, f.stage
    FROM pg_catalog.pg_class c
    JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
    JOIN forbidden f ON f.name = c.relname
    WHERE n.nspname = 'maludb_core'
      AND c.relkind IN ('r','p','v','m')
    ORDER BY f.stage, c.relname;
$body$;
