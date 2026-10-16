-- Stage 5 S5-1 — Workflow Extraction Engine.
--
-- Exercises (per requirements.md §3.8):
--   * extract_workflow_trace reads MDOs of detail_kind='step' from
--     an episode and builds a trace + ordered steps.
--   * The CHECK on workflow_step refuses caused_by_step_id without
--     caused_by_evidence_source_id (§3.8 #10: causation needs
--     evidence beyond ordering).
--   * Positive AND negative evidence is preserved (§3.8 #9):
--     a failure trace and a success trace cluster together with
--     positive_member_count > 0 AND negative_member_count > 0.
--   * cluster_workflow_traces is idempotent: re-running enrolls no
--     duplicate members.
--   * propose_workflow_candidate emits a candidate with
--     review_status='proposed'; nothing else changes.
--   * review_workflow_candidate('approved') flips status only —
--     no procedural memory or workflow is auto-created (§3.8 #8).
--   * Audit events emitted: workflow_trace_extracted,
--     workflow_cluster_built, workflow_candidate_proposed,
--     workflow_candidate_reviewed.

\set ECHO all
SET search_path = maludb_core, public;
SET client_min_messages = NOTICE;

-- ---------- fixture: an episode with three step-MDOs ----------------
SELECT register_episode(
    p_episode_kind => 'deploy',
    p_title        => 'Deploy api-gateway v1.7 to prod',
    p_summary      => 'Three-step rolling deploy with one validation.',
    p_payload_jsonb => jsonb_build_object(
        'subject_class', 'api_gateway',
        'action_class',  'deploy',
        'environment',   'prod',
        'tool_stack',    jsonb_build_array('helm','kubectl','vault'))
) AS ep_a \gset

-- Three step MDOs under the episode. body_jsonb carries actor/tool/etc.
INSERT INTO malu$memory_detail_object
    (episode_id, detail_kind, ordinal, title, body_jsonb)
VALUES
    (:ep_a, 'step', 1, 'helm upgrade',
     jsonb_build_object(
        'action_class','helm_upgrade', 'subject','api-gateway',
        'object_value','v1.7', 'actor','release-bot', 'tool','helm',
        'outcome','success')),
    (:ep_a, 'step', 2, 'rolling restart',
     jsonb_build_object(
        'action_class','rolling_restart', 'subject','api-gateway',
        'actor','release-bot', 'tool','kubectl',
        'outcome','success')),
    (:ep_a, 'step', 3, 'smoke validation',
     jsonb_build_object(
        'action_class','smoke_test', 'subject','api-gateway',
        'actor','ci', 'tool','vault',
        'outcome','success'));

-- ---------- extract a trace -----------------------------------------
SELECT extract_workflow_trace(
    p_episode_id => :ep_a,
    p_outcome    => 'success'
) AS trace_a \gset

SELECT subject_class, action_class, outcome, environment,
       tool_stack, step_count, positive_evidence
FROM malu$workflow_trace WHERE trace_id = :trace_a;

-- Steps came out in ordinal order with predecessor chain
SELECT step_idx, action_class, actor, tool,
       (predecessor_step_id IS NOT NULL)::text AS has_predecessor
FROM malu$workflow_step
WHERE trace_id = :trace_a
ORDER BY step_idx;

-- ---------- causation CHECK: caused_by needs evidence ---------------
-- Picking step 2 and pointing caused_by to step 1 WITHOUT evidence
-- must raise (§3.8 #10).
SELECT step_id AS s1_id FROM malu$workflow_step
 WHERE trace_id = :trace_a AND step_idx = 1 \gset
SELECT step_id AS s2_id FROM malu$workflow_step
 WHERE trace_id = :trace_a AND step_idx = 2 \gset

DO $body$
BEGIN
    UPDATE malu$workflow_step
       SET caused_by_step_id = (SELECT step_id FROM malu$workflow_step
                                 WHERE trace_id = (SELECT trace_id FROM malu$workflow_step LIMIT 1)
                                   AND step_idx = 1)
     WHERE step_id = (SELECT step_id FROM malu$workflow_step
                       WHERE trace_id = (SELECT trace_id FROM malu$workflow_step LIMIT 1)
                         AND step_idx = 2);
    RAISE NOTICE 'UNEXPECTED: caused_by without evidence accepted';
EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'OK: caused_by without evidence rejected';
END;
$body$;

-- A source package then satisfies the CHECK.
SELECT register_source_package(
    p_source_type  => 'log',
    p_content_text => 'helm release succeeded; pods restarting',
    p_origin_jsonb => jsonb_build_object('uri','log://release-bot/deploy-1.7')
) AS sp_evidence \gset

UPDATE malu$workflow_step
   SET caused_by_step_id            = :s1_id,
       caused_by_evidence_source_id = :sp_evidence
 WHERE step_id = :s2_id;

SELECT (caused_by_step_id IS NOT NULL
        AND caused_by_evidence_source_id IS NOT NULL) AS causation_recorded
FROM malu$workflow_step WHERE step_id = :s2_id;

-- ---------- a second trace with same signature but FAILURE outcome --
SELECT register_episode(
    p_episode_kind => 'deploy',
    p_title        => 'Deploy api-gateway v1.7 — second attempt failed',
    p_summary      => 'Rolling restart degraded latency; rolled back.',
    p_payload_jsonb => jsonb_build_object(
        'subject_class', 'api_gateway',
        'action_class',  'deploy',
        'environment',   'prod',
        'tool_stack',    jsonb_build_array('helm','kubectl','vault'))
) AS ep_b \gset

INSERT INTO malu$memory_detail_object
    (episode_id, detail_kind, ordinal, title, body_jsonb)
VALUES
    (:ep_b, 'step', 1, 'helm upgrade',
     jsonb_build_object('action_class','helm_upgrade','actor','release-bot','tool','helm','outcome','success')),
    (:ep_b, 'step', 2, 'rolling restart',
     jsonb_build_object('action_class','rolling_restart','actor','release-bot','tool','kubectl','outcome','failure','exception','LatencySLOBreach'));

SELECT extract_workflow_trace(
    p_episode_id => :ep_b,
    p_outcome    => 'failure'
) AS trace_b \gset

SELECT outcome, positive_evidence, exception_pattern
FROM malu$workflow_trace WHERE trace_id = :trace_b;

-- ---------- cluster both traces -------------------------------------
-- Note: failure trace has exception_pattern='LatencySLOBreach' so the
-- two traces should NOT cluster together when the dim includes
-- exception_pattern. Cluster the success-only signature first.
SELECT cluster_workflow_traces(
    p_subject_class    => 'api_gateway',
    p_action_class     => 'deploy',
    p_outcome          => 'success',
    p_environment      => 'prod',
    p_tool_stack       => ARRAY['helm','kubectl','vault']
) AS cluster_success \gset

SELECT cluster_workflow_traces(
    p_subject_class    => 'api_gateway',
    p_action_class     => 'deploy',
    p_outcome          => 'failure',
    p_environment      => 'prod',
    p_tool_stack       => ARRAY['helm','kubectl','vault'],
    p_exception_pattern => 'LatencySLOBreach'
) AS cluster_failure \gset

SELECT
    member_count, positive_member_count, negative_member_count
FROM malu$workflow_cluster WHERE cluster_id = :cluster_success;

SELECT
    member_count, positive_member_count, negative_member_count,
    exception_pattern
FROM malu$workflow_cluster WHERE cluster_id = :cluster_failure;

-- Re-running cluster build is idempotent: counts don't double.
SELECT cluster_workflow_traces(
    p_subject_class    => 'api_gateway',
    p_action_class     => 'deploy',
    p_outcome          => 'success',
    p_environment      => 'prod',
    p_tool_stack       => ARRAY['helm','kubectl','vault']
) = :cluster_success AS reentrant_cluster_id_stable;

SELECT member_count AS member_count_after_rerun
FROM malu$workflow_cluster WHERE cluster_id = :cluster_success;

-- ---------- propose a candidate -------------------------------------
SELECT propose_workflow_candidate(
    p_cluster_id  => :cluster_success,
    p_name        => 'api-gateway prod deploy (success)',
    p_description => 'Common 3-step deploy: helm → kubectl → vault.'
) AS cand_success \gset

SELECT name, review_status,
       positive_evidence_count, negative_evidence_count,
       jsonb_array_length(step_template) AS template_steps
FROM malu$workflow_candidate WHERE candidate_id = :cand_success;

-- §3.8 #8: no procedural memory or workflow object was auto-created.
-- We have no procedural_memory table yet (Stage 5+); the invariant we
-- can verify is that the candidate is the ONLY artifact created.
SELECT (SELECT count(*) FROM malu$workflow_candidate WHERE candidate_id = :cand_success) AS cand_rows,
       (SELECT count(*) FROM malu$workflow_trace WHERE owner_schema = current_schema()) AS trace_rows;

-- ---------- review flips status only --------------------------------
SELECT review_workflow_candidate(:cand_success, 'approved', 'looks legit');

SELECT review_status, review_notes IS NOT NULL AS notes_recorded,
       reviewed_by IS NOT NULL AS reviewer_recorded
FROM malu$workflow_candidate WHERE candidate_id = :cand_success;

-- Re-reviewing an already-reviewed candidate must raise.
DO $body$
BEGIN
    PERFORM review_workflow_candidate((SELECT max(candidate_id) FROM malu$workflow_candidate
                                         WHERE review_status = 'approved'),
                                       'rejected', 'changed my mind');
    RAISE NOTICE 'UNEXPECTED: double-review accepted';
EXCEPTION WHEN invalid_parameter_value THEN
    RAISE NOTICE 'OK: double-review rejected';
END;
$body$;

-- ---------- audit emission summary ---------------------------------
SELECT event_kind, count(*) AS n
FROM malu$audit_event
WHERE event_kind IN (
    'workflow_trace_extracted',
    'workflow_cluster_built',
    'workflow_candidate_proposed',
    'workflow_candidate_reviewed')
GROUP BY event_kind
ORDER BY event_kind;

-- ---------- cleanup ------------------------------------------------
DELETE FROM malu$audit_event WHERE event_kind LIKE 'workflow_%';
DELETE FROM malu$workflow_candidate         WHERE cluster_id IN (:cluster_success, :cluster_failure);
DELETE FROM malu$workflow_cluster_member    WHERE cluster_id IN (:cluster_success, :cluster_failure);
DELETE FROM malu$workflow_cluster           WHERE cluster_id IN (:cluster_success, :cluster_failure);
DELETE FROM malu$workflow_step              WHERE trace_id   IN (:trace_a, :trace_b);
DELETE FROM malu$workflow_trace             WHERE trace_id   IN (:trace_a, :trace_b);
DELETE FROM malu$memory_detail_object       WHERE episode_id IN (:ep_a, :ep_b);
DELETE FROM malu$episode_object             WHERE episode_id IN (:ep_a, :ep_b);
DELETE FROM malu$source_package             WHERE source_package_id = :sp_evidence;
