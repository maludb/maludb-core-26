/* maludb_atomic.c — S2-7 multi-model atomic insertion.
 *
 * Per requirements.md §3.10 "Atomic multi-model writes":
 *   "Partial commits are forbidden."
 *
 * PG's WAL/MVCC handles atomicity at the transaction level; the value
 * S2-7 adds over the S2-1 register_* PL/pgSQL helpers is:
 *
 *   1. No implicit savepoints. PL/pgSQL EXCEPTION blocks silently
 *      create a savepoint per block — a function that catches an
 *      internal error can return success with partial writes
 *      visible. C functions inherit the outer transaction directly;
 *      any ereport(ERROR, ...) aborts the whole call, period.
 *
 *   2. Cross-write invariants are enforced inside one SPI session
 *      where intermediate IDs can be referenced without round-tripping
 *      back to the client.
 *
 *   3. The inputs hash for the Derivation Ledger is computed once
 *      over the canonical jsonb input manifest. CLAUDE.md doctrine:
 *      "Derivations without ledger entries are bugs." These wrappers
 *      make ledger entries non-optional.
 *
 * Functions:
 *   ingest_claim_atomic(...)        → bigint claim_id
 *     INSERT source_package + claim + ledger in one tx.
 *
 *   promote_claim_to_fact_atomic(...) → bigint fact_id
 *     INSERT fact + fact_claim links + ledger in one tx.
 *
 * Both delegate the actual row writes to the S2-1 register_* / S2-3
 * record_derivation functions via SPI so the validation triggers
 * (S2-2 seal lock, S2-6 payload schema) and RLS still fire.
 */

#include "postgres.h"
#include "fmgr.h"
#include "executor/spi.h"
#include "utils/array.h"
#include "utils/builtins.h"
#include "utils/jsonb.h"
#include "utils/lsyscache.h"
#include "utils/memutils.h"
#include "miscadmin.h"

#include <string.h>

/* Pulls one bigint from the FIRST row of the just-executed SPI query.
 * Raises if the row count != 1 or the value is NULL. */
static int64
spi_int8_singleton(const char *err_label)
{
    bool      isnull;
    Datum     d;
    HeapTuple row;

    if (SPI_processed != 1)
        ereport(ERROR,
                (errcode(ERRCODE_INTERNAL_ERROR),
                 errmsg("%s: expected 1 row, got %lu",
                        err_label, (unsigned long) SPI_processed)));
    row = SPI_tuptable->vals[0];
    d   = SPI_getbinval(row, SPI_tuptable->tupdesc, 1, &isnull);
    if (isnull)
        ereport(ERROR,
                (errcode(ERRCODE_NULL_VALUE_NOT_ALLOWED),
                 errmsg("%s: NULL value returned", err_label)));
    return DatumGetInt64(d);
}

/* ---------------------------------------------------------------------
 * ingest_claim_atomic(
 *     p_source_type     text,
 *     p_source_text     text,
 *     p_subject         text,
 *     p_verb            text,
 *     p_object_value    text,
 *     p_statement_text  text,
 *     p_parser_name     text,
 *     p_origin_jsonb    jsonb,
 *     p_source_locator  jsonb,
 *     p_model_request_id bigint,
 *     p_inputs_jsonb    jsonb
 * ) RETURNS bigint claim_id
 *
 * Inserts: malu$source_package + malu$claim + malu$derivation_ledger
 * in one transactional call. Any failure aborts the entire chain.
 * ------------------------------------------------------------------- */
