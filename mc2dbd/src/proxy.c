/* mc2dbd MCP proxy dispatcher. R1.1-2.
 *
 * Forwards tools/call to a remote MCP server. Transport-specific
 * details live in proxy_http() and proxy_stdio() below; the public
 * entry point (dispatch_mcp_proxy) handles metadata load, envelope
 * build, response parse, and error mapping.
 */

#include "proxy.h"

#include <curl/curl.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

/* ---- libcurl lifecycle --------------------------------------------- */

static int g_curl_inited = 0;

void proxy_global_init(void)
{
    if (g_curl_inited) return;
    curl_global_init(CURL_GLOBAL_DEFAULT);
    g_curl_inited = 1;
}

void proxy_global_cleanup(void)
{
    if (!g_curl_inited) return;
    curl_global_cleanup();
    g_curl_inited = 0;
}

/* ---- mcp_proxy metadata -------------------------------------------- */

typedef struct proxy_meta {
    int64_t tool_id;
    char   *tool_name;
    int     timeout_ms;
    int     max_output_bytes;
    /* mcp_proxy-specific */
    char   *remote_server_name;
    char   *remote_tool_name;
    char   *transport_type;   /* "http" or "stdio" */
    char   *endpoint_url;     /* http transport */
    char   *command_path;     /* stdio transport */
    json_t *argv;             /* json array, stdio transport */
} proxy_meta;

static void proxy_meta_free(proxy_meta *m)
{
    if (!m) return;
    free(m->tool_name);
    free(m->remote_server_name);
    free(m->remote_tool_name);
    free(m->transport_type);
    free(m->endpoint_url);
    free(m->command_path);
    if (m->argv) json_decref(m->argv);
    memset(m, 0, sizeof *m);
}

static char *pg_strdup_or_null(PGresult *r, int row, int col)
{
    if (PQgetisnull(r, row, col)) return NULL;
    return strdup(PQgetvalue(r, row, col));
}

static bool
load_proxy_meta(PGconn *conn, int64_t tool_id, proxy_meta *out,
                char *errbuf, size_t errsz)
{
    char id_buf[32];
    snprintf(id_buf, sizeof id_buf, "%lld", (long long)tool_id);
    const char *params[1] = { id_buf };
    const char *sql =
        "SELECT t.tool_name, t.timeout_ms, t.max_output_bytes, "
        "       mp.remote_server_name, mp.remote_tool_name, "
        "       mp.transport_type, mp.endpoint_url, "
        "       mp.command_path, mp.argv::text "
        "FROM maludb_core.malu$mc2db_tool t "
        "JOIN maludb_core.malu$mc2db_tool_mcp_proxy mp USING (tool_id) "
        "WHERE t.tool_id = $1";
    PGresult *r = PQexecParams(conn, sql, 1, NULL, params, NULL, NULL, 0);
    if (PQresultStatus(r) != PGRES_TUPLES_OK) {
        snprintf(errbuf, errsz, "mcp_proxy metadata lookup failed: %s",
                 PQresultErrorMessage(r));
        PQclear(r);
        return false;
    }
    if (PQntuples(r) == 0) {
        snprintf(errbuf, errsz,
                 "tool_id %lld has no malu$mc2db_tool_mcp_proxy row",
                 (long long)tool_id);
        PQclear(r);
        return false;
    }

    memset(out, 0, sizeof *out);
    out->tool_id            = tool_id;
    out->tool_name          = pg_strdup_or_null(r, 0, 0);
    out->timeout_ms         = atoi(PQgetvalue(r, 0, 1));
    out->max_output_bytes   = atoi(PQgetvalue(r, 0, 2));
    out->remote_server_name = pg_strdup_or_null(r, 0, 3);
    out->remote_tool_name   = pg_strdup_or_null(r, 0, 4);
    out->transport_type     = pg_strdup_or_null(r, 0, 5);
    out->endpoint_url       = pg_strdup_or_null(r, 0, 6);
    out->command_path       = pg_strdup_or_null(r, 0, 7);

    json_error_t je;
    const char *argv_txt = PQgetisnull(r, 0, 8) ? "[]" : PQgetvalue(r, 0, 8);
    out->argv = json_loads(argv_txt, 0, &je);
    if (!out->argv) out->argv = json_array();

    PQclear(r);
    return true;
}

