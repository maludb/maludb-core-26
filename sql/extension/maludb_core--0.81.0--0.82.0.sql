\echo Use "ALTER EXTENSION maludb_core UPDATE TO '0.82.0'" to load this file. \quit

-- =====================================================================
-- maludb_core 0.81.0 -> 0.82.0
--
-- Episode/event enrichment: link subjects, verbs, artifacts (documents),
-- and decisions to an episode, and make the whole thing agent-ready (an
-- LLM extractor can stage derived graph fragments as 'suggested' for
-- review, the same way provided data flows).
--
-- Investigation (verified against a live DB) established:
--   * malu$episode_object exists but had only a write facade
--     (maludb_register_episode) -- no read/list/update path.
--   * malu$relationship_edge is pairwise and uses a controlled
--     relationship_type vocabulary; register_svpor_relationship is
--     hard-restricted to subject<->verb endpoints, so it cannot link a
--     subject (or a document) to an episode.
--   * malu$claim / malu$fact carry SVPOR as denormalised text, not FKs,
--     and are source-oriented -- not a usable subject/verb/object bridge.
--
-- So this release adds a normalised, fully polymorphic SVO assertion
-- table plus the episode read/list/update surface and an event-type
-- picker.
--
--   1. malu$svpor_statement -- (subject_kind/subject_id) --verb_id-->
--      (object_kind/object_id), optional predicate, dated, with
--      confidence, optional source_package provenance, and a
--      provenance state (provided | suggested | accepted | rejected).
--      Both ends polymorphic over the SVPOR + governed-object graph,
--      including 'document' directly. The verb is always a
--      malu$svpor_verb, sidestepping the relationship_type vocabulary.
--      Idempotent and FK-validates both endpoints per kind.
--
--   2. malu$episode_type -- per-schema advisory picker for event types
--      (the document_type pattern from 0.81.0). episode_kind stays free
--      text; nothing is FK-enforced.
--
--   3. malu$episode_object.provenance -- so a derived event lands as
--      'suggested' for review, like derived statements/tags/hints.
--
-- Agent-readiness note: the derivation *process* (launching the LLM,
-- parsing) is NOT defined here -- it lives in the model gateway
-- (malu$model_request/response), the ingest pipeline
-- (malu$raw_ingest/malu$ingest_extraction), MC2DB tools, and lineage
-- (malu$derivation_ledger). This release only ensures the data model
-- carries the provenance/confidence/lineage needed for that process to
-- write reviewable output. malu$svpor_statement is registered as a
-- derived_object_type so its lineage can be recorded.
--
-- Existing schemas pick up the new objects by re-running
-- maludb_core.enable_memory_schema().
-- =====================================================================

CREATE OR REPLACE FUNCTION maludb_core.maludb_core_version() RETURNS text
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$ SELECT '0.82.0'::text $body$;

-- ===== 1. malu$episode_object: provenance ===========================
ALTER TABLE maludb_core.malu$episode_object
    ADD COLUMN IF NOT EXISTS provenance text NOT NULL DEFAULT 'provided'
        CHECK (provenance IN ('provided','suggested','accepted','rejected'));

-- ===== 2. malu$episode_type: per-schema advisory picker =============
CREATE TABLE IF NOT EXISTS maludb_core.malu$episode_type (
    episode_type_id  bigserial PRIMARY KEY,
    owner_schema     name NOT NULL DEFAULT current_schema(),
    episode_type     text NOT NULL,
    description      text,
    display_order    integer,
    created_at       timestamptz NOT NULL DEFAULT now(),
    UNIQUE (owner_schema, episode_type)
);
CREATE UNIQUE INDEX IF NOT EXISTS malu$episode_type_owner_lower_idx
    ON maludb_core.malu$episode_type(owner_schema, lower(episode_type));
CREATE INDEX IF NOT EXISTS malu$episode_type_owner_order_idx
    ON maludb_core.malu$episode_type(owner_schema, display_order, episode_type);

ALTER TABLE maludb_core.malu$episode_type ENABLE ROW LEVEL SECURITY;
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_catalog.pg_policy p
          JOIN pg_catalog.pg_class c ON c.oid = p.polrelid
          JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
         WHERE n.nspname = 'maludb_core'
           AND c.relname = 'malu$episode_type'
           AND p.polname = 'tenant_owner'
    ) THEN
        EXECUTE 'CREATE POLICY tenant_owner ON maludb_core.malu$episode_type
                 USING (owner_schema = current_schema())
                 WITH CHECK (owner_schema = current_schema())';
    END IF;
END$$;

GRANT SELECT, INSERT, UPDATE, DELETE ON maludb_core.malu$episode_type
    TO maludb_memory_admin, maludb_memory_executor;
GRANT SELECT ON maludb_core.malu$episode_type TO maludb_memory_auditor;
GRANT USAGE, SELECT ON SEQUENCE maludb_core.malu$episode_type_episode_type_id_seq
    TO maludb_memory_admin, maludb_memory_executor;

