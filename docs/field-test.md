# MaluDB Release 1.0 — Field Test Acceptance Playbook

This is the acceptance procedure for closing R1.0 per
`release-1.0-requirements.md §13`. It wraps `docs/install.md` with the
21 numbered steps from the build plan and a sign-off template the
field tester fills in.

> **Scope.** A successful run on at least one Ubuntu 24.04 server —
> GPU **or** CPU per the policy below — with the deterministic CI path
> (pg_regress + mc2dbd service tests) green, is the gate for declaring
> R1.0 field-test ready.

## Hardware acceptance paths

R1.0 has two valid hardware paths. Pick one based on what's available:

| Path | Host | Recommended model | Step 4 outcome | Step 11 latency budget |
|---|---|---|---|---|
| **GPU** | Ubuntu 24.04 + CUDA NVIDIA GPU | any size that fits VRAM | PASS | a few seconds |
| **CPU** | Ubuntu 24.04, ≥ 8 GiB RAM | Q4-quantized ≤ 3B params (Qwen 2.5 0.5B, Llama 3.2 1B/3B, Phi 3.5 Mini) | WARN (acceptable — no GPU by design) | up to 60 s for short responses |

Both paths satisfy R1.0 acceptance. The MaluDB stack itself is
GPU-agnostic — only `llama-cli` actually uses the GPU when one is
present. Mark which path you're running at the top of §0 and plan
your model + prompt size accordingly.

## 0. Setup

| | |
|---|---|
| **Field tester** | _________________________ |
| **Date** | _________________________ |
| **Host** | hostname / cloud / VM provider |
| **OS** | Ubuntu 24.04.x LTS (`lsb_release -d`) |
| **Kernel** | `uname -r` |
| **CPU** | `lscpu | head -20` |
| **GPU** | `nvidia-smi -L` (or "none / CPU-only") |
| **Hardware path** | ☐ GPU acceptance ☐ CPU acceptance |
| **Local model** | name / parameter count / quantization (e.g. Qwen 2.5 0.5B Q4_K_M) |
| **MaluDB commit** | `git rev-parse HEAD` |
| **PG version** | `psql -V` |
| **pgvector version** | `psql -c "SELECT extversion FROM pg_extension WHERE extname='vector'"` |

## 1. Provisioning checklist

- [ ] Clean Ubuntu 24.04 LTS image (no prior MaluDB install).
- [ ] At least 4 CPU cores, 20 GiB free disk.
- [ ] **GPU path**: ≥ 4 GiB RAM, CUDA-capable NVIDIA GPU with driver installed; `nvidia-smi` works.
      **CPU path**: ≥ 8 GiB RAM (16 GiB recommended for 3B models); no GPU required.
- [ ] Outbound HTTPS reachable to `apt.postgresql.org` and `github.com`.
- [ ] Outbound HTTPS reachable to your model source (e.g. `huggingface.co`).
- [ ] Field tester has `sudo` privileges.

## 2. The 21 acceptance steps

Each step references a section of `install.md`. Capture **exact
command output** (paste in the report below or attach as a log file)
for any step that doesn't pass on the first try.

### Step 1 — Provision

Provision a clean Ubuntu 24.04 GPU server (or VM with NVIDIA
passthrough) and reach a shell.

- [ ] **PASS** / FAIL
- Notes: ________________________________________

### Step 2 — Install MaluDB

Follow `install.md` §1–§3:

```bash
sudo apt-get update && sudo apt-get -y upgrade
sudo apt-get install -y git curl ca-certificates
git clone <repo> ~/maludb-core
cd ~/maludb-core
git submodule update --init --recursive
./scripts/maludb-bootstrap --dry-run    # plan review
sudo ./scripts/maludb-bootstrap         # actually run
```

- [ ] Bootstrap exits 0
- [ ] Final line is `==> Bootstrap complete`
- [ ] **PASS** / FAIL
- Notes: ________________________________________

### Step 3 — Validate PostgreSQL 17, pgvector, and `maludb_core`

```bash
psql -d maludb -c "SELECT version()"
psql -d maludb -c "SELECT extname, extversion FROM pg_extension"
```

Pass criteria:
- PG version is 17.x
- `pg_extension` shows both `vector` and `maludb_core` (≥ 0.1.0)

- [ ] **PASS** / FAIL
- `extversion` for `maludb_core`: ___________

