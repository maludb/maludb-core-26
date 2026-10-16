\echo Use "ALTER EXTENSION maludb_core UPDATE TO '0.97.0'" to load this file. \quit

-- =====================================================================
-- maludb_core 0.96.0 -> 0.97.0  --  agent-skill distribution
--
-- Skills become distributable, immutable, multi-file artifacts so that
-- Claude Agent Skills (SKILL.md bundles: instructions plus scripts/,
-- references/, assets/) can be ingested, discovered, and shared across
-- project teams with the database as the distribution point.
--
-- The 0.73.0 skill-discovery layer already carries most of the model:
-- fork lineage (source_owner_schema / source_skill_id / forked_at),
-- private/shared/public visibility, keyword/subject/verb discovery
-- tags, description embeddings, and enabled-gated visibility. This
-- release adds what an agent-skill bundle needs on top:
--
--   1. A curated 'skill' ENTITY subject type, so extraction can mint a
--      graph subject per skill (catalog-driven prompts pick it up).
--   2. Content identity on malu$skill_package: bundle_hash (sha256 over
--      the sorted per-file hashes -- a script edit changes the bundle
--      even when SKILL.md is untouched) and frontmatter_jsonb (the
--      parsed SKILL.md YAML frontmatter, verbatim).
--   3. malu$skill_file: the bundle manifest. One row per file,
--      content stored as a deduplicatable malu$source_package, with
--      relative_path + is_executable so a client can reconstruct the
--      directory faithfully ("skill pull").
--   4. Registered agent skills are CONTENT-IMMUTABLE: once bundle_hash
--      is set, markdown / bundle_hash / frontmatter_jsonb reject
--      UPDATE. A changed skill is re-registered as a NEW row whose
--      source_* columns point at the row it forked from. Lineage is a
--      strictly DIVERGENT DAG (no merges -- decided 2026-06-10).
--   5. register_agent_skill: one-call registration used by the API
--      server after maludb_memory_ingest_extraction. Dedupes on
--      (skill_name, bundle_hash), stamps lineage, fills the discovery
--      tags with provenance 'extracted', links bundle files, and --
--      when the new version is NOT materially different from its
--      parent -- supersedes the parent (enabled = false; disabled
--      skills drop out of find_skill/_skill_is_visible). Materially
--      different versions coexist as visible siblings.
--   6. fork_skill bug fix: the 0.73.0 body predates the 0.80.0
--      markdown column and never copied it, so forks silently lost
--      the skill body. Forks now copy markdown, bundle_hash,
--      frontmatter_jsonb, and the file bundle (content re-anchored
--      as source packages in the target schema, deduped by hash).
--   7. get_skill payload gains a 'files' array; the maludb_skill
--      facade gains bundle_hash + frontmatter_jsonb; new
--      maludb_skill_file view and maludb_skill_register wrapper
--      (new _0970 facade builder; maludb_skill is already in the
--      enable_memory_schema drop-first list, so its column set can
--      grow across re-enables). Tenants pick the new objects up by
--      re-running enable_memory_schema().
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. 'skill' entity subject type. Entity types are the closed,
--    curated allow-list (_normalize_svpor_subject_type raises on
--    unknown), so the type must be seeded before an extraction can
--    emit subjects of type 'skill'. Description discriminates the
--    neighbours an extraction model would confuse it with.
-- ---------------------------------------------------------------------
INSERT INTO maludb_core.malu$svpor_subject_type
        (subject_type, display_name, description, sort_order, system_defined, category) VALUES
    ('skill', 'Skill',
     'A packaged, reusable instruction set an AI agent loads to perform a class of task (e.g. a Claude Agent Skill: SKILL.md plus scripts and references). Content, not a running application (''software'') and not an executed procedure (''workflow'').',
     110, true, 'entity')
ON CONFLICT (subject_type) DO UPDATE
    SET display_name   = EXCLUDED.display_name,
        description    = EXCLUDED.description,
        sort_order     = EXCLUDED.sort_order,
        system_defined = true,
        category       = 'entity';

-- ---------------------------------------------------------------------
-- 2. Content identity columns. NULL on every pre-existing row: only
--    registered agent skills carry a bundle hash, and only they are
--    content-immutable (section 4) -- hand-curated skills keep their
--    current editable behaviour.
-- ---------------------------------------------------------------------
ALTER TABLE maludb_core.malu$skill_package
    ADD COLUMN IF NOT EXISTS bundle_hash text,
    ADD COLUMN IF NOT EXISTS frontmatter_jsonb jsonb;

-- ---------------------------------------------------------------------
-- 3. Bundle manifest. File content lives in malu$source_package
--    (content-hash dedupe, retention/sensitivity machinery for free);
--    this table contributes the directory shape. relative_path rejects
--    absolute paths and '..' segments because pull-side clients write
--    these paths to their filesystem.
-- ---------------------------------------------------------------------
INSERT INTO maludb_core.malu$source_type(source_type, stage, description)
VALUES ('skill_file', 2, 'A file belonging to an agent-skill bundle (script, reference, or asset).')
ON CONFLICT (source_type) DO UPDATE
    SET stage = EXCLUDED.stage,
        description = EXCLUDED.description;

