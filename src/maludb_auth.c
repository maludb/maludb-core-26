/* maludb_auth.c — V3-AUTH-02 C-backed auth primitives.
 *
 * Provides:
 *   maludb_hmac_sha256(bytea key, bytea data) RETURNS bytea
 *     OpenSSL-backed HMAC-SHA256. Replaces the pgcrypto / PL/pgSQL
 *     hashing path on the token-verify hot path.
 *
 *   maludb_jwt_verify(text jwt) RETURNS TABLE (...)
 *     Parses a JWT, looks up the signing key in malu$jwt_signing_key
 *     via SPI, verifies the signature, and returns the canonical
 *     claim row. HS256 is fully implemented; RS256/ES256/EdDSA
 *     branches raise a structured error pointing at the asymmetric
 *     follow-up. Constant-time comparison via CRYPTO_memcmp.
 *
 * Build: links against libcrypto (already implied by pgcrypto in this
 * cluster; the extension is built with -lssl -lcrypto via SHLIB_LINK
 * in the Makefile).
 */

#include "postgres.h"
#include "fmgr.h"
#include "access/htup_details.h"
#include "catalog/pg_type.h"
#include "executor/spi.h"
#include "funcapi.h"
#include "miscadmin.h"
#include "nodes/execnodes.h"
#include "utils/tuplestore.h"
#include "utils/array.h"
#include "utils/builtins.h"
#include "utils/jsonb.h"
#include "utils/lsyscache.h"
#include "utils/memutils.h"
#include "miscadmin.h"

#include <openssl/crypto.h>
#include <openssl/hmac.h>
#include <openssl/sha.h>

#include <stddef.h>
#include <string.h>


PG_FUNCTION_INFO_V1(maludb_hmac_sha256);
PG_FUNCTION_INFO_V1(maludb_jwt_verify);


/* ----------------------------------------------------------------------
 * maludb_hmac_sha256(key bytea, data bytea) -> bytea
 * ---------------------------------------------------------------------- */

Datum
maludb_hmac_sha256(PG_FUNCTION_ARGS)
{
    bytea  *key  = PG_GETARG_BYTEA_PP(0);
    bytea  *data = PG_GETARG_BYTEA_PP(1);
    unsigned char  out[SHA256_DIGEST_LENGTH];
    unsigned int   outlen = sizeof(out);
    bytea  *result;

    if (HMAC(EVP_sha256(),
             VARDATA_ANY(key),  VARSIZE_ANY_EXHDR(key),
             (const unsigned char *) VARDATA_ANY(data), VARSIZE_ANY_EXHDR(data),
             out, &outlen) == NULL)
        ereport(ERROR,
                (errcode(ERRCODE_INTERNAL_ERROR),
                 errmsg("maludb_hmac_sha256: OpenSSL HMAC failed")));

    result = (bytea *) palloc(VARHDRSZ + outlen);
    SET_VARSIZE(result, VARHDRSZ + outlen);
    memcpy(VARDATA(result), out, outlen);
    PG_RETURN_BYTEA_P(result);
}


/* ----------------------------------------------------------------------
 * maludb_jwt_verify(p_jwt text) -> TABLE (...)
 *
 * JWT layout: <header_b64url>.<payload_b64url>.<sig_b64url>
 * Algorithms: HS256 (full); RS256/RS384/RS512/ES256/ES384/ES512/EdDSA
 *             (currently raise feature_not_supported with HINT pointing
 *             at the asymmetric follow-up).
 * ---------------------------------------------------------------------- */

/* base64url -> bytes. Returns palloc'd buffer + sets *outlen.
 * Returns NULL on malformed input. */
