/* mc2dbd PG access layer — libpq wrappers, active context, audit. */

#ifndef MC2DBD_DB_H
#define MC2DBD_DB_H

#include "common.h"
#include <libpq-fe.h>

/* Acquire / release a PG connection. R1.0 opens one per request — small
 * load and keeps state contamination away from the listener. */
PGconn *db_open(const mc2dbd_config *cfg);
void    db_close(PGconn *conn);

/* JSON-shaped result helpers. Each returns NULL on error and writes
 * a user-safe message into err_buf (size errsz). */
json_t *db_tools_list(PGconn *conn, char *err_buf, size_t errsz);

/* Tool lookup. Caller checks result is non-NULL; on success returns
 * a json object with: tool_id, tool_name, implementation_type,
 * input_schema, output_schema, enabled, plus type-specific keys (e.g.
 * function_signature for sql_function). */
json_t *db_tool_lookup(PGconn *conn, const char *tool_name,
                       char *err_buf, size_t errsz);

/* Begin / end an MC2DB active-request context. _begin assigns the
 * call_id; _end returns the accumulated payload (or NULL on missing). */
bool    db_begin_request(PGconn *conn, const char *call_id_uuid,
                         const char *tool_name, char *err_buf, size_t errsz);
json_t *db_end_request(PGconn *conn, char *err_buf, size_t errsz);

/* Write one row to malu$mc2db_invocation. */
bool    db_audit_write(PGconn *conn,
                       const char *call_id_uuid,
                       int64_t tool_id_or_zero,
                       const char *tool_name,
                       const char *implementation_type,
                       const char *request_user,
                       bool success,
                       const char *error_code,
                       const char *error_message,
                       int duration_ms);

/* Generate a v4-shaped UUID string into out (must be >= 37 bytes). */
void    db_make_uuid(char out[37]);

/* Collect Prometheus-formatted metrics. Returns a heap-allocated text
 * buffer (caller frees) or NULL on error (err_buf populated). Output
 * uses the Prometheus exposition format with HELP/TYPE comments. */
char   *db_metrics_text(PGconn *conn, char *err_buf, size_t errsz);

#endif /* MC2DBD_DB_H */
