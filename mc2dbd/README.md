# maludb_mc2dbd — MC2DB Listener (R1.0-7)

`maludb_mc2dbd` is the C sidecar that exposes MaluDB as an MCP-compatible
HTTP endpoint. R1.0 listens by default on `https://localhost:5329`,
implements `initialize` / `tools/list` / `tools/call`, and dispatches
`sql_function` tools through governed PostgreSQL sessions. Other
`implementation_type` values (`external_exec`, `mcp_proxy`,
`http_endpoint`) are accepted in the catalog but rejected at call time
with a tool-execution error of code `IMPL_TYPE_NOT_AVAILABLE`. R1.1 will
fill in those dispatchers.

See `release-1.0-build-plan.md §9` and `docs/maludb-mc2dbd-contract.md`
for the full service contract.

## Build

```
sudo apt-get install -y \
    libpq-dev libmicrohttpd-dev libjansson-dev libgnutls28-dev pkg-config
make -C mc2dbd
```

The build does not depend on PGXS — it is a separate binary that links
against `libpq`, `libmicrohttpd`, and `libjansson`. The PostgreSQL
extension `maludb_core` is consumed at runtime via SQL, not at link
time.

## Run (development)

```
./mc2dbd/maludb_mc2dbd \
    --host 127.0.0.1 --port 5329 \
    --pg-conninfo "host=/var/run/postgresql user=maludb dbname=maludb"
```

Verify:

```
curl -s http://127.0.0.1:5329/healthz   # → ok
curl -s -X POST http://127.0.0.1:5329/ \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize"}'
```

## Run (production-ish)

```
sudo make -C mc2dbd install
sudo useradd --system --no-create-home --shell /usr/sbin/nologin maludb_mc2dbd
sudo install -d -o maludb_mc2dbd -g maludb_mc2dbd /var/log/maludb
sudoedit /etc/maludb/maludb-mc2dbd.conf       # set PG_CONNINFO, TLS, etc.
sudo systemctl daemon-reload
sudo systemctl enable --now maludb-mc2dbd
sudo systemctl status maludb-mc2dbd
```

## TLS

The listener supports two modes:

1. **Native TLS** via libmicrohttpd's GnuTLS support. Set `TLS=true`,
   `TLS_CERT=...`, `TLS_KEY=...` in the conf file. R1.0 expects PEM-encoded
   files readable by the daemon user.
2. **NGINX terminator**. Run the listener as plain HTTP on `127.0.0.1:5329`
   and put NGINX in front to terminate HTTPS. This is the simpler path
   for deployments that already standardize on NGINX for cert lifecycle.

For local development, plain HTTP on `127.0.0.1:5329` (TLS off) is the
default.

## Authentication

If `BEARER_TOKEN` (or env `MALUDB_MC2DBD_TOKEN`) is set, every request
must carry `Authorization: Bearer <token>`. If unset, the listener
accepts unauthenticated requests — development only. Per-account auth
(per `release-1.0-requirements.md §10`) is deferred to **R1.1-7**.

## Tests

```
make -C mc2dbd test
```

Requires that `maludb_core` is already installed (`sudo make install &&
make installcheck` in the repo root) and that the local PG cluster is
reachable by the user running the tests. The harness:

1. Picks a free port,
2. Seeds a temporary `mc2db` server profile and three exemplar tools
   (one per supported implementation_type),
3. Starts `maludb_mc2dbd` in the foreground,
4. Exercises `initialize`, `tools/list`, `tools/call` happy path
   (`sql_function`), `tools/call` deferred-type rejection, and protocol
   errors via `curl`/`jq`,
5. Tears the listener down and removes the temporary tools.

Each step prints `PASS` or `FAIL`. The script exits non-zero on any
failure.

## File map

| File | Purpose |
|---|---|
| `Makefile`                       | non-PGXS build, install, test |
| `src/main.c`                     | entry, signal handling, PG probe |
| `src/http.c` `src/http.h`        | libmicrohttpd glue, body buffering, auth |
| `src/mcp.c` `src/mcp.h`          | initialize / tools/list / tools/call |
| `src/dispatch.c` `src/dispatch.h`| polymorphic dispatcher (sql_function only in R1.0) |
| `src/db.c` `src/db.h`            | libpq wrappers, active-context, audit |
| `src/common.h`                   | shared types and constants |
| `etc/maludb-mc2dbd.conf.example` | systemd EnvironmentFile template |
| `systemd/maludb-mc2dbd.service`  | systemd unit |
| `tests/run_all.sh`               | bash+curl service harness |
