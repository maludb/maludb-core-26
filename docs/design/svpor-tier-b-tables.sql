-- MaluDB Tier B — governed-object instance tables.
--
-- Reference DDL for the SVPOR design (Stage 3 per requirements.md §9).
-- DO NOT load this from the Stage 1 sql/extension/maludb_core--0.1.0.sql install script.
--
-- Conventions     : see CLAUDE.md → "Naming and access conventions".
-- Full design     : docs/design/svpor-schema.md.
-- Run after       : docs/design/svpor-system-tables.sql,
--                   docs/design/svpor-seeds.sql.
--
-- Required PG extensions: pgvector, btree_gist, pg_trgm. Created idempotently below.

CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS btree_gist;
CREATE EXTENSION IF NOT EXISTS pg_trgm;

SET search_path TO maludb_core;

-- ============================================================================
--  malu$governed_object — polymorphic anchor
--  Every Tier-B row across every instance table has a row here. Carries the
--  authoritative owner_schema; the instance tables denormalize it for
--  simply-updatable views.
-- ============================================================================

CREATE TABLE malu$governed_object (
    object_id      uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    object_type_id int         NOT NULL REFERENCES malu$object_type,
    owner_schema   text        NOT NULL DEFAULT current_schema(),
    created_at     timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE malu$governed_object IS
    'Polymorphic anchor for every Tier-B row. Tenant ownership is recorded here; instance tables denormalize owner_schema for view simplicity.';

CREATE INDEX malu$governed_object_owner_idx ON malu$governed_object (owner_schema, object_type_id);
CREATE INDEX malu$governed_object_type_idx  ON malu$governed_object (object_type_id);

-- ============================================================================
--  malu$subject — subject instances (white paper §5.1)
-- ============================================================================

CREATE TABLE malu$subject (
    subject_id        uuid        PRIMARY KEY REFERENCES malu$governed_object(object_id),
    subject_type_id   int         NOT NULL REFERENCES malu$subject_type,
    owner_schema      text        NOT NULL DEFAULT current_schema(),
    canonical_name    text        NOT NULL,
    aliases           text[]      NOT NULL DEFAULT '{}',
    external_id       text,
    valid_time        tstzrange   NOT NULL DEFAULT tstzrange(now(), null, '[)'),
    transaction_time  tstzrange   NOT NULL DEFAULT tstzrange(now(), null, '[)'),
    lifecycle_state   text        NOT NULL DEFAULT 'current'
        CHECK (lifecycle_state IN
            ('current','historical','stale','superseded','contradicted','consolidated','decayed','archived','retired')),
    security_label    text        NOT NULL DEFAULT 'unrestricted',
    partition_id      int,
    derivation_id     uuid,
    created_at        timestamptz NOT NULL DEFAULT now(),
    EXCLUDE USING gist (
        owner_schema    WITH =,
        subject_type_id WITH =,
        canonical_name  WITH =,
        valid_time      WITH &&)
);
COMMENT ON TABLE malu$subject IS
    'Subject instance. The EXCLUDE constraint enforces no two simultaneous live versions of the same (owner, type, canonical_name) — corrections must close valid_time and open a new row.';

CREATE INDEX malu$subject_owner_idx      ON malu$subject (owner_schema, subject_type_id);
CREATE INDEX malu$subject_aliases_gin    ON malu$subject USING gin (aliases);
CREATE INDEX malu$subject_name_trgm      ON malu$subject USING gin (canonical_name gin_trgm_ops);
CREATE INDEX malu$subject_valid_time     ON malu$subject USING gist (valid_time);
CREATE INDEX malu$subject_xact_time      ON malu$subject USING gist (transaction_time);
CREATE INDEX malu$subject_current_idx    ON malu$subject (owner_schema, subject_type_id, canonical_name)
    WHERE lifecycle_state = 'current';

-- ============================================================================
--  malu$memory — central SVPOR object (white paper §1.3, §5)
--  Subject and verb inline; predicate frame normalized in malu$memory_predicate_value.
-- ============================================================================

CREATE TABLE malu$memory (
    memory_id          uuid        PRIMARY KEY REFERENCES malu$governed_object(object_id),
    owner_schema       text        NOT NULL DEFAULT current_schema(),
    primary_subject_id uuid        NOT NULL REFERENCES malu$subject(subject_id),
    verb_type_id       int         NOT NULL REFERENCES malu$verb_type,
    summary            text        NOT NULL,
    payload            jsonb       NOT NULL DEFAULT '{}',
    -- pgvector column is undimensioned; per-model HNSW indexes attach with explicit
    -- casts once malu$model_registry rows define each model's dim.
    embedding          vector,
    embedded_text      text,
    embedding_model_id int         REFERENCES malu$model_registry,
    -- bitemporal (requirements.md §3.4)
    event_time         timestamptz,
    valid_time         tstzrange   NOT NULL DEFAULT tstzrange(now(), null, '[)'),
    transaction_time   tstzrange   NOT NULL DEFAULT tstzrange(now(), null, '[)'),
    source_time        timestamptz,
    verification_time  timestamptz,
    stale_after        timestamptz,
    -- MAUT (requirements.md §3.3); per-category subscores live in malu$maut_score (Stage-3, separate file)
    confidence_score   numeric(5,4) CHECK (confidence_score BETWEEN 0 AND 1),
    precision_score    numeric(5,4) CHECK (precision_score  BETWEEN 0 AND 1),
    -- governance
    lifecycle_state    text        NOT NULL DEFAULT 'current'
        CHECK (lifecycle_state IN
            ('current','historical','stale','superseded','contradicted','consolidated','decayed','archived','retired')),
    security_label     text        NOT NULL DEFAULT 'unrestricted',
    partition_id       int,
    derivation_id      uuid,
    created_at         timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE malu$memory IS
    'Central SVPOR-organized memory object. Subject and verb are inline routing keys; the predicate frame is normalized in malu$memory_predicate_value.';

CREATE INDEX malu$memory_owner_idx       ON malu$memory (owner_schema);
CREATE INDEX malu$memory_subj_verb       ON malu$memory (primary_subject_id, verb_type_id);
CREATE INDEX malu$memory_verb            ON malu$memory (verb_type_id);
CREATE INDEX malu$memory_event_time_brin ON malu$memory USING brin (event_time);
CREATE INDEX malu$memory_valid_time      ON malu$memory USING gist (valid_time);
CREATE INDEX malu$memory_xact_time       ON malu$memory USING gist (transaction_time);
CREATE INDEX malu$memory_payload         ON malu$memory USING gin (payload jsonb_path_ops);
CREATE INDEX malu$memory_summary_fts     ON malu$memory USING gin (to_tsvector('english', summary));
CREATE INDEX malu$memory_current_idx     ON malu$memory (owner_schema, primary_subject_id, verb_type_id)
    WHERE lifecycle_state = 'current';

-- ============================================================================
--  malu$memory_predicate_value — normalized predicate frame
--  One row per (memory, predicate_type, ordinality). value_kind on
--  malu$predicate_type selects which value_* column is populated.
-- ============================================================================

CREATE TABLE malu$memory_predicate_value (
    memory_id           uuid        NOT NULL REFERENCES malu$memory ON DELETE CASCADE,
    predicate_type_id   int         NOT NULL REFERENCES malu$predicate_type,
    ordinality          int         NOT NULL DEFAULT 1,
    owner_schema        text        NOT NULL DEFAULT current_schema(),
    value_text          text,
    value_object_id     uuid        REFERENCES malu$governed_object(object_id),
    value_timestamp     timestamptz,
    value_range         tstzrange,
    value_numeric       numeric,
    value_json          jsonb,
    PRIMARY KEY (memory_id, predicate_type_id, ordinality),
    -- exactly one value_* column populated per row
    CHECK (
        (value_text       IS NOT NULL)::int +
        (value_object_id  IS NOT NULL)::int +
        (value_timestamp  IS NOT NULL)::int +
        (value_range      IS NOT NULL)::int +
        (value_numeric    IS NOT NULL)::int +
        (value_json       IS NOT NULL)::int
        = 1
    )
);
COMMENT ON TABLE malu$memory_predicate_value IS
    'Normalized predicate frame. Each row carries a single typed value selected by malu$predicate_type.value_kind. The check constraint enforces exactly-one populated value column.';

CREATE INDEX malu$mpv_text_idx    ON malu$memory_predicate_value (predicate_type_id, value_text)
    WHERE value_text IS NOT NULL;
CREATE INDEX malu$mpv_object_idx  ON malu$memory_predicate_value (predicate_type_id, value_object_id)
    WHERE value_object_id IS NOT NULL;
CREATE INDEX malu$mpv_owner_idx   ON malu$memory_predicate_value (owner_schema);

-- ============================================================================
--  malu$memory_detail_object — recursive Memory Detail Objects (white paper §5.4.1)
-- ============================================================================

CREATE TABLE malu$memory_detail_object (
    detail_id           uuid        PRIMARY KEY REFERENCES malu$governed_object(object_id),
    owner_schema        text        NOT NULL DEFAULT current_schema(),
    parent_memory_id    uuid        REFERENCES malu$memory(memory_id),
    parent_detail_id    uuid        REFERENCES malu$memory_detail_object(detail_id),
    ordinality          int         NOT NULL,
    summary             text        NOT NULL,
    payload             jsonb       NOT NULL DEFAULT '{}',
    embedding           vector,
    embedding_model_id  int         REFERENCES malu$model_registry,
    valid_time          tstzrange   NOT NULL DEFAULT tstzrange(now(), null, '[)'),
    transaction_time    tstzrange   NOT NULL DEFAULT tstzrange(now(), null, '[)'),
    lifecycle_state     text        NOT NULL DEFAULT 'current'
        CHECK (lifecycle_state IN
            ('current','historical','stale','superseded','contradicted','consolidated','decayed','archived','retired')),
    security_label      text        NOT NULL DEFAULT 'unrestricted',
    derivation_id       uuid,
    created_at          timestamptz NOT NULL DEFAULT now(),
    CHECK ((parent_memory_id IS NULL) <> (parent_detail_id IS NULL))
);
COMMENT ON TABLE malu$memory_detail_object IS
    'Addressable substep of a memory. Reuse across memories happens via malu$relationship_edge (has_detail / contains), not row duplication.';

CREATE INDEX malu$mdo_owner_idx          ON malu$memory_detail_object (owner_schema);
CREATE INDEX malu$mdo_parent_memory_idx  ON malu$memory_detail_object (parent_memory_id, ordinality)
    WHERE parent_memory_id IS NOT NULL;
CREATE INDEX malu$mdo_parent_detail_idx  ON malu$memory_detail_object (parent_detail_id, ordinality)
    WHERE parent_detail_id IS NOT NULL;
CREATE INDEX malu$mdo_payload_gin        ON malu$memory_detail_object USING gin (payload jsonb_path_ops);

-- ============================================================================
--  malu$relationship_edge — typed graph edges (white paper §5.5)
-- ============================================================================

CREATE TABLE malu$relationship_edge (
    edge_id              uuid        PRIMARY KEY REFERENCES malu$governed_object(object_id),
    owner_schema         text        NOT NULL DEFAULT current_schema(),
    from_object_id       uuid        NOT NULL REFERENCES malu$governed_object(object_id),
    to_object_id         uuid        NOT NULL REFERENCES malu$governed_object(object_id),
    relationship_type_id int         NOT NULL REFERENCES malu$relationship_type,
    causal_mechanism     text,
    causal_status        text        CHECK (causal_status IN ('asserted','inferred','disputed','verified')),
    confidence_score     numeric(5,4) CHECK (confidence_score BETWEEN 0 AND 1),
    valid_time           tstzrange   NOT NULL DEFAULT tstzrange(now(), null, '[)'),
    transaction_time     tstzrange   NOT NULL DEFAULT tstzrange(now(), null, '[)'),
    lifecycle_state      text        NOT NULL DEFAULT 'current'
        CHECK (lifecycle_state IN
            ('current','historical','stale','superseded','contradicted','consolidated','decayed','archived','retired')),
    derivation_id        uuid,
    created_at           timestamptz NOT NULL DEFAULT now(),
    CHECK (from_object_id <> to_object_id),
    EXCLUDE USING gist (
        from_object_id       WITH =,
        to_object_id         WITH =,
        relationship_type_id WITH =,
        valid_time           WITH &&)
);
COMMENT ON TABLE malu$relationship_edge IS
    'Typed edge between two governed objects. EXCLUDE prevents duplicate live edges of the same type — corrections must close valid_time and open a new edge.';

CREATE INDEX malu$edge_owner_idx          ON malu$relationship_edge (owner_schema);
CREATE INDEX malu$edge_from_idx           ON malu$relationship_edge (from_object_id, relationship_type_id);
CREATE INDEX malu$edge_to_idx             ON malu$relationship_edge (to_object_id,   relationship_type_id);
CREATE INDEX malu$edge_type_idx           ON malu$relationship_edge (relationship_type_id);
CREATE INDEX malu$edge_valid_time         ON malu$relationship_edge USING gist (valid_time);
CREATE INDEX malu$edge_xact_time          ON malu$relationship_edge USING gist (transaction_time);
CREATE INDEX malu$edge_current_idx        ON malu$relationship_edge (from_object_id, relationship_type_id, to_object_id)
    WHERE lifecycle_state = 'current';

-- ============================================================================
--  malu$object_grant — per-row sharing across tenants
--  Tenants grant SELECT/UPDATE/DELETE on individual objects to other roles
--  (typically via a stored-procedure surface, not direct INSERT).
-- ============================================================================

CREATE TABLE malu$object_grant (
    object_id     uuid        NOT NULL REFERENCES malu$governed_object(object_id) ON DELETE CASCADE,
    grantee_role  name        NOT NULL,
    privilege     text        NOT NULL CHECK (privilege IN ('SELECT','UPDATE','DELETE')),
    granted_by    name        NOT NULL DEFAULT current_user,
    valid_time    tstzrange   NOT NULL DEFAULT tstzrange(now(), null, '[)'),
    granted_at    timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (object_id, grantee_role, privilege, valid_time)
);
COMMENT ON TABLE malu$object_grant IS
    'Per-row sharing. Consulted by MALU_ALL_<x> views to expand visibility beyond the callers tenant memberships.';

CREATE INDEX malu$object_grant_grantee_idx   ON malu$object_grant (grantee_role, privilege);
CREATE INDEX malu$object_grant_valid_time    ON malu$object_grant USING gist (valid_time);

-- ============================================================================
--  Anchor-creation triggers
--  Each Tier-B instance INSERT auto-creates the malu$governed_object row so
--  tenants don't have to manage the polymorphic anchor by hand. The shared
--  helper malu_anchor_create() does the lookup + insert; per-table triggers
--  call it with the right object-type discriminator.
-- ============================================================================

CREATE OR REPLACE FUNCTION malu_anchor_create(
    p_object_id     uuid,
    p_type_name     text,
    p_owner_schema  text
) RETURNS uuid
LANGUAGE plpgsql AS $body$
DECLARE
    v_type_id int;
BEGIN
    SELECT object_type_id INTO v_type_id
    FROM   malu$object_type
    WHERE  name = p_type_name;
    IF v_type_id IS NULL THEN
        RAISE EXCEPTION 'malu_anchor_create: unknown object_type %', p_type_name;
    END IF;
    INSERT INTO malu$governed_object (object_id, object_type_id, owner_schema)
    VALUES (p_object_id, v_type_id, p_owner_schema)
    ON CONFLICT (object_id) DO NOTHING;
    RETURN p_object_id;
END;
$body$;

CREATE OR REPLACE FUNCTION malu_subject_before_insert()
RETURNS trigger LANGUAGE plpgsql AS $body$
BEGIN
    NEW.subject_id   := COALESCE(NEW.subject_id, gen_random_uuid());
    NEW.owner_schema := COALESCE(NEW.owner_schema, current_schema());
    PERFORM malu_anchor_create(NEW.subject_id, 'subject', NEW.owner_schema);
    RETURN NEW;
END;
$body$;
CREATE TRIGGER malu$subject_anchor_trg BEFORE INSERT ON malu$subject
FOR EACH ROW EXECUTE FUNCTION malu_subject_before_insert();

CREATE OR REPLACE FUNCTION malu_memory_before_insert()
RETURNS trigger LANGUAGE plpgsql AS $body$
BEGIN
    NEW.memory_id    := COALESCE(NEW.memory_id, gen_random_uuid());
    NEW.owner_schema := COALESCE(NEW.owner_schema, current_schema());
    PERFORM malu_anchor_create(NEW.memory_id, 'memory', NEW.owner_schema);
    RETURN NEW;
END;
$body$;
CREATE TRIGGER malu$memory_anchor_trg BEFORE INSERT ON malu$memory
FOR EACH ROW EXECUTE FUNCTION malu_memory_before_insert();

CREATE OR REPLACE FUNCTION malu_mdo_before_insert()
RETURNS trigger LANGUAGE plpgsql AS $body$
BEGIN
    NEW.detail_id    := COALESCE(NEW.detail_id, gen_random_uuid());
    NEW.owner_schema := COALESCE(NEW.owner_schema, current_schema());
    PERFORM malu_anchor_create(NEW.detail_id, 'memory_detail_object', NEW.owner_schema);
    RETURN NEW;
END;
$body$;
CREATE TRIGGER malu$mdo_anchor_trg BEFORE INSERT ON malu$memory_detail_object
FOR EACH ROW EXECUTE FUNCTION malu_mdo_before_insert();

CREATE OR REPLACE FUNCTION malu_edge_before_insert()
RETURNS trigger LANGUAGE plpgsql AS $body$
BEGIN
    NEW.edge_id      := COALESCE(NEW.edge_id, gen_random_uuid());
    NEW.owner_schema := COALESCE(NEW.owner_schema, current_schema());
    PERFORM malu_anchor_create(NEW.edge_id, 'relationship_edge', NEW.owner_schema);
    RETURN NEW;
END;
$body$;
CREATE TRIGGER malu$edge_anchor_trg BEFORE INSERT ON malu$relationship_edge
FOR EACH ROW EXECUTE FUNCTION malu_edge_before_insert();

-- predicate values inherit owner_schema from their parent memory (no anchor row of their own)
CREATE OR REPLACE FUNCTION malu_mpv_before_insert()
RETURNS trigger LANGUAGE plpgsql AS $body$
BEGIN
    IF NEW.owner_schema IS NULL THEN
        SELECT m.owner_schema INTO NEW.owner_schema
        FROM   malu$memory m WHERE m.memory_id = NEW.memory_id;
    END IF;
    RETURN NEW;
END;
$body$;
CREATE TRIGGER malu$mpv_owner_trg BEFORE INSERT ON malu$memory_predicate_value
FOR EACH ROW EXECUTE FUNCTION malu_mpv_before_insert();

-- ============================================================================
--  Lockdown — base tables are not reachable by PUBLIC. Tenants reach data
--  only via MALU_USER_<x> / MALU_ALL_<x> / MALU_DBA_<x> views (separate file).
-- ============================================================================

REVOKE ALL ON
    malu$governed_object,
    malu$subject,
    malu$memory,
    malu$memory_predicate_value,
    malu$memory_detail_object,
    malu$relationship_edge,
    malu$object_grant
FROM PUBLIC;
