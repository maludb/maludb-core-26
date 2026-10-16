-- Stage 6 S6-2 — Model Registry blue-green + dual-space routing.
--
-- Exercises (per requirements.md §9 Stage 6 + §6.523):
--   * register_embedding_space upsert; redefining geometry raises.
--   * register_model_in_registry: embedding kind MUST have a space;
--     non-embedding kinds MUST NOT.
--   * advance_model_rollout: proposed → canary → active. Promoting
--     a second row to 'active' atomically demotes the prior active
--     to 'retiring' (one-active-per-kind invariant).
--   * Bad state transition raises.
--   * propose_index_migration → shadow_building → dual_serve (with
--     traffic_pct) → cutover → cleanup → done.
--   * advance_index_migration to dual_serve without traffic_pct
--     raises.
--   * route_query returns:
--       strategy='active' when no migration in flight,
--       strategy='dual_serve' with weighted spaces during dual_serve,
--       strategy='target_only' during cutover/cleanup.
--   * Audit events emitted at each transition.

\set ECHO all
SET search_path = maludb_core, public;
SET client_min_messages = NOTICE;

-- ---------- a model provider + alias (Stage 1 infrastructure) -------
SELECT register_model_provider(
    p_name => 's62_local',
    p_kind => 'stub'
) AS prov_id \gset

-- Build two embedding model aliases (older + newer head).
INSERT INTO malu$model_alias (alias_name, provider_id, model_identifier)
VALUES ('s62-bge-v1', :prov_id, 'bge-small-en-v1.5')
RETURNING alias_id AS alias_v1 \gset

INSERT INTO malu$model_alias (alias_name, provider_id, model_identifier)
VALUES ('s62-bge-v2', :prov_id, 'bge-small-en-v2.0')
RETURNING alias_id AS alias_v2 \gset

-- ---------- register two embedding spaces ---------------------------
SELECT register_embedding_space(
    p_space_name => 's62_bge_v1',
    p_dimensions => 384,
    p_model_alias_id => :alias_v1
) AS space_v1 \gset

SELECT register_embedding_space(
    p_space_name => 's62_bge_v2',
    p_dimensions => 768,
    p_model_alias_id => :alias_v2
) AS space_v2 \gset

-- Idempotent re-register with same geometry is OK.
SELECT register_embedding_space('s62_bge_v1', 384, 'cosine') = :space_v1
       AS space_v1_stable_on_rereg;

-- Redefining geometry raises.
DO $body$
BEGIN
    PERFORM register_embedding_space('s62_bge_v1', 768);
    RAISE NOTICE 'UNEXPECTED: geometry redef accepted';
EXCEPTION WHEN invalid_parameter_value THEN
    RAISE NOTICE 'OK: geometry redef rejected';
END;
$body$;

-- ---------- register two embedding models in the registry ----------
SELECT register_model_in_registry(
    p_model_kind => 'embedding',
    p_model_alias_id => :alias_v1,
    p_embedding_space_id => :space_v1,
    p_derived_artifact_map => jsonb_build_object(
        'indexes', jsonb_build_array('malu$memory_chunk_emb_hnsw'),
        'columns', jsonb_build_array('malu$memory_chunk.emb'))
) AS reg_v1 \gset

SELECT register_model_in_registry(
    p_model_kind => 'embedding',
    p_model_alias_id => :alias_v2,
    p_embedding_space_id => :space_v2,
    p_derived_artifact_map => jsonb_build_object(
        'indexes', jsonb_build_array('malu$memory_chunk_emb_hnsw_v2'),
        'columns', jsonb_build_array('malu$memory_chunk.emb_v2'))
) AS reg_v2 \gset

-- Embedding kind without space_id raises (row CHECK).
DO $body$
DECLARE v_alias bigint := (SELECT alias_id FROM malu$model_alias
                            WHERE alias_name = 's62-bge-v1');
BEGIN
    PERFORM register_model_in_registry('embedding', v_alias, NULL);
    RAISE NOTICE 'UNEXPECTED: embedding without space accepted';
EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'OK: embedding without space rejected';
END;
$body$;

-- Non-embedding kind with space_id raises.
DO $body$
DECLARE
    v_alias bigint := (SELECT alias_id FROM malu$model_alias WHERE alias_name = 's62-bge-v1');
    v_space bigint := (SELECT space_id FROM malu$embedding_space WHERE space_name = 's62_bge_v1');
BEGIN
    PERFORM register_model_in_registry('reranker', v_alias, v_space);
    RAISE NOTICE 'UNEXPECTED: reranker with space accepted';
EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'OK: reranker with space rejected';
END;
$body$;

-- ---------- rollout: proposed → canary → active --------------------
SELECT advance_model_rollout(:reg_v1, 'canary');
SELECT advance_model_rollout(:reg_v1, 'active');

