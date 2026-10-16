-- V4 Stage 19 V4-CHATINDEX-02 — incremental append.
--
-- Seven cases per the V4 plan:
--   1. Append to an empty tree opens a root topic and lands the
--      message under it.
--   2. Append without topic_branch extends the current topic.
--   3. Append with topic_branch={new:'X'} opens a new topic from the
--      current node (audit row records opened_new_topic=true).
--   4. Append with topic_branch={from_ancestor_mdo_id:A, new:'X'}
--      opens a topic from a named ancestor (audit row records
--      ancestor_branch_used=true).
--   5. Append with from_ancestor_mdo_id pointing at a non-ancestor
--      is rejected.
--   6. Duplicate message_index is idempotent — returns the existing
--      mdo_id rather than inserting a duplicate, and increments
--      idempotent_hits in the audit row.
--   7. RLS isolation: tenant B cannot append to tenant A's chat tree.

\set ECHO all
SET search_path = maludb_core, public;
SET client_min_messages = NOTICE;

-- ---------- fixture ----------------------------------------------------
SELECT register_source_package(
    p_source_type  => 'conversation',
    p_content_text => '{}',
    p_media_type   => 'application/json'
) AS sp_id \gset

SELECT chat_index_tree_register(:sp_id) AS tree_id \gset
SELECT chat_index_tree_mark_building(:tree_id);
SELECT chat_index_tree_mark_ready(:tree_id);

-- ====================================================================
-- 1. Append on empty tree -> auto-opens root topic.
-- ====================================================================
SELECT message_index, idempotent_hit
FROM chat_index_append_messages(:tree_id,
    jsonb_build_array(
        jsonb_build_object(
            'message_index', 0,
            'user_message', 'first message',
            'assistant_message', 'first reply')));

SELECT opened_new_topic, ancestor_branch_used,
       appended_message_count, idempotent_hits,
       decision_reason
FROM malu$chat_index_append_audit
WHERE tree_id = :tree_id
ORDER BY append_id DESC LIMIT 1;

-- Tree carries the new topic + message.
SELECT count(*) FILTER (WHERE mdo_kind='chat_index_topic')   AS topics_after_1,
       count(*) FILTER (WHERE mdo_kind='chat_index_message') AS messages_after_1
FROM malu$memory_detail_object WHERE chat_tree_id = :tree_id;

-- ====================================================================
-- 2. Append without topic_branch -> extends current topic.
-- ====================================================================
SELECT message_index FROM chat_index_append_messages(:tree_id,
    jsonb_build_array(
        jsonb_build_object(
            'message_index', 1,
            'user_message', 'second message',
            'assistant_message', 'second reply')));

SELECT count(*) FILTER (WHERE mdo_kind='chat_index_topic')   AS topics_after_2,
       count(*) FILTER (WHERE mdo_kind='chat_index_message') AS messages_after_2
FROM malu$memory_detail_object WHERE chat_tree_id = :tree_id;

SELECT opened_new_topic, decision_reason
FROM malu$chat_index_append_audit
WHERE tree_id = :tree_id
ORDER BY append_id DESC LIMIT 1;

-- ====================================================================
-- 3. Append with new topic from current.
-- ====================================================================
SELECT message_index FROM chat_index_append_messages(:tree_id,
    jsonb_build_array(
        jsonb_build_object(
            'message_index', 2,
            'user_message', 'pivot to a new subject',
            'assistant_message', 'sure',
            'topic_branch', jsonb_build_object('new', 'Side Topic'))));

SELECT opened_new_topic, ancestor_branch_used, decision_reason
FROM malu$chat_index_append_audit
WHERE tree_id = :tree_id
ORDER BY append_id DESC LIMIT 1;

-- Confirm new topic exists with the given name.
SELECT topic_name
FROM malu$memory_detail_object
WHERE chat_tree_id = :tree_id
  AND mdo_kind = 'chat_index_topic'
ORDER BY mdo_id;

-- ====================================================================
-- 4. Append with from_ancestor_mdo_id pointing at the root topic.
-- ====================================================================
SELECT mdo_id INTO TEMP TABLE _root_topic
FROM malu$memory_detail_object
WHERE chat_tree_id = :tree_id
  AND mdo_kind = 'chat_index_topic'
ORDER BY mdo_id LIMIT 1;

SELECT message_index
FROM chat_index_append_messages(:tree_id,
    jsonb_build_array(
        jsonb_build_object(
            'message_index', 3,
            'user_message', 'back to original subject',
            'assistant_message', 'understood',
            'topic_branch', jsonb_build_object(
                'new', 'Branched From Root',
                'from_ancestor_mdo_id',
                (SELECT mdo_id FROM _root_topic)))));

SELECT opened_new_topic, ancestor_branch_used,
       branched_from_mdo_id = (SELECT mdo_id FROM _root_topic) AS branched_from_root
FROM malu$chat_index_append_audit
WHERE tree_id = :tree_id
ORDER BY append_id DESC LIMIT 1;

