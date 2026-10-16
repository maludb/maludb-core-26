# `libmaludb` — C client for MaluDB

Native C library over libpq. Same surface (and exception
translation) as the [Python](../python/README.md),
[Node.js](../nodejs/README.md), and [PHP](../php/README.md) drivers,
restricted in v0.1.0 to the headline ingest + retrieve methods.

Status: **alpha, first cut.** v0.1.0 covers ~12 functions; the full
27-method matrix will land incrementally.

## Build requirements

| | |
|---|---|
| CMake | >= 3.16 |
| C standard | C11 |
| libpq | >= 16 (PGDG headers are fine) |
| Build system | gcc / clang with `-Wall -Wextra` clean |

On Ubuntu 24.04:

```bash
sudo apt install libpq-dev cmake build-essential pkg-config
```

## Build

```bash
cd drivers/c
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j
```

Produces:
- `build/libmaludb.so` (and `.so.0`, `.so.0.1.0` symlinks)
- `build/maludb_smoke` — the smoke test binary
- `build/maludb_example_ingest_to_replay` — the example
- `build/maludb.pc` — pkg-config metadata for downstream consumers

## Install

```bash
sudo cmake --install build
```

Default install prefix is `/usr/local`. Override with
`-DCMAKE_INSTALL_PREFIX=/usr` for system packaging.

## Run tests

```bash
MALUDB_TEST_DSN="postgresql:///maludb_bench?host=/var/run/postgresql" \
    ctest --test-dir build --output-on-failure
```

Tests skip if `MALUDB_TEST_DSN` is unset (CTest exit code 77 →
"skipped").

## Quickstart

```c
#include <maludb.h>
#include <stdio.h>
#include <stdlib.h>

int main(void) {
    maludb_t *m = maludb_connect("postgresql:///mydb?host=/var/run/postgresql");
    if (maludb_last_error_code(m) != MALUDB_OK) {
        fprintf(stderr, "connect: %s\n", maludb_last_error_message(m));
        maludb_close(m);
        return 1;
    }

    int64_t sp = maludb_register_source_package(
        m, "log",
        "oncall: 14:22Z api-gateway 5xx burst",
        "{\"uri\":\"log://oncall/2026-05-13\"}",
        NULL);

    int64_t c1 = maludb_register_claim(
        m, "api_gateway", "observed", "5xx_burst",
        "Initial 5xx surge at 14:22Z", sp, NULL);

    maludb_retrieval_hit_t *hits = NULL;
    size_t n = 0;
    if (maludb_retrieve(m, "api_gateway", NULL, 10, &hits, &n) == 0) {
        for (size_t i = 0; i < n; ++i) {
            printf("%s %lld %s\n",
                hits[i].object_type,
                (long long)hits[i].object_id,
                hits[i].strategy);
        }
    }
    maludb_free_retrieval_hits(hits, n);
    maludb_close(m);
    return 0;
}
```

Compile:

```bash
gcc -o myapp myapp.c $(pkg-config --cflags --libs maludb)
```

## API surface (v0.1.0)

| Group | Functions |
|---|---|
| Lifecycle | `maludb_connect`, `maludb_close` |
| Errors | `maludb_last_error_code`, `maludb_last_error_message` |
| Version | `maludb_version` |
| Ingest | `maludb_register_source_package`, `maludb_register_claim`, `maludb_register_fact`, `maludb_register_memory`, `maludb_register_episode` |
| Retrieve | `maludb_text_search`, `maludb_retrieve`, `maludb_replay_episode` |
| Memory | `maludb_free_source_hits`, `maludb_free_retrieval_hits` |

Active memory pools, skill runtime, and local-node sync are deferred
to v0.2.0; the SQL contracts are unchanged so the wrappers are
straightforward to add.

## Ownership rules

- Every `char *` returned by a `maludb_*` function is heap-allocated;
  caller frees with `free()`.
- Arrays of hits (`maludb_source_hit_t`, `maludb_retrieval_hit_t`)
  must be freed with the matching `maludb_free_*` function — these
  free both the array and every inner string.
- The `maludb_t *` handle owns the libpq connection and last-error
  storage. `maludb_close` releases both. Safe to pass `NULL`.

## Error model

`int64_t` returns: `> 0` on success, `-1` on failure. Inspect
`maludb_last_error_code(m)` and `maludb_last_error_message(m)` for
detail.

`int` returns (e.g. `maludb_text_search`): `0` on success, `< 0`
on failure.

Error codes map SQLSTATE classes to typed values:

| `maludb_errcode_t` | SQLSTATE |
|---|---|
| `MALUDB_OK` | 0 |
| `MALUDB_ERR_CONNECT` | connection failure |
| `MALUDB_ERR_NOT_FOUND` | P0002 / 02000 |
| `MALUDB_ERR_INVALID_PARAMETER` | 22023 / 22P02 |
| `MALUDB_ERR_OBJECT_NOT_IN_STATE` | 55000 |
| `MALUDB_ERR_CHECK_VIOLATION` | 23514 |
| `MALUDB_ERR_PERMISSION_DENIED` | 42501 |
| `MALUDB_ERR_GENERIC` | anything else |
