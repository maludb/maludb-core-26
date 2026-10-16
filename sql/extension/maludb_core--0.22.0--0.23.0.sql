\echo Use "ALTER EXTENSION maludb_core UPDATE TO '0.23.0'" to load this file. \quit

-- =====================================================================
-- maludb_core 0.22.0 → 0.23.0
--
-- Stage 3 — Bitemporal columns (S3-1).
--
-- Per requirements.md §3.4: bitemporal columns (event_time,
-- valid_time_*, transaction_time_*, source_time, verification_time,
-- stale_after) using tstzrange + GIST exclusion.
--
-- S3-1 adds the columns + generated tstzrange + helper functions.
-- The EXCLUDE USING gist constraint that enforces no-overlapping-
-- validity per (subject, verb, predicate) ships in S3-2 (Temporal
-- Supersession Engine), where the surrounding correction flow
-- (close prior window + open new version + supersedes edge) is also
-- defined.
--
-- Tables that get bitemporal columns:
--   malu$claim          — assertions; can be open-ended
--   malu$fact           — verified state; correction discipline applies
--   malu$memory         — contextual records
--   malu$episode_object — DBMS representation of an episode
--
-- malu$source_package keeps its existing single timestamps
-- (captured_at, ingested_at, sealed_at, archived_at, tombstoned_at);
-- verbatim artifacts don't have a "valid time" concept.
-- =====================================================================

CREATE OR REPLACE FUNCTION maludb_core_version() RETURNS text
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$ SELECT '0.23.0'::text $body$;

-- btree_gist is required for the (text WITH =, range WITH &&)
-- exclusion the supersession engine (S3-2) will add. Pulling it in
-- now so operators don't hit a surprise dep on the next upgrade.
CREATE EXTENSION IF NOT EXISTS btree_gist;

-- ---------------------------------------------------------------------
-- Generic helpers — bitemporal predicates that work on any (start, end)
-- pair. IMMUTABLE so they can participate in indexes/EXCLUDEs.
-- ---------------------------------------------------------------------
CREATE FUNCTION is_currently_valid(
    p_start timestamptz,
    p_end   timestamptz
) RETURNS boolean
LANGUAGE sql IMMUTABLE PARALLEL SAFE
AS $body$
    SELECT (p_start IS NULL OR p_start <= now())
       AND (p_end   IS NULL OR p_end   >  now());
$body$;

CREATE FUNCTION is_valid_at(
    p_start timestamptz,
    p_end   timestamptz,
    p_at    timestamptz
) RETURNS boolean
LANGUAGE sql IMMUTABLE PARALLEL SAFE
AS $body$
    SELECT (p_start IS NULL OR p_start <= p_at)
       AND (p_end   IS NULL OR p_end   >  p_at);
$body$;

-- ---------------------------------------------------------------------
-- Add bitemporal columns + generated tstzrange columns to each table.
-- Defaults are chosen so existing register_* helpers keep working
-- unchanged: valid_time_start defaults to now() at insert,
-- transaction_time_start is NOT NULL DEFAULT now() (the canonical
-- "row exists" timestamp).
-- ---------------------------------------------------------------------

-- ---- malu$claim ----------------------------------------------------
ALTER TABLE malu$claim
    ADD COLUMN event_time             timestamptz,
    ADD COLUMN valid_time_start       timestamptz DEFAULT now(),
    ADD COLUMN valid_time_end         timestamptz,
    ADD COLUMN transaction_time_start timestamptz NOT NULL DEFAULT now(),
    ADD COLUMN transaction_time_end   timestamptz,
    ADD COLUMN source_time            timestamptz,
    ADD COLUMN verification_time      timestamptz,
    ADD COLUMN stale_after            timestamptz;

ALTER TABLE malu$claim
    ADD COLUMN valid_time_range tstzrange GENERATED ALWAYS AS
        (tstzrange(valid_time_start, valid_time_end, '[)')) STORED,
    ADD COLUMN transaction_time_range tstzrange GENERATED ALWAYS AS
        (tstzrange(transaction_time_start, transaction_time_end, '[)')) STORED;

CREATE INDEX malu$claim_valid_time_idx
    ON malu$claim USING gist (valid_time_range);
