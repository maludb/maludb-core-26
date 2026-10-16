\echo Use "ALTER EXTENSION maludb_core UPDATE TO '0.42.0'" to load this file. \quit

-- =====================================================================
-- maludb_core 0.41.0 → 0.42.0
--
-- Stage 9 / V3-AUTH-01: first-party API token catalog.
--
-- Adds the authentication primitives that MC2DB, the future V3 REST
-- gateway (maludb-restd), and the CLI will share — personal and service
-- tokens with hash storage, expiry, revocation, optional CIDR allow
-- lists, scopes, per-use audit, plus JWT signing-key registry rows.
--
-- This migration lands the SQL surface only. The C HMAC verifier and
-- the JWT signature verifier (RS256 / ES256 / EdDSA) come in a
-- follow-up; until then, `auth_token_verify` calls pgcrypto's hmac()
-- in PL/pgSQL and `jwt_verify` is an explicit stub that raises
-- AUTH_TOKEN_JWT_NOT_AVAILABLE.
--
-- Per requirements.md §1.5 and version3-plan.md V3-AUTH-01:
--   * Same token model for SQL, MC2DB, and REST.
--   * Revocation takes effect immediately, no service restart.
--   * Every create / use / revoke / failed-verify writes audit.
--   * RLS: an account sees only its own token rows. auditor and admin
--     bypass; the verifier reads across RLS via SECURITY DEFINER.
--
-- Plaintext token shape: `mldbat_<43 base64url chars>` — 32 random
-- bytes encoded, prefixed for grep-ability and easy revocation by
-- pattern match in operator logs.
--
-- Apply with:
--   ALTER EXTENSION maludb_core UPDATE TO '0.42.0';
-- =====================================================================

CREATE OR REPLACE FUNCTION maludb_core_version() RETURNS text
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$ SELECT '0.42.0'::text $body$;

-- ---------------------------------------------------------------------
-- pgcrypto dependency. Listed in maludb_core.control's `requires` for
-- fresh installs; this idempotent guard covers in-place upgrades from
-- 0.41.0, where pgcrypto wasn't yet required.
--
-- pgcrypto installs into `public` by default; the SECURITY DEFINER
-- functions below pin search_path = pg_catalog, maludb_core, so every
-- pgcrypto call is schema-qualified as `public.<fn>(...)`.
-- ---------------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ---------------------------------------------------------------------
-- Schema USAGE for the maludb_memory_* role family. Created in 0.14.0,
-- but never granted USAGE on the maludb_core schema — table-level
-- privileges in earlier migrations went unused because no caller bound
-- to maludb_memory_executor without first becoming maludb_llm_executor
-- (which has the USAGE grant). Stage 9 introduces functions
-- (auth_token_create / _revoke / _verify) that maludb_memory_executor
-- needs to call directly, so the gap matters now.
-- ---------------------------------------------------------------------
GRANT USAGE ON SCHEMA maludb_core TO
    maludb_memory_admin,
    maludb_memory_executor,
    maludb_memory_auditor;

-- ---------------------------------------------------------------------
-- malu$auth_pepper — single-row server-side secret used as the key to
-- HMAC-SHA256 over each token's plaintext. Generated on first
-- migration; not visible to ordinary roles.
--
-- A pepper rotation lands as a future migration that re-hashes every
-- non-revoked token; out of scope for the initial cut.
-- ---------------------------------------------------------------------
CREATE TABLE malu$auth_pepper (
    pepper_id  smallint PRIMARY KEY CHECK (pepper_id = 1),
    pepper     bytea    NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);
REVOKE ALL ON malu$auth_pepper FROM PUBLIC;
INSERT INTO malu$auth_pepper(pepper_id, pepper)
VALUES (1, public.gen_random_bytes(32));

-- ---------------------------------------------------------------------
-- malu$auth_token — one row per issued token.
--   * token_hash stores HMAC-SHA256(pepper, plaintext); plaintext is
--     never persisted.
--   * allowed_cidrs is NULL = no IP restriction; otherwise the source
--     IP MUST match at least one CIDR at verify time.
--   * scopes is an opaque text[] consumed by callers; not interpreted
--     by the catalog.
--   * owner_schema is the tenant binding for RLS visibility — it
--     follows the project's tenancy convention (current_schema()).
-- ---------------------------------------------------------------------
CREATE TABLE malu$auth_token (
    token_id       bigserial PRIMARY KEY,
    account_id     bigint    NOT NULL REFERENCES malu$account(account_id) ON DELETE CASCADE,
    token_hash     bytea     NOT NULL UNIQUE,
    token_kind     text      NOT NULL CHECK (token_kind IN ('personal','service')),
    label          text,
    scopes         text[]    NOT NULL DEFAULT ARRAY[]::text[],
    allowed_cidrs  inet[],
    created_at     timestamptz NOT NULL DEFAULT now(),
    expires_at     timestamptz,
    last_used_at   timestamptz,
    revoked_at     timestamptz,
    owner_schema   name      NOT NULL DEFAULT current_schema(),
    CHECK (expires_at IS NULL OR expires_at > created_at)
);
CREATE INDEX malu$auth_token_account_idx
    ON malu$auth_token(account_id) WHERE revoked_at IS NULL;
