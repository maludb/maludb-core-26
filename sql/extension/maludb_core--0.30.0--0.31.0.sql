\echo Use "ALTER EXTENSION maludb_core UPDATE TO '0.31.0'" to load this file. \quit

-- =====================================================================
-- maludb_core 0.30.0 → 0.31.0
--
-- Stage 4 — Query-hint API (S4-4).
--
-- Per requirements.md §9 Stage 4: "Query-hint API."
--
-- Builds on S4-3 (retrieval planner). Hints rewrite the planner's
-- output: reorder strategies, suppress paths, override the intent
-- classifier's verdict, layer in extra envelope constraints
-- (confidence floor, time-as-of).
--
-- Surface:
--   * malu$query_hint — named hint storage with RLS by owner_schema.
--   * register_query_hint(name, jsonb, desc?) — upsert.
--   * apply_hints(plan, hints) → plan — pure transformer over a
--                                        retrieval plan.
--   * plan_retrieval_with_hints(envelope, hint_name?) → plan —
--                                        composes plan_retrieval +
--                                        apply_hints + audit.
--
-- Hint directives (top-level keys in hint_jsonb):
--   "force_path"            — text[]; reorder strategies so listed
--                              names come first in this order.
--   "suppress_path"         — text[]; drop these strategy names.
--   "intent_override"       — text; force intent and re-derive
--                              strategies for it (S4-3 select_
--                              search_paths is invoked again).
--   "confidence_floor_override" — numeric; override envelope
--                              confidence_floor.
--   "time_constraint_override"  — jsonb {valid_as_of?, transaction_as_of?};
--                              merged into the envelope before
--                              re-planning.
--   "boost_weight"          — jsonb {strategy: weight}; the strategy
--                              params get a `boost` numeric field.
--
-- Each application emits an audit_event so reviewers can spot when
-- hints overrode planner output.
-- =====================================================================

CREATE OR REPLACE FUNCTION maludb_core_version() RETURNS text
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$ SELECT '0.31.0'::text $body$;

-- =====================================================================
-- malu$query_hint
-- =====================================================================
CREATE TABLE malu$query_hint (
    hint_id        bigserial PRIMARY KEY,
    owner_schema   name NOT NULL DEFAULT current_schema(),
    hint_name      text NOT NULL,
    hint_jsonb     jsonb NOT NULL,
    description    text,
    enabled        boolean NOT NULL DEFAULT true,
    created_at     timestamptz NOT NULL DEFAULT now(),
    updated_at     timestamptz NOT NULL DEFAULT now(),
    UNIQUE (owner_schema, hint_name)
);

ALTER TABLE malu$query_hint ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_owner ON malu$query_hint
    USING (owner_schema = current_schema())
    WITH CHECK (owner_schema = current_schema());

GRANT SELECT ON malu$query_hint TO
    maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;
GRANT INSERT, UPDATE, DELETE ON malu$query_hint TO
    maludb_memory_admin, maludb_memory_executor;
GRANT USAGE, SELECT ON SEQUENCE malu$query_hint_hint_id_seq TO
    maludb_memory_admin, maludb_memory_executor;

