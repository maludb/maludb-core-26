/* mc2dbd http_endpoint dispatcher. R1.1-3.
 *
 * Generic HTTP call dispatcher. See http_endpoint.h for the contract.
 */

#include "http_endpoint.h"

#include <curl/curl.h>
#include <stdlib.h>
#include <string.h>

typedef struct http_ep_meta {
    int64_t tool_id;
    char   *tool_name;
    int     timeout_ms;
    int     max_output_bytes;
    char   *endpoint_url;
    char   *http_method;          /* GET POST PUT PATCH DELETE */
    json_t *static_headers;       /* {"X-Header":"value", ...} */
    char   *auth_type;            /* none | bearer | basic */
    char   *auth_token;           /* bearer token OR "user:pass" for basic */
} http_ep_meta;

static void http_ep_meta_free(http_ep_meta *m)
{
    if (!m) return;
    free(m->tool_name);
    free(m->endpoint_url);
    free(m->http_method);
    free(m->auth_type);
    free(m->auth_token);
    if (m->static_headers) json_decref(m->static_headers);
    memset(m, 0, sizeof *m);
}

static char *pg_strdup_or_null(PGresult *r, int row, int col)
{
    if (PQgetisnull(r, row, col)) return NULL;
    return strdup(PQgetvalue(r, row, col));
}

static bool
load_http_ep_meta(PGconn *conn, int64_t tool_id, http_ep_meta *out,
                  char *errbuf, size_t errsz)
{
    char id_buf[32];
    snprintf(id_buf, sizeof id_buf, "%lld", (long long)tool_id);
    const char *params[1] = { id_buf };
    const char *sql =
        "SELECT t.tool_name, t.timeout_ms, t.max_output_bytes, "
        "       he.endpoint_url, he.http_method, "
        "       he.static_headers::text, he.auth_type, he.auth_token "
        "FROM maludb_core.malu$mc2db_tool t "
        "JOIN maludb_core.malu$mc2db_tool_http_endpoint he USING (tool_id) "
        "WHERE t.tool_id = $1";
    PGresult *r = PQexecParams(conn, sql, 1, NULL, params, NULL, NULL, 0);
    if (PQresultStatus(r) != PGRES_TUPLES_OK) {
        snprintf(errbuf, errsz, "http_endpoint metadata lookup failed: %s",
                 PQresultErrorMessage(r));
        PQclear(r);
        return false;
    }
    if (PQntuples(r) == 0) {
        snprintf(errbuf, errsz,
                 "tool_id %lld has no malu$mc2db_tool_http_endpoint row",
                 (long long)tool_id);
        PQclear(r);
        return false;
    }

    memset(out, 0, sizeof *out);
    out->tool_id          = tool_id;
    out->tool_name        = pg_strdup_or_null(r, 0, 0);
    out->timeout_ms       = atoi(PQgetvalue(r, 0, 1));
    out->max_output_bytes = atoi(PQgetvalue(r, 0, 2));
    out->endpoint_url     = pg_strdup_or_null(r, 0, 3);
    out->http_method      = pg_strdup_or_null(r, 0, 4);
    out->auth_type        = pg_strdup_or_null(r, 0, 6);
    out->auth_token       = pg_strdup_or_null(r, 0, 7);

    json_error_t je;
    const char *txt = PQgetisnull(r, 0, 5) ? "{}" : PQgetvalue(r, 0, 5);
    out->static_headers = json_loads(txt, 0, &je);
    if (!out->static_headers) out->static_headers = json_object();

    PQclear(r);
    return true;
}

/* ---- libcurl write buffer ----------------------------------------- */

typedef struct curl_buf {
    char  *data;
    size_t len;
    size_t cap;
} curl_buf;

static size_t curl_writefn(void *ptr, size_t size, size_t nmemb, void *userdata)
{
    curl_buf *b = (curl_buf *)userdata;
    size_t n = size * nmemb;
    if (b->len + n + 1 > b->cap) {
        size_t nc = b->cap ? b->cap : 4096;
        while (nc < b->len + n + 1) nc *= 2;
        char *nd = realloc(b->data, nc);
        if (!nd) return 0;
        b->data = nd;
        b->cap = nc;
    }
    memcpy(b->data + b->len, ptr, n);
    b->len += n;
    b->data[b->len] = '\0';
    return n;
}

