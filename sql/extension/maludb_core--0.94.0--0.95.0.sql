\echo Use "ALTER EXTENSION maludb_core UPDATE TO '0.95.0'" to load this file. \quit

-- =====================================================================
-- maludb_core 0.94.0 -> 0.95.0  --  the "semantic spine"
--
-- Entity-level similarity: subjects, verbs and edges (SVO statements)
-- become the vector layer. Their embeddings are rendered from MERGED
-- database state (canonical name + type + aliases + accreted attributes)
-- by deterministic in-DB "card" functions and embedded by an EXTERNAL
-- worker (the DB never computes embeddings) via a trigger-fed dirty
-- queue. Vectors land in the existing-but-never-populated 0.86.0
-- object-embedding rail (malu$object_embedding + semantic_search), which
-- was designed for exactly this: vector hit -> (object_kind, object_id)
-- -> graph traversal. Decisions locked 2026-06-07:
--
--   1. The chunk-compartment rail (malu$vector_compartment/_chunk +
--      maludb_memory_search) is FROZEN: kept installed and answering
--      over existing data, no span-backfill worker will be built, and
--      docs mark it deprecated. Entity/edge cards are THE vector layer.
--   2. The extraction JSON contract does NOT change. An extractor-
--      computed vector is a MENTION embedding (one document's view,
--      stale on the next attribute accretion); entity vectors must be
--      re-rendered from merged state, so ingest writes simply mark the
--      dirty queue via triggers and the worker re-embeds.
--   3. Similarity jumps are MATERIALIZED and OPT-IN: worker-maintained
--      top-k rows in malu$semantic_edge surface as a new arm of
--      malu$edge_unified (rel 'similar_to' / 'similar_statement'), but
--      uedge_neighbors/uedge_walk traverse them ONLY when the caller
--      names them in p_rel_filter. A NULL/empty rel_filter keeps every
--      existing structural walk bit-identical.
--   4. Gap fix: malu$svpor_subject_relationship_edge (where the 0.92.0
--      ingest writes relationships[]) was never added to
--      malu$edge_unified -- ingested relationships were invisible to
--      walks. It becomes arm 3 of the view.
--   5. Verbatim-recall compensation: the statement upsert now ACCRETES
--      metadata_jsonb.source_spans[] (capped, newest first, deduped)
--      instead of keeping only the latest source_span (which remains,
--      for compatibility and as the card's lexical grounding).
--
-- Existing schemas pick up the new facades by re-running
-- maludb_core.enable_memory_schema(). The dirty queue, triggers, and
-- the seeded backfill are active immediately after this migration.
-- =====================================================================

CREATE OR REPLACE FUNCTION maludb_core.maludb_core_version() RETURNS text
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$ SELECT '0.95.0'::text $body$;

-- ---------------------------------------------------------------------
-- 1. Card renderers -- deterministic, versioned embedding inputs.
--    Name-first and content-dominant: the short structural prefix is
--    dwarfed by the attribute lines, so vectors cluster by attribute
--    CONTENT with a mild type/name pull (the template-dominance
--    mitigation). Timestamps are UTC-pinned so renders do not depend on
--    the session timezone. A render-format change bumps
--    embed_render_version() AND moves to a new embedding_space -- never
--    mix render versions inside one space.
-- ---------------------------------------------------------------------
CREATE FUNCTION maludb_core.embed_render_version() RETURNS integer
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$ SELECT 1 $body$;
REVOKE ALL ON FUNCTION maludb_core.embed_render_version() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core.embed_render_version()
    TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;

-- Shared attribute-block renderer: one "name: value [unit]" line per
-- attribute, ORDER BY attr_name. Value coalescing mirrors
-- attributes_jsonb(); ref-only attributes fall back to ref_key.
CREATE FUNCTION maludb_core._attribute_lines_text(p_target_kind text, p_target_id bigint)
RETURNS text
LANGUAGE sql STABLE SECURITY INVOKER
AS $body$
    SELECT string_agg(
               a.attr_name || ': ' ||
               COALESCE(
                   to_char(a.value_timestamp AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
                   CASE WHEN a.value_range IS NOT NULL THEN
                        '[' || COALESCE(to_char(lower(a.value_range) AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'), '') ||
                        ' .. ' || COALESCE(to_char(upper(a.value_range) AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'), '') || ')'
                   END,
                   a.value_numeric::text,
                   a.value_text,
                   a.value_jsonb::text,
                   a.ref_key,
                   '') ||
               COALESCE(' ' || a.unit, ''),
               E'\n' ORDER BY a.attr_name)
      FROM maludb_core.malu$svpor_attribute a
     WHERE a.owner_schema = current_schema()
       AND a.target_kind = lower(btrim(p_target_kind))
       AND a.target_id = p_target_id
$body$;
REVOKE ALL ON FUNCTION maludb_core._attribute_lines_text(text, bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core._attribute_lines_text(text, bigint)
    TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;

CREATE FUNCTION maludb_core.subject_card_text(p_subject_id bigint) RETURNS text
LANGUAGE plpgsql STABLE SECURITY INVOKER
AS $body$
DECLARE
    s record;
    e record;
    v_lines text[] := ARRAY[]::text[];
    v_attrs text;
BEGIN
    SELECT canonical_name, subject_type, aliases, description INTO s
      FROM maludb_core.malu$svpor_subject
     WHERE owner_schema = current_schema() AND subject_id = p_subject_id;
    IF NOT FOUND THEN
        RETURN NULL;
    END IF;

    v_lines := v_lines || s.canonical_name;
    v_lines := v_lines || ('type: ' || s.subject_type ||
        CASE WHEN cardinality(s.aliases) > 0
             THEN ' | aliases: ' || array_to_string(s.aliases, '; ')
             ELSE '' END);
    IF NULLIF(btrim(COALESCE(s.description, '')), '') IS NOT NULL THEN
        v_lines := v_lines || btrim(s.description);
    END IF;

    -- event sidecar (subjects minted from episodes carry the time)
    SELECT occurred_at, occurred_until INTO e
      FROM maludb_core.malu$episode_object
     WHERE owner_schema = current_schema() AND subject_id = p_subject_id
     ORDER BY episode_id
     LIMIT 1;
    IF FOUND AND (e.occurred_at IS NOT NULL OR e.occurred_until IS NOT NULL) THEN
        v_lines := v_lines || ('occurred: ' ||
            COALESCE(to_char(e.occurred_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'), '') ||
            CASE WHEN e.occurred_until IS NOT NULL
                 THEN ' .. ' || to_char(e.occurred_until AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
                 ELSE '' END);
    END IF;

    v_attrs := maludb_core._attribute_lines_text('subject', p_subject_id);
    IF v_attrs IS NOT NULL THEN
        v_lines := v_lines || v_attrs;
    END IF;

    RETURN array_to_string(v_lines, E'\n');
END;
$body$;
REVOKE ALL ON FUNCTION maludb_core.subject_card_text(bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core.subject_card_text(bigint)
    TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;

CREATE FUNCTION maludb_core.verb_card_text(p_verb_id bigint) RETURNS text
LANGUAGE plpgsql STABLE SECURITY INVOKER
AS $body$
DECLARE
    v record;
    v_lines text[] := ARRAY[]::text[];
BEGIN
    SELECT canonical_name, verb_type, aliases, description INTO v
      FROM maludb_core.malu$svpor_verb
     WHERE owner_schema = current_schema() AND verb_id = p_verb_id;
    IF NOT FOUND THEN
        RETURN NULL;
    END IF;

    v_lines := v_lines || v.canonical_name;
    v_lines := v_lines || ('verb' ||
        CASE WHEN NULLIF(btrim(COALESCE(v.verb_type, '')), '') IS NOT NULL
             THEN ' | type: ' || v.verb_type ELSE '' END ||
        CASE WHEN cardinality(v.aliases) > 0
             THEN ' | aliases: ' || array_to_string(v.aliases, '; ')
             ELSE '' END);
    IF NULLIF(btrim(COALESCE(v.description, '')), '') IS NOT NULL THEN
        v_lines := v_lines || btrim(v.description);
    END IF;

    RETURN array_to_string(v_lines, E'\n');
END;
$body$;
REVOKE ALL ON FUNCTION maludb_core.verb_card_text(bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core.verb_card_text(bigint)
    TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;

CREATE FUNCTION maludb_core.statement_card_text(p_statement_id bigint) RETURNS text
LANGUAGE plpgsql STABLE SECURITY INVOKER
AS $body$
DECLARE
    st record;
    v_verb  text;
    v_slab  text;
    v_olab  text;
    v_span  text;
    v_attrs text;
    v_lines text[] := ARRAY[]::text[];
BEGIN
    SELECT subject_kind, subject_id, verb_id, object_kind, object_id,
           valid_from, valid_to, metadata_jsonb INTO st
      FROM maludb_core.malu$svpor_statement
     WHERE owner_schema = current_schema() AND statement_id = p_statement_id;
    IF NOT FOUND THEN
        RETURN NULL;
    END IF;

    SELECT canonical_name INTO v_verb FROM maludb_core.malu$svpor_verb
     WHERE owner_schema = current_schema() AND verb_id = st.verb_id;
    v_slab := COALESCE(maludb_core._svpor_endpoint_label(st.subject_kind, st.subject_id),
                       st.subject_kind || '#' || st.subject_id::text);
    v_olab := COALESCE(maludb_core._svpor_endpoint_label(st.object_kind, st.object_id),
                       st.object_kind || '#' || st.object_id::text);

    v_lines := v_lines || maludb_core.svpor_frame_text(v_slab, v_verb, NULL, v_olab);

    v_attrs := maludb_core._attribute_lines_text('svpor_statement', p_statement_id);
    IF v_attrs IS NOT NULL THEN
        v_lines := v_lines || v_attrs;
    END IF;

    IF st.valid_from IS NOT NULL OR st.valid_to IS NOT NULL THEN
        v_lines := v_lines || ('valid: ' ||
            COALESCE(to_char(st.valid_from AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'), '') ||
            ' .. ' ||
            COALESCE(to_char(st.valid_to AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'), ''));
    END IF;

    -- latest verbatim span: the card's lexical grounding
    v_span := NULLIF(btrim(COALESCE(st.metadata_jsonb ->> 'source_span', '')), '');
    IF v_span IS NOT NULL THEN
        v_lines := v_lines || ('"' || v_span || '"');
    END IF;

    RETURN array_to_string(v_lines, E'\n');
END;
$body$;
REVOKE ALL ON FUNCTION maludb_core.statement_card_text(bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core.statement_card_text(bigint)
    TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;

-- Dispatcher + content hash. Returns no row when the object is gone.
CREATE FUNCTION maludb_core.embedding_card(p_object_kind text, p_object_id bigint)
RETURNS TABLE(card_text text, content_hash text)
LANGUAGE plpgsql STABLE SECURITY INVOKER
AS $body$
DECLARE
    v_kind text := lower(btrim(COALESCE(p_object_kind, '')));
    v_text text;
BEGIN
    CASE v_kind
        WHEN 'subject'         THEN v_text := maludb_core.subject_card_text(p_object_id);
        WHEN 'verb'            THEN v_text := maludb_core.verb_card_text(p_object_id);
        WHEN 'svpor_statement' THEN v_text := maludb_core.statement_card_text(p_object_id);
        ELSE
            RAISE EXCEPTION 'embedding_card: unsupported object kind %', v_kind
                USING ERRCODE = 'invalid_parameter_value';
    END CASE;

    IF v_text IS NULL THEN
        RETURN;
    END IF;
    card_text := v_text;
    content_hash := encode(sha256(convert_to(v_text, 'UTF8')), 'hex');
    RETURN NEXT;
END;
$body$;
REVOKE ALL ON FUNCTION maludb_core.embedding_card(text, bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core.embedding_card(text, bigint)
    TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;

-- ---------------------------------------------------------------------
-- 2. The dirty queue. One row per stale (kind, id); re-dirtying bumps
--    generation instead of adding rows, so N ingest writes collapse to
--    one pending job and staleness is observable (max dirty_since).
-- ---------------------------------------------------------------------
CREATE TABLE maludb_core.malu$embedding_dirty (
    owner_schema name NOT NULL DEFAULT current_schema(),
    object_kind  text NOT NULL
        CHECK (object_kind IN ('subject','verb','svpor_statement')),
    object_id    bigint NOT NULL,
    generation   bigint NOT NULL DEFAULT 1,
    reason       text,
    dirty_since  timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (owner_schema, object_kind, object_id)
);
CREATE INDEX malu$embedding_dirty_since_idx
    ON maludb_core.malu$embedding_dirty(owner_schema, dirty_since);

ALTER TABLE maludb_core.malu$embedding_dirty ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_owner ON maludb_core.malu$embedding_dirty
    USING (owner_schema = current_schema())
    WITH CHECK (owner_schema = current_schema());

GRANT SELECT ON maludb_core.malu$embedding_dirty
    TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;
GRANT INSERT, UPDATE, DELETE ON maludb_core.malu$embedding_dirty
    TO maludb_memory_admin, maludb_memory_executor;

-- Marker + purge: SECURITY DEFINER because callers (triggers under the
-- ingest's pinned search_path, cascaded deletes) do not run with the
-- row's tenant as current_schema(); owner_schema always comes from the
-- triggering ROW, never from current_schema().
CREATE FUNCTION maludb_core._embedding_dirty_mark(
    p_owner_schema name, p_object_kind text, p_object_id bigint, p_reason text DEFAULT 'changed'
) RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
    INSERT INTO maludb_core.malu$embedding_dirty (owner_schema, object_kind, object_id, reason)
    VALUES (p_owner_schema, p_object_kind, p_object_id, p_reason)
    ON CONFLICT (owner_schema, object_kind, object_id) DO UPDATE
        SET generation  = malu$embedding_dirty.generation + 1,
            dirty_since = now(),
            reason      = EXCLUDED.reason;
$body$;
REVOKE ALL ON FUNCTION maludb_core._embedding_dirty_mark(name, text, bigint, text) FROM PUBLIC;

-- A deleted object takes its queue row, its entity-card embeddings and
-- its semantic edges with it (orphaned vectors would otherwise keep
-- surfacing in semantic_search with NULL labels).
-- (plpgsql so the malu$semantic_edge reference -- created later in this
-- migration -- resolves at run time, not at CREATE FUNCTION time)
CREATE FUNCTION maludb_core._embedding_dirty_purge(
    p_owner_schema name, p_object_kind text, p_object_id bigint
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
BEGIN
    DELETE FROM maludb_core.malu$embedding_dirty
     WHERE owner_schema = p_owner_schema
       AND object_kind = p_object_kind AND object_id = p_object_id;
    DELETE FROM maludb_core.malu$object_embedding
     WHERE owner_schema = p_owner_schema
       AND object_kind = p_object_kind AND object_id = p_object_id
       AND source_field = 'entity_card';
    DELETE FROM maludb_core.malu$semantic_edge
     WHERE owner_schema = p_owner_schema
       AND object_kind = p_object_kind
       AND (source_id = p_object_id OR target_id = p_object_id);
END;
$body$;
REVOKE ALL ON FUNCTION maludb_core._embedding_dirty_purge(name, text, bigint) FROM PUBLIC;

-- Trigger bodies: every write path (one-call ingest, facade views,
-- register_* functions) funnels through these tables, so the queue
-- needs no contract or facade changes to stay complete.
CREATE FUNCTION maludb_core._embedding_dirty_subject_tg() RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
BEGIN
    IF TG_OP = 'DELETE' THEN
        PERFORM maludb_core._embedding_dirty_purge(OLD.owner_schema, 'subject', OLD.subject_id);
        RETURN OLD;
    END IF;
    PERFORM maludb_core._embedding_dirty_mark(NEW.owner_schema, 'subject', NEW.subject_id,
        CASE TG_OP WHEN 'INSERT' THEN 'created' ELSE 'changed' END);
    RETURN NEW;
END;
$body$;
REVOKE ALL ON FUNCTION maludb_core._embedding_dirty_subject_tg() FROM PUBLIC;

CREATE FUNCTION maludb_core._embedding_dirty_verb_tg() RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
BEGIN
    IF TG_OP = 'DELETE' THEN
        PERFORM maludb_core._embedding_dirty_purge(OLD.owner_schema, 'verb', OLD.verb_id);
        RETURN OLD;
    END IF;
    PERFORM maludb_core._embedding_dirty_mark(NEW.owner_schema, 'verb', NEW.verb_id,
        CASE TG_OP WHEN 'INSERT' THEN 'created' ELSE 'changed' END);
    RETURN NEW;
END;
$body$;
REVOKE ALL ON FUNCTION maludb_core._embedding_dirty_verb_tg() FROM PUBLIC;

CREATE FUNCTION maludb_core._embedding_dirty_statement_tg() RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
BEGIN
    IF TG_OP = 'DELETE' THEN
        PERFORM maludb_core._embedding_dirty_purge(OLD.owner_schema, 'svpor_statement', OLD.statement_id);
        RETURN OLD;
    END IF;
    PERFORM maludb_core._embedding_dirty_mark(NEW.owner_schema, 'svpor_statement', NEW.statement_id,
        CASE TG_OP WHEN 'INSERT' THEN 'created' ELSE 'changed' END);
    RETURN NEW;
END;
$body$;
REVOKE ALL ON FUNCTION maludb_core._embedding_dirty_statement_tg() FROM PUBLIC;

-- Attribute ACCRETION is exactly what invalidates an entity card.
CREATE FUNCTION maludb_core._embedding_dirty_attribute_tg() RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
BEGIN
    IF TG_OP IN ('INSERT','UPDATE')
       AND NEW.target_kind IN ('subject','verb','svpor_statement') THEN
        PERFORM maludb_core._embedding_dirty_mark(NEW.owner_schema, NEW.target_kind, NEW.target_id, 'attribute');
    END IF;
    IF TG_OP = 'DELETE'
       AND OLD.target_kind IN ('subject','verb','svpor_statement') THEN
        PERFORM maludb_core._embedding_dirty_mark(OLD.owner_schema, OLD.target_kind, OLD.target_id, 'attribute');
    ELSIF TG_OP = 'UPDATE'
       AND (OLD.target_kind <> NEW.target_kind OR OLD.target_id <> NEW.target_id)
       AND OLD.target_kind IN ('subject','verb','svpor_statement') THEN
        -- re-pointed attribute (e.g. statement merge): both sides go stale
        PERFORM maludb_core._embedding_dirty_mark(OLD.owner_schema, OLD.target_kind, OLD.target_id, 'attribute');
    END IF;
    RETURN COALESCE(NEW, OLD);
END;
$body$;
REVOKE ALL ON FUNCTION maludb_core._embedding_dirty_attribute_tg() FROM PUBLIC;

-- The temporal sidecar feeds the subject card's "occurred:" line. The
-- BEFORE-INSERT mint trigger has already set NEW.subject_id. A direct
-- body delete cascades through _episode_subject_cleanup -> subject
-- delete -> the subject trigger's purge; nothing to do here on DELETE.
CREATE FUNCTION maludb_core._embedding_dirty_episode_tg() RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
BEGIN
    IF NEW.subject_id IS NOT NULL THEN
        PERFORM maludb_core._embedding_dirty_mark(NEW.owner_schema, 'subject', NEW.subject_id, 'episode');
    END IF;
    RETURN NEW;
END;
$body$;
REVOKE ALL ON FUNCTION maludb_core._embedding_dirty_episode_tg() FROM PUBLIC;

CREATE TRIGGER malu$svpor_subject_embed_dirty
    AFTER INSERT OR UPDATE OF canonical_name, aliases, description, subject_type OR DELETE
    ON maludb_core.malu$svpor_subject
    FOR EACH ROW EXECUTE FUNCTION maludb_core._embedding_dirty_subject_tg();

CREATE TRIGGER malu$svpor_verb_embed_dirty
    AFTER INSERT OR UPDATE OF canonical_name, aliases, description, verb_type OR DELETE
    ON maludb_core.malu$svpor_verb
    FOR EACH ROW EXECUTE FUNCTION maludb_core._embedding_dirty_verb_tg();

CREATE TRIGGER malu$svpor_statement_embed_dirty
    AFTER INSERT OR UPDATE OR DELETE
    ON maludb_core.malu$svpor_statement
    FOR EACH ROW EXECUTE FUNCTION maludb_core._embedding_dirty_statement_tg();

CREATE TRIGGER malu$svpor_attribute_embed_dirty
    AFTER INSERT OR UPDATE OR DELETE
    ON maludb_core.malu$svpor_attribute
    FOR EACH ROW EXECUTE FUNCTION maludb_core._embedding_dirty_attribute_tg();

CREATE TRIGGER malu$episode_object_embed_dirty
    AFTER INSERT OR UPDATE OF title, summary, occurred_at, occurred_until
    ON maludb_core.malu$episode_object
    FOR EACH ROW EXECUTE FUNCTION maludb_core._embedding_dirty_episode_tg();

-- ---------------------------------------------------------------------
-- 3. content_hash on the object-embedding store + a 10-arg
--    register_object_embedding overload that records it. The hash is of
--    the EMBEDDED card text (computed at claim time and passed through),
--    so an unchanged card can be skipped without an embedding call. The
--    9-arg signature stays for callers that do not track hashes.
-- ---------------------------------------------------------------------
ALTER TABLE maludb_core.malu$object_embedding
    ADD COLUMN content_hash text;

CREATE FUNCTION maludb_core.register_object_embedding(
    p_object_kind     text,
    p_object_id       bigint,
    p_embedding       bytea,
    p_embedding_dim   integer,
    p_embedding_space text,
    p_embedding_model text,
    p_source_field    text,
    p_sub_key         text,
    p_provenance      text,
    p_content_hash    text
) RETURNS bigint
LANGUAGE plpgsql
SECURITY INVOKER
AS $body$
DECLARE
    v_schema name := current_schema();
    v_kind   text := lower(btrim(COALESCE(p_object_kind, '')));
    v_id     bigint;
BEGIN
    IF p_object_id IS NULL OR p_embedding IS NULL OR p_embedding_dim IS NULL
       OR COALESCE(btrim(p_embedding_space),'') = '' THEN
        RAISE EXCEPTION 'register_object_embedding: object_id, embedding, embedding_dim and embedding_space are required'
            USING ERRCODE='invalid_parameter_value';
    END IF;
    IF octet_length(p_embedding) <> p_embedding_dim * 4 THEN
        RAISE EXCEPTION 'register_object_embedding: embedding byte length % does not match dim %',
            octet_length(p_embedding), p_embedding_dim USING ERRCODE='invalid_parameter_value';
    END IF;

    PERFORM maludb_core._svpor_attribute_assert_target(v_schema, v_kind, p_object_id);

    INSERT INTO maludb_core.malu$object_embedding
        (owner_schema, object_kind, object_id, embedding_space, source_field, sub_key,
         embedding, embedding_dim, embedding_model, provenance, content_hash)
    VALUES
        (v_schema, v_kind, p_object_id, p_embedding_space,
         COALESCE(NULLIF(btrim(p_source_field),''),'default'), COALESCE(p_sub_key,''),
         p_embedding, p_embedding_dim, p_embedding_model,
         COALESCE(NULLIF(btrim(p_provenance),''),'provided'), p_content_hash)
    ON CONFLICT (owner_schema, object_kind, object_id, embedding_space, source_field, sub_key)
    DO UPDATE SET
        embedding       = EXCLUDED.embedding,
        embedding_dim   = EXCLUDED.embedding_dim,
        embedding_model = EXCLUDED.embedding_model,
        provenance      = EXCLUDED.provenance,
        content_hash    = EXCLUDED.content_hash
    RETURNING object_embedding_id INTO v_id;

    RETURN v_id;
END;
$body$;
REVOKE ALL ON FUNCTION maludb_core.register_object_embedding(text, bigint, bytea, integer, text, text, text, text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core.register_object_embedding(text, bigint, bytea, integer, text, text, text, text, text, text)
    TO maludb_memory_admin, maludb_memory_executor;

-- The 9-arg original now delegates (and leaves content_hash NULL).
CREATE OR REPLACE FUNCTION maludb_core.register_object_embedding(
    p_object_kind     text,
    p_object_id       bigint,
    p_embedding       bytea,
    p_embedding_dim   integer,
    p_embedding_space text,
    p_embedding_model text DEFAULT NULL,
    p_source_field    text DEFAULT 'default',
    p_sub_key         text DEFAULT '',
    p_provenance      text DEFAULT 'provided'
) RETURNS bigint
LANGUAGE sql
SECURITY INVOKER
AS $body$
    SELECT maludb_core.register_object_embedding(
        p_object_kind, p_object_id, p_embedding, p_embedding_dim, p_embedding_space,
        p_embedding_model, p_source_field, p_sub_key, p_provenance, NULL::text);
$body$;

-- ---------------------------------------------------------------------
-- 4. Materialized semantic edges -- the traversal jump layer. Derived
--    data (bulk-replaced on refresh), deliberately NOT in the assertion
--    stores: legacy malu$relationship_edge CHECK-rejects subject
--    endpoints, and malu$svpor_subject_relationship_edge is the asserted
--    layer (valid-time exclusion constraint, subjects only -- statement
--    pairs would be homeless). cosine over 'entity_card' rows of ONE
--    embedding space; k bounds walk fan-out by construction.
-- ---------------------------------------------------------------------
CREATE TABLE maludb_core.malu$semantic_edge (
    semantic_edge_id bigserial PRIMARY KEY,
    owner_schema    name NOT NULL DEFAULT current_schema(),
    object_kind     text NOT NULL
        CHECK (object_kind IN ('subject','svpor_statement')),
    source_id       bigint NOT NULL,
    target_id       bigint NOT NULL,
    similarity      double precision NOT NULL CHECK (similarity > 0),
    embedding_space text NOT NULL DEFAULT 'entity-v1',
    refreshed_at    timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT malu$semantic_edge_no_self CHECK (source_id <> target_id),
    CONSTRAINT malu$semantic_edge_identity
        UNIQUE (owner_schema, object_kind, source_id, target_id, embedding_space)
);
CREATE INDEX malu$semantic_edge_source_idx
    ON maludb_core.malu$semantic_edge(owner_schema, object_kind, source_id);
CREATE INDEX malu$semantic_edge_target_idx
    ON maludb_core.malu$semantic_edge(owner_schema, object_kind, target_id);

ALTER TABLE maludb_core.malu$semantic_edge ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_owner ON maludb_core.malu$semantic_edge
    USING (owner_schema = current_schema())
    WITH CHECK (owner_schema = current_schema());

GRANT SELECT ON maludb_core.malu$semantic_edge
    TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;
GRANT INSERT, UPDATE, DELETE ON maludb_core.malu$semantic_edge
    TO maludb_memory_admin, maludb_memory_executor;
GRANT USAGE, SELECT ON SEQUENCE maludb_core.malu$semantic_edge_semantic_edge_id_seq
    TO maludb_memory_admin, maludb_memory_executor;

-- Rebuild one node's outbound top-k (+ reciprocal upserts so inbound
-- freshness does not wait for the neighbor's own re-embed).
CREATE FUNCTION maludb_core.semantic_edges_refresh(
    p_object_kind     text,
    p_object_id       bigint,
    p_k               integer DEFAULT 5,
    p_min_similarity  double precision DEFAULT 0.80,
    p_embedding_space text DEFAULT 'entity-v1'
) RETURNS integer
LANGUAGE plpgsql
SECURITY INVOKER
AS $body$
DECLARE
    v_kind  text := lower(btrim(COALESCE(p_object_kind, '')));
    v_vec   bytea;
    v_dim   integer;
    v_count integer := 0;
BEGIN
    IF v_kind NOT IN ('subject','svpor_statement') THEN
        RAISE EXCEPTION 'semantic_edges_refresh: object kind must be subject or svpor_statement, got %', v_kind
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    SELECT oe.embedding, oe.embedding_dim INTO v_vec, v_dim
      FROM maludb_core.malu$object_embedding oe
     WHERE oe.owner_schema = current_schema()
       AND oe.object_kind = v_kind AND oe.object_id = p_object_id
       AND oe.embedding_space = p_embedding_space
       AND oe.source_field = 'entity_card' AND oe.sub_key = '';

    DELETE FROM maludb_core.malu$semantic_edge se
     WHERE se.owner_schema = current_schema()
       AND se.object_kind = v_kind AND se.source_id = p_object_id
       AND se.embedding_space = p_embedding_space;

    IF v_vec IS NULL THEN
        RETURN 0;
    END IF;

    INSERT INTO maludb_core.malu$semantic_edge
        (owner_schema, object_kind, source_id, target_id, similarity, embedding_space)
    SELECT current_schema(), v_kind, p_object_id, t.object_id,
           LEAST(t.sim, 1.0), p_embedding_space
      FROM (
            SELECT oe.object_id,
                   1.0 - maludb_core.cosine_distance(
                       oe.embedding::maludb_core.malu_vector,
                       v_vec::maludb_core.malu_vector) AS sim
              FROM maludb_core.malu$object_embedding oe
             WHERE oe.owner_schema = current_schema()
               AND oe.object_kind = v_kind
               AND oe.object_id <> p_object_id
               AND oe.embedding_space = p_embedding_space
               AND oe.source_field = 'entity_card' AND oe.sub_key = ''
               AND oe.embedding_dim = v_dim
           ) t
     WHERE t.sim >= p_min_similarity
     ORDER BY t.sim DESC, t.object_id
     LIMIT GREATEST(COALESCE(p_k, 5), 1);
    GET DIAGNOSTICS v_count = ROW_COUNT;

    INSERT INTO maludb_core.malu$semantic_edge
        (owner_schema, object_kind, source_id, target_id, similarity, embedding_space)
    SELECT se.owner_schema, se.object_kind, se.target_id, se.source_id,
           se.similarity, se.embedding_space
      FROM maludb_core.malu$semantic_edge se
     WHERE se.owner_schema = current_schema()
       AND se.object_kind = v_kind AND se.source_id = p_object_id
       AND se.embedding_space = p_embedding_space
    ON CONFLICT ON CONSTRAINT malu$semantic_edge_identity
    DO UPDATE SET similarity = EXCLUDED.similarity, refreshed_at = now();

    RETURN v_count;
END;
$body$;
REVOKE ALL ON FUNCTION maludb_core.semantic_edges_refresh(text, bigint, integer, double precision, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core.semantic_edges_refresh(text, bigint, integer, double precision, text)
    TO maludb_memory_admin, maludb_memory_executor;

-- Sweep: refresh every entity-card holder of a kind (nightly hygiene
-- against drift from deletes/re-embeds elsewhere).
CREATE FUNCTION maludb_core.semantic_edges_refresh_all(
    p_object_kind     text    DEFAULT NULL,
    p_batch           integer DEFAULT 200,
    p_k               integer DEFAULT 5,
    p_min_similarity  double precision DEFAULT 0.80,
    p_embedding_space text DEFAULT 'entity-v1'
) RETURNS integer
LANGUAGE plpgsql
SECURITY INVOKER
AS $body$
DECLARE
    r record;
    v_done integer := 0;
BEGIN
    FOR r IN
        SELECT oe.object_kind AS kind, oe.object_id AS id
          FROM maludb_core.malu$object_embedding oe
         WHERE oe.owner_schema = current_schema()
           AND oe.embedding_space = p_embedding_space
           AND oe.source_field = 'entity_card' AND oe.sub_key = ''
           AND oe.object_kind IN ('subject','svpor_statement')
           AND (p_object_kind IS NULL OR oe.object_kind = lower(btrim(p_object_kind)))
         ORDER BY oe.object_kind, oe.object_id
         LIMIT GREATEST(COALESCE(p_batch, 200), 1)
    LOOP
        PERFORM maludb_core.semantic_edges_refresh(r.kind, r.id, p_k, p_min_similarity, p_embedding_space);
        v_done := v_done + 1;
    END LOOP;
    RETURN v_done;
END;
$body$;
REVOKE ALL ON FUNCTION maludb_core.semantic_edges_refresh_all(text, integer, integer, double precision, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core.semantic_edges_refresh_all(text, integer, integer, double precision, text)
    TO maludb_memory_admin, maludb_memory_executor;

-- Query-time semantic hop (always fresh, O(corpus) scan): validation
-- and ad-hoc use; walks use the materialized edges.
CREATE FUNCTION maludb_core.uedge_semantic_neighbors(
    p_kind            text,
    p_id              bigint,
    p_k               integer DEFAULT 5,
    p_min_similarity  double precision DEFAULT 0.70,
    p_embedding_space text DEFAULT 'entity-v1'
) RETURNS TABLE(neighbor_kind text, neighbor_id bigint, similarity double precision, label text)
LANGUAGE plpgsql STABLE
SECURITY INVOKER
AS $body$
DECLARE
    v_kind text := lower(btrim(COALESCE(p_kind, '')));
    v_vec  bytea;
    v_dim  integer;
BEGIN
    IF v_kind NOT IN ('subject','svpor_statement') THEN
        RAISE EXCEPTION 'uedge_semantic_neighbors: object kind must be subject or svpor_statement, got %', v_kind
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    SELECT oe.embedding, oe.embedding_dim INTO v_vec, v_dim
      FROM maludb_core.malu$object_embedding oe
     WHERE oe.owner_schema = current_schema()
       AND oe.object_kind = v_kind AND oe.object_id = p_id
       AND oe.embedding_space = p_embedding_space
       AND oe.source_field = 'entity_card' AND oe.sub_key = '';
    IF v_vec IS NULL THEN
        RETURN;
    END IF;

    RETURN QUERY
        SELECT v_kind, t.object_id, t.sim,
               maludb_core._svpor_endpoint_label(v_kind, t.object_id)
          FROM (
                SELECT oe.object_id,
                       1.0 - maludb_core.cosine_distance(
                           oe.embedding::maludb_core.malu_vector,
                           v_vec::maludb_core.malu_vector) AS sim
                  FROM maludb_core.malu$object_embedding oe
                 WHERE oe.owner_schema = current_schema()
                   AND oe.object_kind = v_kind
                   AND oe.object_id <> p_id
                   AND oe.embedding_space = p_embedding_space
                   AND oe.source_field = 'entity_card' AND oe.sub_key = ''
                   AND oe.embedding_dim = v_dim
               ) t
         WHERE t.sim >= p_min_similarity
         ORDER BY t.sim DESC, t.object_id
         LIMIT GREATEST(COALESCE(p_k, 5), 1);
END;
$body$;
REVOKE ALL ON FUNCTION maludb_core.uedge_semantic_neighbors(text, bigint, integer, double precision, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core.uedge_semantic_neighbors(text, bigint, integer, double precision, text)
    TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;

-- ---------------------------------------------------------------------
-- 5. Worker API: claim -> (external embed) -> complete. The worker is
--    deliberately dumb -- all rendering and hashing happen in-DB. claim
--    uses FOR UPDATE SKIP LOCKED so concurrent workers partition the
--    queue; the generation check on complete makes a mid-embed re-dirty
--    survive (the row stays queued and the NEXT cycle re-embeds).
--    Unchanged cards (stored content_hash matches) and vanished objects
--    are completed in-claim without being returned.
-- ---------------------------------------------------------------------
CREATE FUNCTION maludb_core.embedding_dirty_claim(
    p_kinds text[]  DEFAULT NULL,
    p_limit integer DEFAULT 64
) RETURNS TABLE(object_kind text, object_id bigint, generation bigint,
                card_text text, content_hash text)
LANGUAGE plpgsql
SECURITY INVOKER
AS $body$
DECLARE
    r      record;
    v_card record;
BEGIN
    FOR r IN
        SELECT d.object_kind AS kind, d.object_id AS id, d.generation AS gen
          FROM maludb_core.malu$embedding_dirty d
         WHERE d.owner_schema = current_schema()
           AND (p_kinds IS NULL OR cardinality(p_kinds) = 0 OR d.object_kind = ANY(p_kinds))
         ORDER BY d.dirty_since, d.object_kind, d.object_id
         LIMIT GREATEST(COALESCE(p_limit, 64), 1)
           FOR UPDATE SKIP LOCKED
    LOOP
        SELECT c.card_text, c.content_hash INTO v_card
          FROM maludb_core.embedding_card(r.kind, r.id) c;

        IF v_card.card_text IS NULL
           OR EXISTS (SELECT 1 FROM maludb_core.malu$object_embedding oe
                       WHERE oe.owner_schema = current_schema()
                         AND oe.object_kind = r.kind AND oe.object_id = r.id
                         AND oe.source_field = 'entity_card'
                         AND oe.content_hash = v_card.content_hash) THEN
            -- vanished object, or card unchanged since last embed
            DELETE FROM maludb_core.malu$embedding_dirty d
             WHERE d.owner_schema = current_schema()
               AND d.object_kind = r.kind AND d.object_id = r.id
               AND d.generation = r.gen;
            CONTINUE;
        END IF;

        object_kind  := r.kind;
        object_id    := r.id;
        generation   := r.gen;
        card_text    := v_card.card_text;
        content_hash := v_card.content_hash;
        RETURN NEXT;
    END LOOP;
END;
$body$;
REVOKE ALL ON FUNCTION maludb_core.embedding_dirty_claim(text[], integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core.embedding_dirty_claim(text[], integer)
    TO maludb_memory_admin, maludb_memory_executor;

CREATE FUNCTION maludb_core.embedding_dirty_complete(
    p_object_kind text,
    p_object_id   bigint,
    p_generation  bigint
) RETURNS boolean
LANGUAGE plpgsql
SECURITY INVOKER
AS $body$
BEGIN
    DELETE FROM maludb_core.malu$embedding_dirty d
     WHERE d.owner_schema = current_schema()
       AND d.object_kind = lower(btrim(COALESCE(p_object_kind, '')))
       AND d.object_id = p_object_id
       AND d.generation = p_generation;
    RETURN FOUND;
END;
$body$;
REVOKE ALL ON FUNCTION maludb_core.embedding_dirty_complete(text, bigint, bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core.embedding_dirty_complete(text, bigint, bigint)
    TO maludb_memory_admin, maludb_memory_executor;

-- One-call completion: store the vector (with the hash of the text that
-- was actually embedded), retire the queue row, refresh the node's
-- semantic edges so jump freshness rides the embed queue.
CREATE FUNCTION maludb_core.embedding_complete(
    p_object_kind       text,
    p_object_id         bigint,
    p_generation        bigint,
    p_embedding         bytea,
    p_embedding_dim     integer,
    p_embedding_space   text    DEFAULT 'entity-v1',
    p_embedding_model   text    DEFAULT NULL,
    p_content_hash      text    DEFAULT NULL,
    p_refresh_neighbors boolean DEFAULT true
) RETURNS bigint
LANGUAGE plpgsql
SECURITY INVOKER
AS $body$
DECLARE
    v_kind text := lower(btrim(COALESCE(p_object_kind, '')));
    v_id   bigint;
BEGIN
    v_id := maludb_core.register_object_embedding(
        v_kind, p_object_id, p_embedding, p_embedding_dim, p_embedding_space,
        p_embedding_model, 'entity_card', '', 'provided', p_content_hash);

    PERFORM maludb_core.embedding_dirty_complete(v_kind, p_object_id, p_generation);

    IF p_refresh_neighbors AND v_kind IN ('subject','svpor_statement') THEN
        PERFORM maludb_core.semantic_edges_refresh(
            v_kind, p_object_id, p_embedding_space => p_embedding_space);
    END IF;

    RETURN v_id;
END;
$body$;
REVOKE ALL ON FUNCTION maludb_core.embedding_complete(text, bigint, bigint, bytea, integer, text, text, text, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core.embedding_complete(text, bigint, bigint, bytea, integer, text, text, text, boolean)
    TO maludb_memory_admin, maludb_memory_executor;

-- Model or render-version change: re-queue everything of a kind.
CREATE FUNCTION maludb_core.embedding_requeue_all(p_object_kind text DEFAULT NULL)
RETURNS integer
LANGUAGE plpgsql
SECURITY INVOKER
AS $body$
DECLARE
    v_kind  text := NULLIF(lower(btrim(COALESCE(p_object_kind, ''))), '');
    v_count integer;
BEGIN
    INSERT INTO maludb_core.malu$embedding_dirty (owner_schema, object_kind, object_id, reason)
    SELECT current_schema(), t.kind, t.id, 'requeue'
      FROM (
            SELECT 'subject'::text AS kind, s.subject_id AS id
              FROM maludb_core.malu$svpor_subject s
             WHERE s.owner_schema = current_schema()
            UNION ALL
            SELECT 'verb', v.verb_id
              FROM maludb_core.malu$svpor_verb v
             WHERE v.owner_schema = current_schema()
            UNION ALL
            SELECT 'svpor_statement', st.statement_id
              FROM maludb_core.malu$svpor_statement st
             WHERE st.owner_schema = current_schema()
           ) t
     WHERE v_kind IS NULL OR t.kind = v_kind
    ON CONFLICT (owner_schema, object_kind, object_id) DO UPDATE
        SET generation  = malu$embedding_dirty.generation + 1,
            dirty_since = now(),
            reason      = EXCLUDED.reason;
    GET DIAGNOSTICS v_count = ROW_COUNT;
    RETURN v_count;
END;
$body$;
REVOKE ALL ON FUNCTION maludb_core.embedding_requeue_all(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core.embedding_requeue_all(text)
    TO maludb_memory_admin, maludb_memory_executor;

-- Enqueue only objects that have no entity-card vector yet.
CREATE FUNCTION maludb_core.embedding_backfill()
RETURNS integer
LANGUAGE plpgsql
SECURITY INVOKER
AS $body$
DECLARE
    v_count integer;
BEGIN
    INSERT INTO maludb_core.malu$embedding_dirty (owner_schema, object_kind, object_id, reason)
    SELECT current_schema(), t.kind, t.id, 'backfill'
      FROM (
            SELECT 'subject'::text AS kind, s.subject_id AS id
              FROM maludb_core.malu$svpor_subject s
             WHERE s.owner_schema = current_schema()
            UNION ALL
            SELECT 'verb', v.verb_id
              FROM maludb_core.malu$svpor_verb v
             WHERE v.owner_schema = current_schema()
            UNION ALL
            SELECT 'svpor_statement', st.statement_id
              FROM maludb_core.malu$svpor_statement st
             WHERE st.owner_schema = current_schema()
           ) t
     WHERE NOT EXISTS (
            SELECT 1 FROM maludb_core.malu$object_embedding oe
             WHERE oe.owner_schema = current_schema()
               AND oe.object_kind = t.kind AND oe.object_id = t.id
               AND oe.source_field = 'entity_card')
    ON CONFLICT (owner_schema, object_kind, object_id) DO NOTHING;
    GET DIAGNOSTICS v_count = ROW_COUNT;
    RETURN v_count;
END;
$body$;
REVOKE ALL ON FUNCTION maludb_core.embedding_backfill() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core.embedding_backfill()
    TO maludb_memory_admin, maludb_memory_executor;

-- ---------------------------------------------------------------------
-- 6. The unified edge view grows two arms; traversal gains the OPT-IN
--    semantic guard.
--    Arm 3 (gap fix): malu$svpor_subject_relationship_edge -- the table
--    the 0.92.0 ingest writes relationships[] to -- was never unioned
--    in, so ingested subject<->subject relationships were invisible to
--    uedge_neighbors/uedge_walk.
--    Arm 4: materialized semantic edges (rel 'similar_to' for subjects,
--    'similar_statement' for statements; confidence = similarity;
--    provenance 'derived').
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW maludb_core.malu$edge_unified AS
    SELECT 'svpor_statement'::text AS edge_store,
           s.statement_id          AS edge_id,
           s.owner_schema,
           s.subject_kind          AS source_kind,
           s.subject_id            AS source_id,
           v.canonical_name        AS rel,
           s.object_kind           AS target_kind,
           s.object_id             AS target_id,
           s.confidence,
           s.provenance
      FROM maludb_core.malu$svpor_statement s
      LEFT JOIN maludb_core.malu$svpor_verb v
        ON v.owner_schema = s.owner_schema AND v.verb_id = s.verb_id
    UNION ALL
    SELECT 'relationship_edge'::text,
           e.edge_id,
           e.owner_schema,
           e.source_object_type,
           e.source_object_id,
           e.relationship_type,
           e.target_object_type,
           e.target_object_id,
           e.confidence,
           NULL::text
      FROM maludb_core.malu$relationship_edge e
    UNION ALL
    SELECT 'subject_relationship'::text,
           r.edge_id,
           r.owner_schema,
           'subject'::text,
           r.from_subject_id,
           r.relationship_type,
           'subject'::text,
           r.to_subject_id,
           NULL::numeric(5,4),
           'asserted'::text
      FROM maludb_core.malu$svpor_subject_relationship_edge r
    UNION ALL
    SELECT 'semantic_edge'::text,
           se.semantic_edge_id,
           se.owner_schema,
           se.object_kind,
           se.source_id,
           CASE se.object_kind WHEN 'subject' THEN 'similar_to'
                               ELSE 'similar_statement' END,
           se.object_kind,
           se.target_id,
           se.similarity::numeric(5,4),
           'derived'::text
      FROM maludb_core.malu$semantic_edge se;

GRANT SELECT ON maludb_core.malu$edge_unified
    TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;

-- Re-emit traversal bodies (signatures unchanged) with the semantic-arm
-- guard: a NULL/empty rel_filter means "any rel" for STRUCTURAL edges
-- only; semantic edges traverse only when the caller names their rel
-- explicitly. Without the guard, k-per-node kNN edges would multiply a
-- depth-4 walk frontier by up to k^4 and silently add semantic
-- wormholes to every existing structural query.
CREATE OR REPLACE FUNCTION maludb_core.uedge_neighbors(
    p_kind text, p_id bigint, p_direction text DEFAULT 'both', p_rel_filter text[] DEFAULT NULL
) RETURNS TABLE(
    neighbor_kind text, neighbor_id bigint, rel text, edge_store text,
    confidence numeric, provenance text, label text)
LANGUAGE plpgsql STABLE SECURITY INVOKER
AS $body$
BEGIN
    IF p_direction NOT IN ('out','in','both') THEN
        RAISE EXCEPTION 'uedge_neighbors: bad direction %', p_direction USING ERRCODE='invalid_parameter_value';
    END IF;
    RETURN QUERY
        SELECT e.target_kind, e.target_id, e.rel, e.edge_store, e.confidence, e.provenance,
               maludb_core._svpor_endpoint_label(e.target_kind, e.target_id)
          FROM maludb_core.malu$edge_unified e
         WHERE e.owner_schema = current_schema()
           AND p_direction IN ('out','both')
           AND e.source_kind = p_kind AND e.source_id = p_id
           AND (p_rel_filter IS NULL OR cardinality(p_rel_filter)=0 OR e.rel = ANY(p_rel_filter))
           AND (e.edge_store <> 'semantic_edge'
                OR (p_rel_filter IS NOT NULL AND cardinality(p_rel_filter) > 0 AND e.rel = ANY(p_rel_filter)))
        UNION ALL
        SELECT e.source_kind, e.source_id, e.rel, e.edge_store, e.confidence, e.provenance,
               maludb_core._svpor_endpoint_label(e.source_kind, e.source_id)
          FROM maludb_core.malu$edge_unified e
         WHERE e.owner_schema = current_schema()
           AND p_direction IN ('in','both')
           AND e.target_kind = p_kind AND e.target_id = p_id
           AND (p_rel_filter IS NULL OR cardinality(p_rel_filter)=0 OR e.rel = ANY(p_rel_filter))
           AND (e.edge_store <> 'semantic_edge'
                OR (p_rel_filter IS NOT NULL AND cardinality(p_rel_filter) > 0 AND e.rel = ANY(p_rel_filter)));
END;
$body$;

CREATE OR REPLACE FUNCTION maludb_core.uedge_walk(
    p_kind text, p_id bigint, p_max_depth integer DEFAULT 4,
    p_direction text DEFAULT 'both', p_rel_filter text[] DEFAULT NULL
) RETURNS TABLE(
    object_kind text, object_id bigint, depth integer, rel text, edge_store text,
    label text, path text[])
LANGUAGE plpgsql STABLE SECURITY INVOKER
AS $body$
BEGIN
    IF p_direction NOT IN ('out','in','both') THEN
        RAISE EXCEPTION 'uedge_walk: bad direction %', p_direction USING ERRCODE='invalid_parameter_value';
    END IF;
    RETURN QUERY
    WITH RECURSIVE walk AS (
        SELECT p_kind AS object_kind, p_id AS object_id, 0 AS depth,
               NULL::text AS rel, NULL::text AS edge_store,
               ARRAY[p_kind || ':' || p_id::text] AS path
        UNION ALL
        SELECT
            CASE WHEN e.source_kind = w.object_kind AND e.source_id = w.object_id
                 THEN e.target_kind ELSE e.source_kind END,
            CASE WHEN e.source_kind = w.object_kind AND e.source_id = w.object_id
                 THEN e.target_id ELSE e.source_id END,
            w.depth + 1, e.rel, e.edge_store,
            w.path || (CASE WHEN e.source_kind = w.object_kind AND e.source_id = w.object_id
                            THEN e.target_kind || ':' || e.target_id::text
                            ELSE e.source_kind || ':' || e.source_id::text END)
        FROM walk w
        JOIN maludb_core.malu$edge_unified e
          ON e.owner_schema = current_schema()
         AND (
              (p_direction IN ('out','both') AND e.source_kind = w.object_kind AND e.source_id = w.object_id)
              OR
              (p_direction IN ('in','both')  AND e.target_kind = w.object_kind AND e.target_id = w.object_id)
             )
         AND (p_rel_filter IS NULL OR cardinality(p_rel_filter)=0 OR e.rel = ANY(p_rel_filter))
         AND (e.edge_store <> 'semantic_edge'
              OR (p_rel_filter IS NOT NULL AND cardinality(p_rel_filter) > 0 AND e.rel = ANY(p_rel_filter)))
        WHERE w.depth < p_max_depth
          AND NOT (
              (CASE WHEN e.source_kind = w.object_kind AND e.source_id = w.object_id
                    THEN e.target_kind || ':' || e.target_id::text
                    ELSE e.source_kind || ':' || e.source_id::text END) = ANY(w.path))
    )
    SELECT w.object_kind, w.object_id, w.depth, w.rel, w.edge_store,
           maludb_core._svpor_endpoint_label(w.object_kind, w.object_id) AS label, w.path
      FROM walk w
     WHERE w.depth > 0;
END;
$body$;

-- ---------------------------------------------------------------------
-- 7. Verbatim-recall compensation: the statement upsert ACCRETES a
--    capped, deduped metadata_jsonb.source_spans[] history (newest
--    first) instead of keeping only the latest span. 'source_span'
--    (latest) is preserved for compatibility and the card render.
-- ---------------------------------------------------------------------
CREATE FUNCTION maludb_core._statement_spans_accrete(
    p_existing    jsonb,
    p_span        text,
    p_document_id bigint,
    p_cap         integer DEFAULT 8
) RETURNS jsonb
LANGUAGE sql STABLE
AS $body$
    SELECT CASE
        WHEN NULLIF(btrim(COALESCE(p_span, '')), '') IS NULL
            THEN COALESCE(p_existing, '[]'::jsonb)
        ELSE (
            SELECT COALESCE(jsonb_agg(t.e ORDER BY t.ord), '[]'::jsonb)
              FROM (
                    SELECT e, ord
                      FROM jsonb_array_elements(
                               jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
                                   'span', btrim(p_span),
                                   'document_id', p_document_id,
                                   'at', to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'))))
                               || (SELECT COALESCE(jsonb_agg(o.e), '[]'::jsonb)
                                     FROM jsonb_array_elements(COALESCE(p_existing, '[]'::jsonb)) AS o(e)
                                    WHERE NOT (COALESCE(o.e ->> 'span', '') = btrim(p_span)
                                               AND COALESCE(o.e ->> 'document_id', '')
                                                   = COALESCE(p_document_id::text, '')))
                           ) WITH ORDINALITY AS x(e, ord)
                     ORDER BY ord
                     LIMIT GREATEST(COALESCE(p_cap, 8), 1)
                   ) t
        )
    END
$body$;
REVOKE ALL ON FUNCTION maludb_core._statement_spans_accrete(jsonb, text, bigint, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core._statement_spans_accrete(jsonb, text, bigint, integer)
    TO maludb_memory_admin, maludb_memory_executor;

-- Re-emit the ingest backend (0.94.0 body, edges-section metadata
-- handling changed to accrete source_spans[]; everything else verbatim).
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
    v_span text; v_span_doc bigint;
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
    v_span_doc := CASE WHEN v_src_kind = 'document' THEN v_src_id ELSE NULL END;

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

            v_span := NULLIF(btrim(COALESCE(r.val ->> 'source_span', '')), '');

            INSERT INTO maludb_core.malu$svpor_statement
                (owner_schema, subject_kind, subject_id, verb_id, object_kind, object_id,
                 valid_from, valid_to, confidence, provenance, metadata_jsonb)
            VALUES
                (p_owner_schema, v_sk, v_si, v_vid, v_ok, v_oi,
                 (r.val ->> 'valid_from')::timestamptz, (r.val ->> 'valid_to')::timestamptz,
                 (r.val ->> 'confidence')::numeric, v_prov,
                 jsonb_strip_nulls(jsonb_build_object('source_span', v_span))
                 || CASE WHEN v_span IS NOT NULL
                         THEN jsonb_build_object('source_spans',
                                  maludb_core._statement_spans_accrete(NULL, v_span, v_span_doc))
                         ELSE '{}'::jsonb END)
            ON CONFLICT (owner_schema, subject_kind, subject_id, verb_id, object_kind, object_id)
            DO UPDATE SET
                confidence     = COALESCE(EXCLUDED.confidence, malu$svpor_statement.confidence),
                provenance     = EXCLUDED.provenance,
                valid_from     = COALESCE(EXCLUDED.valid_from, malu$svpor_statement.valid_from),
                valid_to       = COALESCE(EXCLUDED.valid_to,   malu$svpor_statement.valid_to),
                metadata_jsonb = (malu$svpor_statement.metadata_jsonb || EXCLUDED.metadata_jsonb)
                    || CASE WHEN v_span IS NOT NULL
                            THEN jsonb_build_object('source_spans',
                                     maludb_core._statement_spans_accrete(
                                         malu$svpor_statement.metadata_jsonb -> 'source_spans',
                                         v_span, v_span_doc))
                            ELSE '{}'::jsonb END
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
-- 8. 0.95.0 schema-local facade builder: the worker protocol, cards,
--    semantic edges and introspection views for each tenant schema.
-- ---------------------------------------------------------------------
CREATE FUNCTION maludb_core._enable_memory_schema_0950_facade(p_schema name) RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
DECLARE
    v_count integer := 0;
BEGIN
    PERFORM maludb_core._memory_schema_assert_manageable(p_schema);

    -- dirty-queue introspection view (read-only) ----------------------
    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_embedding_dirty', 'view');
    EXECUTE format($sql$
        CREATE OR REPLACE VIEW %I.maludb_embedding_dirty WITH (security_invoker = true) AS
        SELECT object_kind, object_id, generation, reason, dirty_since
          FROM maludb_core.malu$embedding_dirty
         WHERE owner_schema = %L
    $sql$, p_schema, p_schema);
    EXECUTE format('GRANT SELECT ON %I.maludb_embedding_dirty TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_embedding_dirty', 'view', 'Pending entity-card re-embeds (staleness queue).');
    v_count := v_count + 1;

    -- semantic-edge introspection view (read-only) --------------------
    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_semantic_edge', 'view');
    EXECUTE format($sql$
        CREATE OR REPLACE VIEW %I.maludb_semantic_edge WITH (security_invoker = true) AS
        SELECT semantic_edge_id, object_kind, source_id, target_id,
               similarity, embedding_space, refreshed_at
          FROM maludb_core.malu$semantic_edge
         WHERE owner_schema = %L
    $sql$, p_schema, p_schema);
    EXECUTE format('GRANT SELECT ON %I.maludb_semantic_edge TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_semantic_edge', 'view', 'Materialized kNN similarity edges (traversal jump layer).');
    v_count := v_count + 1;

    -- card render ------------------------------------------------------
    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_embedding_card', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_embedding_card(p_object_kind text, p_object_id bigint)
        RETURNS TABLE(card_text text, content_hash text)
        LANGUAGE sql STABLE SECURITY INVOKER
        SET search_path = %I, maludb_core, pg_temp
        AS $facade$ SELECT * FROM maludb_core.embedding_card(p_object_kind, p_object_id) $facade$
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_embedding_card(text, bigint) FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_embedding_card(text, bigint) TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_embedding_card', 'function', 'Deterministic embedding-input card + content hash for an entity.');
    v_count := v_count + 1;

    -- worker protocol ---------------------------------------------------
    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_embedding_dirty_claim', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_embedding_dirty_claim(
            p_kinds text[] DEFAULT NULL, p_limit integer DEFAULT 64)
        RETURNS TABLE(object_kind text, object_id bigint, generation bigint,
                      card_text text, content_hash text)
        LANGUAGE sql SECURITY INVOKER
        SET search_path = %I, maludb_core, pg_temp
        AS $facade$ SELECT * FROM maludb_core.embedding_dirty_claim(p_kinds, p_limit) $facade$
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_embedding_dirty_claim(text[], integer) FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_embedding_dirty_claim(text[], integer) TO maludb_memory_admin, maludb_memory_executor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_embedding_dirty_claim', 'function', 'Claim pending entity cards for external embedding (SKIP LOCKED).');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_embedding_dirty_complete', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_embedding_dirty_complete(
            p_object_kind text, p_object_id bigint, p_generation bigint)
        RETURNS boolean
        LANGUAGE sql SECURITY INVOKER
        SET search_path = %I, maludb_core, pg_temp
        AS $facade$ SELECT maludb_core.embedding_dirty_complete(p_object_kind, p_object_id, p_generation) $facade$
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_embedding_dirty_complete(text, bigint, bigint) FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_embedding_dirty_complete(text, bigint, bigint) TO maludb_memory_admin, maludb_memory_executor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_embedding_dirty_complete', 'function', 'Retire a claimed queue row (generation-checked).');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_embedding_complete', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_embedding_complete(
            p_object_kind text, p_object_id bigint, p_generation bigint,
            p_embedding bytea, p_embedding_dim integer,
            p_embedding_space text DEFAULT 'entity-v1',
            p_embedding_model text DEFAULT NULL,
            p_content_hash text DEFAULT NULL,
            p_refresh_neighbors boolean DEFAULT true)
        RETURNS bigint
        LANGUAGE sql SECURITY INVOKER
        SET search_path = %I, maludb_core, pg_temp
        AS $facade$ SELECT maludb_core.embedding_complete(
            p_object_kind, p_object_id, p_generation, p_embedding, p_embedding_dim,
            p_embedding_space, p_embedding_model, p_content_hash, p_refresh_neighbors) $facade$
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_embedding_complete(text, bigint, bigint, bytea, integer, text, text, text, boolean) FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_embedding_complete(text, bigint, bigint, bytea, integer, text, text, text, boolean) TO maludb_memory_admin, maludb_memory_executor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_embedding_complete', 'function', 'Store an entity-card vector, retire the queue row, refresh semantic edges.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_embedding_requeue_all', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_embedding_requeue_all(p_object_kind text DEFAULT NULL)
        RETURNS integer
        LANGUAGE sql SECURITY INVOKER
        SET search_path = %I, maludb_core, pg_temp
        AS $facade$ SELECT maludb_core.embedding_requeue_all(p_object_kind) $facade$
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_embedding_requeue_all(text) FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_embedding_requeue_all(text) TO maludb_memory_admin, maludb_memory_executor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_embedding_requeue_all', 'function', 'Re-queue every entity for re-embedding (model/render change).');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_embedding_backfill', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_embedding_backfill()
        RETURNS integer
        LANGUAGE sql SECURITY INVOKER
        SET search_path = %I, maludb_core, pg_temp
        AS $facade$ SELECT maludb_core.embedding_backfill() $facade$
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_embedding_backfill() FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_embedding_backfill() TO maludb_memory_admin, maludb_memory_executor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_embedding_backfill', 'function', 'Queue entities that have no entity-card vector yet.');
    v_count := v_count + 1;

    -- semantic edges ----------------------------------------------------
    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_semantic_edges_refresh', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_semantic_edges_refresh(
            p_object_kind text, p_object_id bigint,
            p_k integer DEFAULT 5, p_min_similarity double precision DEFAULT 0.80,
            p_embedding_space text DEFAULT 'entity-v1')
        RETURNS integer
        LANGUAGE sql SECURITY INVOKER
        SET search_path = %I, maludb_core, pg_temp
        AS $facade$ SELECT maludb_core.semantic_edges_refresh(
            p_object_kind, p_object_id, p_k, p_min_similarity, p_embedding_space) $facade$
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_semantic_edges_refresh(text, bigint, integer, double precision, text) FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_semantic_edges_refresh(text, bigint, integer, double precision, text) TO maludb_memory_admin, maludb_memory_executor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_semantic_edges_refresh', 'function', 'Rebuild one node''s materialized similarity edges.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_semantic_edges_refresh_all', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_semantic_edges_refresh_all(
            p_object_kind text DEFAULT NULL, p_batch integer DEFAULT 200,
            p_k integer DEFAULT 5, p_min_similarity double precision DEFAULT 0.80,
            p_embedding_space text DEFAULT 'entity-v1')
        RETURNS integer
        LANGUAGE sql SECURITY INVOKER
        SET search_path = %I, maludb_core, pg_temp
        AS $facade$ SELECT maludb_core.semantic_edges_refresh_all(
            p_object_kind, p_batch, p_k, p_min_similarity, p_embedding_space) $facade$
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_semantic_edges_refresh_all(text, integer, integer, double precision, text) FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_semantic_edges_refresh_all(text, integer, integer, double precision, text) TO maludb_memory_admin, maludb_memory_executor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_semantic_edges_refresh_all', 'function', 'Sweep-refresh materialized similarity edges.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_semantic_neighbors', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_semantic_neighbors(
            p_kind text, p_id bigint, p_k integer DEFAULT 5,
            p_min_similarity double precision DEFAULT 0.70,
            p_embedding_space text DEFAULT 'entity-v1')
        RETURNS TABLE(neighbor_kind text, neighbor_id bigint, similarity double precision, label text)
        LANGUAGE sql STABLE SECURITY INVOKER
        SET search_path = %I, maludb_core, pg_temp
        AS $facade$ SELECT * FROM maludb_core.uedge_semantic_neighbors(
            p_kind, p_id, p_k, p_min_similarity, p_embedding_space) $facade$
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_semantic_neighbors(text, bigint, integer, double precision, text) FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_semantic_neighbors(text, bigint, integer, double precision, text) TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_semantic_neighbors', 'function', 'Query-time semantic neighbors (fresh, unmaterialized).');
    v_count := v_count + 1;

    RETURN v_count;
END;
$body$;

REVOKE ALL ON FUNCTION maludb_core._enable_memory_schema_0950_facade(name) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core._enable_memory_schema_0950_facade(name)
    TO maludb_memory_admin, maludb_memory_executor;

-- ---------------------------------------------------------------------
-- 9. Wire the 0950 facade into enable_memory_schema.
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
    v_count := v_count + maludb_core._enable_memory_schema_0950_facade(p_schema);
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
-- 10. Upgrade seeding: queue every existing subject/verb/statement so
--     the worker's first run embeds the world. No-op on fresh installs
--     (tables are empty); idempotent (PK + DO NOTHING).
-- ---------------------------------------------------------------------
DO $do$
BEGIN
    INSERT INTO maludb_core.malu$embedding_dirty (owner_schema, object_kind, object_id, reason)
    SELECT s.owner_schema, 'subject', s.subject_id, 'backfill-0.95.0'
      FROM maludb_core.malu$svpor_subject s
    UNION ALL
    SELECT v.owner_schema, 'verb', v.verb_id, 'backfill-0.95.0'
      FROM maludb_core.malu$svpor_verb v
    UNION ALL
    SELECT st.owner_schema, 'svpor_statement', st.statement_id, 'backfill-0.95.0'
      FROM maludb_core.malu$svpor_statement st
    ON CONFLICT (owner_schema, object_kind, object_id) DO NOTHING;
END
$do$;

-- ---------------------------------------------------------------------
-- 11. NOTE: tenant facades are NOT auto-refreshed here (extension
--     scripts cannot replace tenant-schema objects). Each memory-enabled
--     schema picks up the 0.95.0 facades by re-running
--     maludb_core.enable_memory_schema(). The dirty queue, triggers,
--     semantic-edge table, edge-view arms and the traversal guard are
--     fully active immediately after this migration regardless.
-- ---------------------------------------------------------------------
