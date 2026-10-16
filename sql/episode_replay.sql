-- Stage 5 S5-4 — Episode replay API. **Stage 5 closer.**
--
-- Exercises (per requirements.md §3.13):
--   * replay_episode('current_valid') answers "what happened" with
--     active+currently-valid evidence.
--   * Steps come from MDOs of detail_kind='step', ordered.
--   * supporting_evidence covers claims + facts that share the
--     episode's subject.
--   * source_packages_inspected lists every cited source.
--   * included_object_ids enumerates claim/fact/memory ids.
--   * Bad mode raises invalid_parameter_value.
--   * Mode 'as_of_transaction_time' without p_as_of raises.
--   * Retracted claim shows up in later_changes for current_valid
--     and is excluded from supporting_evidence (counted in
--     hidden_by_policy_count).
--   * Replay row recorded in malu$episode_replay; audit emitted.
--   * full_bitemporal returns everything regardless of mode filters.

\set ECHO all
SET search_path = maludb_core, public;
SET client_min_messages = NOTICE;

-- ---------- fixture: a small deployment incident ---------------------
SELECT register_episode(
    p_episode_kind => 'incident',
    p_title        => 'api-gateway outage 2026-05-13',
    p_summary      => 'Two-step rolling deploy with one validation failure.',
    p_payload_jsonb => jsonb_build_object('subject_class','api_gateway',
                                          'environment','prod')
) AS ep \gset

-- Two step MDOs.
INSERT INTO malu$memory_detail_object
    (episode_id, detail_kind, ordinal, title, body_jsonb)
VALUES
    (:ep, 'step', 1, 'shift_traffic',
     jsonb_build_object('action_class','traffic_shift','actor','release-bot',
                        'tool','kubectl','outcome','success')),
    (:ep, 'step', 2, 'health_check',
     jsonb_build_object('action_class','health_probe','actor','ci',
                        'tool','curl','outcome','failure',
                        'exception','LatencySLOBreach'));

-- Two source packages cited.
SELECT register_source_package(
    p_source_type  => 'observability',
    p_content_text => 'grafana panel snapshot at 14:22Z'
) AS sp1 \gset
SELECT register_source_package(
    p_source_type  => 'log',
    p_content_text => 'curl: timeout exceeded 2s'
) AS sp2 \gset

-- Two related claims sharing the subject api_gateway.
SELECT register_claim(
    p_subject => 'api_gateway', p_verb => 'observed',
    p_object_value => '5xx_burst',
    p_statement_text => 'Initial 5xx surge at 14:22Z.',
    p_source_package_id => :sp1
) AS c1 \gset
SELECT register_claim(
    p_subject => 'api_gateway', p_verb => 'timed_out',
    p_object_value => 'health_probe',
    p_statement_text => 'Health probe exceeded 2s window.',
    p_source_package_id => :sp2
) AS c2 \gset

-- A verified fact derived from c1+c2.
SELECT register_fact(
    p_claim_ids => ARRAY[:c1,:c2]::bigint[],
    p_subject => 'api_gateway', p_verb => 'incident',
    p_object_value => 'latency_breach',
    p_statement_text => 'Latency SLO breach root cause identified.',
    p_verification_method => 'oncall_review'
) AS f1 \gset

-- ---------- mode: current_valid -------------------------------------
SELECT replay_episode(:ep, 'current_valid') -> 'mode'              AS mode_field,
       jsonb_array_length(replay_episode(:ep, 'current_valid') -> 'steps') AS step_count,
       jsonb_array_length(replay_episode(:ep, 'current_valid') -> 'supporting_evidence')
                                                                    AS evidence_count;

-- The episode block carries title + summary
SELECT (replay_episode(:ep, 'current_valid') -> 'episode' ->> 'title')
       = 'api-gateway outage 2026-05-13' AS title_matches;

-- source_packages_inspected covers both sp1 + sp2 (sp1 via claim,
-- sp2 via claim — neither is on a step MDO so this checks the claim
-- source linkage).
SELECT jsonb_array_length(
    replay_episode(:ep, 'current_valid') -> 'source_packages_inspected'
) AS sources_inspected;