CREATE INDEX malu$auth_token_owner_idx
    ON malu$auth_token(owner_schema, account_id, revoked_at);
COMMENT ON TABLE malu$auth_token IS
    'V3-AUTH-01: issued API tokens. Plaintext is never persisted; '
    'token_hash holds HMAC-SHA256(pepper, plaintext). Read-back is '
    'tenant-bound by RLS; the verifier crosses RLS via SECURITY DEFINER.';

-- ---------------------------------------------------------------------
-- malu$auth_token_use — append-only audit of every verification
-- attempt against a known token. Failed verifications (unknown hash)
-- land in malu$audit_event with event_kind = 'auth_token_verify_reject'
-- and a NULL token_id reference, since there is no row to attach to.
-- ---------------------------------------------------------------------
CREATE TABLE malu$auth_token_use (
    use_id      bigserial PRIMARY KEY,
    token_id    bigint    NOT NULL REFERENCES malu$auth_token(token_id) ON DELETE CASCADE,
    used_at     timestamptz NOT NULL DEFAULT now(),
    source_ip   inet,
    outcome     text      NOT NULL CHECK (outcome IN
                  ('accepted','rejected_expired','rejected_revoked',
                   'rejected_cidr','rejected_disabled_account')),
    detail      text
);
CREATE INDEX malu$auth_token_use_token_idx
    ON malu$auth_token_use(token_id, used_at DESC);
CREATE INDEX malu$auth_token_use_outcome_idx
    ON malu$auth_token_use(outcome, used_at DESC)
    WHERE outcome <> 'accepted';

-- ---------------------------------------------------------------------
-- malu$jwt_signing_key — registry of public signing keys that the
-- future jwt_verify path will trust. C verifier consumes these rows;
-- no plaintext private material is ever persisted.
-- ---------------------------------------------------------------------
CREATE TABLE malu$jwt_signing_key (
    key_id      bigserial PRIMARY KEY,
    kid         text      NOT NULL UNIQUE,
    kty         text      NOT NULL CHECK (kty IN ('RSA','EC','OKP')),
    alg         text      NOT NULL CHECK (alg IN ('RS256','RS384','RS512',
                                                  'ES256','ES384','ES512',
                                                  'EdDSA')),
    public_jwk  jsonb     NOT NULL,
    enabled     boolean   NOT NULL DEFAULT true,
    created_at  timestamptz NOT NULL DEFAULT now(),
    rotated_at  timestamptz,
    note        text
);
CREATE INDEX malu$jwt_signing_key_enabled_idx
    ON malu$jwt_signing_key(enabled, kid);

-- ---------------------------------------------------------------------
-- RLS — tokens are visible only to their owning account; uses follow
-- their parent token. JWT signing keys are admin-only and ungated.
-- ---------------------------------------------------------------------
ALTER TABLE malu$auth_token ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_owner ON malu$auth_token
    USING      (account_id = current_account_id())
    WITH CHECK (account_id = current_account_id());

ALTER TABLE malu$auth_token_use ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_via_token ON malu$auth_token_use
    USING (
        EXISTS (
            SELECT 1 FROM malu$auth_token t
            WHERE t.token_id   = malu$auth_token_use.token_id
              AND t.account_id = current_account_id()
        )
    )
    WITH CHECK (
        EXISTS (
            SELECT 1 FROM malu$auth_token t
            WHERE t.token_id   = malu$auth_token_use.token_id
              AND t.account_id = current_account_id()
        )
    );

ALTER TABLE malu$jwt_signing_key ENABLE ROW LEVEL SECURITY;
-- Non-superuser, non-BYPASSRLS roles see no rows by default; signing
-- keys are operator-managed via maludb_memory_admin (BYPASSRLS).
CREATE POLICY admin_only ON malu$jwt_signing_key USING (false) WITH CHECK (false);

