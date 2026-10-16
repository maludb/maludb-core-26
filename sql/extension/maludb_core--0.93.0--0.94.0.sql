\echo Use "ALTER EXTENSION maludb_core UPDATE TO '0.94.0'" to load this file. \quit

-- =====================================================================
-- maludb_core 0.93.0 -> 0.94.0
--
-- Episodes become a type of subject ("a standup meeting is an event").
-- The SVPOR subject is the episode's graph identity; malu$episode_object
-- stays as the temporal payload sidecar (indexed occurred_at/occurred_until,
-- payload_jsonb, lifecycle). Decisions locked 2026-06-07:
--
--   1. The minted subject's subject_type is the EPISODE KIND itself
--      ('standup_meeting', 'deployment', ...). Kinds are auto-registered
--      in the global malu$svpor_subject_type picker (system_defined=false)
--      because the type normalizer raises on unknown types.
--   2. Canonical name = '<title> (YYYY-MM-DD)' (UTC date of occurred_at);
--      '<title> [#<episode_id>]' when there is no occurred_at or on a
--      same-day name collision. The raw title is kept as an alias.
--   3. Existing svpor_statement edges and svpor_attribute rows addressed
--      as ('episode_object', id) are REWRITTEN to ('subject', subject_id),
--      merging into pre-existing subject-addressed duplicates (identity
--      index) and re-pointing edge attributes. The CHECK constraints still
--      accept 'episode_object' (no constraint rebuild; ghost endpoints are
--      left untouched).
--   4. BREAKING ingest contract: the episodes[] section is REJECTED with a
--      clear error. Events are subjects[] entries carrying occurred_at /
--      occurred_until (+ optional description); the sidecar is created
--      automatically. Event keys resolve to SUBJECT endpoints in edges[]
--      and may now participate in relationships[]. The report drops the
--      'episode_attributes' counter (event attributes are node attributes).
--
-- Mechanics: a BEFORE INSERT trigger on malu$episode_object mints the
-- subject for EVERY insert path (register_episode, the writable
-- maludb_episode view, the ingest) -- no facade signature changes. An
-- AFTER DELETE trigger removes the subject when the body is deleted
-- directly; deleting the subject (the canonical path) cascades to the
-- body via the new composite tenant FK.
--
-- maludb_episode gains subject_id (writable) + canonical_name (read-only)
-- columns; maludb_episode_with_attributes is rebuilt over the new shape
-- and now bundles the SUBJECT's attributes. episode_get() reads both
-- subject-addressed and legacy episode_object-addressed statements.
-- Upgraded tenant schemas re-run maludb_core.enable_memory_schema() to
-- pick up the new view shape (see section 14 note).
-- =====================================================================

CREATE OR REPLACE FUNCTION maludb_core.maludb_core_version() RETURNS text
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$ SELECT '0.94.0'::text $body$;

-- ---------------------------------------------------------------------
-- 1. _ensure_subject_type_for_kind -- kind-as-type needs the kind in the
--    GLOBAL subject_type picker (the normalizer raises on unknown types).
--    Lazily auto-registers the slugged kind; advisory, system_defined=false.
-- ---------------------------------------------------------------------
CREATE FUNCTION maludb_core._ensure_subject_type_for_kind(p_kind text) RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
DECLARE
    v_slug text := COALESCE(maludb_core._svpor_slug(p_kind), 'event');
BEGIN
    INSERT INTO maludb_core.malu$svpor_subject_type
        (subject_type, display_name, description, sort_order, system_defined)
    VALUES (v_slug,
            initcap(replace(v_slug, '_', ' ')),
            'Event kind (auto-registered from an episode kind).',
            500, false)
    ON CONFLICT (subject_type) DO NOTHING;
    RETURN v_slug;
END;
$body$;
REVOKE ALL ON FUNCTION maludb_core._ensure_subject_type_for_kind(text) FROM PUBLIC;

-- ---------------------------------------------------------------------
-- 2. The episode body gains its subject identity. Composite tenant FK so
--    an episode can never point at another schema's subject; CASCADE so
--    deleting the subject (the canonical delete path, via maludb_subject)
--    removes the episode body, whose own CASCADEs clear MDO children.
-- ---------------------------------------------------------------------
ALTER TABLE maludb_core.malu$episode_object
    ADD COLUMN subject_id bigint;

ALTER TABLE maludb_core.malu$episode_object
    ADD CONSTRAINT malu$episode_object_subject_fk
    FOREIGN KEY (owner_schema, subject_id)
    REFERENCES maludb_core.malu$svpor_subject(owner_schema, subject_id)
    ON DELETE CASCADE;

CREATE INDEX malu$episode_subject_idx
    ON maludb_core.malu$episode_object(subject_id)
    WHERE subject_id IS NOT NULL;