-- included_object_ids enumerates the two claims + one fact.
SELECT jsonb_array_length(
    replay_episode(:ep, 'current_valid') #> '{included_object_ids,claim}') AS claim_count,
       jsonb_array_length(
    replay_episode(:ep, 'current_valid') #> '{included_object_ids,fact}')  AS fact_count;

-- prior_belief is null for current_valid.
SELECT replay_episode(:ep, 'current_valid') -> 'prior_belief' IS NULL
       AS prior_belief_null;

-- ---------- mode: bad value raises ----------------------------------
DO $body$
BEGIN
    PERFORM replay_episode((SELECT max(episode_id) FROM malu$episode_object),
                            'nonsense_mode');
    RAISE NOTICE 'UNEXPECTED: bad mode accepted';
EXCEPTION WHEN invalid_parameter_value THEN
    RAISE NOTICE 'OK: bad mode rejected';
END;
$body$;

-- ---------- mode: as_of_transaction_time without anchor raises ------
DO $body$
BEGIN
    PERFORM replay_episode((SELECT max(episode_id) FROM malu$episode_object),
                            'as_of_transaction_time', NULL);
    RAISE NOTICE 'UNEXPECTED: missing as_of accepted';
EXCEPTION WHEN invalid_parameter_value THEN
    RAISE NOTICE 'OK: missing as_of rejected';
END;
$body$;

-- ---------- mode: full_bitemporal returns everything ----------------
SELECT jsonb_array_length(replay_episode(:ep, 'full_bitemporal') -> 'supporting_evidence')
       AS bitemporal_evidence_count;

SELECT replay_episode(:ep, 'full_bitemporal') -> 'prior_belief' IS NOT NULL
       AS prior_belief_present;

-- ---------- retract a claim, replay again ---------------------------
-- After retraction, the retracted claim drops out of current_valid
-- evidence and surfaces in later_changes.
UPDATE malu$claim SET retracted_at = now(), retraction_reason = 'duplicate'
 WHERE claim_id = :c2;

SELECT jsonb_array_length(replay_episode(:ep, 'current_valid')
                          -> 'supporting_evidence')
       AS evidence_after_retract;

-- later_changes should mention the retraction.
SELECT exists(
    SELECT 1 FROM jsonb_array_elements(
        replay_episode(:ep, 'current_valid') -> 'later_changes') ev
     WHERE ev ->> 'kind'  = 'claim'
       AND ev ->> 'event' = 'retracted'
       AND (ev ->> 'object_id')::bigint = :c2)
   AS retraction_in_later_changes;

-- hidden_by_policy_count picks up the retracted claim.
SELECT ((replay_episode(:ep, 'current_valid') ->> 'hidden_by_policy_count')::int) >= 1
       AS hidden_count_at_least_one;

-- ---------- replay row recorded + audit event emitted ---------------
-- The test calls replay_episode many times, each producing one row +
-- one audit. We assert "at least one" rather than a fixed count.
SELECT count(*) > 0 AS replay_rows_present
FROM malu$episode_replay WHERE episode_id = :ep;

SELECT count(*) > 0 AS replay_audit_present
FROM malu$audit_event
WHERE event_kind = 'episode_replayed'
  AND target_object_id = :ep;

-- ---------- cleanup -------------------------------------------------
DELETE FROM malu$audit_event           WHERE event_kind = 'episode_replayed';
DELETE FROM malu$episode_replay        WHERE episode_id = :ep;
DELETE FROM malu$memory_detail_object  WHERE episode_id = :ep;
DELETE FROM malu$fact_claim            WHERE fact_id = :f1;
DELETE FROM malu$fact                  WHERE fact_id = :f1;
DELETE FROM malu$claim                 WHERE claim_id IN (:c1, :c2);
DELETE FROM malu$source_package        WHERE source_package_id IN (:sp1, :sp2);
DELETE FROM malu$episode_object        WHERE episode_id = :ep;
