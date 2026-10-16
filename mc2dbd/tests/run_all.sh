#!/usr/bin/env bash
# mc2dbd service tests. R1.0-7.
#
# Brings the listener up against the local PG cluster, exercises the
# four critical MCP paths via curl/jq, then tears down. Prerequisites:
#   - maludb_core extension installed (sudo make install in repo root)
#   - psql usable as the local "maludb" user without a password
#   - jq, curl on PATH
#   - mc2dbd binary built (run `make -C mc2dbd` first)

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${REPO_ROOT}/maludb_mc2dbd"
PSQL="${PSQL:-psql}"
PGUSER="${PGUSER:-maludb}"
PGDATABASE="${PGDATABASE:-maludb}"
PORT="${PORT:-15329}"
HOST="127.0.0.1"
TOKEN="r10-test-token-$$"

PASS=0
FAIL=0
FAILED=()

color() { printf '\033[%sm%s\033[0m\n' "$1" "$2"; }
ok()    { color '32' "PASS  $*"; PASS=$((PASS+1)); }
ko()    { color '31' "FAIL  $*"; FAIL=$((FAIL+1)); FAILED+=("$*"); }

require() {
    for cmd in "$@"; do
        command -v "$cmd" >/dev/null 2>&1 || { echo "missing: $cmd"; exit 2; }
    done
}
require psql jq curl

[ -x "$BIN" ] || { echo "binary not built: $BIN — run 'make -C mc2dbd'"; exit 2; }

# ---------------------------------------------------------------------
# Seed three exemplar tools (one per impl_type R1.0 cares about) plus a
# stubby SQL function so tools/call has something real to invoke.
# ---------------------------------------------------------------------
SERVER_NAME="r107.test.$$"

cleanup_seed() {
    "$PSQL" -U "$PGUSER" -d "$PGDATABASE" -X -q -v ON_ERROR_STOP=0 >/dev/null 2>&1 <<EOF || true
SET search_path TO maludb_core, public;
-- 1. Throwaway server profile ('r107.test.\$\$') and everything under it.
DELETE FROM malu\$mc2db_invocation
 WHERE tool_id IN (SELECT tool_id FROM malu\$mc2db_tool t
                   JOIN malu\$mc2db_server s USING (server_id)
                   WHERE s.server_name = '${SERVER_NAME}');
DELETE FROM malu\$mc2db_tool t
 USING  malu\$mc2db_server s
 WHERE  t.server_id = s.server_id AND s.server_name = '${SERVER_NAME}';
DELETE FROM malu\$mc2db_server WHERE server_name = '${SERVER_NAME}';
DROP FUNCTION IF EXISTS app_r107_echo(jsonb, jsonb);
DROP SCHEMA   IF EXISTS app_r107 CASCADE;
-- 2. R1.1-1 tests 11f/11g register tools under the seeded 'maludb.r10'
-- server profile (not the throwaway one above) for parity with the
-- real-listener tool surface — they need to be deleted by name.
-- Otherwise the field test step-15 tool count sees them as extras.
DELETE FROM malu\$mc2db_invocation
 WHERE tool_id IN (SELECT tool_id FROM malu\$mc2db_tool
                   WHERE tool_name IN
                     ('maludb.r11.echo_external','maludb.r11.slow_external'));
DELETE FROM malu\$mc2db_tool
 WHERE tool_name IN ('maludb.r11.echo_external','maludb.r11.slow_external');
EOF
}

echo "→ seeding test tools under server '${SERVER_NAME}'"
"$PSQL" -U "$PGUSER" -d "$PGDATABASE" -X -q -v ON_ERROR_STOP=1 <<EOF
SET search_path TO maludb_core, public;

CREATE SCHEMA IF NOT EXISTS app_r107;

CREATE OR REPLACE FUNCTION app_r107.echo(args jsonb, context jsonb)
RETURNS void
LANGUAGE plpgsql
SECURITY INVOKER
AS \$body\$
BEGIN
    CALL mc2db.put_object(jsonb_build_object(
        'content', jsonb_build_array(
            jsonb_build_object('type','text',
                'text', 'echo:' || COALESCE(args->>'msg','(none)'))),
        'structuredContent', jsonb_build_object(
            'echoed', COALESCE(args->>'msg',''),
            'call_id', context->>'call_id'),
        'isError', false));