-- ---------------------------------------------------------------------
-- 3. Canonical-name builder. UTC-pinned so the name does not depend on
--    the session timezone.
-- ---------------------------------------------------------------------
CREATE FUNCTION maludb_core._episode_subject_name(
    p_title       text,
    p_occurred_at timestamptz,
    p_episode_id  bigint
) RETURNS text
LANGUAGE sql STABLE
AS $body$
    SELECT btrim(p_title) ||
           CASE WHEN p_occurred_at IS NOT NULL
                THEN ' (' || to_char(p_occurred_at AT TIME ZONE 'UTC', 'YYYY-MM-DD') || ')'
                ELSE ' [#' || p_episode_id || ']'
           END
$body$;
REVOKE ALL ON FUNCTION maludb_core._episode_subject_name(text, timestamptz, bigint) FROM PUBLIC;

-- ---------------------------------------------------------------------
-- 4. BEFORE INSERT: mint the event subject for every insert path.
--    SECURITY DEFINER with explicit NEW.owner_schema (never
--    current_schema()) so the ingest's explicit-owner inserts stay
--    correctly scoped. A caller-supplied subject_id (restore, backfill)
--    is respected.
-- ---------------------------------------------------------------------
CREATE FUNCTION maludb_core._episode_subject_mint() RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
DECLARE
    v_type text;
    v_name text;
BEGIN
    IF NEW.subject_id IS NOT NULL THEN
        RETURN NEW;
    END IF;

    v_type := maludb_core._ensure_subject_type_for_kind(NEW.episode_kind);
    v_name := maludb_core._episode_subject_name(NEW.title, NEW.occurred_at, NEW.episode_id);

    BEGIN
        INSERT INTO maludb_core.malu$svpor_subject
            (owner_schema, canonical_name, aliases, description, subject_type)
        VALUES (NEW.owner_schema, v_name, ARRAY[btrim(NEW.title)], NEW.summary, v_type)
        RETURNING subject_id INTO NEW.subject_id;
    EXCEPTION WHEN unique_violation THEN
        -- Same-titled event on the same date: keep per-occurrence identity.
        INSERT INTO maludb_core.malu$svpor_subject
            (owner_schema, canonical_name, aliases, description, subject_type)
        VALUES (NEW.owner_schema,
                maludb_core._episode_subject_name(NEW.title, NULL, NEW.episode_id),
                ARRAY[btrim(NEW.title)], NEW.summary, v_type)
        RETURNING subject_id INTO NEW.subject_id;
    END;
    RETURN NEW;
END;
$body$;
REVOKE ALL ON FUNCTION maludb_core._episode_subject_mint() FROM PUBLIC;

CREATE TRIGGER malu$episode_subject_mint
    BEFORE INSERT ON maludb_core.malu$episode_object
    FOR EACH ROW EXECUTE FUNCTION maludb_core._episode_subject_mint();

-- ---------------------------------------------------------------------
-- 5. AFTER DELETE: a direct body delete (writable maludb_episode view)
--    removes the subject identity too. When the delete CAME from the
--    subject cascade the subject row is already gone (0-row no-op). If
--    other FKs still pin the subject (e.g. relationship edges), leave it
--    as a surviving graph entity and warn.
-- ---------------------------------------------------------------------
CREATE FUNCTION maludb_core._episode_subject_cleanup() RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
BEGIN
    IF OLD.subject_id IS NOT NULL THEN
        BEGIN
            DELETE FROM maludb_core.malu$svpor_subject
             WHERE owner_schema = OLD.owner_schema
               AND subject_id   = OLD.subject_id;
        EXCEPTION WHEN foreign_key_violation THEN
            RAISE WARNING 'maludb: event subject % kept (still referenced); episode body % removed',
                OLD.subject_id, OLD.episode_id;
        END;
    END IF;
    RETURN OLD;
END;
$body$;
REVOKE ALL ON FUNCTION maludb_core._episode_subject_cleanup() FROM PUBLIC;

CREATE TRIGGER malu$episode_subject_cleanup
    AFTER DELETE ON maludb_core.malu$episode_object
    FOR EACH ROW EXECUTE FUNCTION maludb_core._episode_subject_cleanup();

-- ---------------------------------------------------------------------
-- 6. Backfill: mint event subjects for pre-0.94.0 episodes. Direct
--    INSERT preserving each row's owner_schema.
-- ---------------------------------------------------------------------
DO $do$
DECLARE
    r      record;
    v_sid  bigint;
    v_type text;
