# V4 PageIndex / ChatIndex bench harness

Reference fixtures + a runner that publishes recall / latency
baselines for the V4 descent surface. Companion to plan §12
acceptance criterion 9 ("benchmark fixtures publish baseline
recall / latency for the fixture PDF + chat corpora") and to
plan §11.2 ("LLM-driven descent latency … cap depth at a
configurable value (default 6); benchmark p95 against fixture
queries").

## Layout

```
bench/v4/
├── README.md                       — this file
├── run-bench                       — entrypoint
└── fixtures/
    ├── reference.md                — small markdown doc (multi-level)
    ├── reference.txt               — plain text fallback
    └── chat.jsonl                  — chat transcript fixture
```

PDF fixtures are not committed — they're generated on the fly by
`run-bench` via `pypdf.PdfWriter` so the repo stays text-only.

## Running

```bash
# Default DB is contrib_regression.
bench/v4/run-bench

# Or against a named DB:
MALUDB_BENCH_DB=maludb bench/v4/run-bench

# JSON output (machine-readable) for CI:
bench/v4/run-bench --json
```

## What the bench measures

For each fixture + cue pair:

| Metric | Definition |
|---|---|
| `descent_latency_ms_p50` | median wall-clock for `retrieve_with_envelope_tree` over N trials |
| `descent_latency_ms_p95` | 95th percentile |
| `depth_reached`          | leaf depth the descent terminus landed at |
| `cue_match`              | whether the descent landed on the leaf the fixture says is the answer |

The harness does NOT use a live model — it relies on the
deterministic `overlap` choice strategy (V4-PAGEINDEX-03) so the
baselines are reproducible. When the `llm` choice strategy lands
(post-GA), the same harness can be rerun with
`--choice llm --model-alias <id>` to compare.

## Acceptance gating

For rc.1 we publish the baselines; for v4.0.0 GA we require the
p95 descent latency under the deterministic strategy to be
< 100 ms on the fixture corpus on the build host. If the strategy
is later swapped to `llm`, the latency budget grows but the
recall floor (≥ 0.8 over the fixture queries) is the gate.
