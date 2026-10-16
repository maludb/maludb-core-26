\echo Enabling MaluDB memory schema :schema
SELECT *
FROM maludb_core.enable_memory_schema(:'schema'::name);
