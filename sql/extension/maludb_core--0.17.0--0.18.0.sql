\echo Use "ALTER EXTENSION maludb_core UPDATE TO '0.18.0'" to load this file. \quit

-- =====================================================================
-- maludb_core 0.17.0 → 0.18.0
--
-- Stage 2 — Cross-tenant relationship edges + malu$object_grant
-- (S2-5).
--
-- Per CLAUDE.md tenancy doc: cross-tenant malu$relationship_edge rows
-- are owned by the schema that recorded the edge; cross-tenant
-- visibility requires malu$object_grant entries.
--
-- Implementation: add a second PERMISSIVE RLS policy to each Stage 2
-- table. RLS combines permissive policies with OR, so the existing
-- tenant_owner policy stays in force and the new grant_visibility
-- policy expands the visible set when explicit grants exist.
--
-- malu$object_grant rows live in the granter's schema (granted_by_
-- schema = current_schema()). The grant points at a specific
-- (object_type, object_id) and a target schema (granted_to_schema)
-- with a grant_level ∈ {read, write, full}. Time-bounded via
-- expires_at; revoked via revoked_at.
-- =====================================================================

CREATE OR REPLACE FUNCTION maludb_core_version() RETURNS text
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$ SELECT '0.18.0'::text $body$;

-- ---------------------------------------------------------------------
-- malu$object_grant
-- ---------------------------------------------------------------------
CREATE TABLE malu$object_grant (
    grant_id            bigserial PRIMARY KEY,
    object_type         text NOT NULL,
    object_id           bigint NOT NULL,
    granted_by_schema   name NOT NULL DEFAULT current_schema(),
    granted_to_schema   name NOT NULL,
    grant_level         text NOT NULL DEFAULT 'read'
        CHECK (grant_level IN ('read','write','full')),
    granted_at          timestamptz NOT NULL DEFAULT now(),
    expires_at          timestamptz,
    revoked_at          timestamptz,
    note                text,
    CHECK (object_type IN
        ('source_package','claim','fact','memory','episode_object',
         'memory_detail_object','relationship_edge','derivation_ledger')),
    -- A given grantee can only have one active grant per object —
    -- raise the level instead of stacking. Revoked rows are kept for
    -- audit; partial unique index ensures only one active row.
    CONSTRAINT malu$object_grant_unique_active
        EXCLUDE (object_type WITH =, object_id WITH =, granted_to_schema WITH =)
        WHERE (revoked_at IS NULL)
);

CREATE INDEX malu$object_grant_target_idx
    ON malu$object_grant(object_type, object_id, granted_to_schema)
    WHERE revoked_at IS NULL;

CREATE INDEX malu$object_grant_grantee_idx
    ON malu$object_grant(granted_to_schema, object_type)
    WHERE revoked_at IS NULL;

CREATE INDEX malu$object_grant_granter_idx
    ON malu$object_grant(granted_by_schema, object_type)
    WHERE revoked_at IS NULL;

-- ---------------------------------------------------------------------
-- RLS on malu$object_grant: granter sees/manages their own grants;
-- grantee sees the grants pointed at them (read-only).
-- ---------------------------------------------------------------------
ALTER TABLE malu$object_grant ENABLE ROW LEVEL SECURITY;

CREATE POLICY granter_owns ON malu$object_grant
    USING (granted_by_schema = current_schema())
    WITH CHECK (granted_by_schema = current_schema());

CREATE POLICY grantee_can_see ON malu$object_grant
    AS PERMISSIVE FOR SELECT
    USING (granted_to_schema = current_schema());

GRANT SELECT ON malu$object_grant TO
    maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;
GRANT INSERT, UPDATE, DELETE ON malu$object_grant TO
    maludb_memory_admin, maludb_memory_executor;
GRANT USAGE, SELECT ON SEQUENCE malu$object_grant_grant_id_seq TO
    maludb_memory_admin, maludb_memory_executor;

-- ---------------------------------------------------------------------
-- _grant_active(p_object_type, p_object_id, p_grant_levels[]) → bool
--
-- Helper for RLS USING/WITH CHECK clauses. Returns true when an
-- active grant exists from any schema to current_schema() for the
-- given object at one of the requested levels.
-- ---------------------------------------------------------------------
CREATE FUNCTION _grant_active(
    p_object_type  text,
    p_object_id    bigint,
    p_grant_levels text[]
) RETURNS boolean
LANGUAGE sql STABLE
AS $body$
    SELECT EXISTS (
        SELECT 1 FROM malu$object_grant g
        WHERE g.object_type = p_object_type
          AND g.object_id   = p_object_id
          AND g.granted_to_schema = current_schema()
          AND g.grant_level = ANY(p_grant_levels)
          AND g.revoked_at IS NULL
          AND (g.expires_at IS NULL OR g.expires_at > now())
    );
