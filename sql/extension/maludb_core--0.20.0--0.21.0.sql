\echo Use "ALTER EXTENSION maludb_core UPDATE TO '0.21.0'" to load this file. \quit

-- =====================================================================
-- maludb_core 0.20.0 → 0.21.0
--
-- Stage 2 — Ingestion contracts (S2-8).
--
-- Per requirements.md §9 Stage 2: "Retrospective and continuous
-- ingestion contracts for source packages, candidate claims, source
-- references, connector checkpoints, and source-specific offsets."
--
-- Lifecycle:
--   1. Operator registers a connector (Slack, GitHub, log tail, ...)
--      via register_connector().
--   2. Each connector advances one or more named cursors via
--      advance_checkpoint() as it consumes upstream events.
--   3. Parser/extractor logic registers raw events as source_packages
--      (S2-1/S2-2 surface) and proposes candidate claims via
--      propose_pending_claim().
--   4. A human reviewer or auto-promotion policy calls
--      accept_pending_claim() (writes malu$claim + ledger; updates
--      pending row) or reject_pending_claim().
--
-- Cursor formats supported: 'timestamp', 'opaque', 'message_id',
-- 'offset'. cursor_jsonb is provided for multi-part cursors (e.g.,
-- {channel_id, last_ts} for Slack).
-- =====================================================================

CREATE OR REPLACE FUNCTION maludb_core_version() RETURNS text
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$ SELECT '0.21.0'::text $body$;

-- =====================================================================
-- malu$ingestion_connector
-- =====================================================================
CREATE TABLE malu$ingestion_connector (
    connector_id        bigserial PRIMARY KEY,
    owner_schema        name NOT NULL DEFAULT current_schema(),
    connector_name      text NOT NULL,
    connector_kind      text NOT NULL,
    source_type         text NOT NULL
        REFERENCES malu$source_type(source_type),
    config_jsonb        jsonb NOT NULL DEFAULT '{}'::jsonb,
    enabled             boolean NOT NULL DEFAULT true,
    sensitivity         text NOT NULL DEFAULT 'internal'
        CHECK (sensitivity IN ('public','internal','restricted','prohibited')),
    created_at          timestamptz NOT NULL DEFAULT now(),
    updated_at          timestamptz NOT NULL DEFAULT now(),
    UNIQUE (owner_schema, connector_name)
);
CREATE INDEX malu$ingestion_connector_kind_idx
    ON malu$ingestion_connector(connector_kind, enabled);

ALTER TABLE malu$ingestion_connector ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_owner ON malu$ingestion_connector
    USING (owner_schema = current_schema())
    WITH CHECK (owner_schema = current_schema());

-- =====================================================================
-- malu$ingestion_checkpoint
--
-- A connector may carry multiple cursors (e.g., one per Slack channel).
-- 'default' is the single-cursor pattern.
-- =====================================================================
CREATE TABLE malu$ingestion_checkpoint (
    checkpoint_id       bigserial PRIMARY KEY,
    connector_id        bigint NOT NULL
        REFERENCES malu$ingestion_connector(connector_id) ON DELETE CASCADE,
    owner_schema        name NOT NULL DEFAULT current_schema(),
    cursor_name         text NOT NULL DEFAULT 'default',
    cursor_format       text NOT NULL DEFAULT 'opaque'
        CHECK (cursor_format IN ('timestamp','opaque','message_id','offset','jsonb')),
    cursor_value        text,
    cursor_jsonb        jsonb,
    mode                text NOT NULL DEFAULT 'continuous'
        CHECK (mode IN ('retrospective','continuous','paused')),
    last_advanced_at    timestamptz,
    last_attempt_at     timestamptz,
    last_error          text,
    items_ingested      bigint NOT NULL DEFAULT 0,
    created_at          timestamptz NOT NULL DEFAULT now(),
    updated_at          timestamptz NOT NULL DEFAULT now(),
    UNIQUE (connector_id, cursor_name)
);
CREATE INDEX malu$ingestion_checkpoint_mode_idx
    ON malu$ingestion_checkpoint(mode);

ALTER TABLE malu$ingestion_checkpoint ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_owner ON malu$ingestion_checkpoint
    USING (owner_schema = current_schema())
    WITH CHECK (owner_schema = current_schema());

