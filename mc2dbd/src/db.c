/* mc2dbd PG access layer. R1.0-7. */

#include "db.h"

#include <fcntl.h>
#include <unistd.h>
#include <stdarg.h>

PGconn *db_open(const mc2dbd_config *cfg)
{
    PGconn *c = PQconnectdb(cfg->pg_conninfo ? cfg->pg_conninfo : "");
    if (PQstatus(c) != CONNECTION_OK) {
        LOG_ERROR("PG connect failed: %s", PQerrorMessage(c));
        PQfinish(c);
        return NULL;
    }
    /* Pin search_path defensively. The mc2db schema holds the public
     * APIs; maludb_core holds the malu$ catalog tables. */
    PGresult *r = PQexec(c, "SET search_path TO maludb_core, mc2db, public");
    if (PQresultStatus(r) != PGRES_COMMAND_OK) {
        LOG_ERROR("SET search_path failed: %s", PQresultErrorMessage(r));
        PQclear(r);
        PQfinish(c);
        return NULL;
    }
    PQclear(r);
    return c;
}

void db_close(PGconn *conn) { if (conn) PQfinish(conn); }

static void copy_err(char *buf, size_t sz, PGresult *r, const char *fallback)
{
    if (!buf || !sz) return;
    const char *m = r ? PQresultErrorMessage(r) : NULL;
    if (!m || !*m) m = fallback ? fallback : "PG error";
    snprintf(buf, sz, "%s", m);
    /* trim trailing newline psql tends to add */
    size_t n = strlen(buf);
    while (n && (buf[n-1] == '\n' || buf[n-1] == '\r')) buf[--n] = 0;
}

json_t *db_tools_list(PGconn *conn, char *err_buf, size_t errsz)
{
    /* All authorized tools across every implementation_type. R1.0
     * authorization filter is "enabled = true"; per-account ACLs land
     * in R1.1-7. */
    const char *sql =
        "SELECT t.tool_id, t.tool_name, t.title, t.description, "
        "       t.implementation_type, "
        "       COALESCE(t.input_schema,  '{}'::jsonb) AS input_schema, "
        "       COALESCE(t.output_schema, 'null'::jsonb) AS output_schema "
        "FROM maludb_core.malu$mc2db_tool t "
        "WHERE t.enabled = true "
        "ORDER BY t.tool_name";
    PGresult *r = PQexec(conn, sql);
    if (PQresultStatus(r) != PGRES_TUPLES_OK) {
        copy_err(err_buf, errsz, r, "tools/list query failed");
        PQclear(r);
        return NULL;
    }
    json_t *arr = json_array();
    int n = PQntuples(r);
    for (int i = 0; i < n; i++) {
        json_t *o = json_object();
        json_object_set_new(o, "name",  json_string(PQgetvalue(r, i, 1)));
        const char *title = PQgetvalue(r, i, 2);
        if (title && *title)
            json_object_set_new(o, "title", json_string(title));
        json_object_set_new(o, "description", json_string(PQgetvalue(r, i, 3)));

        json_error_t je;
        json_t *schema = json_loads(PQgetvalue(r, i, 5), 0, &je);
        if (!schema) schema = json_object();
        json_object_set_new(o, "inputSchema", schema);

        const char *out_raw = PQgetvalue(r, i, 6);
        if (out_raw && strcmp(out_raw, "null") != 0) {
            json_t *out_schema = json_loads(out_raw, 0, &je);
            if (out_schema) json_object_set_new(o, "outputSchema", out_schema);
        }
        /* MaluDB-specific metadata under _meta so listeners that don't
         * understand it can ignore. The dispatcher uses it at call time. */
        json_t *meta = json_object();
        json_object_set_new(meta, "implementation_type",
            json_string(PQgetvalue(r, i, 4)));
        json_object_set_new(meta, "tool_id",
            json_integer(strtoll(PQgetvalue(r, i, 0), NULL, 10)));
        json_object_set_new(o, "_meta", meta);
        json_array_append_new(arr, o);
    }
    PQclear(r);
    return arr;
}

