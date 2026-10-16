\echo Use "ALTER EXTENSION maludb_core UPDATE TO '0.96.0'" to load this file. \quit

-- =====================================================================
-- maludb_core 0.95.0 -> 0.96.0  --  event kinds become first-class
-- subject types
--
-- 0.94.0 folded episodes into subjects: an event's subject_type IS its
-- event kind (deployment, incident, daily_standup, ...). But those
-- kinds only ever materialized LAZILY, via _ensure_subject_type_for_kind,
-- with an identical generic description ("Event kind (auto-registered
-- from an episode kind).") and system_defined = false. Two consequences:
--
--   * The extraction LLM got no guidance distinguishing one kind from
--     another -- the very per-type context that the curated entity-type
--     descriptions exist to give weaker cloud models.
--   * Free-form kinds fragmented the catalog: standup / daily_standup /
--     stand_up each minted a distinct type, splitting what should group.
--
-- Entity types, by contrast, are curated (seeded, described) AND
-- protected (the strict normalizer rejects unknown ones). Event kinds
-- were the opposite: ad-hoc and wide open. This release gives the
-- common event kinds the same curated treatment, and makes the two
-- type families explicit so a prompt builder can emit two labelled
-- lists from one catalog query.
--
-- Changes:
--   1. malu$svpor_subject_type gains category ('entity' | 'event').
--      Existing rows default to 'entity'; the generic 'event' type and
--      any previously auto-registered kind are moved to 'event'.
--   2. The common event kinds are seeded system_defined = true with
--      discriminative descriptions and an event sort-band (300-410).
--   3. _ensure_subject_type_for_kind stamps category = 'event' on any
--      still-novel kind it auto-registers (the safety net stays).
--   4. The maludb_subject_type facade exposes category (new _0960
--      facade builder; the view joins the enable_memory_schema
--      drop-first list so its column set can grow across re-enables).
--      Tenants pick up the column by re-running enable_memory_schema().
--
-- DECISION: 'project' stays ENTITY-only. The extraction prompt's
-- event-kind list drops 'project'; a planned-work occurrence uses
-- 'task'. (A project entity and a "project kickoff" occurrence must not
-- collide on one subject_type primary key.)
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. category column. New column + new CHECK (NOT a rebuild of an
--    existing IN-list CHECK), so the 0.82.0 CHECK-rebuild bug class
--    does not apply. Existing rows back-fill to 'entity' via DEFAULT.
-- ---------------------------------------------------------------------
ALTER TABLE maludb_core.malu$svpor_subject_type
    ADD COLUMN category text NOT NULL DEFAULT 'entity'
        CHECK (category IN ('entity','event'));

-- ---------------------------------------------------------------------
-- 2. Seed the common event kinds. ON CONFLICT DO UPDATE so a kind that
--    was previously lazily auto-registered (generic description,
--    system_defined = false, category back-filled to 'entity') is
--    promoted in place to its curated, described, event-categorised form.
--    Descriptions are written to DISCRIMINATE neighbours (the guidance a
--    weaker extraction model needs), not merely to define.
-- ---------------------------------------------------------------------
INSERT INTO maludb_core.malu$svpor_subject_type
        (subject_type, display_name, description, sort_order, system_defined, category) VALUES
    ('meeting',            'Meeting',            'A scheduled gathering of people. Use for a general meeting; prefer a more specific kind (daily_standup, review, retrospective, one_on_one) when one fits.', 300, true, 'event'),
    ('daily_standup',      'Daily Standup',      'A recurring short team status sync (standup). Use instead of meeting for routine daily syncs.', 310, true, 'event'),
    ('one_on_one',         'One-on-One',         'A 1:1 between two people (e.g. manager and report). Use instead of meeting for a two-person check-in.', 320, true, 'event'),
    ('review',             'Review',             'A review session of in-progress work or a decision (code review, design review). Not a retrospective, which looks back on finished work.', 330, true, 'event'),
    ('retrospective',      'Retrospective',      'A look-back on a completed sprint or project to capture lessons. Not a review of in-progress work.', 340, true, 'event'),
    ('planning',           'Planning',           'A planning session that scopes upcoming work (sprint or release planning). The work items it produces are ''task'' events.', 350, true, 'event'),
    ('sprint',             'Sprint',             'A time-boxed iteration of work. Use occurred_at / occurred_until for the iteration window.', 360, true, 'event'),
    ('task',               'Task',               'A planned unit of work, or its execution. The default kind for planned work when nothing more specific fits.', 370, true, 'event'),
    ('deployment',         'Deployment',         'A release or rollout of software or configuration to an environment.', 380, true, 'event'),
    ('incident',           'Incident',           'An unplanned disruption, outage, or failure. The default kind for unplanned events; not a planned ''task''.', 390, true, 'event'),
    ('maintenance_window', 'Maintenance Window', 'A scheduled window for maintenance or upgrades. Use occurred_at / occurred_until for the window.', 400, true, 'event')