-- ===== 3. malu$svpor_statement: polymorphic SVO assertion ===========
CREATE TABLE IF NOT EXISTS maludb_core.malu$svpor_statement (
    statement_id       bigserial PRIMARY KEY,
    owner_schema       name NOT NULL DEFAULT current_schema(),
    subject_kind       text NOT NULL,
    subject_id         bigint NOT NULL,
    verb_id            bigint NOT NULL
        REFERENCES maludb_core.malu$svpor_verb(verb_id) ON DELETE RESTRICT,
    object_kind        text NOT NULL,
    object_id          bigint NOT NULL,
    predicate_id       bigint
        REFERENCES maludb_core.malu$svpor_predicate(predicate_id) ON DELETE SET NULL,
    valid_from         timestamptz,
    valid_to           timestamptz,
    confidence         numeric(5,4) CHECK (confidence IS NULL OR confidence BETWEEN 0 AND 1),
    provenance         text NOT NULL DEFAULT 'provided'
        CHECK (provenance IN ('provided','suggested','accepted','rejected')),
    source_package_id  bigint
        REFERENCES maludb_core.malu$source_package(source_package_id) ON DELETE SET NULL,
    metadata_jsonb     jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at         timestamptz NOT NULL DEFAULT now(),
    CHECK (subject_kind IN
        ('subject','verb','document','episode_object','memory',
         'source_package','claim','fact','memory_detail_object')),
    CHECK (object_kind IN
        ('subject','verb','document','episode_object','memory',
         'source_package','claim','fact','memory_detail_object'))
);
-- Idempotency identity: a repeated (subject, verb, object) assertion in a
-- tenant is the same assertion. predicate/confidence/provenance/dates are
-- not part of the identity.
CREATE UNIQUE INDEX IF NOT EXISTS malu$svpor_statement_identity_idx
    ON maludb_core.malu$svpor_statement
       (owner_schema, subject_kind, subject_id, verb_id, object_kind, object_id);
CREATE INDEX IF NOT EXISTS malu$svpor_statement_subject_idx
    ON maludb_core.malu$svpor_statement(owner_schema, subject_kind, subject_id);
CREATE INDEX IF NOT EXISTS malu$svpor_statement_object_idx
    ON maludb_core.malu$svpor_statement(owner_schema, object_kind, object_id);
CREATE INDEX IF NOT EXISTS malu$svpor_statement_verb_idx
    ON maludb_core.malu$svpor_statement(owner_schema, verb_id);

ALTER TABLE maludb_core.malu$svpor_statement ENABLE ROW LEVEL SECURITY;
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_catalog.pg_policy p
          JOIN pg_catalog.pg_class c ON c.oid = p.polrelid
          JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
         WHERE n.nspname = 'maludb_core'
           AND c.relname = 'malu$svpor_statement'
           AND p.polname = 'tenant_owner'
    ) THEN
        EXECUTE 'CREATE POLICY tenant_owner ON maludb_core.malu$svpor_statement
                 USING (owner_schema = current_schema())
                 WITH CHECK (owner_schema = current_schema())';
    END IF;
END$$;

GRANT SELECT, INSERT, UPDATE, DELETE ON maludb_core.malu$svpor_statement
    TO maludb_memory_admin, maludb_memory_executor;
GRANT SELECT ON maludb_core.malu$svpor_statement TO maludb_memory_auditor;
GRANT USAGE, SELECT ON SEQUENCE maludb_core.malu$svpor_statement_statement_id_seq
    TO maludb_memory_admin, maludb_memory_executor;

-- ===== 4. derivation_ledger: register the new derived type ==========
ALTER TABLE maludb_core.malu$derivation_ledger
    DROP CONSTRAINT malu$derivation_ledger_derived_object_type_check;
ALTER TABLE maludb_core.malu$derivation_ledger
    ADD CONSTRAINT malu$derivation_ledger_derived_object_type_check
    CHECK (derived_object_type IN (
        'source_package','claim','fact','memory','episode_object',
        'memory_detail_object','relationship_edge','embedding',
        'page_index_tree','page_index_node','svpor_statement'));

-- ===== 5. core helpers: endpoint validation + writers ===============

-- Per-kind existence check for a polymorphic endpoint. RLS already scopes
-- the governed tables to current_schema(); the explicit owner_schema
-- predicate on tenant tables keeps intent obvious. Raises
-- foreign_key_violation when the endpoint does not exist.
-- No SET search_path: this is SECURITY INVOKER and its existence checks
-- depend on current_schema() resolving to the caller's tenant schema
-- (both for the explicit owner_schema predicate and for RLS). All table
-- references are maludb_core-qualified, so inheriting the caller's path is
-- safe. (Pinning pg_catalog here would make current_schema() = pg_catalog
-- and RLS would filter every row for a non-superuser tenant role.)
CREATE FUNCTION maludb_core._svpor_statement_assert_endpoint(
    p_schema name, p_kind text, p_id bigint
) RETURNS void
LANGUAGE plpgsql
SECURITY INVOKER
AS $body$
DECLARE
    v_ok boolean := false;
