\echo Use "ALTER EXTENSION maludb_core UPDATE TO '0.76.0'" to load this file. \quit

-- =====================================================================
-- maludb_core 0.75.0 -> 0.76.0
--
-- Explicit symmetric related-subject support for V4 desktop sync.
-- =====================================================================

CREATE OR REPLACE FUNCTION maludb_core.maludb_core_version() RETURNS text
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$ SELECT '0.76.0'::text $body$;

CREATE TABLE maludb_core.malu$svpor_subject_relationship (
    owner_schema       name NOT NULL DEFAULT current_schema(),
    subject_a_id       bigint NOT NULL,
    subject_b_id       bigint NOT NULL,
    subject_a_label    text NOT NULL,
    subject_b_label    text NOT NULL,
    label              text,
    metadata_jsonb     jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at         timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (owner_schema, subject_a_id, subject_b_id),
    CONSTRAINT malu$svpor_subject_relationship_order_check
        CHECK (subject_a_id < subject_b_id),
    CONSTRAINT malu$svpor_subject_relationship_a_fk
        FOREIGN KEY (owner_schema, subject_a_id)
        REFERENCES maludb_core.malu$svpor_subject(owner_schema, subject_id)
        ON DELETE CASCADE,
    CONSTRAINT malu$svpor_subject_relationship_b_fk
        FOREIGN KEY (owner_schema, subject_b_id)
        REFERENCES maludb_core.malu$svpor_subject(owner_schema, subject_id)
        ON DELETE CASCADE
);

CREATE INDEX malu$svpor_subject_relationship_b_idx
    ON maludb_core.malu$svpor_subject_relationship(owner_schema, subject_b_id, subject_a_id);

ALTER TABLE maludb_core.malu$svpor_subject_relationship ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_owner ON maludb_core.malu$svpor_subject_relationship
    USING (owner_schema = current_schema())
    WITH CHECK (owner_schema = current_schema());

GRANT SELECT ON maludb_core.malu$svpor_subject_relationship TO
    maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;
GRANT INSERT, UPDATE, DELETE ON maludb_core.malu$svpor_subject_relationship TO
    maludb_memory_admin, maludb_memory_executor;

CREATE FUNCTION maludb_core._svpor_subject_relationship_set_labels_tg() RETURNS trigger
LANGUAGE plpgsql
AS $body$
DECLARE
    v_a_label text;
    v_b_label text;
BEGIN
    SELECT canonical_name INTO v_a_label
      FROM maludb_core.malu$svpor_subject
     WHERE owner_schema = NEW.owner_schema
       AND subject_id = NEW.subject_a_id;

    SELECT canonical_name INTO v_b_label
      FROM maludb_core.malu$svpor_subject
     WHERE owner_schema = NEW.owner_schema
       AND subject_id = NEW.subject_b_id;

    IF v_a_label IS NULL OR v_b_label IS NULL THEN
        RAISE EXCEPTION 'subject relationship references missing subject'
            USING ERRCODE = 'foreign_key_violation';
    END IF;

    NEW.subject_a_label := v_a_label;
    NEW.subject_b_label := v_b_label;
    NEW.metadata_jsonb := COALESCE(NEW.metadata_jsonb, '{}'::jsonb);
    RETURN NEW;
END;
$body$;

CREATE TRIGGER svpor_subject_relationship_set_labels_tg
    BEFORE INSERT OR UPDATE OF owner_schema, subject_a_id, subject_b_id
    ON maludb_core.malu$svpor_subject_relationship
    FOR EACH ROW
    EXECUTE FUNCTION maludb_core._svpor_subject_relationship_set_labels_tg();

CREATE FUNCTION maludb_core._svpor_subject_relationship_refresh_label_tg() RETURNS trigger
LANGUAGE plpgsql
AS $body$
BEGIN
    UPDATE maludb_core.malu$svpor_subject_relationship
       SET subject_a_label = NEW.canonical_name
     WHERE owner_schema = NEW.owner_schema
       AND subject_a_id = NEW.subject_id;

    UPDATE maludb_core.malu$svpor_subject_relationship
       SET subject_b_label = NEW.canonical_name
     WHERE owner_schema = NEW.owner_schema
       AND subject_b_id = NEW.subject_id;

    RETURN NEW;
END;
$body$;

CREATE TRIGGER svpor_subject_relationship_refresh_label_tg
    AFTER UPDATE OF canonical_name
    ON maludb_core.malu$svpor_subject
    FOR EACH ROW
    WHEN (OLD.canonical_name IS DISTINCT FROM NEW.canonical_name)
    EXECUTE FUNCTION maludb_core._svpor_subject_relationship_refresh_label_tg();