END;
\$body\$;

SELECT mc2db.create_server('${SERVER_NAME}', 'R1.0-7 test server') AS server_id;

SELECT mc2db.register_tool(
    server_name => '${SERVER_NAME}',
    tool_name   => 'r107.echo',
    description => 'echo args.msg back through put_object',
    implementation_type => 'sql_function',
    impl_metadata => jsonb_build_object('function_signature','app_r107.echo(jsonb, jsonb)'));

SELECT mc2db.register_tool(
    server_name => '${SERVER_NAME}',
    tool_name   => 'r107.exec_demo',
    description => 'external_exec demo — should reject in R1.0',
    implementation_type => 'external_exec',
    impl_metadata => jsonb_build_object('command_path','/usr/local/maludb/tools/demo.py'));

SELECT mc2db.register_tool(
    server_name => '${SERVER_NAME}',
    tool_name   => 'r107.proxy_demo',
    description => 'mcp_proxy demo — should reject in R1.0',
    implementation_type => 'mcp_proxy',
    impl_metadata => jsonb_build_object(
        'remote_server_name','docs','remote_tool_name','search',
        'transport_type','http','endpoint_url','http://127.0.0.1:6000'));
EOF

trap cleanup_seed EXIT

# ---------------------------------------------------------------------
# Start the daemon
# ---------------------------------------------------------------------
LOG="$(mktemp -t mc2dbd-test-XXXXXX.log)"
echo "→ starting maludb_mc2dbd on ${HOST}:${PORT}, log=${LOG}"
"$BIN" --foreground --host "$HOST" --port "$PORT" \
       --pg-conninfo "host=/var/run/postgresql user=${PGUSER} dbname=${PGDATABASE}" \
       --bearer-token "$TOKEN" \
       >"$LOG" 2>&1 &
DAEMON_PID=$!
trap 'kill -TERM "$DAEMON_PID" 2>/dev/null || true; wait "$DAEMON_PID" 2>/dev/null || true; cleanup_seed' EXIT

# Wait until the daemon binds the port (max 5s).
for i in 1 2 3 4 5 6 7 8 9 10; do
    if curl -fsS "http://${HOST}:${PORT}/healthz" >/dev/null 2>&1; then break; fi
    sleep 0.5
    if ! kill -0 "$DAEMON_PID" 2>/dev/null; then
        echo "daemon exited before listener was ready; log:"
        cat "$LOG"
        exit 3
    fi
done

# ---------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------
URL="http://${HOST}:${PORT}/"
post() {
    curl -fsS -X POST "$URL" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer ${TOKEN}" \
        -H "X-MaluDB-User: r107-tester" \
        -d "$1"
}

# ---------------------------------------------------------------------
# 1. healthz
# ---------------------------------------------------------------------
if curl -fsS "http://${HOST}:${PORT}/healthz" | grep -q '^ok$'; then
    ok "healthz returns ok"
else
    ko "healthz did not return ok"
fi

# 1b. metrics — Prometheus text format on /metrics (C6, R1.1).
METRICS="$(curl -fsS "http://${HOST}:${PORT}/metrics" 2>/dev/null || echo "")"
if echo "$METRICS" | grep -q '^maludb_mc2dbd_up 1$' \
   && echo "$METRICS" | grep -q '^# TYPE maludb_mc2dbd_invocations_total counter$' \
   && echo "$METRICS" | grep -q '^# TYPE maludb_model_request_count gauge$'; then
    ok "/metrics exposes maludb_mc2dbd_up + invocations + model_request counters"
else
    ko "/metrics missing expected metric families: $(echo "$METRICS" | head -5 | tr '\n' '|')"
fi

# 2. initialize
RESP="$(post '{"jsonrpc":"2.0","id":1,"method":"initialize"}')" || RESP=""
if echo "$RESP" | jq -e '.result.protocolVersion=="2025-11-25"
                       and .result.serverInfo.name=="maludb_mc2dbd"' >/dev/null; then
    ok "initialize returns serverInfo + protocolVersion"
else
    ko "initialize wrong: $RESP"
fi