json_t *db_tool_lookup(PGconn *conn, const char *tool_name,
                       char *err_buf, size_t errsz)
{
    const char *params[1] = { tool_name };
    const char *sql =
        "SELECT t.tool_id, t.tool_name, t.implementation_type, t.enabled, "
        "       sf.function_signature::text AS function_signature, "
        "       sf.transaction_mode, "
        "       sf.pinned_search_path "
        "FROM maludb_core.malu$mc2db_tool t "
        "LEFT JOIN maludb_core.malu$mc2db_tool_sql_function sf USING (tool_id) "
        "WHERE t.tool_name = $1";
    PGresult *r = PQexecParams(conn, sql, 1, NULL, params, NULL, NULL, 0);
    if (PQresultStatus(r) != PGRES_TUPLES_OK) {
        copy_err(err_buf, errsz, r, "tool lookup failed");
        PQclear(r);
        return NULL;
    }
    if (PQntuples(r) == 0) {
        snprintf(err_buf ? err_buf : (char[1]){0}, errsz, "tool not found: %s", tool_name);
        PQclear(r);
        return NULL;
    }
    json_t *o = json_object();
    json_object_set_new(o, "tool_id",
        json_integer(strtoll(PQgetvalue(r, 0, 0), NULL, 10)));
    json_object_set_new(o, "tool_name", json_string(PQgetvalue(r, 0, 1)));
    json_object_set_new(o, "implementation_type", json_string(PQgetvalue(r, 0, 2)));
    json_object_set_new(o, "enabled",
        json_boolean(PQgetvalue(r, 0, 3)[0] == 't'));
    if (!PQgetisnull(r, 0, 4))
        json_object_set_new(o, "function_signature", json_string(PQgetvalue(r, 0, 4)));
    if (!PQgetisnull(r, 0, 5))
        json_object_set_new(o, "transaction_mode", json_string(PQgetvalue(r, 0, 5)));
    if (!PQgetisnull(r, 0, 6))
        json_object_set_new(o, "pinned_search_path", json_string(PQgetvalue(r, 0, 6)));
    PQclear(r);
    return o;
}

bool db_begin_request(PGconn *conn, const char *call_id_uuid,
                      const char *tool_name, char *err_buf, size_t errsz)
{
    const char *params[2] = { call_id_uuid, tool_name };
    PGresult *r = PQexecParams(conn,
        "SELECT mc2db._begin_request($1::uuid, $2)",
        2, NULL, params, NULL, NULL, 0);
    bool ok = PQresultStatus(r) == PGRES_TUPLES_OK;
    if (!ok) copy_err(err_buf, errsz, r, "_begin_request failed");
    PQclear(r);
    return ok;
}

json_t *db_end_request(PGconn *conn, char *err_buf, size_t errsz)
{
    PGresult *r = PQexec(conn,
        "SELECT call_id, tool_name, payload, text_blocks, error_code, error_msg "
        "FROM mc2db._end_request()");
    if (PQresultStatus(r) != PGRES_TUPLES_OK) {
        copy_err(err_buf, errsz, r, "_end_request failed");
        PQclear(r);
        return NULL;
    }
    if (PQntuples(r) == 0) {
        PQclear(r);
        return json_null();
    }
    json_t *o = json_object();
    if (!PQgetisnull(r, 0, 2)) {
        json_error_t je;
        json_t *p = json_loads(PQgetvalue(r, 0, 2), 0, &je);
        if (p) json_object_set_new(o, "payload", p);
    }
    if (!PQgetisnull(r, 0, 3)) {
        json_error_t je;
        json_t *t = json_loads(PQgetvalue(r, 0, 3), 0, &je);
        if (t) json_object_set_new(o, "text_blocks", t);
    }
    if (!PQgetisnull(r, 0, 4))
        json_object_set_new(o, "error_code", json_string(PQgetvalue(r, 0, 4)));
    if (!PQgetisnull(r, 0, 5))
        json_object_set_new(o, "error_msg",  json_string(PQgetvalue(r, 0, 5)));
    PQclear(r);
    return o;
}

bool db_audit_write(PGconn *conn,
                    const char *call_id_uuid,
                    int64_t tool_id_or_zero,
                    const char *tool_name,
                    const char *implementation_type,
                    const char *request_user,
                    bool success,
                    const char *error_code,
                    const char *error_message,
                    int duration_ms)
{
    char tool_id_buf[32], duration_buf[16];
    snprintf(tool_id_buf, sizeof tool_id_buf, "%lld", (long long)tool_id_or_zero);
    snprintf(duration_buf, sizeof duration_buf, "%d", duration_ms);
    const char *params[9] = {
        call_id_uuid,
        tool_id_or_zero ? tool_id_buf : NULL,
        tool_name,
        implementation_type,
        request_user,
        success ? "t" : "f",
        error_code,
        error_message,
        duration_buf,
    };
    const char *sql =
        "INSERT INTO maludb_core.malu$mc2db_invocation"
        "  (call_id, tool_id, tool_name, implementation_type, "
        "   request_user, database_role, success, error_code, "
        "   error_message, started_at, finished_at, duration_ms) "
        "VALUES ($1::uuid, $2::bigint, $3, $4, $5, current_user::name, "
        "        $6::boolean, $7, $8, now(), now(), $9::integer)";
    PGresult *r = PQexecParams(conn, sql, 9, NULL, params, NULL, NULL, 0);
    bool ok = PQresultStatus(r) == PGRES_COMMAND_OK;
    if (!ok)
        LOG_WARN("audit insert failed: %s", PQresultErrorMessage(r));
    PQclear(r);
    return ok;
}

