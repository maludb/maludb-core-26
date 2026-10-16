\echo Use "ALTER EXTENSION maludb_core UPDATE TO '0.19.0'" to load this file. \quit

-- =====================================================================
-- maludb_core 0.18.0 → 0.19.0
--
-- Stage 2 — JSON payload schema validation (S2-6).
--
-- Per requirements.md §9 Stage 2: "Document/JSON layout for memory
-- payloads (JSONB + pg_jsonschema)". pg_jsonschema isn't packaged in
-- PGDG for Ubuntu 24.04 / PG 17, so v1 ships a pure-PL/pgSQL subset
-- validator (_payload_validate) implementing the JSON Schema
-- features most useful for memory payloads:
--
--   * type        — string | integer | number | boolean | object |
--                    array | null
--   * required    — array of mandatory keys
--   * properties  — per-key recursive schema
--   * additionalProperties=false — reject unknown keys
--   * enum        — closed value set
--   * minimum/maximum            — numeric bounds
--   * minLength/maxLength        — string bounds
--   * pattern                    — string regex
--   * items                      — recursive schema for arrays
--
-- Drop-in replaceable: if/when pg_jsonschema lands, CREATE OR REPLACE
-- _payload_validate with a thin wrapper around jsonb_matches_schema()
-- and the rest of the surface keeps working.
--
-- Schemas live in malu$payload_schema, scoped per (object_type,
-- schema_name). schema_name follows the discriminator column where
-- present (memory.memory_kind, episode_object.episode_kind,
-- memory_detail_object.detail_kind, source_package.source_type);
-- 'default' applies when no kind-specific schema matches. The
-- triggers validate the payload column on INSERT/UPDATE and raise
-- on mismatch.
-- =====================================================================

CREATE OR REPLACE FUNCTION maludb_core_version() RETURNS text
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$ SELECT '0.19.0'::text $body$;

-- ---------------------------------------------------------------------
-- Payload-schema catalog
-- ---------------------------------------------------------------------
CREATE TABLE malu$payload_schema (
    schema_id           bigserial PRIMARY KEY,
    target_object_type  text NOT NULL,
    schema_name         text NOT NULL,
    schema_jsonb        jsonb NOT NULL,
    description         text,
    enabled             boolean NOT NULL DEFAULT true,
    owner_schema        name NOT NULL DEFAULT current_schema(),
    created_at          timestamptz NOT NULL DEFAULT now(),
    updated_at          timestamptz NOT NULL DEFAULT now(),
    CHECK (target_object_type IN
        ('source_package','claim','fact','memory','episode_object',
         'memory_detail_object')),
    UNIQUE (target_object_type, schema_name, owner_schema)
);
CREATE INDEX malu$payload_schema_lookup_idx
    ON malu$payload_schema(target_object_type, schema_name, enabled);

ALTER TABLE malu$payload_schema ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_owner ON malu$payload_schema
    USING (owner_schema = current_schema())
    WITH CHECK (owner_schema = current_schema());

GRANT SELECT ON malu$payload_schema TO
    maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;
GRANT INSERT, UPDATE, DELETE ON malu$payload_schema TO
    maludb_memory_admin, maludb_memory_executor;
GRANT USAGE, SELECT ON SEQUENCE malu$payload_schema_schema_id_seq TO
    maludb_memory_admin, maludb_memory_executor;

-- ---------------------------------------------------------------------
-- _payload_validate(schema_def, instance, path='')  → text[]
--
-- Empty result = valid. Each text element is "<path>: <reason>". Path
-- uses dotted property names + [n] for array indices, e.g.
--   "config.servers[0].port: expected integer, got string"
-- ---------------------------------------------------------------------
CREATE FUNCTION _payload_validate(
    p_schema   jsonb,
    p_instance jsonb,
    p_path     text DEFAULT ''
) RETURNS text[]
LANGUAGE plpgsql IMMUTABLE
AS $body$
DECLARE
    errors      text[] := ARRAY[]::text[];
    sub_errors  text[];
    sch_type    text;
    inst_type   text;
    req         text;
    prop        text;
    item        jsonb;
    idx         int;
    enum_member jsonb;
    allowed     boolean;
    path_here   text;
