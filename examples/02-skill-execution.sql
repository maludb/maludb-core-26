-- examples/02-skill-execution.sql
--
-- Walkthrough of the Stage 5 Skill Runtime (S5-2):
--   register a small canary-deploy skill, run it through success
--   and failure branches, then abort one mid-flight. Emit one
--   claim from the executor as evidence.

SET search_path = maludb_core, public;

DELETE FROM malu$audit_event WHERE event_kind LIKE 'skill_%'
   AND event_jsonb ->> 'skill_name' = 'ex02_canary';
DELETE FROM malu$skill_execution_step  WHERE execution_id IN (
    SELECT execution_id FROM malu$skill_execution_record
    WHERE skill_id IN (SELECT skill_id FROM malu$skill_package WHERE skill_name = 'ex02_canary'));
DELETE FROM malu$skill_execution_record WHERE skill_id IN (
    SELECT skill_id FROM malu$skill_package WHERE skill_name = 'ex02_canary');
DELETE FROM malu$skill_transition WHERE skill_id IN (
    SELECT skill_id FROM malu$skill_package WHERE skill_name = 'ex02_canary');
DELETE FROM malu$skill_state WHERE skill_id IN (
    SELECT skill_id FROM malu$skill_package WHERE skill_name = 'ex02_canary');
DELETE FROM malu$skill_package WHERE skill_name = 'ex02_canary';
DELETE FROM malu$claim WHERE statement_text LIKE 'ex02:%';

-- ---------- register the skill -------------------------------------
SELECT register_skill(
    p_skill_name     => 'ex02_canary',
    p_description    => 'Canary deploy + health-check validation.',
    p_applicability_jsonb => jsonb_build_object(
        'environment', 'prod',
        'technology_stack', jsonb_build_array('helm','kubectl'))
) AS sk \gset

SELECT add_skill_state(:sk, 'plan',          'start');
SELECT add_skill_state(:sk, 'shift_traffic', 'step');
SELECT add_skill_state(:sk, 'health_check',  'validation');
SELECT add_skill_state(:sk, 'rollback',      'exception_handler');
SELECT add_skill_state(:sk, 'success',       'terminal');
SELECT add_skill_state(:sk, 'failure',       'terminal');

SELECT add_skill_transition(:sk, 'plan',          'shift_traffic', 'success');
SELECT add_skill_transition(:sk, 'shift_traffic', 'health_check',  'success');
SELECT add_skill_transition(:sk, 'health_check',  'success',       'success');
SELECT add_skill_transition(:sk, 'health_check',  'rollback',      'failure');
SELECT add_skill_transition(:sk, 'rollback',      'failure',       'success');
SELECT add_skill_transition(:sk, 'shift_traffic', 'rollback',      'exception:*');

-- ---------- happy path execution ------------------------------------
\echo '=== happy path ==='
SELECT begin_skill_execution(
    p_skill_id          => :sk,
    p_environment       => 'prod',
    p_technology_stack  => ARRAY['helm','kubectl','jq'],
    p_task_objective    => 'ship api-gateway v1.7'
) AS exec_happy \gset

SELECT step_skill_execution(:exec_happy, 'success');  -- plan → shift_traffic
SELECT step_skill_execution(:exec_happy, 'success');  -- shift_traffic → health_check

-- Emit a claim while the execution is still running (skill_emit_claim
-- refuses on finalised executions, so this MUST happen before the
-- terminal transition).
SELECT register_claim(
    p_subject        => 'api_gateway',
    p_verb           => 'deployed',
    p_object_value   => 'v1.7',
    p_statement_text => 'ex02: canary skill execution succeeded'
) AS happy_claim \gset

SELECT skill_emit_claim(:exec_happy, :happy_claim);

SELECT step_skill_execution(:exec_happy, 'success');  -- health_check → success terminal

SELECT final_outcome, step_count, cardinality(emitted_claim_ids) AS emitted
FROM malu$skill_execution_record WHERE execution_id = :exec_happy;

-- ---------- failure-branch execution -------------------------------
\echo '=== failure path ==='
SELECT begin_skill_execution(
    p_skill_id          => :sk,
    p_environment       => 'prod',
    p_technology_stack  => ARRAY['helm','kubectl']) AS exec_fail \gset

SELECT step_skill_execution(:exec_fail, 'success');                 -- plan → shift_traffic
SELECT step_skill_execution(:exec_fail, 'success');                 -- shift_traffic → health_check
SELECT step_skill_execution(:exec_fail, 'failure',                   -- health_check → rollback
    jsonb_build_object('reason','5xx_burst'));
SELECT step_skill_execution(:exec_fail, 'success');                 -- rollback → failure terminal

SELECT final_outcome FROM malu$skill_execution_record WHERE execution_id = :exec_fail;

-- ---------- exception:* wildcard -----------------------------------
\echo '=== exception wildcard ==='
SELECT begin_skill_execution(
    p_skill_id          => :sk,
    p_environment       => 'prod',
    p_technology_stack  => ARRAY['helm','kubectl']) AS exec_exc \gset

SELECT step_skill_execution(:exec_exc, 'success');  -- plan → shift_traffic
SELECT step_skill_execution(:exec_exc, 'exception:NetworkTimeout',
    jsonb_build_object('err','timeout'));            -- shift_traffic → rollback (wildcard)
SELECT step_skill_execution(:exec_exc, 'success');  -- rollback → failure terminal

SELECT final_outcome FROM malu$skill_execution_record WHERE execution_id = :exec_exc;

\echo 'example 02 done.'
