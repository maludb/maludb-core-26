\echo Use "ALTER EXTENSION maludb_core UPDATE TO '0.30.0'" to load this file. \quit

-- =====================================================================
-- maludb_core 0.29.0 → 0.30.0
--
-- Stage 4 — Retrieval planner (S4-3).
--
-- Per requirements.md §9 Stage 4: "Retrieval planner: envelope, cue
-- extraction, intent classification, search-path selection."
--
-- Pipeline:
--   1. envelope     — input bundle (cue text + filters + hints).
--   2. extract_cues — tokenise the cue text and resolve tokens
--                     against the SVPOR registries (subject / verb /
--                     predicate). Quoted phrases, time markers,
--                     and unresolved terms are returned as separate
--                     cue kinds.
--   3. classify_intent — closed taxonomy: recall, narrow, broad,
--                     time_as_of, by_source, by_confidence.
--   4. select_search_paths — ordered list of strategies the
--                     retrieval executor should try.
--   5. plan_retrieval — composes the above; returns one
--                     malu$retrieval_plan composite.
--
-- malu$retrieval_envelope stores envelopes for replay / debugging
-- — operators write the persistent row separately when needed.
-- =====================================================================

CREATE OR REPLACE FUNCTION maludb_core_version() RETURNS text
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$ SELECT '0.30.0'::text $body$;

-- =====================================================================
-- Composite types
-- =====================================================================
CREATE TYPE malu$retrieval_envelope_t AS (
    cue_text           text,
    object_types       text[],
    valid_as_of        timestamptz,
    transaction_as_of  timestamptz,
    confidence_floor   numeric,
    hints              jsonb
);

CREATE TYPE malu$retrieval_cue AS (
    cue_kind   text,
    cue_value  text,
    cue_ref_id bigint,
    weight     numeric
);

CREATE TYPE malu$retrieval_plan AS (
    intent      text,
    cues        jsonb,
    strategies  jsonb,
    envelope    jsonb
);

