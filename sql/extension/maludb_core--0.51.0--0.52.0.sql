\echo Use "ALTER EXTENSION maludb_core UPDATE TO '0.52.0'" to load this file. \quit

-- =====================================================================
-- maludb_core 0.51.0 → 0.52.0
--
-- Stage 14 / V3-EMBED-01: embedding job pipeline.
--
-- Wires the V3-QUEUE-01 substrate into a typed embedding workflow:
--   malu$embedding_job     — one row per scheduled embedding. Carries
--                            target_kind (source_excerpt / memory_chunk /
--                            workflow_trace / summary / query_envelope),
--                            target_id, model_alias, embedding_space,
--                            prompt_template_version, input_hash, status.
--   malu$embedding_output  — one row per produced vector. Records the
--                            vector + svpor_frame_text + input/output
--                            hashes + a derivation_ledger entry.
--
-- embedding_enqueue creates a job row and enqueues a payload on the
-- V3-QUEUE-01 'embed' queue (registered on demand). Workers pull jobs,
-- run inference, and call embedding_record_output to persist the
-- vector with a malu$derivation_ledger entry of kind
-- 'memory_detail_object' (the closest existing derived_object_type
-- the ledger accepts; a future ledger migration may add 'embedding'
-- as its own kind).
--
-- Apply with:
--   ALTER EXTENSION maludb_core UPDATE TO '0.52.0';
-- =====================================================================

CREATE OR REPLACE FUNCTION maludb_core_version() RETURNS text
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$ SELECT '0.52.0'::text $body$;

-- ---------------------------------------------------------------------
-- malu$embedding_job
-- ---------------------------------------------------------------------
CREATE TABLE malu$embedding_job (
    job_id                   bigserial PRIMARY KEY,
    target_kind              text      NOT NULL CHECK (target_kind IN
                                ('source_excerpt','memory_chunk','workflow_trace',
                                 'summary','query_envelope')),
    target_id                bigint    NOT NULL,
    model_alias              text      NOT NULL,
    embedding_space          text      NOT NULL,
    prompt_template_version  text,
    input_hash               bytea,
    queue_job_id             bigint,
    status                   text      NOT NULL DEFAULT 'pending' CHECK (status IN
                                ('pending','running','completed','failed')),
    enqueued_at              timestamptz NOT NULL DEFAULT now(),
    started_at               timestamptz,
    finished_at              timestamptz,
    last_error               text,
    owner_schema             name      NOT NULL DEFAULT current_schema()
);
CREATE INDEX malu$embedding_job_target_idx
    ON malu$embedding_job(target_kind, target_id, embedding_space);
CREATE INDEX malu$embedding_job_status_idx
    ON malu$embedding_job(status, enqueued_at);

-- ---------------------------------------------------------------------
-- malu$embedding_output
-- ---------------------------------------------------------------------
CREATE TABLE malu$embedding_output (
    output_id            bigserial PRIMARY KEY,
    job_id               bigint    NOT NULL REFERENCES malu$embedding_job(job_id) ON DELETE CASCADE,
    target_kind          text      NOT NULL,
    target_id            bigint    NOT NULL,
    model_alias          text      NOT NULL,
    embedding_space      text      NOT NULL,
    vector_dim           integer   NOT NULL CHECK (vector_dim > 0),
    vector               bytea     NOT NULL,
    svpor_frame_text     text      NOT NULL,
    input_hash           bytea     NOT NULL,
    output_hash          bytea     NOT NULL,
    derivation_id        bigint    REFERENCES malu$derivation_ledger(derivation_id) ON DELETE SET NULL,
    created_at           timestamptz NOT NULL DEFAULT now(),
    owner_schema         name      NOT NULL DEFAULT current_schema(),
    CHECK (octet_length(vector) = vector_dim * 4)
);
CREATE INDEX malu$embedding_output_target_idx
    ON malu$embedding_output(target_kind, target_id, embedding_space);
CREATE INDEX malu$embedding_output_job_idx
    ON malu$embedding_output(job_id);

-- ---------------------------------------------------------------------
-- RLS — owner_schema-bound. Output rows are tenant-bound.
-- ---------------------------------------------------------------------
ALTER TABLE malu$embedding_job    ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_owner ON malu$embedding_job
    USING      (owner_schema = current_schema())
    WITH CHECK (owner_schema = current_schema());