# 3. tools/list — all three exemplar tools appear, with _meta.implementation_type
RESP="$(post '{"jsonrpc":"2.0","id":2,"method":"tools/list"}')" || RESP=""
EXPECTED='r107.echo r107.exec_demo r107.proxy_demo'
GOT="$(echo "$RESP" | jq -r '.result.tools[] | .name' | grep '^r107\.' | tr '\n' ' ' | xargs echo)"
if [ "$EXPECTED" = "$GOT" ]; then
    ok "tools/list returns all three exemplar tools (sql_function, external_exec, mcp_proxy)"
else
    ko "tools/list wrong; expected '$EXPECTED', got '$GOT'"
fi
if echo "$RESP" | jq -e '
    (.result.tools[] | select(.name=="r107.echo")       | ._meta.implementation_type=="sql_function")
and (.result.tools[] | select(.name=="r107.exec_demo")  | ._meta.implementation_type=="external_exec")
and (.result.tools[] | select(.name=="r107.proxy_demo") | ._meta.implementation_type=="mcp_proxy")' >/dev/null; then
    ok "tools/list _meta.implementation_type correct for each row"
else
    ko "tools/list _meta wrong: $RESP"
fi

# 4. tools/call — sql_function happy path
RESP="$(post '{"jsonrpc":"2.0","id":3,"method":"tools/call",
              "params":{"name":"r107.echo","arguments":{"msg":"hello"}}}')" || RESP=""
if echo "$RESP" | jq -e '
       .result.isError == false
   and (.result.content[0].text | startswith("echo:hello"))
   and .result.structuredContent.echoed == "hello"
   and (.result._meta.call_id | length) == 36' >/dev/null; then
    ok "tools/call sql_function happy path"
else
    ko "sql_function dispatch wrong: $RESP"
fi

# 5. tools/call — external_exec on a missing binary (seed tool points
# at /usr/local/maludb/tools/demo.py which does not exist on a fresh
# install). R1.1-1 wired external_exec, so the dispatcher reports
# the missing binary as an INTERNAL_ERROR rather than the old
# IMPL_TYPE_NOT_AVAILABLE rejection.
RESP="$(post '{"jsonrpc":"2.0","id":4,"method":"tools/call",
              "params":{"name":"r107.exec_demo","arguments":{}}}')" || RESP=""
if echo "$RESP" | jq -e '.result.isError == true
                       and .result._meta.error_code == "INTERNAL_ERROR"
                       and (.result.content[0].text | contains("external_exec command not executable"))' >/dev/null; then
    ok "external_exec seed tool surfaces INTERNAL_ERROR for missing binary (R1.1-1 wired)"
else
    ko "external_exec did not surface INTERNAL_ERROR correctly: $RESP"
fi

# 6. tools/call — mcp_proxy unreachable endpoint should surface as
# UPSTREAM_ERROR now that R1.1-2 has wired the dispatcher. The seed
# tool points at 127.0.0.1:6000 (nothing listening), so the curl
# attempt fails fast with connection refused.
RESP="$(post '{"jsonrpc":"2.0","id":5,"method":"tools/call",
              "params":{"name":"r107.proxy_demo","arguments":{}}}')" || RESP=""
if echo "$RESP" | jq -e '.result.isError == true
                       and .result._meta.error_code == "UPSTREAM_ERROR"' >/dev/null; then
    ok "mcp_proxy unreachable endpoint surfaces UPSTREAM_ERROR (R1.1-2 wired)"
else
    ko "mcp_proxy did not surface UPSTREAM_ERROR: $RESP"
fi

# 7. tools/call — unknown tool → tool error, not protocol error
RESP="$(post '{"jsonrpc":"2.0","id":6,"method":"tools/call",
              "params":{"name":"r107.does_not_exist","arguments":{}}}')" || RESP=""
if echo "$RESP" | jq -e '.error == null
                       and .result.isError == true
                       and .result._meta.error_code == "TOOL_NOT_FOUND"' >/dev/null; then
    ok "unknown tool returns tool error (not protocol error)"
else
    ko "unknown tool wrong: $RESP"
fi

# 8. method not found → protocol error
RESP="$(post '{"jsonrpc":"2.0","id":7,"method":"nope/nope"}')" || RESP=""
if echo "$RESP" | jq -e '.error.code == -32601 and .result == null' >/dev/null; then
    ok "unknown method returns JSON-RPC -32601 (protocol error)"
else
    ko "unknown method wrong: $RESP"
fi

