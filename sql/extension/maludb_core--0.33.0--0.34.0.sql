\echo Use "ALTER EXTENSION maludb_core UPDATE TO '0.34.0'" to load this file. \quit

-- =====================================================================
-- maludb_core 0.33.0 → 0.34.0
--
-- Stage 5 — Skill Runtime as governed state machine (S5-2).
--
-- Per requirements.md §3.9. Skill packages execute as state machines,
-- not free-form prompts. The runtime MUST:
--   1. Bind current account + active pool + task + partitions + source
--      to the execution record.
--   2. Enforce applicability conditions (env/tech_stack/time_window).
--   3. Check preconditions and emit auditable execution records.
--   4. Branch on outcomes via stored transitions.
--   5. Permit emission of new claims tied to the execution.
--
-- v1 scope:
--   - Synchronous in-DB skill execution. step_skill_execution is
--     called by the caller after each step; the caller asserts the
--     outcome (success/failure/exception:<class>) and the runtime
--     resolves the next state via the transition table.
--   - Authority binding uses current_user; account_id linkage to
--     malu$account is optional and recorded if supplied.
--   - Active memory pool linkage uses a free bigint column; the
--     malu$active_memory_pool table lands in S5-3 and the column will
--     gain a FK then.
--   - "load only authorized memories and workflows" relies on existing
--     RLS — the runtime does not bypass it.
--
-- Surface:
--   malu$skill_package, malu$skill_state, malu$skill_transition
--   malu$skill_execution_record, malu$skill_execution_step
--   register_skill, add_skill_state, add_skill_transition
--   begin_skill_execution, step_skill_execution
--   abort_skill_execution, skill_emit_claim
-- =====================================================================

CREATE OR REPLACE FUNCTION maludb_core_version() RETURNS text
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$ SELECT '0.34.0'::text $body$;

-- =====================================================================
-- malu$skill_package
-- =====================================================================
CREATE TABLE malu$skill_package (
    skill_id              bigserial PRIMARY KEY,
    owner_schema          name NOT NULL DEFAULT current_schema(),
    skill_name            text NOT NULL,
    version               text NOT NULL DEFAULT '1.0.0',
    description           text,
    packaging_kind        text NOT NULL DEFAULT 'markdown'
        CHECK (packaging_kind IN ('system_prompt','markdown','mcp_tool','plugin')),
    applicability_jsonb   jsonb NOT NULL DEFAULT '{}'::jsonb,
    precondition_jsonb    jsonb NOT NULL DEFAULT '[]'::jsonb,
    enabled               boolean NOT NULL DEFAULT true,
    created_at            timestamptz NOT NULL DEFAULT now(),
    updated_at            timestamptz NOT NULL DEFAULT now(),
    UNIQUE (owner_schema, skill_name, version)
);
CREATE INDEX malu$skill_package_owner_idx ON malu$skill_package(owner_schema);

ALTER TABLE malu$skill_package ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_owner ON malu$skill_package
    USING (owner_schema = current_schema())
    WITH CHECK (owner_schema = current_schema());

GRANT SELECT ON malu$skill_package TO
    maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;
GRANT INSERT, UPDATE, DELETE ON malu$skill_package TO
    maludb_memory_admin, maludb_memory_executor;
GRANT USAGE, SELECT ON SEQUENCE malu$skill_package_skill_id_seq TO
    maludb_memory_admin, maludb_memory_executor;

-- =====================================================================
-- malu$skill_state — nodes of the state machine.
--
-- state_kind:
--   start              — entry. Exactly one per skill.
--   step               — executable/presentable action.
--   validation         — invariant check; outcome chooses transition.
--   exception_handler  — recovery state reachable from exception outcomes.
--   terminal           — leaf. final_outcome stored on execution record.
-- =====================================================================
CREATE TABLE malu$skill_state (
    state_id        bigserial PRIMARY KEY,
    owner_schema    name NOT NULL DEFAULT current_schema(),
    skill_id        bigint NOT NULL REFERENCES malu$skill_package(skill_id) ON DELETE CASCADE,
    state_name      text NOT NULL,
    state_kind      text NOT NULL
        CHECK (state_kind IN ('start','step','validation','exception_handler','terminal')),
    step_jsonb      jsonb,
    validation_jsonb jsonb,
    UNIQUE (skill_id, state_name)
);
CREATE INDEX malu$skill_state_skill_idx ON malu$skill_state(skill_id);

