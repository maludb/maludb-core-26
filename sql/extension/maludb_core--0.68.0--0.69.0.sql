-- =====================================================================
-- maludb_core 0.68.0 -> 0.69.0  (V4 Stage 19 — V4-CHATINDEX-02)
--
-- Incremental append for ChatIndex.
--
-- The append model:
--   * malu$chat_index_tree.current_node_mdo_id, set by V4-CHATINDEX-01
--     record_topic / record_message, points to the most-recently-
--     touched node. Incremental append decides per-call whether to
--     extend the current leaf's topic OR open a new topic.
--   * Upstream ChatIndex's rule: a new topic may branch only from the
--     current node OR one of its ancestors. Append rejects a request
--     to branch from an unrelated subtree.
--   * Idempotency: duplicate message_index within the same chat tree
--     is a no-op (returns the existing mdo_id rather than inserting
--     a duplicate).
--   * Audit: every call writes a malu$chat_index_append_audit row
--     capturing the decision (opened_new_topic / ancestor_branch_used /
--     decision_reason / range).
--
-- What this migration adds:
--   1. malu$chat_index_append_audit — append decision breadcrumbs.
--   2. chat_index_append_messages(tree_id, messages jsonb) — the
--      append entry point. messages is a JSONB array whose entries
--      have the shape {message_index, system_message, user_message,
--      assistant_message, topic_branch (optional)}. topic_branch is:
--        omitted        → extend current leaf's topic (or open a
--                          root topic if the tree is empty)
--        {"new": "..."} → open a new topic from the current node
--        {"from_ancestor_mdo_id": N, "new": "..."}
--                       → open a new topic from a specific ancestor
--                          node; that node MUST be the current node
--                          or one of its ancestors.
--   3. chat_index_close_topic(tree_id, topic_node_mdo_id) — admin
--      manual override. Closes a topic by clearing
--      current_node_mdo_id if it points into the topic's subtree.
--
-- Out of scope at this migration:
--   * Live model-driven topic-opening decision (the LLM decides
--     "is this message a new topic?"). The append entrypoint exposes
--     `topic_branch` as a caller-supplied JSON field; the operator
--     wires up an LLM client that fills this in before calling
--     chat_index_append_messages.
--
-- Apply with:
--   ALTER EXTENSION maludb_core UPDATE TO '0.69.0';
-- =====================================================================

CREATE OR REPLACE FUNCTION maludb_core_version() RETURNS text
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$ SELECT '0.69.0'::text $body$;

-- =====================================================================
-- 1. malu$chat_index_append_audit
-- =====================================================================
CREATE TABLE malu$chat_index_append_audit (
    append_id              bigserial PRIMARY KEY,
    owner_schema           name NOT NULL DEFAULT current_schema(),
    tree_id                bigint NOT NULL
        REFERENCES malu$chat_index_tree(tree_id) ON DELETE CASCADE,
    appended_at            timestamptz NOT NULL DEFAULT now(),
    message_index_first    integer NOT NULL,
    message_index_last     integer NOT NULL,
    appended_message_count integer NOT NULL DEFAULT 0
        CHECK (appended_message_count >= 0),
    idempotent_hits        integer NOT NULL DEFAULT 0
        CHECK (idempotent_hits >= 0),
    opened_new_topic       boolean NOT NULL DEFAULT false,
    ancestor_branch_used   boolean NOT NULL DEFAULT false,
    branched_from_mdo_id   bigint,
    decision_reason        text
);
CREATE INDEX malu$chat_index_append_audit_tree_idx
    ON malu$chat_index_append_audit(tree_id, appended_at DESC);

ALTER TABLE malu$chat_index_append_audit ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_owner ON malu$chat_index_append_audit
    USING      (owner_schema = current_schema())
    WITH CHECK (owner_schema = current_schema());

GRANT SELECT ON malu$chat_index_append_audit TO
    maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;
GRANT INSERT ON malu$chat_index_append_audit TO
    maludb_memory_admin, maludb_memory_executor, maludb_queue_worker;
GRANT USAGE, SELECT ON SEQUENCE malu$chat_index_append_audit_append_id_seq TO
    maludb_memory_admin, maludb_memory_executor, maludb_queue_worker;