CREATE INDEX malu$claim_tx_time_idx
    ON malu$claim USING gist (transaction_time_range);

-- ---- malu$fact -----------------------------------------------------
ALTER TABLE malu$fact
    ADD COLUMN event_time             timestamptz,
    ADD COLUMN valid_time_start       timestamptz DEFAULT now(),
    ADD COLUMN valid_time_end         timestamptz,
    ADD COLUMN transaction_time_start timestamptz NOT NULL DEFAULT now(),
    ADD COLUMN transaction_time_end   timestamptz,
    ADD COLUMN source_time            timestamptz,
    ADD COLUMN verification_time      timestamptz,
    ADD COLUMN stale_after            timestamptz;

ALTER TABLE malu$fact
    ADD COLUMN valid_time_range tstzrange GENERATED ALWAYS AS
        (tstzrange(valid_time_start, valid_time_end, '[)')) STORED,
    ADD COLUMN transaction_time_range tstzrange GENERATED ALWAYS AS
        (tstzrange(transaction_time_start, transaction_time_end, '[)')) STORED;

CREATE INDEX malu$fact_valid_time_idx
    ON malu$fact USING gist (valid_time_range);
CREATE INDEX malu$fact_tx_time_idx
    ON malu$fact USING gist (transaction_time_range);

-- ---- malu$memory ---------------------------------------------------
ALTER TABLE malu$memory
    ADD COLUMN event_time             timestamptz,
    ADD COLUMN valid_time_start       timestamptz DEFAULT now(),
    ADD COLUMN valid_time_end         timestamptz,
    ADD COLUMN transaction_time_start timestamptz NOT NULL DEFAULT now(),
    ADD COLUMN transaction_time_end   timestamptz,
    ADD COLUMN source_time            timestamptz,
    ADD COLUMN verification_time      timestamptz,
    ADD COLUMN stale_after            timestamptz;

ALTER TABLE malu$memory
    ADD COLUMN valid_time_range tstzrange GENERATED ALWAYS AS
        (tstzrange(valid_time_start, valid_time_end, '[)')) STORED,
    ADD COLUMN transaction_time_range tstzrange GENERATED ALWAYS AS
        (tstzrange(transaction_time_start, transaction_time_end, '[)')) STORED;

CREATE INDEX malu$memory_valid_time_idx
    ON malu$memory USING gist (valid_time_range);
CREATE INDEX malu$memory_tx_time_idx
    ON malu$memory USING gist (transaction_time_range);

-- ---- malu$episode_object -------------------------------------------
ALTER TABLE malu$episode_object
    ADD COLUMN event_time             timestamptz,
    ADD COLUMN valid_time_start       timestamptz DEFAULT now(),
    ADD COLUMN valid_time_end         timestamptz,
    ADD COLUMN transaction_time_start timestamptz NOT NULL DEFAULT now(),
    ADD COLUMN transaction_time_end   timestamptz,
    ADD COLUMN source_time            timestamptz,
    ADD COLUMN verification_time      timestamptz,
    ADD COLUMN stale_after            timestamptz;

ALTER TABLE malu$episode_object
    ADD COLUMN valid_time_range tstzrange GENERATED ALWAYS AS
        (tstzrange(valid_time_start, valid_time_end, '[)')) STORED,
    ADD COLUMN transaction_time_range tstzrange GENERATED ALWAYS AS
        (tstzrange(transaction_time_start, transaction_time_end, '[)')) STORED;

CREATE INDEX malu$episode_valid_time_idx
    ON malu$episode_object USING gist (valid_time_range);
CREATE INDEX malu$episode_tx_time_idx
    ON malu$episode_object USING gist (transaction_time_range);

-- ---------------------------------------------------------------------
-- "Current" views — operator-facing convenience over the bitemporal
-- shape. Each filters to lifecycle='active' AND is_currently_valid.
-- These views are non-updatable; writes still go through register_*
-- helpers.
-- ---------------------------------------------------------------------
CREATE VIEW malu$current_claim AS
SELECT * FROM malu$claim
WHERE is_currently_valid(valid_time_start, valid_time_end)
  AND retracted_at IS NULL;