BEGIN
    CASE p_kind
        WHEN 'subject' THEN
            SELECT EXISTS(SELECT 1 FROM maludb_core.malu$svpor_subject
                          WHERE owner_schema = p_schema AND subject_id = p_id) INTO v_ok;
        WHEN 'verb' THEN
            SELECT EXISTS(SELECT 1 FROM maludb_core.malu$svpor_verb
                          WHERE owner_schema = p_schema AND verb_id = p_id) INTO v_ok;
        WHEN 'document' THEN
            SELECT EXISTS(SELECT 1 FROM maludb_core.malu$document
                          WHERE owner_schema = p_schema AND document_id = p_id) INTO v_ok;
        WHEN 'episode_object' THEN
            SELECT EXISTS(SELECT 1 FROM maludb_core.malu$episode_object
                          WHERE owner_schema = p_schema AND episode_id = p_id) INTO v_ok;
        WHEN 'memory' THEN
            SELECT EXISTS(SELECT 1 FROM maludb_core.malu$memory
                          WHERE owner_schema = p_schema AND memory_id = p_id) INTO v_ok;
        WHEN 'source_package' THEN
            SELECT EXISTS(SELECT 1 FROM maludb_core.malu$source_package
                          WHERE owner_schema = p_schema AND source_package_id = p_id) INTO v_ok;
        WHEN 'claim' THEN
            SELECT EXISTS(SELECT 1 FROM maludb_core.malu$claim
                          WHERE owner_schema = p_schema AND claim_id = p_id) INTO v_ok;
        WHEN 'fact' THEN
            SELECT EXISTS(SELECT 1 FROM maludb_core.malu$fact
                          WHERE owner_schema = p_schema AND fact_id = p_id) INTO v_ok;
        WHEN 'memory_detail_object' THEN
            SELECT EXISTS(SELECT 1 FROM maludb_core.malu$memory_detail_object
                          WHERE owner_schema = p_schema AND mdo_id = p_id) INTO v_ok;
        ELSE
            RAISE EXCEPTION 'svpor_statement: unsupported endpoint kind %', p_kind
                USING ERRCODE = 'invalid_parameter_value';
    END CASE;

    IF NOT v_ok THEN
        RAISE EXCEPTION 'svpor_statement endpoint % % not found in schema %', p_kind, p_id, p_schema
            USING ERRCODE = 'foreign_key_violation';
    END IF;
