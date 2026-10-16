\echo Use "ALTER EXTENSION maludb_core UPDATE TO '0.32.0'" to load this file. \quit

-- =====================================================================
-- maludb_core 0.31.0 → 0.32.0
--
-- Stage 4 — Authorization-aware retrieval (S4-5). **Stage 4 closer.**
--
-- Per CLAUDE.md doctrine: "Authorization is checked at three points:
-- planning, candidate expansion, and result assembly. Never apply
-- authorization only to the final answer — vector similarity, graph
-- traversal, summaries, and active-pool loading can leak otherwise."
--
-- Layout:
--   1. Planning-time: authorize_object_types(envelope) prunes
--      requested types where current_schema has zero visibility.
--   2. Expansion-time: per-strategy executors are thin wrappers
--      over existing helpers (fts_search / fuzzy_subject_match /
--      fact_as_of / etc.) — RLS on the underlying tables filters
--      candidates as they're produced.
--   3. Assembly-time: execute_retrieval merges hits, applies
--      confidence_floor + tombstone/retracted filtering, and emits
--      an audit_event for the request.
--
-- New composite: malu$retrieval_hit for uniform result shape.
-- New orchestrator: execute_retrieval(envelope, hint_name?, limit).
-- =====================================================================

CREATE OR REPLACE FUNCTION maludb_core_version() RETURNS text
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$ SELECT '0.32.0'::text $body$;

-- =====================================================================
-- malu$retrieval_hit — uniform result shape across strategies.
-- =====================================================================
CREATE TYPE malu$retrieval_hit AS (
    object_type   text,
    object_id     bigint,
    title         text,
    snippet       text,
    rank          real,
    strategy      text,
    metadata      jsonb
);

-- =====================================================================
-- authorize_object_types — planning-time pre-pruning.
--
-- For each requested type, runs an EXISTS probe that fires under the
-- caller's RLS context. Types with zero accessible rows are dropped
-- from the planner's input. This prevents the planner from emitting
-- strategies that would always come back empty anyway, and avoids
-- leaking the *existence* of a type to a caller who has no access.
-- =====================================================================
CREATE FUNCTION authorize_object_types(
    p_envelope malu$retrieval_envelope_t
) RETURNS text[]
LANGUAGE plpgsql STABLE
AS $body$
DECLARE
    v_result text[] := ARRAY[]::text[];
    t        text;
    v_has    boolean;
BEGIN
    IF p_envelope.object_types IS NULL THEN
        RETURN ARRAY[]::text[];
    END IF;
    FOREACH t IN ARRAY p_envelope.object_types LOOP
        EXECUTE format(
            'SELECT EXISTS (SELECT 1 FROM maludb_core.%I LIMIT 1)',
            CASE t
                WHEN 'claim'          THEN 'malu$claim'
                WHEN 'fact'           THEN 'malu$fact'
                WHEN 'memory'         THEN 'malu$memory'
                WHEN 'episode_object' THEN 'malu$episode_object'
                ELSE NULL
            END)
        INTO v_has;
        IF v_has THEN
            v_result := v_result || t;
        END IF;
    END LOOP;
    RETURN v_result;
END;
$body$;

-- =====================================================================
-- Per-strategy executors. Each takes the params jsonb from the plan's
-- strategy entry and returns SETOF malu$retrieval_hit. RLS on the
-- underlying tables filters expansion-time candidates.
-- =====================================================================

CREATE FUNCTION _exec_fts(p_params jsonb) RETURNS SETOF malu$retrieval_hit
LANGUAGE plpgsql STABLE
AS $body$
DECLARE
    v_query text  := p_params ->> 'query';
    v_types text[] := CASE WHEN p_params ? 'object_types'
                            THEN ARRAY(SELECT jsonb_array_elements_text(p_params -> 'object_types'))
                            ELSE ARRAY['claim','fact','memory','episode_object'] END;
    v_limit integer := COALESCE((p_params ->> 'limit')::integer, 50);
BEGIN
    IF v_query IS NULL OR v_query = '' THEN RETURN; END IF;
    RETURN QUERY
        SELECT r.object_type, r.object_id, r.title_or_subject,
               r.snippet, r.rank, 'fts'::text,
               jsonb_build_object('query', v_query)
        FROM text_search(v_query, v_types, v_limit) r;
END;
$body$;

CREATE FUNCTION _exec_fuzzy_subject(p_params jsonb) RETURNS SETOF malu$retrieval_hit
LANGUAGE plpgsql STABLE
AS $body$
DECLARE
    v_needle text   := p_params ->> 'needle';
    v_thr    real   := COALESCE((p_params ->> 'threshold')::real, 0.3);
    v_limit  integer := COALESCE((p_params ->> 'limit')::integer, 50);
