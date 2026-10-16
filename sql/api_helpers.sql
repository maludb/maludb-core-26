\set ECHO all
\pset format unaligned
SET client_min_messages = WARNING;
CREATE EXTENSION IF NOT EXISTS maludb_core CASCADE;

SET search_path TO maludb_core, public;

DROP SCHEMA IF EXISTS api_helpers_a CASCADE;
DROP ROLE IF EXISTS api_helpers_user;

CREATE ROLE api_helpers_user NOLOGIN;
GRANT maludb_memory_executor TO api_helpers_user;
GRANT USAGE ON SCHEMA maludb_core TO api_helpers_user;
CREATE SCHEMA api_helpers_a AUTHORIZATION api_helpers_user;

SET ROLE api_helpers_user;
SET search_path TO api_helpers_a, maludb_core, public;
SET TIME ZONE 'UTC';

SELECT object_count > 0 AS enabled
FROM maludb_core.enable_memory_schema();

INSERT INTO maludb_subject(subject_type, canonical_name) VALUES ('person', 'Mary')
RETURNING subject_id AS mary \gset
INSERT INTO maludb_subject(subject_type, canonical_name) VALUES ('project', 'Zozocal')
RETURNING subject_id AS zoz \gset
INSERT INTO maludb_verb(canonical_name) VALUES ('manages')
RETURNING verb_id AS vmanage \gset

-- A1: memory write must work without maludb_core on the search_path ----
\echo '-- A1: maludb_memory writable from a bare search_path --'
SET search_path TO api_helpers_a, public;
INSERT INTO maludb_memory(memory_kind, title, summary) VALUES ('note', 'n1', 'first body')
RETURNING memory_id AS n1 \gset
SET search_path TO api_helpers_a, maludb_core, public;
SELECT memory_kind, title, summary FROM maludb_memory WHERE memory_id = :n1;

-- A2 + F-doc: quick_add_note creates a document whose body round-trips --
\echo '-- A2/F-doc: quick_add_note + readable body_text --'
SELECT maludb_quick_add_note('note title', 'note body text') AS doc_id \gset
SELECT title, source_type, body_text FROM maludb_document WHERE document_id = :doc_id;

-- C + B1: subject<->verb link / unlink ---------------------------------
\echo '-- C/B1: link then unlink (idempotent) --'
SELECT maludb_subject_verb_link(:mary, :vmanage) > 0 AS linked;
SELECT maludb_subject_verb_unlink(:mary, :vmanage) AS unlinked_rows;
SELECT maludb_subject_verb_unlink(:mary, :vmanage) AS unlink_again;

-- D: project archive / unarchive (idempotent boolean flags) ------------
\echo '-- D: project archive/unarchive --'
SELECT maludb_project_archive(:zoz) AS archived_now, maludb_project_archive(:zoz) AS already_archived;
SELECT archived_at IS NOT NULL AS is_archived FROM maludb_project WHERE subject_id = :zoz;
SELECT maludb_project_unarchive(:zoz) AS unarchived_now, maludb_project_unarchive(:zoz) AS not_archived;
SELECT archived_at IS NULL AS is_active FROM maludb_project WHERE subject_id = :zoz;

-- E: notes issue-state on memory --------------------------------------
\echo '-- E: issue_closed_at set/clear --'
UPDATE maludb_memory SET memory_kind = 'issue' WHERE memory_id = :n1;
UPDATE maludb_memory SET issue_closed_at = TIMESTAMPTZ '2026-05-26' WHERE memory_id = :n1;
SELECT memory_kind, issue_closed_at IS NOT NULL AS closed FROM maludb_memory WHERE memory_id = :n1;
UPDATE maludb_memory SET issue_closed_at = NULL WHERE memory_id = :n1;
SELECT issue_closed_at IS NULL AS reopened FROM maludb_memory WHERE memory_id = :n1;

-- F-skill: markdown body read/write via the facade --------------------
\echo '-- F-skill: skill markdown round-trip --'
INSERT INTO maludb_skill(skill_name, markdown) VALUES ('s1', '# Skill One')
RETURNING skill_name;
SELECT markdown FROM maludb_skill WHERE skill_name = 's1';

-- B2: svpor relationship delete (subject/verb endpoints) --------------
\echo '-- B2: svpor_relationship_delete --'
SELECT maludb_svpor_relationship_create('subject', :mary, 'verb', :vmanage, 'related_to') > 0 AS edge_created;
SELECT maludb_svpor_relationship_delete('subject', :mary, 'verb', :vmanage) AS deleted_rows;
SELECT maludb_svpor_relationship_delete('subject', :mary, 'verb', :vmanage) AS delete_again;

-- B3: pool remove named member ----------------------------------------
\echo '-- B3: pool_remove_named_member --'
INSERT INTO maludb_memory_pool(pool_name) VALUES ('p1');
SELECT maludb_pool_add_named_member('p1', 'subject', 'Mary') > 0 AS member_added;
SELECT maludb_pool_remove_named_member('p1', 'subject', 'Mary') AS removed_rows;
SELECT maludb_pool_remove_named_member('p1', 'subject', 'Mary') AS remove_again;

-- rejections ----------------------------------------------------------
\echo '-- unknown pool member_kind rejected --'
DO $$
BEGIN
    PERFORM maludb_pool_remove_named_member('p1', 'bogus', 'x');
    RAISE EXCEPTION 'bogus member_kind not rejected';