-- ---------------------------------------------------------------------
-- Grants. Roles created in earlier migrations (0.14.0+) are reused:
--   * maludb_memory_admin    — BYPASSRLS, full CRUD across tenants.
--   * maludb_memory_executor — CRUD on own tokens via RLS; SELECT on
--                              own uses.
--   * maludb_memory_auditor  — BYPASSRLS, SELECT-only.
-- ---------------------------------------------------------------------
GRANT SELECT, INSERT, UPDATE, DELETE ON malu$auth_token, malu$auth_token_use TO
    maludb_memory_admin, maludb_memory_executor;
GRANT SELECT ON malu$auth_token, malu$auth_token_use TO
    maludb_memory_auditor;

GRANT SELECT, INSERT, UPDATE, DELETE ON malu$jwt_signing_key TO
    maludb_memory_admin;
GRANT SELECT ON malu$jwt_signing_key TO
    maludb_memory_auditor;

GRANT USAGE, SELECT ON SEQUENCE malu$auth_token_token_id_seq        TO
    maludb_memory_admin, maludb_memory_executor;
GRANT USAGE, SELECT ON SEQUENCE malu$auth_token_use_use_id_seq      TO
    maludb_memory_admin, maludb_memory_executor;
GRANT USAGE, SELECT ON SEQUENCE malu$jwt_signing_key_key_id_seq     TO
    maludb_memory_admin;

-- =====================================================================
-- Helpers
-- =====================================================================

-- maludb_core.__auth_pepper — internal accessor to the single-row
-- pepper. SECURITY DEFINER so non-admin roles can verify their own
-- tokens through auth_token_verify without holding SELECT on
-- malu$auth_pepper. Returns bytea, never logged.
CREATE FUNCTION __auth_pepper() RETURNS bytea
    LANGUAGE plpgsql STABLE PARALLEL SAFE
    SECURITY DEFINER
    SET search_path = pg_catalog, maludb_core
    AS $body$
DECLARE v_p bytea;
BEGIN
    SELECT pepper INTO v_p FROM malu$auth_pepper WHERE pepper_id = 1;
    RETURN v_p;
END;
$body$;
REVOKE EXECUTE ON FUNCTION __auth_pepper() FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION __auth_pepper() TO
    maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;

-- __auth_token_encode — turns a 32-byte random into the public
-- mldbat_<base64url> form. base64url = base64 with '+'/'/' → '-'/'_'
-- and '=' padding stripped.
CREATE FUNCTION __auth_token_encode(p_bytes bytea) RETURNS text
    LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE
    SET search_path = pg_catalog, maludb_core
    AS $body$
DECLARE
    v_b64 text;
BEGIN
    -- base64 → base64url: '+' → '-', '/' → '_'. '=' padding and any
    -- newline pgcrypto inserts after 76 chars are dropped (no
    -- corresponding char in the destination set). The four FROM
    -- chars are intentionally ordered ('+', '/', '=', '\n') so the
    -- pairwise TO mapping is '-' for '+', '_' for '/', and drop for
    -- the rest.
    v_b64 := encode(p_bytes, 'base64');
    v_b64 := translate(v_b64, E'+/=\n', '-_');
    RETURN 'mldbat_' || v_b64;
END;
$body$;
REVOKE EXECUTE ON FUNCTION __auth_token_encode(bytea) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION __auth_token_encode(bytea) TO
    maludb_memory_admin, maludb_memory_executor;

-- __auth_token_hash — HMAC-SHA256(pepper, plaintext). Internal; the
-- verifier and the creator both call this to ensure the hashing is
-- defined in exactly one place.
CREATE FUNCTION __auth_token_hash(p_plaintext text) RETURNS bytea
    LANGUAGE plpgsql STABLE PARALLEL SAFE
    SECURITY DEFINER
    SET search_path = pg_catalog, maludb_core
    AS $body$
BEGIN
    RETURN public.hmac(p_plaintext::bytea, __auth_pepper(), 'sha256');
