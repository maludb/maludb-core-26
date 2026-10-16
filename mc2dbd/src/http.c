/* mc2dbd HTTP layer (libmicrohttpd). R1.0-7. */

#include "http.h"
#include "mcp.h"
#include "db.h"

#include <microhttpd.h>
#include <sys/stat.h>

/* Per-request state — accumulates POST body and tracks completion. */
typedef struct req_state {
    char  *body;
    size_t cap;
    size_t len;
} req_state;

/* libmicrohttpd 0.9.71 introduced enum MHD_Result; older Debian/Ubuntu
 * shipped int. Pick whichever the headers prefer. */
#ifndef MHD_RESULT_TYPE
# if defined(MHD_VERSION) && MHD_VERSION >= 0x00097002
#  define MHD_RESULT_TYPE enum MHD_Result
# else
#  define MHD_RESULT_TYPE int
# endif
#endif

static const mc2dbd_config *g_cfg;  /* set by http_start, read by handler */

static MHD_RESULT_TYPE send_text(struct MHD_Connection *c, unsigned status,
                                 const char *body)
{
    struct MHD_Response *resp = MHD_create_response_from_buffer(
        strlen(body), (void*)body, MHD_RESPMEM_MUST_COPY);
    MHD_add_response_header(resp, "Content-Type", "text/plain; charset=utf-8");
    MHD_RESULT_TYPE rc = MHD_queue_response(c, status, resp);
    MHD_destroy_response(resp);
    return rc;
}

static MHD_RESULT_TYPE send_json(struct MHD_Connection *c, unsigned status,
                                 const char *body)
{
    struct MHD_Response *resp = MHD_create_response_from_buffer(
        strlen(body), (void*)body, MHD_RESPMEM_MUST_COPY);
    MHD_add_response_header(resp, "Content-Type", "application/json");
    MHD_RESULT_TYPE rc = MHD_queue_response(c, status, resp);
    MHD_destroy_response(resp);
    return rc;
}

static bool auth_ok(struct MHD_Connection *c)
{
    if (!g_cfg->bearer_token || !*g_cfg->bearer_token) return true;
    const char *h = MHD_lookup_connection_value(c, MHD_HEADER_KIND,
                                                "Authorization");
    if (!h) return false;
    if (strncmp(h, "Bearer ", 7) != 0) return false;
    return strcmp(h + 7, g_cfg->bearer_token) == 0;
}

static MHD_RESULT_TYPE handle(void *cls,
                              struct MHD_Connection *c,
                              const char *url,
                              const char *method,
                              const char *version,
                              const char *upload_data,
                              size_t *upload_data_size,
                              void **con_cls)
{
    (void)cls; (void)version;

    if (strcmp(method, "GET") == 0 && strcmp(url, "/healthz") == 0) {
        return send_text(c, MHD_HTTP_OK, "ok\n");
    }

    if (strcmp(method, "GET") == 0 && strcmp(url, "/metrics") == 0) {
        /* Prometheus scrape endpoint. Same binding policy as /healthz —
         * unauthenticated, intended for cluster-internal Prometheus.
         * The listener binds to 127.0.0.1 by default so external
         * exposure requires explicit operator config. */
        PGconn *pc = db_open(g_cfg);
        if (!pc) {
            return send_text(c, MHD_HTTP_SERVICE_UNAVAILABLE,
                             "# HELP maludb_mc2dbd_up 1 when the listener has PG connectivity.\n"
                             "# TYPE maludb_mc2dbd_up gauge\n"
                             "maludb_mc2dbd_up 0\n");
        }
        char errbuf[256] = "";
        char *body = db_metrics_text(pc, errbuf, sizeof errbuf);
        db_close(pc);
        if (!body) {
            return send_text(c, MHD_HTTP_INTERNAL_SERVER_ERROR,
                             "# metrics collection failed\n");
        }
        struct MHD_Response *resp = MHD_create_response_from_buffer(
            strlen(body), body, MHD_RESPMEM_MUST_FREE);
        MHD_add_response_header(resp, "Content-Type",
                                "text/plain; version=0.0.4; charset=utf-8");
        MHD_RESULT_TYPE rc = MHD_queue_response(c, MHD_HTTP_OK, resp);
        MHD_destroy_response(resp);
        return rc;
    }

    if (strcmp(method, "POST") != 0) {
        return send_text(c, MHD_HTTP_METHOD_NOT_ALLOWED,
                         "POST required\n");
    }

    /* MCP listener serves only the root (/) and an optional /mcp path
     * for forward compatibility with streamable-HTTP. */
    if (strcmp(url, "/") != 0 && strcmp(url, "/mcp") != 0) {
        return send_text(c, MHD_HTTP_NOT_FOUND, "not found\n");
    }

    if (!auth_ok(c)) {
        struct MHD_Response *r = MHD_create_response_from_buffer(
            13, (void*)"unauthorized\n", MHD_RESPMEM_PERSISTENT);
        MHD_add_response_header(r, "WWW-Authenticate", "Bearer");
        MHD_RESULT_TYPE rc = MHD_queue_response(c, MHD_HTTP_UNAUTHORIZED, r);
        MHD_destroy_response(r);
        return rc;
    }

    req_state *st = (req_state *)*con_cls;
    if (!st) {
        st = calloc(1, sizeof *st);
        if (!st) return MHD_NO;
        st->cap = 4096;
        st->body = malloc(st->cap);
        if (!st->body) { free(st); return MHD_NO; }
        st->body[0] = 0;
        *con_cls = st;
        return MHD_YES;
    }
    if (*upload_data_size) {
        size_t need = st->len + *upload_data_size + 1;
        if (need > MC2DBD_MAX_BODY)
            return send_text(c, MHD_HTTP_PAYLOAD_TOO_LARGE,
                             "request body too large\n");
        if (need > st->cap) {
            size_t nc = st->cap;
            while (nc < need) nc *= 2;
            char *nb = realloc(st->body, nc);
            if (!nb) return MHD_NO;
            st->body = nb;
            st->cap = nc;
        }
        memcpy(st->body + st->len, upload_data, *upload_data_size);
        st->len += *upload_data_size;
        st->body[st->len] = 0;
        *upload_data_size = 0;
        return MHD_YES;
    }

    /* Body fully buffered — open a PG conn, dispatch, free. */
    PGconn *conn = db_open(g_cfg);
    char *resp_body;
    if (!conn) {
        resp_body = strdup(
            "{\"jsonrpc\":\"2.0\",\"id\":null,"
            "\"error\":{\"code\":-32603,\"message\":\"db connection failed\"}}");
    } else {
        const char *user_hdr = MHD_lookup_connection_value(c, MHD_HEADER_KIND,
                                                           "X-MaluDB-User");
        resp_body = mcp_handle_request(conn, st->body, st->len,
                                       user_hdr ? user_hdr : "anonymous");
        db_close(conn);
    }
    MHD_RESULT_TYPE rc = send_json(c, MHD_HTTP_OK,
                                   resp_body ? resp_body :
                                   "{\"jsonrpc\":\"2.0\",\"id\":null,"
                                   "\"error\":{\"code\":-32603,\"message\":\"empty response\"}}");
    free(resp_body);
    return rc;
}

