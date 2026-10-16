-- =====================================================================
-- maludb_core 0.65.0 -> 0.66.0  (V4 Stage 17 — V4-PAGEINDEX-02)
--
-- Promotion path and builder substrate for V4 PageIndex.
--
-- What this migration adds:
--   1. malu$structure_pass_audit — one row per deterministic structure
--      pass run by the builder worker. Captures parser kind / version,
--      outline-node and leaf counts, the deterministic inputs hash
--      (sha256 over parser_kind + parser_version + source_bytes), and
--      the outcome.
--   2. malu$embedding_job.precomputed_boundaries_from_tree_id — opt-in
--      column that V3-EMBED-01 callers use to tell the chunker "skip
--      your own splitter; consume leaf ranges from this tree." The
--      column is nullable so the existing embed flow is unchanged.
--   3. embedding_enqueue extended with the new optional parameter.
--      The function is dropped and recreated because PostgreSQL does
--      not allow CREATE OR REPLACE FUNCTION to change the parameter
--      list. Existing callers passing the original six arguments are
--      unaffected because the seventh argument defaults to NULL.
--   4. source_package_promote_to_page_index — operator-visible promotion
--      helper. Registers a tree row, auto-registers the
--      'pageindex_build' V3-QUEUE-01 queue, enqueues a job carrying
--      the tree_id and builder options, and writes a malu$audit_event
--      row for the promotion. Returns the new tree_id.
--   5. page_index_record_structure_pass — worker-visible helper called
--      after the deterministic outline extraction completes. Inserts
--      the audit row and emits a malu$audit_event.
--   6. page_index_record_node — atomic node-insert helper. One call
--      writes the MDO row (mdo_kind='page_index_node') AND the
--      malu$derivation_ledger entry so the doctrine invariant
--      "every derived object MUST have a ledger entry" holds at the
--      single-call level. Returns (mdo_id, derivation_id).
--   7. page_index_chunker_handoff — returns the leaf nodes of a tree
--      in document order. Called by the V3-EMBED-01 chunker when
--      `precomputed_boundaries_from_tree_id` is supplied — the chunker
--      consumes the leaf set instead of running its own splitter.
--
-- Out of scope at this migration:
--   * Builder worker binary — lives in services/maludb-pageindexd/.
--   * Per-leaf malu$source_object_reference linking — V4-STOR-02
--     integration is a follow-up; for v1 the builder records anchors
--     inside the node's body_jsonb so the supersession test does not
--     depend on V3-STOR-01 promotion being wired into Stage-2 Source
--     Packages.
--   * Retrieval planner descent (V4-PAGEINDEX-03).
--
-- Apply with:
--   ALTER EXTENSION maludb_core UPDATE TO '0.66.0';
-- =====================================================================

CREATE OR REPLACE FUNCTION maludb_core_version() RETURNS text
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$ SELECT '0.66.0'::text $body$;

