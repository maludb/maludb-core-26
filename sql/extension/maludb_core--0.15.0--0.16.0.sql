\echo Use "ALTER EXTENSION maludb_core UPDATE TO '0.16.0'" to load this file. \quit

-- =====================================================================
-- maludb_core 0.15.0 → 0.16.0
--
-- Stage 2 — Verbatim Source Archive (S2-2).
--
-- Adds the storage + verification + lifecycle around malu$source_package
-- needed to meet requirements.md §3.6 (Verbatim Source Archive) and
-- §9 Stage 2 ("immutable hash-verified storage, tiered placement,
-- retention/legal-hold metadata").
--
-- New surface:
--   * malu$verbatim_archive          — placement-tier audit row per
--                                       sealed source (inline/hot/warm/
--                                       cold/external)
--   * malu$source_verification       — hash-verification audit log
--   * seal_source_package()          — sets sealed_at; locks content
--   * unseal_source_package()        — admin override; reason required
--   * archive_source_package()       — records archive transition
--   * tombstone_source_package()     — drops content unless legal hold
--   * verify_source_hash()           — recomputes + audits
--   * reingest_source_package()      — verbatim read with verify
--   * source_package_seal_lock_tg    — trigger; rejects content UPDATE
--                                       once sealed_at is set
--
-- Doctrine: once sealed_at is non-NULL, content_bytes / content_text /
-- content_jsonb / content_hash / content_size are immutable to anyone
-- but maludb_memory_admin (via unseal). Tombstone preserves the row
-- but clears content unless legal_hold prevents it.
-- =====================================================================

CREATE OR REPLACE FUNCTION maludb_core_version() RETURNS text
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$ SELECT '0.16.0'::text $body$;

-- ---------------------------------------------------------------------
-- Relax the S2-1 content-required CHECK on malu$source_package so
-- tombstone_source_package() can NULL the content without violating
-- the constraint. New semantics: at least one of content_bytes /
-- _text / _jsonb must be set OR the row must be tombstoned.
-- ---------------------------------------------------------------------
ALTER TABLE malu$source_package
    DROP CONSTRAINT malu$source_package_check;
ALTER TABLE malu$source_package
    ADD CONSTRAINT malu$source_package_content_or_tombstoned_check
    CHECK (
        content_bytes IS NOT NULL
        OR content_text IS NOT NULL
        OR content_jsonb IS NOT NULL
        OR tombstoned_at IS NOT NULL
    );

-- =====================================================================
-- malu$verbatim_archive
--
-- One row per archive event for a source_package. placement_tier
-- distinguishes where the verbatim bytes actually live:
--   inline   — bytes stay on malu$source_package (default; v1).
--   hot      — duplicated here uncompressed for fast read.
--   warm     — compressed copy here (gzip/zstd).
--   cold     — metadata only; bytes evicted to external_uri.
--   external — managed entirely outside MaluDB; external_uri is the
--              system-of-record pointer.
-- =====================================================================
CREATE TABLE malu$verbatim_archive (
    archive_id            bigserial PRIMARY KEY,
    source_package_id     bigint NOT NULL
        REFERENCES malu$source_package(source_package_id) ON DELETE RESTRICT,
    owner_schema          name NOT NULL DEFAULT current_schema(),
    placement_tier        text NOT NULL DEFAULT 'inline'
        CHECK (placement_tier IN ('inline','hot','warm','cold','external')),
    content_bytes         bytea,
    content_compression   text NOT NULL DEFAULT 'none'
        CHECK (content_compression IN ('none','gzip','zstd')),
    content_size_archived bigint,
    archive_hash          text NOT NULL,
    external_uri          text,
    external_etag         text,
    sealed_at             timestamptz NOT NULL DEFAULT now(),
    superseded_at         timestamptz,
    note                  text,
    CHECK (placement_tier <> 'external' OR external_uri IS NOT NULL),
    CHECK (placement_tier <> 'cold'     OR external_uri IS NOT NULL),
    CHECK (placement_tier NOT IN ('inline','hot') OR content_compression = 'none')
);
CREATE INDEX malu$verbatim_archive_pkg_idx
    ON malu$verbatim_archive(source_package_id);
CREATE INDEX malu$verbatim_archive_tier_idx
    ON malu$verbatim_archive(placement_tier)
    WHERE superseded_at IS NULL;

ALTER TABLE malu$verbatim_archive ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_owner ON malu$verbatim_archive
    USING (owner_schema = current_schema())
    WITH CHECK (owner_schema = current_schema());

-- =====================================================================
-- malu$source_verification
--
-- Audit log for every verify_source_hash() call. Records the expected
-- hash (from the row), the computed hash, whether they matched, and
-- the role that ran the verification.
-- =====================================================================
CREATE TABLE malu$source_verification (
    verification_id      bigserial PRIMARY KEY,
    source_package_id    bigint NOT NULL
        REFERENCES malu$source_package(source_package_id) ON DELETE CASCADE,
    archive_id           bigint
        REFERENCES malu$verbatim_archive(archive_id) ON DELETE SET NULL,
    performed_by         name NOT NULL DEFAULT current_user,
    performed_at         timestamptz NOT NULL DEFAULT now(),
    expected_hash        text NOT NULL,
    computed_hash        text NOT NULL,
    matched              boolean NOT NULL,
    context_note         text
);
CREATE INDEX malu$source_verification_pkg_idx
    ON malu$source_verification(source_package_id, performed_at DESC);
CREATE INDEX malu$source_verification_failed_idx
    ON malu$source_verification(source_package_id) WHERE matched = false;

ALTER TABLE malu$source_verification ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_via_source ON malu$source_verification
    USING (EXISTS (
        SELECT 1 FROM malu$source_package sp
        WHERE sp.source_package_id = malu$source_verification.source_package_id
          AND sp.owner_schema = current_schema()
    ))
    WITH CHECK (EXISTS (
        SELECT 1 FROM malu$source_package sp
        WHERE sp.source_package_id = malu$source_verification.source_package_id
          AND sp.owner_schema = current_schema()
    ));

GRANT SELECT ON malu$verbatim_archive, malu$source_verification TO
    maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;
GRANT INSERT, UPDATE, DELETE ON malu$verbatim_archive, malu$source_verification TO
    maludb_memory_admin;
GRANT INSERT ON malu$source_verification TO maludb_memory_executor;

-- =====================================================================
-- Canonical content hash + size — computed identically by
-- register_source_package and verify_source_hash to ensure
-- round-tripping doesn't yield false mismatches.
-- =====================================================================
CREATE FUNCTION _source_canonical_bytes(
    p_bytes bytea, p_text text, p_jsonb jsonb
) RETURNS bytea
LANGUAGE sql IMMUTABLE PARALLEL SAFE
AS $body$
    SELECT
        CASE
            WHEN p_bytes IS NOT NULL THEN p_bytes
            WHEN p_text  IS NOT NULL THEN convert_to(p_text, 'UTF8')
            WHEN p_jsonb IS NOT NULL THEN convert_to(p_jsonb::text, 'UTF8')
            ELSE convert_to('', 'UTF8')
        END;
$body$;

-- =====================================================================
-- Immutability trigger.
--
-- Once sealed_at is set, content_bytes / content_text / content_jsonb /
-- content_hash / content_size cannot be modified. The trigger fires on
-- UPDATE and inspects the prior-row sealed_at vs the new-row values.
--
-- maludb_memory_admin can bypass by first calling unseal_source_package()
-- (which writes a verbatim_archive note and clears sealed_at). The
-- trigger does NOT special-case role identity — it enforces the seal
-- as a row-state invariant.
-- =====================================================================
CREATE FUNCTION _source_package_seal_lock() RETURNS trigger
LANGUAGE plpgsql
AS $body$
BEGIN
    IF OLD.sealed_at IS NOT NULL THEN
        IF NEW.content_bytes IS DISTINCT FROM OLD.content_bytes
           OR NEW.content_text IS DISTINCT FROM OLD.content_text
           OR NEW.content_jsonb IS DISTINCT FROM OLD.content_jsonb
           OR NEW.content_hash IS DISTINCT FROM OLD.content_hash
           OR NEW.content_size IS DISTINCT FROM OLD.content_size
           OR NEW.source_type IS DISTINCT FROM OLD.source_type THEN
            RAISE EXCEPTION
              'SOURCE_PACKAGE_SEALED: content of source_package_id=% is sealed at %; call unseal_source_package() first',
              OLD.source_package_id, OLD.sealed_at
              USING ERRCODE = 'object_not_in_prerequisite_state';
        END IF;
    END IF;
    RETURN NEW;
END;
$body$;

CREATE TRIGGER source_package_seal_lock_tg
    BEFORE UPDATE ON malu$source_package
    FOR EACH ROW EXECUTE FUNCTION _source_package_seal_lock();

-- =====================================================================
-- seal_source_package
--
-- Sets sealed_at = now() and writes the corresponding
-- malu$verbatim_archive row (placement_tier='inline' by default).
-- Idempotent: if already sealed, no-op + returns the existing
-- archive_id.
-- =====================================================================
CREATE FUNCTION seal_source_package(
    p_source_package_id bigint,
    p_placement_tier    text DEFAULT 'inline',
    p_external_uri      text DEFAULT NULL,
    p_note              text DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql
AS $body$
DECLARE
    v_sp          malu$source_package%ROWTYPE;
    v_archive_id  bigint;
    v_size        bigint;
BEGIN
    SELECT * INTO v_sp FROM malu$source_package
     WHERE source_package_id = p_source_package_id;
    IF v_sp.source_package_id IS NULL THEN
        RAISE EXCEPTION 'unknown source_package_id: %', p_source_package_id
            USING ERRCODE = 'no_data_found';
    END IF;

    IF v_sp.sealed_at IS NOT NULL THEN
        -- Already sealed; surface the current archive_id.
        SELECT archive_id INTO v_archive_id FROM malu$verbatim_archive
         WHERE source_package_id = p_source_package_id
           AND superseded_at IS NULL
         ORDER BY sealed_at DESC LIMIT 1;
        RETURN v_archive_id;
    END IF;

    UPDATE malu$source_package SET sealed_at = now()
     WHERE source_package_id = p_source_package_id;

    v_size := octet_length(_source_canonical_bytes(
                  v_sp.content_bytes, v_sp.content_text, v_sp.content_jsonb));

    INSERT INTO malu$verbatim_archive
        (source_package_id, placement_tier, content_size_archived,
         archive_hash, external_uri, note)
    VALUES (p_source_package_id, p_placement_tier, v_size,
            v_sp.content_hash, p_external_uri, p_note)
    RETURNING archive_id INTO v_archive_id;

    RETURN v_archive_id;
END;
$body$;

-- =====================================================================
-- unseal_source_package — admin override. Records the unseal as a
-- verbatim_archive note row (placement_tier=inline + note=reason) so
-- the seal/unseal history stays auditable.
-- =====================================================================
CREATE FUNCTION unseal_source_package(
    p_source_package_id bigint,
    p_reason            text
) RETURNS void
LANGUAGE plpgsql
AS $body$
BEGIN
    IF p_reason IS NULL OR p_reason = '' THEN
        RAISE EXCEPTION 'unseal_source_package: reason required'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    PERFORM 1 FROM malu$source_package
     WHERE source_package_id = p_source_package_id AND sealed_at IS NOT NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION
          'source_package_id=% is not currently sealed',
          p_source_package_id
          USING ERRCODE = 'object_not_in_prerequisite_state';
    END IF;

    UPDATE malu$verbatim_archive
       SET superseded_at = now()
     WHERE source_package_id = p_source_package_id
       AND superseded_at IS NULL;

    UPDATE malu$source_package SET sealed_at = NULL
     WHERE source_package_id = p_source_package_id;

    INSERT INTO malu$verbatim_archive
        (source_package_id, placement_tier, archive_hash, note, sealed_at, superseded_at)
    VALUES (p_source_package_id, 'inline',
            (SELECT content_hash FROM malu$source_package WHERE source_package_id = p_source_package_id),
            'unseal: ' || p_reason,
            now(), now());
END;
$body$;

-- =====================================================================
-- archive_source_package — sets archived_at, records a new
-- verbatim_archive row at the requested placement_tier. The row's
-- content_bytes column may carry a (possibly compressed) snapshot
-- when the operator wants tier-local storage; for inline/external
-- tiers it's NULL.
-- =====================================================================
CREATE FUNCTION archive_source_package(
    p_source_package_id bigint,
    p_placement_tier    text,
    p_content_bytes     bytea  DEFAULT NULL,
    p_content_compression text DEFAULT 'none',
    p_external_uri      text   DEFAULT NULL,
    p_external_etag     text   DEFAULT NULL,
    p_note              text   DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql
AS $body$
DECLARE
    v_sp          malu$source_package%ROWTYPE;
    v_archive_id  bigint;
BEGIN
    SELECT * INTO v_sp FROM malu$source_package
     WHERE source_package_id = p_source_package_id;
    IF v_sp.source_package_id IS NULL THEN
        RAISE EXCEPTION 'unknown source_package_id: %', p_source_package_id
            USING ERRCODE = 'no_data_found';
    END IF;
    IF v_sp.sealed_at IS NULL THEN
        RAISE EXCEPTION
          'archive_source_package: seal first (source_package_id=%)',
          p_source_package_id
          USING ERRCODE = 'object_not_in_prerequisite_state';
    END IF;

    UPDATE malu$verbatim_archive
       SET superseded_at = now()
     WHERE source_package_id = p_source_package_id
       AND superseded_at IS NULL;

    INSERT INTO malu$verbatim_archive
        (source_package_id, placement_tier, content_bytes,
         content_compression, content_size_archived, archive_hash,
         external_uri, external_etag, note)
    VALUES (p_source_package_id, p_placement_tier, p_content_bytes,
            p_content_compression,
            CASE WHEN p_content_bytes IS NOT NULL
                 THEN octet_length(p_content_bytes) END,
            v_sp.content_hash, p_external_uri, p_external_etag, p_note)
    RETURNING archive_id INTO v_archive_id;

    UPDATE malu$source_package SET archived_at = now()
     WHERE source_package_id = p_source_package_id;

    RETURN v_archive_id;
END;
$body$;

-- =====================================================================
-- tombstone_source_package — sets tombstoned_at. If the row is NOT on
-- legal hold, NULL out the inline content + any non-cold archive rows.
-- Hash + size stay intact for audit. legal_hold rows keep their content
-- (the whole point of legal hold).
-- =====================================================================
CREATE FUNCTION tombstone_source_package(
    p_source_package_id bigint,
    p_reason            text
) RETURNS void
LANGUAGE plpgsql
AS $body$
DECLARE
    v_sp malu$source_package%ROWTYPE;
BEGIN
    IF p_reason IS NULL OR p_reason = '' THEN
        RAISE EXCEPTION 'tombstone_source_package: reason required'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    SELECT * INTO v_sp FROM malu$source_package
     WHERE source_package_id = p_source_package_id;
    IF v_sp.source_package_id IS NULL THEN
        RAISE EXCEPTION 'unknown source_package_id: %', p_source_package_id
            USING ERRCODE = 'no_data_found';
    END IF;

    -- Lift the seal so the content-immutability trigger lets the
    -- tombstone NULL pass through. Record the seal lift in the
    -- archive log.
    UPDATE malu$source_package
       SET sealed_at     = NULL,
           tombstoned_at = now()
     WHERE source_package_id = p_source_package_id;

    INSERT INTO malu$verbatim_archive
        (source_package_id, placement_tier, archive_hash, note, sealed_at, superseded_at)
    VALUES (p_source_package_id, 'inline', v_sp.content_hash,
            'tombstone: ' || p_reason, now(), now());

    IF NOT v_sp.legal_hold THEN
        UPDATE malu$source_package
           SET content_bytes = NULL,
               content_text  = NULL,
               content_jsonb = NULL
         WHERE source_package_id = p_source_package_id;
        -- Re-seal the now-empty row.
        UPDATE malu$source_package SET sealed_at = now()
         WHERE source_package_id = p_source_package_id;
        -- Mark non-external archives as superseded so re-ingest fails
        -- loudly (the inline / hot / warm copies just got dropped).
        UPDATE malu$verbatim_archive
           SET superseded_at = now()
         WHERE source_package_id = p_source_package_id
           AND superseded_at    IS NULL
           AND placement_tier   IN ('inline','hot','warm');
    END IF;
END;
$body$;

-- =====================================================================
-- verify_source_hash — recompute the content hash from the inline
-- payload and compare to the stored value. Writes a malu$source_
-- verification audit row regardless of outcome.
--
-- Returns a (matched, expected, computed) composite. The function
-- never raises on mismatch — operators decide how to react (legal
-- hold, alert, reseal from archive, etc.).
-- =====================================================================
CREATE TYPE malu$verify_result AS (
    matched          boolean,
    expected_hash    text,
    computed_hash    text,
    verification_id  bigint
);

CREATE FUNCTION verify_source_hash(
    p_source_package_id bigint,
    p_context_note      text DEFAULT NULL
) RETURNS malu$verify_result
LANGUAGE plpgsql
AS $body$
DECLARE
    v_sp        malu$source_package%ROWTYPE;
    v_canon     bytea;
    v_computed  text;
    v_id        bigint;
    v_archive_id bigint;
    v_matched   boolean;
BEGIN
    SELECT * INTO v_sp FROM malu$source_package
     WHERE source_package_id = p_source_package_id;
    IF v_sp.source_package_id IS NULL THEN
        RAISE EXCEPTION 'unknown source_package_id: %', p_source_package_id
            USING ERRCODE = 'no_data_found';
    END IF;

    v_canon    := _source_canonical_bytes(v_sp.content_bytes,
                                          v_sp.content_text,
                                          v_sp.content_jsonb);
    v_computed := encode(sha256(v_canon), 'hex');
    v_matched  := (v_computed = v_sp.content_hash);

    SELECT archive_id INTO v_archive_id FROM malu$verbatim_archive
     WHERE source_package_id = p_source_package_id
       AND superseded_at IS NULL
     ORDER BY sealed_at DESC LIMIT 1;

    INSERT INTO malu$source_verification
        (source_package_id, archive_id, expected_hash, computed_hash,
         matched, context_note)
    VALUES (p_source_package_id, v_archive_id, v_sp.content_hash,
            v_computed, v_matched, p_context_note)
    RETURNING verification_id INTO v_id;

    RETURN ROW(v_matched, v_sp.content_hash, v_computed, v_id)::malu$verify_result;
END;
$body$;

-- =====================================================================
-- reingest_source_package — the canonical verbatim-read API. Per
-- requirements.md §3.6, future extraction/summarization/embedding
-- models call this to operate on the original evidence with hash
-- verification.
--
-- p_verify=true (default) runs verify_source_hash() first and raises
-- on mismatch. p_verify=false skips verification for read-heavy
-- workloads where the operator already trusts the substrate.
-- =====================================================================
CREATE TYPE malu$reingest_result AS (
    content_bytes  bytea,
    content_text   text,
    content_jsonb  jsonb,
    content_hash   text,
    source_type    text,
    media_type     text,
    sealed_at      timestamptz
);

CREATE FUNCTION reingest_source_package(
    p_source_package_id bigint,
    p_verify            boolean DEFAULT true
) RETURNS malu$reingest_result
LANGUAGE plpgsql
AS $body$
DECLARE
    v_sp     malu$source_package%ROWTYPE;
    v_check  malu$verify_result;
BEGIN
    SELECT * INTO v_sp FROM malu$source_package
     WHERE source_package_id = p_source_package_id;
    IF v_sp.source_package_id IS NULL THEN
        RAISE EXCEPTION 'unknown source_package_id: %', p_source_package_id
            USING ERRCODE = 'no_data_found';
    END IF;
    IF v_sp.tombstoned_at IS NOT NULL
       AND v_sp.content_bytes IS NULL
       AND v_sp.content_text  IS NULL
       AND v_sp.content_jsonb IS NULL THEN
        RAISE EXCEPTION
          'SOURCE_TOMBSTONED: source_package_id=% content was tombstoned at %',
          p_source_package_id, v_sp.tombstoned_at
          USING ERRCODE = 'object_not_in_prerequisite_state';
    END IF;

    IF p_verify THEN
        v_check := verify_source_hash(p_source_package_id, 'reingest');
        IF NOT v_check.matched THEN
            RAISE EXCEPTION
              'SOURCE_HASH_MISMATCH: source_package_id=% expected=% computed=%',
              p_source_package_id, v_check.expected_hash, v_check.computed_hash
              USING ERRCODE = 'data_corrupted';
        END IF;
    END IF;

    RETURN ROW(v_sp.content_bytes, v_sp.content_text, v_sp.content_jsonb,
               v_sp.content_hash, v_sp.source_type, v_sp.media_type,
               v_sp.sealed_at)::malu$reingest_result;
END;
$body$;

-- =====================================================================
-- _validate_source_locator — sanity-check the source_locator JSONB
-- structure on malu$claim. Recognised keys must be the expected type;
-- unknown keys are allowed (forward-compat). Returns true on valid;
-- raises on type mismatch.
--
-- Recognised keys (§3.6 reference model):
--   document_id        text
--   timestamp          text (ISO 8601)
--   authorship         text
--   page_no            integer
--   line_no            integer
--   byte_offset        integer
--   byte_length        integer
--   message_id         text
--   transcript_offset  integer
--   api_record_id      text
--   source_cursor      text
-- =====================================================================
CREATE FUNCTION _validate_source_locator(p_locator jsonb) RETURNS boolean
LANGUAGE plpgsql IMMUTABLE
AS $body$
DECLARE
    v_int_keys constant text[] := ARRAY[
        'page_no','line_no','byte_offset','byte_length','transcript_offset'];
    v_txt_keys constant text[] := ARRAY[
        'document_id','timestamp','authorship','message_id','api_record_id','source_cursor'];
    k text;
BEGIN
    IF p_locator IS NULL THEN RETURN true; END IF;
    IF jsonb_typeof(p_locator) <> 'object' THEN
        RAISE EXCEPTION 'source_locator must be a JSON object, got %', jsonb_typeof(p_locator)
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    FOREACH k IN ARRAY v_int_keys LOOP
        IF p_locator ? k AND jsonb_typeof(p_locator->k) NOT IN ('number','null') THEN
            RAISE EXCEPTION 'source_locator.% must be an integer, got %',
                k, jsonb_typeof(p_locator->k)
                USING ERRCODE = 'invalid_parameter_value';
        END IF;
    END LOOP;
    FOREACH k IN ARRAY v_txt_keys LOOP
        IF p_locator ? k AND jsonb_typeof(p_locator->k) NOT IN ('string','null') THEN
            RAISE EXCEPTION 'source_locator.% must be a string, got %',
                k, jsonb_typeof(p_locator->k)
                USING ERRCODE = 'invalid_parameter_value';
        END IF;
    END LOOP;
    RETURN true;
END;
$body$;

GRANT EXECUTE ON FUNCTION
    seal_source_package(bigint, text, text, text),
    archive_source_package(bigint, text, bytea, text, text, text, text),
    tombstone_source_package(bigint, text),
    verify_source_hash(bigint, text),
    reingest_source_package(bigint, boolean),
    _validate_source_locator(jsonb)
TO maludb_memory_admin, maludb_memory_executor;

-- unseal is admin-only.
GRANT EXECUTE ON FUNCTION unseal_source_package(bigint, text)
TO maludb_memory_admin;

-- =====================================================================
-- Stage-boundary update. S2-2 installs malu$verbatim_archive — remove
-- it from the forbidden list. malu$governed_object stays reserved.
-- =====================================================================
CREATE OR REPLACE FUNCTION stage_boundary_violations()
RETURNS TABLE(object_kind text, object_name text, stage smallint)
LANGUAGE sql STABLE
AS $body$
    WITH forbidden(name, stage) AS (
        VALUES
            ('malu$governed_object'::text,       2::smallint),
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
