# maludb CLI

V3-CLI-01 — first-party command-line tool for MaluDB.

`maludb` operates the memory DBMS through the stable SQL APIs (and,
once `maludb-restd` is running, the REST gateway). It replaces the
growing collection of single-purpose shell scripts under `scripts/`
with one binary that supports human and JSON output for every
subcommand.

## Install

```bash
pip install -e cli/maludb[test]
```

## Connection

The CLI reads the standard `MALUDB_*` environment variables (matching
the project's existing Python driver):

```
MALUDB_DB        # required
MALUDB_HOST
MALUDB_PORT
MALUDB_USER
MALUDB_PASSWORD
```

Every flag can also be passed on the command line (`--db`, `--host`, …).

## Subcommand families

| Family            | Status   | Backing                                     |
|-------------------|----------|---------------------------------------------|
| `status`          | shipped  | `maludb_core_version`, catalog counts.      |
| `install doctor`  | shipped  | preflight: PG version, extensions, roles.   |
| `db upgrade`      | shipped  | `ALTER EXTENSION maludb_core UPDATE`.       |
| `db backup`       | shipped  | wraps `pg_dump` + writes a sidecar manifest.|
| `db restore-check`| shipped  | verifies the dump file against the manifest.|
| `auth token *`    | shipped  | V3-AUTH-01 helpers.                         |
| `secret *`        | shipped  | V3-SECRET-01 helpers.                       |
| `model *`         | shipped  | `register_model_alias`, catalog reads.      |
| `prompt *`        | shipped  | `render_prompt`, `preview_prompt`.          |
| `tool *`          | shipped  | `mc2db.register_tool`, catalog reads.       |
| `retrieve`        | shipped  | `execute_retrieval` (Stage 4 entrypoint).   |
| `replay`          | shipped  | `replay_episode` (Stage 5 entrypoint).      |
| `source *`        | shipped  | V3-STOR-01: adapter-register / put / get / verify / list / promote (local_fs end-to-end; s3 catalog-only). |
| `queue *`         | shipped  | V3-QUEUE-01: enqueue / list / drain / retry.|
| `cron *`          | shipped  | V3-CRON-01: create / enable / disable / run-now / tick. |
| `realtime *`      | shipped  | V3-REALTIME-01: subscribe / list / fetch / ack / tail. |
| `metrics scrape`  | preview  | Catalog-derived; V3-OBS-01 ships server-side.|

## Output

Pass `--format json` to get machine-readable output. Default is
human-readable text aligned to column widths.

## Audit

Every state-changing subcommand routes through the same SQL helpers
the rest of the project uses, so audit (`malu$audit_event`,
`malu$auth_token_use`, etc.) lands automatically.

## Smoke test

```bash
make installcheck PG_CONFIG=/usr/lib/postgresql/17/bin/pg_config   # populates contrib_regression
cd cli/maludb
PYTHONPATH=src python3 -m pytest tests/
```
