# `maludb` — Python driver for MaluDB

Synchronous Python 3.10+ client for the maludb_core extension.

Status: **alpha**. v0.1.0 covers the headline read/write surface;
async support, full MAUT API, and the workflow-extraction helpers
land in subsequent versions.

## Install

```bash
pip install maludb
```

Or from this source tree:

```bash
# One-time host setup on Ubuntu 24.04:
sudo apt install python3-venv

cd drivers/python
python3 -m venv .venv
source .venv/bin/activate
pip install -e '.[test]'
```

Alternative: use the Debian-packaged psycopg 3 directly without a venv:

```bash
sudo apt install python3-psycopg
# Then add drivers/python/src to PYTHONPATH:
export PYTHONPATH=/path/to/maludb-core/drivers/python/src
```

## Quickstart

```python
from maludb import MaluDBClient

with MaluDBClient.from_dsn("postgresql:///mydb") as client:
    # 1. Record a source.
    sp = client.register_source_package(
        source_type="log",
        content_text="oncall: 14:22Z api-gateway 5xx burst",
        origin={"uri": "log://oncall/2026-05-13"})

    # 2. Raise two claims citing the source.
    c1 = client.register_claim(
        subject="api_gateway", verb="observed", object_value="5xx_burst",
        statement_text="Initial 5xx surge at 14:22Z",
        source_package_id=sp)
    c2 = client.register_claim(
        subject="api_gateway", verb="timed_out", object_value="health_probe",
        statement_text="Health probe exceeded 2s",
        source_package_id=sp)

    # 3. Verify into a fact.
    f1 = client.register_fact(
        claim_ids=[c1, c2],
        subject="api_gateway", verb="incident", object_value="latency_breach",
        statement_text="Latency SLO breach root cause identified",
        verification_method="oncall_review")

    # 4. Retrieve.
    for hit in client.retrieve("api_gateway", limit=10):
        print(hit.object_type, hit.object_id, hit.rank)
```

## Available methods

| Group | Methods |
|---|---|
| Ingest | `register_source_package`, `register_claim`, `register_fact`, `register_memory`, `register_episode` |
| Retrieve | `text_search`, `retrieve`, `replay_episode` |
| Pool | `create_pool`, `pool_add_observation`, `pool_promote_to_claim`, `pool_seal` |
| Skill | `register_skill`, `add_skill_state`, `add_skill_transition`, `begin_skill_execution`, `step_skill_execution`, `abort_skill_execution` |
| Node | `register_local_node`, `node_submit`, `node_accept`, `node_reject`, `revoke_local_node` |
| Misc | `transaction()` context manager, `version()`, `raw` (the underlying `psycopg.Connection`) |

Every method maps 1:1 to a maludb_core SQL function. Read the
[admin guide](../../docs/admin-guide.md) for what each does.

## Exception hierarchy

```
MaluDBError
├── MaluDBNotFound                       (P0002 / 02000)
├── MaluDBInvalidParameter               (22023 / 22P02)
├── MaluDBObjectNotInPrerequisiteState   (55000)
├── MaluDBCheckViolation                 (23514)
└── MaluDBPermissionDenied               (42501)
```

Catch the specific class when you care about the failure mode.
Otherwise `except MaluDBError` covers them all.

## Running tests

The test suite needs a running PostgreSQL with the `maludb_core`
extension installed in the target database. Set `MALUDB_TEST_DSN`
to point at it:

```bash
export MALUDB_TEST_DSN="postgresql:///maludb_bench"
cd drivers/python
pytest -v
```

Tests are conservative: they create their own row data with a
unique `py-driver-test-%s` namespace and clean up at the end.
