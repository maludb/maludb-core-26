-- R1.1-5: prompt variable schema + bind-time validators.
--
-- Exercises malu$prompt_variable + _validate_bind_variables across:
--   * additive coexistence with the legacy JSONB variables column
--   * required / default / type coercion / enum / regex / length
--   * on_missing_variable + on_extra_variable + null_handling
--   * escape_mode + max_rendered_prompt_chars + on_truncate

\set ECHO all
SET search_path = maludb_core, public;
SET client_min_messages = NOTICE;

-- ---------- fixture ----------------------------------------------------
INSERT INTO malu$prompt_template (template_name, body, variables)
VALUES
    ('pv_typed',  'hello {{name}}, you are {{age}} years old',  '{}'::jsonb),
    ('pv_legacy', 'plain {{label}}', '{"label": "?"}'::jsonb);

SELECT declare_prompt_variable('pv_typed', 'name',
    p_variable_type=>'text',
    p_required=>true,
    p_max_length=>32,
    p_validation_rule=>'^[A-Za-z][A-Za-z0-9 _-]*$') > 0 AS ok_name;

SELECT declare_prompt_variable('pv_typed', 'age',
    p_variable_type=>'integer',
    p_required=>false,
    p_default_value=>'0') > 0 AS ok_age;

SELECT declare_prompt_variable('pv_typed', 'tier',
    p_variable_type=>'enum',
    p_required=>false,
    p_default_value=>'standard',
    p_enum_values=>ARRAY['standard','premium','enterprise']) > 0 AS ok_tier;

-- notes: text with no validation rule, so escape-mode tests can use special chars
SELECT declare_prompt_variable('pv_typed', 'notes',
    p_variable_type=>'text',
    p_required=>false) > 0 AS ok_notes;

-- declare_prompt_variable upsert: bump max_length on `name`
SELECT declare_prompt_variable('pv_typed', 'name',
    p_variable_type=>'text',
    p_required=>true,
    p_max_length=>64,
    p_validation_rule=>'^[A-Za-z][A-Za-z0-9 _-]*$') > 0 AS ok_name_upsert;

SELECT variable_name, variable_type, required, max_length, default_value, enum_values
FROM malu$prompt_variable
WHERE template_id = (SELECT template_id FROM malu$prompt_template WHERE template_name='pv_typed')
ORDER BY variable_name;

-- ---------- typed path: happy ------------------------------------------
SELECT status, normalized_variables, declared_count, supplied_count, cardinality(warnings) AS n_warn
FROM _validate_bind_variables(
    (SELECT template_id FROM malu$prompt_template WHERE template_name='pv_typed'),
    jsonb_build_object('name', 'Alice', 'age', 30, 'tier', 'premium'),
    _default_bind_options());

-- default fills in for missing optionals
SELECT normalized_variables
FROM _validate_bind_variables(
    (SELECT template_id FROM malu$prompt_template WHERE template_name='pv_typed'),
    jsonb_build_object('name', 'Bob'),
    _default_bind_options());

-- ---------- typed path: required missing -------------------------------
DO $$ BEGIN
    PERFORM _validate_bind_variables(
        (SELECT template_id FROM malu$prompt_template WHERE template_name='pv_typed'),
        '{}'::jsonb,
        _default_bind_options());
    RAISE EXCEPTION 'should have rejected missing required';
EXCEPTION WHEN not_null_violation THEN
    RAISE NOTICE 'OK: required-missing rejected';
END $$;

-- on_missing_variable='blank' → fills with empty string
SELECT normalized_variables
FROM _validate_bind_variables(
    (SELECT template_id FROM malu$prompt_template WHERE template_name='pv_typed'),
    '{}'::jsonb,
    ROW(true,'blank','warn','null_literal',NULL,NULL,'error','none')::malu$bind_options);

-- on_missing_variable='preserve' → leaves the slot unfilled
SELECT normalized_variables
FROM _validate_bind_variables(
    (SELECT template_id FROM malu$prompt_template WHERE template_name='pv_typed'),
    '{}'::jsonb,
    ROW(true,'preserve','warn','null_literal',NULL,NULL,'error','none')::malu$bind_options);

