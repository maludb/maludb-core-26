\echo Use "ALTER EXTENSION maludb_core UPDATE TO '0.20.0'" to load this file. \quit

-- =====================================================================
-- maludb_core 0.19.0 → 0.20.0
--
-- Stage 2 — Multi-model atomic insertion C extension (S2-7).
--
-- Per requirements.md §3.10: "Partial commits are forbidden". PG's
-- WAL/MVCC handles transaction atomicity; what S2-7 adds is:
--
--   1. No implicit savepoints. PL/pgSQL EXCEPTION blocks silently
--      create a savepoint per block, and a function that catches an
--      internal error can return success with partial writes visible.
--      C functions inherit the outer transaction directly; any
--      ereport(ERROR, ...) aborts the whole call.
--
--   2. Cross-write invariants verified in one SPI session (e.g.,
--      every claim_id in promote_claim_to_fact_atomic must be visible
--      before the fact row is created).
--
--   3. Ledger writes are mandatory (CLAUDE.md doctrine: derivations
--      without ledger entries are bugs). The C wrappers cannot be
--      called without writing a ledger row.
--
-- Functions live in src/maludb_atomic.c. SQL declarations bind them
-- with default-valued args so PL/pgSQL callers don't have to spell
-- every parameter.
-- =====================================================================

CREATE OR REPLACE FUNCTION maludb_core_version() RETURNS text
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$ SELECT '0.20.0'::text $body$;

-- ---------------------------------------------------------------------
-- ingest_claim_atomic — source_package + claim + derivation_ledger.
--
-- Returns the new claim_id. Aborts the whole chain on any failure.
-- ---------------------------------------------------------------------
CREATE FUNCTION ingest_claim_atomic(
    p_source_type        text,
    p_source_text        text,
    p_subject            text    DEFAULT NULL,
    p_verb               text    DEFAULT NULL,
    p_object_value       text    DEFAULT NULL,
    p_statement_text     text    DEFAULT NULL,
    p_parser_name        text    DEFAULT NULL,
    p_origin_jsonb       jsonb   DEFAULT NULL,
    p_source_locator     jsonb   DEFAULT NULL,
    p_model_request_id   bigint  DEFAULT NULL,
    p_inputs_jsonb       jsonb   DEFAULT NULL
) RETURNS bigint
    AS 'MODULE_PATHNAME', 'maludb_ingest_claim_atomic'
    LANGUAGE C VOLATILE;

-- ---------------------------------------------------------------------
-- promote_claim_to_fact_atomic — fact + fact_claim links + ledger.
--
-- Verifies every claim_id in p_claim_ids is visible (RLS-scoped)
-- before writing the fact row. Raises no_data_found on any missing
-- claim. Returns the new fact_id.
-- ---------------------------------------------------------------------
CREATE FUNCTION promote_claim_to_fact_atomic(
    p_claim_ids            bigint[],
    p_subject              text    DEFAULT NULL,
    p_verb                 text    DEFAULT NULL,
    p_object_value         text    DEFAULT NULL,
    p_statement_text       text    DEFAULT NULL,
    p_verification_scope   text    DEFAULT NULL,
    p_verification_method  text    DEFAULT NULL,
    p_parser_name          text    DEFAULT NULL,
    p_verifier_name        text    DEFAULT NULL,
    p_inputs_jsonb         jsonb   DEFAULT NULL
) RETURNS bigint
    AS 'MODULE_PATHNAME', 'maludb_promote_claim_to_fact_atomic'
    LANGUAGE C VOLATILE;

GRANT EXECUTE ON FUNCTION
    ingest_claim_atomic(text, text, text, text, text, text, text, jsonb, jsonb, bigint, jsonb),
    promote_claim_to_fact_atomic(bigint[], text, text, text, text, text, text, text, text, jsonb)
TO maludb_memory_admin, maludb_memory_executor;