ON CONFLICT (subject_type) DO UPDATE
    SET display_name   = EXCLUDED.display_name,
        description    = EXCLUDED.description,
        sort_order     = EXCLUDED.sort_order,
        system_defined = true,
        category       = 'event';

-- ---------------------------------------------------------------------
-- 3. Re-categorise the generic 'event' fallback and any kind that was
--    lazily auto-registered before this release (it carried the generic
--    auto-register description and is not one of the curated kinds above).
-- ---------------------------------------------------------------------
UPDATE maludb_core.malu$svpor_subject_type
   SET category = 'event'
 WHERE subject_type = 'event';

UPDATE maludb_core.malu$svpor_subject_type
   SET category = 'event'
 WHERE category = 'entity'
   AND system_defined = false
   AND description = 'Event kind (auto-registered from an episode kind).';

-- ---------------------------------------------------------------------
-- 4. The lazy safety net keeps working, but now stamps category =
--    'event' for genuinely novel kinds (display_name + sort_order band
--    unchanged from 0.94.0). Still ON CONFLICT DO NOTHING -- a kind that
--    a curator has already shaped is left as-is.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION maludb_core._ensure_subject_type_for_kind(p_kind text) RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
DECLARE
    v_slug text := COALESCE(maludb_core._svpor_slug(p_kind), 'event');
BEGIN
    INSERT INTO maludb_core.malu$svpor_subject_type
        (subject_type, display_name, description, sort_order, system_defined, category)
    VALUES (v_slug,
            initcap(replace(v_slug, '_', ' ')),
            'Event kind (auto-registered from an episode kind).',
            500, false, 'event')
    ON CONFLICT (subject_type) DO NOTHING;
    RETURN v_slug;
END;
$body$;

-- ---------------------------------------------------------------------
-- 5. 0960 facade builder: re-create the maludb_subject_type facade with
--    the trailing category column. The 075 builder still emits the
--    pre-0.96 six-column shape; this runs after it and CREATE OR REPLACE
--    appends category. maludb_subject_type joins the enable_memory_schema
--    drop-first list (section 6) so a re-enable starts from the six-column
--    base -- CREATE OR REPLACE VIEW cannot drop a column, and without the
--    drop a second re-enable would see the seven-column view and the 075
--    builder's six-column CREATE OR REPLACE would fail.
-- ---------------------------------------------------------------------
CREATE FUNCTION maludb_core._enable_memory_schema_0960_facade(p_schema name) RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
DECLARE
    v_count integer := 0;
BEGIN
    PERFORM maludb_core._memory_schema_assert_manageable(p_schema);

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_subject_type', 'view');
    EXECUTE format($sql$
        CREATE OR REPLACE VIEW %I.maludb_subject_type AS
        SELECT subject_type, display_name, description, sort_order, system_defined, created_at, category
          FROM maludb_core.malu$svpor_subject_type
    $sql$, p_schema);
    EXECUTE format('GRANT SELECT ON %I.maludb_subject_type TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_subject_type', 'view', 'Schema-local SVPOR subject type catalog facade.');
    v_count := v_count + 1;

    RETURN v_count;
END;
$body$;

REVOKE ALL ON FUNCTION maludb_core._enable_memory_schema_0960_facade(name) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core._enable_memory_schema_0960_facade(name)
    TO maludb_memory_admin, maludb_memory_executor;

-- ---------------------------------------------------------------------
-- 6. Wire the 0960 facade into enable_memory_schema, and add
--    maludb_subject_type to the drop-first list (see section 5).
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
-- 7. Version stamp.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION maludb_core.maludb_core_version() RETURNS text
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$ SELECT '0.96.0'::text $body$;
