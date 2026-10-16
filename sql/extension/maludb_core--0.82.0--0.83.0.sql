\echo Use "ALTER EXTENSION maludb_core UPDATE TO '0.83.0'" to load this file. \quit

-- =====================================================================
-- maludb_core 0.82.0 -> 0.83.0
--
-- Typed, optional attributes on nodes AND edges, plus an advisory
-- per-type "template" catalog so application developers (and agents) can
-- build entry forms. Motivated by project-management style data: a Task
-- spanning months, Sprints spanning weeks, Meetings, and steps -- each
-- carrying planned/actual date ranges, % complete, story points,
-- priority, etc. -- without adding a column per property.
--
-- Modeling decision (see design notes): a date like "Planned Start Date"
-- is NEITHER a subject NOR a verb -- subjects are entities, verbs are
-- relationships, dates are scalar PROPERTIES. So properties are typed
-- attributes attached to any node or edge (a property graph), not new
-- SVPOR vocabulary and not new columns.
--
-- Two layers:
--
--   1. malu$svpor_attribute -- the value store. Polymorphic over nodes
--      AND edges (target_kind includes 'svpor_statement'). Typed value
--      columns (timestamp / tstzrange / numeric / text / jsonb) so dates
--      stay queryable, plus provenance + confidence so an LLM extractor
--      can stage 'suggested' values for review. One value per
--      (target, attr_name) -- the writer upserts.
--
--   2. malu$attribute_template -- an advisory catalog keyed by
--      (applies_to, type_value): for episode_type='Sprint', list the
--      attributes (planned_start_date REQUIRED, planned_end_date
--      REQUIRED, estimated_story_points OPTIONAL, ...). applies_to also
--      covers 'verb' so edge attributes (e.g. 'attended' -> role) get
--      templated the same way. This drives form generation.
--
-- 'required' is ADVISORY -- the DB never rejects an incomplete node
-- (consistent with every other picker). attribute_check(kind, id)
-- resolves the target's type, compares stored attributes against its
-- template, and returns the missing required ones, so the API/agent can
-- validate on submit without re-implementing the rules.
--
-- Existing schemas pick up the new objects by re-running
-- maludb_core.enable_memory_schema().
-- =====================================================================

CREATE OR REPLACE FUNCTION maludb_core.maludb_core_version() RETURNS text
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$ SELECT '0.83.0'::text $body$;

-- ===== 1. malu$svpor_attribute: typed values on nodes + edges =======
CREATE TABLE IF NOT EXISTS maludb_core.malu$svpor_attribute (
    attribute_id    bigserial PRIMARY KEY,
    owner_schema    name NOT NULL DEFAULT current_schema(),
    target_kind     text NOT NULL,
    target_id       bigint NOT NULL,
    attr_name       text NOT NULL,
    value_timestamp timestamptz,
    value_range     tstzrange,
    value_numeric   numeric,
    value_text      text,
    value_jsonb     jsonb,
    unit            text,
    provenance      text NOT NULL DEFAULT 'provided'
        CHECK (provenance IN ('provided','suggested','accepted','rejected')),
    confidence      numeric(5,4) CHECK (confidence IS NULL OR confidence BETWEEN 0 AND 1),
    valid_from      timestamptz,
    valid_to        timestamptz,
    metadata_jsonb  jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at      timestamptz NOT NULL DEFAULT now(),
    -- nodes and edges both carry attributes; 'svpor_statement' is an edge.
    CHECK (target_kind IN
        ('subject','verb','document','episode_object','memory',
         'source_package','claim','fact','memory_detail_object','svpor_statement'))
);
-- One value per (target, attr_name): setting planned_end_date again
-- updates rather than duplicates. Multi-valued attributes use value_jsonb.
CREATE UNIQUE INDEX IF NOT EXISTS malu$svpor_attribute_identity_idx
    ON maludb_core.malu$svpor_attribute(owner_schema, target_kind, target_id, attr_name);
CREATE INDEX IF NOT EXISTS malu$svpor_attribute_target_idx
    ON maludb_core.malu$svpor_attribute(owner_schema, target_kind, target_id);
CREATE INDEX IF NOT EXISTS malu$svpor_attribute_name_idx
    ON maludb_core.malu$svpor_attribute(owner_schema, attr_name);
