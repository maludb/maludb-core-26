/* mc2dbd common types and constants — Phase R1.0-7 */

#ifndef MC2DBD_COMMON_H
#define MC2DBD_COMMON_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <jansson.h>

#define MC2DBD_VERSION       "0.1.0"
#define MC2DBD_PROTOCOL_VER  "2025-11-25"
#define MC2DBD_DEFAULT_HOST  "127.0.0.1"
#define MC2DBD_DEFAULT_PORT  5329
#define MC2DBD_MAX_BODY      (4 * 1024 * 1024)   /* 4 MiB MCP request cap */

/* Tool-execution error codes returned to the MCP client through
 * result.isError = true. These are MaluDB-specific and surface in the
 * audit row's error_code column. */
#define MC2DB_ERR_TOOL_NOT_FOUND       "TOOL_NOT_FOUND"
#define MC2DB_ERR_TOOL_DISABLED        "TOOL_DISABLED"
#define MC2DB_ERR_IMPL_NOT_AVAILABLE   "IMPL_TYPE_NOT_AVAILABLE"
#define MC2DB_ERR_BAD_INPUT            "BAD_INPUT"
#define MC2DB_ERR_TOOL_EXECUTION       "TOOL_EXECUTION_ERROR"
#define MC2DB_ERR_UPSTREAM             "UPSTREAM_ERROR"
#define MC2DB_ERR_INTERNAL             "INTERNAL_ERROR"

/* JSON-RPC 2.0 protocol error codes (top-level error{}). */
#define JSONRPC_PARSE_ERROR     -32700
#define JSONRPC_INVALID_REQUEST -32600
#define JSONRPC_METHOD_NOT_FOUND -32601
#define JSONRPC_INVALID_PARAMS  -32602
#define JSONRPC_INTERNAL_ERROR  -32603

typedef struct mc2dbd_config {
    char *bind_host;       /* default 127.0.0.1 */
    int   bind_port;       /* default 5329 */
    char *pg_conninfo;     /* libpq connection string */
    char *bearer_token;    /* if set, require Authorization: Bearer <this> */
    bool  tls_enabled;
    char *tls_cert_path;
    char *tls_key_path;
    bool  foreground;      /* don't daemonize */
} mc2dbd_config;

void mc2dbd_log(const char *level, const char *fmt, ...)
    __attribute__((format(printf, 2, 3)));

#define LOG_INFO(fmt, ...)  mc2dbd_log("info",  fmt, ##__VA_ARGS__)
#define LOG_WARN(fmt, ...)  mc2dbd_log("warn",  fmt, ##__VA_ARGS__)
#define LOG_ERROR(fmt, ...) mc2dbd_log("error", fmt, ##__VA_ARGS__)

#endif /* MC2DBD_COMMON_H */
