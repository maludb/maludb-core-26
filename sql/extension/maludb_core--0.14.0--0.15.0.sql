\echo Use "ALTER EXTENSION maludb_core UPDATE TO '0.15.0'" to load this file. \quit

-- =====================================================================
-- maludb_core 0.14.0 → 0.15.0
--
-- Stage 2 — Memory object model + Derivation Ledger (S2-1 + S2-3).
--
-- Installs the seven core memory object tables:
--   malu$source_package       — verbatim source ingestion artifact
--   malu$claim                — extracted assertion with source ref
--   malu$fact                 — claim(s) accepted within a scope
--   malu$fact_claim           — fact ↔ claim junction
--   malu$memory               — contextual record of event/decision/...
--   malu$episode_object       — specific remembered episode
--   malu$memory_detail_object — recursively addressable detail
--   malu$relationship_edge    — typed polymorphic edges between objects
--   malu$derivation_ledger    — auditable lineage of every derived object
--
-- Per CLAUDE.md tenancy model:
--   * Tier-B governed objects carry `owner_schema name NOT NULL DEFAULT
--     current_schema()`. One PG schema = one MaluDB tenant.
--   * RLS scopes by owner_schema (cross-tenant grants via S2-5
--     malu$object_grant — deferred).
--   * Base tables get no PUBLIC grants. Three new functional roles
--     (maludb_memory_admin / _executor / _auditor) gate access.
--
-- Doctrine (per CLAUDE.md):
--   * Multi-model writes that span object + edge + ledger must be in a
--     single transaction. S2-7 will add C-level atomic helpers; for
--     now PL/pgSQL `register_*` functions wrap each.
--   * Every derived object must have a malu$derivation_ledger row.
--     The helper `record_derivation()` is the canonical writer.
-- =====================================================================

CREATE OR REPLACE FUNCTION maludb_core_version() RETURNS text
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$ SELECT '0.15.0'::text $body$;

-- ---------------------------------------------------------------------
-- Stage 2 functional roles. Three roles for now — the prompt-style
-- author/approver split from R1.1 doesn't map cleanly to memory writes,
-- so we keep it flat: admin / executor / auditor.
-- ---------------------------------------------------------------------
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'maludb_memory_admin') THEN
        CREATE ROLE maludb_memory_admin   NOLOGIN NOINHERIT BYPASSRLS;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'maludb_memory_executor') THEN
        CREATE ROLE maludb_memory_executor NOLOGIN NOINHERIT;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'maludb_memory_auditor') THEN
        CREATE ROLE maludb_memory_auditor  NOLOGIN NOINHERIT BYPASSRLS;
    END IF;
END $$;

-- =====================================================================
-- malu$source_package
--
-- Verbatim source ingestion artifact. Stage 2 S2-2 will add the
-- immutable archive layer (sealing, tiered placement, retention class
-- enforcement); this S2-1 row holds enough to reference and search.
-- =====================================================================
CREATE TABLE malu$source_package (
    source_package_id   bigserial PRIMARY KEY,
    owner_schema        name NOT NULL DEFAULT current_schema(),
    source_type         text NOT NULL
        REFERENCES malu$source_type(source_type),
    -- Content (one of these must be non-NULL)
    content_bytes       bytea,
    content_text        text,
    content_jsonb       jsonb,
    content_hash        text NOT NULL,   -- sha256 hex over the canonical form
    content_size        bigint NOT NULL CHECK (content_size >= 0),
    media_type          text,
    -- Origin
    origin_jsonb        jsonb,           -- {producer, connector, ingested_by, ...}
    captured_at         timestamptz,
    ingested_at         timestamptz NOT NULL DEFAULT now(),
    -- Retention + legal hold
    retention_class     text NOT NULL DEFAULT 'standard'
        CHECK (retention_class IN ('standard','sensitive','restricted','prohibited')),
    legal_hold          boolean NOT NULL DEFAULT false,
    legal_hold_reason   text,
    retain_until        timestamptz,
    -- Sensitivity (independent of retention)
    sensitivity         text NOT NULL DEFAULT 'internal'
        CHECK (sensitivity IN ('public','internal','restricted','prohibited')),
    -- Lifecycle (S2-2 wires the seal/archive transitions properly)
    sealed_at           timestamptz,
    archived_at         timestamptz,
    tombstoned_at       timestamptz,
    -- Audit
    created_at          timestamptz NOT NULL DEFAULT now(),
    updated_at          timestamptz NOT NULL DEFAULT now(),
    CHECK (content_bytes IS NOT NULL OR content_text IS NOT NULL OR content_jsonb IS NOT NULL)
);
CREATE INDEX malu$source_package_owner_idx ON malu$source_package(owner_schema);
CREATE INDEX malu$source_package_hash_idx  ON malu$source_package(content_hash);
CREATE INDEX malu$source_package_type_idx  ON malu$source_package(source_type);

