-- =====================================================================
-- maludb_core 0.63.0 -> 0.64.0  (v3.1 Stage I — V3-SECRET-02)
--
-- Adds the C-backed external secret resolver. Replaces the
-- feature_not_supported stub in __secret_resolve with a call into
-- maludb_secret_resolve_external for file:// and https:// refs.
--
-- Security posture:
--   * file:// URIs must point at a path under a configured allowlist
--     (GUC maludb_core.secret_file_root, default
--     /etc/maludb/secrets:/var/lib/maludb/secrets).
--   * The file must be a regular file (no symlinks, no special files),
--     owned by the postgres OS user, mode 0400 or 0600.
--   * https:// URIs use libcurl with SSL_VERIFYPEER + SSL_VERIFYHOST,
--     no redirect follow, 5s connect / 10s total timeout, 1 MiB max
--     response.
--
-- Apply with:
--   ALTER EXTENSION maludb_core UPDATE TO '0.64.0';
-- =====================================================================

CREATE OR REPLACE FUNCTION maludb_core_version() RETURNS text
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$ SELECT '0.64.0'::text $body$;

-- ---------------------------------------------------------------------
-- 0. Extend malu$secret_use.outcome to include the new C-resolver
--    failure outcome.
-- ---------------------------------------------------------------------
ALTER TABLE malu$secret_use
    DROP CONSTRAINT malu$secret_use_outcome_check;
ALTER TABLE malu$secret_use
    ADD CONSTRAINT malu$secret_use_outcome_check
    CHECK (outcome IN ('resolved',
                       'rejected_retired',
                       'rejected_external_not_available',
                       'rejected_external_failed'));

-- ---------------------------------------------------------------------
-- 1. The new C primitive.
-- ---------------------------------------------------------------------
CREATE FUNCTION maludb_secret_resolve_external(p_uri text)
    RETURNS text
    AS 'MODULE_PATHNAME', 'maludb_secret_resolve_external'
    LANGUAGE C STRICT VOLATILE
    SECURITY DEFINER;
REVOKE EXECUTE ON FUNCTION maludb_secret_resolve_external(text) FROM PUBLIC;
-- maludb_secret_consumer (the same role permitted to call
-- __secret_resolve) is the only audience.
GRANT  EXECUTE ON FUNCTION maludb_secret_resolve_external(text) TO
    maludb_secret_consumer;

-- ---------------------------------------------------------------------
-- 2. Swap the external branch of __secret_resolve to use the C
--    primitive. Inline (pgp_sym_decrypt) path is unchanged.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION __secret_resolve(p_name text)
    RETURNS text
    LANGUAGE plpgsql VOLATILE
    AS $body$
#variable_conflict use_column
DECLARE
    v_secret_id bigint;
    v_vid       bigint;
    v_enc       bytea;
    v_ref       text;
    v_retired   timestamptz;
    v_plain     text;
BEGIN
    SELECT s.secret_id, s.retired_at
      INTO v_secret_id, v_retired
      FROM malu$secret s
     WHERE s.name = p_name;

    IF v_secret_id IS NULL THEN
        PERFORM audit_event('secret_resolve_reject', 'malu$secret', NULL,
            jsonb_build_object('reason','unknown_secret','name',p_name),
            NULL);
        RAISE EXCEPTION 'secret_resolve: secret % not found in schema %', p_name, current_schema()
            USING ERRCODE = 'no_data_found';
    END IF;

    IF v_retired IS NOT NULL THEN
        PERFORM audit_event('secret_resolve_reject', 'malu$secret', v_secret_id,
            jsonb_build_object('reason','secret_retired','name',p_name),
            NULL);
        RAISE EXCEPTION 'secret_resolve: secret % is retired', p_name
            USING ERRCODE = 'object_not_in_prerequisite_state';
    END IF;

    SELECT sv.secret_version_id, sv.value_encrypted, sv.external_ref
      INTO v_vid, v_enc, v_ref
      FROM malu$secret_version sv
     WHERE sv.secret_id  = v_secret_id
       AND sv.retired_at IS NULL
     ORDER BY sv.version DESC
     LIMIT 1;

    IF v_vid IS NULL THEN
        PERFORM audit_event('secret_resolve_reject', 'malu$secret', v_secret_id,
            jsonb_build_object('reason','no_active_version','name',p_name),
            NULL);
        RAISE EXCEPTION 'secret_resolve: no active version for secret %', p_name
            USING ERRCODE = 'object_not_in_prerequisite_state';
    END IF;

    IF v_enc IS NOT NULL THEN
        v_plain := public.pgp_sym_decrypt(v_enc, __secret_master_key_passphrase());

        UPDATE malu$secret_version SET last_used_at = now()
         WHERE secret_version_id = v_vid;

        INSERT INTO malu$secret_use(secret_version_id, outcome)
        VALUES (v_vid, 'resolved');

        PERFORM audit_event('secret_resolve_accept', 'malu$secret', v_secret_id,
            jsonb_build_object('name',p_name,'version_id',v_vid,'mode','inline'),
            NULL);

        RETURN v_plain;
    END IF;

    -- External reference: V3-SECRET-02 ships the C resolver.
    BEGIN
        v_plain := maludb_secret_resolve_external(v_ref);
    EXCEPTION WHEN OTHERS THEN
        INSERT INTO malu$secret_use(secret_version_id, outcome, detail)
        VALUES (v_vid, 'rejected_external_failed', SQLERRM);
        PERFORM audit_event('secret_resolve_reject', 'malu$secret', v_secret_id,
            jsonb_build_object('name',p_name,'version_id',v_vid,'mode','external',
                               'reason','external_resolver_failed','detail',SQLERRM),
            SQLERRM);
        RAISE;
    END;

    UPDATE malu$secret_version SET last_used_at = now()
     WHERE secret_version_id = v_vid;
    INSERT INTO malu$secret_use(secret_version_id, outcome)
    VALUES (v_vid, 'resolved');
    PERFORM audit_event('secret_resolve_accept', 'malu$secret', v_secret_id,
        jsonb_build_object('name',p_name,'version_id',v_vid,'mode','external',
                           'external_ref',v_ref),
        NULL);
    RETURN v_plain;
END;
$body$;

-- Re-apply GRANTs (CREATE OR REPLACE keeps them, but be explicit).
REVOKE EXECUTE ON FUNCTION __secret_resolve(text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION __secret_resolve(text) TO maludb_secret_consumer;
