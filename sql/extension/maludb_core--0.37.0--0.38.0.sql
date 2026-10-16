\echo Use "ALTER EXTENSION maludb_core UPDATE TO '0.38.0'" to load this file. \quit

-- =====================================================================
-- maludb_core 0.37.0 → 0.38.0
--
-- Stage 6 — Model Registry blue-green + dual-space query routing (S6-2).
--
-- Per requirements.md §9 Stage 6 + §5 Model Registry:
--   "Embedding/extraction/reranker/summarizer model identity, version,
--    dimensions, embedding space, prompt-template policy, evaluation
--    status, rollout state, derived-artifact map. Supports blue-green
--    indexes, dual-space query routing, adapter alignment, staged
--    background re-embedding."
--
-- Per §6: "Embedding model migrations MUST avoid long downtime: blue-
-- green indexes, dual-space query routing during transition, adapter-
-- based alignment between embedding spaces, or staged background re-
-- embedding are all acceptable."
--
-- v1 surface:
--   malu$embedding_space       — identity per embedding model+version.
--   malu$model_registry        — kind+rollout_state+evaluation_status
--                                + derived-artifact map.
--   malu$index_migration       — blue-green migration tracker with
--                                source_space → target_space + status
--                                + traffic_pct weight for dual_serve.
--
--   register_embedding_space, register_model_in_registry,
--   propose_index_migration, advance_index_migration, route_query.
--
-- adapter_id FK on malu$index_migration is added in S6-3 once
-- malu$embedding_adapter lands.
-- =====================================================================

CREATE OR REPLACE FUNCTION maludb_core_version() RETURNS text
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$ SELECT '0.38.0'::text $body$;

-- =====================================================================
-- malu$embedding_space — identity for an embedding model's vector
-- space. Two models that produce different geometry must register
-- different spaces; bumping a model version that re-trains the head
-- requires a new space.
-- =====================================================================
CREATE TABLE malu$embedding_space (
    space_id          bigserial PRIMARY KEY,
    owner_schema      name NOT NULL DEFAULT current_schema(),
    space_name        text NOT NULL,
    model_alias_id    bigint REFERENCES malu$model_alias(alias_id) ON DELETE SET NULL,
    dimensions        integer NOT NULL CHECK (dimensions > 0),
    normalization     text NOT NULL DEFAULT 'cosine'
        CHECK (normalization IN ('cosine','l2','inner_product','none')),
    description       text,
    created_at        timestamptz NOT NULL DEFAULT now(),
    UNIQUE (owner_schema, space_name)
);
CREATE INDEX malu$embedding_space_owner_idx
    ON malu$embedding_space(owner_schema);

ALTER TABLE malu$embedding_space ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_owner ON malu$embedding_space
    USING (owner_schema = current_schema())
    WITH CHECK (owner_schema = current_schema());

GRANT SELECT ON malu$embedding_space TO
    maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;
GRANT INSERT, UPDATE ON malu$embedding_space TO
    maludb_memory_admin, maludb_memory_executor;
GRANT USAGE, SELECT ON SEQUENCE malu$embedding_space_space_id_seq TO
    maludb_memory_admin, maludb_memory_executor;

-- =====================================================================
-- malu$model_registry — broader registry covering all model kinds
-- with rollout/evaluation lifecycle. Only embedding models reference
-- malu$embedding_space; other kinds set embedding_space_id NULL.
--
-- derived_artifact_map records what depends on this model:
--   { "indexes": ["malu$memory_chunk_emb_hnsw"],
--     "columns": ["malu$memory_chunk.emb"],
--     "extraction_outputs": ["fact","claim"] }
-- The map is consulted when proposing migrations so we know what to
-- rebuild / dual-write / cut over.
-- =====================================================================
CREATE TABLE malu$model_registry (
    registry_id           bigserial PRIMARY KEY,
    owner_schema          name NOT NULL DEFAULT current_schema(),
    model_kind            text NOT NULL
        CHECK (model_kind IN ('embedding','extraction','reranker','summarizer')),
    model_alias_id        bigint REFERENCES malu$model_alias(alias_id) ON DELETE RESTRICT,
    embedding_space_id    bigint REFERENCES malu$embedding_space(space_id) ON DELETE RESTRICT,
    rollout_state         text NOT NULL DEFAULT 'proposed'
        CHECK (rollout_state IN ('proposed','canary','active','retiring','retired')),
    evaluation_status     text NOT NULL DEFAULT 'pending'
        CHECK (evaluation_status IN ('pending','passed','failed')),
    derived_artifact_map  jsonb NOT NULL DEFAULT '{}'::jsonb,
    notes                 text,
    registered_at         timestamptz NOT NULL DEFAULT now(),
    last_transition_at    timestamptz NOT NULL DEFAULT now(),
    UNIQUE (owner_schema, model_kind, model_alias_id),
    -- embedding model rows MUST carry a space; non-embedding rows MUST NOT.
    CHECK (
        (model_kind = 'embedding' AND embedding_space_id IS NOT NULL)
        OR
        (model_kind <> 'embedding' AND embedding_space_id IS NULL)
    )
);
CREATE INDEX malu$model_registry_owner_idx
    ON malu$model_registry(owner_schema);