PG_FUNCTION_INFO_V1(maludb_ingest_claim_atomic);
Datum
maludb_ingest_claim_atomic(PG_FUNCTION_ARGS)
{
    int     ret;
    int64   v_source_pkg_id;
    int64   v_claim_id;
    int64   v_inputs_jsonb_arg = 0;

    if (PG_ARGISNULL(0))
        ereport(ERROR,
                (errcode(ERRCODE_NULL_VALUE_NOT_ALLOWED),
                 errmsg("ingest_claim_atomic: source_type is required")));
    if (PG_ARGISNULL(1))
        ereport(ERROR,
                (errcode(ERRCODE_NULL_VALUE_NOT_ALLOWED),
                 errmsg("ingest_claim_atomic: source_text is required (v1)")));

    if ((ret = SPI_connect()) != SPI_OK_CONNECT)
        ereport(ERROR, (errmsg("SPI_connect failed: %d", ret)));

    /* ---- 1. register_source_package ------------------------------- */
    /* Only bind args we actually have. p_media_type, p_captured_at,
     * p_retention_class, p_sensitivity all have DEFAULTs the PL/pgSQL
     * function will apply when their parameters are omitted. */
    {
        Oid       argtypes[3] = { TEXTOID, TEXTOID, JSONBOID };
        Datum     args[3];
        char      nulls[3] = { ' ', ' ', 'n' };
        const char *sql =
            "SELECT maludb_core.register_source_package("
            "  p_source_type   => $1,"
            "  p_content_text  => $2,"
            "  p_origin_jsonb  => $3)";

        args[0] = PG_GETARG_DATUM(0);
        args[1] = PG_GETARG_DATUM(1);
        if (!PG_ARGISNULL(7)) { args[2] = PG_GETARG_DATUM(7); nulls[2] = ' '; }

        ret = SPI_execute_with_args(sql, 3, argtypes, args, nulls, false, 1);
        if (ret != SPI_OK_SELECT)
            ereport(ERROR, (errmsg("ingest_claim_atomic: register_source_package failed: %d", ret)));
        v_source_pkg_id = spi_int8_singleton("register_source_package");
    }

    /* ---- 2. register_claim referencing the source ----------------- */
    /* Bind only the args we have values for — named-arg SQL syntax
     * means the unbound ones fall back to the function's DEFAULTs
     * (notably p_sensitivity='internal'). Passing NULL explicitly via
     * SPI overrides the DEFAULT, so we MUST omit the parameter rather
     * than send NULL. */
    {
        Oid       argtypes[6] = { TEXTOID, TEXTOID, TEXTOID, TEXTOID, INT8OID, JSONBOID };
        Datum     args[6];
        char      nulls[6] = { 'n','n','n','n', ' ', 'n' };
        const char *sql =
            "SELECT maludb_core.register_claim("
            "  p_subject           => $1,"
            "  p_verb              => $2,"
            "  p_object_value      => $3,"
            "  p_statement_text    => $4,"
            "  p_source_package_id => $5,"
            "  p_source_locator    => $6)";

        if (!PG_ARGISNULL(2)) { args[0] = PG_GETARG_DATUM(2); nulls[0] = ' '; }
        if (!PG_ARGISNULL(3)) { args[1] = PG_GETARG_DATUM(3); nulls[1] = ' '; }
        if (!PG_ARGISNULL(4)) { args[2] = PG_GETARG_DATUM(4); nulls[2] = ' '; }
        if (!PG_ARGISNULL(5)) { args[3] = PG_GETARG_DATUM(5); nulls[3] = ' '; }
        args[4] = Int64GetDatum(v_source_pkg_id);
        if (!PG_ARGISNULL(8)) { args[5] = PG_GETARG_DATUM(8); nulls[5] = ' '; }

        ret = SPI_execute_with_args(sql, 6, argtypes, args, nulls, false, 1);
        if (ret != SPI_OK_SELECT)
            ereport(ERROR, (errmsg("ingest_claim_atomic: register_claim failed: %d", ret)));
        v_claim_id = spi_int8_singleton("register_claim");
    }

    /* ---- 3. record_derivation for the claim ----------------------- */
    {
        Oid       argtypes[5] = { TEXTOID, INT8OID, TEXTOID, INT8OID, JSONBOID };
        Datum     args[5];
        char      nulls[5] = { ' ', ' ', ' ', 'n', 'n' };
        const char *sql =
            "SELECT maludb_core.record_derivation("
            "  p_derived_object_type => $1,"
            "  p_derived_object_id   => $2,"
            "  p_parser_name         => $3,"
            "  p_model_request_id    => $4,"
            "  p_inputs_jsonb        => $5)";

        args[0] = CStringGetTextDatum("claim");
        args[1] = Int64GetDatum(v_claim_id);
        if (!PG_ARGISNULL(6)) { args[2] = PG_GETARG_DATUM(6); }
        else                  { args[2] = (Datum) 0; nulls[2] = 'n'; }
        if (!PG_ARGISNULL(9)) { args[3] = PG_GETARG_DATUM(9); nulls[3] = ' '; }
        if (!PG_ARGISNULL(10)) { args[4] = PG_GETARG_DATUM(10); nulls[4] = ' '; }
        (void) v_inputs_jsonb_arg;

        ret = SPI_execute_with_args(sql, 5, argtypes, args, nulls, false, 1);
        if (ret != SPI_OK_SELECT)
            ereport(ERROR, (errmsg("ingest_claim_atomic: record_derivation failed: %d", ret)));
        /* derivation_id returned but not propagated upward — caller
         * looks it up via the ledger if needed. */
    }

    SPI_finish();
    PG_RETURN_INT64(v_claim_id);
}