-- =====================================================================
-- malu$retrieval_envelope — optional persisted record for replay
-- =====================================================================
CREATE TABLE malu$retrieval_envelope (
    envelope_id        bigserial PRIMARY KEY,
    owner_schema       name NOT NULL DEFAULT current_schema(),
    cue_text           text NOT NULL,
    object_types       text[] NOT NULL DEFAULT ARRAY['claim','fact','memory','episode_object'],
    valid_as_of        timestamptz,
    transaction_as_of  timestamptz,
    confidence_floor   numeric(5,4),
    hints              jsonb,
    plan_jsonb         jsonb,
    actor_role         name NOT NULL DEFAULT current_user,
    created_at         timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX malu$retrieval_envelope_actor_idx
    ON malu$retrieval_envelope(actor_role, created_at DESC);

ALTER TABLE malu$retrieval_envelope ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_owner ON malu$retrieval_envelope
    USING (owner_schema = current_schema())
    WITH CHECK (owner_schema = current_schema());

GRANT SELECT ON malu$retrieval_envelope TO
    maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;
GRANT INSERT ON malu$retrieval_envelope TO
    maludb_memory_admin, maludb_memory_executor;
GRANT USAGE, SELECT ON SEQUENCE malu$retrieval_envelope_envelope_id_seq TO
    maludb_memory_admin, maludb_memory_executor;

-- =====================================================================
-- extract_cues — heuristic tokenizer.
--
-- Cue kinds emitted:
--   'phrase'      — quoted phrase ("…")
--   'time_marker' — "as of <ISO>" / "before <ISO>" / "after <ISO>"
--   'subject'     — token resolved against malu$svpor_subject
--                   (canonical or alias)
--   'verb'        — same against malu$svpor_verb
--   'predicate'   — same against malu$svpor_predicate
--   'term'        — unresolved token; rough recall hint
--
-- Weight defaults to 1.0; phrases get 2.0; time markers 0.5.
-- =====================================================================
CREATE FUNCTION extract_cues(p_cue_text text)
RETURNS SETOF malu$retrieval_cue
LANGUAGE plpgsql STABLE
AS $body$
DECLARE
    v_text     text := COALESCE(p_cue_text, '');
    v_phrase   text;
    v_tm_match text[];
    v_token    text;
    v_id       bigint;
BEGIN
    -- 1. Quoted phrases
    FOR v_phrase IN
        SELECT (regexp_matches(v_text, '"([^"]+)"', 'g'))[1]
    LOOP
        RETURN NEXT ROW('phrase', v_phrase, NULL, 2.0)::malu$retrieval_cue;
    END LOOP;
    -- Strip phrases from the working text so they don't tokenize again
    v_text := regexp_replace(v_text, '"[^"]+"', '', 'g');

    -- 2. Time markers — match the keyword + ISO-ish date.
    FOR v_tm_match IN
        SELECT regexp_matches(
            v_text,
            '\m(as of|before|after)\s+(\d{4}-\d{2}-\d{2}(?:T\d{2}:\d{2}(?::\d{2})?Z?)?)',
            'gi')
    LOOP
        RETURN NEXT ROW('time_marker',
                        v_tm_match[1] || ' ' || v_tm_match[2],
                        NULL, 0.5)::malu$retrieval_cue;
    END LOOP;
    v_text := regexp_replace(v_text,
        '\m(as of|before|after)\s+\d{4}-\d{2}-\d{2}(?:T\d{2}:\d{2}(?::\d{2})?Z?)?',
        '', 'gi');

    -- 3. Tokens — split on whitespace and basic punctuation.
    FOR v_token IN
        SELECT lower(unnest(regexp_split_to_array(trim(v_text), '[[:space:],;:!?]+')))
    LOOP
        v_token := trim(v_token);
        IF v_token = '' THEN CONTINUE; END IF;

        -- Try SVPOR registries in order: subject, verb, predicate.
        v_id := resolve_svpor_subject(v_token);
        IF v_id IS NOT NULL THEN
            RETURN NEXT ROW('subject', v_token, v_id, 1.5)::malu$retrieval_cue;
            CONTINUE;
        END IF;
        v_id := resolve_svpor_verb(v_token);
        IF v_id IS NOT NULL THEN
            RETURN NEXT ROW('verb', v_token, v_id, 1.5)::malu$retrieval_cue;
            CONTINUE;
        END IF;
        v_id := resolve_svpor_predicate(v_token);
        IF v_id IS NOT NULL THEN
            RETURN NEXT ROW('predicate', v_token, v_id, 1.5)::malu$retrieval_cue;
            CONTINUE;
        END IF;

        -- Fallback: generic term
        RETURN NEXT ROW('term', v_token, NULL, 1.0)::malu$retrieval_cue;
    END LOOP;
END;
$body$;

-- =====================================================================
-- classify_intent — pick from the closed taxonomy.
--
-- Order matters: explicit constraints win over heuristics on the
-- cue text.
-- =====================================================================
CREATE FUNCTION classify_intent(p_envelope malu$retrieval_envelope_t)
RETURNS text
LANGUAGE plpgsql STABLE
AS $body$
DECLARE
    v_lower      text := lower(COALESCE(p_envelope.cue_text, ''));
    v_cue_count  integer;
    v_svpor_count integer;
BEGIN
    -- explicit envelope filters
    IF p_envelope.valid_as_of IS NOT NULL
       OR p_envelope.transaction_as_of IS NOT NULL THEN
        RETURN 'time_as_of';
    END IF;
    IF p_envelope.confidence_floor IS NOT NULL THEN
        RETURN 'by_confidence';
    END IF;
    IF p_envelope.hints IS NOT NULL
       AND (p_envelope.hints ? 'source_package_id'
            OR p_envelope.hints ? 'connector_id') THEN
        RETURN 'by_source';
    END IF;

    -- cue-derived heuristics
    SELECT count(*)
    INTO v_svpor_count
    FROM extract_cues(p_envelope.cue_text) c
    WHERE c.cue_kind IN ('subject','verb','predicate');

    IF v_svpor_count >= 2 THEN
        RETURN 'narrow';
    END IF;

    -- recall hints in plain English: "what / show me / list / find"
    -- PG POSIX regex uses \y for word boundaries (not \b).
    IF v_lower ~ '^\s*(what|show me|list|find|where|when|who)\y' THEN
        RETURN 'recall';
    END IF;

    RETURN 'broad';
END;
$body$;

-- =====================================================================
-- select_search_paths — produces the ordered strategy list.
--
-- Each strategy is a jsonb object: {strategy: <name>, params: {...}}.
-- Names match the underlying executor surface (callers route them
-- to fts_search / fuzzy_subject_match / graph_walk / vector search,
-- etc.).
-- =====================================================================
CREATE FUNCTION select_search_paths(
    p_intent     text,
    p_envelope   malu$retrieval_envelope_t,
    p_cues_jsonb jsonb
) RETURNS jsonb
LANGUAGE sql STABLE
AS $body$
    SELECT CASE p_intent
        WHEN 'narrow' THEN
            jsonb_build_array(
                jsonb_build_object('strategy', 'svpor_routing',
                    'params', jsonb_build_object('cues', p_cues_jsonb)),
                jsonb_build_object('strategy', 'fts',
                    'params', jsonb_build_object('query', p_envelope.cue_text,
                                                 'object_types', to_jsonb(p_envelope.object_types))),
                jsonb_build_object('strategy', 'vector',
                    'params', jsonb_build_object('query', p_envelope.cue_text)))
        WHEN 'broad' THEN
            jsonb_build_array(
                jsonb_build_object('strategy', 'fts',
                    'params', jsonb_build_object('query', p_envelope.cue_text,
                                                 'object_types', to_jsonb(p_envelope.object_types))),
                jsonb_build_object('strategy', 'vector',
                    'params', jsonb_build_object('query', p_envelope.cue_text)),
                jsonb_build_object('strategy', 'graph_walk',
                    'params', jsonb_build_object('max_depth', 3)))
        WHEN 'recall' THEN
            jsonb_build_array(
                jsonb_build_object('strategy', 'fuzzy_subject',
                    'params', jsonb_build_object('needle', p_envelope.cue_text,
                                                 'threshold', 0.3)),
                jsonb_build_object('strategy', 'fts',
                    'params', jsonb_build_object('query', p_envelope.cue_text)))
        WHEN 'time_as_of' THEN
            jsonb_build_array(
                jsonb_build_object('strategy', 'temporal_as_of',
                    'params', jsonb_build_object(
                        'valid_as_of',       p_envelope.valid_as_of,
                        'transaction_as_of', p_envelope.transaction_as_of)),
                jsonb_build_object('strategy', 'fts',
                    'params', jsonb_build_object('query', p_envelope.cue_text)))
        WHEN 'by_source' THEN
            jsonb_build_array(
                jsonb_build_object('strategy', 'source_filter',
                    'params', jsonb_build_object(
                        'source_package_id', p_envelope.hints->'source_package_id',
                        'connector_id',      p_envelope.hints->'connector_id')),
                jsonb_build_object('strategy', 'fts',
                    'params', jsonb_build_object('query', p_envelope.cue_text)))
        WHEN 'by_confidence' THEN
            jsonb_build_array(
                jsonb_build_object('strategy', 'confidence_floor',
                    'params', jsonb_build_object('floor', p_envelope.confidence_floor)),
                jsonb_build_object('strategy', 'fts',
                    'params', jsonb_build_object('query', p_envelope.cue_text)))
        ELSE
            jsonb_build_array(
                jsonb_build_object('strategy', 'fts',
                    'params', jsonb_build_object('query', p_envelope.cue_text)))
    END;
$body$;

-- =====================================================================
-- plan_retrieval — top-level entry.
--
-- Returns a malu$retrieval_plan composite. The caller dispatches each
-- strategy in `strategies` order, merging hits per their own ranking
-- policy. S4-4 (query hints) and S4-5 (authz-aware retrieval) layer
-- on top — hints can reorder / suppress strategies; authz filters
-- the candidate set at planning, expansion, and assembly.
-- =====================================================================
CREATE FUNCTION plan_retrieval(p_envelope malu$retrieval_envelope_t)
RETURNS malu$retrieval_plan
LANGUAGE plpgsql STABLE
AS $body$
DECLARE
    v_cues      jsonb;
    v_intent    text;
    v_strats    jsonb;
BEGIN
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
                'cue_kind',  c.cue_kind,
                'cue_value', c.cue_value,
                'cue_ref_id', c.cue_ref_id,
                'weight',    c.weight)
                ORDER BY c.weight DESC, c.cue_kind, c.cue_value),
            '[]'::jsonb)
    INTO v_cues
    FROM extract_cues(p_envelope.cue_text) c;

    v_intent := classify_intent(p_envelope);
    v_strats := select_search_paths(v_intent, p_envelope, v_cues);

    RETURN ROW(
        v_intent,
        v_cues,
        v_strats,
        to_jsonb(p_envelope)
    )::malu$retrieval_plan;