END;
$body$;
REVOKE ALL ON FUNCTION maludb_core._svpor_statement_assert_endpoint(name, text, bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core._svpor_statement_assert_endpoint(name, text, bigint)
    TO maludb_memory_admin, maludb_memory_executor;

-- register_svpor_statement -- idempotent writer. Returns the statement id.
-- On a repeated (subject, verb, object) identity, the existing row is
-- returned and its provenance/confidence/predicate/dates are refreshed
-- when explicitly supplied (COALESCE keeps prior values otherwise).
CREATE FUNCTION maludb_core.register_svpor_statement(
    p_subject_kind     text,
    p_subject_id       bigint,
    p_verb_id          bigint,
    p_object_kind      text,
    p_object_id        bigint,
    p_predicate_id     bigint      DEFAULT NULL,
    p_valid_from       timestamptz DEFAULT NULL,
    p_valid_to         timestamptz DEFAULT NULL,
    p_confidence       numeric     DEFAULT NULL,
    p_provenance       text        DEFAULT 'provided',
    p_source_package_id bigint     DEFAULT NULL,
    p_metadata_jsonb   jsonb       DEFAULT '{}'::jsonb
) RETURNS bigint
LANGUAGE plpgsql
SECURITY INVOKER
AS $body$
DECLARE
    v_schema        name := current_schema();
    v_subject_kind  text := lower(btrim(COALESCE(p_subject_kind, '')));
    v_object_kind   text := lower(btrim(COALESCE(p_object_kind, '')));
    v_provenance    text := COALESCE(NULLIF(btrim(p_provenance), ''), 'provided');
    v_id            bigint;
BEGIN
    IF p_subject_id IS NULL OR p_verb_id IS NULL OR p_object_id IS NULL THEN
        RAISE EXCEPTION 'register_svpor_statement: subject_id, verb_id and object_id are required'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;
    IF v_provenance NOT IN ('provided','suggested','accepted','rejected') THEN
        RAISE EXCEPTION 'register_svpor_statement: bad provenance %', v_provenance
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    -- Validate the verb and both polymorphic endpoints exist in this tenant.
    PERFORM maludb_core._svpor_statement_assert_endpoint(v_schema, 'verb', p_verb_id);
    PERFORM maludb_core._svpor_statement_assert_endpoint(v_schema, v_subject_kind, p_subject_id);
    PERFORM maludb_core._svpor_statement_assert_endpoint(v_schema, v_object_kind, p_object_id);

    INSERT INTO maludb_core.malu$svpor_statement
        (owner_schema, subject_kind, subject_id, verb_id, object_kind, object_id,
         predicate_id, valid_from, valid_to, confidence, provenance,
         source_package_id, metadata_jsonb)
    VALUES
        (v_schema, v_subject_kind, p_subject_id, p_verb_id, v_object_kind, p_object_id,
         p_predicate_id, p_valid_from, p_valid_to, p_confidence, v_provenance,
         p_source_package_id, COALESCE(p_metadata_jsonb, '{}'::jsonb))
    ON CONFLICT (owner_schema, subject_kind, subject_id, verb_id, object_kind, object_id)
    DO UPDATE SET
        predicate_id      = COALESCE(EXCLUDED.predicate_id,      malu$svpor_statement.predicate_id),
        valid_from        = COALESCE(EXCLUDED.valid_from,        malu$svpor_statement.valid_from),
        valid_to          = COALESCE(EXCLUDED.valid_to,          malu$svpor_statement.valid_to),
        confidence        = COALESCE(EXCLUDED.confidence,        malu$svpor_statement.confidence),
        provenance        = EXCLUDED.provenance,
        source_package_id = COALESCE(EXCLUDED.source_package_id, malu$svpor_statement.source_package_id),
        metadata_jsonb    = malu$svpor_statement.metadata_jsonb || EXCLUDED.metadata_jsonb
    RETURNING statement_id INTO v_id;

    RETURN v_id;
END;
$body$;
REVOKE ALL ON FUNCTION maludb_core.register_svpor_statement(
    text, bigint, bigint, text, bigint, bigint, timestamptz, timestamptz, numeric, text, bigint, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core.register_svpor_statement(
    text, bigint, bigint, text, bigint, bigint, timestamptz, timestamptz, numeric, text, bigint, jsonb)
    TO maludb_memory_admin, maludb_memory_executor;

-- close (set valid_to) / delete / set provenance
CREATE FUNCTION maludb_core.svpor_statement_close(
    p_statement_id bigint, p_valid_to timestamptz DEFAULT now()
) RETURNS boolean
LANGUAGE plpgsql SECURITY INVOKER
AS $body$
BEGIN
    IF p_statement_id IS NULL OR p_valid_to IS NULL THEN
        RAISE EXCEPTION 'statement_id and valid_to are required'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;
    UPDATE maludb_core.malu$svpor_statement
       SET valid_to = p_valid_to
     WHERE owner_schema = current_schema()
       AND statement_id = p_statement_id
       AND valid_to IS DISTINCT FROM p_valid_to;
    RETURN FOUND;
END;
$body$;
REVOKE ALL ON FUNCTION maludb_core.svpor_statement_close(bigint, timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core.svpor_statement_close(bigint, timestamptz)
    TO maludb_memory_admin, maludb_memory_executor;

CREATE FUNCTION maludb_core.svpor_statement_delete(p_statement_id bigint) RETURNS integer
LANGUAGE plpgsql SECURITY INVOKER
AS $body$
DECLARE v_count integer;
BEGIN
    IF p_statement_id IS NULL THEN
        RAISE EXCEPTION 'statement_id is required' USING ERRCODE = 'invalid_parameter_value';
    END IF;
    DELETE FROM maludb_core.malu$svpor_statement
     WHERE owner_schema = current_schema()
       AND statement_id = p_statement_id;
    GET DIAGNOSTICS v_count = ROW_COUNT;
    RETURN v_count;
END;
$body$;
REVOKE ALL ON FUNCTION maludb_core.svpor_statement_delete(bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core.svpor_statement_delete(bigint)
    TO maludb_memory_admin, maludb_memory_executor;

CREATE FUNCTION maludb_core.svpor_statement_set_provenance(
    p_statement_id bigint, p_provenance text
) RETURNS boolean
LANGUAGE plpgsql SECURITY INVOKER
AS $body$
BEGIN
    IF p_statement_id IS NULL
       OR p_provenance NOT IN ('provided','suggested','accepted','rejected') THEN
        RAISE EXCEPTION 'statement_id and a valid provenance are required'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;
    UPDATE maludb_core.malu$svpor_statement
       SET provenance = p_provenance
     WHERE owner_schema = current_schema()
       AND statement_id = p_statement_id
       AND provenance IS DISTINCT FROM p_provenance;
    RETURN FOUND;
END;
$body$;
REVOKE ALL ON FUNCTION maludb_core.svpor_statement_set_provenance(bigint, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core.svpor_statement_set_provenance(bigint, text)
    TO maludb_memory_admin, maludb_memory_executor;

-- Display-name resolver for a polymorphic endpoint (best-effort label).
-- No SET search_path: see _svpor_statement_assert_endpoint above. The
-- label lookups scope by current_schema(), which must be the tenant.
CREATE FUNCTION maludb_core._svpor_endpoint_label(p_kind text, p_id bigint) RETURNS text
LANGUAGE plpgsql STABLE SECURITY INVOKER
AS $body$
DECLARE v_label text;
BEGIN
    CASE p_kind
        WHEN 'subject' THEN
            SELECT canonical_name INTO v_label FROM maludb_core.malu$svpor_subject
             WHERE owner_schema = current_schema() AND subject_id = p_id;
        WHEN 'verb' THEN
            SELECT canonical_name INTO v_label FROM maludb_core.malu$svpor_verb
             WHERE owner_schema = current_schema() AND verb_id = p_id;
        WHEN 'document' THEN
            SELECT title INTO v_label FROM maludb_core.malu$document
             WHERE owner_schema = current_schema() AND document_id = p_id;
        WHEN 'episode_object' THEN
            SELECT title INTO v_label FROM maludb_core.malu$episode_object
             WHERE owner_schema = current_schema() AND episode_id = p_id;
        WHEN 'memory' THEN
            SELECT title INTO v_label FROM maludb_core.malu$memory
             WHERE owner_schema = current_schema() AND memory_id = p_id;
        WHEN 'source_package' THEN
            SELECT source_type INTO v_label FROM maludb_core.malu$source_package
             WHERE owner_schema = current_schema() AND source_package_id = p_id;
        ELSE
            v_label := NULL;
    END CASE;
    RETURN v_label;
END;
$body$;
REVOKE ALL ON FUNCTION maludb_core._svpor_endpoint_label(text, bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core._svpor_endpoint_label(text, bigint)
    TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;

-- episode_get -- aggregate: the event plus everything related to it.
-- 'statements' covers attendees (subject person + verb), artifacts
-- (document + generated_by), and decisions (memory + made_during) -- any
-- row whose subject OR object is this episode. 'details' carries any
-- memory_detail_objects hung directly off the episode.
CREATE FUNCTION maludb_core.episode_get(p_episode_id bigint)
RETURNS jsonb
LANGUAGE sql STABLE SECURITY INVOKER
AS $body$
    SELECT jsonb_build_object(
        'episode', to_jsonb(e),
        'statements', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                       'statement_id', s.statement_id,
                       'subject_kind', s.subject_kind,
                       'subject_id',   s.subject_id,
                       'subject_label', maludb_core._svpor_endpoint_label(s.subject_kind, s.subject_id),
                       'verb_id',      s.verb_id,
                       'verb',         maludb_core._svpor_endpoint_label('verb', s.verb_id),
                       'object_kind',  s.object_kind,
                       'object_id',    s.object_id,
                       'object_label', maludb_core._svpor_endpoint_label(s.object_kind, s.object_id),
                       'provenance',   s.provenance,
                       'confidence',   s.confidence,
                       'valid_from',   s.valid_from,
                       'valid_to',     s.valid_to)
                     ORDER BY s.statement_id)
              FROM maludb_core.malu$svpor_statement s
             WHERE s.owner_schema = e.owner_schema
               AND ((s.subject_kind = 'episode_object' AND s.subject_id = e.episode_id)
                 OR (s.object_kind  = 'episode_object' AND s.object_id  = e.episode_id))
        ), '[]'::jsonb),
        'details', COALESCE((
            SELECT jsonb_agg(to_jsonb(d) ORDER BY d.ordinal NULLS LAST, d.mdo_id)
              FROM maludb_core.malu$memory_detail_object d
             WHERE d.owner_schema = e.owner_schema
               AND d.episode_id = e.episode_id
        ), '[]'::jsonb)
    )
    FROM maludb_core.malu$episode_object e
    WHERE e.owner_schema = current_schema()
      AND e.episode_id = p_episode_id
$body$;
REVOKE ALL ON FUNCTION maludb_core.episode_get(bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core.episode_get(bigint)
    TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;

-- ===== 6. 0.82.0 schema-local facade builder ========================
CREATE FUNCTION maludb_core._enable_memory_schema_0820_facade(p_schema name) RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
DECLARE
    v_count integer := 0;
BEGIN
    PERFORM maludb_core._memory_schema_assert_manageable(p_schema);

    -- ---- maludb_episode_type: writable per-schema picker -----------
    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_episode_type', 'view');
    EXECUTE format($sql$
        CREATE OR REPLACE VIEW %I.maludb_episode_type WITH (security_invoker = true) AS
        SELECT episode_type_id, episode_type, description, display_order, created_at
          FROM maludb_core.malu$episode_type
         WHERE owner_schema = %L
        WITH LOCAL CHECK OPTION
    $sql$, p_schema, p_schema);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON %I.maludb_episode_type TO maludb_memory_admin, maludb_memory_executor', p_schema);
    EXECUTE format('GRANT SELECT ON %I.maludb_episode_type TO maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_episode_type', 'view', 'Schema-local episode type picker facade.');
    v_count := v_count + 1;

    -- starter event types (idempotent; tenant edits survive re-enable)
    EXECUTE format($sql$
        INSERT INTO maludb_core.malu$episode_type
            (owner_schema, episode_type, description, display_order)
        VALUES
            (%L,'Meeting',       'General meeting.',                       10),
            (%L,'Daily Standup', 'Recurring team standup.',                20),
            (%L,'Review',        'Review or demo session.',                30),
            (%L,'Retrospective', 'Retrospective / lessons-learned.',       40),
            (%L,'1:1',           'One-on-one conversation.',               50),
            (%L,'Incident',      'Incident or outage event.',              60),
            (%L,'Planning',      'Planning or roadmap session.',           70)
        ON CONFLICT DO NOTHING
    $sql$, p_schema, p_schema, p_schema, p_schema, p_schema, p_schema, p_schema);

    -- ---- starter verbs for the meeting use-case --------------------
    EXECUTE format($sql$
        INSERT INTO maludb_core.malu$svpor_verb (owner_schema, canonical_name, aliases, description)
        VALUES
            (%L,'attended',     ARRAY['attended_by']::text[], 'Participant attended an event.'),
            (%L,'generated_by', ARRAY['produced_by']::text[], 'Artifact was generated by an event.'),
            (%L,'made_during',  ARRAY['decided_during']::text[], 'Decision/outcome made during an event.')
        ON CONFLICT (owner_schema, canonical_name) DO NOTHING
    $sql$, p_schema, p_schema, p_schema);

    -- ---- maludb_svpor_statement: writable view ---------------------
    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_svpor_statement', 'view');
    EXECUTE format($sql$
        CREATE OR REPLACE VIEW %I.maludb_svpor_statement WITH (security_invoker = true) AS
        SELECT statement_id, subject_kind, subject_id, verb_id, object_kind, object_id,
               predicate_id, valid_from, valid_to, confidence, provenance,
               source_package_id, metadata_jsonb, created_at
          FROM maludb_core.malu$svpor_statement
         WHERE owner_schema = %L
        WITH LOCAL CHECK OPTION
    $sql$, p_schema, p_schema);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON %I.maludb_svpor_statement TO maludb_memory_admin, maludb_memory_executor', p_schema);
    EXECUTE format('GRANT SELECT ON %I.maludb_svpor_statement TO maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_svpor_statement', 'view', 'Schema-local SVPOR statement facade.');
    v_count := v_count + 1;

    -- ---- maludb_svpor_statement_create / close / delete / set_provenance
    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_svpor_statement_create', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_svpor_statement_create(
            p_subject_kind text, p_subject_id bigint, p_verb_id bigint,
            p_object_kind text, p_object_id bigint,
            p_predicate_id bigint DEFAULT NULL,
            p_valid_from timestamptz DEFAULT NULL, p_valid_to timestamptz DEFAULT NULL,
            p_confidence numeric DEFAULT NULL, p_provenance text DEFAULT 'provided',
            p_source_package_id bigint DEFAULT NULL, p_metadata_jsonb jsonb DEFAULT '{}'::jsonb
        ) RETURNS bigint LANGUAGE sql SECURITY INVOKER
        SET search_path = %I, maludb_core, pg_temp
        AS $facade$ SELECT maludb_core.register_svpor_statement(
            p_subject_kind, p_subject_id, p_verb_id, p_object_kind, p_object_id,
            p_predicate_id, p_valid_from, p_valid_to, p_confidence, p_provenance,
            p_source_package_id, p_metadata_jsonb) $facade$
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_svpor_statement_create(text, bigint, bigint, text, bigint, bigint, timestamptz, timestamptz, numeric, text, bigint, jsonb) FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_svpor_statement_create(text, bigint, bigint, text, bigint, bigint, timestamptz, timestamptz, numeric, text, bigint, jsonb) TO maludb_memory_admin, maludb_memory_executor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_svpor_statement_create', 'function', 'Schema-local SVPOR statement writer.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_svpor_statement_close', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_svpor_statement_close(p_statement_id bigint, p_valid_to timestamptz DEFAULT now())
        RETURNS boolean LANGUAGE sql SECURITY INVOKER
        SET search_path = %I, maludb_core, pg_temp
        AS $facade$ SELECT maludb_core.svpor_statement_close(p_statement_id, p_valid_to) $facade$
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_svpor_statement_close(bigint, timestamptz) FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_svpor_statement_close(bigint, timestamptz) TO maludb_memory_admin, maludb_memory_executor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_svpor_statement_close', 'function', 'Schema-local SVPOR statement close (set valid_to).');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_svpor_statement_delete', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_svpor_statement_delete(p_statement_id bigint)
        RETURNS integer LANGUAGE sql SECURITY INVOKER
        SET search_path = %I, maludb_core, pg_temp
        AS $facade$ SELECT maludb_core.svpor_statement_delete(p_statement_id) $facade$
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_svpor_statement_delete(bigint) FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_svpor_statement_delete(bigint) TO maludb_memory_admin, maludb_memory_executor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_svpor_statement_delete', 'function', 'Schema-local SVPOR statement delete.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_svpor_statement_set_provenance', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_svpor_statement_set_provenance(p_statement_id bigint, p_provenance text)
        RETURNS boolean LANGUAGE sql SECURITY INVOKER
        SET search_path = %I, maludb_core, pg_temp
        AS $facade$ SELECT maludb_core.svpor_statement_set_provenance(p_statement_id, p_provenance) $facade$
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_svpor_statement_set_provenance(bigint, text) FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_svpor_statement_set_provenance(bigint, text) TO maludb_memory_admin, maludb_memory_executor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_svpor_statement_set_provenance', 'function', 'Schema-local SVPOR statement provenance edit.');
    v_count := v_count + 1;

    -- ---- maludb_episode: writable list/get/update view -------------
    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_episode', 'view');
    EXECUTE format($sql$
        CREATE OR REPLACE VIEW %I.maludb_episode WITH (security_invoker = true) AS
        SELECT episode_id, episode_kind, title, summary, payload_jsonb,
               occurred_at, occurred_until, recorded_at, sensitivity,
               lifecycle_state, provenance, created_at
          FROM maludb_core.malu$episode_object
         WHERE owner_schema = %L
        WITH LOCAL CHECK OPTION
    $sql$, p_schema, p_schema);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON %I.maludb_episode TO maludb_memory_admin, maludb_memory_executor', p_schema);
    EXECUTE format('GRANT SELECT ON %I.maludb_episode TO maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_episode', 'view', 'Schema-local episode registry facade.');
    v_count := v_count + 1;

    -- ---- maludb_episode_get aggregate ------------------------------
    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_episode_get', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_episode_get(p_episode_id bigint)
        RETURNS jsonb LANGUAGE sql STABLE SECURITY INVOKER
        SET search_path = %I, maludb_core, pg_temp
        AS $facade$ SELECT maludb_core.episode_get(p_episode_id) $facade$
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_episode_get(bigint) FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_episode_get(bigint) TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_episode_get', 'function', 'Schema-local episode aggregate reader.');
    v_count := v_count + 1;

    -- ---- maludb_register_episode: extend with provenance (8-arg) ----
    -- Drop the 7-arg signature emitted by the 0802 facade so the new
    -- definition replaces it instead of living alongside as an overload.
    EXECUTE format('DROP FUNCTION IF EXISTS %I.maludb_register_episode(text, text, text, jsonb, timestamptz, timestamptz, text)', p_schema);
    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_register_episode', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_register_episode(
            p_episode_kind   text,
            p_title          text,
            p_summary        text DEFAULT NULL,
            p_payload_jsonb  jsonb DEFAULT '{}'::jsonb,
            p_occurred_at    timestamptz DEFAULT NULL,
            p_occurred_until timestamptz DEFAULT NULL,
            p_sensitivity    text DEFAULT 'internal',
            p_provenance     text DEFAULT 'provided'
        ) RETURNS bigint
        LANGUAGE plpgsql
        SECURITY INVOKER
        SET search_path = %I, maludb_core, pg_temp
        AS $facade$
        DECLARE
            v_id bigint;
        BEGIN
            v_id := maludb_core.register_episode(
                p_episode_kind, p_title, p_summary, p_payload_jsonb,
                p_occurred_at, p_occurred_until, p_sensitivity);
            IF COALESCE(NULLIF(btrim(p_provenance), ''), 'provided') <> 'provided' THEN
                UPDATE maludb_core.malu$episode_object
                   SET provenance = p_provenance
                 WHERE owner_schema = current_schema()
                   AND episode_id = v_id;
            END IF;
            RETURN v_id;
        END;
        $facade$
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_register_episode(text, text, text, jsonb, timestamptz, timestamptz, text, text) FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_register_episode(text, text, text, jsonb, timestamptz, timestamptz, text, text) TO maludb_memory_admin, maludb_memory_executor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_register_episode', 'function', 'Schema-local search-path-safe episode writer (with provenance).');
    v_count := v_count + 1;

    RETURN v_count;
END;
$body$;

REVOKE ALL ON FUNCTION maludb_core._enable_memory_schema_0820_facade(name) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core._enable_memory_schema_0820_facade(name)
    TO maludb_memory_admin, maludb_memory_executor;

-- ===== 7. wire the 0820 facade into enable_memory_schema ============
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

    FOREACH v_view IN ARRAY ARRAY['maludb_subject','maludb_memory','maludb_skill','maludb_document']::name[]
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

-- ===== 8. fix: register_svpor_* empty-aggregate NULL bug =============
-- The upsert path merged aliases (and verb search_phrases) with
-- array_agg(DISTINCT ...). When both the existing and incoming arrays are
-- empty, array_agg over zero rows returns NULL, which violates the NOT
-- NULL on those columns -- so the SECOND registration of an alias-less
-- subject/verb/predicate failed. Wrap the merge in COALESCE(..., '{}').
-- These are CREATE OR REPLACE of the existing core registrars (signatures
-- and bodies unchanged except the COALESCE), so grants are preserved.

CREATE OR REPLACE FUNCTION maludb_core.register_svpor_subject(
    p_canonical_name text,
    p_aliases        text[] DEFAULT ARRAY[]::text[],
    p_description    text   DEFAULT NULL,
    p_subject_type   text   DEFAULT 'other',
    p_classifier_md  text   DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql
AS $body$
DECLARE
    v_id bigint;
    v_subject_type text := maludb_core._normalize_svpor_subject_type(p_subject_type);
BEGIN
    INSERT INTO maludb_core.malu$svpor_subject (canonical_name, aliases, description, subject_type, classifier_md)
    VALUES (p_canonical_name, COALESCE(p_aliases, ARRAY[]::text[]), p_description, v_subject_type, p_classifier_md)
    ON CONFLICT (owner_schema, canonical_name) DO UPDATE
        SET aliases = COALESCE((
                SELECT array_agg(DISTINCT a)
                FROM unnest(malu$svpor_subject.aliases || COALESCE(EXCLUDED.aliases, ARRAY[]::text[])) AS a
            ), ARRAY[]::text[]),
            description = COALESCE(EXCLUDED.description, malu$svpor_subject.description),
            subject_type = EXCLUDED.subject_type,
            classifier_md = COALESCE(EXCLUDED.classifier_md, malu$svpor_subject.classifier_md)
    RETURNING subject_id INTO v_id;
    RETURN v_id;
END;
$body$;

CREATE OR REPLACE FUNCTION maludb_core.register_svpor_verb(
    p_canonical_name text,
    p_aliases text[] DEFAULT ARRAY[]::text[],
    p_description text DEFAULT NULL,
    p_verb_type text DEFAULT NULL,
    p_search_phrases text[] DEFAULT ARRAY[]::text[],
    p_classifier_md text DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql
AS $body$
DECLARE
    v_id bigint;
    v_verb_type text := maludb_core._normalize_svpor_verb_type(p_verb_type, p_canonical_name);
BEGIN
    INSERT INTO maludb_core.malu$svpor_verb (canonical_name, aliases, description, verb_type, search_phrases, classifier_md)
    VALUES (
        p_canonical_name,
        COALESCE(p_aliases, ARRAY[]::text[]),
        p_description,
        v_verb_type,
        COALESCE(p_search_phrases, ARRAY[]::text[]),
        p_classifier_md
    )
    ON CONFLICT (owner_schema, canonical_name) DO UPDATE
        SET aliases = COALESCE((
                SELECT array_agg(DISTINCT a)
                FROM unnest(malu$svpor_verb.aliases || COALESCE(EXCLUDED.aliases, ARRAY[]::text[])) AS a
            ), ARRAY[]::text[]),
            search_phrases = COALESCE((
                SELECT array_agg(DISTINCT p)
                FROM unnest(malu$svpor_verb.search_phrases || COALESCE(EXCLUDED.search_phrases, ARRAY[]::text[])) AS p
            ), ARRAY[]::text[]),
            description = COALESCE(EXCLUDED.description, malu$svpor_verb.description),
            verb_type = EXCLUDED.verb_type,
            classifier_md = COALESCE(EXCLUDED.classifier_md, malu$svpor_verb.classifier_md)
    RETURNING verb_id INTO v_id;
    RETURN v_id;
END;
$body$;

CREATE OR REPLACE FUNCTION maludb_core.register_svpor_predicate(
    p_canonical_name text,
    p_aliases        text[] DEFAULT ARRAY[]::text[],
    p_description    text   DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql
AS $body$
DECLARE v_id bigint;
BEGIN
    INSERT INTO maludb_core.malu$svpor_predicate (canonical_name, aliases, description)
    VALUES (p_canonical_name, COALESCE(p_aliases, ARRAY[]::text[]), p_description)
    ON CONFLICT (owner_schema, canonical_name) DO UPDATE
        SET aliases     = COALESCE((SELECT array_agg(DISTINCT a)
                           FROM unnest(malu$svpor_predicate.aliases || COALESCE(EXCLUDED.aliases, ARRAY[]::text[])) AS a), ARRAY[]::text[]),
            description = COALESCE(EXCLUDED.description, malu$svpor_predicate.description)
    RETURNING predicate_id INTO v_id;
    RETURN v_id;
END;
$body$;