/* ---- HTTP transport (libcurl) -------------------------------------- */

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

static int
proxy_http(const char *url, const char *body, long timeout_ms,
           size_t max_output_bytes,
           char **out_body, size_t *out_len,
           char *err, size_t errsz)
{
    CURL *h = curl_easy_init();
    if (!h) {
        snprintf(err, errsz, "curl_easy_init failed");
        return -1;
    }
    curl_buf cb = {0};
    struct curl_slist *hdrs = NULL;
    hdrs = curl_slist_append(hdrs, "Content-Type: application/json");
    hdrs = curl_slist_append(hdrs, "Accept: application/json");

    curl_easy_setopt(h, CURLOPT_URL, url);
    curl_easy_setopt(h, CURLOPT_POST, 1L);
    curl_easy_setopt(h, CURLOPT_POSTFIELDS, body);
    curl_easy_setopt(h, CURLOPT_POSTFIELDSIZE, (long)strlen(body));
    curl_easy_setopt(h, CURLOPT_HTTPHEADER, hdrs);
    curl_easy_setopt(h, CURLOPT_WRITEFUNCTION, curl_writefn);
    curl_easy_setopt(h, CURLOPT_WRITEDATA, &cb);
    curl_easy_setopt(h, CURLOPT_TIMEOUT_MS, timeout_ms > 0 ? timeout_ms : 30000);
    curl_easy_setopt(h, CURLOPT_FOLLOWLOCATION, 0L);
    curl_easy_setopt(h, CURLOPT_NOPROGRESS, 1L);
    curl_easy_setopt(h, CURLOPT_NOSIGNAL, 1L);

    CURLcode rc = curl_easy_perform(h);
    long status = 0;
    curl_easy_getinfo(h, CURLINFO_RESPONSE_CODE, &status);
    curl_slist_free_all(hdrs);
    curl_easy_cleanup(h);

    if (rc != CURLE_OK) {
        snprintf(err, errsz, "curl: %s", curl_easy_strerror(rc));
        free(cb.data);
        return -1;
    }
    if (status < 200 || status >= 300) {
        snprintf(err, errsz, "remote returned HTTP %ld", status);
        free(cb.data);
        return -1;
    }
    if (max_output_bytes > 0 && cb.len > max_output_bytes) {
        snprintf(err, errsz, "remote response exceeds max_output_bytes=%zu",
                 max_output_bytes);
        free(cb.data);
        return -1;
    }
    *out_body = cb.data;
    *out_len  = cb.len;
    return 0;
}

/* ---- stdio transport (fork+exec, one-shot) ------------------------- */

static int
set_nonblock(int fd)
{
    int fl = fcntl(fd, F_GETFL, 0);
    if (fl < 0) return -1;
    return fcntl(fd, F_SETFL, fl | O_NONBLOCK);
}

static long
now_ms_proxy(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000L + ts.tv_nsec / 1000000L;
}