### Step 4 — Validate hardware (GPU readiness OR CPU-only acceptance)

```bash
./scripts/maludb-gpu-check
```

Pass criterion depends on the hardware path you chose in §0:

- **GPU acceptance path**: this script MUST exit 0 and report a
  detected NVIDIA GPU. If it doesn't, either your driver isn't
  installed or you should re-mark this run as CPU acceptance.
- **CPU acceptance path**: this script's WARN result is the expected
  outcome and counts as **PASS** for this step. Note in the comments
  that this is a CPU-only run by design.

| Result | GPU path | CPU path |
|---|---|---|
| script exits 0, GPU listed | PASS | (unexpected — note in artifacts) |
| script WARNs, no GPU | FAIL | **PASS** (by design) |
| script errors out | FAIL | FAIL (re-check install) |

- [ ] **PASS** / FAIL
- Hardware path: ☐ GPU ☐ CPU
- `nvidia-smi -L` output (or "no GPU" for CPU path): ________________________________________

### Step 5 — Register or install a local model

Pick a model sized for your hardware path:

| Path | Recommended models for this acceptance run |
|---|---|
| **GPU** | Any Q4-quantized model that fits VRAM. Llama 3.1 8B Instruct Q4_K_M is a reasonable default. |
| **CPU** | Qwen 2.5 0.5B Instruct Q4_K_M (~400 MB, ~50 tok/s — this is the smoke-test default). Llama 3.2 1B (~25 tok/s). Phi 3.5 Mini (~15 tok/s). |

Build llama.cpp and install a model:

```bash
# llama.cpp uses CMake. Bootstrap installs cmake; if you're starting
# from a host that didn't go through bootstrap, install it first:
#   sudo apt-get install -y cmake
#
# Build llama.cpp:
#   GPU path: make -C runtime cuda
#   CPU path: make -C runtime
make -C runtime
# Real copy, NOT a symlink — see install.md §7.1 for why ProtectHome
# breaks symlinks. Also install the shared libs llama-cli depends on.
sudo install -m 0755 $(pwd)/third_party/llama.cpp/build/bin/llama-cli /usr/local/bin/llama-cli
sudo install -m 0644 $(pwd)/third_party/llama.cpp/build/bin/lib*.so /usr/local/lib/
sudo ldconfig
llama-cli --version
ldd /usr/local/bin/llama-cli | head   # confirm no "not found"

# Drop a model in place. CPU acceptance default = Qwen 2.5 0.5B:
sudo install -d -o maludb_modeld -g maludb /var/lib/maludb/models
sudo curl -fsSL -o /var/lib/maludb/models/qwen2.5-0.5b.q4_k_m.gguf \
    https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/qwen2.5-0.5b-instruct-q4_k_m.gguf
sudo chown maludb_modeld:maludb /var/lib/maludb/models/*.gguf
```

- [ ] llama.cpp built (CPU or CUDA per chosen path)
- [ ] `.gguf` model present and readable by `maludb_modeld`
- [ ] **PASS** / FAIL
- Model used: ___________________________
- Quantization: ___________
- Notes: ________________________________________

### Step 6 — Start `maludb_modeld`

```bash
sudo systemctl enable --now maludb-modeld
systemctl status maludb-modeld --no-pager
```

Pass criterion: `Active: active (running)`. If it failed,
`journalctl -u maludb-modeld -n 50` should show the cause.

- [ ] **PASS** / FAIL
- Notes: ________________________________________

### Step 7 — Register a prompt template

```bash
sudo -u postgres psql -d maludb -c "
SELECT register_model_provider('local-llama','local_runtime','llama-cli',NULL,'internal');
SELECT register_model_alias('tiny','local-llama','qwen2.5-0.5b-instruct',
    '/var/lib/maludb/models/qwen2.5-0.5b.q4_k_m.gguf',
    NULL,'Q4_K_M',32768,'{\"temperature\":0,\"max_tokens\":256}'::jsonb);
SELECT register_prompt_template('r10-greet','Say hi to :name, briefly.');
"
```

- [ ] Provider, alias, and template registered without errors
- [ ] **PASS** / FAIL

### Step 8 — Start a model session