/* Capture response Content-Type. */
static size_t content_type_hdrfn(char *buffer, size_t size, size_t nitems,
                                 void *userdata)
{
    char **out = (char **)userdata;
    size_t n = size * nitems;
    static const char prefix[] = "content-type:";
    if (n > sizeof(prefix) - 1) {
        /* Case-insensitive prefix match. */
        bool match = true;
        for (size_t i = 0; i < sizeof(prefix) - 1; i++) {
            char a = buffer[i];
            if (a >= 'A' && a <= 'Z') a = (char)(a + 32);
            if (a != prefix[i]) { match = false; break; }
        }
        if (match && !*out) {
            const char *v = buffer + sizeof(prefix) - 1;
            size_t vlen = n - (sizeof(prefix) - 1);
            while (vlen && (*v == ' ' || *v == '\t')) { v++; vlen--; }
            while (vlen && (v[vlen - 1] == '\r' || v[vlen - 1] == '\n' ||
                            v[vlen - 1] == ' ' || v[vlen - 1] == '\t')) {
                vlen--;
            }
            char *copy = malloc(vlen + 1);
            if (copy) { memcpy(copy, v, vlen); copy[vlen] = '\0'; *out = copy; }
        }
    }
    return n;
}

static bool ct_is_json(const char *ct)
{
    if (!ct) return false;
    /* Match "application/json" with optional ";charset=...". */
    static const char target[] = "application/json";
    for (size_t i = 0; i < sizeof(target) - 1; i++) {
        char a = ct[i];
        if (a >= 'A' && a <= 'Z') a = (char)(a + 32);
        if (a != target[i]) return false;
    }
    char after = ct[sizeof(target) - 1];
    return after == '\0' || after == ';' || after == ' ';
}

/* ---- Public dispatch ----------------------------------------------- */

static void set_err(mc2dbd_tool_result *r, const char *code, const char *msg)
{
    r->is_error = true;
    free(r->error_code);
    free(r->error_message);
    r->error_code = strdup(code ? code : MC2DB_ERR_INTERNAL);
    r->error_message = strdup(msg ? msg : "");
}