BEGIN
    IF p_schema IS NULL OR jsonb_typeof(p_schema) <> 'object' THEN
        RETURN errors;     -- empty / non-object schema = no constraint
    END IF;
    IF p_instance IS NULL THEN
        RETURN errors;     -- caller decides null-handling
    END IF;

    inst_type := jsonb_typeof(p_instance);
    path_here := COALESCE(NULLIF(p_path, ''), '$');

    -- ----- type --------------------------------------------------
    sch_type := p_schema ->> 'type';
    IF sch_type IS NOT NULL THEN
        IF NOT (
            inst_type = sch_type
            OR (sch_type = 'integer' AND inst_type = 'number' AND
                (p_instance::text) !~ '\.')
        ) THEN
            RETURN errors || format('%s: expected %s, got %s',
                                    path_here, sch_type, inst_type);
        END IF;
    END IF;

    -- ----- enum --------------------------------------------------
    IF p_schema ? 'enum' THEN
        allowed := false;
        FOR enum_member IN
            SELECT value FROM jsonb_array_elements(p_schema -> 'enum') AS v(value)
        LOOP
            IF enum_member = p_instance THEN
                allowed := true;
                EXIT;
            END IF;
        END LOOP;
        IF NOT allowed THEN
            errors := errors || format('%s: value %s not in enum',
                                       path_here, p_instance::text);
        END IF;
    END IF;

    -- ----- object: required + properties + additionalProperties ---
    IF sch_type = 'object' AND inst_type = 'object' THEN
        IF p_schema ? 'required' THEN
            FOR req IN
                SELECT value FROM jsonb_array_elements_text(p_schema -> 'required') AS v(value)
            LOOP
                IF NOT (p_instance ? req) THEN
                    errors := errors || format('%s: missing required property %s',
                                               path_here, req);
                END IF;
            END LOOP;
        END IF;

        FOR prop IN SELECT key FROM jsonb_object_keys(p_instance) AS k(key) LOOP
            IF p_schema ? 'properties' AND (p_schema -> 'properties') ? prop THEN
                sub_errors := _payload_validate(
                    p_schema -> 'properties' -> prop,
                    p_instance -> prop,
                    CASE WHEN p_path = '' THEN prop
                         ELSE p_path || '.' || prop END);
                errors := errors || sub_errors;
            ELSIF COALESCE((p_schema ->> 'additionalProperties')::boolean, true) = false THEN
                errors := errors || format('%s: additional property %s not allowed',
                                           path_here, prop);
            END IF;
        END LOOP;
    END IF;

    -- ----- array: items -----------------------------------------
    IF sch_type = 'array' AND inst_type = 'array' THEN
        idx := 0;
        IF p_schema ? 'items' THEN
            FOR item IN SELECT value FROM jsonb_array_elements(p_instance) AS v(value) LOOP
                sub_errors := _payload_validate(
                    p_schema -> 'items', item,
                    p_path || '[' || idx::text || ']');
                errors := errors || sub_errors;
                idx := idx + 1;
            END LOOP;
        END IF;
        IF p_schema ? 'minItems' THEN
            IF jsonb_array_length(p_instance) < (p_schema ->> 'minItems')::integer THEN
                errors := errors || format('%s: array has %s items, minItems=%s',
                                           path_here, jsonb_array_length(p_instance),
                                           p_schema ->> 'minItems');
            END IF;
        END IF;
        IF p_schema ? 'maxItems' THEN
            IF jsonb_array_length(p_instance) > (p_schema ->> 'maxItems')::integer THEN
                errors := errors || format('%s: array has %s items, maxItems=%s',
                                           path_here, jsonb_array_length(p_instance),
                                           p_schema ->> 'maxItems');
            END IF;
        END IF;
    END IF;

    -- ----- numeric bounds ---------------------------------------
    IF sch_type IN ('integer','number') AND inst_type = 'number' THEN
        IF p_schema ? 'minimum' AND
           (p_instance::text)::numeric < (p_schema ->> 'minimum')::numeric THEN
            errors := errors || format('%s: %s < minimum %s',
                                       path_here, p_instance::text,
                                       p_schema ->> 'minimum');
        END IF;
        IF p_schema ? 'maximum' AND
           (p_instance::text)::numeric > (p_schema ->> 'maximum')::numeric THEN
            errors := errors || format('%s: %s > maximum %s',
                                       path_here, p_instance::text,
                                       p_schema ->> 'maximum');
        END IF;
    END IF;

    -- ----- string bounds + pattern -------------------------------
    IF sch_type = 'string' AND inst_type = 'string' THEN
        DECLARE
            s text := p_instance #>> '{}';
        BEGIN
            IF p_schema ? 'minLength' AND
               char_length(s) < (p_schema ->> 'minLength')::integer THEN
                errors := errors || format('%s: length %s < minLength %s',
                                           path_here, char_length(s),
                                           p_schema ->> 'minLength');
            END IF;
            IF p_schema ? 'maxLength' AND
               char_length(s) > (p_schema ->> 'maxLength')::integer THEN
                errors := errors || format('%s: length %s > maxLength %s',
                                           path_here, char_length(s),
                                           p_schema ->> 'maxLength');
            END IF;
            IF p_schema ? 'pattern' AND s !~ (p_schema ->> 'pattern') THEN
                errors := errors || format('%s: %s does not match pattern %s',
                                           path_here, p_instance::text,
                                           p_schema ->> 'pattern');
            END IF;
        END;
    END IF;

    RETURN errors;
