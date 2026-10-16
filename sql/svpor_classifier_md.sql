\set ECHO all
\pset format unaligned
SET client_min_messages = WARNING;
CREATE EXTENSION IF NOT EXISTS maludb_core CASCADE;

SET search_path TO maludb_core, public;

DROP SCHEMA IF EXISTS svpor_classifier_a CASCADE;
DROP ROLE IF EXISTS svpor_classifier_user;

CREATE ROLE svpor_classifier_user NOLOGIN;
GRANT maludb_memory_executor TO svpor_classifier_user;
GRANT USAGE ON SCHEMA maludb_core TO svpor_classifier_user;
CREATE SCHEMA svpor_classifier_a AUTHORIZATION svpor_classifier_user;

SET ROLE svpor_classifier_user;
SET search_path TO svpor_classifier_a, maludb_core, public;

SELECT object_count > 0 AS enabled
FROM maludb_core.enable_memory_schema();

-- register_svpor_subject carries classifier_md through to storage (project)
SELECT register_svpor_subject(
    p_canonical_name => 'Acme Corp',
    p_aliases        => ARRAY['ACME'],
    p_subject_type   => 'project',
    p_classifier_md  => '# Acme Corp\nReference when text mentions Acme or ACME Inc.'
) AS acme_id \gset

-- ... and for a person
SELECT register_svpor_subject(
    p_canonical_name => 'Jane Doe',
    p_subject_type   => 'person',
    p_classifier_md  => '# Jane Doe\nMatch on Jane or J. Doe.'
) AS jane_id \gset

-- register_svpor_verb carries classifier_md through to storage
SELECT register_svpor_verb(
    p_canonical_name => 'approves',
    p_verb_type      => 'approved',
    p_classifier_md  => '# approves\nTrigger on approved or authorized.'
) AS approves_id \gset

-- base subject facade surfaces classifier_md
SELECT canonical_name, subject_type, classifier_md
FROM maludb_subject
ORDER BY canonical_name;

-- project subject-filter facade surfaces classifier_md
SELECT canonical_name, classifier_md
FROM maludb_project
ORDER BY canonical_name;

-- person subject-filter facade surfaces classifier_md
SELECT canonical_name, classifier_md
FROM maludb_person
ORDER BY canonical_name;

-- verb facade surfaces classifier_md
SELECT canonical_name, classifier_md
FROM maludb_verb
ORDER BY canonical_name;

-- the writable subject view accepts classifier_md directly, and the
-- stakeholder subject-filter facade surfaces it
INSERT INTO maludb_subject(subject_type, canonical_name, classifier_md)
VALUES ('stakeholder', 'Board of Directors', '# Board\nMatch on board or directors.');

SELECT canonical_name, classifier_md
FROM maludb_stakeholder
ORDER BY canonical_name;

-- re-registering with a new classifier_md updates it in place
SELECT register_svpor_subject(
    p_canonical_name => 'Acme Corp',
    p_aliases        => ARRAY['ACME'],
    p_subject_type   => 'project',
    p_classifier_md  => '# Acme Corp (revised)'
) AS acme_again \gset

SELECT classifier_md
FROM maludb_project
WHERE canonical_name = 'Acme Corp';

-- re-registering without classifier_md preserves the stored value (COALESCE)
SELECT register_svpor_subject(
    p_canonical_name => 'Acme Corp',
    p_subject_type   => 'project',
    p_aliases        => ARRAY['ACME']
) AS acme_preserve \gset

SELECT classifier_md
FROM maludb_project
WHERE canonical_name = 'Acme Corp';

-- a subject registered without classifier_md leaves it NULL
SELECT register_svpor_subject(
    p_canonical_name => 'No Markdown Subject'
) AS plain_id \gset

SELECT canonical_name, classifier_md IS NULL AS classifier_md_null
FROM maludb_subject
WHERE canonical_name = 'No Markdown Subject';

RESET ROLE;
SET search_path TO maludb_core, public;

DELETE FROM malu$svpor_subject WHERE owner_schema = 'svpor_classifier_a';
DELETE FROM malu$svpor_verb WHERE owner_schema = 'svpor_classifier_a';
DELETE FROM malu$enabled_schema_object WHERE schema_name = 'svpor_classifier_a';
DELETE FROM malu$enabled_schema WHERE schema_name = 'svpor_classifier_a';
DROP SCHEMA svpor_classifier_a CASCADE;
DROP OWNED BY svpor_classifier_user;
DROP ROLE svpor_classifier_user;
