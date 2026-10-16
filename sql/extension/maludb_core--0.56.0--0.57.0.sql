\echo Use "ALTER EXTENSION maludb_core UPDATE TO '0.57.0'" to load this file. \quit

-- =====================================================================
-- maludb_core 0.56.0 → 0.57.0
--
-- Stage 15 / V3-ENV-01: preview environment catalog.
--
-- Records the state of self-hosted preview databases — name, base
-- migration, current migration, seed policy, anonymizer reference,
-- and per-seed redaction rules. The CLI workflow that drives
-- create / destroy / promote-check / migration-diff is a Stage 15
-- follow-up; this catalog gives that workflow a durable home so it
-- can ship without a new migration.
--
-- Apply with:
--   ALTER EXTENSION maludb_core UPDATE TO '0.57.0';
-- =====================================================================

CREATE OR REPLACE FUNCTION maludb_core_version() RETURNS text
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$ SELECT '0.57.0'::text $body$;

-- ---------------------------------------------------------------------
-- malu$preview_env
-- ---------------------------------------------------------------------
CREATE TABLE malu$preview_env (
    env_id            bigserial PRIMARY KEY,
    name              text       NOT NULL,
    base_migration    text       NOT NULL,
    current_migration text,
    seed_policy       jsonb      NOT NULL DEFAULT '{}'::jsonb,
    anonymizer_ref    text,
    description       text,
    owner_schema      name       NOT NULL DEFAULT current_schema(),
    created_at        timestamptz NOT NULL DEFAULT now(),
    retired_at        timestamptz,
    UNIQUE (owner_schema, name)
);
CREATE INDEX malu$preview_env_owner_idx
    ON malu$preview_env(owner_schema) WHERE retired_at IS NULL;

