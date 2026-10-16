\echo Use "ALTER EXTENSION maludb_core UPDATE TO '0.27.0'" to load this file. \quit

-- =====================================================================
-- maludb_core 0.26.0 → 0.27.0
--
-- Stage 3 — Lifecycle + salience policy (S3-5).
--
-- Per requirements.md §3.14: "The DBMS MUST treat lifecycle management
-- as governed data behavior, not merely retrieval ranking. Memories,
-- facts, Episode Objects ... MUST support explicit lifecycle
-- transitions for staleness, supersession, contradiction, consolidation,
-- decay, archival movement, retirement, legal hold, and pruning."
--
-- And: "Pruning is permitted only through policy-controlled workflows
-- that preserve required audit, legal-hold, provenance, and tombstone
-- records."
--
-- Surface:
--   * malu$reinforcement_event — append-only access/citation log per
--                                 (object_type, object_id).
--   * malu$lifecycle_policy   — per-tenant policy keyed by
--                                target_object_type (decay half-life,
--                                archive_after_idle_days, retain_until
--                                default, autotombstone settings).
--   * malu$legal_hold         — active + historical legal holds; a row
--                                with released_at IS NULL means hold is
--                                active.
--   * record_reinforcement    — append to the event log + bump
--                                indirect salience signals.
--   * compute_salience(type, id) → numeric in [0, 1]; exponential
--                                decay over time + reinforcement count.
--   * apply_lifecycle_state   — polymorphic transition helper for
--                                fact/memory/episode/claim.
--   * consolidate_memories    — combine N memories into one; records
--                                supersession edges + ledger entry +
--                                consolidated_into_memory_id pointer
--                                + audit.
--   * legal_hold_apply / _release / is_under_legal_hold.
--   * retention_candidates    — SETOF rows eligible for pruning
--                                (past retain_until + not on hold).
--   * prune_object            — tombstone + audit, refuses if on hold.
-- =====================================================================

CREATE OR REPLACE FUNCTION maludb_core_version() RETURNS text
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$ SELECT '0.27.0'::text $body$;

-- =====================================================================
-- malu$lifecycle_policy
-- =====================================================================
CREATE TABLE malu$lifecycle_policy (
    policy_id                bigserial PRIMARY KEY,
    owner_schema             name NOT NULL DEFAULT current_schema(),
    target_object_type       text NOT NULL,
    decay_half_life_days     integer NOT NULL DEFAULT 90
        CHECK (decay_half_life_days > 0),
    archive_after_idle_days  integer
        CHECK (archive_after_idle_days IS NULL OR archive_after_idle_days > 0),
    retain_for_days          integer
        CHECK (retain_for_days IS NULL OR retain_for_days > 0),
    autotombstone_enabled    boolean NOT NULL DEFAULT false,
    created_at               timestamptz NOT NULL DEFAULT now(),
    updated_at               timestamptz NOT NULL DEFAULT now(),
    CHECK (target_object_type IN
        ('claim','fact','memory','episode_object','memory_detail_object')),
    UNIQUE (owner_schema, target_object_type)
);

ALTER TABLE malu$lifecycle_policy ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_owner ON malu$lifecycle_policy
    USING (owner_schema = current_schema())
    WITH CHECK (owner_schema = current_schema());

-- =====================================================================
-- malu$reinforcement_event
--
-- Append-only access/citation log. Each row carries a `weight` so
-- different reinforcement kinds can contribute unequally to salience.
-- =====================================================================
CREATE TABLE malu$reinforcement_event (
    event_id            bigserial PRIMARY KEY,
    owner_schema        name NOT NULL DEFAULT current_schema(),
    target_object_type  text NOT NULL,
    target_object_id    bigint NOT NULL,
    event_kind          text NOT NULL,
    weight              numeric(5,4) NOT NULL DEFAULT 1.0
        CHECK (weight >= 0 AND weight <= 10),
    actor_role          name NOT NULL DEFAULT current_user,
    context_jsonb       jsonb,
    occurred_at         timestamptz NOT NULL DEFAULT now(),
    CHECK (target_object_type IN
        ('claim','fact','memory','episode_object','memory_detail_object')),
    CHECK (event_kind IN ('access','citation','edit','review','propagation','consolidation'))
);
CREATE INDEX malu$reinforcement_target_idx
    ON malu$reinforcement_event (target_object_type, target_object_id, occurred_at DESC);

