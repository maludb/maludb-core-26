-- =====================================================================
-- maludb_core 0.67.0 -> 0.68.0  (V4 Stage 19 — V4-CHATINDEX-01)
--
-- Chat tree catalog.
--
-- The ChatIndex catalog mirrors the PageIndex catalog (V4-PAGEINDEX-01)
-- with chat-specific extensions on malu$memory_detail_object. The
-- design intentionally keeps `tree_id` pointing at malu$page_index_tree
-- and introduces a sibling `chat_tree_id` for chat-node rows so the
-- FK integrity remains unambiguous per node kind. The
-- mdo_tree_node_shape_check is refined to enforce the right shape per
-- mdo_kind.
--
-- What this migration adds:
--   1. malu$chat_index_tree — one header row per build generation,
--      with current_node_mdo_id (load-bearing in V4-CHATINDEX-02
--      incremental append), max_children, sub_node_count.
--   2. malu$memory_detail_object extended:
--      * chat_tree_id bigint FK -> malu$chat_index_tree
--      * topic_name text (for chat_index_topic rows)
--      * system_message text / user_message text / assistant_message
--        text / message_index int (for chat_index_message rows)
--      Existing tree_id stays FK -> malu$page_index_tree. The shape
--      check distinguishes by mdo_kind.
--   3. malu$derivation_ledger.derived_object_type admits
--      'chat_index_tree', 'chat_index_topic', 'chat_index_message'.
--   4. malu$relationship_edge source/target admits 'chat_index_tree'
--      so chat-tree supersession edges connect through the same
--      surface as page-tree edges.
--   5. SQL APIs (mirror of PageIndex):
--      * chat_index_tree_register / _mark_building / _mark_ready /
--        _mark_failed / _supersede.
--      * chat_index_record_topic — atomic MDO + ledger insert for
--        an internal topic node.
--      * chat_index_record_message — atomic MDO + ledger insert for
--        a leaf message node (system/user/assistant trio +
--        message_index).
--      * source_package_promote_to_chat_index — registers tree,
--        auto-registers the 'chatindex_build' V3-QUEUE-01 queue,
--        enqueues a build job, emits chat_index_tree.promote audit.
--
-- Out of scope at this migration:
--   * Incremental append + ancestor-only branching rule — that is
--     V4-CHATINDEX-02 (0.68.0 -> 0.69.0).
--   * Builder worker implementation in services/maludb-pageindexd/
--     (the existing service polls both queues; the Python side will
--     branch on parser_kind at the worker level in a follow-on).
--
-- Apply with:
--   ALTER EXTENSION maludb_core UPDATE TO '0.68.0';
-- =====================================================================

CREATE OR REPLACE FUNCTION maludb_core_version() RETURNS text
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$ SELECT '0.68.0'::text $body$;