-- ---------- type coercion ----------------------------------------------
-- integer-as-string OK, integer-as-bool rejected
SELECT normalized_variables
FROM _validate_bind_variables(
    (SELECT template_id FROM malu$prompt_template WHERE template_name='pv_typed'),
    jsonb_build_object('name','Carla','age','42'),
    _default_bind_options());

DO $$ BEGIN
    PERFORM _validate_bind_variables(
        (SELECT template_id FROM malu$prompt_template WHERE template_name='pv_typed'),
        jsonb_build_object('name','Dani','age', true),
        _default_bind_options());
    RAISE EXCEPTION 'should have rejected bool-as-int';
EXCEPTION WHEN invalid_parameter_value THEN
    RAISE NOTICE 'OK: integer rejects boolean';
END $$;

-- enum rejects unknown value
DO $$ BEGIN
    PERFORM _validate_bind_variables(
        (SELECT template_id FROM malu$prompt_template WHERE template_name='pv_typed'),
        jsonb_build_object('name','Eli','tier','platinum'),
        _default_bind_options());
    RAISE EXCEPTION 'should have rejected enum value';
EXCEPTION WHEN invalid_parameter_value THEN
    RAISE NOTICE 'OK: enum rejects out-of-set value';
END $$;

-- regex on text
DO $$ BEGIN
    PERFORM _validate_bind_variables(
        (SELECT template_id FROM malu$prompt_template WHERE template_name='pv_typed'),
        jsonb_build_object('name','9-bad-start'),
        _default_bind_options());
    RAISE EXCEPTION 'should have rejected regex';
EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'OK: regex rule enforced';
END $$;

-- ---------- length / truncate ------------------------------------------
-- max_length on the variable: error mode
DO $$ BEGIN
    PERFORM _validate_bind_variables(
        (SELECT template_id FROM malu$prompt_template WHERE template_name='pv_typed'),
        jsonb_build_object('name', repeat('A', 200)),
        _default_bind_options());
    RAISE EXCEPTION 'should have rejected length';
EXCEPTION WHEN string_data_right_truncation THEN
    RAISE NOTICE 'OK: length rule enforced';
END $$;

-- max_length on the variable: truncate_with_notice mode
SELECT char_length(normalized_variables ->> 'name') AS truncated_len
FROM _validate_bind_variables(
    (SELECT template_id FROM malu$prompt_template WHERE template_name='pv_typed'),
    jsonb_build_object('name', repeat('A', 200)),
    ROW(true,'error','warn','null_literal',NULL,NULL,'truncate_with_notice','none')::malu$bind_options);

-- max_rendered_prompt_chars: error when the variables alone blow the cap
DO $$ BEGIN
    PERFORM _validate_bind_variables(
        (SELECT template_id FROM malu$prompt_template WHERE template_name='pv_typed'),
        jsonb_build_object('name', repeat('B', 60), 'age', 1),
        ROW(true,'error','warn','null_literal',NULL,10,'error','none')::malu$bind_options);
    RAISE EXCEPTION 'should have rejected total length';
EXCEPTION WHEN string_data_right_truncation THEN
    RAISE NOTICE 'OK: max_rendered_prompt_chars enforced';
END $$;

-- max_rendered_prompt_chars: warn under truncate_with_notice
SELECT status, cardinality(warnings) AS n_warn
FROM _validate_bind_variables(
    (SELECT template_id FROM malu$prompt_template WHERE template_name='pv_typed'),
    jsonb_build_object('name', repeat('C', 60), 'age', 1),
    ROW(true,'error','warn','null_literal',NULL,10,'truncate_with_notice','none')::malu$bind_options);

-- ---------- extras / strict mismatch -----------------------------------
SELECT status, cardinality(warnings) AS n_warn
FROM _validate_bind_variables(
    (SELECT template_id FROM malu$prompt_template WHERE template_name='pv_typed'),
    jsonb_build_object('name','Fay','flavour','mango'),
    _default_bind_options());

