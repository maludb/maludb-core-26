-- MaluDB system catalog (Tier A) — CREATE TABLE statements.
--
-- Reference DDL for the SVPOR design (Stage 3 per requirements.md §9).
-- DO NOT load this from the Stage 1 sql/extension/maludb_core--0.1.0.sql install script.
-- Stage 3 will translate this into a versioned maludb_core--X.Y--X.Z.sql
-- upgrade script.
--
-- Conventions     : see CLAUDE.md → "Naming and access conventions".
-- Full design     : docs/design/svpor-schema.md.
-- Tier B (instance tables, Tier-B governance support like malu$governed_object
-- and malu$object_grant) lives in a separate reference file when written.
--
-- This subset (Tier A only) has no extension dependencies.
-- The full SVPOR schema requires: pgvector, btree_gist, pg_trgm.

SET search_path TO maludb_core;

-- ============================================================================
--  Tenancy
-- ============================================================================

CREATE TABLE malu$tenant (
    schema_name           name        PRIMARY KEY,
    display_name          text,
    default_partition_id  int,
    retention_class       text,
    created_at            timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE malu$tenant IS
    'Registered MaluDB tenants. One PG schema = one tenant. Owner_schema on Tier-B rows references schema_name here.';

CREATE TABLE malu$tenant_member (
    schema_name     name        NOT NULL REFERENCES malu$tenant ON DELETE CASCADE,
    role_name       name        NOT NULL,
    role_in_tenant  text        NOT NULL CHECK (role_in_tenant IN ('owner','member','reader')),
    granted_at      timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (schema_name, role_name)
);
COMMENT ON TABLE malu$tenant_member IS
    'Maps PG roles to tenant schemas. MALU_ALL_<x> views consult this to expand a callers visible row set across the tenants they belong to.';

CREATE INDEX malu$tenant_member_role_idx ON malu$tenant_member (role_name);

-- ============================================================================
--  SVPOR taxonomies — type registries
-- ============================================================================

CREATE TABLE malu$object_type (
    object_type_id  int         PRIMARY KEY,
    name            text        UNIQUE NOT NULL,
    description     text        NOT NULL,
    created_at      timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE malu$object_type IS
    'Discriminator for malu$governed_object: memory, claim, fact, episode_object, workflow_trace, source_package, relationship_edge, etc.';

CREATE TABLE malu$subject_type (
    subject_type_id int         PRIMARY KEY,
    name            text        UNIQUE NOT NULL,
    parent_id       int         REFERENCES malu$subject_type,
    description     text        NOT NULL,
    created_at      timestamptz NOT NULL DEFAULT now(),
    CHECK (parent_id IS NULL OR parent_id <> subject_type_id)
);
COMMENT ON TABLE malu$subject_type IS
    'Subject taxonomy (white paper §5.1): person, project, system, server, document, ai_agent, etc. parent_id supports hierarchy.';

CREATE INDEX malu$subject_type_parent_idx ON malu$subject_type (parent_id);

CREATE TABLE malu$verb_type (
    verb_type_id    int         PRIMARY KEY,
    name            text        UNIQUE NOT NULL,
    semantic_class  text        NOT NULL
        CHECK (semantic_class IN ('event','state','observation','derivation')),
    parent_id       int         REFERENCES malu$verb_type,
    description     text        NOT NULL,
    created_at      timestamptz NOT NULL DEFAULT now(),
    CHECK (parent_id IS NULL OR parent_id <> verb_type_id)
);
COMMENT ON TABLE malu$verb_type IS
    'Verb / action-class taxonomy (white paper §5.2): installed, decided, discovered, migrated, etc. Used as a routing index for memory retrieval.';

CREATE INDEX malu$verb_type_parent_idx          ON malu$verb_type (parent_id);
CREATE INDEX malu$verb_type_semantic_class_idx  ON malu$verb_type (semantic_class);

CREATE TABLE malu$predicate_type (
    predicate_type_id int         PRIMARY KEY,
    name              text        UNIQUE NOT NULL,
    value_kind        text        NOT NULL
        CHECK (value_kind IN ('text','identifier_ref','timestamp','tstzrange','numeric','enum','json')),
    description       text        NOT NULL,
    created_at        timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE malu$predicate_type IS
    'Predicate-frame field catalogue (white paper §5.3): purpose, rationale, outcome, actor, role, reason, environment, event_date, etc. value_kind selects which value_* column malu$memory_predicate_value populates.';

CREATE TABLE malu$relationship_type (
    relationship_type_id int         PRIMARY KEY,
    name                 text        UNIQUE NOT NULL,
    category             text        NOT NULL CHECK (category IN
        ('association','causal','temporal','containment','provenance','governance','procedural')),
    is_directed          bool        NOT NULL DEFAULT true,
    inverse_id           int         REFERENCES malu$relationship_type,
    requires_evidence    bool        NOT NULL DEFAULT false,
    description          text        NOT NULL,
    created_at           timestamptz NOT NULL DEFAULT now(),
    CHECK (inverse_id IS NULL OR inverse_id <> relationship_type_id)
);
COMMENT ON TABLE malu$relationship_type IS
    'Edge type taxonomy (white paper §5.5): supports, contradicts, supersedes, derived_from, verified_by, caused_by, depends_on, part_of, related_to, before, after, inside, with, from, has_detail, contains, because_of, about. requires_evidence is true for causal edges.';

CREATE INDEX malu$relationship_type_inverse_idx   ON malu$relationship_type (inverse_id);
CREATE INDEX malu$relationship_type_category_idx  ON malu$relationship_type (category);

-- ============================================================================
--  Model registry — embedding / extraction / etc. models referenced by
--  governed objects through model_id columns
-- ============================================================================

CREATE TABLE malu$model_registry (
    model_id        int         PRIMARY KEY,
    name            text        NOT NULL,
    version         text        NOT NULL,
    role            text        NOT NULL
        CHECK (role IN ('embedding','extraction','summarization','classification','verification')),
    embedding_dim   int,
    parameters      jsonb       NOT NULL DEFAULT '{}',
    registered_at   timestamptz NOT NULL DEFAULT now(),
    UNIQUE (name, version, role),
    CHECK (role <> 'embedding' OR embedding_dim IS NOT NULL)
);
COMMENT ON TABLE malu$model_registry IS
    'Registry of embedding / extraction / verification models. Per requirements §3.5, every derived object names the model that produced it via the derivation ledger; model_id rows here are those identities.';

CREATE INDEX malu$model_registry_role_idx ON malu$model_registry (role);

-- ============================================================================
--  Default lockdown
--  System tables are reachable only through MALU_ALL_<x> (read) and
--  MALU_DBA_<x> (DML) views, never directly. Views and grants are defined
--  in a separate file once the view-generator pattern is finalized.
-- ============================================================================

REVOKE ALL ON
    malu$tenant,
    malu$tenant_member,
    malu$object_type,
    malu$subject_type,
    malu$verb_type,
    malu$predicate_type,
    malu$relationship_type,
    malu$model_registry
FROM PUBLIC;
