-- =====================================================================
-- maludb_core 0.57.0 -> 0.58.0  (v3.1 Stage A — V3-EMBED-02)
--
-- Adds 'embedding' as a first-class kind in the Derivation Ledger.
--
-- v3.0.0 shipped embedding_record_output (Stage 14 / V3-EMBED-01) but
-- the Stage 2 ledger CHECK constraint only accepted seven kinds, so
-- embedding artefacts were recorded as 'memory_detail_object'
-- (documented as a future-migration concern in the 0.51.0->0.52.0
-- migration body). This migration:
--
--   1. Extends the CHECK constraint to allow 'embedding'.
--   2. Backfills existing ledger rows that point at malu$embedding_output
--      rows from 'memory_detail_object' to 'embedding'. The FK from
--      malu$embedding_output.derivation_id makes the set well-defined.
--   3. Updates embedding_record_output to record new rows as 'embedding'.
--
-- Apply with:
--   ALTER EXTENSION maludb_core UPDATE TO '0.58.0';
-- =====================================================================

CREATE OR REPLACE FUNCTION maludb_core_version() RETURNS text
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$ SELECT '0.58.0'::text $body$;

-- ---------------------------------------------------------------------
-- 1. Extend the derived_object_type CHECK to admit 'embedding'.
-- ---------------------------------------------------------------------
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
        'embedding'
    ));

-- ---------------------------------------------------------------------
-- 2. Backfill: rows that point at an embedding_output via the FK
--    were marked 'memory_detail_object' as a placeholder; flip them.
-- ---------------------------------------------------------------------
UPDATE malu$derivation_ledger d
   SET derived_object_type = 'embedding'
  FROM malu$embedding_output e
 WHERE e.derivation_id = d.derivation_id
   AND d.derived_object_type = 'memory_detail_object';

-- ---------------------------------------------------------------------
-- 3. embedding_record_output now records 'embedding' directly.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION embedding_record_output(
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

    INSERT INTO malu$derivation_ledger
        (derived_object_type, derived_object_id, parser_name,
         model_alias_id, prompt_template_id, inputs_jsonb, inputs_hash)
    VALUES
        ('embedding', 0, 'embedding_runner',
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