-- =====================================================================
-- 2. _chat_index_ancestor_chain — helper. Returns the set of mdo_ids
--    on the path from a given node up to (but not past) the topmost
--    topic, in deepest-first order.
-- =====================================================================
CREATE FUNCTION _chat_index_ancestor_chain(p_start_mdo_id bigint)
RETURNS TABLE (mdo_id bigint, depth integer)
LANGUAGE sql STABLE
AS $body$
    WITH RECURSIVE chain AS (
        SELECT m.mdo_id, m.parent_mdo_id, m.mdo_kind, 0 AS depth
          FROM malu$memory_detail_object m
         WHERE m.mdo_id = p_start_mdo_id
        UNION ALL
        SELECT m.mdo_id, m.parent_mdo_id, m.mdo_kind, c.depth + 1
          FROM malu$memory_detail_object m
          JOIN chain c ON c.parent_mdo_id = m.mdo_id
         WHERE m.mdo_kind IN ('chat_index_topic','chat_index_message')
    )
    SELECT mdo_id, depth FROM chain ORDER BY depth;
$body$;

-- =====================================================================
-- 3. chat_index_append_messages — append entry point.
-- =====================================================================
CREATE FUNCTION chat_index_append_messages(
    p_tree_id  bigint,
    p_messages jsonb
) RETURNS TABLE (
    message_index   integer,
    mdo_id          bigint,
    idempotent_hit  boolean)
LANGUAGE plpgsql VOLATILE
AS $body$
#variable_conflict use_column
DECLARE
    v_tree                 malu$chat_index_tree%ROWTYPE;
    v_msg                  jsonb;
    v_msg_index            integer;
    v_topic_mdo_id         bigint;
    v_branched_from        bigint := NULL;
    v_opened_new_topic     boolean := false;
    v_ancestor_used        boolean := false;
    v_existing_mdo         bigint;
    v_new_mdo              bigint;
    v_topic_name           text;
    v_from_ancestor        bigint;
    v_decision_reason      text := '';
    v_appended             integer := 0;
    v_idempotent           integer := 0;
    v_min_idx              integer := NULL;
    v_max_idx              integer := NULL;
    v_unused_deriv         bigint;
