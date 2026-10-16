\echo Use "ALTER EXTENSION maludb_core UPDATE TO '0.40.0'" to load this file. \quit

-- =====================================================================
-- maludb_core 0.39.0 → 0.40.0
--
-- Stage 6 — Advanced MC2DB tools (S6-4).
--
-- Per requirements.md §3.11 + §9 Stage 6: "Advanced MC2DB tools /
-- resources / prompts for memory retrieval, workflow, skills, local-
-- node sync, and governed memory writes."
--
-- R1.0 registered MC2DB tools on a 'maludb.r10' server, scoped to
-- the minimal Stage 1 surface (health, catalog, sessions, prompt
-- render). This phase creates a separate **maludb.advanced** server
-- and registers Stage 2+ tools against it — keeping the R1.0
-- surface unchanged so existing field-test fixtures stay stable.
--
-- All wrapper functions follow the existing convention:
--   `<name>(args jsonb, context jsonb) RETURNS void`
-- and CALL `mc2db.put_object(jsonb)` with the response envelope
-- ({"content":…, "structuredContent":…, "isError":…}).
--
-- Tools landed in this phase:
--   maludb.retrieve            execute_retrieval
--   maludb.text_search         text_search
--   maludb.episode.replay      replay_episode
--   maludb.workflow.extract_trace      extract_workflow_trace
--   maludb.workflow.cluster            cluster_workflow_traces
--   maludb.workflow.propose_candidate  propose_workflow_candidate
--   maludb.skill.begin                 begin_skill_execution
--   maludb.skill.step                  step_skill_execution
--   maludb.skill.abort                 abort_skill_execution
--   maludb.pool.create                 create_active_memory_pool
--   maludb.pool.add_observation        pool_add_observation
--   maludb.pool.promote_claim          pool_promote_to_claim
--   maludb.node.submit                 node_submit
--   maludb.node.accept                 node_accept
--   maludb.write.claim                 register_claim
--   maludb.write.fact                  register_fact
--   maludb.write.memory                register_memory
--   maludb.write.episode               register_episode
--   maludb.write.source_package        register_source_package
-- =====================================================================

CREATE OR REPLACE FUNCTION maludb_core_version() RETURNS text
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$ SELECT '0.40.0'::text $body$;

-- =====================================================================
-- Create the advanced MC2DB server.
-- =====================================================================
SELECT mc2db.create_server(
    'maludb.advanced',
    'MaluDB Advanced',
    'Stage 2..6 governed memory / workflow / skill / pool / node tools.');

-- =====================================================================
-- Wrapper functions — each is a thin shim over the underlying helper.
-- =====================================================================

-- ---- maludb.retrieve ------------------------------------------------
CREATE FUNCTION advanced_retrieve(args jsonb, context jsonb) RETURNS void
LANGUAGE plpgsql SECURITY INVOKER
AS $body$
DECLARE
    v_env malu$retrieval_envelope_t;
    v_hits jsonb;
BEGIN
    v_env := ROW(
        args ->> 'cue_text',
        CASE WHEN args ? 'object_types'
             THEN ARRAY(SELECT jsonb_array_elements_text(args -> 'object_types'))
             ELSE ARRAY['claim','fact','memory','episode_object']::text[] END,
        NULLIF(args ->> 'valid_as_of', '')::timestamptz,
        NULLIF(args ->> 'transaction_as_of', '')::timestamptz,
        NULLIF(args ->> 'confidence_floor', '')::numeric,
        args -> 'hints'
    )::malu$retrieval_envelope_t;

    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'object_type', h.object_type, 'object_id', h.object_id,
        'title', h.title, 'snippet', h.snippet,
        'rank',  h.rank, 'strategy', h.strategy,
        'metadata', h.metadata)), '[]'::jsonb)
      INTO v_hits
      FROM execute_retrieval(v_env, args ->> 'hint_name',
            COALESCE((args ->> 'limit')::integer, 20)) h;

    CALL mc2db.put_object(jsonb_build_object(
        'content', jsonb_build_array(jsonb_build_object('type','text',
            'text', format('%s hit(s)', jsonb_array_length(v_hits)))),
        'structuredContent', jsonb_build_object(
            'cue_text', args ->> 'cue_text',
            'hits',     v_hits),
        'isError', false));
END;
$body$;

