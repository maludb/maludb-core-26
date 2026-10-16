\set ON_ERROR_STOP on
SET search_path = mist, maludb_core, public;

-- ===== Step 6: hierarchy verbs (part_of + assigned, neither seeded) =====
INSERT INTO mist.maludb_verb (canonical_name, verb_type, aliases, description) VALUES
  ('part_of',  'other',    ARRAY['belongs_to','child_of'], 'Object A is a structural part of object B.'),
  ('assigned', 'assigned', ARRAY['assigned_to','owns'],    'Person is assigned to a task or piece of work.')
ON CONFLICT DO NOTHING;

-- ===== Sprints & Tasks as episodes + part_of hierarchy =====
DO $$
DECLARE
    v_mist bigint := (SELECT subject_id FROM mist.maludb_subject WHERE canonical_name='MIST');
    v_part bigint := (SELECT verb_id FROM mist.maludb_verb WHERE canonical_name='part_of');
    v_sprint bigint; v_task bigint;
BEGIN
    v_sprint := mist.maludb_register_episode(p_episode_kind=>'Sprint',p_title=>'MIST Sprint 1',
        p_summary=>'First two-week iteration.',
        p_occurred_at=>'2013-03-25T00:00:00Z'::timestamptz, p_occurred_until=>'2013-04-05T00:00:00Z'::timestamptz);
    PERFORM mist.maludb_attributes_apply('episode_object', v_sprint, $j$[
        {"attr_name":"planned_start_date","value_timestamp":"2013-03-25T00:00:00Z"},
        {"attr_name":"planned_end_date","value_timestamp":"2013-04-05T00:00:00Z"},
        {"attr_name":"estimated_story_points","value_numeric":21,"unit":"points"}]$j$::jsonb);

    v_task := mist.maludb_register_episode(p_episode_kind=>'Task',p_title=>'Build login screen',
        p_summary=>'Implement the MIST login UI + auth wiring.',
        p_occurred_at=>'2013-03-25T00:00:00Z'::timestamptz);
    PERFORM mist.maludb_attributes_apply('episode_object', v_task, $j$[
        {"attr_name":"planned_start_date","value_timestamp":"2013-03-25T00:00:00Z"},
        {"attr_name":"planned_end_date","value_timestamp":"2013-03-29T00:00:00Z"},
        {"attr_name":"percent_complete","value_numeric":0,"unit":"percent"},
        {"attr_name":"priority","value_text":"high"}]$j$::jsonb);

    PERFORM mist.maludb_svpor_statement_create(p_subject_kind=>'episode_object',p_subject_id=>v_sprint,
        p_verb_id=>v_part,p_object_kind=>'subject',p_object_id=>v_mist,
        p_valid_from=>'2013-03-25T00:00:00Z'::timestamptz);
    PERFORM mist.maludb_svpor_statement_create(p_subject_kind=>'episode_object',p_subject_id=>v_task,
        p_verb_id=>v_part,p_object_kind=>'episode_object',p_object_id=>v_sprint,
        p_valid_from=>'2013-03-25T00:00:00Z'::timestamptz);
    PERFORM mist.maludb_svpor_statement_create(p_subject_kind=>'subject',
        p_subject_id=>(SELECT subject_id FROM mist.maludb_subject WHERE canonical_name='Joe'),
        p_verb_id=>(SELECT verb_id FROM mist.maludb_verb WHERE canonical_name='assigned'),
        p_object_kind=>'episode_object',p_object_id=>v_task,
        p_valid_from=>'2013-03-25T00:00:00Z'::timestamptz);
    RAISE NOTICE 'sprint=% task=%', v_sprint, v_task;
END $$;

-- ===== Step 7: meeting + generated document (REAL facade = maludb_upload_document) =====
DO $$
DECLARE
    v_review bigint; v_doc bigint;
    v_genby bigint := (SELECT verb_id FROM mist.maludb_verb WHERE canonical_name='generated_by');
    v_att   bigint := (SELECT verb_id FROM mist.maludb_verb WHERE canonical_name='attended');
    r RECORD;
BEGIN
    v_review := mist.maludb_register_episode(p_episode_kind=>'Review',p_title=>'MIST Sprint 1 Review',
        p_summary=>'Demoed login screen; accepted 18 of 21 points.',
        p_occurred_at=>'2013-04-05T15:00:00Z'::timestamptz);
    PERFORM mist.maludb_attributes_apply('episode_object', v_review, $j$[
        {"attr_name":"duration_minutes","value_numeric":60,"unit":"minutes"}]$j$::jsonb);
    FOR r IN SELECT subject_id FROM mist.maludb_subject WHERE subject_type='person'
    LOOP
        PERFORM mist.maludb_svpor_statement_create(p_subject_kind=>'subject',p_subject_id=>r.subject_id,
            p_verb_id=>v_att,p_object_kind=>'episode_object',p_object_id=>v_review,
            p_valid_from=>'2013-04-05T15:00:00Z'::timestamptz);
    END LOOP;

    v_doc := mist.maludb_upload_document(
        p_title=>'Sprint 1 Review — Minutes',
        p_content_text=>'Attendees: Dave, Ed, Joe, Deb, Leticia. Outcome: 18/21 accepted.',
        p_source_type=>'document',
        p_document_type=>'Minutes');

    PERFORM mist.maludb_svpor_statement_create(p_subject_kind=>'document',p_subject_id=>v_doc,
        p_verb_id=>v_genby,p_object_kind=>'episode_object',p_object_id=>v_review,
        p_valid_from=>'2013-04-05T15:00:00Z'::timestamptz);
    RAISE NOTICE 'review=% doc=%', v_review, v_doc;