BEGIN
    FOR r IN SELECT episode_id, owner_schema, episode_kind, title, summary, occurred_at
               FROM maludb_core.malu$episode_object
              WHERE subject_id IS NULL
              ORDER BY episode_id
    LOOP
        v_type := maludb_core._ensure_subject_type_for_kind(r.episode_kind);
        BEGIN
            INSERT INTO maludb_core.malu$svpor_subject
                (owner_schema, canonical_name, aliases, description, subject_type)
            VALUES (r.owner_schema,
                    maludb_core._episode_subject_name(r.title, r.occurred_at, r.episode_id),
                    ARRAY[btrim(r.title)], r.summary, v_type)
            RETURNING subject_id INTO v_sid;
        EXCEPTION WHEN unique_violation THEN
            INSERT INTO maludb_core.malu$svpor_subject
                (owner_schema, canonical_name, aliases, description, subject_type)
            VALUES (r.owner_schema,
                    maludb_core._episode_subject_name(r.title, NULL, r.episode_id),
                    ARRAY[btrim(r.title)], r.summary, v_type)
            RETURNING subject_id INTO v_sid;
        END;

        UPDATE maludb_core.malu$episode_object
           SET subject_id = v_sid
         WHERE episode_id = r.episode_id;
    END LOOP;
END
$do$;

-- ---------------------------------------------------------------------
-- 7. Seed the subject_type picker from every kind already in use.
-- ---------------------------------------------------------------------
DO $do$
DECLARE r record;
BEGIN
    FOR r IN SELECT DISTINCT episode_type AS kind FROM maludb_core.malu$episode_type
              UNION
             SELECT DISTINCT episode_kind FROM maludb_core.malu$episode_object
    LOOP
        PERFORM maludb_core._ensure_subject_type_for_kind(r.kind);
    END LOOP;
END
$do$;

-- ---------------------------------------------------------------------
-- 8. Rewrite svpor_statement endpoints: ('episode_object', episode_id)
--    -> ('subject', subject_id). On identity collision with an existing
--    subject-addressed assertion, merge metadata/temporal fields, re-point
--    edge attributes to the survivor, and drop the duplicate. Ghost
--    endpoints (no live episode) are left untouched.
-- ---------------------------------------------------------------------
DO $do$
DECLARE
    r      record;
    a      record;
    v_sk   text;  v_si bigint;
    v_ok   text;  v_oi bigint;
    v_surv bigint;
BEGIN
    FOR r IN SELECT s.*
               FROM maludb_core.malu$svpor_statement s
              WHERE s.subject_kind = 'episode_object'
                 OR s.object_kind  = 'episode_object'
              ORDER BY s.statement_id
    LOOP
        v_sk := r.subject_kind;  v_si := r.subject_id;
        v_ok := r.object_kind;   v_oi := r.object_id;

        IF v_sk = 'episode_object' THEN
            SELECT e.subject_id INTO v_si
              FROM maludb_core.malu$episode_object e
             WHERE e.owner_schema = r.owner_schema
               AND e.episode_id   = r.subject_id
               AND e.subject_id IS NOT NULL;
            IF v_si IS NULL THEN CONTINUE; END IF;
            v_sk := 'subject';
        END IF;
        IF v_ok = 'episode_object' THEN
            SELECT e.subject_id INTO v_oi
              FROM maludb_core.malu$episode_object e
             WHERE e.owner_schema = r.owner_schema
               AND e.episode_id   = r.object_id
               AND e.subject_id IS NOT NULL;
            IF v_oi IS NULL THEN CONTINUE; END IF;
            v_ok := 'subject';
        END IF;

        BEGIN
            UPDATE maludb_core.malu$svpor_statement
               SET subject_kind = v_sk, subject_id = v_si,
                   object_kind  = v_ok, object_id  = v_oi
             WHERE statement_id = r.statement_id;
        EXCEPTION WHEN unique_violation THEN
            SELECT t.statement_id INTO v_surv
              FROM maludb_core.malu$svpor_statement t
             WHERE t.owner_schema = r.owner_schema
               AND t.subject_kind = v_sk AND t.subject_id = v_si
               AND t.verb_id      = r.verb_id
               AND t.object_kind  = v_ok AND t.object_id  = v_oi;

            UPDATE maludb_core.malu$svpor_statement t
               SET metadata_jsonb = r.metadata_jsonb || t.metadata_jsonb,
                   confidence     = COALESCE(t.confidence, r.confidence),
                   valid_from     = COALESCE(t.valid_from, r.valid_from),
                   valid_to       = COALESCE(t.valid_to,   r.valid_to)
             WHERE t.statement_id = v_surv;

            FOR a IN SELECT attribute_id
                       FROM maludb_core.malu$svpor_attribute
                      WHERE owner_schema = r.owner_schema
                        AND target_kind  = 'svpor_statement'
                        AND target_id    = r.statement_id
            LOOP
                BEGIN
                    UPDATE maludb_core.malu$svpor_attribute
                       SET target_id = v_surv
                     WHERE attribute_id = a.attribute_id;
                EXCEPTION WHEN unique_violation THEN
                    DELETE FROM maludb_core.malu$svpor_attribute
                     WHERE attribute_id = a.attribute_id;
                END;
            END LOOP;

            DELETE FROM maludb_core.malu$svpor_statement
             WHERE statement_id = r.statement_id;
        END;
    END LOOP;
END
$do$;