DO $$ BEGIN
    PERFORM _validate_bind_variables(
        (SELECT template_id FROM malu$prompt_template WHERE template_name='pv_typed'),
        jsonb_build_object('name','Gia','flavour','mango'),
        ROW(true,'error','error','null_literal',NULL,NULL,'error','none')::malu$bind_options);
    RAISE EXCEPTION 'should have rejected extras';
EXCEPTION WHEN invalid_parameter_value THEN
    RAISE NOTICE 'OK: on_extra_variable=error enforced';
END $$;

-- ---------- null handling ----------------------------------------------
SELECT normalized_variables
FROM _validate_bind_variables(
    (SELECT template_id FROM malu$prompt_template WHERE template_name='pv_typed'),
    jsonb_build_object('name','Hal','age',NULL),
    _default_bind_options());

SELECT normalized_variables
FROM _validate_bind_variables(
    (SELECT template_id FROM malu$prompt_template WHERE template_name='pv_typed'),
    jsonb_build_object('name','Ivy','age',NULL),
    ROW(true,'error','warn','empty',NULL,NULL,'error','none')::malu$bind_options);

DO $$ BEGIN
    PERFORM _validate_bind_variables(
        (SELECT template_id FROM malu$prompt_template WHERE template_name='pv_typed'),
        jsonb_build_object('name','Jay','age',NULL),
        ROW(true,'error','warn','error',NULL,NULL,'error','none')::malu$bind_options);
    RAISE EXCEPTION 'should have rejected null';
EXCEPTION WHEN null_value_not_allowed THEN
    RAISE NOTICE 'OK: null_handling=error enforced';
END $$;

-- ---------- escape mode ------------------------------------------------
SELECT normalized_variables ->> 'notes' AS sql_escaped
FROM _validate_bind_variables(
    (SELECT template_id FROM malu$prompt_template WHERE template_name='pv_typed'),
    jsonb_build_object('name','Kim','notes', E'O''Reilly''s book'),
    ROW(true,'error','warn','null_literal',NULL,NULL,'error','sql_literal')::malu$bind_options);

SELECT normalized_variables ->> 'notes' AS json_escaped
FROM _validate_bind_variables(
    (SELECT template_id FROM malu$prompt_template WHERE template_name='pv_typed'),
    jsonb_build_object('name','Liu','notes', E'she said "hi"\nand left'),
    ROW(true,'error','warn','null_literal',NULL,NULL,'error','json')::malu$bind_options);

-- ---------- legacy JSONB path ------------------------------------------
SELECT status, declared_count, supplied_count, normalized_variables
FROM _validate_bind_variables(
    (SELECT template_id FROM malu$prompt_template WHERE template_name='pv_legacy'),
    jsonb_build_object('label','beta'),
    _default_bind_options());

-- legacy + extras: warn (default)
SELECT status, cardinality(warnings) AS n_warn
FROM _validate_bind_variables(
    (SELECT template_id FROM malu$prompt_template WHERE template_name='pv_legacy'),
    jsonb_build_object('label','beta','extra','x'),
    _default_bind_options());

-- ---------- input shape errors -----------------------------------------
DO $$ BEGIN
    PERFORM _validate_bind_variables(
        (SELECT template_id FROM malu$prompt_template WHERE template_name='pv_typed'),
        '"not an object"'::jsonb,
        _default_bind_options());
    RAISE EXCEPTION 'should have rejected non-object input';
EXCEPTION WHEN invalid_parameter_value THEN
    RAISE NOTICE 'OK: non-object variables rejected';
END $$;

-- ---------- cleanup ----------------------------------------------------
DELETE FROM malu$prompt_variable
WHERE template_id IN (
    SELECT template_id FROM malu$prompt_template
    WHERE template_name IN ('pv_typed','pv_legacy'));
DELETE FROM malu$prompt_template
WHERE template_name IN ('pv_typed','pv_legacy');
