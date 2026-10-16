\echo Use "ALTER EXTENSION maludb_core UPDATE TO '0.54.0'" to load this file. \quit

-- =====================================================================
-- maludb_core 0.53.0 → 0.54.0
--
-- Stage 15 / V3-OBS-01: metric definitions + scrape function.
--
-- The CLI's `maludb metrics scrape` has shipped a Prometheus-flavoured
-- preview since Stage 10. This migration promotes that surface to a
-- server-side concern:
--
--   malu$metric_definition  — one row per metric the project exposes,
--                              with kind, help text, and label set.
--                              Seeded with the families enumerated in
--                              version3-plan.md V3-OBS-01.
--   metrics_prometheus_scrape() — returns a single text blob in
--                              prom exposition format, assembled from
--                              live counters across audit / queue /
--                              REST / MC2DB / auth / secret / vector /
--                              event / source / schedule tables.
--                              The REST gateway (V3-API-01) wires
--                              GET /metrics to this function.
--
-- Apply with:
--   ALTER EXTENSION maludb_core UPDATE TO '0.54.0';
-- =====================================================================

CREATE OR REPLACE FUNCTION maludb_core_version() RETURNS text
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$ SELECT '0.54.0'::text $body$;

-- ---------------------------------------------------------------------
-- malu$metric_definition
-- ---------------------------------------------------------------------
CREATE TABLE malu$metric_definition (
    metric_id    bigserial PRIMARY KEY,
    name         text       NOT NULL UNIQUE,
    kind         text       NOT NULL CHECK (kind IN ('counter','gauge','histogram')),
    help_text    text       NOT NULL,
    labels       text[]     NOT NULL DEFAULT ARRAY[]::text[],
    created_at   timestamptz NOT NULL DEFAULT now(),
    retired_at   timestamptz
);

GRANT SELECT, INSERT, UPDATE, DELETE ON malu$metric_definition TO maludb_memory_admin;
GRANT SELECT                          ON malu$metric_definition TO maludb_memory_executor, maludb_memory_auditor, maludb_rest_dispatcher;
GRANT USAGE, SELECT ON SEQUENCE malu$metric_definition_metric_id_seq TO maludb_memory_admin;

-- Seed the V3-OBS-01 metric families. INSERT IF NOT EXISTS so re-runs
-- of the migration on an installed cluster don't error (would never
-- happen for a single migration step, but defensive).
INSERT INTO malu$metric_definition(name, kind, help_text, labels) VALUES
    ('maludb_extension_version',                 'gauge',   'Always 1; the version is a label.',                        ARRAY['version']),
    ('maludb_catalog_tables',                    'gauge',   'Count of malu$ tables in the maludb_core schema.',         ARRAY[]::text[]),
    ('maludb_audit_event_total',                 'counter', 'Total audit events recorded.',                             ARRAY[]::text[]),
    ('maludb_audit_event_by_kind_total',         'counter', 'Audit events recorded, labeled by event_kind.',            ARRAY['event_kind']),
    ('maludb_mc2db_invocation_total',            'counter', 'MC2DB tool invocations.',                                  ARRAY[]::text[]),
    ('maludb_mc2db_invocation_outcome_total',    'counter', 'MC2DB invocations by outcome.',                            ARRAY['outcome']),
    ('maludb_rest_invocation_total',             'counter', 'REST gateway invocations.',                                ARRAY[]::text[]),
    ('maludb_rest_invocation_outcome_total',     'counter', 'REST invocations by outcome.',                             ARRAY['outcome']),
    ('maludb_auth_token_total',                  'gauge',   'API tokens by state.',                                     ARRAY['state']),
    ('maludb_secret_total',                      'gauge',   'Secrets by state.',                                        ARRAY['state']),
    ('maludb_queue_depth',                       'gauge',   'Queue depth by queue name and status.',                    ARRAY['queue','status']),
    ('maludb_cron_schedule_total',               'gauge',   'Schedules by enabled state.',                              ARRAY['enabled']),
    ('maludb_source_object_total',               'gauge',   'Source archive objects by retention class.',               ARRAY['retention_class']),
    ('maludb_event_total',                       'counter', 'Realtime event rows.',                                     ARRAY[]::text[]),
    ('maludb_event_subscription_total',          'gauge',   'Active event subscriptions.',                              ARRAY[]::text[]),
    ('maludb_vector_compartment_total',          'gauge',   'Vector compartments by search mode.',                      ARRAY['search_mode']),
    ('maludb_embedding_job_total',               'gauge',   'Embedding jobs by status.',                                ARRAY['status'])
ON CONFLICT (name) DO NOTHING;

-- =====================================================================
-- metrics_prometheus_scrape — returns the full exposition text.
-- =====================================================================
CREATE FUNCTION metrics_prometheus_scrape()
    RETURNS text
    LANGUAGE plpgsql STABLE
    AS $body$
#variable_conflict use_column
DECLARE
    v_buf text := '';
    r record;
    v_ext_version text;
