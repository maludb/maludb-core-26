-- =====================================================================
-- 05-external-link.sql — acceptance test for maludb_core 0.90.0
-- Two-way binding between a relational record and a MaluDB graph object:
--   maludb_link_create  (graph -> external back-pointer)
--   maludb_link_resolve (external record -> object(s))
--
-- Run AFTER bringing a DB up to 0.90.0:
--   psql -v ON_ERROR_STOP=1 -d <db> -f 05-external-link.sql
--
-- Self-contained: own schema `link_demo`, with two ordinary relational
-- tables (`projects`, `tasks`) standing in for a project-management app.
-- The scenario is the one from the design thread: a `projects` row binds
-- to a `subject` of type project; a `tasks` row binds to the `upgrade`
-- EDGE between Ed and Oracle 19c (an svpor_statement).
-- =====================================================================

\set ON_ERROR_STOP on

DROP SCHEMA IF EXISTS link_demo CASCADE;
-- DROP SCHEMA does not remove maludb_core rows owned by the tenant (they
-- live in the extension schema, keyed by owner_schema), so clear this
-- tenant's graph rows too to keep the test re-runnable (FK-safe order).
DELETE FROM maludb_core.malu$svpor_attribute WHERE owner_schema = 'link_demo';
DELETE FROM maludb_core.malu$svpor_statement WHERE owner_schema = 'link_demo';
DELETE FROM maludb_core.malu$svpor_verb      WHERE owner_schema = 'link_demo';
DELETE FROM maludb_core.malu$svpor_subject   WHERE owner_schema = 'link_demo';
CREATE SCHEMA link_demo;
SET search_path = link_demo, maludb_core, public;

\echo == enable memory (expect enabled_version 0.90.0) ==
SELECT * FROM maludb_core.enable_memory_schema('link_demo');

-- ---------------------------------------------------------------------
-- The app's OWN relational tables. The forward pointer (relational ->
-- graph) is a plain bigint column the app fills in: NO FK to maludb_core.
-- ---------------------------------------------------------------------
CREATE TABLE link_demo.projects (
    id         bigint PRIMARY KEY,
    name       text NOT NULL,
    subject_id bigint            -- forward pointer into the graph
);
CREATE TABLE link_demo.tasks (
    id           bigint PRIMARY KEY,
    title        text NOT NULL,
    statement_id bigint          -- forward pointer to an edge (svpor_statement)
);
INSERT INTO link_demo.projects (id, name) VALUES (42, 'MIST');
INSERT INTO link_demo.tasks    (id, title) VALUES (100, 'Upgrade Oracle 19c');

-- ---------------------------------------------------------------------
-- BUTTON 1 (project side): create the graph node, store its id in the
-- relational column, and write the reverse-pointer link — one transaction.
-- ---------------------------------------------------------------------
\echo == create a project subject, capture its subject_id ==
SELECT maludb_core.register_svpor_subject(p_canonical_name => 'MIST', p_subject_type => 'project', p_description => 'MIST modernization project') AS sid \gset
UPDATE link_demo.projects SET subject_id = :sid WHERE id = 42;

\echo == link the subject back to projects:42 (returns the link attribute_id) ==
SELECT link_demo.maludb_link_create(
    'subject', :sid,
    'pm', 'projects', '42',
    p_label => 'MIST') AS link_attr \gset

\echo == ASSERT A: the subject carries exactly one reference attribute pointing at pm/projects/42 ==
SELECT a.attr_name, a.ref_source, a.ref_entity, a.ref_key, a.value_text AS label, a.provenance
FROM   link_demo.maludb_svpor_attribute a
WHERE  a.target_kind = 'subject' AND a.target_id = :sid;
-- EXPECT one row: external_ref | pm | projects | 42 | MIST | provided

\echo == ASSERT B: reverse lookup pm/projects/42 -> the subject (graph identifier for the relational row) ==
SELECT target_kind, target_id = :sid AS subject_ok, attr_name, label, provenance
FROM   link_demo.maludb_link_resolve('pm', 'projects', '42');
-- EXPECT one row: subject | t | external_ref | MIST | provided

-- ---------------------------------------------------------------------
-- BUTTON 1 (task side): build the upgrade EDGE (Ed --upgrade--> Oracle 19c)
-- and bind task 100 to that edge.
-- ---------------------------------------------------------------------
\echo == build the upgrade edge: subjects Ed + Oracle 19c, verb upgrade, statement ==
SELECT maludb_core.register_svpor_subject(p_canonical_name => 'Ed', p_subject_type => 'person')          AS ed_id  \gset
SELECT maludb_core.register_svpor_subject(p_canonical_name => 'Oracle 19c', p_subject_type => 'software') AS ora_id \gset
SELECT maludb_core.register_svpor_verb('upgrade')                                        AS upg_id  \gset
SELECT link_demo.maludb_svpor_statement_create(
    'subject', :ed_id, :upg_id, 'subject', :ora_id) AS stmt_id \gset
UPDATE link_demo.tasks SET statement_id = :stmt_id WHERE id = 100;

\echo == link the edge back to tasks:100 ==
SELECT link_demo.maludb_link_create(
    'svpor_statement', :stmt_id,
    'pm', 'tasks', '100',
    p_attr_name => 'pm_task', p_label => 'Upgrade Oracle 19c') AS task_link \gset

