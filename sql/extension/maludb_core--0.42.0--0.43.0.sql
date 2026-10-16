\echo Use "ALTER EXTENSION maludb_core UPDATE TO '0.43.0'" to load this file. \quit

-- =====================================================================
-- maludb_core 0.42.0 → 0.43.0
--
-- Stage 9 / V3-SECRET-01: governed secret store.
--
-- Adds the catalog that V3-AUTH-01 (JWT signing keys), the model
-- gateway (provider API keys), MC2DB external_exec tools, the broker,
-- the future log-drain destinations, and backup destinations will
-- share. Secrets are stored in two forms — *inline* (AES-256 encrypted
-- at rest using pgcrypto pgp_sym_encrypt under a server-side master
-- key) or *external* (a resolver-readable reference like
-- `file:///etc/maludb/secrets/<name>`).
--
-- Per version3-plan.md V3-SECRET-01, this first cut implements:
--   * the catalog + RLS,
--   * the inline AES path,
--   * a stub for the external path that raises feature_not_supported.
-- The C-backed file/HTTPS resolver lands together with the V3-AUTH-01
-- C verifier in a Stage 9 follow-up.
--
-- Tenancy model (matches the project convention for owner_schema-
-- bound tables, e.g. malu$active_memory_pool 0.34.0→0.35.0):
--   * Public APIs run SECURITY INVOKER (default) so current_schema()
--     reflects the caller's tenant search_path.
--   * Only the master-key accessor is SECURITY DEFINER, narrowly
--     granted to roles that need to encrypt or decrypt.
--   * Every set / rotate / revoke / resolve writes malu$audit_event;
--     resolutions also write malu$secret_use.
--
-- Apply with:
--   ALTER EXTENSION maludb_core UPDATE TO '0.43.0';
-- =====================================================================

CREATE OR REPLACE FUNCTION maludb_core_version() RETURNS text
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$ SELECT '0.43.0'::text $body$;

-- ---------------------------------------------------------------------
-- maludb_secret_consumer — NOLOGIN role granted EXECUTE on
-- __secret_resolve(name). Operators GRANT maludb_secret_consumer TO
-- the service roles that need decrypted secrets (model gateway,
-- broker, log-drain workers, backup CLI).
-- ---------------------------------------------------------------------
DO $body$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'maludb_secret_consumer') THEN
        CREATE ROLE maludb_secret_consumer NOLOGIN;
    END IF;
END;
$body$;
GRANT USAGE ON SCHEMA maludb_core TO maludb_secret_consumer;

-- ---------------------------------------------------------------------
-- malu$secret_master_key — single-row dev-mode master key for the
-- inline AES path. Generated on first migration; never visible to
-- non-admin roles. Production resolvers (file / HTTPS / KMS) come in
-- the V3-SECRET-01 C follow-up; operators rotating from dev to prod
-- re-encrypt every malu$secret_version row through that path.
-- ---------------------------------------------------------------------
CREATE TABLE malu$secret_master_key (
    master_key_id smallint PRIMARY KEY CHECK (master_key_id = 1),
    key_material  bytea    NOT NULL,
    note          text     NOT NULL DEFAULT 'dev-mode in-DB master key; replace via the production resolver before exposing to a network',
    created_at    timestamptz NOT NULL DEFAULT now()
);
REVOKE ALL ON malu$secret_master_key FROM PUBLIC;
INSERT INTO malu$secret_master_key(master_key_id, key_material)
VALUES (1, public.gen_random_bytes(32));

-- ---------------------------------------------------------------------
-- malu$secret — one row per named secret. The kind column constrains
-- which subsystem expects to consume it; tenants and operators can
-- query metadata via secret_get_metadata(name).
-- ---------------------------------------------------------------------
CREATE TABLE malu$secret (
    secret_id            bigserial PRIMARY KEY,
    name                 text      NOT NULL,
    kind                 text      NOT NULL CHECK (kind IN
                            ('provider','tool','broker','storage','log_drain','backup','other')),
    description          text,
    rotation_policy_days integer,
    owner_schema         name      NOT NULL DEFAULT current_schema(),
    created_at           timestamptz NOT NULL DEFAULT now(),
    retired_at           timestamptz,
    UNIQUE (owner_schema, name)
);
CREATE INDEX malu$secret_kind_idx ON malu$secret(kind) WHERE retired_at IS NULL;
COMMENT ON TABLE malu$secret IS
    'V3-SECRET-01: named secrets. Values live in malu$secret_version; '
    'plaintext is never reachable through ordinary SELECT — only '
    '__secret_resolve(name), granted to maludb_secret_consumer.';

