-- =====================================================================
-- maludb_core 0.58.0 -> 0.59.0  (v3.1 Stage B — V3-REALTIME-02a)
--
-- Wire emit_event into the Stage 2 + 5 + 6 register_* helpers so
-- realtime subscribers see ingest activity without callers having to
-- emit events explicitly. Functions instrumented:
--
--   Stage 2:
--     register_source_package        -> register_source_package
--     register_claim                 -> register_claim
--     register_fact                  -> register_fact
--     register_memory                -> register_memory
--     register_episode               -> register_episode
--     register_memory_detail         -> register_memory_detail
--     register_relationship_edge     -> register_relationship_edge
--   Stage 5:
--     register_skill                 -> register_skill
--   Stage 6:
--     register_local_node            -> register_local_node
--
-- Each CREATE OR REPLACE preserves the existing semantics; the only
-- behavior change is a PERFORM emit_event(...) just before RETURN.
-- The event payload is a small jsonb summary that the realtime stream
-- can fan out to subscribers without exposing the full row body.
--
-- Apply with:
--   ALTER EXTENSION maludb_core UPDATE TO '0.59.0';
-- =====================================================================

CREATE OR REPLACE FUNCTION maludb_core_version() RETURNS text
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$ SELECT '0.59.0'::text $body$;

-- ---------------------------------------------------------------------
-- Stage 2 register_* helpers
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION register_source_package(
    p_source_type     text,
    p_content_bytes   bytea   DEFAULT NULL,
    p_content_text    text    DEFAULT NULL,
    p_content_jsonb   jsonb   DEFAULT NULL,
    p_media_type      text    DEFAULT NULL,
    p_origin_jsonb    jsonb   DEFAULT NULL,
    p_captured_at     timestamptz DEFAULT NULL,
    p_retention_class text    DEFAULT 'standard',
    p_sensitivity     text    DEFAULT 'internal'
) RETURNS bigint
LANGUAGE plpgsql
AS $body$
DECLARE
    v_id    bigint;
    v_hash  text;
    v_size  bigint;
    v_bytes bytea;
BEGIN
    IF p_content_bytes IS NULL AND p_content_text IS NULL AND p_content_jsonb IS NULL THEN
        RAISE EXCEPTION 'register_source_package: one of content_bytes / _text / _jsonb is required'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    IF p_content_bytes IS NOT NULL THEN
        v_bytes := p_content_bytes;
    ELSIF p_content_text IS NOT NULL THEN
        v_bytes := convert_to(p_content_text, 'UTF8');
    ELSE
        v_bytes := convert_to(p_content_jsonb::text, 'UTF8');
    END IF;
    v_hash := encode(sha256(v_bytes), 'hex');
    v_size := octet_length(v_bytes);

    INSERT INTO malu$source_package
        (source_type, content_bytes, content_text, content_jsonb,
         content_hash, content_size, media_type, origin_jsonb,
         captured_at, retention_class, sensitivity)
    VALUES
        (p_source_type, p_content_bytes, p_content_text, p_content_jsonb,
         v_hash, v_size, p_media_type, p_origin_jsonb,
         p_captured_at, p_retention_class, p_sensitivity)
    RETURNING source_package_id INTO v_id;

    PERFORM emit_event(
        'register_source_package',
        jsonb_build_object('source_package_id', v_id,
                           'source_type',       p_source_type,
                           'content_hash',      v_hash,
                           'content_size',      v_size,
                           'sensitivity',       p_sensitivity),
        NULL, NULL, NULL,
        'source_package', v_id, NULL);
    RETURN v_id;
END;
$body$;