END $$;

-- ===== Step 8: staffing changes =====
SELECT mist.maludb_svpor_statement_close(
    (SELECT st.statement_id FROM mist.maludb_svpor_statement st
       JOIN mist.maludb_verb v ON v.verb_id=st.verb_id
      WHERE st.subject_id=(SELECT subject_id FROM mist.maludb_subject WHERE canonical_name='Joe')
        AND st.object_id=(SELECT subject_id FROM mist.maludb_subject WHERE canonical_name='MIST')
        AND v.canonical_name='develops'),
    '2013-06-30T00:00:00Z'::timestamptz) AS joe_closed;

DO $$
DECLARE v_priya bigint; v_stmt bigint;
BEGIN
    INSERT INTO mist.maludb_subject (canonical_name, subject_type, description)
    VALUES ('Priya','person','MIST programmer (joined 2013-07-01).')
    ON CONFLICT DO NOTHING;
    SELECT subject_id INTO v_priya FROM mist.maludb_subject WHERE canonical_name='Priya';
    v_stmt := mist.maludb_svpor_statement_create(p_subject_kind=>'subject',p_subject_id=>v_priya,
        p_verb_id=>(SELECT verb_id FROM mist.maludb_verb WHERE canonical_name='develops'),
        p_object_kind=>'subject',p_object_id=>(SELECT subject_id FROM mist.maludb_subject WHERE canonical_name='MIST'),
        p_valid_from=>'2013-07-01T00:00:00Z'::timestamptz);
    PERFORM mist.maludb_svpor_attribute_create(p_target_kind=>'svpor_statement',p_target_id=>v_stmt,
        p_attr_name=>'role_title',p_value_text=>'Programmer');
END $$;

-- ===== Step 9: external HR reference attribute =====
SELECT mist.maludb_svpor_attribute_create(
    p_target_kind=>'subject',
    p_target_id=>(SELECT subject_id FROM mist.maludb_subject WHERE canonical_name='Ed'),
    p_attr_name=>'hr_employee', p_value_text=>'Ed Honour',
    p_ref_source=>'hr', p_ref_entity=>'employees', p_ref_key=>'E-100') AS hr_attr_id;

\t on
\a
\echo '== Q8 developers as of three dates =='
SELECT d::date AS as_of, string_agg(developer,', ' ORDER BY developer) AS developers FROM (
  SELECT x.d, p.canonical_name AS developer
  FROM (VALUES ('2013-03-23'::timestamptz),('2013-06-30'::timestamptz),('2013-07-01'::timestamptz)) AS x(d)
  JOIN mist.maludb_svpor_statement st ON st.object_id=(SELECT subject_id FROM mist.maludb_subject WHERE canonical_name='MIST') AND st.object_kind='subject'
  JOIN mist.maludb_subject p ON p.subject_id=st.subject_id
  JOIN mist.maludb_verb v ON v.verb_id=st.verb_id AND v.canonical_name='develops'
  WHERE st.valid_from<=x.d AND (st.valid_to IS NULL OR st.valid_to>x.d)
) s GROUP BY d ORDER BY d;

\echo '== Q9 part_of walk from MIST (incoming) =='
SELECT object_kind||'|'||label||'|depth'||depth||'|'||rel
FROM mist.maludb_graph_walk('subject',(SELECT subject_id FROM mist.maludb_subject WHERE canonical_name='MIST'),4,'in',ARRAY['part_of'])
ORDER BY depth,label;

\echo '== Q10 task object_get (compact) =='
SELECT mist.maludb_object_get('episode_object',(SELECT episode_id FROM mist.maludb_episode WHERE title='Build login screen'))::text;

\echo '== Q10b sprint episode_get keys =='
SELECT (SELECT string_agg(k,',' ORDER BY k) FROM jsonb_object_keys(mist.maludb_episode_get((SELECT episode_id FROM mist.maludb_episode WHERE title='MIST Sprint 1'))) k);

\echo '== Q11 planned vs actual =='
SELECT e.title||' | actual '||coalesce(e.occurred_at::date::text,'-')||'..'||coalesce(e.occurred_until::date::text,'-')
       ||' | planned '||coalesce(ps.value_timestamp::date::text,'-')||'..'||coalesce(pe.value_timestamp::date::text,'-')
FROM mist.maludb_episode e
LEFT JOIN mist.maludb_svpor_attribute ps ON ps.target_kind='episode_object' AND ps.target_id=e.episode_id AND ps.attr_name='planned_start_date'
LEFT JOIN mist.maludb_svpor_attribute pe ON pe.target_kind='episode_object' AND pe.target_id=e.episode_id AND pe.attr_name='planned_end_date'
WHERE e.episode_kind IN ('Sprint','Task') ORDER BY e.occurred_at;

\echo '== Q12 HR reverse lookup =='
SELECT target_kind||'|'||target_id||'|'||value_text||'|'||ref_source||'/'||ref_entity||'/'||ref_key
FROM mist.maludb_svpor_attribute WHERE ref_source='hr' AND ref_entity='employees' AND ref_key='E-100';
