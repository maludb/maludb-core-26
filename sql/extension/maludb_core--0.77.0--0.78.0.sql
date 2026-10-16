\echo Use "ALTER EXTENSION maludb_core UPDATE TO '0.78.0'" to load this file. \quit

-- =====================================================================
-- maludb_core 0.77.0 -> 0.78.0
--
-- Typed, temporal subject relationships.
--
-- The existing related-subject support stores one symmetric, untyped,
-- timeless row per unordered subject pair. This adds directed, typed,
-- valid-time relationship edges on top of it, so the system can record
-- facts like "Mary was 'project manager of' Zozocal from 2025-01-01
-- until 2025-12-31" and answer "what was the relationship as of <T>".
--
--   * malu$svpor_relationship_type        — tenant-scoped controlled
--       vocabulary of relationship types (+ optional inverse name).
--   * malu$svpor_subject_relationship_edge — directed, typed, valid-time
--       edges (tstzrange + GiST), one row per assertion-over-a-window.
--   * malu$svpor_subject_relationship gains relationship_type, kept in
--       sync with the currently-valid edge for the pair by trigger.
--   * core maintenance fns: register_svpor_relationship_type,
--       add/close/list/delete_svpor_relationship_edge.
--   * schema-local facades: maludb_relationship_type (+ _add),
--       maludb_related_subject_edge (+ _add/_close/_delete/_edges); the
--       maludb_related_subject view now also exposes relationship_type.
-- =====================================================================

CREATE OR REPLACE FUNCTION maludb_core.maludb_core_version() RETURNS text
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$ SELECT '0.78.0'::text $body$;

-- ---------- relationship-type catalog (tenant-scoped) ----------------
CREATE TABLE maludb_core.malu$svpor_relationship_type (
    owner_schema              name NOT NULL DEFAULT current_schema(),
    relationship_type         text NOT NULL,
    description               text,
    inverse_relationship_type text,
    created_at                timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (owner_schema, relationship_type),
    CONSTRAINT malu$svpor_relationship_type_inverse_fk
        FOREIGN KEY (owner_schema, inverse_relationship_type)
        REFERENCES maludb_core.malu$svpor_relationship_type(owner_schema, relationship_type)
        ON DELETE SET NULL (inverse_relationship_type)
);

ALTER TABLE maludb_core.malu$svpor_relationship_type ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_owner ON maludb_core.malu$svpor_relationship_type
    USING (owner_schema = current_schema())
    WITH CHECK (owner_schema = current_schema());

GRANT SELECT ON maludb_core.malu$svpor_relationship_type TO
    maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;
GRANT INSERT, UPDATE, DELETE ON maludb_core.malu$svpor_relationship_type TO
    maludb_memory_admin, maludb_memory_executor;

-- ---------- directed, typed, valid-time edges ------------------------
CREATE TABLE maludb_core.malu$svpor_subject_relationship_edge (
    owner_schema        name   NOT NULL DEFAULT current_schema(),
    edge_id             bigserial,
    from_subject_id     bigint NOT NULL,
    to_subject_id       bigint NOT NULL,
    from_subject_label  text   NOT NULL,
    to_subject_label    text   NOT NULL,
    relationship_type   text   NOT NULL,
    label               text,
    valid_from          timestamptz,             -- NULL = open start
    valid_to            timestamptz,             -- NULL = ongoing
    valid_range         tstzrange GENERATED ALWAYS AS
                            (tstzrange(valid_from, valid_to, '[)')) STORED,
    metadata_jsonb      jsonb  NOT NULL DEFAULT '{}'::jsonb,
    created_at          timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (owner_schema, edge_id),
    CONSTRAINT malu$svpor_subject_relationship_edge_no_self
        CHECK (from_subject_id <> to_subject_id),
    CONSTRAINT malu$svpor_subject_relationship_edge_time_order
        CHECK (valid_from IS NULL OR valid_to IS NULL OR valid_from < valid_to),
    CONSTRAINT malu$svpor_subject_relationship_edge_from_fk
        FOREIGN KEY (owner_schema, from_subject_id)
        REFERENCES maludb_core.malu$svpor_subject(owner_schema, subject_id)
        ON DELETE CASCADE,
    CONSTRAINT malu$svpor_subject_relationship_edge_to_fk
        FOREIGN KEY (owner_schema, to_subject_id)
        REFERENCES maludb_core.malu$svpor_subject(owner_schema, subject_id)
        ON DELETE CASCADE,
    CONSTRAINT malu$svpor_subject_relationship_edge_type_fk
        FOREIGN KEY (owner_schema, relationship_type)
        REFERENCES maludb_core.malu$svpor_relationship_type(owner_schema, relationship_type)
        ON DELETE RESTRICT
);

