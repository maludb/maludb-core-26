\echo Use "ALTER EXTENSION maludb_core UPDATE TO '0.47.0'" to load this file. \quit

-- =====================================================================
-- maludb_core 0.46.0 → 0.47.0
--
-- Stage 12 / V3-STOR-01 (catalog): Verbatim Source Archive v1.
--
-- Adds the catalog the future maludb-restd + CLI will consume to
-- track immutable raw evidence:
--   malu$storage_adapter        — local_fs / s3 endpoints.
--   malu$source_object          — content_hash, byte_length, media
--                                 type, retention_class, legal_hold,
--                                 sensitivity, partition, adapter_uri.
--   malu$source_object_reference — byte/line/page/timestamp/cursor
--                                 offsets that anchor a Claim or Fact
--                                 to a specific slice of the object.
--
-- Doctrine:
--   * Objects are immutable. Re-uploading the same byte sequence
--     returns the existing object_id (content_hash is UNIQUE).
--   * The actual byte storage lives outside PostgreSQL — the CLI
--     (and later maludb-restd) writes to the configured adapter and
--     registers the resulting metadata here.
--   * Legal hold and retention_class match the existing
--     malu$source_package vocabulary so promotion is a metadata
--     copy, not a reclassification.
--   * RLS owner_schema-bound everywhere.
--
-- The Stage 12 promotion path (`source_object_promote_to_source_package`
-- + Derivation Ledger entry) lands in `0.47.0 → 0.48.0`.
--
-- Apply with:
--   ALTER EXTENSION maludb_core UPDATE TO '0.47.0';
-- =====================================================================

CREATE OR REPLACE FUNCTION maludb_core_version() RETURNS text
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$ SELECT '0.47.0'::text $body$;

-- ---------------------------------------------------------------------
-- malu$storage_adapter
-- ---------------------------------------------------------------------
CREATE TABLE malu$storage_adapter (
    adapter_id    bigserial PRIMARY KEY,
    name          text       NOT NULL,
    kind          text       NOT NULL CHECK (kind IN ('local_fs','s3')),
    config        jsonb      NOT NULL DEFAULT '{}'::jsonb,
    -- local_fs config: {"base_path": "/var/lib/maludb/source-archive"}
    -- s3        config: {"bucket": "...", "region": "...", "key_prefix": "...",
    --                    "endpoint": "..."}  (credentials live behind secret_ref)
    secret_ref    text,                -- malu$secret.name (resolved via __secret_resolve)
    description   text,
    owner_schema  name       NOT NULL DEFAULT current_schema(),
    created_at    timestamptz NOT NULL DEFAULT now(),
    retired_at    timestamptz,
    UNIQUE (owner_schema, name)
);
CREATE INDEX malu$storage_adapter_owner_idx
    ON malu$storage_adapter(owner_schema) WHERE retired_at IS NULL;

-- ---------------------------------------------------------------------
-- malu$source_object — one row per immutable source byte sequence.
-- content_hash is the raw SHA-256 (bytea, 32 bytes). The hex-encoded
-- form is exposed by source_object_metadata() and is what
-- malu$source_package.content_hash stores after promotion.
-- ---------------------------------------------------------------------
CREATE TABLE malu$source_object (
    object_id          bigserial PRIMARY KEY,
    content_hash       bytea      NOT NULL,
    media_type         text,
    byte_length        bigint     NOT NULL CHECK (byte_length >= 0),
    source_time        timestamptz,
    capture_time       timestamptz NOT NULL DEFAULT now(),
    retention_class    text       NOT NULL DEFAULT 'standard'
        CHECK (retention_class IN ('standard','sensitive','restricted','prohibited')),
    legal_hold         boolean    NOT NULL DEFAULT false,
    legal_hold_reason  text,
    sensitivity        text       NOT NULL DEFAULT 'internal'
        CHECK (sensitivity IN ('public','internal','restricted','prohibited')),
    partition          text,
    adapter_id         bigint     NOT NULL REFERENCES malu$storage_adapter(adapter_id) ON DELETE RESTRICT,
    adapter_uri        text       NOT NULL,
    signed_url_policy  jsonb,
    owner_schema       name       NOT NULL DEFAULT current_schema(),
    created_at         timestamptz NOT NULL DEFAULT now(),
    retired_at         timestamptz,
    UNIQUE (owner_schema, content_hash),
    CHECK (octet_length(content_hash) = 32)
);
CREATE INDEX malu$source_object_hash_idx
    ON malu$source_object(content_hash)
    WHERE retired_at IS NULL;
