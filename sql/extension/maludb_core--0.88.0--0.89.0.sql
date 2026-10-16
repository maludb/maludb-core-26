\echo Use "ALTER EXTENSION maludb_core UPDATE TO '0.89.0'" to load this file. \quit

-- =====================================================================
-- maludb_core 0.88.0 -> 0.89.0
--
-- Wire the in-database model gateway into the memory-extraction path
-- (the "Option B" design: MaluDB owns model selection + brokering).
--
-- PostgreSQL cannot make an outbound model/API call inside a SQL function,
-- so the gateway is ASYNCHRONOUS and daemon-mediated, exactly like the
-- existing submit_request / malu$model_response lifecycle:
--
--   set config  ->  request (enqueue)  ->  [daemon calls model]  ->  harvest
--
-- Two layers ship here:
--
-- 1. Config layer (per-schema/namespace binding, readable by a worker):
--    * malu$memory_extraction_config -- which model alias extracts, which
--      prompt template, which embedding model, default subject_type /
--      provenance / generation_params.
--    * maludb_memory_set_model_config(...)  -- upsert the binding.
--    * maludb_memory_model_config(...)       -- resolved view (alias ->
--      provider_kind, secret_ref, base_url, embedding_model, ...). Returns
--      the secret_ref ONLY, never the secret value.
--
-- 2. Async pipeline:
--    * maludb_memory_request_extraction(source, chunk) -- render the prompt
--      from the bound template and submit_request() it through the bound
--      alias (so the registered provider/secret/host are used), recording a
--      pending row in malu$memory_extraction tied to the model request.
--    * maludb_memory_harvest_extractions() -- for each completed model
--      response, parse its {"candidate_edges":[...]} JSON and call the
--      0.88.0 _memory_ingest_edge_for_schema per edge (graph edge + typed
--      predicate attributes + per-edge embedding into the compartment).
--
-- The model gateway tables (malu$model_provider / _alias / _request /
-- _response, register_model_provider / register_model_alias / secret_set /
-- submit_request) are GLOBAL (extension-wide), configured once by an admin.
-- The config binding and the pending-extraction queue are per-tenant
-- (owner_schema-scoped, RLS).
--
-- Daemon contract (what fulfills a request): a maludb_modeld-style worker
-- drains malu$model_request, calls the model at the provider's host with the
-- resolved secret, and writes malu$model_response.output_json =
--   {"candidate_edges":[
--      {"subject_text","subject_type","verb_text",
--       "predicate":[{"attr_name","value_text"|"value_timestamp"|"value_numeric",...}],
--       "source_span","confidence","embedding":[...],"embedding_model"}, ...]}
-- (No extraction daemon ships in this repo; the SQL surface is exercised by
-- simulating a response row -- see examples/mist-e2e/04-extraction.sql.)
--
-- Backward compatible: new tables + new functions only; no signature
-- changes. Existing schemas pick up the four facades by re-running
-- maludb_core.enable_memory_schema().
-- =====================================================================

CREATE OR REPLACE FUNCTION maludb_core.maludb_core_version() RETURNS text
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$ SELECT '0.89.0'::text $body$;

-- =====================================================================
-- 0. Gateway correctness fix: submit_request prompt hashing.
--
-- The original hashed the prompt with `p_rendered_prompt::bytea`, which
-- routes text through bytea_in (the escape-format parser), so ANY backslash
-- in the prompt (common in real chunks: file paths, regexes, JSON, code)
-- raised "invalid input syntax for type bytea" and the enqueue failed. Use
-- convert_to(..., 'UTF8') to take the actual UTF-8 bytes. Identical hash for
-- plain ASCII prompts; only the previously-broken cases change. Body is
-- otherwise byte-for-byte the original.
-- =====================================================================
CREATE OR REPLACE FUNCTION maludb_core.submit_request(
    p_alias_name        text,
    p_rendered_prompt   text,
    p_account_name      text DEFAULT NULL,
    p_session_id        bigint DEFAULT NULL,
    p_generation_params jsonb DEFAULT '{}'::jsonb,
    p_timeout_ms        integer DEFAULT 30000
) RETURNS bigint
LANGUAGE plpgsql
AS $body$
DECLARE
    v_alias_id   bigint;
    v_account_id bigint;
    v_request_id bigint;
    v_hash       text;