-- =====================================================================
-- register_query_hint — upsert.
-- =====================================================================
CREATE FUNCTION register_query_hint(
    p_hint_name    text,
    p_hint_jsonb   jsonb,
    p_description  text DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql
AS $body$
DECLARE v_id bigint;
BEGIN
    INSERT INTO malu$query_hint
        (hint_name, hint_jsonb, description)
    VALUES (p_hint_name, p_hint_jsonb, p_description)
    ON CONFLICT (owner_schema, hint_name) DO UPDATE
        SET hint_jsonb  = EXCLUDED.hint_jsonb,
            description = COALESCE(EXCLUDED.description, malu$query_hint.description),
            updated_at  = now()
    RETURNING hint_id INTO v_id;
    RETURN v_id;
END;
$body$;

-- =====================================================================
-- apply_hints — pure transformer over a retrieval plan.
--
-- The order matters: intent_override + envelope-mutating hints run
-- FIRST (because they change which strategies get derived); then
-- force_path / suppress_path / boost_weight rewrite the strategy
-- list. Returns the new plan.
--
-- p_hints NULL or empty: returns p_plan unchanged.
-- =====================================================================
CREATE FUNCTION apply_hints(
    p_plan  malu$retrieval_plan,
    p_hints jsonb
) RETURNS malu$retrieval_plan
LANGUAGE plpgsql STABLE
AS $body$
DECLARE
    v_intent          text;
    v_strategies      jsonb;
    v_envelope_jsonb  jsonb;
    v_envelope        malu$retrieval_envelope_t;
    v_replan          boolean := false;
    v_forced          text[];
    v_suppressed      text[];
    v_boosts          jsonb;
    v_idx             integer;
    v_forced_one      text;
    v_strat           jsonb;
    v_remainder       jsonb;
    v_ordered         jsonb;
BEGIN
    IF p_hints IS NULL OR jsonb_typeof(p_hints) <> 'object'
       OR p_hints = '{}'::jsonb THEN
        RETURN p_plan;
    END IF;

    v_intent         := p_plan.intent;
    v_strategies     := p_plan.strategies;
    v_envelope_jsonb := p_plan.envelope;

    -- ---- envelope mutations -----------------------------------------
    IF p_hints ? 'confidence_floor_override' THEN
        v_envelope_jsonb := v_envelope_jsonb ||
            jsonb_build_object('confidence_floor', p_hints -> 'confidence_floor_override');
        v_replan := true;
    END IF;
    IF p_hints ? 'time_constraint_override' THEN
        v_envelope_jsonb := v_envelope_jsonb ||
            (p_hints -> 'time_constraint_override');
        v_replan := true;
    END IF;

    -- ---- intent override --------------------------------------------
    IF p_hints ? 'intent_override' THEN
        v_intent := p_hints ->> 'intent_override';
        v_replan := true;
    END IF;

    -- ---- re-derive strategies if needed -----------------------------
    IF v_replan THEN
        v_envelope := ROW(
            v_envelope_jsonb ->> 'cue_text',
            CASE WHEN v_envelope_jsonb ? 'object_types'
                 THEN ARRAY(SELECT jsonb_array_elements_text(v_envelope_jsonb -> 'object_types'))
                 ELSE ARRAY['claim','fact','memory','episode_object']::text[] END,
            NULLIF(v_envelope_jsonb ->> 'valid_as_of', '')::timestamptz,
            NULLIF(v_envelope_jsonb ->> 'transaction_as_of', '')::timestamptz,
            NULLIF(v_envelope_jsonb ->> 'confidence_floor', '')::numeric,
            v_envelope_jsonb -> 'hints'
        )::malu$retrieval_envelope_t;
        v_strategies := select_search_paths(v_intent, v_envelope, p_plan.cues);
    END IF;

    -- ---- suppress_path ----------------------------------------------
    IF p_hints ? 'suppress_path' THEN
        v_suppressed := ARRAY(SELECT jsonb_array_elements_text(p_hints -> 'suppress_path'));
        v_strategies := COALESCE(
            (SELECT jsonb_agg(s)
             FROM jsonb_array_elements(v_strategies) s
             WHERE NOT (s ->> 'strategy' = ANY(v_suppressed))),
            '[]'::jsonb);
    END IF;

    -- ---- force_path: reorder so listed names come first -------------
    IF p_hints ? 'force_path' THEN
        v_forced := ARRAY(SELECT jsonb_array_elements_text(p_hints -> 'force_path'));
        v_ordered := '[]'::jsonb;
        -- 1. emit forced strategies in the listed order, if present
        FOREACH v_forced_one IN ARRAY v_forced LOOP
            FOR v_strat IN
                SELECT s FROM jsonb_array_elements(v_strategies) s
                WHERE s ->> 'strategy' = v_forced_one
            LOOP
                v_ordered := v_ordered || jsonb_build_array(v_strat);
            END LOOP;
        END LOOP;
        -- 2. then append everything not in the forced list
        v_remainder := COALESCE(
            (SELECT jsonb_agg(s)
             FROM jsonb_array_elements(v_strategies) s
             WHERE NOT (s ->> 'strategy' = ANY(v_forced))),
            '[]'::jsonb);
        v_strategies := v_ordered || v_remainder;
    END IF;

    -- ---- boost_weight: annotate listed strategies -------------------
    IF p_hints ? 'boost_weight' AND jsonb_typeof(p_hints -> 'boost_weight') = 'object' THEN
        v_boosts := p_hints -> 'boost_weight';
        v_ordered := '[]'::jsonb;
        FOR v_idx IN 0 .. jsonb_array_length(v_strategies) - 1 LOOP
            v_strat := v_strategies -> v_idx;
            IF v_boosts ? (v_strat ->> 'strategy') THEN
                v_strat := v_strat || jsonb_build_object(
                    'boost', v_boosts -> (v_strat ->> 'strategy'));
            END IF;
            v_ordered := v_ordered || jsonb_build_array(v_strat);
        END LOOP;
        v_strategies := v_ordered;
    END IF;

    RETURN ROW(v_intent, p_plan.cues, v_strategies, v_envelope_jsonb)::malu$retrieval_plan;
END;
$body$;

-- =====================================================================
-- plan_retrieval_with_hints — top-level entry.
--
-- Composition order:
--   1. plan_retrieval(envelope) — base plan
--   2. apply_hints with the envelope's inline hints (if any)
--   3. apply_hints with the stored named hint (if name supplied)
--
-- Emits an audit_event when the resulting plan differs from the
-- base plan, so reviewers can spot hint-driven changes.
-- =====================================================================
CREATE FUNCTION plan_retrieval_with_hints(
    p_envelope  malu$retrieval_envelope_t,
    p_hint_name text DEFAULT NULL
) RETURNS malu$retrieval_plan
LANGUAGE plpgsql STABLE
AS $body$
DECLARE
    v_base   malu$retrieval_plan;
    v_plan   malu$retrieval_plan;
    v_stored jsonb;
BEGIN
    v_base := plan_retrieval(p_envelope);
    v_plan := v_base;

    IF p_envelope.hints IS NOT NULL THEN
        v_plan := apply_hints(v_plan, p_envelope.hints);
    END IF;

    IF p_hint_name IS NOT NULL THEN
        SELECT hint_jsonb INTO v_stored
        FROM malu$query_hint
        WHERE hint_name = p_hint_name AND enabled = true;
        IF v_stored IS NULL THEN
            RAISE EXCEPTION 'plan_retrieval_with_hints: unknown or disabled hint %', p_hint_name
                USING ERRCODE = 'no_data_found';
        END IF;
        v_plan := apply_hints(v_plan, v_stored);
    END IF;

    -- Audit when the plan was actually rewritten
    IF v_plan.intent      IS DISTINCT FROM v_base.intent
       OR v_plan.strategies IS DISTINCT FROM v_base.strategies THEN
        PERFORM audit_event('plan_hints_applied', NULL, NULL,
            jsonb_build_object(
                'hint_name',     p_hint_name,
                'before_intent', v_base.intent,
                'after_intent',  v_plan.intent,
                'before_strategies', v_base.strategies,
                'after_strategies',  v_plan.strategies));
    END IF;

    RETURN v_plan;
END;
$body$;

GRANT EXECUTE ON FUNCTION
    register_query_hint(text, jsonb, text),
    apply_hints(malu$retrieval_plan, jsonb),
    plan_retrieval_with_hints(malu$retrieval_envelope_t, text)
TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;