-- ---- maludb.text_search --------------------------------------------
CREATE FUNCTION advanced_text_search(args jsonb, context jsonb) RETURNS void
LANGUAGE plpgsql SECURITY INVOKER
AS $body$
DECLARE
    v_types text[];
    v_hits jsonb;
BEGIN
    v_types := CASE WHEN args ? 'object_types'
                    THEN ARRAY(SELECT jsonb_array_elements_text(args -> 'object_types'))
                    ELSE ARRAY['claim','fact','memory','episode_object']::text[] END;
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'object_type',      r.object_type,
        'object_id',        r.object_id,
        'title_or_subject', r.title_or_subject,
        'snippet',          r.snippet,
        'rank',             r.rank)), '[]'::jsonb)
      INTO v_hits
      FROM text_search(args ->> 'query', v_types,
            COALESCE((args ->> 'limit')::integer, 20)) r;
    CALL mc2db.put_object(jsonb_build_object(
        'content', jsonb_build_array(jsonb_build_object('type','text',
            'text', format('%s match(es)', jsonb_array_length(v_hits)))),
        'structuredContent', jsonb_build_object('results', v_hits),
        'isError', false));
END;
$body$;

-- ---- maludb.episode.replay -----------------------------------------
CREATE FUNCTION advanced_episode_replay(args jsonb, context jsonb) RETURNS void
LANGUAGE plpgsql SECURITY INVOKER
AS $body$
DECLARE v_envelope jsonb;
BEGIN
    v_envelope := replay_episode(
        (args ->> 'episode_id')::bigint,
        COALESCE(args ->> 'mode', 'current_valid'),
        NULLIF(args ->> 'as_of', '')::timestamptz);
    CALL mc2db.put_object(jsonb_build_object(
        'content', jsonb_build_array(jsonb_build_object('type','text',
            'text', format('replay mode=%s', v_envelope ->> 'mode'))),
        'structuredContent', v_envelope,
        'isError', false));
END;
$body$;

-- ---- maludb.workflow.extract_trace ---------------------------------
CREATE FUNCTION advanced_workflow_extract(args jsonb, context jsonb) RETURNS void
LANGUAGE plpgsql SECURITY INVOKER
AS $body$
DECLARE v_trace_id bigint;
BEGIN
    v_trace_id := extract_workflow_trace(
        (args ->> 'episode_id')::bigint,
        COALESCE(args ->> 'outcome', 'success'),
        args ->> 'environment',
        args ->> 'security_domain',
        args ->> 'subject_class',
        args ->> 'action_class');
    CALL mc2db.put_object(jsonb_build_object(
        'content', jsonb_build_array(jsonb_build_object('type','text',
            'text', format('extracted trace_id=%s', v_trace_id))),
        'structuredContent', jsonb_build_object('trace_id', v_trace_id),
        'isError', false));
END;
$body$;

-- ---- maludb.workflow.cluster ---------------------------------------
CREATE FUNCTION advanced_workflow_cluster(args jsonb, context jsonb) RETURNS void
LANGUAGE plpgsql SECURITY INVOKER
AS $body$
DECLARE v_id bigint;
BEGIN
    v_id := cluster_workflow_traces(
        args ->> 'subject_class',
        args ->> 'action_class',
        args ->> 'outcome',
        args ->> 'environment',
        CASE WHEN args ? 'tool_stack'
             THEN ARRAY(SELECT jsonb_array_elements_text(args -> 'tool_stack'))
             ELSE NULL END,
        args ->> 'exception_pattern');
    CALL mc2db.put_object(jsonb_build_object(
        'content', jsonb_build_array(jsonb_build_object('type','text',
            'text', format('cluster_id=%s', v_id))),
        'structuredContent', jsonb_build_object('cluster_id', v_id),
        'isError', false));
END;
$body$;

-- ---- maludb.workflow.propose_candidate ----------------------------
CREATE FUNCTION advanced_workflow_propose(args jsonb, context jsonb) RETURNS void
LANGUAGE plpgsql SECURITY INVOKER
AS $body$
DECLARE v_id bigint;
BEGIN
    v_id := propose_workflow_candidate(
        (args ->> 'cluster_id')::bigint,
        args ->> 'name',
        args ->> 'description',
        args -> 'step_template');
    CALL mc2db.put_object(jsonb_build_object(
        'content', jsonb_build_array(jsonb_build_object('type','text',
            'text', format('candidate_id=%s', v_id))),
        'structuredContent', jsonb_build_object('candidate_id', v_id),
        'isError', false));
