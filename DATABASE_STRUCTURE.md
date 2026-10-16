# MaluDB — Complete Database Structure Reference

> **Generated:** 2026-05-25 from the authoritative extension install script 
`sql/extension/maludb_core--0.76.1.sql` (default_version `0.76.1`).

> This document is a *ground-truth* inventory extracted directly from DDL — use it to verify object names, 
columns, and signatures. If an object is not listed here, it does not exist in the installed extension.


## 0. Overview

| Object class | Count |
|---|---|
| Schemas | 2 (`maludb_core`, `mc2db`) |
| Required extensions | 4 (`vector`, `btree_gist`, `pg_trgm`, `pgcrypto`) |
| Tables | 144 |
| Composite / enum types | 13 |
| Top-level views (analytics) | 12 |
| Functions | 584 |
| Triggers | 13 |
| Per-schema facade views (dynamic) | 56 |
| Per-schema facade functions (dynamic) | 20 |

### How the schema is organized

- **`maludb_core`** — the extension's own schema (`relocatable = false`, `schema = 'maludb_core'`). 
All internal storage tables use the naming convention `malu$<name>` and live here. End users normally do **not** touch these directly.
- **`mc2db`** — companion schema created at install for MC2DB tooling.
- **Per-schema facade API** — when memory is enabled on a user schema (via `enable_memory_schema(...)`), 
the extension dynamically creates a set of friendly `maludb_*` **views** and **functions** *inside that user schema* 
that proxy onto the `maludb_core.malu$*` storage. These are the objects application code/agents should use. 
They are created with `CREATE OR REPLACE ... %I.<name>` (the `%I` is the target schema). 
**Note:** there is no object named `v4_related_subjects`; the related-subjects facade is `maludb_related_subject` (view) 
with helper functions `maludb_related_subjects(...)`, `maludb_related_subject_add(...)`, `maludb_related_subject_delete(...)`.


## 1. Types


### `bound_prompt`  
<sub>defined at line 4169</sub>

```sql
CREATE TYPE bound_prompt AS (
    bound_prompt_id     bigint,
    template_id         bigint,
    template_name       text,
    template_version    integer,
    template_hash       text,
    variables           jsonb,
    rendered_system     text,
    rendered_developer  text,
    rendered_user       text,
    rendered_full       text,
    prompt_hash         text,
    validation_status   text,
    estimated_tokens    integer
);
```

### `malu$bind_options`  
<sub>defined at line 3583</sub>

```sql
CREATE TYPE malu$bind_options AS (
    strict                      boolean,
    on_missing_variable         text,   -- 'error' | 'blank' | 'preserve'
    on_extra_variable           text,   -- 'ignore' | 'warn'  | 'error'
    null_handling               text,   -- 'null_literal' | 'empty' | 'error'
    max_variable_chars          integer,
    max_rendered_prompt_chars   integer,
    on_truncate                 text,   -- 'error' | 'truncate_with_notice'
    escape_mode                 text    -- 'none' | 'json' | 'sql_literal'
);
```

### `malu$bind_validation`  
<sub>defined at line 3616</sub>

```sql
CREATE TYPE malu$bind_validation AS (
    status                 text,
    normalized_variables   jsonb,
    declared_count         integer,
    supplied_count         integer,
    warnings               text[]
);
```

### `malu$mdo_root_result`  
<sub>defined at line 9120</sub>

```sql
CREATE TYPE malu$mdo_root_result AS (
    root_kind  text,
    root_id    bigint,
    mdo_chain  bigint[]
);
```

### `malu$reingest_result`  
<sub>defined at line 8807</sub>

```sql
CREATE TYPE malu$reingest_result AS (
    content_bytes  bytea,
    content_text   text,
    content_jsonb  jsonb,
    content_hash   text,
    source_type    text,
    media_type     text,
    sealed_at      timestamptz
);
```

### `malu$response_tokens`  
<sub>defined at line 4988</sub>

```sql
CREATE TYPE malu$response_tokens AS (
    prompt      integer,
    completion  integer,
    total       integer
);
```

### `malu$retrieval_cue`  
<sub>defined at line 13431</sub>

```sql
CREATE TYPE malu$retrieval_cue AS (
    cue_kind   text,
    cue_value  text,
    cue_ref_id bigint,
    weight     numeric
);
```

### `malu$retrieval_envelope_t`  
<sub>defined at line 13422</sub>

```sql
CREATE TYPE malu$retrieval_envelope_t AS (
    cue_text           text,
    object_types       text[],
    valid_as_of        timestamptz,
    transaction_as_of  timestamptz,
    confidence_floor   numeric,
    hints              jsonb
);
```

### `malu$retrieval_hit`  
<sub>defined at line 14069</sub>

```sql
CREATE TYPE malu$retrieval_hit AS (
    object_type   text,
    object_id     bigint,
    title         text,
    snippet       text,
    rank          real,
    strategy      text,
    metadata      jsonb
);
```

### `malu$retrieval_plan`  
<sub>defined at line 13438</sub>

```sql
CREATE TYPE malu$retrieval_plan AS (
    intent      text,
    cues        jsonb,
    strategies  jsonb,
    envelope    jsonb
);
```

### `malu$verify_result`  
<sub>defined at line 8747</sub>

```sql
CREATE TYPE malu$verify_result AS (
    matched          boolean,
    expected_hash    text,
    computed_hash    text,
    verification_id  bigint
);
```

### `malu_vector`  
<sub>defined at line 6492</sub>

```sql
CREATE TYPE malu_vector;  -- shell
```

### `malu_vector`  
<sub>defined at line 6510</sub>

```sql
CREATE TYPE malu_vector (
    INPUT          = malu_vector_in,
    OUTPUT         = malu_vector_out,
    RECEIVE        = malu_vector_recv,
    SEND           = malu_vector_send,
    INTERNALLENGTH = VARIABLE,
    STORAGE        = extended,
    ALIGNMENT      = int4
);
```

## 2. Tables

All 144 tables, in file order, with full column definitions.


### `maludb_core.malu$account`  
<sub>line 35</sub>

```sql
CREATE TABLE malu$account (
    account_id   bigserial PRIMARY KEY,
    account_name text NOT NULL UNIQUE,
    account_kind text NOT NULL
        CHECK (account_kind IN
              ('human','service','agent','application',
               'mcp_client','mc2db_client','local_node','admin')),
    enabled      boolean NOT NULL DEFAULT true,
    description  text,
    created_at   timestamptz NOT NULL DEFAULT now()
);
```

### `maludb_core.malu$role`  
<sub>line 47</sub>

```sql
CREATE TABLE malu$role (
    role_id     bigserial PRIMARY KEY,
    role_name   text NOT NULL UNIQUE,
    description text,
    created_at  timestamptz NOT NULL DEFAULT now()
);
```

### `maludb_core.malu$account_role`  
<sub>line 54</sub>

```sql
CREATE TABLE malu$account_role (
    account_id bigint NOT NULL REFERENCES malu$account(account_id) ON DELETE CASCADE,
    role_id    bigint NOT NULL REFERENCES malu$role(role_id)       ON DELETE CASCADE,
    granted_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (account_id, role_id)
);
```

### `maludb_core.malu$partition`  
<sub>line 61</sub>

```sql
CREATE TABLE malu$partition (
    partition_id    bigserial PRIMARY KEY,
    partition_name  text NOT NULL UNIQUE,
    security_domain text,
    description     text,
    created_at      timestamptz NOT NULL DEFAULT now()
);
```

### `maludb_core.malu$object_type`  
<sub>line 75</sub>

```sql
CREATE TABLE malu$object_type (
    object_type text PRIMARY KEY,
    stage       smallint NOT NULL,
    description text
);
```

### `maludb_core.malu$relationship_type`  
<sub>line 81</sub>

```sql
CREATE TABLE malu$relationship_type (
    relationship_type text PRIMARY KEY,
    stage             smallint NOT NULL,
    description       text,
    inverse_of        text REFERENCES malu$relationship_type(relationship_type)
);
```

### `maludb_core.malu$source_type`  
<sub>line 88</sub>

```sql
CREATE TABLE malu$source_type (
    source_type text PRIMARY KEY,
    stage       smallint NOT NULL,
    description text
);
```

### `maludb_core.malu$model_provider`  
<sub>line 97</sub>

```sql
CREATE TABLE malu$model_provider (
    provider_id       bigserial PRIMARY KEY,
    provider_name     text NOT NULL UNIQUE,
    provider_kind     text NOT NULL CHECK (provider_kind IN
        ('cloud_api','local_http','local_socket','local_runtime',
         'shell_adapter','stub')),
    adapter_name      text,
    secret_ref        text,
    data_sensitivity  text,
    enabled           boolean NOT NULL DEFAULT true,
    created_at        timestamptz NOT NULL DEFAULT now()
);
```

### `maludb_core.malu$model_alias`  
<sub>line 110</sub>

```sql
CREATE TABLE malu$model_alias (
    alias_id          bigserial PRIMARY KEY,
    alias_name        text NOT NULL UNIQUE,
    provider_id       bigint NOT NULL REFERENCES malu$model_provider(provider_id) ON DELETE RESTRICT,
    model_identifier  text NOT NULL,
    model_path        text,
    model_hash        text,
    quantization      text,
    context_length    integer,
    gpu_placement     text,
    runtime_params    jsonb,
    license_metadata  jsonb,
    enabled           boolean NOT NULL DEFAULT true,
    created_at        timestamptz NOT NULL DEFAULT now()
);
```

### `maludb_core.malu$prompt_template`  
<sub>line 126</sub>

```sql
CREATE TABLE malu$prompt_template (
    template_id         bigserial PRIMARY KEY,
    template_name       text NOT NULL,
    template_version    integer NOT NULL DEFAULT 1,
    owner_account_id    bigint REFERENCES malu$account(account_id) ON DELETE SET NULL,
    body                text NOT NULL,
    system_template     text,
    developer_template  text,
    user_template       text,
    variables           jsonb,
    enabled             boolean NOT NULL DEFAULT true,
    created_at          timestamptz NOT NULL DEFAULT now(),
    UNIQUE (template_name, template_version)
);
```

### `maludb_core.malu$session`  
<sub>line 141</sub>

```sql
CREATE TABLE malu$session (
    session_id          bigserial PRIMARY KEY,
    account_id          bigint NOT NULL REFERENCES malu$account(account_id),
    model_alias_id      bigint REFERENCES malu$model_alias(alias_id),
    prompt_template_id  bigint REFERENCES malu$prompt_template(template_id),
    lifecycle_state     text NOT NULL DEFAULT 'open'
        CHECK (lifecycle_state IN ('open','closed','errored')),
    token_budget        integer,
    created_at          timestamptz NOT NULL DEFAULT now(),
    closed_at           timestamptz
);
```

### `maludb_core.malu$session_context`  
<sub>line 162</sub>

```sql
CREATE TABLE malu$session_context (
    context_id      bigserial PRIMARY KEY,
    session_id      bigint NOT NULL REFERENCES malu$session(session_id) ON DELETE CASCADE,
    ordinal         integer NOT NULL CHECK (ordinal > 0),
    role            text,
    content_text    text,
    content_jsonb   jsonb,
    content_hash    text NOT NULL,
    source_label    text,
    sensitivity     text NOT NULL DEFAULT 'internal'
        CHECK (sensitivity IN ('public','internal','restricted','prohibited')),
    token_estimate  integer,
    created_at      timestamptz NOT NULL DEFAULT now(),
    UNIQUE (session_id, ordinal),
    CHECK (content_text IS NOT NULL OR content_jsonb IS NOT NULL)
);
```

### `maludb_core.malu$prompt_render`  
<sub>line 188</sub>

```sql
CREATE TABLE malu$prompt_render (
    render_id            bigserial PRIMARY KEY,
    template_id          bigint NOT NULL REFERENCES malu$prompt_template(template_id) ON DELETE RESTRICT,
    session_id           bigint REFERENCES malu$session(session_id) ON DELETE CASCADE,
    account_id           bigint REFERENCES malu$account(account_id) ON DELETE SET NULL,
    variables            jsonb NOT NULL DEFAULT '{}'::jsonb,
    rendered_prompt      text NOT NULL,
    prompt_hash          text NOT NULL,
    context_block_count  integer NOT NULL DEFAULT 0,
    context_hash         text,
    created_at           timestamptz NOT NULL DEFAULT now()
);
```

### `maludb_core.malu$model_request`  
<sub>line 211</sub>

```sql
CREATE TABLE malu$model_request (
    request_id         bigserial PRIMARY KEY,
    session_id         bigint REFERENCES malu$session(session_id) ON DELETE SET NULL,
    prompt_render_id   bigint REFERENCES malu$prompt_render(render_id) ON DELETE SET NULL,
    alias_id           bigint NOT NULL REFERENCES malu$model_alias(alias_id) ON DELETE RESTRICT,
    account_id         bigint REFERENCES malu$account(account_id) ON DELETE SET NULL,
    rendered_prompt    text NOT NULL,
    prompt_hash        text NOT NULL,
    generation_params  jsonb NOT NULL DEFAULT '{}'::jsonb,
    timeout_ms         integer NOT NULL DEFAULT 30000
        CHECK (timeout_ms > 0),
    cancel_requested   boolean NOT NULL DEFAULT false,
    status             text NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending','running','succeeded','failed','cancelled','timeout')),
    submitted_at       timestamptz NOT NULL DEFAULT now(),
    started_at         timestamptz,
    finished_at        timestamptz
);
```

### `maludb_core.malu$model_response`  
<sub>line 234</sub>

```sql
CREATE TABLE malu$model_response (
    response_id            bigserial PRIMARY KEY,
    request_id             bigint NOT NULL UNIQUE
        REFERENCES malu$model_request(request_id) ON DELETE CASCADE,
    status                 text NOT NULL
        CHECK (status IN ('succeeded','failed','cancelled','timeout')),
    output_text            text,
    output_hash            text,
    output_json            jsonb,
    tool_calls             jsonb,
    finish_reason          text,
    raw_provider_response  jsonb,
    prompt_tokens          integer,
    completion_tokens      integer,
    latency_ms             integer,
    error_class            text,
    user_safe_error        text,
    adapter_name           text NOT NULL,
    finished_at            timestamptz NOT NULL DEFAULT now()
);
```

### `maludb_core.malu$listener_config`  
<sub>line 258</sub>

```sql
CREATE TABLE malu$listener_config (
    listener_id              bigserial PRIMARY KEY,
    listener_name            text NOT NULL UNIQUE,
    bind_host                text NOT NULL DEFAULT '127.0.0.1',
    bind_port                integer NOT NULL DEFAULT 5329,
    tls_enabled              boolean NOT NULL DEFAULT false,
    tls_cert_path            text,
    tls_key_path             text,
    mc2db_protocol_versions  text[] NOT NULL DEFAULT ARRAY['2025-11-25'],
    default_risk_class       text NOT NULL DEFAULT 'read_only',
    default_timeout_ms       integer NOT NULL DEFAULT 30000,
    default_max_input_bytes  integer NOT NULL DEFAULT 262144,
    default_max_output_bytes integer NOT NULL DEFAULT 1048576,
    enabled                  boolean NOT NULL DEFAULT true,
    created_at               timestamptz NOT NULL DEFAULT now(),
    CHECK (bind_port > 0 AND bind_port < 65536),
    CHECK (default_risk_class IN
        ('read_only','evidence_producing','state_changing','external_effect','administrative'))
);
```

### `maludb_core.malu$mc2db_server`  
<sub>line 293</sub>

```sql
CREATE TABLE malu$mc2db_server (
    server_id          bigserial PRIMARY KEY,
    server_name        text NOT NULL UNIQUE,
    title              text,
    description        text,
    protocol_versions  text[] NOT NULL DEFAULT ARRAY['2025-11-25'],
    default_risk_class text NOT NULL DEFAULT 'read_only',
    enabled            boolean NOT NULL DEFAULT true,
    created_at         timestamptz NOT NULL DEFAULT now(),
    CHECK (default_risk_class IN
        ('read_only','evidence_producing','state_changing','external_effect','administrative'))
);
```

### `maludb_core.malu$mc2db_tool`  
<sub>line 306</sub>

```sql
CREATE TABLE malu$mc2db_tool (
    tool_id              bigserial PRIMARY KEY,
    server_id            bigint NOT NULL REFERENCES malu$mc2db_server(server_id) ON DELETE CASCADE,
    tool_name            text NOT NULL,
    title                text,
    description          text NOT NULL,
    implementation_type  text NOT NULL,
    input_schema         jsonb NOT NULL DEFAULT '{}'::jsonb,
    output_schema        jsonb,
    risk_class           text NOT NULL DEFAULT 'read_only',
    read_only            boolean NOT NULL DEFAULT true,
    require_confirmation boolean NOT NULL DEFAULT false,
    timeout_ms           integer NOT NULL DEFAULT 10000,
    max_input_bytes      integer NOT NULL DEFAULT 262144,
    max_output_bytes     integer NOT NULL DEFAULT 1048576,
    allow_network        boolean NOT NULL DEFAULT false,
    required_privileges  text[] NOT NULL DEFAULT ARRAY[]::text[],
    enabled              boolean NOT NULL DEFAULT true,
    created_at           timestamptz NOT NULL DEFAULT now(),
    UNIQUE (server_id, tool_name),
    CHECK (implementation_type IN
        ('sql_function','external_exec','mcp_proxy','http_endpoint')),
    CHECK (risk_class IN
        ('read_only','evidence_producing','state_changing','external_effect','administrative')),
    CHECK (timeout_ms > 0),
    CHECK (max_input_bytes > 0),
    CHECK (max_output_bytes > 0)
);
```

### `maludb_core.malu$mc2db_tool_sql_function`  
<sub>line 335</sub>

```sql
CREATE TABLE malu$mc2db_tool_sql_function (
    tool_id            bigint PRIMARY KEY REFERENCES malu$mc2db_tool(tool_id) ON DELETE CASCADE,
    function_signature regprocedure NOT NULL,
    transaction_mode   text NOT NULL DEFAULT 'read_committed',
    set_role_name      name,
    pinned_search_path text NOT NULL DEFAULT 'maludb_core, pg_catalog',
    CHECK (transaction_mode IN ('read_committed','repeatable_read','serializable'))
);
```

### `maludb_core.malu$mc2db_tool_external_exec`  
<sub>line 344</sub>

```sql
CREATE TABLE malu$mc2db_tool_external_exec (
    tool_id        bigint PRIMARY KEY REFERENCES malu$mc2db_tool(tool_id) ON DELETE CASCADE,
    command_path   text NOT NULL,
    argv_template  jsonb NOT NULL DEFAULT '[]'::jsonb,
    working_dir    text,
    run_as_user    text,
    input_mode     text NOT NULL DEFAULT 'stdin_json',
    output_mode    text NOT NULL DEFAULT 'stdout_json',
    environment    jsonb NOT NULL DEFAULT '{}'::jsonb,
    CHECK (command_path LIKE '/%'),
    CHECK (input_mode IN ('stdin_json','argv_json','env_json')),
    CHECK (output_mode IN ('stdout_json'))
);
```

### `maludb_core.malu$mc2db_tool_mcp_proxy`  
<sub>line 358</sub>

```sql
CREATE TABLE malu$mc2db_tool_mcp_proxy (
    tool_id            bigint PRIMARY KEY REFERENCES malu$mc2db_tool(tool_id) ON DELETE CASCADE,
    remote_server_name text NOT NULL,
    remote_tool_name   text NOT NULL,
    transport_type     text NOT NULL,
    endpoint_url       text,
    command_path       text,
    argv               jsonb NOT NULL DEFAULT '[]'::jsonb,
    CHECK (transport_type IN ('stdio','http')),
    CHECK (
        (transport_type = 'http'  AND endpoint_url IS NOT NULL) OR
        (transport_type = 'stdio' AND command_path IS NOT NULL)
    )
);
```

### `maludb_core.malu$mc2db_tool_http_endpoint`  
<sub>line 373</sub>

```sql
CREATE TABLE malu$mc2db_tool_http_endpoint (
    tool_id  bigint PRIMARY KEY REFERENCES malu$mc2db_tool(tool_id) ON DELETE CASCADE
);
```

### `maludb_core.malu$mc2db_prompt`  
<sub>line 377</sub>

```sql
CREATE TABLE malu$mc2db_prompt (
    prompt_id          bigserial PRIMARY KEY,
    server_id          bigint NOT NULL REFERENCES malu$mc2db_server(server_id) ON DELETE CASCADE,
    prompt_name        text NOT NULL,
    title              text,
    description        text,
    input_schema       jsonb,
    function_signature regprocedure,
    enabled            boolean NOT NULL DEFAULT true,
    created_at         timestamptz NOT NULL DEFAULT now(),
    UNIQUE (server_id, prompt_name)
);
```

### `maludb_core.malu$mc2db_resource`  
<sub>line 390</sub>

```sql
CREATE TABLE malu$mc2db_resource (
    resource_id        bigserial PRIMARY KEY,
    server_id          bigint NOT NULL REFERENCES malu$mc2db_server(server_id) ON DELETE CASCADE,
    uri_template       text NOT NULL,
    title              text,
    description        text,
    mime_type          text NOT NULL DEFAULT 'application/json',
    function_signature regprocedure,
    enabled            boolean NOT NULL DEFAULT true,
    created_at         timestamptz NOT NULL DEFAULT now(),
    UNIQUE (server_id, uri_template)
);
```

### `maludb_core.malu$mc2db_invocation`  
<sub>line 403</sub>

```sql
CREATE TABLE malu$mc2db_invocation (
    call_id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tool_id              bigint REFERENCES malu$mc2db_tool(tool_id) ON DELETE SET NULL,
    tool_name            text NOT NULL,
    implementation_type  text NOT NULL,
    request_user         text,
    database_role        name,
    input_hash           bytea,
    output_hash          bytea,
    success              boolean NOT NULL,
    error_code           text,
    error_message        text,
    external_exit_code   integer,
    external_stderr      text,
    started_at           timestamptz NOT NULL DEFAULT now(),
    finished_at          timestamptz,
    duration_ms          integer
);
```

### `maludb_core.malu$vector_demo`  
<sub>line 430</sub>

```sql
CREATE TABLE malu$vector_demo (
    demo_id    bigserial PRIMARY KEY,
    label      text NOT NULL,
    embedding  vector(8) NOT NULL,
    payload    jsonb,
    created_at timestamptz NOT NULL DEFAULT now()
);
```

### `maludb_core.malu$vector_subject`  
<sub>line 2430</sub>

```sql
CREATE TABLE malu$vector_subject (
    subject_id     bigserial PRIMARY KEY,
    owner_schema   name NOT NULL DEFAULT current_schema(),
    namespace      text NOT NULL,
    subject_name   text NOT NULL,
    description    text,
    created_at     timestamptz NOT NULL DEFAULT now(),
    UNIQUE (owner_schema, namespace, subject_name)
);
```

### `maludb_core.malu$vector_verb`  
<sub>line 2440</sub>

```sql
CREATE TABLE malu$vector_verb (
    verb_id        bigserial PRIMARY KEY,
    owner_schema   name NOT NULL DEFAULT current_schema(),
    namespace      text NOT NULL,
    verb_name      text NOT NULL,
    description    text,
    created_at     timestamptz NOT NULL DEFAULT now(),
    UNIQUE (owner_schema, namespace, verb_name)
);
```

### `maludb_core.malu$vector_compartment`  
<sub>line 2450</sub>

```sql
CREATE TABLE malu$vector_compartment (
    compartment_id    bigserial PRIMARY KEY,
    owner_schema      name NOT NULL DEFAULT current_schema(),
    namespace         text NOT NULL,
    subject_id        bigint NOT NULL REFERENCES malu$vector_subject(subject_id) ON DELETE RESTRICT,
    verb_id           bigint NOT NULL REFERENCES malu$vector_verb(verb_id)       ON DELETE RESTRICT,
    embedding_dim     integer NOT NULL,
    embedding_model   text    NOT NULL,
    distance_metric   text    NOT NULL DEFAULT 'cosine'
        CHECK (distance_metric IN ('cosine','l2','inner_product')),
    vector_count      bigint  NOT NULL DEFAULT 0,
    search_mode       text    NOT NULL DEFAULT 'exact'
        CHECK (search_mode IN ('exact','exact_parallel','local_ann')),
    ann_index_status  text    NOT NULL DEFAULT 'none'
        CHECK (ann_index_status IN ('none','building','ready','stale','rebuilding','disabled')),
    created_at        timestamptz NOT NULL DEFAULT now(),
    updated_at        timestamptz NOT NULL DEFAULT now(),
    UNIQUE (owner_schema, namespace, subject_id, verb_id)
);
```

### `maludb_core.malu$vector_chunk`  
<sub>line 2470</sub>

```sql
CREATE TABLE malu$vector_chunk (
    chunk_id         bigserial PRIMARY KEY,
    compartment_id   bigint NOT NULL
        REFERENCES malu$vector_compartment(compartment_id) ON DELETE CASCADE,
    source_text      text NOT NULL,
    embedding        bytea NOT NULL,
    embedding_dim    integer NOT NULL,
    embedding_model  text NOT NULL,
    embedding_norm   double precision,
    importance_score numeric(6,3),
    created_at       timestamptz NOT NULL DEFAULT now(),
    CHECK (octet_length(embedding) = embedding_dim * 4),
    CHECK (embedding_dim > 0)
);
```

### `maludb_core.malu$prompt_variable`  
<sub>line 3546</sub>

```sql
CREATE TABLE malu$prompt_variable (
    template_id     bigint  NOT NULL
        REFERENCES malu$prompt_template(template_id) ON DELETE CASCADE,
    variable_name   text    NOT NULL
        CHECK (variable_name ~ '^[A-Za-z_][A-Za-z0-9_]*$'),
    variable_type   text    NOT NULL DEFAULT 'text'
        CHECK (variable_type IN ('text','integer','number','boolean','json','enum')),
    required        boolean NOT NULL DEFAULT false,
    default_value   text,
    validation_rule text,
    max_length      integer
        CHECK (max_length IS NULL OR max_length > 0),
    enum_values     text[],
    sensitivity     text    NOT NULL DEFAULT 'internal'
        CHECK (sensitivity IN ('public','internal','restricted','prohibited')),
    created_at      timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (template_id, variable_name),
    -- enum_values is only meaningful for the enum type, but only enforce
    -- the positive direction (enum → values required); allow enum_values
    -- to be set on non-enum types for forward-compat with future kinds.
    CHECK (variable_type <> 'enum' OR (enum_values IS NOT NULL AND array_length(enum_values, 1) > 0))
);
```

### `maludb_core.malu$bound_prompt`  
<sub>line 4131</sub>

```sql
CREATE TABLE malu$bound_prompt (
    bound_prompt_id        bigserial PRIMARY KEY,
    render_id              bigint REFERENCES malu$prompt_render(render_id) ON DELETE SET NULL,
    template_id            bigint NOT NULL
        REFERENCES malu$prompt_template(template_id) ON DELETE RESTRICT,
    template_hash          text NOT NULL,
    account_id             bigint REFERENCES malu$account(account_id) ON DELETE SET NULL,
    session_id             bigint REFERENCES malu$session(session_id) ON DELETE SET NULL,
    variables_raw          jsonb NOT NULL DEFAULT '{}'::jsonb,
    variables_normalized   jsonb NOT NULL DEFAULT '{}'::jsonb,
    rendered_system        text,
    rendered_developer     text,
    rendered_user          text,
    rendered_full          text NOT NULL,
    prompt_hash            text NOT NULL,
    bind_options           malu$bind_options NOT NULL,
    validation_status      text NOT NULL
        CHECK (validation_status IN ('ok','warned')),
    validation_warnings    text[] NOT NULL DEFAULT ARRAY[]::text[],
    estimated_tokens       integer NOT NULL,
    created_at             timestamptz NOT NULL DEFAULT now()
);
```

### `maludb_core.malu$safety_policy`  
<sub>line 4515</sub>

```sql
CREATE TABLE malu$safety_policy (
    policy_id     bigserial PRIMARY KEY,
    policy_name   text NOT NULL UNIQUE,
    description   text,
    created_at    timestamptz NOT NULL DEFAULT now()
);
```

### `maludb_core.malu$retry_policy`  
<sub>line 5580</sub>

```sql
CREATE TABLE malu$retry_policy (
    policy_id           bigserial PRIMARY KEY,
    provider_id         bigint
        REFERENCES malu$model_provider(provider_id) ON DELETE CASCADE,
    max_attempts        integer NOT NULL DEFAULT 3
        CHECK (max_attempts >= 1 AND max_attempts <= 10),
    backoff_initial_ms  integer NOT NULL DEFAULT 1000
        CHECK (backoff_initial_ms >= 0),
    backoff_multiplier  numeric(4,2) NOT NULL DEFAULT 2.0
        CHECK (backoff_multiplier >= 1.0),
    max_backoff_ms      integer NOT NULL DEFAULT 60000
        CHECK (max_backoff_ms >= 0),
    retry_on            text[] NOT NULL DEFAULT ARRAY['timeout','rate_limit','transient'],
    enabled             boolean NOT NULL DEFAULT true,
    created_at          timestamptz NOT NULL DEFAULT now()
);
```