CREATE TABLE malu$preview_env_seed (
    seed_id          bigserial PRIMARY KEY,
    env_id           bigint     NOT NULL REFERENCES malu$preview_env(env_id) ON DELETE CASCADE,
    source_kind      text       NOT NULL CHECK (source_kind IN
                        ('sql_file','json_blob','dump','table_subset','custom')),
    source_ref       text       NOT NULL,
    redaction_rules  jsonb      NOT NULL DEFAULT '[]'::jsonb,
    applied_at       timestamptz,
    created_at       timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX malu$preview_env_seed_env_idx
    ON malu$preview_env_seed(env_id, created_at DESC);

ALTER TABLE malu$preview_env ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_owner ON malu$preview_env
    USING      (owner_schema = current_schema())
    WITH CHECK (owner_schema = current_schema());

ALTER TABLE malu$preview_env_seed ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_via_env ON malu$preview_env_seed
    USING (
        EXISTS (SELECT 1 FROM malu$preview_env e
                WHERE e.env_id = malu$preview_env_seed.env_id
                  AND e.owner_schema = current_schema()))
    WITH CHECK (
        EXISTS (SELECT 1 FROM malu$preview_env e
                WHERE e.env_id = malu$preview_env_seed.env_id
                  AND e.owner_schema = current_schema()));

GRANT SELECT, INSERT, UPDATE, DELETE ON malu$preview_env, malu$preview_env_seed TO maludb_memory_admin;
GRANT SELECT, INSERT, UPDATE         ON malu$preview_env, malu$preview_env_seed TO maludb_memory_executor;
GRANT SELECT                          ON malu$preview_env, malu$preview_env_seed TO maludb_memory_auditor;
GRANT USAGE, SELECT ON SEQUENCE malu$preview_env_env_id_seq             TO maludb_memory_admin, maludb_memory_executor;
GRANT USAGE, SELECT ON SEQUENCE malu$preview_env_seed_seed_id_seq       TO maludb_memory_admin, maludb_memory_executor;

-- =====================================================================
-- preview_env_create / record_seed / promote_check / list
-- =====================================================================
CREATE FUNCTION preview_env_create(
    p_name           text,
    p_base_migration text,
    p_seed_policy    jsonb   DEFAULT '{"production_data": false}'::jsonb,
    p_anonymizer_ref text    DEFAULT NULL,
    p_description    text    DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql VOLATILE AS $body$
#variable_conflict use_column
DECLARE v_id bigint;
BEGIN
    IF p_seed_policy -> 'production_data' = 'true'::jsonb THEN
        RAISE EXCEPTION 'preview_env_create: seed_policy.production_data must be false (V3-ENV-01 default)'
            USING ERRCODE = 'check_violation',
                  HINT    = 'Use the anonymizer_ref + per-seed redaction rules to import sanitised data.';
    END IF;

    INSERT INTO malu$preview_env
        (name, base_migration, current_migration, seed_policy, anonymizer_ref, description)
    VALUES
        (p_name, p_base_migration, p_base_migration, p_seed_policy, p_anonymizer_ref, p_description)
    ON CONFLICT (owner_schema, name) DO UPDATE
        SET base_migration   = EXCLUDED.base_migration,
            current_migration = EXCLUDED.base_migration,
            seed_policy      = EXCLUDED.seed_policy,
            anonymizer_ref   = EXCLUDED.anonymizer_ref,
            description      = EXCLUDED.description,
            retired_at       = NULL
    RETURNING env_id INTO v_id;

    PERFORM audit_event('preview_env_create', 'malu$preview_env', v_id,
        jsonb_build_object('name', p_name, 'base_migration', p_base_migration,
                           'production_data', p_seed_policy -> 'production_data'),
        NULL);
    RETURN v_id;
END;
$body$;

CREATE FUNCTION preview_env_record_seed(
    p_env_id          bigint,
    p_source_kind     text,
    p_source_ref      text,
    p_redaction_rules jsonb DEFAULT '[]'::jsonb
) RETURNS bigint
LANGUAGE plpgsql VOLATILE AS $body$
#variable_conflict use_column
DECLARE v_id bigint;
BEGIN
    INSERT INTO malu$preview_env_seed(env_id, source_kind, source_ref, redaction_rules, applied_at)
    VALUES (p_env_id, p_source_kind, p_source_ref, p_redaction_rules, now())
    RETURNING seed_id INTO v_id;
    PERFORM audit_event('preview_env_record_seed', 'malu$preview_env_seed', v_id,
        jsonb_build_object('env_id', p_env_id, 'source_kind', p_source_kind),
        NULL);
    RETURN v_id;
END;
$body$;

CREATE FUNCTION preview_env_promote_check(p_env_id bigint)
    RETURNS TABLE (gate text, ok boolean, detail text)
LANGUAGE plpgsql STABLE AS $body$
#variable_conflict use_column
DECLARE v_env malu$preview_env%ROWTYPE;
BEGIN
    SELECT * INTO v_env FROM malu$preview_env WHERE env_id = p_env_id;
    IF v_env.env_id IS NULL THEN
        RAISE EXCEPTION 'preview_env_promote_check: env % not found', p_env_id
            USING ERRCODE = 'no_data_found';
    END IF;

    RETURN QUERY
    SELECT 'no_production_data'::text,
           (v_env.seed_policy -> 'production_data' IS DISTINCT FROM 'true'::jsonb),
           'seed_policy.production_data must be false'::text
    UNION ALL
    SELECT 'has_seed'::text,
           EXISTS (SELECT 1 FROM malu$preview_env_seed WHERE env_id = p_env_id),
           'at least one seed row recorded'::text
    UNION ALL
    SELECT 'migration_current'::text,
           v_env.current_migration = maludb_core_version(),
           format('current_migration=%s vs extension=%s',
                  v_env.current_migration, maludb_core_version());
END;
$body$;

CREATE FUNCTION preview_env_list(p_include_retired boolean DEFAULT false)
    RETURNS TABLE (
        env_id            bigint,
        name              text,
        base_migration    text,
        current_migration text,
        seed_count        integer,
        anonymizer_ref    text,
        created_at        timestamptz,
        retired_at        timestamptz
    ) LANGUAGE plpgsql STABLE AS $body$
#variable_conflict use_column
BEGIN
    RETURN QUERY
    SELECT e.env_id, e.name, e.base_migration, e.current_migration,
           (SELECT count(*)::integer FROM malu$preview_env_seed s WHERE s.env_id = e.env_id),
           e.anonymizer_ref, e.created_at, e.retired_at
      FROM malu$preview_env e
     WHERE (p_include_retired OR e.retired_at IS NULL)
     ORDER BY e.name;
END;
$body$;

REVOKE EXECUTE ON FUNCTION preview_env_create(text, text, jsonb, text, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION preview_env_record_seed(bigint, text, text, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION preview_env_promote_check(bigint) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION preview_env_list(boolean) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION preview_env_create(text, text, jsonb, text, text)         TO maludb_memory_admin, maludb_memory_executor;
GRANT  EXECUTE ON FUNCTION preview_env_record_seed(bigint, text, text, jsonb)        TO maludb_memory_admin, maludb_memory_executor;
GRANT  EXECUTE ON FUNCTION preview_env_promote_check(bigint)                          TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;
GRANT  EXECUTE ON FUNCTION preview_env_list(boolean)                                  TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;