CREATE VIEW malu$current_fact AS
SELECT * FROM malu$fact
WHERE is_currently_valid(valid_time_start, valid_time_end)
  AND lifecycle_state = 'active'
  AND superseded_at IS NULL;

CREATE VIEW malu$current_memory AS
SELECT * FROM malu$memory
WHERE is_currently_valid(valid_time_start, valid_time_end)
  AND lifecycle_state = 'active';

CREATE VIEW malu$current_episode AS
SELECT * FROM malu$episode_object
WHERE is_currently_valid(valid_time_start, valid_time_end)
  AND lifecycle_state = 'active';

GRANT SELECT ON
    malu$current_claim, malu$current_fact, malu$current_memory, malu$current_episode
TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;

-- ---------------------------------------------------------------------
-- as_of(p_at) helper: same shape as the current views but at an
-- arbitrary point. Per requirements.md §3.4: replay must reconstruct
-- the historical, current-valid, transaction-time, or full bitemporal
-- view. S3-1 ships the valid-time slice; transaction-time slice is
-- straightforward to query directly with WHERE
-- transaction_time_range @> p_at.
-- ---------------------------------------------------------------------
CREATE FUNCTION fact_as_of(p_at timestamptz) RETURNS SETOF malu$fact
LANGUAGE sql STABLE
AS $body$
    SELECT * FROM malu$fact
    WHERE is_valid_at(valid_time_start, valid_time_end, p_at)
      AND (transaction_time_start <= p_at)
      AND (transaction_time_end IS NULL OR transaction_time_end > p_at)
      AND lifecycle_state = 'active';
$body$;

CREATE FUNCTION memory_as_of(p_at timestamptz) RETURNS SETOF malu$memory
LANGUAGE sql STABLE
AS $body$
    SELECT * FROM malu$memory
    WHERE is_valid_at(valid_time_start, valid_time_end, p_at)
      AND (transaction_time_start <= p_at)
      AND (transaction_time_end IS NULL OR transaction_time_end > p_at)
      AND lifecycle_state = 'active';
$body$;

CREATE FUNCTION episode_as_of(p_at timestamptz) RETURNS SETOF malu$episode_object
LANGUAGE sql STABLE
AS $body$
    SELECT * FROM malu$episode_object
    WHERE is_valid_at(valid_time_start, valid_time_end, p_at)
      AND (transaction_time_start <= p_at)
      AND (transaction_time_end IS NULL OR transaction_time_end > p_at)
      AND lifecycle_state = 'active';
$body$;

GRANT EXECUTE ON FUNCTION
    is_currently_valid(timestamptz, timestamptz),
    is_valid_at(timestamptz, timestamptz, timestamptz),
    fact_as_of(timestamptz),
    memory_as_of(timestamptz),
    episode_as_of(timestamptz)
TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;

-- ---------------------------------------------------------------------
-- Stage-boundary update: malu$valid_time_window and
-- malu$transaction_time_window placeholders are NO LONGER reserved
-- as separate tables — those columns now live on each governed
-- table. Stage 3 reservations still pending: malu$supersession_edge,
-- malu$svpor_*, malu$maut_score.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stage_boundary_violations()
RETURNS TABLE(object_kind text, object_name text, stage smallint)
LANGUAGE sql STABLE
AS $body$
    WITH forbidden(name, stage) AS (
        VALUES
            ('malu$governed_object'::text,       2::smallint),
            ('malu$supersession_edge',           3),
            ('malu$svpor_subject',               3),
            ('malu$svpor_verb',                  3),
            ('malu$svpor_predicate',             3),
            ('malu$maut_score',                  3),
            ('malu$workflow_trace',              5),
            ('malu$generalized_workflow',        5),
            ('malu$procedural_memory_object',    5),
            ('malu$skill_package',               5),
            ('malu$competency_package',          5),
            ('malu$active_memory_pool',          5),
            ('malu$episode_replay',              5),
            ('malu$local_memory_node',           6),
            ('malu$node_sync_record',            6)
    )
    SELECT 'table'::text, c.relname::text, f.stage
    FROM pg_catalog.pg_class c
    JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
    JOIN forbidden f ON f.name = c.relname
    WHERE n.nspname = 'maludb_core'
      AND c.relkind IN ('r','p','v','m')
    ORDER BY f.stage, c.relname;
$body$;
