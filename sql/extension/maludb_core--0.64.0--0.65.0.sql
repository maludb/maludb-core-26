-- =====================================================================
-- maludb_core 0.64.0 -> 0.65.0  (V4 Stage 17 — V4-PAGEINDEX-01)
--
-- Tree catalog and MDO specialization for the V4 PageIndex track.
--
-- This migration introduces:
--   1. malu$page_index_tree — header row per build generation.
--   2. mdo_kind discriminator + tree-node columns on
--      malu$memory_detail_object. Default 'memory_detail' so existing
--      callers behave unchanged.
--   3. malu$derivation_ledger.derived_object_type CHECK extended to
--      accept 'page_index_tree' and 'page_index_node' (ledger coverage
--      for the new derived objects).
--   4. malu$relationship_edge source/target CHECK extended to admit
--      'page_index_tree' (lets the supersedes edge connect prior and
--      new trees through the existing edge surface).
--   5. SQL APIs: page_index_tree_register / _mark_building /
--      _mark_ready / _mark_failed / _supersede. Each writes a
--      malu$audit_event row for the transition.
--
-- Access model: RLS on the new tables, tenancy by owner_schema.
-- No tier views (MALU_USER_* / MALU_ALL_* / MALU_DBA_*) are introduced
-- here — V4 follows V3 RLS-on-base-tables practice. See
-- version4-pageindex-plan.md §10.11 for the deferred tier-view
-- decision.
--
-- Promotion path (source_package_promote_to_page_index), builder worker
-- (services/maludb-pageindexd/), and the structure-pass audit table
-- (malu$structure_pass_audit) land in V4-PAGEINDEX-02 / 0.65.0->0.66.0.
-- This migration explicitly does NOT install any of them.
--
-- Apply with:
--   ALTER EXTENSION maludb_core UPDATE TO '0.65.0';
-- =====================================================================

CREATE OR REPLACE FUNCTION maludb_core_version() RETURNS text
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$ SELECT '0.65.0'::text $body$;

