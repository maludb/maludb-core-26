/*
 * libmaludb implementation. See ../include/maludb.h for the public
 * contract.
 */

#include "maludb.h"

#include <libpq-fe.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdint.h>
#include <inttypes.h>

/* ------------------------------------------------------------------ */
/* Handle                                                              */
/* ------------------------------------------------------------------ */
struct maludb_s {
    PGconn          *conn;
    maludb_errcode_t last_code;
    char            *last_message;
};

/* ------------------------------------------------------------------ */
/* helpers                                                             */
/* ------------------------------------------------------------------ */

static char *xstrdup_or_null(const char *s)
{
    if (!s) return NULL;
    size_t n = strlen(s);
    char *p = malloc(n + 1);
    if (!p) return NULL;
    memcpy(p, s, n + 1);
    return p;
}

static maludb_errcode_t sqlstate_to_errcode(const char *sqlstate)
{
    if (!sqlstate) return MALUDB_ERR_GENERIC;
    if (!strcmp(sqlstate, "P0002") || !strcmp(sqlstate, "02000"))
        return MALUDB_ERR_NOT_FOUND;
    if (!strcmp(sqlstate, "22023") || !strcmp(sqlstate, "22P02"))
        return MALUDB_ERR_INVALID_PARAMETER;
    if (!strcmp(sqlstate, "55000"))
        return MALUDB_ERR_OBJECT_NOT_IN_STATE;
    if (!strcmp(sqlstate, "23514"))
        return MALUDB_ERR_CHECK_VIOLATION;
    if (!strcmp(sqlstate, "42501"))
        return MALUDB_ERR_PERMISSION_DENIED;
    return MALUDB_ERR_GENERIC;
}

static void set_error(maludb_t *m, maludb_errcode_t code, const char *fmt, ...)
{
    free(m->last_message);
    m->last_code = code;
    char buf[1024];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    m->last_message = xstrdup_or_null(buf);
}

static void set_error_from_result(maludb_t *m, PGresult *r)
{
    const char *sqlstate = PQresultErrorField(r, PG_DIAG_SQLSTATE);
    const char *msg = PQresultErrorMessage(r);
    set_error(m, sqlstate_to_errcode(sqlstate),
        "%s%s%s",
        sqlstate ? sqlstate : "00000",
        msg ? ": " : "",
        msg ? msg : "");
}

/*
 * Execute a SQL with text-format params, return the PGresult on
 * tuples-ok / command-ok. On failure, set_error and return NULL.
 */
static PGresult *exec_params(
    maludb_t          *m,
    const char        *sql,
    int                n,
    const char *const *values)
{
    PGresult *r = PQexecParams(m->conn, sql, n, NULL, values, NULL, NULL, 0);
    ExecStatusType s = PQresultStatus(r);
    if (s != PGRES_TUPLES_OK && s != PGRES_COMMAND_OK) {
        set_error_from_result(m, r);
        PQclear(r);
        return NULL;
    }
    return r;
}

/* Pull a single int64 scalar from row 0 col 0. */
static int scalar_int64(maludb_t *m, PGresult *r, int64_t *out)
{
    if (PQnfields(r) < 1 || PQntuples(r) < 1 || PQgetisnull(r, 0, 0)) {
        set_error(m, MALUDB_ERR_GENERIC, "scalar_int64: empty result");
        return -1;
    }
    *out = (int64_t)strtoll(PQgetvalue(r, 0, 0), NULL, 10);
    return 0;
}

static char *scalar_string(PGresult *r)
{
    if (PQnfields(r) < 1 || PQntuples(r) < 1 || PQgetisnull(r, 0, 0))
        return NULL;
    return xstrdup_or_null(PQgetvalue(r, 0, 0));
}

/* Build a Postgres-array literal from a NUL-terminated string list,
 * suitable for ::text[] cast. Caller frees. */
static char *text_array_literal(const char *const *items)
{
    if (!items) {
        return xstrdup_or_null("{claim,fact,memory,episode_object}");
    }
    size_t n = 0, total = 2; /* {} */
    for (const char *const *p = items; *p; ++p) { n++; total += strlen(*p) + 1; }
    if (n == 0) return xstrdup_or_null("{}");
    char *buf = malloc(total + n);
    if (!buf) return NULL;
    char *w = buf;
    *w++ = '{';
    for (size_t i = 0; i < n; ++i) {
        if (i > 0) *w++ = ',';
        size_t len = strlen(items[i]);
        memcpy(w, items[i], len);
        w += len;
    }
    *w++ = '}';
    *w = '\0';
    return buf;
}

static char *int64_array_literal(const int64_t *ids, size_t count)
{
    /* worst case: each int64 prints in 21 chars (sign + 20 digits) plus comma */
    size_t cap = 2 + count * 22;
    char *buf = malloc(cap);
    if (!buf) return NULL;
    char *w = buf;
    *w++ = '{';
    for (size_t i = 0; i < count; ++i) {
        if (i > 0) *w++ = ',';
        w += snprintf(w, cap - (size_t)(w - buf), "%" PRId64, ids[i]);
    }
    *w++ = '}';
    *w = '\0';
    return buf;
}

