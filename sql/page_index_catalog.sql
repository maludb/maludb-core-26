-- V4 Stage 17 V4-PAGEINDEX-01 — PageIndex tree catalog smoke test.
--
-- Exercises:
--   1. page_index_tree_register creates a 'pending' row with audit.
--   2. Status transitions: pending → building → ready, pending → failed,
--      and the wrong-state guards on each transition function.
--   3. MDO discriminator default keeps existing memory_detail rows
--      shaped exactly as before; tree-node insertion requires the
--      tree_id + node_kind shape constraint.
--   4. Existing MDO consumer behavior: a memory_detail register call
--      produces a row whose mdo_kind defaults to 'memory_detail' and
--      whose tree_id / node_kind / title / summary are all NULL.
--   5. Derivation Ledger admits 'page_index_tree' and 'page_index_node'
--      as derived_object_type values.
--   6. Supersession: page_index_tree_supersede closes the prior tree,
--      sets superseded_by, and writes a 'supersedes' relationship_edge
--      row connecting the two trees.
--   7. RLS isolation: a tenant cannot see another tenant's tree row.
--   8. Stage-boundary check: V4-PAGEINDEX-02+ surfaces (promotion
--      helper, builder enqueue, structure-pass audit) do NOT exist yet.

\set ECHO all
SET search_path = maludb_core, public;
SET client_min_messages = NOTICE;

-- ---------- fixture: a Source Package to anchor trees to -------------
SELECT register_source_package(
    p_source_type  => 'document',
    p_content_text => 'V4-PAGEINDEX-01 fixture document.',
    p_media_type   => 'text/plain'
) AS sp_id \gset

-- ====================================================================
-- 1. Register a tree in 'pending' status.
-- ====================================================================
SELECT page_index_tree_register(
    p_source_package_id => :sp_id,
    p_parser_kind       => 'pdf'
) AS tree_a \gset

SELECT build_status,
       source_package_id = :sp_id           AS source_matches,
       parser_kind       = 'pdf'            AS parser_matches,
       build_started_at  IS NULL            AS not_yet_started,
       superseded_by     IS NULL            AS not_superseded,
       owner_schema      = current_schema() AS owned_here
FROM malu$page_index_tree WHERE tree_id = :tree_a;

-- Audit row for the register transition.
SELECT event_kind, target_object_type, target_object_id = :tree_a AS targets_tree
FROM malu$audit_event
WHERE event_kind = 'page_index_tree.register'
  AND target_object_id = :tree_a;

-- ====================================================================
-- 2. Status transitions and their wrong-state guards.
-- ====================================================================
SELECT page_index_tree_mark_building(:tree_a);
SELECT build_status, build_started_at IS NOT NULL AS started
FROM malu$page_index_tree WHERE tree_id = :tree_a;

-- mark_ready from building.
SELECT page_index_tree_mark_ready(:tree_a);
SELECT build_status, build_finished_at IS NOT NULL AS finished
FROM malu$page_index_tree WHERE tree_id = :tree_a;

-- mark_building on an already-ready tree must fail.
DO $body$
BEGIN
    PERFORM page_index_tree_mark_building((SELECT tree_id
                                           FROM malu$page_index_tree
                                           WHERE build_status = 'ready'
                                           ORDER BY tree_id LIMIT 1));
    RAISE EXCEPTION 'should have rejected mark_building on ready tree';
EXCEPTION WHEN invalid_parameter_value THEN
    RAISE NOTICE 'OK: mark_building rejects ready->building';
END $body$;

-- A second tree, taken through pending→failed.
SELECT page_index_tree_register(:sp_id, 'pdf') AS tree_fail \gset
SELECT page_index_tree_mark_failed(:tree_fail, 'fixture failure');
SELECT build_status, failure_reason
FROM malu$page_index_tree WHERE tree_id = :tree_fail;

