# V3-VEC-02 — Vector benchmark harness

Reproducible recall + latency measurement for MaluDB's vector path.
Closes the v3.1 V3-VEC-01 follow-up "bench fixtures so recall /
latency can be measured against a reproducible corpus."

## Why

R1.1-12 / V3-VEC-01 shipped the substrate (single-layer NSW in
`src/maludb_ann.c`, three index kinds in `malu$vector_index_status`:
`exact`, `nsw`, `hnsw_local`, `hnsw_pgvector`) but provided no way
for operators to measure the trade-off between them on their own
corpus. `scripts/maludb-bench-vector` is that measurement.

## Quick start

```bash
MALUDB_BENCH_DB=contrib_regression \
    scripts/maludb-bench-vector --corpus 256 --queries 32 --dim 16
```

The default knobs are sized for a regression cluster (runs in a few
seconds). For a realistic workload, scale `--corpus` and `--queries`
proportional to your live data.

```
corpus            256
dim               16
queries           32
k                 10
insert_ms         412.17
exact_median_ms   1.42
exact_p95_ms      2.91
match_min         10
match_max         10
```

Every run writes a summary blob to `malu$vector_index_status.recall_sample`
via `vector_index_record(...)`. Trending the recall_sample column over
time tells you whether tuning changes regressed recall.

## Reproducibility

* Corpus + queries are generated from `--seed` (default
  `20260514`) using `random.Random`. Same seed → same vectors.
* Vectors are L2-normalised; cosine distance is `1 - dot_product`.
* Insert order is deterministic (loop over the seeded corpus).
* `vector_index_record` writes happen with the operator's
  current_schema → tenant isolation preserved.

## Index kinds

v3.1 ships measurement against the **exact** baseline only — that
is the load-bearing assertion ("recall@k should be 1.0 by
construction"). Comparing **nsw** / **hnsw_local** / **hnsw_pgvector**
recall against the same baseline is straightforward extension once
the corresponding search functions land at SQL level:

| Kind | Status |
|---|---|
| `exact` | full scan via `vector_dot_product`; recall@k = 1.0 |
| `nsw` | local single-layer Navigable Small-World (R1.1-16); SQL surface needed |
| `hnsw_local` | multilevel HNSW; **not yet shipped** — future V3-VEC-03 |
| `hnsw_pgvector` | pgvector `CREATE INDEX ... USING hnsw`; needs a parallel `vector` column because `malu_vector` is our own type |

Each ANN kind, once wired, plugs into the bench by replacing the
exact-search SQL block with a call to its top-k function. The
recall-vs-exact computation stays unchanged.

## Operator workflow

```
# Baseline.
MALUDB_BENCH_DB=mytenant scripts/maludb-bench-vector \
    --corpus 10000 --queries 200 --dim 384 \
    > baseline.json

# After a tuning change (M / ef_construction / ef_search).
MALUDB_BENCH_DB=mytenant scripts/maludb-bench-vector \
    --corpus 10000 --queries 200 --dim 384 \
    > post_change.json

diff <(jq '{recall_sample}' baseline.json) \
     <(jq '{recall_sample}' post_change.json)
```

## CI

The pg_regress test `vector_bench` exercises the catalog side:
inserts ten chunks into a `bench`-namespaced compartment, calls
`vector_dot_product` for an exact-search assertion, and asserts a
`vector_index_record` row was written. The Python harness is run
ad-hoc by operators — adding it to `make installcheck` would slow
the regression suite without measurably increasing coverage.

## Future work (post-v3.1)

* **V3-VEC-03**: ship a real multilevel HNSW in `src/maludb_ann.c`
  with M / Mmax / ef_construction / ef_search knobs and a
  `vector_search_hnsw(compartment_id, query, k, ef_search)` SQL
  wrapper. The bench harness already has a slot for the alternate
  search call; only the `recall@k` numerator changes.
* **V3-VEC-04**: pgvector HNSW integration. Build a parallel
  `vector` column or use a generated column cast from `malu_vector`,
  then `CREATE INDEX USING hnsw`. Catalog already accepts the
  `hnsw_pgvector` kind so the only new surface is the builder
  helper.