/* ------------------------------------------------------------------ */
/* Connection lifecycle                                                */
/* ------------------------------------------------------------------ */
static int set_search_path(maludb_t *m, const char *schema)
{
    PGresult *r = NULL;
    if (schema && *schema) {
        char *quoted = PQescapeIdentifier(m->conn, schema, strlen(schema));
        if (!quoted) {
            set_error(m, MALUDB_ERR_GENERIC, "quote schema identifier failed");
            return -1;
        }
        const char *suffix = ", maludb_core, public";
        size_t sql_len = strlen("SET search_path = ") + strlen(quoted) + strlen(suffix) + 1;
        char *sql = malloc(sql_len);
        if (!sql) {
            PQfreemem(quoted);
            set_error(m, MALUDB_ERR_GENERIC, "set_search_path: out of memory");
            return -1;
        }
        snprintf(sql, sql_len, "SET search_path = %s%s", quoted, suffix);
        r = PQexec(m->conn, sql);
        free(sql);
        PQfreemem(quoted);
    } else {
        r = PQexec(m->conn, "SET search_path = maludb_core, public");
    }
    if (!r) {
        set_error(m, MALUDB_ERR_GENERIC, "set_search_path: command failed");
        return -1;
    }
    if (PQresultStatus(r) != PGRES_COMMAND_OK) {
        set_error_from_result(m, r);
        PQclear(r);
        return -1;
    }
    PQclear(r);
    m->last_code = MALUDB_OK;
    return 0;
}

maludb_t *maludb_connect_schema(const char *dsn, const char *schema)
{
    maludb_t *m = calloc(1, sizeof *m);
    if (!m) return NULL;
    m->conn = PQconnectdb(dsn ? dsn : "");
    if (PQstatus(m->conn) != CONNECTION_OK) {
        set_error(m, MALUDB_ERR_CONNECT, "%s", PQerrorMessage(m->conn));
        return m; /* caller checks last_error_code */
    }
    (void)set_search_path(m, schema);
    return m;
}

maludb_t *maludb_connect(const char *dsn)
{
    return maludb_connect_schema(dsn, NULL);
}

void maludb_close(maludb_t *m)
{
    if (!m) return;
    if (m->conn) PQfinish(m->conn);
    free(m->last_message);
    free(m);
}

maludb_errcode_t maludb_last_error_code(const maludb_t *m)
{
    return m ? m->last_code : MALUDB_ERR_GENERIC;
}

const char *maludb_last_error_message(const maludb_t *m)
{
    return (m && m->last_message) ? m->last_message : "";
}

/* ------------------------------------------------------------------ */
/* version                                                             */
/* ------------------------------------------------------------------ */
char *maludb_version(maludb_t *m)
{
    if (!m || PQstatus(m->conn) != CONNECTION_OK) return NULL;
    PGresult *r = exec_params(m, "SELECT maludb_core_version()", 0, NULL);
    if (!r) return NULL;
    char *out = scalar_string(r);
    PQclear(r);
    if (!out) set_error(m, MALUDB_ERR_GENERIC, "version: empty result");
    else m->last_code = MALUDB_OK;
    return out;
}

char *maludb_search_path(maludb_t *m)
{
    if (!m || PQstatus(m->conn) != CONNECTION_OK) return NULL;
    PGresult *r = exec_params(m, "SHOW search_path", 0, NULL);
    if (!r) return NULL;
    char *out = scalar_string(r);
    PQclear(r);
    if (!out) set_error(m, MALUDB_ERR_GENERIC, "search_path: empty result");
    else m->last_code = MALUDB_OK;
    return out;
}

/* ------------------------------------------------------------------ */
/* Ingest helpers — each is a thin SQL wrapper that returns the new   */
/* id, or -1 on error.                                                */
/* ------------------------------------------------------------------ */

int64_t maludb_register_source_package(
    maludb_t *m, const char *source_type,
    const char *content_text, const char *origin_jsonb,
    const char *sensitivity)
{
    const char *params[3] = {
        source_type, content_text,
        sensitivity ? sensitivity : "internal"
    };
    const char *sql =
        "SELECT register_source_package("
        "  p_source_type   => $1,"
        "  p_content_text  => $2,"
        "  p_origin_jsonb  => NULLIF($3,'')::jsonb,"
        "  p_sensitivity   => $4)";
    const char *params4[4] = {
        source_type, content_text, origin_jsonb ? origin_jsonb : "",
        sensitivity ? sensitivity : "internal"
    };
    PGresult *r = exec_params(m, sql, 4, params4);
    (void)params; /* silence unused if any */
    if (!r) return -1;
    int64_t out;
    int rc = scalar_int64(m, r, &out);
    PQclear(r);
    if (rc < 0) return -1;
    m->last_code = MALUDB_OK;
    return out;
}

