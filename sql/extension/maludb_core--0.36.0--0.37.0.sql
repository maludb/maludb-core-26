\echo Use "ALTER EXTENSION maludb_core UPDATE TO '0.37.0'" to load this file. \quit

-- =====================================================================
-- maludb_core 0.36.0 → 0.37.0
--
-- Stage 6 — Local Node sync protocol + conflict records (S6-1).
--
-- Per requirements.md §3.12 (Local Memory Nodes):
--   * Hold selected memories, pending claims, source snippets, task
--     context, and synchronization metadata.
--   * Operate offline and synchronize back to the Enterprise Memory
--     Core under governance — submitting new claims, Episode Objects,
--     source packages, conflict records, deletions/tombstones, workflow
--     updates, and promotion candidates.
--   * Never act as authoritative sources of record on their own.
--
-- Doctrine baked in:
--   - Nodes submit *proposals*; the server applies them through the
--     normal register_* helpers, which enforce RLS, governance, and
--     audit. The server never trusts node payloads as authoritative.
--   - Conflicts are explicit rows (malu$node_conflict_record), not
--     silent overwrites. Resolution policies are recorded.
--   - Every accept/reject/conflict emits an audit_event.
--
-- v1 in-DB surface only. The on-the-wire sync protocol (REST/grpc) +
-- per-node agent process land as a separate service in a follow-up.
-- =====================================================================

CREATE OR REPLACE FUNCTION maludb_core_version() RETURNS text
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$ SELECT '0.37.0'::text $body$;

-- =====================================================================
-- malu$local_memory_node — registered node identity.
-- =====================================================================
CREATE TABLE malu$local_memory_node (
    node_id            bigserial PRIMARY KEY,
    owner_schema       name NOT NULL DEFAULT current_schema(),
    node_name          text NOT NULL,
    fingerprint        text NOT NULL,
    uri                text,
    description        text,
    lifecycle_state    text NOT NULL DEFAULT 'active'
        CHECK (lifecycle_state IN ('active','quarantined','revoked','retired')),
    registered_at      timestamptz NOT NULL DEFAULT now(),
    last_seen_at       timestamptz,
    revoked_at         timestamptz,
    revoked_reason     text,
    UNIQUE (owner_schema, node_name),
    UNIQUE (owner_schema, fingerprint)
);
CREATE INDEX malu$local_node_owner_idx ON malu$local_memory_node(owner_schema);
CREATE INDEX malu$local_node_state_idx
    ON malu$local_memory_node(lifecycle_state)
    WHERE lifecycle_state <> 'active';

ALTER TABLE malu$local_memory_node ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_owner ON malu$local_memory_node
    USING (owner_schema = current_schema())
    WITH CHECK (owner_schema = current_schema());

GRANT SELECT ON malu$local_memory_node TO
    maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;
GRANT INSERT, UPDATE ON malu$local_memory_node TO
    maludb_memory_admin, maludb_memory_executor;
GRANT USAGE, SELECT ON SEQUENCE malu$local_memory_node_node_id_seq TO
    maludb_memory_admin, maludb_memory_executor;

-- =====================================================================
-- malu$node_sync_record — submission queue from a node.
--
-- submission_kind enumerates §3.12 sync payload classes:
--   claim_new, fact_new, memory_new, episode_new, source_package_new,
--   workflow_update, promotion_candidate, tombstone, deletion
--
-- status: pending → {accepted, rejected, conflict}.
-- =====================================================================
CREATE TABLE malu$node_sync_record (
    submission_id        bigserial PRIMARY KEY,
    owner_schema         name NOT NULL DEFAULT current_schema(),
    node_id              bigint NOT NULL REFERENCES malu$local_memory_node(node_id) ON DELETE RESTRICT,
    submission_kind      text NOT NULL
        CHECK (submission_kind IN
              ('claim_new','fact_new','memory_new','episode_new',
               'source_package_new','workflow_update',
               'promotion_candidate','tombstone','deletion')),
    local_id             bigint,
    local_hash           text,
    payload_jsonb        jsonb NOT NULL,
    status               text NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending','accepted','rejected','conflict')),
    applied_object_type  text,
    applied_object_id    bigint,
    reason               text,
    submitted_at         timestamptz NOT NULL DEFAULT now(),
    decided_at           timestamptz,
    decided_by           name,
    UNIQUE (node_id, local_id, submission_kind)
);
CREATE INDEX malu$node_sync_owner_idx  ON malu$node_sync_record(owner_schema);
CREATE INDEX malu$node_sync_node_idx   ON malu$node_sync_record(node_id);
CREATE INDEX malu$node_sync_status_idx ON malu$node_sync_record(status)
    WHERE status = 'pending';

