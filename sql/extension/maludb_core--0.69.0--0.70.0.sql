-- =====================================================================
-- maludb_core 0.69.0 -> 0.70.0  (V4 alpha.5 — V4-MC2DB-01 completion)
--
-- Fills in the ChatIndex MC2DB surface and adds pageindex.tree_summary
-- so maludb.advanced reaches parity for both V4 trees. Tool count
-- rises 22 -> 27.
--
-- Catalog: no new tables. Two new SQL helpers extend the descent
-- surface:
--
--   chat_tree_descent_retrieve(envelope_id, chat_tree_id, options)
--     mirrors tree_descent_retrieve (V4-PAGEINDEX-03) but walks
--     malu$memory_detail_object rows whose mdo_kind is
--     'chat_index_topic' or 'chat_index_message' under chat_tree_id.
--     Same three-stage authz contract: planning RLS / expansion RLS-
--     filtered candidates / re-check before traversal / assembly
--     redaction. Same 'overlap' default choice strategy. Each step
--     writes a malu$retrieval_decision_audit row with
--     stage='tree_descent' and a malu$derivation_ledger entry of
--     kind 'retrieval_summary'.
--
--   retrieve_with_envelope_chat_tree(cue_text, chat_tree_id, options,
--                                    limit)
--     packaged operator entrypoint. Opens an envelope, sets the
--     'long_chat_recall' intent, invokes chat_tree_descent_retrieve,
--     returns leaf terminus + envelope_id.
--
-- MC2DB tools registered on maludb.advanced:
--   * maludb.chatindex.build       (state_changing)
--   * maludb.chatindex.append      (state_changing)
--   * maludb.chatindex.ask         (read_only)
--   * maludb.chatindex.list        (read_only)
--   * maludb.pageindex.tree_summary (read_only) — returns root +
--     first-level node titles/summaries.
--
-- Apply with:
--   ALTER EXTENSION maludb_core UPDATE TO '0.70.0';
-- =====================================================================

CREATE OR REPLACE FUNCTION maludb_core_version() RETURNS text
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$ SELECT '0.70.0'::text $body$;

-- =====================================================================
-- 1. chat_tree_descent_retrieve — chat-tree analogue of
--    tree_descent_retrieve. Stops at chat_index_message (leaf).
-- =====================================================================
CREATE FUNCTION chat_tree_descent_retrieve(
    p_envelope_id     bigint,
    p_chat_tree_id    bigint,
    p_descent_options jsonb DEFAULT '{}'::jsonb
) RETURNS TABLE (
    leaf_mdo_id     bigint,
    leaf_title      text,
    leaf_summary    text,
    depth_reached   integer)
LANGUAGE plpgsql VOLATILE
AS $body$
#variable_conflict use_column
DECLARE
    v_envelope         malu$retrieval_envelope%ROWTYPE;
    v_tree             malu$chat_index_tree%ROWTYPE;
    v_max_depth        integer := COALESCE(
        (p_descent_options ->> 'max_depth')::integer, 6);
    v_choice_strategy  text := COALESCE(
        p_descent_options ->> 'choice', 'overlap');
    v_cue_text         text;
    v_cue_tokens       text[];
    v_current_mdo      bigint;
    v_current_kind     text;
    v_current_title    text;
    v_current_summary  text;
    v_chosen_mdo       bigint;
    v_chosen_title     text;
    v_chosen_summary   text;
    v_chosen_kind      text;
    v_chosen_score     numeric;
    v_chosen_reason    text;
    v_step             integer := 0;
    v_path             jsonb := '[]'::jsonb;
    v_rec              record;
    v_dummy            integer;