int64_t maludb_register_claim(
    maludb_t *m, const char *subject, const char *verb,
    const char *object_value, const char *statement_text,
    int64_t source_package_id, const char *sensitivity)
{
    char sp_buf[32];
    const char *sp_str = NULL;
    if (source_package_id > 0) {
        snprintf(sp_buf, sizeof sp_buf, "%" PRId64, source_package_id);
        sp_str = sp_buf;
    }
    const char *params[6] = {
        subject, verb, object_value, statement_text,
        sp_str, sensitivity ? sensitivity : "internal"
    };
    const char *sql =
        "SELECT register_claim("
        "  p_subject => $1, p_verb => $2,"
        "  p_object_value => $3, p_statement_text => $4,"
        "  p_source_package_id => $5::bigint,"
        "  p_sensitivity => $6)";
    PGresult *r = exec_params(m, sql, 6, params);
    if (!r) return -1;
    int64_t out;
    int rc = scalar_int64(m, r, &out);
    PQclear(r);
    if (rc < 0) return -1;
    m->last_code = MALUDB_OK;
    return out;
}

int64_t maludb_register_fact(
    maludb_t *m, const int64_t *claim_ids, size_t claim_count,
    const char *subject, const char *verb, const char *object_value,
    const char *statement_text, const char *verification_method,
    const char *sensitivity)
{
    char *arr = int64_array_literal(claim_ids, claim_count);
    if (!arr) { set_error(m, MALUDB_ERR_GENERIC, "alloc failed"); return -1; }
    const char *params[7] = {
        arr, subject, verb, object_value, statement_text,
        verification_method, sensitivity ? sensitivity : "internal"
    };
    const char *sql =
        "SELECT register_fact("
        "  p_claim_ids => $1::bigint[],"
        "  p_subject => $2, p_verb => $3,"
        "  p_object_value => $4, p_statement_text => $5,"
        "  p_verification_method => $6,"
        "  p_sensitivity => $7)";
    PGresult *r = exec_params(m, sql, 7, params);
    free(arr);
    if (!r) return -1;
    int64_t out;
    int rc = scalar_int64(m, r, &out);
    PQclear(r);
    if (rc < 0) return -1;
    m->last_code = MALUDB_OK;
    return out;
}

int64_t maludb_register_memory(
    maludb_t *m, const char *memory_kind, const char *title,
    const char *summary, const char *payload_jsonb,
    const char *sensitivity)
{
    const char *params[5] = {
        memory_kind, title, summary,
        payload_jsonb ? payload_jsonb : "{}",
        sensitivity ? sensitivity : "internal"
    };
    const char *sql =
        "SELECT register_memory("
        "  p_memory_kind => $1, p_title => $2, p_summary => $3,"
        "  p_payload_jsonb => $4::jsonb,"
        "  p_sensitivity => $5)";
    PGresult *r = exec_params(m, sql, 5, params);
    if (!r) return -1;
    int64_t out;
    int rc = scalar_int64(m, r, &out);
    PQclear(r);
    if (rc < 0) return -1;
    m->last_code = MALUDB_OK;
    return out;
}

int64_t maludb_register_episode(
    maludb_t *m, const char *episode_kind, const char *title,
    const char *summary, const char *payload_jsonb,
    const char *sensitivity)
{
    const char *params[5] = {
        episode_kind, title, summary,
        payload_jsonb ? payload_jsonb : "{}",
        sensitivity ? sensitivity : "internal"
    };
    const char *sql =
        "SELECT register_episode("
        "  p_episode_kind => $1, p_title => $2, p_summary => $3,"
        "  p_payload_jsonb => $4::jsonb,"
        "  p_sensitivity => $5)";
    PGresult *r = exec_params(m, sql, 5, params);
    if (!r) return -1;
    int64_t out;
    int rc = scalar_int64(m, r, &out);
    PQclear(r);
    if (rc < 0) return -1;
    m->last_code = MALUDB_OK;
    return out;
}

/* ------------------------------------------------------------------ */
/* Retrieve                                                            */
/* ------------------------------------------------------------------ */