ALTER TABLE malu$node_sync_record ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_owner ON malu$node_sync_record
    USING (owner_schema = current_schema())
    WITH CHECK (owner_schema = current_schema());

GRANT SELECT, INSERT, UPDATE ON malu$node_sync_record TO
    maludb_memory_admin, maludb_memory_executor;
GRANT SELECT ON malu$node_sync_record TO maludb_memory_auditor;
GRANT USAGE, SELECT ON SEQUENCE malu$node_sync_record_submission_id_seq TO
    maludb_memory_admin, maludb_memory_executor;

-- =====================================================================
-- malu$node_conflict_record — explicit conflict rows.
--
-- conflict_kind: duplicate / divergent_content / stale_local /
--                retracted_on_server / tombstoned_on_server / unknown.
-- resolution:    server_wins / local_wins_with_supersession / merged /
--                discarded.
-- =====================================================================
CREATE TABLE malu$node_conflict_record (
    conflict_id          bigserial PRIMARY KEY,
    owner_schema         name NOT NULL DEFAULT current_schema(),
    submission_id        bigint NOT NULL REFERENCES malu$node_sync_record(submission_id) ON DELETE CASCADE,
    server_object_type   text,
    server_object_id     bigint,
    conflict_kind        text NOT NULL
        CHECK (conflict_kind IN
              ('duplicate','divergent_content','stale_local',
               'retracted_on_server','tombstoned_on_server','unknown')),
    resolution           text
        CHECK (resolution IS NULL OR resolution IN
              ('server_wins','local_wins_with_supersession',
               'merged','discarded')),
    resolution_notes     text,
    created_at           timestamptz NOT NULL DEFAULT now(),
    resolved_at          timestamptz,
    resolved_by          name
);
CREATE INDEX malu$node_conflict_owner_idx     ON malu$node_conflict_record(owner_schema);
CREATE INDEX malu$node_conflict_submission_idx
    ON malu$node_conflict_record(submission_id);

ALTER TABLE malu$node_conflict_record ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_owner ON malu$node_conflict_record
    USING (owner_schema = current_schema())
    WITH CHECK (owner_schema = current_schema());

GRANT SELECT, INSERT, UPDATE ON malu$node_conflict_record TO
    maludb_memory_admin, maludb_memory_executor;
GRANT SELECT ON malu$node_conflict_record TO maludb_memory_auditor;
GRANT USAGE, SELECT ON SEQUENCE malu$node_conflict_record_conflict_id_seq TO
    maludb_memory_admin, maludb_memory_executor;