CREATE INDEX malu$svpor_subject_relationship_edge_from_idx
    ON maludb_core.malu$svpor_subject_relationship_edge(owner_schema, from_subject_id);
CREATE INDEX malu$svpor_subject_relationship_edge_to_idx
    ON maludb_core.malu$svpor_subject_relationship_edge(owner_schema, to_subject_id);

-- At most one assertion of the same directed, typed relationship at any
-- moment of valid time. subject ids are globally unique, so they already
-- scope the constraint per tenant; the GiST index also serves as-of reads.
ALTER TABLE maludb_core.malu$svpor_subject_relationship_edge
    ADD CONSTRAINT malu$svpor_subject_relationship_edge_overlap_excl
    EXCLUDE USING gist (
        from_subject_id   WITH =,
        to_subject_id     WITH =,
        relationship_type WITH =,
        valid_range       WITH &&
    );

ALTER TABLE maludb_core.malu$svpor_subject_relationship_edge ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_owner ON maludb_core.malu$svpor_subject_relationship_edge
    USING (owner_schema = current_schema())
    WITH CHECK (owner_schema = current_schema());

GRANT SELECT ON maludb_core.malu$svpor_subject_relationship_edge TO
    maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;
GRANT INSERT, UPDATE, DELETE ON maludb_core.malu$svpor_subject_relationship_edge TO
    maludb_memory_admin, maludb_memory_executor;
GRANT USAGE, SELECT ON SEQUENCE
    maludb_core.malu$svpor_subject_relationship_edge_edge_id_seq
TO maludb_memory_admin, maludb_memory_executor;

-- ---------- relationship_type on the symmetric pair header -----------
ALTER TABLE maludb_core.malu$svpor_subject_relationship
    ADD COLUMN relationship_type text;
ALTER TABLE maludb_core.malu$svpor_subject_relationship
    ADD CONSTRAINT malu$svpor_subject_relationship_type_fk
    FOREIGN KEY (owner_schema, relationship_type)
    REFERENCES maludb_core.malu$svpor_relationship_type(owner_schema, relationship_type)
    ON DELETE SET NULL (relationship_type);

-- ---------- edge label maintenance -----------------------------------
CREATE FUNCTION maludb_core._svpor_relationship_edge_set_labels_tg() RETURNS trigger
LANGUAGE plpgsql
AS $body$
DECLARE
    v_from_label text;
    v_to_label   text;
BEGIN
    SELECT canonical_name INTO v_from_label
      FROM maludb_core.malu$svpor_subject
     WHERE owner_schema = NEW.owner_schema
       AND subject_id = NEW.from_subject_id;

    SELECT canonical_name INTO v_to_label
      FROM maludb_core.malu$svpor_subject
     WHERE owner_schema = NEW.owner_schema
       AND subject_id = NEW.to_subject_id;

    IF v_from_label IS NULL OR v_to_label IS NULL THEN
        RAISE EXCEPTION 'relationship edge references missing subject'
            USING ERRCODE = 'foreign_key_violation';
    END IF;

    NEW.from_subject_label := v_from_label;
    NEW.to_subject_label   := v_to_label;
    NEW.metadata_jsonb     := COALESCE(NEW.metadata_jsonb, '{}'::jsonb);
    RETURN NEW;
END;
$body$;