-- =====================================================================
-- 1. malu$page_index_tree — one row per build generation.
-- =====================================================================
CREATE TABLE malu$page_index_tree (
    tree_id              bigserial PRIMARY KEY,
    owner_schema         name NOT NULL DEFAULT current_schema(),
    source_package_id    bigint NOT NULL
        REFERENCES malu$source_package(source_package_id) ON DELETE CASCADE,
    parser_kind          text NOT NULL
        CHECK (parser_kind IN ('pdf','markdown','plain_text')),
    -- model_alias_id / prompt_template_id are populated by the builder
    -- (V4-PAGEINDEX-02). Nullable at register time so a tree can sit
    -- in 'pending' before the worker picks a model.
    model_alias_id       bigint
        REFERENCES malu$model_alias(alias_id) ON DELETE SET NULL,
    prompt_template_id   bigint
        REFERENCES malu$prompt_template(template_id) ON DELETE SET NULL,
    build_status         text NOT NULL DEFAULT 'pending'
        CHECK (build_status IN (
            'pending','building','ready','stale','superseded','failed')),
    build_started_at     timestamptz,
    build_finished_at    timestamptz,
    failure_reason       text,
    superseded_by        bigint
        REFERENCES malu$page_index_tree(tree_id) ON DELETE SET NULL,
    valid_time_start     timestamptz NOT NULL DEFAULT now(),
    valid_time_end       timestamptz,
    created_at           timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX malu$page_index_tree_owner_idx
    ON malu$page_index_tree(owner_schema);
CREATE INDEX malu$page_index_tree_source_idx
    ON malu$page_index_tree(source_package_id);
CREATE INDEX malu$page_index_tree_status_idx
    ON malu$page_index_tree(build_status);
CREATE INDEX malu$page_index_tree_superseded_idx
    ON malu$page_index_tree(superseded_by) WHERE superseded_by IS NOT NULL;

ALTER TABLE malu$page_index_tree ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_owner ON malu$page_index_tree
    USING (owner_schema = current_schema())
    WITH CHECK (owner_schema = current_schema());

GRANT SELECT ON malu$page_index_tree TO
    maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;
GRANT INSERT, UPDATE ON malu$page_index_tree TO
    maludb_memory_admin, maludb_memory_executor;
GRANT USAGE, SELECT ON SEQUENCE malu$page_index_tree_tree_id_seq TO
    maludb_memory_admin, maludb_memory_executor;

-- =====================================================================
-- 2. Extend malu$memory_detail_object with the mdo_kind discriminator
--    plus tree-node columns. Default keeps existing rows / callers
--    intact.
--
--    title already exists on the table from Stage 2 — tree nodes
--    reuse it (the node's section/topic name). Only summary is new.
-- =====================================================================
ALTER TABLE malu$memory_detail_object
    ADD COLUMN mdo_kind  text NOT NULL DEFAULT 'memory_detail'
        CHECK (mdo_kind IN (
            'memory_detail',
            'page_index_node',
            'chat_index_topic',
            'chat_index_message')),
    ADD COLUMN tree_id   bigint
        REFERENCES malu$page_index_tree(tree_id) ON DELETE CASCADE,
    ADD COLUMN node_kind text
        CHECK (node_kind IS NULL OR node_kind IN ('internal','leaf')),
    ADD COLUMN summary   text;

-- Tree-node rows must reference a tree; memory_detail rows must not.
ALTER TABLE malu$memory_detail_object
    ADD CONSTRAINT malu$mdo_tree_node_shape_check CHECK (
        (mdo_kind = 'memory_detail' AND tree_id IS NULL AND node_kind IS NULL)
        OR (mdo_kind <> 'memory_detail'
            AND tree_id IS NOT NULL
            AND node_kind IS NOT NULL));

-- Stage 2 anchored every MDO row to a parent_mdo / memory / episode.
-- Tree-node rows anchor via tree_id instead. Relax the original
-- anchor check to admit either anchor kind.
ALTER TABLE malu$memory_detail_object
    DROP CONSTRAINT IF EXISTS "malu$memory_detail_object_check";
ALTER TABLE malu$memory_detail_object
    ADD CONSTRAINT "malu$memory_detail_object_check" CHECK (
        parent_mdo_id IS NOT NULL
        OR memory_id   IS NOT NULL
        OR episode_id  IS NOT NULL
        OR tree_id     IS NOT NULL);

-- Partial index — 'memory_detail' dominates row count, no point
-- indexing the common value.
CREATE INDEX malu$mdo_kind_idx
    ON malu$memory_detail_object(mdo_kind)
    WHERE mdo_kind <> 'memory_detail';
CREATE INDEX malu$mdo_tree_idx
    ON malu$memory_detail_object(tree_id)
    WHERE tree_id IS NOT NULL;

-- =====================================================================
-- 3. Extend malu$derivation_ledger.derived_object_type to admit
--    tree + tree-node derivations.
-- =====================================================================
ALTER TABLE malu$derivation_ledger
    DROP CONSTRAINT malu$derivation_ledger_derived_object_type_check;

ALTER TABLE malu$derivation_ledger
    ADD CONSTRAINT malu$derivation_ledger_derived_object_type_check
    CHECK (derived_object_type IN (
        'source_package',
        'claim',
        'fact',
        'memory',
        'episode_object',
        'memory_detail_object',
        'relationship_edge',
        'embedding',
        'page_index_tree',
        'page_index_node'
    ));

-- =====================================================================
-- 4. Extend malu$relationship_edge source/target CHECK so a
--    supersedes edge can connect prior and new trees.
-- =====================================================================
ALTER TABLE malu$relationship_edge
    DROP CONSTRAINT malu$relationship_edge_source_object_type_check;
ALTER TABLE malu$relationship_edge
    ADD CONSTRAINT malu$relationship_edge_source_object_type_check
    CHECK (source_object_type IN (
        'source_package','claim','fact','memory','episode_object',
        'memory_detail_object','page_index_tree'));

ALTER TABLE malu$relationship_edge
    DROP CONSTRAINT malu$relationship_edge_target_object_type_check;
ALTER TABLE malu$relationship_edge
    ADD CONSTRAINT malu$relationship_edge_target_object_type_check
    CHECK (target_object_type IN (
        'source_package','claim','fact','memory','episode_object',
        'memory_detail_object','page_index_tree'));

-- =====================================================================
-- 5. SQL APIs — register + status transitions. Each emits an audit row
--    via the existing audit_event helper.
-- =====================================================================

CREATE FUNCTION page_index_tree_register(
    p_source_package_id  bigint,
    p_parser_kind        text,
    p_model_alias_id     bigint DEFAULT NULL,
    p_prompt_template_id bigint DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql
AS $body$
DECLARE
    v_tree_id bigint;
BEGIN
    INSERT INTO malu$page_index_tree
        (source_package_id, parser_kind, model_alias_id, prompt_template_id)
    VALUES
        (p_source_package_id, p_parser_kind, p_model_alias_id, p_prompt_template_id)
    RETURNING tree_id INTO v_tree_id;

    PERFORM audit_event(
        'page_index_tree.register',
        'page_index_tree',
        v_tree_id,
        jsonb_build_object(
            'source_package_id', p_source_package_id,
            'parser_kind',       p_parser_kind,
            'model_alias_id',    p_model_alias_id,
            'prompt_template_id',p_prompt_template_id));

    RETURN v_tree_id;
END;
$body$;

CREATE FUNCTION page_index_tree_mark_building(p_tree_id bigint)
RETURNS void
LANGUAGE plpgsql
AS $body$
BEGIN
    UPDATE malu$page_index_tree
       SET build_status     = 'building',
           build_started_at = COALESCE(build_started_at, now())
     WHERE tree_id = p_tree_id
       AND build_status IN ('pending','failed');
    IF NOT FOUND THEN
        RAISE EXCEPTION
            'page_index_tree_mark_building: tree % not in pending/failed state',
            p_tree_id
            USING ERRCODE = 'invalid_parameter_value';
    END IF;
    PERFORM audit_event(
        'page_index_tree.mark_building',
        'page_index_tree', p_tree_id);
END;
$body$;

CREATE FUNCTION page_index_tree_mark_ready(p_tree_id bigint)
RETURNS void
LANGUAGE plpgsql
AS $body$
BEGIN
    UPDATE malu$page_index_tree
       SET build_status      = 'ready',
           build_finished_at = now()
     WHERE tree_id = p_tree_id
       AND build_status = 'building';
    IF NOT FOUND THEN
        RAISE EXCEPTION
            'page_index_tree_mark_ready: tree % not in building state',
            p_tree_id
            USING ERRCODE = 'invalid_parameter_value';
    END IF;
    PERFORM audit_event(
        'page_index_tree.mark_ready',
        'page_index_tree', p_tree_id);
END;
$body$;

CREATE FUNCTION page_index_tree_mark_failed(
    p_tree_id bigint,
    p_reason  text DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql
AS $body$
BEGIN
    UPDATE malu$page_index_tree
       SET build_status      = 'failed',
           build_finished_at = now(),
           failure_reason    = p_reason
     WHERE tree_id = p_tree_id
       AND build_status IN ('pending','building');
    IF NOT FOUND THEN
        RAISE EXCEPTION
            'page_index_tree_mark_failed: tree % not in pending/building state',
            p_tree_id
            USING ERRCODE = 'invalid_parameter_value';
    END IF;
    PERFORM audit_event(
        'page_index_tree.mark_failed',
        'page_index_tree', p_tree_id,
        jsonb_build_object('reason', p_reason));
END;
$body$;

-- page_index_tree_supersede — close the prior tree and connect it to
-- the new tree through a supersedes edge. The new tree must already
-- exist; the prior tree must be 'ready' or 'stale'. Sets superseded_by
-- FK and writes the relationship_edge row in one transaction.
CREATE FUNCTION page_index_tree_supersede(
    p_prior_tree_id bigint,
    p_new_tree_id   bigint
) RETURNS bigint
LANGUAGE plpgsql
AS $body$
DECLARE
    v_edge_id bigint;
BEGIN
    IF p_prior_tree_id = p_new_tree_id THEN
        RAISE EXCEPTION 'page_index_tree_supersede: prior and new tree must differ'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    UPDATE malu$page_index_tree
       SET build_status  = 'superseded',
           superseded_by = p_new_tree_id,
           valid_time_end = now()
     WHERE tree_id = p_prior_tree_id
       AND build_status IN ('ready','stale');
    IF NOT FOUND THEN
        RAISE EXCEPTION
            'page_index_tree_supersede: prior tree % not in ready/stale state',
            p_prior_tree_id
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    v_edge_id := register_relationship_edge(
        'page_index_tree', p_prior_tree_id,
        'page_index_tree', p_new_tree_id,
        'supersedes',
        NULL,
        jsonb_build_object('prior_tree', p_prior_tree_id,
                           'new_tree',   p_new_tree_id),
        NULL);

    PERFORM audit_event(
        'page_index_tree.supersede',
        'page_index_tree', p_prior_tree_id,
        jsonb_build_object('new_tree_id', p_new_tree_id,
                           'edge_id',     v_edge_id));

    RETURN v_edge_id;
END;
$body$;

GRANT EXECUTE ON FUNCTION
    page_index_tree_register(bigint, text, bigint, bigint),
    page_index_tree_mark_building(bigint),
    page_index_tree_mark_ready(bigint),
    page_index_tree_mark_failed(bigint, text),
    page_index_tree_supersede(bigint, bigint)
TO maludb_memory_admin, maludb_memory_executor;