END;
$body$;

-- =====================================================================
-- record_retrieval_envelope — persist the envelope + computed plan
-- for replay / debugging / governance review.
-- =====================================================================
CREATE FUNCTION record_retrieval_envelope(
    p_envelope malu$retrieval_envelope_t,
    p_plan     malu$retrieval_plan
) RETURNS bigint
LANGUAGE plpgsql
AS $body$
DECLARE v_id bigint;
BEGIN
    INSERT INTO malu$retrieval_envelope
        (cue_text, object_types, valid_as_of, transaction_as_of,
         confidence_floor, hints, plan_jsonb)
    VALUES (p_envelope.cue_text, p_envelope.object_types,
            p_envelope.valid_as_of, p_envelope.transaction_as_of,
            p_envelope.confidence_floor, p_envelope.hints,
            to_jsonb(p_plan))
    RETURNING envelope_id INTO v_id;
    RETURN v_id;
END;
$body$;

GRANT EXECUTE ON FUNCTION
    extract_cues(text),
    classify_intent(malu$retrieval_envelope_t),
    select_search_paths(text, malu$retrieval_envelope_t, jsonb),
    plan_retrieval(malu$retrieval_envelope_t),
    record_retrieval_envelope(malu$retrieval_envelope_t, malu$retrieval_plan)
TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;