-- ---------------------------------------------------------------------
-- 9. Rewrite node attributes: ('episode_object', episode_id) ->
--    ('subject', subject_id). On (target, attr_name) collision the
--    subject's existing value wins and the episode-targeted row is
--    dropped.
-- ---------------------------------------------------------------------
DO $do$
DECLARE
    r     record;
    v_sid bigint;
BEGIN
    FOR r IN SELECT a.attribute_id, a.owner_schema, a.target_id
               FROM maludb_core.malu$svpor_attribute a
              WHERE a.target_kind = 'episode_object'
              ORDER BY a.attribute_id
    LOOP
        SELECT e.subject_id INTO v_sid
          FROM maludb_core.malu$episode_object e
         WHERE e.owner_schema = r.owner_schema
           AND e.episode_id   = r.target_id
           AND e.subject_id IS NOT NULL;
        IF v_sid IS NULL THEN CONTINUE; END IF;

        BEGIN
            UPDATE maludb_core.malu$svpor_attribute
               SET target_kind = 'subject', target_id = v_sid
             WHERE attribute_id = r.attribute_id;
        EXCEPTION WHEN unique_violation THEN
            DELETE FROM maludb_core.malu$svpor_attribute
             WHERE attribute_id = r.attribute_id;
        END;
    END LOOP;
END
$do$;

