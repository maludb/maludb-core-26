\echo Use "ALTER EXTENSION maludb_core UPDATE TO '0.25.0'" to load this file. \quit

-- =====================================================================
-- maludb_core 0.24.0 → 0.25.0
--
-- Stage 3 — SVPOR organization layer (S3-3).
--
-- Per requirements.md §3.2: "Memory objects, claims, facts, and
-- embedded chunks must carry an explicit SVPOR frame so the system
-- can route on (subject, verb), bind embedding inputs deterministically,
-- and surface contradictions across related predicates."
--
-- And §9 Stage 3: "SVPOR organization layer + routing indexes; SVPOR
-- participation in embedding inputs."
--
-- Surface:
--   * Three Tier-A-style canonical registries: malu$svpor_subject,
--     malu$svpor_verb, malu$svpor_predicate. Each row carries a
--     canonical_name + aliases[] for normalization.
--   * register_svpor_subject / _verb / _predicate helpers (upsert).
--   * resolve_svpor_subject / _verb / _predicate (canonical OR alias
--     lookup; returns id or NULL).
--   * malu$claim / malu$fact get nullable svpor_*_id FK columns
--     plus a BEFORE INSERT/UPDATE trigger that auto-resolves text
--     to IDs when a canonical match exists.
--   * Composite routing index on (svpor_subject_id, svpor_verb_id).
--   * svpor_frame_text(...) — the deterministic embedding-input
--     prefix the caller's pipeline prepends to chunk text before
--     submitting for embedding.
--
-- Distinct from R1.1-12 malu$vector_subject / _verb which are
-- per-compartment routing tags (Stage 1.7); the malu$svpor_*
-- registries are the Stage 3 SEMANTIC layer with synonyms and
-- equivalence classes.
-- =====================================================================

CREATE OR REPLACE FUNCTION maludb_core_version() RETURNS text
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$ SELECT '0.25.0'::text $body$;

-- =====================================================================
-- SVPOR registries
-- =====================================================================
CREATE TABLE malu$svpor_subject (
    subject_id      bigserial PRIMARY KEY,
    owner_schema    name NOT NULL DEFAULT current_schema(),
    canonical_name  text NOT NULL,
    aliases         text[] NOT NULL DEFAULT ARRAY[]::text[],
    description     text,
    created_at      timestamptz NOT NULL DEFAULT now(),
    UNIQUE (owner_schema, canonical_name)
);
CREATE INDEX malu$svpor_subject_aliases_gin
    ON malu$svpor_subject USING gin (aliases);

CREATE TABLE malu$svpor_verb (
    verb_id         bigserial PRIMARY KEY,
    owner_schema    name NOT NULL DEFAULT current_schema(),
    canonical_name  text NOT NULL,
    aliases         text[] NOT NULL DEFAULT ARRAY[]::text[],
    description     text,
    created_at      timestamptz NOT NULL DEFAULT now(),
    UNIQUE (owner_schema, canonical_name)
);
CREATE INDEX malu$svpor_verb_aliases_gin
    ON malu$svpor_verb USING gin (aliases);

CREATE TABLE malu$svpor_predicate (
    predicate_id    bigserial PRIMARY KEY,
    owner_schema    name NOT NULL DEFAULT current_schema(),
    canonical_name  text NOT NULL,
    aliases         text[] NOT NULL DEFAULT ARRAY[]::text[],
    description     text,
    created_at      timestamptz NOT NULL DEFAULT now(),
    UNIQUE (owner_schema, canonical_name)
);
CREATE INDEX malu$svpor_predicate_aliases_gin
    ON malu$svpor_predicate USING gin (aliases);

ALTER TABLE malu$svpor_subject   ENABLE ROW LEVEL SECURITY;
ALTER TABLE malu$svpor_verb      ENABLE ROW LEVEL SECURITY;
ALTER TABLE malu$svpor_predicate ENABLE ROW LEVEL SECURITY;

CREATE POLICY tenant_owner ON malu$svpor_subject
    USING (owner_schema = current_schema())
    WITH CHECK (owner_schema = current_schema());
