\echo Use "ALTER EXTENSION maludb_core UPDATE TO '0.84.0'" to load this file. \quit

-- =====================================================================
-- maludb_core 0.83.0 -> 0.84.0
--
-- Front-end ergonomics for the attribute model, plus external-record
-- reference attributes.
--
--   (A) Bundled reads. A generic maludb_object_get(kind, id) returns an
--       object together with its attributes (and statements/details for
--       episodes) as one JSON payload, and opt-in
--       maludb_<obj>_with_attributes views add an `attributes` jsonb
--       column to the episode/subject/document facades so a list query
--       returns each object with its attributes inline.
--
--   (B) Single-POST writes. maludb_attributes_apply(kind, id, jsonb)
--       bulk-upserts an array of attributes, so an API POST handler can
--       create an object and all its attributes in one transaction.
--
--   (C) External references. An attribute can point at a record in an
--       external relational table (e.g. an svpor_subject -> hr.persons:
--       emp_123) instead of duplicating the fields. A reference is just
--       an attribute whose value is a pointer: malu$svpor_attribute gains
--       ref_source / ref_entity / ref_key (advisory -- no FK; the target
--       table may be in another schema, database, or system), indexed for
--       reverse lookup, and attribute templates gain value_type
--       'reference'. Pointer-only by design: MaluDB stores the typed link
--       and the app owns how to fetch and deep-link each source.
--       provenance + confidence carry over, so an LLM match lands as
--       'suggested' for human confirmation.
--
-- Existing schemas pick up the new objects by re-running
-- maludb_core.enable_memory_schema().
-- =====================================================================

CREATE OR REPLACE FUNCTION maludb_core.maludb_core_version() RETURNS text
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$ SELECT '0.84.0'::text $body$;

-- ===== 1. external-reference columns on the attribute store =========
ALTER TABLE maludb_core.malu$svpor_attribute
    ADD COLUMN IF NOT EXISTS ref_source text,
    ADD COLUMN IF NOT EXISTS ref_entity text,
    ADD COLUMN IF NOT EXISTS ref_key    text;

-- Reverse lookup: "which node is external record X?"
CREATE INDEX IF NOT EXISTS malu$svpor_attribute_ref_idx
    ON maludb_core.malu$svpor_attribute(owner_schema, ref_source, ref_entity, ref_key)
    WHERE ref_source IS NOT NULL;

-- ===== 2. template value_type gains 'reference' =====================
ALTER TABLE maludb_core.malu$attribute_template
    DROP CONSTRAINT malu$attribute_template_value_type_check;
ALTER TABLE maludb_core.malu$attribute_template
    ADD CONSTRAINT malu$attribute_template_value_type_check
    CHECK (value_type IN ('timestamp','tstzrange','numeric','text','jsonb','reference'));

-- ===== 3. extend register_svpor_attribute with the ref fields =======
-- The 14-arg version is replaced by a 17-arg version (3 trailing ref
-- params, default NULL); existing 14-arg callers keep working via the
-- defaults. DROP+CREATE because the signature changes.
DROP FUNCTION IF EXISTS maludb_core.register_svpor_attribute(
    text, bigint, text, timestamptz, tstzrange, numeric, text, jsonb, text, text, numeric, timestamptz, timestamptz, jsonb);