END;
$body$;

-- ---------------------------------------------------------------------
-- validate_payload(target_object_type, schema_name, instance) → text[]
--
-- Looks up the matching schema rows (preferring kind-specific, then
-- 'default'). Visible-to-current-schema schemas apply: tenant_owner
-- RLS gates which catalog rows participate. Returns concatenated
-- validation errors across all matching schemas; empty array = valid.
-- ---------------------------------------------------------------------
CREATE FUNCTION validate_payload(
    p_target_object_type text,
    p_schema_name        text,
    p_instance           jsonb
) RETURNS text[]
LANGUAGE plpgsql STABLE
AS $body$
DECLARE
    errors text[] := ARRAY[]::text[];
    rec    record;
BEGIN
    IF p_instance IS NULL THEN
        RETURN errors;
    END IF;
    FOR rec IN
        SELECT schema_name, schema_jsonb
        FROM malu$payload_schema
        WHERE target_object_type = p_target_object_type
          AND enabled = true
          AND schema_name IN (COALESCE(p_schema_name, '__none__'), 'default')
        ORDER BY (schema_name = 'default') ASC, schema_name
    LOOP
        errors := errors || _payload_validate(rec.schema_jsonb, p_instance);
    END LOOP;
    RETURN errors;
END;
$body$;

-- ---------------------------------------------------------------------
-- register_payload_schema — upsert helper.
-- ---------------------------------------------------------------------
CREATE FUNCTION register_payload_schema(
    p_target_object_type text,
    p_schema_name        text,
    p_schema_jsonb       jsonb,
    p_description        text DEFAULT NULL,
    p_enabled            boolean DEFAULT true
) RETURNS bigint
LANGUAGE plpgsql
AS $body$
DECLARE v_id bigint;
BEGIN
    INSERT INTO malu$payload_schema
        (target_object_type, schema_name, schema_jsonb, description, enabled)
    VALUES (p_target_object_type, p_schema_name, p_schema_jsonb,
            p_description, p_enabled)
    ON CONFLICT (target_object_type, schema_name, owner_schema) DO UPDATE
        SET schema_jsonb = EXCLUDED.schema_jsonb,
            description  = COALESCE(EXCLUDED.description, malu$payload_schema.description),
            enabled      = EXCLUDED.enabled,
            updated_at   = now()
    RETURNING schema_id INTO v_id;
    RETURN v_id;
END;
$body$;

-- ---------------------------------------------------------------------
-- Trigger functions — one per (table, payload column) pair.
-- Each one calls validate_payload() with the appropriate
-- (object_type, kind_or_default, payload). On error array non-empty,
-- raise check_violation with the concatenated error list.
-- ---------------------------------------------------------------------
CREATE FUNCTION _payload_validate_memory() RETURNS trigger
LANGUAGE plpgsql AS $body$
DECLARE errs text[];
BEGIN
    IF NEW.payload_jsonb IS NULL THEN RETURN NEW; END IF;
    errs := validate_payload('memory', NEW.memory_kind, NEW.payload_jsonb);
    IF array_length(errs, 1) > 0 THEN
        RAISE EXCEPTION 'PAYLOAD_VALIDATION_FAILED: memory_id=% kind=% errors=[%]',
            COALESCE(NEW.memory_id, 0), NEW.memory_kind, array_to_string(errs, '; ')
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$body$;

CREATE FUNCTION _payload_validate_episode() RETURNS trigger
LANGUAGE plpgsql AS $body$
DECLARE errs text[];
BEGIN
    IF NEW.payload_jsonb IS NULL THEN RETURN NEW; END IF;
    errs := validate_payload('episode_object', NEW.episode_kind, NEW.payload_jsonb);
    IF array_length(errs, 1) > 0 THEN
        RAISE EXCEPTION 'PAYLOAD_VALIDATION_FAILED: episode_id=% kind=% errors=[%]',
            COALESCE(NEW.episode_id, 0), NEW.episode_kind, array_to_string(errs, '; ')
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$body$;