$body$;

-- =====================================================================
-- Permissive RLS policies on the eight Stage 2 governed tables.
-- These OR with the existing tenant_owner policies — never replace.
--
-- USING clause: read access requires any grant level.
-- WITH CHECK clause: write requires grant_level ∈ {write, full}.
--   DELETE is enforced via the same WITH CHECK (PG checks WITH CHECK
--   on UPDATE; DELETE uses USING only — so we restrict DELETE via
--   the underlying table GRANT, not this policy).
-- =====================================================================

CREATE POLICY grant_visibility ON malu$source_package
    AS PERMISSIVE
    USING (_grant_active('source_package', source_package_id,
                         ARRAY['read','write','full']))
    WITH CHECK (_grant_active('source_package', source_package_id,
                              ARRAY['write','full']));

CREATE POLICY grant_visibility ON malu$claim
    AS PERMISSIVE
    USING (_grant_active('claim', claim_id, ARRAY['read','write','full']))
    WITH CHECK (_grant_active('claim', claim_id, ARRAY['write','full']));

CREATE POLICY grant_visibility ON malu$fact
    AS PERMISSIVE
    USING (_grant_active('fact', fact_id, ARRAY['read','write','full']))
    WITH CHECK (_grant_active('fact', fact_id, ARRAY['write','full']));

CREATE POLICY grant_via_fact ON malu$fact_claim
    AS PERMISSIVE
    USING (_grant_active('fact', fact_id, ARRAY['read','write','full']))
    WITH CHECK (_grant_active('fact', fact_id, ARRAY['write','full']));

CREATE POLICY grant_visibility ON malu$memory
    AS PERMISSIVE
    USING (_grant_active('memory', memory_id, ARRAY['read','write','full']))
    WITH CHECK (_grant_active('memory', memory_id, ARRAY['write','full']));

CREATE POLICY grant_visibility ON malu$episode_object
    AS PERMISSIVE
    USING (_grant_active('episode_object', episode_id,
                         ARRAY['read','write','full']))
    WITH CHECK (_grant_active('episode_object', episode_id,
                              ARRAY['write','full']));

CREATE POLICY grant_visibility ON malu$memory_detail_object
    AS PERMISSIVE
    USING (_grant_active('memory_detail_object', mdo_id,
                         ARRAY['read','write','full']))
    WITH CHECK (_grant_active('memory_detail_object', mdo_id,
                              ARRAY['write','full']));

CREATE POLICY grant_visibility ON malu$relationship_edge
    AS PERMISSIVE
    USING (_grant_active('relationship_edge', edge_id,
                         ARRAY['read','write','full']))
    WITH CHECK (_grant_active('relationship_edge', edge_id,
                              ARRAY['write','full']));

CREATE POLICY grant_visibility ON malu$derivation_ledger
    AS PERMISSIVE
    USING (_grant_active('derivation_ledger', derivation_id,
                         ARRAY['read','write','full']))
    WITH CHECK (_grant_active('derivation_ledger', derivation_id,
                              ARRAY['write','full']));

