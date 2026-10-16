\echo Use "ALTER EXTENSION maludb_core UPDATE TO '0.39.0'" to load this file. \quit

-- =====================================================================
-- maludb_core 0.38.0 → 0.39.0
--
-- Stage 6 — Adapter-based alignment + local model capability
-- negotiation (S6-3).
--
-- Per requirements.md §9 Stage 6: "Model Registry with … adapter-
-- based alignment between embedding spaces, and advanced local model
-- capability negotiation."
--
-- Two surfaces:
--
-- 1. malu$embedding_adapter — registered transform between two
--    embedding spaces. The actual math (matrix, learned projection,
--    distillation head) lives outside the DB; the catalog records
--    identity, kind, parameters, and evaluation metrics. The S6-2
--    malu$index_migration.adapter_id FK is wired in this phase.
--
-- 2. malu$local_model_capability — what a local model can run:
--    GPU/CPU placement, VRAM/RAM, supported quantizations, context
--    window, throughput. negotiate_local_model returns the ranked
--    list of candidates that satisfy a caller's constraints.
-- =====================================================================

CREATE OR REPLACE FUNCTION maludb_core_version() RETURNS text
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$ SELECT '0.39.0'::text $body$;

-- =====================================================================
-- malu$embedding_adapter
--
-- An adapter is a transform from one embedding space to another.
-- adapter_kind values:
--   identity            — same geometry, no transform (rare; useful
--                         when only metadata changed).
--   linear_projection   — A·x + b, where A is the matrix referenced
--                         by params_jsonb.matrix_uri.
--   learned_mlp         — a small trained network (rank stored in
--                         params_jsonb.learned_rank etc.).
--   custom              — operator-supplied transform; runtime
--                         interprets params_jsonb.
--
-- evaluation jsonb is free-form for v1; suggested keys are
--   { "recall_at_10": 0.92,
--     "cosine_drift_mean": 0.04,
--     "sample_count": 5000,
--     "evaluated_at": "2026-05-13T14:00:00Z" }
-- =====================================================================
CREATE TABLE malu$embedding_adapter (
    adapter_id        bigserial PRIMARY KEY,
    owner_schema      name NOT NULL DEFAULT current_schema(),
    adapter_name      text NOT NULL,
    source_space_id   bigint NOT NULL REFERENCES malu$embedding_space(space_id) ON DELETE RESTRICT,
    target_space_id   bigint NOT NULL REFERENCES malu$embedding_space(space_id) ON DELETE RESTRICT,
    adapter_kind      text NOT NULL
        CHECK (adapter_kind IN ('identity','linear_projection','learned_mlp','custom')),
    params_jsonb      jsonb NOT NULL DEFAULT '{}'::jsonb,
    evaluation        jsonb,
    enabled           boolean NOT NULL DEFAULT true,
    created_at        timestamptz NOT NULL DEFAULT now(),
    updated_at        timestamptz NOT NULL DEFAULT now(),
    UNIQUE (owner_schema, adapter_name),
    CHECK (source_space_id <> target_space_id)
);
CREATE INDEX malu$embedding_adapter_owner_idx
    ON malu$embedding_adapter(owner_schema);
CREATE INDEX malu$embedding_adapter_spaces_idx
    ON malu$embedding_adapter(source_space_id, target_space_id);

ALTER TABLE malu$embedding_adapter ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_owner ON malu$embedding_adapter
    USING (owner_schema = current_schema())
    WITH CHECK (owner_schema = current_schema());

GRANT SELECT ON malu$embedding_adapter TO
    maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;
GRANT INSERT, UPDATE ON malu$embedding_adapter TO
    maludb_memory_admin, maludb_memory_executor;
GRANT USAGE, SELECT ON SEQUENCE malu$embedding_adapter_adapter_id_seq TO
    maludb_memory_admin, maludb_memory_executor;

-- Wire the S6-2 deferred FK now that the table exists.
ALTER TABLE malu$index_migration
    ADD CONSTRAINT malu$index_migration_adapter_fk
    FOREIGN KEY (adapter_id) REFERENCES malu$embedding_adapter(adapter_id)
    ON DELETE SET NULL;