CREATE TABLE maludb_core.malu$skill_file (
    skill_file_id     bigserial PRIMARY KEY,
    owner_schema      name NOT NULL DEFAULT current_schema(),
    skill_id          bigint NOT NULL,
    relative_path     text NOT NULL
        CHECK (relative_path <> ''
               AND relative_path !~ '^/'
               AND relative_path !~ '(^|/)\.\.(/|$)'),
    source_package_id bigint NOT NULL
        REFERENCES maludb_core.malu$source_package(source_package_id) ON DELETE RESTRICT,
    file_hash         text NOT NULL,
    file_size         bigint NOT NULL CHECK (file_size >= 0),
    is_executable     boolean NOT NULL DEFAULT false,
    media_type        text,
    created_at        timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (owner_schema, skill_id)
        REFERENCES maludb_core.malu$skill_package(owner_schema, skill_id) ON DELETE CASCADE,
    UNIQUE (owner_schema, skill_id, relative_path)
);
CREATE INDEX malu$skill_file_owner_skill_idx
    ON maludb_core.malu$skill_file(owner_schema, skill_id);

ALTER TABLE maludb_core.malu$skill_file ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_owner ON maludb_core.malu$skill_file
    USING (owner_schema = current_schema())
    WITH CHECK (owner_schema = current_schema());

GRANT SELECT ON maludb_core.malu$skill_file TO
    maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;
-- No UPDATE grant: a bundle file row is immutable; rows die with the skill.
GRANT INSERT, DELETE ON maludb_core.malu$skill_file TO
    maludb_memory_admin, maludb_memory_executor;
GRANT USAGE, SELECT ON SEQUENCE maludb_core.malu$skill_file_skill_file_id_seq TO
    maludb_memory_admin, maludb_memory_executor;

-- ---------------------------------------------------------------------
-- 4a. Discovery-tag provenance widens to admit machine extraction.
--     CHECK-rebuild rule (0.82.0 bug class): the widest historical
--     list for these three constraints is ('manual') -- defined once,
--     in 0.73.0, never rebuilt since -- so the new list is a strict
--     superset of every list ever shipped.
-- ---------------------------------------------------------------------
DO $body$
DECLARE
    v_tbl text;
    v_con record;
BEGIN
    FOREACH v_tbl IN ARRAY ARRAY['malu$skill_keyword','malu$skill_subject','malu$skill_verb']
    LOOP
        -- Drop by DEFINITION, not by assumed auto-generated name: a name
        -- miss here would leave the narrow ('manual') CHECK alive and
        -- every 'extracted' insert failing.
        FOR v_con IN
            SELECT c.conname
              FROM pg_constraint c
             WHERE c.conrelid = format('maludb_core.%I', v_tbl)::regclass
               AND c.contype = 'c'
               AND pg_get_constraintdef(c.oid) ILIKE '%provenance%'
        LOOP
            EXECUTE format('ALTER TABLE maludb_core.%I DROP CONSTRAINT %I', v_tbl, v_con.conname);
        END LOOP;
        EXECUTE format($sql$ALTER TABLE maludb_core.%I
                           ADD CONSTRAINT %I CHECK (provenance IN ('manual','extracted'))$sql$,
                       v_tbl, v_tbl || '_provenance_check');
    END LOOP;
END;
$body$;

-- ---------------------------------------------------------------------
-- 4b. Content immutability. Once a row carries a bundle_hash it is a
--     registered agent skill: its content columns reject UPDATE, and a
--     changed bundle must re-register as a new row (new skill_id, new
--     lineage edge). Lifecycle columns (enabled, visibility,
--     description, applicability/precondition, access) stay mutable.
-- ---------------------------------------------------------------------
CREATE FUNCTION maludb_core._skill_package_content_guard() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
BEGIN
    IF OLD.bundle_hash IS NOT NULL
       AND (NEW.markdown          IS DISTINCT FROM OLD.markdown
            OR NEW.bundle_hash       IS DISTINCT FROM OLD.bundle_hash
            OR NEW.frontmatter_jsonb IS DISTINCT FROM OLD.frontmatter_jsonb
            OR NEW.skill_name        IS DISTINCT FROM OLD.skill_name) THEN
        RAISE EXCEPTION 'skill % (%) is a registered agent skill and content-immutable; register the changed bundle as a new skill version instead',
            OLD.skill_id, OLD.skill_name
            USING ERRCODE = 'integrity_constraint_violation',
                  HINT = 'Use maludb_skill_register(); lifecycle columns (enabled, visibility, description) remain updatable.';
    END IF;
    RETURN NEW;
END;
$body$;

CREATE TRIGGER malu$skill_package_content_guard
    BEFORE UPDATE ON maludb_core.malu$skill_package
    FOR EACH ROW
    EXECUTE FUNCTION maludb_core._skill_package_content_guard();