int maludb_text_search(
    maludb_t *m, const char *query, const char *const *object_types,
    int limit, maludb_source_hit_t **out_hits, size_t *out_count)
{
    *out_hits = NULL;
    *out_count = 0;
    char *types = text_array_literal(object_types);
    if (!types) { set_error(m, MALUDB_ERR_GENERIC, "alloc failed"); return -1; }
    char lim[16];
    snprintf(lim, sizeof lim, "%d", limit);
    const char *params[3] = { query, types, lim };
    const char *sql =
        "SELECT object_type, object_id, title_or_subject, snippet,"
        "       rank::float8::text AS rank "
        "FROM text_search($1, $2::text[], $3::int)";
    PGresult *r = exec_params(m, sql, 3, params);
    free(types);
    if (!r) return -1;

    int n = PQntuples(r);
    maludb_source_hit_t *hits = calloc((size_t)n, sizeof *hits);
    if (n > 0 && !hits) {
        PQclear(r);
        set_error(m, MALUDB_ERR_GENERIC, "alloc failed");
        return -1;
    }
    for (int i = 0; i < n; ++i) {
        hits[i].object_type      = xstrdup_or_null(PQgetvalue(r, i, 0));
        hits[i].object_id        = (int64_t)strtoll(PQgetvalue(r, i, 1), NULL, 10);
        hits[i].title_or_subject = PQgetisnull(r, i, 2) ? NULL : xstrdup_or_null(PQgetvalue(r, i, 2));
        hits[i].snippet          = PQgetisnull(r, i, 3) ? NULL : xstrdup_or_null(PQgetvalue(r, i, 3));
        hits[i].rank             = strtod(PQgetvalue(r, i, 4), NULL);
    }
    PQclear(r);
    *out_hits = hits;
    *out_count = (size_t)n;
    m->last_code = MALUDB_OK;
    return 0;
}

void maludb_free_source_hits(maludb_source_hit_t *hits, size_t count)
{
    if (!hits) return;
    for (size_t i = 0; i < count; ++i) {
        free(hits[i].object_type);
        free(hits[i].title_or_subject);
        free(hits[i].snippet);
    }
    free(hits);
}

int maludb_retrieve(
    maludb_t *m, const char *cue_text, const char *const *object_types,
    int limit, maludb_retrieval_hit_t **out_hits, size_t *out_count)
{
    *out_hits = NULL;
    *out_count = 0;
    char *types = text_array_literal(object_types);
    if (!types) { set_error(m, MALUDB_ERR_GENERIC, "alloc failed"); return -1; }
    char lim[16];
    snprintf(lim, sizeof lim, "%d", limit);
    const char *params[3] = { cue_text, types, lim };
    const char *sql =
        "SELECT object_type, object_id, title, snippet,"
        "       rank::float8::text AS rank, strategy, metadata::text "
        "FROM execute_retrieval("
        "  ROW($1, $2::text[], NULL::timestamptz, NULL::timestamptz, "
        "      NULL::numeric, NULL)::maludb_core.malu$retrieval_envelope_t,"
        "  NULL, $3::int)";
    PGresult *r = exec_params(m, sql, 3, params);
    free(types);
    if (!r) return -1;

    int n = PQntuples(r);
    maludb_retrieval_hit_t *hits = calloc((size_t)n, sizeof *hits);
    if (n > 0 && !hits) {
        PQclear(r);
        set_error(m, MALUDB_ERR_GENERIC, "alloc failed");
        return -1;
    }
    for (int i = 0; i < n; ++i) {
        hits[i].object_type    = xstrdup_or_null(PQgetvalue(r, i, 0));
        hits[i].object_id      = (int64_t)strtoll(PQgetvalue(r, i, 1), NULL, 10);
        hits[i].title          = PQgetisnull(r, i, 2) ? NULL : xstrdup_or_null(PQgetvalue(r, i, 2));
        hits[i].snippet        = PQgetisnull(r, i, 3) ? NULL : xstrdup_or_null(PQgetvalue(r, i, 3));
        hits[i].rank           = strtod(PQgetvalue(r, i, 4), NULL);
        hits[i].strategy       = xstrdup_or_null(PQgetvalue(r, i, 5));
        hits[i].metadata_jsonb = PQgetisnull(r, i, 6) ? NULL : xstrdup_or_null(PQgetvalue(r, i, 6));
    }
    PQclear(r);
    *out_hits = hits;
    *out_count = (size_t)n;
    m->last_code = MALUDB_OK;
    return 0;
}

void maludb_free_retrieval_hits(maludb_retrieval_hit_t *hits, size_t count)
{
    if (!hits) return;
    for (size_t i = 0; i < count; ++i) {
        free(hits[i].object_type);
        free(hits[i].title);
        free(hits[i].snippet);
        free(hits[i].strategy);
        free(hits[i].metadata_jsonb);
    }
    free(hits);
}

/* ------------------------------------------------------------------ */
/* Replay                                                              */
/* ------------------------------------------------------------------ */
char *maludb_replay_episode(maludb_t *m, int64_t episode_id, const char *mode)
{
    char idbuf[32];
    snprintf(idbuf, sizeof idbuf, "%" PRId64, episode_id);
    const char *params[2] = { idbuf, mode ? mode : "current_valid" };
    const char *sql = "SELECT replay_episode($1::bigint, $2)::text";
    PGresult *r = exec_params(m, sql, 2, params);
    if (!r) return NULL;
    char *out = scalar_string(r);
    PQclear(r);
    if (!out) set_error(m, MALUDB_ERR_GENERIC, "replay_episode: empty result");
    else m->last_code = MALUDB_OK;
    return out;
}

/* ==================================================================
 * V3-SDK-01 (v0.2.0) — pool / skill / node wrappers.
 * ================================================================== */