### `maludb_core.malu$budget_policy`  
<sub>line 5941</sub>

```sql
CREATE TABLE malu$budget_policy (
    policy_id          bigserial PRIMARY KEY,
    policy_name        text NOT NULL UNIQUE,
    scope              text NOT NULL
        CHECK (scope IN ('account','prompt','role','global')),
    scope_account_id   bigint REFERENCES malu$account(account_id) ON DELETE CASCADE,
    scope_template_id  bigint REFERENCES malu$prompt_template(template_id) ON DELETE CASCADE,
    scope_role         text,
    limit_kind         text NOT NULL
        CHECK (limit_kind IN ('tokens_daily','cost_daily','requests_daily')),
    limit_value        bigint NOT NULL CHECK (limit_value > 0),
    enabled            boolean NOT NULL DEFAULT true,
    created_at         timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT malu$budget_policy_scope_one_of CHECK (
        CASE scope
            WHEN 'account' THEN scope_account_id IS NOT NULL AND scope_template_id IS NULL AND scope_role IS NULL
            WHEN 'prompt'  THEN scope_template_id IS NOT NULL AND scope_account_id IS NULL AND scope_role IS NULL
            WHEN 'role'    THEN scope_role IS NOT NULL AND scope_account_id IS NULL AND scope_template_id IS NULL
            WHEN 'global'  THEN scope_account_id IS NULL AND scope_template_id IS NULL AND scope_role IS NULL
        END
    )
);
```

### `maludb_core.malu$ann_index`  
<sub>line 7141</sub>

```sql
CREATE TABLE malu$ann_index (
    compartment_id       bigint PRIMARY KEY
        REFERENCES malu$vector_compartment(compartment_id) ON DELETE CASCADE,
    algorithm            text   NOT NULL DEFAULT 'nsw'
        CHECK (algorithm IN ('nsw','hnsw')),
    distance_metric      text   NOT NULL
        CHECK (distance_metric IN ('cosine','l2','inner_product')),
    m                    integer NOT NULL DEFAULT 16
        CHECK (m > 0 AND m <= 256),
    ef_construction      integer NOT NULL DEFAULT 64
        CHECK (ef_construction > 0 AND ef_construction <= 4096),
    ef_search_default    integer NOT NULL DEFAULT 32
        CHECK (ef_search_default > 0 AND ef_search_default <= 4096),
    embedding_dim        integer NOT NULL,
    graph_bytes          bytea  NOT NULL,
    vector_count_at_build bigint NOT NULL DEFAULT 0,
    status               text   NOT NULL DEFAULT 'ready'
        CHECK (status IN ('building','ready','stale','rebuilding','disabled')),
    built_at             timestamptz NOT NULL DEFAULT now(),
    last_rebuilt_at      timestamptz
);
```

### `maludb_core.malu$ann_delta`  
<sub>line 7170</sub>

```sql
CREATE TABLE malu$ann_delta (
    compartment_id   bigint NOT NULL
        REFERENCES malu$vector_compartment(compartment_id) ON DELETE CASCADE,
    chunk_id         bigint NOT NULL
        REFERENCES malu$vector_chunk(chunk_id) ON DELETE CASCADE,
    created_at       timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (compartment_id, chunk_id)
);
```

### `maludb_core.malu$vector_tombstone`  
<sub>line 7186</sub>

```sql
CREATE TABLE malu$vector_tombstone (
    chunk_id    bigint PRIMARY KEY
        REFERENCES malu$vector_chunk(chunk_id) ON DELETE CASCADE,
    deleted_at  timestamptz NOT NULL DEFAULT now()
);
```

### `maludb_core.malu$source_package`  
<sub>line 7654</sub>

```sql
CREATE TABLE malu$source_package (
    source_package_id   bigserial PRIMARY KEY,
    owner_schema        name NOT NULL DEFAULT current_schema(),
    source_type         text NOT NULL
        REFERENCES malu$source_type(source_type),
    -- Content (one of these must be non-NULL)
    content_bytes       bytea,
    content_text        text,
    content_jsonb       jsonb,
    content_hash        text NOT NULL,   -- sha256 hex over the canonical form
    content_size        bigint NOT NULL CHECK (content_size >= 0),
    media_type          text,
    -- Origin
    origin_jsonb        jsonb,           -- {producer, connector, ingested_by, ...}
    captured_at         timestamptz,
    ingested_at         timestamptz NOT NULL DEFAULT now(),
    -- Retention + legal hold
    retention_class     text NOT NULL DEFAULT 'standard'
        CHECK (retention_class IN ('standard','sensitive','restricted','prohibited')),
    legal_hold          boolean NOT NULL DEFAULT false,
    legal_hold_reason   text,
    retain_until        timestamptz,
    -- Sensitivity (independent of retention)
    sensitivity         text NOT NULL DEFAULT 'internal'
        CHECK (sensitivity IN ('public','internal','restricted','prohibited')),
    -- Lifecycle (S2-2 wires the seal/archive transitions properly)
    sealed_at           timestamptz,
    archived_at         timestamptz,
    tombstoned_at       timestamptz,
    -- Audit
    created_at          timestamptz NOT NULL DEFAULT now(),
    updated_at          timestamptz NOT NULL DEFAULT now(),
    CHECK (content_bytes IS NOT NULL OR content_text IS NOT NULL OR content_jsonb IS NOT NULL)
);
```

### `maludb_core.malu$claim`  
<sub>line 7699</sub>

```sql
CREATE TABLE malu$claim (
    claim_id            bigserial PRIMARY KEY,
    owner_schema        name NOT NULL DEFAULT current_schema(),
    -- SVPOR text shape (Stage 3 will normalize)
    subject             text,
    verb                text,
    predicate           text,
    object_value        text,
    relationship        text,
    -- Free-form statement
    statement_text      text,
    statement_jsonb     jsonb,
    -- Source reference (optional)
    source_package_id   bigint REFERENCES malu$source_package(source_package_id) ON DELETE SET NULL,
    source_locator      jsonb,           -- {page, byte_offset, line_no, message_id, ...}
    -- Lifecycle
    asserted_at         timestamptz NOT NULL DEFAULT now(),
    retracted_at        timestamptz,
    retraction_reason   text,
    sensitivity         text NOT NULL DEFAULT 'internal'
        CHECK (sensitivity IN ('public','internal','restricted','prohibited')),
    created_at          timestamptz NOT NULL DEFAULT now()
);
```

### `maludb_core.malu$fact`  
<sub>line 7733</sub>

```sql
CREATE TABLE malu$fact (
    fact_id             bigserial PRIMARY KEY,
    owner_schema        name NOT NULL DEFAULT current_schema(),
    subject             text,
    verb                text,
    predicate           text,
    object_value        text,
    relationship        text,
    statement_text      text,
    statement_jsonb     jsonb,
    -- Verification (Stage 3 MAUT will replace)
    verification_scope  text,
    verification_method text,
    verified_at         timestamptz NOT NULL DEFAULT now(),
    -- Supersession (Stage 3 will replace)
    supersedes_fact_id  bigint REFERENCES malu$fact(fact_id) ON DELETE SET NULL,
    superseded_at       timestamptz,
    -- Sensitivity / lifecycle
    sensitivity         text NOT NULL DEFAULT 'internal'
        CHECK (sensitivity IN ('public','internal','restricted','prohibited')),
    lifecycle_state     text NOT NULL DEFAULT 'active'
        CHECK (lifecycle_state IN ('active','superseded','retired','legal_hold','tombstoned')),
    created_at          timestamptz NOT NULL DEFAULT now()
);
```

### `maludb_core.malu$fact_claim`  
<sub>line 7764</sub>

```sql
CREATE TABLE malu$fact_claim (
    fact_id     bigint  NOT NULL REFERENCES malu$fact(fact_id)   ON DELETE CASCADE,
    claim_id    bigint  NOT NULL REFERENCES malu$claim(claim_id) ON DELETE RESTRICT,
    role        text    NOT NULL DEFAULT 'supports'
        CHECK (role IN ('supports','contradicts','contextualizes')),
    added_at    timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (fact_id, claim_id)
);
```

### `maludb_core.malu$memory`  
<sub>line 7780</sub>

```sql
CREATE TABLE malu$memory (
    memory_id           bigserial PRIMARY KEY,
    owner_schema        name NOT NULL DEFAULT current_schema(),
    memory_kind         text NOT NULL,
    title               text,
    summary             text,
    payload_jsonb       jsonb NOT NULL DEFAULT '{}'::jsonb,
    -- Temporal anchors (Stage 3 fills in full bitemporal)
    occurred_at         timestamptz,
    occurred_until      timestamptz,
    recorded_at         timestamptz NOT NULL DEFAULT now(),
    -- Sensitivity / lifecycle
    sensitivity         text NOT NULL DEFAULT 'internal'
        CHECK (sensitivity IN ('public','internal','restricted','prohibited')),
    lifecycle_state     text NOT NULL DEFAULT 'active'
        CHECK (lifecycle_state IN ('active','consolidated','superseded','archived','retired','legal_hold','tombstoned')),
    consolidated_into_memory_id bigint
        REFERENCES malu$memory(memory_id) ON DELETE SET NULL,
    created_at          timestamptz NOT NULL DEFAULT now(),
    updated_at          timestamptz NOT NULL DEFAULT now()
);
```

### `maludb_core.malu$episode_object`  
<sub>line 7814</sub>

```sql
CREATE TABLE malu$episode_object (
    episode_id          bigserial PRIMARY KEY,
    owner_schema        name NOT NULL DEFAULT current_schema(),
    episode_kind        text NOT NULL,
    title               text NOT NULL,
    summary             text,
    payload_jsonb       jsonb NOT NULL DEFAULT '{}'::jsonb,
    occurred_at         timestamptz,
    occurred_until      timestamptz,
    recorded_at         timestamptz NOT NULL DEFAULT now(),
    sensitivity         text NOT NULL DEFAULT 'internal'
        CHECK (sensitivity IN ('public','internal','restricted','prohibited')),
    lifecycle_state     text NOT NULL DEFAULT 'active'
        CHECK (lifecycle_state IN ('active','consolidated','superseded','archived','retired','legal_hold','tombstoned')),
    created_at          timestamptz NOT NULL DEFAULT now()
);
```

### `maludb_core.malu$memory_detail_object`  
<sub>line 7838</sub>

```sql
CREATE TABLE malu$memory_detail_object (
    mdo_id              bigserial PRIMARY KEY,
    owner_schema        name NOT NULL DEFAULT current_schema(),
    -- Parent: nested under another MDO, OR top-level under memory/episode.
    parent_mdo_id       bigint REFERENCES malu$memory_detail_object(mdo_id) ON DELETE CASCADE,
    memory_id           bigint REFERENCES malu$memory(memory_id)              ON DELETE CASCADE,
    episode_id          bigint REFERENCES malu$episode_object(episode_id)     ON DELETE CASCADE,
    detail_kind         text NOT NULL,
    -- examples: step, substep, parameter, command, validation, exception,
    --           source_excerpt, evidence, observation
    ordinal             integer,
    title               text,
    body_text           text,
    body_jsonb          jsonb,
    sensitivity         text NOT NULL DEFAULT 'internal'
        CHECK (sensitivity IN ('public','internal','restricted','prohibited')),
    created_at          timestamptz NOT NULL DEFAULT now(),
    CHECK (parent_mdo_id IS NOT NULL OR memory_id IS NOT NULL OR episode_id IS NOT NULL)
);
```

### `maludb_core.malu$relationship_edge`  
<sub>line 7868</sub>

```sql
CREATE TABLE malu$relationship_edge (
    edge_id                 bigserial PRIMARY KEY,
    owner_schema            name NOT NULL DEFAULT current_schema(),
    relationship_type       text NOT NULL
        REFERENCES malu$relationship_type(relationship_type),
    source_object_type      text NOT NULL,
    source_object_id        bigint NOT NULL,
    target_object_type      text NOT NULL,
    target_object_id        bigint NOT NULL,
    label                   text,
    edge_jsonb              jsonb,
    confidence              numeric(5,4) CHECK (confidence IS NULL OR (confidence >= 0 AND confidence <= 1)),
    created_at              timestamptz NOT NULL DEFAULT now(),
    CHECK (source_object_type IN
        ('source_package','claim','fact','memory','episode_object','memory_detail_object')),
    CHECK (target_object_type IN
        ('source_package','claim','fact','memory','episode_object','memory_detail_object'))
);
```

### `maludb_core.malu$derivation_ledger`  
<sub>line 7898</sub>

```sql
CREATE TABLE malu$derivation_ledger (
    derivation_id           bigserial PRIMARY KEY,
    owner_schema            name NOT NULL DEFAULT current_schema(),
    derived_object_type     text NOT NULL,
    derived_object_id       bigint NOT NULL,
    -- The pipeline that produced the derived object
    parser_name             text,
    model_alias_id          bigint REFERENCES malu$model_alias(alias_id)         ON DELETE SET NULL,
    prompt_template_id      bigint REFERENCES malu$prompt_template(template_id)  ON DELETE SET NULL,
    policy_name             text,
    verifier_name           text,
    -- When the derivation went through the R1.0 model gateway, link it.
    model_request_id        bigint REFERENCES malu$model_request(request_id)     ON DELETE SET NULL,
    -- Inputs: jsonb manifest plus a sha256 over the canonical form
    inputs_jsonb            jsonb NOT NULL DEFAULT '[]'::jsonb,
    inputs_hash             text  NOT NULL,
    derived_at              timestamptz NOT NULL DEFAULT now(),
    CHECK (derived_object_type IN
        ('source_package','claim','fact','memory','episode_object','memory_detail_object',
         'relationship_edge'))
);
```

### `maludb_core.malu$verbatim_archive`  
<sub>line 8391</sub>

```sql
CREATE TABLE malu$verbatim_archive (
    archive_id            bigserial PRIMARY KEY,
    source_package_id     bigint NOT NULL
        REFERENCES malu$source_package(source_package_id) ON DELETE RESTRICT,
    owner_schema          name NOT NULL DEFAULT current_schema(),
    placement_tier        text NOT NULL DEFAULT 'inline'
        CHECK (placement_tier IN ('inline','hot','warm','cold','external')),
    content_bytes         bytea,
    content_compression   text NOT NULL DEFAULT 'none'
        CHECK (content_compression IN ('none','gzip','zstd')),
    content_size_archived bigint,
    archive_hash          text NOT NULL,
    external_uri          text,
    external_etag         text,
    sealed_at             timestamptz NOT NULL DEFAULT now(),
    superseded_at         timestamptz,
    note                  text,
    CHECK (placement_tier <> 'external' OR external_uri IS NOT NULL),
    CHECK (placement_tier <> 'cold'     OR external_uri IS NOT NULL),
    CHECK (placement_tier NOT IN ('inline','hot') OR content_compression = 'none')
);
```

### `maludb_core.malu$source_verification`  
<sub>line 8430</sub>

```sql
CREATE TABLE malu$source_verification (
    verification_id      bigserial PRIMARY KEY,
    source_package_id    bigint NOT NULL
        REFERENCES malu$source_package(source_package_id) ON DELETE CASCADE,
    archive_id           bigint
        REFERENCES malu$verbatim_archive(archive_id) ON DELETE SET NULL,
    performed_by         name NOT NULL DEFAULT current_user,
    performed_at         timestamptz NOT NULL DEFAULT now(),
    expected_hash        text NOT NULL,
    computed_hash        text NOT NULL,
    matched              boolean NOT NULL,
    context_note         text
);
```

### `maludb_core.malu$object_grant`  
<sub>line 9265</sub>

```sql
CREATE TABLE malu$object_grant (
    grant_id            bigserial PRIMARY KEY,
    object_type         text NOT NULL,
    object_id           bigint NOT NULL,
    granted_by_schema   name NOT NULL DEFAULT current_schema(),
    granted_to_schema   name NOT NULL,
    grant_level         text NOT NULL DEFAULT 'read'
        CHECK (grant_level IN ('read','write','full')),
    granted_at          timestamptz NOT NULL DEFAULT now(),
    expires_at          timestamptz,
    revoked_at          timestamptz,
    note                text,
    CHECK (object_type IN
        ('source_package','claim','fact','memory','episode_object',
         'memory_detail_object','relationship_edge','derivation_ledger')),
    -- A given grantee can only have one active grant per object —
    -- raise the level instead of stacking. Revoked rows are kept for
    -- audit; partial unique index ensures only one active row.
    CONSTRAINT malu$object_grant_unique_active
        EXCLUDE (object_type WITH =, object_id WITH =, granted_to_schema WITH =)
        WHERE (revoked_at IS NULL)
);
```

### `maludb_core.malu$payload_schema`  
<sub>line 9613</sub>

```sql
CREATE TABLE malu$payload_schema (
    schema_id           bigserial PRIMARY KEY,
    target_object_type  text NOT NULL,
    schema_name         text NOT NULL,
    schema_jsonb        jsonb NOT NULL,
    description         text,
    enabled             boolean NOT NULL DEFAULT true,
    owner_schema        name NOT NULL DEFAULT current_schema(),
    created_at          timestamptz NOT NULL DEFAULT now(),
    updated_at          timestamptz NOT NULL DEFAULT now(),
    CHECK (target_object_type IN
        ('source_package','claim','fact','memory','episode_object',
         'memory_detail_object')),
    UNIQUE (target_object_type, schema_name, owner_schema)
);
```

### `maludb_core.malu$ingestion_connector`  
<sub>line 10132</sub>

```sql
CREATE TABLE malu$ingestion_connector (
    connector_id        bigserial PRIMARY KEY,
    owner_schema        name NOT NULL DEFAULT current_schema(),
    connector_name      text NOT NULL,
    connector_kind      text NOT NULL,
    source_type         text NOT NULL
        REFERENCES malu$source_type(source_type),
    config_jsonb        jsonb NOT NULL DEFAULT '{}'::jsonb,
    enabled             boolean NOT NULL DEFAULT true,
    sensitivity         text NOT NULL DEFAULT 'internal'
        CHECK (sensitivity IN ('public','internal','restricted','prohibited')),
    created_at          timestamptz NOT NULL DEFAULT now(),
    updated_at          timestamptz NOT NULL DEFAULT now(),
    UNIQUE (owner_schema, connector_name)
);
```

### `maludb_core.malu$ingestion_checkpoint`  
<sub>line 10161</sub>

```sql
CREATE TABLE malu$ingestion_checkpoint (
    checkpoint_id       bigserial PRIMARY KEY,
    connector_id        bigint NOT NULL
        REFERENCES malu$ingestion_connector(connector_id) ON DELETE CASCADE,
    owner_schema        name NOT NULL DEFAULT current_schema(),
    cursor_name         text NOT NULL DEFAULT 'default',
    cursor_format       text NOT NULL DEFAULT 'opaque'
        CHECK (cursor_format IN ('timestamp','opaque','message_id','offset','jsonb')),
    cursor_value        text,
    cursor_jsonb        jsonb,
    mode                text NOT NULL DEFAULT 'continuous'
        CHECK (mode IN ('retrospective','continuous','paused')),
    last_advanced_at    timestamptz,
    last_attempt_at     timestamptz,
    last_error          text,
    items_ingested      bigint NOT NULL DEFAULT 0,
    created_at          timestamptz NOT NULL DEFAULT now(),
    updated_at          timestamptz NOT NULL DEFAULT now(),
    UNIQUE (connector_id, cursor_name)
);
```

### `maludb_core.malu$pending_claim`  
<sub>line 10192</sub>

```sql
CREATE TABLE malu$pending_claim (
    pending_claim_id    bigserial PRIMARY KEY,
    owner_schema        name NOT NULL DEFAULT current_schema(),
    connector_id        bigint
        REFERENCES malu$ingestion_connector(connector_id) ON DELETE SET NULL,
    source_package_id   bigint
        REFERENCES malu$source_package(source_package_id) ON DELETE SET NULL,
    subject             text,
    verb                text,
    predicate           text,
    object_value        text,
    relationship        text,
    statement_text      text,
    statement_jsonb     jsonb,
    source_locator      jsonb,
    confidence          numeric(5,4)
        CHECK (confidence IS NULL OR (confidence >= 0 AND confidence <= 1)),
    proposed_at         timestamptz NOT NULL DEFAULT now(),
    proposed_by         text,
    review_state        text NOT NULL DEFAULT 'pending'
        CHECK (review_state IN ('pending','accepted','rejected','duplicate','superseded')),
    reviewed_at         timestamptz,
    reviewed_by         text,
    review_note         text,
    promoted_claim_id   bigint
        REFERENCES malu$claim(claim_id) ON DELETE SET NULL,
    sensitivity         text NOT NULL DEFAULT 'internal'
        CHECK (sensitivity IN ('public','internal','restricted','prohibited'))
);
```

### `maludb_core.malu$audit_event`  
<sub>line 10571</sub>

```sql
CREATE TABLE malu$audit_event (
    event_id            bigserial PRIMARY KEY,
    owner_schema        name NOT NULL DEFAULT current_schema(),
    actor_role          name NOT NULL DEFAULT current_user,
    event_kind          text NOT NULL,
    target_object_type  text,
    target_object_id    bigint,
    event_jsonb         jsonb,
    error_text          text,
    occurred_at         timestamptz NOT NULL DEFAULT now()
);
```

### `maludb_core.malu$supersession_edge`  
<sub>line 11338</sub>

```sql
CREATE TABLE malu$supersession_edge (
    edge_id              bigserial PRIMARY KEY,
    owner_schema         name NOT NULL DEFAULT current_schema(),
    predecessor_type     text NOT NULL,
    predecessor_id       bigint NOT NULL,
    successor_type       text,
    successor_id         bigint,
    supersession_kind    text NOT NULL DEFAULT 'correction'
        CHECK (supersession_kind IN ('correction','refinement','retraction',
                                     'consolidation','merge','split')),
    reason               text,
    superseded_at        timestamptz NOT NULL DEFAULT now(),
    actor_role           name NOT NULL DEFAULT current_user,
    CHECK (predecessor_type IN ('fact','memory','episode_object','claim')),
    CHECK (successor_type IS NULL OR
           successor_type IN ('fact','memory','episode_object','claim')),
    -- predecessor and successor (when both present) must be the same kind
    CHECK (successor_type IS NULL OR predecessor_type = successor_type),
    -- no self-supersession
    CHECK (NOT (predecessor_type = successor_type
                AND predecessor_id = successor_id))
);
```

### `maludb_core.malu$svpor_subject`  
<sub>line 11776</sub>

```sql
CREATE TABLE malu$svpor_subject (
    subject_id      bigserial PRIMARY KEY,
    owner_schema    name NOT NULL DEFAULT current_schema(),
    canonical_name  text NOT NULL,
    aliases         text[] NOT NULL DEFAULT ARRAY[]::text[],
    description     text,
    created_at      timestamptz NOT NULL DEFAULT now(),
    UNIQUE (owner_schema, canonical_name)
);
```

### `maludb_core.malu$svpor_verb`  
<sub>line 11788</sub>

```sql
CREATE TABLE malu$svpor_verb (
    verb_id         bigserial PRIMARY KEY,
    owner_schema    name NOT NULL DEFAULT current_schema(),
    canonical_name  text NOT NULL,
    aliases         text[] NOT NULL DEFAULT ARRAY[]::text[],
    description     text,
    created_at      timestamptz NOT NULL DEFAULT now(),
    UNIQUE (owner_schema, canonical_name)
);
```

### `maludb_core.malu$svpor_predicate`  
<sub>line 11800</sub>

```sql
CREATE TABLE malu$svpor_predicate (
    predicate_id    bigserial PRIMARY KEY,
    owner_schema    name NOT NULL DEFAULT current_schema(),
    canonical_name  text NOT NULL,
    aliases         text[] NOT NULL DEFAULT ARRAY[]::text[],
    description     text,
    created_at      timestamptz NOT NULL DEFAULT now(),
    UNIQUE (owner_schema, canonical_name)
);
```

### `maludb_core.malu$maut_weight`  
<sub>line 12140</sub>

```sql
CREATE TABLE malu$maut_weight (
    weight_id           bigserial PRIMARY KEY,
    owner_schema        name NOT NULL DEFAULT current_schema(),
    target_object_type  text NOT NULL,
    category            text NOT NULL,
    weight              numeric(5,4) NOT NULL
        CHECK (weight >= 0 AND weight <= 1),
    enabled             boolean NOT NULL DEFAULT true,
    description         text,
    created_at          timestamptz NOT NULL DEFAULT now(),
    updated_at          timestamptz NOT NULL DEFAULT now(),
    CHECK (target_object_type IN ('claim','fact','memory','episode_object')),
    CHECK (category IN (
        'supporting_facts','claim_consistency','source_diversity',
        'inference','temporal_coherence','contradiction_status',
        'staleness_status')),
    UNIQUE (owner_schema, target_object_type, category)
);
```

### `maludb_core.malu$maut_score`  
<sub>line 12179</sub>

```sql
CREATE TABLE malu$maut_score (
    score_id            bigserial PRIMARY KEY,
    owner_schema        name NOT NULL DEFAULT current_schema(),
    target_object_type  text NOT NULL,
    target_object_id    bigint NOT NULL,
    category            text NOT NULL,
    subscore            numeric(5,4) NOT NULL
        CHECK (subscore >= 0 AND subscore <= 1),
    evaluator_name      text NOT NULL,
    evaluator_kind      text NOT NULL DEFAULT 'manual'
        CHECK (evaluator_kind IN ('manual','automated','model','external')),
    evaluator_meta      jsonb,
    evidence            jsonb,
    evaluated_at        timestamptz NOT NULL DEFAULT now(),
    CHECK (target_object_type IN ('claim','fact','memory','episode_object')),
    CHECK (category IN (
        'supporting_facts','claim_consistency','source_diversity',
        'inference','temporal_coherence','contradiction_status',
        'staleness_status')),
    UNIQUE (owner_schema, target_object_type, target_object_id, category)
);
```

### `maludb_core.malu$lifecycle_policy`  
<sub>line 12465</sub>

```sql
CREATE TABLE malu$lifecycle_policy (
    policy_id                bigserial PRIMARY KEY,
    owner_schema             name NOT NULL DEFAULT current_schema(),
    target_object_type       text NOT NULL,
    decay_half_life_days     integer NOT NULL DEFAULT 90
        CHECK (decay_half_life_days > 0),
    archive_after_idle_days  integer
        CHECK (archive_after_idle_days IS NULL OR archive_after_idle_days > 0),
    retain_for_days          integer
        CHECK (retain_for_days IS NULL OR retain_for_days > 0),
    autotombstone_enabled    boolean NOT NULL DEFAULT false,
    created_at               timestamptz NOT NULL DEFAULT now(),
    updated_at               timestamptz NOT NULL DEFAULT now(),
    CHECK (target_object_type IN
        ('claim','fact','memory','episode_object','memory_detail_object')),
    UNIQUE (owner_schema, target_object_type)
);
```

### `maludb_core.malu$reinforcement_event`  
<sub>line 12494</sub>

```sql
CREATE TABLE malu$reinforcement_event (
    event_id            bigserial PRIMARY KEY,
    owner_schema        name NOT NULL DEFAULT current_schema(),
    target_object_type  text NOT NULL,
    target_object_id    bigint NOT NULL,
    event_kind          text NOT NULL,
    weight              numeric(5,4) NOT NULL DEFAULT 1.0
        CHECK (weight >= 0 AND weight <= 10),
    actor_role          name NOT NULL DEFAULT current_user,
    context_jsonb       jsonb,
    occurred_at         timestamptz NOT NULL DEFAULT now(),
    CHECK (target_object_type IN
        ('claim','fact','memory','episode_object','memory_detail_object')),
    CHECK (event_kind IN ('access','citation','edit','review','propagation','consolidation'))
);
```

### `maludb_core.malu$legal_hold`  
<sub>line 12522</sub>

```sql
CREATE TABLE malu$legal_hold (
    hold_id          bigserial PRIMARY KEY,
    owner_schema     name NOT NULL DEFAULT current_schema(),
    target_object_type text NOT NULL,
    target_object_id   bigint NOT NULL,
    reason           text NOT NULL,
    applied_at       timestamptz NOT NULL DEFAULT now(),
    applied_by       name NOT NULL DEFAULT current_user,
    released_at      timestamptz,
    released_by      name,
    release_reason   text,
    CHECK (target_object_type IN
        ('source_package','claim','fact','memory','episode_object','memory_detail_object'))
);
```

