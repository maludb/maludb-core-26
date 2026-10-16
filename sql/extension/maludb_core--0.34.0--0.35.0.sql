\echo Use "ALTER EXTENSION maludb_core UPDATE TO '0.35.0'" to load this file. \quit

-- =====================================================================
-- maludb_core 0.34.0 → 0.35.0
--
-- Stage 5 — Active Memory Pool manager (S5-3).
--
-- Per requirements.md §3.12. Active Memory Pools are scoped working
-- sets bounded by authorization, partitions, confidence thresholds,
-- and validity windows; they preserve provenance, support concurrent
-- reads/writes by humans and agents, and expose a promotion path:
--
--   active observations → pending claims → verified facts → episodes
--                                                          / workflow traces
--                                                          / procedural memories
--                                                          / skill refinements
--
-- v1 lands the in-DB surface + a clean promotion path through
-- register_claim / register_fact. WebSocket / TCP real-time channel
-- transport stays a follow-up; the §3.12 requirement that real-time
-- channels respect the same identity/partition/provenance rules is
-- already met today because every read/write goes through these RLS-
-- bound functions and tables.
--
-- Surface:
--   malu$active_memory_pool, malu$active_memory_pool_member
--   create_active_memory_pool, pool_add_observation,
--   pool_add_reference, pool_promote_to_claim, pool_promote_to_fact,
--   pool_seal, pool_archive, pool_tombstone
--
-- This phase also wires the FK that S5-2 deferred:
-- malu$skill_execution_record.active_pool_id → malu$active_memory_pool.
-- =====================================================================

CREATE OR REPLACE FUNCTION maludb_core_version() RETURNS text
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$ SELECT '0.35.0'::text $body$;

-- =====================================================================
-- malu$active_memory_pool — pool header.
--
-- creation_kind enumerates the §3.12 originators: prompt / API / MCP
-- request / structured SQL query.
--
-- The lifecycle transitions: active → sealed → archived → tombstoned.
-- A sealed pool refuses new members. An archived pool refuses any
-- write. A tombstoned pool retains rows for audit but is filtered out
-- of working-set lookups.
-- =====================================================================
CREATE TABLE malu$active_memory_pool (
    pool_id                bigserial PRIMARY KEY,
    owner_schema           name NOT NULL DEFAULT current_schema(),
    pool_name              text NOT NULL,
    creation_kind          text NOT NULL DEFAULT 'sql'
        CHECK (creation_kind IN ('prompt','api','mcp','sql')),
    created_by             name NOT NULL DEFAULT current_user,
    task_objective         text,
    authorized_partitions  text[],
    confidence_floor       numeric(5,4)
        CHECK (confidence_floor IS NULL OR (confidence_floor >= 0 AND confidence_floor <= 1)),
    validity_start         timestamptz,
    validity_end           timestamptz,
    max_member_count       integer
        CHECK (max_member_count IS NULL OR max_member_count > 0),
    lifecycle_state        text NOT NULL DEFAULT 'active'
        CHECK (lifecycle_state IN ('active','sealed','archived','tombstoned')),
    sealed_at              timestamptz,
    archived_at            timestamptz,
    tombstoned_at          timestamptz,
    created_at             timestamptz NOT NULL DEFAULT now(),
    updated_at             timestamptz NOT NULL DEFAULT now(),
    UNIQUE (owner_schema, pool_name),
    CHECK (validity_start IS NULL OR validity_end IS NULL OR validity_start <= validity_end)
);
CREATE INDEX malu$active_memory_pool_owner_idx
    ON malu$active_memory_pool(owner_schema);
CREATE INDEX malu$active_memory_pool_state_idx
    ON malu$active_memory_pool(lifecycle_state) WHERE lifecycle_state <> 'active';

ALTER TABLE malu$active_memory_pool ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_owner ON malu$active_memory_pool
    USING (owner_schema = current_schema())
    WITH CHECK (owner_schema = current_schema());

GRANT SELECT ON malu$active_memory_pool TO
    maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;
GRANT INSERT, UPDATE ON malu$active_memory_pool TO
    maludb_memory_admin, maludb_memory_executor;