-- =====================================================================
-- 1. malu$chat_index_tree
-- =====================================================================
CREATE TABLE malu$chat_index_tree (
    tree_id              bigserial PRIMARY KEY,
    owner_schema         name NOT NULL DEFAULT current_schema(),
    source_package_id    bigint NOT NULL
        REFERENCES malu$source_package(source_package_id) ON DELETE CASCADE,
    model_alias_id       bigint
        REFERENCES malu$model_alias(alias_id) ON DELETE SET NULL,
    prompt_template_id   bigint
        REFERENCES malu$prompt_template(template_id) ON DELETE SET NULL,
    build_status         text NOT NULL DEFAULT 'pending'
        CHECK (build_status IN (
            'pending','building','ready','stale','superseded','failed')),
    -- V4-CHATINDEX-02: load-bearing pointer into malu$memory_detail_object.
    -- Set to the most-recently-appended topic (internal) or message
    -- (leaf) so subsequent appends can decide extend-current vs.
    -- open-new-topic-from-ancestor.
    current_node_mdo_id  bigint,
    max_children         integer NOT NULL DEFAULT 10
        CHECK (max_children > 0),
    sub_node_count       integer NOT NULL DEFAULT 0
        CHECK (sub_node_count >= 0),
    build_started_at     timestamptz,
    build_finished_at    timestamptz,
    failure_reason       text,
    superseded_by        bigint
        REFERENCES malu$chat_index_tree(tree_id) ON DELETE SET NULL,
    valid_time_start     timestamptz NOT NULL DEFAULT now(),
    valid_time_end       timestamptz,
    created_at           timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX malu$chat_index_tree_owner_idx
    ON malu$chat_index_tree(owner_schema);
CREATE INDEX malu$chat_index_tree_source_idx
    ON malu$chat_index_tree(source_package_id);
CREATE INDEX malu$chat_index_tree_status_idx
    ON malu$chat_index_tree(build_status);
CREATE INDEX malu$chat_index_tree_current_idx
    ON malu$chat_index_tree(current_node_mdo_id)
    WHERE current_node_mdo_id IS NOT NULL;

ALTER TABLE malu$chat_index_tree ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_owner ON malu$chat_index_tree
    USING      (owner_schema = current_schema())
    WITH CHECK (owner_schema = current_schema());

GRANT SELECT ON malu$chat_index_tree TO
    maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;
GRANT INSERT, UPDATE ON malu$chat_index_tree TO
    maludb_memory_admin, maludb_memory_executor, maludb_queue_worker;
GRANT USAGE, SELECT ON SEQUENCE malu$chat_index_tree_tree_id_seq TO
    maludb_memory_admin, maludb_memory_executor, maludb_queue_worker;

-- =====================================================================
-- 2. Extend malu$memory_detail_object with chat-node columns.
-- =====================================================================
ALTER TABLE malu$memory_detail_object
    ADD COLUMN chat_tree_id        bigint
        REFERENCES malu$chat_index_tree(tree_id) ON DELETE CASCADE,
    ADD COLUMN topic_name          text,
    ADD COLUMN system_message      text,
    ADD COLUMN user_message        text,
    ADD COLUMN assistant_message   text,
    ADD COLUMN message_index       integer;

-- Tighten the existing shape check to require the right anchor per
-- mdo_kind.
ALTER TABLE malu$memory_detail_object
    DROP CONSTRAINT malu$mdo_tree_node_shape_check;
ALTER TABLE malu$memory_detail_object
    ADD CONSTRAINT malu$mdo_tree_node_shape_check CHECK (
        (mdo_kind = 'memory_detail'
            AND tree_id IS NULL
            AND chat_tree_id IS NULL
            AND node_kind IS NULL)
        OR (mdo_kind = 'page_index_node'
            AND tree_id IS NOT NULL
            AND chat_tree_id IS NULL
            AND node_kind IS NOT NULL)
        OR (mdo_kind IN ('chat_index_topic','chat_index_message')
            AND chat_tree_id IS NOT NULL
            AND tree_id IS NULL
            AND node_kind IS NOT NULL));

-- Relax the Stage-2 anchor check further to admit chat_tree_id.
ALTER TABLE malu$memory_detail_object
    DROP CONSTRAINT "malu$memory_detail_object_check";
ALTER TABLE malu$memory_detail_object
    ADD CONSTRAINT "malu$memory_detail_object_check" CHECK (
        parent_mdo_id IS NOT NULL
        OR memory_id   IS NOT NULL
        OR episode_id  IS NOT NULL
        OR tree_id     IS NOT NULL
        OR chat_tree_id IS NOT NULL);

CREATE INDEX malu$mdo_chat_tree_idx
    ON malu$memory_detail_object(chat_tree_id)
    WHERE chat_tree_id IS NOT NULL;
CREATE INDEX malu$mdo_chat_message_idx
    ON malu$memory_detail_object(chat_tree_id, message_index)
    WHERE chat_tree_id IS NOT NULL AND message_index IS NOT NULL;

-- =====================================================================
-- 3. Extend malu$derivation_ledger.derived_object_type.
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
        'retrieval_summary',
        'chat_index_tree',
        'chat_index_topic',
        'chat_index_message'
    ));

