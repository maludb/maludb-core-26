SET search_path TO maludb_core, public;
SELECT register_model_provider('stub-test', 'stub', 'stub', 'SECRET-VALUE-DO-NOT-LEAK', 'internal') AS provider_id;
SELECT register_model_provider('cloud-test', 'cloud_api', 'openai', 'env:OPENAI_API_KEY', 'restricted') AS provider_id;
SELECT register_model_alias('alias-stub',  'stub-test',  'stub-model-1') AS alias_id;
SELECT register_model_alias('alias-cloud', 'cloud-test', 'gpt-test',
                            NULL, NULL, NULL, 8192, '{"temperature":0}'::jsonb) AS alias_id;
SELECT count(*) AS provider_count FROM malu$model_provider;
SELECT count(*) AS alias_count    FROM malu$model_alias;
SELECT provider_name, provider_kind, adapter_name, data_sensitivity, enabled
FROM model_provider_public
ORDER BY provider_name;
SELECT count(*) AS secret_ref_columns_in_public_view
FROM information_schema.columns
WHERE table_schema = 'maludb_core'
  AND table_name   = 'model_provider_public'
  AND column_name  = 'secret_ref';
SELECT count(*) AS secret_leaks
FROM model_provider_public
CROSS JOIN LATERAL (
    SELECT to_jsonb(model_provider_public.*)::text AS row_text
) j
WHERE j.row_text LIKE '%SECRET-VALUE-DO-NOT-LEAK%'
   OR j.row_text LIKE '%OPENAI_API_KEY%';
SELECT register_model_provider('bad-kind', 'invalid');
SELECT register_model_alias('bad-alias', 'no-such-provider', 'm');