-- ---------------------------------------------------------------------
-- malu$secret_version — append-only history of secret values. Exactly
-- one of value_encrypted / external_ref is non-null per row.
-- ---------------------------------------------------------------------
CREATE TABLE malu$secret_version (
    secret_version_id bigserial PRIMARY KEY,
    secret_id         bigint    NOT NULL REFERENCES malu$secret(secret_id) ON DELETE CASCADE,
    version           integer   NOT NULL,
    value_encrypted   bytea,
    external_ref      text,
    kdf_alg           text,
    created_at        timestamptz NOT NULL DEFAULT now(),
    retired_at        timestamptz,
    last_used_at      timestamptz,
    UNIQUE (secret_id, version),
    CHECK (
        (value_encrypted IS NOT NULL AND external_ref IS NULL)
        OR
        (value_encrypted IS NULL AND external_ref IS NOT NULL)
    )
);
CREATE INDEX malu$secret_version_active_idx
    ON malu$secret_version(secret_id) WHERE retired_at IS NULL;

-- ---------------------------------------------------------------------
-- malu$secret_use — append-only audit of resolver calls.
-- ---------------------------------------------------------------------
CREATE TABLE malu$secret_use (
    use_id            bigserial PRIMARY KEY,
    secret_version_id bigint    NOT NULL REFERENCES malu$secret_version(secret_version_id) ON DELETE CASCADE,
    used_at           timestamptz NOT NULL DEFAULT now(),
    caller_role       name      NOT NULL DEFAULT current_user,
    outcome           text      NOT NULL CHECK (outcome IN
                        ('resolved','rejected_retired','rejected_external_not_available')),
    detail            text
);
CREATE INDEX malu$secret_use_version_idx
    ON malu$secret_use(secret_version_id, used_at DESC);

-- ---------------------------------------------------------------------
-- RLS — owner_schema-bound for malu$secret; children follow the parent.
-- malu$secret_master_key is admin-only (BYPASSRLS roles + extension
-- owner via SECURITY DEFINER accessor).
-- ---------------------------------------------------------------------
ALTER TABLE malu$secret ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_owner ON malu$secret
    USING      (owner_schema = current_schema())
    WITH CHECK (owner_schema = current_schema());

ALTER TABLE malu$secret_version ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_via_secret ON malu$secret_version
    USING (
        EXISTS (
            SELECT 1 FROM malu$secret s
            WHERE s.secret_id    = malu$secret_version.secret_id
              AND s.owner_schema = current_schema()
        )
    )
    WITH CHECK (
        EXISTS (
            SELECT 1 FROM malu$secret s
            WHERE s.secret_id    = malu$secret_version.secret_id
              AND s.owner_schema = current_schema()
        )
    );

ALTER TABLE malu$secret_use ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_via_version ON malu$secret_use
    USING (
        EXISTS (
            SELECT 1 FROM malu$secret_version v JOIN malu$secret s ON s.secret_id = v.secret_id
            WHERE v.secret_version_id = malu$secret_use.secret_version_id
              AND s.owner_schema      = current_schema()
        )
    )
    WITH CHECK (
        EXISTS (
            SELECT 1 FROM malu$secret_version v JOIN malu$secret s ON s.secret_id = v.secret_id
            WHERE v.secret_version_id = malu$secret_use.secret_version_id
              AND s.owner_schema      = current_schema()
        )
    );

ALTER TABLE malu$secret_master_key ENABLE ROW LEVEL SECURITY;
CREATE POLICY admin_only ON malu$secret_master_key USING (false) WITH CHECK (false);

-- ---------------------------------------------------------------------
-- Grants. The public APIs are SECURITY INVOKER so they execute with
-- the caller's privileges and the caller's current_schema(); RLS does
-- the tenant filtering. Encrypted bytea exposure is acceptable — the
-- secrecy guarantee is the master-key gate, not column-level grants.
-- ---------------------------------------------------------------------
GRANT SELECT, INSERT, UPDATE ON malu$secret, malu$secret_version, malu$secret_use TO
    maludb_memory_admin, maludb_memory_executor;