-- ---------------------------------------------------------------------
-- 5. fork_skill: copy the body and the bundle. The 0.73.0 body
--    predates the 0.80.0 markdown column, so every fork to date
--    silently dropped the skill body. The replacement copies markdown,
--    bundle_hash, frontmatter_jsonb, and re-anchors each bundle file
--    as a source package in the TARGET schema (deduped on
--    content_hash + source_type) so the fork is self-contained --
--    RLS would hide the source schema's packages from the new owner.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION maludb_core.fork_skill(
    p_source_owner_schema name,
    p_source_skill_id bigint,
    p_target_owner_schema name DEFAULT current_schema(),
    p_new_skill_name text DEFAULT NULL,
    p_new_version text DEFAULT '1.0.0'
) RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
DECLARE
    v_source maludb_core.malu$skill_package%ROWTYPE;
    v_new_skill_id bigint;
    v_state record;
    v_new_state_id bigint;
    v_file record;
    v_sp maludb_core.malu$source_package%ROWTYPE;
    v_new_sp_id bigint;
    v_caller_role name := COALESCE(NULLIF(current_setting('role', true), 'none'), session_user)::name;
    v_state_map_table name := format(
        'maludb_fork_state_map_%s_%s',
        pg_backend_pid(),
        replace(gen_random_uuid()::text, '-', '')
    );
