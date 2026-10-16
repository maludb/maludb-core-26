/* mc2dbd MCP protocol handlers. R1.0-7. */

#ifndef MC2DBD_MCP_H
#define MC2DBD_MCP_H

#include "common.h"
#include "db.h"

/* Build a JSON-RPC 2.0 response from a request body string.
 * Returns a heap-allocated JSON string; caller frees with free(). */
char *mcp_handle_request(PGconn *conn,
                         const char *body,
                         size_t body_len,
                         const char *request_user);

#endif /* MC2DBD_MCP_H */