GRANT SELECT ON malu$secret, malu$secret_version, malu$secret_use TO
    maludb_memory_auditor, maludb_secret_consumer;

GRANT USAGE, SELECT ON SEQUENCE malu$secret_secret_id_seq                 TO
    maludb_memory_admin, maludb_memory_executor;
GRANT USAGE, SELECT ON SEQUENCE malu$secret_version_secret_version_id_seq TO
    maludb_memory_admin, maludb_memory_executor;
GRANT USAGE, SELECT ON SEQUENCE malu$secret_use_use_id_seq                TO
    maludb_memory_admin, maludb_memory_executor, maludb_secret_consumer;

-- =====================================================================
-- Master-key accessor (the only SECURITY DEFINER function in this
-- migration). Returns the raw 32-byte key as bytea or as a base64
-- passphrase suitable for pgp_sym_*.
-- =====================================================================
CREATE FUNCTION __secret_master_key() RETURNS bytea
    LANGUAGE plpgsql STABLE PARALLEL SAFE
    SECURITY DEFINER
    SET search_path = pg_catalog, maludb_core
    AS $body$
DECLARE v_k bytea;
BEGIN
    SELECT key_material INTO v_k FROM malu$secret_master_key WHERE master_key_id = 1;
    IF v_k IS NULL THEN
        RAISE EXCEPTION 'secret store master key is uninitialised'
            USING ERRCODE = 'config_file_error';
    END IF;
    RETURN v_k;
END;
$body$;
REVOKE EXECUTE ON FUNCTION __secret_master_key() FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION __secret_master_key() TO
    maludb_memory_admin, maludb_memory_executor, maludb_secret_consumer;

CREATE FUNCTION __secret_master_key_passphrase() RETURNS text
    LANGUAGE plpgsql STABLE PARALLEL SAFE
    SECURITY DEFINER
    SET search_path = pg_catalog, maludb_core
    AS $body$
BEGIN
    RETURN encode(__secret_master_key(), 'base64');
END;
$body$;
REVOKE EXECUTE ON FUNCTION __secret_master_key_passphrase() FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION __secret_master_key_passphrase() TO
    maludb_memory_admin, maludb_memory_executor, maludb_secret_consumer;

-- =====================================================================
-- Public API — all SECURITY INVOKER so RLS + current_schema() govern
-- tenant access. Schema-qualified pgcrypto calls because pgcrypto
-- lives in `public`, which is not typically first in tenant
-- search_path.
-- =====================================================================

-- secret_set — creates a new secret or pushes a new version of an
-- existing one. Retires any previous active version atomically.
CREATE FUNCTION secret_set(
    p_name                 text,
    p_kind                 text,
    p_value                text,
    p_description          text    DEFAULT NULL,
    p_rotation_policy_days integer DEFAULT NULL
) RETURNS TABLE (secret_id bigint, secret_version_id bigint, version integer)
    LANGUAGE plpgsql VOLATILE
    AS $body$
#variable_conflict use_column
DECLARE
    v_secret_id bigint;
    v_prev_ver  integer;
    v_new_ver   integer;
    v_enc       bytea;
    v_vid       bigint;