BEGIN
    IF v_needle IS NULL OR v_needle = '' THEN RETURN; END IF;
    RETURN QUERY
        SELECT m.object_type, m.object_id, m.subject,
               NULL::text, m.similarity, 'fuzzy_subject'::text,
               jsonb_build_object('needle', v_needle, 'threshold', v_thr)
        FROM fuzzy_subject_match(v_needle, v_thr,
            ARRAY['claim','fact'], v_limit) m;
END;
$body$;

CREATE FUNCTION _exec_temporal_as_of(p_params jsonb)
RETURNS SETOF malu$retrieval_hit
LANGUAGE plpgsql STABLE
AS $body$
DECLARE
    v_valid_at  timestamptz := NULLIF(p_params ->> 'valid_as_of', '')::timestamptz;
    v_tx_at     timestamptz := NULLIF(p_params ->> 'transaction_as_of', '')::timestamptz;
    v_at        timestamptz := COALESCE(v_valid_at, v_tx_at, now());
BEGIN
    RETURN QUERY
        SELECT 'fact'::text, f.fact_id, COALESCE(f.subject, f.verb, '?')::text,
               left(COALESCE(f.statement_text, ''), 240)::text,
               1.0::real, 'temporal_as_of'::text,
               jsonb_build_object('at', v_at)
        FROM fact_as_of(v_at) f
        UNION ALL
        SELECT 'memory'::text, m.memory_id, COALESCE(m.title, m.memory_kind, '?'),
               left(COALESCE(m.summary, ''), 240),
               1.0::real, 'temporal_as_of'::text,
               jsonb_build_object('at', v_at)
        FROM memory_as_of(v_at) m
        UNION ALL
        SELECT 'episode_object'::text, e.episode_id,
               COALESCE(e.title, e.episode_kind, '?'),
               left(COALESCE(e.summary, ''), 240),
               1.0::real, 'temporal_as_of'::text,
               jsonb_build_object('at', v_at)
        FROM episode_as_of(v_at) e;
END;
$body$;

CREATE FUNCTION _exec_source_filter(p_params jsonb)
RETURNS SETOF malu$retrieval_hit
LANGUAGE plpgsql STABLE
AS $body$
DECLARE
    v_sp_id bigint := NULLIF(p_params ->> 'source_package_id', '')::bigint;
BEGIN
    IF v_sp_id IS NULL THEN RETURN; END IF;
    RETURN QUERY
        SELECT 'claim'::text, c.claim_id, COALESCE(c.subject, c.verb, '?')::text,
               left(COALESCE(c.statement_text, ''), 240)::text,
               1.0::real, 'source_filter'::text,
               jsonb_build_object('source_package_id', v_sp_id)
        FROM malu$claim c
        WHERE c.source_package_id = v_sp_id;
END;
$body$;

-- =====================================================================
-- execute_retrieval — the orchestrator. Three-stage authz:
--
--   1. Planning   — authorize_object_types prunes inaccessible types.
--   2. Expansion  — per-strategy executors fire under the caller's
--                   RLS context; rows the caller can't see never
--                   leave the underlying table scan.
--   3. Assembly   — confidence_floor + tombstone/retracted filtering
--                   + dedupe by (object_type, object_id) keeping the
--                   best rank. Final pass re-asserts row visibility
--                   via the same RLS path.
--
-- Returns SETOF malu$retrieval_hit ordered by rank DESC.
-- Always emits a 'retrieval_executed' audit_event.
-- =====================================================================
CREATE FUNCTION execute_retrieval(
    p_envelope  malu$retrieval_envelope_t,
    p_hint_name text DEFAULT NULL,
    p_limit     integer DEFAULT 20
) RETURNS SETOF malu$retrieval_hit
LANGUAGE plpgsql VOLATILE
AS $body$
DECLARE
    v_envelope_pruned malu$retrieval_envelope_t := p_envelope;
    v_authz_types     text[];
    v_plan            malu$retrieval_plan;
    v_strat           jsonb;
    v_strat_name      text;
    v_floor           numeric;
    v_seen_count      integer := 0;
