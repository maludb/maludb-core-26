# MaluDB Post-Install Hardening Guide

Bootstrap (`scripts/maludb-bootstrap`) gets you to a *working* install.
This guide covers the steps to take *after* that — for any deployment
that is going to face network traffic, real users, or auditors.

> **Audience.** Operators putting MaluDB behind real load. If you are
> just running the field-test playbook or a development install, the
> bootstrap defaults are deliberately convenient (SUPERUSER on the
> operator role, plain-HTTP listener bound to `127.0.0.1`,
> bearer-token auth disabled). Lock those down per the steps below
> before exposing the service.

The guide is grouped by concern. Apply the items relevant to your
deployment posture.

---

## 1. PostgreSQL roles

### 1.1 Drop SUPERUSER from the operator role

Bootstrap grants `SUPERUSER` to the human operator (the user who ran
`sudo ./scripts/maludb-bootstrap`). This is convenient for running
`make installcheck` — pg_regress needs `ALTER DATABASE ... SET
lc_messages` which is a SUSET parameter — but it's an over-broad
production privilege.

If you don't plan to run pg_regress on the production host:

```bash
sudo -u postgres psql -c "ALTER ROLE <your-username> NOSUPERUSER;"
```

The operator can still run the validate script, query `malu$mc2db_invocation`
and `malu$model_response` for audit, etc. — bootstrap also granted
the operator full DML on the maludb-realm schemas.

### 1.2 Verify the service-role privilege boundary

Confirm `maludb_mc2dbd` has only what the listener needs:

```bash
sudo -u postgres psql -d maludb -c "
SELECT table_name, privilege_type
FROM information_schema.role_table_grants
WHERE grantee='maludb_mc2dbd'
  AND table_schema='maludb_core'
ORDER BY table_name, privilege_type;
"
```

Expected: SELECT on every `malu$*` table; INSERT/UPDATE/DELETE on the
nine catalog tables that R1.0 tools write to (account, session,
session_context, prompt_render, model_request, model_response,
model_provider, model_alias, prompt_template); INSERT only on
`malu$mc2db_invocation`. No row in this output should reference
`malu$svpor_*` or any Stage 2+ memory-object table — those don't
exist in R1.0.

`maludb_modeld` should have a separate, narrower set: SELECT on
`malu$model_request`, `malu$model_alias`, `malu$model_provider`;
UPDATE on `malu$model_request`; INSERT on `malu$model_response`.

---

## 2. Listener (maludb_mc2dbd)

### 2.1 Enable bearer-token auth

The default install accepts unauthenticated requests. Generate a
strong token and require it on every request:

```bash
TOKEN=$(openssl rand -base64 48)
echo "Save this somewhere safe: $TOKEN"

sudoedit /etc/maludb/maludb-mc2dbd.conf
# uncomment / set:
#   BEARER_TOKEN="<paste $TOKEN>"

sudo systemctl restart maludb-mc2dbd

# Clients now need:
curl -fsS -X POST https://your-host:5329/ \
    -H "Authorization: Bearer $TOKEN" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize"}'
```

For multi-client deployments, rotate this token on a schedule and
manage it via your secrets store, not directly in the conf.

### 2.2 Replace the self-signed TLS cert

