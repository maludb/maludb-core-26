-- V4 Stage 19 V4-CHATINDEX-01 — Chat tree catalog smoke test.
--
-- Six cases:
--   1. chat_index_tree_register / status transitions / wrong-state
--      guards mirror PageIndex catalog (V4-PAGEINDEX-01).
--   2. chat_index_record_topic inserts an internal node with the
--      chat-payload columns NULL except topic_name; sub_node_count
--      and current_node_mdo_id advance on the tree.
--   3. chat_index_record_message inserts a leaf with the
--      system/user/assistant trio + message_index; current_node_mdo_id
--      advances; rejected when all three messages are NULL.
--   4. Discriminator shape: tree_id and chat_tree_id are mutually
--      exclusive per row, enforced by malu$mdo_tree_node_shape_check.
--   5. Derivation Ledger admits the new chat_index_* derived types.
--   6. Supersession: chat_index_tree_supersede flips status + writes
--      a 'supersedes' relationship_edge.
--   7. RLS isolation across two tenants.

\set ECHO all
SET search_path = maludb_core, public;
SET client_min_messages = NOTICE;

-- ---------- fixture ----------------------------------------------------
SELECT register_source_package(
    p_source_type  => 'conversation',
    p_content_text => '{"messages": []}',
    p_media_type   => 'application/json'
) AS sp_id \gset

-- ====================================================================
-- 1. Register, status transitions.
-- ====================================================================
SELECT chat_index_tree_register(:sp_id) AS tree_a \gset

SELECT build_status, source_package_id = :sp_id AS source_matches,
       max_children, sub_node_count, current_node_mdo_id IS NULL AS empty_current
FROM malu$chat_index_tree WHERE tree_id = :tree_a;

SELECT chat_index_tree_mark_building(:tree_a);
SELECT build_status FROM malu$chat_index_tree WHERE tree_id = :tree_a;

DO $body$
BEGIN
    PERFORM chat_index_tree_mark_ready(
        (SELECT tree_id FROM malu$chat_index_tree
         WHERE build_status = 'pending' LIMIT 1));
    RAISE EXCEPTION 'should have rejected mark_ready on pending tree';
EXCEPTION WHEN invalid_parameter_value OR no_data_found THEN
    RAISE NOTICE 'OK: mark_ready rejects pending tree';
END $body$;

-- ====================================================================
-- 2. Record a root topic.
-- ====================================================================
SELECT mdo_id FROM chat_index_record_topic(
    :tree_a, NULL, 'Greetings', 'Top-level greeting topic.')
\gset root_topic_

SELECT mdo_kind, node_kind, topic_name, summary,
       chat_tree_id = :tree_a AS attached,
       tree_id IS NULL AS no_page_tree
FROM malu$memory_detail_object WHERE mdo_id = :root_topic_mdo_id;

-- Tree pointer advanced.
SELECT sub_node_count, current_node_mdo_id = :root_topic_mdo_id AS pointer_advanced
FROM malu$chat_index_tree WHERE tree_id = :tree_a;

-- ====================================================================
-- 3. Record a message under the topic.
-- ====================================================================
SELECT mdo_id FROM chat_index_record_message(
    :tree_a, :root_topic_mdo_id,
    p_message_index   => 0,
    p_user_message    => 'Hello!',
    p_assistant_message => 'Hi there.',
    p_summary         => 'opening exchange')
\gset msg0_

SELECT mdo_kind, node_kind, message_index,
       user_message, assistant_message
FROM malu$memory_detail_object WHERE mdo_id = :msg0_mdo_id;

-- Rejected when all three message fields are NULL.
DO $body$
BEGIN
    PERFORM chat_index_record_message(
        (SELECT tree_id FROM malu$chat_index_tree LIMIT 1),
        (SELECT mdo_id FROM malu$memory_detail_object
         WHERE mdo_kind='chat_index_topic' LIMIT 1),
        99);
    RAISE EXCEPTION 'should have rejected empty message';
EXCEPTION WHEN invalid_parameter_value THEN
    RAISE NOTICE 'OK: empty message rejected';
END $body$;

