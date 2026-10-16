# `@maludb/client` — Node.js / TypeScript driver for MaluDB

Synchronous-feeling async-under-the-hood client for the maludb_core
extension, mirroring the [Python driver](../python/README.md) shape.

Status: **alpha**. v0.1.0 covers the headline read/write surface;
streaming, pool retrieval, and the workflow-extraction helpers land
in later versions.

## Install

```bash
npm install @maludb/client
```

Or from this source tree:

```bash
cd drivers/nodejs
npm install
npm run build
```

## Quickstart

```ts
import { MaluDBClient } from "@maludb/client";

// Unix socket (the default install on PGDG Ubuntu lives at
// /var/run/postgresql). pg defaults to TCP+localhost if no host is
// given, so DSN-only `postgresql:///mydb` will try SCRAM password
// auth — pass an explicit host for peer/socket auth.
const client = await MaluDBClient.connect({
  connectionString: "postgresql:///mydb?host=/var/run/postgresql",
});

// Or TCP with a password:
//   { connectionString: "postgresql://user:pass@host:5432/mydb" }

try {
  const sp = await client.registerSourcePackage({
    sourceType: "log",
    contentText: "oncall: 14:22Z api-gateway 5xx burst",
    originJsonb: { uri: "log://oncall/2026-05-13" },
  });

  const c1 = await client.registerClaim({
    subject: "api_gateway",
    verb: "observed",
    objectValue: "5xx_burst",
    statementText: "Initial 5xx surge at 14:22Z",
    sourcePackageId: sp,
  });
  const c2 = await client.registerClaim({
    subject: "api_gateway",
    verb: "timed_out",
    objectValue: "health_probe",
    statementText: "Health probe exceeded 2s",
    sourcePackageId: sp,
  });

  const f1 = await client.registerFact({
    claimIds: [c1, c2],
    subject: "api_gateway",
    verb: "incident",
    objectValue: "latency_breach",
    statementText: "Latency SLO breach root cause identified",
    verificationMethod: "oncall_review",
  });

  for (const hit of await client.retrieve("api_gateway", { limit: 10 })) {
    console.log(hit.object_type, hit.object_id, hit.rank);
  }
} finally {
  await client.end();
}
```

## Available methods

Mirrors the Python driver one-to-one. See
[../python/README.md](../python/README.md) for the method matrix; in
TypeScript names use camelCase (`registerSourcePackage`,
`textSearch`, `replayEpisode`, etc.) and the underlying SQL function
signatures.

## Exception hierarchy

```
MaluDBError
├── MaluDBNotFound                       (P0002 / 02000)
├── MaluDBInvalidParameter               (22023 / 22P02)
├── MaluDBObjectNotInPrerequisiteState   (55000)
├── MaluDBCheckViolation                 (23514)
└── MaluDBPermissionDenied               (42501)
```

`catch (e) { if (e instanceof MaluDBNotFound) … }`.

## Running tests

```bash
cd drivers/nodejs
npm install
MALUDB_TEST_DSN="postgresql:///maludb_bench?host=/var/run/postgresql" npm test
```

Tests need a running PostgreSQL with `maludb_core` installed in the
target database. They namespace inserted rows under a random
`nodedrv-XXXXXXXX` tag.