Bootstrap generates a self-signed cert at `/etc/maludb/tls/server.{crt,key}`
with 365-day validity. For production, replace with one issued by a
real CA (Let's Encrypt is the common path).

Two patterns:

**Pattern A — terminate TLS at the listener.**

Replace the cert files in place, restart:

```bash
sudo install -m 0640 -o maludb_mc2dbd -g maludb \
    /path/to/your/server.crt /etc/maludb/tls/server.crt
sudo install -m 0640 -o maludb_mc2dbd -g maludb \
    /path/to/your/server.key /etc/maludb/tls/server.key

sudoedit /etc/maludb/maludb-mc2dbd.conf
# set:
#   TLS=true
#   TLS_CERT=/etc/maludb/tls/server.crt
#   TLS_KEY=/etc/maludb/tls/server.key

sudo systemctl restart maludb-mc2dbd

curl -fsS https://your-host:5329/healthz
```

For Let's Encrypt, the cert renews periodically — set up a `certbot`
deploy hook that copies the new cert into `/etc/maludb/tls/` and
restarts the listener.

**Pattern B — terminate TLS at NGINX, listener stays plain HTTP on `127.0.0.1`.**

```nginx
server {
    listen 443 ssl http2;
    server_name maludb.example.com;
    ssl_certificate     /etc/letsencrypt/live/maludb.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/maludb.example.com/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:5329;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $remote_addr;
        # Optional: pass through the bearer-token unchanged
        proxy_set_header Authorization $http_authorization;
        # Optional: identify the requesting account in audit logs
        proxy_set_header X-MaluDB-User $remote_user;
    }
}
```

This pattern keeps cert lifecycle out of MaluDB's process and
matches typical NGINX-fronted Postgres-extension deployments.

### 2.3 Bind the listener correctly for your network

The default is `127.0.0.1:5329`. To accept off-host traffic:

```bash
sudoedit /etc/maludb/maludb-mc2dbd.conf
# set:
#   HOST=0.0.0.0      # or a specific routable interface
sudo systemctl restart maludb-mc2dbd
```

**Only do this with TLS and bearer-token auth both on.** Plain-HTTP
on a routable address with no auth is an open MCP gateway into your
database; assume it will be discovered.

### 2.4 Firewall

Configure `ufw` to allow only the source ranges you trust:

```bash
sudo ufw allow from 10.0.0.0/8 to any port 5329 proto tcp
sudo ufw allow from 192.168.0.0/16 to any port 5329 proto tcp
sudo ufw enable
```

For NGINX-fronted deployments, allow `443/tcp` instead and keep
`5329/tcp` localhost-only.

---

## 3. Model gateway (maludb_modeld)

### 3.1 Lock down model paths

`/etc/maludb/maludb-modeld.conf` ships pointing at
`/usr/local/bin/llama-cli`. The gguf model file is registered against
each alias via `register_model_alias(..., p_model_path => ...)`.

In production, store models under a path with appropriate ownership:

```bash
sudo install -d -o maludb_modeld -g maludb /var/lib/maludb/models
sudo chmod 0750 /var/lib/maludb/models
# Place gguf files here, owned by maludb_modeld:maludb, mode 0640
```

The systemd unit's `ProtectHome=true` already blocks `/home/*` access,
which means models stored in any operator's home directory will fail
to load (we hit this during R1.0-10 field test). Keep models under
`/var/lib/maludb/models/` or other system paths.

### 3.2 Set realistic timeouts

```bash
sudoedit /etc/maludb/maludb-modeld.conf
# DEFAULT_TIMEOUT=300              # 5 min cap; tune for your model size
# MAX_PROMPT_CHARS=200000          # reject prompts beyond this
```

### 3.3 cloud_api adapters not yet supported

R1.0 dispatches `local_runtime` only. `cloud_api` aliases get a
structured failure response. Don't register cloud aliases for
production use until R1.1-X ships those adapters; they'll always
fail.

---

## 4. Logs and audit

### 4.1 Where logs land

| Component | Log destination |
|---|---|
| PostgreSQL | `/var/log/postgresql/postgresql-17-main.log` |
| `maludb-mc2dbd` | `journalctl -u maludb-mc2dbd` |
| `maludb-modeld` | `journalctl -u maludb-modeld` |
| MC2DB tool calls (audit) | `maludb_core.malu$mc2db_invocation` |
| Model run audit (DB view) | `maludb_core.model_run_audit` |

### 4.2 Audit retention

`malu$mc2db_invocation` grows without bound. For long-running
deployments, set up periodic archive + truncate:

```sql
-- Move rows older than 90 days to an archive table
CREATE TABLE IF NOT EXISTS maludb_core.malu$mc2db_invocation_archive
    (LIKE maludb_core.malu$mc2db_invocation INCLUDING ALL);

WITH moved AS (
    DELETE FROM maludb_core.malu$mc2db_invocation
    WHERE started_at < now() - interval '90 days'
    RETURNING *
)
INSERT INTO maludb_core.malu$mc2db_invocation_archive
SELECT * FROM moved;
```

Run as a scheduled job (cron, pg_cron, or your scheduler of choice).

### 4.3 systemd journal retention

By default, systemd journals can fill the disk. Cap them:

```bash
sudoedit /etc/systemd/journald.conf
# set:
#   SystemMaxUse=2G
#   SystemKeepFree=10G
sudo systemctl restart systemd-journald
```

---

## 5. Backups

R1.0 has no backup automation — backup is your existing PG infra
layer. At minimum:

- `pg_dump -Fc maludb > maludb-$(date +%F).dump` daily.
- Test restore quarterly.
- Include `/etc/maludb/` in your config-file backup set (TLS cert,
  bearer token, conf overrides).
- The `malu$mc2db_invocation` audit table is part of the DB dump —
  it doesn't need separate backup.

---

## 6. Upgrades

MaluDB ships versioned PostgreSQL extension migration scripts. To move
an existing database to the installed package's default version:

```bash
cd ~/maludb-core
git pull
sudo make install PG_CONFIG=/usr/lib/postgresql/17/bin/pg_config

pg_dump maludb > maludb-pre-upgrade.dump
sudo -u postgres psql -d maludb -c "ALTER EXTENSION maludb_core UPDATE;"
```

Always test extension upgrades against a restored copy before applying
them to production data.

---

## 7. What's deferred to R1.1+

Items intentionally NOT in R1.0 that you may need:

| Feature | Status | Anchor |
|---|---|---|
| Per-account auth (multi-tenant) | Bootstrap uses one shared role | R1.1-7 |
| Cloud provider adapters (OpenAI, Anthropic, Google) | All `cloud_api` aliases fail | R1.1-1 (partial) + new R1.1-X |
| External_exec / mcp_proxy MC2DB tools | Catalog accepts; listener rejects | R1.1-1 / R1.1-2 |
| Caching of model responses | Not implemented | R1.1-8 |
| Token / cost budgets | Not implemented | R1.1-9 |
| Idempotency keys | Not implemented | R1.1-10 |
| Versioned upgrade SQL | Single 0.1.0 install | R1.1-X |
| Prometheus / Grafana metrics | journalctl + audit table only | R1.1-X |
| HA / replication / failover | PG-native streaming replication only | not in R1.x |

See `release-1.0-build-plan.md §13` for the full R1.1 anchor list.

---

## 8. Quick checklist

For an internal alpha behind a firewall:

- [ ] Bootstrap completed, validator green
- [ ] Listener and gateway services enabled

For a public alpha:

- [ ] Above + bearer-token enabled + production TLS cert + `NOSUPERUSER` on operator role + ufw configured + log retention configured + backup job scheduled

For production:

- [ ] All of the above
- [ ] Wait for R1.1 features your workload depends on (multi-tenant auth, cloud adapters, caching) before you commit
- [ ] Monitor `malu$mc2db_invocation` for `success=false` patterns, especially `error_code='IMPL_TYPE_NOT_AVAILABLE'` (means a registered tool's implementation_type isn't dispatched yet)