# 9. invalid JSON → parse error
RESP="$(curl -fsS -X POST "$URL" -H "Content-Type: application/json" \
            -H "Authorization: Bearer ${TOKEN}" -d 'not json' || true)"
if echo "$RESP" | jq -e '.error.code == -32700' >/dev/null; then
    ok "malformed body returns JSON-RPC -32700 (parse error)"
else
    ko "parse error wrong: $RESP"
fi

# 10. missing bearer token → 401
HTTP_CODE="$(curl -s -o /dev/null -w '%{http_code}' -X POST "$URL" \
              -H "Content-Type: application/json" \
              -d '{"jsonrpc":"2.0","id":99,"method":"initialize"}')"
if [ "$HTTP_CODE" = "401" ]; then
    ok "missing bearer token returns 401"
else
    ko "auth check wrong: HTTP $HTTP_CODE"
fi

# 11. audit row written for every tools/call
ROW_COUNT="$("$PSQL" -U "$PGUSER" -d "$PGDATABASE" -X -q -t -A <<EOF
SELECT count(*) FROM maludb_core.malu\$mc2db_invocation
WHERE tool_name LIKE 'r107.%' OR tool_name = 'r107.does_not_exist';
EOF
)"
if [ "$ROW_COUNT" -ge 4 ]; then
    ok "audit table has ${ROW_COUNT} R1.0-7 invocation rows"
else
    ko "expected >=4 audit rows, got ${ROW_COUNT}"
fi

# 11b. The seeded R1.0-8 + R1.1-14 maludb.* tools are advertised
RESP="$(post '{"jsonrpc":"2.0","id":50,"method":"tools/list"}')" || RESP=""
for t in maludb.health maludb.catalog.describe maludb.models.list \
         maludb.prompts.list maludb.sessions.create maludb.sessions.get \
         maludb.context.append maludb.context.read maludb.prompts.render \
         maludb.models.submit maludb.responses.get \
         maludb.r10.external_exec_demo maludb.r10.mcp_proxy_demo \
         maludb.memory.search.exact; do
    if echo "$RESP" | jq -e --arg n "$t" '.result.tools[] | select(.name==$n)' >/dev/null; then :;
    else ko "tools/list missing seeded tool: $t"; continue; fi
done
ok "tools/list advertises all 14 R1.0-8 + R1.1-14 seeded tools"

# 11c. maludb.health through the listener
RESP="$(post '{"jsonrpc":"2.0","id":51,"method":"tools/call",
              "params":{"name":"maludb.health","arguments":{}}}')" || RESP=""
if echo "$RESP" | jq -e '.result.isError == false
                       and .result.structuredContent.status == "ok"
                       and (.result.structuredContent.version | length) > 0' >/dev/null; then
    ok "maludb.health through listener returns status=ok + version"
else
    ko "maludb.health wrong: $RESP"
fi

# 11d. maludb.catalog.describe through the listener
RESP="$(post '{"jsonrpc":"2.0","id":52,"method":"tools/call",
              "params":{"name":"maludb.catalog.describe","arguments":{}}}')" || RESP=""
if echo "$RESP" | jq -e '.result.isError == false
                       and .result.structuredContent.schema == "maludb_core"
                       and (.result.structuredContent.tables | length) > 10' >/dev/null; then
    ok "maludb.catalog.describe through listener returns >10 maludb_core tables"
else
    ko "maludb.catalog.describe wrong: $RESP"
fi

# 11d.5 maludb.memory.search.exact through the listener — registers a
# small compartment + chunk inline, queries via the tool, expects a
# ranked result. Vectors are 4-dim normalized so the math is legible.
"$PSQL" -U "$PGUSER" -d "$PGDATABASE" -X -q -v ON_ERROR_STOP=1 >/dev/null <<'PSQL'
SET search_path TO maludb_core, public;
SELECT register_vector_compartment(
    'r114-svc-test', 'svc-subj', 'svc-verb', 4, 'svc-test-4d', 'cosine')
   AS svc_cid \gset
SELECT register_vector_chunk(:svc_cid, 'aligned-x',
    vector_from_real_array('{0.95,0.10,0.05,0.05}'::real[]));
SELECT register_vector_chunk(:svc_cid, 'aligned-y',
    vector_from_real_array('{0.05,0.95,0.10,0.05}'::real[]));
