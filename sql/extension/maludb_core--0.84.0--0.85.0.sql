\echo Use "ALTER EXTENSION maludb_core UPDATE TO '0.85.0'" to load this file. \quit

-- =====================================================================
-- maludb_core 0.84.0 -> 0.85.0
--
-- Developer tooling: a scaffolder that generates (and optionally creates)
-- a join VIEW linking a MaluDB object to a record in an external
-- relational table, via the object's external-reference attribute
-- (0.84.0). E.g. join an svpor_subject to hr.persons on
-- ref_key = persons.employee_id, so a SELECT returns the MaluDB subject
-- alongside the live HR columns -- no field duplication.
--
--   maludb_reference_view_sql(...)  -> returns the CREATE VIEW DDL (review)
--   maludb_create_reference_view(...) -> executes it in the caller's schema
--
-- Both are SECURITY INVOKER and create in current_schema(), so the
-- generated view and its access to the external table use the caller's
-- own privileges (no privilege escalation). Identifiers are quoted. The
-- view is generated against the maludb_core base tables (with an
-- owner_schema = current_schema() predicate), NOT the maludb_* facade
-- views, so re-running enable_memory_schema (which drops/recreates those
-- facades) does not drop the developer's view.
--
-- Same-database only: a SQL view can join the external table only when it
-- lives in the same cluster (another schema, or a foreign table via FDW).
-- REST/other systems are resolved app-side.
--
-- Existing schemas pick up the facades by re-running
-- maludb_core.enable_memory_schema().
-- =====================================================================

CREATE OR REPLACE FUNCTION maludb_core.maludb_core_version() RETURNS text
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$ SELECT '0.85.0'::text $body$;

-- ===== reference_view_sql -- build the CREATE VIEW DDL ==============
CREATE FUNCTION maludb_core.reference_view_sql(
    p_view_name         text,
    p_target_kind       text,
    p_attr_name         text,
    p_external_table    text,
    p_external_key      text,
    p_external_key_cast text    DEFAULT 'text',
    p_join              text    DEFAULT 'left',
    p_accepted_only     boolean DEFAULT false,
    p_object_columns    text[]  DEFAULT NULL,
    p_external_columns  text[]  DEFAULT NULL
) RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
AS $body$
DECLARE
    v_schema     name := current_schema();
    v_kind       text := lower(btrim(COALESCE(p_target_kind, 'subject')));
    v_join       text := lower(btrim(COALESCE(p_join, 'left')));
    v_cast       text := lower(btrim(COALESCE(p_external_key_cast, 'text')));
    v_base       text;   -- maludb_core base table name
    v_id         text;   -- object id column
    v_defcols    text[]; -- default object columns
    v_ext_sch    text;
    v_ext_tbl    text;
    v_ext_ref    text;   -- quoted, qualified external table
    v_objcols    text[];
    v_sel        text := '';
    v_col        text;
    v_match      text;
    v_join_kw    text;
    v_attr_pred  text;
    v_sql        text;