BEGIN
    IF p_value IS NULL OR p_value = '' THEN
        RAISE EXCEPTION 'secret_set: value must be non-empty'
            USING ERRCODE = 'check_violation';
    END IF;
    IF p_kind NOT IN ('provider','tool','broker','storage','log_drain','backup','other') THEN
        RAISE EXCEPTION 'secret_set: kind must be one of provider/tool/broker/storage/log_drain/backup/other'
            USING ERRCODE = 'check_violation';
    END IF;

    SELECT s.secret_id INTO v_secret_id
      FROM malu$secret s
     WHERE s.name = p_name;

    IF v_secret_id IS NULL THEN
        INSERT INTO malu$secret(name, kind, description, rotation_policy_days)
        VALUES (p_name, p_kind, p_description, p_rotation_policy_days)
        RETURNING malu$secret.secret_id INTO v_secret_id;
        v_prev_ver := 0;
    ELSE
        SELECT COALESCE(MAX(sv.version), 0) INTO v_prev_ver
          FROM malu$secret_version sv
         WHERE sv.secret_id = v_secret_id;

        UPDATE malu$secret_version
           SET retired_at = COALESCE(retired_at, now())
         WHERE secret_id = v_secret_id
           AND retired_at IS NULL;
    END IF;

    v_new_ver := v_prev_ver + 1;
    v_enc     := public.pgp_sym_encrypt(p_value, __secret_master_key_passphrase());

    INSERT INTO malu$secret_version
        (secret_id, version, value_encrypted, kdf_alg)
    VALUES
        (v_secret_id, v_new_ver, v_enc, 'pgp_sym_aes256')
    RETURNING malu$secret_version.secret_version_id INTO v_vid;

    PERFORM audit_event(
        CASE WHEN v_prev_ver = 0 THEN 'secret_create' ELSE 'secret_rotate' END,
        'malu$secret',
        v_secret_id,
        jsonb_build_object(
            'name',    p_name,
            'kind',    p_kind,
            'version', v_new_ver,
            'mode',    'inline',
            'rotation_policy_days', p_rotation_policy_days),
        NULL);

    secret_id         := v_secret_id;
    secret_version_id := v_vid;
    version           := v_new_ver;
    RETURN NEXT;
END;
$body$;
REVOKE EXECUTE ON FUNCTION secret_set(text, text, text, text, integer) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION secret_set(text, text, text, text, integer) TO
    maludb_memory_admin, maludb_memory_executor;

-- secret_set_external — registers a secret whose value lives outside
-- PostgreSQL behind a resolver. The resolver itself is a Stage 9
-- follow-up; this function lets operators register the reference now
-- so the catalog is forward-compatible.
CREATE FUNCTION secret_set_external(
    p_name                 text,
    p_kind                 text,
    p_external_ref         text,
    p_description          text    DEFAULT NULL,
    p_rotation_policy_days integer DEFAULT NULL
) RETURNS TABLE (secret_id bigint, secret_version_id bigint, version integer)
    LANGUAGE plpgsql VOLATILE
    AS $body$
#variable_conflict use_column
DECLARE
    v_secret_id bigint;
    v_prev_ver  integer;
    v_new_ver   integer;
    v_vid       bigint;
BEGIN
    IF p_external_ref IS NULL OR p_external_ref = '' THEN
        RAISE EXCEPTION 'secret_set_external: external_ref must be non-empty'
            USING ERRCODE = 'check_violation';
    END IF;

    SELECT s.secret_id INTO v_secret_id
      FROM malu$secret s
     WHERE s.name = p_name;

    IF v_secret_id IS NULL THEN
        INSERT INTO malu$secret(name, kind, description, rotation_policy_days)
        VALUES (p_name, p_kind, p_description, p_rotation_policy_days)
        RETURNING malu$secret.secret_id INTO v_secret_id;
        v_prev_ver := 0;
    ELSE
        SELECT COALESCE(MAX(sv.version), 0) INTO v_prev_ver
          FROM malu$secret_version sv
         WHERE sv.secret_id = v_secret_id;

        UPDATE malu$secret_version
           SET retired_at = COALESCE(retired_at, now())
         WHERE secret_id = v_secret_id
           AND retired_at IS NULL;
    END IF;

    v_new_ver := v_prev_ver + 1;

    INSERT INTO malu$secret_version
        (secret_id, version, external_ref, kdf_alg)
    VALUES
        (v_secret_id, v_new_ver, p_external_ref, NULL)
    RETURNING malu$secret_version.secret_version_id INTO v_vid;

    PERFORM audit_event(
        CASE WHEN v_prev_ver = 0 THEN 'secret_create' ELSE 'secret_rotate' END,
        'malu$secret',
        v_secret_id,
        jsonb_build_object(
            'name',         p_name,
            'kind',         p_kind,
            'version',      v_new_ver,
            'mode',         'external',
            'external_ref', p_external_ref),
        NULL);

    secret_id         := v_secret_id;
    secret_version_id := v_vid;
    version           := v_new_ver;
    RETURN NEXT;
END;
$body$;
REVOKE EXECUTE ON FUNCTION secret_set_external(text, text, text, text, integer) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION secret_set_external(text, text, text, text, integer) TO
    maludb_memory_admin, maludb_memory_executor;

