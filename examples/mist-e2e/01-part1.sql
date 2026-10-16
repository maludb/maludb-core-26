\set ON_ERROR_STOP on
\timing off

-- ============ Step 1: schema + enable memory ============
CREATE SCHEMA IF NOT EXISTS mist;
SET search_path = mist, maludb_core, public;
SELECT * FROM maludb_core.enable_memory_schema('mist');

-- ============ Step 2: verbs ============
INSERT INTO mist.maludb_verb (canonical_name, verb_type, aliases, description) VALUES
  ('manages',     'assigned', ARRAY['leads','runs'],                 'Person has management responsibility for a thing.'),
  ('administers', 'other',    ARRAY['dba_for','database_admin_for'], 'Person is the database/system administrator for a thing.'),
  ('develops',    'created',  ARRAY['programs','codes_for'],         'Person writes/maintains code for a thing.')
ON CONFLICT DO NOTHING;

-- ============ Step 3: subjects ============
DO $$
DECLARE v_mist bigint; v_dave bigint; v_ed bigint; v_joe bigint; v_deb bigint; v_leticia bigint;
BEGIN
    INSERT INTO mist.maludb_subject (canonical_name, subject_type, description)
    VALUES ('MIST','project','The MIST software project; started 2013-03-23, ongoing.') RETURNING subject_id INTO v_mist;
    INSERT INTO mist.maludb_subject (canonical_name, subject_type, description) VALUES ('Dave','person','MIST project manager (day one).') RETURNING subject_id INTO v_dave;
    INSERT INTO mist.maludb_subject (canonical_name, subject_type, description) VALUES ('Ed','person','MIST Oracle DBA and Oracle developer.') RETURNING subject_id INTO v_ed;
    INSERT INTO mist.maludb_subject (canonical_name, subject_type, description) VALUES ('Joe','person','MIST programmer (day one).') RETURNING subject_id INTO v_joe;
    INSERT INTO mist.maludb_subject (canonical_name, subject_type, description) VALUES ('Deb','person','MIST programmer (day one).') RETURNING subject_id INTO v_deb;
    INSERT INTO mist.maludb_subject (canonical_name, subject_type, description) VALUES ('Leticia','person','MIST programmer (day one).') RETURNING subject_id INTO v_leticia;
    RAISE NOTICE 'MIST=% Dave=% Ed=% Joe=% Deb=% Leticia=%', v_mist,v_dave,v_ed,v_joe,v_deb,v_leticia;
END $$;

-- ============ Step 4: project attributes ============
SELECT mist.maludb_attributes_apply('subject',
    (SELECT subject_id FROM mist.maludb_subject WHERE canonical_name='MIST'),
    $json$[
        {"attr_name":"start_date","value_timestamp":"2013-03-23T00:00:00Z"},
        {"attr_name":"status","value_text":"ongoing"}
    ]$json$::jsonb) AS attrs_applied;

SELECT mist.maludb_attribute_template_create(p_applies_to=>'subject_type',p_type_value=>'project',p_attr_name=>'start_date',p_value_type=>'timestamp',p_requirement=>'required',p_label=>'Start Date',p_display_order=>10);
SELECT mist.maludb_attribute_template_create(p_applies_to=>'subject_type',p_type_value=>'project',p_attr_name=>'status',p_value_type=>'text',p_requirement=>'recommended',p_label=>'Status',p_display_order=>20);
SELECT mist.maludb_attribute_template_create(p_applies_to=>'subject_type',p_type_value=>'project',p_attr_name=>'end_date',p_value_type=>'timestamp',p_requirement=>'optional',p_label=>'End Date',p_display_order=>30);

-- ============ Step 5: org chart (role statements + titles) ============
DO $$
DECLARE
    v_mist bigint := (SELECT subject_id FROM mist.maludb_subject WHERE canonical_name='MIST');
    v_stmt bigint; r RECORD;
BEGIN
    FOR r IN SELECT * FROM (VALUES
        ('Dave','manages','Project Manager'),
        ('Ed','administers','Oracle DBA'),
        ('Ed','develops','Oracle Developer'),
        ('Joe','develops','Programmer'),
        ('Deb','develops','Programmer'),
        ('Leticia','develops','Programmer')) AS t(person,verb,title)
    LOOP
        v_stmt := mist.maludb_svpor_statement_create(
            p_subject_kind=>'subject',
            p_subject_id=>(SELECT subject_id FROM mist.maludb_subject WHERE canonical_name=r.person),
            p_verb_id=>(SELECT verb_id FROM mist.maludb_verb WHERE canonical_name=r.verb),
            p_object_kind=>'subject', p_object_id=>v_mist,
            p_valid_from=>'2013-03-23T00:00:00Z'::timestamptz, p_valid_to=>NULL, p_provenance=>'provided');
        PERFORM mist.maludb_svpor_attribute_create(
            p_target_kind=>'svpor_statement', p_target_id=>v_stmt,
            p_attr_name=>'role_title', p_value_text=>r.title);
    END LOOP;