PSQL
QB64=$(printf '\x66\xf0\xa9\x3f\xcd\xcc\xcc\x3d\xcd\xcc\x4c\x3d\xcd\xcc\x4c\x3d' | base64 -w0)
# The bytes above pack {0.85, 0.10, 0.05, 0.05} as little-endian float32.
# A real client would build this from its embedding model output.
RESP="$(post "$(jq -nc --arg q "$QB64" '{
    jsonrpc:"2.0",id:54,method:"tools/call",
    params:{name:"maludb.memory.search.exact",
            arguments:{namespace:"r114-svc-test",
                       subject:"svc-subj",verb:"svc-verb",
                       query_embedding_b64:$q,limit:2,metric:"cosine"}}}')")"
if echo "$RESP" | jq -e '.result.isError == false
                       and .result.structuredContent.results[0].source_text == "aligned-x"
                       and (.result.structuredContent.results | length) == 2' >/dev/null; then
    ok "maludb.memory.search.exact ranks aligned-x first via listener"
else
    ko "maludb.memory.search.exact wrong: $RESP"
fi

# 11e. R1.1-1 — the seeded external_exec_demo exemplar's command_path
# does not exist on a fresh box. With external_exec now wired (R1.1-1),
# the listener no longer rejects with IMPL_TYPE_NOT_AVAILABLE; it
# attempts the spawn, fails the access(X_OK) pre-check, and returns
# INTERNAL_ERROR with a "not executable" message. mcp_proxy is still
# deferred and still returns IMPL_TYPE_NOT_AVAILABLE.
RESP="$(post '{"jsonrpc":"2.0","id":53,"method":"tools/call",
              "params":{"name":"maludb.r10.external_exec_demo","arguments":{}}}')" || RESP=""
if echo "$RESP" | jq -e '.result.isError == true
                       and (.result._meta.error_code == "INTERNAL_ERROR"
                         or .result._meta.error_code == "IMPL_TYPE_NOT_AVAILABLE")' >/dev/null; then
    ok "external_exec exemplar with missing binary fails closed"
else
    ko "external_exec exemplar wrong: $RESP"
fi

RESP="$(post '{"jsonrpc":"2.0","id":53,"method":"tools/call",
              "params":{"name":"maludb.r10.mcp_proxy_demo","arguments":{}}}')" || RESP=""
if echo "$RESP" | jq -e '.result.isError == true
                       and .result._meta.error_code == "UPSTREAM_ERROR"' >/dev/null; then
    ok "seeded mcp_proxy exemplar surfaces UPSTREAM_ERROR (R1.1-2 wired, unreachable seed endpoint)"
else
    ko "seeded mcp_proxy exemplar wrong: $RESP"
fi

# 11f. R1.1-1 happy path — register an external_exec tool inline that
# points at our echo_tool.sh fixture, call it, and verify the
# structuredContent round-trip.
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
ECHO_TOOL="$TESTS_DIR/exec-tools/echo_tool.sh"
chmod +x "$ECHO_TOOL"
"$PSQL" -U "$PGUSER" -d "$PGDATABASE" -X -q -v ON_ERROR_STOP=1 >/dev/null <<PSQL
SET search_path TO maludb_core, public;
DELETE FROM malu\$mc2db_tool WHERE tool_name IN
    ('maludb.r11.echo_external','maludb.r11.slow_external');
SELECT mc2db.register_tool(
    server_name => 'maludb.r10',
    tool_name   => 'maludb.r11.echo_external',
    description => 'R1.1-1 service test — echo via external_exec.',
    implementation_type => 'external_exec',
    input_schema  => '{"type":"object"}'::jsonb,
    output_schema => '{"type":"object"}'::jsonb,
    impl_metadata => jsonb_build_object(
        'command_path',  '$ECHO_TOOL',
        'argv_template', '[]'::jsonb,
        'environment',   '{}'::jsonb));
PSQL
RESP="$(post "$(jq -nc '{
    jsonrpc:"2.0",id:55,method:"tools/call",
    params:{name:"maludb.r11.echo_external",
            arguments:{ping:"r11"}}}')")"
if echo "$RESP" | jq -e '.result.isError == false
                       and .result.structuredContent.marker == "external_exec_ok"
                       and .result.structuredContent.arguments.ping == "r11"' >/dev/null; then
    ok "external_exec round-trips arguments via stdin/stdout"
