\set ECHO all
\pset format unaligned
SET client_min_messages = WARNING;
CREATE EXTENSION IF NOT EXISTS maludb_core CASCADE;

SET search_path TO maludb_core, public;

DROP SCHEMA IF EXISTS svpor_type_a CASCADE;
DROP ROLE IF EXISTS svpor_type_user;

CREATE ROLE svpor_type_user NOLOGIN;
GRANT maludb_memory_executor TO svpor_type_user;
GRANT USAGE ON SCHEMA maludb_core TO svpor_type_user;
CREATE SCHEMA svpor_type_a AUTHORIZATION svpor_type_user;

SET ROLE svpor_type_user;
SET search_path TO svpor_type_a, maludb_core, public;

SELECT object_count > 0 AS enabled
FROM maludb_core.enable_memory_schema();

SELECT subject_type, display_name
FROM maludb_subject_type
WHERE subject_type IN (
    'project','person','ai_agent','equipment','software','network',
    'event','process','workflow','time_period','other'
)
ORDER BY sort_order;

SELECT verb_type, display_name, semantic_class
FROM maludb_verb_type
WHERE verb_type IN (
    'installed','attended','configured','verified','decided',
    'resolved','failed','documented','migrated','deployed'
)
ORDER BY sort_order;

INSERT INTO maludb_subject(subject_type, canonical_name, aliases)
VALUES ('AI Agent', 'Ops Assistant', ARRAY['ops-ai'])
RETURNING subject_type, canonical_name;

INSERT INTO maludb_subject(subject_type, canonical_name)
VALUES ('Time Period', '2026 Q2')
RETURNING subject_type, canonical_name;

INSERT INTO maludb_person(subject_type, canonical_name, aliases)
VALUES ('person', 'Person A', ARRAY['A. Person'])
RETURNING subject_type, canonical_name;

SELECT subject_type, canonical_name, aliases
FROM maludb_person
WHERE canonical_name = 'Person A';

INSERT INTO maludb_verb(verb_type, canonical_name, aliases)
VALUES ('Installed', 'Installed', ARRAY['installed on'])
RETURNING verb_type, canonical_name;

INSERT INTO maludb_verb(verb_type, canonical_name)
VALUES ('Attended', 'Attended')
RETURNING verb_type, canonical_name;

SELECT subject_type, canonical_name
FROM maludb_subject
WHERE canonical_name IN ('Ops Assistant', '2026 Q2', 'Person A')
ORDER BY canonical_name;

SELECT verb_type, canonical_name
FROM maludb_verb
WHERE canonical_name IN ('Installed', 'Attended')
ORDER BY canonical_name;

RESET ROLE;
SET search_path TO maludb_core, public;

DELETE FROM malu$svpor_verb WHERE owner_schema = 'svpor_type_a';
DELETE FROM malu$svpor_subject WHERE owner_schema = 'svpor_type_a';
DELETE FROM malu$enabled_schema_object WHERE schema_name = 'svpor_type_a';
DELETE FROM malu$enabled_schema WHERE schema_name = 'svpor_type_a';
DROP SCHEMA svpor_type_a CASCADE;
DROP OWNED BY svpor_type_user;
DROP ROLE svpor_type_user;