### `maludb_core.malu$retrieval_envelope`  
<sub>line 13448</sub>

```sql
CREATE TABLE malu$retrieval_envelope (
    envelope_id        bigserial PRIMARY KEY,
    owner_schema       name NOT NULL DEFAULT current_schema(),
    cue_text           text NOT NULL,
    object_types       text[] NOT NULL DEFAULT ARRAY['claim','fact','memory','episode_object'],
    valid_as_of        timestamptz,
    transaction_as_of  timestamptz,
    confidence_floor   numeric(5,4),
    hints              jsonb,
    plan_jsonb         jsonb,
    actor_role         name NOT NULL DEFAULT current_user,
    created_at         timestamptz NOT NULL DEFAULT now()
);
```

### `maludb_core.malu$query_hint`  
<sub>line 13798</sub>

```sql
CREATE TABLE malu$query_hint (
    hint_id        bigserial PRIMARY KEY,
    owner_schema   name NOT NULL DEFAULT current_schema(),
    hint_name      text NOT NULL,
    hint_jsonb     jsonb NOT NULL,
    description    text,
    enabled        boolean NOT NULL DEFAULT true,
    created_at     timestamptz NOT NULL DEFAULT now(),
    updated_at     timestamptz NOT NULL DEFAULT now(),
    UNIQUE (owner_schema, hint_name)
);
```

### `maludb_core.malu$workflow_trace`  
<sub>line 14402</sub>

```sql
CREATE TABLE malu$workflow_trace (
    trace_id           bigserial PRIMARY KEY,
    owner_schema       name NOT NULL DEFAULT current_schema(),
    episode_id         bigint NOT NULL REFERENCES malu$episode_object(episode_id) ON DELETE CASCADE,
    subject_class      text NOT NULL,
    action_class       text NOT NULL,
    outcome            text NOT NULL
        CHECK (outcome IN ('success','partial','failure','aborted','pending')),
    environment        text,
    tool_stack         text[],
    exception_pattern  text,
    confidence         numeric(5,4)
        CHECK (confidence IS NULL OR (confidence >= 0 AND confidence <= 1)),
    step_count         integer NOT NULL DEFAULT 0,
    positive_evidence  boolean NOT NULL,
    security_domain    text,
    payload_jsonb      jsonb,
    extracted_at       timestamptz NOT NULL DEFAULT now()
);
```

### `maludb_core.malu$workflow_step`  
<sub>line 14445</sub>

```sql
CREATE TABLE malu$workflow_step (
    step_id                       bigserial PRIMARY KEY,
    owner_schema                  name NOT NULL DEFAULT current_schema(),
    trace_id                      bigint NOT NULL REFERENCES malu$workflow_trace(trace_id) ON DELETE CASCADE,
    step_idx                      integer NOT NULL,
    action_class                  text NOT NULL,
    subject                       text,
    object_value                  text,
    actor                         text,
    tool                          text,
    started_at                    timestamptz,
    ended_at                      timestamptz,
    outcome                       text
        CHECK (outcome IS NULL OR outcome IN ('success','partial','failure','aborted','pending','skipped')),
    evidence_source_id            bigint REFERENCES malu$source_package(source_package_id) ON DELETE SET NULL,
    evidence_mdo_id               bigint REFERENCES malu$memory_detail_object(mdo_id) ON DELETE SET NULL,
    exception_text                text,
    predecessor_step_id           bigint REFERENCES malu$workflow_step(step_id) ON DELETE SET NULL,
    caused_by_step_id             bigint REFERENCES malu$workflow_step(step_id) ON DELETE SET NULL,
    caused_by_evidence_source_id  bigint REFERENCES malu$source_package(source_package_id) ON DELETE SET NULL,
    payload_jsonb                 jsonb,
    CHECK (caused_by_step_id IS NULL OR caused_by_evidence_source_id IS NOT NULL),
    UNIQUE (trace_id, step_idx)
);
```

### `maludb_core.malu$workflow_cluster`  
<sub>line 14497</sub>

```sql
CREATE TABLE malu$workflow_cluster (
    cluster_id              bigserial PRIMARY KEY,
    owner_schema            name NOT NULL DEFAULT current_schema(),
    subject_class           text NOT NULL,
    action_class            text NOT NULL,
    outcome                 text NOT NULL
        CHECK (outcome IN ('success','partial','failure','aborted','pending')),
    environment             text NOT NULL DEFAULT '',
    tool_stack_signature    text NOT NULL DEFAULT '',
    exception_pattern       text NOT NULL DEFAULT '',
    member_count            integer NOT NULL DEFAULT 0,
    positive_member_count   integer NOT NULL DEFAULT 0,
    negative_member_count   integer NOT NULL DEFAULT 0,
    created_at              timestamptz NOT NULL DEFAULT now(),
    UNIQUE (owner_schema, subject_class, action_class, outcome,
            environment, tool_stack_signature, exception_pattern)
);
```

### `maludb_core.malu$workflow_cluster_member`  
<sub>line 14527</sub>

```sql
CREATE TABLE malu$workflow_cluster_member (
    cluster_id    bigint NOT NULL REFERENCES malu$workflow_cluster(cluster_id) ON DELETE CASCADE,
    trace_id      bigint NOT NULL REFERENCES malu$workflow_trace(trace_id) ON DELETE CASCADE,
    owner_schema  name NOT NULL DEFAULT current_schema(),
    added_at      timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (cluster_id, trace_id)
);
```

### `maludb_core.malu$workflow_candidate`  
<sub>line 14551</sub>

```sql
CREATE TABLE malu$workflow_candidate (
    candidate_id              bigserial PRIMARY KEY,
    owner_schema              name NOT NULL DEFAULT current_schema(),
    cluster_id                bigint NOT NULL REFERENCES malu$workflow_cluster(cluster_id) ON DELETE CASCADE,
    name                      text NOT NULL,
    description               text,
    step_template             jsonb NOT NULL,
    review_status             text NOT NULL DEFAULT 'proposed'
        CHECK (review_status IN ('proposed','approved','rejected','withdrawn')),
    review_notes              text,
    reviewed_by               name,
    reviewed_at               timestamptz,
    provenance                jsonb,
    positive_evidence_count   integer NOT NULL DEFAULT 0,
    negative_evidence_count   integer NOT NULL DEFAULT 0,
    created_at                timestamptz NOT NULL DEFAULT now(),
    updated_at                timestamptz NOT NULL DEFAULT now()
);
```

### `maludb_core.malu$skill_package`  
<sub>line 15049</sub>

```sql
CREATE TABLE malu$skill_package (
    skill_id              bigserial PRIMARY KEY,
    owner_schema          name NOT NULL DEFAULT current_schema(),
    skill_name            text NOT NULL,
    version               text NOT NULL DEFAULT '1.0.0',
    description           text,
    packaging_kind        text NOT NULL DEFAULT 'markdown'
        CHECK (packaging_kind IN ('system_prompt','markdown','mcp_tool','plugin')),
    applicability_jsonb   jsonb NOT NULL DEFAULT '{}'::jsonb,
    precondition_jsonb    jsonb NOT NULL DEFAULT '[]'::jsonb,
    enabled               boolean NOT NULL DEFAULT true,
    created_at            timestamptz NOT NULL DEFAULT now(),
    updated_at            timestamptz NOT NULL DEFAULT now(),
    UNIQUE (owner_schema, skill_name, version)
);
```

### `maludb_core.malu$skill_state`  
<sub>line 15088</sub>

```sql
CREATE TABLE malu$skill_state (
    state_id        bigserial PRIMARY KEY,
    owner_schema    name NOT NULL DEFAULT current_schema(),
    skill_id        bigint NOT NULL REFERENCES malu$skill_package(skill_id) ON DELETE CASCADE,
    state_name      text NOT NULL,
    state_kind      text NOT NULL
        CHECK (state_kind IN ('start','step','validation','exception_handler','terminal')),
    step_jsonb      jsonb,
    validation_jsonb jsonb,
    UNIQUE (skill_id, state_name)
);
```

### `maludb_core.malu$skill_transition`  
<sub>line 15124</sub>

```sql
CREATE TABLE malu$skill_transition (
    transition_id   bigserial PRIMARY KEY,
    owner_schema    name NOT NULL DEFAULT current_schema(),
    skill_id        bigint NOT NULL REFERENCES malu$skill_package(skill_id) ON DELETE CASCADE,
    from_state_id   bigint NOT NULL REFERENCES malu$skill_state(state_id) ON DELETE CASCADE,
    to_state_id     bigint NOT NULL REFERENCES malu$skill_state(state_id) ON DELETE CASCADE,
    on_outcome      text NOT NULL,
    guard_jsonb     jsonb,
    ordinal         integer NOT NULL DEFAULT 0,
    UNIQUE (skill_id, from_state_id, on_outcome)
);
```

### `maludb_core.malu$skill_execution_record`  
<sub>line 15154</sub>

```sql
CREATE TABLE malu$skill_execution_record (
    execution_id            bigserial PRIMARY KEY,
    owner_schema            name NOT NULL DEFAULT current_schema(),
    skill_id                bigint NOT NULL REFERENCES malu$skill_package(skill_id) ON DELETE RESTRICT,
    account_id              bigint REFERENCES malu$account(account_id) ON DELETE SET NULL,
    actor_role              name NOT NULL DEFAULT current_user,
    active_pool_id          bigint,   -- FK added when malu$active_memory_pool lands (S5-3)
    task_objective          text,
    authorized_partitions   text[],
    source_context_id       bigint REFERENCES malu$source_package(source_package_id) ON DELETE SET NULL,
    environment             text,
    technology_stack        text[],
    bound_at                timestamptz NOT NULL DEFAULT now(),
    started_at              timestamptz,
    completed_at            timestamptz,
    current_state_id        bigint REFERENCES malu$skill_state(state_id) ON DELETE SET NULL,
    final_outcome           text
        CHECK (final_outcome IS NULL OR final_outcome IN ('success','failure','aborted')),
    step_count              integer NOT NULL DEFAULT 0,
    emitted_claim_ids       bigint[] NOT NULL DEFAULT ARRAY[]::bigint[],
    audit_jsonb             jsonb
);
```

### `maludb_core.malu$skill_execution_step`  
<sub>line 15194</sub>

```sql
CREATE TABLE malu$skill_execution_step (
    exec_step_id     bigserial PRIMARY KEY,
    owner_schema     name NOT NULL DEFAULT current_schema(),
    execution_id     bigint NOT NULL REFERENCES malu$skill_execution_record(execution_id) ON DELETE CASCADE,
    step_idx         integer NOT NULL,
    state_id         bigint NOT NULL REFERENCES malu$skill_state(state_id) ON DELETE RESTRICT,
    state_name       text NOT NULL,
    outcome          text,
    observation_jsonb jsonb,
    entered_at       timestamptz NOT NULL DEFAULT now(),
    left_at          timestamptz,
    UNIQUE (execution_id, step_idx)
);
```

### `maludb_core.malu$active_memory_pool`  
<sub>line 15740</sub>

```sql
CREATE TABLE malu$active_memory_pool (
    pool_id                bigserial PRIMARY KEY,
    owner_schema           name NOT NULL DEFAULT current_schema(),
    pool_name              text NOT NULL,
    creation_kind          text NOT NULL DEFAULT 'sql'
        CHECK (creation_kind IN ('prompt','api','mcp','sql')),
    created_by             name NOT NULL DEFAULT current_user,
    task_objective         text,
    authorized_partitions  text[],
    confidence_floor       numeric(5,4)
        CHECK (confidence_floor IS NULL OR (confidence_floor >= 0 AND confidence_floor <= 1)),
    validity_start         timestamptz,
    validity_end           timestamptz,
    max_member_count       integer
        CHECK (max_member_count IS NULL OR max_member_count > 0),
    lifecycle_state        text NOT NULL DEFAULT 'active'
        CHECK (lifecycle_state IN ('active','sealed','archived','tombstoned')),
    sealed_at              timestamptz,
    archived_at            timestamptz,
    tombstoned_at          timestamptz,
    created_at             timestamptz NOT NULL DEFAULT now(),
    updated_at             timestamptz NOT NULL DEFAULT now(),
    UNIQUE (owner_schema, pool_name),
    CHECK (validity_start IS NULL OR validity_end IS NULL OR validity_start <= validity_end)
);
```

### `maludb_core.malu$active_memory_pool_member`  
<sub>line 15794</sub>

```sql
CREATE TABLE malu$active_memory_pool_member (
    member_id                  bigserial PRIMARY KEY,
    owner_schema               name NOT NULL DEFAULT current_schema(),
    pool_id                    bigint NOT NULL REFERENCES malu$active_memory_pool(pool_id) ON DELETE CASCADE,
    member_kind                text NOT NULL
        CHECK (member_kind IN
               ('observation','pending_claim','memory','fact',
                'episode_object','workflow_trace','skill','source_reference')),
    member_object_type         text,
    member_object_id           bigint,
    payload_jsonb              jsonb,
    confidence                 numeric(5,4)
        CHECK (confidence IS NULL OR (confidence >= 0 AND confidence <= 1)),
    staleness                  numeric(5,4)
        CHECK (staleness  IS NULL OR (staleness  >= 0 AND staleness  <= 1)),
    access_label               text,
    provenance                 jsonb,
    added_by                   name NOT NULL DEFAULT current_user,
    added_account_id           bigint REFERENCES malu$account(account_id) ON DELETE SET NULL,
    added_at                   timestamptz NOT NULL DEFAULT now(),
    promoted_from_member_id    bigint REFERENCES malu$active_memory_pool_member(member_id) ON DELETE SET NULL,
    promoted_to_object_type    text,
    promoted_to_object_id      bigint,
    promoted_at                timestamptz,
    CHECK (
        (member_kind = 'observation' AND member_object_id IS NULL)
        OR (member_kind <> 'observation' AND member_object_id IS NOT NULL)
    )
);
```

### `maludb_core.malu$episode_replay`  
<sub>line 16333</sub>

```sql
CREATE TABLE malu$episode_replay (
    replay_id        bigserial PRIMARY KEY,
    owner_schema     name NOT NULL DEFAULT current_schema(),
    episode_id       bigint NOT NULL REFERENCES malu$episode_object(episode_id) ON DELETE CASCADE,
    mode             text NOT NULL
        CHECK (mode IN ('current_valid','historical',
                        'as_of_transaction_time','full_bitemporal')),
    as_of            timestamptz,
    actor_role       name NOT NULL DEFAULT current_user,
    envelope_jsonb   jsonb NOT NULL,
    created_at       timestamptz NOT NULL DEFAULT now()
);
```

### `maludb_core.malu$local_memory_node`  
<sub>line 16770</sub>

```sql
CREATE TABLE malu$local_memory_node (
    node_id            bigserial PRIMARY KEY,
    owner_schema       name NOT NULL DEFAULT current_schema(),
    node_name          text NOT NULL,
    fingerprint        text NOT NULL,
    uri                text,
    description        text,
    lifecycle_state    text NOT NULL DEFAULT 'active'
        CHECK (lifecycle_state IN ('active','quarantined','revoked','retired')),
    registered_at      timestamptz NOT NULL DEFAULT now(),
    last_seen_at       timestamptz,
    revoked_at         timestamptz,
    revoked_reason     text,
    UNIQUE (owner_schema, node_name),
    UNIQUE (owner_schema, fingerprint)
);
```

### `maludb_core.malu$node_sync_record`  
<sub>line 16812</sub>

```sql
CREATE TABLE malu$node_sync_record (
    submission_id        bigserial PRIMARY KEY,
    owner_schema         name NOT NULL DEFAULT current_schema(),
    node_id              bigint NOT NULL REFERENCES malu$local_memory_node(node_id) ON DELETE RESTRICT,
    submission_kind      text NOT NULL
        CHECK (submission_kind IN
              ('claim_new','fact_new','memory_new','episode_new',
               'source_package_new','workflow_update',
               'promotion_candidate','tombstone','deletion')),
    local_id             bigint,
    local_hash           text,
    payload_jsonb        jsonb NOT NULL,
    status               text NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending','accepted','rejected','conflict')),
    applied_object_type  text,
    applied_object_id    bigint,
    reason               text,
    submitted_at         timestamptz NOT NULL DEFAULT now(),
    decided_at           timestamptz,
    decided_by           name,
    UNIQUE (node_id, local_id, submission_kind)
);
```

### `maludb_core.malu$node_conflict_record`  
<sub>line 16858</sub>

```sql
CREATE TABLE malu$node_conflict_record (
    conflict_id          bigserial PRIMARY KEY,
    owner_schema         name NOT NULL DEFAULT current_schema(),
    submission_id        bigint NOT NULL REFERENCES malu$node_sync_record(submission_id) ON DELETE CASCADE,
    server_object_type   text,
    server_object_id     bigint,
    conflict_kind        text NOT NULL
        CHECK (conflict_kind IN
              ('duplicate','divergent_content','stale_local',
               'retracted_on_server','tombstoned_on_server','unknown')),
    resolution           text
        CHECK (resolution IS NULL OR resolution IN
              ('server_wins','local_wins_with_supersession',
               'merged','discarded')),
    resolution_notes     text,
    created_at           timestamptz NOT NULL DEFAULT now(),
    resolved_at          timestamptz,
    resolved_by          name
);
```

### `maludb_core.malu$embedding_space`  
<sub>line 17294</sub>

```sql
CREATE TABLE malu$embedding_space (
    space_id          bigserial PRIMARY KEY,
    owner_schema      name NOT NULL DEFAULT current_schema(),
    space_name        text NOT NULL,
    model_alias_id    bigint REFERENCES malu$model_alias(alias_id) ON DELETE SET NULL,
    dimensions        integer NOT NULL CHECK (dimensions > 0),
    normalization     text NOT NULL DEFAULT 'cosine'
        CHECK (normalization IN ('cosine','l2','inner_product','none')),
    description       text,
    created_at        timestamptz NOT NULL DEFAULT now(),
    UNIQUE (owner_schema, space_name)
);
```

### `maludb_core.malu$model_registry`  
<sub>line 17333</sub>

```sql
CREATE TABLE malu$model_registry (
    registry_id           bigserial PRIMARY KEY,
    owner_schema          name NOT NULL DEFAULT current_schema(),
    model_kind            text NOT NULL
        CHECK (model_kind IN ('embedding','extraction','reranker','summarizer')),
    model_alias_id        bigint REFERENCES malu$model_alias(alias_id) ON DELETE RESTRICT,
    embedding_space_id    bigint REFERENCES malu$embedding_space(space_id) ON DELETE RESTRICT,
    rollout_state         text NOT NULL DEFAULT 'proposed'
        CHECK (rollout_state IN ('proposed','canary','active','retiring','retired')),
    evaluation_status     text NOT NULL DEFAULT 'pending'
        CHECK (evaluation_status IN ('pending','passed','failed')),
    derived_artifact_map  jsonb NOT NULL DEFAULT '{}'::jsonb,
    notes                 text,
    registered_at         timestamptz NOT NULL DEFAULT now(),
    last_transition_at    timestamptz NOT NULL DEFAULT now(),
    UNIQUE (owner_schema, model_kind, model_alias_id),
    -- embedding model rows MUST carry a space; non-embedding rows MUST NOT.
    CHECK (
        (model_kind = 'embedding' AND embedding_space_id IS NOT NULL)
        OR
        (model_kind <> 'embedding' AND embedding_space_id IS NULL)
    )
);
```

### `maludb_core.malu$index_migration`  
<sub>line 17392</sub>

```sql
CREATE TABLE malu$index_migration (
    migration_id        bigserial PRIMARY KEY,
    owner_schema        name NOT NULL DEFAULT current_schema(),
    source_space_id     bigint NOT NULL REFERENCES malu$embedding_space(space_id) ON DELETE RESTRICT,
    target_space_id     bigint NOT NULL REFERENCES malu$embedding_space(space_id) ON DELETE RESTRICT,
    status              text NOT NULL DEFAULT 'proposed'
        CHECK (status IN ('proposed','shadow_building','dual_serve',
                          'cutover','cleanup','done','aborted')),
    traffic_pct         numeric(5,2) NOT NULL DEFAULT 0
        CHECK (traffic_pct >= 0 AND traffic_pct <= 100),
    index_kind          text NOT NULL DEFAULT 'hnsw'
        CHECK (index_kind IN ('hnsw','ivfflat','flat')),
    adapter_id          bigint,    -- FK added in S6-3
    notes               text,
    started_at          timestamptz NOT NULL DEFAULT now(),
    last_transition_at  timestamptz NOT NULL DEFAULT now(),
    completed_at        timestamptz,
    CHECK (source_space_id <> target_space_id)
);
```

### `maludb_core.malu$embedding_adapter`  
<sub>line 17842</sub>

```sql
CREATE TABLE malu$embedding_adapter (
    adapter_id        bigserial PRIMARY KEY,
    owner_schema      name NOT NULL DEFAULT current_schema(),
    adapter_name      text NOT NULL,
    source_space_id   bigint NOT NULL REFERENCES malu$embedding_space(space_id) ON DELETE RESTRICT,
    target_space_id   bigint NOT NULL REFERENCES malu$embedding_space(space_id) ON DELETE RESTRICT,
    adapter_kind      text NOT NULL
        CHECK (adapter_kind IN ('identity','linear_projection','learned_mlp','custom')),
    params_jsonb      jsonb NOT NULL DEFAULT '{}'::jsonb,
    evaluation        jsonb,
    enabled           boolean NOT NULL DEFAULT true,
    created_at        timestamptz NOT NULL DEFAULT now(),
    updated_at        timestamptz NOT NULL DEFAULT now(),
    UNIQUE (owner_schema, adapter_name),
    CHECK (source_space_id <> target_space_id)
);
```

### `maludb_core.malu$local_model_capability`  
<sub>line 17973</sub>

```sql
CREATE TABLE malu$local_model_capability (
    capability_id            bigserial PRIMARY KEY,
    owner_schema             name NOT NULL DEFAULT current_schema(),
    model_alias_id           bigint NOT NULL REFERENCES malu$model_alias(alias_id) ON DELETE CASCADE,
    gpu_available            boolean NOT NULL DEFAULT false,
    gpu_kind                 text
        CHECK (gpu_kind IS NULL OR gpu_kind IN
              ('nvidia','amd','intel','apple_metal','cpu_only')),
    vram_mb                  integer CHECK (vram_mb IS NULL OR vram_mb >= 0),
    system_ram_mb            integer CHECK (system_ram_mb IS NULL OR system_ram_mb >= 0),
    supports_quantizations   text[] NOT NULL DEFAULT ARRAY[]::text[],
    context_window           integer CHECK (context_window IS NULL OR context_window > 0),
    max_batch_size           integer CHECK (max_batch_size IS NULL OR max_batch_size > 0),
    typical_tokens_per_sec   real    CHECK (typical_tokens_per_sec IS NULL OR typical_tokens_per_sec >= 0),
    platform_jsonb           jsonb,
    last_negotiated_at       timestamptz NOT NULL DEFAULT now(),
    UNIQUE (owner_schema, model_alias_id)
);
```

### `maludb_core.malu$auth_pepper`  
<sub>line 18923</sub>

```sql
CREATE TABLE malu$auth_pepper (
    pepper_id  smallint PRIMARY KEY CHECK (pepper_id = 1),
    pepper     bytea    NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);
```

### `maludb_core.malu$auth_token`  
<sub>line 18943</sub>

```sql
CREATE TABLE malu$auth_token (
    token_id       bigserial PRIMARY KEY,
    account_id     bigint    NOT NULL REFERENCES malu$account(account_id) ON DELETE CASCADE,
    token_hash     bytea     NOT NULL UNIQUE,
    token_kind     text      NOT NULL CHECK (token_kind IN ('personal','service')),
    label          text,
    scopes         text[]    NOT NULL DEFAULT ARRAY[]::text[],
    allowed_cidrs  inet[],
    created_at     timestamptz NOT NULL DEFAULT now(),
    expires_at     timestamptz,
    last_used_at   timestamptz,
    revoked_at     timestamptz,
    owner_schema   name      NOT NULL DEFAULT current_schema(),
    CHECK (expires_at IS NULL OR expires_at > created_at)
);
```

### `maludb_core.malu$auth_token_use`  
<sub>line 18973</sub>

```sql
CREATE TABLE malu$auth_token_use (
    use_id      bigserial PRIMARY KEY,
    token_id    bigint    NOT NULL REFERENCES malu$auth_token(token_id) ON DELETE CASCADE,
    used_at     timestamptz NOT NULL DEFAULT now(),
    source_ip   inet,
    outcome     text      NOT NULL CHECK (outcome IN
                  ('accepted','rejected_expired','rejected_revoked',
                   'rejected_cidr','rejected_disabled_account')),
    detail      text
);
```

### `maludb_core.malu$jwt_signing_key`  
<sub>line 18994</sub>

```sql
CREATE TABLE malu$jwt_signing_key (
    key_id      bigserial PRIMARY KEY,
    kid         text      NOT NULL UNIQUE,
    kty         text      NOT NULL CHECK (kty IN ('RSA','EC','OKP')),
    alg         text      NOT NULL CHECK (alg IN ('RS256','RS384','RS512',
                                                  'ES256','ES384','ES512',
                                                  'EdDSA')),
    public_jwk  jsonb     NOT NULL,
    enabled     boolean   NOT NULL DEFAULT true,
    created_at  timestamptz NOT NULL DEFAULT now(),
    rotated_at  timestamptz,
    note        text
);
```

### `maludb_core.malu$secret_master_key`  
<sub>line 19431</sub>

```sql
CREATE TABLE malu$secret_master_key (
    master_key_id smallint PRIMARY KEY CHECK (master_key_id = 1),
    key_material  bytea    NOT NULL,
    note          text     NOT NULL DEFAULT 'dev-mode in-DB master key; replace via the production resolver before exposing to a network',
    created_at    timestamptz NOT NULL DEFAULT now()
);
```

### `maludb_core.malu$secret`  
<sub>line 19446</sub>

```sql
CREATE TABLE malu$secret (
    secret_id            bigserial PRIMARY KEY,
    name                 text      NOT NULL,
    kind                 text      NOT NULL CHECK (kind IN
                            ('provider','tool','broker','storage','log_drain','backup','other')),
    description          text,
    rotation_policy_days integer,
    owner_schema         name      NOT NULL DEFAULT current_schema(),
    created_at           timestamptz NOT NULL DEFAULT now(),
    retired_at           timestamptz,
    UNIQUE (owner_schema, name)
);
```

### `maludb_core.malu$secret_version`  
<sub>line 19468</sub>

```sql
CREATE TABLE malu$secret_version (
    secret_version_id bigserial PRIMARY KEY,
    secret_id         bigint    NOT NULL REFERENCES malu$secret(secret_id) ON DELETE CASCADE,
    version           integer   NOT NULL,
    value_encrypted   bytea,
    external_ref      text,
    kdf_alg           text,
    created_at        timestamptz NOT NULL DEFAULT now(),
    retired_at        timestamptz,
    last_used_at      timestamptz,
    UNIQUE (secret_id, version),
    CHECK (
        (value_encrypted IS NOT NULL AND external_ref IS NULL)
        OR
        (value_encrypted IS NULL AND external_ref IS NOT NULL)
    )
);
```

### `maludb_core.malu$secret_use`  
<sub>line 19491</sub>

```sql
CREATE TABLE malu$secret_use (
    use_id            bigserial PRIMARY KEY,
    secret_version_id bigint    NOT NULL REFERENCES malu$secret_version(secret_version_id) ON DELETE CASCADE,
    used_at           timestamptz NOT NULL DEFAULT now(),
    caller_role       name      NOT NULL DEFAULT current_user,
    outcome           text      NOT NULL CHECK (outcome IN
                        ('resolved','rejected_retired','rejected_external_not_available')),
    detail            text
);
```

### `maludb_core.malu$rest_endpoint`  
<sub>line 20008</sub>

```sql
CREATE TABLE malu$rest_endpoint (
    endpoint_id        bigserial PRIMARY KEY,
    path               text       NOT NULL,
    method             text       NOT NULL CHECK (method IN
                          ('GET','POST','PUT','PATCH','DELETE')),
    handler_function   regprocedure NOT NULL,
    description        text,
    auth_required      boolean    NOT NULL DEFAULT true,
    required_scopes    text[]     NOT NULL DEFAULT ARRAY[]::text[],
    risk_class         text       NOT NULL DEFAULT 'read_only' CHECK (risk_class IN
                          ('read_only','evidence_producing','state_changing',
                           'external_effect','administrative')),
    openapi_spec       jsonb      NOT NULL DEFAULT '{}'::jsonb,
    timeout_ms         integer    NOT NULL DEFAULT 30000 CHECK (timeout_ms > 0),
    max_input_bytes    integer    NOT NULL DEFAULT 1048576 CHECK (max_input_bytes > 0),
    max_output_bytes   integer    NOT NULL DEFAULT 10485760 CHECK (max_output_bytes > 0),
    enabled            boolean    NOT NULL DEFAULT true,
    version_introduced text       NOT NULL DEFAULT '0.44.0',
    owner_schema       name       NOT NULL DEFAULT current_schema(),
    created_at         timestamptz NOT NULL DEFAULT now(),
    retired_at         timestamptz,
    UNIQUE (owner_schema, method, path)
);
```