BEGIN
    SELECT alias_id INTO v_alias_id
    FROM malu$model_alias
    WHERE alias_name = p_alias_name
      AND enabled = true;
    IF v_alias_id IS NULL THEN
        RAISE EXCEPTION 'unknown or disabled alias: %', p_alias_name
            USING ERRCODE = 'foreign_key_violation';
    END IF;

    IF p_account_name IS NOT NULL THEN
        SELECT account_id INTO v_account_id
        FROM malu$account
        WHERE account_name = p_account_name;
        IF v_account_id IS NULL THEN
            RAISE EXCEPTION 'unknown account: %', p_account_name
                USING ERRCODE = 'foreign_key_violation';
        END IF;
    END IF;

    v_hash := encode(sha256(convert_to(p_rendered_prompt, 'UTF8')), 'hex');

    INSERT INTO malu$model_request
           (alias_id, account_id, session_id, rendered_prompt, prompt_hash,
            generation_params, timeout_ms)
    VALUES (v_alias_id, v_account_id, p_session_id, p_rendered_prompt, v_hash,
            COALESCE(p_generation_params, '{}'::jsonb), p_timeout_ms)
    RETURNING request_id INTO v_request_id;

    RETURN v_request_id;
END;
$body$;

-- =====================================================================
-- 1. Per-tenant storage: extraction config + the pending-extraction queue.
-- =====================================================================
CREATE TABLE IF NOT EXISTS maludb_core.malu$memory_extraction_config (
    owner_schema         name NOT NULL DEFAULT current_schema(),
    namespace            text NOT NULL DEFAULT 'default',
    extraction_alias     text NOT NULL,                 -- -> malu$model_alias.alias_name (global)
    prompt_template      text,                          -- {{chunk}} placeholder; NULL -> built-in default
    embedding_model      text,                          -- label recorded on compartment/chunk
    generation_params    jsonb NOT NULL DEFAULT '{}'::jsonb,
    default_subject_type text NOT NULL DEFAULT 'other',
    default_provenance   text NOT NULL DEFAULT 'suggested'
        CHECK (default_provenance IN ('provided','suggested','accepted','rejected')),
    created_at           timestamptz NOT NULL DEFAULT now(),
    updated_at           timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (owner_schema, namespace)
);
ALTER TABLE maludb_core.malu$memory_extraction_config ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_owner ON maludb_core.malu$memory_extraction_config;
CREATE POLICY tenant_owner ON maludb_core.malu$memory_extraction_config
    USING (owner_schema = current_schema())
    WITH CHECK (owner_schema = current_schema());
GRANT SELECT ON maludb_core.malu$memory_extraction_config
    TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;
GRANT INSERT, UPDATE, DELETE ON maludb_core.malu$memory_extraction_config
    TO maludb_memory_admin, maludb_memory_executor;

CREATE TABLE IF NOT EXISTS maludb_core.malu$memory_extraction (
    extraction_id  bigserial PRIMARY KEY,
    owner_schema   name NOT NULL DEFAULT current_schema(),
    namespace      text NOT NULL DEFAULT 'default',
    source_kind    text NOT NULL,
    source_id      bigint NOT NULL,
    chunk_text     text NOT NULL,
    request_id     bigint REFERENCES maludb_core.malu$model_request(request_id) ON DELETE SET NULL,
    status         text NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending','harvested','empty','failed')),
    edge_count     integer NOT NULL DEFAULT 0,
    statement_ids  bigint[] NOT NULL DEFAULT ARRAY[]::bigint[],
    error          text,
    created_at     timestamptz NOT NULL DEFAULT now(),
    harvested_at   timestamptz
);
ALTER TABLE maludb_core.malu$memory_extraction ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_owner ON maludb_core.malu$memory_extraction;
CREATE POLICY tenant_owner ON maludb_core.malu$memory_extraction
    USING (owner_schema = current_schema())
    WITH CHECK (owner_schema = current_schema());