BEGIN
    SELECT * INTO v_envelope
      FROM malu$retrieval_envelope WHERE envelope_id = p_envelope_id;
    IF v_envelope.envelope_id IS NULL THEN
        RAISE EXCEPTION 'chat_tree_descent_retrieve: envelope % not found',
            p_envelope_id USING ERRCODE = 'no_data_found';
    END IF;

    SELECT * INTO v_tree FROM malu$chat_index_tree WHERE tree_id = p_chat_tree_id;
    IF v_tree.tree_id IS NULL THEN
        INSERT INTO malu$retrieval_decision_audit
            (envelope_id, stage, allowed, reason, object_type, object_id)
        VALUES (p_envelope_id, 'tree_descent', false,
                'chat tree not visible to caller',
                'chat_index_tree', p_chat_tree_id);
        UPDATE malu$retrieval_envelope
           SET tree_descent_used = true,
               tree_descent_path = '[]'::jsonb,
               tree_descent_authz_rejections = 1
         WHERE envelope_id = p_envelope_id;
        RAISE EXCEPTION
            'chat_tree_descent_retrieve: chat tree % not visible',
            p_chat_tree_id USING ERRCODE = 'insufficient_privilege';
    END IF;
    IF v_tree.build_status NOT IN ('ready','superseded') THEN
        RAISE EXCEPTION
            'chat_tree_descent_retrieve: chat tree % not in ready/superseded state (status=%)',
            p_chat_tree_id, v_tree.build_status
            USING ERRCODE = 'object_not_in_prerequisite_state';
    END IF;

    INSERT INTO malu$retrieval_decision_audit
        (envelope_id, stage, allowed, reason, object_type, object_id)
    VALUES (p_envelope_id, 'tree_descent', true,
            format('chat descent start: choice=%s max_depth=%s',
                   v_choice_strategy, v_max_depth),
            'chat_index_tree', p_chat_tree_id);

    v_cue_text := COALESCE(v_envelope.cue_text, '');
    v_cue_tokens := regexp_split_to_array(lower(v_cue_text), '\W+');

    -- Root = parent_mdo_id IS NULL.
    SELECT mdo_id, node_kind, COALESCE(topic_name, title), summary
      INTO v_current_mdo, v_current_kind, v_current_title, v_current_summary
      FROM malu$memory_detail_object
     WHERE chat_tree_id = p_chat_tree_id
       AND mdo_kind IN ('chat_index_topic','chat_index_message')
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

    WHILE v_current_kind = 'internal' AND v_step < v_max_depth LOOP
        v_step := v_step + 1;
        v_chosen_mdo := NULL;
        v_chosen_score := -1;
        v_chosen_reason := NULL;

        FOR v_rec IN
            SELECT mdo_id, node_kind,
                   COALESCE(topic_name, title) AS title, summary,
                   system_message, user_message, assistant_message
              FROM malu$memory_detail_object
             WHERE parent_mdo_id = v_current_mdo
               AND mdo_kind IN ('chat_index_topic','chat_index_message')
             ORDER BY message_index NULLS LAST, mdo_id
        LOOP
            DECLARE
                v_score numeric := 0;
                v_lower text := lower(
                    COALESCE(v_rec.title,'') || ' '
                    || COALESCE(v_rec.summary,'') || ' '
                    || COALESCE(v_rec.user_message,'') || ' '
                    || COALESCE(v_rec.assistant_message,''));
                v_tok text;
            BEGIN
                IF v_choice_strategy = 'first' THEN
                    v_score := 1.0 / (1 + v_rec.mdo_id);
                ELSE
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
            INSERT INTO malu$retrieval_decision_audit
                (envelope_id, stage, allowed, reason, object_type, object_id)
            VALUES (p_envelope_id, 'tree_descent', false,
                    'internal chat node with no authz-visible children',
                    'memory_detail_object', v_current_mdo);
            EXIT;
        END IF;

        SELECT 1 INTO v_dummy
          FROM malu$memory_detail_object WHERE mdo_id = v_chosen_mdo;
        IF NOT FOUND THEN
            UPDATE malu$retrieval_envelope
               SET tree_descent_authz_rejections =
                   tree_descent_authz_rejections + 1
             WHERE envelope_id = p_envelope_id;
            INSERT INTO malu$retrieval_decision_audit
                (envelope_id, stage, allowed, reason, object_type, object_id)
            VALUES (p_envelope_id, 'tree_descent', false,
                    'chosen chat child not visible on re-check',
                    'memory_detail_object', v_chosen_mdo);
            EXIT;
        END IF;

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
                format('chat descend step=%s %s', v_step, v_chosen_reason),
                'memory_detail_object', v_chosen_mdo);

        PERFORM record_derivation(
            'retrieval_summary', v_chosen_mdo,
            NULL, NULL, NULL, NULL, NULL, NULL,
            jsonb_build_object(
                'envelope_id', p_envelope_id,
                'chat_tree_id', p_chat_tree_id,
                'step', v_step,
                'cue_text', v_cue_text,
                'choice_strategy', v_choice_strategy,
                'score', v_chosen_score));

        v_current_mdo     := v_chosen_mdo;
        v_current_kind    := v_chosen_kind;
        v_current_title   := v_chosen_title;
        v_current_summary := v_chosen_summary;
    END LOOP;

    UPDATE malu$retrieval_envelope
       SET tree_descent_used = true,
           tree_descent_path = v_path
     WHERE envelope_id = p_envelope_id;

    RETURN QUERY
    SELECT m.mdo_id,
           COALESCE(m.topic_name, m.title),
           m.summary,
           v_step
      FROM malu$memory_detail_object m
     WHERE m.mdo_id = v_current_mdo;