void dispatch_http_endpoint(PGconn *conn,
                            const char *call_id_uuid,
                            json_t *tool_meta,
                            json_t *arguments,
                            const char *request_user,
                            mc2dbd_tool_result *out)
{
    (void)call_id_uuid; (void)request_user;
    int64_t tool_id = json_integer_value(json_object_get(tool_meta, "tool_id"));

    http_ep_meta meta;
    char errbuf[256] = "";
    if (!load_http_ep_meta(conn, tool_id, &meta, errbuf, sizeof errbuf)) {
        set_err(out, MC2DB_ERR_INTERNAL, errbuf);
        return;
    }
    if (!meta.endpoint_url || !meta.endpoint_url[0]) {
        set_err(out, MC2DB_ERR_INTERNAL,
                "http_endpoint row missing endpoint_url");
        http_ep_meta_free(&meta);
        return;
    }
    const char *method = meta.http_method && meta.http_method[0]
                         ? meta.http_method : "POST";
    bool has_body = (strcmp(method, "POST") == 0 ||
                     strcmp(method, "PUT")  == 0 ||
                     strcmp(method, "PATCH") == 0);

    char *body_str = NULL;
    if (has_body) {
        body_str = json_dumps(arguments ? arguments : json_object(),
                              JSON_COMPACT);
        if (!body_str) {
            set_err(out, MC2DB_ERR_INTERNAL, "failed to serialize arguments to JSON");
            http_ep_meta_free(&meta);
            return;
        }
    }

    CURL *h = curl_easy_init();
    if (!h) {
        set_err(out, MC2DB_ERR_INTERNAL, "curl_easy_init failed");
        free(body_str);
        http_ep_meta_free(&meta);
        return;
    }

    struct curl_slist *hdrs = NULL;
    if (has_body) {
        hdrs = curl_slist_append(hdrs, "Content-Type: application/json");
    }
    hdrs = curl_slist_append(hdrs, "Accept: application/json");

    /* Static headers. */
    if (meta.static_headers && json_is_object(meta.static_headers)) {
        const char *k;
        json_t *v;
        json_object_foreach(meta.static_headers, k, v) {
            const char *vs = json_string_value(v);
            if (!vs || !k) continue;
            char line[1024];
            snprintf(line, sizeof line, "%s: %s", k, vs);
            hdrs = curl_slist_append(hdrs, line);
        }
    }

    /* Auth. */
    if (meta.auth_type && strcmp(meta.auth_type, "bearer") == 0 && meta.auth_token) {
        char line[1024];
        snprintf(line, sizeof line, "Authorization: Bearer %s", meta.auth_token);
        hdrs = curl_slist_append(hdrs, line);
    } else if (meta.auth_type && strcmp(meta.auth_type, "basic") == 0 && meta.auth_token) {
        /* auth_token holds "user:pass". Let libcurl encode it. */
        curl_easy_setopt(h, CURLOPT_USERPWD, meta.auth_token);
        curl_easy_setopt(h, CURLOPT_HTTPAUTH, (long)CURLAUTH_BASIC);
    }

    curl_buf cb = {0};
    char *content_type = NULL;

    curl_easy_setopt(h, CURLOPT_URL, meta.endpoint_url);
    curl_easy_setopt(h, CURLOPT_CUSTOMREQUEST, method);
    if (has_body && body_str) {
        curl_easy_setopt(h, CURLOPT_POSTFIELDS, body_str);
        curl_easy_setopt(h, CURLOPT_POSTFIELDSIZE, (long)strlen(body_str));
    }
    curl_easy_setopt(h, CURLOPT_HTTPHEADER, hdrs);
    curl_easy_setopt(h, CURLOPT_WRITEFUNCTION, curl_writefn);
    curl_easy_setopt(h, CURLOPT_WRITEDATA, &cb);
    curl_easy_setopt(h, CURLOPT_HEADERFUNCTION, content_type_hdrfn);
    curl_easy_setopt(h, CURLOPT_HEADERDATA, &content_type);
    curl_easy_setopt(h, CURLOPT_TIMEOUT_MS,
                     meta.timeout_ms > 0 ? (long)meta.timeout_ms : 30000L);
    curl_easy_setopt(h, CURLOPT_FOLLOWLOCATION, 0L);
    curl_easy_setopt(h, CURLOPT_NOPROGRESS, 1L);
    curl_easy_setopt(h, CURLOPT_NOSIGNAL, 1L);

    CURLcode rc = curl_easy_perform(h);
    long status = 0;
    curl_easy_getinfo(h, CURLINFO_RESPONSE_CODE, &status);
    curl_slist_free_all(hdrs);
    curl_easy_cleanup(h);
    free(body_str);

    if (rc != CURLE_OK) {
        char msg[768];
        snprintf(msg, sizeof msg, "upstream http %s %s: %s",
                 method, meta.endpoint_url, curl_easy_strerror(rc));
        set_err(out, MC2DB_ERR_UPSTREAM, msg);
        free(cb.data); free(content_type);
        http_ep_meta_free(&meta);
        return;
    }
    if (status < 200 || status >= 300) {
        char excerpt[256] = "";
        if (cb.data) {
            size_t n = cb.len < sizeof excerpt - 1 ? cb.len : sizeof excerpt - 1;
            memcpy(excerpt, cb.data, n);
            excerpt[n] = '\0';
        }
        char msg[1024];
        snprintf(msg, sizeof msg, "upstream http %s %s returned %ld: %s",
                 method, meta.endpoint_url, status, excerpt);
        set_err(out, MC2DB_ERR_UPSTREAM, msg);
        free(cb.data); free(content_type);
        http_ep_meta_free(&meta);
        return;
    }
    if (meta.max_output_bytes > 0 && cb.len > (size_t)meta.max_output_bytes) {
        char msg[256];
        snprintf(msg, sizeof msg,
                 "upstream response exceeds max_output_bytes=%d",
                 meta.max_output_bytes);
        set_err(out, MC2DB_ERR_UPSTREAM, msg);
        free(cb.data); free(content_type);
        http_ep_meta_free(&meta);
        return;
    }

    /* Shape the result. JSON Content-Type → structuredContent;
     * everything else → single text item in content[]. */
    if (ct_is_json(content_type) && cb.data) {
        json_error_t je;
        json_t *parsed = json_loadb(cb.data, cb.len, 0, &je);
        if (parsed) {
            out->structured = parsed;
            /* Also surface a brief text content so MCP clients that
             * don't look at structuredContent get something useful. */
            char snippet[256];
            size_t n = cb.len < sizeof snippet - 1 ? cb.len : sizeof snippet - 1;
            memcpy(snippet, cb.data, n);
            snippet[n] = '\0';
            json_t *txt = json_object();
            json_object_set_new(txt, "type", json_string("text"));
            json_object_set_new(txt, "text", json_string(snippet));
            json_t *arr = json_array();
            json_array_append_new(arr, txt);
            out->content = arr;
        } else {
            /* Parser said JSON but body didn't parse — fall back to text. */
            json_t *txt = json_object();
            json_object_set_new(txt, "type", json_string("text"));
            json_object_set_new(txt, "text",
                                json_stringn(cb.data ? cb.data : "", cb.len));
            json_t *arr = json_array();
            json_array_append_new(arr, txt);
            out->content = arr;
        }
    } else {
        json_t *txt = json_object();
        json_object_set_new(txt, "type", json_string("text"));
        json_object_set_new(txt, "text",
                            json_stringn(cb.data ? cb.data : "", cb.len));
        json_t *arr = json_array();
        json_array_append_new(arr, txt);
        out->content = arr;
    }

    free(cb.data);
    free(content_type);
    http_ep_meta_free(&meta);
}