/* helpers for the v0.2.0 wrappers ------------------------------------ */

static char *int64_or_null(int64_t v)
{
    if (v == 0) return xstrdup_or_null(NULL);
    char buf[32];
    snprintf(buf, sizeof buf, "%" PRId64, v);
    return xstrdup_or_null(buf);
}

static char *int_str_or_null(int v)
{
    if (v <= 0) return xstrdup_or_null(NULL);
    char buf[32];
    snprintf(buf, sizeof buf, "%d", v);
    return xstrdup_or_null(buf);
}

static char *double_str_or_null(double v)
{
    if (v < 0) return xstrdup_or_null(NULL);
    char buf[64];
    snprintf(buf, sizeof buf, "%.6f", v);
    return xstrdup_or_null(buf);
}

/* Like exec_params but returns int64 scalar; -1 on failure. */
static int64_t exec_scalar_int64(
    maludb_t          *m,
    const char        *sql,
    int                n,
    const char *const *values)
{
    PGresult *r = exec_params(m, sql, n, values);
    if (!r) return -1;
    int64_t out = 0;
    int rc = scalar_int64(m, r, &out);
    PQclear(r);
    if (rc != 0) return -1;
    m->last_code = MALUDB_OK;
    return out;
}

/* ----- Active memory pools ----------------------------------------- */

int64_t maludb_pool_create(
    maludb_t *m,
    const char *pool_name,
    const char *creation_kind,
    const char *task_objective,
    const char *const *authorized_partitions,
    int max_member_count)
{
    if (!pool_name) {
        set_error(m, MALUDB_ERR_INVALID_PARAMETER, "pool_create: pool_name required");
        return -1;
    }
    char *parts_lit = NULL;
    if (authorized_partitions) {
        parts_lit = text_array_literal(authorized_partitions);
    }
    char *max_str = int_str_or_null(max_member_count);
    const char *params[5] = {
        pool_name,
        creation_kind,
        task_objective,
        parts_lit,
        max_str,
    };
    const char *sql =
        "SELECT create_active_memory_pool("
        "  $1, "
        "  COALESCE($2, 'sql'), "
        "  $3, "
        "  CASE WHEN $4::text IS NULL THEN NULL ELSE $4::text[] END, "
        "  NULL::numeric, NULL::timestamptz, NULL::timestamptz, "
        "  CASE WHEN $5::text IS NULL THEN NULL ELSE $5::integer END"
        ")";
    int64_t pid = exec_scalar_int64(m, sql, 5, params);
    free(parts_lit); free(max_str);
    return pid;
}

int64_t maludb_pool_add_observation(
    maludb_t *m, int64_t pool_id,
    const char *payload_jsonb, double confidence,
    const char *provenance_jsonb, const char *access_label,
    int64_t account_id)
{
    if (!payload_jsonb) {
        set_error(m, MALUDB_ERR_INVALID_PARAMETER, "pool_add_observation: payload_jsonb required");
        return -1;
    }
    char idbuf[32]; snprintf(idbuf, sizeof idbuf, "%" PRId64, pool_id);
    char *conf_str = double_str_or_null(confidence);
    char *acct_str = int64_or_null(account_id);
    const char *params[6] = {
        idbuf, payload_jsonb, conf_str, provenance_jsonb, access_label, acct_str,
    };
    const char *sql =
        "SELECT pool_add_observation("
        "  $1::bigint, $2::jsonb, "
        "  CASE WHEN $3::text IS NULL THEN NULL ELSE $3::numeric END, "
        "  CASE WHEN $4::text IS NULL THEN NULL ELSE $4::jsonb END, "
        "  $5, "
        "  CASE WHEN $6::text IS NULL THEN NULL ELSE $6::bigint END"
        ")";
    int64_t oid = exec_scalar_int64(m, sql, 6, params);
    free(conf_str); free(acct_str);
    return oid;
}

int64_t maludb_pool_promote_to_claim(
    maludb_t *m, int64_t member_id,
    const char *subject, const char *verb,
    const char *object_value, const char *statement_text,
    const char *sensitivity)
{
    char idbuf[32]; snprintf(idbuf, sizeof idbuf, "%" PRId64, member_id);
    const char *params[6] = {
        idbuf, subject, verb, object_value, statement_text,
        sensitivity ? sensitivity : "internal",
    };
    const char *sql =
        "SELECT pool_promote_to_claim($1::bigint, $2, $3, $4, $5, $6)";
    return exec_scalar_int64(m, sql, 6, params);
}

/* ----- Skill runtime ----------------------------------------------- */