CREATE POLICY tenant_owner ON malu$svpor_verb
    USING (owner_schema = current_schema())
    WITH CHECK (owner_schema = current_schema());
CREATE POLICY tenant_owner ON malu$svpor_predicate
    USING (owner_schema = current_schema())
    WITH CHECK (owner_schema = current_schema());

GRANT SELECT ON malu$svpor_subject, malu$svpor_verb, malu$svpor_predicate TO
    maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;
GRANT INSERT, UPDATE, DELETE ON malu$svpor_subject, malu$svpor_verb, malu$svpor_predicate TO
    maludb_memory_admin, maludb_memory_executor;
GRANT USAGE, SELECT ON SEQUENCE
    malu$svpor_subject_subject_id_seq,
    malu$svpor_verb_verb_id_seq,
    malu$svpor_predicate_predicate_id_seq
TO maludb_memory_admin, maludb_memory_executor;

-- =====================================================================
-- register_svpor_* — upsert by (owner_schema, canonical_name).
-- aliases array is merged (union) with any existing values on conflict.
-- =====================================================================
CREATE FUNCTION register_svpor_subject(
    p_canonical_name text,
    p_aliases        text[] DEFAULT ARRAY[]::text[],
    p_description    text   DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql
AS $body$
DECLARE v_id bigint;
BEGIN
    INSERT INTO malu$svpor_subject (canonical_name, aliases, description)
    VALUES (p_canonical_name, COALESCE(p_aliases, ARRAY[]::text[]), p_description)
    ON CONFLICT (owner_schema, canonical_name) DO UPDATE
        SET aliases     = (SELECT array_agg(DISTINCT a)
                           FROM unnest(malu$svpor_subject.aliases || COALESCE(EXCLUDED.aliases, ARRAY[]::text[])) AS a),
            description = COALESCE(EXCLUDED.description, malu$svpor_subject.description)
    RETURNING subject_id INTO v_id;
    RETURN v_id;
END;
$body$;

CREATE FUNCTION register_svpor_verb(
    p_canonical_name text,
    p_aliases        text[] DEFAULT ARRAY[]::text[],
    p_description    text   DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql
AS $body$
DECLARE v_id bigint;
BEGIN
    INSERT INTO malu$svpor_verb (canonical_name, aliases, description)
    VALUES (p_canonical_name, COALESCE(p_aliases, ARRAY[]::text[]), p_description)
    ON CONFLICT (owner_schema, canonical_name) DO UPDATE
        SET aliases     = (SELECT array_agg(DISTINCT a)
                           FROM unnest(malu$svpor_verb.aliases || COALESCE(EXCLUDED.aliases, ARRAY[]::text[])) AS a),
            description = COALESCE(EXCLUDED.description, malu$svpor_verb.description)
    RETURNING verb_id INTO v_id;
    RETURN v_id;
END;
$body$;

CREATE FUNCTION register_svpor_predicate(
    p_canonical_name text,
    p_aliases        text[] DEFAULT ARRAY[]::text[],
    p_description    text   DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql
AS $body$
DECLARE v_id bigint;
BEGIN
    INSERT INTO malu$svpor_predicate (canonical_name, aliases, description)
    VALUES (p_canonical_name, COALESCE(p_aliases, ARRAY[]::text[]), p_description)
    ON CONFLICT (owner_schema, canonical_name) DO UPDATE
        SET aliases     = (SELECT array_agg(DISTINCT a)
                           FROM unnest(malu$svpor_predicate.aliases || COALESCE(EXCLUDED.aliases, ARRAY[]::text[])) AS a),
            description = COALESCE(EXCLUDED.description, malu$svpor_predicate.description)
    RETURNING predicate_id INTO v_id;
    RETURN v_id;
END;
$body$;

-- =====================================================================
-- resolve_svpor_* — text → id lookup. Tries canonical_name first,
-- then aliases. Returns NULL when neither matches (graceful: callers
-- carry the literal text in the existing columns).
-- =====================================================================
CREATE FUNCTION resolve_svpor_subject(p_text text) RETURNS bigint
LANGUAGE sql STABLE
AS $body$
    SELECT subject_id FROM malu$svpor_subject
    WHERE canonical_name = p_text OR p_text = ANY(aliases)
    ORDER BY (canonical_name = p_text) DESC LIMIT 1;
$body$;

CREATE FUNCTION resolve_svpor_verb(p_text text) RETURNS bigint
LANGUAGE sql STABLE
AS $body$
    SELECT verb_id FROM malu$svpor_verb
    WHERE canonical_name = p_text OR p_text = ANY(aliases)
    ORDER BY (canonical_name = p_text) DESC LIMIT 1;
$body$;

CREATE FUNCTION resolve_svpor_predicate(p_text text) RETURNS bigint
LANGUAGE sql STABLE
AS $body$
    SELECT predicate_id FROM malu$svpor_predicate
    WHERE canonical_name = p_text OR p_text = ANY(aliases)
    ORDER BY (canonical_name = p_text) DESC LIMIT 1;
$body$;

-- =====================================================================
-- Add FK columns to malu$claim and malu$fact. ON DELETE SET NULL so
-- registry pruning doesn't cascade through governed data.
-- =====================================================================
ALTER TABLE malu$claim
    ADD COLUMN svpor_subject_id   bigint REFERENCES malu$svpor_subject(subject_id)     ON DELETE SET NULL,
    ADD COLUMN svpor_verb_id      bigint REFERENCES malu$svpor_verb(verb_id)           ON DELETE SET NULL,
    ADD COLUMN svpor_predicate_id bigint REFERENCES malu$svpor_predicate(predicate_id) ON DELETE SET NULL;

ALTER TABLE malu$fact
    ADD COLUMN svpor_subject_id   bigint REFERENCES malu$svpor_subject(subject_id)     ON DELETE SET NULL,
    ADD COLUMN svpor_verb_id      bigint REFERENCES malu$svpor_verb(verb_id)           ON DELETE SET NULL,
    ADD COLUMN svpor_predicate_id bigint REFERENCES malu$svpor_predicate(predicate_id) ON DELETE SET NULL;

-- Routing indexes: (subject, verb) is the dominant access path per §3.2.
CREATE INDEX malu$claim_svpor_routing_idx
    ON malu$claim (svpor_subject_id, svpor_verb_id)
    WHERE svpor_subject_id IS NOT NULL OR svpor_verb_id IS NOT NULL;
CREATE INDEX malu$fact_svpor_routing_idx
    ON malu$fact (svpor_subject_id, svpor_verb_id)
    WHERE svpor_subject_id IS NOT NULL OR svpor_verb_id IS NOT NULL;

-- =====================================================================
-- Auto-resolve trigger — when subject/verb/predicate text is written
-- and the matching svpor_*_id is NULL, attempt to resolve via the
-- registries. If no match, leave the FK NULL (caller carries the
-- literal text in subject/verb/predicate). Idempotent for re-resolve
-- after registry updates (operator can SET svpor_subject_id=NULL +
-- update text to force a fresh lookup).
-- =====================================================================
CREATE FUNCTION _svpor_auto_resolve() RETURNS trigger
LANGUAGE plpgsql
AS $body$
BEGIN
    IF NEW.svpor_subject_id IS NULL AND NEW.subject IS NOT NULL THEN
        NEW.svpor_subject_id := resolve_svpor_subject(NEW.subject);
    END IF;
    IF NEW.svpor_verb_id IS NULL AND NEW.verb IS NOT NULL THEN
        NEW.svpor_verb_id := resolve_svpor_verb(NEW.verb);
    END IF;
    IF NEW.svpor_predicate_id IS NULL AND NEW.predicate IS NOT NULL THEN
        NEW.svpor_predicate_id := resolve_svpor_predicate(NEW.predicate);
    END IF;
    RETURN NEW;
END;
$body$;

CREATE TRIGGER claim_svpor_resolve_tg
    BEFORE INSERT OR UPDATE OF subject, verb, predicate ON malu$claim
    FOR EACH ROW EXECUTE FUNCTION _svpor_auto_resolve();
CREATE TRIGGER fact_svpor_resolve_tg
    BEFORE INSERT OR UPDATE OF subject, verb, predicate ON malu$fact
    FOR EACH ROW EXECUTE FUNCTION _svpor_auto_resolve();

-- =====================================================================
-- svpor_frame_text — the embedding-input prefix. The caller's
-- pipeline prepends this to chunk text before submitting to the
-- embedding model. Per §3.2: "bind embedding inputs deterministically".
--
-- Format: "[svpor] <subject> · <verb> [· <predicate>] [= <object>]"
-- Stable across runs; missing components render as "?".
-- =====================================================================
CREATE FUNCTION svpor_frame_text(
    p_subject       text,
    p_verb          text,
    p_predicate     text DEFAULT NULL,
    p_object_value  text DEFAULT NULL
) RETURNS text
LANGUAGE sql IMMUTABLE PARALLEL SAFE
AS $body$
    SELECT '[svpor] ' ||
           COALESCE(NULLIF(p_subject, ''), '?') || ' · ' ||
           COALESCE(NULLIF(p_verb,    ''), '?') ||
           CASE WHEN NULLIF(p_predicate,    '') IS NOT NULL
                THEN ' · ' || p_predicate ELSE '' END ||
           CASE WHEN NULLIF(p_object_value, '') IS NOT NULL
                THEN ' = ' || p_object_value ELSE '' END;
$body$;

-- =====================================================================
-- A view that surfaces resolved canonical names alongside the
-- literal text for ops/UX surfaces.
-- =====================================================================
CREATE VIEW malu$claim_svpor_resolved AS
SELECT c.claim_id,
       c.owner_schema,
       c.subject       AS subject_text,
       s.canonical_name AS subject_canonical,
       c.verb          AS verb_text,
       v.canonical_name AS verb_canonical,
       c.predicate     AS predicate_text,
       p.canonical_name AS predicate_canonical,
       c.object_value,
       c.statement_text,
       c.svpor_subject_id, c.svpor_verb_id, c.svpor_predicate_id
FROM malu$claim c
LEFT JOIN malu$svpor_subject   s ON s.subject_id   = c.svpor_subject_id
LEFT JOIN malu$svpor_verb      v ON v.verb_id      = c.svpor_verb_id
LEFT JOIN malu$svpor_predicate p ON p.predicate_id = c.svpor_predicate_id;

CREATE VIEW malu$fact_svpor_resolved AS
SELECT f.fact_id,
       f.owner_schema,
       f.subject       AS subject_text,
       s.canonical_name AS subject_canonical,
       f.verb          AS verb_text,
       v.canonical_name AS verb_canonical,
       f.predicate     AS predicate_text,
       p.canonical_name AS predicate_canonical,
       f.object_value,
       f.statement_text,
       f.lifecycle_state,
       f.svpor_subject_id, f.svpor_verb_id, f.svpor_predicate_id
FROM malu$fact f
LEFT JOIN malu$svpor_subject   s ON s.subject_id   = f.svpor_subject_id
LEFT JOIN malu$svpor_verb      v ON v.verb_id      = f.svpor_verb_id
LEFT JOIN malu$svpor_predicate p ON p.predicate_id = f.svpor_predicate_id;

GRANT SELECT ON malu$claim_svpor_resolved, malu$fact_svpor_resolved TO
    maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;

GRANT EXECUTE ON FUNCTION
    register_svpor_subject(text, text[], text),
    register_svpor_verb(text, text[], text),
    register_svpor_predicate(text, text[], text),
    resolve_svpor_subject(text),
    resolve_svpor_verb(text),
    resolve_svpor_predicate(text),
    svpor_frame_text(text, text, text, text)
TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;

-- =====================================================================
-- Stage-boundary update. Remove the three svpor_* placeholder names.
-- Remaining Stage 3+ reservations: malu$maut_score (S3-4); Stage 5+
-- and Stage 6+ rows unchanged.
-- =====================================================================
CREATE OR REPLACE FUNCTION stage_boundary_violations()
RETURNS TABLE(object_kind text, object_name text, stage smallint)
LANGUAGE sql STABLE
AS $body$
    WITH forbidden(name, stage) AS (
        VALUES
            ('malu$governed_object'::text,       2::smallint),
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