GRANT SELECT ON maludb_core.malu$memory_extraction
    TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;
GRANT INSERT, UPDATE, DELETE ON maludb_core.malu$memory_extraction
    TO maludb_memory_admin, maludb_memory_executor;
CREATE INDEX IF NOT EXISTS malu$memory_extraction_pending_idx
    ON maludb_core.malu$memory_extraction(owner_schema, namespace, status)
    WHERE status = 'pending';
CREATE INDEX IF NOT EXISTS malu$memory_extraction_request_idx
    ON maludb_core.malu$memory_extraction(request_id)
    WHERE request_id IS NOT NULL;

-- =====================================================================
-- 2. Config layer -- set + resolve the per-schema model binding.
-- =====================================================================
CREATE OR REPLACE FUNCTION maludb_core._memory_model_config_for_schema(
    p_owner_schema name,
    p_namespace    text DEFAULT 'default'
) RETURNS jsonb
LANGUAGE plpgsql STABLE
SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
DECLARE
    v_namespace text := COALESCE(NULLIF(p_namespace, ''), 'default');
    v_result    jsonb;
BEGIN
    PERFORM maludb_core._memory_schema_assert_manageable(p_owner_schema);

    SELECT jsonb_strip_nulls(jsonb_build_object(
               'namespace',            c.namespace,
               'extraction_alias',     c.extraction_alias,
               'model_identifier',     a.model_identifier,
               'provider_name',        p.provider_name,
               'provider_kind',        p.provider_kind,
               'adapter_name',         p.adapter_name,
               'secret_ref',           p.secret_ref,           -- pointer only, NOT the value
               'base_url',             a.runtime_params ->> 'base_url',
               'context_length',       a.context_length,
               'generation_params',    c.generation_params,
               'embedding_model',      c.embedding_model,
               'prompt_template',      c.prompt_template,
               'default_subject_type', c.default_subject_type,
               'default_provenance',   c.default_provenance,
               'alias_enabled',        a.enabled))
      INTO v_result
      FROM maludb_core.malu$memory_extraction_config c
      LEFT JOIN maludb_core.malu$model_alias    a ON a.owner_schema = c.owner_schema
                                                 AND a.alias_name   = c.extraction_alias
      LEFT JOIN maludb_core.malu$model_provider p ON p.provider_id  = a.provider_id
     WHERE c.owner_schema = p_owner_schema
       AND c.namespace    = v_namespace;

    RETURN v_result;   -- NULL if nothing configured for this namespace