SELECT rollout_state FROM malu$model_registry WHERE registry_id = :reg_v1;

-- Bad transition (active → canary) raises.
DO $body$
BEGIN
    PERFORM advance_model_rollout(
        (SELECT registry_id FROM malu$model_registry WHERE rollout_state = 'active'),
        'canary');
    RAISE NOTICE 'UNEXPECTED: active→canary accepted';
EXCEPTION WHEN invalid_parameter_value THEN
    RAISE NOTICE 'OK: active→canary rejected';
END;
$body$;

-- ---------- route_query: 'active' strategy when no migration --------
SELECT route_query('embedding') ->> 'strategy' AS strategy_active,
       jsonb_array_length(route_query('embedding') -> 'spaces') AS spaces_count_active,
       route_query('embedding') -> 'migration_id' IS NULL AS migration_id_null;

SELECT (route_query('embedding') -> 'spaces' -> 0 ->> 'space_id')::bigint = :space_v1
       AS routes_to_active_space;

-- ---------- propose blue-green migration v1 → v2 -------------------
SELECT propose_index_migration(
    p_source_space_id => :space_v1,
    p_target_space_id => :space_v2,
    p_index_kind => 'hnsw'
) AS mig_id \gset

SELECT status, traffic_pct FROM malu$index_migration WHERE migration_id = :mig_id;

-- propose → shadow_building
SELECT advance_index_migration(:mig_id, 'shadow_building');

-- shadow_building → dual_serve without traffic_pct raises.
DO $body$
BEGIN
    PERFORM advance_index_migration(
        (SELECT migration_id FROM malu$index_migration WHERE status = 'shadow_building'),
        'dual_serve', NULL);
    RAISE NOTICE 'UNEXPECTED: dual_serve without pct accepted';
EXCEPTION WHEN invalid_parameter_value THEN
    RAISE NOTICE 'OK: dual_serve without pct rejected';
END;
$body$;

-- shadow_building → dual_serve with 30% to target.
SELECT advance_index_migration(:mig_id, 'dual_serve', 30::numeric);

-- route_query during dual_serve splits weights.
SELECT route_query('embedding') ->> 'strategy' AS strategy_dual,
       jsonb_array_length(route_query('embedding') -> 'spaces') AS spaces_count_dual;

-- Source share = 0.70, target share = 0.30.
SELECT
    (route_query('embedding') -> 'spaces' -> 0 ->> 'weight')::numeric AS source_weight,
    (route_query('embedding') -> 'spaces' -> 1 ->> 'weight')::numeric AS target_weight,
    (route_query('embedding') -> 'spaces' -> 0 ->> 'role')           AS first_role;

-- Re-weight to 70% target.
SELECT advance_index_migration(:mig_id, 'dual_serve', 70::numeric);

SELECT (route_query('embedding') -> 'spaces' -> 1 ->> 'weight')::numeric
       = 0.7 AS reweight_applied;

-- ---------- cutover: route_query flips to target_only ---------------
SELECT advance_index_migration(:mig_id, 'cutover');

SELECT route_query('embedding') ->> 'strategy' AS strategy_cutover,
       jsonb_array_length(route_query('embedding') -> 'spaces') AS spaces_count_cutover,
       (route_query('embedding') -> 'spaces' -> 0 ->> 'space_id')::bigint = :space_v2
       AS routes_to_target;

-- cleanup → done
SELECT advance_index_migration(:mig_id, 'cleanup');
SELECT advance_index_migration(:mig_id, 'done');

SELECT status, completed_at IS NOT NULL AS done_recorded
FROM malu$index_migration WHERE migration_id = :mig_id;

-- After done, route_query returns 'active' strategy again (the
-- in-flight predicate excludes done/aborted migrations).
SELECT route_query('embedding') ->> 'strategy' AS strategy_post_done;

-- ---------- audit emission summary ---------------------------------
SELECT event_kind, count(*) AS n
FROM malu$audit_event
WHERE event_kind IN (
    'model_registry_added','model_rollout_advanced',
    'index_migration_proposed','index_migration_advanced')
GROUP BY event_kind ORDER BY event_kind;

-- ---------- cleanup ------------------------------------------------
DELETE FROM malu$audit_event
 WHERE event_kind LIKE 'model_%' OR event_kind LIKE 'index_migration_%';
DELETE FROM malu$index_migration WHERE migration_id = :mig_id;
DELETE FROM malu$model_registry  WHERE registry_id IN (:reg_v1, :reg_v2);
DELETE FROM malu$embedding_space WHERE space_id    IN (:space_v1, :space_v2);
DELETE FROM malu$model_alias     WHERE alias_id    IN (:alias_v1, :alias_v2);
DELETE FROM malu$model_provider  WHERE provider_id = :prov_id;
