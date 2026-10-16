\echo Use "ALTER EXTENSION maludb_core UPDATE TO '0.73.0'" to load this file. \quit

-- =====================================================================
-- maludb_core 0.72.0 -> 0.73.0
--
-- Skill discovery:
--   * manual subject, verb, and keyword tags for skills
--   * optional skill-description embeddings
--   * private/shared/public skill visibility
--   * maludb_public read-only public skills
--   * find/get/fork skill APIs
-- =====================================================================

CREATE OR REPLACE FUNCTION maludb_core_version() RETURNS text
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$ SELECT '0.73.0'::text $body$;

DO $body$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'maludb_skill_curator') THEN
        CREATE ROLE maludb_skill_curator NOLOGIN;
    END IF;
END;
$body$;

GRANT USAGE ON SCHEMA maludb_core TO maludb_skill_curator;

ALTER TABLE malu$skill_package
    ADD COLUMN IF NOT EXISTS visibility text NOT NULL DEFAULT 'private',
    ADD COLUMN IF NOT EXISTS source_owner_schema name,
    ADD COLUMN IF NOT EXISTS source_skill_id bigint,
    ADD COLUMN IF NOT EXISTS forked_at timestamptz;

ALTER TABLE malu$skill_package
    ALTER COLUMN visibility SET DEFAULT 'private';

UPDATE malu$skill_package
   SET visibility = 'private'
 WHERE visibility IS NULL;

ALTER TABLE malu$skill_package
    ALTER COLUMN visibility SET NOT NULL;

DO $body$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'malu$skill_package'::regclass
          AND conname = 'malu$skill_package_visibility_ck'
    ) THEN
        ALTER TABLE malu$skill_package
            ADD CONSTRAINT malu$skill_package_visibility_ck
            CHECK (visibility IN ('private','shared','public'));
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'malu$skill_package'::regclass
          AND conname = 'malu$skill_package_public_owner_ck'
    ) THEN
        ALTER TABLE malu$skill_package
            ADD CONSTRAINT malu$skill_package_public_owner_ck
            CHECK (visibility <> 'public' OR owner_schema = 'maludb_public');
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'malu$skill_package'::regclass
          AND conname = 'malu$skill_package_owner_skill_id_key'
    ) THEN
        ALTER TABLE malu$skill_package
            ADD CONSTRAINT malu$skill_package_owner_skill_id_key
            UNIQUE (owner_schema, skill_id);
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'malu$svpor_subject'::regclass
          AND conname = 'malu$svpor_subject_owner_subject_id_key'
    ) THEN
        ALTER TABLE malu$svpor_subject
            ADD CONSTRAINT malu$svpor_subject_owner_subject_id_key
            UNIQUE (owner_schema, subject_id);
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'malu$svpor_verb'::regclass
          AND conname = 'malu$svpor_verb_owner_verb_id_key'
    ) THEN
        ALTER TABLE malu$svpor_verb
            ADD CONSTRAINT malu$svpor_verb_owner_verb_id_key
            UNIQUE (owner_schema, verb_id);
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'malu$skill_package'::regclass
          AND conname = 'malu$skill_package_source_fk'
    ) THEN
        ALTER TABLE malu$skill_package
            ADD CONSTRAINT malu$skill_package_source_fk
            FOREIGN KEY (source_owner_schema, source_skill_id)
            REFERENCES malu$skill_package(owner_schema, skill_id)
            ON DELETE SET NULL (source_owner_schema, source_skill_id);
    END IF;
END;
$body$;

CREATE TABLE IF NOT EXISTS malu$skill_keyword (
    keyword_id   bigserial PRIMARY KEY,
    owner_schema name NOT NULL DEFAULT current_schema(),
    skill_id     bigint NOT NULL,
    keyword      text NOT NULL,
    weight       numeric NOT NULL DEFAULT 1.0,
    provenance   text NOT NULL DEFAULT 'manual'
        CHECK (provenance IN ('manual')),
    created_at   timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (owner_schema, skill_id)
        REFERENCES malu$skill_package(owner_schema, skill_id) ON DELETE CASCADE
);
CREATE UNIQUE INDEX IF NOT EXISTS malu$skill_keyword_owner_skill_keyword_key
    ON malu$skill_keyword(owner_schema, skill_id, lower(keyword));
CREATE INDEX IF NOT EXISTS malu$skill_keyword_lookup_idx
    ON malu$skill_keyword(owner_schema, lower(keyword));

CREATE TABLE IF NOT EXISTS malu$skill_subject (
    skill_subject_id bigserial PRIMARY KEY,
    owner_schema     name NOT NULL DEFAULT current_schema(),
    skill_id         bigint NOT NULL,
    subject_id       bigint,
    subject_name     text NOT NULL,
    weight           numeric NOT NULL DEFAULT 1.0,
    provenance       text NOT NULL DEFAULT 'manual'
        CHECK (provenance IN ('manual')),
    created_at       timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (owner_schema, skill_id)
        REFERENCES malu$skill_package(owner_schema, skill_id) ON DELETE CASCADE,
    FOREIGN KEY (owner_schema, subject_id)
        REFERENCES malu$svpor_subject(owner_schema, subject_id) ON DELETE SET NULL (subject_id)
);
CREATE UNIQUE INDEX IF NOT EXISTS malu$skill_subject_owner_skill_subject_key
    ON malu$skill_subject(owner_schema, skill_id, lower(subject_name));
CREATE INDEX IF NOT EXISTS malu$skill_subject_lookup_idx
    ON malu$skill_subject(owner_schema, lower(subject_name));

CREATE TABLE IF NOT EXISTS malu$skill_verb (
    skill_verb_id bigserial PRIMARY KEY,
    owner_schema  name NOT NULL DEFAULT current_schema(),
    skill_id      bigint NOT NULL,
    verb_id       bigint,
    verb_name     text NOT NULL,
    weight        numeric NOT NULL DEFAULT 1.0,
    provenance    text NOT NULL DEFAULT 'manual'
        CHECK (provenance IN ('manual')),
    created_at    timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (owner_schema, skill_id)
        REFERENCES malu$skill_package(owner_schema, skill_id) ON DELETE CASCADE,
    FOREIGN KEY (owner_schema, verb_id)
        REFERENCES malu$svpor_verb(owner_schema, verb_id) ON DELETE SET NULL (verb_id)
);
CREATE UNIQUE INDEX IF NOT EXISTS malu$skill_verb_owner_skill_verb_key
    ON malu$skill_verb(owner_schema, skill_id, lower(verb_name));
CREATE INDEX IF NOT EXISTS malu$skill_verb_lookup_idx
    ON malu$skill_verb(owner_schema, lower(verb_name));