\echo == ASSERT C: reverse lookup pm/tasks/100 -> the upgrade edge ==
SELECT target_kind, target_id = :stmt_id AS statement_ok, attr_name, label
FROM   link_demo.maludb_link_resolve('pm', 'tasks', '100');
-- EXPECT one row: svpor_statement | t | pm_task | Upgrade Oracle 19c

-- ---------------------------------------------------------------------
-- Multiple external systems on one object: each distinct attr_name is a
-- distinct link. Ed is both an HR person record AND a directory user.
-- ---------------------------------------------------------------------
\echo == link Ed to two external systems under distinct attr_names (HR + directory) ==
SELECT link_demo.maludb_link_create(
    'subject', :ed_id, 'hr', 'persons', 'emp_7',
    p_attr_name => 'hr_person', p_label => 'Edward Honour') AS hr_link \gset
SELECT link_demo.maludb_link_create(
    'subject', :ed_id, 'ad', 'users', 'ehonour',
    p_attr_name => 'ad_user', p_label => 'ehonour') AS ad_link \gset

\echo == ASSERT D: Ed now has two independent reference links ==
SELECT count(*) AS ref_links
FROM   link_demo.maludb_svpor_attribute
WHERE  target_kind = 'subject' AND target_id = :ed_id AND ref_source IS NOT NULL;
-- EXPECT: 2

\echo == ASSERT D2: each external key resolves to Ed ==
SELECT 'hr'  AS via, target_id = :ed_id AS ed_ok FROM link_demo.maludb_link_resolve('hr', 'persons', 'emp_7')
UNION ALL
SELECT 'any-entity', target_id = :ed_id FROM link_demo.maludb_link_resolve('hr', NULL, 'emp_7');
-- EXPECT: both rows ed_ok = t (second proves ref_entity is an optional filter)

-- ---------------------------------------------------------------------
-- Idempotent upsert: re-linking under the SAME attr_name updates in place.
-- ---------------------------------------------------------------------
\echo == re-link projects:42 with a corrected label (same attr_name) ==
SELECT link_demo.maludb_link_create('subject', :sid, 'pm', 'projects', '42', p_label => 'MIST (renamed)') AS relink \gset

\echo == ASSERT E: still ONE external_ref on the subject; label updated; same attribute_id ==
SELECT count(*) AS n, max(value_text) AS label, bool_and(attribute_id = :link_attr) AS same_id
FROM   link_demo.maludb_svpor_attribute
WHERE  target_kind = 'subject' AND target_id = :sid AND attr_name = 'external_ref';
-- EXPECT: 1 | MIST (renamed) | t

-- ---------------------------------------------------------------------
-- Agent entity-resolution staging: a 'suggested' match a human accepts.
-- ---------------------------------------------------------------------
\echo == an agent suggests Oracle 19c maps to a CMDB asset (provenance suggested) ==
SELECT link_demo.maludb_link_create(
    'subject', :ora_id, 'cmdb', 'assets', 'asset-9000',
    p_attr_name => 'cmdb_asset', p_label => 'ORA-PROD-01',
    p_provenance => 'suggested', p_confidence => 0.82) AS cmdb_link \gset

\echo == ASSERT F: resolves as suggested, then a human accepts it ==
SELECT provenance, confidence FROM link_demo.maludb_link_resolve('cmdb', 'assets', 'asset-9000');
-- EXPECT: suggested | 0.82
SELECT link_demo.maludb_svpor_attribute_set_provenance(:cmdb_link, 'accepted');
SELECT provenance FROM link_demo.maludb_link_resolve('cmdb', 'assets', 'asset-9000');
-- EXPECT: accepted

-- ---------------------------------------------------------------------
-- Display-time graph -> relational: object_get bundles the ref inline,
-- and the forward column joins straight back to the relational row.
-- ---------------------------------------------------------------------
\echo == ASSERT G: object_get('subject', sid) bundles the reference attribute ==
SELECT maludb_core.object_get('subject', :sid) -> 'attributes' -> 'external_ref' -> 'ref' AS ref
FROM (SELECT 1) t;
-- EXPECT: {"key": "42", "source": "pm", "entity": "projects"}

\echo == ASSERT H: forward pointer round-trips (projects.subject_id -> subject -> back to projects via resolve) ==
SELECT p.name, p.subject_id = :sid AS fwd_ok, r.target_id = p.subject_id AS rev_ok
FROM   link_demo.projects p
CROSS JOIN LATERAL link_demo.maludb_link_resolve('pm', 'projects', p.id::text) r
WHERE  p.id = 42;
-- EXPECT: MIST | t | t

-- ---------------------------------------------------------------------
-- Negative: a link without the full (source, entity, key) triplet errors.
-- ---------------------------------------------------------------------
\echo == ASSERT I: missing ref_key is rejected ==
DO $$
BEGIN
    PERFORM link_demo.maludb_link_create('subject', 1, 'pm', 'projects', NULL);
    RAISE EXCEPTION 'FAIL: link_create accepted a NULL ref_key';
EXCEPTION
    WHEN invalid_parameter_value THEN
        RAISE NOTICE 'OK: NULL ref_key rejected as expected';
END $$;

\echo == ASSERT J: a bad target is rejected (delegated validation) ==
DO $$
BEGIN
    PERFORM link_demo.maludb_link_create('subject', 999999, 'pm', 'projects', '999');
    RAISE EXCEPTION 'FAIL: link_create accepted a non-existent subject';
EXCEPTION
    WHEN foreign_key_violation THEN
        RAISE NOTICE 'OK: missing target rejected as expected';
END $$;

\echo == DONE ==
