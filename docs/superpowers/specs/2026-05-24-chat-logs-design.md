# Chat Logs as Documents Design

## Goal

Add durable end-user chat logging to MaluDB so API and desktop chat sessions are preserved as exact turn-level history, can be projected into the document pipeline, can carry SVPOR hints, and can later be promoted to memories.

## Context

MaluDB already has three related layers:

- `malu$session` and `malu$session_context` support model-session execution and short-term prompt context.
- `malu$source_package`, `malu$document`, `malu$document_tag`, and the planned `malu$document_svpor_hint` support durable document-style ingestion and promotion.
- `malu$chat_index_tree` and chat-index MDO nodes support long-chat retrieval over a conversation-like source package.

The missing layer is a user-facing chat log contract. `malu$session_context` is explicitly not long-term memory and should not become the authoritative chat transcript. Chat logs need their own durable session/message tables, while the document layer remains the durable source surface used by retrieval and promotion.

Document source taxonomy:

- `conversation` is reserved for human-to-human conversations such as meeting transcripts, customer calls, chats between people, and imported collaboration threads.
- `llm-chat` is used for end-user interactions with the MaluDB system, AI agents, model sessions, tools, or assistant workflows.

## Recommendation

Use a hybrid model:

1. First-class chat tables are the authoritative log.
2. Each system chat session can be projected into an `llm-chat` source package and document.
3. Chat documents use existing document tags and SVPOR hint frames.
4. Long or retrieval-heavy chat documents can be promoted into ChatIndex.
5. Later memory promotion reads the chat document, message log, SVPOR hints, and optional ChatIndex summaries.

This avoids forcing turn-level chat behavior into document blobs, while still preserving the document pipeline as the shared ingestion and promotion path.

## Data Model

### `malu$chat_session`

One row per end-user chat session.

Key attributes:

- `chat_session_id bigint primary key`
- `owner_schema name not null default current_schema()`
- `account_id bigint references malu$account(account_id)`
- `model_session_id bigint references malu$session(session_id)`
- `document_id bigint references malu$document(document_id)`
- `source_package_id bigint references malu$source_package(source_package_id)`
- `chat_title text`
- `lifecycle_state text check in ('open','closed','errored','archived','tombstoned')`
- `primary_project_subject_id bigint references malu$svpor_subject(subject_id)`
- `started_at timestamptz`
- `last_message_at timestamptz`
- `closed_at timestamptz`
- `message_count integer`
- `metadata_jsonb jsonb`

The `document_id` and `source_package_id` columns identify the generated transcript projection. They remain nullable while the chat is open if projection is deferred, but the recommended API should support immediate projection creation for crash-safe workflows.

### `malu$chat_message`

One row per message or system event in a chat session.

Key attributes:

- `chat_message_id bigint primary key`
- `owner_schema name not null default current_schema()`
- `chat_session_id bigint not null references malu$chat_session(chat_session_id)`
- `ordinal integer not null`
- `role text check in ('system','developer','user','assistant','tool','event')`
- `content_text text`
- `content_jsonb jsonb`
- `content_hash text`
- `token_estimate integer`
- `model_request_id bigint references malu$model_request(request_id)`
- `model_response_id bigint references malu$model_response(response_id)`
- `tool_call_id text`
- `source_locator jsonb`
- `sensitivity text check in ('public','internal','restricted','prohibited')`
- `created_at timestamptz`
- `metadata_jsonb jsonb`

`ordinal` is unique within each chat session. Messages are append-only for normal use. Corrections should create new messages or later supersession records, not silently rewrite existing content.

### Document Projection

Each chat session can produce a transcript document:

- `source_type = 'llm-chat'`
- `media_type = 'application/vnd.maludb.chat+json'` for structured projection, or `text/markdown` for a rendered transcript
- `metadata_jsonb` includes `chat_session_id`, `message_count`, `started_at`, `last_message_at`, and projection version

The projection should be deterministic: ordered messages are rendered into a stable JSON payload and optionally a stable text transcript. The source package hash should change only when the message log changes.

## Public API

Schema-local facades should be created by `enable_memory_schema` so desktop/API callers can work inside a tenant schema.