CREATE TABLE IF NOT EXISTS malu$skill_embedding (
    embedding_id     bigserial PRIMARY KEY,
    owner_schema     name NOT NULL DEFAULT current_schema(),
    skill_id         bigint NOT NULL,
    embedding_model  text NOT NULL,
    embedding_dim    integer NOT NULL,
    embedding        malu_vector NOT NULL,
    source_text_hash text NOT NULL,
    source_text_kind text NOT NULL DEFAULT 'description',
    created_at       timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (owner_schema, skill_id)
        REFERENCES malu$skill_package(owner_schema, skill_id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS malu$skill_embedding_owner_skill_idx
    ON malu$skill_embedding(owner_schema, skill_id);

DO $body$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'malu$skill_embedding'::regclass
          AND conname = 'malu$skill_embedding_dim_ck'
    ) THEN
        ALTER TABLE malu$skill_embedding
            ADD CONSTRAINT malu$skill_embedding_dim_ck
            CHECK (embedding_dim = maludb_core.vector_dims(embedding));
    END IF;
END;
$body$;

CREATE TABLE IF NOT EXISTS malu$skill_access (
    access_id     bigserial PRIMARY KEY,
    owner_schema  name NOT NULL DEFAULT current_schema(),
    skill_id      bigint NOT NULL,
    grantee_role  name NOT NULL,
    access_level  text NOT NULL DEFAULT 'read'
        CHECK (access_level IN ('read','execute','fork','admin')),
    created_at    timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (owner_schema, skill_id)
        REFERENCES malu$skill_package(owner_schema, skill_id) ON DELETE CASCADE,
    UNIQUE (owner_schema, skill_id, grantee_role, access_level)
);
CREATE INDEX IF NOT EXISTS malu$skill_access_grantee_idx
    ON malu$skill_access(grantee_role, owner_schema, skill_id);

ALTER TABLE malu$skill_package ENABLE ROW LEVEL SECURITY;
ALTER TABLE malu$skill_state ENABLE ROW LEVEL SECURITY;
ALTER TABLE malu$skill_transition ENABLE ROW LEVEL SECURITY;
ALTER TABLE malu$skill_keyword ENABLE ROW LEVEL SECURITY;
ALTER TABLE malu$skill_subject ENABLE ROW LEVEL SECURITY;
ALTER TABLE malu$skill_verb ENABLE ROW LEVEL SECURITY;
ALTER TABLE malu$skill_embedding ENABLE ROW LEVEL SECURITY;
ALTER TABLE malu$skill_access ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION _memory_schema_is_owned_by_current_role(p_schema name) RETURNS boolean
LANGUAGE SQL
STABLE
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
    WITH caller AS (
        SELECT COALESCE(NULLIF(current_setting('role', true), 'none'), session_user)::name AS role_name
    )
    SELECT pg_catalog.pg_has_role(c.role_name, 'maludb_memory_admin', 'member')
        OR EXISTS (
            SELECT 1
              FROM pg_catalog.pg_namespace n
             WHERE n.nspname = p_schema
               AND pg_catalog.pg_has_role(c.role_name, n.nspowner, 'member')
        )
      FROM caller c
$body$;

DROP POLICY IF EXISTS tenant_owner ON malu$skill_package;
DROP POLICY IF EXISTS tenant_owner ON malu$skill_state;
DROP POLICY IF EXISTS tenant_owner ON malu$skill_transition;
DROP POLICY IF EXISTS skill_package_select ON malu$skill_package;
DROP POLICY IF EXISTS skill_package_insert ON malu$skill_package;
DROP POLICY IF EXISTS skill_package_update ON malu$skill_package;
DROP POLICY IF EXISTS skill_package_delete ON malu$skill_package;
DROP POLICY IF EXISTS skill_state_select ON malu$skill_state;
DROP POLICY IF EXISTS skill_state_insert ON malu$skill_state;
DROP POLICY IF EXISTS skill_state_update ON malu$skill_state;
DROP POLICY IF EXISTS skill_state_delete ON malu$skill_state;
DROP POLICY IF EXISTS skill_transition_select ON malu$skill_transition;
DROP POLICY IF EXISTS skill_transition_insert ON malu$skill_transition;
DROP POLICY IF EXISTS skill_transition_update ON malu$skill_transition;
DROP POLICY IF EXISTS skill_transition_delete ON malu$skill_transition;

CREATE POLICY skill_package_select ON malu$skill_package
    FOR SELECT
    USING (
        maludb_core._memory_schema_is_owned_by_current_role(owner_schema)
        OR visibility = 'public'
        OR EXISTS (
            SELECT 1
              FROM malu$skill_access a
             WHERE a.owner_schema = malu$skill_package.owner_schema
               AND a.skill_id = malu$skill_package.skill_id
               AND a.access_level IN ('read','fork')
               AND pg_catalog.pg_has_role(current_user, a.grantee_role, 'member')
        )
    );
CREATE POLICY skill_package_insert ON malu$skill_package
    FOR INSERT
    WITH CHECK (
        maludb_core._memory_schema_is_owned_by_current_role(owner_schema)
        AND (
            owner_schema <> 'maludb_public'
            OR pg_catalog.pg_has_role(current_user, 'maludb_skill_curator', 'member')
            OR pg_catalog.pg_has_role(current_user, 'maludb_memory_admin', 'member')
        )
        AND (
            owner_schema = 'maludb_public'
            OR pg_catalog.pg_has_role(current_user, 'maludb_memory_executor', 'member')
            OR pg_catalog.pg_has_role(current_user, 'maludb_memory_admin', 'member')
        )
    );
CREATE POLICY skill_package_update ON malu$skill_package
    FOR UPDATE
    USING (
        maludb_core._memory_schema_is_owned_by_current_role(owner_schema)
        AND (
            owner_schema <> 'maludb_public'
            OR pg_catalog.pg_has_role(current_user, 'maludb_skill_curator', 'member')
            OR pg_catalog.pg_has_role(current_user, 'maludb_memory_admin', 'member')
        )
        AND (
            owner_schema = 'maludb_public'
            OR pg_catalog.pg_has_role(current_user, 'maludb_memory_executor', 'member')
            OR pg_catalog.pg_has_role(current_user, 'maludb_memory_admin', 'member')
        )
    )
    WITH CHECK (
        maludb_core._memory_schema_is_owned_by_current_role(owner_schema)
        AND (
            owner_schema <> 'maludb_public'
            OR pg_catalog.pg_has_role(current_user, 'maludb_skill_curator', 'member')
            OR pg_catalog.pg_has_role(current_user, 'maludb_memory_admin', 'member')
        )
        AND (
            owner_schema = 'maludb_public'
            OR pg_catalog.pg_has_role(current_user, 'maludb_memory_executor', 'member')
            OR pg_catalog.pg_has_role(current_user, 'maludb_memory_admin', 'member')
        )
    );
CREATE POLICY skill_package_delete ON malu$skill_package
    FOR DELETE
    USING (
        maludb_core._memory_schema_is_owned_by_current_role(owner_schema)
        AND (
            owner_schema <> 'maludb_public'
            OR pg_catalog.pg_has_role(current_user, 'maludb_skill_curator', 'member')
            OR pg_catalog.pg_has_role(current_user, 'maludb_memory_admin', 'member')
        )
        AND (
            owner_schema = 'maludb_public'
            OR pg_catalog.pg_has_role(current_user, 'maludb_memory_executor', 'member')
            OR pg_catalog.pg_has_role(current_user, 'maludb_memory_admin', 'member')
        )
    );

CREATE POLICY skill_state_select ON malu$skill_state
    FOR SELECT
    USING (
        EXISTS (
            SELECT 1
              FROM malu$skill_package p
             WHERE p.owner_schema = malu$skill_state.owner_schema
               AND p.skill_id = malu$skill_state.skill_id
               AND (
                   maludb_core._memory_schema_is_owned_by_current_role(p.owner_schema)
                   OR p.visibility = 'public'
                   OR EXISTS (
                       SELECT 1
                         FROM malu$skill_access a
                        WHERE a.owner_schema = p.owner_schema
                          AND a.skill_id = p.skill_id
                          AND a.access_level IN ('read','fork')
                          AND pg_catalog.pg_has_role(current_user, a.grantee_role, 'member')
                   )
               )
        )
    );
CREATE POLICY skill_state_insert ON malu$skill_state
    FOR INSERT
    WITH CHECK (
        maludb_core._memory_schema_is_owned_by_current_role(owner_schema)
        AND (
            owner_schema <> 'maludb_public'
            OR pg_catalog.pg_has_role(current_user, 'maludb_skill_curator', 'member')
            OR pg_catalog.pg_has_role(current_user, 'maludb_memory_admin', 'member')
        )
    );
CREATE POLICY skill_state_update ON malu$skill_state
    FOR UPDATE
    USING (
        maludb_core._memory_schema_is_owned_by_current_role(owner_schema)
        AND (
            owner_schema <> 'maludb_public'
            OR pg_catalog.pg_has_role(current_user, 'maludb_skill_curator', 'member')
            OR pg_catalog.pg_has_role(current_user, 'maludb_memory_admin', 'member')
        )
    )
    WITH CHECK (
        maludb_core._memory_schema_is_owned_by_current_role(owner_schema)
        AND (
            owner_schema <> 'maludb_public'
            OR pg_catalog.pg_has_role(current_user, 'maludb_skill_curator', 'member')
            OR pg_catalog.pg_has_role(current_user, 'maludb_memory_admin', 'member')
        )
    );
CREATE POLICY skill_state_delete ON malu$skill_state
    FOR DELETE
    USING (
        maludb_core._memory_schema_is_owned_by_current_role(owner_schema)
        AND (
            owner_schema <> 'maludb_public'
            OR pg_catalog.pg_has_role(current_user, 'maludb_skill_curator', 'member')
            OR pg_catalog.pg_has_role(current_user, 'maludb_memory_admin', 'member')
        )
    );

CREATE POLICY skill_transition_select ON malu$skill_transition
    FOR SELECT
    USING (
        EXISTS (
            SELECT 1
              FROM malu$skill_package p
             WHERE p.owner_schema = malu$skill_transition.owner_schema
               AND p.skill_id = malu$skill_transition.skill_id
               AND (
                   maludb_core._memory_schema_is_owned_by_current_role(p.owner_schema)
                   OR p.visibility = 'public'
                   OR EXISTS (
                       SELECT 1
                         FROM malu$skill_access a
                        WHERE a.owner_schema = p.owner_schema
                          AND a.skill_id = p.skill_id
                          AND a.access_level IN ('read','fork')
                          AND pg_catalog.pg_has_role(current_user, a.grantee_role, 'member')
                   )
               )
        )
    );
CREATE POLICY skill_transition_insert ON malu$skill_transition
    FOR INSERT
    WITH CHECK (
        maludb_core._memory_schema_is_owned_by_current_role(owner_schema)
        AND (
            owner_schema <> 'maludb_public'
            OR pg_catalog.pg_has_role(current_user, 'maludb_skill_curator', 'member')
            OR pg_catalog.pg_has_role(current_user, 'maludb_memory_admin', 'member')
        )
    );
CREATE POLICY skill_transition_update ON malu$skill_transition
    FOR UPDATE
    USING (
        maludb_core._memory_schema_is_owned_by_current_role(owner_schema)
        AND (
            owner_schema <> 'maludb_public'
            OR pg_catalog.pg_has_role(current_user, 'maludb_skill_curator', 'member')
            OR pg_catalog.pg_has_role(current_user, 'maludb_memory_admin', 'member')
        )
    )
    WITH CHECK (
        maludb_core._memory_schema_is_owned_by_current_role(owner_schema)
        AND (
            owner_schema <> 'maludb_public'
            OR pg_catalog.pg_has_role(current_user, 'maludb_skill_curator', 'member')
            OR pg_catalog.pg_has_role(current_user, 'maludb_memory_admin', 'member')
        )
    );
CREATE POLICY skill_transition_delete ON malu$skill_transition
    FOR DELETE
    USING (
        maludb_core._memory_schema_is_owned_by_current_role(owner_schema)
        AND (
            owner_schema <> 'maludb_public'
            OR pg_catalog.pg_has_role(current_user, 'maludb_skill_curator', 'member')
            OR pg_catalog.pg_has_role(current_user, 'maludb_memory_admin', 'member')
        )
    );

DROP POLICY IF EXISTS skill_keyword_select ON malu$skill_keyword;
DROP POLICY IF EXISTS skill_keyword_insert ON malu$skill_keyword;
DROP POLICY IF EXISTS skill_keyword_update ON malu$skill_keyword;
DROP POLICY IF EXISTS skill_keyword_delete ON malu$skill_keyword;
DROP POLICY IF EXISTS skill_subject_select ON malu$skill_subject;
DROP POLICY IF EXISTS skill_subject_insert ON malu$skill_subject;
DROP POLICY IF EXISTS skill_subject_update ON malu$skill_subject;
DROP POLICY IF EXISTS skill_subject_delete ON malu$skill_subject;
DROP POLICY IF EXISTS skill_verb_select ON malu$skill_verb;
DROP POLICY IF EXISTS skill_verb_insert ON malu$skill_verb;
DROP POLICY IF EXISTS skill_verb_update ON malu$skill_verb;
DROP POLICY IF EXISTS skill_verb_delete ON malu$skill_verb;
DROP POLICY IF EXISTS skill_embedding_select ON malu$skill_embedding;
DROP POLICY IF EXISTS skill_embedding_insert ON malu$skill_embedding;
DROP POLICY IF EXISTS skill_embedding_update ON malu$skill_embedding;
DROP POLICY IF EXISTS skill_embedding_delete ON malu$skill_embedding;
DROP POLICY IF EXISTS skill_access_select ON malu$skill_access;
DROP POLICY IF EXISTS skill_access_insert ON malu$skill_access;
DROP POLICY IF EXISTS skill_access_update ON malu$skill_access;
DROP POLICY IF EXISTS skill_access_delete ON malu$skill_access;

CREATE POLICY skill_keyword_select ON malu$skill_keyword
    FOR SELECT
    USING (
        EXISTS (
            SELECT 1
            FROM malu$skill_package p
            WHERE p.owner_schema = malu$skill_keyword.owner_schema
              AND p.skill_id = malu$skill_keyword.skill_id
              AND (
                  maludb_core._memory_schema_is_owned_by_current_role(p.owner_schema)
                  OR p.visibility = 'public'
                  OR EXISTS (
                      SELECT 1
                        FROM malu$skill_access a
                       WHERE a.owner_schema = p.owner_schema
                         AND a.skill_id = p.skill_id
                         AND a.access_level IN ('read','fork')
                         AND pg_catalog.pg_has_role(current_user, a.grantee_role, 'member')
                  )
              )
        )
    );
CREATE POLICY skill_keyword_insert ON malu$skill_keyword
    FOR INSERT
    WITH CHECK (
        maludb_core._memory_schema_is_owned_by_current_role(owner_schema)
        AND (
            owner_schema <> 'maludb_public'
            OR pg_catalog.pg_has_role(current_user, 'maludb_skill_curator', 'member')
            OR pg_catalog.pg_has_role(current_user, 'maludb_memory_admin', 'member')
        )
        AND (
            owner_schema = 'maludb_public'
            OR pg_catalog.pg_has_role(current_user, 'maludb_memory_executor', 'member')
            OR pg_catalog.pg_has_role(current_user, 'maludb_memory_admin', 'member')
        )
    );
CREATE POLICY skill_keyword_update ON malu$skill_keyword
    FOR UPDATE
    USING (
        maludb_core._memory_schema_is_owned_by_current_role(owner_schema)
        AND (
            owner_schema <> 'maludb_public'
            OR pg_catalog.pg_has_role(current_user, 'maludb_skill_curator', 'member')
            OR pg_catalog.pg_has_role(current_user, 'maludb_memory_admin', 'member')
        )
        AND (
            owner_schema = 'maludb_public'
            OR pg_catalog.pg_has_role(current_user, 'maludb_memory_executor', 'member')
            OR pg_catalog.pg_has_role(current_user, 'maludb_memory_admin', 'member')
        )
    )
    WITH CHECK (
        maludb_core._memory_schema_is_owned_by_current_role(owner_schema)
        AND (
            owner_schema <> 'maludb_public'
            OR pg_catalog.pg_has_role(current_user, 'maludb_skill_curator', 'member')
            OR pg_catalog.pg_has_role(current_user, 'maludb_memory_admin', 'member')
        )
        AND (
            owner_schema = 'maludb_public'
            OR pg_catalog.pg_has_role(current_user, 'maludb_memory_executor', 'member')
            OR pg_catalog.pg_has_role(current_user, 'maludb_memory_admin', 'member')
        )
    );
CREATE POLICY skill_keyword_delete ON malu$skill_keyword
    FOR DELETE
    USING (
        maludb_core._memory_schema_is_owned_by_current_role(owner_schema)
        AND (
            owner_schema <> 'maludb_public'
            OR pg_catalog.pg_has_role(current_user, 'maludb_skill_curator', 'member')
            OR pg_catalog.pg_has_role(current_user, 'maludb_memory_admin', 'member')
        )
        AND (
            owner_schema = 'maludb_public'
            OR pg_catalog.pg_has_role(current_user, 'maludb_memory_executor', 'member')
            OR pg_catalog.pg_has_role(current_user, 'maludb_memory_admin', 'member')
        )
    );

CREATE POLICY skill_subject_select ON malu$skill_subject
    FOR SELECT
    USING (
        EXISTS (
            SELECT 1
            FROM malu$skill_package p
            WHERE p.owner_schema = malu$skill_subject.owner_schema
              AND p.skill_id = malu$skill_subject.skill_id
              AND (
                  maludb_core._memory_schema_is_owned_by_current_role(p.owner_schema)
                  OR p.visibility = 'public'
                  OR EXISTS (
                      SELECT 1
                        FROM malu$skill_access a
                       WHERE a.owner_schema = p.owner_schema
                         AND a.skill_id = p.skill_id
                         AND a.access_level IN ('read','fork')
                         AND pg_catalog.pg_has_role(current_user, a.grantee_role, 'member')
                  )
              )
        )
    );
CREATE POLICY skill_subject_insert ON malu$skill_subject
    FOR INSERT
    WITH CHECK (
        maludb_core._memory_schema_is_owned_by_current_role(owner_schema)
        AND (
            owner_schema <> 'maludb_public'
            OR pg_catalog.pg_has_role(current_user, 'maludb_skill_curator', 'member')
            OR pg_catalog.pg_has_role(current_user, 'maludb_memory_admin', 'member')
        )
        AND (
            owner_schema = 'maludb_public'
            OR pg_catalog.pg_has_role(current_user, 'maludb_memory_executor', 'member')
            OR pg_catalog.pg_has_role(current_user, 'maludb_memory_admin', 'member')
        )
    );
CREATE POLICY skill_subject_update ON malu$skill_subject
    FOR UPDATE
    USING (
        maludb_core._memory_schema_is_owned_by_current_role(owner_schema)
        AND (
            owner_schema <> 'maludb_public'
            OR pg_catalog.pg_has_role(current_user, 'maludb_skill_curator', 'member')
            OR pg_catalog.pg_has_role(current_user, 'maludb_memory_admin', 'member')
        )
        AND (
            owner_schema = 'maludb_public'
            OR pg_catalog.pg_has_role(current_user, 'maludb_memory_executor', 'member')
            OR pg_catalog.pg_has_role(current_user, 'maludb_memory_admin', 'member')
        )
    )
    WITH CHECK (
        maludb_core._memory_schema_is_owned_by_current_role(owner_schema)
        AND (
            owner_schema <> 'maludb_public'
            OR pg_catalog.pg_has_role(current_user, 'maludb_skill_curator', 'member')
            OR pg_catalog.pg_has_role(current_user, 'maludb_memory_admin', 'member')
        )
        AND (
            owner_schema = 'maludb_public'
            OR pg_catalog.pg_has_role(current_user, 'maludb_memory_executor', 'member')
            OR pg_catalog.pg_has_role(current_user, 'maludb_memory_admin', 'member')
        )
    );
CREATE POLICY skill_subject_delete ON malu$skill_subject
    FOR DELETE
    USING (
        maludb_core._memory_schema_is_owned_by_current_role(owner_schema)
        AND (
            owner_schema <> 'maludb_public'
            OR pg_catalog.pg_has_role(current_user, 'maludb_skill_curator', 'member')
            OR pg_catalog.pg_has_role(current_user, 'maludb_memory_admin', 'member')
        )
        AND (
            owner_schema = 'maludb_public'
            OR pg_catalog.pg_has_role(current_user, 'maludb_memory_executor', 'member')
            OR pg_catalog.pg_has_role(current_user, 'maludb_memory_admin', 'member')
        )
    );

CREATE POLICY skill_verb_select ON malu$skill_verb
    FOR SELECT
    USING (
        EXISTS (
            SELECT 1
            FROM malu$skill_package p
            WHERE p.owner_schema = malu$skill_verb.owner_schema
              AND p.skill_id = malu$skill_verb.skill_id
              AND (
                  maludb_core._memory_schema_is_owned_by_current_role(p.owner_schema)
                  OR p.visibility = 'public'
                  OR EXISTS (
                      SELECT 1
                        FROM malu$skill_access a
                       WHERE a.owner_schema = p.owner_schema
                         AND a.skill_id = p.skill_id
                         AND a.access_level IN ('read','fork')
                         AND pg_catalog.pg_has_role(current_user, a.grantee_role, 'member')
                  )
              )
        )
    );
CREATE POLICY skill_verb_insert ON malu$skill_verb
    FOR INSERT
    WITH CHECK (
        maludb_core._memory_schema_is_owned_by_current_role(owner_schema)
        AND (
            owner_schema <> 'maludb_public'
            OR pg_catalog.pg_has_role(current_user, 'maludb_skill_curator', 'member')
            OR pg_catalog.pg_has_role(current_user, 'maludb_memory_admin', 'member')
        )
        AND (
            owner_schema = 'maludb_public'
            OR pg_catalog.pg_has_role(current_user, 'maludb_memory_executor', 'member')
            OR pg_catalog.pg_has_role(current_user, 'maludb_memory_admin', 'member')
        )
    );
CREATE POLICY skill_verb_update ON malu$skill_verb
    FOR UPDATE
    USING (
        maludb_core._memory_schema_is_owned_by_current_role(owner_schema)
        AND (
            owner_schema <> 'maludb_public'
            OR pg_catalog.pg_has_role(current_user, 'maludb_skill_curator', 'member')
            OR pg_catalog.pg_has_role(current_user, 'maludb_memory_admin', 'member')
        )
        AND (
            owner_schema = 'maludb_public'
            OR pg_catalog.pg_has_role(current_user, 'maludb_memory_executor', 'member')
            OR pg_catalog.pg_has_role(current_user, 'maludb_memory_admin', 'member')
        )
    )
    WITH CHECK (
        maludb_core._memory_schema_is_owned_by_current_role(owner_schema)
        AND (
            owner_schema <> 'maludb_public'
            OR pg_catalog.pg_has_role(current_user, 'maludb_skill_curator', 'member')
            OR pg_catalog.pg_has_role(current_user, 'maludb_memory_admin', 'member')
        )
        AND (
            owner_schema = 'maludb_public'
            OR pg_catalog.pg_has_role(current_user, 'maludb_memory_executor', 'member')
            OR pg_catalog.pg_has_role(current_user, 'maludb_memory_admin', 'member')
        )
    );
CREATE POLICY skill_verb_delete ON malu$skill_verb
    FOR DELETE
    USING (
        maludb_core._memory_schema_is_owned_by_current_role(owner_schema)
        AND (
            owner_schema <> 'maludb_public'
            OR pg_catalog.pg_has_role(current_user, 'maludb_skill_curator', 'member')
            OR pg_catalog.pg_has_role(current_user, 'maludb_memory_admin', 'member')
        )
        AND (
            owner_schema = 'maludb_public'
            OR pg_catalog.pg_has_role(current_user, 'maludb_memory_executor', 'member')
            OR pg_catalog.pg_has_role(current_user, 'maludb_memory_admin', 'member')
        )
    );

CREATE POLICY skill_embedding_select ON malu$skill_embedding
    FOR SELECT
    USING (
        EXISTS (
            SELECT 1
            FROM malu$skill_package p
            WHERE p.owner_schema = malu$skill_embedding.owner_schema
              AND p.skill_id = malu$skill_embedding.skill_id
              AND (
                  maludb_core._memory_schema_is_owned_by_current_role(p.owner_schema)
                  OR p.visibility = 'public'
                  OR EXISTS (
                      SELECT 1
                        FROM malu$skill_access a
                       WHERE a.owner_schema = p.owner_schema
                         AND a.skill_id = p.skill_id
                         AND a.access_level IN ('read','fork')
                         AND pg_catalog.pg_has_role(current_user, a.grantee_role, 'member')
                  )
              )
        )
    );
CREATE POLICY skill_embedding_insert ON malu$skill_embedding
    FOR INSERT
    WITH CHECK (
        maludb_core._memory_schema_is_owned_by_current_role(owner_schema)
        AND (
            owner_schema <> 'maludb_public'
            OR pg_catalog.pg_has_role(current_user, 'maludb_skill_curator', 'member')
            OR pg_catalog.pg_has_role(current_user, 'maludb_memory_admin', 'member')
        )
        AND (
            owner_schema = 'maludb_public'
            OR pg_catalog.pg_has_role(current_user, 'maludb_memory_executor', 'member')
            OR pg_catalog.pg_has_role(current_user, 'maludb_memory_admin', 'member')
        )
    );
CREATE POLICY skill_embedding_update ON malu$skill_embedding
    FOR UPDATE
    USING (
        maludb_core._memory_schema_is_owned_by_current_role(owner_schema)
        AND (
            owner_schema <> 'maludb_public'
            OR pg_catalog.pg_has_role(current_user, 'maludb_skill_curator', 'member')
            OR pg_catalog.pg_has_role(current_user, 'maludb_memory_admin', 'member')
        )
        AND (
            owner_schema = 'maludb_public'
            OR pg_catalog.pg_has_role(current_user, 'maludb_memory_executor', 'member')
            OR pg_catalog.pg_has_role(current_user, 'maludb_memory_admin', 'member')
        )
    )
    WITH CHECK (
        maludb_core._memory_schema_is_owned_by_current_role(owner_schema)
        AND (
            owner_schema <> 'maludb_public'
            OR pg_catalog.pg_has_role(current_user, 'maludb_skill_curator', 'member')
            OR pg_catalog.pg_has_role(current_user, 'maludb_memory_admin', 'member')
        )
        AND (
            owner_schema = 'maludb_public'
            OR pg_catalog.pg_has_role(current_user, 'maludb_memory_executor', 'member')
            OR pg_catalog.pg_has_role(current_user, 'maludb_memory_admin', 'member')
        )
    );
CREATE POLICY skill_embedding_delete ON malu$skill_embedding
    FOR DELETE
    USING (
        maludb_core._memory_schema_is_owned_by_current_role(owner_schema)
        AND (
            owner_schema <> 'maludb_public'
            OR pg_catalog.pg_has_role(current_user, 'maludb_skill_curator', 'member')
            OR pg_catalog.pg_has_role(current_user, 'maludb_memory_admin', 'member')
        )
        AND (
            owner_schema = 'maludb_public'
            OR pg_catalog.pg_has_role(current_user, 'maludb_memory_executor', 'member')
            OR pg_catalog.pg_has_role(current_user, 'maludb_memory_admin', 'member')
        )
    );

CREATE POLICY skill_access_select ON malu$skill_access
    FOR SELECT
    USING (
        maludb_core._memory_schema_is_owned_by_current_role(owner_schema)
        OR (
            access_level IN ('read','fork')
            AND pg_catalog.pg_has_role(current_user, grantee_role, 'member')
        )
    );
CREATE POLICY skill_access_insert ON malu$skill_access
    FOR INSERT
    WITH CHECK (
        maludb_core._memory_schema_is_owned_by_current_role(owner_schema)
        AND (
            owner_schema <> 'maludb_public'
            OR pg_catalog.pg_has_role(current_user, 'maludb_skill_curator', 'member')
            OR pg_catalog.pg_has_role(current_user, 'maludb_memory_admin', 'member')
        )
        AND (
            owner_schema = 'maludb_public'
            OR pg_catalog.pg_has_role(current_user, 'maludb_memory_executor', 'member')
            OR pg_catalog.pg_has_role(current_user, 'maludb_memory_admin', 'member')
        )
    );
CREATE POLICY skill_access_update ON malu$skill_access
    FOR UPDATE
    USING (
        maludb_core._memory_schema_is_owned_by_current_role(owner_schema)
        AND (
            owner_schema <> 'maludb_public'
            OR pg_catalog.pg_has_role(current_user, 'maludb_skill_curator', 'member')
            OR pg_catalog.pg_has_role(current_user, 'maludb_memory_admin', 'member')
        )
        AND (
            owner_schema = 'maludb_public'
            OR pg_catalog.pg_has_role(current_user, 'maludb_memory_executor', 'member')
            OR pg_catalog.pg_has_role(current_user, 'maludb_memory_admin', 'member')
        )
    )
    WITH CHECK (
        maludb_core._memory_schema_is_owned_by_current_role(owner_schema)
        AND (
            owner_schema <> 'maludb_public'
            OR pg_catalog.pg_has_role(current_user, 'maludb_skill_curator', 'member')
            OR pg_catalog.pg_has_role(current_user, 'maludb_memory_admin', 'member')
        )
        AND (
            owner_schema = 'maludb_public'
            OR pg_catalog.pg_has_role(current_user, 'maludb_memory_executor', 'member')
            OR pg_catalog.pg_has_role(current_user, 'maludb_memory_admin', 'member')
        )
    );
CREATE POLICY skill_access_delete ON malu$skill_access
    FOR DELETE
    USING (
        maludb_core._memory_schema_is_owned_by_current_role(owner_schema)
        AND (
            owner_schema <> 'maludb_public'
            OR pg_catalog.pg_has_role(current_user, 'maludb_skill_curator', 'member')
            OR pg_catalog.pg_has_role(current_user, 'maludb_memory_admin', 'member')
        )
        AND (
            owner_schema = 'maludb_public'
            OR pg_catalog.pg_has_role(current_user, 'maludb_memory_executor', 'member')
            OR pg_catalog.pg_has_role(current_user, 'maludb_memory_admin', 'member')
        )
    );

GRANT SELECT, INSERT, UPDATE, DELETE ON
    malu$skill_keyword,
    malu$skill_subject,
    malu$skill_verb,
    malu$skill_embedding,
    malu$skill_access
TO maludb_memory_admin, maludb_memory_executor;

GRANT SELECT, INSERT, UPDATE, DELETE ON
    malu$skill_package,
    malu$skill_keyword,
    malu$skill_subject,
    malu$skill_verb,
    malu$skill_embedding,
    malu$skill_access
TO maludb_skill_curator;

GRANT SELECT ON
    malu$skill_keyword,
    malu$skill_subject,
    malu$skill_verb,
    malu$skill_embedding,
    malu$skill_access
TO maludb_memory_auditor;

GRANT SELECT ON malu$mc2db_tool_sql_function
TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;

GRANT USAGE, SELECT ON SEQUENCE
    malu$skill_package_skill_id_seq,
    malu$skill_keyword_keyword_id_seq,
    malu$skill_subject_skill_subject_id_seq,
    malu$skill_verb_skill_verb_id_seq,
    malu$skill_embedding_embedding_id_seq,
    malu$skill_access_access_id_seq
TO maludb_skill_curator;

GRANT USAGE, SELECT ON SEQUENCE
    malu$skill_keyword_keyword_id_seq,
    malu$skill_subject_skill_subject_id_seq,
    malu$skill_verb_skill_verb_id_seq,
    malu$skill_embedding_embedding_id_seq,
    malu$skill_access_access_id_seq
TO maludb_memory_admin, maludb_memory_executor;

CREATE OR REPLACE FUNCTION _skill_is_visible(
    p_owner_schema name,
    p_skill_id bigint,
    p_requesting_schema name,
    p_include_public boolean DEFAULT true
) RETURNS boolean
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
    WITH caller AS (
        SELECT COALESCE(NULLIF(current_setting('role', true), 'none'), session_user)::name AS role_name
    )
    SELECT EXISTS (
        SELECT 1
          FROM maludb_core.malu$skill_package s
          CROSS JOIN caller c
         WHERE s.owner_schema = p_owner_schema
           AND s.skill_id = p_skill_id
           AND s.enabled
           AND (
                s.owner_schema = p_requesting_schema
             OR (p_include_public AND s.owner_schema = 'maludb_public' AND s.visibility = 'public')
             OR EXISTS (
                    SELECT 1
                      FROM maludb_core.malu$skill_access a
                     WHERE a.owner_schema = s.owner_schema
                       AND a.skill_id = s.skill_id
                       AND pg_catalog.pg_has_role(c.role_name, a.grantee_role, 'member')
                       AND a.access_level IN ('read','fork')
                )
           )
    )
$body$;

REVOKE ALL ON FUNCTION _skill_is_visible(name, bigint, name, boolean) FROM PUBLIC;

CREATE OR REPLACE FUNCTION find_skill(
    p_query text DEFAULT NULL,
    p_subject text DEFAULT NULL,
    p_verb text DEFAULT NULL,
    p_query_embedding malu_vector DEFAULT NULL,
    p_owner_schema name DEFAULT current_schema(),
    p_limit integer DEFAULT 20,
    p_include_public boolean DEFAULT true
) RETURNS TABLE (
    owner_schema name,
    skill_id bigint,
    skill_name text,
    version text,
    description text,
    visibility text,
    subjects text[],
    verbs text[],
    keywords text[],
    score numeric,
    match_reasons text[],
    is_public boolean,
    is_forkable boolean,
    source_owner_schema name,
    source_skill_id bigint,
    updated_at timestamptz
)
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
WITH params AS (
    SELECT NULLIF(btrim(p_query), '') AS query_text,
           NULLIF(btrim(p_subject), '') AS subject_text,
           NULLIF(btrim(p_verb), '') AS verb_text,
           COALESCE(NULLIF(current_setting('role', true), 'none'), session_user)::name AS caller_role
),
trusted_params AS (
    SELECT p.*,
           CASE
               WHEN p_owner_schema IS NULL THEN NULL::name
               WHEN pg_catalog.pg_has_role(p.caller_role, 'maludb_memory_admin', 'member') THEN p_owner_schema
               WHEN EXISTS (
                   SELECT 1
                     FROM pg_catalog.pg_namespace n
                    WHERE n.nspname = p_owner_schema
                      AND pg_catalog.pg_has_role(p.caller_role, n.nspowner, 'member')
               ) THEN p_owner_schema
               ELSE NULL::name
           END AS requesting_schema
      FROM params p
),
visible_skills AS (
    SELECT s.*
      FROM maludb_core.malu$skill_package s
      CROSS JOIN trusted_params p
     WHERE p.requesting_schema IS NOT NULL
       AND maludb_core._skill_is_visible(s.owner_schema, s.skill_id, p.requesting_schema, p_include_public)
),
tagged AS (
    SELECT s.owner_schema,
           s.skill_id,
           array_remove(array_agg(DISTINCT ss.subject_name ORDER BY ss.subject_name), NULL) AS subjects,
           array_remove(array_agg(DISTINCT sv.verb_name ORDER BY sv.verb_name), NULL) AS verbs,
           array_remove(array_agg(DISTINCT sk.keyword ORDER BY sk.keyword), NULL) AS keywords
      FROM visible_skills s
      LEFT JOIN maludb_core.malu$skill_subject ss
        ON ss.owner_schema = s.owner_schema
       AND ss.skill_id = s.skill_id
      LEFT JOIN maludb_core.malu$skill_verb sv
        ON sv.owner_schema = s.owner_schema
       AND sv.skill_id = s.skill_id
      LEFT JOIN maludb_core.malu$skill_keyword sk
        ON sk.owner_schema = s.owner_schema
       AND sk.skill_id = s.skill_id
     GROUP BY s.owner_schema, s.skill_id
),
embedding_scores AS (
    SELECT se.owner_schema,
           se.skill_id,
           max((1.0 - maludb_core.cosine_distance(se.embedding, p_query_embedding))::numeric) AS embedding_score
      FROM maludb_core.malu$skill_embedding se
      JOIN visible_skills s
        ON s.owner_schema = se.owner_schema
       AND s.skill_id = se.skill_id
     WHERE p_query_embedding IS NOT NULL
       AND se.embedding_dim = maludb_core.vector_dims(p_query_embedding)
       AND maludb_core.vector_dims(se.embedding) = maludb_core.vector_dims(p_query_embedding)
     GROUP BY se.owner_schema, se.skill_id
),
scored AS (
    SELECT s.owner_schema,
           s.skill_id,
           s.skill_name,
           s.version,
           s.description,
           s.visibility,
           COALESCE(t.subjects, ARRAY[]::text[]) AS subjects,
           COALESCE(t.verbs, ARRAY[]::text[]) AS verbs,
           COALESCE(t.keywords, ARRAY[]::text[]) AS keywords,
           (
               CASE WHEN p.subject_text IS NOT NULL
                         AND EXISTS (
                             SELECT 1
                               FROM unnest(COALESCE(t.subjects, ARRAY[]::text[])) AS subject_match(subject_name)
                              WHERE lower(subject_match.subject_name) = lower(p.subject_text)
                         )
                    THEN 100 ELSE 0 END
             + CASE WHEN p.verb_text IS NOT NULL
                         AND EXISTS (
                             SELECT 1
                               FROM unnest(COALESCE(t.verbs, ARRAY[]::text[])) AS verb_match(verb_name)
                              WHERE lower(verb_match.verb_name) = lower(p.verb_text)
                         )
                    THEN 80 ELSE 0 END
             + CASE WHEN p.query_text IS NOT NULL
                         AND EXISTS (
                             SELECT 1
                               FROM unnest(COALESCE(t.keywords, ARRAY[]::text[])) AS keyword_match(keyword_text)
                              WHERE lower(keyword_match.keyword_text) = lower(p.query_text)
                                 OR strpos(lower(p.query_text), lower(keyword_match.keyword_text)) > 0
                                 OR strpos(lower(keyword_match.keyword_text), lower(p.query_text)) > 0
                         )
                    THEN 40 ELSE 0 END
             + CASE WHEN p.query_text IS NOT NULL
                         AND EXISTS (
                             SELECT 1
                               FROM regexp_split_to_table(lower(p.query_text), '[^[:alnum:]_]+') AS query_token(token)
                              WHERE length(query_token.token) > 1
                                AND to_tsvector(
                                        'simple',
                                        COALESCE(s.skill_name, '') || ' ' || COALESCE(s.description, '')
                                    ) @@ plainto_tsquery('simple', query_token.token)
                         )
                    THEN 10 ELSE 0 END
           )::numeric
           + COALESCE(es.embedding_score, 0) AS score,
           array_remove(ARRAY[
               CASE WHEN p.subject_text IS NOT NULL
                         AND EXISTS (
                             SELECT 1
                               FROM unnest(COALESCE(t.subjects, ARRAY[]::text[])) AS subject_match(subject_name)
                              WHERE lower(subject_match.subject_name) = lower(p.subject_text)
                         )
                    THEN 'subject' END,
               CASE WHEN p.verb_text IS NOT NULL
                         AND EXISTS (
                             SELECT 1
                               FROM unnest(COALESCE(t.verbs, ARRAY[]::text[])) AS verb_match(verb_name)
                              WHERE lower(verb_match.verb_name) = lower(p.verb_text)
                         )
                    THEN 'verb' END,
               CASE WHEN p.query_text IS NOT NULL
                         AND EXISTS (
                             SELECT 1
                               FROM unnest(COALESCE(t.keywords, ARRAY[]::text[])) AS keyword_match(keyword_text)
                              WHERE lower(keyword_match.keyword_text) = lower(p.query_text)
                                 OR strpos(lower(p.query_text), lower(keyword_match.keyword_text)) > 0
                                 OR strpos(lower(keyword_match.keyword_text), lower(p.query_text)) > 0
                         )
                    THEN 'keyword' END,
               CASE WHEN p.query_text IS NOT NULL
                         AND EXISTS (
                             SELECT 1
                               FROM regexp_split_to_table(lower(p.query_text), '[^[:alnum:]_]+') AS query_token(token)
                              WHERE length(query_token.token) > 1
                                AND to_tsvector(
                                        'simple',
                                        COALESCE(s.skill_name, '') || ' ' || COALESCE(s.description, '')
                                    ) @@ plainto_tsquery('simple', query_token.token)
                         )
                    THEN 'text' END,
               CASE WHEN es.embedding_score IS NOT NULL THEN 'embedding' END
           ], NULL) AS match_reasons,
           (s.owner_schema = 'maludb_public' AND s.visibility = 'public') AS is_public,
           (
               (s.owner_schema = 'maludb_public' AND s.visibility = 'public')
            OR EXISTS (
                   SELECT 1
                     FROM maludb_core.malu$skill_access a
                   WHERE a.owner_schema = s.owner_schema
                      AND a.skill_id = s.skill_id
                      AND pg_catalog.pg_has_role(p.caller_role, a.grantee_role, 'member')
                      AND a.access_level = 'fork'
               )
           ) AS is_forkable,
           s.source_owner_schema,
           s.source_skill_id,
           s.updated_at,
           p.query_text,
           p.subject_text,
           p.verb_text
      FROM visible_skills s
      CROSS JOIN trusted_params p
      LEFT JOIN tagged t
        ON t.owner_schema = s.owner_schema
       AND t.skill_id = s.skill_id
      LEFT JOIN embedding_scores es
        ON es.owner_schema = s.owner_schema
       AND es.skill_id = s.skill_id
)
SELECT owner_schema,
       skill_id,
       skill_name,
       version,
       description,
       visibility,
       subjects,
       verbs,
       keywords,
       score,
       match_reasons,
       is_public,
       is_forkable,
       source_owner_schema,
       source_skill_id,
       updated_at
  FROM scored
 WHERE score > 0
    OR (
        query_text IS NULL
        AND subject_text IS NULL
        AND verb_text IS NULL
        AND p_query_embedding IS NULL
    )
 ORDER BY score DESC, is_public DESC, updated_at DESC, owner_schema, skill_name, skill_id
 LIMIT GREATEST(COALESCE(p_limit, 20), 1)
$body$;

REVOKE ALL ON FUNCTION find_skill(text, text, text, malu_vector, name, integer, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION find_skill(text, text, text, malu_vector, name, integer, boolean)
TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;

CREATE FUNCTION get_skill(
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

REVOKE ALL ON FUNCTION get_skill(name, bigint, name) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION get_skill(name, bigint, name)
TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;

CREATE FUNCTION fork_skill(
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
        forked_at
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
        now()
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

REVOKE ALL ON FUNCTION fork_skill(name, bigint, name, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fork_skill(name, bigint, name, text, text)
TO maludb_memory_admin, maludb_memory_executor;

CREATE FUNCTION r10_skill_find(args jsonb, context jsonb) RETURNS void
LANGUAGE plpgsql SECURITY INVOKER
AS $body$
DECLARE
    v_query text := args->>'query';
    v_subject text := args->>'subject';
    v_verb text := args->>'verb';
    v_embedding malu_vector;
    v_requesting_schema name;
    v_limit integer := 20;
    v_include_public boolean := true;
    v_results jsonb;
BEGIN
    BEGIN
        v_requesting_schema := NULLIF(args->>'requesting_schema', '')::name;
        v_limit := COALESCE(NULLIF(args->>'limit', '')::integer, 20);
        v_include_public := COALESCE(NULLIF(args->>'include_public', '')::boolean, true);
        IF args ? 'query_embedding' AND args->'query_embedding' IS NOT NULL THEN
            v_embedding := (args->'query_embedding')::text::malu_vector;
        END IF;
    EXCEPTION WHEN OTHERS THEN
        CALL mc2db.put_error('invalid skill.find argument',
            jsonb_build_object('code', 'BAD_INPUT', 'message', SQLERRM));
        RETURN;
    END;

    IF v_requesting_schema IS NULL THEN
        CALL mc2db.put_error('requesting_schema is required',
            jsonb_build_object('code', 'BAD_INPUT'));
        RETURN;
    END IF;

    SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY r.score DESC, r.is_public DESC, r.updated_at DESC, r.owner_schema, r.skill_name, r.skill_id), '[]'::jsonb)
      INTO v_results
      FROM maludb_core.find_skill(
          v_query,
          v_subject,
          v_verb,
          v_embedding,
          v_requesting_schema,
          v_limit,
          v_include_public
      ) AS r;

    CALL mc2db.put_object(jsonb_build_object(
        'content', jsonb_build_array(jsonb_build_object(
            'type', 'text',
            'text', format('%s skill result(s)', jsonb_array_length(v_results))
        )),
        'structuredContent', jsonb_build_object('results', v_results),
        'isError', false
    ));
END;
$body$;

CREATE FUNCTION r10_skill_get(args jsonb, context jsonb) RETURNS void
LANGUAGE plpgsql SECURITY INVOKER
AS $body$
DECLARE
    v_owner_schema name;
    v_skill_id bigint;
    v_requesting_schema name;
    v_payload jsonb;
BEGIN
    BEGIN
        v_owner_schema := NULLIF(args->>'owner_schema', '')::name;
        v_skill_id := NULLIF(args->>'skill_id', '')::bigint;
        v_requesting_schema := NULLIF(args->>'requesting_schema', '')::name;
    EXCEPTION WHEN OTHERS THEN
        CALL mc2db.put_error('invalid skill.get argument',
            jsonb_build_object('code', 'BAD_INPUT', 'message', SQLERRM));
        RETURN;
    END;

    IF v_owner_schema IS NULL OR v_skill_id IS NULL THEN
        CALL mc2db.put_error('owner_schema and skill_id are required',
            jsonb_build_object('code', 'BAD_INPUT'));
        RETURN;
    END IF;

    IF v_requesting_schema IS NULL THEN
        CALL mc2db.put_error('requesting_schema is required',
            jsonb_build_object('code', 'BAD_INPUT'));
        RETURN;
    END IF;

    SELECT got.payload
      INTO v_payload
      FROM maludb_core.get_skill(v_owner_schema, v_skill_id, v_requesting_schema) AS got(payload);

    IF v_payload IS NULL THEN
        CALL mc2db.put_error(format('skill %.% not found or not visible', v_owner_schema, v_skill_id),
            jsonb_build_object('code', 'NOT_FOUND'));
        RETURN;
    END IF;

    CALL mc2db.put_object(jsonb_build_object(
        'content', jsonb_build_array(jsonb_build_object(
            'type', 'text',
            'text', format('skill %s returned', v_skill_id)
        )),
        'structuredContent', jsonb_build_object('payload', v_payload),
        'isError', false
    ));
END;
$body$;

CREATE FUNCTION r10_skill_fork(args jsonb, context jsonb) RETURNS void
LANGUAGE plpgsql SECURITY INVOKER
AS $body$
DECLARE
    v_source_owner_schema name;
    v_source_skill_id bigint;
    v_target_owner_schema name;
    v_new_skill_name text := args->>'new_skill_name';
    v_new_version text := args->>'new_version';
    v_skill_id bigint;
BEGIN
    BEGIN
        v_source_owner_schema := NULLIF(args->>'source_owner_schema', '')::name;
        v_source_skill_id := NULLIF(args->>'source_skill_id', '')::bigint;
        v_target_owner_schema := NULLIF(args->>'target_owner_schema', '')::name;
    EXCEPTION WHEN OTHERS THEN
        CALL mc2db.put_error('invalid skill.fork argument',
            jsonb_build_object('code', 'BAD_INPUT', 'message', SQLERRM));
        RETURN;
    END;

    IF v_source_owner_schema IS NULL OR v_source_skill_id IS NULL THEN
        CALL mc2db.put_error('source_owner_schema and source_skill_id are required',
            jsonb_build_object('code', 'BAD_INPUT'));
        RETURN;
    END IF;

    IF v_target_owner_schema IS NULL THEN
        CALL mc2db.put_error('target_owner_schema is required',
            jsonb_build_object('code', 'BAD_INPUT'));
        RETURN;
    END IF;

    v_skill_id := maludb_core.fork_skill(
        v_source_owner_schema,
        v_source_skill_id,
        v_target_owner_schema,
        v_new_skill_name,
        COALESCE(NULLIF(v_new_version, ''), '1.0.0')
    );

    CALL mc2db.put_object(jsonb_build_object(
        'content', jsonb_build_array(jsonb_build_object(
            'type', 'text',
            'text', format('forked skill %s', v_skill_id)
        )),
        'structuredContent', jsonb_build_object('skill_id', v_skill_id),
        'isError', false
    ));
END;
$body$;

SELECT mc2db.register_tool(
    server_name => 'maludb.r10',
    tool_name => 'skill.find',
    description => 'Find visible MaluDB skills by query, subject, verb, keyword, or embedding.',
    implementation_type => 'sql_function',
    input_schema => '{
        "type":"object",
        "required":["requesting_schema"],
        "properties":{
            "query":{"type":["string","null"]},
            "subject":{"type":["string","null"]},
            "verb":{"type":["string","null"]},
            "query_embedding":{"type":["array","null"],"items":{"type":"number"}},
            "requesting_schema":{"type":["string","null"]},
            "limit":{"type":"integer","minimum":1,"maximum":100},
            "include_public":{"type":"boolean"}
        },
        "additionalProperties":false
    }'::jsonb,
    output_schema => '{
        "type":"object",
        "required":["results"],
        "properties":{"results":{"type":"array"}}
    }'::jsonb,
    risk_class => 'read_only',
    read_only => true,
    impl_metadata => jsonb_build_object(
        'function_signature',
        'maludb_core.r10_skill_find(jsonb, jsonb)'
    ));

SELECT mc2db.register_tool(
    server_name => 'maludb.r10',
    tool_name => 'skill.get',
    description => 'Return the full executable definition for one visible MaluDB skill.',
    implementation_type => 'sql_function',
    input_schema => '{
        "type":"object",
        "required":["owner_schema","skill_id","requesting_schema"],
        "properties":{
            "owner_schema":{"type":"string"},
            "skill_id":{"type":"integer"},
            "requesting_schema":{"type":["string","null"]}
        },
        "additionalProperties":false
    }'::jsonb,
    output_schema => '{
        "type":"object",
        "required":["payload"],
        "properties":{"payload":{"type":"object"}}
    }'::jsonb,
    risk_class => 'read_only',
    read_only => true,
    impl_metadata => jsonb_build_object(
        'function_signature',
        'maludb_core.r10_skill_get(jsonb, jsonb)'
    ));