CREATE OR REPLACE FUNCTION register_claim(
    p_subject           text  DEFAULT NULL,
    p_verb              text  DEFAULT NULL,
    p_predicate         text  DEFAULT NULL,
    p_object_value      text  DEFAULT NULL,
    p_relationship      text  DEFAULT NULL,
    p_statement_text    text  DEFAULT NULL,
    p_statement_jsonb   jsonb DEFAULT NULL,
    p_source_package_id bigint DEFAULT NULL,
    p_source_locator    jsonb DEFAULT NULL,
    p_sensitivity       text  DEFAULT 'internal'
) RETURNS bigint
LANGUAGE plpgsql
AS $body$
DECLARE v_id bigint;
BEGIN
    INSERT INTO malu$claim
        (subject, verb, predicate, object_value, relationship,
         statement_text, statement_jsonb,
         source_package_id, source_locator, sensitivity)
    VALUES (p_subject, p_verb, p_predicate, p_object_value, p_relationship,
            p_statement_text, p_statement_jsonb,
            p_source_package_id, p_source_locator, p_sensitivity)
    RETURNING claim_id INTO v_id;

    PERFORM emit_event(
        'register_claim',
        jsonb_build_object('claim_id',          v_id,
                           'source_package_id', p_source_package_id,
                           'subject',           p_subject,
                           'verb',              p_verb,
                           'predicate',         p_predicate,
                           'sensitivity',       p_sensitivity),
        NULL, NULL, NULL,
        'claim', v_id, NULL);
    RETURN v_id;
END;
$body$;

CREATE OR REPLACE FUNCTION register_fact(
    p_claim_ids         bigint[],
    p_subject           text  DEFAULT NULL,
    p_verb              text  DEFAULT NULL,
    p_predicate         text  DEFAULT NULL,
    p_object_value      text  DEFAULT NULL,
    p_relationship      text  DEFAULT NULL,
    p_statement_text    text  DEFAULT NULL,
    p_statement_jsonb   jsonb DEFAULT NULL,
    p_verification_scope  text DEFAULT NULL,
    p_verification_method text DEFAULT NULL,
    p_sensitivity       text  DEFAULT 'internal'
) RETURNS bigint
LANGUAGE plpgsql
AS $body$
DECLARE
    v_id    bigint;
    v_claim bigint;
BEGIN
    INSERT INTO malu$fact
        (subject, verb, predicate, object_value, relationship,
         statement_text, statement_jsonb,
         verification_scope, verification_method, sensitivity)
    VALUES (p_subject, p_verb, p_predicate, p_object_value, p_relationship,
            p_statement_text, p_statement_jsonb,
            p_verification_scope, p_verification_method, p_sensitivity)
    RETURNING fact_id INTO v_id;

    IF p_claim_ids IS NOT NULL THEN
        FOREACH v_claim IN ARRAY p_claim_ids LOOP
            INSERT INTO malu$fact_claim (fact_id, claim_id)
            VALUES (v_id, v_claim);
        END LOOP;
    END IF;

    PERFORM emit_event(
        'register_fact',
        jsonb_build_object('fact_id',             v_id,
                           'claim_ids',           COALESCE(to_jsonb(p_claim_ids), '[]'::jsonb),
                           'subject',             p_subject,
                           'verb',                p_verb,
                           'predicate',           p_predicate,
                           'verification_method', p_verification_method,
                           'sensitivity',         p_sensitivity),
        NULL, NULL, NULL,
        'fact', v_id, NULL);
    RETURN v_id;
END;
$body$;

CREATE OR REPLACE FUNCTION register_memory(
    p_memory_kind   text,
    p_title         text  DEFAULT NULL,
    p_summary       text  DEFAULT NULL,
    p_payload_jsonb jsonb DEFAULT '{}'::jsonb,
    p_occurred_at   timestamptz DEFAULT NULL,
    p_occurred_until timestamptz DEFAULT NULL,
    p_sensitivity   text  DEFAULT 'internal'
) RETURNS bigint
LANGUAGE plpgsql
AS $body$
DECLARE v_id bigint;
BEGIN
    INSERT INTO malu$memory
        (memory_kind, title, summary, payload_jsonb,
         occurred_at, occurred_until, sensitivity)
    VALUES (p_memory_kind, p_title, p_summary, COALESCE(p_payload_jsonb, '{}'::jsonb),
            p_occurred_at, p_occurred_until, p_sensitivity)
    RETURNING memory_id INTO v_id;

    PERFORM emit_event(
        'register_memory',
        jsonb_build_object('memory_id',   v_id,
                           'memory_kind', p_memory_kind,
                           'title',       p_title,
                           'sensitivity', p_sensitivity),
        NULL, NULL, NULL,
        'memory', v_id, NULL);
    RETURN v_id;