CREATE INDEX IF NOT EXISTS malu$svpor_attribute_range_idx
    ON maludb_core.malu$svpor_attribute USING gist (value_range)
    WHERE value_range IS NOT NULL;

ALTER TABLE maludb_core.malu$svpor_attribute ENABLE ROW LEVEL SECURITY;
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_catalog.pg_policy p
          JOIN pg_catalog.pg_class c ON c.oid = p.polrelid
          JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
         WHERE n.nspname = 'maludb_core' AND c.relname = 'malu$svpor_attribute'
           AND p.polname = 'tenant_owner'
    ) THEN
        EXECUTE 'CREATE POLICY tenant_owner ON maludb_core.malu$svpor_attribute
                 USING (owner_schema = current_schema())
                 WITH CHECK (owner_schema = current_schema())';
    END IF;
END$$;

GRANT SELECT, INSERT, UPDATE, DELETE ON maludb_core.malu$svpor_attribute
    TO maludb_memory_admin, maludb_memory_executor;
GRANT SELECT ON maludb_core.malu$svpor_attribute TO maludb_memory_auditor;
GRANT USAGE, SELECT ON SEQUENCE maludb_core.malu$svpor_attribute_attribute_id_seq
    TO maludb_memory_admin, maludb_memory_executor;

-- ===== 2. malu$attribute_template: advisory per-type catalog =========
CREATE TABLE IF NOT EXISTS maludb_core.malu$attribute_template (
    template_id     bigserial PRIMARY KEY,
    owner_schema    name NOT NULL DEFAULT current_schema(),
    applies_to      text NOT NULL
        CHECK (applies_to IN ('episode_type','document_type','subject_type','verb')),
    type_value      text NOT NULL,
    attr_name       text NOT NULL,
    value_type      text NOT NULL
        CHECK (value_type IN ('timestamp','tstzrange','numeric','text','jsonb')),
    requirement     text NOT NULL DEFAULT 'optional'
        CHECK (requirement IN ('required','recommended','optional')),
    label           text,
    description     text,
    unit            text,
    allowed_values  jsonb,
    default_value   jsonb,
    display_order   integer,
    created_at      timestamptz NOT NULL DEFAULT now(),
    UNIQUE (owner_schema, applies_to, type_value, attr_name)
);
CREATE INDEX IF NOT EXISTS malu$attribute_template_lookup_idx
    ON maludb_core.malu$attribute_template(owner_schema, applies_to, type_value, display_order);

ALTER TABLE maludb_core.malu$attribute_template ENABLE ROW LEVEL SECURITY;
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_catalog.pg_policy p
          JOIN pg_catalog.pg_class c ON c.oid = p.polrelid
          JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
         WHERE n.nspname = 'maludb_core' AND c.relname = 'malu$attribute_template'
           AND p.polname = 'tenant_owner'
    ) THEN
        EXECUTE 'CREATE POLICY tenant_owner ON maludb_core.malu$attribute_template
                 USING (owner_schema = current_schema())
                 WITH CHECK (owner_schema = current_schema())';
    END IF;
END$$;

GRANT SELECT, INSERT, UPDATE, DELETE ON maludb_core.malu$attribute_template
    TO maludb_memory_admin, maludb_memory_executor;
GRANT SELECT ON maludb_core.malu$attribute_template TO maludb_memory_auditor;
GRANT USAGE, SELECT ON SEQUENCE maludb_core.malu$attribute_template_template_id_seq
    TO maludb_memory_admin, maludb_memory_executor;

-- ===== 3. core helpers + writers ====================================