-- mark_ready on failed tree must fail.
DO $body$
DECLARE v_id bigint;
BEGIN
    SELECT tree_id INTO v_id FROM malu$page_index_tree
     WHERE build_status = 'failed' ORDER BY tree_id LIMIT 1;
    PERFORM page_index_tree_mark_ready(v_id);
    RAISE EXCEPTION 'should have rejected mark_ready on failed tree';
EXCEPTION WHEN invalid_parameter_value THEN
    RAISE NOTICE 'OK: mark_ready rejects failed->ready';
END $body$;

-- ====================================================================
-- 3. MDO discriminator shape constraint.
-- ====================================================================
-- Inserting a 'page_index_node' row without tree_id / node_kind is rejected.
DO $body$
BEGIN
    INSERT INTO malu$memory_detail_object
        (owner_schema, parent_mdo_id, memory_id, episode_id, detail_kind,
         mdo_kind)
    VALUES (current_schema(), NULL, NULL, NULL, 'page_index_node',
            'page_index_node');
    RAISE EXCEPTION 'should have rejected page_index_node without tree_id';
EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'OK: mdo_tree_node_shape_check rejects bare page_index_node';
END $body$;

-- A well-formed leaf node attached to tree_a.
INSERT INTO malu$memory_detail_object
    (owner_schema, detail_kind, mdo_kind, tree_id, node_kind, title, summary)
VALUES (current_schema(), 'page_index_node', 'page_index_node',
        :tree_a, 'leaf', 'Section 1', 'Summary of section 1')
RETURNING mdo_id AS leaf_a \gset

SELECT mdo_kind, node_kind, tree_id = :tree_a AS attached_to_tree,
       title, summary
FROM malu$memory_detail_object WHERE mdo_id = :leaf_a;

-- A memory_detail row may NOT carry tree_id (constraint forbids it).
DO $body$
BEGIN
    INSERT INTO malu$memory_detail_object
        (owner_schema, detail_kind, mdo_kind, tree_id, node_kind)
    VALUES (current_schema(), 'step', 'memory_detail', 1, 'leaf');
    RAISE EXCEPTION 'memory_detail with tree_id should be rejected';
EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'OK: memory_detail rows cannot carry tree_id';
END $body$;

-- ====================================================================
-- 4. Existing MDO consumer behavior unchanged.
--    register_memory_detail still works and the row defaults to
--    mdo_kind='memory_detail' with tree-node columns NULL.
-- ====================================================================
SELECT register_episode(
    p_episode_kind => 'migration',
    p_title        => 'V4-PI-01 fixture episode',
    p_summary      => 'verify legacy MDO defaults'
) AS ep_id \gset

SELECT register_memory_detail(
    p_detail_kind => 'step',
    p_episode_id  => :ep_id,
    p_ordinal     => 1,
    p_title       => 'Legacy MDO step'
) AS legacy_mdo \gset

SELECT mdo_kind,
       tree_id IS NULL AS tree_id_null,
       node_kind IS NULL AS node_kind_null,
       summary IS NULL AS summary_null,
       title AS title_kept
FROM malu$memory_detail_object WHERE mdo_id = :legacy_mdo;

-- ====================================================================
-- 5. Derivation Ledger admits the two new derived_object_type values.
-- ====================================================================
SELECT record_derivation(
    p_derived_object_type => 'page_index_tree',
    p_derived_object_id   => :tree_a,
    p_parser_name         => 'pypdf'
) AS deriv_tree \gset

SELECT record_derivation(
    p_derived_object_type => 'page_index_node',
    p_derived_object_id   => :leaf_a,
    p_parser_name         => 'page_index_node_summarizer'
) AS deriv_node \gset

SELECT derived_object_type
FROM malu$derivation_ledger
WHERE derivation_id IN (:deriv_tree, :deriv_node)
ORDER BY derivation_id;

-- ====================================================================
-- 6. Supersession edge + status flip on re-derivation.
-- ====================================================================
SELECT page_index_tree_register(:sp_id, 'pdf') AS tree_b \gset
SELECT page_index_tree_mark_building(:tree_b);
SELECT page_index_tree_mark_ready(:tree_b);

