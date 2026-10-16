SET search_path TO maludb_core, pg_catalog;
SELECT object_kind, object_name, stage
FROM stage_boundary_violations();
SELECT count(*) AS violation_count FROM stage_boundary_violations();
SELECT object_type, stage
FROM malu$object_type
WHERE stage = 1
  AND object_type NOT IN
      ('account','partition','model_provider','model_alias',
       'prompt_template','session','listener_config',
       'model_request','model_response',
       'session_context','prompt_render',
       'mc2db_server','mc2db_tool','mc2db_prompt',
       'mc2db_resource','mc2db_invocation',
       'vector_subject','vector_verb',
       'vector_compartment','vector_chunk')
ORDER BY object_type;
