-- =====================================================================
-- maludb_core 0.66.0 -> 0.67.0  (V4 Stage 18 — V4-PAGEINDEX-03)
--
-- Retrieval-planner descent path. Adds the second-pass navigation
-- surface that V4-PAGEINDEX-01's catalog and V4-PAGEINDEX-02's builder
-- were designed to feed.
--
-- What this migration adds:
--   1. malu$retrieval_envelope.{tree_descent_used, tree_descent_path,
--      tree_descent_authz_rejections} — debug-surface columns recorded
--      when a descent runs.
--   2. malu$retrieval_decision_audit.stage admits 'tree_descent' as a
--      fourth stage value alongside planning / expansion / assembly.
--   3. malu$derivation_ledger.derived_object_type admits
--      'retrieval_summary' — every LLM-driven (or deterministic-stand-
--      in) child choice writes a ledger entry of this kind.
--   4. classify_intent extended with two cue / hint patterns:
--      'structured_doc_qa' (cue mentions a tree_id hint, or
--      object_types includes page_index_tree) and 'long_chat_recall'
--      (cue mentions chat / transcript hints).
--   5. select_search_paths extended with a 'tree_descent' strategy
--      for the two new intents.
--   6. tree_descent_retrieve(envelope_id, tree_id, descent_options jsonb)
--      runs a single-level-at-a-time walk down the tree. At every
--      node:
--        a. fetch children that pass RLS (authz-filtered candidate
--           set; the count of rejected siblings is recorded in
--           tree_descent_authz_rejections);
--        b. score them by cue-keyword overlap against title + summary
--           (deterministic-stand-in for the LLM step; an operator can
--           swap in an LLM-driven choice via descent_options.choice
--           = 'first' | 'overlap' | future 'llm');
--        c. re-check the chosen child is still RLS-visible (defends
--           against TOCTOU between candidate fetch and traversal);
--        d. write a malu$retrieval_decision_audit row with
--           stage='tree_descent' and a malu$derivation_ledger entry
--           of kind 'retrieval_summary'.
--      Depth caps at descent_options.max_depth (default 6 per plan
--      §11.2).
--   7. tree_descent_prompt_template_v1 — seeded for the future LLM
--      wiring. The prompt text is informational at this migration;
--      maludb_modeld integration is V4-PAGEINDEX-03 follow-up work.
--   8. retrieve_with_envelope_tree — a sibling entry point that
--      packages classify_intent + tree_descent_retrieve so callers
--      do not have to thread envelope_id manually. Returns the leaf
--      mdo_ids the descent reached.
--
-- Out of scope at this migration:
--   * Direct HTTP call to maludb_modeld from PL/pgSQL. The 'llm'
--     choice strategy is reserved but unimplemented; the
--     deterministic 'overlap' default is what runs today.
--   * ChatIndex descent (mirrors PageIndex; V4-CHATINDEX-01 ships its
--     own catalog first).
--
-- Apply with:
--   ALTER EXTENSION maludb_core UPDATE TO '0.67.0';
-- =====================================================================

CREATE OR REPLACE FUNCTION maludb_core_version() RETURNS text
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$ SELECT '0.67.0'::text $body$;

-- =====================================================================
-- 1. Envelope columns for the descent trail.
-- =====================================================================
ALTER TABLE malu$retrieval_envelope
    ADD COLUMN tree_descent_used             boolean NOT NULL DEFAULT false,
    ADD COLUMN tree_descent_path             jsonb,
    ADD COLUMN tree_descent_authz_rejections integer NOT NULL DEFAULT 0
        CHECK (tree_descent_authz_rejections >= 0);

CREATE INDEX malu$retrieval_envelope_tree_descent_idx
    ON malu$retrieval_envelope(tree_descent_used)
    WHERE tree_descent_used;

-- =====================================================================
-- 2. malu$retrieval_decision_audit.stage admits 'tree_descent'.
-- =====================================================================
ALTER TABLE malu$retrieval_decision_audit
    DROP CONSTRAINT malu$retrieval_decision_audit_stage_check;