### `maludb_core.malu$rest_invocation`  
<sub>line 20046</sub>

```sql
CREATE TABLE malu$rest_invocation (
    call_id        uuid       PRIMARY KEY DEFAULT public.gen_random_uuid(),
    endpoint_id    bigint     REFERENCES malu$rest_endpoint(endpoint_id) ON DELETE SET NULL,
    account_id     bigint     REFERENCES malu$account(account_id)        ON DELETE SET NULL,
    token_id       bigint     REFERENCES malu$auth_token(token_id)       ON DELETE SET NULL,
    method         text       NOT NULL,
    path           text       NOT NULL,
    request_user   text,
    source_ip      inet,
    request_hash   bytea,
    response_hash  bytea,
    status_code    smallint,
    latency_ms     integer,
    started_at     timestamptz NOT NULL DEFAULT now(),
    finished_at    timestamptz,
    success        boolean    NOT NULL,
    error_code     text,
    error_message  text,
    owner_schema   name       NOT NULL DEFAULT current_schema()
);
```

### `maludb_core.malu$queue`  
<sub>line 20406</sub>

```sql
CREATE TABLE malu$queue (
    queue_id              bigserial PRIMARY KEY,
    name                  text       NOT NULL,
    default_visibility_ms integer    NOT NULL DEFAULT 30000 CHECK (default_visibility_ms > 0),
    max_retries           smallint   NOT NULL DEFAULT 3     CHECK (max_retries >= 0),
    dlq_queue_id          bigint     REFERENCES malu$queue(queue_id) ON DELETE SET NULL,
    description           text,
    owner_schema          name       NOT NULL DEFAULT current_schema(),
    created_at            timestamptz NOT NULL DEFAULT now(),
    retired_at            timestamptz,
    UNIQUE (owner_schema, name),
    CHECK (dlq_queue_id IS NULL OR dlq_queue_id <> queue_id)
);
```

### `maludb_core.malu$queue_job`  
<sub>line 20424</sub>

```sql
CREATE TABLE malu$queue_job (
    job_id           bigserial PRIMARY KEY,
    queue_id         bigint    NOT NULL REFERENCES malu$queue(queue_id) ON DELETE CASCADE,
    payload          jsonb     NOT NULL,
    idempotency_key  text,
    priority         smallint  NOT NULL DEFAULT 0,
    account_id       bigint,
    owner_schema     name      NOT NULL DEFAULT current_schema(),
    status           text      NOT NULL DEFAULT 'pending' CHECK (status IN
                        ('pending','leased','completed','failed','dead')),
    enqueued_at      timestamptz NOT NULL DEFAULT now(),
    visible_at       timestamptz NOT NULL DEFAULT now(),
    attempts         smallint  NOT NULL DEFAULT 0,
    last_error       text,
    last_state_change_at timestamptz NOT NULL DEFAULT now()
);
```

### `maludb_core.malu$queue_lease`  
<sub>line 20454</sub>

```sql
CREATE TABLE malu$queue_lease (
    lease_id    bigserial PRIMARY KEY,
    job_id      bigint    NOT NULL UNIQUE REFERENCES malu$queue_job(job_id) ON DELETE CASCADE,
    worker_id   text      NOT NULL,
    leased_at   timestamptz NOT NULL DEFAULT now(),
    expires_at  timestamptz NOT NULL
);
```

### `maludb_core.malu$schedule`  
<sub>line 20892</sub>

```sql
CREATE TABLE malu$schedule (
    schedule_id    bigserial PRIMARY KEY,
    name           text       NOT NULL,
    cron_expr      text       NOT NULL,
    action_kind    text       NOT NULL CHECK (action_kind IN ('enqueue','sql')),
    action_payload jsonb      NOT NULL,
    -- action_kind='enqueue' expects {"queue":"<name>","payload":<jsonb>}
    -- action_kind='sql'     expects {"sql":"<statement>"} (admin-only)
    description    text,
    enabled        boolean    NOT NULL DEFAULT true,
    next_run_at    timestamptz,
    last_run_at    timestamptz,
    last_error     text,
    owner_schema   name       NOT NULL DEFAULT current_schema(),
    created_at     timestamptz NOT NULL DEFAULT now(),
    retired_at     timestamptz,
    UNIQUE (owner_schema, name)
);
```

### `maludb_core.malu$schedule_run`  
<sub>line 20919</sub>

```sql
CREATE TABLE malu$schedule_run (
    run_id        bigserial PRIMARY KEY,
    schedule_id   bigint    NOT NULL REFERENCES malu$schedule(schedule_id) ON DELETE CASCADE,
    started_at    timestamptz NOT NULL DEFAULT now(),
    finished_at   timestamptz,
    status        text      NOT NULL CHECK (status IN ('running','succeeded','failed')),
    detail_jsonb  jsonb,
    error_text    text
);
```

### `maludb_core.malu$storage_adapter`  
<sub>line 21429</sub>

```sql
CREATE TABLE malu$storage_adapter (
    adapter_id    bigserial PRIMARY KEY,
    name          text       NOT NULL,
    kind          text       NOT NULL CHECK (kind IN ('local_fs','s3')),
    config        jsonb      NOT NULL DEFAULT '{}'::jsonb,
    -- local_fs config: {"base_path": "/var/lib/maludb/source-archive"}
    -- s3        config: {"bucket": "...", "region": "...", "key_prefix": "...",
    --                    "endpoint": "..."}  (credentials live behind secret_ref)
    secret_ref    text,                -- malu$secret.name (resolved via __secret_resolve)
    description   text,
    owner_schema  name       NOT NULL DEFAULT current_schema(),
    created_at    timestamptz NOT NULL DEFAULT now(),
    retired_at    timestamptz,
    UNIQUE (owner_schema, name)
);
```

### `maludb_core.malu$source_object`  
<sub>line 21453</sub>

```sql
CREATE TABLE malu$source_object (
    object_id          bigserial PRIMARY KEY,
    content_hash       bytea      NOT NULL,
    media_type         text,
    byte_length        bigint     NOT NULL CHECK (byte_length >= 0),
    source_time        timestamptz,
    capture_time       timestamptz NOT NULL DEFAULT now(),
    retention_class    text       NOT NULL DEFAULT 'standard'
        CHECK (retention_class IN ('standard','sensitive','restricted','prohibited')),
    legal_hold         boolean    NOT NULL DEFAULT false,
    legal_hold_reason  text,
    sensitivity        text       NOT NULL DEFAULT 'internal'
        CHECK (sensitivity IN ('public','internal','restricted','prohibited')),
    partition          text,
    adapter_id         bigint     NOT NULL REFERENCES malu$storage_adapter(adapter_id) ON DELETE RESTRICT,
    adapter_uri        text       NOT NULL,
    signed_url_policy  jsonb,
    owner_schema       name       NOT NULL DEFAULT current_schema(),
    created_at         timestamptz NOT NULL DEFAULT now(),
    retired_at         timestamptz,
    UNIQUE (owner_schema, content_hash),
    CHECK (octet_length(content_hash) = 32)
);
```

### `maludb_core.malu$source_object_reference`  
<sub>line 21491</sub>

```sql
CREATE TABLE malu$source_object_reference (
    reference_id  bigserial PRIMARY KEY,
    object_id     bigint    NOT NULL REFERENCES malu$source_object(object_id) ON DELETE CASCADE,
    kind          text      NOT NULL CHECK (kind IN
                    ('byte_range','line_range','page','timestamp','cursor')),
    value_jsonb   jsonb     NOT NULL,
    note          text,
    created_at    timestamptz NOT NULL DEFAULT now()
);
```

### `maludb_core.malu$event`  
<sub>line 21939</sub>

```sql
CREATE TABLE malu$event (
    event_id          bigserial PRIMARY KEY,
    event_kind        text       NOT NULL,
    account_id        bigint     REFERENCES malu$account(account_id) ON DELETE SET NULL,
    partition         text,
    active_pool_id    bigint,
    object_type       text,
    object_id         bigint,
    scope             jsonb,
    transaction_time  timestamptz NOT NULL DEFAULT now(),
    payload           jsonb      NOT NULL DEFAULT '{}'::jsonb,
    owner_schema      name       NOT NULL DEFAULT current_schema()
);
```

### `maludb_core.malu$event_subscription`  
<sub>line 21960</sub>

```sql
CREATE TABLE malu$event_subscription (
    subscription_id bigserial PRIMARY KEY,
    name            text,
    account_id      bigint     REFERENCES malu$account(account_id) ON DELETE CASCADE,
    kinds           text[]     NOT NULL DEFAULT ARRAY[]::text[],
    partitions      text[]     NOT NULL DEFAULT ARRAY[]::text[],
    active_pool_id  bigint,
    cursor          bigint     NOT NULL DEFAULT 0,
    last_seen_at    timestamptz,
    owner_schema    name       NOT NULL DEFAULT current_schema(),
    created_at      timestamptz NOT NULL DEFAULT now(),
    retired_at      timestamptz
);
```

### `maludb_core.malu$event_delivery`  
<sub>line 21979</sub>

```sql
CREATE TABLE malu$event_delivery (
    delivery_id     bigserial PRIMARY KEY,
    subscription_id bigint     NOT NULL REFERENCES malu$event_subscription(subscription_id) ON DELETE CASCADE,
    event_id        bigint     NOT NULL REFERENCES malu$event(event_id) ON DELETE CASCADE,
    delivered_at    timestamptz NOT NULL DEFAULT now(),
    status          text       NOT NULL DEFAULT 'delivered' CHECK (status IN ('delivered','acked','failed')),
    UNIQUE (subscription_id, event_id)
);
```

### `maludb_core.malu$pool_presence`  
<sub>line 22441</sub>

```sql
CREATE TABLE malu$pool_presence (
    presence_id      bigserial PRIMARY KEY,
    pool_id          bigint    NOT NULL REFERENCES malu$active_memory_pool(pool_id) ON DELETE CASCADE,
    participant_kind text      NOT NULL CHECK (participant_kind IN ('human','agent','tool')),
    participant_ref  text      NOT NULL,
    role             text,
    declared_task    text,
    cursor_jsonb     jsonb,
    last_seen_at     timestamptz NOT NULL DEFAULT now(),
    left_at          timestamptz,
    owner_schema     name      NOT NULL DEFAULT current_schema(),
    UNIQUE (pool_id, participant_kind, participant_ref)
);
```

### `maludb_core.malu$pool_presence_event`  
<sub>line 22460</sub>

```sql
CREATE TABLE malu$pool_presence_event (
    event_id     bigserial PRIMARY KEY,
    presence_id  bigint    NOT NULL REFERENCES malu$pool_presence(presence_id) ON DELETE CASCADE,
    kind         text      NOT NULL CHECK (kind IN ('join','update','leave')),
    event_time   timestamptz NOT NULL DEFAULT now(),
    detail_jsonb jsonb
);
```

### `maludb_core.malu$vector_index_status`  
<sub>line 22701</sub>

```sql
CREATE TABLE malu$vector_index_status (
    status_id            bigserial PRIMARY KEY,
    compartment_id       bigint    NOT NULL UNIQUE REFERENCES malu$vector_compartment(compartment_id) ON DELETE CASCADE,
    kind                 text      NOT NULL CHECK (kind IN
                            ('exact','nsw','hnsw_local','hnsw_pgvector')),
    build_started_at     timestamptz,
    build_finished_at    timestamptz,
    last_rebuild_at      timestamptz,
    delta_count          bigint    NOT NULL DEFAULT 0,
    tombstone_count      bigint    NOT NULL DEFAULT 0,
    recall_sample        jsonb,
    owner_schema         name      NOT NULL DEFAULT current_schema(),
    created_at           timestamptz NOT NULL DEFAULT now()
);
```

### `maludb_core.malu$embedding_job`  
<sub>line 22916</sub>

```sql
CREATE TABLE malu$embedding_job (
    job_id                   bigserial PRIMARY KEY,
    target_kind              text      NOT NULL CHECK (target_kind IN
                                ('source_excerpt','memory_chunk','workflow_trace',
                                 'summary','query_envelope')),
    target_id                bigint    NOT NULL,
    model_alias              text      NOT NULL,
    embedding_space          text      NOT NULL,
    prompt_template_version  text,
    input_hash               bytea,
    queue_job_id             bigint,
    status                   text      NOT NULL DEFAULT 'pending' CHECK (status IN
                                ('pending','running','completed','failed')),
    enqueued_at              timestamptz NOT NULL DEFAULT now(),
    started_at               timestamptz,
    finished_at              timestamptz,
    last_error               text,
    owner_schema             name      NOT NULL DEFAULT current_schema()
);
```

### `maludb_core.malu$embedding_output`  
<sub>line 22943</sub>

```sql
CREATE TABLE malu$embedding_output (
    output_id            bigserial PRIMARY KEY,
    job_id               bigint    NOT NULL REFERENCES malu$embedding_job(job_id) ON DELETE CASCADE,
    target_kind          text      NOT NULL,
    target_id            bigint    NOT NULL,
    model_alias          text      NOT NULL,
    embedding_space      text      NOT NULL,
    vector_dim           integer   NOT NULL CHECK (vector_dim > 0),
    vector               bytea     NOT NULL,
    svpor_frame_text     text      NOT NULL,
    input_hash           bytea     NOT NULL,
    output_hash          bytea     NOT NULL,
    derivation_id        bigint    REFERENCES malu$derivation_ledger(derivation_id) ON DELETE SET NULL,
    created_at           timestamptz NOT NULL DEFAULT now(),
    owner_schema         name      NOT NULL DEFAULT current_schema(),
    CHECK (octet_length(vector) = vector_dim * 4)
);
```

### `maludb_core.malu$retrieval_decision_audit`  
<sub>line 23232</sub>

```sql
CREATE TABLE malu$retrieval_decision_audit (
    decision_id    bigserial PRIMARY KEY,
    envelope_id    bigint    NOT NULL REFERENCES malu$retrieval_envelope(envelope_id) ON DELETE CASCADE,
    stage          text      NOT NULL CHECK (stage IN ('planning','expansion','assembly')),
    allowed        boolean   NOT NULL,
    reason         text,
    object_type    text,
    object_id      bigint,
    decided_at     timestamptz NOT NULL DEFAULT now()
);
```

### `maludb_core.malu$metric_definition`  
<sub>line 23438</sub>

```sql
CREATE TABLE malu$metric_definition (
    metric_id    bigserial PRIMARY KEY,
    name         text       NOT NULL UNIQUE,
    kind         text       NOT NULL CHECK (kind IN ('counter','gauge','histogram')),
    help_text    text       NOT NULL,
    labels       text[]     NOT NULL DEFAULT ARRAY[]::text[],
    created_at   timestamptz NOT NULL DEFAULT now(),
    retired_at   timestamptz
);
```

### `maludb_core.malu$log_drain`  
<sub>line 23631</sub>

```sql
CREATE TABLE malu$log_drain (
    drain_id          bigserial PRIMARY KEY,
    name              text       NOT NULL,
    kind              text       NOT NULL CHECK (kind IN ('http','file','s3','otlp_http')),
    destination       jsonb      NOT NULL,
    destination_secret_ref text,
    source_streams    text[]     NOT NULL DEFAULT ARRAY[]::text[],
    -- source_streams entries: 'pg_log','audit_event','mc2db_invocation',
    -- 'rest_invocation','model_gateway','broker','secret_use'.
    redaction_rules   jsonb      NOT NULL DEFAULT '[]'::jsonb,
    enabled           boolean    NOT NULL DEFAULT true,
    batch_size        integer    NOT NULL DEFAULT 100 CHECK (batch_size > 0),
    flush_interval_ms integer    NOT NULL DEFAULT 5000 CHECK (flush_interval_ms > 0),
    owner_schema      name       NOT NULL DEFAULT current_schema(),
    created_at        timestamptz NOT NULL DEFAULT now(),
    retired_at        timestamptz,
    UNIQUE (owner_schema, name)
);
```

### `maludb_core.malu$log_drain_run`  
<sub>line 23655</sub>

```sql
CREATE TABLE malu$log_drain_run (
    run_id      bigserial PRIMARY KEY,
    drain_id    bigint     NOT NULL REFERENCES malu$log_drain(drain_id) ON DELETE CASCADE,
    started_at  timestamptz NOT NULL DEFAULT now(),
    finished_at timestamptz,
    batches     integer    NOT NULL DEFAULT 0,
    bytes       bigint     NOT NULL DEFAULT 0,
    records     integer    NOT NULL DEFAULT 0,
    errors      integer    NOT NULL DEFAULT 0,
    last_error  text
);
```

### `maludb_core.malu$backup_manifest`  
<sub>line 23860</sub>

```sql
CREATE TABLE malu$backup_manifest (
    manifest_id              bigserial PRIMARY KEY,
    label                    text,
    postgres_state_kind      text       NOT NULL CHECK (postgres_state_kind IN ('dump','basebackup')),
    postgres_state_uri       text       NOT NULL,
    wal_archive_uri          text,
    etc_maludb_uri           text,
    source_archive_manifest_uri text,
    model_configs_uri        text,
    tls_uri                  text,
    tool_binaries_uri        text,
    broker_configs_uri       text,
    extension_version        text       NOT NULL,
    hash_summary             jsonb      NOT NULL DEFAULT '{}'::jsonb,
    owner_schema             name       NOT NULL DEFAULT current_schema(),
    created_at               timestamptz NOT NULL DEFAULT now()
);
```

### `maludb_core.malu$backup_verification`  
<sub>line 23883</sub>

```sql
CREATE TABLE malu$backup_verification (
    verification_id bigserial PRIMARY KEY,
    manifest_id     bigint     NOT NULL REFERENCES malu$backup_manifest(manifest_id) ON DELETE CASCADE,
    started_at      timestamptz NOT NULL DEFAULT now(),
    finished_at     timestamptz,
    status          text       NOT NULL CHECK (status IN ('running','passed','failed')) DEFAULT 'running',
    errors_jsonb    jsonb,
    notes           text
);
```

### `maludb_core.malu$preview_env`  
<sub>line 24044</sub>

```sql
CREATE TABLE malu$preview_env (
    env_id            bigserial PRIMARY KEY,
    name              text       NOT NULL,
    base_migration    text       NOT NULL,
    current_migration text,
    seed_policy       jsonb      NOT NULL DEFAULT '{}'::jsonb,
    anonymizer_ref    text,
    description       text,
    owner_schema      name       NOT NULL DEFAULT current_schema(),
    created_at        timestamptz NOT NULL DEFAULT now(),
    retired_at        timestamptz,
    UNIQUE (owner_schema, name)
);
```

### `maludb_core.malu$preview_env_seed`  
<sub>line 24060</sub>

```sql
CREATE TABLE malu$preview_env_seed (
    seed_id          bigserial PRIMARY KEY,
    env_id           bigint     NOT NULL REFERENCES malu$preview_env(env_id) ON DELETE CASCADE,
    source_kind      text       NOT NULL CHECK (source_kind IN
                        ('sql_file','json_blob','dump','table_subset','custom')),
    source_ref       text       NOT NULL,
    redaction_rules  jsonb      NOT NULL DEFAULT '[]'::jsonb,
    applied_at       timestamptz,
    created_at       timestamptz NOT NULL DEFAULT now()
);
```

### `maludb_core.malu$page_index_tree`  
<sub>line 25803</sub>

```sql
CREATE TABLE malu$page_index_tree (
    tree_id              bigserial PRIMARY KEY,
    owner_schema         name NOT NULL DEFAULT current_schema(),
    source_package_id    bigint NOT NULL
        REFERENCES malu$source_package(source_package_id) ON DELETE CASCADE,
    parser_kind          text NOT NULL
        CHECK (parser_kind IN ('pdf','markdown','plain_text')),
    -- model_alias_id / prompt_template_id are populated by the builder
    -- (V4-PAGEINDEX-02). Nullable at register time so a tree can sit
    -- in 'pending' before the worker picks a model.
    model_alias_id       bigint
        REFERENCES malu$model_alias(alias_id) ON DELETE SET NULL,
    prompt_template_id   bigint
        REFERENCES malu$prompt_template(template_id) ON DELETE SET NULL,
    build_status         text NOT NULL DEFAULT 'pending'
        CHECK (build_status IN (
            'pending','building','ready','stale','superseded','failed')),
    build_started_at     timestamptz,
    build_finished_at    timestamptz,
    failure_reason       text,
    superseded_by        bigint
        REFERENCES malu$page_index_tree(tree_id) ON DELETE SET NULL,
    valid_time_start     timestamptz NOT NULL DEFAULT now(),
    valid_time_end       timestamptz,
    created_at           timestamptz NOT NULL DEFAULT now()
);
```

### `maludb_core.malu$structure_pass_audit`  
<sub>line 26167</sub>

```sql
CREATE TABLE malu$structure_pass_audit (
    audit_id                    bigserial PRIMARY KEY,
    owner_schema                name NOT NULL DEFAULT current_schema(),
    tree_id                     bigint NOT NULL
        REFERENCES malu$page_index_tree(tree_id) ON DELETE CASCADE,
    parser_kind                 text NOT NULL
        CHECK (parser_kind IN ('pdf','markdown','plain_text')),
    parser_version              text NOT NULL,
    started_at                  timestamptz NOT NULL DEFAULT now(),
    finished_at                 timestamptz,
    outline_node_count          integer NOT NULL DEFAULT 0
        CHECK (outline_node_count >= 0),
    leaf_count                  integer NOT NULL DEFAULT 0
        CHECK (leaf_count >= 0),
    deterministic_inputs_hash   text NOT NULL,
    outcome                     text NOT NULL DEFAULT 'ok'
        CHECK (outcome IN ('ok','partial','failed')),
    error_text                  text,
    created_at                  timestamptz NOT NULL DEFAULT now()
);
```

### `maludb_core.malu$chat_index_tree`  
<sub>line 27258</sub>

```sql
CREATE TABLE malu$chat_index_tree (
    tree_id              bigserial PRIMARY KEY,
    owner_schema         name NOT NULL DEFAULT current_schema(),
    source_package_id    bigint NOT NULL
        REFERENCES malu$source_package(source_package_id) ON DELETE CASCADE,
    model_alias_id       bigint
        REFERENCES malu$model_alias(alias_id) ON DELETE SET NULL,
    prompt_template_id   bigint
        REFERENCES malu$prompt_template(template_id) ON DELETE SET NULL,
    build_status         text NOT NULL DEFAULT 'pending'
        CHECK (build_status IN (
            'pending','building','ready','stale','superseded','failed')),
    -- V4-CHATINDEX-02: load-bearing pointer into malu$memory_detail_object.
    -- Set to the most-recently-appended topic (internal) or message
    -- (leaf) so subsequent appends can decide extend-current vs.
    -- open-new-topic-from-ancestor.
    current_node_mdo_id  bigint,
    max_children         integer NOT NULL DEFAULT 10
        CHECK (max_children > 0),
    sub_node_count       integer NOT NULL DEFAULT 0
        CHECK (sub_node_count >= 0),
    build_started_at     timestamptz,
    build_finished_at    timestamptz,
    failure_reason       text,
    superseded_by        bigint
        REFERENCES malu$chat_index_tree(tree_id) ON DELETE SET NULL,
    valid_time_start     timestamptz NOT NULL DEFAULT now(),
    valid_time_end       timestamptz,
    created_at           timestamptz NOT NULL DEFAULT now()
);
```

### `maludb_core.malu$chat_index_append_audit`  
<sub>line 27758</sub>

```sql
CREATE TABLE malu$chat_index_append_audit (
    append_id              bigserial PRIMARY KEY,
    owner_schema           name NOT NULL DEFAULT current_schema(),
    tree_id                bigint NOT NULL
        REFERENCES malu$chat_index_tree(tree_id) ON DELETE CASCADE,
    appended_at            timestamptz NOT NULL DEFAULT now(),
    message_index_first    integer NOT NULL,
    message_index_last     integer NOT NULL,
    appended_message_count integer NOT NULL DEFAULT 0
        CHECK (appended_message_count >= 0),
    idempotent_hits        integer NOT NULL DEFAULT 0
        CHECK (idempotent_hits >= 0),
    opened_new_topic       boolean NOT NULL DEFAULT false,
    ancestor_branch_used   boolean NOT NULL DEFAULT false,
    branched_from_mdo_id   bigint,
    decision_reason        text
);
```

### `maludb_core.malu$enabled_schema`  
<sub>line 28914</sub>

```sql
CREATE TABLE malu$enabled_schema (
    schema_name        name PRIMARY KEY,
    enabled_version    text NOT NULL,
    enabled_at         timestamptz NOT NULL DEFAULT now(),
    enabled_by         name NOT NULL DEFAULT current_user,
    last_refreshed_at  timestamptz NOT NULL DEFAULT now()
);
```

### `maludb_core.malu$enabled_schema_object`  
<sub>line 28922</sub>

```sql
CREATE TABLE malu$enabled_schema_object (
    schema_name   name NOT NULL REFERENCES malu$enabled_schema(schema_name) ON DELETE CASCADE,
    object_name   name NOT NULL,
    object_kind   text NOT NULL CHECK (object_kind IN ('view','function','trigger')),
    object_purpose text NOT NULL,
    created_at    timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (schema_name, object_name, object_kind)
);
```

### `maludb_core.malu$document`  
<sub>line 28979</sub>

```sql
CREATE TABLE malu$document (
    document_id        bigserial PRIMARY KEY,
    owner_schema       name NOT NULL DEFAULT current_schema(),
    source_package_id  bigint,
    title              text NOT NULL,
    source_type        text NOT NULL REFERENCES malu$source_type(source_type),
    media_type         text,
    primary_project_id bigint REFERENCES malu$svpor_subject(subject_id) ON DELETE SET NULL,
    lifecycle_state    text NOT NULL DEFAULT 'active'
        CHECK (lifecycle_state IN ('active','processing','processed','archived','tombstoned')),
    metadata_jsonb     jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at         timestamptz NOT NULL DEFAULT now(),
    updated_at         timestamptz NOT NULL DEFAULT now(),
    UNIQUE (owner_schema, document_id),
    FOREIGN KEY (owner_schema, source_package_id, source_type)
        REFERENCES malu$source_package(owner_schema, source_package_id, source_type)
);
```

### `maludb_core.malu$document_tag`  
<sub>line 29004</sub>

```sql
CREATE TABLE malu$document_tag (
    tag_id          bigserial PRIMARY KEY,
    owner_schema    name NOT NULL DEFAULT current_schema(),
    document_id     bigint NOT NULL,
    tag_kind        text NOT NULL
        CHECK (tag_kind IN ('project','subject','verb','event','stakeholder','skill','workflow','freeform')),
    tag_value       text NOT NULL,
    tag_object_type text,
    tag_object_id   bigint,
    provenance      text NOT NULL DEFAULT 'provided'
        CHECK (provenance IN ('provided','suggested','accepted','rejected')),
    confidence      numeric(5,4) CHECK (confidence IS NULL OR confidence BETWEEN 0 AND 1),
    metadata_jsonb  jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at      timestamptz NOT NULL DEFAULT now(),
    UNIQUE (document_id, tag_kind, tag_value, provenance),
    FOREIGN KEY (owner_schema, document_id)
        REFERENCES malu$document(owner_schema, document_id) ON DELETE CASCADE
);
```

### `maludb_core.malu$raw_ingest`  
<sub>line 29030</sub>

```sql
CREATE TABLE malu$raw_ingest (
    ingest_id     bigserial PRIMARY KEY,
    owner_schema  name NOT NULL DEFAULT current_schema(),
    source_type   text NOT NULL,
    source_name   text,
    payload_jsonb jsonb,
    content_text  text,
    content_bytes bytea,
    content_hash  text,
    state         text NOT NULL DEFAULT 'received'
        CHECK (state IN ('received','queued','processing','processed','partially_applied','applied','failed','ignored')),
    received_at   timestamptz NOT NULL DEFAULT now(),
    processed_at  timestamptz,
    last_error    text,
    context_jsonb jsonb NOT NULL DEFAULT '{}'::jsonb,
    CHECK (payload_jsonb IS NOT NULL OR content_text IS NOT NULL OR content_bytes IS NOT NULL),
    UNIQUE (owner_schema, ingest_id)
);
```