static unsigned char *
b64url_decode(const char *src, size_t src_len, size_t *outlen)
{
    static const signed char dec[256] = {
        ['A']=0, ['B']=1, ['C']=2, ['D']=3, ['E']=4, ['F']=5, ['G']=6, ['H']=7,
        ['I']=8, ['J']=9, ['K']=10,['L']=11,['M']=12,['N']=13,['O']=14,['P']=15,
        ['Q']=16,['R']=17,['S']=18,['T']=19,['U']=20,['V']=21,['W']=22,['X']=23,
        ['Y']=24,['Z']=25,
        ['a']=26,['b']=27,['c']=28,['d']=29,['e']=30,['f']=31,['g']=32,['h']=33,
        ['i']=34,['j']=35,['k']=36,['l']=37,['m']=38,['n']=39,['o']=40,['p']=41,
        ['q']=42,['r']=43,['s']=44,['t']=45,['u']=46,['v']=47,['w']=48,['x']=49,
        ['y']=50,['z']=51,
        ['0']=52,['1']=53,['2']=54,['3']=55,['4']=56,['5']=57,['6']=58,['7']=59,
        ['8']=60,['9']=61,['-']=62,['_']=63,
    };
    /* Mark every other byte as invalid (-1). */
    static int dec_initialised = 0;
    static signed char tab[256];
    if (!dec_initialised)
    {
        memset(tab, -1, sizeof(tab));
        for (int i = 0; i < 256; i++)
            if (dec[i] != 0 || i == 'A')
                tab[i] = dec[i];
        dec_initialised = 1;
    }

    size_t outcap = (src_len * 3) / 4 + 4;
    unsigned char *out = palloc(outcap);
    size_t op = 0;
    uint32_t buf = 0;
    int bits = 0;

    for (size_t i = 0; i < src_len; i++)
    {
        char c = src[i];
        if (c == '=' || c == '\n' || c == '\r')
            continue;
        if (c < 0 || tab[(unsigned char) c] < 0)
        {
            pfree(out);
            return NULL;
        }
        buf = (buf << 6) | tab[(unsigned char) c];
        bits += 6;
        if (bits >= 8)
        {
            bits -= 8;
            out[op++] = (buf >> bits) & 0xFF;
        }
    }
    *outlen = op;
    return out;
}

/* Constant-time compare. Both buffers must be the same length. */
static int
ct_eq(const unsigned char *a, const unsigned char *b, size_t n)
{
    return CRYPTO_memcmp(a, b, n) == 0;
}

/* Locate '.' separators in a JWT string. Returns 0 on success and
 * populates the offsets/lengths; -1 on malformed. */
static int
jwt_split(const char *jwt, size_t jwt_len,
          size_t *h_off, size_t *h_len,
          size_t *p_off, size_t *p_len,
          size_t *s_off, size_t *s_len)
{
    size_t dot1 = 0, dot2 = 0;
    int    found = 0;

    for (size_t i = 0; i < jwt_len; i++)
    {
        if (jwt[i] == '.')
        {
            if (found == 0) { dot1 = i; found = 1; }
            else if (found == 1) { dot2 = i; found = 2; }
            else return -1;
        }
    }
    if (found != 2 || dot1 == 0 || dot2 <= dot1 + 1 || dot2 == jwt_len - 1)
        return -1;
    *h_off = 0;          *h_len = dot1;
    *p_off = dot1 + 1;   *p_len = dot2 - dot1 - 1;
    *s_off = dot2 + 1;   *s_len = jwt_len - dot2 - 1;
    return 0;
}

/* Extract a single string field from a JSON object's top level.
 * Returns a palloc'd C string (caller frees with pfree) or NULL on
 * miss / malformed. This is a small hand-rolled scanner so we don't
 * need to spin up jsonb parsing for header / payload. Whitespace is
 * tolerated; nested objects / arrays / numbers are skipped.
 */
