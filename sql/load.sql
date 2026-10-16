\pset format unaligned
CREATE EXTENSION maludb_core CASCADE;
SELECT extname, extversion FROM pg_extension WHERE extname = 'maludb_core';
SELECT maludb_core.maludb_core_version();
SELECT maludb_core.maludb_core_release();
SELECT count(*) > 0 AS has_maludb_core_schema
FROM pg_namespace
WHERE nspname = 'maludb_core';