-- =====================================================================
-- register_local_node — upsert by (owner_schema, node_name).
--
-- fingerprint must be globally unique within the tenant; re-registering
-- with a different fingerprint raises. Operators can re-key by first
-- revoking the old node row.
-- =====================================================================
CREATE FUNCTION register_local_node(
    p_node_name    text,
    p_fingerprint  text,
    p_uri          text DEFAULT NULL,
    p_description  text DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql
AS $body$
DECLARE v_id bigint;
BEGIN
    INSERT INTO malu$local_memory_node
        (node_name, fingerprint, uri, description)
    VALUES (p_node_name, p_fingerprint, p_uri, p_description)
    ON CONFLICT (owner_schema, node_name) DO UPDATE
        SET uri          = COALESCE(EXCLUDED.uri,         malu$local_memory_node.uri),
            description  = COALESCE(EXCLUDED.description, malu$local_memory_node.description),
            last_seen_at = now()
        WHERE malu$local_memory_node.fingerprint = EXCLUDED.fingerprint
    RETURNING node_id INTO v_id;

    IF v_id IS NULL THEN
        RAISE EXCEPTION 'register_local_node: fingerprint mismatch for node %', p_node_name
            USING ERRCODE = 'unique_violation';
    END IF;

    PERFORM audit_event('local_node_registered', NULL, NULL,
        jsonb_build_object('node_id', v_id, 'node_name', p_node_name));
    RETURN v_id;
END;
$body$;

-- =====================================================================
-- node_submit — record a sync proposal from a node.
--
-- Always lands as status='pending'. The accept/reject/conflict flow
-- is a follow-up call. Duplicate (node_id, local_id, submission_kind)
-- raises unique_violation — nodes should call node_record_conflict on
-- the existing submission_id in that case.
-- =====================================================================
CREATE FUNCTION node_submit(
    p_node_id          bigint,
    p_submission_kind  text,
    p_payload_jsonb    jsonb,
    p_local_id         bigint DEFAULT NULL,
    p_local_hash       text   DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql
AS $body$
DECLARE
    v_state text;
    v_id    bigint;
BEGIN
    SELECT lifecycle_state INTO v_state
      FROM malu$local_memory_node WHERE node_id = p_node_id;
    IF v_state IS NULL THEN
        RAISE EXCEPTION 'node_submit: node % not found', p_node_id
            USING ERRCODE = 'no_data_found';
    END IF;
    IF v_state <> 'active' THEN
        RAISE EXCEPTION 'node_submit: node % is %, submissions rejected',
            p_node_id, v_state
            USING ERRCODE = 'object_not_in_prerequisite_state';
    END IF;

    INSERT INTO malu$node_sync_record
        (node_id, submission_kind, payload_jsonb, local_id, local_hash)
    VALUES (p_node_id, p_submission_kind, p_payload_jsonb, p_local_id, p_local_hash)
    RETURNING submission_id INTO v_id;

    UPDATE malu$local_memory_node SET last_seen_at = now()
        WHERE node_id = p_node_id;

    PERFORM audit_event('node_submission', NULL, NULL,
        jsonb_build_object(
            'submission_id',    v_id,
            'node_id',          p_node_id,
            'submission_kind',  p_submission_kind,
            'local_id',         p_local_id));
    RETURN v_id;
END;
$body$;

-- =====================================================================
-- node_accept — apply a pending submission through the normal
-- register_* helpers and mark it accepted.
--
-- Applicable kinds in v1:
--   claim_new          → register_claim
--   fact_new           → register_fact (claim_ids from payload)
--   memory_new         → register_memory
--   episode_new        → register_episode
--   source_package_new → register_source_package
--
-- workflow_update / promotion_candidate / tombstone / deletion go
-- through their own flow; for v1 those are accepted as no-ops with a
-- recorded reason. The operator-driven applicator can call the
-- right register_* helper afterwards.
-- =====================================================================
CREATE FUNCTION node_accept(
    p_submission_id  bigint,
    p_reason         text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
AS $body$
DECLARE
    v_sub    malu$node_sync_record%ROWTYPE;
    v_obj_id bigint;
    v_obj_t  text;
    p        jsonb;
BEGIN
    SELECT * INTO v_sub FROM malu$node_sync_record
        WHERE submission_id = p_submission_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'node_accept: submission % not found', p_submission_id
            USING ERRCODE = 'no_data_found';
    END IF;
    IF v_sub.status <> 'pending' THEN
        RAISE EXCEPTION 'node_accept: submission % is %, not pending',
            p_submission_id, v_sub.status
            USING ERRCODE = 'object_not_in_prerequisite_state';
    END IF;

    p := v_sub.payload_jsonb;
    CASE v_sub.submission_kind
        WHEN 'claim_new' THEN
            v_obj_id := register_claim(
                p_subject        => p ->> 'subject',
                p_verb           => p ->> 'verb',
                p_object_value   => p ->> 'object_value',
                p_predicate      => p ->> 'predicate',
                p_statement_text => p ->> 'statement_text',
                p_statement_jsonb => p -> 'statement_jsonb',
                p_source_package_id => NULLIF(p ->> 'source_package_id', '')::bigint,
                p_sensitivity    => COALESCE(p ->> 'sensitivity','internal'));
            v_obj_t  := 'claim';
        WHEN 'fact_new' THEN
            v_obj_id := register_fact(
                p_claim_ids => COALESCE(
                    ARRAY(SELECT (jsonb_array_elements_text(p -> 'claim_ids'))::bigint),
                    ARRAY[]::bigint[]),
                p_subject        => p ->> 'subject',
                p_verb           => p ->> 'verb',
                p_object_value   => p ->> 'object_value',
                p_statement_text => p ->> 'statement_text',
                p_verification_scope  => p ->> 'verification_scope',
                p_verification_method => p ->> 'verification_method',
                p_sensitivity    => COALESCE(p ->> 'sensitivity','internal'));
            v_obj_t := 'fact';
        WHEN 'memory_new' THEN
            v_obj_id := register_memory(
                p_memory_kind => p ->> 'memory_kind',
                p_title       => p ->> 'title',
                p_summary     => p ->> 'summary',
                p_payload_jsonb => COALESCE(p -> 'payload_jsonb', '{}'::jsonb),
                p_sensitivity => COALESCE(p ->> 'sensitivity','internal'));
            v_obj_t := 'memory';
        WHEN 'episode_new' THEN
            v_obj_id := register_episode(
                p_episode_kind => p ->> 'episode_kind',
                p_title        => p ->> 'title',
                p_summary      => p ->> 'summary',
                p_payload_jsonb => COALESCE(p -> 'payload_jsonb', '{}'::jsonb),
                p_sensitivity  => COALESCE(p ->> 'sensitivity','internal'));
            v_obj_t := 'episode_object';
        WHEN 'source_package_new' THEN
            v_obj_id := register_source_package(
                p_source_type  => p ->> 'source_type',
                p_content_text => p ->> 'content_text',
                p_content_jsonb => p -> 'content_jsonb',
                p_origin_jsonb => p -> 'origin_jsonb',
                p_sensitivity  => COALESCE(p ->> 'sensitivity','internal'));
            v_obj_t := 'source_package';
        ELSE
            -- Accept-as-recorded for kinds that don't have a direct
            -- register_* applicator in v1.
            v_obj_id := NULL;
            v_obj_t  := v_sub.submission_kind;
    END CASE;

    UPDATE malu$node_sync_record
       SET status              = 'accepted',
           applied_object_type = v_obj_t,
           applied_object_id   = v_obj_id,
           decided_at          = now(),
           decided_by          = current_user,
           reason              = p_reason
     WHERE submission_id = p_submission_id;

    PERFORM audit_event('node_submission_accepted', v_obj_t, v_obj_id,
        jsonb_build_object(
            'submission_id',   p_submission_id,
            'node_id',         v_sub.node_id,
            'submission_kind', v_sub.submission_kind));

    RETURN jsonb_build_object(
        'submission_id',       p_submission_id,
        'applied_object_type', v_obj_t,
        'applied_object_id',   v_obj_id);
END;
$body$;

-- =====================================================================
-- node_reject — refuse a submission.
-- =====================================================================
CREATE FUNCTION node_reject(
    p_submission_id  bigint,
    p_reason         text
) RETURNS void
LANGUAGE plpgsql
AS $body$
DECLARE v_node_id bigint; v_kind text;
BEGIN
    UPDATE malu$node_sync_record
       SET status     = 'rejected',
           decided_at = now(),
           decided_by = current_user,
           reason     = p_reason
     WHERE submission_id = p_submission_id AND status = 'pending'
    RETURNING node_id, submission_kind INTO v_node_id, v_kind;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'node_reject: submission % missing or not pending',
            p_submission_id
            USING ERRCODE = 'object_not_in_prerequisite_state';
    END IF;

    PERFORM audit_event('node_submission_rejected', NULL, NULL,
        jsonb_build_object(
            'submission_id', p_submission_id,
            'node_id',       v_node_id,
            'submission_kind', v_kind,
            'reason',        p_reason));
END;
$body$;

-- =====================================================================
-- node_record_conflict — emit an explicit conflict row + flip the
-- submission status to 'conflict' (terminal pending alt-state).
-- =====================================================================
CREATE FUNCTION node_record_conflict(
    p_submission_id      bigint,
    p_conflict_kind      text,
    p_server_object_type text DEFAULT NULL,
    p_server_object_id   bigint DEFAULT NULL,
    p_resolution         text DEFAULT NULL,
    p_resolution_notes   text DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql
AS $body$
DECLARE
    v_id      bigint;
    v_node_id bigint;
BEGIN
    UPDATE malu$node_sync_record
       SET status     = 'conflict',
           decided_at = now(),
           decided_by = current_user,
           reason     = COALESCE(p_resolution_notes, p_conflict_kind)
     WHERE submission_id = p_submission_id
       AND status IN ('pending')
    RETURNING node_id INTO v_node_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'node_record_conflict: submission % missing or not pending',
            p_submission_id
            USING ERRCODE = 'object_not_in_prerequisite_state';
    END IF;

    INSERT INTO malu$node_conflict_record
        (submission_id, server_object_type, server_object_id,
         conflict_kind, resolution, resolution_notes,
         resolved_at, resolved_by)
    VALUES (p_submission_id, p_server_object_type, p_server_object_id,
            p_conflict_kind, p_resolution, p_resolution_notes,
            CASE WHEN p_resolution IS NOT NULL THEN now() END,
            CASE WHEN p_resolution IS NOT NULL THEN current_user END)
    RETURNING conflict_id INTO v_id;

    PERFORM audit_event('node_submission_conflict',
        p_server_object_type, p_server_object_id,
        jsonb_build_object(
            'submission_id', p_submission_id,
            'conflict_id',   v_id,
            'node_id',       v_node_id,
            'conflict_kind', p_conflict_kind,
            'resolution',    p_resolution));

    RETURN v_id;
END;
$body$;

-- =====================================================================
-- revoke_local_node — terminal state for a compromised or retired node.
-- =====================================================================
CREATE FUNCTION revoke_local_node(
    p_node_id  bigint,
    p_reason   text
) RETURNS void
LANGUAGE plpgsql
AS $body$
BEGIN
    UPDATE malu$local_memory_node
       SET lifecycle_state = 'revoked',
           revoked_at      = now(),
           revoked_reason  = p_reason
     WHERE node_id = p_node_id AND lifecycle_state <> 'revoked';
    IF NOT FOUND THEN
        RAISE EXCEPTION 'revoke_local_node: node % missing or already revoked',
            p_node_id
            USING ERRCODE = 'object_not_in_prerequisite_state';
    END IF;

    PERFORM audit_event('local_node_revoked', NULL, NULL,
        jsonb_build_object('node_id', p_node_id, 'reason', p_reason));
END;
$body$;

GRANT EXECUTE ON FUNCTION
    register_local_node(text, text, text, text),
    node_submit(bigint, text, jsonb, bigint, text),
    node_accept(bigint, text),
    node_reject(bigint, text),
    node_record_conflict(bigint, text, text, bigint, text, text),
    revoke_local_node(bigint, text)
TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;

-- =====================================================================
-- Stage-boundary roadmap update: malu$local_memory_node and
-- malu$node_sync_record now legitimately installed.
-- =====================================================================
CREATE OR REPLACE FUNCTION stage_boundary_violations()
RETURNS TABLE(object_kind text, object_name text, stage smallint)
LANGUAGE sql STABLE
AS $body$
    WITH forbidden(name, stage) AS (
        VALUES
            ('malu$governed_object'::text,       2::smallint),
            ('malu$generalized_workflow',        5),
            ('malu$procedural_memory_object',    5),
            ('malu$competency_package',          5)
    )
    SELECT 'table'::text, c.relname::text, f.stage
    FROM pg_catalog.pg_class c
    JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
    JOIN forbidden f ON f.name = c.relname
    WHERE n.nspname = 'maludb_core'
      AND c.relkind IN ('r','p','v','m')
    ORDER BY f.stage, c.relname;
$body$;