BEGIN
    -- Serialize concurrent appends on this tree (plan §11.5).
    SELECT * INTO v_tree
      FROM malu$chat_index_tree
     WHERE tree_id = p_tree_id
     FOR UPDATE;
    IF v_tree.tree_id IS NULL THEN
        RAISE EXCEPTION 'chat_index_append_messages: tree % not found',
            p_tree_id USING ERRCODE = 'no_data_found';
    END IF;
    IF v_tree.build_status NOT IN ('pending','building','ready') THEN
        RAISE EXCEPTION
            'chat_index_append_messages: tree % is %, cannot append',
            p_tree_id, v_tree.build_status
            USING ERRCODE = 'object_not_in_prerequisite_state';
    END IF;

    IF jsonb_typeof(p_messages) <> 'array' OR jsonb_array_length(p_messages) = 0 THEN
        RAISE EXCEPTION
            'chat_index_append_messages: p_messages must be a non-empty array'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    FOR v_msg IN SELECT * FROM jsonb_array_elements(p_messages)
    LOOP
        v_msg_index := (v_msg ->> 'message_index')::integer;
        IF v_msg_index IS NULL THEN
            RAISE EXCEPTION
                'chat_index_append_messages: each message needs message_index'
                USING ERRCODE = 'invalid_parameter_value';
        END IF;
        v_min_idx := LEAST(v_min_idx, v_msg_index);
        v_max_idx := GREATEST(v_max_idx, v_msg_index);

        -- Idempotency: a row with this (chat_tree_id, message_index)
        -- already exists -> return it.
        SELECT m.mdo_id INTO v_existing_mdo
          FROM malu$memory_detail_object m
         WHERE m.chat_tree_id  = p_tree_id
           AND m.message_index = v_msg_index
           AND m.mdo_kind      = 'chat_index_message';
        IF v_existing_mdo IS NOT NULL THEN
            v_idempotent := v_idempotent + 1;
            message_index  := v_msg_index;
            mdo_id         := v_existing_mdo;
            idempotent_hit := true;
            RETURN NEXT;
            CONTINUE;
        END IF;

        -- Decide topic attachment.
        IF v_msg ? 'topic_branch' AND (v_msg -> 'topic_branch') IS NOT NULL
           AND (v_msg -> 'topic_branch') <> 'null'::jsonb THEN
            v_topic_name := (v_msg -> 'topic_branch') ->> 'new';
            IF v_topic_name IS NULL OR v_topic_name = '' THEN
                RAISE EXCEPTION
                    'chat_index_append_messages: topic_branch.new (topic name) required'
                    USING ERRCODE = 'invalid_parameter_value';
            END IF;
            v_from_ancestor := NULLIF(
                (v_msg -> 'topic_branch') ->> 'from_ancestor_mdo_id', '')::bigint;

            -- Resolve "from" node: explicit ancestor or current.
            DECLARE
                v_from_node bigint;
                v_new_topic_parent bigint;
            BEGIN
                IF v_from_ancestor IS NOT NULL THEN
                    IF v_tree.current_node_mdo_id IS NULL THEN
                        RAISE EXCEPTION
                            'chat_index_append_messages: tree % has no current node; cannot branch from ancestor',
                            p_tree_id USING ERRCODE = 'invalid_parameter_value';
                    END IF;
                    -- Enforce ancestor-only rule: from_ancestor must be
                    -- the current node or one of its ancestors.
                    IF NOT EXISTS (
                        SELECT 1 FROM _chat_index_ancestor_chain(v_tree.current_node_mdo_id) c
                         WHERE c.mdo_id = v_from_ancestor
                    ) THEN
                        RAISE EXCEPTION
                            'chat_index_append_messages: from_ancestor_mdo_id % is not the current node or an ancestor of it',
                            v_from_ancestor USING ERRCODE = 'invalid_parameter_value';
                    END IF;
                    v_from_node := v_from_ancestor;
                    v_ancestor_used := true;
                    v_branched_from := v_from_ancestor;
                ELSE
                    v_from_node := v_tree.current_node_mdo_id;
                    v_branched_from := v_tree.current_node_mdo_id;
                END IF;

                -- Per upstream semantics: new topic is a sibling of
                -- the from-node, so new_topic.parent = parent_of(from).
                -- If from is NULL (empty tree), the new topic is a
                -- root topic with NULL parent.
                IF v_from_node IS NULL THEN
                    v_new_topic_parent := NULL;
                ELSE
                    SELECT parent_mdo_id INTO v_new_topic_parent
                      FROM malu$memory_detail_object
                     WHERE mdo_id = v_from_node;
                END IF;

                -- Create the new topic node (one for the whole batch).
                SELECT t.mdo_id INTO v_topic_mdo_id
                  FROM chat_index_record_topic(
                    p_tree_id, v_new_topic_parent, v_topic_name,
                    format('Auto-opened topic: %s', v_topic_name)) t;
            END;

            v_opened_new_topic := true;
            v_decision_reason := COALESCE(v_decision_reason || '; ', '')
                || format('opened topic "%s" from %s',
                          v_topic_name,
                          CASE WHEN v_ancestor_used THEN 'ancestor'
                               ELSE 'current' END);

            -- Refresh v_tree.current_node_mdo_id after the topic insert.
            SELECT current_node_mdo_id INTO v_tree.current_node_mdo_id
              FROM malu$chat_index_tree WHERE tree_id = p_tree_id;
        ELSE
            -- Extend the current topic. If no current topic exists,
            -- open a root topic with a default name.
            v_topic_mdo_id := NULL;
            IF v_tree.current_node_mdo_id IS NOT NULL THEN
                SELECT mdo_id INTO v_topic_mdo_id
                  FROM (SELECT m.mdo_id, m.mdo_kind
                          FROM _chat_index_ancestor_chain(
                                   v_tree.current_node_mdo_id) c
                          JOIN malu$memory_detail_object m ON m.mdo_id = c.mdo_id
                         ORDER BY c.depth) t
                 WHERE t.mdo_kind = 'chat_index_topic'
                 LIMIT 1;
            END IF;
            IF v_topic_mdo_id IS NULL THEN
                SELECT t.mdo_id INTO v_topic_mdo_id
                  FROM chat_index_record_topic(
                    p_tree_id, NULL, 'root',
                    'Auto-opened root topic') t;
                v_opened_new_topic := true;
                v_decision_reason := COALESCE(v_decision_reason || '; ', '')
                    || 'opened root topic';
                SELECT current_node_mdo_id INTO v_tree.current_node_mdo_id
                  FROM malu$chat_index_tree WHERE tree_id = p_tree_id;
            END IF;
        END IF;

        -- Record the message node under v_topic_mdo_id.
        SELECT t.mdo_id INTO v_new_mdo
          FROM chat_index_record_message(
            p_tree_id, v_topic_mdo_id, v_msg_index,
            v_msg ->> 'system_message',
            v_msg ->> 'user_message',
            v_msg ->> 'assistant_message',
            v_msg ->> 'summary') t;
        v_appended := v_appended + 1;

        -- Refresh current_node for the next iteration.
        SELECT current_node_mdo_id INTO v_tree.current_node_mdo_id
          FROM malu$chat_index_tree WHERE tree_id = p_tree_id;

        message_index  := v_msg_index;
        mdo_id         := v_new_mdo;
        idempotent_hit := false;
        RETURN NEXT;
    END LOOP;

    INSERT INTO malu$chat_index_append_audit
        (tree_id, message_index_first, message_index_last,
         appended_message_count, idempotent_hits,
         opened_new_topic, ancestor_branch_used,
         branched_from_mdo_id, decision_reason)
    VALUES (p_tree_id, COALESCE(v_min_idx, 0), COALESCE(v_max_idx, 0),
            v_appended, v_idempotent,
            v_opened_new_topic, v_ancestor_used,
            v_branched_from,
            NULLIF(v_decision_reason, ''));

    PERFORM audit_event('chat_index_tree.append',
        'chat_index_tree', p_tree_id,
        jsonb_build_object(
            'appended', v_appended,
            'idempotent_hits', v_idempotent,
            'opened_new_topic', v_opened_new_topic,
            'ancestor_branch_used', v_ancestor_used));