### `maludb_core.malu$ingest_extraction`  
<sub>line 29056</sub>

```sql
CREATE TABLE malu$ingest_extraction (
    extraction_id       bigserial PRIMARY KEY,
    owner_schema        name NOT NULL DEFAULT current_schema(),
    ingest_id           bigint NOT NULL,
    derived_object_type text NOT NULL,
    derived_object_id   bigint,
    extraction_state    text NOT NULL DEFAULT 'suggested'
        CHECK (extraction_state IN ('suggested','accepted','rejected','applied')),
    confidence          numeric(5,4) CHECK (confidence IS NULL OR confidence BETWEEN 0 AND 1),
    payload_jsonb       jsonb,
    created_at          timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (owner_schema, ingest_id)
        REFERENCES malu$raw_ingest(owner_schema, ingest_id) ON DELETE CASCADE
);
```

### `maludb_core.malu$active_memory_pool_tag`  
<sub>line 29138</sub>

```sql
CREATE TABLE malu$active_memory_pool_tag (
    tag_id       bigserial PRIMARY KEY,
    owner_schema name NOT NULL DEFAULT current_schema(),
    pool_id      bigint NOT NULL,
    tag_kind     text NOT NULL,
    tag_value    text NOT NULL,
    created_at   timestamptz NOT NULL DEFAULT now(),
    UNIQUE (pool_id, tag_kind, tag_value),
    FOREIGN KEY (owner_schema, pool_id)
        REFERENCES malu$active_memory_pool(owner_schema, pool_id) ON DELETE CASCADE
);
```

### `maludb_core.malu$active_memory_pool_access`  
<sub>line 29157</sub>

```sql
CREATE TABLE malu$active_memory_pool_access (
    access_id    bigserial PRIMARY KEY,
    owner_schema name NOT NULL DEFAULT current_schema(),
    pool_id      bigint NOT NULL,
    grantee_role name NOT NULL,
    access_level text NOT NULL CHECK (access_level IN ('read','write','manage','execute')),
    granted_by   name NOT NULL DEFAULT current_user,
    granted_at   timestamptz NOT NULL DEFAULT now(),
    revoked_at   timestamptz,
    FOREIGN KEY (owner_schema, pool_id)
        REFERENCES malu$active_memory_pool(owner_schema, pool_id) ON DELETE CASCADE
);
```

### `maludb_core.malu$skill_keyword`  
<sub>line 31853</sub>

```sql
CREATE TABLE IF NOT EXISTS malu$skill_keyword (
    keyword_id   bigserial PRIMARY KEY,
    owner_schema name NOT NULL DEFAULT current_schema(),
    skill_id     bigint NOT NULL,
    keyword      text NOT NULL,
    weight       numeric NOT NULL DEFAULT 1.0,
    provenance   text NOT NULL DEFAULT 'manual'
        CHECK (provenance IN ('manual')),
    created_at   timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (owner_schema, skill_id)
        REFERENCES malu$skill_package(owner_schema, skill_id) ON DELETE CASCADE
);
```

### `maludb_core.malu$skill_subject`  
<sub>line 31870</sub>

```sql
CREATE TABLE IF NOT EXISTS malu$skill_subject (
    skill_subject_id bigserial PRIMARY KEY,
    owner_schema     name NOT NULL DEFAULT current_schema(),
    skill_id         bigint NOT NULL,
    subject_id       bigint,
    subject_name     text NOT NULL,
    weight           numeric NOT NULL DEFAULT 1.0,
    provenance       text NOT NULL DEFAULT 'manual'
        CHECK (provenance IN ('manual')),
    created_at       timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (owner_schema, skill_id)
        REFERENCES malu$skill_package(owner_schema, skill_id) ON DELETE CASCADE,
    FOREIGN KEY (owner_schema, subject_id)
        REFERENCES malu$svpor_subject(owner_schema, subject_id) ON DELETE SET NULL (subject_id)
);
```

### `maludb_core.malu$skill_verb`  
<sub>line 31890</sub>

```sql
CREATE TABLE IF NOT EXISTS malu$skill_verb (
    skill_verb_id bigserial PRIMARY KEY,
    owner_schema  name NOT NULL DEFAULT current_schema(),
    skill_id      bigint NOT NULL,
    verb_id       bigint,
    verb_name     text NOT NULL,
    weight        numeric NOT NULL DEFAULT 1.0,
    provenance    text NOT NULL DEFAULT 'manual'
        CHECK (provenance IN ('manual')),
    created_at    timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (owner_schema, skill_id)
        REFERENCES malu$skill_package(owner_schema, skill_id) ON DELETE CASCADE,
    FOREIGN KEY (owner_schema, verb_id)
        REFERENCES malu$svpor_verb(owner_schema, verb_id) ON DELETE SET NULL (verb_id)
);
```

### `maludb_core.malu$skill_embedding`  
<sub>line 31910</sub>

```sql
CREATE TABLE IF NOT EXISTS malu$skill_embedding (
    embedding_id     bigserial PRIMARY KEY,
    owner_schema     name NOT NULL DEFAULT current_schema(),
    skill_id         bigint NOT NULL,
    embedding_model  text NOT NULL,
    embedding_dim    integer NOT NULL,
    embedding        malu_vector NOT NULL,
    source_text_hash text NOT NULL,
    source_text_kind text NOT NULL DEFAULT 'description',
    created_at       timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (owner_schema, skill_id)
        REFERENCES malu$skill_package(owner_schema, skill_id) ON DELETE CASCADE
);
```

### `maludb_core.malu$skill_access`  
<sub>line 31941</sub>

```sql
CREATE TABLE IF NOT EXISTS malu$skill_access (
    access_id     bigserial PRIMARY KEY,
    owner_schema  name NOT NULL DEFAULT current_schema(),
    skill_id      bigint NOT NULL,
    grantee_role  name NOT NULL,
    access_level  text NOT NULL DEFAULT 'read'
        CHECK (access_level IN ('read','execute','fork','admin')),
    created_at    timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (owner_schema, skill_id)
        REFERENCES malu$skill_package(owner_schema, skill_id) ON DELETE CASCADE,
    UNIQUE (owner_schema, skill_id, grantee_role, access_level)
);
```

### `maludb_core.malu$document_svpor_hint`  
<sub>line 34000</sub>

```sql
CREATE TABLE maludb_core.malu$document_svpor_hint (
    hint_id            bigserial PRIMARY KEY,
    owner_schema       name NOT NULL DEFAULT current_schema(),
    document_id        bigint NOT NULL,
    project_subject_id bigint REFERENCES maludb_core.malu$svpor_subject(subject_id) ON DELETE SET NULL,
    project_name       text,
    subject_id         bigint REFERENCES maludb_core.malu$svpor_subject(subject_id) ON DELETE SET NULL,
    subject_name       text,
    verb_id            bigint REFERENCES maludb_core.malu$svpor_verb(verb_id) ON DELETE SET NULL,
    verb_name          text,
    provenance         text NOT NULL DEFAULT 'provided'
        CHECK (provenance IN ('provided','suggested','accepted','rejected')),
    confidence         numeric(5,4) CHECK (confidence IS NULL OR confidence BETWEEN 0 AND 1),
    metadata_jsonb     jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at         timestamptz NOT NULL DEFAULT now(),
    CHECK (
        project_subject_id IS NOT NULL OR NULLIF(project_name, '') IS NOT NULL OR
        subject_id IS NOT NULL OR NULLIF(subject_name, '') IS NOT NULL OR
        verb_id IS NOT NULL OR NULLIF(verb_name, '') IS NOT NULL
    ),
    FOREIGN KEY (owner_schema, document_id)
        REFERENCES maludb_core.malu$document(owner_schema, document_id) ON DELETE CASCADE
);
```

### `maludb_core.malu$chat_session`  
<sub>line 34171</sub>

```sql
CREATE TABLE maludb_core.malu$chat_session (
    chat_session_id           bigserial PRIMARY KEY,
    owner_schema              name NOT NULL DEFAULT current_schema(),
    account_id                bigint REFERENCES maludb_core.malu$account(account_id) ON DELETE SET NULL,
    model_session_id          bigint REFERENCES maludb_core.malu$session(session_id) ON DELETE SET NULL,
    document_id               bigint REFERENCES maludb_core.malu$document(document_id) ON DELETE SET NULL,
    source_package_id         bigint REFERENCES maludb_core.malu$source_package(source_package_id) ON DELETE SET NULL,
    chat_title                text NOT NULL,
    lifecycle_state           text NOT NULL DEFAULT 'open'
        CHECK (lifecycle_state IN ('open','closed','errored','archived','tombstoned')),
    primary_project_subject_id bigint REFERENCES maludb_core.malu$svpor_subject(subject_id) ON DELETE SET NULL,
    projects                  text[] NOT NULL DEFAULT ARRAY[]::text[],
    subjects                  text[] NOT NULL DEFAULT ARRAY[]::text[],
    verbs                     text[] NOT NULL DEFAULT ARRAY[]::text[],
    svpor_frames              jsonb NOT NULL DEFAULT '[]'::jsonb,
    started_at                timestamptz NOT NULL DEFAULT now(),
    last_message_at           timestamptz,
    closed_at                 timestamptz,
    message_count             integer NOT NULL DEFAULT 0 CHECK (message_count >= 0),
    metadata_jsonb            jsonb NOT NULL DEFAULT '{}'::jsonb,
    UNIQUE (owner_schema, chat_session_id)
);
```

### `maludb_core.malu$chat_message`  
<sub>line 34208</sub>

```sql
CREATE TABLE maludb_core.malu$chat_message (
    chat_message_id  bigserial PRIMARY KEY,
    owner_schema     name NOT NULL DEFAULT current_schema(),
    chat_session_id  bigint NOT NULL,
    ordinal          integer NOT NULL CHECK (ordinal > 0),
    role             text NOT NULL
        CHECK (role IN ('system','developer','user','assistant','tool','event')),
    content_text     text,
    content_jsonb    jsonb,
    content_hash     text NOT NULL,
    token_estimate   integer CHECK (token_estimate IS NULL OR token_estimate >= 0),
    model_request_id bigint REFERENCES maludb_core.malu$model_request(request_id) ON DELETE SET NULL,
    model_response_id bigint REFERENCES maludb_core.malu$model_response(response_id) ON DELETE SET NULL,
    tool_call_id     text,
    source_locator   jsonb,
    sensitivity      text NOT NULL DEFAULT 'internal'
        CHECK (sensitivity IN ('public','internal','restricted','prohibited')),
    created_at       timestamptz NOT NULL DEFAULT now(),
    metadata_jsonb   jsonb NOT NULL DEFAULT '{}'::jsonb,
    CHECK (content_text IS NOT NULL OR content_jsonb IS NOT NULL),
    UNIQUE (owner_schema, chat_session_id, ordinal),
    FOREIGN KEY (owner_schema, chat_session_id)
        REFERENCES maludb_core.malu$chat_session(owner_schema, chat_session_id) ON DELETE CASCADE
);
```

### `maludb_core.malu$svpor_subject_type`  
<sub>line 34615</sub>

```sql
CREATE TABLE maludb_core.malu$svpor_subject_type (
    subject_type   text PRIMARY KEY,
    display_name   text NOT NULL,
    description    text,
    sort_order     integer NOT NULL,
    system_defined boolean NOT NULL DEFAULT true,
    created_at     timestamptz NOT NULL DEFAULT now()
);
```

### `maludb_core.malu$svpor_verb_type`  
<sub>line 34624</sub>

```sql
CREATE TABLE maludb_core.malu$svpor_verb_type (
    verb_type      text PRIMARY KEY,
    display_name   text NOT NULL,
    semantic_class text NOT NULL DEFAULT 'action'
        CHECK (semantic_class IN ('action','state','event','decision','communication','verification','failure','planning','documentation','other')),
    description    text,
    sort_order     integer NOT NULL,
    system_defined boolean NOT NULL DEFAULT true,
    created_at     timestamptz NOT NULL DEFAULT now()
);
```

### `maludb_core.malu$svpor_subject_relationship`  
<sub>line 35531</sub>

```sql
CREATE TABLE maludb_core.malu$svpor_subject_relationship (
    owner_schema       name NOT NULL DEFAULT current_schema(),
    subject_a_id       bigint NOT NULL,
    subject_b_id       bigint NOT NULL,
    subject_a_label    text NOT NULL,
    subject_b_label    text NOT NULL,
    label              text,
    metadata_jsonb     jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at         timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (owner_schema, subject_a_id, subject_b_id),
    CONSTRAINT malu$svpor_subject_relationship_order_check
        CHECK (subject_a_id < subject_b_id),
    CONSTRAINT malu$svpor_subject_relationship_a_fk
        FOREIGN KEY (owner_schema, subject_a_id)
        REFERENCES maludb_core.malu$svpor_subject(owner_schema, subject_id)
        ON DELETE CASCADE,
    CONSTRAINT malu$svpor_subject_relationship_b_fk
        FOREIGN KEY (owner_schema, subject_b_id)
        REFERENCES maludb_core.malu$svpor_subject(owner_schema, subject_id)
        ON DELETE CASCADE
);
```

## 3. Top-level views (in `maludb_core`)

These are static analytics/reporting views defined directly in the extension (distinct from the per-schema facades in §6).


### `maludb_core.model_provider_public`  
<sub>line 799</sub>

```sql
CREATE VIEW model_provider_public AS
    SELECT provider_id, provider_name, provider_kind, adapter_name,
           data_sensitivity, enabled, created_at
    FROM malu$model_provider;
```

### `maludb_core.model_run_audit`  
<sub>line 1278</sub>

```sql
CREATE VIEW model_run_audit AS
SELECT
    pr.render_id,
    pr.session_id,
    s.lifecycle_state         AS session_state,
    s.created_at              AS session_started_at,
    s.closed_at               AS session_closed_at,
    s.account_id,
    a.account_name,
    pr.template_id,
    pt.template_name,
    pt.template_version,
    pr.variables              AS render_variables,
    pr.prompt_hash,
    pr.context_hash,
    pr.context_block_count,
    pr.created_at             AS rendered_at,
    mr.request_id,
    mr.alias_id,
    ma.alias_name,
    mp.provider_kind,
    mp.provider_name,
    mr.status                 AS request_status,
    mr.cancel_requested,
    mr.submitted_at,
    mr.started_at,
    mr.finished_at            AS request_finished_at,
    mres.response_id,
    mres.status               AS response_status,
    mres.output_hash,
    mres.finish_reason,
    mres.adapter_name,
    mres.prompt_tokens,
    mres.completion_tokens,
    mres.latency_ms,
    mres.error_class,
    mres.user_safe_error,
    mres.finished_at          AS response_finished_at
FROM malu$prompt_render pr
LEFT JOIN malu$session         s    ON s.session_id    = pr.session_id
LEFT JOIN malu$account         a    ON a.account_id    = s.account_id
LEFT JOIN malu$prompt_template pt   ON pt.template_id  = pr.template_id
LEFT JOIN malu$model_request   mr   ON mr.prompt_render_id = pr.render_id
LEFT JOIN malu$model_alias     ma   ON ma.alias_id     = mr.alias_id
LEFT JOIN malu$model_provider  mp   ON mp.provider_id  = ma.provider_id
LEFT JOIN malu$model_response  mres ON mres.request_id = mr.request_id;
```

### `maludb_core.malu$vector_compartment_stats`  
<sub>line 2839</sub>

```sql
CREATE VIEW malu$vector_compartment_stats AS
SELECT
    c.compartment_id,
    c.namespace,
    s.subject_name,
    v.verb_name,
    c.embedding_dim,
    c.embedding_model,
    c.distance_metric,
    c.vector_count,
    c.search_mode,
    c.ann_index_status,
    c.created_at,
    c.updated_at
FROM malu$vector_compartment c
JOIN malu$vector_subject s ON s.subject_id = c.subject_id
JOIN malu$vector_verb    v ON v.verb_id    = c.verb_id;
```

### `maludb_core.malu_provider_public`  
<sub>line 3179</sub>

```sql
CREATE VIEW malu_provider_public AS
SELECT provider_id, provider_name, provider_kind, adapter_name,
       data_sensitivity, enabled, created_at
FROM malu$model_provider;
```

### `maludb_core.cost_by_account`  
<sub>line 6432</sub>

```sql
CREATE VIEW cost_by_account AS
SELECT
    a.account_id,
    a.account_name,
    ma.alias_name,
    date_trunc('day', resp.finished_at)::date AS day,
    count(*)                                  AS request_count,
    sum(COALESCE(resp.prompt_tokens, 0))      AS input_tokens,
    sum(COALESCE(resp.completion_tokens, 0))  AS output_tokens,
    sum(response_cost(resp))                  AS cost_micro_cents
FROM malu$model_response  resp
JOIN malu$model_request   mr ON mr.request_id = resp.request_id
LEFT JOIN malu$account    a  ON a.account_id  = mr.account_id
JOIN malu$model_alias     ma ON ma.alias_id   = mr.alias_id
WHERE resp.cache_hit = false
GROUP BY a.account_id, a.account_name, ma.alias_name, date_trunc('day', resp.finished_at);
```

### `maludb_core.malu$current_claim`  
<sub>line 11186</sub>

```sql
CREATE VIEW malu$current_claim AS
SELECT * FROM malu$claim
WHERE is_currently_valid(valid_time_start, valid_time_end)
  AND retracted_at IS NULL;
```

### `maludb_core.malu$current_fact`  
<sub>line 11191</sub>

```sql
CREATE VIEW malu$current_fact AS
SELECT * FROM malu$fact
WHERE is_currently_valid(valid_time_start, valid_time_end)
  AND lifecycle_state = 'active'
  AND superseded_at IS NULL;
```

### `maludb_core.malu$current_memory`  
<sub>line 11197</sub>

```sql
CREATE VIEW malu$current_memory AS
SELECT * FROM malu$memory
WHERE is_currently_valid(valid_time_start, valid_time_end)
  AND lifecycle_state = 'active';
```

### `maludb_core.malu$current_episode`  
<sub>line 11202</sub>

```sql
CREATE VIEW malu$current_episode AS
SELECT * FROM malu$episode_object
WHERE is_currently_valid(valid_time_start, valid_time_end)
  AND lifecycle_state = 'active';
```

### `maludb_core.malu$claim_svpor_resolved`  
<sub>line 12012</sub>

```sql
CREATE VIEW malu$claim_svpor_resolved AS
SELECT c.claim_id,
       c.owner_schema,
       c.subject       AS subject_text,
       s.canonical_name AS subject_canonical,
       c.verb          AS verb_text,
       v.canonical_name AS verb_canonical,
       c.predicate     AS predicate_text,
       p.canonical_name AS predicate_canonical,
       c.object_value,
       c.statement_text,
       c.svpor_subject_id, c.svpor_verb_id, c.svpor_predicate_id
FROM malu$claim c
LEFT JOIN malu$svpor_subject   s ON s.subject_id   = c.svpor_subject_id
LEFT JOIN malu$svpor_verb      v ON v.verb_id      = c.svpor_verb_id
LEFT JOIN malu$svpor_predicate p ON p.predicate_id = c.svpor_predicate_id;
```

### `maludb_core.malu$fact_svpor_resolved`  
<sub>line 12029</sub>

```sql
CREATE VIEW malu$fact_svpor_resolved AS
SELECT f.fact_id,
       f.owner_schema,
       f.subject       AS subject_text,
       s.canonical_name AS subject_canonical,
       f.verb          AS verb_text,
       v.canonical_name AS verb_canonical,
       f.predicate     AS predicate_text,
       p.canonical_name AS predicate_canonical,
       f.object_value,
       f.statement_text,
       f.lifecycle_state,
       f.svpor_subject_id, f.svpor_verb_id, f.svpor_predicate_id
FROM malu$fact f
LEFT JOIN malu$svpor_subject   s ON s.subject_id   = f.svpor_subject_id
LEFT JOIN malu$svpor_verb      v ON v.verb_id      = f.svpor_verb_id
LEFT JOIN malu$svpor_predicate p ON p.predicate_id = f.svpor_predicate_id;
```

### `maludb_core.malu$maut_summary`  
<sub>line 12358</sub>

```sql
CREATE VIEW malu$maut_summary AS
SELECT
    s.target_object_type,
    s.target_object_id,
    s.owner_schema,
    count(*)::integer                                  AS categories_scored,
    array_agg(s.category ORDER BY s.category)          AS scored_categories,
    maut_aggregate_confidence(s.target_object_type, s.target_object_id) AS aggregate_confidence,
    min(s.evaluated_at) AS earliest_eval,
    max(s.evaluated_at) AS latest_eval
FROM malu$maut_score s
GROUP BY s.target_object_type, s.target_object_id, s.owner_schema;
```

## 4. Functions

All 584 functions in `maludb_core`, alphabetical. Signatures shown through the `RETURNS` clause 
(bodies omitted for brevity).

