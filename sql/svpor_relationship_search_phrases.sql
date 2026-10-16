\set ECHO all
\pset format unaligned
SET client_min_messages = WARNING;
CREATE EXTENSION IF NOT EXISTS maludb_core CASCADE;

SET search_path TO maludb_core, public;

DROP SCHEMA IF EXISTS svpor_rel_a CASCADE;
DROP ROLE IF EXISTS svpor_rel_user;

CREATE ROLE svpor_rel_user NOLOGIN;
GRANT maludb_memory_executor TO svpor_rel_user;
GRANT USAGE ON SCHEMA maludb_core TO svpor_rel_user;
CREATE SCHEMA svpor_rel_a AUTHORIZATION svpor_rel_user;

SET ROLE svpor_rel_user;
SET search_path TO svpor_rel_a, maludb_core, public;

SELECT object_count > 0 AS enabled
FROM maludb_core.enable_memory_schema();

INSERT INTO maludb_project(subject_type, canonical_name, aliases)
VALUES ('project', 'Project X', ARRAY['PX'])
RETURNING subject_id AS project_x_id \gset

INSERT INTO maludb_project(subject_type, canonical_name)
VALUES ('project', 'Project Y')
RETURNING subject_id AS project_y_id \gset

INSERT INTO maludb_project(subject_type, canonical_name)
VALUES ('project', 'Project Z')
RETURNING subject_id AS project_z_id \gset

INSERT INTO maludb_person(subject_type, canonical_name)
VALUES ('person', 'Person A')
RETURNING subject_id AS person_a_id \gset

INSERT INTO maludb_subject(subject_type, canonical_name)
VALUES ('Equipment', 'Server X')
RETURNING subject_id AS server_x_id \gset

INSERT INTO maludb_subject(subject_type, canonical_name)
VALUES ('Equipment', 'Server Y')
RETURNING subject_id AS server_y_id \gset

INSERT INTO maludb_subject(subject_type, canonical_name)
VALUES ('Software', 'Tech Stack C')
RETURNING subject_id AS tech_stack_c_id \gset

INSERT INTO maludb_verb(verb_type, canonical_name, aliases, search_phrases)
VALUES (
    'Configured',
    'Configured',
    ARRAY['configure','configuring','configuration','set up','setup'],
    ARRAY['Server Configuration','Configured Server','Configure Server','Server Setup']
)
RETURNING verb_id AS configured_id \gset

SELECT maludb_svpor_relationship_create('subject', :project_x_id, 'subject', :person_a_id, 'has_member') > 0 AS project_person_edge;
SELECT maludb_svpor_relationship_create('subject', :project_x_id, 'subject', :server_x_id, 'has_asset') > 0 AS project_server_edge;
SELECT maludb_svpor_relationship_create('subject', :project_x_id, 'subject', :tech_stack_c_id, 'uses') > 0 AS project_stack_edge;
SELECT maludb_svpor_relationship_create('subject', :person_a_id, 'subject', :project_y_id, 'assigned_to') > 0 AS person_project_y_edge;
SELECT maludb_svpor_relationship_create('subject', :person_a_id, 'subject', :project_z_id, 'assigned_to') > 0 AS person_project_z_edge;
SELECT maludb_svpor_relationship_create('verb', :configured_id, 'subject', :server_x_id, 'applies_to') > 0 AS configured_server_x_edge;
SELECT maludb_svpor_relationship_create('verb', :configured_id, 'subject', :server_y_id, 'applies_to') > 0 AS configured_server_y_edge;
SELECT maludb_svpor_relationship_create('verb', :configured_id, 'subject', :person_a_id, 'performed_by') > 0 AS configured_person_edge;

SELECT source_kind, source_name, relationship_type, target_kind, target_name
FROM maludb_svpor_relationship
WHERE source_name IN ('Project X', 'Person A', 'Configured')
ORDER BY source_name, relationship_type, target_name;

SELECT canonical_name, match_kind, matched_text
FROM maludb_verb_phrase_search('Server Configuration')
ORDER BY canonical_name;

SELECT canonical_name, match_kind, matched_text
FROM maludb_verb_phrase_search('Configured Server')
ORDER BY canonical_name;

RESET ROLE;
SET search_path TO maludb_core, public;

DELETE FROM malu$relationship_edge WHERE owner_schema = 'svpor_rel_a';
DELETE FROM malu$svpor_verb WHERE owner_schema = 'svpor_rel_a';
DELETE FROM malu$svpor_subject WHERE owner_schema = 'svpor_rel_a';
DELETE FROM malu$enabled_schema_object WHERE schema_name = 'svpor_rel_a';
DELETE FROM malu$enabled_schema WHERE schema_name = 'svpor_rel_a';
DROP SCHEMA svpor_rel_a CASCADE;
DROP OWNED BY svpor_rel_user;
DROP ROLE svpor_rel_user;