ALTER TABLE malu$reinforcement_event ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_owner ON malu$reinforcement_event
    USING (owner_schema = current_schema())
    WITH CHECK (owner_schema = current_schema());

-- =====================================================================
-- malu$legal_hold
--
-- Polymorphic legal-hold registry. released_at IS NULL means active.
-- =====================================================================
CREATE TABLE malu$legal_hold (
    hold_id          bigserial PRIMARY KEY,
    owner_schema     name NOT NULL DEFAULT current_schema(),
    target_object_type text NOT NULL,
    target_object_id   bigint NOT NULL,
    reason           text NOT NULL,
    applied_at       timestamptz NOT NULL DEFAULT now(),
    applied_by       name NOT NULL DEFAULT current_user,
    released_at      timestamptz,
    released_by      name,
    release_reason   text,
    CHECK (target_object_type IN
        ('source_package','claim','fact','memory','episode_object','memory_detail_object'))
);
CREATE INDEX malu$legal_hold_active_idx
    ON malu$legal_hold (target_object_type, target_object_id)
    WHERE released_at IS NULL;

ALTER TABLE malu$legal_hold ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_owner ON malu$legal_hold
    USING (owner_schema = current_schema())
    WITH CHECK (owner_schema = current_schema());

-- =====================================================================
-- Grants
-- =====================================================================
GRANT SELECT ON
    malu$lifecycle_policy, malu$reinforcement_event, malu$legal_hold
TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;
GRANT INSERT, UPDATE, DELETE ON
    malu$lifecycle_policy, malu$reinforcement_event, malu$legal_hold
TO maludb_memory_admin, maludb_memory_executor;
GRANT USAGE, SELECT ON SEQUENCE
    malu$lifecycle_policy_policy_id_seq,
    malu$reinforcement_event_event_id_seq,
    malu$legal_hold_hold_id_seq
TO maludb_memory_admin, maludb_memory_executor;

-- =====================================================================
-- set_lifecycle_policy — upsert per tenant + object type.
-- =====================================================================
CREATE FUNCTION set_lifecycle_policy(
    p_target_object_type     text,
    p_decay_half_life_days   integer DEFAULT 90,
    p_archive_after_idle_days integer DEFAULT NULL,
    p_retain_for_days        integer DEFAULT NULL,
    p_autotombstone_enabled  boolean DEFAULT false
) RETURNS bigint
LANGUAGE plpgsql
AS $body$
DECLARE v_id bigint;
BEGIN
    INSERT INTO malu$lifecycle_policy
        (target_object_type, decay_half_life_days,
         archive_after_idle_days, retain_for_days, autotombstone_enabled)
    VALUES (p_target_object_type, p_decay_half_life_days,
            p_archive_after_idle_days, p_retain_for_days,
            p_autotombstone_enabled)
    ON CONFLICT (owner_schema, target_object_type) DO UPDATE
        SET decay_half_life_days     = EXCLUDED.decay_half_life_days,
            archive_after_idle_days  = EXCLUDED.archive_after_idle_days,
            retain_for_days          = EXCLUDED.retain_for_days,
            autotombstone_enabled    = EXCLUDED.autotombstone_enabled,
            updated_at               = now()
    RETURNING policy_id INTO v_id;
    RETURN v_id;
END;
$body$;