BEGIN
    IF COALESCE(btrim(p_view_name), '') = '' OR COALESCE(btrim(p_attr_name), '') = ''
       OR COALESCE(btrim(p_external_table), '') = '' OR COALESCE(btrim(p_external_key), '') = '' THEN
        RAISE EXCEPTION 'reference_view_sql: view_name, attr_name, external_table and external_key are required'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    -- target_kind -> base table, id column, default object columns
    CASE v_kind
        WHEN 'subject' THEN
            v_base := 'malu$svpor_subject';   v_id := 'subject_id';
            v_defcols := ARRAY['subject_id','canonical_name','subject_type'];
        WHEN 'verb' THEN
            v_base := 'malu$svpor_verb';       v_id := 'verb_id';
            v_defcols := ARRAY['verb_id','canonical_name'];
        WHEN 'episode_object' THEN
            v_base := 'malu$episode_object';   v_id := 'episode_id';
            v_defcols := ARRAY['episode_id','title','episode_kind','occurred_at','occurred_until'];
        WHEN 'document' THEN
            v_base := 'malu$document';         v_id := 'document_id';
            v_defcols := ARRAY['document_id','title','document_type'];
        WHEN 'memory' THEN
            v_base := 'malu$memory';           v_id := 'memory_id';
            v_defcols := ARRAY['memory_id','title'];
        WHEN 'source_package' THEN
            v_base := 'malu$source_package';   v_id := 'source_package_id';
            v_defcols := ARRAY['source_package_id','source_type'];
        WHEN 'memory_detail_object' THEN
            v_base := 'malu$memory_detail_object'; v_id := 'mdo_id';
            v_defcols := ARRAY['mdo_id','title'];
        WHEN 'svpor_statement' THEN
            v_base := 'malu$svpor_statement';  v_id := 'statement_id';
            v_defcols := ARRAY['statement_id','subject_kind','subject_id','verb_id','object_kind','object_id'];
        WHEN 'claim' THEN
            v_base := 'malu$claim';            v_id := 'claim_id';
            v_defcols := ARRAY['claim_id'];
        WHEN 'fact' THEN
            v_base := 'malu$fact';             v_id := 'fact_id';
            v_defcols := ARRAY['fact_id'];
        ELSE
            RAISE EXCEPTION 'reference_view_sql: unsupported target_kind %', v_kind
                USING ERRCODE = 'invalid_parameter_value';
    END CASE;

    IF v_join NOT IN ('left','inner') THEN
        RAISE EXCEPTION 'reference_view_sql: join must be left or inner' USING ERRCODE = 'invalid_parameter_value';
    END IF;
    IF v_cast NOT IN ('text','bigint','integer','int','uuid','numeric') THEN
        RAISE EXCEPTION 'reference_view_sql: external_key_cast must be one of text/bigint/integer/int/uuid/numeric'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    -- external table -> quoted, qualified reference
    IF position('.' in p_external_table) > 0 THEN
        v_ext_sch := split_part(p_external_table, '.', 1);
        v_ext_tbl := split_part(p_external_table, '.', 2);
        v_ext_ref := format('%I.%I', v_ext_sch, v_ext_tbl);
    ELSE
        v_ext_ref := format('%I', p_external_table);
    END IF;

    -- object columns (curated default or caller-supplied)
    v_objcols := COALESCE(p_object_columns, v_defcols);
    FOREACH v_col IN ARRAY v_objcols LOOP
        v_sel := v_sel || format('o.%I, ', v_col);
    END LOOP;

    -- link columns from the reference attribute
    v_sel := v_sel
        || 'a.attribute_id AS link_attr_id, '
        || 'a.provenance AS link_provenance, '
        || 'a.confidence AS link_confidence, '
        || 'a.ref_key AS ref_key, ';

    -- external columns (all, or caller-supplied)
    IF p_external_columns IS NULL THEN
        v_sel := v_sel || 'x.*';
    ELSE
        FOREACH v_col IN ARRAY p_external_columns LOOP
            v_sel := v_sel || format('x.%I, ', v_col);
        END LOOP;
        v_sel := rtrim(v_sel, ', ');
    END IF;

    -- join keyword + external match expression (ref_key is text)
    v_join_kw := CASE WHEN v_join = 'inner' THEN 'JOIN' ELSE 'LEFT JOIN' END;
    IF v_cast = 'text' THEN
        v_match := format('x.%I::text = a.ref_key', p_external_key);
    ELSE
        v_match := format('a.ref_key::%s = x.%I', v_cast, p_external_key);
    END IF;

    -- attribute join predicate
    v_attr_pred := format(
        'a.owner_schema = o.owner_schema AND a.target_kind = %L AND a.target_id = o.%I AND a.attr_name = %L',
        v_kind, v_id, btrim(p_attr_name));
    IF p_accepted_only THEN
        v_attr_pred := v_attr_pred || ' AND a.provenance = ''accepted''';
    END IF;

    v_sql := format(
        'CREATE VIEW %I.%I WITH (security_invoker = true) AS' || E'\n' ||
        'SELECT %s' || E'\n' ||
        '  FROM maludb_core.%I o' || E'\n' ||
        '  %s maludb_core.malu$svpor_attribute a ON %s' || E'\n' ||
        '  %s %s x ON %s' || E'\n' ||
        ' WHERE o.owner_schema = current_schema()',
        v_schema, btrim(p_view_name),
        v_sel,
        v_base,
        v_join_kw, v_attr_pred,
        v_join_kw, v_ext_ref, v_match);

    RETURN v_sql;