```sql
maludb_core.__auth_pepper() RETURNS bytea
maludb_core.__auth_token_encode(p_bytes bytea) RETURNS text
maludb_core.__auth_token_hash(p_plaintext text) RETURNS bytea
maludb_core.__auth_token_hash(p_plaintext text) RETURNS bytea
maludb_core.__secret_master_key() RETURNS bytea
maludb_core.__secret_master_key_passphrase() RETURNS text
maludb_core.__secret_resolve(p_name text) RETURNS text
maludb_core.__secret_resolve(p_name text) RETURNS text
maludb_core._apply_cache_hit( p_new_request_id bigint, p_original_request_id bigint ) RETURNS bigint
maludb_core._assert_pool_capacity(p_pool_id bigint) RETURNS void
maludb_core._assert_pool_capacity(p_pool_id bigint) RETURNS void
maludb_core._assert_pool_writable(p_pool_id bigint) RETURNS void
maludb_core._assert_pool_writable(p_pool_id bigint) RETURNS void
maludb_core._chat_index_ancestor_chain(p_start_mdo_id bigint) RETURNS TABLE (mdo_id bigint, depth integer)
maludb_core._coerce_variable( p_var malu$prompt_variable, p_raw jsonb, p_opts malu$bind_options, OUT v_text text, OUT v_null boolean )
maludb_core._compute_cache_key( p_account_id bigint, p_template_id bigint, p_alias_id bigint, p_prompt_hash text, p_generation_params jsonb ) RETURNS text
maludb_core._cron_expand_field(p_field text, p_min integer, p_max integer) RETURNS integer[]
maludb_core._default_bind_options() RETURNS malu$bind_options
maludb_core._enable_memory_schema_075_facade(p_schema name) RETURNS integer
maludb_core._enable_memory_schema_076_facade(p_schema name) RETURNS integer
maludb_core._enable_memory_schema_ai_facade(p_schema name) RETURNS integer
maludb_core._enable_memory_schema_ai_facade(p_schema name) RETURNS integer
maludb_core._enable_memory_schema_core_facade(p_schema name) RETURNS integer
maludb_core._enable_memory_schema_ingest_facade(p_schema name) RETURNS integer
maludb_core._enable_memory_schema_pool_facade(p_schema name) RETURNS integer
maludb_core._enable_memory_schema_subject_facade(p_schema name) RETURNS integer
maludb_core._enable_memory_schema_subject_facade(p_schema name) RETURNS integer
maludb_core._escape_for(p_value text, p_mode text) RETURNS text
maludb_core._evaluate_applicability( p_applicability jsonb, p_environment text, p_technology_stack text[] ) RETURNS text
maludb_core._exec_fts(p_params jsonb) RETURNS SETOF malu$retrieval_hit
maludb_core._exec_fuzzy_subject(p_params jsonb) RETURNS SETOF malu$retrieval_hit
maludb_core._exec_source_filter(p_params jsonb) RETURNS SETOF malu$retrieval_hit
maludb_core._exec_temporal_as_of(p_params jsonb) RETURNS SETOF malu$retrieval_hit
maludb_core._grant_active( p_object_type text, p_object_id bigint, p_grant_levels text[] ) RETURNS boolean
maludb_core._grant_memory_schema_reader_access(p_schema name) RETURNS integer
maludb_core._insert_document_svpor_hints_for_schema( p_owner_schema name, p_document_id bigint, p_svpor_frames jsonb DEFAULT '[]'::jsonb ) RETURNS integer
maludb_core._lookup_cache(p_cache_key text) RETURNS bigint
maludb_core._lookup_idempotent_request( p_account_id bigint, p_idempotency_key text ) RETURNS bigint
maludb_core._memory_schema_assert_manageable(p_schema name) RETURNS void
maludb_core._memory_schema_assert_object_slot( p_schema name, p_object name, p_kind text ) RETURNS void
maludb_core._memory_schema_is_owned_by_current_role(p_schema name) RETURNS boolean
maludb_core._memory_schema_record_object( p_schema name, p_object name, p_kind text, p_purpose text ) RETURNS void
maludb_core._normalize_svpor_subject_type(p_value text) RETURNS text
maludb_core._normalize_svpor_verb_type(p_value text, p_fallback_text text DEFAULT NULL) RETURNS text
maludb_core._payload_validate( p_schema jsonb, p_instance jsonb, p_path text DEFAULT '' ) RETURNS text[]
maludb_core._payload_validate_claim() RETURNS trigger
maludb_core._payload_validate_episode() RETURNS trigger
maludb_core._payload_validate_fact() RETURNS trigger
maludb_core._payload_validate_mdo() RETURNS trigger
maludb_core._payload_validate_memory() RETURNS trigger
maludb_core._payload_validate_source_package() RETURNS trigger
maludb_core._register_vector_compartment_for_schema( p_owner_schema name, p_namespace text, p_subject_name text, p_verb_name text, p_embedding_dim integer, p_embedding_model text, p_distance_metric text DEFAULT 'cosine' ) RETURNS bigint
maludb_core._render_channels( p_template malu$prompt_template, p_variables jsonb, OUT s_text text, OUT d_text text, OUT u_text text, OUT full_text text )
maludb_core._render_compose(p_template malu$prompt_template) RETURNS text
maludb_core._render_core( p_session_id bigint, p_template_name text, p_template_version integer, p_variables jsonb, OUT template_id bigint, OUT rendered_prompt text, OUT prompt_hash text, OUT context_hash text, OUT context_block_count integer )
maludb_core._render_substitute(p_text text, p_variables jsonb) RETURNS text
maludb_core._resolve_template_for_lifecycle( p_template_name text, p_template_version integer ) RETURNS bigint
maludb_core._schedule_execute_action( p_schedule_id bigint, p_action_kind text, p_payload jsonb ) RETURNS jsonb
maludb_core._skill_is_visible( p_owner_schema name, p_skill_id bigint, p_requesting_schema name, p_include_public boolean DEFAULT true ) RETURNS boolean
maludb_core._source_canonical_bytes( p_bytes bytea, p_text text, p_jsonb jsonb ) RETURNS bytea
maludb_core._source_package_seal_lock() RETURNS trigger
maludb_core._svpor_auto_resolve() RETURNS trigger
maludb_core._svpor_slug(p_value text) RETURNS text
maludb_core._svpor_subject_normalize_type_tg() RETURNS trigger
maludb_core._svpor_subject_relationship_refresh_label_tg() RETURNS trigger
maludb_core._svpor_subject_relationship_set_labels_tg() RETURNS trigger
maludb_core._svpor_verb_normalize_type_tg() RETURNS trigger
maludb_core._template_hash(p_t malu$prompt_template) RETURNS text
maludb_core._tool_stack_signature(p_tools text[]) RETURNS text
maludb_core._upload_document_for_schema( p_owner_schema name, p_title text, p_content_text text, p_source_type text DEFAULT 'document', p_content_jsonb jsonb DEFAULT NULL, p_media_type text DEFAULT NULL, p_projects text[] DEFAULT ARRAY[]::text[], p_subjects text[] DEFAULT ARRAY[]::text[], p_verbs text[] DEFAULT ARRAY[]::text[], p_events text[] DEFAULT ARRAY[]::text[], p_metadata_jsonb jsonb DEFAULT '{}'::jsonb ) RETURNS bigint
maludb_core._v3_api_arg( p_name text, p_type text, p_required boolean DEFAULT true, p_in text DEFAULT 'body', p_default jsonb DEFAULT 'null'::jsonb ) RETURNS jsonb
maludb_core._v3_api_arg( p_name text, p_type text, p_required boolean DEFAULT true, p_in text DEFAULT 'body', p_default jsonb DEFAULT 'null'::jsonb) RETURNS jsonb
maludb_core._v3_api_arg( p_name text, p_type text, p_required boolean DEFAULT true, p_in text DEFAULT 'body', p_default jsonb DEFAULT 'null'::jsonb) RETURNS jsonb
maludb_core._validate_bind_variables( p_template_id bigint, p_variables jsonb, p_opts malu$bind_options ) RETURNS malu$bind_validation
maludb_core._validate_source_locator(p_locator jsonb) RETURNS boolean
maludb_core.abort_skill_execution( p_execution_id bigint, p_reason text DEFAULT NULL ) RETURNS void
maludb_core.accept_pending_claim( p_pending_claim_id bigint, p_reviewer text DEFAULT NULL, p_review_note text DEFAULT NULL, p_parser_name text DEFAULT NULL, p_verifier_name text DEFAULT NULL, p_inputs_jsonb jsonb DEFAULT NULL ) RETURNS bigint
maludb_core.add_skill_state( p_skill_id bigint, p_state_name text, p_state_kind text, p_step_jsonb jsonb DEFAULT NULL, p_validation_jsonb jsonb DEFAULT NULL ) RETURNS bigint
maludb_core.add_skill_transition( p_skill_id bigint, p_from_state text, p_to_state text, p_on_outcome text, p_guard_jsonb jsonb DEFAULT NULL, p_ordinal integer DEFAULT 0 ) RETURNS bigint
maludb_core.add_svpor_related_subject( p_subject_id bigint, p_related_subject_id bigint, p_label text DEFAULT NULL, p_metadata_jsonb jsonb DEFAULT '{}'::jsonb ) RETURNS TABLE (
maludb_core.advance_checkpoint( p_connector_id bigint, p_cursor_name text DEFAULT 'default', p_cursor_value text DEFAULT NULL, p_cursor_jsonb jsonb DEFAULT NULL, p_cursor_format text DEFAULT NULL, p_mode text DEFAULT NULL, p_items_added bigint DEFAULT 0, p_last_error text DEFAULT NULL ) RETURNS bigint
maludb_core.advance_index_migration( p_migration_id bigint, p_new_status text, p_traffic_pct numeric DEFAULT NULL ) RETURNS void
maludb_core.advance_model_rollout( p_registry_id bigint, p_new_state text ) RETURNS void
maludb_core.advanced_chatindex_append(args jsonb, context jsonb) RETURNS void
maludb_core.advanced_chatindex_ask(args jsonb, context jsonb) RETURNS void
maludb_core.advanced_chatindex_build(args jsonb, context jsonb) RETURNS void
maludb_core.advanced_chatindex_list(args jsonb, context jsonb) RETURNS void
maludb_core.advanced_episode_replay(args jsonb, context jsonb) RETURNS void
maludb_core.advanced_node_accept(args jsonb, context jsonb) RETURNS void
maludb_core.advanced_node_submit(args jsonb, context jsonb) RETURNS void
maludb_core.advanced_pageindex_ask(args jsonb, context jsonb) RETURNS void
maludb_core.advanced_pageindex_build(args jsonb, context jsonb) RETURNS void
maludb_core.advanced_pageindex_list(args jsonb, context jsonb) RETURNS void
maludb_core.advanced_pageindex_tree_summary(args jsonb, context jsonb) RETURNS void
maludb_core.advanced_pool_add_observation(args jsonb, context jsonb) RETURNS void
maludb_core.advanced_pool_create(args jsonb, context jsonb) RETURNS void
maludb_core.advanced_pool_promote_claim(args jsonb, context jsonb) RETURNS void
maludb_core.advanced_retrieve(args jsonb, context jsonb) RETURNS void
maludb_core.advanced_skill_abort(args jsonb, context jsonb) RETURNS void
maludb_core.advanced_skill_begin(args jsonb, context jsonb) RETURNS void
maludb_core.advanced_skill_step(args jsonb, context jsonb) RETURNS void
maludb_core.advanced_text_search(args jsonb, context jsonb) RETURNS void
maludb_core.advanced_workflow_cluster(args jsonb, context jsonb) RETURNS void
maludb_core.advanced_workflow_extract(args jsonb, context jsonb) RETURNS void
maludb_core.advanced_workflow_propose(args jsonb, context jsonb) RETURNS void
maludb_core.advanced_write_claim(args jsonb, context jsonb) RETURNS void
maludb_core.advanced_write_episode(args jsonb, context jsonb) RETURNS void
maludb_core.advanced_write_fact(args jsonb, context jsonb) RETURNS void
maludb_core.advanced_write_memory(args jsonb, context jsonb) RETURNS void
maludb_core.advanced_write_source_package(args jsonb, context jsonb) RETURNS void
maludb_core.ann_build( p_compartment_id bigint, p_m integer DEFAULT 16, p_ef_construction integer DEFAULT 64, p_ef_search integer DEFAULT 32 ) RETURNS bigint
maludb_core.ann_rebuild( p_compartment_id bigint ) RETURNS bigint
maludb_core.ann_status(p_compartment_id bigint) RETURNS TABLE (
maludb_core.append_context( p_session_id bigint, p_role text DEFAULT NULL, p_content_text text DEFAULT NULL, p_content_jsonb jsonb DEFAULT NULL, p_source_label text DEFAULT NULL, p_sensitivity text DEFAULT 'internal', p_token_estimate integer DEFAULT NULL ) RETURNS bigint
maludb_core.apply_default_weights(p_target_object_type text) RETURNS integer
maludb_core.apply_hints( p_plan malu$retrieval_plan, p_hints jsonb ) RETURNS malu$retrieval_plan
maludb_core.apply_lifecycle_state( p_target_object_type text, p_target_object_id bigint, p_new_state text, p_reason text DEFAULT NULL ) RETURNS void
maludb_core.approve_prompt( p_template_name text, p_template_version integer DEFAULT NULL, p_safety_policy text DEFAULT NULL, p_approver_account text DEFAULT NULL ) RETURNS bigint
maludb_core.archive_source_package( p_source_package_id bigint, p_placement_tier text, p_content_bytes bytea DEFAULT NULL, p_content_compression text DEFAULT 'none', p_external_uri text DEFAULT NULL, p_external_etag text DEFAULT NULL, p_note text DEFAULT NULL ) RETURNS bigint
maludb_core.attach_adapter_to_migration( p_migration_id bigint, p_adapter_id bigint ) RETURNS void
maludb_core.audit_event( p_event_kind text, p_target_object_type text DEFAULT NULL, p_target_object_id bigint DEFAULT NULL, p_event_jsonb jsonb DEFAULT NULL, p_error_text text DEFAULT NULL ) RETURNS bigint
maludb_core.audit_status() RETURNS TABLE (
maludb_core.auth_token_create( p_account_id bigint, p_kind text, p_label text DEFAULT NULL, p_scopes text[] DEFAULT ARRAY[]::text[], p_allowed_cidrs inet[] DEFAULT NULL, p_expires_at timestamptz DEFAULT NULL ) RETURNS TABLE (token_id bigint, plaintext_token text)
maludb_core.auth_token_create( p_account_id bigint, p_kind text, p_label text DEFAULT NULL, p_scopes text[] DEFAULT ARRAY[]::text[], p_allowed_cidrs inet[] DEFAULT NULL, p_expires_at timestamptz DEFAULT NULL ) RETURNS TABLE (token_id bigint, plaintext_token text)
maludb_core.auth_token_revoke(p_token_id bigint, p_reason text DEFAULT NULL) RETURNS boolean
maludb_core.auth_token_verify( p_plaintext text, p_source_ip inet DEFAULT NULL ) RETURNS TABLE (
maludb_core.authorize_object_types( p_envelope malu$retrieval_envelope_t ) RETURNS text[]
maludb_core.backup_manifest_latest() RETURNS TABLE (
maludb_core.backup_manifest_record( p_label text, p_postgres_state_kind text, p_postgres_state_uri text, p_hash_summary jsonb, p_wal_archive_uri text DEFAULT NULL, p_etc_maludb_uri text DEFAULT NULL, p_source_archive_manifest_uri text DEFAULT NULL, p_model_configs_uri text DEFAULT NULL, p_tls_uri text DEFAULT NULL, p_tool_binaries_uri text DEFAULT NULL, p_broker_configs_uri text DEFAULT NULL ) RETURNS bigint
maludb_core.backup_verification_record( p_manifest_id bigint, p_status text, p_errors jsonb DEFAULT NULL, p_notes text DEFAULT NULL ) RETURNS bigint
maludb_core.begin_skill_execution( p_skill_id bigint, p_environment text DEFAULT NULL, p_technology_stack text[] DEFAULT NULL, p_task_objective text DEFAULT NULL, p_authorized_partitions text[] DEFAULT NULL, p_account_id bigint DEFAULT NULL, p_active_pool_id bigint DEFAULT NULL, p_source_context_id bigint DEFAULT NULL ) RETURNS bigint
maludb_core.bind_prompt( p_template_name text, p_variables jsonb DEFAULT '{}'::jsonb, p_opts malu$bind_options DEFAULT NULL, p_session_id bigint DEFAULT NULL, p_template_version integer DEFAULT NULL, p_account_id bigint DEFAULT NULL ) RETURNS bound_prompt
maludb_core.bind_prompt( p_template_name text, p_variables jsonb DEFAULT '{}'::jsonb, p_opts malu$bind_options DEFAULT NULL, p_session_id bigint DEFAULT NULL, p_template_version integer DEFAULT NULL, p_account_id bigint DEFAULT NULL ) RETURNS bound_prompt
maludb_core.call( p_bound bound_prompt, p_alias_name text, p_session_id bigint DEFAULT NULL, p_generation_params jsonb DEFAULT '{}'::jsonb, p_timeout_ms integer DEFAULT 30000, p_account_name text DEFAULT NULL ) RETURNS bigint
maludb_core.call( p_bound bound_prompt, p_alias_name text, p_session_id bigint DEFAULT NULL, p_generation_params jsonb DEFAULT '{}'::jsonb, p_timeout_ms integer DEFAULT 30000, p_account_name text DEFAULT NULL, p_cache_mode text DEFAULT 'off' ) RETURNS bigint
maludb_core.call( p_bound bound_prompt, p_alias_name text, p_session_id bigint DEFAULT NULL, p_generation_params jsonb DEFAULT '{}'::jsonb, p_timeout_ms integer DEFAULT 30000, p_account_name text DEFAULT NULL, p_cache_mode text DEFAULT 'off', p_idempotency_key text DEFAULT NULL ) RETURNS bigint
maludb_core.call( p_bound bound_prompt, p_alias_name text, p_session_id bigint DEFAULT NULL, p_generation_params jsonb DEFAULT '{}'::jsonb, p_timeout_ms integer DEFAULT 30000, p_account_name text DEFAULT NULL, p_cache_mode text DEFAULT 'off', p_idempotency_key text DEFAULT NULL ) RETURNS bigint
maludb_core.cancel_request(p_request_id bigint) RETURNS text
maludb_core.chat_append_message( p_chat_session_id bigint, p_role text, p_content_text text DEFAULT NULL, p_content_jsonb jsonb DEFAULT NULL, p_metadata_jsonb jsonb DEFAULT '{}'::jsonb ) RETURNS bigint
maludb_core.chat_finalize(p_chat_session_id bigint) RETURNS jsonb
maludb_core.chat_get(p_chat_session_id bigint) RETURNS jsonb
maludb_core.chat_index_append_messages( p_tree_id bigint, p_messages jsonb ) RETURNS TABLE (
maludb_core.chat_index_close_topic( p_tree_id bigint, p_topic_node_mdo_id bigint ) RETURNS void
maludb_core.chat_index_record_message( p_tree_id bigint, p_topic_mdo_id bigint, p_message_index integer, p_system_message text DEFAULT NULL, p_user_message text DEFAULT NULL, p_assistant_message text DEFAULT NULL, p_summary text DEFAULT NULL, p_model_alias_id bigint DEFAULT NULL, p_prompt_template_id bigint DEFAULT NULL ) RETURNS TABLE (mdo_id bigint, derivation_id bigint)
maludb_core.chat_index_record_topic( p_tree_id bigint, p_parent_mdo_id bigint, p_topic_name text, p_summary text, p_model_alias_id bigint DEFAULT NULL, p_prompt_template_id bigint DEFAULT NULL ) RETURNS TABLE (mdo_id bigint, derivation_id bigint)
maludb_core.chat_index_tree_mark_building(p_tree_id bigint) RETURNS void
maludb_core.chat_index_tree_mark_failed( p_tree_id bigint, p_reason text DEFAULT NULL ) RETURNS void
maludb_core.chat_index_tree_mark_ready(p_tree_id bigint) RETURNS void
maludb_core.chat_index_tree_register( p_source_package_id bigint, p_model_alias_id bigint DEFAULT NULL, p_prompt_template_id bigint DEFAULT NULL, p_max_children integer DEFAULT 10 ) RETURNS bigint
maludb_core.chat_index_tree_supersede( p_prior_tree_id bigint, p_new_tree_id bigint ) RETURNS bigint
maludb_core.chat_messages(p_chat_session_id bigint) RETURNS TABLE (
maludb_core.chat_start( p_title text DEFAULT NULL, p_account_name text DEFAULT NULL, p_projects text[] DEFAULT ARRAY[]::text[], p_subjects text[] DEFAULT ARRAY[]::text[], p_verbs text[] DEFAULT ARRAY[]::text[], p_svpor_frames jsonb DEFAULT '[]'::jsonb, p_metadata_jsonb jsonb DEFAULT '{}'::jsonb ) RETURNS bigint
maludb_core.chat_tree_descent_retrieve( p_envelope_id bigint, p_chat_tree_id bigint, p_descent_options jsonb DEFAULT '{}'::jsonb ) RETURNS TABLE (
maludb_core.chatindex_list_trees( p_build_status text DEFAULT NULL, p_limit integer DEFAULT 50 ) RETURNS TABLE (
maludb_core.check_budget( p_account_id bigint, p_template_id bigint ) RETURNS void
maludb_core.classify_intent(p_envelope malu$retrieval_envelope_t) RETURNS text
maludb_core.classify_intent(p_envelope malu$retrieval_envelope_t) RETURNS text
maludb_core.clear_context(p_session_id bigint) RETURNS integer
maludb_core.close_session( p_session_id bigint, p_state text DEFAULT 'closed' ) RETURNS text
maludb_core.close_valid_window( p_object_type text, p_object_id bigint, p_end_time timestamptz DEFAULT now(), p_reason text DEFAULT NULL ) RETURNS void
maludb_core.cluster_workflow_traces( p_subject_class text, p_action_class text, p_outcome text, p_environment text DEFAULT NULL, p_tool_stack text[] DEFAULT NULL, p_exception_pattern text DEFAULT NULL ) RETURNS bigint
maludb_core.compute_salience( p_target_object_type text, p_target_object_id bigint, p_normalisation numeric DEFAULT 5.0 ) RETURNS numeric
maludb_core.consolidate_memories( p_source_memory_ids bigint[], p_consolidated_kind text, p_title text, p_summary text, p_payload_jsonb jsonb DEFAULT '{}'::jsonb, p_reason text DEFAULT NULL ) RETURNS bigint
maludb_core.correct_fact( p_fact_id bigint, p_new_object_value text DEFAULT NULL, p_new_statement text DEFAULT NULL, p_new_statement_jsonb jsonb DEFAULT NULL, p_reason text DEFAULT NULL, p_supersession_kind text DEFAULT 'correction' ) RETURNS bigint
maludb_core.cosine_distance(a bytea, b bytea) RETURNS double precision
maludb_core.cosine_distance(a malu_vector, b malu_vector) RETURNS double precision
maludb_core.create_active_memory_pool( p_pool_name text, p_creation_kind text DEFAULT 'sql', p_task_objective text DEFAULT NULL, p_authorized_partitions text[] DEFAULT NULL, p_confidence_floor numeric DEFAULT NULL, p_validity_start timestamptz DEFAULT NULL, p_validity_end timestamptz DEFAULT NULL, p_max_member_count integer DEFAULT NULL ) RETURNS bigint
maludb_core.cron_next_after(p_expr text, p_after timestamptz) RETURNS timestamptz
maludb_core.current_account_id() RETURNS bigint
maludb_core.declare_prompt_variable( p_template_name text, p_variable_name text, p_variable_type text DEFAULT 'text', p_required boolean DEFAULT false, p_default_value text DEFAULT NULL, p_validation_rule text DEFAULT NULL, p_max_length integer DEFAULT NULL, p_enum_values text[] DEFAULT NULL, p_sensitivity text DEFAULT 'internal', p_template_version integer DEFAULT NULL ) RETURNS bigint
maludb_core.delete_svpor_related_subject( p_subject_id bigint, p_related_subject_id bigint ) RETURNS boolean
maludb_core.deprecate_prompt( p_template_name text, p_template_version integer DEFAULT NULL, p_reason text DEFAULT NULL ) RETURNS bigint
maludb_core.document_get(p_document_id bigint) RETURNS jsonb
maludb_core.embedding_enqueue( p_target_kind text, p_target_id bigint, p_model_alias text, p_embedding_space text, p_input_hash bytea DEFAULT NULL, p_prompt_template_version text DEFAULT NULL ) RETURNS bigint
maludb_core.embedding_enqueue( p_target_kind text, p_target_id bigint, p_model_alias text, p_embedding_space text, p_input_hash bytea DEFAULT NULL, p_prompt_template_version text DEFAULT NULL, p_precomputed_boundaries_from_tree_id bigint DEFAULT NULL ) RETURNS bigint
maludb_core.embedding_record_output( p_job_id bigint, p_vector malu_vector, p_vector_dim integer, p_svpor_frame_text text, p_output_hash bytea ) RETURNS TABLE (output_id bigint, derivation_id bigint)
maludb_core.embedding_record_output( p_job_id bigint, p_vector malu_vector, p_vector_dim integer, p_svpor_frame_text text, p_output_hash bytea ) RETURNS TABLE (output_id bigint, derivation_id bigint)
maludb_core.embedding_results( p_target_kind text, p_target_id bigint, p_embedding_space text DEFAULT NULL ) RETURNS TABLE (
maludb_core.emit_event( p_event_kind text, p_payload jsonb DEFAULT '{}'::jsonb, p_account_id bigint DEFAULT NULL, p_partition text DEFAULT NULL, p_active_pool_id bigint DEFAULT NULL, p_object_type text DEFAULT NULL, p_object_id bigint DEFAULT NULL, p_scope jsonb DEFAULT NULL ) RETURNS bigint
maludb_core.enable_memory_schema(p_schema name DEFAULT current_schema()) RETURNS TABLE(schema_name name, enabled_version text, object_count integer)
maludb_core.enable_memory_schema(p_schema name DEFAULT current_schema()) RETURNS TABLE(schema_name name, enabled_version text, object_count integer)
maludb_core.enable_memory_schema(p_schema name DEFAULT current_schema()) RETURNS TABLE(schema_name name, enabled_version text, object_count integer)
maludb_core.enable_memory_schema(p_schema name DEFAULT current_schema()) RETURNS TABLE(schema_name name, enabled_version text, object_count integer)
maludb_core.enable_memory_schema(p_schema name DEFAULT current_schema()) RETURNS TABLE(schema_name name, enabled_version text, object_count integer)
maludb_core.episode_as_of(p_at timestamptz) RETURNS SETOF malu$episode_object
maludb_core.event_ack(p_subscription_id bigint, p_through_event_id bigint) RETURNS integer
maludb_core.event_fetch_batch( p_subscription_id bigint, p_limit integer DEFAULT 100 ) RETURNS TABLE (
maludb_core.event_list_subscriptions(p_include_retired boolean DEFAULT false) RETURNS TABLE (
maludb_core.event_subscribe( p_name text, p_account_id bigint DEFAULT NULL, p_kinds text[] DEFAULT ARRAY[]::text[], p_partitions text[] DEFAULT ARRAY[]::text[], p_active_pool_id bigint DEFAULT NULL, p_start_cursor bigint DEFAULT 0 ) RETURNS bigint
maludb_core.exact_vector_search_c( p_compartment_id bigint, p_query bytea, p_limit integer DEFAULT 10, p_metric text DEFAULT NULL ) RETURNS TABLE (
maludb_core.exact_vector_search_c( p_compartment_id bigint, p_query malu_vector, p_limit integer DEFAULT 10, p_metric text DEFAULT NULL ) RETURNS TABLE (
maludb_core.exact_vector_search_parallel_c( p_compartment_id bigint, p_query malu_vector, p_limit integer DEFAULT 10, p_metric text DEFAULT NULL ) RETURNS TABLE (
maludb_core.exact_vector_search_plpgsql( p_compartment_id bigint, p_query bytea, p_limit integer DEFAULT 10, p_metric text DEFAULT NULL ) RETURNS TABLE (
maludb_core.exact_vector_search_plpgsql( p_compartment_id bigint, p_query malu_vector, p_limit integer DEFAULT 10, p_metric text DEFAULT NULL ) RETURNS TABLE (
maludb_core.exact_vector_search_sql( p_compartment_id bigint, p_query bytea, p_limit integer DEFAULT 10, p_metric text DEFAULT NULL ) RETURNS TABLE (
maludb_core.exact_vector_search_sql( p_compartment_id bigint, p_query malu_vector, p_limit integer DEFAULT 10, p_metric text DEFAULT NULL ) RETURNS TABLE (
maludb_core.exact_vector_search_sql( p_compartment_id bigint, p_query malu_vector, p_limit integer DEFAULT 10, p_metric text DEFAULT NULL ) RETURNS TABLE (
maludb_core.exact_vector_search_sql( p_compartment_id bigint, p_query malu_vector, p_limit integer DEFAULT 10, p_metric text DEFAULT NULL ) RETURNS TABLE (
maludb_core.execute_retrieval( p_envelope malu$retrieval_envelope_t, p_hint_name text DEFAULT NULL, p_limit integer DEFAULT 20 ) RETURNS SETOF malu$retrieval_hit
maludb_core.explain_vector_search( p_namespace text, p_subject text, p_verb text ) RETURNS TABLE (
maludb_core.extract_cues(p_cue_text text) RETURNS SETOF malu$retrieval_cue
maludb_core.extract_workflow_trace( p_episode_id bigint, p_outcome text DEFAULT 'success', p_environment text DEFAULT NULL, p_security_domain text DEFAULT NULL, p_subject_class text DEFAULT NULL, p_action_class text DEFAULT NULL ) RETURNS bigint
maludb_core.fact_as_of(p_at timestamptz) RETURNS SETOF malu$fact
maludb_core.find_skill( p_query text DEFAULT NULL, p_subject text DEFAULT NULL, p_verb text DEFAULT NULL, p_query_embedding malu_vector DEFAULT NULL, p_owner_schema name DEFAULT current_schema(), p_limit integer DEFAULT 20, p_include_public boolean DEFAULT true ) RETURNS TABLE (
maludb_core.fork_skill( p_source_owner_schema name, p_source_skill_id bigint, p_target_owner_schema name DEFAULT current_schema(), p_new_skill_name text DEFAULT NULL, p_new_version text DEFAULT '1.0.0' ) RETURNS bigint
maludb_core.fuzzy_subject_match( p_needle text, p_threshold real DEFAULT 0.3, p_object_types text[] DEFAULT ARRAY['claim','fact'], p_limit integer DEFAULT 50 ) RETURNS TABLE (
maludb_core.get_response(p_request_id bigint) RETURNS TABLE (
maludb_core.get_retry_policy(p_provider_id bigint) RETURNS malu$retry_policy
maludb_core.get_skill( p_owner_schema name, p_skill_id bigint, p_requesting_schema name DEFAULT current_schema() ) RETURNS TABLE (payload jsonb)
maludb_core.grant_memory_access( p_role_name name, p_access_level text DEFAULT 'write' ) RETURNS name
maludb_core.grant_object_access( p_object_type text, p_object_id bigint, p_granted_to_schema name, p_grant_level text DEFAULT 'read', p_expires_at timestamptz DEFAULT NULL, p_note text DEFAULT NULL ) RETURNS bigint
maludb_core.grant_object_access( p_object_type text, p_object_id bigint, p_granted_to_schema name, p_grant_level text DEFAULT 'read', p_expires_at timestamptz DEFAULT NULL, p_note text DEFAULT NULL ) RETURNS bigint
maludb_core.graph_neighbors( p_object_type text, p_object_id bigint, p_direction text DEFAULT 'out', p_relationship_filter text[] DEFAULT NULL ) RETURNS TABLE (
maludb_core.graph_path( p_source_type text, p_source_id bigint, p_target_type text, p_target_id bigint, p_max_depth integer DEFAULT 6, p_direction text DEFAULT 'out' ) RETURNS TABLE (
maludb_core.graph_walk( p_object_type text, p_object_id bigint, p_max_depth integer DEFAULT 4, p_direction text DEFAULT 'out', p_relationship_filter text[] DEFAULT NULL, p_mode text DEFAULT 'bfs' ) RETURNS TABLE (
maludb_core.ingest_claim_atomic( p_source_type text, p_source_text text, p_subject text DEFAULT NULL, p_verb text DEFAULT NULL, p_object_value text DEFAULT NULL, p_statement_text text DEFAULT NULL, p_parser_name text DEFAULT NULL, p_origin_jsonb jsonb DEFAULT NULL, p_source_locator jsonb DEFAULT NULL, p_model_request_id bigint DEFAULT NULL, p_inputs_jsonb jsonb DEFAULT NULL ) RETURNS bigint
maludb_core.inner_product(a bytea, b bytea) RETURNS double precision
maludb_core.inner_product(a malu_vector, b malu_vector) RETURNS double precision
maludb_core.is_currently_valid( p_start timestamptz, p_end timestamptz ) RETURNS boolean
maludb_core.is_under_legal_hold( p_target_object_type text, p_target_object_id bigint ) RETURNS boolean
maludb_core.is_valid_at( p_start timestamptz, p_end timestamptz, p_at timestamptz ) RETURNS boolean
maludb_core.jwt_verify(p_jwt text) RETURNS TABLE (
maludb_core.jwt_verify(p_jwt text) RETURNS TABLE (
maludb_core.l2_squared_distance(a bytea, b bytea) RETURNS double precision
maludb_core.l2_squared_distance(a malu_vector, b malu_vector) RETURNS double precision
maludb_core.legal_hold_apply( p_target_object_type text, p_target_object_id bigint, p_reason text ) RETURNS bigint
maludb_core.legal_hold_release( p_hold_id bigint, p_release_reason text ) RETURNS void
maludb_core.list_object_grants( p_object_type text, p_object_id bigint ) RETURNS TABLE (
maludb_core.list_pending_claims( p_connector_id bigint DEFAULT NULL, p_limit integer DEFAULT 100 ) RETURNS TABLE (
maludb_core.list_svpor_related_subjects( p_subject_id bigint ) RETURNS TABLE (
maludb_core.log_drain_advance_cursor( p_drain_id bigint, p_stream text, p_last_id bigint ) RETURNS bigint
maludb_core.log_drain_disable(p_name text, p_reason text DEFAULT NULL) RETURNS boolean
maludb_core.log_drain_enable(p_name text) RETURNS boolean
maludb_core.log_drain_fetch_batch( p_drain_id bigint, p_stream text, p_limit integer DEFAULT 100 ) RETURNS TABLE (record_id bigint, payload jsonb)
maludb_core.log_drain_list(p_include_disabled boolean DEFAULT false) RETURNS TABLE (drain_id bigint, name text, kind text, source_streams text[], enabled boolean, retired_at timestamptz)
maludb_core.log_drain_record_run( p_drain_id bigint, p_batches integer, p_bytes bigint, p_records integer, p_errors integer DEFAULT 0, p_last_error text DEFAULT NULL ) RETURNS bigint
maludb_core.log_drain_set( p_name text, p_kind text, p_destination jsonb, p_source_streams text[], p_destination_secret_ref text DEFAULT NULL, p_redaction_rules jsonb DEFAULT '[]'::jsonb, p_batch_size integer DEFAULT 100, p_flush_interval_ms integer DEFAULT 5000 ) RETURNS bigint
maludb_core.malu_vector_in(cstring) RETURNS malu_vector
maludb_core.malu_vector_out(malu_vector) RETURNS cstring
maludb_core.malu_vector_recv(internal) RETURNS malu_vector
maludb_core.malu_vector_send(malu_vector) RETURNS bytea
maludb_core.maludb_ann_build_c( p_compartment_id bigint, p_m integer, p_ef_construct integer, p_metric text ) RETURNS bytea
maludb_core.maludb_ann_search_c( p_graph bytea, p_query malu_vector, p_limit integer, p_ef_search integer, p_metric text ) RETURNS TABLE (
maludb_core.maludb_core_attach_stat_statements_view() RETURNS void
maludb_core.maludb_core_release() RETURNS text
maludb_core.maludb_core_version() RETURNS text
maludb_core.maludb_core_version() RETURNS text
maludb_core.maludb_core_version() RETURNS text
maludb_core.maludb_core_version() RETURNS text
maludb_core.maludb_core_version() RETURNS text
maludb_core.maludb_core_version() RETURNS text
maludb_core.maludb_core_version() RETURNS text
maludb_core.maludb_core_version() RETURNS text
maludb_core.maludb_core_version() RETURNS text
maludb_core.maludb_core_version() RETURNS text
maludb_core.maludb_core_version() RETURNS text
maludb_core.maludb_core_version() RETURNS text
maludb_core.maludb_core_version() RETURNS text
maludb_core.maludb_core_version() RETURNS text
maludb_core.maludb_core_version() RETURNS text
maludb_core.maludb_core_version() RETURNS text
maludb_core.maludb_core_version() RETURNS text
maludb_core.maludb_core_version() RETURNS text
maludb_core.maludb_core_version() RETURNS text
maludb_core.maludb_core_version() RETURNS text
maludb_core.maludb_core_version() RETURNS text
maludb_core.maludb_core_version() RETURNS text
maludb_core.maludb_core_version() RETURNS text
maludb_core.maludb_core_version() RETURNS text
maludb_core.maludb_core_version() RETURNS text
maludb_core.maludb_core_version() RETURNS text
maludb_core.maludb_core_version() RETURNS text
maludb_core.maludb_core_version() RETURNS text
maludb_core.maludb_core_version() RETURNS text
maludb_core.maludb_core_version() RETURNS text
maludb_core.maludb_core_version() RETURNS text
maludb_core.maludb_core_version() RETURNS text
maludb_core.maludb_core_version() RETURNS text
maludb_core.maludb_core_version() RETURNS text
maludb_core.maludb_core_version() RETURNS text
maludb_core.maludb_core_version() RETURNS text
maludb_core.maludb_core_version() RETURNS text
maludb_core.maludb_core_version() RETURNS text
maludb_core.maludb_core_version() RETURNS text
maludb_core.maludb_core_version() RETURNS text
maludb_core.maludb_core_version() RETURNS text
maludb_core.maludb_core_version() RETURNS text
maludb_core.maludb_core_version() RETURNS text
maludb_core.maludb_core_version() RETURNS text
maludb_core.maludb_core_version() RETURNS text
maludb_core.maludb_core_version() RETURNS text
maludb_core.maludb_core_version() RETURNS text
maludb_core.maludb_core_version() RETURNS text
maludb_core.maludb_core_version() RETURNS text
maludb_core.maludb_core_version() RETURNS text
maludb_core.maludb_core_version() RETURNS text
maludb_core.maludb_core_version() RETURNS text
maludb_core.maludb_core_version() RETURNS text
maludb_core.maludb_core_version() RETURNS text
maludb_core.maludb_core_version() RETURNS text
maludb_core.maludb_core_version() RETURNS text
maludb_core.maludb_core_version() RETURNS text
maludb_core.maludb_core_version() RETURNS text
maludb_core.maludb_core_version() RETURNS text
maludb_core.maludb_core_version() RETURNS text
maludb_core.maludb_core_version() RETURNS text
maludb_core.maludb_core_version() RETURNS text
maludb_core.maludb_core_version() RETURNS text
maludb_core.maludb_core_version() RETURNS text
maludb_core.maludb_core_version() RETURNS text
maludb_core.maludb_core_version() RETURNS text
maludb_core.maludb_core_version() RETURNS text
maludb_core.maludb_core_version() RETURNS text
maludb_core.maludb_core_version() RETURNS text
maludb_core.maludb_core_version() RETURNS text
maludb_core.maludb_core_version() RETURNS text
maludb_core.maludb_core_version() RETURNS text
maludb_core.maludb_core_version() RETURNS text
maludb_core.maludb_core_version() RETURNS text
maludb_core.maludb_core_version() RETURNS text
maludb_core.maludb_core_version() RETURNS text
maludb_core.maludb_core_version() RETURNS text
maludb_core.maludb_hmac_sha256(p_key bytea, p_data bytea) RETURNS bytea
maludb_core.maludb_secret_resolve_external(p_uri text) RETURNS text
maludb_core.maut_aggregate_confidence( p_target_object_type text, p_target_object_id bigint ) RETURNS numeric
maludb_core.maut_score_detail( p_target_object_type text, p_target_object_id bigint ) RETURNS TABLE (
maludb_core.mc_stub_process(p_request_id bigint) RETURNS bigint
maludb_core.mdo_ancestors(p_mdo_id bigint) RETURNS TABLE (
maludb_core.mdo_descendants( p_mdo_id bigint, p_max_depth integer DEFAULT NULL ) RETURNS TABLE (
maludb_core.mdo_resolve(p_uri text) RETURNS bigint
maludb_core.mdo_root(p_mdo_id bigint) RETURNS malu$mdo_root_result
maludb_core.mdo_subtree_json( p_mdo_id bigint, p_max_depth integer DEFAULT 5 ) RETURNS jsonb
maludb_core.memory_as_of(p_at timestamptz) RETURNS SETOF malu$memory
maludb_core.metrics_prometheus_scrape() RETURNS text
maludb_core.negotiate_local_model( p_min_context_window integer DEFAULT NULL, p_required_quantization text DEFAULT NULL, p_min_vram_mb integer DEFAULT NULL ) RETURNS TABLE (
maludb_core.node_accept( p_submission_id bigint, p_reason text DEFAULT NULL ) RETURNS jsonb
maludb_core.node_record_conflict( p_submission_id bigint, p_conflict_kind text, p_server_object_type text DEFAULT NULL, p_server_object_id bigint DEFAULT NULL, p_resolution text DEFAULT NULL, p_resolution_notes text DEFAULT NULL ) RETURNS bigint
maludb_core.node_reject( p_submission_id bigint, p_reason text ) RETURNS void
maludb_core.node_submit( p_node_id bigint, p_submission_kind text, p_payload_jsonb jsonb, p_local_id bigint DEFAULT NULL, p_local_hash text DEFAULT NULL ) RETURNS bigint
maludb_core.octet_length(malu_vector) RETURNS integer
maludb_core.page_index_chunker_handoff(p_tree_id bigint) RETURNS TABLE (
maludb_core.page_index_record_node( p_tree_id bigint, p_parent_mdo_id bigint, p_node_kind text, p_title text, p_summary text, p_model_alias_id bigint DEFAULT NULL, p_prompt_template_id bigint DEFAULT NULL, p_input_hash bytea DEFAULT NULL, p_output_hash bytea DEFAULT NULL, p_anchor_jsonb jsonb DEFAULT NULL ) RETURNS TABLE (mdo_id bigint, derivation_id bigint)
maludb_core.page_index_record_structure_pass( p_tree_id bigint, p_parser_kind text, p_parser_version text, p_outline_node_count integer, p_leaf_count integer, p_deterministic_inputs_hash text, p_outcome text DEFAULT 'ok', p_error_text text DEFAULT NULL ) RETURNS bigint
maludb_core.page_index_tree_mark_building(p_tree_id bigint) RETURNS void
maludb_core.page_index_tree_mark_failed( p_tree_id bigint, p_reason text DEFAULT NULL ) RETURNS void
maludb_core.page_index_tree_mark_ready(p_tree_id bigint) RETURNS void
maludb_core.page_index_tree_register( p_source_package_id bigint, p_parser_kind text, p_model_alias_id bigint DEFAULT NULL, p_prompt_template_id bigint DEFAULT NULL ) RETURNS bigint
maludb_core.page_index_tree_supersede( p_prior_tree_id bigint, p_new_tree_id bigint ) RETURNS bigint
maludb_core.pageindex_get_tree(p_tree_id bigint) RETURNS TABLE (
maludb_core.pageindex_list_trees( p_build_status text DEFAULT NULL, p_limit integer DEFAULT 50 ) RETURNS TABLE (
maludb_core.pgaudit_recommended_settings() RETURNS text
maludb_core.plan_retrieval(p_envelope malu$retrieval_envelope_t) RETURNS malu$retrieval_plan
maludb_core.plan_retrieval_with_hints( p_envelope malu$retrieval_envelope_t, p_hint_name text DEFAULT NULL ) RETURNS malu$retrieval_plan
maludb_core.pool_add_named_member( p_pool_name text, p_member_kind text, p_member_name text, p_confidence numeric DEFAULT NULL ) RETURNS bigint
maludb_core.pool_add_observation( p_pool_id bigint, p_payload_jsonb jsonb, p_confidence numeric DEFAULT NULL, p_provenance jsonb DEFAULT NULL, p_access_label text DEFAULT NULL, p_account_id bigint DEFAULT NULL ) RETURNS bigint
maludb_core.pool_add_reference( p_pool_id bigint, p_member_kind text, p_member_object_type text, p_member_object_id bigint, p_confidence numeric DEFAULT NULL, p_provenance jsonb DEFAULT NULL, p_access_label text DEFAULT NULL, p_account_id bigint DEFAULT NULL ) RETURNS bigint
maludb_core.pool_add_reference( p_pool_id bigint, p_member_kind text, p_member_object_type text, p_member_object_id bigint, p_confidence numeric DEFAULT NULL, p_provenance jsonb DEFAULT NULL, p_access_label text DEFAULT NULL, p_account_id bigint DEFAULT NULL ) RETURNS bigint
maludb_core.pool_archive(p_pool_id bigint, p_reason text DEFAULT NULL) RETURNS void
maludb_core.pool_promote_to_claim( p_member_id bigint, p_subject text DEFAULT NULL, p_verb text DEFAULT NULL, p_object_value text DEFAULT NULL, p_statement_text text DEFAULT NULL, p_sensitivity text DEFAULT 'internal' ) RETURNS bigint
maludb_core.pool_promote_to_fact( p_member_id bigint, p_subject text DEFAULT NULL, p_verb text DEFAULT NULL, p_object_value text DEFAULT NULL, p_statement_text text DEFAULT NULL, p_verification_scope text DEFAULT NULL, p_verification_method text DEFAULT NULL, p_sensitivity text DEFAULT 'internal' ) RETURNS bigint
maludb_core.pool_seal(p_pool_id bigint, p_reason text DEFAULT NULL) RETURNS void
maludb_core.pool_search( p_pool_name text, p_query_text text DEFAULT NULL, p_limit integer DEFAULT 20, p_allow_fallback boolean DEFAULT false ) RETURNS TABLE (
maludb_core.pool_tombstone(p_pool_id bigint, p_reason text DEFAULT NULL) RETURNS void
maludb_core.presence_leave( p_pool_id bigint, p_participant_kind text, p_participant_ref text, p_reason text DEFAULT NULL ) RETURNS boolean
maludb_core.presence_list(p_pool_id bigint, p_include_left boolean DEFAULT false) RETURNS TABLE (
maludb_core.presence_sweep() RETURNS bigint
maludb_core.presence_update( p_pool_id bigint, p_participant_kind text, p_participant_ref text, p_role text DEFAULT NULL, p_declared_task text DEFAULT NULL, p_cursor_jsonb jsonb DEFAULT NULL ) RETURNS bigint
maludb_core.presence_update( p_pool_id bigint, p_participant_kind text, p_participant_ref text, p_role text DEFAULT NULL, p_declared_task text DEFAULT NULL, p_cursor_jsonb jsonb DEFAULT NULL, p_ttl_seconds integer DEFAULT NULL ) RETURNS bigint
maludb_core.preview_env_create( p_name text, p_base_migration text, p_seed_policy jsonb DEFAULT '{"production_data": false}'::jsonb, p_anonymizer_ref text DEFAULT NULL, p_description text DEFAULT NULL ) RETURNS bigint
maludb_core.preview_env_list(p_include_retired boolean DEFAULT false) RETURNS TABLE (
maludb_core.preview_env_promote_check(p_env_id bigint) RETURNS TABLE (gate text, ok boolean, detail text)
maludb_core.preview_env_record_seed( p_env_id bigint, p_source_kind text, p_source_ref text, p_redaction_rules jsonb DEFAULT '[]'::jsonb ) RETURNS bigint
maludb_core.preview_prompt( p_session_id bigint, p_template_name text, p_template_version integer DEFAULT NULL, p_variables jsonb DEFAULT '{}'::jsonb ) RETURNS TABLE(
maludb_core.promote_claim_to_fact_atomic( p_claim_ids bigint[], p_subject text DEFAULT NULL, p_verb text DEFAULT NULL, p_object_value text DEFAULT NULL, p_statement_text text DEFAULT NULL, p_verification_scope text DEFAULT NULL, p_verification_method text DEFAULT NULL, p_parser_name text DEFAULT NULL, p_verifier_name text DEFAULT NULL, p_inputs_jsonb jsonb DEFAULT NULL ) RETURNS bigint
maludb_core.propagate_staleness( p_source_type text, p_source_id bigint, p_reason text DEFAULT NULL ) RETURNS integer
maludb_core.propose_index_migration( p_source_space_id bigint, p_target_space_id bigint, p_index_kind text DEFAULT 'hnsw', p_notes text DEFAULT NULL ) RETURNS bigint
maludb_core.propose_pending_claim( p_connector_id bigint DEFAULT NULL, p_source_package_id bigint DEFAULT NULL, p_subject text DEFAULT NULL, p_verb text DEFAULT NULL, p_predicate text DEFAULT NULL, p_object_value text DEFAULT NULL, p_relationship text DEFAULT NULL, p_statement_text text DEFAULT NULL, p_statement_jsonb jsonb DEFAULT NULL, p_source_locator jsonb DEFAULT NULL, p_confidence numeric DEFAULT NULL, p_proposed_by text DEFAULT NULL, p_sensitivity text DEFAULT 'internal' ) RETURNS bigint
maludb_core.propose_workflow_candidate( p_cluster_id bigint, p_name text, p_description text DEFAULT NULL, p_step_template jsonb DEFAULT NULL ) RETURNS bigint
maludb_core.prune_object( p_target_object_type text, p_target_object_id bigint, p_reason text ) RETURNS void
maludb_core.queue_ack(p_job_id bigint) RETURNS boolean
maludb_core.queue_enqueue( p_queue_name text, p_payload jsonb, p_idempotency_key text DEFAULT NULL, p_priority integer DEFAULT 0, p_visible_at timestamptz DEFAULT NULL, p_account_id bigint DEFAULT NULL ) RETURNS bigint
maludb_core.queue_enqueue( p_queue_name text, p_payload jsonb, p_idempotency_key text DEFAULT NULL, p_priority integer DEFAULT 0, p_visible_at timestamptz DEFAULT NULL, p_account_id bigint DEFAULT NULL ) RETURNS bigint
maludb_core.queue_lease( p_queue_name text, p_worker_id text, p_batch integer DEFAULT 1, p_visibility_ms integer DEFAULT NULL ) RETURNS TABLE (job_id bigint, payload jsonb, attempts integer, enqueued_at timestamptz)
maludb_core.queue_nack(p_job_id bigint, p_error_text text DEFAULT NULL) RETURNS text
maludb_core.queue_reap_expired_leases() RETURNS integer
maludb_core.queue_register( p_name text, p_default_visibility_ms integer DEFAULT 30000, p_max_retries integer DEFAULT 3, p_dlq_name text DEFAULT NULL, p_description text DEFAULT NULL ) RETURNS bigint
maludb_core.queue_stats() RETURNS TABLE (
maludb_core.quick_add_note( p_title text, p_body_text text, p_projects text[] DEFAULT ARRAY[]::text[], p_subjects text[] DEFAULT ARRAY[]::text[], p_verbs text[] DEFAULT ARRAY[]::text[], p_svpor_frames jsonb DEFAULT '[]'::jsonb, p_metadata_jsonb jsonb DEFAULT '{}'::jsonb ) RETURNS bigint
maludb_core.r10_catalog_describe(args jsonb, context jsonb) RETURNS void
maludb_core.r10_context_append(args jsonb, context jsonb) RETURNS void
maludb_core.r10_context_read(args jsonb, context jsonb) RETURNS void
maludb_core.r10_health(args jsonb, context jsonb) RETURNS void
maludb_core.r10_memory_search_exact(args jsonb, context jsonb) RETURNS void
maludb_core.r10_memory_search_exact(args jsonb, context jsonb) RETURNS void
maludb_core.r10_models_list(args jsonb, context jsonb) RETURNS void
maludb_core.r10_models_submit(args jsonb, context jsonb) RETURNS void
maludb_core.r10_prompts_list(args jsonb, context jsonb) RETURNS void
maludb_core.r10_prompts_render(args jsonb, context jsonb) RETURNS void
maludb_core.r10_responses_get(args jsonb, context jsonb) RETURNS void
maludb_core.r10_sessions_create(args jsonb, context jsonb) RETURNS void
maludb_core.r10_sessions_get(args jsonb, context jsonb) RETURNS void
maludb_core.r10_skill_find(args jsonb, context jsonb) RETURNS void
maludb_core.r10_skill_fork(args jsonb, context jsonb) RETURNS void
maludb_core.r10_skill_get(args jsonb, context jsonb) RETURNS void
maludb_core.read_context(p_session_id bigint) RETURNS TABLE (
maludb_core.record_derivation( p_derived_object_type text, p_derived_object_id bigint, p_parser_name text DEFAULT NULL, p_model_alias_id bigint DEFAULT NULL, p_prompt_template_id bigint DEFAULT NULL, p_policy_name text DEFAULT NULL, p_verifier_name text DEFAULT NULL, p_model_request_id bigint DEFAULT NULL, p_inputs_jsonb jsonb DEFAULT '[]'::jsonb ) RETURNS bigint
maludb_core.record_local_model_capability( p_model_alias_id bigint, p_gpu_available boolean DEFAULT false, p_gpu_kind text DEFAULT NULL, p_vram_mb integer DEFAULT NULL, p_system_ram_mb integer DEFAULT NULL, p_supports_quantizations text[] DEFAULT ARRAY[]::text[], p_context_window integer DEFAULT NULL, p_max_batch_size integer DEFAULT NULL, p_typical_tokens_per_sec real DEFAULT NULL, p_platform_jsonb jsonb DEFAULT NULL ) RETURNS bigint
maludb_core.record_reinforcement( p_target_object_type text, p_target_object_id bigint, p_event_kind text, p_weight numeric DEFAULT 1.0, p_context_jsonb jsonb DEFAULT NULL ) RETURNS bigint
maludb_core.record_retrieval_envelope( p_envelope malu$retrieval_envelope_t, p_plan malu$retrieval_plan ) RETURNS bigint
maludb_core.register_claim( p_subject text DEFAULT NULL, p_verb text DEFAULT NULL, p_predicate text DEFAULT NULL, p_object_value text DEFAULT NULL, p_relationship text DEFAULT NULL, p_statement_text text DEFAULT NULL, p_statement_jsonb jsonb DEFAULT NULL, p_source_package_id bigint DEFAULT NULL, p_source_locator jsonb DEFAULT NULL, p_sensitivity text DEFAULT 'internal' ) RETURNS bigint
maludb_core.register_claim( p_subject text DEFAULT NULL, p_verb text DEFAULT NULL, p_predicate text DEFAULT NULL, p_object_value text DEFAULT NULL, p_relationship text DEFAULT NULL, p_statement_text text DEFAULT NULL, p_statement_jsonb jsonb DEFAULT NULL, p_source_package_id bigint DEFAULT NULL, p_source_locator jsonb DEFAULT NULL, p_sensitivity text DEFAULT 'internal' ) RETURNS bigint
maludb_core.register_connector( p_connector_name text, p_connector_kind text, p_source_type text, p_config_jsonb jsonb DEFAULT '{}'::jsonb, p_sensitivity text DEFAULT 'internal' ) RETURNS bigint
maludb_core.register_embedding_adapter( p_adapter_name text, p_source_space_id bigint, p_target_space_id bigint, p_adapter_kind text, p_params_jsonb jsonb DEFAULT '{}'::jsonb, p_evaluation jsonb DEFAULT NULL ) RETURNS bigint
maludb_core.register_embedding_space( p_space_name text, p_dimensions integer, p_normalization text DEFAULT 'cosine', p_model_alias_id bigint DEFAULT NULL, p_description text DEFAULT NULL ) RETURNS bigint
maludb_core.register_episode( p_episode_kind text, p_title text, p_summary text DEFAULT NULL, p_payload_jsonb jsonb DEFAULT '{}'::jsonb, p_occurred_at timestamptz DEFAULT NULL, p_occurred_until timestamptz DEFAULT NULL, p_sensitivity text DEFAULT 'internal' ) RETURNS bigint
maludb_core.register_episode( p_episode_kind text, p_title text, p_summary text DEFAULT NULL, p_payload_jsonb jsonb DEFAULT '{}'::jsonb, p_occurred_at timestamptz DEFAULT NULL, p_occurred_until timestamptz DEFAULT NULL, p_sensitivity text DEFAULT 'internal' ) RETURNS bigint
maludb_core.register_fact( p_claim_ids bigint[], p_subject text DEFAULT NULL, p_verb text DEFAULT NULL, p_predicate text DEFAULT NULL, p_object_value text DEFAULT NULL, p_relationship text DEFAULT NULL, p_statement_text text DEFAULT NULL, p_statement_jsonb jsonb DEFAULT NULL, p_verification_scope text DEFAULT NULL, p_verification_method text DEFAULT NULL, p_sensitivity text DEFAULT 'internal' ) RETURNS bigint
maludb_core.register_fact( p_claim_ids bigint[], p_subject text DEFAULT NULL, p_verb text DEFAULT NULL, p_predicate text DEFAULT NULL, p_object_value text DEFAULT NULL, p_relationship text DEFAULT NULL, p_statement_text text DEFAULT NULL, p_statement_jsonb jsonb DEFAULT NULL, p_verification_scope text DEFAULT NULL, p_verification_method text DEFAULT NULL, p_sensitivity text DEFAULT 'internal' ) RETURNS bigint
maludb_core.register_local_node( p_node_name text, p_fingerprint text, p_uri text DEFAULT NULL, p_description text DEFAULT NULL ) RETURNS bigint
maludb_core.register_local_node( p_node_name text, p_fingerprint text, p_uri text DEFAULT NULL, p_description text DEFAULT NULL ) RETURNS bigint
maludb_core.register_memory( p_memory_kind text, p_title text DEFAULT NULL, p_summary text DEFAULT NULL, p_payload_jsonb jsonb DEFAULT '{}'::jsonb, p_occurred_at timestamptz DEFAULT NULL, p_occurred_until timestamptz DEFAULT NULL, p_sensitivity text DEFAULT 'internal' ) RETURNS bigint
maludb_core.register_memory( p_memory_kind text, p_title text DEFAULT NULL, p_summary text DEFAULT NULL, p_payload_jsonb jsonb DEFAULT '{}'::jsonb, p_occurred_at timestamptz DEFAULT NULL, p_occurred_until timestamptz DEFAULT NULL, p_sensitivity text DEFAULT 'internal' ) RETURNS bigint
maludb_core.register_memory_detail( p_detail_kind text, p_parent_mdo_id bigint DEFAULT NULL, p_memory_id bigint DEFAULT NULL, p_episode_id bigint DEFAULT NULL, p_ordinal integer DEFAULT NULL, p_title text DEFAULT NULL, p_body_text text DEFAULT NULL, p_body_jsonb jsonb DEFAULT NULL, p_sensitivity text DEFAULT 'internal' ) RETURNS bigint
maludb_core.register_memory_detail( p_detail_kind text, p_parent_mdo_id bigint DEFAULT NULL, p_memory_id bigint DEFAULT NULL, p_episode_id bigint DEFAULT NULL, p_ordinal integer DEFAULT NULL, p_title text DEFAULT NULL, p_body_text text DEFAULT NULL, p_body_jsonb jsonb DEFAULT NULL, p_sensitivity text DEFAULT 'internal' ) RETURNS bigint
maludb_core.register_model_alias( p_alias text, p_provider text, p_model_identifier text, p_model_path text DEFAULT NULL, p_model_hash text DEFAULT NULL, p_quantization text DEFAULT NULL, p_context_length integer DEFAULT NULL, p_runtime_params jsonb DEFAULT NULL ) RETURNS bigint
maludb_core.register_model_in_registry( p_model_kind text, p_model_alias_id bigint DEFAULT NULL, p_embedding_space_id bigint DEFAULT NULL, p_derived_artifact_map jsonb DEFAULT '{}'::jsonb, p_notes text DEFAULT NULL ) RETURNS bigint
maludb_core.register_model_provider( p_name text, p_kind text, p_adapter_name text DEFAULT NULL, p_secret_ref text DEFAULT NULL, p_data_sensitivity text DEFAULT 'internal' ) RETURNS bigint
maludb_core.register_payload_schema( p_target_object_type text, p_schema_name text, p_schema_jsonb jsonb, p_description text DEFAULT NULL, p_enabled boolean DEFAULT true ) RETURNS bigint
maludb_core.register_prompt_template( p_name text, p_body text, p_owner_account text DEFAULT NULL, p_variables jsonb DEFAULT NULL, p_version integer DEFAULT NULL, p_system_template text DEFAULT NULL, p_developer_template text DEFAULT NULL, p_user_template text DEFAULT NULL ) RETURNS bigint
maludb_core.register_query_hint( p_hint_name text, p_hint_jsonb jsonb, p_description text DEFAULT NULL ) RETURNS bigint
maludb_core.register_relationship_edge( p_source_object_type text, p_source_object_id bigint, p_target_object_type text, p_target_object_id bigint, p_relationship_type text, p_label text DEFAULT NULL, p_edge_jsonb jsonb DEFAULT NULL, p_confidence numeric DEFAULT NULL ) RETURNS bigint
maludb_core.register_relationship_edge( p_source_object_type text, p_source_object_id bigint, p_target_object_type text, p_target_object_id bigint, p_relationship_type text, p_label text DEFAULT NULL, p_edge_jsonb jsonb DEFAULT NULL, p_confidence numeric DEFAULT NULL ) RETURNS bigint
maludb_core.register_skill( p_skill_name text, p_version text DEFAULT '1.0.0', p_description text DEFAULT NULL, p_packaging_kind text DEFAULT 'markdown', p_applicability_jsonb jsonb DEFAULT '{}'::jsonb, p_precondition_jsonb jsonb DEFAULT '[]'::jsonb ) RETURNS bigint
maludb_core.register_skill( p_skill_name text, p_version text DEFAULT '1.0.0', p_description text DEFAULT NULL, p_packaging_kind text DEFAULT 'markdown', p_applicability_jsonb jsonb DEFAULT '{}'::jsonb, p_precondition_jsonb jsonb DEFAULT '[]'::jsonb ) RETURNS bigint
maludb_core.register_source_package( p_source_type text, p_content_bytes bytea DEFAULT NULL, p_content_text text DEFAULT NULL, p_content_jsonb jsonb DEFAULT NULL, p_media_type text DEFAULT NULL, p_origin_jsonb jsonb DEFAULT NULL, p_captured_at timestamptz DEFAULT NULL, p_retention_class text DEFAULT 'standard', p_sensitivity text DEFAULT 'internal' ) RETURNS bigint
maludb_core.register_source_package( p_source_type text, p_content_bytes bytea DEFAULT NULL, p_content_text text DEFAULT NULL, p_content_jsonb jsonb DEFAULT NULL, p_media_type text DEFAULT NULL, p_origin_jsonb jsonb DEFAULT NULL, p_captured_at timestamptz DEFAULT NULL, p_retention_class text DEFAULT 'standard', p_sensitivity text DEFAULT 'internal' ) RETURNS bigint
maludb_core.register_storage_adapter( p_name text, p_kind text, p_config jsonb DEFAULT '{}'::jsonb, p_secret_ref text DEFAULT NULL, p_description text DEFAULT NULL ) RETURNS bigint
maludb_core.register_svpor_predicate( p_canonical_name text, p_aliases text[] DEFAULT ARRAY[]::text[], p_description text DEFAULT NULL ) RETURNS bigint
maludb_core.register_svpor_relationship( p_source_kind text, p_source_id bigint, p_target_kind text, p_target_id bigint, p_relationship_type text, p_label text DEFAULT NULL, p_edge_jsonb jsonb DEFAULT NULL, p_confidence numeric DEFAULT NULL ) RETURNS bigint
maludb_core.register_svpor_subject( p_canonical_name text, p_aliases text[] DEFAULT ARRAY[]::text[], p_description text DEFAULT NULL ) RETURNS bigint
maludb_core.register_svpor_subject( p_canonical_name text, p_aliases text[] DEFAULT ARRAY[]::text[], p_description text DEFAULT NULL, p_subject_type text DEFAULT 'concept' ) RETURNS bigint
maludb_core.register_svpor_subject( p_canonical_name text, p_aliases text[] DEFAULT ARRAY[]::text[], p_description text DEFAULT NULL, p_subject_type text DEFAULT 'other' ) RETURNS bigint
maludb_core.register_svpor_verb( p_canonical_name text, p_aliases text[] DEFAULT ARRAY[]::text[], p_description text DEFAULT NULL ) RETURNS bigint
maludb_core.register_svpor_verb( p_canonical_name text, p_aliases text[] DEFAULT ARRAY[]::text[], p_description text DEFAULT NULL, p_verb_type text DEFAULT NULL, p_search_phrases text[] DEFAULT ARRAY[]::text[] ) RETURNS bigint
maludb_core.register_vector_chunk( p_compartment_id bigint, p_source_text text, p_embedding bytea, p_embedding_model text DEFAULT NULL ) RETURNS bigint
maludb_core.register_vector_chunk( p_compartment_id bigint, p_source_text text, p_embedding malu_vector, p_embedding_model text DEFAULT NULL ) RETURNS bigint
maludb_core.register_vector_chunk( p_compartment_id bigint, p_source_text text, p_embedding malu_vector, p_embedding_model text DEFAULT NULL ) RETURNS bigint
maludb_core.register_vector_compartment( p_namespace text, p_subject_name text, p_verb_name text, p_embedding_dim integer, p_embedding_model text, p_distance_metric text DEFAULT 'cosine' ) RETURNS bigint
maludb_core.register_vector_subject(p_namespace text, p_subject_name text) RETURNS bigint
maludb_core.register_vector_verb(p_namespace text, p_verb_name text) RETURNS bigint
maludb_core.reingest_source_package( p_source_package_id bigint, p_verify boolean DEFAULT true ) RETURNS malu$reingest_result
maludb_core.reject_pending_claim( p_pending_claim_id bigint, p_reviewer text DEFAULT NULL, p_review_note text DEFAULT NULL, p_final_state text DEFAULT 'rejected' ) RETURNS void
maludb_core.render_prompt( p_session_id bigint, p_template_name text, p_template_version integer DEFAULT NULL, p_variables jsonb DEFAULT '{}'::jsonb ) RETURNS bigint
maludb_core.reopen_valid_window( p_object_type text, p_object_id bigint, p_reason text DEFAULT NULL ) RETURNS void
maludb_core.replay_episode( p_episode_id bigint, p_mode text DEFAULT 'current_valid', p_as_of timestamptz DEFAULT NULL ) RETURNS jsonb
maludb_core.request_review( p_template_name text, p_template_version integer DEFAULT NULL ) RETURNS bigint
maludb_core.request_status(p_request_id bigint) RETURNS text
maludb_core.resolve_svpor_predicate(p_text text) RETURNS bigint
maludb_core.resolve_svpor_subject(p_text text) RETURNS bigint
maludb_core.resolve_svpor_verb(p_text text) RETURNS bigint
maludb_core.response_cost(p_request_id bigint) RETURNS numeric
maludb_core.response_cost(p_request_id bigint) RETURNS numeric
maludb_core.response_cost(r malu$model_response) RETURNS numeric
maludb_core.response_cost(r malu$model_response) RETURNS numeric
maludb_core.response_error(p_request_id bigint) RETURNS text
maludb_core.response_error(r malu$model_response) RETURNS text
maludb_core.response_json(p_request_id bigint) RETURNS jsonb
maludb_core.response_json(r malu$model_response) RETURNS jsonb
maludb_core.response_text(p_request_id bigint) RETURNS text
maludb_core.response_text(r malu$model_response) RETURNS text
maludb_core.response_tokens(p_request_id bigint) RETURNS malu$response_tokens
maludb_core.response_tokens(r malu$model_response) RETURNS malu$response_tokens
maludb_core.rest_disable_endpoint(p_method text, p_path text, p_reason text DEFAULT NULL) RETURNS boolean
maludb_core.rest_list_endpoints(p_include_disabled boolean DEFAULT false) RETURNS TABLE (
maludb_core.rest_log_invocation( p_endpoint_id bigint, p_account_id bigint, p_token_id bigint, p_method text, p_path text, p_request_user text, p_source_ip inet, p_request_hash bytea, p_response_hash bytea, p_status_code smallint, p_latency_ms integer, p_started_at timestamptz, p_finished_at timestamptz, p_success boolean, p_error_code text DEFAULT NULL, p_error_message text DEFAULT NULL ) RETURNS uuid
maludb_core.rest_openapi_spec() RETURNS jsonb
maludb_core.rest_register_endpoint( p_method text, p_path text, p_handler regprocedure, p_description text DEFAULT NULL, p_required_scopes text[] DEFAULT ARRAY[]::text[], p_risk_class text DEFAULT 'read_only', p_openapi_spec jsonb DEFAULT '{}'::jsonb, p_auth_required boolean DEFAULT true, p_timeout_ms integer DEFAULT 30000, p_max_input_bytes integer DEFAULT 1048576, p_max_output_bytes integer DEFAULT 10485760 ) RETURNS bigint
maludb_core.rest_register_endpoint( p_method text, p_path text, p_handler regprocedure, p_description text DEFAULT NULL, p_required_scopes text[] DEFAULT ARRAY[]::text[], p_risk_class text DEFAULT 'read_only', p_openapi_spec jsonb DEFAULT '{}'::jsonb, p_auth_required boolean DEFAULT true, p_timeout_ms integer DEFAULT 30000, p_max_input_bytes integer DEFAULT 1048576, p_max_output_bytes integer DEFAULT 10485760, p_arg_schema jsonb DEFAULT '[]'::jsonb ) RETURNS bigint
maludb_core.retention_candidates( p_target_object_type text, p_cutoff timestamptz DEFAULT now() ) RETURNS TABLE (
maludb_core.retract_fact( p_fact_id bigint, p_reason text ) RETURNS void
maludb_core.retrieve_envelope_debug(p_envelope_id bigint) RETURNS TABLE (
maludb_core.retrieve_with_envelope( p_cue_text text, p_object_types text[] DEFAULT NULL, p_valid_as_of timestamptz DEFAULT NULL, p_transaction_as_of timestamptz DEFAULT NULL, p_confidence_floor numeric DEFAULT NULL, p_hints jsonb DEFAULT '{}'::jsonb, p_partitions text[] DEFAULT ARRAY[]::text[], p_hint_name text DEFAULT NULL, p_limit integer DEFAULT 20, p_temporal_mode text DEFAULT 'current_valid' ) RETURNS SETOF malu$retrieval_hit
maludb_core.retrieve_with_envelope_chat_tree( p_cue_text text, p_chat_tree_id bigint, p_descent_options jsonb DEFAULT '{}'::jsonb, p_limit integer DEFAULT 1 ) RETURNS TABLE (
maludb_core.retrieve_with_envelope_tree( p_cue_text text, p_tree_id bigint, p_descent_options jsonb DEFAULT '{}'::jsonb, p_limit integer DEFAULT 1 ) RETURNS TABLE (
maludb_core.review_workflow_candidate( p_candidate_id bigint, p_status text, p_notes text DEFAULT NULL ) RETURNS void
maludb_core.revoke_local_node( p_node_id bigint, p_reason text ) RETURNS void
maludb_core.revoke_object_grant( p_grant_id bigint, p_reason text DEFAULT NULL ) RETURNS void
maludb_core.revoke_object_grant( p_grant_id bigint, p_reason text DEFAULT NULL ) RETURNS void
maludb_core.route_query( p_model_kind text DEFAULT 'embedding' ) RETURNS jsonb
maludb_core.run_session_step( p_session_id bigint, p_template_name text, p_alias_name text, p_variables jsonb DEFAULT '{}'::jsonb, p_template_version integer DEFAULT NULL, p_account_name text DEFAULT NULL, p_generation_params jsonb DEFAULT '{}'::jsonb, p_timeout_ms integer DEFAULT 30000 ) RETURNS TABLE (
maludb_core.schedule_create( p_name text, p_cron_expr text, p_action_kind text, p_action_payload jsonb, p_description text DEFAULT NULL, p_enabled boolean DEFAULT true ) RETURNS bigint
maludb_core.schedule_disable(p_name text, p_reason text DEFAULT NULL) RETURNS boolean
maludb_core.schedule_enable(p_name text) RETURNS boolean
maludb_core.schedule_list(p_include_disabled boolean DEFAULT false) RETURNS TABLE (
maludb_core.schedule_run_now(p_name text) RETURNS bigint
maludb_core.schedule_tick() RETURNS integer
maludb_core.seal_source_package( p_source_package_id bigint, p_placement_tier text DEFAULT 'inline', p_external_uri text DEFAULT NULL, p_note text DEFAULT NULL ) RETURNS bigint
maludb_core.seal_source_package( p_source_package_id bigint, p_placement_tier text DEFAULT 'inline', p_external_uri text DEFAULT NULL, p_note text DEFAULT NULL ) RETURNS bigint
maludb_core.search_memory_exact( p_namespace text, p_subject text, p_verb text, p_query bytea, p_limit integer DEFAULT 10, p_metric text DEFAULT NULL ) RETURNS TABLE (
maludb_core.search_memory_exact( p_namespace text, p_subject text, p_verb text, p_query malu_vector, p_limit integer DEFAULT 10, p_metric text DEFAULT NULL ) RETURNS TABLE (
maludb_core.search_memory_filter( p_namespace text, p_subject text, p_verb text, p_query malu_vector, p_metadata_filter jsonb, p_limit integer DEFAULT 10, p_metric text DEFAULT NULL ) RETURNS TABLE (
maludb_core.secret_get_metadata(p_name text) RETURNS TABLE (
maludb_core.secret_revoke(p_name text, p_reason text DEFAULT NULL) RETURNS boolean
maludb_core.secret_set( p_name text, p_kind text, p_value text, p_description text DEFAULT NULL, p_rotation_policy_days integer DEFAULT NULL ) RETURNS TABLE (secret_id bigint, secret_version_id bigint, version integer)
maludb_core.secret_set_external( p_name text, p_kind text, p_external_ref text, p_description text DEFAULT NULL, p_rotation_policy_days integer DEFAULT NULL ) RETURNS TABLE (secret_id bigint, secret_version_id bigint, version integer)
maludb_core.select_search_paths( p_intent text, p_envelope malu$retrieval_envelope_t, p_cues_jsonb jsonb ) RETURNS jsonb
maludb_core.select_search_paths( p_intent text, p_envelope malu$retrieval_envelope_t, p_cues_jsonb jsonb ) RETURNS jsonb
maludb_core.set_lifecycle_policy( p_target_object_type text, p_decay_half_life_days integer DEFAULT 90, p_archive_after_idle_days integer DEFAULT NULL, p_retain_for_days integer DEFAULT NULL, p_autotombstone_enabled boolean DEFAULT false ) RETURNS bigint
maludb_core.set_maut_score( p_target_object_type text, p_target_object_id bigint, p_category text, p_subscore numeric, p_evaluator_name text, p_evaluator_kind text DEFAULT 'manual', p_evaluator_meta jsonb DEFAULT NULL, p_evidence jsonb DEFAULT NULL ) RETURNS bigint
maludb_core.skill_emit_claim( p_execution_id bigint, p_claim_id bigint ) RETURNS void
maludb_core.source_object_add_reference( p_object_id bigint, p_kind text, p_value_jsonb jsonb, p_note text DEFAULT NULL ) RETURNS bigint
maludb_core.source_object_lookup_by_hash(p_content_hash bytea) RETURNS bigint
maludb_core.source_object_metadata(p_object_id bigint) RETURNS TABLE (
maludb_core.source_object_promote_to_source_package( p_object_id bigint, p_source_type text, p_content_bytes bytea DEFAULT NULL, p_content_text text DEFAULT NULL, p_content_jsonb jsonb DEFAULT NULL, p_origin_jsonb jsonb DEFAULT NULL, p_captured_at timestamptz DEFAULT NULL ) RETURNS bigint
maludb_core.source_object_register( p_adapter_name text, p_adapter_uri text, p_content_hash bytea, p_byte_length bigint, p_media_type text DEFAULT NULL, p_source_time timestamptz DEFAULT NULL, p_retention_class text DEFAULT 'standard', p_sensitivity text DEFAULT 'internal', p_partition text DEFAULT NULL ) RETURNS bigint
maludb_core.source_object_register( p_adapter_name text, p_adapter_uri text, p_content_hash bytea, p_byte_length bigint, p_media_type text DEFAULT NULL, p_source_time timestamptz DEFAULT NULL, p_retention_class text DEFAULT 'standard', p_sensitivity text DEFAULT 'internal', p_partition text DEFAULT NULL ) RETURNS bigint
maludb_core.source_object_set_legal_hold( p_object_id bigint, p_hold boolean, p_reason text DEFAULT NULL ) RETURNS boolean
maludb_core.source_package_promote_to_chat_index( p_source_package_id bigint, p_model_alias_id bigint DEFAULT NULL, p_prompt_template_id bigint DEFAULT NULL, p_max_children integer DEFAULT 10, p_builder_options jsonb DEFAULT '{}'::jsonb ) RETURNS bigint
maludb_core.source_package_promote_to_page_index( p_source_package_id bigint, p_parser_kind text, p_model_alias_id bigint DEFAULT NULL, p_prompt_template_id bigint DEFAULT NULL, p_builder_options jsonb DEFAULT '{}'::jsonb ) RETURNS bigint
maludb_core.stage_boundary_violations() RETURNS TABLE(object_kind text, object_name text, stage smallint)
maludb_core.stage_boundary_violations() RETURNS TABLE(object_kind text, object_name text, stage smallint)
maludb_core.stage_boundary_violations() RETURNS TABLE(object_kind text, object_name text, stage smallint)
maludb_core.stage_boundary_violations() RETURNS TABLE(object_kind text, object_name text, stage smallint)
maludb_core.stage_boundary_violations() RETURNS TABLE(object_kind text, object_name text, stage smallint)
maludb_core.stage_boundary_violations() RETURNS TABLE(object_kind text, object_name text, stage smallint)
maludb_core.stage_boundary_violations() RETURNS TABLE(object_kind text, object_name text, stage smallint)
maludb_core.stage_boundary_violations() RETURNS TABLE(object_kind text, object_name text, stage smallint)
maludb_core.stage_boundary_violations() RETURNS TABLE(object_kind text, object_name text, stage smallint)
maludb_core.stage_boundary_violations() RETURNS TABLE(object_kind text, object_name text, stage smallint)
maludb_core.stage_boundary_violations() RETURNS TABLE(object_kind text, object_name text, stage smallint)
maludb_core.stage_boundary_violations() RETURNS TABLE(object_kind text, object_name text, stage smallint)
maludb_core.start_session( p_account_name text, p_alias_name text DEFAULT NULL, p_template_name text DEFAULT NULL, p_template_version integer DEFAULT NULL, p_token_budget integer DEFAULT NULL ) RETURNS bigint
maludb_core.step_skill_execution( p_execution_id bigint, p_outcome text, p_observation_jsonb jsonb DEFAULT NULL ) RETURNS text
maludb_core.submit_render( p_render_id bigint, p_alias_name text, p_account_name text DEFAULT NULL, p_generation_params jsonb DEFAULT '{}'::jsonb, p_timeout_ms integer DEFAULT 30000 ) RETURNS bigint
maludb_core.submit_render( p_render_id bigint, p_alias_name text, p_account_name text DEFAULT NULL, p_generation_params jsonb DEFAULT '{}'::jsonb, p_timeout_ms integer DEFAULT 30000 ) RETURNS bigint
maludb_core.submit_render( p_render_id bigint, p_alias_name text, p_account_name text DEFAULT NULL, p_generation_params jsonb DEFAULT '{}'::jsonb, p_timeout_ms integer DEFAULT 30000, p_cache_mode text DEFAULT 'off' ) RETURNS bigint
maludb_core.submit_render( p_render_id bigint, p_alias_name text, p_account_name text DEFAULT NULL, p_generation_params jsonb DEFAULT '{}'::jsonb, p_timeout_ms integer DEFAULT 30000, p_cache_mode text DEFAULT 'off', p_idempotency_key text DEFAULT NULL ) RETURNS bigint
maludb_core.submit_render( p_render_id bigint, p_alias_name text, p_account_name text DEFAULT NULL, p_generation_params jsonb DEFAULT '{}'::jsonb, p_timeout_ms integer DEFAULT 30000, p_cache_mode text DEFAULT 'off', p_idempotency_key text DEFAULT NULL ) RETURNS bigint
maludb_core.submit_request( p_alias_name text, p_rendered_prompt text, p_account_name text DEFAULT NULL, p_session_id bigint DEFAULT NULL, p_generation_params jsonb DEFAULT '{}'::jsonb, p_timeout_ms integer DEFAULT 30000 ) RETURNS bigint
maludb_core.svpor_frame_text( p_subject text, p_verb text, p_predicate text DEFAULT NULL, p_object_value text DEFAULT NULL ) RETURNS text
maludb_core.text_search( p_query text, p_object_types text[] DEFAULT ARRAY['claim','fact','memory','episode_object'], p_limit integer DEFAULT 20 ) RETURNS TABLE (
maludb_core.text_search( p_query text, p_object_types text[] DEFAULT ARRAY['claim','fact','memory','episode_object'], p_limit integer DEFAULT 20 ) RETURNS TABLE (
maludb_core.tombstone_source_package( p_source_package_id bigint, p_reason text ) RETURNS void
maludb_core.tombstone_source_package( p_source_package_id bigint, p_reason text ) RETURNS void
maludb_core.tombstone_vector_chunk(p_chunk_id bigint) RETURNS void
maludb_core.topk_vector_combine(internal, internal) RETURNS internal
maludb_core.topk_vector_deserialize(bytea, internal) RETURNS internal
maludb_core.topk_vector_finalize(internal) RETURNS jsonb
maludb_core.topk_vector_serialize(internal) RETURNS bytea
maludb_core.topk_vector_sfunc( state internal, embedding malu_vector, chunk_id bigint, source_text text, query malu_vector, k integer, metric text ) RETURNS internal
maludb_core.tree_descent_retrieve( p_envelope_id bigint, p_tree_id bigint, p_descent_options jsonb DEFAULT '{}'::jsonb ) RETURNS TABLE (
maludb_core.unseal_source_package( p_source_package_id bigint, p_reason text ) RETURNS void
maludb_core.unseal_source_package( p_source_package_id bigint, p_reason text ) RETURNS void
maludb_core.upload_document( p_title text, p_content_text text, p_source_type text DEFAULT 'document', p_content_jsonb jsonb DEFAULT NULL, p_media_type text DEFAULT NULL, p_projects text[] DEFAULT ARRAY[]::text[], p_subjects text[] DEFAULT ARRAY[]::text[], p_verbs text[] DEFAULT ARRAY[]::text[], p_events text[] DEFAULT ARRAY[]::text[], p_metadata_jsonb jsonb DEFAULT '{}'::jsonb ) RETURNS bigint
maludb_core.usage_today( p_scope text, p_scope_account_id bigint, p_scope_template_id bigint, p_scope_role text, p_limit_kind text ) RETURNS numeric
maludb_core.validate_payload( p_target_object_type text, p_schema_name text, p_instance jsonb ) RETURNS text[]
maludb_core.vector_dims(bytea) RETURNS integer
maludb_core.vector_dims(malu_vector) RETURNS integer
maludb_core.vector_dot_product(bytea, bytea) RETURNS double precision
maludb_core.vector_dot_product(malu_vector, malu_vector) RETURNS double precision
maludb_core.vector_from_real_array(real[]) RETURNS bytea
maludb_core.vector_from_real_array(real[]) RETURNS malu_vector
maludb_core.vector_index_record( p_compartment_id bigint, p_kind text, p_build_finished boolean DEFAULT true, p_delta_count bigint DEFAULT 0, p_tombstone_count bigint DEFAULT 0, p_recall_sample jsonb DEFAULT NULL ) RETURNS bigint
maludb_core.vector_index_status() RETURNS TABLE (
maludb_core.vector_l2_squared(bytea, bytea) RETURNS double precision
maludb_core.vector_l2_squared(malu_vector, malu_vector) RETURNS double precision
maludb_core.vector_norm(bytea) RETURNS double precision
maludb_core.vector_norm(malu_vector) RETURNS double precision
maludb_core.vector_normalize(bytea) RETURNS bytea
maludb_core.vector_normalize(malu_vector) RETURNS malu_vector
maludb_core.vector_search_by_tags( p_namespace text DEFAULT 'default', p_subject text DEFAULT NULL, p_verb text DEFAULT NULL, p_query_embedding malu_vector DEFAULT NULL, p_limit integer DEFAULT 20, p_metric text DEFAULT NULL ) RETURNS TABLE (
maludb_core.vector_to_real_array(bytea) RETURNS real[]
maludb_core.vector_to_real_array(malu_vector) RETURNS real[]
maludb_core.verb_phrase_search(p_query text) RETURNS TABLE (
maludb_core.verify_source_hash( p_source_package_id bigint, p_context_note text DEFAULT NULL ) RETURNS malu$verify_result
mc2db._begin_request(p_call_id uuid, p_tool_name text) RETURNS void
mc2db._end_request() RETURNS TABLE(call_id uuid, tool_name text, payload jsonb,
mc2db._ensure_active_table() RETURNS void
mc2db._require_active() RETURNS void
mc2db.create_server( name text, title text DEFAULT NULL, description text DEFAULT NULL, protocol_versions text[] DEFAULT ARRAY['2025-11-25'], default_risk_class text DEFAULT 'read_only' ) RETURNS bigint
mc2db.register_prompt( server_name text, prompt_name text, description text DEFAULT NULL, title text DEFAULT NULL, input_schema jsonb DEFAULT NULL, function_signature text DEFAULT NULL ) RETURNS bigint
mc2db.register_resource( server_name text, uri_template text, description text DEFAULT NULL, title text DEFAULT NULL, mime_type text DEFAULT 'application/json', function_signature text DEFAULT NULL ) RETURNS bigint
mc2db.register_tool( server_name text, tool_name text, description text, implementation_type text, input_schema jsonb DEFAULT '{}'::jsonb, output_schema jsonb DEFAULT NULL, title text DEFAULT NULL, risk_class text DEFAULT 'read_only', read_only boolean DEFAULT true, require_confirmation boolean DEFAULT false, timeout_ms integer DEFAULT 10000, max_input_bytes integer DEFAULT 262144, max_output_bytes integer DEFAULT 1048576, allow_network boolean DEFAULT false, required_privileges text[] DEFAULT ARRAY[]::text[], impl_metadata jsonb DEFAULT '{}'::jsonb ) RETURNS bigint
mc2db.register_tool( server_name text, tool_name text, description text, implementation_type text, input_schema jsonb DEFAULT '{}'::jsonb, output_schema jsonb DEFAULT NULL, title text DEFAULT NULL, risk_class text DEFAULT 'read_only', read_only boolean DEFAULT true, require_confirmation boolean DEFAULT false, timeout_ms integer DEFAULT 10000, max_input_bytes integer DEFAULT 262144, max_output_bytes integer DEFAULT 1048576, allow_network boolean DEFAULT false, required_privileges text[] DEFAULT ARRAY[]::text[], impl_metadata jsonb DEFAULT '{}'::jsonb ) RETURNS bigint
```