-- ====================================================================
-- 5. from_ancestor_mdo_id pointing at a non-ancestor is rejected.
-- ====================================================================
-- Create a second tree to get a node that is NOT an ancestor of the
-- current node in tree_id.
SELECT chat_index_tree_register(:sp_id) AS unrelated_tree \gset
SELECT chat_index_tree_mark_building(:unrelated_tree);
SELECT chat_index_tree_mark_ready(:unrelated_tree);
SELECT mdo_id INTO TEMP TABLE _unrelated_topic
FROM chat_index_record_topic(:unrelated_tree, NULL, 'unrelated', 'unrelated topic');

DO $body$
DECLARE v_unrelated bigint;
BEGIN
    SELECT mdo_id INTO v_unrelated FROM _unrelated_topic LIMIT 1;
    BEGIN
        PERFORM chat_index_append_messages(
            (SELECT tree_id FROM malu$chat_index_tree
             WHERE max_children = 10 AND build_status = 'ready'
             ORDER BY tree_id LIMIT 1),
            jsonb_build_array(
                jsonb_build_object(
                    'message_index', 99,
                    'user_message', 'bogus branch',
                    'topic_branch', jsonb_build_object(
                        'new', 'Bogus',
                        'from_ancestor_mdo_id', v_unrelated))));
        RAISE EXCEPTION 'non-ancestor branch should have been rejected';
    EXCEPTION WHEN invalid_parameter_value THEN
        RAISE NOTICE 'OK: non-ancestor branch rejected';
    END;
END $body$;

-- ====================================================================
-- 6. Duplicate message_index is idempotent.
-- ====================================================================
SELECT count(*) AS messages_before_dup
FROM malu$memory_detail_object
WHERE chat_tree_id = :tree_id AND mdo_kind = 'chat_index_message';

SELECT message_index, idempotent_hit
FROM chat_index_append_messages(:tree_id,
    jsonb_build_array(
        jsonb_build_object(
            'message_index', 0,
            'user_message', 'duplicate'),
        jsonb_build_object(
            'message_index', 4,
            'user_message', 'new')));

SELECT count(*) AS messages_after_dup
FROM malu$memory_detail_object
WHERE chat_tree_id = :tree_id AND mdo_kind = 'chat_index_message';

SELECT idempotent_hits, appended_message_count
FROM malu$chat_index_append_audit
WHERE tree_id = :tree_id
ORDER BY append_id DESC LIMIT 1;

-- ====================================================================
-- 7. RLS isolation.
-- ====================================================================
DROP ROLE   IF EXISTS ci2_user_a;
DROP ROLE   IF EXISTS ci2_user_b;
DROP SCHEMA IF EXISTS ci2_a CASCADE;
DROP SCHEMA IF EXISTS ci2_b CASCADE;
CREATE ROLE ci2_user_a NOLOGIN;
CREATE ROLE ci2_user_b NOLOGIN;
GRANT maludb_memory_executor TO ci2_user_a, ci2_user_b;
GRANT USAGE ON SCHEMA maludb_core TO ci2_user_a, ci2_user_b;
CREATE SCHEMA ci2_a AUTHORIZATION ci2_user_a;
CREATE SCHEMA ci2_b AUTHORIZATION ci2_user_b;

SET ROLE ci2_user_a;
SET search_path TO ci2_a, maludb_core, public;
SELECT register_source_package('conversation', NULL, '{}', NULL, 'application/json')
       AS sp_a \gset
SELECT chat_index_tree_register(:sp_a) AS priv_tree \gset
SELECT chat_index_tree_mark_building(:priv_tree);
SELECT chat_index_tree_mark_ready(:priv_tree);

SET ROLE ci2_user_b;
SET search_path TO ci2_b, maludb_core, public;
DO $body$
DECLARE v_tree bigint;
BEGIN
    SELECT tree_id INTO v_tree FROM maludb_core.malu$chat_index_tree
     WHERE owner_schema = 'ci2_a' LIMIT 1;
    BEGIN
        PERFORM chat_index_append_messages(v_tree,
            jsonb_build_array(jsonb_build_object(
                'message_index', 0, 'user_message', 'sneak')));
        RAISE EXCEPTION 'cross-tenant append should have been rejected';
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'OK: cross-tenant append rejected (%)', SQLSTATE;
    END;
END $body$;

RESET ROLE;
RESET search_path;
SET search_path TO maludb_core, public;

-- ---------- cleanup --------------------------------------------------
DROP TABLE _root_topic;
DROP TABLE _unrelated_topic;
DELETE FROM malu$chat_index_tree WHERE owner_schema IN ('ci2_a','ci2_b');
DELETE FROM malu$source_package  WHERE owner_schema IN ('ci2_a','ci2_b');
DROP SCHEMA ci2_a CASCADE;
DROP SCHEMA ci2_b CASCADE;
DROP OWNED BY ci2_user_a;
DROP OWNED BY ci2_user_b;
DROP ROLE   ci2_user_a;
DROP ROLE   ci2_user_b;
