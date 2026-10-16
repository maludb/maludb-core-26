/* mc2dbd MCP protocol handlers. R1.0-7.
 *
 * Implements the three MCP methods required by R1.0:
 *   initialize    — capability negotiation
 *   tools/list    — discovery, all impl_types, authorization-filtered
 *   tools/call    — dispatch via dispatch.c
 *
 * Plus protocol-level handling: parse errors, unknown methods, malformed
 * params. R1.0-7 distinguishes:
 *   protocol error  → top-level "error" field with JSON-RPC code
 *   tool error      → "result.isError = true" with a content[] block
 */

#include "mcp.h"
#include "dispatch.h"

static char *encode_response(json_t *resp)
{
    char *s = json_dumps(resp, JSON_COMPACT);
    json_decref(resp);
    return s;
}

static json_t *make_envelope(json_t *id)
{
    json_t *e = json_object();
    json_object_set_new(e, "jsonrpc", json_string("2.0"));
    json_object_set(e, "id", id ? id : json_null());
    return e;
}

static char *protocol_error(json_t *id, int code, const char *msg)
{
    json_t *resp = make_envelope(id);
    json_t *err = json_object();
    json_object_set_new(err, "code", json_integer(code));
    json_object_set_new(err, "message", json_string(msg));
    json_object_set_new(resp, "error", err);
    return encode_response(resp);
}

static char *handle_initialize(json_t *id, json_t *params)
{
    (void)params;
    json_t *result = json_object();
    json_object_set_new(result, "protocolVersion",
                        json_string(MC2DBD_PROTOCOL_VER));
    json_t *caps = json_object();
    json_t *tools_cap = json_object();
    json_object_set_new(tools_cap, "listChanged", json_false());
    json_object_set_new(caps, "tools", tools_cap);
    json_object_set_new(result, "capabilities", caps);
    json_t *info = json_object();
    json_object_set_new(info, "name", json_string("maludb_mc2dbd"));
    json_object_set_new(info, "version", json_string(MC2DBD_VERSION));
    json_object_set_new(result, "serverInfo", info);

    json_t *resp = make_envelope(id);
    json_object_set_new(resp, "result", result);
    return encode_response(resp);
}

static char *handle_tools_list(PGconn *conn, json_t *id)
{
    char err_buf[512] = {0};
    json_t *tools = db_tools_list(conn, err_buf, sizeof err_buf);
    if (!tools)
        return protocol_error(id, JSONRPC_INTERNAL_ERROR,
                              err_buf[0] ? err_buf : "tools/list failed");
    json_t *result = json_object();
    json_object_set_new(result, "tools", tools);
    json_t *resp = make_envelope(id);
    json_object_set_new(resp, "result", result);
    return encode_response(resp);
}

static char *handle_tools_call(PGconn *conn, json_t *id, json_t *params,
                               const char *request_user)
{
    if (!json_is_object(params))
        return protocol_error(id, JSONRPC_INVALID_PARAMS,
                              "tools/call params must be an object");
    const char *name = json_string_value(json_object_get(params, "name"));
    if (!name || !*name)
        return protocol_error(id, JSONRPC_INVALID_PARAMS,
                              "tools/call requires params.name");
    json_t *arguments = json_object_get(params, "arguments");
    /* arguments is optional but if present must be an object */
    if (arguments && !json_is_object(arguments))
        return protocol_error(id, JSONRPC_INVALID_PARAMS,
                              "tools/call params.arguments must be an object");

    char call_id[37];
    db_make_uuid(call_id);

    char err_buf[512] = {0};
    json_t *tool_meta = db_tool_lookup(conn, name, err_buf, sizeof err_buf);

    mc2dbd_tool_result tr;
    mc2dbd_tool_result_init(&tr);

    if (!tool_meta) {
        /* Tool-execution error, not protocol error: surface via
         * result.isError and audit it. */
        json_t *block = json_object();
        json_object_set_new(block, "type", json_string("text"));
        json_object_set_new(block, "text", json_string(err_buf[0] ? err_buf : "tool not found"));
        tr.is_error = true;
        tr.error_code = strdup(MC2DB_ERR_TOOL_NOT_FOUND);
        tr.error_message = strdup(err_buf[0] ? err_buf : "tool not found");
        tr.content = json_array();
        json_array_append_new(tr.content, block);
        db_audit_write(conn, call_id, 0, name, "unknown",
                       request_user, false,
                       MC2DB_ERR_TOOL_NOT_FOUND,
                       err_buf[0] ? err_buf : "tool not found", 0);
    } else {
        dispatch_tool(conn, call_id, tool_meta, arguments, request_user, &tr);
        json_decref(tool_meta);
    }

    json_t *result = json_object();
    json_object_set_new(result, "content",
        tr.content ? tr.content : json_array());
    if (tr.structured)
        json_object_set_new(result, "structuredContent", tr.structured);
    json_object_set_new(result, "isError", json_boolean(tr.is_error));
    json_t *meta = json_object();
    json_object_set_new(meta, "call_id", json_string(call_id));
    if (tr.error_code)
        json_object_set_new(meta, "error_code", json_string(tr.error_code));
    json_object_set_new(result, "_meta", meta);

    /* Ownership transferred above; clear before free. */
    tr.content = NULL;
    tr.structured = NULL;
    mc2dbd_tool_result_free(&tr);

    json_t *resp = make_envelope(id);
    json_object_set_new(resp, "result", result);
    return encode_response(resp);
}

char *mcp_handle_request(PGconn *conn,
                         const char *body,
                         size_t body_len,
                         const char *request_user)
{
    (void)body_len;
    json_error_t je;
    json_t *root = json_loads(body ? body : "", 0, &je);
    if (!root)
        return protocol_error(NULL, JSONRPC_PARSE_ERROR, je.text);

    json_t *id     = json_object_get(root, "id");
    json_t *method = json_object_get(root, "method");
    json_t *params = json_object_get(root, "params");

    if (!json_is_string(method)) {
        char *resp = protocol_error(id, JSONRPC_INVALID_REQUEST,
                                    "request must include a string method");
        json_decref(root);
        return resp;
    }
    const char *m = json_string_value(method);

    char *out;
    if (strcmp(m, "initialize") == 0) {
        out = handle_initialize(id, params);
    } else if (strcmp(m, "tools/list") == 0) {
        out = handle_tools_list(conn, id);
    } else if (strcmp(m, "tools/call") == 0) {
        out = handle_tools_call(conn, id, params, request_user);
    } else if (strcmp(m, "ping") == 0) {
        json_t *resp = make_envelope(id);
        json_object_set_new(resp, "result", json_object());
        out = encode_response(resp);
    } else {
        char buf[128];
        snprintf(buf, sizeof buf, "method not found: %s", m);
        out = protocol_error(id, JSONRPC_METHOD_NOT_FOUND, buf);
    }
    json_decref(root);
    return out;
}