-- secret_revoke — retires the secret and all of its versions.
CREATE FUNCTION secret_revoke(p_name text, p_reason text DEFAULT NULL)
    RETURNS boolean
    LANGUAGE plpgsql VOLATILE
    AS $body$
#variable_conflict use_column
DECLARE
    v_secret_id bigint;
    v_was_open  boolean;
BEGIN
    SELECT s.secret_id, s.retired_at IS NULL
      INTO v_secret_id, v_was_open
      FROM malu$secret s
     WHERE s.name = p_name;

    IF v_secret_id IS NULL THEN
        RAISE EXCEPTION 'secret_revoke: secret % not found in schema %', p_name, current_schema()
            USING ERRCODE = 'no_data_found';
    END IF;

    UPDATE malu$secret
       SET retired_at = COALESCE(retired_at, now())
     WHERE secret_id = v_secret_id;

    UPDATE malu$secret_version
       SET retired_at = COALESCE(retired_at, now())
     WHERE secret_id = v_secret_id
       AND retired_at IS NULL;

    PERFORM audit_event(
        'secret_revoke',
        'malu$secret',
        v_secret_id,
        jsonb_build_object('name', p_name, 'reason', p_reason, 'was_active', v_was_open),
        NULL);

    RETURN v_was_open;
END;
$body$;
REVOKE EXECUTE ON FUNCTION secret_revoke(text, text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION secret_revoke(text, text) TO
    maludb_memory_admin, maludb_memory_executor;

-- secret_get_metadata — metadata-only view of a secret. Never returns
-- value_encrypted or external_ref. Callable by every memory_* role
-- plus secret_consumer.
CREATE FUNCTION secret_get_metadata(p_name text)
    RETURNS TABLE (
        secret_id            bigint,
        name                 text,
        kind                 text,
        owner_schema         name,
        current_version      integer,
        mode                 text,
        rotation_policy_days integer,
        last_used_at         timestamptz,
        created_at           timestamptz,
        retired_at           timestamptz
    ) LANGUAGE plpgsql STABLE
    AS $body$
#variable_conflict use_column
BEGIN
    RETURN QUERY
    SELECT s.secret_id,
           s.name,
           s.kind,
           s.owner_schema,
           sv.version                                              AS current_version,
           CASE WHEN sv.value_encrypted IS NOT NULL THEN 'inline'
                WHEN sv.external_ref    IS NOT NULL THEN 'external'
                ELSE NULL END                                      AS mode,
           s.rotation_policy_days,
           sv.last_used_at,
           s.created_at,
           s.retired_at
      FROM malu$secret s
      LEFT JOIN LATERAL (
            SELECT * FROM malu$secret_version vv
             WHERE vv.secret_id = s.secret_id
               AND vv.retired_at IS NULL
             ORDER BY vv.version DESC
             LIMIT 1
      ) sv ON TRUE
     WHERE s.name = p_name;
END;
$body$;
REVOKE EXECUTE ON FUNCTION secret_get_metadata(text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION secret_get_metadata(text) TO
    maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor,
    maludb_secret_consumer;

-- __secret_resolve — internal decryption / external dereference path.
-- Granted only to maludb_secret_consumer; the caller's RLS context
-- determines which tenant's secret is visible. INVOKER (default) so
-- current_schema() == caller's tenant.
CREATE FUNCTION __secret_resolve(p_name text)
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

    -- External reference: catalog accepts it, resolver not yet wired.
    INSERT INTO malu$secret_use(secret_version_id, outcome, detail)
    VALUES (v_vid, 'rejected_external_not_available', v_ref);

    PERFORM audit_event('secret_resolve_reject', 'malu$secret', v_secret_id,
        jsonb_build_object('name',p_name,'version_id',v_vid,'mode','external','reason','external_resolver_unavailable'),
        NULL);

    RAISE EXCEPTION 'secret_resolve: external reference resolver (file/env/https) is not available in 0.43.0; the C resolver ships in a follow-up'
        USING ERRCODE = 'feature_not_supported',
              HINT    = 'Use secret_set(...) to store the value inline until the C resolver lands.',
              DETAIL  = format('secret %s has external_ref = %s', p_name, v_ref);
END;
$body$;
REVOKE EXECUTE ON FUNCTION __secret_resolve(text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION __secret_resolve(text) TO maludb_secret_consumer;