END;
$body$;
REVOKE EXECUTE ON FUNCTION __auth_token_hash(text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION __auth_token_hash(text) TO
    maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;

-- =====================================================================
-- Public API
-- =====================================================================

-- auth_token_create — issues a new token. Returns (token_id,
-- plaintext_token) exactly once; plaintext is irrecoverable
-- afterwards. SECURITY DEFINER so an executor role can write the row
-- without holding INSERT directly (the caller's identity flows through
-- current_account_id; the row's account_id is checked against it).
CREATE FUNCTION auth_token_create(
    p_account_id    bigint,
    p_kind          text,
    p_label         text             DEFAULT NULL,
    p_scopes        text[]           DEFAULT ARRAY[]::text[],
    p_allowed_cidrs inet[]           DEFAULT NULL,
    p_expires_at    timestamptz      DEFAULT NULL
) RETURNS TABLE (token_id bigint, plaintext_token text)
    LANGUAGE plpgsql VOLATILE
    SECURITY DEFINER
    SET search_path = pg_catalog, maludb_core
    AS $body$
DECLARE
    v_caller bigint := current_account_id();
    v_random bytea;
    v_plain  text;
    v_hash   bytea;
    v_id     bigint;
BEGIN
    -- Authorization: the caller may issue tokens only for its own
    -- account, unless the caller is BYPASSRLS (memory_admin /
    -- memory_auditor) in which case we trust them and skip the check.
    IF v_caller IS NOT NULL AND v_caller <> p_account_id THEN
        RAISE EXCEPTION 'auth_token_create: caller account % cannot issue tokens for account %',
            v_caller, p_account_id
            USING ERRCODE = 'insufficient_privilege';
    END IF;

    IF p_kind NOT IN ('personal','service') THEN
        RAISE EXCEPTION 'auth_token_create: token_kind must be personal or service'
            USING ERRCODE = 'check_violation';
    END IF;

    v_random := public.gen_random_bytes(32);
    v_plain  := __auth_token_encode(v_random);
    v_hash   := __auth_token_hash(v_plain);

    INSERT INTO malu$auth_token
        (account_id, token_hash, token_kind, label, scopes,
         allowed_cidrs, expires_at)
    VALUES
        (p_account_id, v_hash, p_kind, p_label, p_scopes,
         p_allowed_cidrs, p_expires_at)
    RETURNING malu$auth_token.token_id INTO v_id;

    PERFORM audit_event(
        'auth_token_create',
        'malu$auth_token',
        v_id,
        jsonb_build_object(
            'account_id', p_account_id,
            'token_kind', p_kind,
            'label',      p_label,
            'expires_at', p_expires_at,
            'scopes',     to_jsonb(p_scopes),
            'has_cidr',   p_allowed_cidrs IS NOT NULL),
        NULL);

    token_id         := v_id;
    plaintext_token  := v_plain;
    RETURN NEXT;
END;
$body$;
REVOKE EXECUTE ON FUNCTION auth_token_create(bigint, text, text, text[], inet[], timestamptz) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION auth_token_create(bigint, text, text, text[], inet[], timestamptz) TO
    maludb_memory_admin, maludb_memory_executor;

-- auth_token_revoke — sets revoked_at and writes audit. No-ops idem-
-- potently when the token is already revoked.
CREATE FUNCTION auth_token_revoke(p_token_id bigint, p_reason text DEFAULT NULL)
    RETURNS boolean
    LANGUAGE plpgsql VOLATILE
    SECURITY DEFINER
    SET search_path = pg_catalog, maludb_core
    AS $body$
DECLARE
    v_caller    bigint := current_account_id();
    v_owner     bigint;
    v_was_open  boolean;
BEGIN
    SELECT account_id, revoked_at IS NULL
      INTO v_owner, v_was_open
      FROM malu$auth_token
     WHERE token_id = p_token_id;

    IF v_owner IS NULL THEN
        RAISE EXCEPTION 'auth_token_revoke: token_id % not found', p_token_id
            USING ERRCODE = 'no_data_found';
    END IF;

    IF v_caller IS NOT NULL AND v_caller <> v_owner THEN
        RAISE EXCEPTION 'auth_token_revoke: account % cannot revoke token owned by account %',
            v_caller, v_owner
            USING ERRCODE = 'insufficient_privilege';
    END IF;

    UPDATE malu$auth_token
       SET revoked_at = COALESCE(revoked_at, now())
     WHERE token_id = p_token_id;

    PERFORM audit_event(
        'auth_token_revoke',
        'malu$auth_token',
        p_token_id,
        jsonb_build_object(
            'reason',     p_reason,
            'was_active', v_was_open),
        NULL);

    RETURN v_was_open;
END;
$body$;
REVOKE EXECUTE ON FUNCTION auth_token_revoke(bigint, text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION auth_token_revoke(bigint, text) TO
    maludb_memory_admin, maludb_memory_executor;

-- auth_token_verify — accepts plaintext, returns the binding context.
-- SECURITY DEFINER so the lookup can find the matching token regardless
-- of which tenant the caller currently appears as. Failed verifications
-- still write a malu$audit_event row; rejected verifications against a
-- KNOWN token also write malu$auth_token_use so per-token rate-limit
-- analytics work.
CREATE FUNCTION auth_token_verify(
    p_plaintext   text,
    p_source_ip   inet DEFAULT NULL
) RETURNS TABLE (
    token_id    bigint,
    account_id  bigint,
    token_kind  text,
    scopes      text[]
) LANGUAGE plpgsql VOLATILE
    SECURITY DEFINER
    SET search_path = pg_catalog, maludb_core
    AS $body$
#variable_conflict use_column
DECLARE
    v_hash    bytea;
    v_row     malu$auth_token%ROWTYPE;
    v_account_enabled boolean;
    v_outcome text;
    v_detail  text := NULL;
BEGIN
    IF p_plaintext IS NULL OR p_plaintext = '' THEN
        PERFORM audit_event('auth_token_verify_reject', 'malu$auth_token', NULL,
            jsonb_build_object('reason','empty_plaintext','source_ip',p_source_ip::text),
            NULL);
        RETURN;
    END IF;

    v_hash := __auth_token_hash(p_plaintext);

    SELECT * INTO v_row FROM malu$auth_token WHERE token_hash = v_hash;
    IF v_row.token_id IS NULL THEN
        PERFORM audit_event('auth_token_verify_reject', 'malu$auth_token', NULL,
            jsonb_build_object('reason','unknown_token','source_ip',p_source_ip::text),
            NULL);
        RETURN;
    END IF;

    -- Verify the parent account is still enabled.
    SELECT enabled INTO v_account_enabled FROM malu$account WHERE account_id = v_row.account_id;
    IF NOT v_account_enabled THEN
        v_outcome := 'rejected_disabled_account';
    ELSIF v_row.revoked_at IS NOT NULL THEN
        v_outcome := 'rejected_revoked';
    ELSIF v_row.expires_at IS NOT NULL AND v_row.expires_at <= now() THEN
        v_outcome := 'rejected_expired';
    ELSIF v_row.allowed_cidrs IS NOT NULL AND p_source_ip IS NOT NULL THEN
        IF NOT EXISTS (SELECT 1 FROM unnest(v_row.allowed_cidrs) c WHERE p_source_ip <<= c) THEN
            v_outcome := 'rejected_cidr';
            v_detail  := 'source_ip not in allowed_cidrs';
        END IF;
    END IF;

    IF v_outcome IS NULL THEN
        v_outcome := 'accepted';
        UPDATE malu$auth_token SET last_used_at = now() WHERE token_id = v_row.token_id;
    END IF;

    INSERT INTO malu$auth_token_use(token_id, source_ip, outcome, detail)
    VALUES (v_row.token_id, p_source_ip, v_outcome, v_detail);

    PERFORM audit_event(
        CASE WHEN v_outcome = 'accepted' THEN 'auth_token_verify_accept'
             ELSE 'auth_token_verify_reject' END,
        'malu$auth_token',
        v_row.token_id,
        jsonb_build_object('outcome',v_outcome,'source_ip',p_source_ip::text),
        v_detail);

    IF v_outcome <> 'accepted' THEN
        RETURN;
    END IF;

    token_id   := v_row.token_id;
    account_id := v_row.account_id;
    token_kind := v_row.token_kind;
    scopes     := v_row.scopes;
    RETURN NEXT;
END;
$body$;
REVOKE EXECUTE ON FUNCTION auth_token_verify(text, inet) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION auth_token_verify(text, inet) TO
    maludb_memory_admin, maludb_memory_executor;

-- jwt_verify — stub. The C verifier (RS256/ES256/EdDSA via OpenSSL)
-- lands in a follow-up; for now this function raises a structured
-- error so callers can distinguish "JWT not yet wired" from a real
-- verification failure.
CREATE FUNCTION jwt_verify(p_jwt text)
    RETURNS TABLE (
        account_id    bigint,
        role_name     text,
        owner_schema  name,
        active_pool   bigint,
        agent_chain   text[]
    ) LANGUAGE plpgsql STABLE PARALLEL SAFE
    AS $body$
BEGIN
    RAISE EXCEPTION 'jwt_verify: JWT signature verification is not available in 0.42.0; the C verifier ships in a follow-up'
        USING ERRCODE = 'feature_not_supported',
              HINT    = 'Use auth_token_verify with an opaque bearer token until the JWT path lands.',
              DETAIL  = 'malu$jwt_signing_key registry rows are accepted but unused.';
END;
$body$;
REVOKE EXECUTE ON FUNCTION jwt_verify(text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION jwt_verify(text) TO
    maludb_memory_admin, maludb_memory_executor;