-- =====================================================================
-- register_embedding_adapter — upsert by (owner_schema, adapter_name).
--
-- Refuses to redefine source/target spaces or adapter_kind once
-- registered; bump the name for a different alignment. params_jsonb
-- and evaluation may be updated freely.
-- =====================================================================
CREATE FUNCTION register_embedding_adapter(
    p_adapter_name     text,
    p_source_space_id  bigint,
    p_target_space_id  bigint,
    p_adapter_kind     text,
    p_params_jsonb     jsonb DEFAULT '{}'::jsonb,
    p_evaluation       jsonb DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql
AS $body$
DECLARE v_id bigint;
BEGIN
    INSERT INTO malu$embedding_adapter
        (adapter_name, source_space_id, target_space_id,
         adapter_kind, params_jsonb, evaluation)
    VALUES (p_adapter_name, p_source_space_id, p_target_space_id,
            p_adapter_kind, p_params_jsonb, p_evaluation)
    ON CONFLICT (owner_schema, adapter_name) DO UPDATE
        SET params_jsonb = EXCLUDED.params_jsonb,
            evaluation   = COALESCE(EXCLUDED.evaluation, malu$embedding_adapter.evaluation),
            updated_at   = now()
        WHERE malu$embedding_adapter.source_space_id = EXCLUDED.source_space_id
          AND malu$embedding_adapter.target_space_id = EXCLUDED.target_space_id
          AND malu$embedding_adapter.adapter_kind    = EXCLUDED.adapter_kind
    RETURNING adapter_id INTO v_id;

    IF v_id IS NULL THEN
        RAISE EXCEPTION 'register_embedding_adapter: cannot redefine % with different spaces or kind', p_adapter_name
            USING ERRCODE = 'invalid_parameter_value',
                  HINT = 'Pick a new adapter_name';
    END IF;
    RETURN v_id;
END;
$body$;

-- =====================================================================
-- attach_adapter_to_migration — pin the alignment used by a blue-
-- green migration. Refuses if the migration's source/target spaces
-- don't match the adapter's.
-- =====================================================================
CREATE FUNCTION attach_adapter_to_migration(
    p_migration_id  bigint,
    p_adapter_id    bigint
) RETURNS void
LANGUAGE plpgsql
AS $body$
DECLARE
    v_mig malu$index_migration%ROWTYPE;
    v_ad  malu$embedding_adapter%ROWTYPE;
BEGIN
    SELECT * INTO v_mig FROM malu$index_migration WHERE migration_id = p_migration_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'attach_adapter_to_migration: migration % not found', p_migration_id
            USING ERRCODE = 'no_data_found';
    END IF;
    SELECT * INTO v_ad FROM malu$embedding_adapter WHERE adapter_id = p_adapter_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'attach_adapter_to_migration: adapter % not found', p_adapter_id
            USING ERRCODE = 'no_data_found';
    END IF;
    IF v_mig.source_space_id <> v_ad.source_space_id
       OR v_mig.target_space_id <> v_ad.target_space_id THEN
        RAISE EXCEPTION 'attach_adapter_to_migration: adapter spaces (%, %) do not match migration spaces (%, %)',
            v_ad.source_space_id, v_ad.target_space_id,
            v_mig.source_space_id, v_mig.target_space_id
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    UPDATE malu$index_migration
       SET adapter_id         = p_adapter_id,
           last_transition_at = now()
     WHERE migration_id = p_migration_id;

    PERFORM audit_event('index_migration_adapter_attached', NULL, NULL,
        jsonb_build_object('migration_id', p_migration_id,
                           'adapter_id',   p_adapter_id));
END;
$body$;

-- =====================================================================
-- malu$local_model_capability — what a local model can run.
--
-- One row per (owner_schema, model_alias_id). Re-running
-- record_local_model_capability upserts.
-- =====================================================================
CREATE TABLE malu$local_model_capability (
    capability_id            bigserial PRIMARY KEY,
    owner_schema             name NOT NULL DEFAULT current_schema(),
    model_alias_id           bigint NOT NULL REFERENCES malu$model_alias(alias_id) ON DELETE CASCADE,
    gpu_available            boolean NOT NULL DEFAULT false,
    gpu_kind                 text
        CHECK (gpu_kind IS NULL OR gpu_kind IN
              ('nvidia','amd','intel','apple_metal','cpu_only')),
    vram_mb                  integer CHECK (vram_mb IS NULL OR vram_mb >= 0),
    system_ram_mb            integer CHECK (system_ram_mb IS NULL OR system_ram_mb >= 0),
    supports_quantizations   text[] NOT NULL DEFAULT ARRAY[]::text[],
    context_window           integer CHECK (context_window IS NULL OR context_window > 0),
    max_batch_size           integer CHECK (max_batch_size IS NULL OR max_batch_size > 0),
    typical_tokens_per_sec   real    CHECK (typical_tokens_per_sec IS NULL OR typical_tokens_per_sec >= 0),
    platform_jsonb           jsonb,
    last_negotiated_at       timestamptz NOT NULL DEFAULT now(),
    UNIQUE (owner_schema, model_alias_id)
);
CREATE INDEX malu$local_model_capability_owner_idx
    ON malu$local_model_capability(owner_schema);
CREATE INDEX malu$local_model_capability_ctx_idx
    ON malu$local_model_capability(context_window)
    WHERE context_window IS NOT NULL;

ALTER TABLE malu$local_model_capability ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_owner ON malu$local_model_capability
    USING (owner_schema = current_schema())
    WITH CHECK (owner_schema = current_schema());

GRANT SELECT ON malu$local_model_capability TO
    maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;
GRANT INSERT, UPDATE ON malu$local_model_capability TO
    maludb_memory_admin, maludb_memory_executor;
GRANT USAGE, SELECT ON SEQUENCE malu$local_model_capability_capability_id_seq TO
    maludb_memory_admin, maludb_memory_executor;

-- =====================================================================
-- record_local_model_capability — upsert.
-- =====================================================================
CREATE FUNCTION record_local_model_capability(
    p_model_alias_id          bigint,
    p_gpu_available           boolean DEFAULT false,
    p_gpu_kind                text    DEFAULT NULL,
    p_vram_mb                 integer DEFAULT NULL,
    p_system_ram_mb           integer DEFAULT NULL,
    p_supports_quantizations  text[]  DEFAULT ARRAY[]::text[],
    p_context_window          integer DEFAULT NULL,
    p_max_batch_size          integer DEFAULT NULL,
    p_typical_tokens_per_sec  real    DEFAULT NULL,
    p_platform_jsonb          jsonb   DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql
AS $body$
DECLARE v_id bigint;
BEGIN
    INSERT INTO malu$local_model_capability
        (model_alias_id, gpu_available, gpu_kind, vram_mb, system_ram_mb,
         supports_quantizations, context_window, max_batch_size,
         typical_tokens_per_sec, platform_jsonb)
    VALUES
        (p_model_alias_id, p_gpu_available, p_gpu_kind, p_vram_mb, p_system_ram_mb,
         p_supports_quantizations, p_context_window, p_max_batch_size,
         p_typical_tokens_per_sec, p_platform_jsonb)
    ON CONFLICT (owner_schema, model_alias_id) DO UPDATE
        SET gpu_available           = EXCLUDED.gpu_available,
            gpu_kind                = COALESCE(EXCLUDED.gpu_kind, malu$local_model_capability.gpu_kind),
            vram_mb                 = COALESCE(EXCLUDED.vram_mb, malu$local_model_capability.vram_mb),
            system_ram_mb           = COALESCE(EXCLUDED.system_ram_mb, malu$local_model_capability.system_ram_mb),
            supports_quantizations  = EXCLUDED.supports_quantizations,
            context_window          = COALESCE(EXCLUDED.context_window, malu$local_model_capability.context_window),
            max_batch_size          = COALESCE(EXCLUDED.max_batch_size, malu$local_model_capability.max_batch_size),
            typical_tokens_per_sec  = COALESCE(EXCLUDED.typical_tokens_per_sec, malu$local_model_capability.typical_tokens_per_sec),
            platform_jsonb          = COALESCE(EXCLUDED.platform_jsonb, malu$local_model_capability.platform_jsonb),
            last_negotiated_at      = now()
    RETURNING capability_id INTO v_id;

    PERFORM audit_event('local_model_capability_recorded', NULL, NULL,
        jsonb_build_object(
            'capability_id', v_id,
            'model_alias_id', p_model_alias_id,
            'gpu_available', p_gpu_available));
    RETURN v_id;
END;
$body$;

-- =====================================================================
-- negotiate_local_model — return models that satisfy the constraints,
-- ranked by typical_tokens_per_sec DESC (preferring faster), with
-- GPU-available rows preferred over CPU-only when ties.
--
-- Filters:
--   p_min_context_window — model's context_window must be ≥ this.
--   p_required_quantization — must appear in supports_quantizations
--                            (NULL → no filter).
--   p_min_vram_mb — when supplied, restrict to GPU-capable rows with
--                   vram_mb ≥ this.
-- =====================================================================
CREATE FUNCTION negotiate_local_model(
    p_min_context_window      integer DEFAULT NULL,
    p_required_quantization   text    DEFAULT NULL,
    p_min_vram_mb             integer DEFAULT NULL
) RETURNS TABLE (
    alias_id               bigint,
    alias_name             text,
    gpu_available          boolean,
    gpu_kind               text,
    vram_mb                integer,
    context_window         integer,
    typical_tokens_per_sec real
)
LANGUAGE sql STABLE
AS $body$
    SELECT a.alias_id, a.alias_name,
           c.gpu_available, c.gpu_kind, c.vram_mb,
           c.context_window, c.typical_tokens_per_sec
      FROM malu$local_model_capability c
      JOIN malu$model_alias a ON a.alias_id = c.model_alias_id
     WHERE (p_min_context_window IS NULL
            OR (c.context_window IS NOT NULL AND c.context_window >= p_min_context_window))
       AND (p_required_quantization IS NULL
            OR p_required_quantization = ANY(c.supports_quantizations))
       AND (p_min_vram_mb IS NULL
            OR (c.gpu_available AND c.vram_mb IS NOT NULL AND c.vram_mb >= p_min_vram_mb))
     ORDER BY c.gpu_available DESC,
              c.typical_tokens_per_sec DESC NULLS LAST,
              a.alias_id;
$body$;

GRANT EXECUTE ON FUNCTION
    register_embedding_adapter(text, bigint, bigint, text, jsonb, jsonb),
    attach_adapter_to_migration(bigint, bigint),
    record_local_model_capability(bigint, boolean, text, integer, integer, text[], integer, integer, real, jsonb),
    negotiate_local_model(integer, text, integer)
TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;
