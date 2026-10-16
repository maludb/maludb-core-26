\echo Use "ALTER EXTENSION maludb_core UPDATE TO '0.75.0'" to load this file. \quit

-- ---------------------------------------------------------------------
-- maludb_core 0.74.0 -> 0.75.0
-- Note documents with SVPOR hints, typed SVPOR identifiers, and
-- subject/verb relationship + phrase-search support.
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION maludb_core.maludb_core_version() RETURNS text
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$ SELECT '0.75.0'::text $body$;

INSERT INTO maludb_core.malu$source_type(source_type, stage, description)
VALUES ('note', 2, 'End-user quick-added note stored as a document source.')
ON CONFLICT (source_type) DO UPDATE
    SET stage = EXCLUDED.stage,
        description = EXCLUDED.description;

INSERT INTO maludb_core.malu$source_type(source_type, stage, description)
VALUES ('llm-chat', 2, 'End-user chat with MaluDB, AI agents, model sessions, tools, or assistant workflows.')
ON CONFLICT (source_type) DO UPDATE
    SET stage = EXCLUDED.stage,
        description = EXCLUDED.description;

CREATE TABLE maludb_core.malu$document_svpor_hint (
    hint_id            bigserial PRIMARY KEY,
    owner_schema       name NOT NULL DEFAULT current_schema(),
    document_id        bigint NOT NULL,
    project_subject_id bigint REFERENCES maludb_core.malu$svpor_subject(subject_id) ON DELETE SET NULL,
    project_name       text,
    subject_id         bigint REFERENCES maludb_core.malu$svpor_subject(subject_id) ON DELETE SET NULL,
    subject_name       text,
    verb_id            bigint REFERENCES maludb_core.malu$svpor_verb(verb_id) ON DELETE SET NULL,
    verb_name          text,
    provenance         text NOT NULL DEFAULT 'provided'
        CHECK (provenance IN ('provided','suggested','accepted','rejected')),
    confidence         numeric(5,4) CHECK (confidence IS NULL OR confidence BETWEEN 0 AND 1),
    metadata_jsonb     jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at         timestamptz NOT NULL DEFAULT now(),
    CHECK (
        project_subject_id IS NOT NULL OR NULLIF(project_name, '') IS NOT NULL OR
        subject_id IS NOT NULL OR NULLIF(subject_name, '') IS NOT NULL OR
        verb_id IS NOT NULL OR NULLIF(verb_name, '') IS NOT NULL
    ),
    FOREIGN KEY (owner_schema, document_id)
        REFERENCES maludb_core.malu$document(owner_schema, document_id) ON DELETE CASCADE
);

CREATE INDEX malu$document_svpor_hint_document_idx
    ON maludb_core.malu$document_svpor_hint(document_id);
CREATE INDEX malu$document_svpor_hint_lookup_idx
    ON maludb_core.malu$document_svpor_hint(owner_schema, project_name, subject_name, verb_name);

ALTER TABLE maludb_core.malu$document_svpor_hint ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_owner ON maludb_core.malu$document_svpor_hint
    USING (owner_schema = current_schema())
    WITH CHECK (owner_schema = current_schema());

GRANT SELECT ON maludb_core.malu$document_svpor_hint TO
    maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;
GRANT INSERT, UPDATE, DELETE ON maludb_core.malu$document_svpor_hint TO
    maludb_memory_admin, maludb_memory_executor;
GRANT USAGE, SELECT ON SEQUENCE maludb_core.malu$document_svpor_hint_hint_id_seq TO
    maludb_memory_admin, maludb_memory_executor;

CREATE FUNCTION maludb_core._insert_document_svpor_hints_for_schema(
    p_owner_schema name,
    p_document_id bigint,
    p_svpor_frames jsonb DEFAULT '[]'::jsonb
) RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
DECLARE
    v_frame jsonb;
    v_count integer := 0;
BEGIN
    PERFORM maludb_core._memory_schema_assert_manageable(p_owner_schema);

    IF p_svpor_frames IS NULL THEN
        RETURN 0;
    END IF;
    IF jsonb_typeof(p_svpor_frames) <> 'array' THEN
        RAISE EXCEPTION 'svpor_frames must be a JSON array'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    FOR v_frame IN SELECT value FROM jsonb_array_elements(p_svpor_frames)
    LOOP
        IF jsonb_typeof(v_frame) <> 'object' THEN
            RAISE EXCEPTION 'each svpor frame must be a JSON object'
                USING ERRCODE = 'invalid_parameter_value';
        END IF;

        INSERT INTO maludb_core.malu$document_svpor_hint(
            owner_schema, document_id,
            project_subject_id, project_name,
            subject_id, subject_name,
            verb_id, verb_name,
            provenance, confidence, metadata_jsonb
        )
        VALUES (
            p_owner_schema, p_document_id,
            NULLIF(v_frame ->> 'project_id', '')::bigint,
            NULLIF(btrim(v_frame ->> 'project'), ''),
            NULLIF(v_frame ->> 'subject_id', '')::bigint,
            NULLIF(btrim(v_frame ->> 'subject'), ''),
            NULLIF(v_frame ->> 'verb_id', '')::bigint,
            NULLIF(btrim(v_frame ->> 'verb'), ''),
            COALESCE(NULLIF(v_frame ->> 'provenance', ''), 'provided'),
            NULLIF(v_frame ->> 'confidence', '')::numeric,
            COALESCE(v_frame -> 'metadata', '{}'::jsonb)
        );
        v_count := v_count + 1;
    END LOOP;

    RETURN v_count;
END;
$body$;

REVOKE ALL ON FUNCTION maludb_core._insert_document_svpor_hints_for_schema(name, bigint, jsonb) FROM PUBLIC;

CREATE FUNCTION maludb_core.quick_add_note(
    p_title text,
    p_body_text text,
    p_projects text[] DEFAULT ARRAY[]::text[],
    p_subjects text[] DEFAULT ARRAY[]::text[],
    p_verbs text[] DEFAULT ARRAY[]::text[],
    p_svpor_frames jsonb DEFAULT '[]'::jsonb,
    p_metadata_jsonb jsonb DEFAULT '{}'::jsonb
) RETURNS bigint
LANGUAGE plpgsql
SECURITY INVOKER
AS $body$
DECLARE
    v_document_id bigint;
BEGIN
    v_document_id := maludb_core.upload_document(
        p_title => p_title,
        p_content_text => p_body_text,
        p_source_type => 'note',
        p_content_jsonb => NULL,
        p_media_type => 'text/plain',
        p_projects => p_projects,
        p_subjects => p_subjects,
        p_verbs => p_verbs,
        p_events => ARRAY[]::text[],
        p_metadata_jsonb => COALESCE(p_metadata_jsonb, '{}'::jsonb)
    );

    PERFORM maludb_core._insert_document_svpor_hints_for_schema(
        current_schema()::name,
        v_document_id,
        COALESCE(p_svpor_frames, '[]'::jsonb)
    );

    RETURN v_document_id;
END;
$body$;