-- =====================================================================
-- 4. Extend malu$relationship_edge source/target CHECK.
-- =====================================================================
ALTER TABLE malu$relationship_edge
    DROP CONSTRAINT malu$relationship_edge_source_object_type_check;
ALTER TABLE malu$relationship_edge
    ADD CONSTRAINT malu$relationship_edge_source_object_type_check
    CHECK (source_object_type IN (
        'source_package','claim','fact','memory','episode_object',
        'memory_detail_object','page_index_tree','chat_index_tree'));

ALTER TABLE malu$relationship_edge
    DROP CONSTRAINT malu$relationship_edge_target_object_type_check;
ALTER TABLE malu$relationship_edge
    ADD CONSTRAINT malu$relationship_edge_target_object_type_check
    CHECK (target_object_type IN (
        'source_package','claim','fact','memory','episode_object',
        'memory_detail_object','page_index_tree','chat_index_tree'));

-- =====================================================================
-- 5. SQL APIs.
-- =====================================================================

CREATE FUNCTION chat_index_tree_register(
    p_source_package_id  bigint,
    p_model_alias_id     bigint DEFAULT NULL,
    p_prompt_template_id bigint DEFAULT NULL,
    p_max_children       integer DEFAULT 10
) RETURNS bigint
LANGUAGE plpgsql
AS $body$
DECLARE v_tree_id bigint;
BEGIN
    INSERT INTO malu$chat_index_tree
        (source_package_id, model_alias_id, prompt_template_id, max_children)
    VALUES (p_source_package_id, p_model_alias_id, p_prompt_template_id, p_max_children)
    RETURNING tree_id INTO v_tree_id;

    PERFORM audit_event(
        'chat_index_tree.register',
        'chat_index_tree', v_tree_id,
        jsonb_build_object(
            'source_package_id', p_source_package_id,
            'model_alias_id',    p_model_alias_id,
            'prompt_template_id',p_prompt_template_id,
            'max_children',      p_max_children));
    RETURN v_tree_id;
END;
$body$;

CREATE FUNCTION chat_index_tree_mark_building(p_tree_id bigint)
RETURNS void
LANGUAGE plpgsql
AS $body$
BEGIN
    UPDATE malu$chat_index_tree
       SET build_status     = 'building',
           build_started_at = COALESCE(build_started_at, now())
     WHERE tree_id = p_tree_id
       AND build_status IN ('pending','failed');
    IF NOT FOUND THEN
        RAISE EXCEPTION
            'chat_index_tree_mark_building: tree % not in pending/failed state',
            p_tree_id USING ERRCODE = 'invalid_parameter_value';
    END IF;
    PERFORM audit_event('chat_index_tree.mark_building',
        'chat_index_tree', p_tree_id);
END;
$body$;

CREATE FUNCTION chat_index_tree_mark_ready(p_tree_id bigint)
RETURNS void
LANGUAGE plpgsql
AS $body$
BEGIN
    UPDATE malu$chat_index_tree
       SET build_status      = 'ready',
           build_finished_at = now()
     WHERE tree_id = p_tree_id
       AND build_status = 'building';
    IF NOT FOUND THEN
        RAISE EXCEPTION
            'chat_index_tree_mark_ready: tree % not in building state',
            p_tree_id USING ERRCODE = 'invalid_parameter_value';
    END IF;
    PERFORM audit_event('chat_index_tree.mark_ready',
        'chat_index_tree', p_tree_id);
END;
$body$;

