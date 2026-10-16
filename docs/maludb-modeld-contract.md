# `maludb_modeld` service contract

This document describes the database-side contract that the eventual
`maludb_modeld` service binary will honor. It is the same contract the
in-database deterministic stub adapter (`maludb_core.mc_stub_process`)
already implements, so any provider — local, cloud, or stub — is
behaviorally substitutable from the database's perspective.

The binary itself is **not** part of Phase R1.0-3. R1.0-3 ships the SQL
contract and the stub adapter; the real binary lands once R1.0-4
(Session Context + prompt rendering) and R1.0-5 (end-to-end submit) have
proven the contract is right.

## Roles

| Actor | Role |
|---|---|
| Caller (Stage 1.5+ application, MC2DB tool, or test) | Calls `maludb_core.submit_request(...)` to enqueue work, then `maludb_core.get_response(request_id)` to read the result. |
| `maludb_modeld` (this service) | Polls `malu$model_request` for `status='pending'`, dispatches to the matching provider adapter, and writes the result row. |
| Provider adapter (local llama.cpp, cloud OpenAI/Anthropic/etc., stub) | Owned by `maludb_modeld`. Receives a request payload, produces an output, returns to the service. |
| Database (PostgreSQL) | Authoritative store of every request, response, status transition, and audit field. The service holds no durable state. |

## Tables

`malu$model_request` and `malu$model_response` are the only durable
state. Schemas in `sql/extension/maludb_core--0.1.0.sql`. Service writes go through
the SQL APIs below, **not** by direct DML against the tables, so status
transitions stay in one place.

## SQL APIs

| Function | Used by | Purpose |
|---|---|---|
| `register_model_provider(name, kind, adapter_name, secret_ref, data_sensitivity)` | Operator | Insert provider; `kind` ∈ {local, cloud, stub}. |
| `register_model_alias(alias, provider, model_identifier, model_path, model_hash, quantization, context_length, runtime_params)` | Operator | Bind an alias to a provider. |
| `submit_request(alias_name, rendered_prompt, account_name, session_id, generation_params, timeout_ms)` | Caller | Enqueue a `pending` request. Returns `request_id`. Hashes the rendered prompt. |
| `request_status(request_id)` | Caller / service | Read `pending` / `running` / `succeeded` / `failed` / `cancelled` / `timeout`. |
| `cancel_request(request_id)` | Caller | Sets `cancel_requested = true`. If still `pending`, transitions to `cancelled`. |
| `get_response(request_id)` | Caller | Returns the response row when one exists, else empty. |
| `mc_stub_process(request_id)` | Stub adapter (in-DB) | Reference implementation of the polling+writing contract. Real `maludb_modeld` mirrors this from outside the backend. |

## Status state machine

```
              submit_request ──▶ pending
                                   │
                  cancel_request   │  modeld picks up
                  (still pending)──┼──▶ running
                                   ▼            │
                              cancelled         │ adapter completes
                                                ▼
                                           succeeded
                                           failed
                                           timeout
                                           cancelled (cancel_requested seen mid-run)
```

Terminal states: `succeeded`, `failed`, `cancelled`, `timeout`.

A response row MUST exist for every terminal state. The
`malu$model_response.status` mirrors the request's terminal status; the
unique constraint on `request_id` enforces one-response-per-request.

## Polling contract (real `maludb_modeld`)

1. Open a long-lived PostgreSQL session as a `maludb_modeld_*` role.
2. Loop:
   ```sql
   BEGIN;
   SELECT request_id, alias_id, rendered_prompt, prompt_hash,
          generation_params, timeout_ms, cancel_requested
   FROM   maludb_core.malu$model_request
   WHERE  status = 'pending'
   ORDER  BY submitted_at
   LIMIT  1
   FOR    UPDATE SKIP LOCKED;
   ```
3. If a row is locked: transition to `running` with `started_at = now()`,
   resolve the provider/adapter from `alias_id` → `malu$model_alias` →
   `malu$model_provider`, dispatch.
4. While the adapter is running, periodically re-read
   `cancel_requested` for that row. If `true`, abort the adapter, write
   a `cancelled` response, transition the request to `cancelled`.
5. On completion, INSERT into `malu$model_response` with the final
   status, output text/hash, token counts, latency, and adapter name.
   Then UPDATE the request to the matching terminal status with
   `finished_at = now()`. Both writes happen in the same transaction.
6. COMMIT. Loop.

`FOR UPDATE SKIP LOCKED` lets multiple `maludb_modeld` workers run
concurrently without coordinating outside the database.

## Timeouts

`timeout_ms` on the request is advisory to the service. The service
SHOULD enforce it locally and write `status='timeout'` if exceeded.
Database-side enforcement (a watchdog cron that flips overdue `running`
rows to `timeout`) is allowed but not part of R1.0-3.

## Secret resolution

`malu$model_provider.secret_ref` is a **reference** (e.g.
`env:OPENAI_API_KEY`, `vault:secret/data/openai`, `file:/etc/maludb/openai.key`),
never a literal credential. Only `maludb_modeld` resolves it. The
`maludb_core.model_provider_public` view excludes the column entirely
so no SQL caller can read it through normal means; ordinary read paths
do not have permission on the underlying `malu$model_provider` table.

## Stub-equivalence rule

For provider kind `stub`, the contract MUST be byte-for-byte identical
between `mc_stub_process` (in-DB) and `maludb_modeld` running its stub
adapter:

- `output_text == 'MALUDB_STUB_REPLY:' || prompt_hash`
- `adapter_name == 'stub'`
- `prompt_tokens == ⌈len(rendered_prompt) / 4⌉`
- `completion_tokens == ⌈len(output_text) / 4⌉`
- `latency_ms == 0`

This makes the stub a deterministic regression target across the SQL
and service implementations.

## Open questions (deferred)

1. Implementation language for `maludb_modeld`. Candidates: C (matches
   the extension; minimal deps), Go (best concurrency + JSON), Rust
   (safety, harder ramp). Decision deferred until R1.0-5.
2. Whether the local-runtime worker links `libllama` directly into the
   service process or controls a separate `llama-cli` over IPC. Tracked
   in `requirements.md` §10 and `mc2db-white-paper.md` §12.
3. Cancellation propagation latency target. R1.0-3 enforces no upper
   bound; field-test work in R1.0-10 will set one.