END $$;

-- kickoff episode + attendance
DO $$
DECLARE v_kick bigint; r RECORD;
BEGIN
    v_kick := mist.maludb_register_episode(p_episode_kind=>'Planning',p_title=>'MIST Project Kickoff',
        p_summary=>'Day-one kickoff: project chartered, roles assigned.',
        p_occurred_at=>'2013-03-23T00:00:00Z'::timestamptz);
    FOR r IN SELECT canonical_name FROM mist.maludb_subject WHERE subject_type='person'
    LOOP
        PERFORM mist.maludb_svpor_statement_create(
            p_subject_kind=>'subject',
            p_subject_id=>(SELECT subject_id FROM mist.maludb_subject WHERE canonical_name=r.canonical_name),
            p_verb_id=>(SELECT verb_id FROM mist.maludb_verb WHERE canonical_name='attended'),
            p_object_kind=>'episode_object', p_object_id=>v_kick,
            p_valid_from=>'2013-03-23T00:00:00Z'::timestamptz);
    END LOOP;
END $$;

\echo '===== Q1: raw statement read ====='
SELECT s_subj.canonical_name AS person, v.canonical_name AS relationship, st.valid_from, st.valid_to
FROM mist.maludb_svpor_statement st
JOIN mist.maludb_verb v ON v.verb_id=st.verb_id
JOIN mist.maludb_subject s_subj ON s_subj.subject_id=st.subject_id
JOIN mist.maludb_subject s_obj ON s_obj.subject_id=st.object_id
WHERE st.subject_kind='subject' AND st.object_kind='subject' AND s_obj.canonical_name='MIST'
ORDER BY person;

\echo '===== Q2: one-hop neighbors (incoming) ====='
SELECT label AS person, rel AS relationship, edge_store
FROM mist.maludb_graph_neighbors('subject',
    (SELECT subject_id FROM mist.maludb_subject WHERE canonical_name='MIST'),'in')
ORDER BY person;

\echo '===== Q2b: neighbors filtered to develops ====='
SELECT label FROM mist.maludb_graph_neighbors('subject',
    (SELECT subject_id FROM mist.maludb_subject WHERE canonical_name='MIST'),'in',ARRAY['develops']) ORDER BY label;

\echo '===== Q3: team with titles (edge attributes) ====='
SELECT person.canonical_name AS person, v.canonical_name AS relationship, attr.value_text AS role_title
FROM mist.maludb_svpor_statement st
JOIN mist.maludb_subject person ON person.subject_id=st.subject_id
JOIN mist.maludb_verb v ON v.verb_id=st.verb_id
LEFT JOIN mist.maludb_svpor_attribute attr
  ON attr.target_kind='svpor_statement' AND attr.target_id=st.statement_id AND attr.attr_name='role_title'
WHERE st.object_kind='subject' AND st.object_id=(SELECT subject_id FROM mist.maludb_subject WHERE canonical_name='MIST')
  AND v.canonical_name IN ('manages','administers','develops')
ORDER BY role_title, person;

\echo '===== Q4: object_get(MIST) ====='
SELECT jsonb_pretty(mist.maludb_object_get('subject',
    (SELECT subject_id FROM mist.maludb_subject WHERE canonical_name='MIST')));

\echo '===== Q5: graph_walk from MIST ====='
SELECT object_kind, label, depth, rel, edge_store, path
FROM mist.maludb_graph_walk('subject',
    (SELECT subject_id FROM mist.maludb_subject WHERE canonical_name='MIST'),3,'both')
ORDER BY depth, label;

\echo '===== Q6: attribute_check(MIST) ====='
SELECT jsonb_pretty(mist.maludb_attribute_check('subject',
    (SELECT subject_id FROM mist.maludb_subject WHERE canonical_name='MIST')));

\echo '===== Q7: org chart as of 2013-03-23 ====='
WITH as_of AS (SELECT '2013-03-23'::timestamptz AS t)
SELECT person.canonical_name AS person, v.canonical_name AS relationship
FROM mist.maludb_svpor_statement st
JOIN mist.maludb_subject person ON person.subject_id=st.subject_id
JOIN mist.maludb_verb v ON v.verb_id=st.verb_id
CROSS JOIN as_of
WHERE st.object_id=(SELECT subject_id FROM mist.maludb_subject WHERE canonical_name='MIST')
  AND st.object_kind='subject' AND v.canonical_name IN ('manages','administers','develops')
  AND st.valid_from<=as_of.t AND (st.valid_to IS NULL OR st.valid_to>as_of.t)
ORDER BY person;
