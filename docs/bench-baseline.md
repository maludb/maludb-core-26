# MaluDB benchmark baseline (S7-1)

This document captures the **initial** performance baseline for the
maludb_core extension. It is intentionally small — a fixed fixture
exercised by three workloads — so future regressions can be detected
without arguing about test methodology. Replace these numbers with
fresh ones when the workload, fixture, or host changes.

## Scope

Three workloads:

| Script | Exercises |
|---|---|
| `bench/text_search.sql` | Cross-object FTS (`text_search`) across claim/fact/memory/episode_object. |
| `bench/retrieve.sql` | Full `execute_retrieval` orchestrator: planner → strategy dispatch → assembly filter → audit emission. |
| `bench/graph_walk.sql` | `graph_walk` depth-2 BFS over relationship edges starting from a random bench claim. |

Vector ANN, MAUT aggregation, and bitemporal `as_of` lookups are
**not** in v1 of the baseline; they require fixture changes (real
embeddings, MAUT subscores per object, supersession history). Land
those in later S7-1 refinements when the workloads merit them.

## Fixture

`bench/seed.sql` is idempotent and creates, scoped to the bench
namespace (`bench_*`):

| Table | Rows |
|---|---|
| `malu$claim` | 1000 |
| `malu$fact` | 300 |
| `malu$memory` | 200 |
| `malu$episode_object` | 100 |
| `malu$relationship_edge` (`fact` → `claim`) | 300 |
| `malu$relationship_edge` (`memory` → `claim`) | 200 |

Subjects rotate through 200 stems (`bench_subject_0` … `bench_subject_199`)
so search keys are reasonably distributed.

## How to run

```bash
# Defaults: db=maludb_bench, duration=30s, clients=4
./bench/run-baseline.sh

# Or override:
./bench/run-baseline.sh my_bench_db 60 8
```

The runner:

1. Creates the target db if missing.
2. `CREATE EXTENSION IF NOT EXISTS maludb_core CASCADE`.
3. Runs `seed.sql` (idempotent re-seed; deletes prior `bench_%` rows).
4. For each `*.sql` in `bench/` (excluding seed) runs `pgbench -n -T <s> -c <clients> -j <clients> -P 5`.
5. Captures stdout to `bench/results/<script>.out` and prints the
   latency / tps summary line.

## Captured baseline (2026-05-13)

Host: 16-core x86_64, 32 GiB RAM, Ubuntu 24.04. PostgreSQL 17.9 (PGDG)
single-host, default config, no tuning. maludb_core 0.40.0.

`pgbench -n -T 30 -c 4 -j 4`:

| Workload | latency avg | latency stddev | tps |
|---|---:|---:|---:|
| `text_search` | 1.04 ms | 0.38 ms | **3856** |
| `graph_walk` | 1.87 ms | 0.75 ms | **2135** |
| `retrieve` (full orchestrator) | 28.40 ms | 15.77 ms | **141** |

Observations:

- **`text_search` is GIN-bound and fast.** The generated `fts_tsv` column +
  GIN index from S4-2 carries the FTS path with no tuning.
- **`graph_walk` depth-2 BFS is sub-2 ms.** The recursive-CTE
  approach (S4-1) scales fine for moderate fan-out; the bench graph
  has ~500 edges total.
- **`retrieve` is roughly 14–28× slower than `text_search`** because
  the orchestrator does planning + audit + dedupe + assembly +
  confidence-floor + tombstone filtering, with VOLATILE side-effect
  writes (audit emission, temp-table churn). At 141 tps it still
  comfortably exceeds R1.0-class workloads. Optimization candidates,
  in order: skip audit row insertion for read-only retrieves under a
  GUC; cache the planner output across same-envelope calls; bypass
  the temp table for single-strategy plans.

## Regression watch

If a later commit drops any number below:

- `text_search` tps < 2500
- `graph_walk` tps < 1500
- `retrieve` tps < 80

…investigate before merging. These are advisory thresholds, not gates.

## Adding workloads

Drop a new `bench/<name>.sql` and re-run. The script convention is one
SQL statement (or a small batch) per transaction, parameterised via
`\set` so the workload exercises a range of inputs rather than a
single hot row.