BEGIN
    IF NOT maludb_core._memory_schema_is_owned_by_current_role(p_target_owner_schema) THEN
        RAISE EXCEPTION 'fork_skill: target schema % is not owned by current role', p_target_owner_schema
            USING ERRCODE = '42501';
    END IF;

    SELECT * INTO v_source
      FROM maludb_core.malu$skill_package
     WHERE owner_schema = p_source_owner_schema
       AND skill_id = p_source_skill_id
       AND maludb_core._skill_is_visible(owner_schema, skill_id, p_target_owner_schema, true);

    IF NOT FOUND THEN
        RAISE EXCEPTION 'fork_skill: source skill %.% not found or not visible', p_source_owner_schema, p_source_skill_id
            USING ERRCODE = 'P0002';
    END IF;

    IF NOT (
        (v_source.owner_schema = 'maludb_public' AND v_source.visibility = 'public')
        OR EXISTS (
            SELECT 1
              FROM maludb_core.malu$skill_access a
             WHERE a.owner_schema = v_source.owner_schema
               AND a.skill_id = v_source.skill_id
               AND pg_catalog.pg_has_role(v_caller_role, a.grantee_role, 'member')
               AND a.access_level = 'fork'
        )
    ) THEN
        RAISE EXCEPTION 'fork_skill: source skill %.% is not forkable', p_source_owner_schema, p_source_skill_id
            USING ERRCODE = '42501';
    END IF;

    INSERT INTO maludb_core.malu$skill_package(
        owner_schema,
        skill_name,
        version,
        description,
        packaging_kind,
        applicability_jsonb,
        precondition_jsonb,
        enabled,
        visibility,
        source_owner_schema,
        source_skill_id,
        forked_at,
        markdown,
        bundle_hash,
        frontmatter_jsonb
    )
    VALUES (
        p_target_owner_schema,
        COALESCE(NULLIF(p_new_skill_name, ''), v_source.skill_name),
        COALESCE(NULLIF(p_new_version, ''), v_source.version),
        v_source.description,
        v_source.packaging_kind,
        v_source.applicability_jsonb,
        v_source.precondition_jsonb,
        v_source.enabled,
        'private',
        v_source.owner_schema,
        v_source.skill_id,
        now(),
        v_source.markdown,
        v_source.bundle_hash,
        v_source.frontmatter_jsonb
    )
    RETURNING skill_id INTO v_new_skill_id;

    INSERT INTO maludb_core.malu$skill_keyword(owner_schema, skill_id, keyword, weight, provenance)
    SELECT p_target_owner_schema, v_new_skill_id, keyword, weight, provenance
      FROM maludb_core.malu$skill_keyword
     WHERE owner_schema = v_source.owner_schema
       AND skill_id = v_source.skill_id
     ORDER BY keyword, keyword_id;

    INSERT INTO maludb_core.malu$skill_subject(owner_schema, skill_id, subject_id, subject_name, weight, provenance)
    SELECT p_target_owner_schema, v_new_skill_id, NULL, subject_name, weight, provenance
      FROM maludb_core.malu$skill_subject
     WHERE owner_schema = v_source.owner_schema
       AND skill_id = v_source.skill_id
     ORDER BY subject_name, skill_subject_id;

    INSERT INTO maludb_core.malu$skill_verb(owner_schema, skill_id, verb_id, verb_name, weight, provenance)
    SELECT p_target_owner_schema, v_new_skill_id, NULL, verb_name, weight, provenance
      FROM maludb_core.malu$skill_verb
     WHERE owner_schema = v_source.owner_schema
       AND skill_id = v_source.skill_id
     ORDER BY verb_name, skill_verb_id;

    INSERT INTO maludb_core.malu$skill_embedding(
        owner_schema,
        skill_id,
        embedding_model,
        embedding_dim,
        embedding,
        source_text_hash,
        source_text_kind
    )
    SELECT p_target_owner_schema,
           v_new_skill_id,
           embedding_model,
           embedding_dim,
           embedding,
           source_text_hash,
           source_text_kind
      FROM maludb_core.malu$skill_embedding
     WHERE owner_schema = v_source.owner_schema
       AND skill_id = v_source.skill_id
     ORDER BY embedding_model, source_text_kind, source_text_hash, embedding_id;

    FOR v_file IN
        SELECT *
          FROM maludb_core.malu$skill_file
         WHERE owner_schema = v_source.owner_schema
           AND skill_id = v_source.skill_id
         ORDER BY relative_path, skill_file_id
    LOOP
        SELECT * INTO v_sp
          FROM maludb_core.malu$source_package
         WHERE source_package_id = v_file.source_package_id;

        SELECT sp.source_package_id INTO v_new_sp_id
          FROM maludb_core.malu$source_package sp
         WHERE sp.owner_schema = p_target_owner_schema
           AND sp.content_hash = v_sp.content_hash
           AND sp.source_type = v_sp.source_type
         ORDER BY sp.source_package_id
         LIMIT 1;

        IF v_new_sp_id IS NULL THEN
            INSERT INTO maludb_core.malu$source_package(
                owner_schema, source_type,
                content_bytes, content_text, content_jsonb,
                content_hash, content_size, media_type,
                origin_jsonb, captured_at,
                retention_class, sensitivity
            )
            VALUES (
                p_target_owner_schema, v_sp.source_type,
                v_sp.content_bytes, v_sp.content_text, v_sp.content_jsonb,
                v_sp.content_hash, v_sp.content_size, v_sp.media_type,
                COALESCE(v_sp.origin_jsonb, '{}'::jsonb)
                    || jsonb_build_object(
                           'forked_from_schema', v_source.owner_schema::text,
                           'forked_from_skill_id', v_source.skill_id),
                v_sp.captured_at,
                v_sp.retention_class, v_sp.sensitivity
            )
            RETURNING source_package_id INTO v_new_sp_id;
        END IF;

        INSERT INTO maludb_core.malu$skill_file(
            owner_schema, skill_id, relative_path, source_package_id,
            file_hash, file_size, is_executable, media_type
        )
        VALUES (
            p_target_owner_schema, v_new_skill_id, v_file.relative_path, v_new_sp_id,
            v_file.file_hash, v_file.file_size, v_file.is_executable, v_file.media_type
        );
    END LOOP;

    EXECUTE format(
        'CREATE TEMP TABLE pg_temp.%I (old_state_id bigint PRIMARY KEY, new_state_id bigint NOT NULL) ON COMMIT DROP',
        v_state_map_table
    );

    FOR v_state IN
        SELECT state_id, state_name, state_kind, step_jsonb, validation_jsonb
          FROM maludb_core.malu$skill_state
         WHERE owner_schema = v_source.owner_schema
           AND skill_id = v_source.skill_id
         ORDER BY state_name, state_id
    LOOP
        INSERT INTO maludb_core.malu$skill_state(
            owner_schema,
            skill_id,
            state_name,
            state_kind,
            step_jsonb,
            validation_jsonb
        )
        VALUES (
            p_target_owner_schema,
            v_new_skill_id,
            v_state.state_name,
            v_state.state_kind,
            v_state.step_jsonb,
            v_state.validation_jsonb
        )
        RETURNING state_id INTO v_new_state_id;

        EXECUTE format(
            'INSERT INTO pg_temp.%I(old_state_id, new_state_id) VALUES ($1, $2)',
            v_state_map_table
        )
        USING v_state.state_id, v_new_state_id;
    END LOOP;

    EXECUTE format($sql$
        INSERT INTO maludb_core.malu$skill_transition(
            owner_schema,
            skill_id,
            from_state_id,
            to_state_id,
            on_outcome,
            guard_jsonb,
            ordinal
        )
        SELECT $1::name,
               $2::bigint,
               from_map.new_state_id,
               to_map.new_state_id,
               tr.on_outcome,
               tr.guard_jsonb,
               tr.ordinal
          FROM maludb_core.malu$skill_transition tr
          JOIN pg_temp.%I from_map
            ON from_map.old_state_id = tr.from_state_id
          JOIN pg_temp.%I to_map
            ON to_map.old_state_id = tr.to_state_id
         WHERE tr.owner_schema = $3::name
           AND tr.skill_id = $4::bigint
         ORDER BY tr.ordinal, tr.transition_id
    $sql$, v_state_map_table, v_state_map_table)
    USING p_target_owner_schema, v_new_skill_id, v_source.owner_schema, v_source.skill_id;

    EXECUTE format('DROP TABLE pg_temp.%I', v_state_map_table);

    RETURN v_new_skill_id;
END;
$body$;