static char *
json_get_string(const char *json, size_t json_len, const char *field)
{
    size_t flen = strlen(field);
    size_t i = 0;
    int depth = 0;
    int in_str = 0;
    int esc = 0;

    /* Find top-level field. */
    while (i < json_len)
    {
        char c = json[i];
        if (in_str)
        {
            if (esc) { esc = 0; i++; continue; }
            if (c == '\\') { esc = 1; i++; continue; }
            if (c == '"')  { in_str = 0; i++; continue; }
            i++;
            continue;
        }
        if (c == '"')
        {
            /* Maybe a key — but only at depth 1 */
            size_t start = i + 1;
            size_t j = start;
            int esc2 = 0;
            while (j < json_len)
            {
                char kc = json[j];
                if (esc2) { esc2 = 0; j++; continue; }
                if (kc == '\\') { esc2 = 1; j++; continue; }
                if (kc == '"') break;
                j++;
            }
            if (j >= json_len) return NULL;
            size_t klen = j - start;
            int is_field = (depth == 1 && klen == flen
                            && memcmp(json + start, field, flen) == 0);
            i = j + 1;
            /* skip spaces */
            while (i < json_len && (json[i] == ' ' || json[i] == '\t'
                                     || json[i] == '\n' || json[i] == '\r'))
                i++;
            if (i >= json_len || json[i] != ':')
                continue;
            i++;
            while (i < json_len && (json[i] == ' ' || json[i] == '\t'
                                     || json[i] == '\n' || json[i] == '\r'))
                i++;
            if (is_field)
            {
                if (i >= json_len || json[i] != '"') return NULL;
                i++;
                size_t vstart = i;
                while (i < json_len)
                {
                    char vc = json[i];
                    if (vc == '\\') { i += 2; continue; }
                    if (vc == '"') break;
                    i++;
                }
                if (i >= json_len) return NULL;
                size_t vlen = i - vstart;
                char *result = palloc(vlen + 1);
                memcpy(result, json + vstart, vlen);
                result[vlen] = '\0';
                return result;
            }
            /* skip value */
            continue;
        }
        if (c == '{' || c == '[') depth++;
        if (c == '}' || c == ']') depth--;
        i++;
    }
    return NULL;
}

/* Fetch the public_jwk row for a given kid via SPI. Returns the
 * palloc'd alg + jwk_text + sets *found. Caller frees. */
static void
fetch_signing_key(const char *kid, char **out_alg, char **out_jwk, int *found)
{
    Oid    argtypes[1] = { TEXTOID };
    Datum  args[1];
    int    rc;
    HeapTuple row;
    TupleDesc tdesc;
    bool   isnull;

    *found  = 0;
    *out_alg = NULL;
    *out_jwk = NULL;

    args[0] = CStringGetTextDatum(kid);
    if (SPI_connect() != SPI_OK_CONNECT)
        ereport(ERROR,
                (errcode(ERRCODE_INTERNAL_ERROR),
                 errmsg("maludb_jwt_verify: SPI_connect failed")));
    rc = SPI_execute_with_args(
        "SELECT alg, public_jwk::text FROM maludb_core.malu$jwt_signing_key "
        "WHERE kid = $1 AND enabled = true LIMIT 1",
        1, argtypes, args, NULL, true, 1);
    if (rc != SPI_OK_SELECT)
    {
        SPI_finish();
        ereport(ERROR,
                (errcode(ERRCODE_INTERNAL_ERROR),
                 errmsg("maludb_jwt_verify: signing-key SPI failed: %d", rc)));
    }
    if (SPI_processed == 0)
    {
        SPI_finish();
        return;
    }

    row   = SPI_tuptable->vals[0];
    tdesc = SPI_tuptable->tupdesc;

    {
        MemoryContext oldcxt = MemoryContextSwitchTo(CurrentMemoryContext);
        Datum d_alg = SPI_getbinval(row, tdesc, 1, &isnull);
        if (!isnull)
        {
            text *t = (text *) PG_DETOAST_DATUM_COPY(d_alg);
            *out_alg = text_to_cstring(t);
            pfree(t);
        }
        Datum d_jwk = SPI_getbinval(row, tdesc, 2, &isnull);
        if (!isnull)
        {
            text *t = (text *) PG_DETOAST_DATUM_COPY(d_jwk);
            *out_jwk = text_to_cstring(t);
            pfree(t);
        }
        MemoryContextSwitchTo(oldcxt);
    }
    *found = 1;
    SPI_finish();
}

/* Push a single claim row into the SRF tuplestore. The caller is
 * responsible for having set up the ReturnSetInfo / per-call context;
 * we just BuildTupleFromCStrings against the bless'd tdesc and stash
 * it. */