## 5. Triggers

```
CREATE TRIGGER source_package_seal_lock_tg BEFORE UPDATE ON malu$source_package FOR EACH ROW EXECUTE FUNCTION _source_package_seal_lock();
CREATE TRIGGER memory_payload_validate_tg BEFORE INSERT OR UPDATE OF payload_jsonb, memory_kind ON malu$memory FOR EACH ROW EXECUTE FUNCTION _payload_validate_memory();
CREATE TRIGGER episode_payload_validate_tg BEFORE INSERT OR UPDATE OF payload_jsonb, episode_kind ON malu$episode_object FOR EACH ROW EXECUTE FUNCTION _payload_validate_episode();
CREATE TRIGGER mdo_payload_validate_tg BEFORE INSERT OR UPDATE OF body_jsonb, detail_kind ON malu$memory_detail_object FOR EACH ROW EXECUTE FUNCTION _payload_validate_mdo();
CREATE TRIGGER claim_payload_validate_tg BEFORE INSERT OR UPDATE OF statement_jsonb ON malu$claim FOR EACH ROW EXECUTE FUNCTION _payload_validate_claim();
CREATE TRIGGER fact_payload_validate_tg BEFORE INSERT OR UPDATE OF statement_jsonb ON malu$fact FOR EACH ROW EXECUTE FUNCTION _payload_validate_fact();
CREATE TRIGGER source_package_payload_validate_tg BEFORE INSERT OR UPDATE OF origin_jsonb, source_type ON malu$source_package FOR EACH ROW EXECUTE FUNCTION _payload_validate_source_package();
CREATE TRIGGER claim_svpor_resolve_tg BEFORE INSERT OR UPDATE OF subject, verb, predicate ON malu$claim FOR EACH ROW EXECUTE FUNCTION _svpor_auto_resolve();
CREATE TRIGGER fact_svpor_resolve_tg BEFORE INSERT OR UPDATE OF subject, verb, predicate ON malu$fact FOR EACH ROW EXECUTE FUNCTION _svpor_auto_resolve();
CREATE TRIGGER svpor_subject_normalize_type_tg BEFORE INSERT OR UPDATE OF subject_type ON maludb_core.malu$svpor_subject FOR EACH ROW EXECUTE FUNCTION maludb_core._svpor_subject_normalize_type_tg();
CREATE TRIGGER svpor_verb_normalize_type_tg BEFORE INSERT OR UPDATE OF verb_type, canonical_name ON maludb_core.malu$svpor_verb FOR EACH ROW EXECUTE FUNCTION maludb_core._svpor_verb_normalize_type_tg();
CREATE TRIGGER svpor_subject_relationship_set_labels_tg BEFORE INSERT OR UPDATE OF owner_schema, subject_a_id, subject_b_id ON maludb_core.malu$svpor_subject_relationship FOR EACH ROW EXECUTE FUNCTION maludb_core._svpor_subject_relationship_set_labels_tg();
CREATE TRIGGER svpor_subject_relationship_refresh_label_tg AFTER UPDATE OF canonical_name ON maludb_core.malu$svpor_subject FOR EACH ROW WHEN (OLD.canonical_name IS DISTINCT FROM NEW.canonical_name) EXECUTE FUNCTION maludb_core._svpor_subject_relationship_refresh_label_tg();
```