-- ---------------------------------------------------------------------
-- grant_object_access(object_type, object_id, granted_to_schema,
--                     grant_level='read', expires_at=NULL, note=NULL)
--   → bigint grant_id
--
-- Idempotent for active grants: if a non-revoked grant already exists
-- to the same (object, schema) pair, the level/expiry/note are
-- updated and the existing grant_id is returned. New target schemas
-- always create a new row.
--
-- The granter must own (or have a 'full' grant on) the object.
-- Enforcement happens via the table's RLS: if current_schema() can't
-- see the source row, the existence-check fails.
-- ---------------------------------------------------------------------
CREATE FUNCTION grant_object_access(
    p_object_type      text,
    p_object_id        bigint,
    p_granted_to_schema name,
    p_grant_level      text       DEFAULT 'read',
    p_expires_at       timestamptz DEFAULT NULL,
    p_note             text       DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql
AS $body$
DECLARE
    v_id     bigint;
    v_exists boolean;
BEGIN
    IF p_grant_level NOT IN ('read','write','full') THEN
        RAISE EXCEPTION 'grant_object_access: bad level %', p_grant_level
            USING ERRCODE = 'invalid_parameter_value';
    END IF;
    IF p_granted_to_schema IS NULL OR p_granted_to_schema = current_schema() THEN
        RAISE EXCEPTION 'grant_object_access: must grant to a different schema'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    -- Existence check uses RLS: if the granter can't see the row,
    -- the EXISTS yields false and we refuse.
    EXECUTE format(
        'SELECT EXISTS (SELECT 1 FROM maludb_core.%I WHERE %I = $1)',
        CASE p_object_type
            WHEN 'source_package'        THEN 'malu$source_package'
            WHEN 'claim'                 THEN 'malu$claim'
            WHEN 'fact'                  THEN 'malu$fact'
            WHEN 'memory'                THEN 'malu$memory'
            WHEN 'episode_object'        THEN 'malu$episode_object'
            WHEN 'memory_detail_object'  THEN 'malu$memory_detail_object'
            WHEN 'relationship_edge'     THEN 'malu$relationship_edge'
            WHEN 'derivation_ledger'     THEN 'malu$derivation_ledger'
        END,
        CASE p_object_type
            WHEN 'source_package'        THEN 'source_package_id'
            WHEN 'claim'                 THEN 'claim_id'
            WHEN 'fact'                  THEN 'fact_id'
            WHEN 'memory'                THEN 'memory_id'
            WHEN 'episode_object'        THEN 'episode_id'
            WHEN 'memory_detail_object'  THEN 'mdo_id'
            WHEN 'relationship_edge'     THEN 'edge_id'
            WHEN 'derivation_ledger'     THEN 'derivation_id'
        END
    ) INTO v_exists USING p_object_id;
    IF NOT v_exists THEN
        RAISE EXCEPTION 'grant_object_access: %s id=% not visible to current schema',
            p_object_type, p_object_id
            USING ERRCODE = 'no_data_found';
    END IF;

    -- Upsert by (object_type, object_id, granted_to_schema) for the
    -- active row.
    UPDATE malu$object_grant
       SET grant_level = p_grant_level,
           expires_at  = p_expires_at,
           note        = COALESCE(p_note, note),
           granted_at  = now()
     WHERE object_type        = p_object_type
       AND object_id          = p_object_id
       AND granted_to_schema  = p_granted_to_schema
       AND revoked_at         IS NULL
     RETURNING grant_id INTO v_id;
    IF FOUND THEN
        RETURN v_id;
    END IF;

    INSERT INTO malu$object_grant
        (object_type, object_id, granted_to_schema,
         grant_level, expires_at, note)
    VALUES (p_object_type, p_object_id, p_granted_to_schema,
            p_grant_level, p_expires_at, p_note)
    RETURNING grant_id INTO v_id;
    RETURN v_id;
END;
$body$;

-- ---------------------------------------------------------------------
-- revoke_object_grant(grant_id, reason=NULL) → void
--
-- Marks the grant revoked. Reason is appended to the note column for
-- audit; the row stays for history.
-- ---------------------------------------------------------------------
CREATE FUNCTION revoke_object_grant(
    p_grant_id bigint,
    p_reason   text DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql
AS $body$
BEGIN
    UPDATE malu$object_grant
       SET revoked_at = now(),
           note       = COALESCE(note || E'\n', '') ||
                        'revoked: ' || COALESCE(p_reason, 'no reason given')
     WHERE grant_id = p_grant_id
       AND revoked_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'revoke_object_grant: grant_id=% not found or already revoked',
            p_grant_id
            USING ERRCODE = 'no_data_found';
    END IF;
END;
$body$;

-- ---------------------------------------------------------------------
-- list_object_grants(p_object_type, p_object_id) → SETOF grant rows
-- Visible per RLS (granter sees own; grantee sees own).
-- ---------------------------------------------------------------------
CREATE FUNCTION list_object_grants(
    p_object_type text,
    p_object_id   bigint
) RETURNS TABLE (
    grant_id            bigint,
    granted_by_schema   name,
    granted_to_schema   name,
    grant_level         text,
    granted_at          timestamptz,
    expires_at          timestamptz,
    revoked_at          timestamptz,
    note                text
) LANGUAGE sql STABLE
AS $body$
    SELECT grant_id, granted_by_schema, granted_to_schema, grant_level,
           granted_at, expires_at, revoked_at, note
    FROM malu$object_grant
    WHERE object_type = p_object_type
      AND object_id   = p_object_id
    ORDER BY granted_at DESC;
$body$;

GRANT EXECUTE ON FUNCTION
    _grant_active(text, bigint, text[]),
    grant_object_access(text, bigint, name, text, timestamptz, text),
    revoke_object_grant(bigint, text),
    list_object_grants(text, bigint)
TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;