END;
$body$;

-- ---- maludb.skill.* -------------------------------------------------
CREATE FUNCTION advanced_skill_begin(args jsonb, context jsonb) RETURNS void
LANGUAGE plpgsql SECURITY INVOKER
AS $body$
DECLARE v_id bigint;
BEGIN
    v_id := begin_skill_execution(
        (args ->> 'skill_id')::bigint,
        args ->> 'environment',
        CASE WHEN args ? 'technology_stack'
             THEN ARRAY(SELECT jsonb_array_elements_text(args -> 'technology_stack'))
             ELSE NULL END,
        args ->> 'task_objective',
        CASE WHEN args ? 'authorized_partitions'
             THEN ARRAY(SELECT jsonb_array_elements_text(args -> 'authorized_partitions'))
             ELSE NULL END,
        NULLIF(args ->> 'account_id','')::bigint,
        NULLIF(args ->> 'active_pool_id','')::bigint,
        NULLIF(args ->> 'source_context_id','')::bigint);
    CALL mc2db.put_object(jsonb_build_object(
        'content', jsonb_build_array(jsonb_build_object('type','text',
            'text', format('execution_id=%s', v_id))),
        'structuredContent', jsonb_build_object('execution_id', v_id),
        'isError', false));
END;
$body$;

CREATE FUNCTION advanced_skill_step(args jsonb, context jsonb) RETURNS void
LANGUAGE plpgsql SECURITY INVOKER
AS $body$
DECLARE v_next text;
BEGIN
    v_next := step_skill_execution(
        (args ->> 'execution_id')::bigint,
        args ->> 'outcome',
        args -> 'observation');
    CALL mc2db.put_object(jsonb_build_object(
        'content', jsonb_build_array(jsonb_build_object('type','text',
            'text', format('next_state=%s', v_next))),
        'structuredContent', jsonb_build_object('next_state', v_next),
        'isError', false));
END;
$body$;

CREATE FUNCTION advanced_skill_abort(args jsonb, context jsonb) RETURNS void
LANGUAGE plpgsql SECURITY INVOKER
AS $body$
BEGIN
    PERFORM abort_skill_execution(
        (args ->> 'execution_id')::bigint, args ->> 'reason');
    CALL mc2db.put_object(jsonb_build_object(
        'content', jsonb_build_array(jsonb_build_object('type','text','text','aborted')),
        'structuredContent', jsonb_build_object(
            'execution_id', (args ->> 'execution_id')::bigint),
        'isError', false));
END;
$body$;

-- ---- maludb.pool.* --------------------------------------------------
CREATE FUNCTION advanced_pool_create(args jsonb, context jsonb) RETURNS void
LANGUAGE plpgsql SECURITY INVOKER
AS $body$
DECLARE v_id bigint;
BEGIN
    v_id := create_active_memory_pool(
        args ->> 'pool_name',
        COALESCE(args ->> 'creation_kind', 'mcp'),
        args ->> 'task_objective',
        CASE WHEN args ? 'authorized_partitions'
             THEN ARRAY(SELECT jsonb_array_elements_text(args -> 'authorized_partitions'))
             ELSE NULL END,
        NULLIF(args ->> 'confidence_floor','')::numeric,
        NULLIF(args ->> 'validity_start','')::timestamptz,
        NULLIF(args ->> 'validity_end','')::timestamptz,
        NULLIF(args ->> 'max_member_count','')::integer);
    CALL mc2db.put_object(jsonb_build_object(
        'content', jsonb_build_array(jsonb_build_object('type','text',
            'text', format('pool_id=%s', v_id))),
        'structuredContent', jsonb_build_object('pool_id', v_id),
        'isError', false));
END;
$body$;

CREATE FUNCTION advanced_pool_add_observation(args jsonb, context jsonb) RETURNS void
LANGUAGE plpgsql SECURITY INVOKER
AS $body$
DECLARE v_id bigint;
BEGIN
    v_id := pool_add_observation(
        (args ->> 'pool_id')::bigint,
        args -> 'payload',
        NULLIF(args ->> 'confidence','')::numeric,
        args -> 'provenance',
        args ->> 'access_label',
        NULLIF(args ->> 'account_id','')::bigint);
    CALL mc2db.put_object(jsonb_build_object(
        'content', jsonb_build_array(jsonb_build_object('type','text',
            'text', format('member_id=%s', v_id))),
        'structuredContent', jsonb_build_object('member_id', v_id),
        'isError', false));