CREATE TRIGGER svpor_relationship_edge_set_labels_tg
    BEFORE INSERT OR UPDATE OF owner_schema, from_subject_id, to_subject_id
    ON maludb_core.malu$svpor_subject_relationship_edge
    FOR EACH ROW
    EXECUTE FUNCTION maludb_core._svpor_relationship_edge_set_labels_tg();

-- Keep edge labels current when a subject is renamed. The 0.76 trigger
-- on malu$svpor_subject already refreshes the symmetric pair labels;
-- extend it to refresh the directed edge labels too.
CREATE OR REPLACE FUNCTION maludb_core._svpor_subject_relationship_refresh_label_tg() RETURNS trigger
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

    UPDATE maludb_core.malu$svpor_subject_relationship_edge
       SET from_subject_label = NEW.canonical_name
     WHERE owner_schema = NEW.owner_schema
       AND from_subject_id = NEW.subject_id;

    UPDATE maludb_core.malu$svpor_subject_relationship_edge
       SET to_subject_label = NEW.canonical_name
     WHERE owner_schema = NEW.owner_schema
       AND to_subject_id = NEW.subject_id;

    RETURN NEW;
END;
$body$;

-- ---------- header relationship_type sync ----------------------------
-- Recompute malu$svpor_subject_relationship.relationship_type for the
-- (x, y) pair from its edges: the currently-valid edge wins, else the
-- most recent edge; NULL if no edges remain. Only the type is touched
-- so manually-added pairs are preserved.
CREATE FUNCTION maludb_core._svpor_sync_relationship_header(
    p_owner_schema name,
    p_subject_x    bigint,
    p_subject_y    bigint
) RETURNS void
LANGUAGE plpgsql
AS $body$
DECLARE
    v_a    bigint := LEAST(p_subject_x, p_subject_y);
    v_b    bigint := GREATEST(p_subject_x, p_subject_y);
    v_type text;
    v_found boolean;
BEGIN
    SELECT e.relationship_type INTO v_type
      FROM maludb_core.malu$svpor_subject_relationship_edge e
     WHERE e.owner_schema = p_owner_schema
       AND ((e.from_subject_id = v_a AND e.to_subject_id = v_b)
         OR (e.from_subject_id = v_b AND e.to_subject_id = v_a))
     ORDER BY maludb_core.is_currently_valid(e.valid_from, e.valid_to) DESC,
              e.created_at DESC,
              e.edge_id DESC
     LIMIT 1;
    v_found := FOUND;

    IF v_found THEN
        INSERT INTO maludb_core.malu$svpor_subject_relationship(
            owner_schema, subject_a_id, subject_b_id,
            subject_a_label, subject_b_label, label, relationship_type)
        VALUES (p_owner_schema, v_a, v_b, '', '', NULL, v_type)
        ON CONFLICT (owner_schema, subject_a_id, subject_b_id) DO UPDATE
            SET relationship_type = EXCLUDED.relationship_type;
    ELSE
        UPDATE maludb_core.malu$svpor_subject_relationship
           SET relationship_type = NULL
         WHERE owner_schema = p_owner_schema
           AND subject_a_id = v_a
           AND subject_b_id = v_b;
    END IF;
END;
$body$;

CREATE FUNCTION maludb_core._svpor_relationship_edge_sync_header_tg() RETURNS trigger
LANGUAGE plpgsql
AS $body$
BEGIN
    IF TG_OP = 'DELETE' THEN
        PERFORM maludb_core._svpor_sync_relationship_header(
            OLD.owner_schema, OLD.from_subject_id, OLD.to_subject_id);
        RETURN OLD;
    END IF;

    PERFORM maludb_core._svpor_sync_relationship_header(
        NEW.owner_schema, NEW.from_subject_id, NEW.to_subject_id);

    -- if an UPDATE moved the edge to a different pair, refresh the old pair too
    IF TG_OP = 'UPDATE'
       AND (OLD.owner_schema    <> NEW.owner_schema
         OR OLD.from_subject_id <> NEW.from_subject_id
         OR OLD.to_subject_id   <> NEW.to_subject_id) THEN
        PERFORM maludb_core._svpor_sync_relationship_header(
            OLD.owner_schema, OLD.from_subject_id, OLD.to_subject_id);
    END IF;

    RETURN NULL;