END;
$body$;
REVOKE ALL ON FUNCTION maludb_core._memory_model_config_for_schema(name, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core._memory_model_config_for_schema(name, text)
    TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;

CREATE OR REPLACE FUNCTION maludb_core._memory_set_model_config_for_schema(
    p_owner_schema         name,
    p_extraction_alias     text,
    p_prompt_template      text    DEFAULT NULL,
    p_embedding_model      text    DEFAULT NULL,
    p_namespace            text    DEFAULT 'default',
    p_generation_params    jsonb   DEFAULT '{}'::jsonb,
    p_default_subject_type text    DEFAULT 'other',
    p_default_provenance   text    DEFAULT 'suggested'
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
DECLARE
    v_namespace text := COALESCE(NULLIF(p_namespace, ''), 'default');
    v_alias     text := btrim(COALESCE(p_extraction_alias, ''));
    v_prov      text := COALESCE(NULLIF(btrim(p_default_provenance), ''), 'suggested');
    v_subjtype  text := maludb_core._normalize_svpor_subject_type(
                            COALESCE(NULLIF(btrim(p_default_subject_type), ''), 'other'));
BEGIN
    PERFORM maludb_core._memory_schema_assert_manageable(p_owner_schema);

    IF v_alias = '' THEN
        RAISE EXCEPTION 'memory_set_model_config: extraction_alias is required'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;
    IF v_prov NOT IN ('provided','suggested','accepted','rejected') THEN
        RAISE EXCEPTION 'memory_set_model_config: bad default_provenance %', v_prov
            USING ERRCODE = 'invalid_parameter_value';
    END IF;
    -- the model alias is per-tenant gateway config; it must already be registered
    -- in this schema (owner_schema-scoped: malu$model_alias UNIQUE(owner_schema, alias_name)).
    IF NOT EXISTS (SELECT 1 FROM maludb_core.malu$model_alias
                    WHERE owner_schema = p_owner_schema AND alias_name = v_alias) THEN
        RAISE EXCEPTION 'memory_set_model_config: unknown model alias % in schema % (register it with maludb_core.register_model_alias first)', v_alias, p_owner_schema
            USING ERRCODE = 'foreign_key_violation';
    END IF;

    INSERT INTO maludb_core.malu$memory_extraction_config
        (owner_schema, namespace, extraction_alias, prompt_template, embedding_model,
         generation_params, default_subject_type, default_provenance)
    VALUES
        (p_owner_schema, v_namespace, v_alias,
         NULLIF(btrim(COALESCE(p_prompt_template, '')), ''),
         NULLIF(btrim(COALESCE(p_embedding_model, '')), ''),
         COALESCE(p_generation_params, '{}'::jsonb), v_subjtype, v_prov)
    ON CONFLICT (owner_schema, namespace) DO UPDATE SET
        extraction_alias     = EXCLUDED.extraction_alias,
        prompt_template      = EXCLUDED.prompt_template,
        embedding_model      = EXCLUDED.embedding_model,
        generation_params    = EXCLUDED.generation_params,
        default_subject_type = EXCLUDED.default_subject_type,
        default_provenance   = EXCLUDED.default_provenance,
        updated_at           = now();

    RETURN maludb_core._memory_model_config_for_schema(p_owner_schema, v_namespace);
END;
$body$;
REVOKE ALL ON FUNCTION maludb_core._memory_set_model_config_for_schema(name, text, text, text, text, jsonb, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core._memory_set_model_config_for_schema(name, text, text, text, text, jsonb, text, text)
    TO maludb_memory_admin, maludb_memory_executor;

-- =====================================================================
-- 3. Enqueue -- render the bound prompt and submit_request() it through the
--    bound alias, recording a pending extraction tied to the model request.
-- =====================================================================
CREATE OR REPLACE FUNCTION maludb_core._memory_request_extraction_for_schema(
    p_owner_schema name,
    p_source_kind  text,
    p_source_id    bigint,
    p_chunk_text   text,
    p_namespace    text DEFAULT 'default'
) RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
DECLARE
    v_namespace   text := COALESCE(NULLIF(p_namespace, ''), 'default');
    v_source_kind text := lower(btrim(COALESCE(p_source_kind, '')));
    v_alias       text;
    v_cfg_prompt  text;
    v_genparams   jsonb;
    v_template    text;
    v_prompt      text;
    v_request_id  bigint;
    v_alias_id    bigint;
    v_hash        text;
    v_default_prompt text :=
        'You convert a document chunk into canonical memory edges for a knowledge graph. '
     || 'Return ONLY JSON of the form '
     || '{"candidate_edges":[{"subject_text":"<entity the memory is about>",'
     || '"subject_type":"<person|software|project|...>","verb_text":"<small canonical verb>",'
     || '"predicate":[{"attr_name":"status","value_text":"completed"},'
     || '{"attr_name":"event_at","value_timestamp":"<ISO 8601>"}],'
     || '"source_span":"<verbatim span>","confidence":0.0,'
     || '"embedding":[<floats>],"embedding_model":"<model>"}]}. '
     || 'Use a small canonical verb (e.g. "upgrade", not "performed_upgrade"); put '
     || 'status / timing / details in predicate attributes.'
     || E'\n\nCHUNK:\n{{chunk}}';
BEGIN
    PERFORM maludb_core._memory_schema_assert_manageable(p_owner_schema);

    IF v_source_kind = '' OR p_source_id IS NULL THEN
        RAISE EXCEPTION 'memory_request_extraction: source_kind and source_id are required'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;
    IF COALESCE(btrim(p_chunk_text), '') = '' THEN
        RAISE EXCEPTION 'memory_request_extraction: chunk_text is required'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    SELECT extraction_alias, prompt_template, generation_params
      INTO v_alias, v_cfg_prompt, v_genparams
      FROM maludb_core.malu$memory_extraction_config
     WHERE owner_schema = p_owner_schema AND namespace = v_namespace;

    IF v_alias IS NULL THEN
        RAISE EXCEPTION 'memory_request_extraction: no extraction model configured for schema % namespace % (call maludb_memory_set_model_config first)',
            p_owner_schema, v_namespace
            USING ERRCODE = 'no_data_found';
    END IF;

    -- resolve the alias within THIS tenant (the gateway is owner_schema-scoped).
    SELECT alias_id INTO v_alias_id
      FROM maludb_core.malu$model_alias
     WHERE owner_schema = p_owner_schema AND alias_name = v_alias AND enabled = true;
    IF v_alias_id IS NULL THEN
        RAISE EXCEPTION 'memory_request_extraction: model alias % is not registered/enabled in schema %', v_alias, p_owner_schema
            USING ERRCODE = 'foreign_key_violation';
    END IF;

    v_template := COALESCE(NULLIF(btrim(COALESCE(v_cfg_prompt, '')), ''), v_default_prompt);
    IF position('{{chunk}}' IN v_template) > 0 THEN
        v_prompt := replace(v_template, '{{chunk}}', p_chunk_text);
    ELSE
        v_prompt := v_template || E'\n\nCHUNK:\n' || p_chunk_text;
    END IF;

    -- enqueue into the model gateway with EXPLICIT owner_schema (this runs under a
    -- DEFINER search_path where current_schema() is not the tenant, so we cannot lean
    -- on submit_request's current_schema()-based owner_schema default). UTF-8 prompt
    -- hash; idempotency_key left NULL so the gateway's idempotency index is bypassed.
    v_hash := encode(sha256(convert_to(v_prompt, 'UTF8')), 'hex');
    INSERT INTO maludb_core.malu$model_request
        (owner_schema, alias_id, rendered_prompt, prompt_hash, generation_params, timeout_ms)
    VALUES
        (p_owner_schema, v_alias_id, v_prompt, v_hash, COALESCE(v_genparams, '{}'::jsonb), 30000)
    RETURNING request_id INTO v_request_id;

    INSERT INTO maludb_core.malu$memory_extraction
        (owner_schema, namespace, source_kind, source_id, chunk_text, request_id, status)
    VALUES
        (p_owner_schema, v_namespace, v_source_kind, p_source_id, p_chunk_text, v_request_id, 'pending');

    RETURN v_request_id;
END;
$body$;
REVOKE ALL ON FUNCTION maludb_core._memory_request_extraction_for_schema(name, text, bigint, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core._memory_request_extraction_for_schema(name, text, bigint, text, text)
    TO maludb_memory_admin, maludb_memory_executor;

-- =====================================================================
-- 4. Harvest -- turn completed model responses into ingested edges.
-- =====================================================================
CREATE OR REPLACE FUNCTION maludb_core._memory_harvest_extractions_for_schema(
    p_owner_schema name,
    p_limit        integer DEFAULT 100,
    p_namespace    text    DEFAULT NULL
) RETURNS TABLE (
    extraction_id bigint,
    request_id    bigint,
    status        text,
    edge_count    integer
) LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
#variable_conflict use_column
DECLARE
    r        record;
    v_eid    bigint;
    v_req    bigint;
    v_payload jsonb;
    v_edges  jsonb;
    v_edge   jsonb;
    v_subj   text;
    v_vrb    text;
    v_pred   jsonb;
    v_emb    maludb_core.malu_vector;
    v_stmt   bigint;
    v_cnt    integer;
    v_ids    bigint[];
    v_status text;
BEGIN
    PERFORM maludb_core._memory_schema_assert_manageable(p_owner_schema);

    FOR r IN
        SELECT me.extraction_id AS eid,
               me.request_id    AS req,
               me.namespace     AS ns,
               me.source_kind   AS source_kind,
               me.source_id     AS source_id,
               resp.status      AS resp_status,
               resp.output_json AS out_json,
               resp.output_text AS out_text,
               COALESCE(cfg.embedding_model, 'unspecified')  AS cfg_embedding_model,
               COALESCE(cfg.default_subject_type, 'other')   AS cfg_subject_type,
               COALESCE(cfg.default_provenance, 'suggested') AS cfg_provenance,
               COALESCE(cfg.extraction_alias, 'unknown')     AS cfg_alias
          FROM maludb_core.malu$memory_extraction me
          JOIN maludb_core.malu$model_response resp ON resp.request_id = me.request_id
          LEFT JOIN maludb_core.malu$memory_extraction_config cfg
                 ON cfg.owner_schema = me.owner_schema AND cfg.namespace = me.namespace
         WHERE me.owner_schema = p_owner_schema
           AND me.status = 'pending'
           AND (p_namespace IS NULL OR me.namespace = p_namespace)
         ORDER BY me.extraction_id
         LIMIT GREATEST(COALESCE(p_limit, 100), 1)
    LOOP
        v_eid := r.eid;
        v_req := r.req;
        BEGIN
            IF r.resp_status <> 'succeeded' THEN
                UPDATE maludb_core.malu$memory_extraction
                   SET status = 'failed', error = 'model response status: ' || r.resp_status,
                       harvested_at = now()
                 WHERE extraction_id = v_eid;
                extraction_id := v_eid; request_id := v_req; status := 'failed'; edge_count := 0;
                RETURN NEXT; CONTINUE;
            END IF;

            v_payload := COALESCE(r.out_json, NULLIF(btrim(COALESCE(r.out_text, '')), '')::jsonb);
            v_edges := CASE
                WHEN jsonb_typeof(v_payload) = 'array' THEN v_payload
                WHEN v_payload ? 'candidate_edges'     THEN v_payload -> 'candidate_edges'
                ELSE '[]'::jsonb
            END;

            v_cnt := 0;
            v_ids := ARRAY[]::bigint[];

            FOR v_edge IN SELECT * FROM jsonb_array_elements(COALESCE(v_edges, '[]'::jsonb))
            LOOP
                v_subj := COALESCE(v_edge ->> 'subject_text', v_edge ->> 'subject');
                v_vrb  := COALESCE(v_edge ->> 'verb_text',    v_edge ->> 'verb');
                IF COALESCE(btrim(v_subj), '') = '' OR COALESCE(btrim(v_vrb), '') = '' THEN
                    CONTINUE;
                END IF;

                -- predicate: accept the attributes_apply array form, or convert a
                -- flat {key:value} object to text attributes.
                v_pred := v_edge -> 'predicate';
                IF v_pred IS NULL OR jsonb_typeof(v_pred) = 'null' THEN
                    v_pred := '[]'::jsonb;
                ELSIF jsonb_typeof(v_pred) = 'object' THEN
                    SELECT COALESCE(jsonb_agg(jsonb_build_object('attr_name', k, 'value_text', val)), '[]'::jsonb)
                      INTO v_pred
                      FROM jsonb_each_text(v_edge -> 'predicate') AS e(k, val);
                ELSIF jsonb_typeof(v_pred) <> 'array' THEN
                    v_pred := '[]'::jsonb;
                END IF;

                -- per-edge embedding, if the daemon supplied one.
                v_emb := NULL;
                IF jsonb_typeof(v_edge -> 'embedding') = 'array' THEN
                    v_emb := (v_edge -> 'embedding')::text::maludb_core.malu_vector;
                END IF;

                v_stmt := maludb_core._memory_ingest_edge_for_schema(
                    p_owner_schema,
                    r.source_kind,
                    r.source_id,
                    v_subj,
                    v_vrb,
                    v_pred,
                    v_emb,
                    COALESCE(v_edge ->> 'embedding_model', r.cfg_embedding_model),
                    COALESCE(v_edge ->> 'subject_type',    r.cfg_subject_type),
                    v_edge ->> 'source_span',
                    (v_edge ->> 'confidence')::numeric,
                    r.cfg_provenance,
                    r.cfg_alias,                                  -- extraction_model label
                    r.ns,
                    CASE WHEN lower(r.source_kind) = 'document' THEN r.source_id ELSE NULL END,
                    NULL, NULL, 'cosine');

                v_cnt := v_cnt + 1;
                v_ids := v_ids || v_stmt;
            END LOOP;

            v_status := CASE WHEN v_cnt > 0 THEN 'harvested' ELSE 'empty' END;
            UPDATE maludb_core.malu$memory_extraction
               SET status = v_status, edge_count = v_cnt, statement_ids = v_ids,
                   error = NULL, harvested_at = now()
             WHERE extraction_id = v_eid;

            extraction_id := v_eid; request_id := v_req; status := v_status; edge_count := v_cnt;
            RETURN NEXT;
        EXCEPTION WHEN OTHERS THEN
            UPDATE maludb_core.malu$memory_extraction
               SET status = 'failed', error = left(SQLERRM, 500), harvested_at = now()
             WHERE extraction_id = v_eid;
            extraction_id := v_eid; request_id := v_req; status := 'failed'; edge_count := 0;
            RETURN NEXT;
        END;
    END LOOP;

    RETURN;
END;
$body$;
REVOKE ALL ON FUNCTION maludb_core._memory_harvest_extractions_for_schema(name, integer, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core._memory_harvest_extractions_for_schema(name, integer, text)
    TO maludb_memory_admin, maludb_memory_executor;

-- =====================================================================
-- 5. 0.89.0 schema-local facade builder.
-- =====================================================================
CREATE OR REPLACE FUNCTION maludb_core._enable_memory_schema_0890_facade(p_schema name) RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
DECLARE
    v_count integer := 0;
BEGIN
    PERFORM maludb_core._memory_schema_assert_manageable(p_schema);

    -- maludb_memory_set_model_config(...)
    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_memory_set_model_config', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_memory_set_model_config(
            p_extraction_alias     text,
            p_prompt_template      text  DEFAULT NULL,
            p_embedding_model      text  DEFAULT NULL,
            p_namespace            text  DEFAULT 'default',
            p_generation_params    jsonb DEFAULT '{}'::jsonb,
            p_default_subject_type text  DEFAULT 'other',
            p_default_provenance   text  DEFAULT 'suggested'
        ) RETURNS jsonb
        LANGUAGE sql SECURITY DEFINER
        SET search_path = pg_catalog, maludb_core, pg_temp
        AS $facade$
            SELECT maludb_core._memory_set_model_config_for_schema(
                %L::name, p_extraction_alias, p_prompt_template, p_embedding_model,
                p_namespace, p_generation_params, p_default_subject_type, p_default_provenance)
        $facade$
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_memory_set_model_config(text, text, text, text, jsonb, text, text) FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_memory_set_model_config(text, text, text, text, jsonb, text, text) TO maludb_memory_admin, maludb_memory_executor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_memory_set_model_config', 'function', 'Bind which model alias / prompt / embedding model extracts memory edges.');
    v_count := v_count + 1;

    -- maludb_memory_model_config(...)
    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_memory_model_config', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_memory_model_config(
            p_namespace text DEFAULT 'default'
        ) RETURNS jsonb
        LANGUAGE sql STABLE SECURITY DEFINER
        SET search_path = pg_catalog, maludb_core, pg_temp
        AS $facade$
            SELECT maludb_core._memory_model_config_for_schema(%L::name, p_namespace)
        $facade$
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_memory_model_config(text) FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_memory_model_config(text) TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_memory_model_config', 'function', 'Resolved extraction model binding (alias -> provider, secret_ref, base_url, embedding model).');
    v_count := v_count + 1;

    -- maludb_memory_request_extraction(...)
    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_memory_request_extraction', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_memory_request_extraction(
            p_source_kind text,
            p_source_id   bigint,
            p_chunk_text  text,
            p_namespace   text DEFAULT 'default'
        ) RETURNS bigint
        LANGUAGE sql SECURITY DEFINER
        SET search_path = pg_catalog, maludb_core, pg_temp
        AS $facade$
            SELECT maludb_core._memory_request_extraction_for_schema(
                %L::name, p_source_kind, p_source_id, p_chunk_text, p_namespace)
        $facade$
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_memory_request_extraction(text, bigint, text, text) FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_memory_request_extraction(text, bigint, text, text) TO maludb_memory_admin, maludb_memory_executor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_memory_request_extraction', 'function', 'Enqueue a chunk for SVP extraction through the bound model alias.');
    v_count := v_count + 1;

    -- maludb_memory_harvest_extractions(...)
    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_memory_harvest_extractions', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_memory_harvest_extractions(
            p_limit     integer DEFAULT 100,
            p_namespace text    DEFAULT NULL
        ) RETURNS TABLE (
            extraction_id bigint,
            request_id    bigint,
            status        text,
            edge_count    integer
        )
        LANGUAGE sql SECURITY DEFINER
        SET search_path = pg_catalog, maludb_core, pg_temp
        AS $facade$
            SELECT * FROM maludb_core._memory_harvest_extractions_for_schema(%L::name, p_limit, p_namespace)
        $facade$
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_memory_harvest_extractions(integer, text) FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_memory_harvest_extractions(integer, text) TO maludb_memory_admin, maludb_memory_executor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_memory_harvest_extractions', 'function', 'Promote completed extraction responses into graph edges + compartment embeddings.');
    v_count := v_count + 1;

    RETURN v_count;
END;
$body$;

REVOKE ALL ON FUNCTION maludb_core._enable_memory_schema_0890_facade(name) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core._enable_memory_schema_0890_facade(name)
    TO maludb_memory_admin, maludb_memory_executor;

-- =====================================================================
-- 6. Wire the 0890 facade into enable_memory_schema.
-- =====================================================================
CREATE OR REPLACE FUNCTION maludb_core.enable_memory_schema(p_schema name DEFAULT current_schema())
RETURNS TABLE(schema_name name, enabled_version text, object_count integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
DECLARE
    v_enabled_version text := maludb_core.maludb_core_version();
    v_count integer := 0;
    v_view  name;
BEGIN
    IF p_schema IS NULL THEN
        p_schema := current_schema();
    END IF;

    PERFORM maludb_core._memory_schema_assert_manageable(p_schema);

    FOREACH v_view IN ARRAY ARRAY['maludb_subject','maludb_memory','maludb_skill','maludb_document','maludb_svpor_attribute']::name[]
    LOOP
        IF EXISTS (
            SELECT 1 FROM maludb_core.malu$enabled_schema_object o
             WHERE o.schema_name = p_schema
               AND o.object_name = v_view
               AND o.object_kind = 'view'
        ) THEN
            EXECUTE format('DROP VIEW IF EXISTS %I.%I CASCADE', p_schema, v_view);
        END IF;
    END LOOP;

    INSERT INTO maludb_core.malu$enabled_schema(schema_name, enabled_version, enabled_by)
    VALUES (p_schema, v_enabled_version, session_user)
    ON CONFLICT ON CONSTRAINT malu$enabled_schema_pkey DO UPDATE
       SET enabled_version   = EXCLUDED.enabled_version,
           last_refreshed_at = now();

    v_count := v_count + maludb_core._enable_memory_schema_subject_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_core_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_ingest_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_pool_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_ai_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_075_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_076_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_078_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_080_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_0802_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_0803_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_0810_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_0820_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_0830_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_0840_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_0850_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_0860_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_0870_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_0880_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_0890_facade(p_schema);
    PERFORM maludb_core._grant_memory_schema_reader_access(p_schema);

    schema_name := p_schema;
    enabled_version := v_enabled_version;
    object_count := v_count;
    RETURN NEXT;
END;
$body$;

REVOKE ALL ON FUNCTION maludb_core.enable_memory_schema(name) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core.enable_memory_schema(name)
    TO maludb_memory_admin, maludb_memory_executor, maludb_user, maludb_admin;