SELECT mc2db.register_tool(
    server_name => 'maludb.r10',
    tool_name => 'skill.fork',
    description => 'Fork a public or explicitly forkable MaluDB skill into the caller schema.',
    implementation_type => 'sql_function',
    input_schema => '{
        "type":"object",
        "required":["source_owner_schema","source_skill_id","target_owner_schema"],
        "properties":{
            "source_owner_schema":{"type":"string"},
            "source_skill_id":{"type":"integer"},
            "target_owner_schema":{"type":["string","null"]},
            "requesting_schema":{"type":["string","null"]},
            "new_skill_name":{"type":["string","null"]},
            "new_version":{"type":["string","null"]}
        },
        "additionalProperties":false
    }'::jsonb,
    output_schema => '{
        "type":"object",
        "required":["skill_id"],
        "properties":{"skill_id":{"type":"integer"}}
    }'::jsonb,
    risk_class => 'state_changing',
    read_only => false,
    impl_metadata => jsonb_build_object(
        'function_signature',
        'maludb_core.r10_skill_fork(jsonb, jsonb)'
    ));

ALTER FUNCTION _enable_memory_schema_ai_facade(name) RENAME TO _enable_memory_schema_ai_facade_072;
REVOKE ALL ON FUNCTION _enable_memory_schema_ai_facade_072(name) FROM PUBLIC;