ALTER TABLE malu$skill_state ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_owner ON malu$skill_state
    USING (owner_schema = current_schema())
    WITH CHECK (owner_schema = current_schema());

GRANT SELECT, INSERT, UPDATE, DELETE ON malu$skill_state TO
    maludb_memory_admin, maludb_memory_executor;
GRANT SELECT ON malu$skill_state TO maludb_memory_auditor;
GRANT USAGE, SELECT ON SEQUENCE malu$skill_state_state_id_seq TO
    maludb_memory_admin, maludb_memory_executor;

-- Exactly one start state per skill.
CREATE UNIQUE INDEX malu$skill_state_one_start
    ON malu$skill_state(skill_id) WHERE state_kind = 'start';

-- =====================================================================
-- malu$skill_transition — directed edges.
--
-- on_outcome conventions: 'success' | 'failure' | 'aborted' | 'skipped'
-- | 'exception:<class>'. For an outcome of 'exception:<class>', the
-- runtime first looks for a literal match, then falls back to
-- 'exception:*'.
-- =====================================================================
CREATE TABLE malu$skill_transition (
    transition_id   bigserial PRIMARY KEY,
    owner_schema    name NOT NULL DEFAULT current_schema(),
    skill_id        bigint NOT NULL REFERENCES malu$skill_package(skill_id) ON DELETE CASCADE,
    from_state_id   bigint NOT NULL REFERENCES malu$skill_state(state_id) ON DELETE CASCADE,
    to_state_id     bigint NOT NULL REFERENCES malu$skill_state(state_id) ON DELETE CASCADE,
    on_outcome      text NOT NULL,
    guard_jsonb     jsonb,
    ordinal         integer NOT NULL DEFAULT 0,
    UNIQUE (skill_id, from_state_id, on_outcome)
);
CREATE INDEX malu$skill_transition_from_idx
    ON malu$skill_transition(from_state_id);
CREATE INDEX malu$skill_transition_skill_idx
    ON malu$skill_transition(skill_id);

ALTER TABLE malu$skill_transition ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_owner ON malu$skill_transition
    USING (owner_schema = current_schema())
    WITH CHECK (owner_schema = current_schema());

GRANT SELECT, INSERT, UPDATE, DELETE ON malu$skill_transition TO
    maludb_memory_admin, maludb_memory_executor;
GRANT SELECT ON malu$skill_transition TO maludb_memory_auditor;
GRANT USAGE, SELECT ON SEQUENCE malu$skill_transition_transition_id_seq TO
    maludb_memory_admin, maludb_memory_executor;

-- =====================================================================
-- malu$skill_execution_record — per-run header.
-- =====================================================================
CREATE TABLE malu$skill_execution_record (
    execution_id            bigserial PRIMARY KEY,
    owner_schema            name NOT NULL DEFAULT current_schema(),
    skill_id                bigint NOT NULL REFERENCES malu$skill_package(skill_id) ON DELETE RESTRICT,
    account_id              bigint REFERENCES malu$account(account_id) ON DELETE SET NULL,
    actor_role              name NOT NULL DEFAULT current_user,
    active_pool_id          bigint,   -- FK added when malu$active_memory_pool lands (S5-3)
    task_objective          text,
    authorized_partitions   text[],
    source_context_id       bigint REFERENCES malu$source_package(source_package_id) ON DELETE SET NULL,
    environment             text,
    technology_stack        text[],
    bound_at                timestamptz NOT NULL DEFAULT now(),
    started_at              timestamptz,
    completed_at            timestamptz,
    current_state_id        bigint REFERENCES malu$skill_state(state_id) ON DELETE SET NULL,
    final_outcome           text
        CHECK (final_outcome IS NULL OR final_outcome IN ('success','failure','aborted')),
    step_count              integer NOT NULL DEFAULT 0,
    emitted_claim_ids       bigint[] NOT NULL DEFAULT ARRAY[]::bigint[],
    audit_jsonb             jsonb
);
CREATE INDEX malu$skill_exec_owner_idx ON malu$skill_execution_record(owner_schema);
CREATE INDEX malu$skill_exec_skill_idx ON malu$skill_execution_record(skill_id);