CREATE INDEX malu$source_object_partition_idx
    ON malu$source_object(owner_schema, partition)
    WHERE partition IS NOT NULL AND retired_at IS NULL;
CREATE INDEX malu$source_object_legal_hold_idx
    ON malu$source_object(owner_schema)
    WHERE legal_hold;

-- ---------------------------------------------------------------------
-- malu$source_object_reference — byte/line/page/timestamp/cursor
-- anchors. A Claim or Fact can point at one or more reference rows
-- to record "this assertion comes from these bytes of this object".
-- ---------------------------------------------------------------------
CREATE TABLE malu$source_object_reference (
    reference_id  bigserial PRIMARY KEY,
    object_id     bigint    NOT NULL REFERENCES malu$source_object(object_id) ON DELETE CASCADE,
    kind          text      NOT NULL CHECK (kind IN
                    ('byte_range','line_range','page','timestamp','cursor')),
    value_jsonb   jsonb     NOT NULL,
    note          text,
    created_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX malu$source_object_reference_object_idx
    ON malu$source_object_reference(object_id);

-- ---------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------
ALTER TABLE malu$storage_adapter ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_owner ON malu$storage_adapter
    USING      (owner_schema = current_schema())
    WITH CHECK (owner_schema = current_schema());

ALTER TABLE malu$source_object ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_owner ON malu$source_object
    USING      (owner_schema = current_schema())
    WITH CHECK (owner_schema = current_schema());

ALTER TABLE malu$source_object_reference ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_via_object ON malu$source_object_reference
    USING (
        EXISTS (
            SELECT 1 FROM malu$source_object o
            WHERE o.object_id    = malu$source_object_reference.object_id
              AND o.owner_schema = current_schema()
        )
    )
    WITH CHECK (
        EXISTS (
            SELECT 1 FROM malu$source_object o
            WHERE o.object_id    = malu$source_object_reference.object_id
              AND o.owner_schema = current_schema()
        )
    );

-- ---------------------------------------------------------------------
-- Grants. Admin + executor write; auditor reads.
-- ---------------------------------------------------------------------
GRANT SELECT, INSERT, UPDATE, DELETE ON malu$storage_adapter, malu$source_object, malu$source_object_reference TO maludb_memory_admin;
GRANT SELECT, INSERT, UPDATE         ON malu$storage_adapter, malu$source_object, malu$source_object_reference TO maludb_memory_executor;
GRANT SELECT                          ON malu$storage_adapter, malu$source_object, malu$source_object_reference TO maludb_memory_auditor;

GRANT USAGE, SELECT ON SEQUENCE malu$storage_adapter_adapter_id_seq             TO maludb_memory_admin, maludb_memory_executor;
GRANT USAGE, SELECT ON SEQUENCE malu$source_object_object_id_seq                TO maludb_memory_admin, maludb_memory_executor;
GRANT USAGE, SELECT ON SEQUENCE malu$source_object_reference_reference_id_seq   TO maludb_memory_admin, maludb_memory_executor;

-- =====================================================================
-- Public API
-- =====================================================================

CREATE FUNCTION register_storage_adapter(
    p_name         text,
    p_kind         text,
    p_config       jsonb DEFAULT '{}'::jsonb,
    p_secret_ref   text  DEFAULT NULL,
    p_description  text  DEFAULT NULL
) RETURNS bigint
    LANGUAGE plpgsql VOLATILE
    AS $body$
#variable_conflict use_column
DECLARE v_id bigint;
BEGIN
    IF p_kind NOT IN ('local_fs','s3') THEN
        RAISE EXCEPTION 'register_storage_adapter: kind must be local_fs or s3'
            USING ERRCODE = 'check_violation';
    END IF;
    IF p_kind = 'local_fs' AND NOT (p_config ? 'base_path') THEN
        RAISE EXCEPTION 'register_storage_adapter: local_fs config needs {"base_path": "..."}'
            USING ERRCODE = 'check_violation';
    END IF;
    IF p_kind = 's3' AND NOT (p_config ? 'bucket') THEN
        RAISE EXCEPTION 'register_storage_adapter: s3 config needs {"bucket": "...", ...}'
            USING ERRCODE = 'check_violation';
    END IF;

    INSERT INTO malu$storage_adapter(name, kind, config, secret_ref, description)
    VALUES (p_name, p_kind, p_config, p_secret_ref, p_description)
    ON CONFLICT (owner_schema, name) DO UPDATE
        SET kind        = EXCLUDED.kind,
            config      = EXCLUDED.config,
            secret_ref  = EXCLUDED.secret_ref,
            description = EXCLUDED.description,
            retired_at  = NULL
    RETURNING adapter_id INTO v_id;

    PERFORM audit_event('storage_adapter_register', 'malu$storage_adapter', v_id,
        jsonb_build_object('name', p_name, 'kind', p_kind, 'secret_ref', p_secret_ref),
        NULL);
    RETURN v_id;
END;
$body$;
REVOKE EXECUTE ON FUNCTION register_storage_adapter(text, text, jsonb, text, text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION register_storage_adapter(text, text, jsonb, text, text) TO
    maludb_memory_admin, maludb_memory_executor;

-- source_object_register — UPSERT keyed by (owner_schema, content_hash).
-- If the same byte sequence has already been registered, returns the
-- existing object_id without re-inserting. Otherwise creates a new
-- row pointing at the supplied adapter_uri.
CREATE FUNCTION source_object_register(
    p_adapter_name    text,
    p_adapter_uri     text,
    p_content_hash    bytea,
    p_byte_length     bigint,
    p_media_type      text          DEFAULT NULL,
    p_source_time     timestamptz   DEFAULT NULL,
    p_retention_class text          DEFAULT 'standard',
    p_sensitivity     text          DEFAULT 'internal',
    p_partition       text          DEFAULT NULL
) RETURNS bigint
    LANGUAGE plpgsql VOLATILE
    AS $body$
#variable_conflict use_column
DECLARE
    v_adapter_id bigint;
    v_existing   bigint;
    v_id         bigint;
BEGIN
    IF octet_length(p_content_hash) <> 32 THEN
        RAISE EXCEPTION 'source_object_register: content_hash must be 32 bytes (raw SHA-256)'
            USING ERRCODE = 'check_violation';
    END IF;

    SELECT adapter_id INTO v_adapter_id
      FROM malu$storage_adapter
     WHERE name = p_adapter_name AND retired_at IS NULL;
    IF v_adapter_id IS NULL THEN
        RAISE EXCEPTION 'source_object_register: adapter % not found or retired', p_adapter_name
            USING ERRCODE = 'no_data_found';
    END IF;

    SELECT object_id INTO v_existing
      FROM malu$source_object
     WHERE content_hash = p_content_hash
       AND retired_at IS NULL;
    IF v_existing IS NOT NULL THEN
        RETURN v_existing;
    END IF;

    INSERT INTO malu$source_object
        (content_hash, byte_length, media_type, source_time,
         retention_class, sensitivity, partition,
         adapter_id, adapter_uri)
    VALUES
        (p_content_hash, p_byte_length, p_media_type, p_source_time,
         p_retention_class, p_sensitivity, p_partition,
         v_adapter_id, p_adapter_uri)
    RETURNING object_id INTO v_id;

    PERFORM audit_event('source_object_register', 'malu$source_object', v_id,
        jsonb_build_object(
            'adapter',         p_adapter_name,
            'adapter_uri',     p_adapter_uri,
            'content_hash',    encode(p_content_hash, 'hex'),
            'byte_length',     p_byte_length,
            'media_type',      p_media_type,
            'retention_class', p_retention_class,
            'sensitivity',     p_sensitivity,
            'partition',       p_partition),
        NULL);
    RETURN v_id;
END;
$body$;
REVOKE EXECUTE ON FUNCTION source_object_register(text, text, bytea, bigint, text, timestamptz, text, text, text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION source_object_register(text, text, bytea, bigint, text, timestamptz, text, text, text) TO
    maludb_memory_admin, maludb_memory_executor;

CREATE FUNCTION source_object_lookup_by_hash(p_content_hash bytea)
    RETURNS bigint
    LANGUAGE plpgsql STABLE
    AS $body$
#variable_conflict use_column
DECLARE v_id bigint;
BEGIN
    SELECT object_id INTO v_id
      FROM malu$source_object
     WHERE content_hash = p_content_hash
       AND retired_at IS NULL
     LIMIT 1;
    RETURN v_id;
END;
$body$;
REVOKE EXECUTE ON FUNCTION source_object_lookup_by_hash(bytea) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION source_object_lookup_by_hash(bytea) TO
    maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;

CREATE FUNCTION source_object_set_legal_hold(
    p_object_id bigint,
    p_hold      boolean,
    p_reason    text DEFAULT NULL
) RETURNS boolean
    LANGUAGE plpgsql VOLATILE
    AS $body$
#variable_conflict use_column
DECLARE v_was boolean;
BEGIN
    SELECT legal_hold INTO v_was FROM malu$source_object WHERE object_id = p_object_id;
    IF v_was IS NULL THEN
        RAISE EXCEPTION 'source_object_set_legal_hold: object % not found', p_object_id
            USING ERRCODE = 'no_data_found';
    END IF;
    UPDATE malu$source_object
       SET legal_hold        = p_hold,
           legal_hold_reason = CASE WHEN p_hold THEN p_reason ELSE NULL END
     WHERE object_id = p_object_id;
    PERFORM audit_event(
        CASE WHEN p_hold THEN 'source_object_legal_hold_on' ELSE 'source_object_legal_hold_off' END,
        'malu$source_object', p_object_id,
        jsonb_build_object('reason', p_reason, 'was_held', v_was), NULL);
    RETURN v_was;
END;
$body$;
REVOKE EXECUTE ON FUNCTION source_object_set_legal_hold(bigint, boolean, text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION source_object_set_legal_hold(bigint, boolean, text) TO
    maludb_memory_admin, maludb_memory_executor;

CREATE FUNCTION source_object_add_reference(
    p_object_id   bigint,
    p_kind        text,
    p_value_jsonb jsonb,
    p_note        text DEFAULT NULL
) RETURNS bigint
    LANGUAGE plpgsql VOLATILE
    AS $body$
#variable_conflict use_column
DECLARE v_id bigint;
BEGIN
    INSERT INTO malu$source_object_reference(object_id, kind, value_jsonb, note)
    VALUES (p_object_id, p_kind, p_value_jsonb, p_note)
    RETURNING reference_id INTO v_id;
    RETURN v_id;
END;
$body$;
REVOKE EXECUTE ON FUNCTION source_object_add_reference(bigint, text, jsonb, text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION source_object_add_reference(bigint, text, jsonb, text) TO
    maludb_memory_admin, maludb_memory_executor;

CREATE FUNCTION source_object_metadata(p_object_id bigint)
    RETURNS TABLE (
        object_id        bigint,
        content_hash_hex text,
        byte_length      bigint,
        media_type       text,
        source_time      timestamptz,
        capture_time     timestamptz,
        retention_class  text,
        legal_hold       boolean,
        sensitivity      text,
        partition        text,
        adapter_name     text,
        adapter_kind     text,
        adapter_uri      text,
        created_at       timestamptz,
        retired_at       timestamptz
    ) LANGUAGE plpgsql STABLE
    AS $body$
#variable_conflict use_column
BEGIN
    RETURN QUERY
    SELECT o.object_id, encode(o.content_hash, 'hex'), o.byte_length, o.media_type,
           o.source_time, o.capture_time, o.retention_class, o.legal_hold,
           o.sensitivity, o.partition, a.name, a.kind, o.adapter_uri,
           o.created_at, o.retired_at
      FROM malu$source_object o
      JOIN malu$storage_adapter a ON a.adapter_id = o.adapter_id
     WHERE o.object_id = p_object_id;
END;
$body$;
REVOKE EXECUTE ON FUNCTION source_object_metadata(bigint) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION source_object_metadata(bigint) TO
    maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;