-- ---------------------------------------------------------------------
-- 10. episode_get reads both addressing forms and exposes the identity.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION maludb_core.episode_get(p_episode_id bigint)
RETURNS jsonb
LANGUAGE sql STABLE SECURITY INVOKER
AS $body$
    SELECT jsonb_build_object(
        'episode', to_jsonb(e),
        'subject', (SELECT jsonb_build_object(
                        'subject_id',     s.subject_id,
                        'canonical_name', s.canonical_name,
                        'subject_type',   s.subject_type)
                      FROM maludb_core.malu$svpor_subject s
                     WHERE s.owner_schema = e.owner_schema
                       AND s.subject_id   = e.subject_id),
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
               AND ((s.subject_kind = 'subject'        AND s.subject_id = e.subject_id)
                 OR (s.object_kind  = 'subject'        AND s.object_id  = e.subject_id)
                 OR (s.subject_kind = 'episode_object' AND s.subject_id = e.episode_id)
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

-- ---------------------------------------------------------------------
-- 11. Ingest rework (BREAKING). episodes[] is rejected; events are
--     subjects[] entries with occurred_at / occurred_until. The sidecar
--     is created automatically (the mint trigger supplies the subject);
--     dedup stays (kind, title, occurred_at). Event keys resolve to
--     SUBJECT endpoints, so they work in edges[] AND relationships[].
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION maludb_core._memory_ingest_extraction_for_schema(
    p_owner_schema name,
    p_extraction   jsonb,
    p_source_kind  text   DEFAULT 'document',
    p_source_id    bigint DEFAULT NULL,
    p_provenance   text   DEFAULT 'accepted'
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
DECLARE
    v_prov         text := COALESCE(NULLIF(btrim(p_provenance), ''), 'accepted');
    v_src_kind     text := lower(btrim(COALESCE(p_source_kind, '')));
    v_src_id       bigint := p_source_id;
    v_doc          jsonb;
    v_ids          jsonb := '{}'::jsonb;   -- key -> id
    v_kinds        jsonb := '{}'::jsonb;   -- key -> kind
    v_skipped      jsonb := '[]'::jsonb;
    r              record;
    v_key          text;
    v_name         text;
    v_type         text;
    v_occ          timestamptz;
    v_occu         timestamptz;
    v_id           bigint;
    -- counters
    c_subj_c integer := 0; c_subj_r integer := 0;
    c_verb_c integer := 0; c_verb_r integer := 0;
    c_epi_c  integer := 0; c_epi_r  integer := 0;
    c_edges  integer := 0; c_rels   integer := 0;
    c_nattr  integer := 0; c_eattr  integer := 0;
    -- edge resolution
    v_sk text; v_si bigint; v_ok text; v_oi bigint; v_vid bigint; v_stmt bigint;
    v_ref text; v_okind text;
BEGIN
    PERFORM maludb_core._memory_schema_assert_manageable(p_owner_schema);

    IF p_extraction IS NULL OR jsonb_typeof(p_extraction) <> 'object' THEN
        RAISE EXCEPTION 'memory_ingest_extraction: p_extraction must be a JSON object'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;
    IF v_prov NOT IN ('provided','suggested','accepted','rejected') THEN
        RAISE EXCEPTION 'memory_ingest_extraction: bad provenance %', v_prov
            USING ERRCODE = 'invalid_parameter_value';
    END IF;
    -- BREAKING (0.94.0): fail fast so a stale extractor cannot silently
    -- drop its events.
    IF p_extraction ? 'episodes' THEN
        RAISE EXCEPTION 'memory_ingest_extraction: the episodes[] section was removed in 0.94.0; emit events as subjects[] entries with occurred_at/occurred_until (see docs/memory-extraction-json-contract.md)'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    -- ---- source anchor: create the document, or use the passed source -----
    v_doc := p_extraction -> 'document';
    IF v_doc IS NOT NULL AND jsonb_typeof(v_doc) = 'object' THEN
        v_src_id := maludb_core._upload_document_for_schema(
            p_owner_schema,
            v_doc ->> 'title',
            v_doc ->> 'content_text',
            COALESCE(NULLIF(v_doc ->> 'source_type', ''), 'document'),
            CASE WHEN jsonb_typeof(v_doc -> 'content_jsonb') = 'object' THEN v_doc -> 'content_jsonb' ELSE NULL END,
            v_doc ->> 'media_type',
            ARRAY[]::text[], ARRAY[]::text[], ARRAY[]::text[], ARRAY[]::text[],
            COALESCE(v_doc -> 'metadata', '{}'::jsonb),
            v_doc ->> 'document_type');
        v_src_kind := 'document';
    END IF;

    -- ---- subjects (entities AND events) ------------------------------------
    FOR r IN SELECT val, (ord - 1) AS idx
               FROM jsonb_array_elements(COALESCE(p_extraction -> 'subjects', '[]'::jsonb)) WITH ORDINALITY AS t(val, ord)
    LOOP
        BEGIN
            v_key  := r.val ->> 'key';
            v_name := btrim(COALESCE(r.val ->> 'name', ''));
            v_type := NULLIF(btrim(COALESCE(r.val ->> 'type', '')), '');
            v_occ  := (r.val ->> 'occurred_at')::timestamptz;
            v_occu := (r.val ->> 'occurred_until')::timestamptz;
            IF COALESCE(btrim(v_key), '') = '' OR v_name = '' THEN
                v_skipped := v_skipped || jsonb_build_object('section','subjects','index',r.idx,'reason','missing key or name');
                CONTINUE;
            END IF;

            IF v_occ IS NOT NULL OR v_occu IS NOT NULL THEN
                -- Events resolve by EXACT canonical name (the extractor
                -- reusing the dated KNOWN_SUBJECTS name) or by the dedup
                -- triple (kind, title, occurred_at) -- NEVER by alias:
                -- recurring titles ("Daily standup") alias many distinct
                -- occurrences, and an alias hit would swallow new ones.
                SELECT subject_id INTO v_id
                  FROM maludb_core.malu$svpor_subject
                 WHERE owner_schema = p_owner_schema
                   AND canonical_name = v_name;
                IF v_id IS NULL THEN
                    SELECT e.subject_id INTO v_id
                      FROM maludb_core.malu$episode_object e
                     WHERE e.owner_schema = p_owner_schema
                       AND e.episode_kind = COALESCE(v_type, 'event')
                       AND e.title = v_name
                       AND e.occurred_at IS NOT DISTINCT FROM v_occ
                       AND e.subject_id IS NOT NULL;
                    IF v_id IS NOT NULL THEN
                        c_epi_r := c_epi_r + 1;
                    END IF;
                END IF;
            ELSE
                SELECT subject_id INTO v_id
                  FROM maludb_core.malu$svpor_subject
                 WHERE owner_schema = p_owner_schema
                   AND (canonical_name = v_name OR v_name = ANY(aliases))
                 ORDER BY (canonical_name = v_name) DESC
                 LIMIT 1;
            END IF;

            IF v_id IS NULL THEN
                IF v_occ IS NOT NULL OR v_occu IS NOT NULL THEN
                    -- event: the sidecar insert mints the subject identity
                    INSERT INTO maludb_core.malu$episode_object
                        (owner_schema, episode_kind, title, summary, occurred_at, occurred_until)
                    VALUES (p_owner_schema, COALESCE(v_type, 'event'), v_name,
                            r.val ->> 'description', v_occ, v_occu)
                    RETURNING subject_id INTO v_id;
                    c_epi_c := c_epi_c + 1;
                ELSE
                    INSERT INTO maludb_core.malu$svpor_subject (owner_schema, canonical_name, subject_type, aliases)
                    VALUES (p_owner_schema, v_name,
                            maludb_core._normalize_svpor_subject_type(COALESCE(v_type, 'other')),
                            CASE WHEN jsonb_typeof(r.val -> 'aliases') = 'array'
                                 THEN ARRAY(SELECT jsonb_array_elements_text(r.val -> 'aliases')) ELSE ARRAY[]::text[] END)
                    RETURNING subject_id INTO v_id;
                END IF;
                c_subj_c := c_subj_c + 1;
                IF (v_occ IS NOT NULL OR v_occu IS NOT NULL)
                   AND jsonb_typeof(r.val -> 'aliases') = 'array' THEN
                    UPDATE maludb_core.malu$svpor_subject s
                       SET aliases = (SELECT array_agg(DISTINCT a)
                                        FROM unnest(s.aliases || ARRAY(SELECT jsonb_array_elements_text(r.val -> 'aliases'))) a)
                     WHERE s.owner_schema = p_owner_schema AND s.subject_id = v_id;
                END IF;
            ELSE
                IF jsonb_typeof(r.val -> 'aliases') = 'array' THEN
                    UPDATE maludb_core.malu$svpor_subject s
                       SET aliases = (SELECT array_agg(DISTINCT a)
                                        FROM unnest(s.aliases || ARRAY(SELECT jsonb_array_elements_text(r.val -> 'aliases'))) a)
                     WHERE s.owner_schema = p_owner_schema AND s.subject_id = v_id;
                END IF;
                c_subj_r := c_subj_r + 1;
            END IF;

            c_nattr := c_nattr + maludb_core._memory_apply_attributes_for_schema(
                           p_owner_schema, 'subject', v_id, r.val -> 'attributes', v_prov);

            -- external ref pointer (sugar) -> a single reference attribute
            IF jsonb_typeof(r.val -> 'ref') = 'object' THEN
                c_nattr := c_nattr + maludb_core._memory_apply_attributes_for_schema(
                    p_owner_schema, 'subject', v_id,
                    jsonb_build_array(jsonb_build_object(
                        'attr_name', 'external_ref',
                        'value_text', COALESCE(r.val -> 'ref' ->> 'key', v_name),
                        'ref_source', r.val -> 'ref' ->> 'source',
                        'ref_entity', r.val -> 'ref' ->> 'entity',
                        'ref_key',    r.val -> 'ref' ->> 'key')),
                    v_prov);
            END IF;

            v_ids   := jsonb_set(v_ids,   ARRAY[v_key], to_jsonb(v_id));
            v_kinds := jsonb_set(v_kinds, ARRAY[v_key], to_jsonb('subject'::text));
        EXCEPTION WHEN OTHERS THEN
            v_skipped := v_skipped || jsonb_build_object('section','subjects','index',r.idx,'reason',left(SQLERRM,300));
        END;
    END LOOP;

    -- ---- verbs (explicit registration; edges also auto-create) ------------
    FOR r IN SELECT val, (ord - 1) AS idx
               FROM jsonb_array_elements(COALESCE(p_extraction -> 'verbs', '[]'::jsonb)) WITH ORDINALITY AS t(val, ord)
    LOOP
        BEGIN
            v_name := btrim(COALESCE(r.val ->> 'name', ''));
            IF v_name = '' THEN
                v_skipped := v_skipped || jsonb_build_object('section','verbs','index',r.idx,'reason','missing name');
                CONTINUE;
            END IF;
            SELECT verb_id INTO v_id FROM maludb_core.malu$svpor_verb
             WHERE owner_schema = p_owner_schema AND canonical_name = v_name;
            IF v_id IS NULL THEN
                INSERT INTO maludb_core.malu$svpor_verb (owner_schema, canonical_name, verb_type, aliases, description)
                VALUES (p_owner_schema, v_name,
                        maludb_core._normalize_svpor_verb_type(NULLIF(btrim(r.val ->> 'type'), ''), v_name),
                        CASE WHEN jsonb_typeof(r.val -> 'aliases') = 'array'
                             THEN ARRAY(SELECT jsonb_array_elements_text(r.val -> 'aliases')) ELSE ARRAY[]::text[] END,
                        r.val ->> 'description')
                RETURNING verb_id INTO v_id;
                c_verb_c := c_verb_c + 1;
            ELSE
                c_verb_r := c_verb_r + 1;
            END IF;
        EXCEPTION WHEN OTHERS THEN
            v_skipped := v_skipped || jsonb_build_object('section','verbs','index',r.idx,'reason',left(SQLERRM,300));
        END;
    END LOOP;

    -- ---- edges (verb-typed SVO statements) --------------------------------
    FOR r IN SELECT val, (ord - 1) AS idx
               FROM jsonb_array_elements(COALESCE(p_extraction -> 'edges', '[]'::jsonb)) WITH ORDINALITY AS t(val, ord)
    LOOP
        BEGIN
            -- subject endpoint
            v_ref := COALESCE(r.val ->> 'subject', '$source');
            IF v_ref = '$source' THEN
                v_sk := v_src_kind; v_si := v_src_id;
            ELSIF v_ids ? v_ref THEN
                v_sk := v_kinds ->> v_ref; v_si := (v_ids ->> v_ref)::bigint;
            ELSE
                v_sk := NULL; v_si := NULL;
            END IF;

            -- object endpoint (default $source)
            v_ref := COALESCE(r.val ->> 'object', '$source');
            IF v_ref = '$source' THEN
                v_ok := v_src_kind; v_oi := v_src_id;
            ELSIF v_ids ? v_ref THEN
                v_ok := v_kinds ->> v_ref; v_oi := (v_ids ->> v_ref)::bigint;
            ELSE
                v_ok := NULL; v_oi := NULL;
            END IF;

            IF v_si IS NULL OR v_oi IS NULL THEN
                v_skipped := v_skipped || jsonb_build_object('section','edges','index',r.idx,
                    'reason','unresolved endpoint (unknown key or no source anchor)');
                CONTINUE;
            END IF;

            v_name := btrim(COALESCE(r.val ->> 'verb', ''));
            IF v_name = '' THEN
                v_skipped := v_skipped || jsonb_build_object('section','edges','index',r.idx,'reason','missing verb');
                CONTINUE;
            END IF;
            SELECT verb_id INTO v_vid FROM maludb_core.malu$svpor_verb
             WHERE owner_schema = p_owner_schema AND (canonical_name = v_name OR v_name = ANY(aliases))
             ORDER BY (canonical_name = v_name) DESC LIMIT 1;
            IF v_vid IS NULL THEN
                INSERT INTO maludb_core.malu$svpor_verb (owner_schema, canonical_name)
                VALUES (p_owner_schema, v_name) RETURNING verb_id INTO v_vid;
                c_verb_c := c_verb_c + 1;
            END IF;

            INSERT INTO maludb_core.malu$svpor_statement
                (owner_schema, subject_kind, subject_id, verb_id, object_kind, object_id,
                 valid_from, valid_to, confidence, provenance, metadata_jsonb)
            VALUES
                (p_owner_schema, v_sk, v_si, v_vid, v_ok, v_oi,
                 (r.val ->> 'valid_from')::timestamptz, (r.val ->> 'valid_to')::timestamptz,
                 (r.val ->> 'confidence')::numeric, v_prov,
                 jsonb_strip_nulls(jsonb_build_object('source_span', NULLIF(btrim(COALESCE(r.val ->> 'source_span','')), ''))))
            ON CONFLICT (owner_schema, subject_kind, subject_id, verb_id, object_kind, object_id)
            DO UPDATE SET
                confidence     = COALESCE(EXCLUDED.confidence, malu$svpor_statement.confidence),
                provenance     = EXCLUDED.provenance,
                valid_from     = COALESCE(EXCLUDED.valid_from, malu$svpor_statement.valid_from),
                valid_to       = COALESCE(EXCLUDED.valid_to,   malu$svpor_statement.valid_to),
                metadata_jsonb = malu$svpor_statement.metadata_jsonb || EXCLUDED.metadata_jsonb
            RETURNING statement_id INTO v_stmt;

            c_edges := c_edges + 1;
            c_eattr := c_eattr + maludb_core._memory_apply_attributes_for_schema(
                           p_owner_schema, 'svpor_statement', v_stmt, r.val -> 'attributes', v_prov);
        EXCEPTION WHEN OTHERS THEN
            v_skipped := v_skipped || jsonb_build_object('section','edges','index',r.idx,'reason',left(SQLERRM,300));
        END;
    END LOOP;

    -- ---- relationships (subject<->subject directed/temporal layer) --------
    FOR r IN SELECT val, (ord - 1) AS idx
               FROM jsonb_array_elements(COALESCE(p_extraction -> 'relationships', '[]'::jsonb)) WITH ORDINALITY AS t(val, ord)
    LOOP
        BEGIN
            v_ref  := r.val ->> 'from';
            v_okind:= r.val ->> 'to';
            v_name := btrim(COALESCE(r.val ->> 'relationship_type', ''));
            IF NOT (v_ids ? COALESCE(v_ref,'')) OR NOT (v_ids ? COALESCE(v_okind,'')) OR v_name = '' THEN
                v_skipped := v_skipped || jsonb_build_object('section','relationships','index',r.idx,'reason','unknown from/to key or missing relationship_type');
                CONTINUE;
            END IF;
            IF (v_kinds ->> v_ref) <> 'subject' OR (v_kinds ->> v_okind) <> 'subject' THEN
                v_skipped := v_skipped || jsonb_build_object('section','relationships','index',r.idx,'reason','relationship endpoints must be subjects');
                CONTINUE;
            END IF;
            v_si := (v_ids ->> v_ref)::bigint;
            v_oi := (v_ids ->> v_okind)::bigint;

            -- The directed subject-relationship edge stores relationship_type as
            -- free text in the live schema (no per-schema relationship_type FK);
            -- labels are NOT NULL, so resolve them from the subjects.
            INSERT INTO maludb_core.malu$svpor_subject_relationship_edge
                (owner_schema, from_subject_id, to_subject_id, from_subject_label, to_subject_label,
                 relationship_type, valid_from, valid_to)
            VALUES (p_owner_schema, v_si, v_oi,
                    (SELECT canonical_name FROM maludb_core.malu$svpor_subject WHERE owner_schema=p_owner_schema AND subject_id=v_si),
                    (SELECT canonical_name FROM maludb_core.malu$svpor_subject WHERE owner_schema=p_owner_schema AND subject_id=v_oi),
                    v_name, (r.val ->> 'valid_from')::timestamptz, (r.val ->> 'valid_to')::timestamptz);
            c_rels := c_rels + 1;
        EXCEPTION WHEN OTHERS THEN
            v_skipped := v_skipped || jsonb_build_object('section','relationships','index',r.idx,'reason',left(SQLERRM,300));
        END;
    END LOOP;

    RETURN jsonb_build_object(
        'source',   jsonb_strip_nulls(jsonb_build_object('kind', v_src_kind, 'id', v_src_id)),
        'created',  jsonb_build_object('subjects', c_subj_c, 'verbs', c_verb_c, 'episodes', c_epi_c,
                                       'edges', c_edges, 'relationships', c_rels,
                                       'node_attributes', c_nattr, 'edge_attributes', c_eattr),
        'resolved', jsonb_build_object('subjects', c_subj_r, 'verbs', c_verb_r, 'episodes', c_epi_r),
        'ids',      v_ids,
        'skipped',  v_skipped);
END;
$body$;

-- ---------------------------------------------------------------------
-- 12. 0.94.0 schema-local facade builder: maludb_episode gains
--     subject_id (writable) + canonical_name (read-only expression);
--     maludb_episode_with_attributes is rebuilt over the new shape and
--     bundles the SUBJECT's attributes (where event attributes now live).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION maludb_core._enable_memory_schema_0940_facade(p_schema name) RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
DECLARE
    v_count integer := 0;
BEGIN
    PERFORM maludb_core._memory_schema_assert_manageable(p_schema);

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_episode', 'view');
    EXECUTE format($sql$
        CREATE OR REPLACE VIEW %I.maludb_episode WITH (security_invoker = true) AS
        SELECT e.episode_id, e.episode_kind, e.title, e.summary, e.payload_jsonb,
               e.occurred_at, e.occurred_until, e.recorded_at, e.sensitivity,
               e.lifecycle_state, e.provenance, e.created_at,
               e.subject_id,
               (SELECT s.canonical_name
                  FROM maludb_core.malu$svpor_subject s
                 WHERE s.owner_schema = e.owner_schema
                   AND s.subject_id   = e.subject_id) AS canonical_name
          FROM maludb_core.malu$episode_object e
         WHERE e.owner_schema = %L
        WITH LOCAL CHECK OPTION
    $sql$, p_schema, p_schema);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON %I.maludb_episode TO maludb_memory_admin, maludb_memory_executor', p_schema);
    EXECUTE format('GRANT SELECT ON %I.maludb_episode TO maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_episode', 'view', 'Schema-local episode registry facade (event subject identity + temporal body).');
    v_count := v_count + 1;

    -- Rebuild so b.* picks up the new columns (CREATE OR REPLACE cannot
    -- reorder the trailing attributes column).
    EXECUTE format('DROP VIEW IF EXISTS %I.maludb_episode_with_attributes', p_schema);
    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_episode_with_attributes', 'view');
    EXECUTE format($sql$
        CREATE VIEW %I.maludb_episode_with_attributes WITH (security_invoker = true) AS
        SELECT b.*, maludb_core.attributes_jsonb('subject', b.subject_id) AS attributes
          FROM %I.maludb_episode b
    $sql$, p_schema, p_schema);
    EXECUTE format('GRANT SELECT ON %I.maludb_episode_with_attributes TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_episode_with_attributes', 'view', 'Episodes with their event subject''s attributes bundled.');
    v_count := v_count + 1;

    RETURN v_count;
END;
$body$;

REVOKE ALL ON FUNCTION maludb_core._enable_memory_schema_0940_facade(name) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core._enable_memory_schema_0940_facade(name)
    TO maludb_memory_admin, maludb_memory_executor;

-- ---------------------------------------------------------------------
-- 13. Wire the 0940 facade into enable_memory_schema. maludb_episode and
--     maludb_episode_with_attributes join the drop-first list: the 0820 /
--     0840 builders emit the pre-0.94 column sets and CREATE OR REPLACE
--     cannot drop or reorder view columns.
-- ---------------------------------------------------------------------
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

    FOREACH v_view IN ARRAY ARRAY['maludb_subject','maludb_memory','maludb_skill','maludb_document','maludb_svpor_attribute','maludb_episode','maludb_episode_with_attributes']::name[]
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
    v_count := v_count + maludb_core._enable_memory_schema_0900_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_0910_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_0920_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_0940_facade(p_schema);
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

-- ---------------------------------------------------------------------
-- 14. NOTE: tenant facades are NOT auto-refreshed here. An extension
--     script cannot drop/replace tenant-schema objects (they are not
--     extension members), so — per the established convention — each
--     memory-enabled schema picks up the new maludb_episode view shape
--     (subject_id + canonical_name) by re-running
--     maludb_core.enable_memory_schema(). The table-level fold (mint
--     trigger, backfill, edge/attribute rewrite, ingest behavior) is
--     fully active immediately after this migration regardless.
-- ---------------------------------------------------------------------
