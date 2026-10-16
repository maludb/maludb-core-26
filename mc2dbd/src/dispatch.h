/* mc2dbd polymorphic dispatcher. R1.0-7. */

#ifndef MC2DBD_DISPATCH_H
#define MC2DBD_DISPATCH_H

#include "common.h"
#include "db.h"

/* Return shape from a tool dispatch. The caller wraps this into the
 * MCP tools/call result envelope (or treats it as a tool error). */
typedef struct mc2dbd_tool_result {
    bool      is_error;       /* set MCP result.isError */
    char     *error_code;     /* IMPL_TYPE_NOT_AVAILABLE etc. for audit */
    char     *error_message;  /* user-safe message */
    json_t   *content;        /* optional MCP content array */
    json_t   *structured;     /* optional MCP structuredContent */
} mc2dbd_tool_result;

void mc2dbd_tool_result_init(mc2dbd_tool_result *r);
void mc2dbd_tool_result_free(mc2dbd_tool_result *r);

/* Dispatch a tool call. tool_meta is what db_tool_lookup returned.
 * On return r->is_error tells the caller whether to surface as a tool
 * execution error; protocol errors are handled at a higher layer. */
void dispatch_tool(PGconn *conn,
                   const char *call_id_uuid,
                   json_t *tool_meta,
                   json_t *arguments,
                   const char *request_user,
                   mc2dbd_tool_result *out);

#endif /* MC2DBD_DISPATCH_H */
