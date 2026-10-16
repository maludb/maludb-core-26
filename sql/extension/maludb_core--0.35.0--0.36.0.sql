\echo Use "ALTER EXTENSION maludb_core UPDATE TO '0.36.0'" to load this file. \quit

-- =====================================================================
-- maludb_core 0.35.0 → 0.36.0
--
-- Stage 5 — Episode replay API (S5-4). **Stage 5 closer.**
--
-- Per requirements.md §3.13. Replay reconstructs an authorized,
-- time-aware view of an Episode Object from durable evidence and
-- derivation records. It must answer:
--   1. What happened (current accepted view)?
--   2. What evidence supports that view?
--   3. What did the DBMS believe at a prior transaction time?
--   4. What later sources or memories changed the interpretation?
--
-- And it MUST identify:
--   - which source packages were inspected,
--   - which derived objects were included or hidden by policy,
--   - which temporal mode was used.
--
-- Modes:
--   current_valid             — active rows, currently valid only.
--   historical                — as of an event-time anchor
--                               (defaults to episode.occurred_at).
--   as_of_transaction_time    — what the DBMS believed at p_as_of
--                               in transaction time. Requires p_as_of.
--   full_bitemporal           — every connected revision returned.
--
-- Authorization: SECURITY INVOKER — RLS on every underlying table
-- gates what the caller can see. The "hidden_by_policy_count" counts
-- objects the caller CAN see but that were excluded by mode-specific
-- temporal/lifecycle filters; RLS-filtered rows are invisible to the
-- function by design.
--
-- The replay envelope is recorded in malu$episode_replay (kept for
-- audit / replay-of-replays) and the caller receives a jsonb copy.
-- =====================================================================

CREATE OR REPLACE FUNCTION maludb_core_version() RETURNS text
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$ SELECT '0.36.0'::text $body$;