END;
$body$;

CREATE FUNCTION advanced_pool_promote_claim(args jsonb, context jsonb) RETURNS void
LANGUAGE plpgsql SECURITY INVOKER
AS $body$
DECLARE v_id bigint;
BEGIN
    v_id := pool_promote_to_claim(
        (args ->> 'member_id')::bigint,
        args ->> 'subject', args ->> 'verb',
        args ->> 'object_value', args ->> 'statement_text',
        COALESCE(args ->> 'sensitivity','internal'));
    CALL mc2db.put_object(jsonb_build_object(
        'content', jsonb_build_array(jsonb_build_object('type','text',
            'text', format('claim_id=%s', v_id))),
        'structuredContent', jsonb_build_object('claim_id', v_id),
        'isError', false));
END;
$body$;

-- ---- maludb.node.* -------------------------------------------------
CREATE FUNCTION advanced_node_submit(args jsonb, context jsonb) RETURNS void
LANGUAGE plpgsql SECURITY INVOKER
AS $body$
DECLARE v_id bigint;
BEGIN
    v_id := node_submit(
        (args ->> 'node_id')::bigint,
        args ->> 'submission_kind',
        args -> 'payload',
        NULLIF(args ->> 'local_id','')::bigint,
        args ->> 'local_hash');
    CALL mc2db.put_object(jsonb_build_object(
        'content', jsonb_build_array(jsonb_build_object('type','text',
            'text', format('submission_id=%s', v_id))),
        'structuredContent', jsonb_build_object('submission_id', v_id),
        'isError', false));
END;
$body$;

CREATE FUNCTION advanced_node_accept(args jsonb, context jsonb) RETURNS void
LANGUAGE plpgsql SECURITY INVOKER
AS $body$
DECLARE v_result jsonb;
BEGIN
    v_result := node_accept(
        (args ->> 'submission_id')::bigint,
        args ->> 'reason');
    CALL mc2db.put_object(jsonb_build_object(
        'content', jsonb_build_array(jsonb_build_object('type','text',
            'text', format('applied=%s', v_result ->> 'applied_object_type'))),
        'structuredContent', v_result,
        'isError', false));
END;
$body$;

-- ---- maludb.write.* (governed writes) ------------------------------
CREATE FUNCTION advanced_write_claim(args jsonb, context jsonb) RETURNS void
LANGUAGE plpgsql SECURITY INVOKER
AS $body$
DECLARE v_id bigint;
BEGIN
    v_id := register_claim(
        p_subject        => args ->> 'subject',
        p_verb           => args ->> 'verb',
        p_predicate      => args ->> 'predicate',
        p_object_value   => args ->> 'object_value',
        p_relationship   => args ->> 'relationship',
        p_statement_text => args ->> 'statement_text',
        p_statement_jsonb => args -> 'statement_jsonb',
        p_source_package_id => NULLIF(args ->> 'source_package_id','')::bigint,
        p_sensitivity    => COALESCE(args ->> 'sensitivity','internal'));
    CALL mc2db.put_object(jsonb_build_object(
        'content', jsonb_build_array(jsonb_build_object('type','text',
            'text', format('claim_id=%s', v_id))),
        'structuredContent', jsonb_build_object('claim_id', v_id),
        'isError', false));
END;
$body$;

CREATE FUNCTION advanced_write_fact(args jsonb, context jsonb) RETURNS void
LANGUAGE plpgsql SECURITY INVOKER
AS $body$
DECLARE v_id bigint;
BEGIN
    v_id := register_fact(
        p_claim_ids => COALESCE(
            ARRAY(SELECT (jsonb_array_elements_text(args -> 'claim_ids'))::bigint),
            ARRAY[]::bigint[]),
        p_subject        => args ->> 'subject',
        p_verb           => args ->> 'verb',
        p_object_value   => args ->> 'object_value',
        p_statement_text => args ->> 'statement_text',
        p_verification_scope  => args ->> 'verification_scope',
        p_verification_method => args ->> 'verification_method',
        p_sensitivity    => COALESCE(args ->> 'sensitivity','internal'));
    CALL mc2db.put_object(jsonb_build_object(
        'content', jsonb_build_array(jsonb_build_object('type','text',
            'text', format('fact_id=%s', v_id))),
        'structuredContent', jsonb_build_object('fact_id', v_id),
        'isError', false));