int64_t maludb_skill_register(
    maludb_t *m,
    const char *skill_name, const char *version,
    const char *description, const char *packaging_kind,
    const char *applicability_jsonb, const char *precondition_jsonb)
{
    if (!skill_name) {
        set_error(m, MALUDB_ERR_INVALID_PARAMETER, "skill_register: skill_name required");
        return -1;
    }
    const char *params[6] = {
        skill_name,
        version       ? version       : "1.0.0",
        description,
        packaging_kind ? packaging_kind : "markdown",
        applicability_jsonb ? applicability_jsonb : "{}",
        precondition_jsonb  ? precondition_jsonb  : "[]",
    };
    const char *sql =
        "SELECT register_skill($1, $2, $3, $4, $5::jsonb, $6::jsonb)";
    return exec_scalar_int64(m, sql, 6, params);
}

int64_t maludb_skill_add_state(
    maludb_t *m, int64_t skill_id,
    const char *state_name, const char *state_kind,
    const char *step_jsonb, const char *validation_jsonb)
{
    if (!state_name || !state_kind) {
        set_error(m, MALUDB_ERR_INVALID_PARAMETER, "skill_add_state: name + kind required");
        return -1;
    }
    char idbuf[32]; snprintf(idbuf, sizeof idbuf, "%" PRId64, skill_id);
    const char *params[5] = {
        idbuf, state_name, state_kind, step_jsonb, validation_jsonb,
    };
    const char *sql =
        "SELECT add_skill_state("
        "  $1::bigint, $2, $3, "
        "  CASE WHEN $4::text IS NULL THEN NULL ELSE $4::jsonb END, "
        "  CASE WHEN $5::text IS NULL THEN NULL ELSE $5::jsonb END"
        ")";
    return exec_scalar_int64(m, sql, 5, params);
}

int64_t maludb_skill_add_transition(
    maludb_t *m, int64_t skill_id,
    const char *from_state, const char *to_state,
    const char *on_outcome, const char *guard_jsonb, int ordinal)
{
    if (!from_state || !to_state || !on_outcome) {
        set_error(m, MALUDB_ERR_INVALID_PARAMETER, "skill_add_transition: from/to/on_outcome required");
        return -1;
    }
    char idbuf[32]; snprintf(idbuf, sizeof idbuf, "%" PRId64, skill_id);
    char ordbuf[32]; snprintf(ordbuf, sizeof ordbuf, "%d", ordinal);
    const char *params[6] = {
        idbuf, from_state, to_state, on_outcome, guard_jsonb, ordbuf,
    };
    const char *sql =
        "SELECT add_skill_transition("
        "  $1::bigint, $2, $3, $4, "
        "  CASE WHEN $5::text IS NULL THEN NULL ELSE $5::jsonb END, "
        "  $6::integer"
        ")";
    return exec_scalar_int64(m, sql, 6, params);
}

int64_t maludb_skill_begin_execution(
    maludb_t *m, int64_t skill_id,
    const char *environment,
    const char *const *technology_stack,
    const char *task_objective,
    int64_t account_id, int64_t active_pool_id)
{
    char idbuf[32]; snprintf(idbuf, sizeof idbuf, "%" PRId64, skill_id);
    char *stack_lit = technology_stack ? text_array_literal(technology_stack) : NULL;
    char *acct_str  = int64_or_null(account_id);
    char *pool_str  = int64_or_null(active_pool_id);
    const char *params[6] = {
        idbuf, environment, stack_lit, task_objective, acct_str, pool_str,
    };
    const char *sql =
        "SELECT begin_skill_execution("
        "  $1::bigint, $2, "
        "  CASE WHEN $3::text IS NULL THEN NULL ELSE $3::text[] END, "
        "  $4, NULL::text[], "
        "  CASE WHEN $5::text IS NULL THEN NULL ELSE $5::bigint END, "
        "  CASE WHEN $6::text IS NULL THEN NULL ELSE $6::bigint END, "
        "  NULL::bigint"
        ")";
    int64_t eid = exec_scalar_int64(m, sql, 6, params);
    free(stack_lit); free(acct_str); free(pool_str);
    return eid;
}

char *maludb_skill_step_execution(
    maludb_t *m, int64_t execution_id,
    const char *outcome, const char *observation_jsonb)
{
    if (!outcome) {
        set_error(m, MALUDB_ERR_INVALID_PARAMETER, "skill_step_execution: outcome required");
        return NULL;
    }
    char idbuf[32]; snprintf(idbuf, sizeof idbuf, "%" PRId64, execution_id);
    const char *params[3] = { idbuf, outcome, observation_jsonb };
    const char *sql =
        "SELECT step_skill_execution("
        "  $1::bigint, $2, "
        "  CASE WHEN $3::text IS NULL THEN NULL ELSE $3::jsonb END"
        ")";
    PGresult *r = exec_params(m, sql, 3, params);
    if (!r) return NULL;
    char *out = scalar_string(r);
    PQclear(r);
    if (!out) set_error(m, MALUDB_ERR_GENERIC, "step_skill_execution: empty result");
    else m->last_code = MALUDB_OK;
    return out;
}

