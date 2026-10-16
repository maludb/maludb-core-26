-- examples/04-local-node-sync.sql
--
-- Walkthrough of the Stage 6 Local Node sync protocol (S6-1):
-- register a node, accept a claim submission, reject a duplicate,
-- record an explicit conflict on a third proposal, then revoke
-- the node.

SET search_path = maludb_core, public;

DELETE FROM malu$audit_event
 WHERE event_kind LIKE 'local_node_%' OR event_kind LIKE 'node_submission%';
DELETE FROM malu$node_conflict_record WHERE submission_id IN (
    SELECT submission_id FROM malu$node_sync_record
    WHERE node_id IN (SELECT node_id FROM malu$local_memory_node
                       WHERE node_name = 'ex04-edge'));
DELETE FROM malu$node_sync_record WHERE node_id IN (
    SELECT node_id FROM malu$local_memory_node WHERE node_name = 'ex04-edge');
DELETE FROM malu$claim WHERE statement_text LIKE 'ex04:%';
DELETE FROM malu$local_memory_node WHERE node_name = 'ex04-edge';

-- ---------- register the node --------------------------------------
SELECT register_local_node(
    p_node_name   => 'ex04-edge',
    p_fingerprint => 'sha256:ex04-fingerprint',
    p_uri         => 'https://10.0.0.91:8443',
    p_description => 'ex04 demo edge node'
) AS node \gset

-- ---------- node submits a claim_new proposal ----------------------
\echo '=== submit pending claim ==='
SELECT node_submit(
    p_node_id         => :node,
    p_submission_kind => 'claim_new',
    p_payload_jsonb   => jsonb_build_object(
        'subject','edge_sensor_22',
        'verb','reported',
        'object_value','temperature_anomaly',
        'statement_text','ex04: spike at 14:22Z while offline'),
    p_local_id => 1001) AS sub_a \gset

SELECT submission_kind, status FROM malu$node_sync_record
 WHERE submission_id = :sub_a;

-- ---------- server accepts -----------------------------------------
\echo '=== accept submission ==='
SELECT node_accept(:sub_a, 'reviewed by oncall') AS accept_result;

SELECT status, applied_object_type, applied_object_id IS NOT NULL AS applied
FROM malu$node_sync_record WHERE submission_id = :sub_a;

-- Confirm the claim materialised.
SELECT subject, verb, statement_text
FROM malu$claim WHERE claim_id = (
    SELECT applied_object_id FROM malu$node_sync_record
    WHERE submission_id = :sub_a);

-- ---------- server rejects a duplicate -----------------------------
SELECT node_submit(
    p_node_id         => :node,
    p_submission_kind => 'memory_new',
    p_payload_jsonb   => jsonb_build_object(
        'memory_kind','observation',
        'title','ex04 stale snapshot',
        'summary','already mirrored on central'),
    p_local_id => 1002) AS sub_b \gset

\echo '=== reject duplicate ==='
SELECT node_reject(:sub_b, 'central already has equivalent memory id=42');

SELECT status, reason FROM malu$node_sync_record WHERE submission_id = :sub_b;

-- ---------- conflict path ------------------------------------------
SELECT node_submit(
    p_node_id         => :node,
    p_submission_kind => 'fact_new',
    p_payload_jsonb   => jsonb_build_object(
        'subject','edge_sensor_22',
        'verb','verified',
        'object_value','temperature_anomaly_root_cause',
        'statement_text','ex04: offline derivation says cooling failure',
        'claim_ids', jsonb_build_array()),
    p_local_id => 1003) AS sub_c \gset

\echo '=== record explicit conflict ==='
SELECT node_record_conflict(
    p_submission_id      => :sub_c,
    p_conflict_kind      => 'divergent_content',
    p_server_object_type => 'fact',
    p_server_object_id   => 1,
    p_resolution         => 'server_wins',
    p_resolution_notes   => 'server fact is more recent and verified'
);

SELECT status FROM malu$node_sync_record WHERE submission_id = :sub_c;
SELECT conflict_kind, resolution FROM malu$node_conflict_record
 WHERE submission_id = :sub_c;

-- ---------- revoke the node ----------------------------------------
\echo '=== revoke node ==='
SELECT revoke_local_node(:node, 'fingerprint mismatch on rekey');

SELECT lifecycle_state FROM malu$local_memory_node WHERE node_id = :node;

\echo 'example 04 done.'
