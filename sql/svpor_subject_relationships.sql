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
SET TIME ZONE 'UTC';

SELECT object_count > 0 AS enabled
FROM maludb_core.enable_memory_schema();

-- subjects ------------------------------------------------------------
INSERT INTO maludb_subject(subject_type, canonical_name)
VALUES ('person', 'Mary')
RETURNING subject_id AS mary_id \gset

INSERT INTO maludb_subject(subject_type, canonical_name)
VALUES ('project', 'Zozocal')
RETURNING subject_id AS zozocal_id \gset

INSERT INTO maludb_subject(subject_type, canonical_name)
VALUES ('person', 'Sam')
RETURNING subject_id AS sam_id \gset

-- STORE: one row, a relationship valid for a date range (free-text type)
INSERT INTO maludb_subject_relationship
    (from_subject_id, to_subject_id, relationship_type, valid_from, valid_to, label)
VALUES (:mary_id, :zozocal_id, 'project manager of',
        DATE '2025-01-01', DATE '2026-01-01', 'Q1-Q4 engagement');

\echo '-- the stored relationship --'
SELECT from_subject_label, to_subject_label, relationship_type,
       valid_from::date, valid_to::date, label
FROM maludb_subject_relationship
ORDER BY relationship_id;

\echo '-- valid on 2025-06-01 (plain SQL date predicate) --'
SELECT from_subject_label, to_subject_label, relationship_type
FROM maludb_subject_relationship
WHERE DATE '2025-06-01' >= valid_from
  AND (valid_to IS NULL OR DATE '2025-06-01' < valid_to);

\echo '-- valid on 2026-06-01 (after it ended): none --'
SELECT count(*) AS active_on_2026_06_01
FROM maludb_subject_relationship
WHERE DATE '2026-06-01' >= valid_from
  AND (valid_to IS NULL OR DATE '2026-06-01' < valid_to);

\echo '-- point-in-time reader: as_of 2025-06-01 --'
SELECT from_subject_name, to_subject_name, relationship_type, is_current
FROM maludb_subject_relationships(:mary_id, '2025-06-01'::timestamptz)
ORDER BY relationship_id;

-- a second, ongoing relationship (open-ended), different type ---------
INSERT INTO maludb_subject_relationship
    (from_subject_id, to_subject_id, relationship_type, valid_from)
VALUES (:mary_id, :zozocal_id, 'advisor to', DATE '2026-02-01');

\echo '-- reader, Mary as from-subject (PM expired, advisor current) --'
SELECT relationship_type, is_current
FROM maludb_subject_relationships(:mary_id, NULL, NULL, 'from')
ORDER BY valid_from;

\echo '-- direction filter: Zozocal as target --'
SELECT from_subject_name, to_subject_name, relationship_type
FROM maludb_subject_relationships(:zozocal_id, NULL, NULL, 'to')
ORDER BY valid_from;

-- "close" a relationship == plain UPDATE of valid_to -----------------
UPDATE maludb_subject_relationship
   SET valid_to = DATE '2026-03-01'
 WHERE from_subject_id = :mary_id
   AND relationship_type = 'advisor to';

\echo '-- advisor no longer valid as of 2026-04-01 --'
SELECT count(*) AS advisor_active_2026_04
FROM maludb_subject_relationships(:mary_id, '2026-04-01'::timestamptz, 'advisor to');

-- overlap of the same directed, typed relationship is rejected -------
DO $$
DECLARE
    v_mary    bigint := (SELECT subject_id FROM maludb_subject WHERE canonical_name = 'Mary');
    v_zozocal bigint := (SELECT subject_id FROM maludb_subject WHERE canonical_name = 'Zozocal');
BEGIN
    INSERT INTO maludb_subject_relationship (from_subject_id, to_subject_id, relationship_type, valid_from, valid_to)
    VALUES (v_mary, v_zozocal, 'project manager of', DATE '2025-06-01', DATE '2025-09-01');
    RAISE EXCEPTION 'overlapping relationship was not rejected';
EXCEPTION WHEN exclusion_violation THEN
    RAISE NOTICE 'OK: overlapping relationship rejected';
END;
$$;

-- relationship_type is required --------------------------------------
DO $$
DECLARE
    v_mary    bigint := (SELECT subject_id FROM maludb_subject WHERE canonical_name = 'Mary');
    v_zozocal bigint := (SELECT subject_id FROM maludb_subject WHERE canonical_name = 'Zozocal');
BEGIN
    INSERT INTO maludb_subject_relationship (from_subject_id, to_subject_id, relationship_type)
    VALUES (v_mary, v_zozocal, NULL);
    RAISE EXCEPTION 'null relationship_type was not rejected';
EXCEPTION WHEN not_null_violation THEN
    RAISE NOTICE 'OK: relationship_type required';
END;
$$;

-- self-link rejected --------------------------------------------------
DO $$
DECLARE
    v_mary bigint := (SELECT subject_id FROM maludb_subject WHERE canonical_name = 'Mary');
BEGIN
    INSERT INTO maludb_subject_relationship (from_subject_id, to_subject_id, relationship_type)
    VALUES (v_mary, v_mary, 'advisor to');
    RAISE EXCEPTION 'self-link was not rejected';
EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'OK: self-link rejected';
END;
$$;

-- missing subject rejected -------------------------------------------
DO $$
DECLARE
    v_mary bigint := (SELECT subject_id FROM maludb_subject WHERE canonical_name = 'Mary');
BEGIN
    INSERT INTO maludb_subject_relationship (from_subject_id, to_subject_id, relationship_type)
    VALUES (v_mary, 999999999, 'advisor to');
    RAISE EXCEPTION 'missing subject was not rejected';
EXCEPTION WHEN foreign_key_violation THEN
    RAISE NOTICE 'OK: missing subject rejected';
END;
$$;

-- renaming a subject refreshes denormalized labels -------------------
UPDATE maludb_subject SET canonical_name = 'Zozocal Inc' WHERE subject_id = :zozocal_id;

\echo '-- labels follow the rename --'
SELECT from_subject_label, to_subject_label, relationship_type
FROM maludb_subject_relationship
ORDER BY relationship_id;

-- delete == plain DELETE ---------------------------------------------
DELETE FROM maludb_subject_relationship
 WHERE from_subject_id = :mary_id AND relationship_type = 'advisor to';

\echo '-- remaining relationships for Mary --'
SELECT relationship_type
FROM maludb_subject_relationships(:mary_id)
ORDER BY relationship_type;

-- subject delete cascades to its relationships -----------------------
INSERT INTO maludb_subject_relationship (from_subject_id, to_subject_id, relationship_type)
VALUES (:mary_id, :sam_id, 'advisor to');

DELETE FROM maludb_subject WHERE subject_id = :sam_id;

SELECT count(*) AS rels_touching_sam
FROM maludb_subject_relationship
WHERE from_subject_id = :sam_id OR to_subject_id = :sam_id;

-- cleanup -------------------------------------------------------------
RESET ROLE;
SET search_path TO maludb_core, public;

DELETE FROM malu$svpor_subject_relationship_edge WHERE owner_schema = 'svpor_rel_a';
DELETE FROM malu$svpor_subject WHERE owner_schema = 'svpor_rel_a';
DELETE FROM malu$enabled_schema_object WHERE schema_name = 'svpor_rel_a';
DELETE FROM malu$enabled_schema WHERE schema_name = 'svpor_rel_a';
DROP SCHEMA svpor_rel_a CASCADE;
DROP OWNED BY svpor_rel_user;
DROP ROLE svpor_rel_user;