END;
$body$;

CREATE OR REPLACE FUNCTION register_episode(
    p_episode_kind  text,
    p_title         text,
    p_summary       text  DEFAULT NULL,
    p_payload_jsonb jsonb DEFAULT '{}'::jsonb,
    p_occurred_at   timestamptz DEFAULT NULL,
    p_occurred_until timestamptz DEFAULT NULL,
    p_sensitivity   text  DEFAULT 'internal'
) RETURNS bigint
LANGUAGE plpgsql
AS $body$
DECLARE v_id bigint;
BEGIN
    INSERT INTO malu$episode_object
        (episode_kind, title, summary, payload_jsonb,
         occurred_at, occurred_until, sensitivity)
    VALUES (p_episode_kind, p_title, p_summary, COALESCE(p_payload_jsonb, '{}'::jsonb),
            p_occurred_at, p_occurred_until, p_sensitivity)
    RETURNING episode_id INTO v_id;

    PERFORM emit_event(
        'register_episode',
        jsonb_build_object('episode_id',   v_id,
                           'episode_kind', p_episode_kind,
                           'title',        p_title,
                           'sensitivity',  p_sensitivity),
        NULL, NULL, NULL,
        'episode_object', v_id, NULL);
    RETURN v_id;
END;
$body$;

CREATE OR REPLACE FUNCTION register_memory_detail(
    p_detail_kind   text,
    p_parent_mdo_id bigint DEFAULT NULL,
    p_memory_id     bigint DEFAULT NULL,
    p_episode_id    bigint DEFAULT NULL,
    p_ordinal       integer DEFAULT NULL,
    p_title         text   DEFAULT NULL,
    p_body_text     text   DEFAULT NULL,
    p_body_jsonb    jsonb  DEFAULT NULL,
    p_sensitivity   text   DEFAULT 'internal'
) RETURNS bigint
LANGUAGE plpgsql
AS $body$
DECLARE v_id bigint;
BEGIN
    IF p_parent_mdo_id IS NULL AND p_memory_id IS NULL AND p_episode_id IS NULL THEN
        RAISE EXCEPTION
          'register_memory_detail: at least one of parent_mdo_id / memory_id / episode_id required'
          USING ERRCODE = 'invalid_parameter_value';
    END IF;
    INSERT INTO malu$memory_detail_object
        (parent_mdo_id, memory_id, episode_id, detail_kind,
         ordinal, title, body_text, body_jsonb, sensitivity)
    VALUES (p_parent_mdo_id, p_memory_id, p_episode_id, p_detail_kind,
            p_ordinal, p_title, p_body_text, p_body_jsonb, p_sensitivity)
    RETURNING mdo_id INTO v_id;

    PERFORM emit_event(
        'register_memory_detail',
        jsonb_build_object('mdo_id',        v_id,
                           'detail_kind',   p_detail_kind,
                           'parent_mdo_id', p_parent_mdo_id,
                           'memory_id',     p_memory_id,
                           'episode_id',    p_episode_id,
                           'sensitivity',   p_sensitivity),
        NULL, NULL, NULL,
        'memory_detail_object', v_id, NULL);
    RETURN v_id;
END;
$body$;