END;
$body$;

REVOKE EXECUTE ON FUNCTION chat_tree_descent_retrieve(bigint, bigint, jsonb) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION chat_tree_descent_retrieve(bigint, bigint, jsonb) TO
    maludb_memory_admin, maludb_memory_executor, maludb_queue_worker;

-- =====================================================================
-- 2. retrieve_with_envelope_chat_tree — packaged entrypoint.
-- =====================================================================
CREATE FUNCTION retrieve_with_envelope_chat_tree(
    p_cue_text        text,
    p_chat_tree_id    bigint,
    p_descent_options jsonb DEFAULT '{}'::jsonb,
    p_limit           integer DEFAULT 1
) RETURNS TABLE (
    envelope_id     bigint,
    leaf_mdo_id     bigint,
    leaf_title      text,
    leaf_summary    text,
    depth_reached   integer)
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
        (current_account_id(), p_cue_text,
         jsonb_build_object('chat_tree_id', p_chat_tree_id),
         ARRAY[]::text[], 'current_valid',
         ARRAY['chat_index_topic','chat_index_message']::text[],
         now())
    RETURNING envelope_id INTO v_envelope_id;

    v_envelope := ROW(p_cue_text,
                      ARRAY['chat_index_topic','chat_index_message']::text[],
                      NULL::timestamptz, NULL::timestamptz,
                      NULL::numeric,
                      jsonb_build_object('chat_tree_id', p_chat_tree_id))::malu$retrieval_envelope_t;
    v_intent := classify_intent(v_envelope);

    INSERT INTO malu$retrieval_decision_audit
        (envelope_id, stage, allowed, reason)
    VALUES (v_envelope_id, 'planning', true,
            format('intent=%s', v_intent));

    RETURN QUERY
    SELECT v_envelope_id, t.leaf_mdo_id, t.leaf_title, t.leaf_summary, t.depth_reached
      FROM chat_tree_descent_retrieve(v_envelope_id, p_chat_tree_id, p_descent_options) t
     LIMIT GREATEST(p_limit, 1);

    UPDATE malu$retrieval_envelope
       SET finished_at = now(),
           final_count = 1
     WHERE envelope_id = v_envelope_id;

    PERFORM audit_event('retrieve_with_envelope_chat_tree',
        'malu$retrieval_envelope', v_envelope_id,
        jsonb_build_object('chat_tree_id', p_chat_tree_id,
                           'cue_text', p_cue_text,
                           'intent', v_intent));
END;
$body$;

REVOKE EXECUTE ON FUNCTION retrieve_with_envelope_chat_tree(text, bigint, jsonb, integer) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION retrieve_with_envelope_chat_tree(text, bigint, jsonb, integer) TO
    maludb_memory_admin, maludb_memory_executor;

-- =====================================================================
-- 3. MC2DB tool wrappers + registrations.
-- =====================================================================

CREATE FUNCTION advanced_chatindex_build(args jsonb, context jsonb)
RETURNS void
LANGUAGE plpgsql SECURITY INVOKER
AS $body$
DECLARE v_tree_id bigint;
BEGIN
    v_tree_id := source_package_promote_to_chat_index(
        (args ->> 'source_package_id')::bigint,
        NULLIF(args ->> 'model_alias_id', '')::bigint,
        NULLIF(args ->> 'prompt_template_id', '')::bigint,
        COALESCE((args ->> 'max_children')::integer, 10),
        COALESCE(args -> 'builder_options', '{}'::jsonb));

    CALL mc2db.put_object(jsonb_build_object(
        'content', jsonb_build_array(jsonb_build_object(
            'type', 'text',
            'text', format('promoted source_package=%s -> chat_tree_id=%s',
                           args ->> 'source_package_id', v_tree_id))),
        'structuredContent', jsonb_build_object(
            'tree_id', v_tree_id,
            'source_package_id', (args ->> 'source_package_id')::bigint,
            'build_status', 'pending'),
        'isError', false));