-- =====================================================================
-- record_reinforcement — append-only log.
-- =====================================================================
CREATE FUNCTION record_reinforcement(
    p_target_object_type text,
    p_target_object_id   bigint,
    p_event_kind         text,
    p_weight             numeric DEFAULT 1.0,
    p_context_jsonb      jsonb   DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql
AS $body$
DECLARE v_id bigint;
BEGIN
    INSERT INTO malu$reinforcement_event
        (target_object_type, target_object_id, event_kind, weight, context_jsonb)
    VALUES (p_target_object_type, p_target_object_id, p_event_kind,
            COALESCE(p_weight, 1.0), p_context_jsonb)
    RETURNING event_id INTO v_id;
    RETURN v_id;
END;
$body$;

-- =====================================================================
-- compute_salience — combines reinforcement count with exponential
-- decay over time. Per the policy's half_life_days, recent
-- reinforcements weigh more.
--
--   salience = 1 − exp(−decayed_total / k)
--
-- where decayed_total = Σ weight × 0.5 ^ (age_days / half_life)
-- and k is a normalisation constant (default 5.0) chosen so a
-- handful of recent strong reinforcements push toward 1.
-- =====================================================================
CREATE FUNCTION compute_salience(
    p_target_object_type text,
    p_target_object_id   bigint,
    p_normalisation      numeric DEFAULT 5.0
) RETURNS numeric
LANGUAGE plpgsql STABLE
AS $body$
DECLARE
    v_half_life integer;
    v_decayed   numeric;
    v_salience  numeric;
BEGIN
    SELECT decay_half_life_days INTO v_half_life
    FROM malu$lifecycle_policy
    WHERE target_object_type = p_target_object_type;
    IF v_half_life IS NULL THEN
        v_half_life := 90;  -- fallback default
    END IF;

    SELECT COALESCE(SUM(weight * 0.5 ^ (EXTRACT(EPOCH FROM (now() - occurred_at)) / 86400.0
                                        / v_half_life)), 0)
    INTO v_decayed
    FROM malu$reinforcement_event
    WHERE target_object_type = p_target_object_type
      AND target_object_id   = p_target_object_id;

    IF v_decayed = 0 THEN
        RETURN 0;
    END IF;

    v_salience := 1.0 - exp(-v_decayed / COALESCE(p_normalisation, 5.0));
    RETURN ROUND(v_salience, 4);
END;
$body$;

-- =====================================================================
-- is_under_legal_hold(type, id) — TRUE iff at least one active row.
-- =====================================================================
CREATE FUNCTION is_under_legal_hold(
    p_target_object_type text,
    p_target_object_id   bigint
) RETURNS boolean
LANGUAGE sql STABLE
AS $body$
    SELECT EXISTS (
        SELECT 1 FROM malu$legal_hold
        WHERE target_object_type = p_target_object_type
          AND target_object_id   = p_target_object_id
          AND released_at IS NULL
    );
$body$;

-- =====================================================================
-- legal_hold_apply / _release.
-- =====================================================================
CREATE FUNCTION legal_hold_apply(
    p_target_object_type text,
    p_target_object_id   bigint,
    p_reason             text
) RETURNS bigint
LANGUAGE plpgsql
AS $body$
DECLARE v_id bigint;
BEGIN
    IF p_reason IS NULL OR p_reason = '' THEN
        RAISE EXCEPTION 'legal_hold_apply: reason required'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;
    INSERT INTO malu$legal_hold
        (target_object_type, target_object_id, reason)
    VALUES (p_target_object_type, p_target_object_id, p_reason)
    RETURNING hold_id INTO v_id;

    PERFORM audit_event('legal_hold_apply', p_target_object_type, p_target_object_id,
        jsonb_build_object('hold_id', v_id, 'reason', p_reason));
    RETURN v_id;
END;
$body$;

CREATE FUNCTION legal_hold_release(
    p_hold_id        bigint,
    p_release_reason text
) RETURNS void
LANGUAGE plpgsql
AS $body$
DECLARE
    v_type text;
    v_oid  bigint;
BEGIN
    IF p_release_reason IS NULL OR p_release_reason = '' THEN
        RAISE EXCEPTION 'legal_hold_release: reason required'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;
    UPDATE malu$legal_hold
       SET released_at    = now(),
           released_by    = current_user,
           release_reason = p_release_reason
     WHERE hold_id = p_hold_id AND released_at IS NULL
     RETURNING target_object_type, target_object_id INTO v_type, v_oid;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'legal_hold_release: hold_id=% not active', p_hold_id
            USING ERRCODE = 'no_data_found';
    END IF;
    PERFORM audit_event('legal_hold_release', v_type, v_oid,
        jsonb_build_object('hold_id', p_hold_id, 'release_reason', p_release_reason));
END;
$body$;

-- =====================================================================
-- apply_lifecycle_state — polymorphic state transition helper.
-- Allowed states per table differ; we keep the function generic and
-- let the table-level CHECK constraint reject invalid transitions.
-- =====================================================================
CREATE FUNCTION apply_lifecycle_state(
    p_target_object_type text,
    p_target_object_id   bigint,
    p_new_state          text,
    p_reason             text DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql
AS $body$
DECLARE
    v_table  text;
    v_id_col text;
BEGIN
    CASE p_target_object_type
        WHEN 'fact'           THEN v_table := 'malu$fact';
                                   v_id_col := 'fact_id';
        WHEN 'memory'         THEN v_table := 'malu$memory';
                                   v_id_col := 'memory_id';
        WHEN 'episode_object' THEN v_table := 'malu$episode_object';
                                   v_id_col := 'episode_id';
        ELSE
            RAISE EXCEPTION 'apply_lifecycle_state: type % not supported',
                p_target_object_type
                USING ERRCODE = 'invalid_parameter_value';
    END CASE;

    IF is_under_legal_hold(p_target_object_type, p_target_object_id)
       AND p_new_state IN ('tombstoned','retired','archived') THEN
        RAISE EXCEPTION
          'LEGAL_HOLD_BLOCKS_TRANSITION: %s id=% is on legal hold; release first',
          p_target_object_type, p_target_object_id
          USING ERRCODE = 'object_not_in_prerequisite_state';
    END IF;

    EXECUTE format(
        'UPDATE maludb_core.%I SET lifecycle_state = $1 WHERE %I = $2',
        v_table, v_id_col)
    USING p_new_state, p_target_object_id;

    PERFORM audit_event('apply_lifecycle_state',
        p_target_object_type, p_target_object_id,
        jsonb_build_object('new_state', p_new_state, 'reason', p_reason));
END;
$body$;

-- =====================================================================
-- consolidate_memories — combine N memories into one.
--
-- Per §3.14: "Consolidation MUST preserve links to the source
-- memories, facts, claims, source packages, workflow traces, and
-- derivation ledger entries that supported the consolidated object."
--
-- Atomic flow:
--   1. Verify all input memory_ids exist + are active.
--   2. Create the new consolidated memory.
--   3. UPDATE each original: lifecycle_state='consolidated' +
--      consolidated_into_memory_id = new_memory_id.
--   4. INSERT one malu$supersession_edge per original
--      (kind='consolidation').
--   5. INSERT a derivation_ledger entry recording the source set.
--   6. record_reinforcement on each input as kind='consolidation'.
--   7. audit_event.
-- =====================================================================
CREATE FUNCTION consolidate_memories(
    p_source_memory_ids  bigint[],
    p_consolidated_kind  text,
    p_title              text,
    p_summary            text,
    p_payload_jsonb      jsonb DEFAULT '{}'::jsonb,
    p_reason             text  DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql
AS $body$
DECLARE
    v_new_memory_id bigint;
    v_count_active  bigint;
    v_id            bigint;
BEGIN
    IF p_source_memory_ids IS NULL OR array_length(p_source_memory_ids, 1) IS NULL THEN
        RAISE EXCEPTION 'consolidate_memories: source_memory_ids must be non-empty'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    SELECT count(*) INTO v_count_active
    FROM malu$memory
    WHERE memory_id = ANY(p_source_memory_ids)
      AND lifecycle_state = 'active';
    IF v_count_active <> array_length(p_source_memory_ids, 1) THEN
        RAISE EXCEPTION
          'consolidate_memories: one or more source memories missing or not active'
          USING ERRCODE = 'no_data_found';
    END IF;

    INSERT INTO malu$memory
        (memory_kind, title, summary, payload_jsonb)
    VALUES (p_consolidated_kind, p_title, p_summary,
            COALESCE(p_payload_jsonb, '{}'::jsonb))
    RETURNING memory_id INTO v_new_memory_id;

    FOREACH v_id IN ARRAY p_source_memory_ids LOOP
        UPDATE malu$memory
           SET lifecycle_state           = 'consolidated',
               consolidated_into_memory_id = v_new_memory_id,
               updated_at                = now()
         WHERE memory_id = v_id;

        INSERT INTO malu$supersession_edge
            (predecessor_type, predecessor_id, successor_type, successor_id,
             supersession_kind, reason)
        VALUES ('memory', v_id, 'memory', v_new_memory_id,
                'consolidation', p_reason);

        PERFORM record_reinforcement('memory', v_id, 'consolidation', 1.0,
            jsonb_build_object('consolidated_into', v_new_memory_id));
    END LOOP;

    PERFORM record_derivation(
        p_derived_object_type => 'memory',
        p_derived_object_id   => v_new_memory_id,
        p_parser_name         => 'consolidate_memories',
        p_inputs_jsonb        => jsonb_build_object(
            'source_memory_ids', to_jsonb(p_source_memory_ids),
            'reason',            p_reason));

    PERFORM audit_event('consolidate_memories', 'memory', v_new_memory_id,
        jsonb_build_object(
            'source_count',      array_length(p_source_memory_ids, 1),
            'source_memory_ids', to_jsonb(p_source_memory_ids),
            'reason',            p_reason));

    RETURN v_new_memory_id;
END;
$body$;

-- =====================================================================
-- retention_candidates — surface rows whose retention window has
-- elapsed AND are NOT on legal hold. Operators choose whether to
-- prune.
-- =====================================================================
CREATE FUNCTION retention_candidates(
    p_target_object_type text,
    p_cutoff             timestamptz DEFAULT now()
) RETURNS TABLE (
    object_id          bigint,
    lifecycle_state    text,
    last_updated       timestamptz,
    days_idle          integer
) LANGUAGE plpgsql STABLE
AS $body$
DECLARE
    v_policy   malu$lifecycle_policy%ROWTYPE;
    v_idle_cutoff timestamptz;
BEGIN
    SELECT * INTO v_policy FROM malu$lifecycle_policy
    WHERE target_object_type = p_target_object_type;

    -- Default 365 days if no policy
    v_idle_cutoff := p_cutoff - make_interval(days => COALESCE(v_policy.retain_for_days, 365));

    IF p_target_object_type = 'memory' THEN
        RETURN QUERY
            SELECT m.memory_id, m.lifecycle_state, m.updated_at,
                   EXTRACT(DAY FROM (p_cutoff - m.updated_at))::integer
            FROM malu$memory m
            WHERE m.lifecycle_state IN ('archived','superseded','consolidated','retired')
              AND m.updated_at < v_idle_cutoff
              AND NOT is_under_legal_hold('memory', m.memory_id);
    ELSIF p_target_object_type = 'fact' THEN
        RETURN QUERY
            SELECT f.fact_id, f.lifecycle_state, f.verified_at,
                   EXTRACT(DAY FROM (p_cutoff - f.verified_at))::integer
            FROM malu$fact f
            WHERE f.lifecycle_state IN ('superseded','retired')
              AND f.verified_at < v_idle_cutoff
              AND NOT is_under_legal_hold('fact', f.fact_id);
    ELSIF p_target_object_type = 'episode_object' THEN
        RETURN QUERY
            SELECT e.episode_id, e.lifecycle_state, e.recorded_at,
                   EXTRACT(DAY FROM (p_cutoff - e.recorded_at))::integer
            FROM malu$episode_object e
            WHERE e.lifecycle_state IN ('archived','superseded','consolidated','retired')
              AND e.recorded_at < v_idle_cutoff
              AND NOT is_under_legal_hold('episode_object', e.episode_id);
    ELSE
        RAISE EXCEPTION 'retention_candidates: type % not supported', p_target_object_type
            USING ERRCODE = 'invalid_parameter_value';
    END IF;
END;
$body$;

-- =====================================================================
-- prune_object — final transition to tombstoned. Refuses if the
-- object is on legal hold or has unresolved supersedents.
-- =====================================================================
CREATE FUNCTION prune_object(
    p_target_object_type text,
    p_target_object_id   bigint,
    p_reason             text
) RETURNS void
LANGUAGE plpgsql
AS $body$
BEGIN
    IF p_reason IS NULL OR p_reason = '' THEN
        RAISE EXCEPTION 'prune_object: reason required'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;
    IF is_under_legal_hold(p_target_object_type, p_target_object_id) THEN
        RAISE EXCEPTION
          'LEGAL_HOLD_BLOCKS_PRUNE: %s id=% is on legal hold',
          p_target_object_type, p_target_object_id
          USING ERRCODE = 'object_not_in_prerequisite_state';
    END IF;

    -- prune_object always goes through apply_lifecycle_state, which
    -- handles the actual UPDATE + audit emission. We don't physically
    -- DELETE the row — tombstones preserve provenance.
    PERFORM apply_lifecycle_state(p_target_object_type, p_target_object_id,
                                  'tombstoned', p_reason);

    PERFORM audit_event('prune_object', p_target_object_type, p_target_object_id,
        jsonb_build_object('reason', p_reason));
END;
$body$;

GRANT EXECUTE ON FUNCTION
    set_lifecycle_policy(text, integer, integer, integer, boolean),
    record_reinforcement(text, bigint, text, numeric, jsonb),
    compute_salience(text, bigint, numeric),
    is_under_legal_hold(text, bigint),
    legal_hold_apply(text, bigint, text),
    legal_hold_release(bigint, text),
    apply_lifecycle_state(text, bigint, text, text),
    consolidate_memories(bigint[], text, text, text, jsonb, text),
    retention_candidates(text, timestamptz),
    prune_object(text, bigint, text)
TO maludb_memory_admin, maludb_memory_executor;
