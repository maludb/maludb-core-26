# MaluDB local model runtime

This document covers the Release 1.0 Phase R1.0-2 deliverables: the
vendored `llama.cpp` runtime, its build orchestration, and the GPU and
runtime readiness scripts. The PostgreSQL extension build (PGXS, top-level
`Makefile`) does **not** depend on this runtime — they are deliberately
separate so the database can install on a host that has no GPU and no
local model.

## What's vendored

`llama.cpp` is a git submodule pinned to release tag **`b9019`** at:

```
third_party/llama.cpp
```

After cloning the MaluDB repo for the first time, fetch the submodule:

```bash
git submodule update --init --recursive
```

The pin moves only when this repo's tracked submodule SHA changes. Updating
it is a deliberate engineering act: bump the tag, re-test the readiness
scripts, and document any GGUF compatibility implications.

## Building the runtime

The runtime build lives in `runtime/Makefile` and drives `llama.cpp`'s own
CMake build. CPU is the default. CUDA is opt-in.

```bash
# CPU release build (default)
make -C runtime

# CUDA build (requires NVIDIA toolchain)
make -C runtime cuda
# or equivalently
make -C runtime GGML_CUDA=1

# Inspect resolved paths
make -C runtime print

# Wipe the build directory entirely
make -C runtime distclean
```

Outputs land under `third_party/llama.cpp/build/bin/`:

| Path | Role |
|---|---|
| `third_party/llama.cpp/build/bin/llama-cli` | CLI smoke-test driver used by `maludb-model-runtime-check`. |
| `third_party/llama.cpp/build/bin/libllama.so` | Shared library; the Stage 1.5 model gateway will link against this. |

The runtime build is **never** invoked by `make` at the repo root, by
`make installcheck`, or by the `maludb_core` extension install path. If you
only need the database substrate, you can skip the runtime build entirely.

## GPU readiness — `scripts/maludb-gpu-check`

```text
Usage: maludb-gpu-check [--dev] [--quiet] [--json]
```

Exit codes:

| Code | Meaning |
|---:|---|
| `0` | NVIDIA GPU + driver visible (or `--dev` and the host is CPU-only). |
| `1` | No usable GPU and `--dev` was not supplied. |
| `2` | Bad arguments. |

Field-test installs **must** pass without `--dev`. CPU-only dev hosts and
CI may use `--dev`, in which case the script emits a warning and exits 0
but reports `field_test_ready: false` in `--json` output. CPU-only is
explicitly **not** a release-1.0 field-test posture; it exists so
developers without a GPU can still run regression tests, lint, and the
model-gateway stub adapter.

## Runtime readiness — `scripts/maludb-model-runtime-check`

```text
Usage: maludb-model-runtime-check [--mode=stub|local] [options]
```

Two modes:

- **`--mode=stub`** (default) — deterministic, hardware-free path for CI
  and dev hosts that have not built `llama.cpp`. Hashes the prompt with
  SHA256, emits a fixed reply token, and exits 0. Same prompt always
  produces the same `prompt_hash`, which is what the Stage 1.5 model
  gateway will use to validate the deterministic stub adapter.
- **`--mode=local`** — exercises the real runtime. Verifies that
  `llama-cli` exists and is executable, that `--model` resolves to a real
  GGUF file, that an optional `--expect-hash` (SHA256) matches the file,
  and runs a bounded `--max-tokens=N` smoke completion. Exit code from
  `llama-cli` is the success signal.

Common options across modes: `--quiet`, `--json`, `-h|--help`.

`--mode=local` options: `--bin=PATH`, `--model=PATH`, `--expect-hash=HEX`,
`--prompt=TEXT`, `--max-tokens=N`. If `--bin` is omitted it defaults to
`third_party/llama.cpp/build/bin/llama-cli` (i.e. the vendored build).

## What "field-test ready" means in R1.0

A host is field-test ready for Release 1.0 when **all** of the following
hold:

1. `scripts/maludb-gpu-check` exits 0 without `--dev`.
2. The `runtime` Makefile has built successfully with `GGML_CUDA=1`.
3. `scripts/maludb-model-runtime-check --mode=local --model=...` exits 0
   against the operator's chosen GGUF model with a matching SHA256.
4. The PostgreSQL substrate gate from R1.0-1 still passes (`make
   installcheck`).

CI does not need to satisfy 1–3. CI must satisfy 4 plus
`maludb-gpu-check --dev` and `maludb-model-runtime-check --mode=stub`.

## Open question (deferred)

Whether the Stage 1.5 model gateway loads `libllama` directly (in-process
worker) or controls a separately launched `llama-cli` over IPC remains
open per `requirements.md` §10 and `mc2db-white-paper.md` §12. Both paths
are compatible with the readiness scripts as written.