END;
$body$;

CREATE FUNCTION advanced_chatindex_append(args jsonb, context jsonb)
RETURNS void
LANGUAGE plpgsql SECURITY INVOKER
AS $body$
DECLARE
    v_results jsonb := '[]'::jsonb;
    v_rec     record;
BEGIN
    FOR v_rec IN
        SELECT *
          FROM chat_index_append_messages(
            (args ->> 'tree_id')::bigint,
            COALESCE(args -> 'messages', '[]'::jsonb))
    LOOP
        v_results := v_results || jsonb_build_object(
            'message_index', v_rec.message_index,
            'mdo_id',        v_rec.mdo_id,
            'idempotent_hit', v_rec.idempotent_hit);
    END LOOP;

    CALL mc2db.put_object(jsonb_build_object(
        'content', jsonb_build_array(jsonb_build_object(
            'type', 'text',
            'text', format('%s message(s) processed',
                           jsonb_array_length(v_results)))),
        'structuredContent', jsonb_build_object(
            'tree_id', (args ->> 'tree_id')::bigint,
            'results', v_results),
        'isError', false));
END;
$body$;

CREATE FUNCTION advanced_chatindex_ask(args jsonb, context jsonb)
RETURNS void
LANGUAGE plpgsql SECURITY INVOKER
AS $body$
DECLARE v_row record;
BEGIN
    SELECT *
      INTO v_row
      FROM retrieve_with_envelope_chat_tree(
        args ->> 'cue_text',
        (args ->> 'tree_id')::bigint,
        COALESCE(args -> 'descent_options', '{}'::jsonb),
        COALESCE((args ->> 'limit')::integer, 1));

    CALL mc2db.put_object(jsonb_build_object(
        'content', jsonb_build_array(jsonb_build_object(
            'type', 'text',
            'text', format('leaf %s @ depth %s',
                           v_row.leaf_mdo_id, v_row.depth_reached))),
        'structuredContent', jsonb_build_object(
            'envelope_id',  v_row.envelope_id,
            'tree_id',      (args ->> 'tree_id')::bigint,
            'leaf_mdo_id',  v_row.leaf_mdo_id,
            'leaf_title',   v_row.leaf_title,
            'leaf_summary', v_row.leaf_summary,
            'depth_reached', v_row.depth_reached),
        'isError', false));
END;
$body$;

CREATE FUNCTION advanced_chatindex_list(args jsonb, context jsonb)
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
        SELECT tree_id, source_package_id, build_status,
               current_node_mdo_id, max_children, sub_node_count,
               build_started_at, build_finished_at, superseded_by
          FROM malu$chat_index_tree
         WHERE v_status IS NULL OR build_status = v_status
         ORDER BY tree_id DESC
         LIMIT v_limit
      ) t;

    CALL mc2db.put_object(jsonb_build_object(
        'content', jsonb_build_array(jsonb_build_object(
            'type', 'text',
            'text', format('%s chat tree(s)', jsonb_array_length(v_trees)))),
        'structuredContent', jsonb_build_object('trees', v_trees),
        'isError', false));
END;
$body$;

CREATE FUNCTION advanced_pageindex_tree_summary(args jsonb, context jsonb)
RETURNS void
LANGUAGE plpgsql SECURITY INVOKER
AS $body$
DECLARE
    v_tree_id bigint := (args ->> 'tree_id')::bigint;
    v_root    record;
    v_first   jsonb;
