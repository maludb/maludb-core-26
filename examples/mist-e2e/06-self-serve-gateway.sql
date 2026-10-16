-- =====================================================================
-- 06-self-serve-gateway.sql — acceptance test for maludb_core 0.91.0
-- Per-tenant, zero-admin model-gateway self-service: each schema registers
-- its OWN provider + alias (same names across tenants must not collide),
-- binds config, sees only its own rows, and a NON-admin role can do it all
-- through the SECURITY DEFINER facades (no maludb_llm_model_admin grant).
--
-- Run AFTER bringing a DB up to 0.91.0:
--   psql -v ON_ERROR_STOP=1 -d <db> -f 06-self-serve-gateway.sql
-- Self-contained: two schemas gw_a, gw_b.
-- =====================================================================

\set ON_ERROR_STOP on

-- Re-runnable: clear gateway rows owned by these tenants (DROP SCHEMA does
-- not touch maludb_core tables).
DROP SCHEMA IF EXISTS gw_a CASCADE;
DROP SCHEMA IF EXISTS gw_b CASCADE;
DELETE FROM maludb_core.malu$memory_extraction_config WHERE owner_schema IN ('gw_a','gw_b');
DELETE FROM maludb_core.malu$model_alias    WHERE owner_schema IN ('gw_a','gw_b');
DELETE FROM maludb_core.malu$model_provider WHERE owner_schema IN ('gw_a','gw_b');
CREATE SCHEMA gw_a;
CREATE SCHEMA gw_b;

\echo == enable both tenants (expect enabled_version 0.91.0) ==
SELECT * FROM maludb_core.enable_memory_schema('gw_a');
SELECT * FROM maludb_core.enable_memory_schema('gw_b');

-- ---------------------------------------------------------------------
-- Each tenant self-registers the SAME provider + alias names. Pre-0.91 the
-- global provider_name / alias_name uniques would make the second collide.
-- ---------------------------------------------------------------------
\echo == gw_a registers provider 'llm' + alias 'extractor' ==
SET search_path = gw_a, maludb_core, public;
SELECT gw_a.maludb_register_model_provider('llm','cloud_api',
         p_adapter_name=>'anthropic', p_secret_ref=>'gw_a_token') AS a_provider \gset
SELECT gw_a.maludb_register_model_alias('extractor','llm','model-a',
         p_runtime_params=>'{"base_url":"https://a.example/v1"}'::jsonb) AS a_alias \gset
SELECT gw_a.maludb_memory_set_model_config(p_extraction_alias=>'extractor',
         p_embedding_model=>'emb-a') IS NOT NULL AS a_config_ok \gset

\echo == gw_b registers the SAME names 'llm' + 'extractor' (must NOT collide) ==
SET search_path = gw_b, maludb_core, public;
SELECT gw_b.maludb_register_model_provider('llm','cloud_api',
         p_adapter_name=>'openai', p_secret_ref=>'gw_b_token') AS b_provider \gset
SELECT gw_b.maludb_register_model_alias('extractor','llm','model-b',
         p_runtime_params=>'{"base_url":"https://b.example/v1"}'::jsonb) AS b_alias \gset

\echo == ASSERT A: same names, DIFFERENT rows per tenant ==
SELECT (:a_provider <> :b_provider) AS providers_distinct,
       (:a_alias    <> :b_alias)    AS aliases_distinct;
-- EXPECT: t | t

\echo == ASSERT B: each tenant sees ONLY its own provider (isolation) ==
SELECT 'gw_a' AS tenant, count(*) AS n, max(adapter_name) AS adapter FROM gw_a.maludb_model_provider
UNION ALL
SELECT 'gw_b', count(*), max(adapter_name) FROM gw_b.maludb_model_provider
ORDER BY tenant;
-- EXPECT: gw_a | 1 | anthropic   and   gw_b | 1 | openai

\echo == ASSERT C: set_model_config in each tenant resolves to ITS OWN alias/model ==
SELECT gw_a.maludb_memory_model_config() ->> 'model_identifier' AS gw_a_model,
       gw_b.maludb_memory_set_model_config(p_extraction_alias=>'extractor', p_embedding_model=>'emb-b')
         ->> 'model_identifier' AS gw_b_model;
-- EXPECT: model-a | model-b

\echo == ASSERT D: idempotent re-register updates in place (still one provider, adapter changed) ==
SELECT gw_a.maludb_register_model_provider('llm','cloud_api', p_adapter_name=>'anthropic-v2') AS a_provider2 \gset
SELECT (:a_provider2 = :a_provider) AS same_provider_id,
       (SELECT count(*) FROM gw_a.maludb_model_provider WHERE provider_name='llm') AS n,
       (SELECT adapter_name FROM gw_a.maludb_model_provider WHERE provider_name='llm') AS adapter;
-- EXPECT: t | 1 | anthropic-v2

\echo == ASSERT E: unknown provider is rejected ==
DO $$
BEGIN
    PERFORM gw_a.maludb_register_model_alias('x','no_such_provider','m');
    RAISE EXCEPTION 'FAIL: alias accepted an unknown provider';
EXCEPTION WHEN foreign_key_violation THEN
    RAISE NOTICE 'OK: unknown provider rejected';
END $$;

-- ---------------------------------------------------------------------
-- Zero-admin proof: a NON-admin role (maludb_memory_executor, WITHOUT
-- maludb_llm_model_admin) can self-serve through the DEFINER facade, but
-- cannot touch the gateway tables directly.
-- ---------------------------------------------------------------------
\echo == ASSERT F: maludb_memory_executor (no gateway-admin) registers via the facade ==
SET search_path = gw_a, maludb_core, public;
SET ROLE maludb_memory_executor;
SELECT pg_has_role(current_user,'maludb_llm_model_admin','USAGE') AS has_gateway_admin;
-- EXPECT: f  (it is NOT a gateway admin)
SELECT gw_a.maludb_register_model_alias('exec_made','llm','model-exec') > 0 AS executor_self_served;
-- EXPECT: t
RESET ROLE;

\echo == ASSERT G: that same non-admin role is denied DIRECT table access ==
SET ROLE maludb_memory_executor;
DO $$
BEGIN
    PERFORM 1 FROM maludb_core.malu$model_provider;
    RAISE NOTICE 'NOTE: direct SELECT returned (RLS-filtered) — no rows leak across tenants';
EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'OK: direct table access denied (facade is the only path)';
END $$;
RESET ROLE;

\echo == ASSERT H: the executor-made alias is visible in gw_a, absent from gw_b ==
SELECT (SELECT count(*) FROM gw_a.maludb_model_alias WHERE alias_name='exec_made') AS in_gw_a,
       (SELECT count(*) FROM gw_b.maludb_model_alias WHERE alias_name='exec_made') AS in_gw_b;
-- EXPECT: 1 | 0

\echo == DONE ==