-- Per-kind existence check for an attribute target (nodes AND edges).
-- No SET search_path: SECURITY INVOKER, current_schema() must resolve to
-- the tenant (explicit owner_schema predicate + RLS); all refs are
-- maludb_core-qualified. Raises foreign_key_violation when absent.
CREATE FUNCTION maludb_core._svpor_attribute_assert_target(
    p_schema name, p_kind text, p_id bigint
) RETURNS void
LANGUAGE plpgsql
SECURITY INVOKER
AS $body$
DECLARE v_ok boolean := false;
BEGIN
    CASE p_kind
        WHEN 'subject' THEN
            SELECT EXISTS(SELECT 1 FROM maludb_core.malu$svpor_subject
                          WHERE owner_schema = p_schema AND subject_id = p_id) INTO v_ok;
        WHEN 'verb' THEN
            SELECT EXISTS(SELECT 1 FROM maludb_core.malu$svpor_verb
                          WHERE owner_schema = p_schema AND verb_id = p_id) INTO v_ok;
        WHEN 'document' THEN
            SELECT EXISTS(SELECT 1 FROM maludb_core.malu$document
                          WHERE owner_schema = p_schema AND document_id = p_id) INTO v_ok;
        WHEN 'episode_object' THEN
            SELECT EXISTS(SELECT 1 FROM maludb_core.malu$episode_object
                          WHERE owner_schema = p_schema AND episode_id = p_id) INTO v_ok;
        WHEN 'memory' THEN
            SELECT EXISTS(SELECT 1 FROM maludb_core.malu$memory
                          WHERE owner_schema = p_schema AND memory_id = p_id) INTO v_ok;
        WHEN 'source_package' THEN
            SELECT EXISTS(SELECT 1 FROM maludb_core.malu$source_package
                          WHERE owner_schema = p_schema AND source_package_id = p_id) INTO v_ok;
        WHEN 'claim' THEN
            SELECT EXISTS(SELECT 1 FROM maludb_core.malu$claim
                          WHERE owner_schema = p_schema AND claim_id = p_id) INTO v_ok;
        WHEN 'fact' THEN
            SELECT EXISTS(SELECT 1 FROM maludb_core.malu$fact
                          WHERE owner_schema = p_schema AND fact_id = p_id) INTO v_ok;
        WHEN 'memory_detail_object' THEN
            SELECT EXISTS(SELECT 1 FROM maludb_core.malu$memory_detail_object
                          WHERE owner_schema = p_schema AND mdo_id = p_id) INTO v_ok;
        WHEN 'svpor_statement' THEN
            SELECT EXISTS(SELECT 1 FROM maludb_core.malu$svpor_statement
                          WHERE owner_schema = p_schema AND statement_id = p_id) INTO v_ok;
        ELSE
            RAISE EXCEPTION 'svpor_attribute: unsupported target kind %', p_kind
                USING ERRCODE = 'invalid_parameter_value';
    END CASE;

    IF NOT v_ok THEN
        RAISE EXCEPTION 'svpor_attribute target % % not found in schema %', p_kind, p_id, p_schema
            USING ERRCODE = 'foreign_key_violation';
    END IF;
END;
$body$;
REVOKE ALL ON FUNCTION maludb_core._svpor_attribute_assert_target(name, text, bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core._svpor_attribute_assert_target(name, text, bigint)
    TO maludb_memory_admin, maludb_memory_executor;

-- register_svpor_attribute -- upsert one attribute value on a target.
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
    p_metadata_jsonb  jsonb       DEFAULT '{}'::jsonb
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
         valid_from, valid_to, metadata_jsonb)
    VALUES
        (v_schema, v_kind, p_target_id, v_attr, p_value_timestamp, p_value_range,
         p_value_numeric, p_value_text, p_value_jsonb, p_unit, v_provenance, p_confidence,
         p_valid_from, p_valid_to, COALESCE(p_metadata_jsonb, '{}'::jsonb))
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
        metadata_jsonb  = malu$svpor_attribute.metadata_jsonb || EXCLUDED.metadata_jsonb
    RETURNING attribute_id INTO v_id;

    RETURN v_id;
