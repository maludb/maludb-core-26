\echo Use "ALTER EXTENSION maludb_core UPDATE TO '0.41.0'" to load this file. \quit

-- =====================================================================
-- maludb_core 0.40.0 → 0.41.0
--
-- S7-2.a — owner_schema + RLS on malu$mc2db_invocation.
--
-- Closes docs/security-review.md finding #2: every MC2DB tool call
-- lands an audit row in malu$mc2db_invocation, but the table had no
-- tenant discriminator. As long as only the extension owner had
-- GRANT, the leak was theoretical — but as soon as an operator
-- opens self-service audit-reader access, cross-tenant invocation
-- patterns would be visible.
--
-- This migration:
--   1. ADD COLUMN owner_schema NOT NULL DEFAULT current_schema().
--   2. Backfills existing rows with 'maludb_core' (the extension
--      owner schema, which is where every pre-0.41 invocation row
--      originated).
--   3. ENABLE ROW LEVEL SECURITY + a tenant_owner policy.
--   4. Grants SELECT on the table to the memory_* role family so
--      tenants can read their own invocation history; INSERT stays
--      restricted to the extension owner (the dispatcher writes
--      through SECURITY DEFINER-style elevation, which is its job).
--
-- The dispatcher (mc2dbd) must, when invoking a tool on behalf of a
-- tenant, ensure current_schema() resolves to the tenant's schema
-- before the INSERT. The standard pattern is:
--   SET LOCAL ROLE <tenant_role>;
--   SET LOCAL search_path TO <tenant_schema>, maludb_core, public;
-- =====================================================================

CREATE OR REPLACE FUNCTION maludb_core_version() RETURNS text
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$ SELECT '0.41.0'::text $body$;

-- =====================================================================
-- 1. Add owner_schema with a backfill-safe default.
-- =====================================================================
ALTER TABLE malu$mc2db_invocation
    ADD COLUMN owner_schema name NOT NULL DEFAULT current_schema();

-- 2. Backfill existing rows. ADD COLUMN ... NOT NULL DEFAULT fills
--    with the DEFAULT at the time of ALTER, which is 'maludb_core'
--    when the migration runs as the extension owner. Explicit update
--    here just to make the intent unmistakable.
UPDATE malu$mc2db_invocation
   SET owner_schema = 'maludb_core'
 WHERE owner_schema IS NULL OR owner_schema = '';

-- 3. RLS.
ALTER TABLE malu$mc2db_invocation ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_owner ON malu$mc2db_invocation
    USING (owner_schema = current_schema())
    WITH CHECK (owner_schema = current_schema());

CREATE INDEX malu$mc2db_invocation_owner_idx
    ON malu$mc2db_invocation(owner_schema, started_at DESC);

-- 4. Grants — same pattern as the Tier-B governed-object surface:
--    SELECT to admin/executor/auditor; no INSERT/UPDATE/DELETE to
--    memory_* (the dispatcher owns the write path, not tenants).
GRANT SELECT ON malu$mc2db_invocation TO
    maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;

-- =====================================================================
-- Stage-boundary roadmap is unchanged; malu$mc2db_invocation was
-- never on the forbidden list.
-- =====================================================================