```bash
sudo -u postgres psql -d maludb -c "
INSERT INTO maludb_core.malu\$account(account_name, account_kind) VALUES ('fieldtest','human');
SELECT start_session('fieldtest','tiny','r10-greet');
"
```

Pass criterion: returns an integer session_id ≥ 1.

- [ ] **PASS** / FAIL
- session_id: ___________

### Step 9 — Append Session Context

```bash
SID=<session_id from Step 8>
sudo -u postgres psql -d maludb -c "
SELECT append_context($SID, 'system', 'be terse');
SELECT append_context($SID, 'user',   'about widgets');
"
```

- [ ] Two context_id values returned
- [ ] **PASS** / FAIL

### Step 10 — Render and submit a prompt

```bash
sudo -u postgres psql -d maludb -c "
SELECT render_prompt($SID, 'r10-greet', NULL, '{\"name\":\"world\"}'::jsonb);
"
RID=<render_id>
sudo -u postgres psql -d maludb -c "
SELECT submit_render($RID, 'tiny', 'fieldtest');
"
REQ=<request_id>
```

- [ ] render_id and request_id returned
- [ ] **PASS** / FAIL

### Step 11 — Read the response and audit metadata

Latency budget by hardware path:
- **GPU**: response in a few seconds. Bump the inner loop to 6 attempts × 5 s if you've picked a large model.
- **CPU**: small model (≤ 1B params) finishes within 10–30 s; 3B models can take up to 60 s. The polling loop below allows up to 60 s.

If the response is still pending after the budget, increase
`timeout_ms` in the `submit_render` call (e.g. 120000) or pick a
smaller model.

```bash
# Wait up to ~60s for maludb_modeld to fulfill the request
for i in $(seq 1 12); do
    R=$(sudo -u postgres psql -d maludb -tAc "SELECT status FROM maludb_core.malu\$model_response WHERE request_id=$REQ")
    echo "attempt $i: status=$R"
    [ "$R" = "succeeded" ] && break
    sleep 5
done

sudo -u postgres psql -d maludb -c "
SELECT response_id, status, finish_reason, length(output_text) AS output_chars,
       latency_ms, adapter_name
FROM maludb_core.malu\$model_response
WHERE request_id=$REQ;
"

sudo -u postgres psql -d maludb -c "
SELECT * FROM maludb_core.model_run_audit WHERE request_id=$REQ;
"
```

Pass criterion: `status='succeeded'`, `finish_reason='stop'`,
non-empty `output_text`, `adapter_name='llama-cli'`.

- [ ] **PASS** / FAIL
- output_chars: ___________
- latency_ms: ___________
- output sample (first 200 chars): ________________________________________

### Step 12 — Start `maludb_mc2dbd`

```bash
sudo systemctl enable --now maludb-mc2dbd
systemctl status maludb-mc2dbd --no-pager
```

- [ ] `Active: active (running)`
- [ ] **PASS** / FAIL

### Step 13 — Connect to `https://localhost:5329`

R1.0 default install uses plain HTTP on `127.0.0.1:5329`. To exercise
the HTTPS path:

```bash
# Enable TLS in the conf
sudoedit /etc/maludb/maludb-mc2dbd.conf   # set TLS=true and the cert/key paths
sudo systemctl restart maludb-mc2dbd

curl -fsSk https://127.0.0.1:5329/healthz
```

- [ ] `/healthz` returns `ok` over HTTPS
- [ ] **PASS** / FAIL

### Step 14 — Run MCP-shaped initialize

```bash
curl -fsSk -X POST https://127.0.0.1:5329/ \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize"}' | jq .
```

- [ ] Response carries `result.serverInfo.name == "maludb_mc2dbd"`
- [ ] `result.protocolVersion == "2025-11-25"`
- [ ] **PASS** / FAIL

### Step 15 — Run tool discovery

```bash
curl -fsSk -X POST https://127.0.0.1:5329/ \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
    | jq '.result.tools | length, [.[] | .name] | sort'
```

- [ ] Length is 14
- [ ] All 11 R1.0 `maludb.*` tools advertised plus the two
      `maludb.r10.*_demo` exemplars plus `maludb.memory.search.exact` (R1.1-14)
- [ ] **PASS** / FAIL

### Step 16 — Append/read Session Context through MC2DB