## 6. Per-schema facade API (created dynamically by `enable_memory_schema`)

When memory is enabled on a user schema, these objects are created **inside that schema** (shown below without the schema prefix). 
This is the public, application-facing surface.


### Facade views (56)

- `maludb_chat_message`
- `maludb_chat_session`
- `maludb_claim`
- `maludb_document`
- `maludb_document_suggested_tag`
- `maludb_document_svpor_hint`
- `maludb_document_tag`
- `maludb_fact`
- `maludb_llm_model`
- `maludb_llm_provider`
- `maludb_llm_request`
- `maludb_llm_response`
- `maludb_mcp_invocation`
- `maludb_mcp_prompt`
- `maludb_mcp_resource`
- `maludb_mcp_server`
- `maludb_mcp_tool`
- `maludb_memory`
- `maludb_memory_detail`
- `maludb_memory_pool`
- `maludb_memory_pool_access`
- `maludb_memory_pool_member`
- `maludb_memory_pool_tag`
- `maludb_person`
- `maludb_pool_document`
- `maludb_pool_presence`
- `maludb_pool_skill`
- `maludb_pool_subject`
- `maludb_pool_subject_verb`
- `maludb_pool_verb`
- `maludb_project`
- `maludb_prompt`
- `maludb_prompt_render`
- `maludb_raw_ingest`
- `maludb_related_subject`
- `maludb_skill`
- `maludb_skill_access`
- `maludb_skill_embedding`
- `maludb_skill_execution`
- `maludb_skill_keyword`
- `maludb_skill_state`
- `maludb_skill_subject`
- `maludb_skill_transition`
- `maludb_skill_verb`
- `maludb_source_package`
- `maludb_stakeholder`
- `maludb_subject`
- `maludb_subject_type`
- `maludb_subject_verb`
- `maludb_svpor_relationship`
- `maludb_unapplied_ingest`
- `maludb_verb`
- `maludb_verb_type`
- `maludb_workflow_candidate`
- `maludb_workflow_step`
- `maludb_workflow_trace`

### Facade functions (20)

- `maludb_chat_append_message(...)`
- `maludb_chat_finalize(...)`
- `maludb_chat_get(...)`
- `maludb_chat_messages(...)`
- `maludb_chat_start(...)`
- `maludb_document_get(...)`
- `maludb_pool_add_named_member(...)`
- `maludb_pool_search(...)`
- `maludb_quick_add_note(...)`
- `maludb_related_subject_add(...)`
- `maludb_related_subject_delete(...)`
- `maludb_related_subjects(...)`
- `maludb_skill_fork(...)`
- `maludb_skill_get(...)`
- `maludb_skill_search(...)`
- `maludb_subject_verb_create(...)`
- `maludb_svpor_relationship_create(...)`
- `maludb_upload_document(...)`
- `maludb_vector_search(...)`
- `maludb_verb_phrase_search(...)`