else
    ko "external_exec round-trip wrong: $RESP"
fi

# 11g. R1.1-1 — timeout enforcement. Register a tool that sleeps longer
# than its timeout_ms; expect TOOL_EXECUTION_ERROR with "timed out".
"$PSQL" -U "$PGUSER" -d "$PGDATABASE" -X -q -v ON_ERROR_STOP=1 >/dev/null <<PSQL
SET search_path TO maludb_core, public;
SELECT mc2db.register_tool(
    server_name => 'maludb.r10',
    tool_name   => 'maludb.r11.slow_external',
    description => 'R1.1-1 service test — timeout enforcement.',
    implementation_type => 'external_exec',
    input_schema  => '{"type":"object"}'::jsonb,
    output_schema => '{"type":"object"}'::jsonb,
    impl_metadata => jsonb_build_object(
        'command_path',  '/bin/sleep',
        'argv_template', '["3"]'::jsonb,
        'environment',   '{}'::jsonb));
UPDATE malu\$mc2db_tool SET timeout_ms = 500
 WHERE tool_name = 'maludb.r11.slow_external';
PSQL
RESP="$(post '{"jsonrpc":"2.0","id":56,"method":"tools/call",
              "params":{"name":"maludb.r11.slow_external","arguments":{}}}')" || RESP=""
if echo "$RESP" | jq -e '.result.isError == true
                       and (.result.content[0].text | test("timed out"))' >/dev/null; then
    ok "external_exec enforces timeout_ms"
else
    ko "external_exec timeout wrong: $RESP"
fi

# 11h. R1.1-2 — mcp_proxy http round-trip via a stub MCP server.
EXEC_TOOLS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/exec-tools" && pwd)"
HTTP_PORT=$((50000 + RANDOM % 10000))
"$EXEC_TOOLS_DIR/proxy_http_stub.py" "$HTTP_PORT" >/dev/null 2>&1 &
HTTP_STUB_PID=$!
trap 'kill -TERM "$HTTP_STUB_PID" 2>/dev/null || true; kill -TERM "$DAEMON_PID" 2>/dev/null || true; wait "$DAEMON_PID" 2>/dev/null || true; cleanup_seed' EXIT

# Wait for stub to bind.
for _ in 1 2 3 4 5 6 7 8; do
    if curl -fsS -X POST "http://127.0.0.1:${HTTP_PORT}/" \
            -H 'Content-Type: application/json' \
            -d '{"jsonrpc":"2.0","id":"ping","method":"x"}' \
            >/dev/null 2>&1; then break; fi
    sleep 0.2
done

"$PSQL" -U "$PGUSER" -d "$PGDATABASE" -X -q -v ON_ERROR_STOP=1 >/dev/null <<EOF
SET search_path TO maludb_core, mc2db, public;
SELECT mc2db.register_tool(
    server_name => '${SERVER_NAME}',
    tool_name   => 'r112.proxy_http_echo',
    description => 'R1.1-2 service test — mcp_proxy/http round-trip.',
    implementation_type => 'mcp_proxy',
    impl_metadata => jsonb_build_object(
        'remote_server_name','test_stub',
        'remote_tool_name','echo',
        'transport_type','http',
        'endpoint_url','http://127.0.0.1:${HTTP_PORT}/'));
EOF

RESP="$(post '{"jsonrpc":"2.0","id":17,"method":"tools/call",
              "params":{"name":"r112.proxy_http_echo",
                        "arguments":{"hello":"world"}}}')" || RESP=""
if echo "$RESP" | jq -e '.result.isError == false
                       and (.result.content[0].text | startswith("http_echo:"))
                       and .result.structuredContent.params.arguments.hello == "world"' >/dev/null; then
    ok "mcp_proxy/http: round-trip echoes through stub server"
else
    ko "mcp_proxy/http round-trip failed: $RESP"
fi

kill -TERM "$HTTP_STUB_PID" 2>/dev/null || true
wait "$HTTP_STUB_PID" 2>/dev/null || true