-- =====================================================================
-- malu$claim
--
-- An extracted assertion. May or may not reference a source package
-- (hypothetical claims have no source). SVPOR shape carried as plain
-- text columns; Stage 3 will normalize via malu$svpor_*.
-- =====================================================================
CREATE TABLE malu$claim (
    claim_id            bigserial PRIMARY KEY,
    owner_schema        name NOT NULL DEFAULT current_schema(),
    -- SVPOR text shape (Stage 3 will normalize)
    subject             text,
    verb                text,
    predicate           text,
    object_value        text,
    relationship        text,
    -- Free-form statement
    statement_text      text,
    statement_jsonb     jsonb,
    -- Source reference (optional)
    source_package_id   bigint REFERENCES malu$source_package(source_package_id) ON DELETE SET NULL,
    source_locator      jsonb,           -- {page, byte_offset, line_no, message_id, ...}
    -- Lifecycle
    asserted_at         timestamptz NOT NULL DEFAULT now(),
    retracted_at        timestamptz,
    retraction_reason   text,
    sensitivity         text NOT NULL DEFAULT 'internal'
        CHECK (sensitivity IN ('public','internal','restricted','prohibited')),
    created_at          timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX malu$claim_owner_idx       ON malu$claim(owner_schema);
CREATE INDEX malu$claim_source_idx      ON malu$claim(source_package_id) WHERE source_package_id IS NOT NULL;
CREATE INDEX malu$claim_subj_verb_idx   ON malu$claim(subject, verb) WHERE subject IS NOT NULL;

-- =====================================================================
-- malu$fact
--
-- A claim or set of claims accepted as true within a defined scope.
-- supersedes_fact_id captures simple correction chains; Stage 3 will
-- replace with full bitemporal supersession.
-- =====================================================================
CREATE TABLE malu$fact (
    fact_id             bigserial PRIMARY KEY,
    owner_schema        name NOT NULL DEFAULT current_schema(),
    subject             text,
    verb                text,
    predicate           text,
    object_value        text,
    relationship        text,
    statement_text      text,
    statement_jsonb     jsonb,
    -- Verification (Stage 3 MAUT will replace)
    verification_scope  text,
    verification_method text,
    verified_at         timestamptz NOT NULL DEFAULT now(),
    -- Supersession (Stage 3 will replace)
    supersedes_fact_id  bigint REFERENCES malu$fact(fact_id) ON DELETE SET NULL,
    superseded_at       timestamptz,
    -- Sensitivity / lifecycle
    sensitivity         text NOT NULL DEFAULT 'internal'
        CHECK (sensitivity IN ('public','internal','restricted','prohibited')),
    lifecycle_state     text NOT NULL DEFAULT 'active'
        CHECK (lifecycle_state IN ('active','superseded','retired','legal_hold','tombstoned')),
    created_at          timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX malu$fact_owner_idx      ON malu$fact(owner_schema);
CREATE INDEX malu$fact_subj_verb_idx  ON malu$fact(subject, verb) WHERE subject IS NOT NULL;
CREATE INDEX malu$fact_supersedes_idx ON malu$fact(supersedes_fact_id) WHERE supersedes_fact_id IS NOT NULL;

-- =====================================================================
-- malu$fact_claim — junction. A fact aggregates one or more claims.
-- =====================================================================
CREATE TABLE malu$fact_claim (
    fact_id     bigint  NOT NULL REFERENCES malu$fact(fact_id)   ON DELETE CASCADE,
    claim_id    bigint  NOT NULL REFERENCES malu$claim(claim_id) ON DELETE RESTRICT,
    role        text    NOT NULL DEFAULT 'supports'
        CHECK (role IN ('supports','contradicts','contextualizes')),
    added_at    timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (fact_id, claim_id)
);
CREATE INDEX malu$fact_claim_claim_idx ON malu$fact_claim(claim_id);

-- =====================================================================
-- malu$memory
--
-- Contextual record. memory_kind is operator-defined (event, decision,
-- discovery, lesson, dependency, change, observation, ...).
-- =====================================================================
CREATE TABLE malu$memory (
    memory_id           bigserial PRIMARY KEY,
    owner_schema        name NOT NULL DEFAULT current_schema(),
    memory_kind         text NOT NULL,
    title               text,
    summary             text,
    payload_jsonb       jsonb NOT NULL DEFAULT '{}'::jsonb,
    -- Temporal anchors (Stage 3 fills in full bitemporal)
    occurred_at         timestamptz,
    occurred_until      timestamptz,
    recorded_at         timestamptz NOT NULL DEFAULT now(),
    -- Sensitivity / lifecycle
    sensitivity         text NOT NULL DEFAULT 'internal'
        CHECK (sensitivity IN ('public','internal','restricted','prohibited')),
    lifecycle_state     text NOT NULL DEFAULT 'active'
        CHECK (lifecycle_state IN ('active','consolidated','superseded','archived','retired','legal_hold','tombstoned')),
    consolidated_into_memory_id bigint
        REFERENCES malu$memory(memory_id) ON DELETE SET NULL,
    created_at          timestamptz NOT NULL DEFAULT now(),
    updated_at          timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX malu$memory_owner_idx       ON malu$memory(owner_schema);
CREATE INDEX malu$memory_kind_idx        ON malu$memory(memory_kind);
CREATE INDEX malu$memory_occurred_idx    ON malu$memory(occurred_at)    WHERE occurred_at IS NOT NULL;
CREATE INDEX malu$memory_lifecycle_idx   ON malu$memory(lifecycle_state) WHERE lifecycle_state <> 'active';

-- =====================================================================
-- malu$episode_object
--
-- DBMS representation of a specific remembered episode. An episode
-- typically aggregates memories + facts + Memory Detail Objects under
-- one lifecycle. Stage 5 will add Workflow Trace extraction over
-- these.
-- =====================================================================
CREATE TABLE malu$episode_object (
    episode_id          bigserial PRIMARY KEY,
    owner_schema        name NOT NULL DEFAULT current_schema(),
    episode_kind        text NOT NULL,
    title               text NOT NULL,
    summary             text,
    payload_jsonb       jsonb NOT NULL DEFAULT '{}'::jsonb,
    occurred_at         timestamptz,
    occurred_until      timestamptz,
    recorded_at         timestamptz NOT NULL DEFAULT now(),
    sensitivity         text NOT NULL DEFAULT 'internal'
        CHECK (sensitivity IN ('public','internal','restricted','prohibited')),
    lifecycle_state     text NOT NULL DEFAULT 'active'
        CHECK (lifecycle_state IN ('active','consolidated','superseded','archived','retired','legal_hold','tombstoned')),
    created_at          timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX malu$episode_owner_idx     ON malu$episode_object(owner_schema);
CREATE INDEX malu$episode_kind_idx      ON malu$episode_object(episode_kind);
CREATE INDEX malu$episode_occurred_idx  ON malu$episode_object(occurred_at) WHERE occurred_at IS NOT NULL;

-- =====================================================================
-- malu$memory_detail_object — recursively containable child of a
-- memory or episode. parent_mdo_id self-references for nesting.
-- =====================================================================
CREATE TABLE malu$memory_detail_object (
    mdo_id              bigserial PRIMARY KEY,
    owner_schema        name NOT NULL DEFAULT current_schema(),
    -- Parent: nested under another MDO, OR top-level under memory/episode.
    parent_mdo_id       bigint REFERENCES malu$memory_detail_object(mdo_id) ON DELETE CASCADE,
    memory_id           bigint REFERENCES malu$memory(memory_id)              ON DELETE CASCADE,
    episode_id          bigint REFERENCES malu$episode_object(episode_id)     ON DELETE CASCADE,
    detail_kind         text NOT NULL,
    -- examples: step, substep, parameter, command, validation, exception,
    --           source_excerpt, evidence, observation
    ordinal             integer,
    title               text,
    body_text           text,
    body_jsonb          jsonb,
    sensitivity         text NOT NULL DEFAULT 'internal'
        CHECK (sensitivity IN ('public','internal','restricted','prohibited')),
    created_at          timestamptz NOT NULL DEFAULT now(),
    CHECK (parent_mdo_id IS NOT NULL OR memory_id IS NOT NULL OR episode_id IS NOT NULL)
);
CREATE INDEX malu$mdo_owner_idx   ON malu$memory_detail_object(owner_schema);
CREATE INDEX malu$mdo_parent_idx  ON malu$memory_detail_object(parent_mdo_id) WHERE parent_mdo_id IS NOT NULL;
CREATE INDEX malu$mdo_memory_idx  ON malu$memory_detail_object(memory_id)     WHERE memory_id     IS NOT NULL;
CREATE INDEX malu$mdo_episode_idx ON malu$memory_detail_object(episode_id)    WHERE episode_id    IS NOT NULL;

-- =====================================================================
-- malu$relationship_edge — typed polymorphic edges between governed
-- objects. Cross-tenant edges land in the schema that recorded them;
-- visibility across tenants is mediated by future malu$object_grant
-- (S2-5).
-- =====================================================================
CREATE TABLE malu$relationship_edge (
    edge_id                 bigserial PRIMARY KEY,
    owner_schema            name NOT NULL DEFAULT current_schema(),
    relationship_type       text NOT NULL
        REFERENCES malu$relationship_type(relationship_type),
    source_object_type      text NOT NULL,
    source_object_id        bigint NOT NULL,
    target_object_type      text NOT NULL,
    target_object_id        bigint NOT NULL,
    label                   text,
    edge_jsonb              jsonb,
    confidence              numeric(5,4) CHECK (confidence IS NULL OR (confidence >= 0 AND confidence <= 1)),
    created_at              timestamptz NOT NULL DEFAULT now(),
    CHECK (source_object_type IN
        ('source_package','claim','fact','memory','episode_object','memory_detail_object')),
    CHECK (target_object_type IN
        ('source_package','claim','fact','memory','episode_object','memory_detail_object'))
);
CREATE INDEX malu$edge_owner_idx ON malu$relationship_edge(owner_schema);
CREATE INDEX malu$edge_src_idx   ON malu$relationship_edge(source_object_type, source_object_id);
CREATE INDEX malu$edge_tgt_idx   ON malu$relationship_edge(target_object_type, target_object_id);
CREATE INDEX malu$edge_rel_idx   ON malu$relationship_edge(relationship_type);

-- =====================================================================
-- malu$derivation_ledger (S2-3)
--
-- Auditable lineage. Every derived object MUST have a row here. Stage
-- 3 will extend with MAUT subscore tables; for now we record the
-- pipeline + the input set hash.
-- =====================================================================
CREATE TABLE malu$derivation_ledger (
    derivation_id           bigserial PRIMARY KEY,
    owner_schema            name NOT NULL DEFAULT current_schema(),
    derived_object_type     text NOT NULL,
    derived_object_id       bigint NOT NULL,
    -- The pipeline that produced the derived object
    parser_name             text,
    model_alias_id          bigint REFERENCES malu$model_alias(alias_id)         ON DELETE SET NULL,
    prompt_template_id      bigint REFERENCES malu$prompt_template(template_id)  ON DELETE SET NULL,
    policy_name             text,
    verifier_name           text,
    -- When the derivation went through the R1.0 model gateway, link it.
    model_request_id        bigint REFERENCES malu$model_request(request_id)     ON DELETE SET NULL,
    -- Inputs: jsonb manifest plus a sha256 over the canonical form
    inputs_jsonb            jsonb NOT NULL DEFAULT '[]'::jsonb,
    inputs_hash             text  NOT NULL,
    derived_at              timestamptz NOT NULL DEFAULT now(),
    CHECK (derived_object_type IN
        ('source_package','claim','fact','memory','episode_object','memory_detail_object',
         'relationship_edge'))
);
CREATE INDEX malu$ledger_owner_idx     ON malu$derivation_ledger(owner_schema);
CREATE INDEX malu$ledger_derived_idx   ON malu$derivation_ledger(derived_object_type, derived_object_id);
CREATE INDEX malu$ledger_request_idx   ON malu$derivation_ledger(model_request_id) WHERE model_request_id IS NOT NULL;

-- =====================================================================
-- Row-level security. Tenancy by owner_schema = current_schema().
-- Auditor + admin BYPASSRLS; executor sees their tenant only.
-- =====================================================================
ALTER TABLE malu$source_package        ENABLE ROW LEVEL SECURITY;
ALTER TABLE malu$claim                 ENABLE ROW LEVEL SECURITY;
ALTER TABLE malu$fact                  ENABLE ROW LEVEL SECURITY;
ALTER TABLE malu$fact_claim            ENABLE ROW LEVEL SECURITY;
ALTER TABLE malu$memory                ENABLE ROW LEVEL SECURITY;
ALTER TABLE malu$episode_object        ENABLE ROW LEVEL SECURITY;
ALTER TABLE malu$memory_detail_object  ENABLE ROW LEVEL SECURITY;
ALTER TABLE malu$relationship_edge     ENABLE ROW LEVEL SECURITY;
ALTER TABLE malu$derivation_ledger     ENABLE ROW LEVEL SECURITY;

CREATE POLICY tenant_owner ON malu$source_package
    USING (owner_schema = current_schema())
    WITH CHECK (owner_schema = current_schema());
CREATE POLICY tenant_owner ON malu$claim
    USING (owner_schema = current_schema())
    WITH CHECK (owner_schema = current_schema());
CREATE POLICY tenant_owner ON malu$fact
    USING (owner_schema = current_schema())
    WITH CHECK (owner_schema = current_schema());
CREATE POLICY tenant_via_fact ON malu$fact_claim
    USING (
        EXISTS (SELECT 1 FROM malu$fact f
                WHERE f.fact_id = malu$fact_claim.fact_id
                  AND f.owner_schema = current_schema())
    )
    WITH CHECK (
        EXISTS (SELECT 1 FROM malu$fact f
                WHERE f.fact_id = malu$fact_claim.fact_id
                  AND f.owner_schema = current_schema())
    );
CREATE POLICY tenant_owner ON malu$memory
    USING (owner_schema = current_schema())
    WITH CHECK (owner_schema = current_schema());
CREATE POLICY tenant_owner ON malu$episode_object
    USING (owner_schema = current_schema())
    WITH CHECK (owner_schema = current_schema());
CREATE POLICY tenant_owner ON malu$memory_detail_object
    USING (owner_schema = current_schema())
    WITH CHECK (owner_schema = current_schema());
CREATE POLICY tenant_owner ON malu$relationship_edge
    USING (owner_schema = current_schema())
    WITH CHECK (owner_schema = current_schema());
CREATE POLICY tenant_owner ON malu$derivation_ledger
    USING (owner_schema = current_schema())
    WITH CHECK (owner_schema = current_schema());

-- ---------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------
-- All memory roles read the catalog reference tables too.
GRANT SELECT ON malu$object_type, malu$relationship_type, malu$source_type
TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;

-- admin: full CRUD on every Stage 2 governed table
GRANT ALL ON
    malu$source_package, malu$claim, malu$fact, malu$fact_claim,
    malu$memory, malu$episode_object, malu$memory_detail_object,
    malu$relationship_edge, malu$derivation_ledger
TO maludb_memory_admin;

-- executor: CRUD within tenant (RLS handles scoping)
GRANT SELECT, INSERT, UPDATE, DELETE ON
    malu$source_package, malu$claim, malu$fact, malu$fact_claim,
    malu$memory, malu$episode_object, malu$memory_detail_object,
    malu$relationship_edge, malu$derivation_ledger
TO maludb_memory_executor;

-- auditor: SELECT only (BYPASSRLS = sees all tenants)
GRANT SELECT ON
    malu$source_package, malu$claim, malu$fact, malu$fact_claim,
    malu$memory, malu$episode_object, malu$memory_detail_object,
    malu$relationship_edge, malu$derivation_ledger
TO maludb_memory_auditor;

GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA maludb_core
    TO maludb_memory_admin, maludb_memory_executor;

-- =====================================================================
-- Registration helpers. Each register_* is a thin write API with input
-- validation; multi-model atomic helpers come in S2-7.
-- =====================================================================

CREATE FUNCTION register_source_package(
    p_source_type     text,
    p_content_bytes   bytea   DEFAULT NULL,
    p_content_text    text    DEFAULT NULL,
    p_content_jsonb   jsonb   DEFAULT NULL,
    p_media_type      text    DEFAULT NULL,
    p_origin_jsonb    jsonb   DEFAULT NULL,
    p_captured_at     timestamptz DEFAULT NULL,
    p_retention_class text    DEFAULT 'standard',
    p_sensitivity     text    DEFAULT 'internal'
) RETURNS bigint
LANGUAGE plpgsql
AS $body$
DECLARE
    v_id    bigint;
    v_hash  text;
    v_size  bigint;
    v_bytes bytea;
BEGIN
    IF p_content_bytes IS NULL AND p_content_text IS NULL AND p_content_jsonb IS NULL THEN
        RAISE EXCEPTION 'register_source_package: one of content_bytes / _text / _jsonb is required'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    -- Canonical hash form: bytes if given; else text; else jsonb::text.
    IF p_content_bytes IS NOT NULL THEN
        v_bytes := p_content_bytes;
    ELSIF p_content_text IS NOT NULL THEN
        v_bytes := convert_to(p_content_text, 'UTF8');
    ELSE
        v_bytes := convert_to(p_content_jsonb::text, 'UTF8');
    END IF;
    v_hash := encode(sha256(v_bytes), 'hex');
    v_size := octet_length(v_bytes);

    INSERT INTO malu$source_package
        (source_type, content_bytes, content_text, content_jsonb,
         content_hash, content_size, media_type, origin_jsonb,
         captured_at, retention_class, sensitivity)
    VALUES
        (p_source_type, p_content_bytes, p_content_text, p_content_jsonb,
         v_hash, v_size, p_media_type, p_origin_jsonb,
         p_captured_at, p_retention_class, p_sensitivity)
    RETURNING source_package_id INTO v_id;
    RETURN v_id;
END;
$body$;

CREATE FUNCTION register_claim(
    p_subject           text  DEFAULT NULL,
    p_verb              text  DEFAULT NULL,
    p_predicate         text  DEFAULT NULL,
    p_object_value      text  DEFAULT NULL,
    p_relationship      text  DEFAULT NULL,
    p_statement_text    text  DEFAULT NULL,
    p_statement_jsonb   jsonb DEFAULT NULL,
    p_source_package_id bigint DEFAULT NULL,
    p_source_locator    jsonb DEFAULT NULL,
    p_sensitivity       text  DEFAULT 'internal'
) RETURNS bigint
LANGUAGE plpgsql
AS $body$
DECLARE v_id bigint;
BEGIN
    INSERT INTO malu$claim
        (subject, verb, predicate, object_value, relationship,
         statement_text, statement_jsonb,
         source_package_id, source_locator, sensitivity)
    VALUES (p_subject, p_verb, p_predicate, p_object_value, p_relationship,
            p_statement_text, p_statement_jsonb,
            p_source_package_id, p_source_locator, p_sensitivity)
    RETURNING claim_id INTO v_id;
    RETURN v_id;
END;
$body$;

CREATE FUNCTION register_fact(
    p_claim_ids         bigint[],
    p_subject           text  DEFAULT NULL,
    p_verb              text  DEFAULT NULL,
    p_predicate         text  DEFAULT NULL,
    p_object_value      text  DEFAULT NULL,
    p_relationship      text  DEFAULT NULL,
    p_statement_text    text  DEFAULT NULL,
    p_statement_jsonb   jsonb DEFAULT NULL,
    p_verification_scope  text DEFAULT NULL,
    p_verification_method text DEFAULT NULL,
    p_sensitivity       text  DEFAULT 'internal'
) RETURNS bigint
LANGUAGE plpgsql
AS $body$
DECLARE
    v_id    bigint;
    v_claim bigint;
BEGIN
    INSERT INTO malu$fact
        (subject, verb, predicate, object_value, relationship,
         statement_text, statement_jsonb,
         verification_scope, verification_method, sensitivity)
    VALUES (p_subject, p_verb, p_predicate, p_object_value, p_relationship,
            p_statement_text, p_statement_jsonb,
            p_verification_scope, p_verification_method, p_sensitivity)
    RETURNING fact_id INTO v_id;

    IF p_claim_ids IS NOT NULL THEN
        FOREACH v_claim IN ARRAY p_claim_ids LOOP
            INSERT INTO malu$fact_claim (fact_id, claim_id)
            VALUES (v_id, v_claim);
        END LOOP;
    END IF;
    RETURN v_id;
END;
$body$;

CREATE FUNCTION register_memory(
    p_memory_kind   text,
    p_title         text  DEFAULT NULL,
    p_summary       text  DEFAULT NULL,
    p_payload_jsonb jsonb DEFAULT '{}'::jsonb,
    p_occurred_at   timestamptz DEFAULT NULL,
    p_occurred_until timestamptz DEFAULT NULL,
    p_sensitivity   text  DEFAULT 'internal'
) RETURNS bigint
LANGUAGE plpgsql
AS $body$
DECLARE v_id bigint;
BEGIN
    INSERT INTO malu$memory
        (memory_kind, title, summary, payload_jsonb,
         occurred_at, occurred_until, sensitivity)
    VALUES (p_memory_kind, p_title, p_summary, COALESCE(p_payload_jsonb, '{}'::jsonb),
            p_occurred_at, p_occurred_until, p_sensitivity)
    RETURNING memory_id INTO v_id;
    RETURN v_id;
END;
$body$;

CREATE FUNCTION register_episode(
    p_episode_kind  text,
    p_title         text,
    p_summary       text  DEFAULT NULL,
    p_payload_jsonb jsonb DEFAULT '{}'::jsonb,
    p_occurred_at   timestamptz DEFAULT NULL,
    p_occurred_until timestamptz DEFAULT NULL,
    p_sensitivity   text  DEFAULT 'internal'
) RETURNS bigint
LANGUAGE plpgsql
AS $body$
DECLARE v_id bigint;
BEGIN
    INSERT INTO malu$episode_object
        (episode_kind, title, summary, payload_jsonb,
         occurred_at, occurred_until, sensitivity)
    VALUES (p_episode_kind, p_title, p_summary, COALESCE(p_payload_jsonb, '{}'::jsonb),
            p_occurred_at, p_occurred_until, p_sensitivity)
    RETURNING episode_id INTO v_id;
    RETURN v_id;
END;
$body$;

CREATE FUNCTION register_memory_detail(
    p_detail_kind   text,
    p_parent_mdo_id bigint DEFAULT NULL,
    p_memory_id     bigint DEFAULT NULL,
    p_episode_id    bigint DEFAULT NULL,
    p_ordinal       integer DEFAULT NULL,
    p_title         text   DEFAULT NULL,
    p_body_text     text   DEFAULT NULL,
    p_body_jsonb    jsonb  DEFAULT NULL,
    p_sensitivity   text   DEFAULT 'internal'
) RETURNS bigint
LANGUAGE plpgsql
AS $body$
DECLARE v_id bigint;
BEGIN
    IF p_parent_mdo_id IS NULL AND p_memory_id IS NULL AND p_episode_id IS NULL THEN
        RAISE EXCEPTION
          'register_memory_detail: at least one of parent_mdo_id / memory_id / episode_id required'
          USING ERRCODE = 'invalid_parameter_value';
    END IF;
    INSERT INTO malu$memory_detail_object
        (parent_mdo_id, memory_id, episode_id, detail_kind,
         ordinal, title, body_text, body_jsonb, sensitivity)
    VALUES (p_parent_mdo_id, p_memory_id, p_episode_id, p_detail_kind,
            p_ordinal, p_title, p_body_text, p_body_jsonb, p_sensitivity)
    RETURNING mdo_id INTO v_id;
    RETURN v_id;
END;
$body$;

CREATE FUNCTION register_relationship_edge(
    p_source_object_type text,
    p_source_object_id   bigint,
    p_target_object_type text,
    p_target_object_id   bigint,
    p_relationship_type  text,
    p_label              text   DEFAULT NULL,
    p_edge_jsonb         jsonb  DEFAULT NULL,
    p_confidence         numeric DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql
AS $body$
DECLARE v_id bigint;
BEGIN
    INSERT INTO malu$relationship_edge
        (relationship_type, source_object_type, source_object_id,
         target_object_type, target_object_id,
         label, edge_jsonb, confidence)
    VALUES (p_relationship_type, p_source_object_type, p_source_object_id,
            p_target_object_type, p_target_object_id,
            p_label, p_edge_jsonb, p_confidence)
    RETURNING edge_id INTO v_id;
    RETURN v_id;
END;
$body$;

-- =====================================================================
-- record_derivation — the canonical ledger writer.
--
-- Per CLAUDE.md doctrine: every derived object MUST have a ledger
-- entry. Callers wrap their object creation + this call in one
-- transaction. S2-7 will provide atomic C wrappers.
-- =====================================================================
CREATE FUNCTION record_derivation(
    p_derived_object_type text,
    p_derived_object_id   bigint,
    p_parser_name         text   DEFAULT NULL,
    p_model_alias_id      bigint DEFAULT NULL,
    p_prompt_template_id  bigint DEFAULT NULL,
    p_policy_name         text   DEFAULT NULL,
    p_verifier_name       text   DEFAULT NULL,
    p_model_request_id    bigint DEFAULT NULL,
    p_inputs_jsonb        jsonb  DEFAULT '[]'::jsonb
) RETURNS bigint
LANGUAGE plpgsql
AS $body$
DECLARE
    v_id   bigint;
    v_hash text;
BEGIN
    v_hash := encode(sha256(
        convert_to(COALESCE(p_inputs_jsonb, '[]'::jsonb)::text, 'UTF8')
    ), 'hex');

    INSERT INTO malu$derivation_ledger
        (derived_object_type, derived_object_id,
         parser_name, model_alias_id, prompt_template_id,
         policy_name, verifier_name, model_request_id,
         inputs_jsonb, inputs_hash)
    VALUES (p_derived_object_type, p_derived_object_id,
            p_parser_name, p_model_alias_id, p_prompt_template_id,
            p_policy_name, p_verifier_name, p_model_request_id,
            COALESCE(p_inputs_jsonb, '[]'::jsonb), v_hash)
    RETURNING derivation_id INTO v_id;
    RETURN v_id;
END;
$body$;

GRANT EXECUTE ON FUNCTION
    register_source_package(text,bytea,text,jsonb,text,jsonb,timestamptz,text,text),
    register_claim(text,text,text,text,text,text,jsonb,bigint,jsonb,text),
    register_fact(bigint[],text,text,text,text,text,text,jsonb,text,text,text),
    register_memory(text,text,text,jsonb,timestamptz,timestamptz,text),
    register_episode(text,text,text,jsonb,timestamptz,timestamptz,text),
    register_memory_detail(text,bigint,bigint,bigint,integer,text,text,jsonb,text),
    register_relationship_edge(text,bigint,text,bigint,text,text,jsonb,numeric),
    record_derivation(text,bigint,text,bigint,bigint,text,text,bigint,jsonb)
TO maludb_memory_admin, maludb_memory_executor;

-- =====================================================================
-- Stage-boundary update.
--
-- stage_boundary_violations() had a hardcoded list that flagged any
-- malu$<stage2>* table as a violation. Now that S2-1 actually installs
-- them, narrow the forbidden list to Stage 3+ only. The Stage 2 names
-- we install (source_package, claim, fact, episode_object, memory,
-- memory_detail_object, relationship_edge, derivation_ledger) are
-- removed; malu$verbatim_archive (S2-2) and malu$governed_object
-- (currently unscoped) remain reserved.
-- =====================================================================
CREATE OR REPLACE FUNCTION stage_boundary_violations()
RETURNS TABLE(object_kind text, object_name text, stage smallint)
LANGUAGE sql STABLE
AS $body$
    WITH forbidden(name, stage) AS (
        VALUES
            ('malu$governed_object'::text,       2::smallint),
            ('malu$verbatim_archive',            2),
            ('malu$valid_time_window',           3),
            ('malu$transaction_time_window',     3),
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