END;
$body$;
REVOKE ALL ON FUNCTION maludb_core.reference_view_sql(text, text, text, text, text, text, text, boolean, text[], text[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core.reference_view_sql(text, text, text, text, text, text, text, boolean, text[], text[])
    TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;

-- ===== create_reference_view -- build + execute ====================
CREATE FUNCTION maludb_core.create_reference_view(
    p_view_name         text,
    p_target_kind       text,
    p_attr_name         text,
    p_external_table    text,
    p_external_key      text,
    p_external_key_cast text    DEFAULT 'text',
    p_join              text    DEFAULT 'left',
    p_accepted_only     boolean DEFAULT false,
    p_object_columns    text[]  DEFAULT NULL,
    p_external_columns  text[]  DEFAULT NULL,
    p_replace           boolean DEFAULT false
) RETURNS text
LANGUAGE plpgsql
SECURITY INVOKER
AS $body$
DECLARE
    v_sql text;
BEGIN
    v_sql := maludb_core.reference_view_sql(
        p_view_name, p_target_kind, p_attr_name, p_external_table, p_external_key,
        p_external_key_cast, p_join, p_accepted_only, p_object_columns, p_external_columns);
    IF p_replace THEN
        -- turn "CREATE VIEW" into "CREATE OR REPLACE VIEW"
        v_sql := regexp_replace(v_sql, '^CREATE VIEW', 'CREATE OR REPLACE VIEW');
    END IF;
    EXECUTE v_sql;
    RETURN v_sql;
END;
$body$;
REVOKE ALL ON FUNCTION maludb_core.create_reference_view(text, text, text, text, text, text, text, boolean, text[], text[], boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core.create_reference_view(text, text, text, text, text, text, text, boolean, text[], text[], boolean)
    TO maludb_memory_admin, maludb_memory_executor;

-- ===== 0.85.0 schema-local facade builder ==========================
CREATE FUNCTION maludb_core._enable_memory_schema_0850_facade(p_schema name) RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
DECLARE
    v_count integer := 0;
BEGIN
    PERFORM maludb_core._memory_schema_assert_manageable(p_schema);

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_reference_view_sql', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_reference_view_sql(
            p_view_name text, p_target_kind text, p_attr_name text,
            p_external_table text, p_external_key text,
            p_external_key_cast text DEFAULT 'text', p_join text DEFAULT 'left',
            p_accepted_only boolean DEFAULT false,
            p_object_columns text[] DEFAULT NULL, p_external_columns text[] DEFAULT NULL
        ) RETURNS text LANGUAGE sql STABLE SECURITY INVOKER
        SET search_path = %I, maludb_core, pg_temp
        AS $facade$ SELECT maludb_core.reference_view_sql(
            p_view_name, p_target_kind, p_attr_name, p_external_table, p_external_key,
            p_external_key_cast, p_join, p_accepted_only, p_object_columns, p_external_columns) $facade$
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_reference_view_sql(text, text, text, text, text, text, text, boolean, text[], text[]) FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_reference_view_sql(text, text, text, text, text, text, text, boolean, text[], text[]) TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_reference_view_sql', 'function', 'Schema-local external-reference view scaffolder (returns DDL).');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_create_reference_view', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_create_reference_view(
            p_view_name text, p_target_kind text, p_attr_name text,
            p_external_table text, p_external_key text,
            p_external_key_cast text DEFAULT 'text', p_join text DEFAULT 'left',
            p_accepted_only boolean DEFAULT false,
            p_object_columns text[] DEFAULT NULL, p_external_columns text[] DEFAULT NULL,
            p_replace boolean DEFAULT false
        ) RETURNS text LANGUAGE plpgsql SECURITY INVOKER
        SET search_path = %I, maludb_core, pg_temp
        AS $facade$
        BEGIN
            RETURN maludb_core.create_reference_view(
                p_view_name, p_target_kind, p_attr_name, p_external_table, p_external_key,
                p_external_key_cast, p_join, p_accepted_only, p_object_columns, p_external_columns, p_replace);
        END;
        $facade$
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_create_reference_view(text, text, text, text, text, text, text, boolean, text[], text[], boolean) FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_create_reference_view(text, text, text, text, text, text, text, boolean, text[], text[], boolean) TO maludb_memory_admin, maludb_memory_executor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_create_reference_view', 'function', 'Schema-local external-reference view creator (executes DDL).');
    v_count := v_count + 1;

    RETURN v_count;
END;
$body$;

REVOKE ALL ON FUNCTION maludb_core._enable_memory_schema_0850_facade(name) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core._enable_memory_schema_0850_facade(name)
    TO maludb_memory_admin, maludb_memory_executor;

-- ===== wire the 0850 facade into enable_memory_schema ===============
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
    v_count := v_count + maludb_core._enable_memory_schema_0850_facade(p_schema);
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
