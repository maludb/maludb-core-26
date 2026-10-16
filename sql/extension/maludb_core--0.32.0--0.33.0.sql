\echo Use "ALTER EXTENSION maludb_core UPDATE TO '0.33.0'" to load this file. \quit

-- =====================================================================
-- maludb_core 0.32.0 → 0.33.0
--
-- Stage 5 — Workflow Extraction Engine (S5-1).
--
-- Per requirements.md §3.8: a governed subsystem (not optional
-- summarization). Operators select project/subject/action/time/source
-- to analyze; the engine extracts steps from Episode Objects + their
-- Memory Detail Objects, normalizes action/subject classes, clusters
-- similar traces, and proposes candidate generalized workflows for
-- review.
--
-- Doctrine baked into the schema:
--   * §3.8 #8 — candidates MUST NOT auto-promote. Approval flips a
--     review_status only; no procedural memory or workflow is
--     created as a side effect.
--   * §3.8 #9 — positive AND negative evidence are first-class. A
--     trace's outcome may be success/partial/failure/aborted; the
--     cluster counts both kinds.
--   * §3.8 #10 — temporal sequence ≠ causal assertion. workflow_step
--     has BOTH `predecessor_step_id` (temporal) AND `caused_by_step_id`
--     (causal). A CHECK constraint refuses caused_by without an
--     evidence_source_id, so causation cannot be asserted on the
--     strength of ordering alone.
--
-- Surface:
--   * malu$workflow_trace      — one per Episode/case.
--   * malu$workflow_step       — children of a trace.
--   * malu$workflow_cluster    — grouping by §3.8 #7 dims.
--   * malu$workflow_cluster_member — many traces per cluster.
--   * malu$workflow_candidate  — proposal for a generalized workflow.
--   * extract_workflow_trace(episode_id, outcome, environment?)
--   * cluster_workflow_traces(subject_class, action_class, outcome)
--   * propose_workflow_candidate(cluster_id, name, description?)
--   * review_workflow_candidate(candidate_id, status, notes?)
-- =====================================================================

CREATE OR REPLACE FUNCTION maludb_core_version() RETURNS text
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$ SELECT '0.33.0'::text $body$;