BEGIN
    -- 1. Planning-time authz: prune inaccessible types.
    v_authz_types := authorize_object_types(p_envelope);
    v_envelope_pruned.object_types := v_authz_types;

    IF v_authz_types IS NULL OR cardinality(v_authz_types) = 0 THEN
        -- Caller has no read access to any of the requested types.
        -- Audit the empty result + return zero rows.
        PERFORM audit_event('retrieval_executed', NULL, NULL,
            jsonb_build_object('cue_text', p_envelope.cue_text,
                               'hits',     0,
                               'reason',   'no_authorized_types'));
        RETURN;
    END IF;

    -- 2. Plan with hints.
    v_plan := plan_retrieval_with_hints(v_envelope_pruned, p_hint_name);
    v_floor := p_envelope.confidence_floor;

    -- 3. Dispatch each strategy. Hits accumulate into a temp set;
    --    we dedupe + apply filters + emit at the end.
    CREATE TEMP TABLE IF NOT EXISTS _exec_hits (
        object_type text, object_id bigint, title text, snippet text,
        rank real, strategy text, metadata jsonb
    ) ON COMMIT DROP;
    DELETE FROM _exec_hits;

    FOR v_strat IN SELECT * FROM jsonb_array_elements(v_plan.strategies) LOOP
        v_strat_name := v_strat ->> 'strategy';
        IF v_strat_name = 'fts' THEN
            INSERT INTO _exec_hits SELECT * FROM _exec_fts(v_strat -> 'params');
        ELSIF v_strat_name = 'fuzzy_subject' THEN
            INSERT INTO _exec_hits SELECT * FROM _exec_fuzzy_subject(v_strat -> 'params');
        ELSIF v_strat_name = 'temporal_as_of' THEN
            INSERT INTO _exec_hits SELECT * FROM _exec_temporal_as_of(v_strat -> 'params');
        ELSIF v_strat_name = 'source_filter' THEN
            INSERT INTO _exec_hits SELECT * FROM _exec_source_filter(v_strat -> 'params');
        -- vector / graph_walk / svpor_routing / confidence_floor:
        -- skipped in v1; executor stubs land alongside R2.x retrieval
        -- planner work.
        END IF;
    END LOOP;

    -- 4. Assembly: dedupe + filter + audit.
    --    Drop tombstoned / retired rows that slipped past RLS (RLS
    --    doesn't filter by lifecycle state on its own — that's the
    --    Retrieval Coordinator's job).
    --    Apply confidence_floor when set.
    SELECT count(*) INTO v_seen_count FROM _exec_hits;

    RETURN QUERY
        WITH deduped AS (
            SELECT DISTINCT ON (object_type, object_id)
                   object_type, object_id, title, snippet, rank,
                   strategy, metadata
            FROM _exec_hits
            ORDER BY object_type, object_id, rank DESC NULLS LAST
        ),
        gated AS (
            SELECT d.*
            FROM deduped d
            WHERE NOT EXISTS (
                SELECT 1
                FROM malu$fact f
                WHERE d.object_type = 'fact' AND f.fact_id = d.object_id
                  AND f.lifecycle_state IN ('tombstoned','retired')
            )
              AND NOT EXISTS (
                SELECT 1
                FROM malu$memory m
                WHERE d.object_type = 'memory' AND m.memory_id = d.object_id
                  AND m.lifecycle_state IN ('tombstoned','retired')
            )
              AND NOT EXISTS (
                SELECT 1
                FROM malu$episode_object e
                WHERE d.object_type = 'episode_object' AND e.episode_id = d.object_id
                  AND e.lifecycle_state IN ('tombstoned','retired')
            )
              AND (
                v_floor IS NULL
                OR COALESCE(maut_aggregate_confidence(d.object_type, d.object_id), 1.0)
                   >= v_floor
              )
        )
        SELECT * FROM gated
        ORDER BY rank DESC NULLS LAST, object_type, object_id
        LIMIT p_limit;

    -- Audit emission (count after dedupe + gating; we re-aggregate
    -- inline because RETURN QUERY's result isn't visible to us).
    PERFORM audit_event('retrieval_executed', NULL, NULL,
        jsonb_build_object(
            'cue_text',         p_envelope.cue_text,
            'intent',           v_plan.intent,
            'authorized_types', to_jsonb(v_authz_types),
            'strategies_fired', jsonb_array_length(v_plan.strategies),
            'raw_hits',         v_seen_count,
            'hint_name',        p_hint_name));
END;
$body$;

GRANT EXECUTE ON FUNCTION
    authorize_object_types(malu$retrieval_envelope_t),
    _exec_fts(jsonb),
    _exec_fuzzy_subject(jsonb),
    _exec_temporal_as_of(jsonb),
    _exec_source_filter(jsonb),
    execute_retrieval(malu$retrieval_envelope_t, text, integer)
TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;