BEGIN
    SELECT mdo_id, title, summary, node_kind
      INTO v_root
      FROM malu$memory_detail_object
     WHERE tree_id = v_tree_id
       AND mdo_kind = 'page_index_node'
       AND parent_mdo_id IS NULL
     ORDER BY mdo_id LIMIT 1;
    IF v_root.mdo_id IS NULL THEN
        RAISE EXCEPTION 'maludb.pageindex.tree_summary: tree % has no root node',
            v_tree_id USING ERRCODE = 'no_data_found';
    END IF;

    SELECT COALESCE(jsonb_agg(row_to_json(t)::jsonb ORDER BY mdo_id),
                    '[]'::jsonb)
      INTO v_first
      FROM (
        SELECT mdo_id, title, summary, node_kind
          FROM malu$memory_detail_object
         WHERE parent_mdo_id = v_root.mdo_id
           AND mdo_kind = 'page_index_node'
         ORDER BY mdo_id
      ) t;

    CALL mc2db.put_object(jsonb_build_object(
        'content', jsonb_build_array(jsonb_build_object(
            'type', 'text',
            'text', format('%s top-level child node(s) under "%s"',
                           jsonb_array_length(v_first),
                           v_root.title))),
        'structuredContent', jsonb_build_object(
            'tree_id', v_tree_id,
            'root', jsonb_build_object(
                'mdo_id',    v_root.mdo_id,
                'title',     v_root.title,
                'summary',   v_root.summary,
                'node_kind', v_root.node_kind),
            'children', v_first),
        'isError', false));
END;
$body$;

GRANT EXECUTE ON FUNCTION
    advanced_chatindex_build(jsonb, jsonb),
    advanced_chatindex_append(jsonb, jsonb),
    advanced_chatindex_ask(jsonb, jsonb),
    advanced_chatindex_list(jsonb, jsonb),
    advanced_pageindex_tree_summary(jsonb, jsonb)
TO maludb_memory_admin, maludb_memory_executor;

SELECT mc2db.register_tool(
    server_name => 'maludb.advanced', tool_name => 'maludb.chatindex.build',
    description => 'Promote a Source Package to a ChatIndex tree (queues the builder).',
    implementation_type => 'sql_function',
    risk_class => 'evidence_producing', read_only => false,
    input_schema  => '{"type":"object","required":["source_package_id"]}'::jsonb,
    output_schema => '{"type":"object","required":["tree_id"]}'::jsonb,
    impl_metadata => jsonb_build_object('function_signature',
        'maludb_core.advanced_chatindex_build(jsonb, jsonb)'));

SELECT mc2db.register_tool(
    server_name => 'maludb.advanced', tool_name => 'maludb.chatindex.append',
    description => 'Append one or more messages to a ChatIndex tree (handles topic decisions).',
    implementation_type => 'sql_function',
    risk_class => 'evidence_producing', read_only => false,
    input_schema  => '{"type":"object","required":["tree_id","messages"]}'::jsonb,
    output_schema => '{"type":"object","required":["results"]}'::jsonb,
    impl_metadata => jsonb_build_object('function_signature',
        'maludb_core.advanced_chatindex_append(jsonb, jsonb)'));

SELECT mc2db.register_tool(
    server_name => 'maludb.advanced', tool_name => 'maludb.chatindex.ask',
    description => 'Descend a ChatIndex tree to answer a query; returns the leaf terminus + envelope_id.',
    implementation_type => 'sql_function',
    input_schema  => '{"type":"object","required":["cue_text","tree_id"]}'::jsonb,
    output_schema => '{"type":"object","required":["leaf_mdo_id","depth_reached"]}'::jsonb,
    impl_metadata => jsonb_build_object('function_signature',
        'maludb_core.advanced_chatindex_ask(jsonb, jsonb)'));

SELECT mc2db.register_tool(
    server_name => 'maludb.advanced', tool_name => 'maludb.chatindex.list',
    description => 'List ChatIndex trees visible to the caller; optional build_status filter.',
    implementation_type => 'sql_function',
    input_schema  => '{"type":"object"}'::jsonb,
    output_schema => '{"type":"object","required":["trees"]}'::jsonb,
    impl_metadata => jsonb_build_object('function_signature',
        'maludb_core.advanced_chatindex_list(jsonb, jsonb)'));

SELECT mc2db.register_tool(
    server_name => 'maludb.advanced', tool_name => 'maludb.pageindex.tree_summary',
    description => 'Return the root + first-level node titles/summaries for a PageIndex tree.',
    implementation_type => 'sql_function',
    input_schema  => '{"type":"object","required":["tree_id"]}'::jsonb,
    output_schema => '{"type":"object","required":["root","children"]}'::jsonb,
    impl_metadata => jsonb_build_object('function_signature',
        'maludb_core.advanced_pageindex_tree_summary(jsonb, jsonb)'));