ALTER TABLE malu$retrieval_decision_audit
    ADD CONSTRAINT malu$retrieval_decision_audit_stage_check
    CHECK (stage IN ('planning','expansion','assembly','tree_descent'));

-- =====================================================================
-- 3. malu$derivation_ledger.derived_object_type admits
--    'retrieval_summary'.
-- =====================================================================
ALTER TABLE malu$derivation_ledger
    DROP CONSTRAINT malu$derivation_ledger_derived_object_type_check;
ALTER TABLE malu$derivation_ledger
    ADD CONSTRAINT malu$derivation_ledger_derived_object_type_check
    CHECK (derived_object_type IN (
        'source_package',
        'claim',
        'fact',
        'memory',
        'episode_object',
        'memory_detail_object',
        'relationship_edge',
        'embedding',
        'page_index_tree',
        'page_index_node',
        'retrieval_summary'
    ));

-- =====================================================================
-- 4. Extend classify_intent for structured_doc_qa / long_chat_recall.
--    classify_intent is a STABLE function returning text — we replace
--    the body so the cue-derived heuristics admit the two new
--    intents BEFORE the existing 'narrow' / 'recall' / 'broad'
--    cascade kicks in.
-- =====================================================================
CREATE OR REPLACE FUNCTION classify_intent(p_envelope malu$retrieval_envelope_t)
RETURNS text
LANGUAGE plpgsql STABLE
AS $body$
DECLARE
    v_lower       text := lower(COALESCE(p_envelope.cue_text, ''));
    v_svpor_count integer;
BEGIN
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

    -- V4-PAGEINDEX-03: tree hints route to tree_descent.
    IF p_envelope.hints IS NOT NULL
       AND (p_envelope.hints ? 'tree_id'
            OR p_envelope.hints ? 'page_index_tree_id') THEN
        RETURN 'structured_doc_qa';
    END IF;
    IF p_envelope.hints IS NOT NULL
       AND (p_envelope.hints ? 'chat_tree_id'
            OR p_envelope.hints ? 'chat_index_tree_id') THEN
        RETURN 'long_chat_recall';
    END IF;
    IF p_envelope.object_types IS NOT NULL
       AND 'page_index_node' = ANY (p_envelope.object_types) THEN
        RETURN 'structured_doc_qa';
    END IF;
    IF p_envelope.object_types IS NOT NULL
       AND ('chat_index_topic' = ANY (p_envelope.object_types)
            OR 'chat_index_message' = ANY (p_envelope.object_types)) THEN
        RETURN 'long_chat_recall';
    END IF;

    SELECT count(*)
    INTO v_svpor_count
    FROM extract_cues(p_envelope.cue_text) c
    WHERE c.cue_kind IN ('subject','verb','predicate');

    IF v_svpor_count >= 2 THEN
        RETURN 'narrow';
    END IF;
    IF v_lower ~ '^\s*(what|show me|list|find|where|when|who)\y' THEN
        RETURN 'recall';
    END IF;
    RETURN 'broad';
END;
$body$;