REVOKE ALL ON FUNCTION maludb_core.quick_add_note(text, text, text[], text[], text[], jsonb, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core.quick_add_note(text, text, text[], text[], text[], jsonb, jsonb)
TO maludb_memory_admin, maludb_memory_executor;

CREATE FUNCTION maludb_core.document_get(p_document_id bigint)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY INVOKER
AS $body$
    SELECT jsonb_build_object(
        'document', to_jsonb(d),
        'tags', COALESCE((
            SELECT jsonb_agg(to_jsonb(t) ORDER BY t.tag_kind, t.tag_value, t.tag_id)
              FROM maludb_core.malu$document_tag t
             WHERE t.owner_schema = d.owner_schema
               AND t.document_id = d.document_id
        ), '[]'::jsonb),
        'svpor_hints', COALESCE((
            SELECT jsonb_agg(to_jsonb(h) ORDER BY h.hint_id)
              FROM maludb_core.malu$document_svpor_hint h
             WHERE h.owner_schema = d.owner_schema
               AND h.document_id = d.document_id
        ), '[]'::jsonb)
    )
    FROM maludb_core.malu$document d
    WHERE d.owner_schema = current_schema()
      AND d.document_id = p_document_id
$body$;

REVOKE ALL ON FUNCTION maludb_core.document_get(bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core.document_get(bigint)
TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;

CREATE TABLE maludb_core.malu$chat_session (
    chat_session_id           bigserial PRIMARY KEY,
    owner_schema              name NOT NULL DEFAULT current_schema(),
    account_id                bigint REFERENCES maludb_core.malu$account(account_id) ON DELETE SET NULL,
    model_session_id          bigint REFERENCES maludb_core.malu$session(session_id) ON DELETE SET NULL,
    document_id               bigint REFERENCES maludb_core.malu$document(document_id) ON DELETE SET NULL,
    source_package_id         bigint REFERENCES maludb_core.malu$source_package(source_package_id) ON DELETE SET NULL,
    chat_title                text NOT NULL,
    lifecycle_state           text NOT NULL DEFAULT 'open'
        CHECK (lifecycle_state IN ('open','closed','errored','archived','tombstoned')),
    primary_project_subject_id bigint REFERENCES maludb_core.malu$svpor_subject(subject_id) ON DELETE SET NULL,
    projects                  text[] NOT NULL DEFAULT ARRAY[]::text[],
    subjects                  text[] NOT NULL DEFAULT ARRAY[]::text[],
    verbs                     text[] NOT NULL DEFAULT ARRAY[]::text[],
    svpor_frames              jsonb NOT NULL DEFAULT '[]'::jsonb,
    started_at                timestamptz NOT NULL DEFAULT now(),
    last_message_at           timestamptz,
    closed_at                 timestamptz,
    message_count             integer NOT NULL DEFAULT 0 CHECK (message_count >= 0),
    metadata_jsonb            jsonb NOT NULL DEFAULT '{}'::jsonb,
    UNIQUE (owner_schema, chat_session_id)
);

CREATE INDEX malu$chat_session_owner_idx
    ON maludb_core.malu$chat_session(owner_schema, started_at DESC);
CREATE INDEX malu$chat_session_document_idx
    ON maludb_core.malu$chat_session(document_id)
    WHERE document_id IS NOT NULL;
CREATE INDEX malu$chat_session_source_idx
    ON maludb_core.malu$chat_session(source_package_id)
    WHERE source_package_id IS NOT NULL;

ALTER TABLE maludb_core.malu$chat_session ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_owner ON maludb_core.malu$chat_session
    USING (owner_schema = current_schema())
    WITH CHECK (owner_schema = current_schema());

CREATE TABLE maludb_core.malu$chat_message (
    chat_message_id  bigserial PRIMARY KEY,
    owner_schema     name NOT NULL DEFAULT current_schema(),
    chat_session_id  bigint NOT NULL,
    ordinal          integer NOT NULL CHECK (ordinal > 0),
    role             text NOT NULL
        CHECK (role IN ('system','developer','user','assistant','tool','event')),
    content_text     text,
    content_jsonb    jsonb,
    content_hash     text NOT NULL,
    token_estimate   integer CHECK (token_estimate IS NULL OR token_estimate >= 0),
    model_request_id bigint REFERENCES maludb_core.malu$model_request(request_id) ON DELETE SET NULL,
    model_response_id bigint REFERENCES maludb_core.malu$model_response(response_id) ON DELETE SET NULL,
    tool_call_id     text,
    source_locator   jsonb,
    sensitivity      text NOT NULL DEFAULT 'internal'
        CHECK (sensitivity IN ('public','internal','restricted','prohibited')),
    created_at       timestamptz NOT NULL DEFAULT now(),
    metadata_jsonb   jsonb NOT NULL DEFAULT '{}'::jsonb,
    CHECK (content_text IS NOT NULL OR content_jsonb IS NOT NULL),
    UNIQUE (owner_schema, chat_session_id, ordinal),
    FOREIGN KEY (owner_schema, chat_session_id)
        REFERENCES maludb_core.malu$chat_session(owner_schema, chat_session_id) ON DELETE CASCADE
);

CREATE INDEX malu$chat_message_session_idx
    ON maludb_core.malu$chat_message(owner_schema, chat_session_id, ordinal);
CREATE INDEX malu$chat_message_role_idx
    ON maludb_core.malu$chat_message(owner_schema, role, created_at DESC);

ALTER TABLE maludb_core.malu$chat_message ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_owner ON maludb_core.malu$chat_message
    USING (owner_schema = current_schema())
    WITH CHECK (owner_schema = current_schema());

GRANT SELECT ON maludb_core.malu$chat_session, maludb_core.malu$chat_message TO
    maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;
GRANT INSERT, UPDATE, DELETE ON maludb_core.malu$chat_session, maludb_core.malu$chat_message TO
    maludb_memory_admin, maludb_memory_executor;
GRANT USAGE, SELECT ON SEQUENCE
    maludb_core.malu$chat_session_chat_session_id_seq,
    maludb_core.malu$chat_message_chat_message_id_seq
TO maludb_memory_admin, maludb_memory_executor;

CREATE FUNCTION maludb_core.chat_start(
    p_title text DEFAULT NULL,
    p_account_name text DEFAULT NULL,
    p_projects text[] DEFAULT ARRAY[]::text[],
    p_subjects text[] DEFAULT ARRAY[]::text[],
    p_verbs text[] DEFAULT ARRAY[]::text[],
    p_svpor_frames jsonb DEFAULT '[]'::jsonb,
    p_metadata_jsonb jsonb DEFAULT '{}'::jsonb
) RETURNS bigint
LANGUAGE plpgsql
SECURITY INVOKER
AS $body$
DECLARE
    v_account_id bigint;
    v_chat_session_id bigint;
    v_title text := COALESCE(NULLIF(btrim(p_title), ''), 'Untitled chat');
BEGIN
    IF p_account_name IS NOT NULL THEN
        SELECT account_id INTO v_account_id
          FROM maludb_core.malu$account
         WHERE account_name = p_account_name;
        IF v_account_id IS NULL THEN
            RAISE EXCEPTION 'chat_start: account % not found', p_account_name
                USING ERRCODE = 'foreign_key_violation';
        END IF;
    END IF;

    IF p_svpor_frames IS NOT NULL AND jsonb_typeof(p_svpor_frames) <> 'array' THEN
        RAISE EXCEPTION 'chat_start: svpor_frames must be a JSON array'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    INSERT INTO maludb_core.malu$chat_session(
        owner_schema, account_id, chat_title, projects, subjects, verbs,
        svpor_frames, metadata_jsonb
    )
    VALUES (
        current_schema()::name,
        v_account_id,
        v_title,
        COALESCE(p_projects, ARRAY[]::text[]),
        COALESCE(p_subjects, ARRAY[]::text[]),
        COALESCE(p_verbs, ARRAY[]::text[]),
        COALESCE(p_svpor_frames, '[]'::jsonb),
        COALESCE(p_metadata_jsonb, '{}'::jsonb)
    )
    RETURNING chat_session_id INTO v_chat_session_id;

    RETURN v_chat_session_id;
END;
$body$;

REVOKE ALL ON FUNCTION maludb_core.chat_start(text, text, text[], text[], text[], jsonb, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core.chat_start(text, text, text[], text[], text[], jsonb, jsonb)
TO maludb_memory_admin, maludb_memory_executor;

CREATE FUNCTION maludb_core.chat_append_message(
    p_chat_session_id bigint,
    p_role text,
    p_content_text text DEFAULT NULL,
    p_content_jsonb jsonb DEFAULT NULL,
    p_metadata_jsonb jsonb DEFAULT '{}'::jsonb
) RETURNS bigint
LANGUAGE plpgsql
SECURITY INVOKER
AS $body$
DECLARE
    v_session maludb_core.malu$chat_session%ROWTYPE;
    v_role text := lower(btrim(COALESCE(p_role, '')));
    v_ordinal integer;
    v_hash text;
    v_message_id bigint;
BEGIN
    IF p_content_text IS NULL AND p_content_jsonb IS NULL THEN
        RAISE EXCEPTION 'chat_append_message: content_text or content_jsonb is required'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;
    IF v_role NOT IN ('system','developer','user','assistant','tool','event') THEN
        RAISE EXCEPTION 'chat_append_message: invalid role %', p_role
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    SELECT * INTO v_session
      FROM maludb_core.malu$chat_session
     WHERE owner_schema = current_schema()
       AND chat_session_id = p_chat_session_id
     FOR UPDATE;
    IF v_session.chat_session_id IS NULL THEN
        RAISE EXCEPTION 'chat_append_message: chat_session % not found', p_chat_session_id
            USING ERRCODE = 'no_data_found';
    END IF;
    IF v_session.lifecycle_state <> 'open' THEN
        RAISE EXCEPTION 'chat_append_message: chat_session % is %, not open',
            p_chat_session_id, v_session.lifecycle_state
            USING ERRCODE = 'object_not_in_prerequisite_state';
    END IF;

    SELECT COALESCE(max(ordinal), 0) + 1 INTO v_ordinal
      FROM maludb_core.malu$chat_message
     WHERE owner_schema = current_schema()
       AND chat_session_id = p_chat_session_id;

    v_hash := encode(
        public.digest(
            convert_to(v_role || '|' || COALESCE(p_content_text, p_content_jsonb::text), 'UTF8'),
            'sha256'
        ),
        'hex'
    );

    INSERT INTO maludb_core.malu$chat_message(
        owner_schema, chat_session_id, ordinal, role, content_text,
        content_jsonb, content_hash, metadata_jsonb
    )
    VALUES (
        current_schema()::name, p_chat_session_id, v_ordinal, v_role,
        p_content_text, p_content_jsonb, v_hash, COALESCE(p_metadata_jsonb, '{}'::jsonb)
    )
    RETURNING chat_message_id INTO v_message_id;

    UPDATE maludb_core.malu$chat_session
       SET message_count = v_ordinal,
           last_message_at = now()
     WHERE owner_schema = current_schema()
       AND chat_session_id = p_chat_session_id;

    RETURN v_message_id;
END;
$body$;

REVOKE ALL ON FUNCTION maludb_core.chat_append_message(bigint, text, text, jsonb, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core.chat_append_message(bigint, text, text, jsonb, jsonb)
TO maludb_memory_admin, maludb_memory_executor;

CREATE FUNCTION maludb_core.chat_finalize(p_chat_session_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
AS $body$
DECLARE
    v_session maludb_core.malu$chat_session%ROWTYPE;
    v_content_jsonb jsonb;
    v_content_text text;
    v_hash text;
    v_size bigint;
    v_source_id bigint;
    v_document_id bigint;
    v_metadata jsonb;
BEGIN
    SELECT * INTO v_session
      FROM maludb_core.malu$chat_session
     WHERE owner_schema = current_schema()
       AND chat_session_id = p_chat_session_id
     FOR UPDATE;
    IF v_session.chat_session_id IS NULL THEN
        RAISE EXCEPTION 'chat_finalize: chat_session % not found', p_chat_session_id
            USING ERRCODE = 'no_data_found';
    END IF;
    IF v_session.lifecycle_state NOT IN ('open','closed') THEN
        RAISE EXCEPTION 'chat_finalize: chat_session % is %, cannot finalize',
            p_chat_session_id, v_session.lifecycle_state
            USING ERRCODE = 'object_not_in_prerequisite_state';
    END IF;

    SELECT jsonb_build_object(
        'chat_session', jsonb_build_object(
            'chat_session_id', v_session.chat_session_id,
            'title', v_session.chat_title,
            'started_at', v_session.started_at,
            'last_message_at', v_session.last_message_at,
            'message_count', v_session.message_count,
            'metadata_jsonb', v_session.metadata_jsonb
        ),
        'messages', COALESCE(jsonb_agg(
            jsonb_build_object(
                'ordinal', m.ordinal,
                'role', m.role,
                'content_text', m.content_text,
                'content_jsonb', m.content_jsonb,
                'created_at', m.created_at,
                'metadata_jsonb', m.metadata_jsonb
            )
            ORDER BY m.ordinal
        ), '[]'::jsonb)
    )
    INTO v_content_jsonb
    FROM maludb_core.malu$chat_message m
    WHERE m.owner_schema = current_schema()
      AND m.chat_session_id = p_chat_session_id;

    SELECT COALESCE(string_agg(
        format('[%s] %s', m.role, COALESCE(m.content_text, m.content_jsonb::text)),
        E'\n' ORDER BY m.ordinal
    ), '')
    INTO v_content_text
    FROM maludb_core.malu$chat_message m
    WHERE m.owner_schema = current_schema()
      AND m.chat_session_id = p_chat_session_id;

    v_hash := encode(public.digest(convert_to(v_content_jsonb::text, 'UTF8'), 'sha256'), 'hex');
    v_size := octet_length(convert_to(v_content_jsonb::text, 'UTF8'));
    v_metadata := COALESCE(v_session.metadata_jsonb, '{}'::jsonb) ||
        jsonb_build_object(
            'chat_session_id', v_session.chat_session_id,
            'message_count', v_session.message_count,
            'projection', 'llm-chat',
            'projection_version', 1,
            'started_at', v_session.started_at,
            'last_message_at', v_session.last_message_at
        );

    IF v_session.source_package_id IS NULL THEN
        INSERT INTO maludb_core.malu$source_package(
            owner_schema, source_type, content_text, content_jsonb, content_hash,
            content_size, media_type, origin_jsonb, captured_at
        )
        VALUES (
            current_schema()::name, 'llm-chat', v_content_text, v_content_jsonb,
            v_hash, v_size, 'application/vnd.maludb.chat+json',
            jsonb_build_object('producer', 'maludb_chat_finalize', 'chat_session_id', p_chat_session_id),
            now()
        )
        RETURNING source_package_id INTO v_source_id;
    ELSE
        v_source_id := v_session.source_package_id;
        UPDATE maludb_core.malu$source_package
           SET content_text = v_content_text,
               content_jsonb = v_content_jsonb,
               content_hash = v_hash,
               content_size = v_size,
               media_type = 'application/vnd.maludb.chat+json',
               origin_jsonb = jsonb_build_object('producer', 'maludb_chat_finalize', 'chat_session_id', p_chat_session_id),
               captured_at = now(),
               updated_at = now()
         WHERE owner_schema = current_schema()
           AND source_package_id = v_source_id;
    END IF;

    IF v_session.document_id IS NULL THEN
        INSERT INTO maludb_core.malu$document(
            owner_schema, source_package_id, title, source_type, media_type, metadata_jsonb
        )
        VALUES (
            current_schema()::name, v_source_id, v_session.chat_title,
            'llm-chat', 'application/vnd.maludb.chat+json', v_metadata
        )
        RETURNING document_id INTO v_document_id;
    ELSE
        v_document_id := v_session.document_id;
        UPDATE maludb_core.malu$document
           SET source_package_id = v_source_id,
               title = v_session.chat_title,
               source_type = 'llm-chat',
               media_type = 'application/vnd.maludb.chat+json',
               metadata_jsonb = v_metadata,
               updated_at = now()
         WHERE owner_schema = current_schema()
           AND document_id = v_document_id;
    END IF;

    DELETE FROM maludb_core.malu$document_tag
     WHERE owner_schema = current_schema()
       AND document_id = v_document_id
       AND tag_kind IN ('project','subject','verb');

    INSERT INTO maludb_core.malu$document_tag(owner_schema, document_id, tag_kind, tag_value, provenance)
    SELECT current_schema()::name, v_document_id, 'project', tag_value, 'provided'
      FROM (SELECT DISTINCT btrim(x) AS tag_value FROM unnest(v_session.projects) AS x) AS tags
     WHERE tag_value <> '';

    INSERT INTO maludb_core.malu$document_tag(owner_schema, document_id, tag_kind, tag_value, provenance)
    SELECT current_schema()::name, v_document_id, 'subject', tag_value, 'provided'
      FROM (SELECT DISTINCT btrim(x) AS tag_value FROM unnest(v_session.subjects) AS x) AS tags
     WHERE tag_value <> '';

    INSERT INTO maludb_core.malu$document_tag(owner_schema, document_id, tag_kind, tag_value, provenance)
    SELECT current_schema()::name, v_document_id, 'verb', tag_value, 'provided'
      FROM (SELECT DISTINCT btrim(x) AS tag_value FROM unnest(v_session.verbs) AS x) AS tags
     WHERE tag_value <> '';

    DELETE FROM maludb_core.malu$document_svpor_hint
     WHERE owner_schema = current_schema()
       AND document_id = v_document_id;
    PERFORM maludb_core._insert_document_svpor_hints_for_schema(
        current_schema()::name, v_document_id, v_session.svpor_frames
    );

    UPDATE maludb_core.malu$chat_session
       SET source_package_id = v_source_id,
           document_id = v_document_id,
           lifecycle_state = 'closed',
           closed_at = COALESCE(closed_at, now())
     WHERE owner_schema = current_schema()
       AND chat_session_id = p_chat_session_id;

    RETURN jsonb_build_object(
        'chat_session_id', p_chat_session_id,
        'source_package_id', v_source_id,
        'document_id', v_document_id,
        'source_type', 'llm-chat',
        'message_count', v_session.message_count
    );
END;
$body$;

REVOKE ALL ON FUNCTION maludb_core.chat_finalize(bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core.chat_finalize(bigint)
TO maludb_memory_admin, maludb_memory_executor;

CREATE FUNCTION maludb_core.chat_get(p_chat_session_id bigint)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY INVOKER
AS $body$
    SELECT jsonb_build_object(
        'chat_session', to_jsonb(s),
        'document', CASE WHEN s.document_id IS NULL THEN NULL ELSE maludb_core.document_get(s.document_id) END,
        'message_count', s.message_count
    )
    FROM maludb_core.malu$chat_session s
    WHERE s.owner_schema = current_schema()
      AND s.chat_session_id = p_chat_session_id
$body$;

REVOKE ALL ON FUNCTION maludb_core.chat_get(bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core.chat_get(bigint)
TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;

CREATE FUNCTION maludb_core.chat_messages(p_chat_session_id bigint)
RETURNS TABLE (
    chat_message_id bigint,
    ordinal integer,
    role text,
    content_text text,
    content_jsonb jsonb,
    content_hash text,
    token_estimate integer,
    model_request_id bigint,
    model_response_id bigint,
    tool_call_id text,
    source_locator jsonb,
    sensitivity text,
    created_at timestamptz,
    metadata_jsonb jsonb
)
LANGUAGE sql
STABLE
SECURITY INVOKER
AS $body$
    SELECT chat_message_id, ordinal, role, content_text, content_jsonb,
           content_hash, token_estimate, model_request_id, model_response_id,
           tool_call_id, source_locator, sensitivity, created_at, metadata_jsonb
      FROM maludb_core.malu$chat_message
     WHERE owner_schema = current_schema()
       AND chat_session_id = p_chat_session_id
     ORDER BY ordinal
$body$;

REVOKE ALL ON FUNCTION maludb_core.chat_messages(bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core.chat_messages(bigint)
TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;

CREATE TABLE maludb_core.malu$svpor_subject_type (
    subject_type   text PRIMARY KEY,
    display_name   text NOT NULL,
    description    text,
    sort_order     integer NOT NULL,
    system_defined boolean NOT NULL DEFAULT true,
    created_at     timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE maludb_core.malu$svpor_verb_type (
    verb_type      text PRIMARY KEY,
    display_name   text NOT NULL,
    semantic_class text NOT NULL DEFAULT 'action'
        CHECK (semantic_class IN ('action','state','event','decision','communication','verification','failure','planning','documentation','other')),
    description    text,
    sort_order     integer NOT NULL,
    system_defined boolean NOT NULL DEFAULT true,
    created_at     timestamptz NOT NULL DEFAULT now()
);

INSERT INTO maludb_core.malu$svpor_subject_type(subject_type, display_name, description, sort_order) VALUES
    ('project',     'Project',     'Project, program, initiative, or engagement.', 10),
    ('person',      'Person',      'Human actor, stakeholder, customer, operator, or participant.', 20),
    ('ai_agent',    'AI Agent',    'Autonomous or assisted AI agent identity.', 30),
    ('equipment',   'Equipment',   'Physical device, machine, server, appliance, or tool.', 40),
    ('software',    'Software',    'Application, service, package, library, or software component.', 50),
    ('network',     'Network',     'Network, subnet, route, connection, or communications domain.', 60),
    ('event',       'Event',       'Incident, meeting, deployment, outage, milestone, or occurrence.', 70),
    ('process',     'Process',     'Business, operational, or technical process.', 80),
    ('workflow',    'Workflow',    'Repeatable ordered activity or procedure.', 90),
    ('time_period', 'Time Period', 'Date, range, quarter, sprint, release window, or named period.', 100),
    ('other',       'Other',       'Fallback subject type when no more specific type applies.', 900),
    ('stakeholder', 'Stakeholder', 'Legacy compatibility type for existing stakeholder facades.', 910),
    ('concept',     'Concept',     'Legacy compatibility type for pre-typed SVPOR subjects.', 920)
ON CONFLICT (subject_type) DO UPDATE
    SET display_name = EXCLUDED.display_name,
        description = EXCLUDED.description,
        sort_order = EXCLUDED.sort_order,
        system_defined = true;

INSERT INTO maludb_core.malu$svpor_verb_type(verb_type, display_name, semantic_class, description, sort_order) VALUES
    ('installed',    'Installed',    'action',        'Installed equipment, software, services, or configuration.', 10),
    ('configured',   'Configured',   'action',        'Configured settings, infrastructure, accounts, or policies.', 20),
    ('attended',     'Attended',     'event',         'Attended a meeting, event, review, or session.', 30),
    ('created',      'Created',      'action',        'Created an object, record, artifact, account, or environment.', 40),
    ('updated',      'Updated',      'action',        'Updated an existing object, record, artifact, or configuration.', 50),
    ('removed',      'Removed',      'action',        'Removed, deleted, retired, or decommissioned something.', 60),
    ('migrated',     'Migrated',     'action',        'Moved data, services, systems, or users between states or platforms.', 70),
    ('deployed',     'Deployed',     'action',        'Deployed a release, service, configuration, or artifact.', 80),
    ('tested',       'Tested',       'verification',  'Tested behavior, performance, integration, or acceptance.', 90),
    ('verified',     'Verified',     'verification',  'Verified a result, state, fact, or requirement.', 100),
    ('approved',     'Approved',     'decision',      'Approved a request, decision, change, or artifact.', 110),
    ('rejected',     'Rejected',     'decision',      'Rejected a request, decision, change, or artifact.', 120),
    ('decided',      'Decided',      'decision',      'Recorded a decision or selected an option.', 130),
    ('discovered',   'Discovered',   'event',         'Discovered a fact, condition, issue, or opportunity.', 140),
    ('observed',     'Observed',     'event',         'Observed a state, behavior, symptom, metric, or outcome.', 150),
    ('reported',     'Reported',     'communication', 'Reported status, findings, incidents, or results.', 160),
    ('requested',    'Requested',    'communication', 'Requested work, approval, information, or action.', 170),
    ('assigned',     'Assigned',     'planning',      'Assigned ownership, work, responsibility, or routing.', 180),
    ('scheduled',    'Scheduled',    'planning',      'Scheduled an event, job, meeting, release, or activity.', 190),
    ('completed',    'Completed',    'state',         'Completed work, a process, a workflow, or an event.', 200),
    ('failed',       'Failed',       'failure',       'Failed a check, operation, deployment, process, or expectation.', 210),
    ('blocked',      'Blocked',      'state',         'Blocked progress, access, workflow, or execution.', 220),
    ('resolved',     'Resolved',     'state',         'Resolved an incident, task, ticket, defect, or issue.', 230),
    ('documented',   'Documented',   'documentation', 'Documented knowledge, procedure, decision, or evidence.', 240),
    ('learned',      'Learned',      'documentation', 'Captured a lesson, insight, or retained know-how.', 250),
    ('connected',    'Connected',    'action',        'Connected systems, people, services, networks, or records.', 260),
    ('disconnected', 'Disconnected', 'action',        'Disconnected systems, people, services, networks, or records.', 270),
    ('started',      'Started',      'event',         'Started a service, task, event, workflow, or period.', 280),
    ('stopped',      'Stopped',      'event',         'Stopped a service, task, event, workflow, or period.', 290),
    ('other',        'Other',        'other',         'Fallback verb type when no more specific verb applies.', 900)
ON CONFLICT (verb_type) DO UPDATE
    SET display_name = EXCLUDED.display_name,
        semantic_class = EXCLUDED.semantic_class,
        description = EXCLUDED.description,
        sort_order = EXCLUDED.sort_order,
        system_defined = true;

GRANT SELECT ON maludb_core.malu$svpor_subject_type, maludb_core.malu$svpor_verb_type TO
    maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;
GRANT INSERT, UPDATE, DELETE ON maludb_core.malu$svpor_subject_type, maludb_core.malu$svpor_verb_type TO
    maludb_memory_admin;

CREATE FUNCTION maludb_core._svpor_slug(p_value text) RETURNS text
LANGUAGE sql IMMUTABLE
AS $body$
    SELECT NULLIF(
        regexp_replace(
            regexp_replace(lower(btrim(COALESCE(p_value, ''))), '[^a-z0-9]+', '_', 'g'),
            '^_+|_+$', '', 'g'
        ),
        ''
    )
$body$;

CREATE FUNCTION maludb_core._normalize_svpor_subject_type(p_value text) RETURNS text
LANGUAGE plpgsql STABLE
AS $body$
DECLARE
    v_slug text := COALESCE(maludb_core._svpor_slug(p_value), 'other');
    v_type text;
BEGIN
    SELECT subject_type INTO v_type
      FROM maludb_core.malu$svpor_subject_type
     WHERE subject_type = v_slug
        OR lower(display_name) = lower(btrim(COALESCE(p_value, '')))
     ORDER BY CASE WHEN subject_type = v_slug THEN 0 ELSE 1 END
     LIMIT 1;

    IF v_type IS NULL THEN
        RAISE EXCEPTION 'unknown subject_type %. Register it in malu$svpor_subject_type first', p_value
            USING ERRCODE = 'invalid_parameter_value';
    END IF;
    RETURN v_type;
END;
$body$;

CREATE FUNCTION maludb_core._normalize_svpor_verb_type(p_value text, p_fallback_text text DEFAULT NULL) RETURNS text
LANGUAGE plpgsql STABLE
AS $body$
DECLARE
    v_input text := COALESCE(NULLIF(p_value, ''), p_fallback_text, 'other');
    v_slug text := COALESCE(maludb_core._svpor_slug(v_input), 'other');
    v_type text;
BEGIN
    SELECT verb_type INTO v_type
      FROM maludb_core.malu$svpor_verb_type
     WHERE verb_type = v_slug
        OR lower(display_name) = lower(btrim(COALESCE(v_input, '')))
     ORDER BY CASE WHEN verb_type = v_slug THEN 0 ELSE 1 END
     LIMIT 1;

    IF v_type IS NULL AND p_value IS NULL THEN
        RETURN 'other';
    END IF;
    IF v_type IS NULL THEN
        RAISE EXCEPTION 'unknown verb_type %. Register it in malu$svpor_verb_type first', p_value
            USING ERRCODE = 'invalid_parameter_value';
    END IF;
    RETURN v_type;
END;
$body$;

ALTER TABLE maludb_core.malu$svpor_subject
    ALTER COLUMN subject_type SET DEFAULT 'other';

UPDATE maludb_core.malu$svpor_subject
   SET subject_type = maludb_core._normalize_svpor_subject_type(subject_type);

ALTER TABLE maludb_core.malu$svpor_subject
    ADD CONSTRAINT malu$svpor_subject_subject_type_fk
    FOREIGN KEY (subject_type)
    REFERENCES maludb_core.malu$svpor_subject_type(subject_type);

ALTER TABLE maludb_core.malu$svpor_verb
    ADD COLUMN verb_type text NOT NULL DEFAULT 'other',
    ADD COLUMN search_phrases text[] NOT NULL DEFAULT ARRAY[]::text[];

ALTER TABLE maludb_core.malu$svpor_verb
    ADD CONSTRAINT malu$svpor_verb_verb_type_fk
    FOREIGN KEY (verb_type)
    REFERENCES maludb_core.malu$svpor_verb_type(verb_type);

CREATE INDEX malu$svpor_verb_type_idx
    ON maludb_core.malu$svpor_verb(owner_schema, verb_type, canonical_name);
CREATE INDEX malu$svpor_verb_search_phrases_gin
    ON maludb_core.malu$svpor_verb USING gin (search_phrases);

CREATE OR REPLACE FUNCTION maludb_core.register_svpor_subject(
    p_canonical_name text,
    p_aliases        text[] DEFAULT ARRAY[]::text[],
    p_description    text   DEFAULT NULL,
    p_subject_type   text   DEFAULT 'other'
) RETURNS bigint
LANGUAGE plpgsql
AS $body$
DECLARE
    v_id bigint;
    v_subject_type text := maludb_core._normalize_svpor_subject_type(p_subject_type);
BEGIN
    INSERT INTO maludb_core.malu$svpor_subject (canonical_name, aliases, description, subject_type)
    VALUES (p_canonical_name, COALESCE(p_aliases, ARRAY[]::text[]), p_description, v_subject_type)
    ON CONFLICT (owner_schema, canonical_name) DO UPDATE
        SET aliases = (
                SELECT array_agg(DISTINCT a)
                FROM unnest(malu$svpor_subject.aliases || COALESCE(EXCLUDED.aliases, ARRAY[]::text[])) AS a
            ),
            description = COALESCE(EXCLUDED.description, malu$svpor_subject.description),
            subject_type = EXCLUDED.subject_type
    RETURNING subject_id INTO v_id;
    RETURN v_id;
END;
$body$;

ALTER EXTENSION maludb_core DROP FUNCTION register_svpor_verb(text, text[], text);
DROP FUNCTION register_svpor_verb(text, text[], text);

CREATE FUNCTION maludb_core.register_svpor_verb(
    p_canonical_name text,
    p_aliases text[] DEFAULT ARRAY[]::text[],
    p_description text DEFAULT NULL,
    p_verb_type text DEFAULT NULL,
    p_search_phrases text[] DEFAULT ARRAY[]::text[]
) RETURNS bigint
LANGUAGE plpgsql
AS $body$
DECLARE
    v_id bigint;
    v_verb_type text := maludb_core._normalize_svpor_verb_type(p_verb_type, p_canonical_name);
BEGIN
    INSERT INTO maludb_core.malu$svpor_verb (canonical_name, aliases, description, verb_type, search_phrases)
    VALUES (
        p_canonical_name,
        COALESCE(p_aliases, ARRAY[]::text[]),
        p_description,
        v_verb_type,
        COALESCE(p_search_phrases, ARRAY[]::text[])
    )
    ON CONFLICT (owner_schema, canonical_name) DO UPDATE
        SET aliases = (
                SELECT array_agg(DISTINCT a)
                FROM unnest(malu$svpor_verb.aliases || COALESCE(EXCLUDED.aliases, ARRAY[]::text[])) AS a
            ),
            search_phrases = (
                SELECT array_agg(DISTINCT p)
                FROM unnest(malu$svpor_verb.search_phrases || COALESCE(EXCLUDED.search_phrases, ARRAY[]::text[])) AS p
            ),
            description = COALESCE(EXCLUDED.description, malu$svpor_verb.description),
            verb_type = EXCLUDED.verb_type
    RETURNING verb_id INTO v_id;
    RETURN v_id;
END;
$body$;

REVOKE ALL ON FUNCTION maludb_core.register_svpor_verb(text, text[], text, text, text[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core.register_svpor_verb(text, text[], text, text, text[]) TO
    maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;

CREATE FUNCTION maludb_core._svpor_subject_normalize_type_tg() RETURNS trigger
LANGUAGE plpgsql
AS $body$
BEGIN
    NEW.subject_type := maludb_core._normalize_svpor_subject_type(NEW.subject_type);
    RETURN NEW;
END;
$body$;

CREATE TRIGGER svpor_subject_normalize_type_tg
    BEFORE INSERT OR UPDATE OF subject_type ON maludb_core.malu$svpor_subject
    FOR EACH ROW EXECUTE FUNCTION maludb_core._svpor_subject_normalize_type_tg();

CREATE FUNCTION maludb_core._svpor_verb_normalize_type_tg() RETURNS trigger
LANGUAGE plpgsql
AS $body$
BEGIN
    NEW.verb_type := maludb_core._normalize_svpor_verb_type(NEW.verb_type, NEW.canonical_name);
    RETURN NEW;
END;
$body$;

CREATE TRIGGER svpor_verb_normalize_type_tg
    BEFORE INSERT OR UPDATE OF verb_type, canonical_name ON maludb_core.malu$svpor_verb
    FOR EACH ROW EXECUTE FUNCTION maludb_core._svpor_verb_normalize_type_tg();

INSERT INTO maludb_core.malu$relationship_type(relationship_type, stage, description) VALUES
    ('has_member',   3, 'Subject A has subject B as a member or participant.'),
    ('has_asset',    3, 'Subject A has subject B as an owned, managed, or relevant asset.'),
    ('uses',         3, 'Subject A uses subject B.'),
    ('assigned_to',  3, 'Subject A is assigned to subject B.'),
    ('applies_to',   3, 'Verb A applies to subject B.'),
    ('performed_by', 3, 'Verb A is performed by subject B.')
ON CONFLICT (relationship_type) DO UPDATE
    SET stage = EXCLUDED.stage,
        description = EXCLUDED.description;

ALTER TABLE maludb_core.malu$relationship_edge
    DROP CONSTRAINT malu$relationship_edge_source_object_type_check;
ALTER TABLE maludb_core.malu$relationship_edge
    ADD CONSTRAINT malu$relationship_edge_source_object_type_check
    CHECK (source_object_type IN (
        'source_package','claim','fact','memory','episode_object',
        'memory_detail_object','page_index_tree','chat_index_tree',
        'subject','verb'
    ));

ALTER TABLE maludb_core.malu$relationship_edge
    DROP CONSTRAINT malu$relationship_edge_target_object_type_check;
ALTER TABLE maludb_core.malu$relationship_edge
    ADD CONSTRAINT malu$relationship_edge_target_object_type_check
    CHECK (target_object_type IN (
        'source_package','claim','fact','memory','episode_object',
        'memory_detail_object','page_index_tree','chat_index_tree',
        'subject','verb'
    ));

CREATE FUNCTION maludb_core.register_svpor_relationship(
    p_source_kind text,
    p_source_id bigint,
    p_target_kind text,
    p_target_id bigint,
    p_relationship_type text,
    p_label text DEFAULT NULL,
    p_edge_jsonb jsonb DEFAULT NULL,
    p_confidence numeric DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql
SECURITY INVOKER
AS $body$
DECLARE
    v_source_kind text := lower(btrim(COALESCE(p_source_kind, '')));
    v_target_kind text := lower(btrim(COALESCE(p_target_kind, '')));
BEGIN
    IF v_source_kind NOT IN ('subject','verb') OR v_target_kind NOT IN ('subject','verb') THEN
        RAISE EXCEPTION 'SVPOR relationships support only subject and verb endpoints'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    RETURN maludb_core.register_relationship_edge(
        v_source_kind,
        p_source_id,
        v_target_kind,
        p_target_id,
        p_relationship_type,
        p_label,
        COALESCE(p_edge_jsonb, '{}'::jsonb),
        p_confidence
    );
END;
$body$;

REVOKE ALL ON FUNCTION maludb_core.register_svpor_relationship(text, bigint, text, bigint, text, text, jsonb, numeric) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core.register_svpor_relationship(text, bigint, text, bigint, text, text, jsonb, numeric)
TO maludb_memory_admin, maludb_memory_executor;

CREATE FUNCTION maludb_core.verb_phrase_search(p_query text)
RETURNS TABLE (
    verb_id bigint,
    canonical_name text,
    verb_type text,
    match_kind text,
    matched_text text
) LANGUAGE sql STABLE
AS $body$
    WITH q AS (
        SELECT lower(btrim(COALESCE(p_query, ''))) AS text
    ),
    matches AS (
        SELECT v.verb_id, v.canonical_name, v.verb_type, 'canonical'::text AS match_kind, v.canonical_name AS matched_text, 1 AS priority
          FROM maludb_core.malu$svpor_verb v, q
         WHERE lower(v.canonical_name) = q.text
        UNION ALL
        SELECT v.verb_id, v.canonical_name, v.verb_type, 'alias'::text, a.alias, 2
          FROM maludb_core.malu$svpor_verb v
          CROSS JOIN LATERAL unnest(v.aliases) AS a(alias), q
         WHERE lower(a.alias) = q.text
        UNION ALL
        SELECT v.verb_id, v.canonical_name, v.verb_type, 'search_phrase'::text, p.phrase, 3
          FROM maludb_core.malu$svpor_verb v
          CROSS JOIN LATERAL unnest(v.search_phrases) AS p(phrase), q
         WHERE lower(p.phrase) = q.text
    )
    SELECT verb_id, canonical_name, verb_type, match_kind, matched_text
      FROM matches
     ORDER BY priority, canonical_name, matched_text
$body$;

REVOKE ALL ON FUNCTION maludb_core.verb_phrase_search(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core.verb_phrase_search(text)
TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;

CREATE FUNCTION maludb_core._enable_memory_schema_075_facade(p_schema name) RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
DECLARE
    v_count integer := 0;
BEGIN
    PERFORM maludb_core._memory_schema_assert_manageable(p_schema);

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_subject_type', 'view');
    EXECUTE format($sql$
        CREATE OR REPLACE VIEW %I.maludb_subject_type AS
        SELECT subject_type, display_name, description, sort_order, system_defined, created_at
          FROM maludb_core.malu$svpor_subject_type
    $sql$, p_schema);
    EXECUTE format('GRANT SELECT ON %I.maludb_subject_type TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_subject_type', 'view', 'Schema-local SVPOR subject type catalog facade.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_verb_type', 'view');
    EXECUTE format($sql$
        CREATE OR REPLACE VIEW %I.maludb_verb_type AS
        SELECT verb_type, display_name, semantic_class, description, sort_order, system_defined, created_at
          FROM maludb_core.malu$svpor_verb_type
    $sql$, p_schema);
    EXECUTE format('GRANT SELECT ON %I.maludb_verb_type TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_verb_type', 'view', 'Schema-local SVPOR verb type catalog facade.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_verb', 'view');
    EXECUTE format($sql$
        CREATE OR REPLACE VIEW %I.maludb_verb AS
        SELECT verb_id,
               canonical_name,
               aliases,
               description,
               created_at,
               verb_type,
               search_phrases
          FROM maludb_core.malu$svpor_verb
         WHERE owner_schema = %L
        WITH LOCAL CHECK OPTION
    $sql$, p_schema, p_schema);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON %I.maludb_verb TO maludb_memory_admin, maludb_memory_executor', p_schema);
    EXECUTE format('GRANT SELECT ON %I.maludb_verb TO maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_verb', 'view', 'Schema-local type-aware SVPOR verb facade.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_document_svpor_hint', 'view');
    EXECUTE format($sql$
        CREATE OR REPLACE VIEW %I.maludb_document_svpor_hint WITH (security_invoker = true) AS
        SELECT hint_id,
               document_id,
               project_subject_id,
               project_name,
               subject_id,
               subject_name,
               verb_id,
               verb_name,
               provenance,
               confidence,
               metadata_jsonb,
               created_at
          FROM maludb_core.malu$document_svpor_hint
         WHERE owner_schema = %L
        WITH LOCAL CHECK OPTION
    $sql$, p_schema, p_schema);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON %I.maludb_document_svpor_hint TO maludb_memory_admin, maludb_memory_executor', p_schema);
    EXECUTE format('GRANT SELECT ON %I.maludb_document_svpor_hint TO maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_document_svpor_hint', 'view', 'Schema-local document SVPOR hint facade.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_quick_add_note', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_quick_add_note(
            p_title text,
            p_body_text text,
            p_projects text[] DEFAULT ARRAY[]::text[],
            p_subjects text[] DEFAULT ARRAY[]::text[],
            p_verbs text[] DEFAULT ARRAY[]::text[],
            p_svpor_frames jsonb DEFAULT '[]'::jsonb,
            p_metadata_jsonb jsonb DEFAULT '{}'::jsonb
        ) RETURNS bigint
        LANGUAGE sql
        SECURITY INVOKER
        SET search_path = %I, maludb_core, pg_temp
        AS $facade$
            SELECT maludb_core.quick_add_note(
                p_title, p_body_text, p_projects, p_subjects, p_verbs,
                p_svpor_frames, p_metadata_jsonb
            )
        $facade$
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_quick_add_note(text, text, text[], text[], text[], jsonb, jsonb) FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_quick_add_note(text, text, text[], text[], text[], jsonb, jsonb) TO maludb_memory_admin, maludb_memory_executor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_quick_add_note', 'function', 'Schema-local quick note upload facade.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_document_get', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_document_get(p_document_id bigint)
        RETURNS jsonb
        LANGUAGE sql
        STABLE
        SECURITY INVOKER
        SET search_path = %I, maludb_core, pg_temp
        AS $facade$
            SELECT maludb_core.document_get(p_document_id)
        $facade$
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_document_get(bigint) FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_document_get(bigint) TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_document_get', 'function', 'Schema-local document payload reader.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_svpor_relationship', 'view');
    EXECUTE format($sql$
        CREATE OR REPLACE VIEW %I.maludb_svpor_relationship AS
        SELECT e.edge_id,
               e.source_object_type AS source_kind,
               e.source_object_id AS source_id,
               COALESCE(src_s.canonical_name, src_v.canonical_name) AS source_name,
               e.relationship_type,
               e.target_object_type AS target_kind,
               e.target_object_id AS target_id,
               COALESCE(tgt_s.canonical_name, tgt_v.canonical_name) AS target_name,
               e.label,
               e.edge_jsonb,
               e.confidence,
               e.created_at
          FROM maludb_core.malu$relationship_edge e
          LEFT JOIN maludb_core.malu$svpor_subject src_s
            ON e.source_object_type = 'subject'
           AND src_s.owner_schema = e.owner_schema
           AND src_s.subject_id = e.source_object_id
          LEFT JOIN maludb_core.malu$svpor_verb src_v
            ON e.source_object_type = 'verb'
           AND src_v.owner_schema = e.owner_schema
           AND src_v.verb_id = e.source_object_id
          LEFT JOIN maludb_core.malu$svpor_subject tgt_s
            ON e.target_object_type = 'subject'
           AND tgt_s.owner_schema = e.owner_schema
           AND tgt_s.subject_id = e.target_object_id
          LEFT JOIN maludb_core.malu$svpor_verb tgt_v
            ON e.target_object_type = 'verb'
           AND tgt_v.owner_schema = e.owner_schema
           AND tgt_v.verb_id = e.target_object_id
         WHERE e.owner_schema = %L
           AND e.source_object_type IN ('subject','verb')
           AND e.target_object_type IN ('subject','verb')
    $sql$, p_schema, p_schema);
    EXECUTE format('GRANT SELECT ON %I.maludb_svpor_relationship TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_svpor_relationship', 'view', 'Schema-local SVPOR subject/verb relationship facade.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_svpor_relationship_create', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_svpor_relationship_create(
            p_source_kind text,
            p_source_id bigint,
            p_target_kind text,
            p_target_id bigint,
            p_relationship_type text,
            p_label text DEFAULT NULL,
            p_edge_jsonb jsonb DEFAULT '{}'::jsonb,
            p_confidence numeric DEFAULT NULL
        ) RETURNS bigint
        LANGUAGE sql
        SECURITY INVOKER
        SET search_path = %I, maludb_core, pg_temp
        AS $facade$
            SELECT maludb_core.register_svpor_relationship(
                p_source_kind, p_source_id, p_target_kind, p_target_id,
                p_relationship_type, p_label, p_edge_jsonb, p_confidence
            )
        $facade$
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_svpor_relationship_create(text, bigint, text, bigint, text, text, jsonb, numeric) FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_svpor_relationship_create(text, bigint, text, bigint, text, text, jsonb, numeric) TO maludb_memory_admin, maludb_memory_executor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_svpor_relationship_create', 'function', 'Schema-local SVPOR relationship writer.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_verb_phrase_search', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_verb_phrase_search(p_query text)
        RETURNS TABLE (
            verb_id bigint,
            canonical_name text,
            verb_type text,
            match_kind text,
            matched_text text
        )
        LANGUAGE sql
        STABLE
        SECURITY INVOKER
        SET search_path = %I, maludb_core, pg_temp
        AS $facade$
            SELECT *
            FROM maludb_core.verb_phrase_search(p_query)
        $facade$
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_verb_phrase_search(text) FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_verb_phrase_search(text) TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_verb_phrase_search', 'function', 'Schema-local verb phrase resolver.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_chat_session', 'view');
    EXECUTE format($sql$
        CREATE OR REPLACE VIEW %I.maludb_chat_session WITH (security_invoker = true) AS
        SELECT chat_session_id,
               account_id,
               model_session_id,
               document_id,
               source_package_id,
               chat_title,
               lifecycle_state,
               primary_project_subject_id,
               projects,
               subjects,
               verbs,
               svpor_frames,
               started_at,
               last_message_at,
               closed_at,
               message_count,
               metadata_jsonb
          FROM maludb_core.malu$chat_session
         WHERE owner_schema = %L
        WITH LOCAL CHECK OPTION
    $sql$, p_schema, p_schema);
    EXECUTE format('GRANT SELECT ON %I.maludb_chat_session TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_chat_session', 'view', 'Schema-local LLM chat session facade.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_chat_message', 'view');
    EXECUTE format($sql$
        CREATE OR REPLACE VIEW %I.maludb_chat_message WITH (security_invoker = true) AS
        SELECT chat_message_id,
               chat_session_id,
               ordinal,
               role,
               content_text,
               content_jsonb,
               content_hash,
               token_estimate,
               model_request_id,
               model_response_id,
               tool_call_id,
               source_locator,
               sensitivity,
               created_at,
               metadata_jsonb
          FROM maludb_core.malu$chat_message
         WHERE owner_schema = %L
        WITH LOCAL CHECK OPTION
    $sql$, p_schema, p_schema);
    EXECUTE format('GRANT SELECT ON %I.maludb_chat_message TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_chat_message', 'view', 'Schema-local LLM chat message facade.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_chat_start', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_chat_start(
            p_title text DEFAULT NULL,
            p_account_name text DEFAULT NULL,
            p_projects text[] DEFAULT ARRAY[]::text[],
            p_subjects text[] DEFAULT ARRAY[]::text[],
            p_verbs text[] DEFAULT ARRAY[]::text[],
            p_svpor_frames jsonb DEFAULT '[]'::jsonb,
            p_metadata_jsonb jsonb DEFAULT '{}'::jsonb
        ) RETURNS bigint
        LANGUAGE sql
        SECURITY INVOKER
        SET search_path = %I, maludb_core, pg_temp
        AS $facade$
            SELECT maludb_core.chat_start(
                p_title, p_account_name, p_projects, p_subjects, p_verbs,
                p_svpor_frames, p_metadata_jsonb
            )
        $facade$
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_chat_start(text, text, text[], text[], text[], jsonb, jsonb) FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_chat_start(text, text, text[], text[], text[], jsonb, jsonb) TO maludb_memory_admin, maludb_memory_executor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_chat_start', 'function', 'Schema-local LLM chat session creator.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_chat_append_message', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_chat_append_message(
            p_chat_session_id bigint,
            p_role text,
            p_content_text text DEFAULT NULL,
            p_content_jsonb jsonb DEFAULT NULL,
            p_metadata_jsonb jsonb DEFAULT '{}'::jsonb
        ) RETURNS bigint
        LANGUAGE sql
        SECURITY INVOKER
        SET search_path = %I, maludb_core, pg_temp
        AS $facade$
            SELECT maludb_core.chat_append_message(
                p_chat_session_id, p_role, p_content_text, p_content_jsonb, p_metadata_jsonb
            )
        $facade$
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_chat_append_message(bigint, text, text, jsonb, jsonb) FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_chat_append_message(bigint, text, text, jsonb, jsonb) TO maludb_memory_admin, maludb_memory_executor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_chat_append_message', 'function', 'Schema-local LLM chat message append API.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_chat_finalize', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_chat_finalize(p_chat_session_id bigint)
        RETURNS jsonb
        LANGUAGE sql
        SECURITY INVOKER
        SET search_path = %I, maludb_core, pg_temp
        AS $facade$
            SELECT maludb_core.chat_finalize(p_chat_session_id)
        $facade$
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_chat_finalize(bigint) FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_chat_finalize(bigint) TO maludb_memory_admin, maludb_memory_executor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_chat_finalize', 'function', 'Schema-local LLM chat document projection finalizer.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_chat_get', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_chat_get(p_chat_session_id bigint)
        RETURNS jsonb
        LANGUAGE sql
        STABLE
        SECURITY INVOKER
        SET search_path = %I, maludb_core, pg_temp
        AS $facade$
            SELECT maludb_core.chat_get(p_chat_session_id)
        $facade$
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_chat_get(bigint) FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_chat_get(bigint) TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_chat_get', 'function', 'Schema-local LLM chat reader.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_chat_messages', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_chat_messages(p_chat_session_id bigint)
        RETURNS TABLE (
            chat_message_id bigint,
            ordinal integer,
            role text,
            content_text text,
            content_jsonb jsonb,
            content_hash text,
            token_estimate integer,
            model_request_id bigint,
            model_response_id bigint,
            tool_call_id text,
            source_locator jsonb,
            sensitivity text,
            created_at timestamptz,
            metadata_jsonb jsonb
        )
        LANGUAGE sql
        STABLE
        SECURITY INVOKER
        SET search_path = %I, maludb_core, pg_temp
        AS $facade$
            SELECT *
            FROM maludb_core.chat_messages(p_chat_session_id)
        $facade$
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_chat_messages(bigint) FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_chat_messages(bigint) TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_chat_messages', 'function', 'Schema-local ordered LLM chat message reader.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_person', 'view');
    EXECUTE format($sql$
        CREATE OR REPLACE VIEW %I.maludb_person AS
        SELECT subject_id,
               subject_type,
               canonical_name,
               aliases,
               description,
               created_at
          FROM %I.maludb_subject
         WHERE subject_type = 'person'
        WITH LOCAL CHECK OPTION
    $sql$, p_schema, p_schema);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON %I.maludb_person TO maludb_memory_admin, maludb_memory_executor', p_schema);
    EXECUTE format('GRANT SELECT ON %I.maludb_person TO maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_person', 'view', 'Schema-local person subject convenience facade.');
    v_count := v_count + 1;

    RETURN v_count;
END;
$body$;

REVOKE ALL ON FUNCTION maludb_core._enable_memory_schema_075_facade(name) FROM PUBLIC;

CREATE OR REPLACE FUNCTION maludb_core.enable_memory_schema(p_schema name DEFAULT current_schema())
RETURNS TABLE(schema_name name, enabled_version text, object_count integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
DECLARE
    v_count integer := 0;
    v_enabled_version text := maludb_core.maludb_core_version();
BEGIN
    PERFORM maludb_core._memory_schema_assert_manageable(p_schema);

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

CREATE OR REPLACE FUNCTION maludb_core._v3_api_arg(
    p_name text,
    p_type text,
    p_required boolean DEFAULT true,
    p_in text DEFAULT 'body',
    p_default jsonb DEFAULT 'null'::jsonb
) RETURNS jsonb
LANGUAGE SQL IMMUTABLE PARALLEL SAFE
AS $body$
    SELECT jsonb_build_object(
        'name', p_name,
        'type', p_type,
        'in', p_in,
        'required', p_required,
        'default', p_default
    )
$body$;

SELECT rest_register_endpoint(
    'POST', '/v3/note',
    'quick_add_note(text,text,text[],text[],text[],jsonb,jsonb)'::regprocedure,
    'Quick-add a note as a document with SVPOR hints.',
    ARRAY['document.write']::text[], 'state_changing', '{}'::jsonb, true,
    30000, 1048576, 65536,
    jsonb_build_array(
        _v3_api_arg('p_title',          'text'),
        _v3_api_arg('p_body_text',      'text'),
        _v3_api_arg('p_projects',       'text[]', false),
        _v3_api_arg('p_subjects',       'text[]', false),
        _v3_api_arg('p_verbs',          'text[]', false),
        _v3_api_arg('p_svpor_frames',   'jsonb',  false),
        _v3_api_arg('p_metadata_jsonb', 'jsonb',  false)));

SELECT rest_register_endpoint(
    'GET', '/v3/document',
    'document_get(bigint)'::regprocedure,
    'Read a document with tags and SVPOR hints.',
    ARRAY['document.read']::text[], 'read_only', '{}'::jsonb, true,
    30000, 1048576, 65536,
    jsonb_build_array(
        _v3_api_arg('p_document_id', 'bigint', true, 'query')));

SELECT rest_register_endpoint(
    'POST', '/v3/chat/session',
    'chat_start(text,text,text[],text[],text[],jsonb,jsonb)'::regprocedure,
    'Start an end-user LLM chat session.',
    ARRAY['chat.write']::text[], 'state_changing', '{}'::jsonb, true,
    30000, 1048576, 65536,
    jsonb_build_array(
        _v3_api_arg('p_title',          'text',  false),
        _v3_api_arg('p_account_name',   'text',  false),
        _v3_api_arg('p_projects',       'text[]', false),
        _v3_api_arg('p_subjects',       'text[]', false),
        _v3_api_arg('p_verbs',          'text[]', false),
        _v3_api_arg('p_svpor_frames',   'jsonb', false),
        _v3_api_arg('p_metadata_jsonb', 'jsonb', false)));

SELECT rest_register_endpoint(
    'POST', '/v3/chat/message',
    'chat_append_message(bigint,text,text,jsonb,jsonb)'::regprocedure,
    'Append a message to an end-user LLM chat session.',
    ARRAY['chat.write']::text[], 'state_changing', '{}'::jsonb, true,
    30000, 1048576, 65536,
    jsonb_build_array(
        _v3_api_arg('p_chat_session_id', 'bigint'),
        _v3_api_arg('p_role',            'text'),
        _v3_api_arg('p_content_text',    'text',  false),
        _v3_api_arg('p_content_jsonb',   'jsonb', false),
        _v3_api_arg('p_metadata_jsonb',  'jsonb', false)));

SELECT rest_register_endpoint(
    'POST', '/v3/chat/finalize',
    'chat_finalize(bigint)'::regprocedure,
    'Finalize an LLM chat and refresh its llm-chat document projection.',
    ARRAY['chat.write']::text[], 'state_changing', '{}'::jsonb, true,
    30000, 1048576, 65536,
    jsonb_build_array(
        _v3_api_arg('p_chat_session_id', 'bigint')));

SELECT rest_register_endpoint(
    'GET', '/v3/chat/session',
    'chat_get(bigint)'::regprocedure,
    'Read LLM chat session metadata and document projection.',
    ARRAY['chat.read']::text[], 'read_only', '{}'::jsonb, true,
    30000, 1048576, 65536,
    jsonb_build_array(
        _v3_api_arg('p_chat_session_id', 'bigint', true, 'query')));

SELECT rest_register_endpoint(
    'GET', '/v3/chat/messages',
    'chat_messages(bigint)'::regprocedure,
    'Read ordered messages for an LLM chat session.',
    ARRAY['chat.read']::text[], 'read_only', '{}'::jsonb, true,
    30000, 1048576, 65536,
    jsonb_build_array(
        _v3_api_arg('p_chat_session_id', 'bigint', true, 'query')));

DROP FUNCTION maludb_core._v3_api_arg(text, text, boolean, text, jsonb);