static int
proxy_stdio(const char *cmd, json_t *argv, const char *body, long timeout_ms,
            size_t max_output_bytes,
            char **out_body, size_t *out_len,
            char *err, size_t errsz)
{
    if (!cmd || cmd[0] != '/') {
        snprintf(err, errsz, "stdio command_path must be absolute");
        return -1;
    }

    /* Build argv[]: program name + jsonb argv items + NULL. */
    size_t nargs = argv && json_is_array(argv) ? json_array_size(argv) : 0;
    char **av = calloc(nargs + 2, sizeof *av);
    if (!av) { snprintf(err, errsz, "oom"); return -1; }
    av[0] = strdup(cmd);
    for (size_t i = 0; i < nargs; i++) {
        json_t *e = json_array_get(argv, i);
        const char *s = json_string_value(e);
        av[i + 1] = strdup(s ? s : "");
    }
    av[nargs + 1] = NULL;

    int in_pipe[2] = {-1,-1}, out_pipe[2] = {-1,-1};
    if (pipe(in_pipe) < 0 || pipe(out_pipe) < 0) {
        snprintf(err, errsz, "pipe(): %s", strerror(errno));
        goto fail_cleanup;
    }

    pid_t pid = fork();
    if (pid < 0) {
        snprintf(err, errsz, "fork(): %s", strerror(errno));
        goto fail_cleanup;
    }
    if (pid == 0) {
        /* Child: stdin from in_pipe[0], stdout to out_pipe[1]. */
        dup2(in_pipe[0], 0);
        dup2(out_pipe[1], 1);
        /* Redirect stderr to /dev/null — we don't capture it for v1. */
        int devnull = open("/dev/null", O_WRONLY);
        if (devnull >= 0) { dup2(devnull, 2); close(devnull); }
        close(in_pipe[0]); close(in_pipe[1]);
        close(out_pipe[0]); close(out_pipe[1]);
        /* Scrub env: keep only PATH, HOME, LANG. */
        char *path = getenv("PATH");
        char *home = getenv("HOME");
        char *lang = getenv("LANG");
        char *envp[5];
        int ei = 0;
        char ebuf[3][256];
        if (path) { snprintf(ebuf[0], sizeof ebuf[0], "PATH=%s", path); envp[ei++] = ebuf[0]; }
        if (home) { snprintf(ebuf[1], sizeof ebuf[1], "HOME=%s", home); envp[ei++] = ebuf[1]; }
        if (lang) { snprintf(ebuf[2], sizeof ebuf[2], "LANG=%s", lang); envp[ei++] = ebuf[2]; }
        envp[ei] = NULL;
        execve(cmd, av, envp);
        _exit(127);
    }

    /* Parent. */
    close(in_pipe[0]); in_pipe[0] = -1;
    close(out_pipe[1]); out_pipe[1] = -1;
    set_nonblock(in_pipe[1]);
    set_nonblock(out_pipe[0]);

    for (size_t i = 0; av[i]; i++) free(av[i]);
    free(av);
    av = NULL;

    /* Write request body + newline, then close stdin to signal EOF. */
    size_t bodylen = strlen(body);
    char *req = malloc(bodylen + 2);
    if (!req) { snprintf(err, errsz, "oom"); goto fail_kill; }
    memcpy(req, body, bodylen);
    req[bodylen] = '\n';
    req[bodylen + 1] = '\0';
    size_t req_len = bodylen + 1;
    size_t req_off = 0;

    curl_buf rb = {0};
    long deadline = now_ms_proxy() + (timeout_ms > 0 ? timeout_ms : 30000);

    while (1) {
        long remaining = deadline - now_ms_proxy();
        if (remaining <= 0) {
            snprintf(err, errsz, "stdio child timed out");
            free(req); free(rb.data);
            goto fail_kill;
        }
        struct pollfd pfds[2];
        int nfds = 0;
        if (in_pipe[1] >= 0 && req_off < req_len) {
            pfds[nfds].fd = in_pipe[1];
            pfds[nfds].events = POLLOUT;
            nfds++;
        }
        if (out_pipe[0] >= 0) {
            pfds[nfds].fd = out_pipe[0];
            pfds[nfds].events = POLLIN;
            nfds++;
        }
        if (nfds == 0) break;

        int pr = poll(pfds, nfds, remaining > 1000 ? 1000 : (int)remaining);
        if (pr < 0) {
            if (errno == EINTR) continue;
            snprintf(err, errsz, "poll(): %s", strerror(errno));
            free(req); free(rb.data);
            goto fail_kill;
        }
        for (int i = 0; i < nfds; i++) {
            if (pfds[i].fd == in_pipe[1] && (pfds[i].revents & POLLOUT)) {
                ssize_t w = write(in_pipe[1], req + req_off, req_len - req_off);
                if (w > 0) req_off += w;
                if (req_off >= req_len) {
                    close(in_pipe[1]);
                    in_pipe[1] = -1;
                }
            }
            if (pfds[i].fd == out_pipe[0] && (pfds[i].revents & POLLIN)) {
                char chunk[4096];
                ssize_t rr = read(out_pipe[0], chunk, sizeof chunk);
                if (rr > 0) {
                    if (max_output_bytes > 0 && rb.len + (size_t)rr > max_output_bytes) {
                        snprintf(err, errsz,
                                 "stdio child output exceeds max_output_bytes=%zu",
                                 max_output_bytes);
                        free(req); free(rb.data);
                        goto fail_kill;
                    }
                    if (curl_writefn(chunk, 1, (size_t)rr, &rb) == 0) {
                        snprintf(err, errsz, "oom buffering stdio output");
                        free(req); free(rb.data);
                        goto fail_kill;
                    }
                } else if (rr == 0) {
                    close(out_pipe[0]);
                    out_pipe[0] = -1;
                }
            }
            if (pfds[i].revents & (POLLHUP | POLLERR)) {
                if (pfds[i].fd == out_pipe[0]) { close(out_pipe[0]); out_pipe[0] = -1; }
                if (pfds[i].fd == in_pipe[1])  { close(in_pipe[1]);  in_pipe[1]  = -1; }
            }
        }
    }
    free(req);

    /* Reap. */
    int status = 0;
    long reap_deadline = now_ms_proxy() + 500;
    while (1) {
        pid_t w = waitpid(pid, &status, WNOHANG);
        if (w == pid) break;
        if (now_ms_proxy() >= reap_deadline) { kill(pid, SIGKILL); waitpid(pid, &status, 0); break; }
        usleep(10000);
    }

    if (WIFEXITED(status) && WEXITSTATUS(status) != 0) {
        snprintf(err, errsz, "stdio child exited with code %d", WEXITSTATUS(status));
        free(rb.data);
        return -1;
    }
    if (WIFSIGNALED(status)) {
        snprintf(err, errsz, "stdio child killed by signal %d", WTERMSIG(status));
        free(rb.data);
        return -1;
    }
    if (rb.len == 0) {
        snprintf(err, errsz, "stdio child produced no output");
        free(rb.data);
        return -1;
    }
    *out_body = rb.data;
    *out_len  = rb.len;
    return 0;

fail_kill:
    if (av) { for (size_t i = 0; av[i]; i++) free(av[i]); free(av); }
    kill(pid, SIGKILL);
    waitpid(pid, NULL, 0);
    if (in_pipe[0] >= 0) close(in_pipe[0]);
    if (in_pipe[1] >= 0) close(in_pipe[1]);
    if (out_pipe[0] >= 0) close(out_pipe[0]);
    if (out_pipe[1] >= 0) close(out_pipe[1]);
    return -1;

fail_cleanup:
    if (av) { for (size_t i = 0; av[i]; i++) free(av[i]); free(av); }
    if (in_pipe[0] >= 0) close(in_pipe[0]);
    if (in_pipe[1] >= 0) close(in_pipe[1]);
    if (out_pipe[0] >= 0) close(out_pipe[0]);
    if (out_pipe[1] >= 0) close(out_pipe[1]);
    return -1;
}