```bash
# Open a fresh session via the listener
curl -fsSk -X POST https://127.0.0.1:5329/ \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":3,"method":"tools/call",
         "params":{"name":"maludb.sessions.create",
                   "arguments":{"account_name":"fieldtest","alias_name":"tiny","template_name":"r10-greet"}}}' \
    | jq '.result.structuredContent'

# (capture session_id from output)
SID2=...

curl -fsSk -X POST https://127.0.0.1:5329/ \
    -H 'Content-Type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",
         \"params\":{\"name\":\"maludb.context.append\",
                     \"arguments\":{\"session_id\":$SID2,\"role\":\"system\",\"content_text\":\"test ctx\"}}}" \
    | jq '.result.structuredContent'

curl -fsSk -X POST https://127.0.0.1:5329/ \
    -H 'Content-Type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/call\",
         \"params\":{\"name\":\"maludb.context.read\",\"arguments\":{\"session_id\":$SID2}}}" \
    | jq '.result.structuredContent.blocks | length'
# → should be 1
```

- [ ] context.append returns ordinal=1
- [ ] context.read returns 1 block
- [ ] **PASS** / FAIL

### Step 17 — Submit a model request through MC2DB

```bash
curl -fsSk -X POST https://127.0.0.1:5329/ \
    -H 'Content-Type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"tools/call\",
         \"params\":{\"name\":\"maludb.prompts.render\",
                     \"arguments\":{\"session_id\":$SID2,\"template_name\":\"r10-greet\",
                                    \"variables\":{\"name\":\"MaluDB\"}}}}" \
    | jq '.result.structuredContent.render_id'
RID2=...

curl -fsSk -X POST https://127.0.0.1:5329/ \
    -H 'Content-Type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"tools/call\",
         \"params\":{\"name\":\"maludb.models.submit\",
                     \"arguments\":{\"render_id\":$RID2,\"alias_name\":\"tiny\"}}}" \
    | jq '.result.structuredContent'
REQ2=...
```

- [ ] models.submit returns `request_id`, `provider_kind="local_runtime"`,
      `response_id=null` (deferred to maludb_modeld)
- [ ] **PASS** / FAIL

### Step 18 — Read response through MC2DB

```bash
# Poll until the response lands
for i in $(seq 1 12); do
    OUT=$(curl -fsSk -X POST https://127.0.0.1:5329/ \
            -H 'Content-Type: application/json' \
            -d "{\"jsonrpc\":\"2.0\",\"id\":8,\"method\":\"tools/call\",
                 \"params\":{\"name\":\"maludb.responses.get\",
                             \"arguments\":{\"request_id\":$REQ2}}}")
    P=$(echo "$OUT" | jq -r '.result.structuredContent.pending')
    echo "attempt $i: pending=$P"
    [ "$P" = "false" ] && break
    sleep 5
done
echo "$OUT" | jq '.result.structuredContent.response | {status, finish_reason, output_text}'
```

- [ ] Eventually `pending=false`
- [ ] response.status = "succeeded"
- [ ] response.finish_reason = "stop"
- [ ] response.output_text non-empty
- [ ] **PASS** / FAIL

### Step 19 — Verify audit records

```bash
sudo -u postgres psql -d maludb -c "
SELECT call_id, tool_name, implementation_type, success, error_code, duration_ms
FROM maludb_core.malu\$mc2db_invocation
ORDER BY started_at DESC LIMIT 10;
"

sudo -u postgres psql -d maludb -c "
SELECT count(*) FROM maludb_core.malu\$mc2db_invocation
WHERE error_code = 'IMPL_TYPE_NOT_AVAILABLE';
"
# → should be 0 if you didn't call the deferred-type exemplars
```

- [ ] Recent invocations include `maludb.sessions.create`,
      `maludb.context.append`, `maludb.context.read`,
      `maludb.prompts.render`, `maludb.models.submit`,
      `maludb.responses.get`
- [ ] All `success=true`
- [ ] **PASS** / FAIL

### Step 20 — Verify no later-stage memory objects

```bash
sudo -u postgres psql -d maludb -c "
SELECT * FROM maludb_core.stage_boundary_violations();
"
```

Pass criterion: zero rows. R1.0 ships **zero** Stage 2+ memory
objects.

- [ ] **PASS** / FAIL

### Step 21 — Verify deferred-type rejection

