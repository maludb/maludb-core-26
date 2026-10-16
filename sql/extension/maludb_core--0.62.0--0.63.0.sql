-- =====================================================================
-- maludb_core 0.62.0 -> 0.63.0  (v3.1 Stage H — V3-AUTH-02)
--
-- Replaces the PL/pgSQL + pgcrypto HMAC on the token-verify hot path
-- with a C function (constant-time, no PL/pgSQL function-call
-- overhead) and replaces the jwt_verify stub with a C verifier that
-- implements HS256 fully. RS256 / RS384 / RS512 / ES256 / ES384 /
-- ES512 / EdDSA still raise feature_not_supported, but now via the C
-- dispatcher rather than a plain stub — V3-AUTH-03 plugs in the
-- asymmetric branches without changing the SQL surface.
--
-- Apply with:
--   ALTER EXTENSION maludb_core UPDATE TO '0.63.0';
-- =====================================================================

CREATE OR REPLACE FUNCTION maludb_core_version() RETURNS text
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$ SELECT '0.63.0'::text $body$;

-- ---------------------------------------------------------------------
-- 0. Extend malu$jwt_signing_key to accept HS256 / oct (V3-AUTH-02
--    ships a real HS256 verifier; the symmetric key needs a row in
--    this table).
-- ---------------------------------------------------------------------
ALTER TABLE malu$jwt_signing_key
    DROP CONSTRAINT malu$jwt_signing_key_alg_check,
    DROP CONSTRAINT malu$jwt_signing_key_kty_check;
ALTER TABLE malu$jwt_signing_key
    ADD CONSTRAINT malu$jwt_signing_key_alg_check
    CHECK (alg IN ('HS256',
                   'RS256','RS384','RS512',
                   'ES256','ES384','ES512',
                   'EdDSA')),
    ADD CONSTRAINT malu$jwt_signing_key_kty_check
    CHECK (kty IN ('RSA','EC','OKP','oct'));

-- ---------------------------------------------------------------------
-- 1. C primitives.
-- ---------------------------------------------------------------------
CREATE FUNCTION maludb_hmac_sha256(p_key bytea, p_data bytea)
    RETURNS bytea
    AS 'MODULE_PATHNAME', 'maludb_hmac_sha256'
    LANGUAGE C STRICT IMMUTABLE PARALLEL SAFE;
REVOKE EXECUTE ON FUNCTION maludb_hmac_sha256(bytea, bytea) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION maludb_hmac_sha256(bytea, bytea) TO
    maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;

-- ---------------------------------------------------------------------
-- 2. Swap __auth_token_hash to use the C HMAC primitive. Same input,
--    same output, same RLS / GRANT surface; only the body changes.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION __auth_token_hash(p_plaintext text) RETURNS bytea
    LANGUAGE plpgsql STABLE PARALLEL SAFE
    SECURITY DEFINER
    SET search_path = pg_catalog, maludb_core
    AS $body$
BEGIN
    RETURN maludb_hmac_sha256(__auth_pepper(), p_plaintext::bytea);
END;
$body$;

-- ---------------------------------------------------------------------
-- 3. jwt_verify is now a thin wrapper over the C dispatcher. The C
--    function returns the same TABLE shape jwt_verify originally
--    advertised.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION jwt_verify(p_jwt text)
    RETURNS TABLE (
        account_id   bigint,
        role_name    text,
        owner_schema name,
        active_pool  bigint,
        agent_chain  text[]
    )
    AS 'MODULE_PATHNAME', 'maludb_jwt_verify'
    LANGUAGE C STABLE STRICT PARALLEL SAFE;
REVOKE EXECUTE ON FUNCTION jwt_verify(text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION jwt_verify(text) TO
    maludb_memory_admin, maludb_memory_executor;
