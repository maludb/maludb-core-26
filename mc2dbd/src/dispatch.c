/* mc2dbd polymorphic dispatcher. R1.0-7.
 *
 * R1.0 dispatches sql_function only. external_exec, mcp_proxy, and
 * http_endpoint are catalog-modeled but unwired and MUST return a
 * tool-execution error of code IMPL_TYPE_NOT_AVAILABLE per
 * release-1.0-requirements.md §10. R1.1-1/2/3 replace the rejection
 * branches with real dispatchers.
 */

#include "dispatch.h"
#include "exec.h"
#include "proxy.h"
#include "http_endpoint.h"
#include <time.h>

void mc2dbd_tool_result_init(mc2dbd_tool_result *r)
{
    memset(r, 0, sizeof *r);
}

void mc2dbd_tool_result_free(mc2dbd_tool_result *r)
{
    free(r->error_code);
    free(r->error_message);
    if (r->content)    json_decref(r->content);
    if (r->structured) json_decref(r->structured);
    memset(r, 0, sizeof *r);
}

static void set_error(mc2dbd_tool_result *r, const char *code, const char *msg)
{
    r->is_error      = true;
    r->error_code    = strdup(code);
    r->error_message = strdup(msg);
    /* MCP requires content[] even on error — populate a single text block
     * so a strict client doesn't choke. */
    json_t *block = json_object();
    json_object_set_new(block, "type", json_string("text"));
    json_object_set_new(block, "text", json_string(msg));
    r->content = json_array();
    json_array_append_new(r->content, block);
}

static int now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int)(ts.tv_sec * 1000 + ts.tv_nsec / 1000000);
}

/* dispatch_sql_function — open a TX, set a pinned search_path, bracket
 * the call with mc2db._begin_request / _end_request, execute the
 * registered function with the provided arguments jsonb, COMMIT, and
 * return whatever payload the function emitted via mc2db.put_object
 * (or compose one from put_text blocks). */
static void dispatch_sql_function(PGconn *conn,
                                  const char *call_id_uuid,
                                  json_t *tool_meta,
                                  json_t *arguments,
                                  const char *request_user,
                                  mc2dbd_tool_result *out)
{
    const char *func_sig = json_string_value(json_object_get(tool_meta,
                                              "function_signature"));
    const char *tool_name = json_string_value(json_object_get(tool_meta,
                                              "tool_name"));
    if (!func_sig) {
        set_error(out, MC2DB_ERR_INTERNAL,
                  "sql_function tool has no function_signature");
        return;
    }

    /* function_signature is a regprocedure text like "schema.name(t1, t2)".
     * For SELECT we only need the schema-qualified name; the argument
     * types are implicit from the values we pass. Strip from the first
     * '(' onward, plus trailing whitespace. */
    char func_name[256];
    {
        const char *paren = strchr(func_sig, '(');
        size_t n = paren ? (size_t)(paren - func_sig) : strlen(func_sig);
        while (n > 0 && (func_sig[n-1] == ' ' || func_sig[n-1] == '\t')) n--;
        if (n >= sizeof func_name) n = sizeof func_name - 1;
        memcpy(func_name, func_sig, n);
        func_name[n] = 0;
    }

    char err_buf[512] = {0};

    PGresult *bx = PQexec(conn, "BEGIN");
    PQclear(bx);

    if (!db_begin_request(conn, call_id_uuid, tool_name, err_buf, sizeof err_buf)) {
        bx = PQexec(conn, "ROLLBACK"); PQclear(bx);
        set_error(out, MC2DB_ERR_INTERNAL, err_buf[0] ? err_buf : "begin_request failed");
        return;
    }

    /* Build the call. The R1.0 sql_function contract REQUIRES the
     * two-arg shape: func(args jsonb, context jsonb). Tools that want
     * a parameterless or one-arg interface adapt by ignoring the args
     * they don't need. R1.0-7 originally had a dynamic
     * two-arg→one-arg→zero-arg fallback, but the over-eager retry
     * heuristic ("if error mentions 'function' then try a smaller
     * arity") fired on permission-denied errors too — masking the real
     * cause behind a secondary "current transaction is aborted"
     * (R1.0-10 field test, commit e286a97). The fallback is gone;
     * any error from the SQL call surfaces directly. */
    char *args_text = json_dumps(arguments ? arguments : json_object(), JSON_COMPACT);
    json_t *ctx = json_object();
    json_object_set_new(ctx, "call_id", json_string(call_id_uuid));
    json_object_set_new(ctx, "request_user",
        json_string(request_user ? request_user : "anonymous"));
    char *ctx_text = json_dumps(ctx, JSON_COMPACT);
    json_decref(ctx);

    char call_buf[1024];
    snprintf(call_buf, sizeof call_buf,
             "SELECT %s($1::jsonb, $2::jsonb)", func_name);
    const char *params[2] = { args_text, ctx_text };
    PGresult *r = PQexecParams(conn, call_buf, 2, NULL, params, NULL, NULL, 0);
    if (PQresultStatus(r) != PGRES_TUPLES_OK
        && PQresultStatus(r) != PGRES_COMMAND_OK) {
        const char *e = PQresultErrorMessage(r);
        if (!e || !*e) e = "function execution failed";
        char msg[512];
        snprintf(msg, sizeof msg, "%s", e);
        size_t L = strlen(msg);
        while (L && (msg[L-1] == '\n' || msg[L-1] == '\r')) msg[--L] = 0;
        PQclear(r);
        bx = PQexec(conn, "ROLLBACK"); PQclear(bx);
        set_error(out, MC2DB_ERR_TOOL_EXECUTION, msg);
        free(args_text); free(ctx_text);
        return;
    }
    PQclear(r);
    free(args_text);
    free(ctx_text);

    json_t *captured = db_end_request(conn, err_buf, sizeof err_buf);

    bx = PQexec(conn, "COMMIT");
    if (PQresultStatus(bx) != PGRES_COMMAND_OK) {
        PQclear(bx);
        if (captured) json_decref(captured);
        set_error(out, MC2DB_ERR_INTERNAL, "COMMIT failed");
        return;
    }
    PQclear(bx);

    /* Compose result. Prefer the put_object payload; otherwise build
     * from text_blocks; otherwise empty success. */
    json_t *payload = captured ? json_object_get(captured, "payload") : NULL;
    json_t *texts   = captured ? json_object_get(captured, "text_blocks") : NULL;

    if (payload && json_is_object(payload)) {
        /* Tool may have set isError=true via mc2db.put_error. Honor it. */
        json_t *is_err = json_object_get(payload, "isError");
        if (json_is_true(is_err)) {
            const char *msg = "tool reported error";
            json_t *sc = json_object_get(payload, "structuredContent");
            if (json_is_object(sc)) {
                json_t *e = json_object_get(sc, "error");
                if (json_is_object(e)) {
                    const char *m = json_string_value(json_object_get(e, "message"));
                    if (m) msg = m;
                }
            }
            set_error(out, MC2DB_ERR_TOOL_EXECUTION, msg);
            /* Replace content with the tool's content array if present. */
            json_t *content = json_object_get(payload, "content");
            if (content && json_is_array(content)) {
                json_decref(out->content);
                out->content = json_incref(content);
            }
        } else {
            /* success — extract content + structuredContent */
            json_t *content = json_object_get(payload, "content");
            json_t *sc      = json_object_get(payload, "structuredContent");
            if (content && json_is_array(content))
                out->content = json_incref(content);
            if (sc) out->structured = json_incref(sc);
        }
    } else if (texts && json_is_array(texts) && json_array_size(texts) > 0) {
        out->content = json_incref(texts);
    } else {
        /* Empty success — synthesize a minimal content block. */
        json_t *block = json_object();
        json_object_set_new(block, "type", json_string("text"));
        json_object_set_new(block, "text", json_string("ok"));
        out->content = json_array();
        json_array_append_new(out->content, block);
    }

    if (captured) json_decref(captured);
}