SELECT page_index_tree_supersede(:tree_a, :tree_b) AS edge_id \gset

SELECT build_status, superseded_by = :tree_b AS points_at_new,
       valid_time_end IS NOT NULL AS valid_time_closed
FROM malu$page_index_tree WHERE tree_id = :tree_a;

SELECT relationship_type, source_object_type, target_object_type,
       source_object_id = :tree_a AS edge_from_a,
       target_object_id = :tree_b AS edge_to_b
FROM malu$relationship_edge WHERE edge_id = :edge_id;

-- Self-supersession rejected.
DO $body$
BEGIN
    PERFORM page_index_tree_supersede(
        (SELECT tree_id FROM malu$page_index_tree
         WHERE build_status = 'ready' ORDER BY tree_id LIMIT 1),
        (SELECT tree_id FROM malu$page_index_tree
         WHERE build_status = 'ready' ORDER BY tree_id LIMIT 1));
    RAISE EXCEPTION 'should have rejected self-supersession';
EXCEPTION WHEN invalid_parameter_value THEN
    RAISE NOTICE 'OK: page_index_tree_supersede rejects self';
END $body$;

-- ====================================================================
-- 7. RLS isolation between tenants.
-- ====================================================================
DROP ROLE   IF EXISTS pi_user_a;
DROP ROLE   IF EXISTS pi_user_b;
DROP SCHEMA IF EXISTS pi_a CASCADE;
DROP SCHEMA IF EXISTS pi_b CASCADE;

CREATE ROLE pi_user_a NOLOGIN;
CREATE ROLE pi_user_b NOLOGIN;
GRANT maludb_memory_executor TO pi_user_a, pi_user_b;
GRANT USAGE ON SCHEMA maludb_core TO pi_user_a, pi_user_b;
CREATE SCHEMA pi_a AUTHORIZATION pi_user_a;
CREATE SCHEMA pi_b AUTHORIZATION pi_user_b;

SET ROLE pi_user_a;
SET search_path TO pi_a, maludb_core, public;

SELECT register_source_package(
    p_source_type  => 'document',
    p_content_text => 'tenant A doc',
    p_media_type   => 'text/plain'
) AS sp_a \gset

SELECT page_index_tree_register(:sp_a, 'pdf') AS tree_priv \gset

SELECT count(*) AS visible_to_a
FROM maludb_core.malu$page_index_tree WHERE tree_id = :tree_priv;

SET ROLE pi_user_b;
SET search_path TO pi_b, maludb_core, public;

SELECT count(*) AS visible_to_b
FROM maludb_core.malu$page_index_tree WHERE tree_id = :tree_priv;

RESET ROLE;
RESET search_path;
SET search_path TO maludb_core, public;

-- ====================================================================
-- 8. Stage-boundary check — V4-PAGEINDEX-02+ surfaces don't exist yet.
-- ====================================================================
SELECT count(*) FILTER (WHERE proname = 'source_package_promote_to_page_index') AS promote_fn,
       count(*) FILTER (WHERE proname = 'page_index_builder_enqueue')           AS enqueue_fn,
       count(*) FILTER (WHERE proname = 'page_index_record_structure_pass')     AS struct_pass_fn
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'maludb_core';

SELECT count(*) AS structure_pass_audit_table
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'maludb_core'
  AND c.relname = 'malu$structure_pass_audit';

-- ---------- cleanup --------------------------------------------------
DELETE FROM malu$page_index_tree
 WHERE owner_schema IN ('pi_a','pi_b');
DELETE FROM malu$source_package
 WHERE owner_schema IN ('pi_a','pi_b');

DROP SCHEMA pi_a CASCADE;
DROP SCHEMA pi_b CASCADE;
DROP OWNED BY pi_user_a;
DROP OWNED BY pi_user_b;
DROP ROLE   pi_user_a;
DROP ROLE   pi_user_b;