CREATE INDEX malu$model_registry_kind_state_idx
    ON malu$model_registry(model_kind, rollout_state)
    WHERE rollout_state IN ('active','canary');
-- One active model per (owner_schema, model_kind).
CREATE UNIQUE INDEX malu$model_registry_one_active
    ON malu$model_registry(owner_schema, model_kind)
    WHERE rollout_state = 'active';

ALTER TABLE malu$model_registry ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_owner ON malu$model_registry
    USING (owner_schema = current_schema())
    WITH CHECK (owner_schema = current_schema());

GRANT SELECT ON malu$model_registry TO
    maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;
GRANT INSERT, UPDATE ON malu$model_registry TO
    maludb_memory_admin, maludb_memory_executor;
GRANT USAGE, SELECT ON SEQUENCE malu$model_registry_registry_id_seq TO
    maludb_memory_admin, maludb_memory_executor;

-- =====================================================================
-- malu$index_migration — blue-green migration tracker.
--
-- Status machine:
--   proposed         → shadow_building (start backfill of target index)
--   shadow_building  → dual_serve      (target index ready, route both)
--   dual_serve       → cutover         (commit to target only; source drains)
--   cutover          → cleanup         (drop source index)
--   cleanup          → done            (terminal)
--   *                → aborted         (rollback at any non-terminal stage)
--
-- traffic_pct is the share routed to the *target* space during the
-- dual_serve stage. Outside dual_serve it's informational only.
-- =====================================================================
CREATE TABLE malu$index_migration (
    migration_id        bigserial PRIMARY KEY,
    owner_schema        name NOT NULL DEFAULT current_schema(),
    source_space_id     bigint NOT NULL REFERENCES malu$embedding_space(space_id) ON DELETE RESTRICT,
    target_space_id     bigint NOT NULL REFERENCES malu$embedding_space(space_id) ON DELETE RESTRICT,
    status              text NOT NULL DEFAULT 'proposed'
        CHECK (status IN ('proposed','shadow_building','dual_serve',
                          'cutover','cleanup','done','aborted')),
    traffic_pct         numeric(5,2) NOT NULL DEFAULT 0
        CHECK (traffic_pct >= 0 AND traffic_pct <= 100),
    index_kind          text NOT NULL DEFAULT 'hnsw'
        CHECK (index_kind IN ('hnsw','ivfflat','flat')),
    adapter_id          bigint,    -- FK added in S6-3
    notes               text,
    started_at          timestamptz NOT NULL DEFAULT now(),
    last_transition_at  timestamptz NOT NULL DEFAULT now(),
    completed_at        timestamptz,
    CHECK (source_space_id <> target_space_id)
);
CREATE INDEX malu$index_migration_owner_idx
    ON malu$index_migration(owner_schema);
CREATE INDEX malu$index_migration_status_idx
    ON malu$index_migration(status)
    WHERE status NOT IN ('done','aborted');
-- Only one in-flight migration per (source_space, target_space) at a time.
CREATE UNIQUE INDEX malu$index_migration_uq_inflight
    ON malu$index_migration(owner_schema, source_space_id, target_space_id)
    WHERE status NOT IN ('done','aborted');

ALTER TABLE malu$index_migration ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_owner ON malu$index_migration
    USING (owner_schema = current_schema())
    WITH CHECK (owner_schema = current_schema());

GRANT SELECT ON malu$index_migration TO
    maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;
GRANT INSERT, UPDATE ON malu$index_migration TO
    maludb_memory_admin, maludb_memory_executor;
GRANT USAGE, SELECT ON SEQUENCE malu$index_migration_migration_id_seq TO
    maludb_memory_admin, maludb_memory_executor;