-- =====================================================================
-- malu$workflow_trace
-- =====================================================================
CREATE TABLE malu$workflow_trace (
    trace_id           bigserial PRIMARY KEY,
    owner_schema       name NOT NULL DEFAULT current_schema(),
    episode_id         bigint NOT NULL REFERENCES malu$episode_object(episode_id) ON DELETE CASCADE,
    subject_class      text NOT NULL,
    action_class       text NOT NULL,
    outcome            text NOT NULL
        CHECK (outcome IN ('success','partial','failure','aborted','pending')),
    environment        text,
    tool_stack         text[],
    exception_pattern  text,
    confidence         numeric(5,4)
        CHECK (confidence IS NULL OR (confidence >= 0 AND confidence <= 1)),
    step_count         integer NOT NULL DEFAULT 0,
    positive_evidence  boolean NOT NULL,
    security_domain    text,
    payload_jsonb      jsonb,
    extracted_at       timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX malu$workflow_trace_owner_idx     ON malu$workflow_trace(owner_schema);
CREATE INDEX malu$workflow_trace_episode_idx   ON malu$workflow_trace(episode_id);
CREATE INDEX malu$workflow_trace_signature_idx
    ON malu$workflow_trace(subject_class, action_class, outcome);

ALTER TABLE malu$workflow_trace ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_owner ON malu$workflow_trace
    USING (owner_schema = current_schema())
    WITH CHECK (owner_schema = current_schema());

GRANT SELECT ON malu$workflow_trace TO
    maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;
GRANT INSERT, UPDATE, DELETE ON malu$workflow_trace TO
    maludb_memory_admin, maludb_memory_executor;
GRANT USAGE, SELECT ON SEQUENCE malu$workflow_trace_trace_id_seq TO
    maludb_memory_admin, maludb_memory_executor;

-- =====================================================================
-- malu$workflow_step
--
-- Causation invariant (§3.8 #10): caused_by_step_id MUST come with
-- caused_by_evidence_source_id. Temporal ordering lives in
-- predecessor_step_id and has no evidence requirement.
-- =====================================================================
CREATE TABLE malu$workflow_step (
    step_id                       bigserial PRIMARY KEY,
    owner_schema                  name NOT NULL DEFAULT current_schema(),
    trace_id                      bigint NOT NULL REFERENCES malu$workflow_trace(trace_id) ON DELETE CASCADE,
    step_idx                      integer NOT NULL,
    action_class                  text NOT NULL,
    subject                       text,
    object_value                  text,
    actor                         text,
    tool                          text,
    started_at                    timestamptz,
    ended_at                      timestamptz,
    outcome                       text
        CHECK (outcome IS NULL OR outcome IN ('success','partial','failure','aborted','pending','skipped')),
    evidence_source_id            bigint REFERENCES malu$source_package(source_package_id) ON DELETE SET NULL,
    evidence_mdo_id               bigint REFERENCES malu$memory_detail_object(mdo_id) ON DELETE SET NULL,
    exception_text                text,
    predecessor_step_id           bigint REFERENCES malu$workflow_step(step_id) ON DELETE SET NULL,
    caused_by_step_id             bigint REFERENCES malu$workflow_step(step_id) ON DELETE SET NULL,
    caused_by_evidence_source_id  bigint REFERENCES malu$source_package(source_package_id) ON DELETE SET NULL,
    payload_jsonb                 jsonb,
    CHECK (caused_by_step_id IS NULL OR caused_by_evidence_source_id IS NOT NULL),
    UNIQUE (trace_id, step_idx)
);
CREATE INDEX malu$workflow_step_trace_idx   ON malu$workflow_step(trace_id);
CREATE INDEX malu$workflow_step_pred_idx
    ON malu$workflow_step(predecessor_step_id) WHERE predecessor_step_id IS NOT NULL;
CREATE INDEX malu$workflow_step_caused_idx
    ON malu$workflow_step(caused_by_step_id)   WHERE caused_by_step_id   IS NOT NULL;

ALTER TABLE malu$workflow_step ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_owner ON malu$workflow_step
    USING (owner_schema = current_schema())
    WITH CHECK (owner_schema = current_schema());

GRANT SELECT ON malu$workflow_step TO
    maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;
GRANT INSERT, UPDATE, DELETE ON malu$workflow_step TO
    maludb_memory_admin, maludb_memory_executor;
GRANT USAGE, SELECT ON SEQUENCE malu$workflow_step_step_id_seq TO
    maludb_memory_admin, maludb_memory_executor;

-- =====================================================================
-- malu$workflow_cluster — groups similar traces. Signature derived
-- from §3.8 #7 dims: subject_class, action_class, outcome,
-- environment, tool stack, exception pattern.
--
-- tool_stack_signature is a deterministic string built from the
-- sorted tool array so cluster lookups can compare with a single
-- equality on the column. NULL environment / exception_pattern are
-- canonicalised to the empty string in the signature for uniqueness.
-- =====================================================================
CREATE TABLE malu$workflow_cluster (
    cluster_id              bigserial PRIMARY KEY,
    owner_schema            name NOT NULL DEFAULT current_schema(),
    subject_class           text NOT NULL,
    action_class            text NOT NULL,
    outcome                 text NOT NULL
        CHECK (outcome IN ('success','partial','failure','aborted','pending')),
    environment             text NOT NULL DEFAULT '',
    tool_stack_signature    text NOT NULL DEFAULT '',
    exception_pattern       text NOT NULL DEFAULT '',
    member_count            integer NOT NULL DEFAULT 0,
    positive_member_count   integer NOT NULL DEFAULT 0,
    negative_member_count   integer NOT NULL DEFAULT 0,
    created_at              timestamptz NOT NULL DEFAULT now(),
    UNIQUE (owner_schema, subject_class, action_class, outcome,
            environment, tool_stack_signature, exception_pattern)
);

ALTER TABLE malu$workflow_cluster ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_owner ON malu$workflow_cluster
    USING (owner_schema = current_schema())
    WITH CHECK (owner_schema = current_schema());

GRANT SELECT ON malu$workflow_cluster TO
    maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;
GRANT INSERT, UPDATE, DELETE ON malu$workflow_cluster TO
    maludb_memory_admin, maludb_memory_executor;
GRANT USAGE, SELECT ON SEQUENCE malu$workflow_cluster_cluster_id_seq TO
    maludb_memory_admin, maludb_memory_executor;

CREATE TABLE malu$workflow_cluster_member (
    cluster_id    bigint NOT NULL REFERENCES malu$workflow_cluster(cluster_id) ON DELETE CASCADE,
    trace_id      bigint NOT NULL REFERENCES malu$workflow_trace(trace_id) ON DELETE CASCADE,
    owner_schema  name NOT NULL DEFAULT current_schema(),
    added_at      timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (cluster_id, trace_id)
);

ALTER TABLE malu$workflow_cluster_member ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_owner ON malu$workflow_cluster_member
    USING (owner_schema = current_schema())
    WITH CHECK (owner_schema = current_schema());

GRANT SELECT, INSERT, DELETE ON malu$workflow_cluster_member TO
    maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;

-- =====================================================================
-- malu$workflow_candidate — proposed generalized workflow.
--
-- review_status begins 'proposed'. review_workflow_candidate transitions
-- it. Per §3.8 #8 nothing else happens on 'approved': no procedural
-- memory is created, no existing workflow is overwritten. Promotion
-- is a separate explicit action (future S5-x or operator-driven).
-- =====================================================================
CREATE TABLE malu$workflow_candidate (
    candidate_id              bigserial PRIMARY KEY,
    owner_schema              name NOT NULL DEFAULT current_schema(),
    cluster_id                bigint NOT NULL REFERENCES malu$workflow_cluster(cluster_id) ON DELETE CASCADE,
    name                      text NOT NULL,
    description               text,
    step_template             jsonb NOT NULL,
    review_status             text NOT NULL DEFAULT 'proposed'
        CHECK (review_status IN ('proposed','approved','rejected','withdrawn')),
    review_notes              text,
    reviewed_by               name,
    reviewed_at               timestamptz,
    provenance                jsonb,
    positive_evidence_count   integer NOT NULL DEFAULT 0,
    negative_evidence_count   integer NOT NULL DEFAULT 0,
    created_at                timestamptz NOT NULL DEFAULT now(),
    updated_at                timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX malu$workflow_candidate_cluster_idx
    ON malu$workflow_candidate(cluster_id);
CREATE INDEX malu$workflow_candidate_status_idx
    ON malu$workflow_candidate(review_status) WHERE review_status <> 'rejected';

ALTER TABLE malu$workflow_candidate ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_owner ON malu$workflow_candidate
    USING (owner_schema = current_schema())
    WITH CHECK (owner_schema = current_schema());

GRANT SELECT ON malu$workflow_candidate TO
    maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;
GRANT INSERT, UPDATE ON malu$workflow_candidate TO
    maludb_memory_admin, maludb_memory_executor;
GRANT USAGE, SELECT ON SEQUENCE malu$workflow_candidate_candidate_id_seq TO
    maludb_memory_admin, maludb_memory_executor;

-- =====================================================================
-- _tool_stack_signature — deterministic string for cluster grouping.
-- Sorts the array, lowercases, joins with '|'. NULL/empty → ''.
-- =====================================================================
CREATE FUNCTION _tool_stack_signature(p_tools text[]) RETURNS text
LANGUAGE sql IMMUTABLE
AS $body$
    SELECT COALESCE(
        (SELECT string_agg(lower(t), '|' ORDER BY lower(t))
         FROM unnest(p_tools) AS u(t)
         WHERE t IS NOT NULL AND t <> ''),
        '');
$body$;

-- =====================================================================
-- extract_workflow_trace — build a trace + steps from an Episode.
--
-- Steps come from malu$memory_detail_object rows of detail_kind='step'
-- attached to the episode, ordered by ordinal. Each step's actor /
-- tool / started_at / ended_at / outcome / exception come from the
-- MDO's body_jsonb. evidence_source_id and caused_by_evidence_source_id
-- come from body_jsonb->>'source_package_id' and
-- body_jsonb->>'caused_by_source_package_id' respectively.
--
-- p_outcome is the trace-level outcome. positive_evidence is derived:
-- success/partial → true, failure/aborted → false. pending traces are
-- treated as positive (the engine doesn't yet know the disposition).
--
-- Emits a 'workflow_trace_extracted' audit_event.
-- =====================================================================
CREATE FUNCTION extract_workflow_trace(
    p_episode_id        bigint,
    p_outcome           text   DEFAULT 'success',
    p_environment       text   DEFAULT NULL,
    p_security_domain   text   DEFAULT NULL,
    p_subject_class     text   DEFAULT NULL,
    p_action_class      text   DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql
AS $body$
DECLARE
    v_episode           malu$episode_object%ROWTYPE;
    v_trace_id          bigint;
    v_subject_class     text;
    v_action_class      text;
    v_step_count        integer := 0;
    v_tool_stack        text[];
    v_exception_pattern text;
    v_positive          boolean;
    v_prev_step_id      bigint := NULL;
    v_step_id           bigint;
    v_mdo               record;
BEGIN
    IF p_outcome NOT IN ('success','partial','failure','aborted','pending') THEN
        RAISE EXCEPTION 'extract_workflow_trace: bad outcome %', p_outcome
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    SELECT * INTO v_episode FROM malu$episode_object
        WHERE episode_id = p_episode_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'extract_workflow_trace: episode % not found', p_episode_id
            USING ERRCODE = 'no_data_found';
    END IF;

    v_positive       := p_outcome IN ('success','partial','pending');
    v_subject_class  := COALESCE(p_subject_class,
                                 v_episode.payload_jsonb ->> 'subject_class',
                                 v_episode.episode_kind);
    v_action_class   := COALESCE(p_action_class,
                                 v_episode.payload_jsonb ->> 'action_class',
                                 'unspecified');
    v_tool_stack     := COALESCE(
        ARRAY(SELECT jsonb_array_elements_text(v_episode.payload_jsonb -> 'tool_stack')),
        ARRAY[]::text[]);

    INSERT INTO malu$workflow_trace
        (episode_id, subject_class, action_class, outcome, environment,
         tool_stack, exception_pattern, positive_evidence,
         security_domain, payload_jsonb)
    VALUES
        (p_episode_id, v_subject_class, v_action_class, p_outcome,
         COALESCE(p_environment, v_episode.payload_jsonb ->> 'environment'),
         v_tool_stack, NULL, v_positive,
         p_security_domain, v_episode.payload_jsonb)
    RETURNING trace_id INTO v_trace_id;

    -- Steps come from MDOs of detail_kind='step' attached directly to
    -- the episode, ordered by ordinal then by mdo_id for stable tie-
    -- breaks.
    FOR v_mdo IN
        SELECT mdo_id, ordinal, title, body_jsonb, body_text
        FROM malu$memory_detail_object
        WHERE episode_id = p_episode_id
          AND detail_kind = 'step'
        ORDER BY COALESCE(ordinal, 0), mdo_id
    LOOP
        v_step_count := v_step_count + 1;
        INSERT INTO malu$workflow_step
            (trace_id, step_idx, action_class, subject, object_value,
             actor, tool, started_at, ended_at, outcome,
             evidence_source_id, evidence_mdo_id, exception_text,
             predecessor_step_id, payload_jsonb)
        VALUES (
            v_trace_id, v_step_count,
            COALESCE(v_mdo.body_jsonb ->> 'action_class', v_action_class),
            v_mdo.body_jsonb ->> 'subject',
            v_mdo.body_jsonb ->> 'object_value',
            v_mdo.body_jsonb ->> 'actor',
            v_mdo.body_jsonb ->> 'tool',
            NULLIF(v_mdo.body_jsonb ->> 'started_at', '')::timestamptz,
            NULLIF(v_mdo.body_jsonb ->> 'ended_at',   '')::timestamptz,
            v_mdo.body_jsonb ->> 'outcome',
            NULLIF(v_mdo.body_jsonb ->> 'source_package_id', '')::bigint,
            v_mdo.mdo_id,
            v_mdo.body_jsonb ->> 'exception',
            v_prev_step_id,
            v_mdo.body_jsonb)
        RETURNING step_id INTO v_step_id;

        IF (v_mdo.body_jsonb ->> 'exception') IS NOT NULL THEN
            v_exception_pattern := v_mdo.body_jsonb ->> 'exception';
        END IF;

        v_prev_step_id := v_step_id;
    END LOOP;

    UPDATE malu$workflow_trace
       SET step_count        = v_step_count,
           exception_pattern = v_exception_pattern
     WHERE trace_id = v_trace_id;

    PERFORM audit_event('workflow_trace_extracted', 'episode_object', p_episode_id,
        jsonb_build_object(
            'trace_id',     v_trace_id,
            'step_count',   v_step_count,
            'outcome',      p_outcome,
            'positive_evidence', v_positive,
            'subject_class', v_subject_class,
            'action_class',  v_action_class));

    RETURN v_trace_id;
END;
$body$;

-- =====================================================================
-- cluster_workflow_traces — group traces by §3.8 #7 dims.
--
-- Finds or creates a malu$workflow_cluster with the given signature,
-- then enrolls every matching workflow_trace as a member. Maintains
-- cluster.member_count / positive_member_count / negative_member_count.
--
-- Returns the cluster_id. Emits 'workflow_cluster_built' audit.
-- =====================================================================
CREATE FUNCTION cluster_workflow_traces(
    p_subject_class    text,
    p_action_class     text,
    p_outcome          text,
    p_environment      text DEFAULT NULL,
    p_tool_stack       text[] DEFAULT NULL,
    p_exception_pattern text DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql
AS $body$
DECLARE
    v_cluster_id  bigint;
    v_env         text := COALESCE(p_environment, '');
    v_tool_sig    text := _tool_stack_signature(p_tool_stack);
    v_exc         text := COALESCE(p_exception_pattern, '');
    v_added       integer := 0;
    v_pos_added   integer := 0;
    v_neg_added   integer := 0;
BEGIN
    INSERT INTO malu$workflow_cluster
        (subject_class, action_class, outcome, environment,
         tool_stack_signature, exception_pattern)
    VALUES (p_subject_class, p_action_class, p_outcome,
            v_env, v_tool_sig, v_exc)
    ON CONFLICT (owner_schema, subject_class, action_class, outcome,
                 environment, tool_stack_signature, exception_pattern)
        DO UPDATE SET subject_class = EXCLUDED.subject_class
    RETURNING cluster_id INTO v_cluster_id;

    -- Enroll all matching traces that aren't already members.
    WITH new_members AS (
        INSERT INTO malu$workflow_cluster_member (cluster_id, trace_id)
        SELECT v_cluster_id, t.trace_id
        FROM malu$workflow_trace t
        WHERE t.subject_class = p_subject_class
          AND t.action_class  = p_action_class
          AND t.outcome       = p_outcome
          AND COALESCE(t.environment, '')         = v_env
          AND _tool_stack_signature(t.tool_stack) = v_tool_sig
          AND COALESCE(t.exception_pattern, '')   = v_exc
          AND NOT EXISTS (
              SELECT 1 FROM malu$workflow_cluster_member m
              WHERE m.cluster_id = v_cluster_id AND m.trace_id = t.trace_id)
        RETURNING trace_id
    )
    SELECT count(*),
           count(*) FILTER (WHERE t.positive_evidence),
           count(*) FILTER (WHERE NOT t.positive_evidence)
      INTO v_added, v_pos_added, v_neg_added
      FROM new_members n
      JOIN malu$workflow_trace t USING (trace_id);

    UPDATE malu$workflow_cluster
       SET member_count          = member_count + v_added,
           positive_member_count = positive_member_count + v_pos_added,
           negative_member_count = negative_member_count + v_neg_added
     WHERE cluster_id = v_cluster_id;

    PERFORM audit_event('workflow_cluster_built', NULL, NULL,
        jsonb_build_object(
            'cluster_id', v_cluster_id,
            'subject_class', p_subject_class,
            'action_class',  p_action_class,
            'outcome',       p_outcome,
            'added',         v_added,
            'positive_added', v_pos_added,
            'negative_added', v_neg_added));

    RETURN v_cluster_id;
END;
$body$;

-- =====================================================================
-- propose_workflow_candidate — emit a proposal for review.
--
-- step_template defaults to a JSON aggregation of the most-common
-- step shape across cluster members (action_class + actor + tool
-- frequency). The proposal carries provenance pointing back to the
-- cluster + its member trace_ids and a snapshot of the §3.8 #7 dims.
-- review_status starts 'proposed'. Per §3.8 #8 nothing else changes
-- on this side effect — there is no auto-promotion path here.
-- =====================================================================
CREATE FUNCTION propose_workflow_candidate(
    p_cluster_id        bigint,
    p_name              text,
    p_description       text  DEFAULT NULL,
    p_step_template     jsonb DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql
AS $body$
DECLARE
    v_cluster       malu$workflow_cluster%ROWTYPE;
    v_candidate_id  bigint;
    v_template      jsonb;
    v_member_ids    bigint[];
BEGIN
    SELECT * INTO v_cluster FROM malu$workflow_cluster
        WHERE cluster_id = p_cluster_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'propose_workflow_candidate: cluster % not found', p_cluster_id
            USING ERRCODE = 'no_data_found';
    END IF;

    SELECT COALESCE(array_agg(trace_id ORDER BY trace_id), ARRAY[]::bigint[])
      INTO v_member_ids
      FROM malu$workflow_cluster_member
     WHERE cluster_id = p_cluster_id;

    IF p_step_template IS NOT NULL THEN
        v_template := p_step_template;
    ELSE
        -- Default template: ordered action_class sequence with mode
        -- actor/tool per step_idx, plus per-step success rate.
        SELECT COALESCE(jsonb_agg(t ORDER BY (t->>'step_idx')::int), '[]'::jsonb)
          INTO v_template
          FROM (
            SELECT jsonb_build_object(
                     'step_idx',         s.step_idx,
                     'action_class',     mode() WITHIN GROUP (ORDER BY s.action_class),
                     'common_actor',     mode() WITHIN GROUP (ORDER BY s.actor),
                     'common_tool',      mode() WITHIN GROUP (ORDER BY s.tool),
                     'success_rate',
                       ROUND(
                         (count(*) FILTER (WHERE s.outcome = 'success'))::numeric
                         / NULLIF(count(*), 0), 4),
                     'sample_count',     count(*)
                   ) AS t
            FROM malu$workflow_step s
            JOIN malu$workflow_cluster_member m
              ON m.trace_id = s.trace_id
            WHERE m.cluster_id = p_cluster_id
            GROUP BY s.step_idx) tt;
    END IF;

    INSERT INTO malu$workflow_candidate
        (cluster_id, name, description, step_template,
         provenance, positive_evidence_count, negative_evidence_count)
    VALUES
        (p_cluster_id, p_name, p_description, v_template,
         jsonb_build_object(
            'cluster_id', p_cluster_id,
            'cluster_signature', jsonb_build_object(
                'subject_class', v_cluster.subject_class,
                'action_class',  v_cluster.action_class,
                'outcome',       v_cluster.outcome,
                'environment',   v_cluster.environment,
                'tool_stack_signature', v_cluster.tool_stack_signature,
                'exception_pattern',    v_cluster.exception_pattern),
            'member_trace_ids', to_jsonb(v_member_ids),
            'extraction_engine_version', '0.33.0'),
         v_cluster.positive_member_count,
         v_cluster.negative_member_count)
    RETURNING candidate_id INTO v_candidate_id;

    PERFORM audit_event('workflow_candidate_proposed', NULL, NULL,
        jsonb_build_object(
            'candidate_id', v_candidate_id,
            'cluster_id',   p_cluster_id,
            'name',         p_name,
            'positive_evidence_count', v_cluster.positive_member_count,
            'negative_evidence_count', v_cluster.negative_member_count));

    RETURN v_candidate_id;
END;
$body$;

-- =====================================================================
-- review_workflow_candidate — flip review_status.
--
-- Per §3.8 #8 transitioning to 'approved' has no automatic
-- downstream side effect. No procedural memory is created here; no
-- workflow is overwritten. Approval is a governance signal that
-- some other explicit action (operator promotion, S5-2 skill
-- packaging) may consume.
-- =====================================================================
CREATE FUNCTION review_workflow_candidate(
    p_candidate_id  bigint,
    p_status        text,
    p_notes         text DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql
AS $body$
DECLARE
    v_current text;
BEGIN
    IF p_status NOT IN ('approved','rejected','withdrawn') THEN
        RAISE EXCEPTION 'review_workflow_candidate: bad status %', p_status
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    SELECT review_status INTO v_current
      FROM malu$workflow_candidate
     WHERE candidate_id = p_candidate_id;
    IF v_current IS NULL THEN
        RAISE EXCEPTION 'review_workflow_candidate: candidate % not found', p_candidate_id
            USING ERRCODE = 'no_data_found';
    END IF;
    IF v_current <> 'proposed' THEN
        RAISE EXCEPTION 'review_workflow_candidate: candidate % already %, cannot re-review',
            p_candidate_id, v_current
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    UPDATE malu$workflow_candidate
       SET review_status = p_status,
           review_notes  = COALESCE(p_notes, review_notes),
           reviewed_by   = current_user,
           reviewed_at   = now(),
           updated_at    = now()
     WHERE candidate_id = p_candidate_id;

    PERFORM audit_event('workflow_candidate_reviewed', NULL, NULL,
        jsonb_build_object(
            'candidate_id', p_candidate_id,
            'new_status',   p_status,
            'reviewer',     current_user));
END;
$body$;

GRANT EXECUTE ON FUNCTION
    _tool_stack_signature(text[]),
    extract_workflow_trace(bigint, text, text, text, text, text),
    cluster_workflow_traces(text, text, text, text, text[], text),
    propose_workflow_candidate(bigint, text, text, jsonb),
    review_workflow_candidate(bigint, text, text)
TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;

-- =====================================================================
-- Stage-boundary roadmap update.
--
-- Stage 5 is now partially live (workflow extraction). Remove
-- malu$workflow_trace from the forbidden list. Other Stage 5
-- placeholders (generalized_workflow, procedural_memory_object,
-- skill_package, competency_package, active_memory_pool,
-- episode_replay) and Stage 6 entries remain forbidden until those
-- phases ship.
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
            ('malu$skill_package',               5),
            ('malu$competency_package',          5),
            ('malu$active_memory_pool',          5),
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