```bash
curl -fsSk -X POST https://127.0.0.1:5329/ \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":9,"method":"tools/call",
         "params":{"name":"maludb.r10.external_exec_demo","arguments":{}}}' \
    | jq '.result | {isError, error_code: ._meta.error_code}'
# → {"isError": true, "error_code": "IMPL_TYPE_NOT_AVAILABLE"}

curl -fsSk -X POST https://127.0.0.1:5329/ \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":10,"method":"tools/call",
         "params":{"name":"maludb.r10.mcp_proxy_demo","arguments":{}}}' \
    | jq '.result | {isError, error_code: ._meta.error_code}'
```

- [ ] Both deferred-type exemplars return `isError=true`,
      `error_code=IMPL_TYPE_NOT_AVAILABLE`, **as a tool error**
      (not a JSON-RPC protocol error)
- [ ] **PASS** / FAIL

## 3. Final acceptance check

Run the validator one more time end-to-end:

```bash
./scripts/maludb-validate
```

- [ ] Exit code 0
- [ ] No FAIL lines
- [ ] WARN lines acceptable (GPU absent, etc.)

## 4. CI parity

Confirm the deterministic CI path remains green on the same checkout:

```bash
cd ~/maludb-core
make installcheck PG_CONFIG=/usr/lib/postgresql/17/bin/pg_config
make -C mc2dbd test
```

- [ ] All 12 pg_regress tests pass
- [ ] All 17 mc2dbd service tests pass

## 5. Sign-off

R1.0 is **field-test ready** when:

- [ ] All 21 steps PASS for the chosen hardware path
- [ ] On the CPU acceptance path, Step 4's WARN is recorded as PASS
      (it is the expected outcome, not a failure)
- [ ] Validator returns 0
- [ ] CI parity green

Field tester signature: _________________________________

Date: _________________________________

## 6. Capture artifacts

Attach to the field-test report:

- Output of `./scripts/maludb-bootstrap --dry-run`
- Final `./scripts/maludb-validate` output
- `git rev-parse HEAD`
- `psql -d maludb -c "SELECT extname, extversion FROM pg_extension"`
- `systemctl status maludb-mc2dbd maludb-modeld --no-pager`
- `journalctl -u maludb-mc2dbd --since '1 hour ago' --no-pager` (last 200 lines)
- `journalctl -u maludb-modeld --since '1 hour ago' --no-pager` (last 200 lines)
- `psql -d maludb -c "SELECT * FROM maludb_core.malu\$mc2db_invocation ORDER BY started_at DESC LIMIT 20"` output
- The Step 11 / Step 18 model response output text

## 7. Known acceptable WARNs

| Step | WARN reason | Acceptable when |
|---|---|---|
| Step 4 / validator GPU check | no NVIDIA GPU | CPU acceptance path (counts as PASS for that path) |
| validator pgvector demo empty | demo table seeded with no rows | always (R1.0-1 doesn't seed test rows) |
| validator listener not running | listener not yet started | between bootstrap and `systemctl start` |
| Step 6 / validator maludb_modeld | daemon not started yet | CPU/GPU paths both before §7's gateway enable |

## 8. Common field-test failures and recovery

| Symptom | Likely cause | Recovery |
|---|---|---|
| Step 11: `status='timeout'` | Model too large for available RAM/VRAM, or `LLAMA_CLI` missing. | Pick a smaller gguf or run on a GPU host. |
| Step 11: `status='failed'`, `error_class='MODEL_NOT_FOUND'` | Path mismatch or owner. | `ls -l /var/lib/maludb/models/`; ensure `maludb_modeld` can read it. |
| Step 17: `provider_kind='cloud_api'` and `error_class='ADAPTER_NOT_AVAILABLE'` | Wrong alias used (cloud not yet supported). | Use a `local_runtime` alias for R1.0. |
| Step 18: stays `pending=true` indefinitely | `maludb_modeld` not running, or stuck. | `systemctl status maludb-modeld`; `journalctl -u maludb-modeld -f`. |
| Step 14: `curl: (60) SSL certificate problem` | Self-signed cert + no `-k`. | Add `-k` or replace the cert with a CA-signed one. |
| Step 19: many invocations with `success=false` | A prior step's tool error. | Look at `error_code`; usually `BAD_INPUT` or `TOOL_NOT_FOUND` from earlier curl args. |

If you hit something not in this table, capture the full output and
file an issue with the artifacts from §6.