CREATE FUNCTION _payload_validate_mdo() RETURNS trigger
LANGUAGE plpgsql AS $body$
DECLARE errs text[];
BEGIN
    IF NEW.body_jsonb IS NULL THEN RETURN NEW; END IF;
    errs := validate_payload('memory_detail_object', NEW.detail_kind, NEW.body_jsonb);
    IF array_length(errs, 1) > 0 THEN
        RAISE EXCEPTION 'PAYLOAD_VALIDATION_FAILED: mdo_id=% kind=% errors=[%]',
            COALESCE(NEW.mdo_id, 0), NEW.detail_kind, array_to_string(errs, '; ')
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$body$;

CREATE FUNCTION _payload_validate_claim() RETURNS trigger
LANGUAGE plpgsql AS $body$
DECLARE errs text[];
BEGIN
    IF NEW.statement_jsonb IS NULL THEN RETURN NEW; END IF;
    errs := validate_payload('claim', NULL, NEW.statement_jsonb);
    IF array_length(errs, 1) > 0 THEN
        RAISE EXCEPTION 'PAYLOAD_VALIDATION_FAILED: claim_id=% errors=[%]',
            COALESCE(NEW.claim_id, 0), array_to_string(errs, '; ')
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$body$;

CREATE FUNCTION _payload_validate_fact() RETURNS trigger
LANGUAGE plpgsql AS $body$
DECLARE errs text[];
BEGIN
    IF NEW.statement_jsonb IS NULL THEN RETURN NEW; END IF;
    errs := validate_payload('fact', NULL, NEW.statement_jsonb);
    IF array_length(errs, 1) > 0 THEN
        RAISE EXCEPTION 'PAYLOAD_VALIDATION_FAILED: fact_id=% errors=[%]',
            COALESCE(NEW.fact_id, 0), array_to_string(errs, '; ')
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$body$;

CREATE FUNCTION _payload_validate_source_package() RETURNS trigger
LANGUAGE plpgsql AS $body$
DECLARE errs text[];
BEGIN
    IF NEW.origin_jsonb IS NULL THEN RETURN NEW; END IF;
    errs := validate_payload('source_package', NEW.source_type, NEW.origin_jsonb);
    IF array_length(errs, 1) > 0 THEN
        RAISE EXCEPTION 'PAYLOAD_VALIDATION_FAILED: source_package_id=% type=% errors=[%]',
            COALESCE(NEW.source_package_id, 0), NEW.source_type, array_to_string(errs, '; ')
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$body$;

-- ---------------------------------------------------------------------
-- Triggers
-- ---------------------------------------------------------------------
CREATE TRIGGER memory_payload_validate_tg
    BEFORE INSERT OR UPDATE OF payload_jsonb, memory_kind
    ON malu$memory
    FOR EACH ROW EXECUTE FUNCTION _payload_validate_memory();

CREATE TRIGGER episode_payload_validate_tg
    BEFORE INSERT OR UPDATE OF payload_jsonb, episode_kind
    ON malu$episode_object
    FOR EACH ROW EXECUTE FUNCTION _payload_validate_episode();

CREATE TRIGGER mdo_payload_validate_tg
    BEFORE INSERT OR UPDATE OF body_jsonb, detail_kind
    ON malu$memory_detail_object
    FOR EACH ROW EXECUTE FUNCTION _payload_validate_mdo();

CREATE TRIGGER claim_payload_validate_tg
    BEFORE INSERT OR UPDATE OF statement_jsonb
    ON malu$claim
    FOR EACH ROW EXECUTE FUNCTION _payload_validate_claim();

CREATE TRIGGER fact_payload_validate_tg
    BEFORE INSERT OR UPDATE OF statement_jsonb
    ON malu$fact
    FOR EACH ROW EXECUTE FUNCTION _payload_validate_fact();

CREATE TRIGGER source_package_payload_validate_tg
    BEFORE INSERT OR UPDATE OF origin_jsonb, source_type
    ON malu$source_package
    FOR EACH ROW EXECUTE FUNCTION _payload_validate_source_package();

GRANT EXECUTE ON FUNCTION
    _payload_validate(jsonb, jsonb, text),
    validate_payload(text, text, jsonb),
    register_payload_schema(text, text, jsonb, text, boolean)
TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;