CREATE FUNCTION _enable_memory_schema_ai_facade(p_schema name) RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
DECLARE
    v_count integer := 0;
BEGIN
    PERFORM maludb_core._memory_schema_assert_manageable(p_schema);

    IF EXISTS (
        SELECT 1
          FROM pg_catalog.pg_attribute a
         WHERE a.attrelid = to_regclass(format('%I.maludb_skill', p_schema))
           AND a.attname = 'owner_schema'
           AND NOT a.attisdropped
    ) THEN
        -- The retained 0.72 helper reports 18 AI facade objects; skip it
        -- once the upgraded skill facade is present so refreshes stay idempotent.
        v_count := v_count + 18;
    ELSE
        v_count := v_count + maludb_core._enable_memory_schema_ai_facade_072(p_schema);
    END IF;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_skill', 'view');
    EXECUTE format($sql$
        CREATE OR REPLACE VIEW %I.maludb_skill WITH (security_invoker = true) AS
        SELECT skill_id,
               skill_name,
               version,
               description,
               packaging_kind,
               applicability_jsonb,
               precondition_jsonb,
               enabled,
               created_at,
               updated_at,
               visibility,
               source_owner_schema,
               source_skill_id,
               forked_at,
               owner_schema
          FROM maludb_core.malu$skill_package
         WHERE owner_schema = %L
        WITH LOCAL CHECK OPTION
    $sql$, p_schema, p_schema);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON %I.maludb_skill TO maludb_memory_admin, maludb_memory_executor', p_schema);
    EXECUTE format('GRANT SELECT ON %I.maludb_skill TO maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_skill', 'view', 'Schema-local skill package facade.');

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_skill_keyword', 'view');
    EXECUTE format($sql$
        CREATE OR REPLACE VIEW %I.maludb_skill_keyword WITH (security_invoker = true) AS
        SELECT keyword_id,
               skill_id,
               keyword,
               weight,
               provenance,
               created_at
          FROM maludb_core.malu$skill_keyword
         WHERE owner_schema = %L
        WITH LOCAL CHECK OPTION
    $sql$, p_schema, p_schema);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON %I.maludb_skill_keyword TO maludb_memory_admin, maludb_memory_executor', p_schema);
    EXECUTE format('GRANT SELECT ON %I.maludb_skill_keyword TO maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_skill_keyword', 'view', 'Schema-local skill keyword discovery facade.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_skill_subject', 'view');
    EXECUTE format($sql$
        CREATE OR REPLACE VIEW %I.maludb_skill_subject WITH (security_invoker = true) AS
        SELECT skill_subject_id,
               skill_id,
               subject_id,
               subject_name,
               weight,
               provenance,
               created_at
          FROM maludb_core.malu$skill_subject
         WHERE owner_schema = %L
        WITH LOCAL CHECK OPTION
    $sql$, p_schema, p_schema);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON %I.maludb_skill_subject TO maludb_memory_admin, maludb_memory_executor', p_schema);
    EXECUTE format('GRANT SELECT ON %I.maludb_skill_subject TO maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_skill_subject', 'view', 'Schema-local skill subject discovery facade.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_skill_verb', 'view');
    EXECUTE format($sql$
        CREATE OR REPLACE VIEW %I.maludb_skill_verb WITH (security_invoker = true) AS
        SELECT skill_verb_id,
               skill_id,
               verb_id,
               verb_name,
               weight,
               provenance,
               created_at
          FROM maludb_core.malu$skill_verb
         WHERE owner_schema = %L
        WITH LOCAL CHECK OPTION
    $sql$, p_schema, p_schema);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON %I.maludb_skill_verb TO maludb_memory_admin, maludb_memory_executor', p_schema);
    EXECUTE format('GRANT SELECT ON %I.maludb_skill_verb TO maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_skill_verb', 'view', 'Schema-local skill verb discovery facade.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_skill_embedding', 'view');
    EXECUTE format($sql$
        CREATE OR REPLACE VIEW %I.maludb_skill_embedding WITH (security_invoker = true) AS
        SELECT embedding_id,
               skill_id,
               embedding_model,
               embedding_dim,
               embedding,
               source_text_hash,
               source_text_kind,
               created_at
          FROM maludb_core.malu$skill_embedding
         WHERE owner_schema = %L
        WITH LOCAL CHECK OPTION
    $sql$, p_schema, p_schema);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON %I.maludb_skill_embedding TO maludb_memory_admin, maludb_memory_executor', p_schema);
    EXECUTE format('GRANT SELECT ON %I.maludb_skill_embedding TO maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_skill_embedding', 'view', 'Schema-local skill embedding discovery facade.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_skill_access', 'view');
    EXECUTE format($sql$
        CREATE OR REPLACE VIEW %I.maludb_skill_access WITH (security_invoker = true) AS
        SELECT access_id,
               skill_id,
               grantee_role,
               access_level,
               created_at
          FROM maludb_core.malu$skill_access
         WHERE owner_schema = %L
        WITH LOCAL CHECK OPTION
    $sql$, p_schema, p_schema);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON %I.maludb_skill_access TO maludb_memory_admin, maludb_memory_executor', p_schema);
    EXECUTE format('GRANT SELECT ON %I.maludb_skill_access TO maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_skill_access', 'view', 'Schema-local skill access discovery facade.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_skill_search', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_skill_search(
            p_query text DEFAULT NULL,
            p_subject text DEFAULT NULL,
            p_verb text DEFAULT NULL,
            p_query_embedding maludb_core.malu_vector DEFAULT NULL,
            p_limit integer DEFAULT 20,
            p_include_public boolean DEFAULT true
        ) RETURNS TABLE (
            owner_schema name,
            skill_id bigint,
            skill_name text,
            version text,
            description text,
            visibility text,
            subjects text[],
            verbs text[],
            keywords text[],
            score numeric,
            match_reasons text[],
            is_public boolean,
            is_forkable boolean,
            source_owner_schema name,
            source_skill_id bigint,
            updated_at timestamptz
        )
        LANGUAGE SQL
        SECURITY INVOKER
        SET search_path = pg_catalog, maludb_core, pg_temp
        AS $fn$
            SELECT *
              FROM maludb_core.find_skill(
                  p_query,
                  p_subject,
                  p_verb,
                  p_query_embedding,
                  %L::name,
                  p_limit,
                  p_include_public
              )
        $fn$;
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_skill_search(text, text, text, maludb_core.malu_vector, integer, boolean) FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_skill_search(text, text, text, maludb_core.malu_vector, integer, boolean) TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_skill_search', 'function', 'Schema-local skill discovery search wrapper.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_skill_get', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_skill_get(
            p_owner_schema name,
            p_skill_id bigint
        ) RETURNS TABLE (payload jsonb)
        LANGUAGE SQL
        SECURITY INVOKER
        SET search_path = pg_catalog, maludb_core, pg_temp
        AS $fn$
            SELECT *
              FROM maludb_core.get_skill(
                  p_owner_schema,
                  p_skill_id,
                  %L::name
              )
        $fn$;
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_skill_get(name, bigint) FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_skill_get(name, bigint) TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_skill_get', 'function', 'Schema-local full skill discovery payload wrapper.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_skill_fork', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_skill_fork(
            p_source_owner_schema name,
            p_source_skill_id bigint,
            p_new_skill_name text DEFAULT NULL,
            p_new_version text DEFAULT '1.0.0'
        ) RETURNS bigint
        LANGUAGE SQL
        SECURITY INVOKER
        SET search_path = pg_catalog, maludb_core, pg_temp
        AS $fn$
            SELECT maludb_core.fork_skill(
                p_source_owner_schema,
                p_source_skill_id,
                %L::name,
                p_new_skill_name,
                p_new_version
            )
        $fn$;
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_skill_fork(name, bigint, text, text) FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_skill_fork(name, bigint, text, text) TO maludb_memory_admin, maludb_memory_executor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_skill_fork', 'function', 'Schema-local skill fork wrapper.');
    v_count := v_count + 1;

    IF p_schema = 'maludb_public' THEN
        EXECUTE format('REVOKE INSERT, UPDATE, DELETE ON %I.maludb_skill FROM maludb_memory_executor', p_schema);
        EXECUTE format('REVOKE INSERT, UPDATE, DELETE ON %I.maludb_skill_keyword FROM maludb_memory_executor', p_schema);
        EXECUTE format('REVOKE INSERT, UPDATE, DELETE ON %I.maludb_skill_subject FROM maludb_memory_executor', p_schema);
        EXECUTE format('REVOKE INSERT, UPDATE, DELETE ON %I.maludb_skill_verb FROM maludb_memory_executor', p_schema);
        EXECUTE format('REVOKE INSERT, UPDATE, DELETE ON %I.maludb_skill_embedding FROM maludb_memory_executor', p_schema);
        EXECUTE format('REVOKE INSERT, UPDATE, DELETE ON %I.maludb_skill_access FROM maludb_memory_executor', p_schema);
        EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON %I.maludb_skill TO maludb_skill_curator', p_schema);
        EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON %I.maludb_skill_keyword TO maludb_skill_curator', p_schema);
        EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON %I.maludb_skill_subject TO maludb_skill_curator', p_schema);
        EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON %I.maludb_skill_verb TO maludb_skill_curator', p_schema);
        EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON %I.maludb_skill_embedding TO maludb_skill_curator', p_schema);
        EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON %I.maludb_skill_access TO maludb_skill_curator', p_schema);
    END IF;

    RETURN v_count;
END;
$body$;

REVOKE ALL ON FUNCTION _enable_memory_schema_ai_facade(name) FROM PUBLIC;

CREATE OR REPLACE FUNCTION enable_memory_schema(p_schema name DEFAULT current_schema())
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

    schema_name := p_schema;
    enabled_version := v_enabled_version;
    object_count := v_count;
    RETURN NEXT;
END;
$body$;

REVOKE ALL ON FUNCTION enable_memory_schema(name) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION enable_memory_schema(name)
TO maludb_memory_admin, maludb_memory_executor;