-- =====================================================================
-- malu$pending_claim — candidate claims awaiting review/promotion
-- =====================================================================
CREATE TABLE malu$pending_claim (
    pending_claim_id    bigserial PRIMARY KEY,
    owner_schema        name NOT NULL DEFAULT current_schema(),
    connector_id        bigint
        REFERENCES malu$ingestion_connector(connector_id) ON DELETE SET NULL,
    source_package_id   bigint
        REFERENCES malu$source_package(source_package_id) ON DELETE SET NULL,
    subject             text,
    verb                text,
    predicate           text,
    object_value        text,
    relationship        text,
    statement_text      text,
    statement_jsonb     jsonb,
    source_locator      jsonb,
    confidence          numeric(5,4)
        CHECK (confidence IS NULL OR (confidence >= 0 AND confidence <= 1)),
    proposed_at         timestamptz NOT NULL DEFAULT now(),
    proposed_by         text,
    review_state        text NOT NULL DEFAULT 'pending'
        CHECK (review_state IN ('pending','accepted','rejected','duplicate','superseded')),
    reviewed_at         timestamptz,
    reviewed_by         text,
    review_note         text,
    promoted_claim_id   bigint
        REFERENCES malu$claim(claim_id) ON DELETE SET NULL,
    sensitivity         text NOT NULL DEFAULT 'internal'
        CHECK (sensitivity IN ('public','internal','restricted','prohibited'))
);
CREATE INDEX malu$pending_claim_state_idx
    ON malu$pending_claim(review_state, proposed_at DESC)
    WHERE review_state = 'pending';
CREATE INDEX malu$pending_claim_connector_idx
    ON malu$pending_claim(connector_id, review_state);
CREATE INDEX malu$pending_claim_source_idx
    ON malu$pending_claim(source_package_id)
    WHERE source_package_id IS NOT NULL;

ALTER TABLE malu$pending_claim ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_owner ON malu$pending_claim
    USING (owner_schema = current_schema())
    WITH CHECK (owner_schema = current_schema());

-- =====================================================================
-- Grants + sequences
-- =====================================================================
GRANT SELECT ON malu$ingestion_connector, malu$ingestion_checkpoint, malu$pending_claim TO
    maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;
GRANT INSERT, UPDATE, DELETE ON malu$ingestion_connector, malu$ingestion_checkpoint, malu$pending_claim TO
    maludb_memory_admin, maludb_memory_executor;
GRANT USAGE, SELECT ON SEQUENCE
    malu$ingestion_connector_connector_id_seq,
    malu$ingestion_checkpoint_checkpoint_id_seq,
    malu$pending_claim_pending_claim_id_seq
TO maludb_memory_admin, maludb_memory_executor;

-- =====================================================================
-- register_connector — upsert by (owner_schema, connector_name).
-- =====================================================================
CREATE FUNCTION register_connector(
    p_connector_name text,
    p_connector_kind text,
    p_source_type    text,
    p_config_jsonb   jsonb DEFAULT '{}'::jsonb,
    p_sensitivity    text  DEFAULT 'internal'
) RETURNS bigint
LANGUAGE plpgsql
AS $body$
DECLARE v_id bigint;
BEGIN
    INSERT INTO malu$ingestion_connector
        (connector_name, connector_kind, source_type, config_jsonb, sensitivity)
    VALUES (p_connector_name, p_connector_kind, p_source_type,
            COALESCE(p_config_jsonb, '{}'::jsonb), p_sensitivity)
    ON CONFLICT (owner_schema, connector_name) DO UPDATE
        SET connector_kind = EXCLUDED.connector_kind,
            source_type    = EXCLUDED.source_type,
            config_jsonb   = EXCLUDED.config_jsonb,
            sensitivity    = EXCLUDED.sensitivity,
            updated_at     = now()
    RETURNING connector_id INTO v_id;
    RETURN v_id;
END;
$body$;

