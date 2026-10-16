# maludb-pageindexd

MaluDB PageIndex / ChatIndex builder daemon. Promotes Source Packages to
navigable trees by running a deterministic structure pass followed by
per-node LLM summarization through the MaluDB model gateway.

V4 implementation. Per-ticket scope and acceptance criteria live in
[`../../version4-pageindex-plan.md`](../../version4-pageindex-plan.md);
the conceptual brief lives in
[`../../docs/pageindex/PageIndex_Technology_Guide.md`](../../docs/pageindex/PageIndex_Technology_Guide.md).

## Components

| Layer | Status | Notes |
|---|---|---|
| Parser package (`maludb_pageindexd.parsers`) | **v4.0.0-alpha.2 (V4-PARSER-01)** | Pluggable `PageIndexParser` Protocol with `pypdf` (BSD-3-Clause), markdown (stdlib), and plain-text implementations. |
| Builder worker | V4-PAGEINDEX-02 | Polls the `pageindex_build` queue, runs structure pass, calls `maludb_modeld` for per-node summaries, writes node + ledger rows transactionally. |
| Service entrypoint | V4-PAGEINDEX-02 | `python3 -m maludb_pageindexd` / `maludb-pageindexd`. |

## Why a pluggable parser interface

PDF parsing has a long tail of corner cases (embedded outlines vs.
heading detection, scanned PDFs, vendor-specific font encodings).
MaluDB ships `pypdf` as the default because it is BSD-3-Clause and
packaged in Ubuntu 24.04 as `python3-pypdf`. Operators who already
accept AGPL terms or hold a commercial license can plug in PyMuPDF,
pdfminer.six, or a hosted vision parser by implementing the
`PageIndexParser` Protocol — no code change to MaluDB itself.

## Install (development)

```bash
sudo apt-get install -y python3-pypdf
PYTHONPATH=src python3 -m pytest tests/
```

The service does **not** require pip; system packages are sufficient.

## Doctrine

The deterministic structure pass MUST NOT call the LLM. Boundary
decisions come from PDF outlines, markdown headers, or
message-author/timestamp anchors. Only summarization calls
`maludb_modeld`. This is what makes a re-derived tree under a new
model alias produce identical leaf ranges (and a fresh set of
summaries) — see `version4-pageindex-plan.md` §9.2.