CREATE FUNCTION maludb_core.register_svpor_attribute(
    p_target_kind     text,
    p_target_id       bigint,
    p_attr_name       text,
    p_value_timestamp timestamptz DEFAULT NULL,
    p_value_range     tstzrange   DEFAULT NULL,
    p_value_numeric   numeric     DEFAULT NULL,
    p_value_text      text        DEFAULT NULL,
    p_value_jsonb     jsonb       DEFAULT NULL,
    p_unit            text        DEFAULT NULL,
    p_provenance      text        DEFAULT 'provided',
    p_confidence      numeric     DEFAULT NULL,
    p_valid_from      timestamptz DEFAULT NULL,
    p_valid_to        timestamptz DEFAULT NULL,
    p_metadata_jsonb  jsonb       DEFAULT '{}'::jsonb,
    p_ref_source      text        DEFAULT NULL,
    p_ref_entity      text        DEFAULT NULL,
    p_ref_key         text        DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql
SECURITY INVOKER
AS $body$
DECLARE
    v_schema     name := current_schema();
    v_kind       text := lower(btrim(COALESCE(p_target_kind, '')));
    v_attr       text := btrim(COALESCE(p_attr_name, ''));
    v_provenance text := COALESCE(NULLIF(btrim(p_provenance), ''), 'provided');
    v_id         bigint;
BEGIN
    IF p_target_id IS NULL OR v_attr = '' THEN
        RAISE EXCEPTION 'register_svpor_attribute: target_id and attr_name are required'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;
    IF v_provenance NOT IN ('provided','suggested','accepted','rejected') THEN
        RAISE EXCEPTION 'register_svpor_attribute: bad provenance %', v_provenance
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    PERFORM maludb_core._svpor_attribute_assert_target(v_schema, v_kind, p_target_id);

    INSERT INTO maludb_core.malu$svpor_attribute
        (owner_schema, target_kind, target_id, attr_name, value_timestamp, value_range,
         value_numeric, value_text, value_jsonb, unit, provenance, confidence,
         valid_from, valid_to, metadata_jsonb, ref_source, ref_entity, ref_key)
    VALUES
        (v_schema, v_kind, p_target_id, v_attr, p_value_timestamp, p_value_range,
         p_value_numeric, p_value_text, p_value_jsonb, p_unit, v_provenance, p_confidence,
         p_valid_from, p_valid_to, COALESCE(p_metadata_jsonb, '{}'::jsonb),
         NULLIF(btrim(COALESCE(p_ref_source,'')),''), NULLIF(btrim(COALESCE(p_ref_entity,'')),''), NULLIF(btrim(COALESCE(p_ref_key,'')),''))
    ON CONFLICT (owner_schema, target_kind, target_id, attr_name)
    DO UPDATE SET
        value_timestamp = EXCLUDED.value_timestamp,
        value_range     = EXCLUDED.value_range,
        value_numeric   = EXCLUDED.value_numeric,
        value_text      = EXCLUDED.value_text,
        value_jsonb     = EXCLUDED.value_jsonb,
        unit            = EXCLUDED.unit,
        provenance      = EXCLUDED.provenance,
        confidence      = EXCLUDED.confidence,
        valid_from      = EXCLUDED.valid_from,
        valid_to        = EXCLUDED.valid_to,
        metadata_jsonb  = malu$svpor_attribute.metadata_jsonb || EXCLUDED.metadata_jsonb,
        ref_source      = EXCLUDED.ref_source,
        ref_entity      = EXCLUDED.ref_entity,
        ref_key         = EXCLUDED.ref_key
    RETURNING attribute_id INTO v_id;

    RETURN v_id;
END;
$body$;
REVOKE ALL ON FUNCTION maludb_core.register_svpor_attribute(
    text, bigint, text, timestamptz, tstzrange, numeric, text, jsonb, text, text, numeric, timestamptz, timestamptz, jsonb, text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core.register_svpor_attribute(
    text, bigint, text, timestamptz, tstzrange, numeric, text, jsonb, text, text, numeric, timestamptz, timestamptz, jsonb, text, text, text)
    TO maludb_memory_admin, maludb_memory_executor;

-- ===== 4. attributes_jsonb -- roll a target's attributes into JSON ===
-- No SET search_path: SECURITY INVOKER, scopes by current_schema().
CREATE FUNCTION maludb_core.attributes_jsonb(p_target_kind text, p_target_id bigint)
RETURNS jsonb
LANGUAGE sql STABLE SECURITY INVOKER
AS $body$
    SELECT COALESCE(jsonb_object_agg(a.attr_name, jsonb_build_object(
                'value', COALESCE(to_jsonb(a.value_timestamp), to_jsonb(a.value_range),
                                  to_jsonb(a.value_numeric), to_jsonb(a.value_text), a.value_jsonb),
                'type', CASE
                            WHEN a.ref_source     IS NOT NULL THEN 'reference'
                            WHEN a.value_timestamp IS NOT NULL THEN 'timestamp'
                            WHEN a.value_range    IS NOT NULL THEN 'tstzrange'
                            WHEN a.value_numeric  IS NOT NULL THEN 'numeric'
                            WHEN a.value_text     IS NOT NULL THEN 'text'
                            WHEN a.value_jsonb    IS NOT NULL THEN 'jsonb'
                            ELSE NULL
                        END,
                'unit', a.unit,
                'provenance', a.provenance,
                'confidence', a.confidence,
                'ref', CASE WHEN a.ref_source IS NOT NULL
                            THEN jsonb_build_object('source', a.ref_source, 'entity', a.ref_entity, 'key', a.ref_key)
                            ELSE NULL END,
                'valid_from', a.valid_from,
                'valid_to', a.valid_to,
                'attribute_id', a.attribute_id)), '{}'::jsonb)
      FROM maludb_core.malu$svpor_attribute a
     WHERE a.owner_schema = current_schema()
       AND a.target_kind = lower(btrim(p_target_kind))
       AND a.target_id = p_target_id
$body$;
REVOKE ALL ON FUNCTION maludb_core.attributes_jsonb(text, bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core.attributes_jsonb(text, bigint)
    TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;

-- ===== 5. object_get -- generic object + attributes (+ relations) ===
CREATE FUNCTION maludb_core.object_get(p_target_kind text, p_target_id bigint)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY INVOKER
AS $body$
DECLARE
    v_schema name := current_schema();
    v_kind   text := lower(btrim(COALESCE(p_target_kind, '')));
    v_object jsonb;
    v_result jsonb;
BEGIN
    CASE v_kind
        WHEN 'episode_object' THEN
            SELECT to_jsonb(e) INTO v_object FROM maludb_core.malu$episode_object e
             WHERE e.owner_schema = v_schema AND e.episode_id = p_target_id;
        WHEN 'subject' THEN
            SELECT to_jsonb(s) INTO v_object FROM maludb_core.malu$svpor_subject s
             WHERE s.owner_schema = v_schema AND s.subject_id = p_target_id;
        WHEN 'verb' THEN
            SELECT to_jsonb(v) INTO v_object FROM maludb_core.malu$svpor_verb v
             WHERE v.owner_schema = v_schema AND v.verb_id = p_target_id;
        WHEN 'document' THEN
            SELECT to_jsonb(d) INTO v_object FROM maludb_core.malu$document d
             WHERE d.owner_schema = v_schema AND d.document_id = p_target_id;
        WHEN 'memory' THEN
            SELECT to_jsonb(m) INTO v_object FROM maludb_core.malu$memory m
             WHERE m.owner_schema = v_schema AND m.memory_id = p_target_id;
        WHEN 'source_package' THEN
            SELECT to_jsonb(sp) INTO v_object FROM maludb_core.malu$source_package sp
             WHERE sp.owner_schema = v_schema AND sp.source_package_id = p_target_id;
        WHEN 'claim' THEN
            SELECT to_jsonb(c) INTO v_object FROM maludb_core.malu$claim c
             WHERE c.owner_schema = v_schema AND c.claim_id = p_target_id;
        WHEN 'fact' THEN
            SELECT to_jsonb(f) INTO v_object FROM maludb_core.malu$fact f
             WHERE f.owner_schema = v_schema AND f.fact_id = p_target_id;
        WHEN 'memory_detail_object' THEN
            SELECT to_jsonb(mdo) INTO v_object FROM maludb_core.malu$memory_detail_object mdo
             WHERE mdo.owner_schema = v_schema AND mdo.mdo_id = p_target_id;
        WHEN 'svpor_statement' THEN
            SELECT to_jsonb(st) INTO v_object FROM maludb_core.malu$svpor_statement st
             WHERE st.owner_schema = v_schema AND st.statement_id = p_target_id;
        ELSE
            RAISE EXCEPTION 'object_get: unsupported target kind %', v_kind
                USING ERRCODE = 'invalid_parameter_value';
    END CASE;

    IF v_object IS NULL THEN
        RETURN NULL;
    END IF;

    v_result := jsonb_build_object(
        'kind', v_kind,
        'id', p_target_id,
        'object', v_object,
        'attributes', maludb_core.attributes_jsonb(v_kind, p_target_id));

    -- Episodes also carry their statements + detail steps.
    IF v_kind = 'episode_object' THEN
        v_result := v_result || jsonb_build_object(
            'statements', maludb_core.episode_get(p_target_id) -> 'statements',
            'details',    maludb_core.episode_get(p_target_id) -> 'details');
    END IF;

    RETURN v_result;
END;
$body$;
REVOKE ALL ON FUNCTION maludb_core.object_get(text, bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core.object_get(text, bigint)
    TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;

-- ===== 6. attributes_apply -- bulk upsert from a jsonb array ========
-- Each element: { attr_name, value_timestamp?, value_range?, value_numeric?,
--                 value_text?, value_jsonb?, unit?, provenance?, confidence?,
--                 ref_source?, ref_entity?, ref_key? }
CREATE FUNCTION maludb_core.attributes_apply(
    p_target_kind text, p_target_id bigint, p_attributes jsonb
) RETURNS integer
LANGUAGE plpgsql
SECURITY INVOKER
AS $body$
DECLARE
    v_elem  jsonb;
    v_count integer := 0;
BEGIN
    IF p_attributes IS NULL OR jsonb_typeof(p_attributes) <> 'array' THEN
        RAISE EXCEPTION 'attributes_apply: p_attributes must be a JSON array'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    FOR v_elem IN SELECT * FROM jsonb_array_elements(p_attributes)
    LOOP
        PERFORM maludb_core.register_svpor_attribute(
            p_target_kind,
            p_target_id,
            v_elem ->> 'attr_name',
            (v_elem ->> 'value_timestamp')::timestamptz,
            (v_elem ->> 'value_range')::tstzrange,
            (v_elem ->> 'value_numeric')::numeric,
            v_elem ->> 'value_text',
            v_elem -> 'value_jsonb',
            v_elem ->> 'unit',
            COALESCE(v_elem ->> 'provenance', 'provided'),
            (v_elem ->> 'confidence')::numeric,
            (v_elem ->> 'valid_from')::timestamptz,
            (v_elem ->> 'valid_to')::timestamptz,
            COALESCE(v_elem -> 'metadata_jsonb', '{}'::jsonb),
            v_elem ->> 'ref_source',
            v_elem ->> 'ref_entity',
            v_elem ->> 'ref_key');
        v_count := v_count + 1;
    END LOOP;

    RETURN v_count;
END;
$body$;
REVOKE ALL ON FUNCTION maludb_core.attributes_apply(text, bigint, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core.attributes_apply(text, bigint, jsonb)
    TO maludb_memory_admin, maludb_memory_executor;

-- ===== 7. 0.84.0 schema-local facade builder ========================
CREATE FUNCTION maludb_core._enable_memory_schema_0840_facade(p_schema name) RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
DECLARE
    v_count integer := 0;
BEGIN
    PERFORM maludb_core._memory_schema_assert_manageable(p_schema);

    -- ---- re-issue maludb_svpor_attribute view with ref_* columns ---
    -- (CREATE OR REPLACE appends the new columns at the end.)
    EXECUTE format($sql$
        CREATE OR REPLACE VIEW %I.maludb_svpor_attribute WITH (security_invoker = true) AS
        SELECT attribute_id, target_kind, target_id, attr_name,
               value_timestamp, value_range, value_numeric, value_text, value_jsonb,
               unit, provenance, confidence, valid_from, valid_to, metadata_jsonb, created_at,
               ref_source, ref_entity, ref_key
          FROM maludb_core.malu$svpor_attribute
         WHERE owner_schema = %L
        WITH LOCAL CHECK OPTION
    $sql$, p_schema, p_schema);

    -- ---- replace maludb_svpor_attribute_create with ref-aware 17-arg
    EXECUTE format('DROP FUNCTION IF EXISTS %I.maludb_svpor_attribute_create(text, bigint, text, timestamptz, tstzrange, numeric, text, jsonb, text, text, numeric, timestamptz, timestamptz, jsonb)', p_schema);
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_svpor_attribute_create(
            p_target_kind text, p_target_id bigint, p_attr_name text,
            p_value_timestamp timestamptz DEFAULT NULL, p_value_range tstzrange DEFAULT NULL,
            p_value_numeric numeric DEFAULT NULL, p_value_text text DEFAULT NULL,
            p_value_jsonb jsonb DEFAULT NULL, p_unit text DEFAULT NULL,
            p_provenance text DEFAULT 'provided', p_confidence numeric DEFAULT NULL,
            p_valid_from timestamptz DEFAULT NULL, p_valid_to timestamptz DEFAULT NULL,
            p_metadata_jsonb jsonb DEFAULT '{}'::jsonb,
            p_ref_source text DEFAULT NULL, p_ref_entity text DEFAULT NULL, p_ref_key text DEFAULT NULL
        ) RETURNS bigint LANGUAGE sql SECURITY INVOKER
        SET search_path = %I, maludb_core, pg_temp
        AS $facade$ SELECT maludb_core.register_svpor_attribute(
            p_target_kind, p_target_id, p_attr_name, p_value_timestamp, p_value_range,
            p_value_numeric, p_value_text, p_value_jsonb, p_unit, p_provenance,
            p_confidence, p_valid_from, p_valid_to, p_metadata_jsonb,
            p_ref_source, p_ref_entity, p_ref_key) $facade$
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_svpor_attribute_create(text, bigint, text, timestamptz, tstzrange, numeric, text, jsonb, text, text, numeric, timestamptz, timestamptz, jsonb, text, text, text) FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_svpor_attribute_create(text, bigint, text, timestamptz, tstzrange, numeric, text, jsonb, text, text, numeric, timestamptz, timestamptz, jsonb, text, text, text) TO maludb_memory_admin, maludb_memory_executor', p_schema);

    -- ---- maludb_attributes_apply (bulk upsert) ---------------------
    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_attributes_apply', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_attributes_apply(p_target_kind text, p_target_id bigint, p_attributes jsonb)
        RETURNS integer LANGUAGE sql SECURITY INVOKER
        SET search_path = %I, maludb_core, pg_temp
        AS $facade$ SELECT maludb_core.attributes_apply(p_target_kind, p_target_id, p_attributes) $facade$
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_attributes_apply(text, bigint, jsonb) FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_attributes_apply(text, bigint, jsonb) TO maludb_memory_admin, maludb_memory_executor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_attributes_apply', 'function', 'Schema-local bulk attribute upsert.');
    v_count := v_count + 1;

    -- ---- maludb_attributes (bundler) + maludb_object_get -----------
    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_attributes', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_attributes(p_target_kind text, p_target_id bigint)
        RETURNS jsonb LANGUAGE sql STABLE SECURITY INVOKER
        SET search_path = %I, maludb_core, pg_temp
        AS $facade$ SELECT maludb_core.attributes_jsonb(p_target_kind, p_target_id) $facade$
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_attributes(text, bigint) FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_attributes(text, bigint) TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_attributes', 'function', 'Schema-local attribute bundler.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_object_get', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_object_get(p_target_kind text, p_target_id bigint)
        RETURNS jsonb LANGUAGE sql STABLE SECURITY INVOKER
        SET search_path = %I, maludb_core, pg_temp
        AS $facade$ SELECT maludb_core.object_get(p_target_kind, p_target_id) $facade$
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_object_get(text, bigint) FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_object_get(text, bigint) TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_object_get', 'function', 'Schema-local object + attributes reader.');
    v_count := v_count + 1;

    -- ---- opt-in *_with_attributes views ----------------------------
    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_episode_with_attributes', 'view');
    EXECUTE format($sql$
        CREATE OR REPLACE VIEW %I.maludb_episode_with_attributes WITH (security_invoker = true) AS
        SELECT b.*, maludb_core.attributes_jsonb('episode_object', b.episode_id) AS attributes
          FROM %I.maludb_episode b
    $sql$, p_schema, p_schema);
    EXECUTE format('GRANT SELECT ON %I.maludb_episode_with_attributes TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_episode_with_attributes', 'view', 'Episodes with attributes bundled.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_subject_with_attributes', 'view');
    EXECUTE format($sql$
        CREATE OR REPLACE VIEW %I.maludb_subject_with_attributes WITH (security_invoker = true) AS
        SELECT b.*, maludb_core.attributes_jsonb('subject', b.subject_id) AS attributes
          FROM %I.maludb_subject b
    $sql$, p_schema, p_schema);
    EXECUTE format('GRANT SELECT ON %I.maludb_subject_with_attributes TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_subject_with_attributes', 'view', 'Subjects with attributes bundled.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_document_with_attributes', 'view');
    EXECUTE format($sql$
        CREATE OR REPLACE VIEW %I.maludb_document_with_attributes WITH (security_invoker = true) AS
        SELECT b.*, maludb_core.attributes_jsonb('document', b.document_id) AS attributes
          FROM %I.maludb_document b
    $sql$, p_schema, p_schema);
    EXECUTE format('GRANT SELECT ON %I.maludb_document_with_attributes TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_document_with_attributes', 'view', 'Documents with attributes bundled.');
    v_count := v_count + 1;

    RETURN v_count;
END;
$body$;

REVOKE ALL ON FUNCTION maludb_core._enable_memory_schema_0840_facade(name) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core._enable_memory_schema_0840_facade(name)
    TO maludb_memory_admin, maludb_memory_executor;

-- ===== 8. wire the 0840 facade into enable_memory_schema ============
CREATE OR REPLACE FUNCTION maludb_core.enable_memory_schema(p_schema name DEFAULT current_schema())
RETURNS TABLE(schema_name name, enabled_version text, object_count integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
DECLARE
    v_enabled_version text := maludb_core.maludb_core_version();
    v_count integer := 0;
    v_view  name;
BEGIN
    IF p_schema IS NULL THEN
        p_schema := current_schema();
    END IF;

    PERFORM maludb_core._memory_schema_assert_manageable(p_schema);

    FOREACH v_view IN ARRAY ARRAY['maludb_subject','maludb_memory','maludb_skill','maludb_document']::name[]
    LOOP
        IF EXISTS (
            SELECT 1 FROM maludb_core.malu$enabled_schema_object o
             WHERE o.schema_name = p_schema
               AND o.object_name = v_view
               AND o.object_kind = 'view'
        ) THEN
            EXECUTE format('DROP VIEW IF EXISTS %I.%I CASCADE', p_schema, v_view);
        END IF;
    END LOOP;

    INSERT INTO maludb_core.malu$enabled_schema(schema_name, enabled_version, enabled_by)
    VALUES (p_schema, v_enabled_version, session_user)
    ON CONFLICT ON CONSTRAINT malu$enabled_schema_pkey DO UPDATE
       SET enabled_version   = EXCLUDED.enabled_version,
           last_refreshed_at = now();

    v_count := v_count + maludb_core._enable_memory_schema_subject_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_core_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_ingest_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_pool_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_ai_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_075_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_076_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_078_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_080_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_0802_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_0803_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_0810_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_0820_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_0830_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_0840_facade(p_schema);
    PERFORM maludb_core._grant_memory_schema_reader_access(p_schema);

    schema_name := p_schema;
    enabled_version := v_enabled_version;
    object_count := v_count;
    RETURN NEXT;
END;
$body$;

REVOKE ALL ON FUNCTION maludb_core.enable_memory_schema(name) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core.enable_memory_schema(name)
    TO maludb_memory_admin, maludb_memory_executor, maludb_user, maludb_admin;