Core functions:

- `chat_start(title, account_name, projects, subjects, verbs, svpor_frames, metadata_jsonb) returns bigint`
- `chat_append_message(chat_session_id, role, content_text, content_jsonb, metadata_jsonb) returns bigint`
- `chat_finalize(chat_session_id) returns jsonb`
- `chat_get(chat_session_id) returns jsonb`
- `chat_messages(chat_session_id) returns setof record`

REST endpoints:

- `POST /v3/chat/session` creates a chat session.
- `POST /v3/chat/message` appends a message.
- `POST /v3/chat/finalize` closes the chat and refreshes the document projection.
- `GET /v3/chat/session` returns session metadata and document link.
- `GET /v3/chat/messages` returns ordered messages.

Initial scopes:

- `chat.write` for session creation, message append, and finalize.
- `chat.read` for session and message reads.
- Existing `document.read` can read the generated document through `document_get`.

## Process Flow

1. API or desktop starts a chat.
2. MaluDB creates `malu$chat_session`.
3. The system optionally creates an initial `llm-chat` source package and document projection.
4. Each user, assistant, tool, system, or event message is appended to `malu$chat_message`.
5. Each append updates `message_count`, `last_message_at`, and the content hash.
6. Projection can be refreshed after each append or only on finalize. The default implementation should refresh on finalize and expose a helper for manual refresh during long-running chats.
7. Finalize closes the chat, writes or refreshes the document projection, attaches document tags and SVPOR hints, and returns the chat/document ids.
8. If the chat is long or retrieval-worthy, callers can promote the source package into `malu$chat_index_tree`.
9. Memory promotion later reads from the document, chat messages, SVPOR hints, and optional ChatIndex nodes.

## SVPOR and Search

Chat sessions should accept the same project, subject, verb, and explicit SVPOR hint inputs as quick notes. Those hints attach to the generated document. Chat messages should also support lightweight message metadata for per-turn hints, but the first release should avoid a separate per-message SVPOR table unless a concrete workflow requires it.

Search behavior:

- Document search finds system chat transcripts as `source_type = 'llm-chat'`.
- Human-to-human transcript search continues to use `source_type = 'conversation'`.
- SVPOR tag searches find chats through document tags and hint frames.
- Long-chat retrieval uses ChatIndex when the transcript has been promoted.
- Exact audit and replay use `malu$chat_message`, not the rendered document text.

## Error Handling

- Appending to an unknown chat session raises `no_data_found`.
- Appending to a closed, archived, or tombstoned chat raises `object_not_in_prerequisite_state`.
- Appending a message without `content_text` or `content_jsonb` raises `invalid_parameter_value`.
- Invalid roles raise `invalid_parameter_value`.
- Duplicate ordinals are prevented by a unique constraint. The append function should allocate ordinals inside a row lock on `malu$chat_session`.
- Finalizing an already closed chat is idempotent if no new messages were appended.

## Security

Both chat tables are tenant-owned with `owner_schema` RLS. Schema-local facades filter by tenant schema. Read roles can read chat session/message views; write roles can create sessions and append messages through functions. Direct updates should be limited to admin/executor roles, with normal callers using append/finalize APIs.

The projection document inherits the existing document RLS and document-read/document-write semantics.

## Testing

Regression coverage should prove:

- Multiple messages append in order and roles are preserved.
- Chat sessions can link to a generated `llm-chat` document.
- `conversation` remains reserved for human-to-human transcripts and is not used by the system-chat projection.
- The generated document can carry multiple project, subject, verb, and SVPOR hints.
- A closed chat rejects new appends.
- `chat_get` returns session metadata, document link, and message count.
- Schema-local facades isolate two tenant schemas.
- REST catalog includes the chat endpoints and typed argument schemas.

## Release Scope

This is a new `0.75.0` release item that builds on the note-as-document slice. The first implementation should stop at durable logs, document projection, schema-local facades, and REST catalog registration. Automatic ChatIndex promotion and memory promotion should remain explicit follow-up steps unless the caller invokes an existing ChatIndex promotion API.