ALTER TABLE malu$skill_execution_record ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_owner ON malu$skill_execution_record
    USING (owner_schema = current_schema())
    WITH CHECK (owner_schema = current_schema());

GRANT SELECT ON malu$skill_execution_record TO
    maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;
GRANT INSERT, UPDATE ON malu$skill_execution_record TO
    maludb_memory_admin, maludb_memory_executor;
GRANT USAGE, SELECT ON SEQUENCE malu$skill_execution_record_execution_id_seq TO
    maludb_memory_admin, maludb_memory_executor;

-- =====================================================================
-- malu$skill_execution_step — per-step trace.
-- =====================================================================
CREATE TABLE malu$skill_execution_step (
    exec_step_id     bigserial PRIMARY KEY,
    owner_schema     name NOT NULL DEFAULT current_schema(),
    execution_id     bigint NOT NULL REFERENCES malu$skill_execution_record(execution_id) ON DELETE CASCADE,
    step_idx         integer NOT NULL,
    state_id         bigint NOT NULL REFERENCES malu$skill_state(state_id) ON DELETE RESTRICT,
    state_name       text NOT NULL,
    outcome          text,
    observation_jsonb jsonb,
    entered_at       timestamptz NOT NULL DEFAULT now(),
    left_at          timestamptz,
    UNIQUE (execution_id, step_idx)
);

ALTER TABLE malu$skill_execution_step ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_owner ON malu$skill_execution_step
    USING (owner_schema = current_schema())
    WITH CHECK (owner_schema = current_schema());

GRANT SELECT, INSERT, UPDATE ON malu$skill_execution_step TO
    maludb_memory_admin, maludb_memory_executor;
GRANT SELECT ON malu$skill_execution_step TO maludb_memory_auditor;
GRANT USAGE, SELECT ON SEQUENCE malu$skill_execution_step_exec_step_id_seq TO
    maludb_memory_admin, maludb_memory_executor;

-- =====================================================================
-- register_skill — upsert by (owner_schema, skill_name, version).
-- =====================================================================
CREATE FUNCTION register_skill(
    p_skill_name           text,
    p_version              text DEFAULT '1.0.0',
    p_description          text DEFAULT NULL,
    p_packaging_kind       text DEFAULT 'markdown',
    p_applicability_jsonb  jsonb DEFAULT '{}'::jsonb,
    p_precondition_jsonb   jsonb DEFAULT '[]'::jsonb
) RETURNS bigint
LANGUAGE plpgsql
AS $body$
DECLARE v_id bigint;
BEGIN
    INSERT INTO malu$skill_package
        (skill_name, version, description, packaging_kind,
         applicability_jsonb, precondition_jsonb)
    VALUES (p_skill_name, p_version, p_description, p_packaging_kind,
            p_applicability_jsonb, p_precondition_jsonb)
    ON CONFLICT (owner_schema, skill_name, version) DO UPDATE
        SET description          = COALESCE(EXCLUDED.description,         malu$skill_package.description),
            packaging_kind       = EXCLUDED.packaging_kind,
            applicability_jsonb  = EXCLUDED.applicability_jsonb,
            precondition_jsonb   = EXCLUDED.precondition_jsonb,
            updated_at           = now()
    RETURNING skill_id INTO v_id;
    RETURN v_id;
END;
$body$;