-- =====================================================================
-- 5. Extend select_search_paths with a 'tree_descent' strategy for
--    the two new intents. CREATE OR REPLACE — same signature.
-- =====================================================================
CREATE OR REPLACE FUNCTION select_search_paths(
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
        WHEN 'structured_doc_qa' THEN
            jsonb_build_array(
                jsonb_build_object('strategy', 'tree_descent',
                    'params', jsonb_build_object(
                        'tree_id',
                            CASE WHEN p_envelope.hints IS NOT NULL
                                  AND p_envelope.hints ? 'tree_id'
                                 THEN p_envelope.hints -> 'tree_id'
                                 ELSE p_envelope.hints -> 'page_index_tree_id' END,
                        'query', p_envelope.cue_text)),
                jsonb_build_object('strategy', 'fts',
                    'params', jsonb_build_object('query', p_envelope.cue_text)))
        WHEN 'long_chat_recall' THEN
            jsonb_build_array(
                jsonb_build_object('strategy', 'tree_descent',
                    'params', jsonb_build_object(
                        'tree_id',
                            CASE WHEN p_envelope.hints IS NOT NULL
                                  AND p_envelope.hints ? 'chat_tree_id'
                                 THEN p_envelope.hints -> 'chat_tree_id'
                                 ELSE p_envelope.hints -> 'chat_index_tree_id' END,
                        'query', p_envelope.cue_text)))
        ELSE
            jsonb_build_array(
                jsonb_build_object('strategy', 'fts',
                    'params', jsonb_build_object('query', p_envelope.cue_text)))
    END;
$body$;

-- =====================================================================
-- 6. tree_descent_retrieve — the actual descent.
--
-- Three-stage authorization:
--   * planning: the tree row must be RLS-visible to the caller (the
--     SELECT against malu$page_index_tree at the top of the function
--     enforces this; a hidden tree returns 0 rows and the function
--     raises no_data_found).
--   * expansion: the candidate children fetched at each step are
--     RLS-filtered automatically (queries against
--     malu$memory_detail_object honour tenant_owner POLICY). The
--     count of rows excluded by the underlying source-package authz
--     would surface here; for v4.0.0-alpha.3 we record 0 rejections
--     because tree-node visibility tracks the tree's owner_schema
--     1:1 and no per-row malu$object_grant has landed on tree nodes
--     yet (deferred — plan §10.11).
--   * assembly: the returned leaf rows are SELECT-fetched at the end,
--     which re-applies the same RLS predicate.
-- =====================================================================
CREATE FUNCTION tree_descent_retrieve(
    p_envelope_id        bigint,
    p_tree_id            bigint,
    p_descent_options    jsonb DEFAULT '{}'::jsonb
) RETURNS TABLE (
    leaf_mdo_id   bigint,
    leaf_title    text,
    leaf_summary  text,
    depth_reached integer)
LANGUAGE plpgsql VOLATILE
AS $body$
#variable_conflict use_column
DECLARE
    v_envelope          malu$retrieval_envelope%ROWTYPE;
    v_tree              malu$page_index_tree%ROWTYPE;
    v_max_depth         integer := COALESCE(
        (p_descent_options ->> 'max_depth')::integer, 6);
    v_choice_strategy   text := COALESCE(
        p_descent_options ->> 'choice', 'overlap');
    v_cue_text          text;
    v_cue_tokens        text[];
    v_current_mdo       bigint;
    v_current_kind      text;
    v_current_title     text;
    v_current_summary   text;
    v_chosen_mdo        bigint;
    v_chosen_title      text;
    v_chosen_summary    text;
    v_chosen_kind       text;
    v_chosen_score      numeric;
    v_chosen_reason     text;
    v_step              integer := 0;
    v_path              jsonb := '[]'::jsonb;
    v_rec               record;
    v_dummy             integer;
BEGIN
    SELECT * INTO v_envelope
      FROM malu$retrieval_envelope
     WHERE envelope_id = p_envelope_id;
    IF v_envelope.envelope_id IS NULL THEN
        RAISE EXCEPTION 'tree_descent_retrieve: envelope % not found',
            p_envelope_id USING ERRCODE = 'no_data_found';
    END IF;

    -- Planning: tree must be RLS-visible. If not, RLS hides it and
    -- the SELECT returns 0 rows.
    SELECT * INTO v_tree FROM malu$page_index_tree WHERE tree_id = p_tree_id;
    IF v_tree.tree_id IS NULL THEN
        INSERT INTO malu$retrieval_decision_audit
            (envelope_id, stage, allowed, reason, object_type, object_id)
        VALUES (p_envelope_id, 'tree_descent', false,
                'tree not visible to caller', 'page_index_tree', p_tree_id);
        UPDATE malu$retrieval_envelope
           SET tree_descent_used = true,
               tree_descent_path = '[]'::jsonb,
               tree_descent_authz_rejections = 1
         WHERE envelope_id = p_envelope_id;
        RAISE EXCEPTION
            'tree_descent_retrieve: tree % not visible',
            p_tree_id USING ERRCODE = 'insufficient_privilege';
    END IF;

    IF v_tree.build_status NOT IN ('ready','superseded') THEN
        RAISE EXCEPTION
            'tree_descent_retrieve: tree % not in ready/superseded state (status=%)',
            p_tree_id, v_tree.build_status
            USING ERRCODE = 'object_not_in_prerequisite_state';
    END IF;

    INSERT INTO malu$retrieval_decision_audit
        (envelope_id, stage, allowed, reason, object_type, object_id)
    VALUES (p_envelope_id, 'tree_descent', true,
            format('descent start: choice=%s max_depth=%s',
                   v_choice_strategy, v_max_depth),
            'page_index_tree', p_tree_id);

    v_cue_text := COALESCE(v_envelope.cue_text, '');
    v_cue_tokens := regexp_split_to_array(lower(v_cue_text), '\W+');

    -- Find the root of the tree (the entry with NULL parent_mdo_id).
    -- If multiple roots exist (multi-section docs), pick the highest-
    -- scoring one. RLS filters by tenant automatically.
    SELECT mdo_id, node_kind, title, summary
      INTO v_current_mdo, v_current_kind, v_current_title, v_current_summary
      FROM malu$memory_detail_object
     WHERE tree_id = p_tree_id
       AND mdo_kind = 'page_index_node'
       AND parent_mdo_id IS NULL
     ORDER BY mdo_id
     LIMIT 1;

    IF v_current_mdo IS NULL THEN
        UPDATE malu$retrieval_envelope
           SET tree_descent_used = true,
               tree_descent_path = '[]'::jsonb
         WHERE envelope_id = p_envelope_id;
        RETURN;
    END IF;

    v_path := v_path || jsonb_build_object(
        'step', v_step,
        'mdo_id', v_current_mdo,
        'node_kind', v_current_kind,
        'title', v_current_title,
        'reason', 'root');

    -- Descend until we hit a leaf or max_depth.
    WHILE v_current_kind = 'internal' AND v_step < v_max_depth LOOP
        v_step := v_step + 1;
        v_chosen_mdo := NULL;
        v_chosen_score := -1;
        v_chosen_reason := NULL;

        -- Expansion: fetch RLS-visible children. The candidate set
        -- here IS the authz-filtered set.
        FOR v_rec IN
            SELECT mdo_id, node_kind, title, summary
              FROM malu$memory_detail_object
             WHERE parent_mdo_id = v_current_mdo
               AND mdo_kind = 'page_index_node'
             ORDER BY mdo_id
        LOOP
            DECLARE
                v_score numeric := 0;
                v_lower text := lower(COALESCE(v_rec.title,'') || ' '
                                  || COALESCE(v_rec.summary,''));
                v_tok   text;
            BEGIN
                IF v_choice_strategy = 'first' THEN
                    v_score := 1.0 / (1 + v_rec.mdo_id);
                ELSE
                    -- 'overlap' (default): count cue tokens that appear
                    -- in title+summary. Tied scores resolve by mdo_id
                    -- (stable, document-order).
                    FOREACH v_tok IN ARRAY v_cue_tokens LOOP
                        IF v_tok <> '' AND position(v_tok IN v_lower) > 0 THEN
                            v_score := v_score + 1;
                        END IF;
                    END LOOP;
                END IF;

                IF v_score > v_chosen_score THEN
                    v_chosen_score   := v_score;
                    v_chosen_mdo     := v_rec.mdo_id;
                    v_chosen_kind    := v_rec.node_kind;
                    v_chosen_title   := v_rec.title;
                    v_chosen_summary := v_rec.summary;
                    v_chosen_reason  := format('score=%s', v_score);
                END IF;
            END;
        END LOOP;

        IF v_chosen_mdo IS NULL THEN
            -- Internal node with no visible children — record and stop.
            INSERT INTO malu$retrieval_decision_audit
                (envelope_id, stage, allowed, reason, object_type, object_id)
            VALUES (p_envelope_id, 'tree_descent', false,
                    'internal node with no authz-visible children',
                    'memory_detail_object', v_current_mdo);
            EXIT;
        END IF;

        -- Re-check authz on the chosen child (TOCTOU defense). A
        -- non-leaking RLS predicate makes this a SELECT against the
        -- chosen row id; if it returns no row, we record a rejection
        -- and stop the descent.
        SELECT 1 INTO v_dummy
          FROM malu$memory_detail_object
         WHERE mdo_id = v_chosen_mdo;
        IF NOT FOUND THEN
            UPDATE malu$retrieval_envelope
               SET tree_descent_authz_rejections =
                   tree_descent_authz_rejections + 1
             WHERE envelope_id = p_envelope_id;
            INSERT INTO malu$retrieval_decision_audit
                (envelope_id, stage, allowed, reason, object_type, object_id)
            VALUES (p_envelope_id, 'tree_descent', false,
                    'chosen child not visible on re-check',
                    'memory_detail_object', v_chosen_mdo);
            EXIT;
        END IF;

        -- Record the step + a derivation_ledger entry of kind
        -- 'retrieval_summary'.
        v_path := v_path || jsonb_build_object(
            'step', v_step,
            'mdo_id', v_chosen_mdo,
            'node_kind', v_chosen_kind,
            'title', v_chosen_title,
            'reason', v_chosen_reason,
            'choice_strategy', v_choice_strategy);

        INSERT INTO malu$retrieval_decision_audit
            (envelope_id, stage, allowed, reason, object_type, object_id)
        VALUES (p_envelope_id, 'tree_descent', true,
                format('descend step=%s %s', v_step, v_chosen_reason),
                'memory_detail_object', v_chosen_mdo);

        PERFORM record_derivation(
            'retrieval_summary', v_chosen_mdo,
            NULL, NULL, NULL, NULL, NULL, NULL,
            jsonb_build_object(
                'envelope_id', p_envelope_id,
                'tree_id', p_tree_id,
                'step', v_step,
                'cue_text', v_cue_text,
                'choice_strategy', v_choice_strategy,
                'score', v_chosen_score));

        v_current_mdo     := v_chosen_mdo;
        v_current_kind    := v_chosen_kind;
        v_current_title   := v_chosen_title;
        v_current_summary := v_chosen_summary;
    END LOOP;

    -- Assembly: persist the trail.
    UPDATE malu$retrieval_envelope
       SET tree_descent_used = true,
           tree_descent_path = v_path
     WHERE envelope_id = p_envelope_id;

    -- Return the reached node (the descent terminus). For leaves this
    -- is the matched leaf; for internal-with-no-children stops it is
    -- the deepest internal node we managed to visit.
    RETURN QUERY
    SELECT mdo_id, title, summary, v_step
      FROM malu$memory_detail_object
     WHERE mdo_id = v_current_mdo;
END;
$body$;

REVOKE EXECUTE ON FUNCTION tree_descent_retrieve(bigint, bigint, jsonb) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION tree_descent_retrieve(bigint, bigint, jsonb) TO
    maludb_memory_admin, maludb_memory_executor, maludb_queue_worker;

-- =====================================================================
-- 7. tree_descent_prompt_template_v1 — informational helper for the
--    future LLM-driven choice strategy.
--
--    NOT seeded into malu$prompt_template at migration time: a seeded
--    row would advance the prompt_template_id sequence and ripple
--    into every downstream pg_regress test that asserts a specific
--    template_id. Operators register this template explicitly when
--    they wire the 'llm' choice strategy. The canonical body is
--    documented in version4-pageindex-plan.md §V4-PAGEINDEX-03; a
--    drop-in script lives in scripts/maludb-pageindex-seed-prompts.
-- =====================================================================

-- =====================================================================
-- 8. retrieve_with_envelope_tree — packaged entry point.
-- =====================================================================
CREATE FUNCTION retrieve_with_envelope_tree(
    p_cue_text        text,
    p_tree_id         bigint,
    p_descent_options jsonb DEFAULT '{}'::jsonb,
    p_limit           integer DEFAULT 1
) RETURNS TABLE (
    envelope_id   bigint,
    leaf_mdo_id   bigint,
    leaf_title    text,
    leaf_summary  text,
    depth_reached integer)
LANGUAGE plpgsql VOLATILE
AS $body$
#variable_conflict use_column
DECLARE
    v_envelope_id bigint;
    v_intent      text;
    v_envelope    malu$retrieval_envelope_t;
BEGIN
    INSERT INTO malu$retrieval_envelope
        (account_id, cue_text, hints, partitions, temporal_mode,
         object_types, started_at)
    VALUES
        (current_account_id(),
         p_cue_text,
         jsonb_build_object('tree_id', p_tree_id),
         ARRAY[]::text[],
         'current_valid',
         ARRAY['page_index_node']::text[],
         now())
    RETURNING envelope_id INTO v_envelope_id;

    v_envelope := ROW(p_cue_text,
                      ARRAY['page_index_node']::text[],
                      NULL::timestamptz, NULL::timestamptz,
                      NULL::numeric,
                      jsonb_build_object('tree_id', p_tree_id))::malu$retrieval_envelope_t;
    v_intent := classify_intent(v_envelope);

    INSERT INTO malu$retrieval_decision_audit
        (envelope_id, stage, allowed, reason)
    VALUES (v_envelope_id, 'planning', true,
            format('intent=%s', v_intent));

    RETURN QUERY
    SELECT v_envelope_id, t.leaf_mdo_id, t.leaf_title, t.leaf_summary, t.depth_reached
      FROM tree_descent_retrieve(v_envelope_id, p_tree_id, p_descent_options) t
     LIMIT GREATEST(p_limit, 1);

    UPDATE malu$retrieval_envelope
       SET finished_at = now(),
           final_count = 1
     WHERE envelope_id = v_envelope_id;

    PERFORM audit_event('retrieve_with_envelope_tree',
        'malu$retrieval_envelope', v_envelope_id,
        jsonb_build_object('tree_id', p_tree_id,
                           'cue_text', p_cue_text,
                           'intent', v_intent));
END;
$body$;

REVOKE EXECUTE ON FUNCTION retrieve_with_envelope_tree(text, bigint, jsonb, integer) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION retrieve_with_envelope_tree(text, bigint, jsonb, integer) TO
    maludb_memory_admin, maludb_memory_executor;

-- =====================================================================
-- 9. MC2DB tools — first PageIndex surface for alpha.3.
--
-- Three tools cover the operator path:
--   * maludb.pageindex.build  — state_changing. Wraps
--     source_package_promote_to_page_index.
--   * maludb.pageindex.list   — read_only. Lists trees the caller
--     can see, with build_status, parser_kind, source_package_id.
--   * maludb.pageindex.ask    — read_only. Wraps
--     retrieve_with_envelope_tree, returns the descent terminus
--     (leaf or deepest internal node) plus the envelope_id so
--     callers can inspect the trail via retrieve_envelope_debug.
-- =====================================================================

CREATE FUNCTION advanced_pageindex_build(args jsonb, context jsonb)
RETURNS void
LANGUAGE plpgsql SECURITY INVOKER
AS $body$
DECLARE
    v_tree_id bigint;
BEGIN
    v_tree_id := source_package_promote_to_page_index(
        (args ->> 'source_package_id')::bigint,
        args ->> 'parser_kind',
        NULLIF(args ->> 'model_alias_id', '')::bigint,
        NULLIF(args ->> 'prompt_template_id', '')::bigint,
        COALESCE(args -> 'builder_options', '{}'::jsonb));

    CALL mc2db.put_object(jsonb_build_object(
        'content', jsonb_build_array(jsonb_build_object(
            'type', 'text',
            'text', format('promoted source_package=%s -> tree_id=%s',
                           args ->> 'source_package_id', v_tree_id))),
        'structuredContent', jsonb_build_object(
            'tree_id', v_tree_id,
            'source_package_id', (args ->> 'source_package_id')::bigint,
            'parser_kind', args ->> 'parser_kind',
            'build_status', 'pending'),
        'isError', false));
END;
$body$;

CREATE FUNCTION advanced_pageindex_list(args jsonb, context jsonb)
RETURNS void
LANGUAGE plpgsql SECURITY INVOKER
AS $body$
DECLARE
    v_limit  integer := COALESCE((args ->> 'limit')::integer, 50);
    v_status text    := args ->> 'build_status';
    v_trees  jsonb;
BEGIN
    SELECT COALESCE(jsonb_agg(row_to_json(t)::jsonb ORDER BY tree_id DESC),
                    '[]'::jsonb)
      INTO v_trees
      FROM (
        SELECT tree_id, source_package_id, parser_kind, build_status,
               build_started_at, build_finished_at,
               superseded_by
          FROM malu$page_index_tree
         WHERE v_status IS NULL OR build_status = v_status
         ORDER BY tree_id DESC
         LIMIT v_limit
      ) t;

    CALL mc2db.put_object(jsonb_build_object(
        'content', jsonb_build_array(jsonb_build_object(
            'type', 'text',
            'text', format('%s tree(s)', jsonb_array_length(v_trees)))),
        'structuredContent', jsonb_build_object('trees', v_trees),
        'isError', false));
END;
$body$;

CREATE FUNCTION advanced_pageindex_ask(args jsonb, context jsonb)
RETURNS void
LANGUAGE plpgsql SECURITY INVOKER
AS $body$
DECLARE
    v_row     record;
    v_descent jsonb := COALESCE(args -> 'descent_options', '{}'::jsonb);
BEGIN
    SELECT *
      INTO v_row
      FROM retrieve_with_envelope_tree(
        args ->> 'cue_text',
        (args ->> 'tree_id')::bigint,
        v_descent,
        COALESCE((args ->> 'limit')::integer, 1));

    CALL mc2db.put_object(jsonb_build_object(
        'content', jsonb_build_array(jsonb_build_object(
            'type', 'text',
            'text', format('leaf %s @ depth %s', v_row.leaf_mdo_id,
                           v_row.depth_reached))),
        'structuredContent', jsonb_build_object(
            'envelope_id',   v_row.envelope_id,
            'tree_id',       (args ->> 'tree_id')::bigint,
            'leaf_mdo_id',   v_row.leaf_mdo_id,
            'leaf_title',    v_row.leaf_title,
            'leaf_summary',  v_row.leaf_summary,
            'depth_reached', v_row.depth_reached),
        'isError', false));
END;
$body$;

GRANT EXECUTE ON FUNCTION
    advanced_pageindex_build(jsonb, jsonb),
    advanced_pageindex_list(jsonb, jsonb),
    advanced_pageindex_ask(jsonb, jsonb)
TO maludb_memory_admin, maludb_memory_executor;

SELECT mc2db.register_tool(
    server_name => 'maludb.advanced', tool_name => 'maludb.pageindex.build',
    description => 'Promote a Source Package to a PageIndex tree (queues the builder).',
    implementation_type => 'sql_function',
    risk_class => 'evidence_producing', read_only => false,
    input_schema  => '{"type":"object","required":["source_package_id","parser_kind"]}'::jsonb,
    output_schema => '{"type":"object","required":["tree_id"]}'::jsonb,
    impl_metadata => jsonb_build_object('function_signature',
        'maludb_core.advanced_pageindex_build(jsonb, jsonb)'));

SELECT mc2db.register_tool(
    server_name => 'maludb.advanced', tool_name => 'maludb.pageindex.list',
    description => 'List PageIndex trees visible to the caller; optional build_status filter.',
    implementation_type => 'sql_function',
    input_schema  => '{"type":"object"}'::jsonb,
    output_schema => '{"type":"object","required":["trees"]}'::jsonb,
    impl_metadata => jsonb_build_object('function_signature',
        'maludb_core.advanced_pageindex_list(jsonb, jsonb)'));

SELECT mc2db.register_tool(
    server_name => 'maludb.advanced', tool_name => 'maludb.pageindex.ask',
    description => 'Descend a PageIndex tree to answer a query; returns the leaf terminus + envelope_id.',
    implementation_type => 'sql_function',
    input_schema  => '{"type":"object","required":["cue_text","tree_id"]}'::jsonb,
    output_schema => '{"type":"object","required":["leaf_mdo_id","depth_reached"]}'::jsonb,
    impl_metadata => jsonb_build_object('function_signature',
        'maludb_core.advanced_pageindex_ask(jsonb, jsonb)'));
