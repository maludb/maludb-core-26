SET search_path TO maludb_core, public;
SELECT submit_request('alias-stub', 'hello world',
                      NULL, NULL, '{"max_tokens":16}'::jsonb, 5000) AS request_id \gset
SELECT request_status(:request_id) AS pending_status;
SELECT prompt_hash FROM malu$model_request WHERE request_id = :request_id;
SELECT mc_stub_process(:request_id) AS response_id;
SELECT request_status(:request_id) AS final_status;
SELECT status, output_text, output_hash, adapter_name
FROM get_response(:request_id);
SELECT mc_stub_process(:request_id) AS idempotent_response_id;
SELECT count(*) AS responses_for_request FROM malu$model_response WHERE request_id = :request_id;
SELECT submit_request('alias-stub', 'cancel-me') AS rid \gset
SELECT cancel_request(:rid) AS after_cancel;
SELECT mc_stub_process(:rid) AS cancelled_response_id;
SELECT status, error_class, adapter_name FROM get_response(:rid);
SELECT submit_request('no-such-alias', 'x');
SELECT cancel_request(999999);