EXCEPTION WHEN invalid_parameter_value THEN
    RAISE NOTICE 'OK: bogus member_kind rejected';
END;
$$;

\echo '-- archive of a non-project rejected --'
DO $$
DECLARE v_mary bigint := (SELECT subject_id FROM maludb_subject WHERE canonical_name = 'Mary');
BEGIN
    PERFORM maludb_project_archive(v_mary);
    RAISE EXCEPTION 'archiving a non-project was not rejected';
EXCEPTION WHEN foreign_key_violation THEN
    RAISE NOTICE 'OK: non-project archive rejected';
END;
$$;

-- 1.2: svpor relationship create is idempotent + FK-validates ---------
\echo '-- 1.2: svpor_relationship_create is idempotent (same edge id) --'
SELECT maludb_svpor_relationship_create('subject', :mary, 'verb', :vmanage, 'related_to') AS e1 \gset
SELECT maludb_svpor_relationship_create('subject', :mary, 'verb', :vmanage, 'related_to') AS e2 \gset
SELECT :e1 = :e2 AS idempotent;
SELECT count(*) AS edge_rows FROM maludb_core.malu$relationship_edge
 WHERE owner_schema = 'api_helpers_a'
   AND source_object_type = 'subject' AND source_object_id = :mary
   AND target_object_type = 'verb'    AND target_object_id = :vmanage
   AND relationship_type = 'related_to';

\echo '-- 1.2: svpor_relationship_create FK-validates a dangling endpoint --'
DO $$
DECLARE v_verb bigint := (SELECT verb_id FROM maludb_verb WHERE canonical_name = 'manages');
BEGIN
    PERFORM maludb_svpor_relationship_create('subject', 999999999, 'verb', v_verb, 'related_to');
    RAISE EXCEPTION 'dangling SVPOR endpoint was not rejected';
EXCEPTION WHEN foreign_key_violation THEN
    RAISE NOTICE 'OK: dangling SVPOR endpoint rejected';
END;
$$;

-- 6: search-path-safe episode writer ---------------------------------
\echo '-- 6: maludb_register_episode from a bare search_path --'
SET search_path TO api_helpers_a, public;
SELECT maludb_register_episode('meeting', 'kickoff', 'kickoff summary') AS ep \gset
SET search_path TO api_helpers_a, maludb_core, public;
SELECT episode_kind, title, summary
  FROM maludb_core.malu$episode_object
 WHERE owner_schema = 'api_helpers_a' AND episode_id = :ep;

-- subject-relationship edit facades (close / set_type / delete) -------
\echo '-- subject_relationship facades: close / set_type / delete --'
INSERT INTO maludb_subject(subject_type, canonical_name) VALUES ('person', 'Alex')
RETURNING subject_id AS alex \gset
INSERT INTO maludb_subject_relationship
    (from_subject_id, to_subject_id, relationship_type, valid_from)
VALUES (:mary, :alex, 'manager of', TIMESTAMPTZ '2026-01-01')
RETURNING relationship_id AS rel \gset

-- close: set valid_to (idempotent — second call with same value is a no-op)
SELECT maludb_subject_relationship_close(:rel, TIMESTAMPTZ '2026-05-28') AS closed_now,
       maludb_subject_relationship_close(:rel, TIMESTAMPTZ '2026-05-28') AS already_closed;
SELECT valid_to IS NOT NULL AS expired FROM maludb_subject_relationship WHERE relationship_id = :rel;

-- set_type: edit relationship_type
SELECT maludb_subject_relationship_set_type(:rel, 'advisor to') AS type_changed,
       maludb_subject_relationship_set_type(:rel, 'advisor to') AS already_that_type;
SELECT relationship_type FROM maludb_subject_relationship WHERE relationship_id = :rel;

-- delete: remove a mistake
SELECT maludb_subject_relationship_delete(:rel) AS deleted_rows,
       maludb_subject_relationship_delete(:rel) AS delete_again;

-- cleanup -------------------------------------------------------------
RESET ROLE;
SET search_path TO maludb_core, public;

DELETE FROM malu$relationship_edge WHERE owner_schema = 'api_helpers_a';
DELETE FROM malu$active_memory_pool_member WHERE owner_schema = 'api_helpers_a';
DELETE FROM malu$active_memory_pool WHERE owner_schema = 'api_helpers_a';
DELETE FROM malu$vector_compartment WHERE owner_schema = 'api_helpers_a';
DELETE FROM malu$vector_subject WHERE owner_schema = 'api_helpers_a';
DELETE FROM malu$vector_verb WHERE owner_schema = 'api_helpers_a';
DELETE FROM malu$skill_package WHERE owner_schema = 'api_helpers_a';
DELETE FROM malu$memory WHERE owner_schema = 'api_helpers_a';
DELETE FROM malu$episode_object WHERE owner_schema = 'api_helpers_a';
DELETE FROM malu$document WHERE owner_schema = 'api_helpers_a';
DELETE FROM malu$source_package WHERE owner_schema = 'api_helpers_a';
DELETE FROM malu$svpor_verb WHERE owner_schema = 'api_helpers_a';
DELETE FROM malu$svpor_subject WHERE owner_schema = 'api_helpers_a';
DELETE FROM malu$enabled_schema_object WHERE schema_name = 'api_helpers_a';
DELETE FROM malu$enabled_schema WHERE schema_name = 'api_helpers_a';
DROP SCHEMA api_helpers_a CASCADE;
DROP OWNED BY api_helpers_user;
DROP ROLE api_helpers_user;