void dispatch_tool(PGconn *conn,
                   const char *call_id_uuid,
                   json_t *tool_meta,
                   json_t *arguments,
                   const char *request_user,
                   mc2dbd_tool_result *out)
{
    int t0 = now_ms();
    const char *impl = json_string_value(json_object_get(tool_meta,
                                          "implementation_type"));
    const char *tool_name = json_string_value(json_object_get(tool_meta,
                                          "tool_name"));
    int64_t tool_id = json_integer_value(json_object_get(tool_meta, "tool_id"));

    json_t *enabled = json_object_get(tool_meta, "enabled");
    if (json_is_false(enabled)) {
        set_error(out, MC2DB_ERR_TOOL_DISABLED, "tool is disabled");
    } else if (!impl) {
        set_error(out, MC2DB_ERR_INTERNAL, "tool has no implementation_type");
    } else if (strcmp(impl, "sql_function") == 0) {
        dispatch_sql_function(conn, call_id_uuid, tool_meta, arguments,
                              request_user, out);
    } else if (strcmp(impl, "external_exec") == 0) {
        dispatch_external_exec(conn, call_id_uuid, tool_meta, arguments,
                               request_user, out);
    } else if (strcmp(impl, "mcp_proxy") == 0) {
        dispatch_mcp_proxy(conn, call_id_uuid, tool_meta, arguments,
                           request_user, out);
    } else if (strcmp(impl, "http_endpoint") == 0) {
        dispatch_http_endpoint(conn, call_id_uuid, tool_meta, arguments,
                               request_user, out);
    } else {
        char msg[128];
        snprintf(msg, sizeof msg, "unknown implementation_type: %s", impl);
        set_error(out, MC2DB_ERR_INTERNAL, msg);
    }

    db_audit_write(conn, call_id_uuid, tool_id, tool_name, impl ? impl : "unknown",
                   request_user,
                   !out->is_error,
                   out->error_code,
                   out->error_message,
                   now_ms() - t0);
}
