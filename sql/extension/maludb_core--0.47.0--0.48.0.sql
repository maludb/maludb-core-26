\echo Use "ALTER EXTENSION maludb_core UPDATE TO '0.48.0'" to load this file. \quit

-- =====================================================================
-- maludb_core 0.47.0 → 0.48.0
--
-- Stage 12 / V3-STOR-01 (promotion): source_object → source_package.
--
-- Closes V3-STOR-01's "promotion path from stored object to Source
-- Package, Claims, Facts, embeddings, Derivation Ledger" requirement.
-- The function in this migration handles the source_object →
-- source_package step plus a malu$derivation_ledger entry recording
-- the source_object_id, adapter, and content_hash that produced the
-- source_package. Further promotions (claim, fact, ...) reuse the
-- existing register_claim / register_fact pipeline from Stage 2.
--
-- Apply with:
--   ALTER EXTENSION maludb_core UPDATE TO '0.48.0';
-- =====================================================================

CREATE OR REPLACE FUNCTION maludb_core_version() RETURNS text
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$ SELECT '0.48.0'::text $body$;

-- source_object_promote_to_source_package — wraps register_source_package
-- with the source-archive content_hash + byte_length, and writes a
-- malu$derivation_ledger entry of kind 'source_package' recording the
-- archive provenance. The promoted package's content lives in the
-- catalog row's content_text/_bytes/_jsonb (one of which the caller
-- supplies); the malu$source_object itself remains the immutable
-- byte-source-of-truth, addressable by hash.
CREATE FUNCTION source_object_promote_to_source_package(
    p_object_id       bigint,
    p_source_type     text,
    p_content_bytes   bytea       DEFAULT NULL,
    p_content_text    text        DEFAULT NULL,
    p_content_jsonb   jsonb       DEFAULT NULL,
    p_origin_jsonb    jsonb       DEFAULT NULL,
    p_captured_at     timestamptz DEFAULT NULL
) RETURNS bigint
    LANGUAGE plpgsql VOLATILE
    AS $body$
#variable_conflict use_column
DECLARE
    v_obj                 malu$source_object%ROWTYPE;
    v_adapter_name        text;
    v_adapter_kind        text;
    v_hash_hex            text;
    v_origin              jsonb;
    v_package_id          bigint;
    v_ledger_id           bigint;
    v_inputs              jsonb;
BEGIN
    SELECT * INTO v_obj FROM malu$source_object WHERE object_id = p_object_id;
    IF v_obj.object_id IS NULL THEN
        RAISE EXCEPTION 'source_object_promote_to_source_package: object % not found', p_object_id
            USING ERRCODE = 'no_data_found';
    END IF;
    IF v_obj.retired_at IS NOT NULL THEN
        RAISE EXCEPTION 'source_object_promote_to_source_package: object % is retired', p_object_id
            USING ERRCODE = 'object_not_in_prerequisite_state';
    END IF;

    SELECT name, kind
      INTO v_adapter_name, v_adapter_kind
      FROM malu$storage_adapter
     WHERE adapter_id = v_obj.adapter_id;

    v_hash_hex := encode(v_obj.content_hash, 'hex');

    -- Build the origin envelope: caller-supplied origin merged with
    -- archive provenance, so the resulting Source Package row carries
    -- the adapter and object_id even before anyone looks at the
    -- Derivation Ledger.
    v_origin := COALESCE(p_origin_jsonb, '{}'::jsonb) || jsonb_build_object(
        'source_object_id', v_obj.object_id,
        'adapter',          v_adapter_name,
        'adapter_kind',     v_adapter_kind,
        'adapter_uri',      v_obj.adapter_uri,
        'content_hash',     v_hash_hex,
        'byte_length',      v_obj.byte_length,
        'media_type',       v_obj.media_type);

    v_package_id := register_source_package(
        p_source_type     => p_source_type,
        p_content_bytes   => p_content_bytes,
        p_content_text    => p_content_text,
        p_content_jsonb   => p_content_jsonb,
        p_media_type      => v_obj.media_type,
        p_origin_jsonb    => v_origin,
        p_captured_at     => COALESCE(p_captured_at, v_obj.source_time, v_obj.capture_time),
        p_retention_class => v_obj.retention_class,
        p_sensitivity     => v_obj.sensitivity);

    v_inputs := jsonb_build_array(jsonb_build_object(
        'kind',          'source_object',
        'object_id',     v_obj.object_id,
        'content_hash',  v_hash_hex,
        'byte_length',   v_obj.byte_length,
        'adapter',       v_adapter_name));

    INSERT INTO malu$derivation_ledger
        (derived_object_type, derived_object_id, parser_name,
         inputs_jsonb, inputs_hash)
    VALUES
        ('source_package', v_package_id, 'source_object_promote',
         v_inputs,
         encode(public.digest(v_inputs::text::bytea, 'sha256'), 'hex'))
    RETURNING derivation_id INTO v_ledger_id;

    PERFORM audit_event('source_object_promote', 'malu$source_object', v_obj.object_id,
        jsonb_build_object(
            'source_package_id', v_package_id,
            'derivation_id',     v_ledger_id,
            'source_type',       p_source_type,
            'content_hash',      v_hash_hex),
        NULL);

    RETURN v_package_id;
END;
$body$;
REVOKE EXECUTE ON FUNCTION source_object_promote_to_source_package(bigint, text, bytea, text, jsonb, jsonb, timestamptz) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION source_object_promote_to_source_package(bigint, text, bytea, text, jsonb, jsonb, timestamptz) TO
    maludb_memory_admin, maludb_memory_executor;