-- =====================================================================
-- 1. malu$structure_pass_audit
-- =====================================================================
CREATE TABLE malu$structure_pass_audit (
    audit_id                    bigserial PRIMARY KEY,
    owner_schema                name NOT NULL DEFAULT current_schema(),
    tree_id                     bigint NOT NULL
        REFERENCES malu$page_index_tree(tree_id) ON DELETE CASCADE,
    parser_kind                 text NOT NULL
        CHECK (parser_kind IN ('pdf','markdown','plain_text')),
    parser_version              text NOT NULL,
    started_at                  timestamptz NOT NULL DEFAULT now(),
    finished_at                 timestamptz,
    outline_node_count          integer NOT NULL DEFAULT 0
        CHECK (outline_node_count >= 0),
    leaf_count                  integer NOT NULL DEFAULT 0
        CHECK (leaf_count >= 0),
    deterministic_inputs_hash   text NOT NULL,
    outcome                     text NOT NULL DEFAULT 'ok'
        CHECK (outcome IN ('ok','partial','failed')),
    error_text                  text,
    created_at                  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX malu$structure_pass_audit_tree_idx
    ON malu$structure_pass_audit(tree_id);
CREATE INDEX malu$structure_pass_audit_outcome_idx
    ON malu$structure_pass_audit(outcome, created_at DESC);

ALTER TABLE malu$structure_pass_audit ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_owner ON malu$structure_pass_audit
    USING      (owner_schema = current_schema())
    WITH CHECK (owner_schema = current_schema());

GRANT SELECT ON malu$structure_pass_audit TO
    maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;
GRANT INSERT, UPDATE ON malu$structure_pass_audit TO
    maludb_memory_admin, maludb_memory_executor, maludb_queue_worker;
GRANT USAGE, SELECT ON SEQUENCE malu$structure_pass_audit_audit_id_seq TO
    maludb_memory_admin, maludb_memory_executor, maludb_queue_worker;

-- =====================================================================
-- 2. Extend malu$embedding_job with the precomputed-boundaries opt-in.
-- =====================================================================
ALTER TABLE malu$embedding_job
    ADD COLUMN precomputed_boundaries_from_tree_id bigint
        REFERENCES malu$page_index_tree(tree_id) ON DELETE SET NULL;
CREATE INDEX malu$embedding_job_tree_idx
    ON malu$embedding_job(precomputed_boundaries_from_tree_id)
    WHERE precomputed_boundaries_from_tree_id IS NOT NULL;

-- =====================================================================
-- 3. embedding_enqueue with optional precomputed_boundaries_from_tree_id.
-- =====================================================================
DROP FUNCTION embedding_enqueue(text, bigint, text, text, bytea, text);

CREATE FUNCTION embedding_enqueue(
    p_target_kind                          text,
    p_target_id                            bigint,
    p_model_alias                          text,
    p_embedding_space                      text,
    p_input_hash                           bytea   DEFAULT NULL,
    p_prompt_template_version              text    DEFAULT NULL,
    p_precomputed_boundaries_from_tree_id  bigint  DEFAULT NULL
) RETURNS bigint
    LANGUAGE plpgsql VOLATILE
    AS $body$
#variable_conflict use_column
DECLARE
    v_job_id     bigint;
    v_queue_job  bigint;
BEGIN
    IF p_target_kind NOT IN ('source_excerpt','memory_chunk','workflow_trace','summary','query_envelope') THEN
        RAISE EXCEPTION 'embedding_enqueue: target_kind must be one of source_excerpt/memory_chunk/workflow_trace/summary/query_envelope'
            USING ERRCODE = 'check_violation';
    END IF;

    PERFORM queue_register('embed', 60000, 3, NULL, 'V3-EMBED-01 embedding job queue');

    INSERT INTO malu$embedding_job
        (target_kind, target_id, model_alias, embedding_space,
         prompt_template_version, input_hash, status,
         precomputed_boundaries_from_tree_id)
    VALUES
        (p_target_kind, p_target_id, p_model_alias, p_embedding_space,
         p_prompt_template_version, p_input_hash, 'pending',
         p_precomputed_boundaries_from_tree_id)
    RETURNING job_id INTO v_job_id;

    v_queue_job := queue_enqueue(
        'embed',
        jsonb_build_object(
            'embedding_job_id', v_job_id,
            'target_kind',      p_target_kind,
            'target_id',        p_target_id,
            'model_alias',      p_model_alias,
            'embedding_space',  p_embedding_space,
            'prompt_template_version', p_prompt_template_version,
            'precomputed_boundaries_from_tree_id', p_precomputed_boundaries_from_tree_id),
        format('embed:%s:%s:%s:%s', p_target_kind, p_target_id, p_model_alias, p_embedding_space),
        0, NULL, NULL);

    UPDATE malu$embedding_job
       SET queue_job_id = v_queue_job
     WHERE job_id = v_job_id;

    PERFORM audit_event('embedding_enqueue', 'malu$embedding_job', v_job_id,
        jsonb_build_object('target_kind', p_target_kind, 'target_id', p_target_id,
                           'model_alias', p_model_alias, 'embedding_space', p_embedding_space,
                           'queue_job_id', v_queue_job,
                           'precomputed_boundaries_from_tree_id', p_precomputed_boundaries_from_tree_id),
        NULL);

    RETURN v_job_id;
END;
$body$;
REVOKE EXECUTE ON FUNCTION embedding_enqueue(text, bigint, text, text, bytea, text, bigint) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION embedding_enqueue(text, bigint, text, text, bytea, text, bigint) TO
    maludb_memory_admin, maludb_memory_executor;

-- =====================================================================
-- 4. source_package_promote_to_page_index — operator-facing promotion.
-- =====================================================================
CREATE FUNCTION source_package_promote_to_page_index(
    p_source_package_id    bigint,
    p_parser_kind          text,
    p_model_alias_id       bigint  DEFAULT NULL,
    p_prompt_template_id   bigint  DEFAULT NULL,
    p_builder_options      jsonb   DEFAULT '{}'::jsonb
) RETURNS bigint
LANGUAGE plpgsql
AS $body$
#variable_conflict use_column
DECLARE
    v_tree_id      bigint;
    v_queue_job_id bigint;
BEGIN
    v_tree_id := page_index_tree_register(
        p_source_package_id, p_parser_kind,
        p_model_alias_id, p_prompt_template_id);

    -- Idempotent registration of the V4 builder queue.
    PERFORM queue_register('pageindex_build', 120000, 3, NULL,
        'V4-PAGEINDEX-02 tree builder job queue');

    v_queue_job_id := queue_enqueue(
        'pageindex_build',
        jsonb_build_object(
            'tree_id',            v_tree_id,
            'source_package_id',  p_source_package_id,
            'parser_kind',        p_parser_kind,
            'model_alias_id',     p_model_alias_id,
            'prompt_template_id', p_prompt_template_id,
            'builder_options',    p_builder_options),
        format('pageindex:%s', v_tree_id),
        0, NULL, NULL);

    PERFORM audit_event(
        'page_index_tree.promote',
        'page_index_tree', v_tree_id,
        jsonb_build_object(
            'source_package_id', p_source_package_id,
            'parser_kind',       p_parser_kind,
            'queue_job_id',      v_queue_job_id,
            'builder_options',   p_builder_options));

    RETURN v_tree_id;
END;
$body$;

-- =====================================================================
-- 5. page_index_record_structure_pass — worker writes audit row.
-- =====================================================================
CREATE FUNCTION page_index_record_structure_pass(
    p_tree_id                    bigint,
    p_parser_kind                text,
    p_parser_version             text,
    p_outline_node_count         integer,
    p_leaf_count                 integer,
    p_deterministic_inputs_hash  text,
    p_outcome                    text   DEFAULT 'ok',
    p_error_text                 text   DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql
AS $body$
DECLARE
    v_id bigint;
BEGIN
    INSERT INTO malu$structure_pass_audit
        (tree_id, parser_kind, parser_version,
         outline_node_count, leaf_count,
         deterministic_inputs_hash, outcome, error_text,
         finished_at)
    VALUES
        (p_tree_id, p_parser_kind, p_parser_version,
         p_outline_node_count, p_leaf_count,
         p_deterministic_inputs_hash, p_outcome, p_error_text,
         now())
    RETURNING audit_id INTO v_id;

    PERFORM audit_event(
        'page_index_tree.structure_pass',
        'page_index_tree', p_tree_id,
        jsonb_build_object('audit_id', v_id, 'outcome', p_outcome,
                           'outline_node_count', p_outline_node_count,
                           'leaf_count',         p_leaf_count,
                           'parser_kind',        p_parser_kind,
                           'parser_version',     p_parser_version));
    RETURN v_id;
END;
$body$;

-- =====================================================================
-- 6. page_index_record_node — atomic MDO + ledger insert per node.
-- =====================================================================
CREATE FUNCTION page_index_record_node(
    p_tree_id              bigint,
    p_parent_mdo_id        bigint,
    p_node_kind            text,
    p_title                text,
    p_summary              text,
    p_model_alias_id       bigint   DEFAULT NULL,
    p_prompt_template_id   bigint   DEFAULT NULL,
    p_input_hash           bytea    DEFAULT NULL,
    p_output_hash          bytea    DEFAULT NULL,
    p_anchor_jsonb         jsonb    DEFAULT NULL
) RETURNS TABLE (mdo_id bigint, derivation_id bigint)
LANGUAGE plpgsql
AS $body$
#variable_conflict use_column
DECLARE
    v_mdo_id    bigint;
    v_deriv_id  bigint;
    v_inputs    jsonb;
BEGIN
    IF p_node_kind NOT IN ('internal','leaf') THEN
        RAISE EXCEPTION 'page_index_record_node: node_kind must be internal or leaf'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    INSERT INTO malu$memory_detail_object
        (parent_mdo_id, detail_kind, mdo_kind,
         tree_id, node_kind, title, summary, body_jsonb)
    VALUES
        (p_parent_mdo_id, 'page_index_node', 'page_index_node',
         p_tree_id, p_node_kind, p_title, p_summary, p_anchor_jsonb)
    RETURNING mdo_id INTO v_mdo_id;

    v_inputs := jsonb_build_object(
        'tree_id',       p_tree_id,
        'parent_mdo_id', p_parent_mdo_id,
        'node_kind',     p_node_kind,
        'anchor',        p_anchor_jsonb,
        'input_hash',    CASE WHEN p_input_hash  IS NULL THEN NULL ELSE encode(p_input_hash,  'hex') END,
        'output_hash',   CASE WHEN p_output_hash IS NULL THEN NULL ELSE encode(p_output_hash, 'hex') END);

    v_deriv_id := record_derivation(
        'page_index_node', v_mdo_id,
        NULL,
        p_model_alias_id,
        p_prompt_template_id,
        NULL, NULL, NULL,
        v_inputs);

    RETURN QUERY SELECT v_mdo_id, v_deriv_id;
END;
$body$;

-- =====================================================================
-- 7. page_index_chunker_handoff — leaf set in document order.
-- =====================================================================
CREATE FUNCTION page_index_chunker_handoff(p_tree_id bigint)
RETURNS TABLE (
    leaf_mdo_id bigint,
    title       text,
    summary     text,
    anchor      jsonb)
LANGUAGE sql STABLE
AS $body$
    SELECT mdo_id, title, summary, body_jsonb
    FROM malu$memory_detail_object
    WHERE tree_id  = p_tree_id
      AND mdo_kind = 'page_index_node'
      AND node_kind = 'leaf'
    ORDER BY mdo_id;
$body$;

-- =====================================================================
-- 8. Grants on the new helpers.
-- =====================================================================
GRANT EXECUTE ON FUNCTION
    source_package_promote_to_page_index(bigint, text, bigint, bigint, jsonb),
    page_index_record_structure_pass(bigint, text, text, integer, integer, text, text, text),
    page_index_record_node(bigint, bigint, text, text, text, bigint, bigint, bytea, bytea, jsonb),
    page_index_chunker_handoff(bigint)
TO maludb_memory_admin, maludb_memory_executor, maludb_queue_worker;