int maludb_skill_abort_execution(
    maludb_t *m, int64_t execution_id, const char *reason)
{
    char idbuf[32]; snprintf(idbuf, sizeof idbuf, "%" PRId64, execution_id);
    const char *params[2] = { idbuf, reason };
    PGresult *r = exec_params(m, "SELECT abort_skill_execution($1::bigint, $2)", 2, params);
    if (!r) return -1;
    PQclear(r);
    m->last_code = MALUDB_OK;
    return 0;
}

/* ----- Local memory nodes ------------------------------------------ */

int64_t maludb_node_register(
    maludb_t *m,
    const char *node_name, const char *fingerprint,
    const char *uri, const char *description)
{
    if (!node_name || !fingerprint) {
        set_error(m, MALUDB_ERR_INVALID_PARAMETER, "node_register: node_name + fingerprint required");
        return -1;
    }
    const char *params[4] = { node_name, fingerprint, uri, description };
    return exec_scalar_int64(m, "SELECT register_local_node($1, $2, $3, $4)", 4, params);
}

int64_t maludb_node_submit(
    maludb_t *m, int64_t node_id,
    const char *submission_kind, const char *payload_jsonb,
    int64_t local_id, const char *local_hash)
{
    if (!submission_kind || !payload_jsonb) {
        set_error(m, MALUDB_ERR_INVALID_PARAMETER, "node_submit: kind + payload required");
        return -1;
    }
    char idbuf[32]; snprintf(idbuf, sizeof idbuf, "%" PRId64, node_id);
    char *lid_str = int64_or_null(local_id);
    const char *params[5] = {
        idbuf, submission_kind, payload_jsonb, lid_str, local_hash,
    };
    const char *sql =
        "SELECT node_submit("
        "  $1::bigint, $2, $3::jsonb, "
        "  CASE WHEN $4::text IS NULL THEN NULL ELSE $4::bigint END, "
        "  $5"
        ")";
    int64_t sid = exec_scalar_int64(m, sql, 5, params);
    free(lid_str);
    return sid;
}

char *maludb_node_accept(maludb_t *m, int64_t submission_id, const char *reason)
{
    char idbuf[32]; snprintf(idbuf, sizeof idbuf, "%" PRId64, submission_id);
    const char *params[2] = { idbuf, reason };
    PGresult *r = exec_params(m, "SELECT node_accept($1::bigint, $2)::text", 2, params);
    if (!r) return NULL;
    char *out = scalar_string(r);
    PQclear(r);
    if (!out) set_error(m, MALUDB_ERR_GENERIC, "node_accept: empty result");
    else m->last_code = MALUDB_OK;
    return out;
}

int maludb_node_reject(maludb_t *m, int64_t submission_id, const char *reason)
{
    if (!reason) {
        set_error(m, MALUDB_ERR_INVALID_PARAMETER, "node_reject: reason required");
        return -1;
    }
    char idbuf[32]; snprintf(idbuf, sizeof idbuf, "%" PRId64, submission_id);
    const char *params[2] = { idbuf, reason };
    PGresult *r = exec_params(m, "SELECT node_reject($1::bigint, $2)", 2, params);
    if (!r) return -1;
    PQclear(r);
    m->last_code = MALUDB_OK;
    return 0;
}

/* ===== V4 PageIndex (alpha.5+) =================================== */

static char *int64_str_or_null(int64_t v)
{
    if (v <= 0) return xstrdup_or_null(NULL);
    char buf[32];
    snprintf(buf, sizeof buf, "%" PRId64, v);
    return xstrdup_or_null(buf);
}

int64_t maludb_pageindex_build(
    maludb_t *m,
    int64_t source_package_id,
    const char *parser_kind,
    int64_t model_alias_id,
    int64_t prompt_template_id,
    const char *builder_options_jsonb)
{
    if (source_package_id <= 0 || !parser_kind) {
        set_error(m, MALUDB_ERR_INVALID_PARAMETER,
                  "pageindex_build: source_package_id and parser_kind required");
        return -1;
    }
    char sp[32]; snprintf(sp, sizeof sp, "%" PRId64, source_package_id);
    char *ma = int64_str_or_null(model_alias_id);
    char *pt = int64_str_or_null(prompt_template_id);
    const char *params[5] = {
        sp, parser_kind, ma, pt,
        builder_options_jsonb ? builder_options_jsonb : "{}"
    };
    int64_t tid = exec_scalar_int64(m,
        "SELECT source_package_promote_to_page_index("
        "  $1::bigint, $2, "
        "  CASE WHEN $3::text IS NULL THEN NULL ELSE $3::bigint END, "
        "  CASE WHEN $4::text IS NULL THEN NULL ELSE $4::bigint END, "
        "  $5::jsonb)",
        5, params);
    free(ma); free(pt);
    return tid;
}

