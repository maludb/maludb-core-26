\echo Use "ALTER EXTENSION maludb_core UPDATE TO '0.53.0'" to load this file. \quit

-- =====================================================================
-- maludb_core 0.52.0 → 0.53.0
--
-- Stage 14 / V3-RET-01: public retrieval endpoint + envelope.
--
-- Stage 4 already defined `malu$retrieval_envelope` as a plan record
-- (cue_text, object_types, hints, plan_jsonb, actor_role). This
-- migration EXTENDS that table with the V3 fields the public retrieval
-- endpoint needs — account_id, partitions, temporal_mode, started_at,
-- finished_at, candidate_counts, final_count, authz_decisions — and
-- adds malu$retrieval_decision_audit for per-stage authz breadcrumbs.
--
-- retrieve_with_envelope wraps the existing execute_retrieval, records
-- the envelope, and emits planning/assembly decision rows.
-- retrieve_envelope_debug exposes the per-stage breakdown to
-- maludb_memory_auditor members only.
--
-- Apply with:
--   ALTER EXTENSION maludb_core UPDATE TO '0.53.0';
-- =====================================================================

CREATE OR REPLACE FUNCTION maludb_core_version() RETURNS text
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$ SELECT '0.53.0'::text $body$;

-- ---------------------------------------------------------------------
-- Extend malu$retrieval_envelope (Stage 4) with V3 fields.
-- ---------------------------------------------------------------------
ALTER TABLE malu$retrieval_envelope
    ADD COLUMN account_id        bigint,
    ADD COLUMN partitions        text[]      NOT NULL DEFAULT ARRAY[]::text[],
    ADD COLUMN temporal_mode     text        NOT NULL DEFAULT 'current_valid'
        CHECK (temporal_mode IN
            ('current_valid','historical_valid','as_of_transaction_time','full_bitemporal')),
    ADD COLUMN started_at        timestamptz,
    ADD COLUMN finished_at       timestamptz,
    ADD COLUMN candidate_counts  jsonb,
    ADD COLUMN final_count       integer,
    ADD COLUMN authz_decisions   jsonb;

CREATE INDEX malu$retrieval_envelope_account_idx
    ON malu$retrieval_envelope(account_id, created_at DESC) WHERE account_id IS NOT NULL;
CREATE INDEX malu$retrieval_envelope_partitions_gin
    ON malu$retrieval_envelope USING gin (partitions)
    WHERE partitions IS NOT NULL AND cardinality(partitions) > 0;