GRANT USAGE, SELECT ON SEQUENCE malu$active_memory_pool_pool_id_seq TO
    maludb_memory_admin, maludb_memory_executor;

-- =====================================================================
-- malu$active_memory_pool_member — polymorphic membership.
--
-- member_kind enumerates the §3.12 working-set object classes plus
-- 'observation' (a free-form note not yet promoted to a claim) and
-- 'pending_claim' (a claim that exists but has not yet been verified
-- into a fact).
--
-- promoted_to_object_type + promoted_to_object_id record the result
-- of a promotion action; the row stays in the pool so callers can
-- audit the chain.
-- =====================================================================
CREATE TABLE malu$active_memory_pool_member (
    member_id                  bigserial PRIMARY KEY,
    owner_schema               name NOT NULL DEFAULT current_schema(),
    pool_id                    bigint NOT NULL REFERENCES malu$active_memory_pool(pool_id) ON DELETE CASCADE,
    member_kind                text NOT NULL
        CHECK (member_kind IN
               ('observation','pending_claim','memory','fact',
                'episode_object','workflow_trace','skill','source_reference')),
    member_object_type         text,
    member_object_id           bigint,
    payload_jsonb              jsonb,
    confidence                 numeric(5,4)
        CHECK (confidence IS NULL OR (confidence >= 0 AND confidence <= 1)),
    staleness                  numeric(5,4)
        CHECK (staleness  IS NULL OR (staleness  >= 0 AND staleness  <= 1)),
    access_label               text,
    provenance                 jsonb,
    added_by                   name NOT NULL DEFAULT current_user,
    added_account_id           bigint REFERENCES malu$account(account_id) ON DELETE SET NULL,
    added_at                   timestamptz NOT NULL DEFAULT now(),
    promoted_from_member_id    bigint REFERENCES malu$active_memory_pool_member(member_id) ON DELETE SET NULL,
    promoted_to_object_type    text,
    promoted_to_object_id      bigint,
    promoted_at                timestamptz,
    CHECK (
        (member_kind = 'observation' AND member_object_id IS NULL)
        OR (member_kind <> 'observation' AND member_object_id IS NOT NULL)
    )
);
CREATE INDEX malu$pool_member_pool_idx   ON malu$active_memory_pool_member(pool_id);
CREATE INDEX malu$pool_member_object_idx
    ON malu$active_memory_pool_member(member_kind, member_object_id)
    WHERE member_object_id IS NOT NULL;
CREATE UNIQUE INDEX malu$pool_member_ref_uq
    ON malu$active_memory_pool_member(pool_id, member_kind, member_object_id)
    WHERE member_object_id IS NOT NULL;

ALTER TABLE malu$active_memory_pool_member ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_owner ON malu$active_memory_pool_member
    USING (owner_schema = current_schema())
    WITH CHECK (owner_schema = current_schema());

GRANT SELECT ON malu$active_memory_pool_member TO
    maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;
GRANT INSERT, UPDATE ON malu$active_memory_pool_member TO
    maludb_memory_admin, maludb_memory_executor;
GRANT USAGE, SELECT ON SEQUENCE malu$active_memory_pool_member_member_id_seq TO
    maludb_memory_admin, maludb_memory_executor;

-- =====================================================================
-- Wire S5-2's deferred FK now that the pool table exists.
-- =====================================================================
ALTER TABLE malu$skill_execution_record
    ADD CONSTRAINT malu$skill_execution_record_active_pool_fk
    FOREIGN KEY (active_pool_id)
    REFERENCES malu$active_memory_pool(pool_id) ON DELETE SET NULL;

-- =====================================================================
-- _assert_pool_writable — common guard for add/promote/seal.
-- =====================================================================
CREATE FUNCTION _assert_pool_writable(p_pool_id bigint) RETURNS void
LANGUAGE plpgsql
AS $body$
DECLARE v_state text;
BEGIN
    SELECT lifecycle_state INTO v_state
      FROM malu$active_memory_pool
     WHERE pool_id = p_pool_id;
    IF v_state IS NULL THEN
        RAISE EXCEPTION 'active_memory_pool % not found', p_pool_id
            USING ERRCODE = 'no_data_found';
    END IF;
    IF v_state <> 'active' THEN
        RAISE EXCEPTION 'active_memory_pool % is %, not writable', p_pool_id, v_state
            USING ERRCODE = 'object_not_in_prerequisite_state';
    END IF;