/* ---- Response parsing ---------------------------------------------- */

/* Pulls the first complete JSON object from buf — useful for stdio
 * servers that emit a newline-terminated response (or HTTP servers
 * that return a single JSON document). Returns parsed json on success,
 * NULL on failure. Caller decref's. */
static json_t *
parse_first_json(const char *buf, size_t len, char *err, size_t errsz)
{
    /* json_loadb is forgiving of trailing whitespace; strip newline
     * after the last `}`. */
    size_t end = len;
    while (end > 0 && (buf[end - 1] == '\n' || buf[end - 1] == '\r'
                       || buf[end - 1] == ' ' || buf[end - 1] == '\t')) {
        end--;
    }
    json_error_t je;
    json_t *j = json_loadb(buf, end, 0, &je);
    if (!j) {
        snprintf(err, errsz, "malformed JSON response: %s", je.text);
        return NULL;
    }
    return j;
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

void dispatch_mcp_proxy(PGconn *conn,
                        const char *call_id_uuid,
                        json_t *tool_meta,
                        json_t *arguments,
                        const char *request_user,
                        mc2dbd_tool_result *out)
{
    (void)request_user;
    int64_t tool_id = json_integer_value(json_object_get(tool_meta, "tool_id"));

    proxy_meta meta;
    char errbuf[256] = "";
    if (!load_proxy_meta(conn, tool_id, &meta, errbuf, sizeof errbuf)) {
        set_err(out, MC2DB_ERR_INTERNAL, errbuf);
        return;
    }

    /* Build the JSON-RPC envelope for the remote MCP server. */
    json_t *params = json_object();
    json_object_set_new(params, "name", json_string(meta.remote_tool_name ? meta.remote_tool_name : ""));
    json_object_set(params, "arguments", arguments ? arguments : json_object());
    json_t *env = json_object();
    json_object_set_new(env, "jsonrpc", json_string("2.0"));
    json_object_set_new(env, "id", json_string(call_id_uuid));
    json_object_set_new(env, "method", json_string("tools/call"));
    json_object_set_new(env, "params", params);
    char *envelope = json_dumps(env, JSON_COMPACT);
    json_decref(env);
    if (!envelope) {
        set_err(out, MC2DB_ERR_INTERNAL, "failed to build proxy request envelope");
        proxy_meta_free(&meta);
        return;
    }

    char *resp_body = NULL;
    size_t resp_len = 0;
    int rc = -1;
    char xerr[512] = "";

    if (meta.transport_type && strcmp(meta.transport_type, "http") == 0) {
        if (!meta.endpoint_url || !meta.endpoint_url[0]) {
            set_err(out, MC2DB_ERR_INTERNAL, "http transport missing endpoint_url");
            free(envelope); proxy_meta_free(&meta); return;
        }
        rc = proxy_http(meta.endpoint_url, envelope,
                        meta.timeout_ms, (size_t)meta.max_output_bytes,
                        &resp_body, &resp_len, xerr, sizeof xerr);
    } else if (meta.transport_type && strcmp(meta.transport_type, "stdio") == 0) {
        if (!meta.command_path || !meta.command_path[0]) {
            set_err(out, MC2DB_ERR_INTERNAL, "stdio transport missing command_path");
            free(envelope); proxy_meta_free(&meta); return;
        }
        rc = proxy_stdio(meta.command_path, meta.argv, envelope,
                         meta.timeout_ms, (size_t)meta.max_output_bytes,
                         &resp_body, &resp_len, xerr, sizeof xerr);
    } else {
        set_err(out, MC2DB_ERR_INTERNAL, "unsupported transport_type");
        free(envelope); proxy_meta_free(&meta); return;
    }
    free(envelope);

    if (rc != 0) {
        char msg[768];
        snprintf(msg, sizeof msg, "upstream %s://%s: %s",
                 meta.transport_type ? meta.transport_type : "?",
                 meta.remote_server_name ? meta.remote_server_name : "?",
                 xerr);
        set_err(out, MC2DB_ERR_UPSTREAM, msg);
        proxy_meta_free(&meta);
        return;
    }

    /* Parse JSON-RPC response. */
    json_t *resp = parse_first_json(resp_body, resp_len, xerr, sizeof xerr);
    free(resp_body);
    if (!resp) {
        set_err(out, MC2DB_ERR_UPSTREAM, xerr);
        proxy_meta_free(&meta);
        return;
    }

    json_t *err_obj = json_object_get(resp, "error");
    if (err_obj && json_is_object(err_obj)) {
        const char *msg = json_string_value(json_object_get(err_obj, "message"));
        char detail[512];
        snprintf(detail, sizeof detail, "remote %s:%s reported: %s",
                 meta.remote_server_name ? meta.remote_server_name : "?",
                 meta.remote_tool_name ? meta.remote_tool_name : "?",
                 msg ? msg : "(no message)");
        set_err(out, MC2DB_ERR_TOOL_EXECUTION, detail);
        json_decref(resp);
        proxy_meta_free(&meta);
        return;
    }

    json_t *result = json_object_get(resp, "result");
    if (!result || !json_is_object(result)) {
        set_err(out, MC2DB_ERR_UPSTREAM, "remote response missing 'result' object");
        json_decref(resp);
        proxy_meta_free(&meta);
        return;
    }

    /* Pass through content / structuredContent. */
    json_t *content = json_object_get(result, "content");
    if (content) {
        out->content = json_deep_copy(content);
    }
    json_t *structured = json_object_get(result, "structuredContent");
    if (structured) {
        out->structured = json_deep_copy(structured);
    }

    /* Honor a remote isError=true flag. */
    json_t *is_err = json_object_get(result, "isError");
    if (json_is_true(is_err)) {
        const char *txt = "remote tool reported isError=true";
        if (content && json_is_array(content) && json_array_size(content) > 0) {
            json_t *first = json_array_get(content, 0);
            json_t *t = json_object_get(first, "text");
            if (json_is_string(t)) txt = json_string_value(t);
        }
        set_err(out, MC2DB_ERR_TOOL_EXECUTION, txt);
    }

    json_decref(resp);
    proxy_meta_free(&meta);
}