END;
$body$;

CREATE FUNCTION advanced_write_memory(args jsonb, context jsonb) RETURNS void
LANGUAGE plpgsql SECURITY INVOKER
AS $body$
DECLARE v_id bigint;
BEGIN
    v_id := register_memory(
        p_memory_kind => args ->> 'memory_kind',
        p_title       => args ->> 'title',
        p_summary     => args ->> 'summary',
        p_payload_jsonb => COALESCE(args -> 'payload_jsonb', '{}'::jsonb),
        p_sensitivity => COALESCE(args ->> 'sensitivity','internal'));
    CALL mc2db.put_object(jsonb_build_object(
        'content', jsonb_build_array(jsonb_build_object('type','text',
            'text', format('memory_id=%s', v_id))),
        'structuredContent', jsonb_build_object('memory_id', v_id),
        'isError', false));
END;
$body$;

CREATE FUNCTION advanced_write_episode(args jsonb, context jsonb) RETURNS void
LANGUAGE plpgsql SECURITY INVOKER
AS $body$
DECLARE v_id bigint;
BEGIN
    v_id := register_episode(
        p_episode_kind => args ->> 'episode_kind',
        p_title        => args ->> 'title',
        p_summary      => args ->> 'summary',
        p_payload_jsonb => COALESCE(args -> 'payload_jsonb', '{}'::jsonb),
        p_sensitivity  => COALESCE(args ->> 'sensitivity','internal'));
    CALL mc2db.put_object(jsonb_build_object(
        'content', jsonb_build_array(jsonb_build_object('type','text',
            'text', format('episode_id=%s', v_id))),
        'structuredContent', jsonb_build_object('episode_id', v_id),
        'isError', false));
END;
$body$;

CREATE FUNCTION advanced_write_source_package(args jsonb, context jsonb) RETURNS void
LANGUAGE plpgsql SECURITY INVOKER
AS $body$
DECLARE v_id bigint;
BEGIN
    v_id := register_source_package(
        p_source_type  => args ->> 'source_type',
        p_content_text => args ->> 'content_text',
        p_content_jsonb => args -> 'content_jsonb',
        p_origin_jsonb => args -> 'origin_jsonb',
        p_sensitivity  => COALESCE(args ->> 'sensitivity','internal'));
    CALL mc2db.put_object(jsonb_build_object(
        'content', jsonb_build_array(jsonb_build_object('type','text',
            'text', format('source_package_id=%s', v_id))),
        'structuredContent', jsonb_build_object('source_package_id', v_id),
        'isError', false));
END;
$body$;

-- =====================================================================
-- Register tools against 'maludb.advanced'.
--
-- input_schema is intentionally permissive (additionalProperties:true)
-- in v1; tightening per-tool schemas can land later. risk_class and
-- read_only flags follow the convention from the R1.0 catalog.
-- =====================================================================

SELECT mc2db.register_tool(
    server_name => 'maludb.advanced', tool_name => 'maludb.retrieve',
    description => 'Authorization-aware retrieval orchestrator (S4-5).',
    implementation_type => 'sql_function',
    input_schema  => '{"type":"object","required":["cue_text"]}'::jsonb,
    output_schema => '{"type":"object","required":["hits"]}'::jsonb,
    impl_metadata => jsonb_build_object('function_signature',
        'maludb_core.advanced_retrieve(jsonb, jsonb)'));

SELECT mc2db.register_tool(
    server_name => 'maludb.advanced', tool_name => 'maludb.text_search',
    description => 'Cross-object FTS over claim/fact/memory/episode_object.',
    implementation_type => 'sql_function',
    input_schema  => '{"type":"object","required":["query"]}'::jsonb,
    output_schema => '{"type":"object","required":["results"]}'::jsonb,
    impl_metadata => jsonb_build_object('function_signature',
        'maludb_core.advanced_text_search(jsonb, jsonb)'));

SELECT mc2db.register_tool(
    server_name => 'maludb.advanced', tool_name => 'maludb.episode.replay',
    description => 'Reconstruct an authorized, time-aware view of an Episode Object.',
    implementation_type => 'sql_function',
    input_schema  => '{"type":"object","required":["episode_id"]}'::jsonb,
    impl_metadata => jsonb_build_object('function_signature',
        'maludb_core.advanced_episode_replay(jsonb, jsonb)'));