-- ---------------------------------------------------------------------
-- 6. get_skill payload gains a 'files' array (the bundle manifest a
--    pull-side client needs; bytes are fetched per source package).
--    The 'skill' key picks up bundle_hash / frontmatter_jsonb for free
--    via to_jsonb(s).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION maludb_core.get_skill(
    p_owner_schema name,
    p_skill_id bigint,
    p_requesting_schema name DEFAULT current_schema()
) RETURNS TABLE (payload jsonb)
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
    WITH caller AS (
        SELECT COALESCE(NULLIF(current_setting('role', true), 'none'), session_user)::name AS role_name
    )
    SELECT jsonb_build_object(
        'skill', to_jsonb(s),
        'keywords', COALESCE((
            SELECT jsonb_agg(to_jsonb(k) ORDER BY k.keyword, k.keyword_id)
              FROM maludb_core.malu$skill_keyword k
             WHERE k.owner_schema = s.owner_schema
               AND k.skill_id = s.skill_id
        ), '[]'::jsonb),
        'subjects', COALESCE((
            SELECT jsonb_agg(to_jsonb(subj) ORDER BY subj.subject_name, subj.skill_subject_id)
              FROM maludb_core.malu$skill_subject subj
             WHERE subj.owner_schema = s.owner_schema
               AND subj.skill_id = s.skill_id
        ), '[]'::jsonb),
        'verbs', COALESCE((
            SELECT jsonb_agg(to_jsonb(v) ORDER BY v.verb_name, v.skill_verb_id)
              FROM maludb_core.malu$skill_verb v
             WHERE v.owner_schema = s.owner_schema
               AND v.skill_id = s.skill_id
        ), '[]'::jsonb),
        'files', COALESCE((
            SELECT jsonb_agg(to_jsonb(f) ORDER BY f.relative_path, f.skill_file_id)
              FROM maludb_core.malu$skill_file f
             WHERE f.owner_schema = s.owner_schema
               AND f.skill_id = s.skill_id
        ), '[]'::jsonb),
        'states', COALESCE((
            SELECT jsonb_agg(to_jsonb(st) ORDER BY st.state_name, st.state_id)
              FROM maludb_core.malu$skill_state st
             WHERE st.owner_schema = s.owner_schema
               AND st.skill_id = s.skill_id
        ), '[]'::jsonb),
        'transitions', COALESCE((
            SELECT jsonb_agg(
                       to_jsonb(tr)
                       || jsonb_build_object(
                              'from_state_name', from_state.state_name,
                              'to_state_name', to_state.state_name
                          )
                       ORDER BY tr.ordinal, tr.transition_id
                   )
              FROM maludb_core.malu$skill_transition tr
              JOIN maludb_core.malu$skill_state from_state
                ON from_state.owner_schema = tr.owner_schema
               AND from_state.skill_id = tr.skill_id
               AND from_state.state_id = tr.from_state_id
              JOIN maludb_core.malu$skill_state to_state
                ON to_state.owner_schema = tr.owner_schema
               AND to_state.skill_id = tr.skill_id
               AND to_state.state_id = tr.to_state_id
             WHERE tr.owner_schema = s.owner_schema
               AND tr.skill_id = s.skill_id
        ), '[]'::jsonb),
        'access_policy', jsonb_build_object(
            'visibility', s.visibility,
            'is_public', (s.owner_schema = 'maludb_public' AND s.visibility = 'public'),
            'is_forkable', (
                (s.owner_schema = 'maludb_public' AND s.visibility = 'public')
                OR EXISTS (
                    SELECT 1
                      FROM maludb_core.malu$skill_access a
                     WHERE a.owner_schema = s.owner_schema
                       AND a.skill_id = s.skill_id
                       AND a.access_level = 'fork'
                       AND pg_catalog.pg_has_role(c.role_name, a.grantee_role, 'member')
                )
            ),
            'grants', CASE
                WHEN maludb_core._memory_schema_is_owned_by_current_role(s.owner_schema) THEN
                    COALESCE((
                        SELECT jsonb_agg(to_jsonb(a) ORDER BY a.grantee_role, a.access_level, a.access_id)
                          FROM maludb_core.malu$skill_access a
                         WHERE a.owner_schema = s.owner_schema
                           AND a.skill_id = s.skill_id
                           AND a.access_level IN ('read','fork')
                    ), '[]'::jsonb)
                ELSE '[]'::jsonb
            END
        )
    ) AS payload
      FROM maludb_core.malu$skill_package s
      CROSS JOIN caller c
     WHERE s.owner_schema = p_owner_schema
       AND s.skill_id = p_skill_id
       AND maludb_core._memory_schema_is_owned_by_current_role(p_requesting_schema)
       AND maludb_core._skill_is_visible(s.owner_schema, s.skill_id, p_requesting_schema, true)
$body$;