CREATE FUNCTION chat_index_tree_mark_failed(
    p_tree_id bigint,
    p_reason  text DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql
AS $body$
BEGIN
    UPDATE malu$chat_index_tree
       SET build_status      = 'failed',
           build_finished_at = now(),
           failure_reason    = p_reason
     WHERE tree_id = p_tree_id
       AND build_status IN ('pending','building');
    IF NOT FOUND THEN
        RAISE EXCEPTION
            'chat_index_tree_mark_failed: tree % not in pending/building state',
            p_tree_id USING ERRCODE = 'invalid_parameter_value';
    END IF;
    PERFORM audit_event('chat_index_tree.mark_failed',
        'chat_index_tree', p_tree_id,
        jsonb_build_object('reason', p_reason));
END;
$body$;

CREATE FUNCTION chat_index_tree_supersede(
    p_prior_tree_id bigint,
    p_new_tree_id   bigint
) RETURNS bigint
LANGUAGE plpgsql
AS $body$
DECLARE v_edge_id bigint;
BEGIN
    IF p_prior_tree_id = p_new_tree_id THEN
        RAISE EXCEPTION 'chat_index_tree_supersede: prior and new tree must differ'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    UPDATE malu$chat_index_tree
       SET build_status   = 'superseded',
           superseded_by  = p_new_tree_id,
           valid_time_end = now()
     WHERE tree_id = p_prior_tree_id
       AND build_status IN ('ready','stale');
    IF NOT FOUND THEN
        RAISE EXCEPTION
            'chat_index_tree_supersede: prior tree % not in ready/stale state',
            p_prior_tree_id USING ERRCODE = 'invalid_parameter_value';
    END IF;

    v_edge_id := register_relationship_edge(
        'chat_index_tree', p_prior_tree_id,
        'chat_index_tree', p_new_tree_id,
        'supersedes',
        NULL,
        jsonb_build_object('prior_tree', p_prior_tree_id,
                           'new_tree',   p_new_tree_id),
        NULL);

    PERFORM audit_event(
        'chat_index_tree.supersede',
        'chat_index_tree', p_prior_tree_id,
        jsonb_build_object('new_tree_id', p_new_tree_id,
                           'edge_id',     v_edge_id));
    RETURN v_edge_id;
END;
$body$;

-- chat_index_record_topic — internal topic node. NULL parent means
-- the topic attaches at the root of the tree.
CREATE FUNCTION chat_index_record_topic(
    p_tree_id              bigint,
    p_parent_mdo_id        bigint,
    p_topic_name           text,
    p_summary              text,
    p_model_alias_id       bigint   DEFAULT NULL,
    p_prompt_template_id   bigint   DEFAULT NULL
) RETURNS TABLE (mdo_id bigint, derivation_id bigint)
LANGUAGE plpgsql
AS $body$
#variable_conflict use_column
DECLARE
    v_mdo_id   bigint;
    v_deriv_id bigint;
BEGIN
    INSERT INTO malu$memory_detail_object
        (parent_mdo_id, detail_kind, mdo_kind,
         chat_tree_id, node_kind,
         topic_name, summary)
    VALUES (p_parent_mdo_id, 'chat_index_topic', 'chat_index_topic',
            p_tree_id, 'internal',
            p_topic_name, p_summary)
    RETURNING mdo_id INTO v_mdo_id;

    v_deriv_id := record_derivation(
        'chat_index_topic', v_mdo_id,
        NULL, p_model_alias_id, p_prompt_template_id,
        NULL, NULL, NULL,
        jsonb_build_object('tree_id', p_tree_id,
                           'parent_mdo_id', p_parent_mdo_id,
                           'topic_name', p_topic_name));

    -- Advance the tree's current_node_mdo_id pointer + sub_node_count.
    UPDATE malu$chat_index_tree
       SET current_node_mdo_id = v_mdo_id,
           sub_node_count = sub_node_count + 1
     WHERE tree_id = p_tree_id;

    RETURN QUERY SELECT v_mdo_id, v_deriv_id;
END;
$body$;

-- chat_index_record_message — leaf message node carrying the
-- system/user/assistant trio.
CREATE FUNCTION chat_index_record_message(
    p_tree_id              bigint,
    p_topic_mdo_id         bigint,
    p_message_index        integer,
    p_system_message       text     DEFAULT NULL,
    p_user_message         text     DEFAULT NULL,
    p_assistant_message    text     DEFAULT NULL,
    p_summary              text     DEFAULT NULL,
    p_model_alias_id       bigint   DEFAULT NULL,
    p_prompt_template_id   bigint   DEFAULT NULL
) RETURNS TABLE (mdo_id bigint, derivation_id bigint)
LANGUAGE plpgsql
AS $body$
#variable_conflict use_column
DECLARE
    v_mdo_id    bigint;
    v_deriv_id  bigint;
    v_title     text;
BEGIN
    IF p_system_message IS NULL
       AND p_user_message IS NULL
       AND p_assistant_message IS NULL THEN
        RAISE EXCEPTION
            'chat_index_record_message: at least one of system/user/assistant must be non-null'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    v_title := format('msg#%s', p_message_index);

    INSERT INTO malu$memory_detail_object
        (parent_mdo_id, detail_kind, mdo_kind,
         chat_tree_id, node_kind,
         title, summary,
         system_message, user_message, assistant_message,
         message_index)
    VALUES (p_topic_mdo_id, 'chat_index_message', 'chat_index_message',
            p_tree_id, 'leaf',
            v_title, p_summary,
            p_system_message, p_user_message, p_assistant_message,
            p_message_index)
    RETURNING mdo_id INTO v_mdo_id;

    v_deriv_id := record_derivation(
        'chat_index_message', v_mdo_id,
        NULL, p_model_alias_id, p_prompt_template_id,
        NULL, NULL, NULL,
        jsonb_build_object('tree_id', p_tree_id,
                           'topic_mdo_id', p_topic_mdo_id,
                           'message_index', p_message_index));

    UPDATE malu$chat_index_tree
       SET current_node_mdo_id = v_mdo_id,
           sub_node_count = sub_node_count + 1
     WHERE tree_id = p_tree_id;

    RETURN QUERY SELECT v_mdo_id, v_deriv_id;
END;
$body$;

-- source_package_promote_to_chat_index — operator-facing promotion.
CREATE FUNCTION source_package_promote_to_chat_index(
    p_source_package_id    bigint,
    p_model_alias_id       bigint  DEFAULT NULL,
    p_prompt_template_id   bigint  DEFAULT NULL,
    p_max_children         integer DEFAULT 10,
    p_builder_options      jsonb   DEFAULT '{}'::jsonb
) RETURNS bigint
LANGUAGE plpgsql
AS $body$
#variable_conflict use_column
DECLARE
    v_tree_id      bigint;
    v_queue_job_id bigint;
BEGIN
    v_tree_id := chat_index_tree_register(
        p_source_package_id, p_model_alias_id, p_prompt_template_id, p_max_children);

    PERFORM queue_register('chatindex_build', 120000, 3, NULL,
        'V4-CHATINDEX-01 tree builder job queue');

    v_queue_job_id := queue_enqueue(
        'chatindex_build',
        jsonb_build_object(
            'tree_id',            v_tree_id,
            'source_package_id',  p_source_package_id,
            'model_alias_id',     p_model_alias_id,
            'prompt_template_id', p_prompt_template_id,
            'max_children',       p_max_children,
            'builder_options',    p_builder_options),
        format('chatindex:%s', v_tree_id),
        0, NULL, NULL);

    PERFORM audit_event(
        'chat_index_tree.promote',
        'chat_index_tree', v_tree_id,
        jsonb_build_object(
            'source_package_id', p_source_package_id,
            'queue_job_id',      v_queue_job_id,
            'builder_options',   p_builder_options));
    RETURN v_tree_id;
END;
$body$;

GRANT EXECUTE ON FUNCTION
    chat_index_tree_register(bigint, bigint, bigint, integer),
    chat_index_tree_mark_building(bigint),
    chat_index_tree_mark_ready(bigint),
    chat_index_tree_mark_failed(bigint, text),
    chat_index_tree_supersede(bigint, bigint),
    chat_index_record_topic(bigint, bigint, text, text, bigint, bigint),
    chat_index_record_message(bigint, bigint, integer, text, text, text, text, bigint, bigint),
    source_package_promote_to_chat_index(bigint, bigint, bigint, integer, jsonb)
TO maludb_memory_admin, maludb_memory_executor, maludb_queue_worker;