END;
$body$;
REVOKE ALL ON FUNCTION maludb_core.register_svpor_attribute(
    text, bigint, text, timestamptz, tstzrange, numeric, text, jsonb, text, text, numeric, timestamptz, timestamptz, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core.register_svpor_attribute(
    text, bigint, text, timestamptz, tstzrange, numeric, text, jsonb, text, text, numeric, timestamptz, timestamptz, jsonb)
    TO maludb_memory_admin, maludb_memory_executor;

CREATE FUNCTION maludb_core.svpor_attribute_delete(p_attribute_id bigint) RETURNS integer
LANGUAGE plpgsql SECURITY INVOKER
AS $body$
DECLARE v_count integer;
BEGIN
    IF p_attribute_id IS NULL THEN
        RAISE EXCEPTION 'attribute_id is required' USING ERRCODE = 'invalid_parameter_value';
    END IF;
    DELETE FROM maludb_core.malu$svpor_attribute
     WHERE owner_schema = current_schema() AND attribute_id = p_attribute_id;
    GET DIAGNOSTICS v_count = ROW_COUNT;
    RETURN v_count;
END;
$body$;
REVOKE ALL ON FUNCTION maludb_core.svpor_attribute_delete(bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core.svpor_attribute_delete(bigint)
    TO maludb_memory_admin, maludb_memory_executor;

CREATE FUNCTION maludb_core.svpor_attribute_set_provenance(
    p_attribute_id bigint, p_provenance text
) RETURNS boolean
LANGUAGE plpgsql SECURITY INVOKER
AS $body$
BEGIN
    IF p_attribute_id IS NULL
       OR p_provenance NOT IN ('provided','suggested','accepted','rejected') THEN
        RAISE EXCEPTION 'attribute_id and a valid provenance are required'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;
    UPDATE maludb_core.malu$svpor_attribute
       SET provenance = p_provenance
     WHERE owner_schema = current_schema()
       AND attribute_id = p_attribute_id
       AND provenance IS DISTINCT FROM p_provenance;
    RETURN FOUND;
END;
$body$;
REVOKE ALL ON FUNCTION maludb_core.svpor_attribute_set_provenance(bigint, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core.svpor_attribute_set_provenance(bigint, text)
    TO maludb_memory_admin, maludb_memory_executor;

-- register_attribute_template -- upsert one template row.
CREATE FUNCTION maludb_core.register_attribute_template(
    p_applies_to     text,
    p_type_value     text,
    p_attr_name      text,
    p_value_type     text,
    p_requirement    text   DEFAULT 'optional',
    p_label          text   DEFAULT NULL,
    p_description    text   DEFAULT NULL,
    p_unit           text   DEFAULT NULL,
    p_allowed_values jsonb  DEFAULT NULL,
    p_default_value  jsonb  DEFAULT NULL,
    p_display_order  integer DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql
SECURITY INVOKER
AS $body$
DECLARE v_id bigint;
BEGIN
    IF p_applies_to IS NULL OR p_type_value IS NULL OR btrim(COALESCE(p_attr_name,'')) = '' THEN
        RAISE EXCEPTION 'register_attribute_template: applies_to, type_value and attr_name are required'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;
    INSERT INTO maludb_core.malu$attribute_template
        (applies_to, type_value, attr_name, value_type, requirement, label,
         description, unit, allowed_values, default_value, display_order)
    VALUES
        (p_applies_to, p_type_value, btrim(p_attr_name), p_value_type,
         COALESCE(p_requirement,'optional'), p_label, p_description, p_unit,
         p_allowed_values, p_default_value, p_display_order)
    ON CONFLICT (owner_schema, applies_to, type_value, attr_name)
    DO UPDATE SET
        value_type     = EXCLUDED.value_type,
        requirement    = EXCLUDED.requirement,
        label          = COALESCE(EXCLUDED.label,          malu$attribute_template.label),
        description    = COALESCE(EXCLUDED.description,     malu$attribute_template.description),
        unit           = COALESCE(EXCLUDED.unit,           malu$attribute_template.unit),
        allowed_values = COALESCE(EXCLUDED.allowed_values, malu$attribute_template.allowed_values),
        default_value  = COALESCE(EXCLUDED.default_value,  malu$attribute_template.default_value),
        display_order  = COALESCE(EXCLUDED.display_order,  malu$attribute_template.display_order)
    RETURNING template_id INTO v_id;
    RETURN v_id;
END;
$body$;
REVOKE ALL ON FUNCTION maludb_core.register_attribute_template(
    text, text, text, text, text, text, text, text, jsonb, jsonb, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core.register_attribute_template(
    text, text, text, text, text, text, text, text, jsonb, jsonb, integer)
    TO maludb_memory_admin, maludb_memory_executor;

CREATE FUNCTION maludb_core.attribute_template_delete(p_template_id bigint) RETURNS integer
LANGUAGE plpgsql SECURITY INVOKER
AS $body$
DECLARE v_count integer;
BEGIN
    IF p_template_id IS NULL THEN
        RAISE EXCEPTION 'template_id is required' USING ERRCODE = 'invalid_parameter_value';
    END IF;
    DELETE FROM maludb_core.malu$attribute_template
     WHERE owner_schema = current_schema() AND template_id = p_template_id;
    GET DIAGNOSTICS v_count = ROW_COUNT;
    RETURN v_count;
END;
$body$;
REVOKE ALL ON FUNCTION maludb_core.attribute_template_delete(bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core.attribute_template_delete(bigint)
    TO maludb_memory_admin, maludb_memory_executor;

-- attribute_check -- resolve a target's type, compare its stored
-- attributes against the matching template, and report completeness.
-- Advisory: nothing is rejected; this just tells the caller what is
-- missing/expected so the API or an agent can decide.
CREATE FUNCTION maludb_core.attribute_check(p_target_kind text, p_target_id bigint)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY INVOKER
AS $body$
DECLARE
    v_schema     name := current_schema();
    v_kind       text := lower(btrim(COALESCE(p_target_kind, '')));
    v_applies_to text;
    v_type_value text;
    v_result     jsonb;
BEGIN
    -- Map the target to its (applies_to, type_value).
    CASE v_kind
        WHEN 'episode_object' THEN
            v_applies_to := 'episode_type';
            SELECT episode_kind INTO v_type_value FROM maludb_core.malu$episode_object
             WHERE owner_schema = v_schema AND episode_id = p_target_id;
        WHEN 'document' THEN
            v_applies_to := 'document_type';
            SELECT document_type INTO v_type_value FROM maludb_core.malu$document
             WHERE owner_schema = v_schema AND document_id = p_target_id;
        WHEN 'subject' THEN
            v_applies_to := 'subject_type';
            SELECT subject_type INTO v_type_value FROM maludb_core.malu$svpor_subject
             WHERE owner_schema = v_schema AND subject_id = p_target_id;
        WHEN 'svpor_statement' THEN
            v_applies_to := 'verb';
            SELECT v.canonical_name INTO v_type_value
              FROM maludb_core.malu$svpor_statement s
              JOIN maludb_core.malu$svpor_verb v
                ON v.owner_schema = s.owner_schema AND v.verb_id = s.verb_id
             WHERE s.owner_schema = v_schema AND s.statement_id = p_target_id;
        ELSE
            v_applies_to := NULL;
            v_type_value := NULL;
    END CASE;

    SELECT jsonb_build_object(
        'target_kind', v_kind,
        'target_id',   p_target_id,
        'applies_to',  v_applies_to,
        'type_value',  v_type_value,
        'missing_required', COALESCE((
            SELECT jsonb_agg(t.attr_name ORDER BY t.display_order NULLS LAST, t.attr_name)
              FROM maludb_core.malu$attribute_template t
             WHERE t.owner_schema = v_schema
               AND t.applies_to = v_applies_to
               AND t.type_value = v_type_value
               AND t.requirement = 'required'
               AND NOT EXISTS (
                   SELECT 1 FROM maludb_core.malu$svpor_attribute a
                    WHERE a.owner_schema = v_schema
                      AND a.target_kind = v_kind
                      AND a.target_id = p_target_id
                      AND a.attr_name = t.attr_name)
        ), '[]'::jsonb),
        'fields', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                       'attr_name',   t.attr_name,
                       'value_type',  t.value_type,
                       'requirement', t.requirement,
                       'label',       t.label,
                       'present', EXISTS (
                           SELECT 1 FROM maludb_core.malu$svpor_attribute a
                            WHERE a.owner_schema = v_schema
                              AND a.target_kind = v_kind
                              AND a.target_id = p_target_id
                              AND a.attr_name = t.attr_name))
                     ORDER BY t.display_order NULLS LAST, t.attr_name)
              FROM maludb_core.malu$attribute_template t
             WHERE t.owner_schema = v_schema
               AND t.applies_to = v_applies_to
               AND t.type_value = v_type_value
        ), '[]'::jsonb)
    ) INTO v_result;

    RETURN v_result;
END;
$body$;
REVOKE ALL ON FUNCTION maludb_core.attribute_check(text, bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core.attribute_check(text, bigint)
    TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;

-- ===== 4. 0.83.0 schema-local facade builder ========================
CREATE FUNCTION maludb_core._enable_memory_schema_0830_facade(p_schema name) RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
DECLARE
    v_count integer := 0;
BEGIN
    PERFORM maludb_core._memory_schema_assert_manageable(p_schema);

    -- ---- maludb_svpor_attribute: writable view ---------------------
    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_svpor_attribute', 'view');
    EXECUTE format($sql$
        CREATE OR REPLACE VIEW %I.maludb_svpor_attribute WITH (security_invoker = true) AS
        SELECT attribute_id, target_kind, target_id, attr_name,
               value_timestamp, value_range, value_numeric, value_text, value_jsonb,
               unit, provenance, confidence, valid_from, valid_to, metadata_jsonb, created_at
          FROM maludb_core.malu$svpor_attribute
         WHERE owner_schema = %L
        WITH LOCAL CHECK OPTION
    $sql$, p_schema, p_schema);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON %I.maludb_svpor_attribute TO maludb_memory_admin, maludb_memory_executor', p_schema);
    EXECUTE format('GRANT SELECT ON %I.maludb_svpor_attribute TO maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_svpor_attribute', 'view', 'Schema-local attribute value facade.');
    v_count := v_count + 1;

    -- ---- maludb_attribute_template: writable view ------------------
    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_attribute_template', 'view');
    EXECUTE format($sql$
        CREATE OR REPLACE VIEW %I.maludb_attribute_template WITH (security_invoker = true) AS
        SELECT template_id, applies_to, type_value, attr_name, value_type, requirement,
               label, description, unit, allowed_values, default_value, display_order, created_at
          FROM maludb_core.malu$attribute_template
         WHERE owner_schema = %L
        WITH LOCAL CHECK OPTION
    $sql$, p_schema, p_schema);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON %I.maludb_attribute_template TO maludb_memory_admin, maludb_memory_executor', p_schema);
    EXECUTE format('GRANT SELECT ON %I.maludb_attribute_template TO maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_attribute_template', 'view', 'Schema-local attribute template catalog facade.');
    v_count := v_count + 1;

    -- ---- create / delete / set_provenance / check facades ----------
    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_svpor_attribute_create', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_svpor_attribute_create(
            p_target_kind text, p_target_id bigint, p_attr_name text,
            p_value_timestamp timestamptz DEFAULT NULL, p_value_range tstzrange DEFAULT NULL,
            p_value_numeric numeric DEFAULT NULL, p_value_text text DEFAULT NULL,
            p_value_jsonb jsonb DEFAULT NULL, p_unit text DEFAULT NULL,
            p_provenance text DEFAULT 'provided', p_confidence numeric DEFAULT NULL,
            p_valid_from timestamptz DEFAULT NULL, p_valid_to timestamptz DEFAULT NULL,
            p_metadata_jsonb jsonb DEFAULT '{}'::jsonb
        ) RETURNS bigint LANGUAGE sql SECURITY INVOKER
        SET search_path = %I, maludb_core, pg_temp
        AS $facade$ SELECT maludb_core.register_svpor_attribute(
            p_target_kind, p_target_id, p_attr_name, p_value_timestamp, p_value_range,
            p_value_numeric, p_value_text, p_value_jsonb, p_unit, p_provenance,
            p_confidence, p_valid_from, p_valid_to, p_metadata_jsonb) $facade$
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_svpor_attribute_create(text, bigint, text, timestamptz, tstzrange, numeric, text, jsonb, text, text, numeric, timestamptz, timestamptz, jsonb) FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_svpor_attribute_create(text, bigint, text, timestamptz, tstzrange, numeric, text, jsonb, text, text, numeric, timestamptz, timestamptz, jsonb) TO maludb_memory_admin, maludb_memory_executor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_svpor_attribute_create', 'function', 'Schema-local attribute upsert.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_svpor_attribute_delete', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_svpor_attribute_delete(p_attribute_id bigint)
        RETURNS integer LANGUAGE sql SECURITY INVOKER
        SET search_path = %I, maludb_core, pg_temp
        AS $facade$ SELECT maludb_core.svpor_attribute_delete(p_attribute_id) $facade$
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_svpor_attribute_delete(bigint) FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_svpor_attribute_delete(bigint) TO maludb_memory_admin, maludb_memory_executor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_svpor_attribute_delete', 'function', 'Schema-local attribute delete.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_svpor_attribute_set_provenance', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_svpor_attribute_set_provenance(p_attribute_id bigint, p_provenance text)
        RETURNS boolean LANGUAGE sql SECURITY INVOKER
        SET search_path = %I, maludb_core, pg_temp
        AS $facade$ SELECT maludb_core.svpor_attribute_set_provenance(p_attribute_id, p_provenance) $facade$
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_svpor_attribute_set_provenance(bigint, text) FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_svpor_attribute_set_provenance(bigint, text) TO maludb_memory_admin, maludb_memory_executor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_svpor_attribute_set_provenance', 'function', 'Schema-local attribute provenance edit.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_attribute_template_create', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_attribute_template_create(
            p_applies_to text, p_type_value text, p_attr_name text, p_value_type text,
            p_requirement text DEFAULT 'optional', p_label text DEFAULT NULL,
            p_description text DEFAULT NULL, p_unit text DEFAULT NULL,
            p_allowed_values jsonb DEFAULT NULL, p_default_value jsonb DEFAULT NULL,
            p_display_order integer DEFAULT NULL
        ) RETURNS bigint LANGUAGE sql SECURITY INVOKER
        SET search_path = %I, maludb_core, pg_temp
        AS $facade$ SELECT maludb_core.register_attribute_template(
            p_applies_to, p_type_value, p_attr_name, p_value_type, p_requirement, p_label,
            p_description, p_unit, p_allowed_values, p_default_value, p_display_order) $facade$
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_attribute_template_create(text, text, text, text, text, text, text, text, jsonb, jsonb, integer) FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_attribute_template_create(text, text, text, text, text, text, text, text, jsonb, jsonb, integer) TO maludb_memory_admin, maludb_memory_executor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_attribute_template_create', 'function', 'Schema-local attribute template upsert.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_attribute_template_delete', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_attribute_template_delete(p_template_id bigint)
        RETURNS integer LANGUAGE sql SECURITY INVOKER
        SET search_path = %I, maludb_core, pg_temp
        AS $facade$ SELECT maludb_core.attribute_template_delete(p_template_id) $facade$
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_attribute_template_delete(bigint) FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_attribute_template_delete(bigint) TO maludb_memory_admin, maludb_memory_executor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_attribute_template_delete', 'function', 'Schema-local attribute template delete.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_attribute_check', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_attribute_check(p_target_kind text, p_target_id bigint)
        RETURNS jsonb LANGUAGE sql STABLE SECURITY INVOKER
        SET search_path = %I, maludb_core, pg_temp
        AS $facade$ SELECT maludb_core.attribute_check(p_target_kind, p_target_id) $facade$
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_attribute_check(text, bigint) FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_attribute_check(text, bigint) TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_attribute_check', 'function', 'Schema-local attribute completeness check.');
    v_count := v_count + 1;

    -- ---- seed PM episode types (extend the 0820 picker) ------------
    EXECUTE format($sql$
        INSERT INTO maludb_core.malu$episode_type (owner_schema, episode_type, description, display_order)
        VALUES
            (%L,'Project','A project or program of work.', 5),
            (%L,'Task',   'A unit of work, may span weeks/months.', 8),
            (%L,'Sprint', 'A time-boxed iteration.', 15)
        ON CONFLICT DO NOTHING
    $sql$, p_schema, p_schema, p_schema);

    -- ---- seed starter attribute templates --------------------------
    EXECUTE format($sql$
        INSERT INTO maludb_core.malu$attribute_template
            (owner_schema, applies_to, type_value, attr_name, value_type, requirement, label, unit, display_order)
        VALUES
            (%L,'episode_type','Sprint','planned_start_date','timestamp','required','Planned Start Date',NULL,10),
            (%L,'episode_type','Sprint','planned_end_date','timestamp','required','Planned End Date',NULL,20),
            (%L,'episode_type','Sprint','estimated_story_points','numeric','optional','Estimated Story Points','points',30),
            (%L,'episode_type','Task','planned_start_date','timestamp','required','Planned Start Date',NULL,10),
            (%L,'episode_type','Task','planned_end_date','timestamp','required','Planned End Date',NULL,20),
            (%L,'episode_type','Task','percent_complete','numeric','optional','Percent Complete','percent',30),
            (%L,'episode_type','Task','priority','text','recommended','Priority',NULL,40),
            (%L,'episode_type','Meeting','duration_minutes','numeric','optional','Duration','minutes',10)
        ON CONFLICT DO NOTHING
    $sql$, p_schema, p_schema, p_schema, p_schema, p_schema, p_schema, p_schema, p_schema);

    RETURN v_count;
END;
$body$;

REVOKE ALL ON FUNCTION maludb_core._enable_memory_schema_0830_facade(name) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core._enable_memory_schema_0830_facade(name)
    TO maludb_memory_admin, maludb_memory_executor;

-- ===== 5. wire the 0830 facade into enable_memory_schema ============
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