SELECT mc2db.register_tool(
    server_name => 'maludb.advanced', tool_name => 'maludb.workflow.extract_trace',
    description => 'Extract a workflow trace from an Episode Object.',
    implementation_type => 'sql_function',
    input_schema  => '{"type":"object","required":["episode_id"]}'::jsonb,
    impl_metadata => jsonb_build_object('function_signature',
        'maludb_core.advanced_workflow_extract(jsonb, jsonb)'));

SELECT mc2db.register_tool(
    server_name => 'maludb.advanced', tool_name => 'maludb.workflow.cluster',
    description => 'Group workflow traces sharing a signature into a cluster.',
    implementation_type => 'sql_function',
    input_schema  => '{"type":"object","required":["subject_class","action_class","outcome"]}'::jsonb,
    impl_metadata => jsonb_build_object('function_signature',
        'maludb_core.advanced_workflow_cluster(jsonb, jsonb)'));

SELECT mc2db.register_tool(
    server_name => 'maludb.advanced', tool_name => 'maludb.workflow.propose_candidate',
    description => 'Propose a generalised workflow candidate from a cluster.',
    implementation_type => 'sql_function',
    input_schema  => '{"type":"object","required":["cluster_id","name"]}'::jsonb,
    impl_metadata => jsonb_build_object('function_signature',
        'maludb_core.advanced_workflow_propose(jsonb, jsonb)'));

SELECT mc2db.register_tool(
    server_name => 'maludb.advanced', tool_name => 'maludb.skill.begin',
    description => 'Bind context + applicability check + open a skill execution.',
    implementation_type => 'sql_function',
    risk_class => 'evidence_producing', read_only => false,
    input_schema  => '{"type":"object","required":["skill_id"]}'::jsonb,
    impl_metadata => jsonb_build_object('function_signature',
        'maludb_core.advanced_skill_begin(jsonb, jsonb)'));

SELECT mc2db.register_tool(
    server_name => 'maludb.advanced', tool_name => 'maludb.skill.step',
    description => 'Advance a skill execution by one transition.',
    implementation_type => 'sql_function',
    risk_class => 'evidence_producing', read_only => false,
    input_schema  => '{"type":"object","required":["execution_id","outcome"]}'::jsonb,
    impl_metadata => jsonb_build_object('function_signature',
        'maludb_core.advanced_skill_step(jsonb, jsonb)'));

SELECT mc2db.register_tool(
    server_name => 'maludb.advanced', tool_name => 'maludb.skill.abort',
    description => 'Abort a skill execution.',
    implementation_type => 'sql_function',
    risk_class => 'evidence_producing', read_only => false,
    input_schema  => '{"type":"object","required":["execution_id"]}'::jsonb,
    impl_metadata => jsonb_build_object('function_signature',
        'maludb_core.advanced_skill_abort(jsonb, jsonb)'));

SELECT mc2db.register_tool(
    server_name => 'maludb.advanced', tool_name => 'maludb.pool.create',
    description => 'Create or re-bind an active memory pool.',
    implementation_type => 'sql_function',
    risk_class => 'evidence_producing', read_only => false,
    input_schema  => '{"type":"object","required":["pool_name"]}'::jsonb,
    impl_metadata => jsonb_build_object('function_signature',
        'maludb_core.advanced_pool_create(jsonb, jsonb)'));

SELECT mc2db.register_tool(
    server_name => 'maludb.advanced', tool_name => 'maludb.pool.add_observation',
    description => 'Add a free-form observation to an active memory pool.',
    implementation_type => 'sql_function',
    risk_class => 'evidence_producing', read_only => false,
    input_schema  => '{"type":"object","required":["pool_id","payload"]}'::jsonb,
    impl_metadata => jsonb_build_object('function_signature',
        'maludb_core.advanced_pool_add_observation(jsonb, jsonb)'));

SELECT mc2db.register_tool(
    server_name => 'maludb.advanced', tool_name => 'maludb.pool.promote_claim',
    description => 'Promote a pool observation into a pending claim.',
    implementation_type => 'sql_function',
    risk_class => 'evidence_producing', read_only => false,
    input_schema  => '{"type":"object","required":["member_id"]}'::jsonb,
    impl_metadata => jsonb_build_object('function_signature',
        'maludb_core.advanced_pool_promote_claim(jsonb, jsonb)'));