int64_t maludb_pageindex_supersede(
    maludb_t *m, int64_t prior_tree_id, int64_t new_tree_id)
{
    if (prior_tree_id <= 0 || new_tree_id <= 0) {
        set_error(m, MALUDB_ERR_INVALID_PARAMETER,
                  "pageindex_supersede: both tree ids required");
        return -1;
    }
    char a[32], b[32];
    snprintf(a, sizeof a, "%" PRId64, prior_tree_id);
    snprintf(b, sizeof b, "%" PRId64, new_tree_id);
    const char *params[2] = { a, b };
    return exec_scalar_int64(m,
        "SELECT page_index_tree_supersede($1::bigint, $2::bigint)",
        2, params);
}

char *maludb_pageindex_ask(
    maludb_t *m,
    const char *cue_text,
    int64_t tree_id,
    const char *descent_options_jsonb,
    int limit)
{
    if (!cue_text || tree_id <= 0) {
        set_error(m, MALUDB_ERR_INVALID_PARAMETER,
                  "pageindex_ask: cue_text and tree_id required");
        return NULL;
    }
    char tid[32]; snprintf(tid, sizeof tid, "%" PRId64, tree_id);
    char lim[16]; snprintf(lim, sizeof lim, "%d", limit > 0 ? limit : 1);
    const char *params[4] = {
        cue_text, tid,
        descent_options_jsonb ? descent_options_jsonb : "{}",
        lim
    };
    PGresult *r = exec_params(m,
        "SELECT row_to_json(t)::text FROM "
        "  retrieve_with_envelope_tree($1, $2::bigint, $3::jsonb, $4::integer) t",
        4, params);
    if (!r) return NULL;
    char *out = scalar_string(r);
    PQclear(r);
    if (!out) set_error(m, MALUDB_ERR_GENERIC, "pageindex_ask: empty result");
    else m->last_code = MALUDB_OK;
    return out;
}

/* ===== V4 ChatIndex (alpha.5+) =================================== */

int64_t maludb_chatindex_build(
    maludb_t *m,
    int64_t source_package_id,
    int64_t model_alias_id,
    int64_t prompt_template_id,
    int max_children,
    const char *builder_options_jsonb)
{
    if (source_package_id <= 0) {
        set_error(m, MALUDB_ERR_INVALID_PARAMETER,
                  "chatindex_build: source_package_id required");
        return -1;
    }
    char sp[32]; snprintf(sp, sizeof sp, "%" PRId64, source_package_id);
    char *ma = int64_str_or_null(model_alias_id);
    char *pt = int64_str_or_null(prompt_template_id);
    char mc[16];
    snprintf(mc, sizeof mc, "%d", max_children > 0 ? max_children : 10);
    const char *params[5] = {
        sp, ma, pt, mc,
        builder_options_jsonb ? builder_options_jsonb : "{}"
    };
    int64_t tid = exec_scalar_int64(m,
        "SELECT source_package_promote_to_chat_index("
        "  $1::bigint, "
        "  CASE WHEN $2::text IS NULL THEN NULL ELSE $2::bigint END, "
        "  CASE WHEN $3::text IS NULL THEN NULL ELSE $3::bigint END, "
        "  $4::integer, $5::jsonb)",
        5, params);
    free(ma); free(pt);
    return tid;
}

int maludb_chatindex_append(
    maludb_t *m, int64_t tree_id, const char *messages_jsonb)
{
    if (tree_id <= 0 || !messages_jsonb) {
        set_error(m, MALUDB_ERR_INVALID_PARAMETER,
                  "chatindex_append: tree_id and messages_jsonb required");
        return -1;
    }
    char tid[32]; snprintf(tid, sizeof tid, "%" PRId64, tree_id);
    const char *params[2] = { tid, messages_jsonb };
    PGresult *r = exec_params(m,
        "SELECT count(*) FROM chat_index_append_messages($1::bigint, $2::jsonb)",
        2, params);
    if (!r) return -1;
    PQclear(r);
    m->last_code = MALUDB_OK;
    return 0;
}

char *maludb_chatindex_ask(
    maludb_t *m,
    const char *cue_text,
    int64_t chat_tree_id,
    const char *descent_options_jsonb,
    int limit)
{
    if (!cue_text || chat_tree_id <= 0) {
        set_error(m, MALUDB_ERR_INVALID_PARAMETER,
                  "chatindex_ask: cue_text and chat_tree_id required");
        return NULL;
    }
    char tid[32]; snprintf(tid, sizeof tid, "%" PRId64, chat_tree_id);
    char lim[16]; snprintf(lim, sizeof lim, "%d", limit > 0 ? limit : 1);
    const char *params[4] = {
        cue_text, tid,
        descent_options_jsonb ? descent_options_jsonb : "{}",
        lim
    };
    PGresult *r = exec_params(m,
        "SELECT row_to_json(t)::text FROM "
        "  retrieve_with_envelope_chat_tree($1, $2::bigint, $3::jsonb, $4::integer) t",
        4, params);
    if (!r) return NULL;
    char *out = scalar_string(r);
    PQclear(r);
    if (!out) set_error(m, MALUDB_ERR_GENERIC, "chatindex_ask: empty result");
    else m->last_code = MALUDB_OK;
    return out;
}