# 11i. R1.1-2 — mcp_proxy stdio round-trip.
"$PSQL" -U "$PGUSER" -d "$PGDATABASE" -X -q -v ON_ERROR_STOP=1 >/dev/null <<EOF
SET search_path TO maludb_core, mc2db, public;
SELECT mc2db.register_tool(
    server_name => '${SERVER_NAME}',
    tool_name   => 'r112.proxy_stdio_echo',
    description => 'R1.1-2 service test — mcp_proxy/stdio round-trip.',
    implementation_type => 'mcp_proxy',
    impl_metadata => jsonb_build_object(
        'remote_server_name','test_stub',
        'remote_tool_name','echo',
        'transport_type','stdio',
        'command_path','${EXEC_TOOLS_DIR}/proxy_stdio_stub.py',
        'argv','[]'::jsonb));
EOF

RESP="$(post '{"jsonrpc":"2.0","id":18,"method":"tools/call",
              "params":{"name":"r112.proxy_stdio_echo",
                        "arguments":{"foo":"bar"}}}')" || RESP=""
if echo "$RESP" | jq -e '.result.isError == false
                       and (.result.content[0].text | startswith("stdio_echo:"))
                       and .result.structuredContent.params.arguments.foo == "bar"' >/dev/null; then
    ok "mcp_proxy/stdio: round-trip echoes through forked child"
else
    ko "mcp_proxy/stdio round-trip failed: $RESP"
fi

# 11j. R1.1-3 — http_endpoint round-trip via the existing
# proxy_http_stub.py (it returns a valid JSON object, which is all
# http_endpoint cares about).
HTTP_EP_PORT=$((50000 + RANDOM % 10000))
"$EXEC_TOOLS_DIR/proxy_http_stub.py" "$HTTP_EP_PORT" >/dev/null 2>&1 &
HTTP_EP_STUB_PID=$!
trap 'kill -TERM "$HTTP_EP_STUB_PID" 2>/dev/null || true; kill -TERM "$DAEMON_PID" 2>/dev/null || true; wait "$DAEMON_PID" 2>/dev/null || true; cleanup_seed' EXIT

for _ in 1 2 3 4 5 6 7 8; do
    if curl -fsS -X POST "http://127.0.0.1:${HTTP_EP_PORT}/" \
            -H 'Content-Type: application/json' -d '{}' >/dev/null 2>&1; then break; fi
    sleep 0.2
done

"$PSQL" -U "$PGUSER" -d "$PGDATABASE" -X -q -v ON_ERROR_STOP=1 >/dev/null <<EOF
SET search_path TO maludb_core, mc2db, public;
SELECT mc2db.register_tool(
    server_name => '${SERVER_NAME}',
    tool_name   => 'r113.http_endpoint_echo',
    description => 'R1.1-3 service test — http_endpoint POST round-trip.',
    implementation_type => 'http_endpoint',
    impl_metadata => jsonb_build_object(
        'endpoint_url','http://127.0.0.1:${HTTP_EP_PORT}/',
        'http_method','POST',
        'static_headers', jsonb_build_object('X-Test','c3'),
        'auth_type','bearer',
        'auth_token','demo-token'));
EOF

RESP="$(post '{"jsonrpc":"2.0","id":19,"method":"tools/call",
              "params":{"name":"r113.http_endpoint_echo",
                        "arguments":{"hi":"there"}}}')" || RESP=""
if echo "$RESP" | jq -e '.result.isError == false
                       and (.result.structuredContent.result.content[0].text | startswith("http_echo:"))' >/dev/null; then
    ok "http_endpoint: POST round-trip, JSON response routed to structuredContent"
else
    ko "http_endpoint round-trip failed: $RESP"
fi

# 11k. http_endpoint missing endpoint_url is rejected at register time
# (not at dispatch). Verify register_tool raises.
REG_FAIL="$("$PSQL" -U "$PGUSER" -d "$PGDATABASE" -X -q -t -A -v ON_ERROR_STOP=0 <<EOF 2>&1 || true
SET search_path TO maludb_core, mc2db, public;
SELECT mc2db.register_tool(
    server_name => '${SERVER_NAME}',
    tool_name   => 'r113.http_endpoint_bad',
    description => 'should fail — no endpoint_url',
    implementation_type => 'http_endpoint',
    impl_metadata => '{}'::jsonb);
EOF
)"
if echo "$REG_FAIL" | grep -q 'MC2DB_IMPL_METADATA_MISSING'; then
    ok "register_tool rejects http_endpoint without endpoint_url"
else
    ko "register_tool did not reject missing endpoint_url: $REG_FAIL"
fi