END;
$body$;

-- =====================================================================
-- 4. chat_index_close_topic — admin override. Clears the tree's
--    current_node_mdo_id pointer if it points into the subtree
--    rooted at the given topic node.
-- =====================================================================
CREATE FUNCTION chat_index_close_topic(
    p_tree_id            bigint,
    p_topic_node_mdo_id  bigint
) RETURNS void
LANGUAGE plpgsql
AS $body$
DECLARE
    v_current bigint;
    v_in_subtree boolean;
BEGIN
    IF NOT pg_has_role(session_user, 'maludb_memory_admin', 'MEMBER') THEN
        RAISE EXCEPTION 'chat_index_close_topic: requires maludb_memory_admin membership'
            USING ERRCODE = 'insufficient_privilege';
    END IF;

    SELECT current_node_mdo_id INTO v_current
      FROM malu$chat_index_tree WHERE tree_id = p_tree_id;
    IF v_current IS NULL THEN
        PERFORM audit_event('chat_index_tree.close_topic',
            'chat_index_tree', p_tree_id,
            jsonb_build_object('topic_node_mdo_id', p_topic_node_mdo_id,
                               'cleared', false,
                               'reason', 'no current node'));
        RETURN;
    END IF;

    SELECT EXISTS (
        SELECT 1 FROM _chat_index_ancestor_chain(v_current) c
         WHERE c.mdo_id = p_topic_node_mdo_id)
      INTO v_in_subtree;

    IF v_in_subtree THEN
        UPDATE malu$chat_index_tree
           SET current_node_mdo_id = NULL
         WHERE tree_id = p_tree_id;
    END IF;

    PERFORM audit_event('chat_index_tree.close_topic',
        'chat_index_tree', p_tree_id,
        jsonb_build_object('topic_node_mdo_id', p_topic_node_mdo_id,
                           'cleared', v_in_subtree));
END;
$body$;

GRANT EXECUTE ON FUNCTION
    _chat_index_ancestor_chain(bigint),
    chat_index_append_messages(bigint, jsonb),
    chat_index_close_topic(bigint, bigint)
TO maludb_memory_admin, maludb_memory_executor, maludb_queue_worker;