-- ====================================================================
-- 4. Shape constraint: chat_tree_id without chat mdo_kind is rejected.
-- ====================================================================
DO $body$
BEGIN
    INSERT INTO malu$memory_detail_object
        (owner_schema, detail_kind, mdo_kind,
         chat_tree_id, node_kind)
    VALUES (current_schema(), 'step', 'memory_detail',
            (SELECT tree_id FROM malu$chat_index_tree LIMIT 1), NULL);
    RAISE EXCEPTION 'memory_detail with chat_tree_id should be rejected';
EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'OK: memory_detail cannot carry chat_tree_id';
END $body$;

-- chat_index_topic with NULL chat_tree_id is rejected.
DO $body$
BEGIN
    INSERT INTO malu$memory_detail_object
        (owner_schema, detail_kind, mdo_kind, node_kind, topic_name)
    VALUES (current_schema(), 'chat_index_topic', 'chat_index_topic',
            'internal', 'orphan');
    RAISE EXCEPTION 'orphan chat topic should be rejected';
EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'OK: chat_index_topic requires chat_tree_id';
END $body$;

-- ====================================================================
-- 5. Derivation Ledger admits chat_index_* derived types.
-- ====================================================================
SELECT derived_object_type
FROM malu$derivation_ledger
WHERE derived_object_id IN (:root_topic_mdo_id, :msg0_mdo_id)
  AND derived_object_type IN ('chat_index_topic','chat_index_message')
ORDER BY derived_object_type;

-- ====================================================================
-- 6. Supersession.
-- ====================================================================
SELECT chat_index_tree_mark_ready(:tree_a);
SELECT chat_index_tree_register(:sp_id) AS tree_b \gset
SELECT chat_index_tree_mark_building(:tree_b);
SELECT chat_index_tree_mark_ready(:tree_b);

SELECT chat_index_tree_supersede(:tree_a, :tree_b) AS edge_id \gset

SELECT build_status, superseded_by = :tree_b AS points_at_new
FROM malu$chat_index_tree WHERE tree_id = :tree_a;

SELECT relationship_type, source_object_type, target_object_type
FROM malu$relationship_edge WHERE edge_id = :edge_id;

-- ====================================================================
-- 7. RLS isolation.
-- ====================================================================
DROP ROLE   IF EXISTS ci1_user_a;
DROP ROLE   IF EXISTS ci1_user_b;
DROP SCHEMA IF EXISTS ci1_a CASCADE;
DROP SCHEMA IF EXISTS ci1_b CASCADE;
CREATE ROLE ci1_user_a NOLOGIN;
CREATE ROLE ci1_user_b NOLOGIN;
GRANT maludb_memory_executor TO ci1_user_a, ci1_user_b;
GRANT USAGE ON SCHEMA maludb_core TO ci1_user_a, ci1_user_b;
CREATE SCHEMA ci1_a AUTHORIZATION ci1_user_a;
CREATE SCHEMA ci1_b AUTHORIZATION ci1_user_b;

SET ROLE ci1_user_a;
SET search_path TO ci1_a, maludb_core, public;
SELECT register_source_package(
    p_source_type => 'conversation',
    p_content_text => '{}',
    p_media_type => 'application/json'
) AS sp_a \gset
SELECT chat_index_tree_register(:sp_a) AS priv_tree \gset

SELECT count(*) AS visible_to_a
FROM maludb_core.malu$chat_index_tree WHERE tree_id = :priv_tree;

SET ROLE ci1_user_b;
SET search_path TO ci1_b, maludb_core, public;
SELECT count(*) AS visible_to_b
FROM maludb_core.malu$chat_index_tree WHERE tree_id = :priv_tree;

RESET ROLE;
RESET search_path;
SET search_path TO maludb_core, public;

-- ---------- cleanup --------------------------------------------------
DELETE FROM malu$chat_index_tree   WHERE owner_schema IN ('ci1_a','ci1_b');
DELETE FROM malu$source_package    WHERE owner_schema IN ('ci1_a','ci1_b');
DROP SCHEMA ci1_a CASCADE;
DROP SCHEMA ci1_b CASCADE;
DROP OWNED BY ci1_user_a;
DROP OWNED BY ci1_user_b;
DROP ROLE   ci1_user_a;
DROP ROLE   ci1_user_b;
