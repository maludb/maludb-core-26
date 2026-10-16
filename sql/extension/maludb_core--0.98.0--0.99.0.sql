\echo Use "ALTER EXTENSION maludb_core UPDATE TO '0.99.0'" to load this file. \quit

-- =====================================================================
-- maludb_core 0.98.0 -> 0.99.0  --  skill reindex protocol
--
-- A skill's discovery tags (subjects/verbs/keywords in
-- malu$skill_subject / _verb / _keyword) are written ONCE, at
-- registration, from whatever the external API server's extractor
-- handed maludb_skill_register. Two problems accrue over time:
--   1. the SVPOR vocabulary keeps growing -- new subjects and verbs
--      get minted after a skill was loaded -- so an old skill never
--      links to terms that did not exist when it was registered; and
--   2. if the extractor did a poor job at load time, the weak tag set
--      is frozen in place and find_skill() silently degrades to the
--      +10 full-text fallback (the high-weight subject/verb facets
--      never fire).
--
-- This release ships the DATABASE half of a background "reindex"
-- protocol that re-derives those tags against the CURRENT graph.
-- Core never calls a model (the documented extraction boundary); it
-- exposes a claim -> apply contract an external worker drives:
--
--     loop:
--       rows = maludb_skill_reindex_claim(limit, max_age)   -- stalest first
--       for r in rows:
--           tags = model.extract(r.markdown, current_registry)  -- worker side
--           maludb_skill_reindex_apply(r.skill_id, tags.subjects,
--                                      tags.verbs, tags.keywords, MODEL)
--
--   1. malu$skill_package gains last_indexed (the watermark that stops
--      repeat work) and last_indexed_model (which model produced the
--      current tags -- the hook for migrating to a cheaper model later:
--      a future sweep can re-pick rows tagged by a superseded model).
--      Both are lifecycle metadata, untouched by the 0.97.0
--      _skill_package_content_guard (it only freezes markdown /
--      bundle_hash / frontmatter_jsonb / skill_name).
--   2. _skill_reindex_claim_for_schema: a registry-aware staleness
--      scan. Returns the skill body + its current tags so the worker
--      can show the model what exists today, picking skills that were
--      never indexed, indexed before p_max_age ago, or indexed before
--      the newest subject/verb was minted (max(created_at) over the
--      tenant svpor_subject/verb tables). NOTE: created_at catches
--      ADDITIONS; edits to an existing subject's aliases/description
--      are not timestamped on those tables, so they are picked up by
--      the periodic p_max_age clause rather than instantly. Plain
--      ranked SELECT -- the apply stamps last_indexed and is
--      idempotent, so overlapping sweeps just redo equivalent work.
--   3. _skill_reindex_apply_for_schema: REPLACE-extracted. Deletes the
--      skill's provenance='extracted' subject/verb/keyword rows and
--      rewrites them from the fresh extraction (same name->id
--      resolution as registration). provenance='manual' curator tags
--      are never touched. Stamps last_indexed / last_indexed_model.
--      Because it can remove tags, it also corrects a bad initial load
--      (problem #2), not just augment (problem #1).
--   4. Tenant facades maludb_skill_reindex_claim (read-only -> auditor
--      gets EXECUTE, the maludb_memory_search posture) and
--      maludb_skill_reindex_apply (a write) via a new _0990 builder.
--      In maludb_public the apply facade is curator-only, mirroring
--      the 0.97.0 maludb_skill_register write posture. The builder
--      creates ONLY the two objects it introduces -- no CREATE OR
--      REPLACE of earlier facades, no re-grants. Tenants pick the
--      functions up by re-running enable_memory_schema().
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Watermark columns on the skill package.
-- ---------------------------------------------------------------------
ALTER TABLE maludb_core.malu$skill_package
    ADD COLUMN IF NOT EXISTS last_indexed       timestamptz,
    ADD COLUMN IF NOT EXISTS last_indexed_model text;

-- ---------------------------------------------------------------------
-- 2. _skill_reindex_claim_for_schema. SECURITY DEFINER bypasses RLS, so
--    every tenant table carries an explicit owner_schema predicate. The
--    registry watermark is the max created_at over this tenant's
--    subjects and verbs (NULL when the graph is empty).
-- ---------------------------------------------------------------------
CREATE FUNCTION maludb_core._skill_reindex_claim_for_schema(
    p_schema          name,
    p_limit           integer  DEFAULT 32,
    p_max_age         interval DEFAULT '30 days',
    p_only_registered boolean  DEFAULT true
) RETURNS TABLE (
    skill_id           bigint,
    skill_name         text,
    version            text,
    description        text,
    markdown           text,
    frontmatter_jsonb  jsonb,
    bundle_hash        text,
    last_indexed       timestamptz,
    last_indexed_model text,
    current_subjects   jsonb,
    current_verbs      jsonb,
    current_keywords   jsonb
) LANGUAGE plpgsql STABLE
SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
#variable_conflict use_column
DECLARE
    v_limit     integer := LEAST(GREATEST(COALESCE(p_limit, 32), 1), 500);
    v_cutoff    timestamptz := CASE WHEN p_max_age IS NULL THEN NULL ELSE now() - p_max_age END;
    v_watermark timestamptz;
BEGIN
    PERFORM maludb_core._memory_schema_assert_manageable(p_schema);

    SELECT max(c) INTO v_watermark
      FROM (
        SELECT max(created_at) AS c FROM maludb_core.malu$svpor_subject WHERE owner_schema = p_schema
        UNION ALL
        SELECT max(created_at)      FROM maludb_core.malu$svpor_verb    WHERE owner_schema = p_schema
      ) w;

    RETURN QUERY
    SELECT sp.skill_id, sp.skill_name, sp.version, sp.description, sp.markdown,
           sp.frontmatter_jsonb, sp.bundle_hash, sp.last_indexed, sp.last_indexed_model,
           COALESCE((
               SELECT jsonb_agg(jsonb_build_object(
                          'name', ss.subject_name, 'id', ss.subject_id,
                          'weight', ss.weight, 'provenance', ss.provenance)
                      ORDER BY ss.subject_name)
                 FROM maludb_core.malu$skill_subject ss
                WHERE ss.owner_schema = p_schema AND ss.skill_id = sp.skill_id), '[]'::jsonb),
           COALESCE((
               SELECT jsonb_agg(jsonb_build_object(
                          'name', sv.verb_name, 'id', sv.verb_id,
                          'weight', sv.weight, 'provenance', sv.provenance)
                      ORDER BY sv.verb_name)
                 FROM maludb_core.malu$skill_verb sv
                WHERE sv.owner_schema = p_schema AND sv.skill_id = sp.skill_id), '[]'::jsonb),
           COALESCE((
               SELECT jsonb_agg(jsonb_build_object(
                          'keyword', sk.keyword,
                          'weight', sk.weight, 'provenance', sk.provenance)
                      ORDER BY sk.keyword)
                 FROM maludb_core.malu$skill_keyword sk
                WHERE sk.owner_schema = p_schema AND sk.skill_id = sp.skill_id), '[]'::jsonb)
      FROM maludb_core.malu$skill_package sp
     WHERE sp.owner_schema = p_schema
       AND sp.enabled
       AND (NOT p_only_registered OR sp.bundle_hash IS NOT NULL)
       AND (sp.last_indexed IS NULL
            OR (v_cutoff    IS NOT NULL AND sp.last_indexed < v_cutoff)
            OR (v_watermark IS NOT NULL AND sp.last_indexed < v_watermark))
     ORDER BY sp.last_indexed NULLS FIRST, sp.skill_id
     LIMIT v_limit;
END;
$body$;

REVOKE ALL ON FUNCTION maludb_core._skill_reindex_claim_for_schema(name, integer, interval, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core._skill_reindex_claim_for_schema(name, integer, interval, boolean)
    TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;

-- ---------------------------------------------------------------------
-- 3. _skill_reindex_apply_for_schema. Replace the skill's 'extracted'
--    discovery tags with a fresh set; preserve 'manual' tags. The
--    subject/verb name->id resolution mirrors
--    _register_agent_skill_for_schema (a supplied id is honoured only
--    when it still resolves in this tenant's registry, else NULL). The
--    last_indexed UPDATE leaves markdown/bundle_hash/frontmatter/name
--    untouched, so the content-immutability guard passes.
-- ---------------------------------------------------------------------
CREATE FUNCTION maludb_core._skill_reindex_apply_for_schema(
    p_schema   name,
    p_skill_id bigint,
    p_subjects jsonb   DEFAULT NULL,
    p_verbs    jsonb   DEFAULT NULL,
    p_keywords text[]  DEFAULT NULL,
    p_model    text    DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
DECLARE
    v_model    text := NULLIF(btrim(COALESCE(p_model, '')), '');
    r          record;
    v_tag_name text;
    v_tag_id   bigint;
    v_kw       text;
    c_kw integer := 0; c_subj integer := 0; c_verb integer := 0;
    d_kw integer := 0; d_subj integer := 0; d_verb integer := 0;
BEGIN
    PERFORM maludb_core._memory_schema_assert_manageable(p_schema);

    -- Lock the row; also asserts existence in this tenant.
    PERFORM 1 FROM maludb_core.malu$skill_package
     WHERE owner_schema = p_schema AND skill_id = p_skill_id
     FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'skill_reindex_apply: skill % not found in schema %', p_skill_id, p_schema
            USING ERRCODE = 'P0002';
    END IF;

    -- Drop the prior machine-extracted tag set (curator 'manual' rows stay).
    WITH d AS (DELETE FROM maludb_core.malu$skill_subject
                WHERE owner_schema = p_schema AND skill_id = p_skill_id AND provenance = 'extracted'
                RETURNING 1)
    SELECT count(*) INTO d_subj FROM d;
    WITH d AS (DELETE FROM maludb_core.malu$skill_verb
                WHERE owner_schema = p_schema AND skill_id = p_skill_id AND provenance = 'extracted'
                RETURNING 1)
    SELECT count(*) INTO d_verb FROM d;
    WITH d AS (DELETE FROM maludb_core.malu$skill_keyword
                WHERE owner_schema = p_schema AND skill_id = p_skill_id AND provenance = 'extracted'
                RETURNING 1)
    SELECT count(*) INTO d_kw FROM d;

    -- Rewrite from the fresh extraction (ON CONFLICT DO NOTHING yields
    -- to any surviving 'manual' tag of the same name).
    FOREACH v_kw IN ARRAY COALESCE(p_keywords, ARRAY[]::text[])
    LOOP
        CONTINUE WHEN btrim(COALESCE(v_kw, '')) = '';
        INSERT INTO maludb_core.malu$skill_keyword(owner_schema, skill_id, keyword, provenance)
        VALUES (p_schema, p_skill_id, btrim(v_kw), 'extracted')
        ON CONFLICT (owner_schema, skill_id, lower(keyword)) DO NOTHING;
        c_kw := c_kw + 1;
    END LOOP;

    FOR r IN SELECT val FROM jsonb_array_elements(COALESCE(p_subjects, '[]'::jsonb)) AS t(val)
    LOOP
        v_tag_name := btrim(COALESCE(r.val ->> 'name', ''));
        CONTINUE WHEN v_tag_name = '';
        v_tag_id := NULLIF(btrim(COALESCE(r.val ->> 'id', '')), '')::bigint;
        IF v_tag_id IS NOT NULL AND NOT EXISTS (
            SELECT 1 FROM maludb_core.malu$svpor_subject
             WHERE owner_schema = p_schema AND subject_id = v_tag_id) THEN
            v_tag_id := NULL;
        END IF;
        INSERT INTO maludb_core.malu$skill_subject(owner_schema, skill_id, subject_id, subject_name, weight, provenance)
        VALUES (p_schema, p_skill_id, v_tag_id, v_tag_name,
                COALESCE(NULLIF(btrim(COALESCE(r.val ->> 'weight', '')), '')::numeric, 1.0), 'extracted')
        ON CONFLICT (owner_schema, skill_id, lower(subject_name)) DO NOTHING;
        c_subj := c_subj + 1;
    END LOOP;

    FOR r IN SELECT val FROM jsonb_array_elements(COALESCE(p_verbs, '[]'::jsonb)) AS t(val)
    LOOP
        v_tag_name := btrim(COALESCE(r.val ->> 'name', ''));
        CONTINUE WHEN v_tag_name = '';
        v_tag_id := NULLIF(btrim(COALESCE(r.val ->> 'id', '')), '')::bigint;
        IF v_tag_id IS NOT NULL AND NOT EXISTS (
            SELECT 1 FROM maludb_core.malu$svpor_verb
             WHERE owner_schema = p_schema AND verb_id = v_tag_id) THEN
            v_tag_id := NULL;
        END IF;
        INSERT INTO maludb_core.malu$skill_verb(owner_schema, skill_id, verb_id, verb_name, weight, provenance)
        VALUES (p_schema, p_skill_id, v_tag_id, v_tag_name,
                COALESCE(NULLIF(btrim(COALESCE(r.val ->> 'weight', '')), '')::numeric, 1.0), 'extracted')
        ON CONFLICT (owner_schema, skill_id, lower(verb_name)) DO NOTHING;
        c_verb := c_verb + 1;
    END LOOP;

    UPDATE maludb_core.malu$skill_package
       SET last_indexed       = now(),
           last_indexed_model = v_model,
           updated_at         = now()
     WHERE owner_schema = p_schema AND skill_id = p_skill_id;

    RETURN jsonb_build_object(
        'skill_id',           p_skill_id,
        'last_indexed_model', v_model,
        'replaced',           jsonb_build_object('subjects', d_subj, 'verbs', d_verb, 'keywords', d_kw),
        'written',            jsonb_build_object('subjects', c_subj, 'verbs', c_verb, 'keywords', c_kw));
END;
$body$;

REVOKE ALL ON FUNCTION maludb_core._skill_reindex_apply_for_schema(name, bigint, jsonb, jsonb, text[], text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core._skill_reindex_apply_for_schema(name, bigint, jsonb, jsonb, text[], text)
    TO maludb_memory_admin, maludb_memory_executor;

-- ---------------------------------------------------------------------
-- 4. 0990 facade builder: maludb_skill_reindex_claim (read-only) +
--    maludb_skill_reindex_apply (write). maludb_public keeps the
--    curator-only write posture of the other skill facades.
-- ---------------------------------------------------------------------
CREATE FUNCTION maludb_core._enable_memory_schema_0990_facade(p_schema name) RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
DECLARE
    v_count integer := 0;
BEGIN
    PERFORM maludb_core._memory_schema_assert_manageable(p_schema);

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_skill_reindex_claim', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_skill_reindex_claim(
            p_limit           integer  DEFAULT 32,
            p_max_age         interval DEFAULT '30 days',
            p_only_registered boolean  DEFAULT true
        ) RETURNS TABLE (
            skill_id           bigint,
            skill_name         text,
            version            text,
            description        text,
            markdown           text,
            frontmatter_jsonb  jsonb,
            bundle_hash        text,
            last_indexed       timestamptz,
            last_indexed_model text,
            current_subjects   jsonb,
            current_verbs      jsonb,
            current_keywords   jsonb
        )
        LANGUAGE SQL STABLE
        SECURITY DEFINER
        SET search_path = pg_catalog, maludb_core, pg_temp
        AS $fn$
            SELECT * FROM maludb_core._skill_reindex_claim_for_schema(
                %L::name, p_limit, p_max_age, p_only_registered)
        $fn$;
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_skill_reindex_claim(integer, interval, boolean) FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_skill_reindex_claim(integer, interval, boolean) TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_skill_reindex_claim', 'function', 'Schema-local stalest-first scan of skills due for tag reindexing.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_skill_reindex_apply', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_skill_reindex_apply(
            p_skill_id bigint,
            p_subjects jsonb  DEFAULT NULL,
            p_verbs    jsonb  DEFAULT NULL,
            p_keywords text[] DEFAULT NULL,
            p_model    text   DEFAULT NULL
        ) RETURNS jsonb
        LANGUAGE SQL
        SECURITY DEFINER
        SET search_path = pg_catalog, maludb_core, pg_temp
        AS $fn$
            SELECT maludb_core._skill_reindex_apply_for_schema(
                %L::name, p_skill_id, p_subjects, p_verbs, p_keywords, p_model)
        $fn$;
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_skill_reindex_apply(bigint, jsonb, jsonb, text[], text) FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_skill_reindex_apply(bigint, jsonb, jsonb, text[], text) TO maludb_memory_admin, maludb_memory_executor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_skill_reindex_apply', 'function', 'Schema-local replace-extracted skill tag reindex apply.');
    v_count := v_count + 1;

    IF p_schema = 'maludb_public' THEN
        EXECUTE format('REVOKE EXECUTE ON FUNCTION %I.maludb_skill_reindex_apply(bigint, jsonb, jsonb, text[], text) FROM maludb_memory_executor', p_schema);
        EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_skill_reindex_apply(bigint, jsonb, jsonb, text[], text) TO maludb_skill_curator', p_schema);
    END IF;

    RETURN v_count;
END;
$body$;

REVOKE ALL ON FUNCTION maludb_core._enable_memory_schema_0990_facade(name) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core._enable_memory_schema_0990_facade(name)
    TO maludb_memory_admin, maludb_memory_executor;

-- ---------------------------------------------------------------------
-- 5. Wire the 0990 facade into enable_memory_schema. Functions only --
--    the drop-first view list is untouched.
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

    FOREACH v_view IN ARRAY ARRAY['maludb_subject','maludb_memory','maludb_skill','maludb_document','maludb_svpor_attribute','maludb_episode','maludb_episode_with_attributes','maludb_subject_type']::name[]
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
    v_count := v_count + maludb_core._enable_memory_schema_0960_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_0970_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_0980_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_0990_facade(p_schema);
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
-- 6. Version stamp.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION maludb_core.maludb_core_version() RETURNS text
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$ SELECT '0.99.0'::text $body$;
