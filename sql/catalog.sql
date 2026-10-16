SET search_path TO maludb_core, pg_catalog;
SELECT count(*) AS catalog_tables
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'maludb_core'
  AND c.relkind = 'r'
  AND c.relname LIKE 'malu$%';
SELECT count(*) AS object_types FROM malu$object_type;
SELECT count(*) AS relationship_types FROM malu$relationship_type;
SELECT count(*) AS source_types FROM malu$source_type;
SELECT object_type, stage FROM malu$object_type
WHERE stage = 1
ORDER BY object_type;
INSERT INTO malu$account(account_name, account_kind, description)
VALUES ('test_admin', 'admin', 'pg_regress smoke test row');
SELECT account_name, account_kind, enabled
FROM malu$account
WHERE account_name = 'test_admin';
INSERT INTO malu$listener_config(listener_name) VALUES ('default');
SELECT listener_name, bind_host, bind_port, tls_enabled
FROM malu$listener_config
WHERE listener_name = 'default';
