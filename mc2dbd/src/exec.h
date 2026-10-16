/* mc2dbd external_exec dispatcher — R1.1-1.
 *
 * Spawns a registered external executable per malu$mc2db_tool_external_exec,
 * pipes the call envelope as JSON on stdin, reads JSON from stdout,
 * captures stderr for audit, enforces timeout_ms from malu$mc2db_tool.
 *
 * Contract (release-1.0-requirements.md §9.1):
 *   stdin  : {"tool_name":..,"call_id":..,"arguments":..,"context":..}
 *   stdout : {"ok":true,"result":{...}}
 *          | {"ok":false,"error":{"code":"...","message":"..."}}
 *   stderr : free-form; first 4 KiB recorded into audit error_message
 *
 * Only command_path values starting with '/' are accepted. The child's
 * environment is scrubbed to a minimal allowlist plus the explicit
 * kv pairs from malu$mc2db_tool_external_exec.environment.
 */

#ifndef MC2DBD_EXEC_H
#define MC2DBD_EXEC_H

#include "common.h"
#include "dispatch.h"
#include <libpq-fe.h>

void dispatch_external_exec(PGconn *conn,
                            const char *call_id_uuid,
                            json_t *tool_meta,
                            json_t *arguments,
                            const char *request_user,
                            mc2dbd_tool_result *out);

#endif /* MC2DBD_EXEC_H */