CREATE FUNCTION maludb_core.add_svpor_related_subject(
    p_subject_id bigint,
    p_related_subject_id bigint,
    p_label text DEFAULT NULL,
    p_metadata_jsonb jsonb DEFAULT '{}'::jsonb
) RETURNS TABLE (
    related_subject_id bigint,
    related_subject_name text,
    label text,
    metadata_jsonb jsonb,
    created_at timestamptz
) LANGUAGE plpgsql
SECURITY INVOKER
AS $body$
DECLARE
    v_schema name := current_schema();
    v_subject_a_id bigint;
    v_subject_b_id bigint;
    v_row maludb_core.malu$svpor_subject_relationship%ROWTYPE;
BEGIN
    IF p_subject_id IS NULL OR p_related_subject_id IS NULL THEN
        RAISE EXCEPTION 'subject ids are required'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    IF p_subject_id = p_related_subject_id THEN
        RAISE EXCEPTION 'related subjects cannot link a subject to itself'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    v_subject_a_id := LEAST(p_subject_id, p_related_subject_id);
    v_subject_b_id := GREATEST(p_subject_id, p_related_subject_id);

    INSERT INTO maludb_core.malu$svpor_subject_relationship(
        owner_schema,
        subject_a_id,
        subject_b_id,
        subject_a_label,
        subject_b_label,
        label,
        metadata_jsonb
    )
    VALUES (
        v_schema,
        v_subject_a_id,
        v_subject_b_id,
        '',
        '',
        p_label,
        COALESCE(p_metadata_jsonb, '{}'::jsonb)
    )
    ON CONFLICT (owner_schema, subject_a_id, subject_b_id) DO NOTHING;

    SELECT *
      INTO v_row
      FROM maludb_core.malu$svpor_subject_relationship r
     WHERE r.owner_schema = v_schema
       AND r.subject_a_id = v_subject_a_id
       AND r.subject_b_id = v_subject_b_id;

    IF p_subject_id = v_row.subject_a_id THEN
        related_subject_id := v_row.subject_b_id;
        related_subject_name := v_row.subject_b_label;
    ELSE
        related_subject_id := v_row.subject_a_id;
        related_subject_name := v_row.subject_a_label;
    END IF;
    label := v_row.label;
    metadata_jsonb := v_row.metadata_jsonb;
    created_at := v_row.created_at;
    RETURN NEXT;
END;
$body$;