-- =====================================================================
-- malu$episode_replay — recorded replay envelope.
-- =====================================================================
CREATE TABLE malu$episode_replay (
    replay_id        bigserial PRIMARY KEY,
    owner_schema     name NOT NULL DEFAULT current_schema(),
    episode_id       bigint NOT NULL REFERENCES malu$episode_object(episode_id) ON DELETE CASCADE,
    mode             text NOT NULL
        CHECK (mode IN ('current_valid','historical',
                        'as_of_transaction_time','full_bitemporal')),
    as_of            timestamptz,
    actor_role       name NOT NULL DEFAULT current_user,
    envelope_jsonb   jsonb NOT NULL,
    created_at       timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX malu$episode_replay_episode_idx
    ON malu$episode_replay(episode_id);
CREATE INDEX malu$episode_replay_owner_idx
    ON malu$episode_replay(owner_schema);

ALTER TABLE malu$episode_replay ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_owner ON malu$episode_replay
    USING (owner_schema = current_schema())
    WITH CHECK (owner_schema = current_schema());

GRANT SELECT ON malu$episode_replay TO
    maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;
GRANT INSERT ON malu$episode_replay TO
    maludb_memory_admin, maludb_memory_executor;
GRANT USAGE, SELECT ON SEQUENCE malu$episode_replay_replay_id_seq TO
    maludb_memory_admin, maludb_memory_executor;

-- =====================================================================
-- replay_episode — main entrypoint.
--
-- Returns a single jsonb envelope. Also inserts a row into
-- malu$episode_replay for audit.
--
-- Envelope shape:
--   episode_id, mode, as_of, temporal_mode_used,
--   episode: { core columns from malu$episode_object },
--   steps: [ {step_idx, action_class, actor, tool, outcome, ...}, ... ],
--   what_happened: { title, summary, payload_jsonb, occurred_at },
--   supporting_evidence: [
--     { kind: 'claim'|'fact'|'memory'|'source_package',
--       object_id, subject?, verb?, statement_text?,
--       source_package_id?, captured_at?, transaction_time_start? },
--     ...
--   ],
--   prior_belief: { ... } | null,    -- only for as_of_transaction_time
--                                    -- and full_bitemporal
--   later_changes: [ ... ],           -- objects changed/superseded
--                                    -- after as_of (or after episode time
--                                    -- for current_valid mode)
--   source_packages_inspected: [...],
--   included_object_ids: { claim:[], fact:[], memory:[], ... },
--   hidden_by_policy_count: N
-- =====================================================================
CREATE FUNCTION replay_episode(
    p_episode_id  bigint,
    p_mode        text DEFAULT 'current_valid',
    p_as_of       timestamptz DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
AS $body$
DECLARE
    v_episode malu$episode_object%ROWTYPE;
    v_anchor  timestamptz;
    v_envelope jsonb;
    v_steps        jsonb;
    v_evidence     jsonb;
    v_prior_belief jsonb;
    v_later_changes jsonb;
    v_source_pkgs  bigint[];
    v_included_claims  bigint[];
    v_included_facts   bigint[];
    v_included_memories bigint[];
    v_hidden_count integer := 0;
    v_later_anchor timestamptz;
    v_replay_id    bigint;
BEGIN
    IF p_mode NOT IN ('current_valid','historical',
                      'as_of_transaction_time','full_bitemporal') THEN
        RAISE EXCEPTION 'replay_episode: bad mode %', p_mode
            USING ERRCODE = 'invalid_parameter_value';
    END IF;
    IF p_mode = 'as_of_transaction_time' AND p_as_of IS NULL THEN
        RAISE EXCEPTION 'replay_episode: mode as_of_transaction_time requires p_as_of'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    SELECT * INTO v_episode FROM malu$episode_object WHERE episode_id = p_episode_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'replay_episode: episode % not found', p_episode_id
            USING ERRCODE = 'no_data_found';
    END IF;

    -- Temporal anchor:
    --   historical              → episode.occurred_at, or p_as_of override
    --   as_of_transaction_time  → p_as_of
    --   full_bitemporal         → now() (used only for "later_changes" cutoff)
    --   current_valid           → now()
    v_anchor := CASE p_mode
        WHEN 'historical'             THEN COALESCE(p_as_of, v_episode.occurred_at, v_episode.recorded_at)
        WHEN 'as_of_transaction_time' THEN p_as_of
        ELSE now()
    END;

    -- ---------- steps from MDOs of detail_kind='step' ---------------
    SELECT COALESCE(jsonb_agg(t ORDER BY (t->>'step_idx')::int), '[]'::jsonb)
      INTO v_steps
      FROM (
        SELECT jsonb_build_object(
                 'mdo_id',      m.mdo_id,
                 'step_idx',    COALESCE(m.ordinal, 0),
                 'title',       m.title,
                 'action_class', m.body_jsonb ->> 'action_class',
                 'actor',       m.body_jsonb ->> 'actor',
                 'tool',        m.body_jsonb ->> 'tool',
                 'outcome',     m.body_jsonb ->> 'outcome',
                 'started_at',  m.body_jsonb ->> 'started_at',
                 'ended_at',    m.body_jsonb ->> 'ended_at',
                 'exception',   m.body_jsonb ->> 'exception',
                 'payload',     m.body_jsonb) AS t
        FROM malu$memory_detail_object m
        WHERE m.episode_id  = p_episode_id
          AND m.detail_kind = 'step') ss;

    -- ---------- supporting evidence: claims + facts + memories ------
    --
    -- Selection rules per mode:
    --   current_valid: lifecycle_state='active' AND valid_time_range
    --                  contains now()
    --   historical:    valid_time_range contains v_anchor
    --   as_of_transaction_time: transaction_time_range contains v_anchor
    --   full_bitemporal: everything, no filter
    --
    -- A row is associated with the episode when any of:
    --   - it shares the episode's subject (via SVPOR text columns)
    --   - it is reachable via malu$relationship_edge from the episode
    --
    -- v1 implements the SVPOR subject match; the relationship_edge
    -- traversal lands in a later refinement.
    --
    -- Objects EXCLUDED for non-RLS reasons increment hidden_by_policy.

    WITH episode_subject AS (
        SELECT COALESCE(v_episode.payload_jsonb ->> 'subject_class',
                        v_episode.episode_kind) AS subj
    ),
    related_claims AS (
        SELECT c.claim_id, c.subject, c.verb, c.statement_text,
               c.source_package_id, c.valid_time_start, c.valid_time_end,
               c.transaction_time_start,
               CASE
                 WHEN p_mode = 'current_valid'
                   THEN (c.retracted_at IS NULL
                         AND c.valid_time_range @> now()
                         AND c.transaction_time_end IS NULL)
                 WHEN p_mode = 'historical'
                   THEN (c.valid_time_range @> v_anchor)
                 WHEN p_mode = 'as_of_transaction_time'
                   THEN (c.transaction_time_range @> v_anchor)
                 ELSE true
               END AS included
        FROM malu$claim c, episode_subject e
        WHERE c.subject = e.subj
           OR EXISTS (
              SELECT 1 FROM malu$memory_detail_object m
              WHERE m.episode_id = p_episode_id
                AND m.body_jsonb ? 'claim_id'
                AND (m.body_jsonb ->> 'claim_id')::bigint = c.claim_id)
    ),
    related_facts AS (
        SELECT f.fact_id, f.subject, f.verb, f.statement_text,
               f.lifecycle_state,
               f.valid_time_start, f.valid_time_end,
               f.transaction_time_start,
               CASE
                 WHEN p_mode = 'current_valid'
                   THEN (f.lifecycle_state = 'active'
                         AND f.valid_time_range @> now()
                         AND f.transaction_time_end IS NULL
                         AND f.superseded_at IS NULL)
                 WHEN p_mode = 'historical'
                   THEN (f.valid_time_range @> v_anchor)
                 WHEN p_mode = 'as_of_transaction_time'
                   THEN (f.transaction_time_range @> v_anchor)
                 ELSE true
               END AS included
        FROM malu$fact f, episode_subject e
        WHERE f.subject = e.subj
    ),
    unioned AS (
        SELECT 'claim'::text AS kind, c.claim_id AS object_id, c.subject, c.verb,
               c.statement_text, c.source_package_id,
               NULL::text AS lifecycle_state,
               c.valid_time_start, c.valid_time_end,
               c.transaction_time_start, c.included
        FROM related_claims c
        UNION ALL
        SELECT 'fact', f.fact_id, f.subject, f.verb,
               f.statement_text, NULL::bigint,
               f.lifecycle_state,
               f.valid_time_start, f.valid_time_end,
               f.transaction_time_start, f.included
        FROM related_facts f
    )
    SELECT
        COALESCE(jsonb_agg(jsonb_build_object(
            'kind', u.kind,
            'object_id', u.object_id,
            'subject', u.subject,
            'verb', u.verb,
            'statement_text', u.statement_text,
            'source_package_id', u.source_package_id,
            'lifecycle_state', u.lifecycle_state,
            'valid_time_start', u.valid_time_start,
            'valid_time_end',   u.valid_time_end,
            'transaction_time_start', u.transaction_time_start)
          ) FILTER (WHERE u.included),
          '[]'::jsonb),
        ARRAY(SELECT DISTINCT object_id FROM unioned WHERE kind='claim' AND included),
        ARRAY(SELECT DISTINCT object_id FROM unioned WHERE kind='fact'  AND included),
        count(*) FILTER (WHERE NOT u.included)
    INTO v_evidence, v_included_claims, v_included_facts, v_hidden_count
    FROM unioned u;

    -- Memories linked into this replay: those produced by MDOs of the
    -- episode (via parent linkage) or with subject match.
    SELECT ARRAY(
        SELECT DISTINCT m.memory_id
          FROM malu$memory m
         WHERE EXISTS (
            SELECT 1 FROM malu$memory_detail_object d
             WHERE d.episode_id = p_episode_id
               AND d.body_jsonb ? 'memory_id'
               AND (d.body_jsonb ->> 'memory_id')::bigint = m.memory_id))
      INTO v_included_memories;

    -- Source packages cited by any included claim, fact, or step MDO.
    SELECT ARRAY(
        SELECT DISTINCT spid FROM (
            SELECT source_package_id AS spid FROM malu$claim
             WHERE claim_id = ANY(v_included_claims) AND source_package_id IS NOT NULL
            UNION
            SELECT NULLIF(m.body_jsonb ->> 'source_package_id', '')::bigint
              FROM malu$memory_detail_object m
             WHERE m.episode_id = p_episode_id AND m.detail_kind = 'step'
        ) q WHERE spid IS NOT NULL)
      INTO v_source_pkgs;

    -- ---------- prior_belief: only set for as_of_transaction_time
    --             and full_bitemporal ----------------------------------
    IF p_mode IN ('as_of_transaction_time','full_bitemporal') THEN
        SELECT jsonb_build_object(
            'as_of', v_anchor,
            'fact_count_at_as_of',
              (SELECT count(*) FROM malu$fact
                WHERE subject = COALESCE(v_episode.payload_jsonb ->> 'subject_class',
                                         v_episode.episode_kind)
                  AND transaction_time_range @> v_anchor),
            'claim_count_at_as_of',
              (SELECT count(*) FROM malu$claim
                WHERE subject = COALESCE(v_episode.payload_jsonb ->> 'subject_class',
                                         v_episode.episode_kind)
                  AND transaction_time_range @> v_anchor))
          INTO v_prior_belief;
    ELSE
        v_prior_belief := NULL;
    END IF;

    -- ---------- later_changes: rows whose valid window closed AFTER
    --             the relevant "story-time" anchor.
    --
    -- Anchor semantics:
    --   current_valid / full_bitemporal → episode.occurred_at (or
    --     recorded_at): "what changed since the episode?"
    --   historical / as_of_transaction_time → v_anchor: "what changed
    --     after the point we're looking from?"
    -- =====================================================================
    v_later_anchor := CASE p_mode
        WHEN 'current_valid'   THEN COALESCE(v_episode.occurred_at, v_episode.recorded_at)
        WHEN 'full_bitemporal' THEN COALESCE(v_episode.occurred_at, v_episode.recorded_at)
        ELSE v_anchor
    END;

    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'kind',       kind,
        'object_id',  object_id,
        'event',      event,
        'happened_at', happened_at)), '[]'::jsonb)
      INTO v_later_changes
      FROM (
        SELECT 'fact'::text AS kind, f.fact_id AS object_id,
               'superseded'::text AS event, f.superseded_at AS happened_at
          FROM malu$fact f
         WHERE f.subject = COALESCE(v_episode.payload_jsonb ->> 'subject_class',
                                    v_episode.episode_kind)
           AND f.superseded_at IS NOT NULL
           AND f.superseded_at > v_later_anchor
        UNION ALL
        SELECT 'claim', c.claim_id, 'retracted', c.retracted_at
          FROM malu$claim c
         WHERE c.subject = COALESCE(v_episode.payload_jsonb ->> 'subject_class',
                                    v_episode.episode_kind)
           AND c.retracted_at IS NOT NULL
           AND c.retracted_at > v_later_anchor
        UNION ALL
        SELECT 'fact', f.fact_id, 'valid_window_closed', f.valid_time_end
          FROM malu$fact f
         WHERE f.subject = COALESCE(v_episode.payload_jsonb ->> 'subject_class',
                                    v_episode.episode_kind)
           AND f.valid_time_end IS NOT NULL
           AND f.valid_time_end > v_later_anchor) x;

    -- ---------- assemble envelope -----------------------------------
    v_envelope := jsonb_build_object(
        'episode_id',             p_episode_id,
        'mode',                   p_mode,
        'as_of',                  v_anchor,
        'temporal_mode_used',     p_mode,
        'episode', jsonb_build_object(
            'episode_id',    v_episode.episode_id,
            'episode_kind',  v_episode.episode_kind,
            'title',         v_episode.title,
            'summary',       v_episode.summary,
            'occurred_at',   v_episode.occurred_at,
            'occurred_until', v_episode.occurred_until,
            'recorded_at',   v_episode.recorded_at,
            'lifecycle_state', v_episode.lifecycle_state,
            'sensitivity',   v_episode.sensitivity,
            'payload_jsonb', v_episode.payload_jsonb),
        'what_happened', jsonb_build_object(
            'title',         v_episode.title,
            'summary',       v_episode.summary,
            'occurred_at',   v_episode.occurred_at,
            'payload_jsonb', v_episode.payload_jsonb),
        'steps',                  v_steps,
        'supporting_evidence',    v_evidence,
        'later_changes',          v_later_changes,
        'source_packages_inspected',
            to_jsonb(COALESCE(v_source_pkgs, ARRAY[]::bigint[])),
        'included_object_ids', jsonb_build_object(
            'claim',  to_jsonb(COALESCE(v_included_claims, ARRAY[]::bigint[])),
            'fact',   to_jsonb(COALESCE(v_included_facts, ARRAY[]::bigint[])),
            'memory', to_jsonb(COALESCE(v_included_memories, ARRAY[]::bigint[]))),
        'hidden_by_policy_count', v_hidden_count);

    IF v_prior_belief IS NOT NULL THEN
        v_envelope := v_envelope || jsonb_build_object('prior_belief', v_prior_belief);
    END IF;

    INSERT INTO malu$episode_replay
        (episode_id, mode, as_of, envelope_jsonb)
    VALUES (p_episode_id, p_mode, v_anchor, v_envelope)
    RETURNING replay_id INTO v_replay_id;

    PERFORM audit_event('episode_replayed', 'episode_object', p_episode_id,
        jsonb_build_object(
            'replay_id',   v_replay_id,
            'mode',        p_mode,
            'as_of',       v_anchor,
            'evidence_count',
                jsonb_array_length(v_evidence),
            'source_packages_inspected',
                cardinality(COALESCE(v_source_pkgs, ARRAY[]::bigint[])),
            'hidden_by_policy_count', v_hidden_count));

    RETURN v_envelope;
END;
$body$;

GRANT EXECUTE ON FUNCTION
    replay_episode(bigint, text, timestamptz)
TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;

-- =====================================================================
-- Stage-boundary roadmap update: malu$episode_replay now landed.
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