static void
emit_claim_row(FunctionCallInfo fcinfo, const char *payload, size_t payload_len)
{
    ReturnSetInfo *rsi = (ReturnSetInfo *) fcinfo->resultinfo;
    TupleDesc      tdesc;
    AttInMetadata *attinmeta;
    HeapTuple      tup;
    char          *values[5];

    if (rsi == NULL || !IsA(rsi, ReturnSetInfo)
        || (rsi->allowedModes & SFRM_Materialize) == 0)
        ereport(ERROR,
                (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
                 errmsg("maludb_jwt_verify: materialize-mode caller required")));

    if (get_call_result_type(fcinfo, NULL, &tdesc) != TYPEFUNC_COMPOSITE)
        ereport(ERROR,
                (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
                 errmsg("maludb_jwt_verify: function must be called in a context that accepts a record")));
    tdesc = BlessTupleDesc(tdesc);

    {
        MemoryContext per_query  = rsi->econtext->ecxt_per_query_memory;
        MemoryContext oldcxt     = MemoryContextSwitchTo(per_query);
        Tuplestorestate *tstore  = tuplestore_begin_heap(true, false, work_mem);
        MemoryContextSwitchTo(oldcxt);

        values[0] = json_get_string(payload, payload_len, "account_id");
        values[1] = json_get_string(payload, payload_len, "role_name");
        values[2] = json_get_string(payload, payload_len, "owner_schema");
        values[3] = json_get_string(payload, payload_len, "active_pool");
        /* agent_chain is an array; we surface NULL until the array path
         * is implemented (the schema accepts NULL). */
        values[4] = NULL;

        attinmeta = TupleDescGetAttInMetadata(tdesc);
        tup       = BuildTupleFromCStrings(attinmeta, values);
        tuplestore_puttuple(tstore, tup);

        rsi->returnMode = SFRM_Materialize;
        rsi->setResult  = tstore;
        rsi->setDesc    = tdesc;
    }
}

