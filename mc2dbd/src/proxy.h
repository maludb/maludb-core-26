/* mc2dbd MCP proxy dispatcher. R1.1-2.
 *
 * Forwards tools/call to a remote MCP server registered as
 * implementation_type='mcp_proxy'. Supports two transports:
 *   - http   POST JSON-RPC to endpoint_url (libcurl)
 *   - stdio  fork+exec command_path with argv, one-shot
 *            request/response over the child's stdin/stdout
 *
 * Remote JSON-RPC errors surface as MC2DB tool-execution errors.
 * Transport-level failures (refused connection, timeout, malformed
 * response) are recorded as UPSTREAM_ERROR for audit clarity.
 */

#ifndef MC2DBD_PROXY_H
#define MC2DBD_PROXY_H

#include "dispatch.h"

void dispatch_mcp_proxy(PGconn *conn,
                        const char *call_id_uuid,
                        json_t *tool_meta,
                        json_t *arguments,
                        const char *request_user,
                        mc2dbd_tool_result *out);

/* libcurl lifecycle. Call once at listener startup / shutdown. */
void proxy_global_init(void);
void proxy_global_cleanup(void);

#endif /* MC2DBD_PROXY_H */
