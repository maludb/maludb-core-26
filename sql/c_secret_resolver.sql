-- V3-SECRET-02 — C-backed external secret resolver regression coverage.
--
-- The file:// allowlist + 0400/0600 mode + uid check exercises better
-- as a TAP test against a real filesystem, but we can still exercise:
--   * unsupported scheme rejection
--   * file:// outside the allowlist rejection
--   * file:// containing '..' rejection
--   * https://-only enforcement (no plain http)
--   * the __secret_resolve dispatch story
--
-- Happy-path file:// reads + libcurl response handling live in the
-- TAP suite (services/tap/secret_resolver.t) because they need real
-- files with controlled mode bits and an httptest endpoint.

SET search_path TO maludb_core, public;

-- ---------------------------------------------------------------------
-- Test 1: unsupported scheme.
-- ---------------------------------------------------------------------
DO $body$
BEGIN
    PERFORM maludb_secret_resolve_external('s3://bucket/key');
    RAISE EXCEPTION 'resolver accepted s3:// (test 1 fail)';
EXCEPTION WHEN feature_not_supported THEN
    RAISE NOTICE 'resolver rejects unsupported scheme';
END;
$body$;

-- ---------------------------------------------------------------------
-- Test 2: plain http:// is rejected (only https:// allowed).
-- ---------------------------------------------------------------------
DO $body$
BEGIN
    PERFORM maludb_secret_resolve_external('http://example.com/secret');
    RAISE EXCEPTION 'resolver accepted http:// (test 2 fail)';
EXCEPTION WHEN feature_not_supported THEN
    RAISE NOTICE 'resolver rejects plain http';
END;
$body$;

-- ---------------------------------------------------------------------
-- Test 3: file:// outside the allowlist.
-- ---------------------------------------------------------------------
DO $body$
BEGIN
    PERFORM maludb_secret_resolve_external('file:///tmp/secret');
    RAISE EXCEPTION 'resolver accepted /tmp path (test 3 fail)';
EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'resolver rejects path outside allowlist';
END;
$body$;

-- ---------------------------------------------------------------------
-- Test 4: file:// with '..' traversal.
-- ---------------------------------------------------------------------
DO $body$
BEGIN
    PERFORM maludb_secret_resolve_external('file:///etc/maludb/secrets/../passwd');
    RAISE EXCEPTION 'resolver accepted .. traversal (test 4 fail)';
EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'resolver rejects path with ..';
END;
$body$;

-- ---------------------------------------------------------------------
-- Test 5: file:// relative path.
-- ---------------------------------------------------------------------
DO $body$
BEGIN
    PERFORM maludb_secret_resolve_external('file://relative/path');
    RAISE EXCEPTION 'resolver accepted relative path (test 5 fail)';
EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'resolver rejects relative path';
END;
$body$;

-- ---------------------------------------------------------------------
-- Test 6: __secret_resolve dispatches to the C path on external_ref.
-- We register a secret with a clearly-bogus external_ref so the C
-- function rejects; the wrapper SQLERRMs are routed through
-- malu$secret_use as 'rejected_external_failed'.
-- ---------------------------------------------------------------------
DO $body$
DECLARE
    v_sid bigint;
BEGIN
    PERFORM secret_set_external('csr_smoke_secret', 'other',
        's3://oops', 'V3-SECRET-02 dispatch smoke', NULL);

    BEGIN
        PERFORM __secret_resolve('csr_smoke_secret');
        RAISE EXCEPTION 'secret_resolve did not raise on s3 ref (test 6 fail)';
    EXCEPTION WHEN feature_not_supported THEN
        RAISE NOTICE '__secret_resolve dispatched the external_ref to the C resolver';
    END;

    SELECT secret_id INTO v_sid FROM malu$secret WHERE name = 'csr_smoke_secret';
    -- A 'rejected_external_failed' malu$secret_use row was written.
    PERFORM 1 FROM malu$secret_use su
              JOIN malu$secret_version sv USING (secret_version_id)
             WHERE sv.secret_id = v_sid AND su.outcome = 'rejected_external_failed';
    IF NOT FOUND THEN
        RAISE EXCEPTION 'no rejected_external_failed row recorded for csr_smoke_secret';
    END IF;
END;
$body$;

-- ---------------------------------------------------------------------
-- Cleanup.
-- ---------------------------------------------------------------------
DELETE FROM malu$secret_use
 WHERE secret_version_id IN
   (SELECT sv.secret_version_id FROM malu$secret_version sv
     JOIN malu$secret s USING (secret_id)
    WHERE s.name = 'csr_smoke_secret');
DELETE FROM malu$secret_version
 WHERE secret_id IN (SELECT secret_id FROM malu$secret WHERE name = 'csr_smoke_secret');
DELETE FROM malu$secret WHERE name = 'csr_smoke_secret';
DELETE FROM malu$audit_event
 WHERE event_kind LIKE 'secret_resolve_%' OR event_kind LIKE 'secret_set_%';