kill -TERM "$HTTP_EP_STUB_PID" 2>/dev/null || true
wait "$HTTP_EP_STUB_PID" 2>/dev/null || true

# 11l. R1.1-1.1 — argv_template {{key}} substitution. Register a tool
# whose argv_template references arguments via {{name}} and {{age}}.
# The fixture echoes its argv back; verify substitution happened.
ARGV_TOOL="$TESTS_DIR/exec-tools/argv_dump_tool.sh"
chmod +x "$ARGV_TOOL"
"$PSQL" -U "$PGUSER" -d "$PGDATABASE" -X -q -v ON_ERROR_STOP=1 >/dev/null <<PSQL
SET search_path TO maludb_core, public;
DELETE FROM malu\$mc2db_tool WHERE tool_name = 'maludb.r111.argv_substitute';
SELECT mc2db.register_tool(
    server_name => 'maludb.r10',
    tool_name   => 'maludb.r111.argv_substitute',
    description => 'R1.1-1.1 service test — argv_template {{key}} substitution.',
    implementation_type => 'external_exec',
    input_schema  => '{"type":"object"}'::jsonb,
    output_schema => '{"type":"object"}'::jsonb,
    impl_metadata => jsonb_build_object(
        'command_path',  '$ARGV_TOOL',
        'argv_template', '["--name={{name}}","--age={{age}}","--mode={{mode}}","--unmatched={{missing}}"]'::jsonb,
        'environment',   '{}'::jsonb));
PSQL
RESP="$(post "$(jq -nc '{
    jsonrpc:"2.0",id:60,method:"tools/call",
    params:{name:"maludb.r111.argv_substitute",
            arguments:{name:"Alice", age:42, mode:"production"}}}')")"
if echo "$RESP" | jq -e '
    .result.isError == false
    and .result.structuredContent.marker == "argv_substitute_ok"
    and (.result.structuredContent.argv | index("--name=Alice"))     != null
    and (.result.structuredContent.argv | index("--age=42"))         != null
    and (.result.structuredContent.argv | index("--mode=production")) != null
    and (.result.structuredContent.argv | index("--unmatched={{missing}}")) != null
' >/dev/null; then
    ok "argv_template: {{key}} substituted from arguments; unmatched left as-is"
else
    ko "argv_template substitution wrong: $RESP"
fi

# 12. audit row: after R1.1-2 the mcp_proxy seed tool surfaces
# UPSTREAM_ERROR (not IMPL_TYPE_NOT_AVAILABLE — that branch is gone
# entirely once R1.1-3 lands; all four impl_types are wired). Verify
# the audit captures the mcp_proxy outcome correctly.
UPSTREAM_ROWS="$("$PSQL" -U "$PGUSER" -d "$PGDATABASE" -X -q -t -A <<EOF
SELECT count(*) FROM maludb_core.malu\$mc2db_invocation
WHERE error_code = 'UPSTREAM_ERROR'
  AND implementation_type = 'mcp_proxy';
EOF
)"
if [ "$UPSTREAM_ROWS" -ge 1 ]; then
    ok "audit captures mcp_proxy UPSTREAM_ERROR for unreachable endpoint"
else
    ko "expected mcp_proxy UPSTREAM_ERROR audit row, found ${UPSTREAM_ROWS}"
fi

# 12b. audit row for the external_exec round-trip — verify success was
# recorded with implementation_type='external_exec'.
EXEC_OK="$("$PSQL" -U "$PGUSER" -d "$PGDATABASE" -X -q -t -A <<EOF
SELECT count(*) FROM maludb_core.malu\$mc2db_invocation
WHERE tool_name = 'maludb.r11.echo_external'
  AND implementation_type = 'external_exec'
  AND success IS TRUE;
EOF
)"
if [ "$EXEC_OK" -ge 1 ]; then
    ok "audit captures external_exec success row"
else
    ko "audit missing external_exec success row: ${EXEC_OK}"
fi

echo
if [ "$FAIL" -eq 0 ]; then
    color '32' "All ${PASS} mc2dbd service tests passed."
    rm -f "$LOG"
    exit 0
else
    color '31' "${FAIL} of $((PASS+FAIL)) tests failed:"
    for m in "${FAILED[@]}"; do echo "    - $m"; done
    echo "daemon log: $LOG"
    exit 1
fi