END;
$body$;

-- =====================================================================
-- _assert_pool_capacity — enforce max_member_count if set.
-- =====================================================================
CREATE FUNCTION _assert_pool_capacity(p_pool_id bigint) RETURNS void
LANGUAGE plpgsql
AS $body$
DECLARE
    v_cap     integer;
    v_current integer;
BEGIN
    SELECT max_member_count INTO v_cap
      FROM malu$active_memory_pool WHERE pool_id = p_pool_id;
    IF v_cap IS NULL THEN RETURN; END IF;

    SELECT count(*) INTO v_current
      FROM malu$active_memory_pool_member
     WHERE pool_id = p_pool_id;
    IF v_current >= v_cap THEN
        RAISE EXCEPTION 'active_memory_pool % at capacity (% / %)',
            p_pool_id, v_current, v_cap
            USING ERRCODE = 'cardinality_violation';
    END IF;
END;
$body$;

-- =====================================================================
-- create_active_memory_pool — entry point per §3.12.
--
-- Upserts on (owner_schema, pool_name). Returning an existing pool_id
-- supports the case where a prompt/API/MCP request re-binds to a pool
-- that's already alive.
-- =====================================================================
CREATE FUNCTION create_active_memory_pool(
    p_pool_name             text,
    p_creation_kind         text   DEFAULT 'sql',
    p_task_objective        text   DEFAULT NULL,
    p_authorized_partitions text[] DEFAULT NULL,
    p_confidence_floor      numeric DEFAULT NULL,
    p_validity_start        timestamptz DEFAULT NULL,
    p_validity_end          timestamptz DEFAULT NULL,
    p_max_member_count      integer DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql
AS $body$
DECLARE v_id bigint;
BEGIN
    INSERT INTO malu$active_memory_pool
        (pool_name, creation_kind, task_objective, authorized_partitions,
         confidence_floor, validity_start, validity_end, max_member_count)
    VALUES (p_pool_name, p_creation_kind, p_task_objective, p_authorized_partitions,
            p_confidence_floor, p_validity_start, p_validity_end, p_max_member_count)
    ON CONFLICT (owner_schema, pool_name) DO UPDATE
        SET task_objective         = COALESCE(EXCLUDED.task_objective, malu$active_memory_pool.task_objective),
            authorized_partitions  = COALESCE(EXCLUDED.authorized_partitions, malu$active_memory_pool.authorized_partitions),
            confidence_floor       = COALESCE(EXCLUDED.confidence_floor,      malu$active_memory_pool.confidence_floor),
            validity_start         = COALESCE(EXCLUDED.validity_start,        malu$active_memory_pool.validity_start),
            validity_end           = COALESCE(EXCLUDED.validity_end,          malu$active_memory_pool.validity_end),
            max_member_count       = COALESCE(EXCLUDED.max_member_count,      malu$active_memory_pool.max_member_count),
            updated_at             = now()
    RETURNING pool_id INTO v_id;

    PERFORM audit_event('active_memory_pool_created', NULL, NULL,
        jsonb_build_object('pool_id', v_id, 'pool_name', p_pool_name,
                           'creation_kind', p_creation_kind));
    RETURN v_id;
END;
$body$;

-- =====================================================================
-- pool_add_observation — add a free-form working-set entry.
--
-- Observations don't yet have an underlying object. payload_jsonb
-- carries the raw observation. confidence/provenance/access_label are
-- preserved per §3.12 ("they are not opaque caches").
-- =====================================================================
CREATE FUNCTION pool_add_observation(
    p_pool_id      bigint,
    p_payload_jsonb jsonb,
    p_confidence   numeric DEFAULT NULL,
    p_provenance   jsonb   DEFAULT NULL,
    p_access_label text    DEFAULT NULL,
    p_account_id   bigint  DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql
AS $body$
DECLARE v_id bigint;
BEGIN
    PERFORM _assert_pool_writable(p_pool_id);
    PERFORM _assert_pool_capacity(p_pool_id);

    INSERT INTO malu$active_memory_pool_member
        (pool_id, member_kind, payload_jsonb, confidence,
         provenance, access_label, added_account_id)
    VALUES (p_pool_id, 'observation', p_payload_jsonb, p_confidence,
            p_provenance, p_access_label, p_account_id)
    RETURNING member_id INTO v_id;

    PERFORM audit_event('pool_observation_added', NULL, NULL,
        jsonb_build_object('pool_id', p_pool_id, 'member_id', v_id));
    RETURN v_id;
END;
$body$;

-- =====================================================================
-- pool_add_reference — add a typed pointer to an existing object.
--
-- The caller's RLS context still gates whether the referenced row is
-- ever observable through the pool view. The unique partial index
-- prevents adding the same (object_type, object_id) twice to a pool.
-- =====================================================================
CREATE FUNCTION pool_add_reference(
    p_pool_id            bigint,
    p_member_kind        text,
    p_member_object_type text,
    p_member_object_id   bigint,
    p_confidence         numeric DEFAULT NULL,
    p_provenance         jsonb   DEFAULT NULL,
    p_access_label       text    DEFAULT NULL,
    p_account_id         bigint  DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql
AS $body$
DECLARE v_id bigint;
BEGIN
    PERFORM _assert_pool_writable(p_pool_id);
    PERFORM _assert_pool_capacity(p_pool_id);

    IF p_member_kind = 'observation' THEN
        RAISE EXCEPTION 'pool_add_reference: use pool_add_observation for observations'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    INSERT INTO malu$active_memory_pool_member
        (pool_id, member_kind, member_object_type, member_object_id,
         confidence, provenance, access_label, added_account_id)
    VALUES (p_pool_id, p_member_kind, p_member_object_type, p_member_object_id,
            p_confidence, p_provenance, p_access_label, p_account_id)
    RETURNING member_id INTO v_id;

    PERFORM audit_event('pool_reference_added', p_member_object_type, p_member_object_id,
        jsonb_build_object('pool_id', p_pool_id,
                           'member_id', v_id,
                           'member_kind', p_member_kind));
    RETURN v_id;
END;
$body$;

-- =====================================================================
-- pool_promote_to_claim — observation → pending_claim.
--
-- Calls register_claim to materialise the claim, then either:
--   (a) inserts a new pool_member of kind 'pending_claim' carrying the
--       claim_id and the promotion link, OR
--   (b) updates the source observation in place to mark it promoted.
--
-- v1 picks (a) to preserve the audit trail: the observation row stays
-- as a leaf, and a new pending_claim row points back via
-- promoted_from_member_id.
-- =====================================================================
CREATE FUNCTION pool_promote_to_claim(
    p_member_id      bigint,
    p_subject        text DEFAULT NULL,
    p_verb           text DEFAULT NULL,
    p_object_value   text DEFAULT NULL,
    p_statement_text text DEFAULT NULL,
    p_sensitivity    text DEFAULT 'internal'
) RETURNS bigint
LANGUAGE plpgsql
AS $body$
DECLARE
    v_source malu$active_memory_pool_member%ROWTYPE;
    v_claim_id   bigint;
    v_new_member bigint;
BEGIN
    SELECT * INTO v_source FROM malu$active_memory_pool_member
        WHERE member_id = p_member_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'pool_promote_to_claim: member % not found', p_member_id
            USING ERRCODE = 'no_data_found';
    END IF;
    IF v_source.member_kind <> 'observation' THEN
        RAISE EXCEPTION 'pool_promote_to_claim: member % is %, not an observation',
            p_member_id, v_source.member_kind
            USING ERRCODE = 'invalid_parameter_value';
    END IF;
    IF v_source.promoted_to_object_id IS NOT NULL THEN
        RAISE EXCEPTION 'pool_promote_to_claim: member % already promoted to %:%',
            p_member_id, v_source.promoted_to_object_type, v_source.promoted_to_object_id
            USING ERRCODE = 'object_not_in_prerequisite_state';
    END IF;
    PERFORM _assert_pool_writable(v_source.pool_id);

    v_claim_id := register_claim(
        p_subject          => p_subject,
        p_verb             => p_verb,
        p_object_value     => p_object_value,
        p_statement_text   => p_statement_text,
        p_sensitivity      => p_sensitivity);

    INSERT INTO malu$active_memory_pool_member
        (pool_id, member_kind, member_object_type, member_object_id,
         confidence, provenance, access_label,
         promoted_from_member_id, added_account_id)
    VALUES (v_source.pool_id, 'pending_claim', 'claim', v_claim_id,
            v_source.confidence,
            COALESCE(v_source.provenance, '{}'::jsonb)
                || jsonb_build_object('promoted_from_member_id', p_member_id),
            v_source.access_label,
            p_member_id, v_source.added_account_id)
    RETURNING member_id INTO v_new_member;

    UPDATE malu$active_memory_pool_member
       SET promoted_to_object_type = 'claim',
           promoted_to_object_id   = v_claim_id,
           promoted_at             = now()
     WHERE member_id = p_member_id;

    PERFORM audit_event('pool_member_promoted', 'claim', v_claim_id,
        jsonb_build_object(
            'pool_id',         v_source.pool_id,
            'from_member_id',  p_member_id,
            'to_member_id',    v_new_member,
            'promotion_step',  'observation->pending_claim'));

    RETURN v_claim_id;
END;
$body$;

-- =====================================================================
-- pool_promote_to_fact — pending_claim → fact.
--
-- Calls register_fact with the linked claim_ids. Marks the source
-- pending_claim member as promoted to the fact. The fact row also
-- gets a new pool member of kind 'fact' so the working set surfaces
-- the verified evidence.
-- =====================================================================
CREATE FUNCTION pool_promote_to_fact(
    p_member_id           bigint,
    p_subject             text DEFAULT NULL,
    p_verb                text DEFAULT NULL,
    p_object_value        text DEFAULT NULL,
    p_statement_text      text DEFAULT NULL,
    p_verification_scope  text DEFAULT NULL,
    p_verification_method text DEFAULT NULL,
    p_sensitivity         text DEFAULT 'internal'
) RETURNS bigint
LANGUAGE plpgsql
AS $body$
DECLARE
    v_source malu$active_memory_pool_member%ROWTYPE;
    v_fact_id    bigint;
    v_new_member bigint;
BEGIN
    SELECT * INTO v_source FROM malu$active_memory_pool_member
        WHERE member_id = p_member_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'pool_promote_to_fact: member % not found', p_member_id
            USING ERRCODE = 'no_data_found';
    END IF;
    IF v_source.member_kind <> 'pending_claim' THEN
        RAISE EXCEPTION 'pool_promote_to_fact: member % is %, not a pending_claim',
            p_member_id, v_source.member_kind
            USING ERRCODE = 'invalid_parameter_value';
    END IF;
    IF v_source.promoted_to_object_id IS NOT NULL THEN
        RAISE EXCEPTION 'pool_promote_to_fact: member % already promoted to %:%',
            p_member_id, v_source.promoted_to_object_type, v_source.promoted_to_object_id
            USING ERRCODE = 'object_not_in_prerequisite_state';
    END IF;
    PERFORM _assert_pool_writable(v_source.pool_id);

    v_fact_id := register_fact(
        p_claim_ids           => ARRAY[v_source.member_object_id]::bigint[],
        p_subject             => p_subject,
        p_verb                => p_verb,
        p_object_value        => p_object_value,
        p_statement_text      => p_statement_text,
        p_verification_scope  => p_verification_scope,
        p_verification_method => p_verification_method,
        p_sensitivity         => p_sensitivity);

    INSERT INTO malu$active_memory_pool_member
        (pool_id, member_kind, member_object_type, member_object_id,
         confidence, provenance, access_label,
         promoted_from_member_id, added_account_id)
    VALUES (v_source.pool_id, 'fact', 'fact', v_fact_id,
            v_source.confidence,
            COALESCE(v_source.provenance, '{}'::jsonb)
                || jsonb_build_object('promoted_from_member_id', p_member_id),
            v_source.access_label,
            p_member_id, v_source.added_account_id)
    RETURNING member_id INTO v_new_member;

    UPDATE malu$active_memory_pool_member
       SET promoted_to_object_type = 'fact',
           promoted_to_object_id   = v_fact_id,
           promoted_at             = now()
     WHERE member_id = p_member_id;

    PERFORM audit_event('pool_member_promoted', 'fact', v_fact_id,
        jsonb_build_object(
            'pool_id',         v_source.pool_id,
            'from_member_id',  p_member_id,
            'to_member_id',    v_new_member,
            'promotion_step',  'pending_claim->fact',
            'claim_id',        v_source.member_object_id));

    RETURN v_fact_id;
END;
$body$;

-- =====================================================================
-- Lifecycle transitions.
-- =====================================================================
CREATE FUNCTION pool_seal(p_pool_id bigint, p_reason text DEFAULT NULL)
RETURNS void
LANGUAGE plpgsql
AS $body$
BEGIN
    UPDATE malu$active_memory_pool
       SET lifecycle_state = 'sealed',
           sealed_at       = now(),
           updated_at      = now()
     WHERE pool_id = p_pool_id AND lifecycle_state = 'active';
    IF NOT FOUND THEN
        RAISE EXCEPTION 'pool_seal: pool % missing or not active', p_pool_id
            USING ERRCODE = 'object_not_in_prerequisite_state';
    END IF;
    PERFORM audit_event('active_memory_pool_sealed', NULL, NULL,
        jsonb_build_object('pool_id', p_pool_id, 'reason', p_reason));
END;
$body$;

CREATE FUNCTION pool_archive(p_pool_id bigint, p_reason text DEFAULT NULL)
RETURNS void
LANGUAGE plpgsql
AS $body$
BEGIN
    UPDATE malu$active_memory_pool
       SET lifecycle_state = 'archived',
           archived_at     = now(),
           updated_at      = now()
     WHERE pool_id = p_pool_id AND lifecycle_state IN ('active','sealed');
    IF NOT FOUND THEN
        RAISE EXCEPTION 'pool_archive: pool % missing or already archived/tombstoned',
            p_pool_id
            USING ERRCODE = 'object_not_in_prerequisite_state';
    END IF;
    PERFORM audit_event('active_memory_pool_archived', NULL, NULL,
        jsonb_build_object('pool_id', p_pool_id, 'reason', p_reason));
END;
$body$;

CREATE FUNCTION pool_tombstone(p_pool_id bigint, p_reason text DEFAULT NULL)
RETURNS void
LANGUAGE plpgsql
AS $body$
BEGIN
    UPDATE malu$active_memory_pool
       SET lifecycle_state = 'tombstoned',
           tombstoned_at   = now(),
           updated_at      = now()
     WHERE pool_id = p_pool_id AND lifecycle_state <> 'tombstoned';
    IF NOT FOUND THEN
        RAISE EXCEPTION 'pool_tombstone: pool % missing or already tombstoned',
            p_pool_id
            USING ERRCODE = 'object_not_in_prerequisite_state';
    END IF;
    PERFORM audit_event('active_memory_pool_tombstoned', NULL, NULL,
        jsonb_build_object('pool_id', p_pool_id, 'reason', p_reason));
END;
$body$;

GRANT EXECUTE ON FUNCTION
    _assert_pool_writable(bigint),
    _assert_pool_capacity(bigint),
    create_active_memory_pool(text, text, text, text[], numeric, timestamptz, timestamptz, integer),
    pool_add_observation(bigint, jsonb, numeric, jsonb, text, bigint),
    pool_add_reference(bigint, text, text, bigint, numeric, jsonb, text, bigint),
    pool_promote_to_claim(bigint, text, text, text, text, text),
    pool_promote_to_fact(bigint, text, text, text, text, text, text, text),
    pool_seal(bigint, text),
    pool_archive(bigint, text),
    pool_tombstone(bigint, text)
TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;

-- =====================================================================
-- Stage-boundary roadmap update: malu$active_memory_pool now landed.
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
            ('malu$competency_package',          5),
            ('malu$episode_replay',              5),
            ('malu$local_memory_node',           6),
            ('malu$node_sync_record',            6)
    )
    SELECT 'table'::text, c.relname::text, f.stage
    FROM pg_catalog.pg_class c
    JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
    JOIN forbidden f ON f.name = c.relname
    WHERE n.nspname = 'maludb_core'
      AND c.relkind IN ('r','p','v','m')
    ORDER BY f.stage, c.relname;
$body$;