SELECT mc2db.register_tool(
    server_name => 'maludb.advanced', tool_name => 'maludb.node.submit',
    description => 'Submit a sync proposal from a local memory node.',
    implementation_type => 'sql_function',
    risk_class => 'evidence_producing', read_only => false,
    input_schema  => '{"type":"object","required":["node_id","submission_kind","payload"]}'::jsonb,
    impl_metadata => jsonb_build_object('function_signature',
        'maludb_core.advanced_node_submit(jsonb, jsonb)'));

SELECT mc2db.register_tool(
    server_name => 'maludb.advanced', tool_name => 'maludb.node.accept',
    description => 'Accept a pending local-node submission and apply it.',
    implementation_type => 'sql_function',
    risk_class => 'evidence_producing', read_only => false, require_confirmation => true,
    input_schema  => '{"type":"object","required":["submission_id"]}'::jsonb,
    impl_metadata => jsonb_build_object('function_signature',
        'maludb_core.advanced_node_accept(jsonb, jsonb)'));

SELECT mc2db.register_tool(
    server_name => 'maludb.advanced', tool_name => 'maludb.write.claim',
    description => 'Governed claim insertion via register_claim.',
    implementation_type => 'sql_function',
    risk_class => 'evidence_producing', read_only => false,
    input_schema  => '{"type":"object"}'::jsonb,
    impl_metadata => jsonb_build_object('function_signature',
        'maludb_core.advanced_write_claim(jsonb, jsonb)'));

SELECT mc2db.register_tool(
    server_name => 'maludb.advanced', tool_name => 'maludb.write.fact',
    description => 'Governed fact insertion via register_fact (with claim linkage).',
    implementation_type => 'sql_function',
    risk_class => 'evidence_producing', read_only => false,
    input_schema  => '{"type":"object","required":["claim_ids"]}'::jsonb,
    impl_metadata => jsonb_build_object('function_signature',
        'maludb_core.advanced_write_fact(jsonb, jsonb)'));

SELECT mc2db.register_tool(
    server_name => 'maludb.advanced', tool_name => 'maludb.write.memory',
    description => 'Governed memory insertion via register_memory.',
    implementation_type => 'sql_function',
    risk_class => 'evidence_producing', read_only => false,
    input_schema  => '{"type":"object","required":["memory_kind"]}'::jsonb,
    impl_metadata => jsonb_build_object('function_signature',
        'maludb_core.advanced_write_memory(jsonb, jsonb)'));

SELECT mc2db.register_tool(
    server_name => 'maludb.advanced', tool_name => 'maludb.write.episode',
    description => 'Governed episode insertion via register_episode.',
    implementation_type => 'sql_function',
    risk_class => 'evidence_producing', read_only => false,
    input_schema  => '{"type":"object","required":["episode_kind","title"]}'::jsonb,
    impl_metadata => jsonb_build_object('function_signature',
        'maludb_core.advanced_write_episode(jsonb, jsonb)'));

SELECT mc2db.register_tool(
    server_name => 'maludb.advanced', tool_name => 'maludb.write.source_package',
    description => 'Governed source-package insertion via register_source_package.',
    implementation_type => 'sql_function',
    risk_class => 'evidence_producing', read_only => false,
    input_schema  => '{"type":"object","required":["source_type"]}'::jsonb,
    impl_metadata => jsonb_build_object('function_signature',
        'maludb_core.advanced_write_source_package(jsonb, jsonb)'));

GRANT EXECUTE ON FUNCTION
    advanced_retrieve(jsonb, jsonb),
    advanced_text_search(jsonb, jsonb),
    advanced_episode_replay(jsonb, jsonb),
    advanced_workflow_extract(jsonb, jsonb),
    advanced_workflow_cluster(jsonb, jsonb),
    advanced_workflow_propose(jsonb, jsonb),
    advanced_skill_begin(jsonb, jsonb),
    advanced_skill_step(jsonb, jsonb),
    advanced_skill_abort(jsonb, jsonb),
    advanced_pool_create(jsonb, jsonb),
    advanced_pool_add_observation(jsonb, jsonb),
    advanced_pool_promote_claim(jsonb, jsonb),
    advanced_node_submit(jsonb, jsonb),
    advanced_node_accept(jsonb, jsonb),
    advanced_write_claim(jsonb, jsonb),
    advanced_write_fact(jsonb, jsonb),
    advanced_write_memory(jsonb, jsonb),
    advanced_write_episode(jsonb, jsonb),
    advanced_write_source_package(jsonb, jsonb)
TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;