REVOKE ALL ON FUNCTION maludb_core.add_svpor_related_subject(bigint, bigint, text, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core.add_svpor_related_subject(bigint, bigint, text, jsonb)
TO maludb_memory_admin, maludb_memory_executor;

CREATE FUNCTION maludb_core.list_svpor_related_subjects(
    p_subject_id bigint
) RETURNS TABLE (
    related_subject_id bigint,
    related_subject_name text,
    label text,
    metadata_jsonb jsonb,
    created_at timestamptz
) LANGUAGE plpgsql
STABLE
SECURITY INVOKER
AS $body$
DECLARE
    v_schema name := current_schema();
BEGIN
    IF NOT EXISTS (
        SELECT 1
          FROM maludb_core.malu$svpor_subject s
         WHERE s.owner_schema = v_schema
           AND s.subject_id = p_subject_id
    ) THEN
        RAISE EXCEPTION 'subject % does not exist in schema %', p_subject_id, v_schema
            USING ERRCODE = 'foreign_key_violation';
    END IF;

    RETURN QUERY
    SELECT CASE WHEN r.subject_a_id = p_subject_id THEN r.subject_b_id ELSE r.subject_a_id END AS related_subject_id,
           CASE WHEN r.subject_a_id = p_subject_id THEN r.subject_b_label ELSE r.subject_a_label END AS related_subject_name,
           r.label,
           r.metadata_jsonb,
           r.created_at
      FROM maludb_core.malu$svpor_subject_relationship r
     WHERE r.owner_schema = v_schema
       AND (r.subject_a_id = p_subject_id OR r.subject_b_id = p_subject_id)
     ORDER BY related_subject_id;
END;
$body$;

REVOKE ALL ON FUNCTION maludb_core.list_svpor_related_subjects(bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core.list_svpor_related_subjects(bigint)
TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;

CREATE FUNCTION maludb_core.delete_svpor_related_subject(
    p_subject_id bigint,
    p_related_subject_id bigint
) RETURNS boolean
LANGUAGE plpgsql
SECURITY INVOKER
AS $body$
DECLARE
    v_schema name := current_schema();
    v_subject_a_id bigint;
    v_subject_b_id bigint;
BEGIN
    IF p_subject_id IS NULL OR p_related_subject_id IS NULL THEN
        RAISE EXCEPTION 'subject ids are required'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    IF p_subject_id = p_related_subject_id THEN
        RAISE EXCEPTION 'related subjects cannot link a subject to itself'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    IF NOT EXISTS (
        SELECT 1
          FROM maludb_core.malu$svpor_subject s
         WHERE s.owner_schema = v_schema
           AND s.subject_id IN (p_subject_id, p_related_subject_id)
         GROUP BY s.owner_schema
        HAVING count(*) = 2
    ) THEN
        RAISE EXCEPTION 'one or both subjects do not exist in schema %', v_schema
            USING ERRCODE = 'foreign_key_violation';
    END IF;

    v_subject_a_id := LEAST(p_subject_id, p_related_subject_id);
    v_subject_b_id := GREATEST(p_subject_id, p_related_subject_id);

    DELETE FROM maludb_core.malu$svpor_subject_relationship r
     WHERE r.owner_schema = v_schema
       AND r.subject_a_id = v_subject_a_id
       AND r.subject_b_id = v_subject_b_id;

    RETURN FOUND;
END;
$body$;

REVOKE ALL ON FUNCTION maludb_core.delete_svpor_related_subject(bigint, bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core.delete_svpor_related_subject(bigint, bigint)
TO maludb_memory_admin, maludb_memory_executor;

CREATE FUNCTION maludb_core._enable_memory_schema_076_facade(p_schema name) RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
DECLARE
    v_count integer := 0;
BEGIN
    PERFORM maludb_core._memory_schema_assert_manageable(p_schema);

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_related_subject', 'view');
    EXECUTE format($sql$
        CREATE OR REPLACE VIEW %I.maludb_related_subject WITH (security_invoker = true) AS
        SELECT owner_schema,
               subject_a_id,
               subject_b_id,
               subject_a_label,
               subject_b_label,
               label,
               metadata_jsonb,
               created_at
          FROM maludb_core.malu$svpor_subject_relationship
         WHERE owner_schema = %L
        WITH LOCAL CHECK OPTION
    $sql$, p_schema, p_schema);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON %I.maludb_related_subject TO maludb_memory_admin, maludb_memory_executor', p_schema);
    EXECUTE format('GRANT SELECT ON %I.maludb_related_subject TO maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_related_subject', 'view', 'Schema-local canonical related-subject relationship facade.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_related_subject_add', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_related_subject_add(
            p_subject_id bigint,
            p_related_subject_id bigint,
            p_label text DEFAULT NULL,
            p_metadata_jsonb jsonb DEFAULT '{}'::jsonb
        ) RETURNS TABLE (
            related_subject_id bigint,
            related_subject_name text,
            label text,
            metadata_jsonb jsonb,
            created_at timestamptz
        )
        LANGUAGE sql
        SECURITY INVOKER
        SET search_path = %I, maludb_core, pg_temp
        AS $facade$
            SELECT *
              FROM maludb_core.add_svpor_related_subject(
                  p_subject_id, p_related_subject_id, p_label, p_metadata_jsonb
              )
        $facade$
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_related_subject_add(bigint, bigint, text, jsonb) FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_related_subject_add(bigint, bigint, text, jsonb) TO maludb_memory_admin, maludb_memory_executor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_related_subject_add', 'function', 'Schema-local related-subject writer.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_related_subjects', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_related_subjects(
            p_subject_id bigint
        ) RETURNS TABLE (
            related_subject_id bigint,
            related_subject_name text,
            label text,
            metadata_jsonb jsonb,
            created_at timestamptz
        )
        LANGUAGE sql
        STABLE
        SECURITY INVOKER
        SET search_path = %I, maludb_core, pg_temp
        AS $facade$
            SELECT * FROM maludb_core.list_svpor_related_subjects(p_subject_id)
        $facade$
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_related_subjects(bigint) FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_related_subjects(bigint) TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_related_subjects', 'function', 'Schema-local related-subject reader.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_related_subject_delete', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_related_subject_delete(
            p_subject_id bigint,
            p_related_subject_id bigint
        ) RETURNS boolean
        LANGUAGE sql
        SECURITY INVOKER
        SET search_path = %I, maludb_core, pg_temp
        AS $facade$
            SELECT maludb_core.delete_svpor_related_subject(p_subject_id, p_related_subject_id)
        $facade$
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_related_subject_delete(bigint, bigint) FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_related_subject_delete(bigint, bigint) TO maludb_memory_admin, maludb_memory_executor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_related_subject_delete', 'function', 'Schema-local related-subject delete helper.');
    v_count := v_count + 1;

    RETURN v_count;
END;
$body$;

REVOKE ALL ON FUNCTION maludb_core._enable_memory_schema_076_facade(name) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core._enable_memory_schema_076_facade(name)
TO maludb_memory_admin, maludb_memory_executor;

CREATE OR REPLACE FUNCTION maludb_core.enable_memory_schema(p_schema name DEFAULT current_schema())
RETURNS TABLE(schema_name name, enabled_version text, object_count integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
DECLARE
    v_enabled_version text := maludb_core.maludb_core_version();
    v_count integer := 0;
BEGIN
    IF p_schema IS NULL THEN
        p_schema := current_schema();
    END IF;

    PERFORM maludb_core._memory_schema_assert_manageable(p_schema);

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