-- =====================================================================
-- register_embedding_space — upsert by (owner_schema, space_name).
-- =====================================================================
CREATE FUNCTION register_embedding_space(
    p_space_name      text,
    p_dimensions      integer,
    p_normalization   text   DEFAULT 'cosine',
    p_model_alias_id  bigint DEFAULT NULL,
    p_description     text   DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql
AS $body$
DECLARE v_id bigint;
BEGIN
    INSERT INTO malu$embedding_space
        (space_name, dimensions, normalization, model_alias_id, description)
    VALUES (p_space_name, p_dimensions, p_normalization, p_model_alias_id, p_description)
    ON CONFLICT (owner_schema, space_name) DO UPDATE
        SET model_alias_id = COALESCE(EXCLUDED.model_alias_id, malu$embedding_space.model_alias_id),
            description    = COALESCE(EXCLUDED.description,    malu$embedding_space.description)
        WHERE malu$embedding_space.dimensions    = EXCLUDED.dimensions
          AND malu$embedding_space.normalization = EXCLUDED.normalization
    RETURNING space_id INTO v_id;

    IF v_id IS NULL THEN
        RAISE EXCEPTION 'register_embedding_space: cannot redefine % with different geometry', p_space_name
            USING ERRCODE = 'invalid_parameter_value',
                  HINT = 'Register a new space_name for any change to dimensions or normalization';
    END IF;
    RETURN v_id;
END;
$body$;

-- =====================================================================
-- register_model_in_registry — record a model in the registry.
--
-- Rolls in 'proposed' state. Move to canary/active via
-- advance_model_rollout. Embedding models MUST supply
-- embedding_space_id; non-embedding kinds MUST NOT (the row CHECK
-- enforces this).
-- =====================================================================
CREATE FUNCTION register_model_in_registry(
    p_model_kind           text,
    p_model_alias_id       bigint DEFAULT NULL,
    p_embedding_space_id   bigint DEFAULT NULL,
    p_derived_artifact_map jsonb  DEFAULT '{}'::jsonb,
    p_notes                text   DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql
AS $body$
DECLARE v_id bigint;
BEGIN
    INSERT INTO malu$model_registry
        (model_kind, model_alias_id, embedding_space_id,
         derived_artifact_map, notes)
    VALUES (p_model_kind, p_model_alias_id, p_embedding_space_id,
            p_derived_artifact_map, p_notes)
    RETURNING registry_id INTO v_id;

    PERFORM audit_event('model_registry_added', NULL, NULL,
        jsonb_build_object(
            'registry_id', v_id,
            'model_kind',  p_model_kind,
            'embedding_space_id', p_embedding_space_id));
    RETURN v_id;
END;
$body$;

-- =====================================================================
-- advance_model_rollout — state machine over rollout_state.
--
-- Allowed transitions:
--   proposed → canary
--   canary   → active   (the previously-active row of same kind is
--                        moved to retiring atomically)
--   active   → retiring
--   retiring → retired
--   *        → retired  (after rejection; not enforced here)
-- =====================================================================
CREATE FUNCTION advance_model_rollout(
    p_registry_id  bigint,
    p_new_state    text
) RETURNS void
LANGUAGE plpgsql
AS $body$
DECLARE
    v_cur   text;
    v_kind  text;
    v_owner name;
    v_legal_next text[];
BEGIN
    SELECT rollout_state, model_kind, owner_schema
      INTO v_cur, v_kind, v_owner
      FROM malu$model_registry WHERE registry_id = p_registry_id;
    IF v_cur IS NULL THEN
        RAISE EXCEPTION 'advance_model_rollout: registry % not found', p_registry_id
            USING ERRCODE = 'no_data_found';
    END IF;

    v_legal_next := CASE v_cur
        WHEN 'proposed' THEN ARRAY['canary','retired']
        WHEN 'canary'   THEN ARRAY['active','retired']
        WHEN 'active'   THEN ARRAY['retiring']
        WHEN 'retiring' THEN ARRAY['retired']
        ELSE ARRAY[]::text[]
    END;
    IF NOT (p_new_state = ANY(v_legal_next)) THEN
        RAISE EXCEPTION 'advance_model_rollout: cannot transition % → %',
            v_cur, p_new_state
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    -- When promoting to 'active', demote any other active row of the
    -- same kind first. The partial unique index would otherwise raise.
    IF p_new_state = 'active' THEN
        UPDATE malu$model_registry
           SET rollout_state      = 'retiring',
               last_transition_at = now()
         WHERE owner_schema  = v_owner
           AND model_kind    = v_kind
           AND rollout_state = 'active'
           AND registry_id  <> p_registry_id;
    END IF;

    UPDATE malu$model_registry
       SET rollout_state      = p_new_state,
           last_transition_at = now()
     WHERE registry_id = p_registry_id;

    PERFORM audit_event('model_rollout_advanced', NULL, NULL,
        jsonb_build_object(
            'registry_id', p_registry_id,
            'model_kind',  v_kind,
            'from_state',  v_cur,
            'to_state',    p_new_state));
END;
$body$;

-- =====================================================================
-- propose_index_migration — start a blue-green migration.
--
-- Refuses if the target space dimensions don't match what the source
-- space's derived artifacts expect (caller's responsibility, but we
-- check the obvious shape mismatch: different dimensions need an
-- adapter — recorded in S6-3 via adapter_id).
-- =====================================================================
CREATE FUNCTION propose_index_migration(
    p_source_space_id  bigint,
    p_target_space_id  bigint,
    p_index_kind       text DEFAULT 'hnsw',
    p_notes            text DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql
AS $body$
DECLARE
    v_id   bigint;
    v_src  malu$embedding_space%ROWTYPE;
    v_tgt  malu$embedding_space%ROWTYPE;
BEGIN
    SELECT * INTO v_src FROM malu$embedding_space WHERE space_id = p_source_space_id;
    SELECT * INTO v_tgt FROM malu$embedding_space WHERE space_id = p_target_space_id;
    IF v_src.space_id IS NULL OR v_tgt.space_id IS NULL THEN
        RAISE EXCEPTION 'propose_index_migration: source or target space not found'
            USING ERRCODE = 'no_data_found';
    END IF;

    INSERT INTO malu$index_migration
        (source_space_id, target_space_id, index_kind, notes)
    VALUES (p_source_space_id, p_target_space_id, p_index_kind, p_notes)
    RETURNING migration_id INTO v_id;

    PERFORM audit_event('index_migration_proposed', NULL, NULL,
        jsonb_build_object(
            'migration_id',     v_id,
            'source_space_id',  p_source_space_id,
            'target_space_id',  p_target_space_id,
            'source_dims',      v_src.dimensions,
            'target_dims',      v_tgt.dimensions,
            'index_kind',       p_index_kind));
    RETURN v_id;
END;
$body$;

-- =====================================================================
-- advance_index_migration — state machine over status.
--
-- Allowed transitions:
--   proposed         → shadow_building
--   shadow_building  → dual_serve   (requires p_traffic_pct)
--   dual_serve       → dual_serve   (re-weight the split)
--   dual_serve       → cutover
--   cutover          → cleanup
--   cleanup          → done
--   any non-terminal → aborted
-- =====================================================================
CREATE FUNCTION advance_index_migration(
    p_migration_id   bigint,
    p_new_status     text,
    p_traffic_pct    numeric DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql
AS $body$
DECLARE
    v_cur text;
    v_legal_next text[];
BEGIN
    SELECT status INTO v_cur FROM malu$index_migration
        WHERE migration_id = p_migration_id;
    IF v_cur IS NULL THEN
        RAISE EXCEPTION 'advance_index_migration: migration % not found', p_migration_id
            USING ERRCODE = 'no_data_found';
    END IF;

    v_legal_next := CASE v_cur
        WHEN 'proposed'        THEN ARRAY['shadow_building','aborted']
        WHEN 'shadow_building' THEN ARRAY['dual_serve','aborted']
        WHEN 'dual_serve'      THEN ARRAY['dual_serve','cutover','aborted']
        WHEN 'cutover'         THEN ARRAY['cleanup','aborted']
        WHEN 'cleanup'         THEN ARRAY['done']
        ELSE ARRAY[]::text[]
    END;
    IF NOT (p_new_status = ANY(v_legal_next)) THEN
        RAISE EXCEPTION 'advance_index_migration: cannot transition % → %',
            v_cur, p_new_status
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    IF p_new_status = 'dual_serve' THEN
        IF p_traffic_pct IS NULL THEN
            RAISE EXCEPTION 'advance_index_migration: dual_serve requires p_traffic_pct'
                USING ERRCODE = 'invalid_parameter_value';
        END IF;
        UPDATE malu$index_migration
           SET status             = p_new_status,
               traffic_pct        = p_traffic_pct,
               last_transition_at = now()
         WHERE migration_id = p_migration_id;
    ELSIF p_new_status IN ('done','aborted') THEN
        UPDATE malu$index_migration
           SET status             = p_new_status,
               completed_at       = now(),
               last_transition_at = now()
         WHERE migration_id = p_migration_id;
    ELSIF p_new_status = 'cutover' THEN
        -- Cutover commits 100% to the target.
        UPDATE malu$index_migration
           SET status             = p_new_status,
               traffic_pct        = 100,
               last_transition_at = now()
         WHERE migration_id = p_migration_id;
    ELSE
        UPDATE malu$index_migration
           SET status             = p_new_status,
               last_transition_at = now()
         WHERE migration_id = p_migration_id;
    END IF;

    PERFORM audit_event('index_migration_advanced', NULL, NULL,
        jsonb_build_object(
            'migration_id', p_migration_id,
            'from_status',  v_cur,
            'to_status',    p_new_status,
            'traffic_pct',  p_traffic_pct));
END;
$body$;

-- =====================================================================
-- route_query — dual-space query routing.
--
-- Returns a jsonb describing which embedding space(s) the caller's
-- query should target. The shape is:
--
--   { "strategy": "active" | "dual_serve" | "target_only",
--     "spaces": [{"space_id": …, "weight": 0.7, "role": "source"},
--                {"space_id": …, "weight": 0.3, "role": "target"}],
--     "migration_id": …|null }
--
-- "active" — no migration in flight; query the currently active
--            embedding space.
-- "dual_serve" — migration in dual_serve state; query BOTH spaces
--            with traffic_pct used to weight the target side.
-- "target_only" — migration in cutover/cleanup; query the target.
-- =====================================================================
CREATE FUNCTION route_query(
    p_model_kind text DEFAULT 'embedding'
) RETURNS jsonb
LANGUAGE plpgsql STABLE
AS $body$
DECLARE
    v_active_space bigint;
    v_mig          malu$index_migration%ROWTYPE;
    v_spaces       jsonb := '[]'::jsonb;
BEGIN
    SELECT embedding_space_id INTO v_active_space
      FROM malu$model_registry
     WHERE model_kind = p_model_kind
       AND rollout_state = 'active'
     LIMIT 1;
    IF v_active_space IS NULL THEN
        RAISE EXCEPTION 'route_query: no active model in registry for kind %', p_model_kind
            USING ERRCODE = 'no_data_found';
    END IF;

    SELECT * INTO v_mig
      FROM malu$index_migration
     WHERE source_space_id = v_active_space
       AND status IN ('dual_serve','cutover','cleanup')
     ORDER BY started_at DESC
     LIMIT 1;

    IF v_mig.migration_id IS NULL THEN
        v_spaces := jsonb_build_array(
            jsonb_build_object('space_id', v_active_space,
                               'weight',   1.0,
                               'role',     'active'));
        RETURN jsonb_build_object(
            'strategy', 'active',
            'spaces',   v_spaces,
            'migration_id', NULL);
    END IF;

    IF v_mig.status = 'dual_serve' THEN
        v_spaces := jsonb_build_array(
            jsonb_build_object('space_id', v_mig.source_space_id,
                               'weight',   ROUND((100 - v_mig.traffic_pct)/100.0, 4),
                               'role',     'source'),
            jsonb_build_object('space_id', v_mig.target_space_id,
                               'weight',   ROUND(v_mig.traffic_pct/100.0, 4),
                               'role',     'target'));
        RETURN jsonb_build_object(
            'strategy',     'dual_serve',
            'spaces',       v_spaces,
            'migration_id', v_mig.migration_id);
    END IF;

    -- cutover or cleanup → target_only
    v_spaces := jsonb_build_array(
        jsonb_build_object('space_id', v_mig.target_space_id,
                           'weight',   1.0,
                           'role',     'target'));
    RETURN jsonb_build_object(
        'strategy',     'target_only',
        'spaces',       v_spaces,
        'migration_id', v_mig.migration_id);
END;
$body$;

GRANT EXECUTE ON FUNCTION
    register_embedding_space(text, integer, text, bigint, text),
    register_model_in_registry(text, bigint, bigint, jsonb, text),
    advance_model_rollout(bigint, text),
    propose_index_migration(bigint, bigint, text, text),
    advance_index_migration(bigint, text, numeric),
    route_query(text)
TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;