END;
$body$;

CREATE TRIGGER svpor_relationship_edge_sync_header_tg
    AFTER INSERT OR UPDATE OR DELETE
    ON maludb_core.malu$svpor_subject_relationship_edge
    FOR EACH ROW
    EXECUTE FUNCTION maludb_core._svpor_relationship_edge_sync_header_tg();

-- ---------- core maintenance functions -------------------------------
CREATE FUNCTION maludb_core.register_svpor_relationship_type(
    p_relationship_type         text,
    p_description               text DEFAULT NULL,
    p_inverse_relationship_type text DEFAULT NULL
) RETURNS text
LANGUAGE plpgsql
AS $body$
DECLARE
    v_type text;
BEGIN
    IF p_relationship_type IS NULL OR btrim(p_relationship_type) = '' THEN
        RAISE EXCEPTION 'relationship_type is required'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    INSERT INTO maludb_core.malu$svpor_relationship_type(
        relationship_type, description, inverse_relationship_type)
    VALUES (p_relationship_type, p_description, p_inverse_relationship_type)
    ON CONFLICT (owner_schema, relationship_type) DO UPDATE
        SET description = COALESCE(EXCLUDED.description,
                                   malu$svpor_relationship_type.description),
            inverse_relationship_type = COALESCE(EXCLUDED.inverse_relationship_type,
                                   malu$svpor_relationship_type.inverse_relationship_type)
    RETURNING relationship_type INTO v_type;
    RETURN v_type;
END;
$body$;

