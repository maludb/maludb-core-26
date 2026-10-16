/* mc2dbd http_endpoint dispatcher. R1.1-3.
 *
 * Generic HTTP-call dispatcher: invoke a REST endpoint with the
 * MCP tool's `arguments` jsonb as the request body (for POST/PUT/PATCH),
 * apply static_headers + optional auth, parse the response body as
 * JSON (structured) or text (fallback). Transport-level failures
 * surface as UPSTREAM_ERROR; non-2xx responses also surface as
 * UPSTREAM_ERROR with a body excerpt.
 *
 * libcurl-backed; relies on proxy_global_init() / proxy_global_cleanup()
 * to manage the global curl lifecycle (no separate init for this
 * dispatcher).
 */

#ifndef MC2DBD_HTTP_ENDPOINT_H
#define MC2DBD_HTTP_ENDPOINT_H

#include "dispatch.h"

void dispatch_http_endpoint(PGconn *conn,
                            const char *call_id_uuid,
                            json_t *tool_meta,
                            json_t *arguments,
                            const char *request_user,
                            mc2dbd_tool_result *out);

#endif /* MC2DBD_HTTP_ENDPOINT_H */