Datum
maludb_jwt_verify(PG_FUNCTION_ARGS)
{
    text *jwt_arg = PG_GETARG_TEXT_PP(0);
    const char *jwt = VARDATA_ANY(jwt_arg);
    size_t      jwt_len = VARSIZE_ANY_EXHDR(jwt_arg);
    size_t      h_off, h_len, p_off, p_len, s_off, s_len;
    char       *header_json = NULL, *alg = NULL, *kid = NULL, *jwk = NULL;
    unsigned char *header_bytes = NULL;
    unsigned char *payload_bytes = NULL;
    unsigned char *sig_bytes = NULL;
    size_t      header_dlen = 0, payload_dlen = 0, sig_dlen = 0;
    int         found = 0;

    if (jwt_split(jwt, jwt_len, &h_off, &h_len, &p_off, &p_len, &s_off, &s_len) != 0)
        ereport(ERROR,
                (errcode(ERRCODE_INVALID_PARAMETER_VALUE),
                 errmsg("maludb_jwt_verify: malformed JWT (expected three dot-separated segments)")));

    header_bytes  = b64url_decode(jwt + h_off, h_len, &header_dlen);
    payload_bytes = b64url_decode(jwt + p_off, p_len, &payload_dlen);
    sig_bytes     = b64url_decode(jwt + s_off, s_len, &sig_dlen);
    if (!header_bytes || !payload_bytes || !sig_bytes)
        ereport(ERROR,
                (errcode(ERRCODE_INVALID_PARAMETER_VALUE),
                 errmsg("maludb_jwt_verify: base64url decode failed")));

    header_json = palloc(header_dlen + 1);
    memcpy(header_json, header_bytes, header_dlen);
    header_json[header_dlen] = '\0';

    alg = json_get_string(header_json, header_dlen, "alg");
    kid = json_get_string(header_json, header_dlen, "kid");
    if (!alg)
        ereport(ERROR,
                (errcode(ERRCODE_INVALID_PARAMETER_VALUE),
                 errmsg("maludb_jwt_verify: header missing 'alg'")));
    if (!kid)
        ereport(ERROR,
                (errcode(ERRCODE_INVALID_PARAMETER_VALUE),
                 errmsg("maludb_jwt_verify: header missing 'kid'")));

    fetch_signing_key(kid, &alg /* may differ — we trust header for selection */, &jwk, &found);
    if (!found)
        ereport(ERROR,
                (errcode(ERRCODE_INVALID_PARAMETER_VALUE),
                 errmsg("maludb_jwt_verify: signing key '%s' not registered or disabled", kid)));

    /* Re-read alg from header (the SPI call clobbered it above with the
     * stored alg). We need both: header_alg for what was signed, and
     * the registered alg for what the operator authorised. They must
     * match. */
    {
        char *header_alg = json_get_string(header_json, header_dlen, "alg");
        if (!header_alg || !alg || strcmp(header_alg, alg) != 0)
            ereport(ERROR,
                    (errcode(ERRCODE_INVALID_PARAMETER_VALUE),
                     errmsg("maludb_jwt_verify: header.alg=%s does not match registered alg=%s for kid=%s",
                            header_alg ? header_alg : "?", alg ? alg : "?", kid)));
        pfree(header_alg);
    }

    /* HS256: derive the secret from the JWK 'k' (base64url-encoded), HMAC-SHA256
     * over the signed input, constant-time compare against sig_bytes. */
    if (strcmp(alg, "HS256") == 0)
    {
        char *k_b64 = json_get_string(jwk, strlen(jwk), "k");
        if (!k_b64)
            ereport(ERROR,
                    (errcode(ERRCODE_INVALID_PARAMETER_VALUE),
                     errmsg("maludb_jwt_verify: HS256 JWK missing 'k'")));
        size_t k_len = 0;
        unsigned char *k = b64url_decode(k_b64, strlen(k_b64), &k_len);
        if (!k)
            ereport(ERROR,
                    (errcode(ERRCODE_INVALID_PARAMETER_VALUE),
                     errmsg("maludb_jwt_verify: HS256 JWK 'k' is not valid base64url")));

        /* Signed input = header_b64url || '.' || payload_b64url */
        size_t signed_len = h_len + 1 + p_len;
        unsigned char *signed_input = palloc(signed_len);
        memcpy(signed_input, jwt + h_off, h_len);
        signed_input[h_len] = '.';
        memcpy(signed_input + h_len + 1, jwt + p_off, p_len);

        unsigned char mac[SHA256_DIGEST_LENGTH];
        unsigned int  maclen = sizeof(mac);
        if (HMAC(EVP_sha256(), k, k_len, signed_input, signed_len, mac, &maclen) == NULL)
            ereport(ERROR,
                    (errcode(ERRCODE_INTERNAL_ERROR),
                     errmsg("maludb_jwt_verify: HMAC failed")));

        if (sig_dlen != maclen || !ct_eq(mac, sig_bytes, maclen))
            ereport(ERROR,
                    (errcode(ERRCODE_INVALID_PARAMETER_VALUE),
                     errmsg("maludb_jwt_verify: HS256 signature mismatch")));

        char *payload_text = palloc(payload_dlen + 1);
        memcpy(payload_text, payload_bytes, payload_dlen);
        payload_text[payload_dlen] = '\0';
        emit_claim_row(fcinfo, payload_text, payload_dlen);
        PG_RETURN_NULL();
    }

    /* RS/ES/EdDSA: the OpenSSL EVP API + JWK->EVP_PKEY decode is a
     * larger lift; the verifier dispatch is in place but the actual
     * signature check ships in V3-AUTH-03. Surface a feature-not-
     * supported error rather than silently accepting. */
    ereport(ERROR,
            (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
             errmsg("maludb_jwt_verify: algorithm %s is not yet implemented (HS256 only in 0.63.0)", alg),
             errhint("Asymmetric JWT algorithms (RS256/RS384/RS512/ES256/ES384/ES512/EdDSA) land in V3-AUTH-03; use HS256 or an opaque token via auth_token_verify until then.")));

    PG_RETURN_NULL();
}