REVOKE ALL ON FUNCTION maludb_core.register_svpor_relationship_type(text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core.register_svpor_relationship_type(text, text, text)
TO maludb_memory_admin, maludb_memory_executor;

CREATE FUNCTION maludb_core.add_svpor_relationship_edge(
    p_from_subject_id   bigint,
    p_to_subject_id     bigint,
    p_relationship_type text,
    p_valid_from        timestamptz DEFAULT NULL,
    p_valid_to          timestamptz DEFAULT NULL,
    p_label             text DEFAULT NULL,
    p_metadata_jsonb    jsonb DEFAULT '{}'::jsonb
) RETURNS TABLE (
    edge_id            bigint,
    from_subject_id    bigint,
    from_subject_name  text,
    to_subject_id      bigint,
    to_subject_name    text,
    relationship_type  text,
    label              text,
    valid_from         timestamptz,
    valid_to           timestamptz,
    metadata_jsonb     jsonb,
    created_at         timestamptz
) LANGUAGE plpgsql
SECURITY INVOKER
AS $body$
DECLARE
    v_schema name := current_schema();
    v_row maludb_core.malu$svpor_subject_relationship_edge%ROWTYPE;
BEGIN
    IF p_from_subject_id IS NULL OR p_to_subject_id IS NULL THEN
        RAISE EXCEPTION 'subject ids are required'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    IF p_from_subject_id = p_to_subject_id THEN
        RAISE EXCEPTION 'a relationship edge cannot link a subject to itself'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    INSERT INTO maludb_core.malu$svpor_subject_relationship_edge(
        owner_schema, from_subject_id, to_subject_id,
        from_subject_label, to_subject_label,
        relationship_type, label, valid_from, valid_to, metadata_jsonb)
    VALUES (
        v_schema, p_from_subject_id, p_to_subject_id,
        '', '',
        p_relationship_type, p_label, p_valid_from, p_valid_to,
        COALESCE(p_metadata_jsonb, '{}'::jsonb))
    RETURNING * INTO v_row;

    edge_id           := v_row.edge_id;
    from_subject_id   := v_row.from_subject_id;
    from_subject_name := v_row.from_subject_label;
    to_subject_id     := v_row.to_subject_id;
    to_subject_name   := v_row.to_subject_label;
    relationship_type := v_row.relationship_type;
    label             := v_row.label;
    valid_from        := v_row.valid_from;
    valid_to          := v_row.valid_to;
    metadata_jsonb    := v_row.metadata_jsonb;
    created_at        := v_row.created_at;
    RETURN NEXT;
END;
$body$;

REVOKE ALL ON FUNCTION maludb_core.add_svpor_relationship_edge(bigint, bigint, text, timestamptz, timestamptz, text, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core.add_svpor_relationship_edge(bigint, bigint, text, timestamptz, timestamptz, text, jsonb)
TO maludb_memory_admin, maludb_memory_executor;

CREATE FUNCTION maludb_core.close_svpor_relationship_edge(
    p_edge_id  bigint,
    p_valid_to timestamptz
) RETURNS boolean
LANGUAGE plpgsql
SECURITY INVOKER
AS $body$
DECLARE
    v_schema name := current_schema();
BEGIN
    IF p_edge_id IS NULL OR p_valid_to IS NULL THEN
        RAISE EXCEPTION 'edge id and valid_to are required'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    UPDATE maludb_core.malu$svpor_subject_relationship_edge
       SET valid_to = p_valid_to
     WHERE owner_schema = v_schema
       AND edge_id = p_edge_id
       AND valid_to IS DISTINCT FROM p_valid_to;

    RETURN FOUND;
END;
$body$;

REVOKE ALL ON FUNCTION maludb_core.close_svpor_relationship_edge(bigint, timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core.close_svpor_relationship_edge(bigint, timestamptz)
TO maludb_memory_admin, maludb_memory_executor;

CREATE FUNCTION maludb_core.list_svpor_relationship_edges(
    p_subject_id        bigint,
    p_as_of             timestamptz DEFAULT NULL,
    p_relationship_type text DEFAULT NULL,
    p_direction         text DEFAULT 'both'
) RETURNS TABLE (
    edge_id            bigint,
    from_subject_id    bigint,
    from_subject_name  text,
    to_subject_id      bigint,
    to_subject_name    text,
    relationship_type  text,
    label              text,
    valid_from         timestamptz,
    valid_to           timestamptz,
    is_current         boolean,
    metadata_jsonb     jsonb,
    created_at         timestamptz
) LANGUAGE plpgsql
STABLE
SECURITY INVOKER
AS $body$
DECLARE
    v_schema name := current_schema();
    v_dir    text := lower(COALESCE(p_direction, 'both'));
BEGIN
    IF v_dir NOT IN ('from', 'to', 'both') THEN
        RAISE EXCEPTION 'direction must be one of from, to, both'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM maludb_core.malu$svpor_subject s
         WHERE s.owner_schema = v_schema
           AND s.subject_id = p_subject_id
    ) THEN
        RAISE EXCEPTION 'subject % does not exist in schema %', p_subject_id, v_schema
            USING ERRCODE = 'foreign_key_violation';
    END IF;

    RETURN QUERY
    SELECT e.edge_id,
           e.from_subject_id, e.from_subject_label,
           e.to_subject_id,   e.to_subject_label,
           e.relationship_type, e.label,
           e.valid_from, e.valid_to,
           maludb_core.is_currently_valid(e.valid_from, e.valid_to),
           e.metadata_jsonb, e.created_at
      FROM maludb_core.malu$svpor_subject_relationship_edge e
     WHERE e.owner_schema = v_schema
       AND ((v_dir IN ('from', 'both') AND e.from_subject_id = p_subject_id)
         OR (v_dir IN ('to',   'both') AND e.to_subject_id   = p_subject_id))
       AND (p_relationship_type IS NULL OR e.relationship_type = p_relationship_type)
       AND (p_as_of IS NULL OR maludb_core.is_valid_at(e.valid_from, e.valid_to, p_as_of))
     ORDER BY e.from_subject_id, e.to_subject_id, e.valid_from NULLS FIRST, e.edge_id;
END;
$body$;

REVOKE ALL ON FUNCTION maludb_core.list_svpor_relationship_edges(bigint, timestamptz, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core.list_svpor_relationship_edges(bigint, timestamptz, text, text)
TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;

CREATE FUNCTION maludb_core.delete_svpor_relationship_edge(
    p_edge_id bigint
) RETURNS boolean
LANGUAGE plpgsql
SECURITY INVOKER
AS $body$
DECLARE
    v_schema name := current_schema();
BEGIN
    IF p_edge_id IS NULL THEN
        RAISE EXCEPTION 'edge id is required'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    DELETE FROM maludb_core.malu$svpor_subject_relationship_edge
     WHERE owner_schema = v_schema
       AND edge_id = p_edge_id;

    RETURN FOUND;
END;
$body$;

REVOKE ALL ON FUNCTION maludb_core.delete_svpor_relationship_edge(bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core.delete_svpor_relationship_edge(bigint)
TO maludb_memory_admin, maludb_memory_executor;

-- ---------- schema-local facade: surface relationship_type -----------
-- Redefine the 0.76 facade builder so maludb_related_subject also
-- exposes relationship_type. The column is appended last so existing
-- tenant views can be replaced with CREATE OR REPLACE VIEW.
CREATE OR REPLACE FUNCTION maludb_core._enable_memory_schema_076_facade(p_schema name) RETURNS integer
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
               created_at,
               relationship_type
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

-- ---------- schema-local facade: typed temporal edges ----------------
CREATE FUNCTION maludb_core._enable_memory_schema_078_facade(p_schema name) RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
DECLARE
    v_count integer := 0;
BEGIN
    PERFORM maludb_core._memory_schema_assert_manageable(p_schema);

    -- relationship-type catalog facade
    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_relationship_type', 'view');
    EXECUTE format($sql$
        CREATE OR REPLACE VIEW %I.maludb_relationship_type WITH (security_invoker = true) AS
        SELECT relationship_type,
               description,
               inverse_relationship_type,
               created_at
          FROM maludb_core.malu$svpor_relationship_type
         WHERE owner_schema = %L
        WITH LOCAL CHECK OPTION
    $sql$, p_schema, p_schema);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON %I.maludb_relationship_type TO maludb_memory_admin, maludb_memory_executor', p_schema);
    EXECUTE format('GRANT SELECT ON %I.maludb_relationship_type TO maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_relationship_type', 'view', 'Schema-local relationship-type catalog facade.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_relationship_type_add', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_relationship_type_add(
            p_relationship_type text,
            p_description text DEFAULT NULL,
            p_inverse_relationship_type text DEFAULT NULL
        ) RETURNS text
        LANGUAGE sql
        SECURITY INVOKER
        SET search_path = %I, maludb_core, pg_temp
        AS $facade$
            SELECT maludb_core.register_svpor_relationship_type(
                p_relationship_type, p_description, p_inverse_relationship_type)
        $facade$
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_relationship_type_add(text, text, text) FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_relationship_type_add(text, text, text) TO maludb_memory_admin, maludb_memory_executor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_relationship_type_add', 'function', 'Schema-local relationship-type writer.');
    v_count := v_count + 1;

    -- directed temporal edge facade
    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_related_subject_edge', 'view');
    EXECUTE format($sql$
        CREATE OR REPLACE VIEW %I.maludb_related_subject_edge WITH (security_invoker = true) AS
        SELECT owner_schema,
               edge_id,
               from_subject_id,
               to_subject_id,
               from_subject_label,
               to_subject_label,
               relationship_type,
               label,
               valid_from,
               valid_to,
               metadata_jsonb,
               created_at
          FROM maludb_core.malu$svpor_subject_relationship_edge
         WHERE owner_schema = %L
        WITH LOCAL CHECK OPTION
    $sql$, p_schema, p_schema);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON %I.maludb_related_subject_edge TO maludb_memory_admin, maludb_memory_executor', p_schema);
    EXECUTE format('GRANT SELECT ON %I.maludb_related_subject_edge TO maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_related_subject_edge', 'view', 'Schema-local directed, typed, temporal relationship edge facade.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_related_subject_edge_add', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_related_subject_edge_add(
            p_from_subject_id bigint,
            p_to_subject_id bigint,
            p_relationship_type text,
            p_valid_from timestamptz DEFAULT NULL,
            p_valid_to timestamptz DEFAULT NULL,
            p_label text DEFAULT NULL,
            p_metadata_jsonb jsonb DEFAULT '{}'::jsonb
        ) RETURNS TABLE (
            edge_id bigint,
            from_subject_id bigint,
            from_subject_name text,
            to_subject_id bigint,
            to_subject_name text,
            relationship_type text,
            label text,
            valid_from timestamptz,
            valid_to timestamptz,
            metadata_jsonb jsonb,
            created_at timestamptz
        )
        LANGUAGE sql
        SECURITY INVOKER
        SET search_path = %I, maludb_core, pg_temp
        AS $facade$
            SELECT *
              FROM maludb_core.add_svpor_relationship_edge(
                  p_from_subject_id, p_to_subject_id, p_relationship_type,
                  p_valid_from, p_valid_to, p_label, p_metadata_jsonb)
        $facade$
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_related_subject_edge_add(bigint, bigint, text, timestamptz, timestamptz, text, jsonb) FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_related_subject_edge_add(bigint, bigint, text, timestamptz, timestamptz, text, jsonb) TO maludb_memory_admin, maludb_memory_executor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_related_subject_edge_add', 'function', 'Schema-local relationship-edge writer.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_related_subject_edges', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_related_subject_edges(
            p_subject_id bigint,
            p_as_of timestamptz DEFAULT NULL,
            p_relationship_type text DEFAULT NULL,
            p_direction text DEFAULT 'both'
        ) RETURNS TABLE (
            edge_id bigint,
            from_subject_id bigint,
            from_subject_name text,
            to_subject_id bigint,
            to_subject_name text,
            relationship_type text,
            label text,
            valid_from timestamptz,
            valid_to timestamptz,
            is_current boolean,
            metadata_jsonb jsonb,
            created_at timestamptz
        )
        LANGUAGE sql
        STABLE
        SECURITY INVOKER
        SET search_path = %I, maludb_core, pg_temp
        AS $facade$
            SELECT *
              FROM maludb_core.list_svpor_relationship_edges(
                  p_subject_id, p_as_of, p_relationship_type, p_direction)
        $facade$
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_related_subject_edges(bigint, timestamptz, text, text) FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_related_subject_edges(bigint, timestamptz, text, text) TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_related_subject_edges', 'function', 'Schema-local relationship-edge reader (point-in-time).');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_related_subject_edge_close', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_related_subject_edge_close(
            p_edge_id bigint,
            p_valid_to timestamptz
        ) RETURNS boolean
        LANGUAGE sql
        SECURITY INVOKER
        SET search_path = %I, maludb_core, pg_temp
        AS $facade$
            SELECT maludb_core.close_svpor_relationship_edge(p_edge_id, p_valid_to)
        $facade$
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_related_subject_edge_close(bigint, timestamptz) FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_related_subject_edge_close(bigint, timestamptz) TO maludb_memory_admin, maludb_memory_executor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_related_subject_edge_close', 'function', 'Schema-local relationship-edge close helper.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_related_subject_edge_delete', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_related_subject_edge_delete(
            p_edge_id bigint
        ) RETURNS boolean
        LANGUAGE sql
        SECURITY INVOKER
        SET search_path = %I, maludb_core, pg_temp
        AS $facade$
            SELECT maludb_core.delete_svpor_relationship_edge(p_edge_id)
        $facade$
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_related_subject_edge_delete(bigint) FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_related_subject_edge_delete(bigint) TO maludb_memory_admin, maludb_memory_executor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_related_subject_edge_delete', 'function', 'Schema-local relationship-edge delete helper.');
    v_count := v_count + 1;

    RETURN v_count;
END;
$body$;

REVOKE ALL ON FUNCTION maludb_core._enable_memory_schema_078_facade(name) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core._enable_memory_schema_078_facade(name)
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
    v_count := v_count + maludb_core._enable_memory_schema_078_facade(p_schema);
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