-- ---------------------------------------------------------------------
-- malu$retrieval_decision_audit
-- ---------------------------------------------------------------------
CREATE TABLE malu$retrieval_decision_audit (
    decision_id    bigserial PRIMARY KEY,
    envelope_id    bigint    NOT NULL REFERENCES malu$retrieval_envelope(envelope_id) ON DELETE CASCADE,
    stage          text      NOT NULL CHECK (stage IN ('planning','expansion','assembly')),
    allowed        boolean   NOT NULL,
    reason         text,
    object_type    text,
    object_id      bigint,
    decided_at     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX malu$retrieval_decision_audit_envelope_idx
    ON malu$retrieval_decision_audit(envelope_id, decided_at);

ALTER TABLE malu$retrieval_decision_audit ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_via_envelope ON malu$retrieval_decision_audit
    USING (
        EXISTS (
            SELECT 1 FROM malu$retrieval_envelope e
            WHERE e.envelope_id  = malu$retrieval_decision_audit.envelope_id
              AND e.owner_schema = current_schema()
        )
    )
    WITH CHECK (
        EXISTS (
            SELECT 1 FROM malu$retrieval_envelope e
            WHERE e.envelope_id  = malu$retrieval_decision_audit.envelope_id
              AND e.owner_schema = current_schema()
        )
    );

GRANT SELECT, INSERT, UPDATE, DELETE ON malu$retrieval_decision_audit TO maludb_memory_admin;
GRANT SELECT, INSERT, UPDATE         ON malu$retrieval_decision_audit TO maludb_memory_executor;
GRANT SELECT                          ON malu$retrieval_decision_audit TO maludb_memory_auditor;

GRANT USAGE, SELECT ON SEQUENCE malu$retrieval_decision_audit_decision_id_seq TO
    maludb_memory_admin, maludb_memory_executor;

-- =====================================================================
-- retrieve_with_envelope — wraps execute_retrieval; records envelope.
-- =====================================================================
CREATE FUNCTION retrieve_with_envelope(
    p_cue_text          text,
    p_object_types      text[]      DEFAULT NULL,
    p_valid_as_of       timestamptz DEFAULT NULL,
    p_transaction_as_of timestamptz DEFAULT NULL,
    p_confidence_floor  numeric     DEFAULT NULL,
    p_hints             jsonb       DEFAULT '{}'::jsonb,
    p_partitions        text[]      DEFAULT ARRAY[]::text[],
    p_hint_name         text        DEFAULT NULL,
    p_limit             integer     DEFAULT 20,
    p_temporal_mode     text        DEFAULT 'current_valid'
) RETURNS SETOF malu$retrieval_hit
    LANGUAGE plpgsql VOLATILE
    AS $body$
#variable_conflict use_column
DECLARE
    v_envelope_id  bigint;
    v_envelope     malu$retrieval_envelope_t;
    v_started      timestamptz := now();
    v_count        integer;
BEGIN
    INSERT INTO malu$retrieval_envelope
        (account_id, cue_text, hints, partitions, temporal_mode,
         object_types, valid_as_of, transaction_as_of, confidence_floor,
         started_at)
    VALUES
        (current_account_id(), p_cue_text,
         COALESCE(p_hints, '{}'::jsonb),
         COALESCE(p_partitions, ARRAY[]::text[]),
         p_temporal_mode,
         COALESCE(p_object_types, ARRAY['claim','fact','memory','episode_object']),
         p_valid_as_of, p_transaction_as_of, p_confidence_floor,
         v_started)
    RETURNING envelope_id INTO v_envelope_id;

    INSERT INTO malu$retrieval_decision_audit
        (envelope_id, stage, allowed, reason)
    VALUES
        (v_envelope_id, 'planning', true,
         CASE WHEN p_hint_name IS NULL THEN 'no_hint'
              ELSE 'hint:'||p_hint_name END);

    v_envelope := ROW(p_cue_text, p_object_types,
                      p_valid_as_of, p_transaction_as_of,
                      p_confidence_floor, p_hints)::malu$retrieval_envelope_t;

    CREATE TEMP TABLE _retrieval_tmp ON COMMIT DROP AS
        SELECT row_number() OVER ()::int AS rn, h.*
          FROM execute_retrieval(v_envelope, p_hint_name, p_limit) h;

    SELECT count(*)::integer INTO v_count FROM _retrieval_tmp;

    INSERT INTO malu$retrieval_decision_audit
        (envelope_id, stage, allowed, reason, object_type, object_id)
    SELECT v_envelope_id, 'assembly', true, 'object included',
           t.object_type, t.object_id
      FROM _retrieval_tmp t;

    UPDATE malu$retrieval_envelope
       SET finished_at      = now(),
           final_count      = v_count,
           candidate_counts = jsonb_build_object('final_count', v_count, 'limit', p_limit),
           authz_decisions  = jsonb_build_object('stages',
                                jsonb_build_array(
                                    jsonb_build_object('stage','planning',  'allowed', true),
                                    jsonb_build_object('stage','expansion', 'allowed', true),
                                    jsonb_build_object('stage','assembly',  'allowed', true)))
     WHERE envelope_id = v_envelope_id;

    PERFORM audit_event('retrieve_with_envelope', 'malu$retrieval_envelope', v_envelope_id,
        jsonb_build_object('cue_text', p_cue_text, 'limit', p_limit,
                           'temporal_mode', p_temporal_mode,
                           'final_count', v_count),
        NULL);

    RETURN QUERY
    SELECT object_type, object_id, title, snippet, rank, strategy, metadata
      FROM _retrieval_tmp ORDER BY rn;

    DROP TABLE _retrieval_tmp;
END;
$body$;
REVOKE EXECUTE ON FUNCTION retrieve_with_envelope(text, text[], timestamptz, timestamptz, numeric, jsonb, text[], text, integer, text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION retrieve_with_envelope(text, text[], timestamptz, timestamptz, numeric, jsonb, text[], text, integer, text) TO
    maludb_memory_admin, maludb_memory_executor;

CREATE FUNCTION retrieve_envelope_debug(p_envelope_id bigint)
    RETURNS TABLE (
        envelope_id      bigint,
        cue_text         text,
        partitions       text[],
        temporal_mode    text,
        started_at       timestamptz,
        finished_at      timestamptz,
        final_count      integer,
        candidate_counts jsonb,
        authz_decisions  jsonb,
        per_stage        jsonb
    ) LANGUAGE plpgsql STABLE
    AS $body$
#variable_conflict use_column
BEGIN
    IF NOT pg_has_role(session_user, 'maludb_memory_auditor', 'MEMBER') THEN
        RAISE EXCEPTION 'retrieve_envelope_debug: requires maludb_memory_auditor membership'
            USING ERRCODE = 'insufficient_privilege';
    END IF;

    RETURN QUERY
    SELECT e.envelope_id, e.cue_text, e.partitions, e.temporal_mode,
           e.started_at, e.finished_at, e.final_count,
           e.candidate_counts, e.authz_decisions,
           COALESCE((
                SELECT jsonb_agg(jsonb_build_object(
                            'stage', d.stage,
                            'allowed', d.allowed,
                            'reason', d.reason,
                            'object_type', d.object_type,
                            'object_id', d.object_id))
                  FROM malu$retrieval_decision_audit d
                 WHERE d.envelope_id = e.envelope_id),
                '[]'::jsonb)
      FROM malu$retrieval_envelope e
     WHERE e.envelope_id = p_envelope_id;
END;
$body$;
REVOKE EXECUTE ON FUNCTION retrieve_envelope_debug(bigint) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION retrieve_envelope_debug(bigint) TO
    maludb_memory_admin, maludb_memory_auditor;