void db_make_uuid(char out[37])
{
    /* /dev/urandom-derived v4 UUID. Avoids pulling in libuuid. */
    unsigned char b[16];
    int fd = open("/dev/urandom", O_RDONLY);
    if (fd < 0) {
        memset(b, 0, sizeof b);
    } else {
        ssize_t n = read(fd, b, sizeof b);
        (void)n;
        close(fd);
    }
    b[6] = (b[6] & 0x0F) | 0x40;
    b[8] = (b[8] & 0x3F) | 0x80;
    snprintf(out, 37,
        "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
        b[0],b[1],b[2],b[3], b[4],b[5], b[6],b[7],
        b[8],b[9], b[10],b[11],b[12],b[13],b[14],b[15]);
}

/* ---- Prometheus metrics -------------------------------------------- */

static int metrics_append(char *buf, size_t cap, size_t *len,
                          const char *fmt, ...)
{
    if (*len >= cap) return -1;
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(buf + *len, cap - *len, fmt, ap);
    va_end(ap);
    if (n < 0 || (size_t)n >= cap - *len) return -1;
    *len += (size_t)n;
    return 0;
}

/* Prometheus label value: escape backslash, double-quote, newline. */
static void prom_label_escape(char *out, size_t out_sz, const char *in)
{
    size_t j = 0;
    for (size_t i = 0; in && in[i] && j + 3 < out_sz; i++) {
        char c = in[i];
        if (c == '\\' || c == '"') {
            out[j++] = '\\';
            out[j++] = c;
        } else if (c == '\n') {
            out[j++] = '\\';
            out[j++] = 'n';
        } else {
            out[j++] = c;
        }
    }
    if (j >= out_sz) j = out_sz - 1;
    out[j] = '\0';
}

char *db_metrics_text(PGconn *conn, char *err_buf, size_t errsz)
{
    const size_t CAP = 65536;
    char *buf = malloc(CAP);
    if (!buf) {
        if (err_buf && errsz) snprintf(err_buf, errsz, "out of memory");
        return NULL;
    }
    buf[0] = '\0';
    size_t len = 0;

    metrics_append(buf, CAP, &len,
        "# HELP maludb_mc2dbd_up 1 when the listener has PG connectivity.\n"
        "# TYPE maludb_mc2dbd_up gauge\n"
        "maludb_mc2dbd_up 1\n");

    /* Invocation totals + duration sums, grouped by (tool_name, success). */
    PGresult *r = PQexec(conn,
        "SELECT tool_name, success::text, count(*)::bigint, "
        "       coalesce(sum(duration_ms),0)::bigint "
        "FROM maludb_core.\"malu$mc2db_invocation\" "
        "GROUP BY tool_name, success "
        "ORDER BY tool_name, success");
    if (PQresultStatus(r) == PGRES_TUPLES_OK) {
        int nrows = PQntuples(r);
        metrics_append(buf, CAP, &len,
            "# HELP maludb_mc2dbd_invocations_total Total MC2DB tool invocations.\n"
            "# TYPE maludb_mc2dbd_invocations_total counter\n");
        for (int i = 0; i < nrows; i++) {
            char esc[256];
            prom_label_escape(esc, sizeof esc, PQgetvalue(r, i, 0));
            metrics_append(buf, CAP, &len,
                "maludb_mc2dbd_invocations_total{tool=\"%s\",success=\"%s\"} %s\n",
                esc, PQgetvalue(r, i, 1), PQgetvalue(r, i, 2));
        }
        metrics_append(buf, CAP, &len,
            "# HELP maludb_mc2dbd_invocation_duration_ms_sum Sum of MC2DB tool invocation durations in ms.\n"
            "# TYPE maludb_mc2dbd_invocation_duration_ms_sum counter\n");
        for (int i = 0; i < nrows; i++) {
            char esc[256];
            prom_label_escape(esc, sizeof esc, PQgetvalue(r, i, 0));
            metrics_append(buf, CAP, &len,
                "maludb_mc2dbd_invocation_duration_ms_sum{tool=\"%s\",success=\"%s\"} %s\n",
                esc, PQgetvalue(r, i, 1), PQgetvalue(r, i, 3));
        }
    } else {
        LOG_WARN("invocation metrics query failed: %s", PQresultErrorMessage(r));
    }
    PQclear(r);

    /* model_request status counts. */
    r = PQexec(conn,
        "SELECT status, count(*)::bigint "
        "FROM maludb_core.\"malu$model_request\" "
        "GROUP BY status "
        "ORDER BY status");
    if (PQresultStatus(r) == PGRES_TUPLES_OK) {
        int nrows = PQntuples(r);
        metrics_append(buf, CAP, &len,
            "# HELP maludb_model_request_count Model request rows grouped by status.\n"
            "# TYPE maludb_model_request_count gauge\n");
        for (int i = 0; i < nrows; i++) {
            metrics_append(buf, CAP, &len,
                "maludb_model_request_count{status=\"%s\"} %s\n",
                PQgetvalue(r, i, 0), PQgetvalue(r, i, 1));
        }
    } else {
        LOG_WARN("model_request metrics query failed: %s", PQresultErrorMessage(r));
    }
    PQclear(r);

    return buf;
}