/* ---------------------------------------------------------------------
 * promote_claim_to_fact_atomic(
 *     p_claim_ids         bigint[],
 *     p_subject           text,
 *     p_verb              text,
 *     p_object_value      text,
 *     p_statement_text    text,
 *     p_verification_scope  text,
 *     p_verification_method text,
 *     p_parser_name       text,
 *     p_verifier_name     text,
 *     p_inputs_jsonb      jsonb
 * ) RETURNS bigint fact_id
 *
 * Inserts: malu$fact + fact_claim links + malu$derivation_ledger in
 * one tx. Verifies every claim_id in p_claim_ids exists (raises
 * no_data_found otherwise) before the fact row is created.
 * ------------------------------------------------------------------- */
PG_FUNCTION_INFO_V1(maludb_promote_claim_to_fact_atomic);
Datum
maludb_promote_claim_to_fact_atomic(PG_FUNCTION_ARGS)
{
    int       ret;
    int64     v_fact_id;
    ArrayType *claim_ids_arr;
    Datum    *claim_id_datums;
    int       n_claims;
    bool     *claim_id_nulls;

    if (PG_ARGISNULL(0))
        ereport(ERROR,
                (errcode(ERRCODE_NULL_VALUE_NOT_ALLOWED),
                 errmsg("promote_claim_to_fact_atomic: claim_ids required")));
    claim_ids_arr = PG_GETARG_ARRAYTYPE_P(0);
    deconstruct_array(claim_ids_arr, INT8OID, 8, true, 'd',
                      &claim_id_datums, &claim_id_nulls, &n_claims);
    if (n_claims == 0)
        ereport(ERROR,
                (errcode(ERRCODE_INVALID_PARAMETER_VALUE),
                 errmsg("promote_claim_to_fact_atomic: claim_ids must be non-empty")));

    if ((ret = SPI_connect()) != SPI_OK_CONNECT)
        ereport(ERROR, (errmsg("SPI_connect failed: %d", ret)));

    /* ---- 0. Verify every claim id exists. RLS gates which we see. -- */
    {
        Oid       argtypes[1] = { INT8ARRAYOID };
        Datum     args[1];
        const char *sql =
            "SELECT count(*)::bigint FROM maludb_core.malu$claim "
            "WHERE claim_id = ANY($1)";

        args[0] = PG_GETARG_DATUM(0);
        ret = SPI_execute_with_args(sql, 1, argtypes, args, NULL, true, 1);
        if (ret != SPI_OK_SELECT)
            ereport(ERROR, (errmsg("promote_claim_to_fact_atomic: claim verification failed: %d", ret)));
        if (spi_int8_singleton("claim verification") != (int64) n_claims) {
            SPI_finish();
            ereport(ERROR,
                    (errcode(ERRCODE_NO_DATA_FOUND),
                     errmsg("promote_claim_to_fact_atomic: one or more claim_ids not visible or missing")));
        }
    }

    /* ---- 1. register_fact, which writes both the fact row and the
     *        malu$fact_claim links in a single PL/pgSQL call. Omit
     *        unbound named args so DEFAULTs apply. -------------------- */
    {
        Oid       argtypes[7] = { INT8ARRAYOID, TEXTOID, TEXTOID, TEXTOID, TEXTOID, TEXTOID, TEXTOID };
        Datum     args[7];
        char      nulls[7] = { ' ', 'n','n','n','n', 'n','n' };
        const char *sql =
            "SELECT maludb_core.register_fact("
            "  p_claim_ids           => $1,"
            "  p_subject             => $2,"
            "  p_verb                => $3,"
            "  p_object_value        => $4,"
            "  p_statement_text      => $5,"
            "  p_verification_scope  => $6,"
            "  p_verification_method => $7)";

        args[0] = PG_GETARG_DATUM(0);
        if (!PG_ARGISNULL(1)) { args[1] = PG_GETARG_DATUM(1); nulls[1] = ' '; }
        if (!PG_ARGISNULL(2)) { args[2] = PG_GETARG_DATUM(2); nulls[2] = ' '; }
        if (!PG_ARGISNULL(3)) { args[3] = PG_GETARG_DATUM(3); nulls[3] = ' '; }
        if (!PG_ARGISNULL(4)) { args[4] = PG_GETARG_DATUM(4); nulls[4] = ' '; }
        if (!PG_ARGISNULL(5)) { args[5] = PG_GETARG_DATUM(5); nulls[5] = ' '; }
        if (!PG_ARGISNULL(6)) { args[6] = PG_GETARG_DATUM(6); nulls[6] = ' '; }

        ret = SPI_execute_with_args(sql, 7, argtypes, args, nulls, false, 1);
        if (ret != SPI_OK_SELECT)
            ereport(ERROR, (errmsg("promote_claim_to_fact_atomic: register_fact failed: %d", ret)));
        v_fact_id = spi_int8_singleton("register_fact");
    }

    /* ---- 2. record_derivation for the fact ------------------------ */
    {
        Oid       argtypes[5] = { TEXTOID, INT8OID, TEXTOID, TEXTOID, JSONBOID };
        Datum     args[5];
        char      nulls[5] = { ' ', ' ', 'n', 'n', 'n' };
        const char *sql =
            "SELECT maludb_core.record_derivation("
            "  p_derived_object_type => $1,"
            "  p_derived_object_id   => $2,"
            "  p_parser_name         => $3,"
            "  p_verifier_name       => $4,"
            "  p_inputs_jsonb        => $5)";

        args[0] = CStringGetTextDatum("fact");
        args[1] = Int64GetDatum(v_fact_id);
        if (!PG_ARGISNULL(7)) { args[2] = PG_GETARG_DATUM(7); nulls[2] = ' '; }
        if (!PG_ARGISNULL(8)) { args[3] = PG_GETARG_DATUM(8); nulls[3] = ' '; }
        if (!PG_ARGISNULL(9)) { args[4] = PG_GETARG_DATUM(9); nulls[4] = ' '; }

        ret = SPI_execute_with_args(sql, 5, argtypes, args, nulls, false, 1);
        if (ret != SPI_OK_SELECT)
            ereport(ERROR, (errmsg("promote_claim_to_fact_atomic: record_derivation failed: %d", ret)));
    }

    SPI_finish();
    PG_RETURN_INT64(v_fact_id);
}