-- =====================================================================
-- add_skill_state / add_skill_transition — fluent helpers.
-- =====================================================================
CREATE FUNCTION add_skill_state(
    p_skill_id        bigint,
    p_state_name      text,
    p_state_kind      text,
    p_step_jsonb      jsonb DEFAULT NULL,
    p_validation_jsonb jsonb DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql
AS $body$
DECLARE v_id bigint;
BEGIN
    INSERT INTO malu$skill_state
        (skill_id, state_name, state_kind, step_jsonb, validation_jsonb)
    VALUES (p_skill_id, p_state_name, p_state_kind, p_step_jsonb, p_validation_jsonb)
    RETURNING state_id INTO v_id;
    RETURN v_id;
END;
$body$;

CREATE FUNCTION add_skill_transition(
    p_skill_id    bigint,
    p_from_state  text,
    p_to_state    text,
    p_on_outcome  text,
    p_guard_jsonb jsonb DEFAULT NULL,
    p_ordinal     integer DEFAULT 0
) RETURNS bigint
LANGUAGE plpgsql
AS $body$
DECLARE
    v_from bigint;
    v_to   bigint;
    v_id   bigint;
BEGIN
    SELECT state_id INTO v_from FROM malu$skill_state
        WHERE skill_id = p_skill_id AND state_name = p_from_state;
    SELECT state_id INTO v_to   FROM malu$skill_state
        WHERE skill_id = p_skill_id AND state_name = p_to_state;
    IF v_from IS NULL OR v_to IS NULL THEN
        RAISE EXCEPTION 'add_skill_transition: state(s) not found: from=% to=%',
            p_from_state, p_to_state
            USING ERRCODE = 'no_data_found';
    END IF;
    INSERT INTO malu$skill_transition
        (skill_id, from_state_id, to_state_id, on_outcome, guard_jsonb, ordinal)
    VALUES (p_skill_id, v_from, v_to, p_on_outcome, p_guard_jsonb, p_ordinal)
    RETURNING transition_id INTO v_id;
    RETURN v_id;
END;
$body$;

-- =====================================================================
-- _evaluate_applicability — internal helper.
--
-- Returns NULL on pass, or a short reason string on fail. Applicability
-- keys checked in v1:
--   "environment" (text)         — must == p_environment if both set.
--   "technology_stack" (text[])  — every entry must appear in p_technology_stack.
--   "time_window" (jsonb)        — {start?, end?} ISO timestamps; now()
--                                  must be within the range.
-- Unknown keys are ignored in v1 (forward compatibility with future
-- applicability dimensions).
-- =====================================================================
CREATE FUNCTION _evaluate_applicability(
    p_applicability    jsonb,
    p_environment      text,
    p_technology_stack text[]
) RETURNS text
LANGUAGE plpgsql IMMUTABLE
AS $body$
DECLARE
    v_required_env text;
    v_required_tech text[];
    v_now timestamptz := now();
    v_tw_start timestamptz;
    v_tw_end   timestamptz;
    t text;
BEGIN
    IF p_applicability IS NULL OR p_applicability = '{}'::jsonb THEN
        RETURN NULL;
    END IF;

    v_required_env := p_applicability ->> 'environment';
    IF v_required_env IS NOT NULL
       AND p_environment IS DISTINCT FROM v_required_env THEN
        RETURN format('environment mismatch: required %s, caller %s',
                      v_required_env, COALESCE(p_environment, '<unset>'));
    END IF;

    IF p_applicability ? 'technology_stack' THEN
        v_required_tech := ARRAY(SELECT jsonb_array_elements_text(p_applicability -> 'technology_stack'));
        IF v_required_tech IS NOT NULL THEN
            FOREACH t IN ARRAY v_required_tech LOOP
                IF p_technology_stack IS NULL
                   OR NOT (t = ANY(p_technology_stack)) THEN
                    RETURN format('technology_stack missing required entry: %s', t);
                END IF;
            END LOOP;
        END IF;
    END IF;

    IF p_applicability ? 'time_window' THEN
        v_tw_start := NULLIF(p_applicability #>> '{time_window,start}', '')::timestamptz;
        v_tw_end   := NULLIF(p_applicability #>> '{time_window,end}',   '')::timestamptz;
        IF v_tw_start IS NOT NULL AND v_now < v_tw_start THEN
            RETURN format('time_window not yet open: starts %s', v_tw_start);
        END IF;
        IF v_tw_end IS NOT NULL AND v_now > v_tw_end THEN
            RETURN format('time_window already closed: ended %s', v_tw_end);
        END IF;
    END IF;

    RETURN NULL;
END;
$body$;

-- =====================================================================
-- begin_skill_execution — bind context + applicability + start state.
--
-- Refuses with errcode 'check_violation' if the skill is disabled, has
-- no start state, or applicability rejects the request. Records the
-- execution + an initial step row for the start state.
-- =====================================================================
CREATE FUNCTION begin_skill_execution(
    p_skill_id              bigint,
    p_environment           text DEFAULT NULL,
    p_technology_stack      text[] DEFAULT NULL,
    p_task_objective        text DEFAULT NULL,
    p_authorized_partitions text[] DEFAULT NULL,
    p_account_id            bigint DEFAULT NULL,
    p_active_pool_id        bigint DEFAULT NULL,
    p_source_context_id     bigint DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql
AS $body$
DECLARE
    v_skill        malu$skill_package%ROWTYPE;
    v_start        malu$skill_state%ROWTYPE;
    v_reason       text;
    v_execution_id bigint;
BEGIN
    SELECT * INTO v_skill FROM malu$skill_package WHERE skill_id = p_skill_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'begin_skill_execution: skill % not found', p_skill_id
            USING ERRCODE = 'no_data_found';
    END IF;
    IF NOT v_skill.enabled THEN
        RAISE EXCEPTION 'begin_skill_execution: skill % is disabled', p_skill_id
            USING ERRCODE = 'object_not_in_prerequisite_state';
    END IF;

    SELECT * INTO v_start FROM malu$skill_state
        WHERE skill_id = p_skill_id AND state_kind = 'start';
    IF NOT FOUND THEN
        RAISE EXCEPTION 'begin_skill_execution: skill % has no start state', p_skill_id
            USING ERRCODE = 'object_not_in_prerequisite_state';
    END IF;

    v_reason := _evaluate_applicability(v_skill.applicability_jsonb,
                                        p_environment, p_technology_stack);
    IF v_reason IS NOT NULL THEN
        RAISE EXCEPTION 'begin_skill_execution: applicability check failed: %', v_reason
            USING ERRCODE = 'check_violation';
    END IF;

    INSERT INTO malu$skill_execution_record
        (skill_id, account_id, active_pool_id, task_objective,
         authorized_partitions, source_context_id, environment,
         technology_stack, started_at, current_state_id, step_count)
    VALUES
        (p_skill_id, p_account_id, p_active_pool_id, p_task_objective,
         p_authorized_partitions, p_source_context_id, p_environment,
         p_technology_stack, now(), v_start.state_id, 1)
    RETURNING execution_id INTO v_execution_id;

    INSERT INTO malu$skill_execution_step
        (execution_id, step_idx, state_id, state_name)
    VALUES (v_execution_id, 1, v_start.state_id, v_start.state_name);

    PERFORM audit_event('skill_execution_begun', NULL, NULL,
        jsonb_build_object(
            'execution_id', v_execution_id,
            'skill_id',     p_skill_id,
            'skill_name',   v_skill.skill_name,
            'skill_version', v_skill.version,
            'environment',  p_environment,
            'task_objective', p_task_objective));

    RETURN v_execution_id;
END;
$body$;

-- =====================================================================
-- step_skill_execution — advance the state machine.
--
-- Closes the current step row with the supplied outcome + observation.
-- Resolves the next state via malu$skill_transition: literal on_outcome
-- match first, then 'exception:*' wildcard, then 'default'. Refuses if
-- no transition matches. On a terminal target, the execution is
-- finalised (completed_at + final_outcome).
--
-- Returns the next state's name. If the execution just finalised,
-- returns the terminal state's name and the execution_record has its
-- completed_at + final_outcome set.
-- =====================================================================
CREATE FUNCTION step_skill_execution(
    p_execution_id    bigint,
    p_outcome         text,
    p_observation_jsonb jsonb DEFAULT NULL
) RETURNS text
LANGUAGE plpgsql
AS $body$
DECLARE
    v_exec          malu$skill_execution_record%ROWTYPE;
    v_current_state malu$skill_state%ROWTYPE;
    v_next_id       bigint;
    v_next          malu$skill_state%ROWTYPE;
    v_next_idx      integer;
    v_final_outcome text;
BEGIN
    SELECT * INTO v_exec FROM malu$skill_execution_record
        WHERE execution_id = p_execution_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'step_skill_execution: execution % not found', p_execution_id
            USING ERRCODE = 'no_data_found';
    END IF;
    IF v_exec.completed_at IS NOT NULL THEN
        RAISE EXCEPTION 'step_skill_execution: execution % already finalised', p_execution_id
            USING ERRCODE = 'object_not_in_prerequisite_state';
    END IF;

    SELECT * INTO v_current_state FROM malu$skill_state
        WHERE state_id = v_exec.current_state_id;

    -- Close the current step row.
    UPDATE malu$skill_execution_step
       SET outcome           = p_outcome,
           observation_jsonb = p_observation_jsonb,
           left_at           = now()
     WHERE execution_id = p_execution_id
       AND step_idx     = v_exec.step_count;

    -- Resolve the next state. Precedence:
    --   1. literal on_outcome match (lowest ordinal wins)
    --   2. 'exception:*' wildcard if outcome starts with 'exception:'
    --   3. 'default' catch-all
    SELECT to_state_id INTO v_next_id
      FROM malu$skill_transition
     WHERE skill_id      = v_exec.skill_id
       AND from_state_id = v_exec.current_state_id
       AND on_outcome    = p_outcome
     ORDER BY ordinal
     LIMIT 1;

    IF v_next_id IS NULL AND p_outcome LIKE 'exception:%' THEN
        SELECT to_state_id INTO v_next_id
          FROM malu$skill_transition
         WHERE skill_id      = v_exec.skill_id
           AND from_state_id = v_exec.current_state_id
           AND on_outcome    = 'exception:*'
         ORDER BY ordinal
         LIMIT 1;
    END IF;

    IF v_next_id IS NULL THEN
        SELECT to_state_id INTO v_next_id
          FROM malu$skill_transition
         WHERE skill_id      = v_exec.skill_id
           AND from_state_id = v_exec.current_state_id
           AND on_outcome    = 'default'
         ORDER BY ordinal
         LIMIT 1;
    END IF;

    IF v_next_id IS NULL THEN
        RAISE EXCEPTION 'step_skill_execution: no transition from % on outcome %',
            v_current_state.state_name, p_outcome
            USING ERRCODE = 'no_data_found';
    END IF;

    SELECT * INTO v_next FROM malu$skill_state WHERE state_id = v_next_id;

    -- Terminal: finalise and emit audit. Map state_name conventions:
    -- terminal states named 'success'/'failure'/'aborted' map onto
    -- final_outcome of the same value; others default to 'success'.
    IF v_next.state_kind = 'terminal' THEN
        v_final_outcome := CASE
            WHEN v_next.state_name IN ('success','failure','aborted')
                THEN v_next.state_name
            ELSE 'success' END;

        UPDATE malu$skill_execution_record
           SET current_state_id = v_next.state_id,
               completed_at     = now(),
               final_outcome    = v_final_outcome,
               step_count       = step_count + 1
         WHERE execution_id = p_execution_id;

        -- Record the terminal state row.
        INSERT INTO malu$skill_execution_step
            (execution_id, step_idx, state_id, state_name, entered_at, left_at, outcome)
        VALUES (p_execution_id, v_exec.step_count + 1, v_next.state_id,
                v_next.state_name, now(), now(), v_final_outcome);

        PERFORM audit_event('skill_execution_finalised', NULL, NULL,
            jsonb_build_object(
                'execution_id',  p_execution_id,
                'skill_id',      v_exec.skill_id,
                'final_outcome', v_final_outcome,
                'terminal_state', v_next.state_name,
                'step_count',    v_exec.step_count + 1));

        RETURN v_next.state_name;
    END IF;

    -- Non-terminal advance.
    v_next_idx := v_exec.step_count + 1;
    UPDATE malu$skill_execution_record
       SET current_state_id = v_next.state_id,
           step_count       = v_next_idx
     WHERE execution_id = p_execution_id;

    INSERT INTO malu$skill_execution_step
        (execution_id, step_idx, state_id, state_name)
    VALUES (p_execution_id, v_next_idx, v_next.state_id, v_next.state_name);

    PERFORM audit_event('skill_execution_advanced', NULL, NULL,
        jsonb_build_object(
            'execution_id', p_execution_id,
            'from_state',   v_current_state.state_name,
            'on_outcome',   p_outcome,
            'to_state',     v_next.state_name,
            'step_idx',     v_next_idx));

    RETURN v_next.state_name;
END;
$body$;

-- =====================================================================
-- abort_skill_execution — terminate without traversing transitions.
-- =====================================================================
CREATE FUNCTION abort_skill_execution(
    p_execution_id  bigint,
    p_reason        text DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql
AS $body$
BEGIN
    UPDATE malu$skill_execution_record
       SET completed_at  = now(),
           final_outcome = 'aborted',
           audit_jsonb   = jsonb_build_object('abort_reason', p_reason)
     WHERE execution_id = p_execution_id
       AND completed_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'abort_skill_execution: execution % missing or already finalised',
            p_execution_id
            USING ERRCODE = 'object_not_in_prerequisite_state';
    END IF;

    PERFORM audit_event('skill_execution_aborted', NULL, NULL,
        jsonb_build_object(
            'execution_id', p_execution_id,
            'reason',       p_reason));
END;
$body$;

-- =====================================================================
-- skill_emit_claim — record that this execution produced a claim.
--
-- Appends to the execution's emitted_claim_ids array. The caller is
-- responsible for having inserted the claim row first (and for
-- attaching a derivation_ledger entry to it).
-- =====================================================================
CREATE FUNCTION skill_emit_claim(
    p_execution_id  bigint,
    p_claim_id      bigint
) RETURNS void
LANGUAGE plpgsql
AS $body$
BEGIN
    UPDATE malu$skill_execution_record
       SET emitted_claim_ids = emitted_claim_ids || ARRAY[p_claim_id]::bigint[]
     WHERE execution_id = p_execution_id
       AND completed_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'skill_emit_claim: execution % missing or already finalised',
            p_execution_id
            USING ERRCODE = 'object_not_in_prerequisite_state';
    END IF;

    PERFORM audit_event('skill_claim_emitted', 'claim', p_claim_id,
        jsonb_build_object('execution_id', p_execution_id));
END;
$body$;

GRANT EXECUTE ON FUNCTION
    register_skill(text, text, text, text, jsonb, jsonb),
    add_skill_state(bigint, text, text, jsonb, jsonb),
    add_skill_transition(bigint, text, text, text, jsonb, integer),
    _evaluate_applicability(jsonb, text, text[]),
    begin_skill_execution(bigint, text, text[], text, text[], bigint, bigint, bigint),
    step_skill_execution(bigint, text, jsonb),
    abort_skill_execution(bigint, text),
    skill_emit_claim(bigint, bigint)
TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;

-- =====================================================================
-- Stage-boundary roadmap update: malu$skill_package now legitimately
-- installed. The other Stage 5 placeholders remain forbidden.
-- =====================================================================
CREATE OR REPLACE FUNCTION stage_boundary_violations()
RETURNS TABLE(object_kind text, object_name text, stage smallint)
LANGUAGE sql STABLE
AS $body$
    WITH forbidden(name, stage) AS (
        VALUES
            ('malu$governed_object'::text,       2::smallint),
            ('malu$generalized_workflow',        5),
            ('malu$procedural_memory_object',    5),
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