-- =====================================================================
-- advance_checkpoint — upsert by (connector_id, cursor_name). When the
-- caller is making forward progress, pass p_last_error => NULL. On
-- transient failure, pass the error string + skip the cursor advance.
-- =====================================================================
CREATE FUNCTION advance_checkpoint(
    p_connector_id    bigint,
    p_cursor_name     text    DEFAULT 'default',
    p_cursor_value    text    DEFAULT NULL,
    p_cursor_jsonb    jsonb   DEFAULT NULL,
    p_cursor_format   text    DEFAULT NULL,
    p_mode            text    DEFAULT NULL,
    p_items_added     bigint  DEFAULT 0,
    p_last_error      text    DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql
AS $body$
DECLARE
    v_id     bigint;
    v_format text;
BEGIN
    -- Look up an existing row; if found, preserve cursor_format unless
    -- caller supplied a new one. INSERT path uses p_cursor_format
    -- explicitly so the default ('opaque') applies for first-touch.
    SELECT checkpoint_id, cursor_format INTO v_id, v_format
    FROM malu$ingestion_checkpoint
    WHERE connector_id = p_connector_id AND cursor_name = p_cursor_name;

    IF v_id IS NULL THEN
        INSERT INTO malu$ingestion_checkpoint
            (connector_id, cursor_name, cursor_format, cursor_value, cursor_jsonb,
             mode, last_advanced_at, last_attempt_at, last_error, items_ingested)
        VALUES
            (p_connector_id, p_cursor_name,
             COALESCE(p_cursor_format, 'opaque'),
             p_cursor_value, p_cursor_jsonb,
             COALESCE(p_mode, 'continuous'),
             CASE WHEN p_last_error IS NULL THEN now() END,
             now(), p_last_error, COALESCE(p_items_added, 0))
        RETURNING checkpoint_id INTO v_id;
    ELSE
        UPDATE malu$ingestion_checkpoint
           SET cursor_value     = CASE WHEN p_last_error IS NULL
                                       THEN COALESCE(p_cursor_value, cursor_value)
                                       ELSE cursor_value END,
               cursor_jsonb     = CASE WHEN p_last_error IS NULL
                                       THEN COALESCE(p_cursor_jsonb, cursor_jsonb)
                                       ELSE cursor_jsonb END,
               cursor_format    = COALESCE(p_cursor_format, cursor_format),
               mode             = COALESCE(p_mode, mode),
               last_advanced_at = CASE WHEN p_last_error IS NULL THEN now()
                                       ELSE last_advanced_at END,
               last_attempt_at  = now(),
               last_error       = p_last_error,
               items_ingested   = items_ingested + COALESCE(p_items_added, 0),
               updated_at       = now()
         WHERE checkpoint_id = v_id;
    END IF;
    RETURN v_id;
END;
$body$;

-- =====================================================================
-- propose_pending_claim — adds a candidate to the review queue.
-- =====================================================================
CREATE FUNCTION propose_pending_claim(
    p_connector_id      bigint   DEFAULT NULL,
    p_source_package_id bigint   DEFAULT NULL,
    p_subject           text     DEFAULT NULL,
    p_verb              text     DEFAULT NULL,
    p_predicate         text     DEFAULT NULL,
    p_object_value      text     DEFAULT NULL,
    p_relationship      text     DEFAULT NULL,
    p_statement_text    text     DEFAULT NULL,
    p_statement_jsonb   jsonb    DEFAULT NULL,
    p_source_locator    jsonb    DEFAULT NULL,
    p_confidence        numeric  DEFAULT NULL,
    p_proposed_by       text     DEFAULT NULL,
    p_sensitivity       text     DEFAULT 'internal'
) RETURNS bigint
LANGUAGE plpgsql
AS $body$
DECLARE v_id bigint;
BEGIN
    INSERT INTO malu$pending_claim
        (connector_id, source_package_id,
         subject, verb, predicate, object_value, relationship,
         statement_text, statement_jsonb, source_locator,
         confidence, proposed_by, sensitivity)
    VALUES (p_connector_id, p_source_package_id,
            p_subject, p_verb, p_predicate, p_object_value, p_relationship,
            p_statement_text, p_statement_jsonb, p_source_locator,
            p_confidence, p_proposed_by, p_sensitivity)
    RETURNING pending_claim_id INTO v_id;
    RETURN v_id;
END;
$body$;

-- =====================================================================
-- accept_pending_claim — the promotion path. Writes malu$claim +
-- malu$derivation_ledger in one tx and marks the pending row accepted.
--
-- Doctrine: pending → claim transitions MUST produce a ledger entry
-- (CLAUDE.md "Derivations without ledger entries are bugs"). No
-- EXCEPTION blocks inside this function, so any failure aborts the
-- whole call.
-- =====================================================================
CREATE FUNCTION accept_pending_claim(
    p_pending_claim_id bigint,
    p_reviewer         text  DEFAULT NULL,
    p_review_note      text  DEFAULT NULL,
    p_parser_name      text  DEFAULT NULL,
    p_verifier_name    text  DEFAULT NULL,
    p_inputs_jsonb     jsonb DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql
AS $body$
DECLARE
    v_pending malu$pending_claim%ROWTYPE;
    v_claim_id bigint;
    v_connector_kind text;
BEGIN
    SELECT * INTO v_pending FROM malu$pending_claim
     WHERE pending_claim_id = p_pending_claim_id
       FOR UPDATE;
    IF v_pending.pending_claim_id IS NULL THEN
        RAISE EXCEPTION 'unknown pending_claim_id: %', p_pending_claim_id
            USING ERRCODE = 'no_data_found';
    END IF;
    IF v_pending.review_state <> 'pending' THEN
        RAISE EXCEPTION
          'pending_claim_id=% is %; only pending rows can be accepted',
          p_pending_claim_id, v_pending.review_state
          USING ERRCODE = 'object_not_in_prerequisite_state';
    END IF;

    -- 1. Write the real claim row.
    v_claim_id := register_claim(
        p_subject           => v_pending.subject,
        p_verb              => v_pending.verb,
        p_predicate         => v_pending.predicate,
        p_object_value      => v_pending.object_value,
        p_relationship      => v_pending.relationship,
        p_statement_text    => v_pending.statement_text,
        p_statement_jsonb   => v_pending.statement_jsonb,
        p_source_package_id => v_pending.source_package_id,
        p_source_locator    => v_pending.source_locator,
        p_sensitivity       => v_pending.sensitivity);

    -- 2. Ledger entry. parser_name falls back to the connector kind
    -- if not supplied — gives the ledger a non-NULL provenance even
    -- when reviewers click 'accept' without filling extra fields.
    IF p_parser_name IS NULL AND v_pending.connector_id IS NOT NULL THEN
        SELECT connector_kind INTO v_connector_kind
        FROM malu$ingestion_connector
        WHERE connector_id = v_pending.connector_id;
    END IF;

    PERFORM record_derivation(
        p_derived_object_type => 'claim',
        p_derived_object_id   => v_claim_id,
        p_parser_name         => COALESCE(p_parser_name, v_connector_kind, 'pending_queue'),
        p_verifier_name       => p_verifier_name,
        p_inputs_jsonb        => COALESCE(p_inputs_jsonb,
            jsonb_build_object(
                'pending_claim_id', p_pending_claim_id,
                'connector_id',     v_pending.connector_id,
                'source_package_id', v_pending.source_package_id,
                'confidence',       v_pending.confidence)));

    -- 3. Update the pending row.
    UPDATE malu$pending_claim
       SET review_state      = 'accepted',
           reviewed_at       = now(),
           reviewed_by       = p_reviewer,
           review_note       = p_review_note,
           promoted_claim_id = v_claim_id
     WHERE pending_claim_id = p_pending_claim_id;

    RETURN v_claim_id;
END;
$body$;

-- =====================================================================
-- reject_pending_claim — non-destructive; row stays for audit.
-- =====================================================================
CREATE FUNCTION reject_pending_claim(
    p_pending_claim_id bigint,
    p_reviewer         text DEFAULT NULL,
    p_review_note      text DEFAULT NULL,
    p_final_state      text DEFAULT 'rejected'
) RETURNS void
LANGUAGE plpgsql
AS $body$
BEGIN
    IF p_final_state NOT IN ('rejected','duplicate','superseded') THEN
        RAISE EXCEPTION 'reject_pending_claim: bad final_state %', p_final_state
            USING ERRCODE = 'invalid_parameter_value';
    END IF;
    UPDATE malu$pending_claim
       SET review_state = p_final_state,
           reviewed_at  = now(),
           reviewed_by  = p_reviewer,
           review_note  = p_review_note
     WHERE pending_claim_id = p_pending_claim_id
       AND review_state     = 'pending';
    IF NOT FOUND THEN
        RAISE EXCEPTION
          'pending_claim_id=% not found or not in state=pending',
          p_pending_claim_id
          USING ERRCODE = 'object_not_in_prerequisite_state';
    END IF;
END;
$body$;

-- =====================================================================
-- list_pending_claims — operator/reviewer queue.
-- =====================================================================
CREATE FUNCTION list_pending_claims(
    p_connector_id bigint DEFAULT NULL,
    p_limit        integer DEFAULT 100
) RETURNS TABLE (
    pending_claim_id  bigint,
    connector_name    text,
    subject           text,
    verb              text,
    object_value      text,
    statement_text    text,
    confidence        numeric,
    proposed_at       timestamptz,
    proposed_by       text
) LANGUAGE sql STABLE
AS $body$
    SELECT p.pending_claim_id,
           c.connector_name,
           p.subject, p.verb, p.object_value, p.statement_text,
           p.confidence, p.proposed_at, p.proposed_by
    FROM malu$pending_claim p
    LEFT JOIN malu$ingestion_connector c ON c.connector_id = p.connector_id
    WHERE p.review_state = 'pending'
      AND (p_connector_id IS NULL OR p.connector_id = p_connector_id)
    ORDER BY p.proposed_at ASC, p.pending_claim_id
    LIMIT p_limit;
$body$;

GRANT EXECUTE ON FUNCTION
    register_connector(text, text, text, jsonb, text),
    advance_checkpoint(bigint, text, text, jsonb, text, text, bigint, text),
    propose_pending_claim(bigint, bigint, text, text, text, text, text, text, jsonb, jsonb, numeric, text, text),
    accept_pending_claim(bigint, text, text, text, text, jsonb),
    reject_pending_claim(bigint, text, text, text),
    list_pending_claims(bigint, integer)
TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;