BEGIN
    SELECT maludb_core_version() INTO v_ext_version;

    -- HELP/TYPE block per metric.
    FOR r IN SELECT name, kind, help_text FROM malu$metric_definition WHERE retired_at IS NULL ORDER BY name LOOP
        v_buf := v_buf || format('# HELP %s %s%s# TYPE %s %s%s',
                                 r.name, r.help_text, E'\n',
                                 r.name, r.kind, E'\n');
    END LOOP;

    v_buf := v_buf || format('maludb_extension_version{version="%s"} 1%s', v_ext_version, E'\n');

    -- catalog_tables
    v_buf := v_buf || format('maludb_catalog_tables %s%s',
        (SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE n.nspname = 'maludb_core' AND c.relkind = 'r' AND c.relname LIKE 'malu$%'),
        E'\n');

    v_buf := v_buf || format('maludb_audit_event_total %s%s',
        (SELECT count(*) FROM malu$audit_event), E'\n');

    FOR r IN SELECT event_kind, count(*) AS n FROM malu$audit_event GROUP BY event_kind ORDER BY event_kind LOOP
        v_buf := v_buf || format('maludb_audit_event_by_kind_total{event_kind="%s"} %s%s',
                                 r.event_kind, r.n, E'\n');
    END LOOP;

    v_buf := v_buf || format('maludb_mc2db_invocation_total %s%s',
        (SELECT count(*) FROM malu$mc2db_invocation), E'\n');
    FOR r IN SELECT CASE WHEN success THEN 'success' ELSE 'failure' END AS outcome,
                    count(*) AS n
               FROM malu$mc2db_invocation GROUP BY 1 LOOP
        v_buf := v_buf || format('maludb_mc2db_invocation_outcome_total{outcome="%s"} %s%s',
                                 r.outcome, r.n, E'\n');
    END LOOP;

    v_buf := v_buf || format('maludb_rest_invocation_total %s%s',
        (SELECT count(*) FROM malu$rest_invocation), E'\n');
    FOR r IN SELECT CASE WHEN success THEN 'success' ELSE 'failure' END AS outcome,
                    count(*) AS n
               FROM malu$rest_invocation GROUP BY 1 LOOP
        v_buf := v_buf || format('maludb_rest_invocation_outcome_total{outcome="%s"} %s%s',
                                 r.outcome, r.n, E'\n');
    END LOOP;

    FOR r IN
        SELECT CASE WHEN revoked_at IS NULL AND (expires_at IS NULL OR expires_at > now())
                    THEN 'active' ELSE 'revoked' END AS state,
               count(*) AS n
          FROM malu$auth_token GROUP BY 1
    LOOP
        v_buf := v_buf || format('maludb_auth_token_total{state="%s"} %s%s',
                                 r.state, r.n, E'\n');
    END LOOP;

    FOR r IN
        SELECT CASE WHEN retired_at IS NULL THEN 'active' ELSE 'retired' END AS state,
               count(*) AS n
          FROM malu$secret GROUP BY 1
    LOOP
        v_buf := v_buf || format('maludb_secret_total{state="%s"} %s%s',
                                 r.state, r.n, E'\n');
    END LOOP;

    FOR r IN
        SELECT q.name AS queue, j.status, count(*) AS n
          FROM malu$queue q
          JOIN malu$queue_job j ON j.queue_id = q.queue_id
         WHERE q.retired_at IS NULL
         GROUP BY q.name, j.status
    LOOP
        v_buf := v_buf || format('maludb_queue_depth{queue="%s",status="%s"} %s%s',
                                 r.queue, r.status, r.n, E'\n');
    END LOOP;

    FOR r IN
        SELECT CASE WHEN enabled THEN 'true' ELSE 'false' END AS enabled, count(*) AS n
          FROM malu$schedule WHERE retired_at IS NULL GROUP BY enabled
    LOOP
        v_buf := v_buf || format('maludb_cron_schedule_total{enabled="%s"} %s%s',
                                 r.enabled, r.n, E'\n');
    END LOOP;

    FOR r IN
        SELECT retention_class, count(*) AS n
          FROM malu$source_object WHERE retired_at IS NULL GROUP BY retention_class
    LOOP
        v_buf := v_buf || format('maludb_source_object_total{retention_class="%s"} %s%s',
                                 r.retention_class, r.n, E'\n');
    END LOOP;

    v_buf := v_buf || format('maludb_event_total %s%s',
        (SELECT count(*) FROM malu$event), E'\n');
    v_buf := v_buf || format('maludb_event_subscription_total %s%s',
        (SELECT count(*) FROM malu$event_subscription WHERE retired_at IS NULL), E'\n');

    FOR r IN
        SELECT search_mode, count(*) AS n FROM malu$vector_compartment GROUP BY search_mode
    LOOP
        v_buf := v_buf || format('maludb_vector_compartment_total{search_mode="%s"} %s%s',
                                 r.search_mode, r.n, E'\n');
    END LOOP;

    FOR r IN
        SELECT status, count(*) AS n FROM malu$embedding_job GROUP BY status
    LOOP
        v_buf := v_buf || format('maludb_embedding_job_total{status="%s"} %s%s',
                                 r.status, r.n, E'\n');
    END LOOP;

    RETURN v_buf;
END;
$body$;
REVOKE EXECUTE ON FUNCTION metrics_prometheus_scrape() FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION metrics_prometheus_scrape() TO
    maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor,
    maludb_rest_dispatcher;