static void completed(void *cls, struct MHD_Connection *c,
                      void **con_cls, enum MHD_RequestTerminationCode toe)
{
    (void)cls; (void)c; (void)toe;
    req_state *st = (req_state *)*con_cls;
    if (st) { free(st->body); free(st); *con_cls = NULL; }
}

static char *read_file(const char *path)
{
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    char *buf = malloc(n + 1);
    if (!buf) { fclose(f); return NULL; }
    if (fread(buf, 1, n, f) != (size_t)n) { fclose(f); free(buf); return NULL; }
    buf[n] = 0;
    fclose(f);
    return buf;
}

struct MHD_Daemon *http_start(const mc2dbd_config *cfg)
{
    g_cfg = cfg;
    unsigned int flags = MHD_USE_INTERNAL_POLLING_THREAD;
    if (cfg->tls_enabled) flags |= MHD_USE_TLS;

    char *cert = NULL, *key = NULL;
    if (cfg->tls_enabled) {
        if (!cfg->tls_cert_path || !cfg->tls_key_path) {
            LOG_ERROR("tls_enabled requires tls_cert_path and tls_key_path");
            return NULL;
        }
        cert = read_file(cfg->tls_cert_path);
        key  = read_file(cfg->tls_key_path);
        if (!cert || !key) {
            LOG_ERROR("failed to read TLS cert/key");
            free(cert); free(key);
            return NULL;
        }
    }

    struct MHD_Daemon *d;
    if (cfg->tls_enabled) {
        d = MHD_start_daemon(flags, (uint16_t)cfg->bind_port,
                             NULL, NULL, &handle, NULL,
                             MHD_OPTION_NOTIFY_COMPLETED, completed, NULL,
                             MHD_OPTION_HTTPS_MEM_KEY,  key,
                             MHD_OPTION_HTTPS_MEM_CERT, cert,
                             MHD_OPTION_END);
    } else {
        d = MHD_start_daemon(flags, (uint16_t)cfg->bind_port,
                             NULL, NULL, &handle, NULL,
                             MHD_OPTION_NOTIFY_COMPLETED, completed, NULL,
                             MHD_OPTION_END);
    }
    /* libmicrohttpd copies the cert/key into its own buffers; we can free now. */
    free(cert); free(key);
    if (!d) {
        LOG_ERROR("MHD_start_daemon failed for %s:%d (TLS=%d)",
                  cfg->bind_host, cfg->bind_port, (int)cfg->tls_enabled);
        return NULL;
    }
    LOG_INFO("listening on %s:%d (TLS=%s)",
             cfg->bind_host, cfg->bind_port, cfg->tls_enabled ? "on" : "off");
    return d;
}

void http_stop(struct MHD_Daemon *d) { if (d) MHD_stop_daemon(d); }