CREATE OR REPLACE FUNCTION register_relationship_edge(
    p_source_object_type text,
    p_source_object_id   bigint,
    p_target_object_type text,
    p_target_object_id   bigint,
    p_relationship_type  text,
    p_label              text   DEFAULT NULL,
    p_edge_jsonb         jsonb  DEFAULT NULL,
    p_confidence         numeric DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql
AS $body$
DECLARE v_id bigint;
BEGIN
    INSERT INTO malu$relationship_edge
        (relationship_type, source_object_type, source_object_id,
         target_object_type, target_object_id,
         label, edge_jsonb, confidence)
    VALUES (p_relationship_type, p_source_object_type, p_source_object_id,
            p_target_object_type, p_target_object_id,
            p_label, p_edge_jsonb, p_confidence)
    RETURNING edge_id INTO v_id;

    PERFORM emit_event(
        'register_relationship_edge',
        jsonb_build_object('edge_id',             v_id,
                           'relationship_type',   p_relationship_type,
                           'source_object_type',  p_source_object_type,
                           'source_object_id',    p_source_object_id,
                           'target_object_type',  p_target_object_type,
                           'target_object_id',    p_target_object_id),
        NULL, NULL, NULL,
        'relationship_edge', v_id, NULL);
    RETURN v_id;
END;
$body$;

-- ---------------------------------------------------------------------
-- Stage 5 register_skill
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION register_skill(
    p_skill_name           text,
    p_version              text DEFAULT '1.0.0',
    p_description          text DEFAULT NULL,
    p_packaging_kind       text DEFAULT 'markdown',
    p_applicability_jsonb  jsonb DEFAULT '{}'::jsonb,
    p_precondition_jsonb   jsonb DEFAULT '[]'::jsonb
) RETURNS bigint
LANGUAGE plpgsql
AS $body$
DECLARE v_id bigint;
BEGIN
    INSERT INTO malu$skill_package
        (skill_name, version, description, packaging_kind,
         applicability_jsonb, precondition_jsonb)
    VALUES (p_skill_name, p_version, p_description, p_packaging_kind,
            p_applicability_jsonb, p_precondition_jsonb)
    ON CONFLICT (owner_schema, skill_name, version) DO UPDATE
        SET description          = COALESCE(EXCLUDED.description,         malu$skill_package.description),
            packaging_kind       = EXCLUDED.packaging_kind,
            applicability_jsonb  = EXCLUDED.applicability_jsonb,
            precondition_jsonb   = EXCLUDED.precondition_jsonb,
            updated_at           = now()
    RETURNING skill_id INTO v_id;

    PERFORM emit_event(
        'register_skill',
        jsonb_build_object('skill_id',       v_id,
                           'skill_name',     p_skill_name,
                           'version',        p_version,
                           'packaging_kind', p_packaging_kind),
        NULL, NULL, NULL,
        'skill_package', v_id, NULL);
    RETURN v_id;
END;
$body$;

-- ---------------------------------------------------------------------
-- Stage 6 register_local_node
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION register_local_node(
    p_node_name    text,
    p_fingerprint  text,
    p_uri          text DEFAULT NULL,
    p_description  text DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql
AS $body$
DECLARE v_id bigint;
BEGIN
    INSERT INTO malu$local_memory_node
        (node_name, fingerprint, uri, description)
    VALUES (p_node_name, p_fingerprint, p_uri, p_description)
    ON CONFLICT (owner_schema, node_name) DO UPDATE
        SET uri          = COALESCE(EXCLUDED.uri,         malu$local_memory_node.uri),
            description  = COALESCE(EXCLUDED.description, malu$local_memory_node.description),
            last_seen_at = now()
        WHERE malu$local_memory_node.fingerprint = EXCLUDED.fingerprint
    RETURNING node_id INTO v_id;

    IF v_id IS NULL THEN
        RAISE EXCEPTION 'register_local_node: fingerprint mismatch for node %', p_node_name
            USING ERRCODE = 'unique_violation';
    END IF;

    PERFORM audit_event('local_node_registered', NULL, NULL,
        jsonb_build_object('node_id', v_id, 'node_name', p_node_name));

    PERFORM emit_event(
        'register_local_node',
        jsonb_build_object('node_id',   v_id,
                           'node_name', p_node_name,
                           'uri',       p_uri),
        NULL, NULL, NULL,
        'local_memory_node', v_id, NULL);
    RETURN v_id;
END;
$body$;