ALTER TABLE malu$embedding_output ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_owner ON malu$embedding_output
    USING      (owner_schema = current_schema())
    WITH CHECK (owner_schema = current_schema());

GRANT SELECT, INSERT, UPDATE, DELETE ON malu$embedding_job, malu$embedding_output TO
    maludb_memory_admin;
GRANT SELECT, INSERT, UPDATE         ON malu$embedding_job, malu$embedding_output TO
    maludb_memory_executor, maludb_queue_worker;
GRANT SELECT                          ON malu$embedding_job, malu$embedding_output TO
    maludb_memory_auditor;

GRANT USAGE, SELECT ON SEQUENCE malu$embedding_job_job_id_seq       TO
    maludb_memory_admin, maludb_memory_executor, maludb_queue_worker;
GRANT USAGE, SELECT ON SEQUENCE malu$embedding_output_output_id_seq TO
    maludb_memory_admin, maludb_memory_executor, maludb_queue_worker;

-- =====================================================================
-- embedding_enqueue — record a malu$embedding_job and push it onto
-- the V3-QUEUE-01 'embed' queue. Registers the queue on first use.
-- =====================================================================
CREATE FUNCTION embedding_enqueue(
    p_target_kind              text,
    p_target_id                bigint,
    p_model_alias              text,
    p_embedding_space          text,
    p_input_hash               bytea   DEFAULT NULL,
    p_prompt_template_version  text    DEFAULT NULL
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

    -- Auto-register the embed queue (idempotent).
    PERFORM queue_register('embed', 60000, 3, NULL, 'V3-EMBED-01 embedding job queue');

    INSERT INTO malu$embedding_job
        (target_kind, target_id, model_alias, embedding_space,
         prompt_template_version, input_hash, status)
    VALUES
        (p_target_kind, p_target_id, p_model_alias, p_embedding_space,
         p_prompt_template_version, p_input_hash, 'pending')
    RETURNING job_id INTO v_job_id;

    v_queue_job := queue_enqueue(
        'embed',
        jsonb_build_object(
            'embedding_job_id', v_job_id,
            'target_kind',      p_target_kind,
            'target_id',        p_target_id,
            'model_alias',      p_model_alias,
            'embedding_space',  p_embedding_space,
            'prompt_template_version', p_prompt_template_version),
        format('embed:%s:%s:%s:%s', p_target_kind, p_target_id, p_model_alias, p_embedding_space),
        0, NULL, NULL);

    UPDATE malu$embedding_job
       SET queue_job_id = v_queue_job
     WHERE job_id = v_job_id;

    PERFORM audit_event('embedding_enqueue', 'malu$embedding_job', v_job_id,
        jsonb_build_object('target_kind', p_target_kind, 'target_id', p_target_id,
                           'model_alias', p_model_alias, 'embedding_space', p_embedding_space,
                           'queue_job_id', v_queue_job),
        NULL);

    RETURN v_job_id;
END;
$body$;
REVOKE EXECUTE ON FUNCTION embedding_enqueue(text, bigint, text, text, bytea, text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION embedding_enqueue(text, bigint, text, text, bytea, text) TO
    maludb_memory_admin, maludb_memory_executor;

-- embedding_record_output — workers call this after running inference.
-- Writes the vector + svpor frame and a malu$derivation_ledger entry.
-- Returns (output_id, derivation_id).
CREATE FUNCTION embedding_record_output(
    p_job_id           bigint,
    p_vector           malu_vector,
    p_vector_dim       integer,
    p_svpor_frame_text text,
    p_output_hash      bytea
) RETURNS TABLE (output_id bigint, derivation_id bigint)
    LANGUAGE plpgsql VOLATILE
    AS $body$
#variable_conflict use_column
DECLARE
    v_job    malu$embedding_job%ROWTYPE;
    v_oid    bigint;
    v_did    bigint;
    v_inputs jsonb;
BEGIN
    SELECT * INTO v_job FROM malu$embedding_job WHERE job_id = p_job_id;
    IF v_job.job_id IS NULL THEN
        RAISE EXCEPTION 'embedding_record_output: job % not found', p_job_id
            USING ERRCODE = 'no_data_found';
    END IF;

    -- SVPOR frame must be present per requirements.md §3.2.
    IF p_svpor_frame_text IS NULL OR length(p_svpor_frame_text) = 0 THEN
        RAISE EXCEPTION 'embedding_record_output: svpor_frame_text is required'
            USING ERRCODE = 'check_violation';
    END IF;

    v_inputs := jsonb_build_array(jsonb_build_object(
        'kind',                    'embedding_input',
        'target_kind',             v_job.target_kind,
        'target_id',               v_job.target_id,
        'model_alias',             v_job.model_alias,
        'embedding_space',         v_job.embedding_space,
        'prompt_template_version', v_job.prompt_template_version,
        'input_hash',              encode(COALESCE(v_job.input_hash, '\x00'::bytea), 'hex'),
        'svpor_frame_hash',        encode(public.digest(p_svpor_frame_text::bytea, 'sha256'), 'hex')));

    -- The Stage 2 ledger CHECK constraint accepts only the seven kinds
    -- {source_package, claim, fact, memory, episode_object,
    --  memory_detail_object, relationship_edge}. We map embedding
    -- artefacts to memory_detail_object — they're addressable derived
    -- detail rows under §3.7. A future ledger migration may add
    -- 'embedding' as its own kind.
    INSERT INTO malu$derivation_ledger
        (derived_object_type, derived_object_id, parser_name,
         model_alias_id, prompt_template_id, inputs_jsonb, inputs_hash)
    VALUES
        ('memory_detail_object', 0, 'embedding_runner',
         (SELECT alias_id FROM malu$model_alias WHERE alias_name = v_job.model_alias),
         NULL, v_inputs,
         encode(public.digest(v_inputs::text::bytea, 'sha256'), 'hex'))
    RETURNING malu$derivation_ledger.derivation_id INTO v_did;

    INSERT INTO malu$embedding_output
        (job_id, target_kind, target_id, model_alias, embedding_space,
         vector_dim, vector, svpor_frame_text,
         input_hash, output_hash, derivation_id)
    VALUES
        (p_job_id, v_job.target_kind, v_job.target_id, v_job.model_alias,
         v_job.embedding_space, p_vector_dim, p_vector, p_svpor_frame_text,
         COALESCE(v_job.input_hash, public.digest(p_svpor_frame_text::bytea, 'sha256')),
         p_output_hash, v_did)
    RETURNING malu$embedding_output.output_id INTO v_oid;

    -- Patch the ledger entry's derived_object_id to point at the
    -- output row (we inserted 0 as a placeholder above because the
    -- output_id was not yet known).
    UPDATE malu$derivation_ledger
       SET derived_object_id = v_oid
     WHERE derivation_id = v_did;

    UPDATE malu$embedding_job
       SET status      = 'completed',
           finished_at = now(),
           last_error  = NULL
     WHERE job_id = p_job_id;

    PERFORM audit_event('embedding_record_output', 'malu$embedding_output', v_oid,
        jsonb_build_object('job_id', p_job_id, 'derivation_id', v_did,
                           'vector_dim', p_vector_dim),
        NULL);

    output_id     := v_oid;
    derivation_id := v_did;
    RETURN NEXT;
END;
$body$;
REVOKE EXECUTE ON FUNCTION embedding_record_output(bigint, malu_vector, integer, text, bytea) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION embedding_record_output(bigint, malu_vector, integer, text, bytea) TO
    maludb_memory_admin, maludb_memory_executor, maludb_queue_worker;

CREATE FUNCTION embedding_results(
    p_target_kind     text,
    p_target_id       bigint,
    p_embedding_space text DEFAULT NULL
) RETURNS TABLE (
    output_id        bigint,
    model_alias      text,
    embedding_space  text,
    vector_dim       integer,
    derivation_id    bigint,
    created_at       timestamptz
) LANGUAGE plpgsql STABLE
    AS $body$
#variable_conflict use_column
BEGIN
    RETURN QUERY
    SELECT o.output_id, o.model_alias, o.embedding_space, o.vector_dim,
           o.derivation_id, o.created_at
      FROM malu$embedding_output o
     WHERE o.target_kind = p_target_kind
       AND o.target_id   = p_target_id
       AND (p_embedding_space IS NULL OR o.embedding_space = p_embedding_space)
     ORDER BY o.created_at DESC;
END;
$body$;
REVOKE EXECUTE ON FUNCTION embedding_results(text, bigint, text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION embedding_results(text, bigint, text) TO
    maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;