-- ---------------------------------------------------------------------
-- 7. One-call agent-skill registration. The API server runs the LLM
--    extraction, ingests the graph via maludb_memory_ingest_extraction
--    (which returns the key->id map), stores bundle files as source
--    packages, then calls this with the extracted names/ids. Strictly
--    validating (one bad input aborts the whole registration): unlike
--    ingest, every input here is produced by our own API layer.
--
--    Dedupe + lineage semantics:
--      * same (skill_name, bundle_hash) in the schema -> no-op, returns
--        the existing row (reused: true).
--      * p_parent_* points at the row this bundle was modified from.
--      * p_materially_different = false -> the parent is superseded
--        (enabled = false) when it lives in the registering schema;
--        a cross-schema parent is left untouched and reported.
--      * lineage never merges (divergent DAG).
-- ---------------------------------------------------------------------
CREATE FUNCTION maludb_core._register_agent_skill_for_schema(
    p_schema               name,
    p_skill_name           text,
    p_markdown             text,
    p_bundle_hash          text,
    p_description          text DEFAULT NULL,
    p_frontmatter          jsonb DEFAULT '{}'::jsonb,
    p_version              text DEFAULT NULL,
    p_keywords             text[] DEFAULT NULL,
    p_subjects             jsonb DEFAULT NULL,
    p_verbs                jsonb DEFAULT NULL,
    p_files                jsonb DEFAULT NULL,
    p_parent_owner_schema  name DEFAULT NULL,
    p_parent_skill_id      bigint DEFAULT NULL,
    p_materially_different boolean DEFAULT true,
    p_enabled              boolean DEFAULT true
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
DECLARE
    v_name        text := btrim(COALESCE(p_skill_name, ''));
    v_hash        text := lower(btrim(COALESCE(p_bundle_hash, '')));
    v_version     text;
    v_skill_id    bigint;
    v_existing    bigint;
    v_superseded  bigint;
    v_parent      maludb_core.malu$skill_package%ROWTYPE;
    v_notes       jsonb := '[]'::jsonb;
    r             record;
    v_tag_name    text;
    v_tag_id      bigint;
    v_kw          text;
    v_sp_id       bigint;
    v_sp          maludb_core.malu$source_package%ROWTYPE;
    c_kw integer := 0; c_subj integer := 0; c_verb integer := 0; c_files integer := 0;
BEGIN
    PERFORM maludb_core._memory_schema_assert_manageable(p_schema);

    IF v_name = '' THEN
        RAISE EXCEPTION 'register_agent_skill: skill_name is required'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;
    IF COALESCE(btrim(p_markdown), '') = '' THEN
        RAISE EXCEPTION 'register_agent_skill: markdown (the SKILL.md body) is required'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;
    IF v_hash !~ '^[0-9a-f]{64}$' THEN
        RAISE EXCEPTION 'register_agent_skill: bundle_hash must be 64 lowercase hex chars (sha256), got %', p_bundle_hash
            USING ERRCODE = 'invalid_parameter_value';
    END IF;
    IF (p_parent_owner_schema IS NULL) <> (p_parent_skill_id IS NULL) THEN
        RAISE EXCEPTION 'register_agent_skill: parent schema and skill id must be provided together'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    -- Idempotent re-push of an unchanged bundle.
    SELECT skill_id INTO v_existing
      FROM maludb_core.malu$skill_package
     WHERE owner_schema = p_schema
       AND skill_name = v_name
       AND bundle_hash = v_hash
     ORDER BY skill_id
     LIMIT 1;
    IF v_existing IS NOT NULL THEN
        RETURN jsonb_build_object(
            'skill_id', v_existing,
            'skill_name', v_name,
            'reused', true);
    END IF;

    IF p_parent_skill_id IS NOT NULL THEN
        SELECT * INTO v_parent
          FROM maludb_core.malu$skill_package
         WHERE owner_schema = p_parent_owner_schema
           AND skill_id = p_parent_skill_id;
        IF NOT FOUND
           OR NOT (v_parent.owner_schema = p_schema
                   OR maludb_core._skill_is_visible(v_parent.owner_schema, v_parent.skill_id, p_schema, true)) THEN
            RAISE EXCEPTION 'register_agent_skill: parent skill %.% not found or not visible from %',
                p_parent_owner_schema, p_parent_skill_id, p_schema
                USING ERRCODE = 'P0002';
        END IF;
    END IF;

    -- Version: caller-supplied (frontmatter metadata.version), else the
    -- bundle hash prefix. (owner, name, version) is UNIQUE; a stale
    -- caller version on changed content falls back to a hash suffix.
    v_version := COALESCE(NULLIF(btrim(p_version), ''), left(v_hash, 12));
    IF EXISTS (SELECT 1 FROM maludb_core.malu$skill_package
                WHERE owner_schema = p_schema AND skill_name = v_name AND version = v_version) THEN
        v_version := v_version || '+' || left(v_hash, 8);
        IF EXISTS (SELECT 1 FROM maludb_core.malu$skill_package
                    WHERE owner_schema = p_schema AND skill_name = v_name AND version = v_version) THEN
            RAISE EXCEPTION 'register_agent_skill: version % already taken for skill % (and so is its hash-suffixed fallback)',
                v_version, v_name
                USING ERRCODE = 'unique_violation';
        END IF;
    END IF;

    INSERT INTO maludb_core.malu$skill_package(
        owner_schema, skill_name, version, description,
        packaging_kind, enabled, visibility,
        markdown, bundle_hash, frontmatter_jsonb,
        source_owner_schema, source_skill_id, forked_at
    )
    VALUES (
        p_schema, v_name, v_version, NULLIF(btrim(COALESCE(p_description, '')), ''),
        'markdown', COALESCE(p_enabled, true), 'private',
        p_markdown, v_hash, COALESCE(p_frontmatter, '{}'::jsonb),
        p_parent_owner_schema, p_parent_skill_id,
        CASE WHEN p_parent_skill_id IS NOT NULL THEN now() END
    )
    RETURNING skill_id INTO v_skill_id;

    -- Discovery tags (provenance 'extracted').
    FOREACH v_kw IN ARRAY COALESCE(p_keywords, ARRAY[]::text[])
    LOOP
        CONTINUE WHEN btrim(COALESCE(v_kw, '')) = '';
        INSERT INTO maludb_core.malu$skill_keyword(owner_schema, skill_id, keyword, provenance)
        VALUES (p_schema, v_skill_id, btrim(v_kw), 'extracted')
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
        VALUES (p_schema, v_skill_id, v_tag_id, v_tag_name,
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
        VALUES (p_schema, v_skill_id, v_tag_id, v_tag_name,
                COALESCE(NULLIF(btrim(COALESCE(r.val ->> 'weight', '')), '')::numeric, 1.0), 'extracted')
        ON CONFLICT (owner_schema, skill_id, lower(verb_name)) DO NOTHING;
        c_verb := c_verb + 1;
    END LOOP;

    -- Bundle manifest. Each file's bytes must already sit in a source
    -- package owned by the registering schema; hash/size/media default
    -- from the package when omitted.
    FOR r IN SELECT val FROM jsonb_array_elements(COALESCE(p_files, '[]'::jsonb)) AS t(val)
    LOOP
        v_sp_id := NULLIF(btrim(COALESCE(r.val ->> 'source_package_id', '')), '')::bigint;
        IF v_sp_id IS NULL OR btrim(COALESCE(r.val ->> 'relative_path', '')) = '' THEN
            RAISE EXCEPTION 'register_agent_skill: each file needs relative_path and source_package_id (got %)', r.val
                USING ERRCODE = 'invalid_parameter_value';
        END IF;
        SELECT * INTO v_sp
          FROM maludb_core.malu$source_package
         WHERE source_package_id = v_sp_id
           AND owner_schema = p_schema;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'register_agent_skill: source package % not found in schema %', v_sp_id, p_schema
                USING ERRCODE = 'P0002';
        END IF;
        INSERT INTO maludb_core.malu$skill_file(
            owner_schema, skill_id, relative_path, source_package_id,
            file_hash, file_size, is_executable, media_type)
        VALUES (
            p_schema, v_skill_id, btrim(r.val ->> 'relative_path'), v_sp_id,
            COALESCE(NULLIF(btrim(COALESCE(r.val ->> 'file_hash', '')), ''), v_sp.content_hash),
            COALESCE(NULLIF(btrim(COALESCE(r.val ->> 'file_size', '')), '')::bigint, v_sp.content_size),
            COALESCE((r.val ->> 'is_executable')::boolean, false),
            COALESCE(NULLIF(btrim(COALESCE(r.val ->> 'media_type', '')), ''), v_sp.media_type));
        c_files := c_files + 1;
    END LOOP;

    -- Supersession: a non-materially-different revision hides its
    -- parent from discovery (enabled = false). Cross-schema parents
    -- are another team's rows -- never touched, only reported.
    IF p_parent_skill_id IS NOT NULL AND NOT COALESCE(p_materially_different, true) THEN
        IF p_parent_owner_schema = p_schema THEN
            UPDATE maludb_core.malu$skill_package
               SET enabled = false,
                   updated_at = now()
             WHERE owner_schema = p_schema
               AND skill_id = p_parent_skill_id
               AND enabled;
            IF FOUND THEN
                v_superseded := p_parent_skill_id;
            END IF;
        ELSE
            v_notes := v_notes || jsonb_build_object(
                'note', 'parent_not_disabled',
                'reason', 'parent lives in another schema',
                'parent_owner_schema', p_parent_owner_schema::text,
                'parent_skill_id', p_parent_skill_id);
        END IF;
    END IF;

    RETURN jsonb_strip_nulls(jsonb_build_object(
        'skill_id', v_skill_id,
        'skill_name', v_name,
        'version', v_version,
        'reused', false,
        'superseded_skill_id', v_superseded,
        'tags', jsonb_build_object('keywords', c_kw, 'subjects', c_subj, 'verbs', c_verb),
        'files_linked', c_files,
        'notes', CASE WHEN v_notes = '[]'::jsonb THEN NULL ELSE v_notes END));
END;
$body$;

REVOKE ALL ON FUNCTION maludb_core._register_agent_skill_for_schema(name, text, text, text, text, jsonb, text, text[], jsonb, jsonb, jsonb, name, bigint, boolean, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core._register_agent_skill_for_schema(name, text, text, text, text, jsonb, text, text[], jsonb, jsonb, jsonb, name, bigint, boolean, boolean)
    TO maludb_memory_admin, maludb_memory_executor;

-- ---------------------------------------------------------------------
-- 8. 0970 facade builder: widen maludb_skill (bundle_hash,
--    frontmatter_jsonb appended; the view is already in the
--    enable_memory_schema drop-first list so the column set may grow),
--    and add maludb_skill_file + maludb_skill_register. maludb_public
--    keeps the curator-only write posture of the other skill facades.
-- ---------------------------------------------------------------------
CREATE FUNCTION maludb_core._enable_memory_schema_0970_facade(p_schema name) RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
DECLARE
    v_count integer := 0;
BEGIN
    PERFORM maludb_core._memory_schema_assert_manageable(p_schema);

    -- Widen the view WITHOUT re-granting (the 080 builder's recipe):
    -- CREATE OR REPLACE preserves the ACLs the earlier builders layered,
    -- including the 073 maludb_public revoke that keeps public skill
    -- writes curator-only. A re-GRANT here would silently undo it.
    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_skill', 'view');
    EXECUTE format($sql$
        CREATE OR REPLACE VIEW %I.maludb_skill WITH (security_invoker = true) AS
        SELECT skill_id, skill_name, version, description, packaging_kind,
               applicability_jsonb, precondition_jsonb, enabled, created_at,
               updated_at, visibility, source_owner_schema, source_skill_id,
               forked_at, owner_schema, markdown, bundle_hash, frontmatter_jsonb
          FROM maludb_core.malu$skill_package
         WHERE owner_schema = %L
        WITH LOCAL CHECK OPTION
    $sql$, p_schema, p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_skill', 'view', 'Schema-local skill package facade.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_skill_file', 'view');
    EXECUTE format($sql$
        CREATE OR REPLACE VIEW %I.maludb_skill_file WITH (security_invoker = true) AS
        SELECT skill_file_id,
               skill_id,
               relative_path,
               source_package_id,
               file_hash,
               file_size,
               is_executable,
               media_type,
               created_at
          FROM maludb_core.malu$skill_file
         WHERE owner_schema = %L
        WITH LOCAL CHECK OPTION
    $sql$, p_schema, p_schema);
    EXECUTE format('GRANT SELECT, INSERT, DELETE ON %I.maludb_skill_file TO maludb_memory_admin, maludb_memory_executor', p_schema);
    EXECUTE format('GRANT SELECT ON %I.maludb_skill_file TO maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_skill_file', 'view', 'Schema-local agent-skill bundle manifest facade.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_skill_register', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_skill_register(
            p_skill_name           text,
            p_markdown             text,
            p_bundle_hash          text,
            p_description          text DEFAULT NULL,
            p_frontmatter          jsonb DEFAULT '{}'::jsonb,
            p_version              text DEFAULT NULL,
            p_keywords             text[] DEFAULT NULL,
            p_subjects             jsonb DEFAULT NULL,
            p_verbs                jsonb DEFAULT NULL,
            p_files                jsonb DEFAULT NULL,
            p_parent_owner_schema  name DEFAULT NULL,
            p_parent_skill_id      bigint DEFAULT NULL,
            p_materially_different boolean DEFAULT true,
            p_enabled              boolean DEFAULT true
        ) RETURNS jsonb
        LANGUAGE SQL
        SECURITY DEFINER
        SET search_path = pg_catalog, maludb_core, pg_temp
        AS $fn$
            SELECT maludb_core._register_agent_skill_for_schema(
                %L::name,
                p_skill_name, p_markdown, p_bundle_hash,
                p_description, p_frontmatter, p_version,
                p_keywords, p_subjects, p_verbs, p_files,
                p_parent_owner_schema, p_parent_skill_id,
                p_materially_different, p_enabled
            )
        $fn$;
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_skill_register(text, text, text, text, jsonb, text, text[], jsonb, jsonb, jsonb, name, bigint, boolean, boolean) FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_skill_register(text, text, text, text, jsonb, text, text[], jsonb, jsonb, jsonb, name, bigint, boolean, boolean) TO maludb_memory_admin, maludb_memory_executor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_skill_register', 'function', 'Schema-local one-call agent-skill registration wrapper.');
    v_count := v_count + 1;

    IF p_schema = 'maludb_public' THEN
        EXECUTE format('REVOKE INSERT, DELETE ON %I.maludb_skill_file FROM maludb_memory_executor', p_schema);
        EXECUTE format('GRANT SELECT, INSERT, DELETE ON %I.maludb_skill_file TO maludb_skill_curator', p_schema);
        EXECUTE format('REVOKE EXECUTE ON FUNCTION %I.maludb_skill_register(text, text, text, text, jsonb, text, text[], jsonb, jsonb, jsonb, name, bigint, boolean, boolean) FROM maludb_memory_executor', p_schema);
        EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_skill_register(text, text, text, text, jsonb, text, text[], jsonb, jsonb, jsonb, name, bigint, boolean, boolean) TO maludb_skill_curator', p_schema);
    END IF;

    RETURN v_count;
END;
$body$;

REVOKE ALL ON FUNCTION maludb_core._enable_memory_schema_0970_facade(name) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core._enable_memory_schema_0970_facade(name)
    TO maludb_memory_admin, maludb_memory_executor;

-- ---------------------------------------------------------------------
-- 9. Wire the 0970 facade into enable_memory_schema. maludb_skill is
--    already in the drop-first list (since 0.96.0's list revision), so
--    no list change is needed for its column growth.
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
-- 10. Version stamp.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION maludb_core.maludb_core_version() RETURNS text
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$ SELECT '0.97.0'::text $body$;
