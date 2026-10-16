/**
 * Smoke test for the MaluDB Node.js driver.
 *
 * Mirrors the Python driver's tests/test_smoke.py. Skips when
 * MALUDB_TEST_DSN isn't set.
 */

import { describe, it, before, after } from "node:test";
import assert from "node:assert/strict";
import { randomBytes } from "node:crypto";
import { MaluDBClient, MaluDBNotFound } from "../src/index.js";

const dsn = process.env["MALUDB_TEST_DSN"];

describe("maludb driver smoke", () => {
  if (!dsn) {
    it.skip("MALUDB_TEST_DSN not set", () => {});
    return;
  }

  let client: MaluDBClient;
  const tag = `nodedrv-${randomBytes(4).toString("hex")}`;

  before(async () => {
    client = await MaluDBClient.connect({ connectionString: dsn });
  });

  after(async () => {
    if (client) await client.end();
  });

  it("version reports 0.x.x", async () => {
    const v = await client.version();
    assert.match(v, /^0\./);
  });

  it("schema option prefixes search_path", async () => {
    const tenant = await MaluDBClient.connect({
      connectionString: dsn,
      schema: "driver_tenant",
    });
    try {
      const result = await tenant.raw.query("SHOW search_path");
      assert.ok(
        String(result.rows[0].search_path).startsWith("driver_tenant, maludb_core, public"),
        result.rows[0].search_path,
      );
    } finally {
      await tenant.end();
    }
  });

  it("ingest → retrieve round trip", async () => {
    const sp = await client.registerSourcePackage({
      sourceType: "log",
      contentText: `${tag} log line`,
      originJsonb: { uri: `log://${tag}` },
    });
    assert.ok(Number(sp) > 0, "source package id");

    const c1 = await client.registerClaim({
      subject: `${tag}_subject`,
      verb: "observed",
      objectValue: "event_a",
      statementText: `${tag}: claim a`,
      sourcePackageId: sp,
    });
    const c2 = await client.registerClaim({
      subject: `${tag}_subject`,
      verb: "confirmed",
      objectValue: "event_a",
      statementText: `${tag}: claim b`,
      sourcePackageId: sp,
    });

    const f = await client.registerFact({
      claimIds: [c1, c2],
      subject: `${tag}_subject`,
      verb: "verified_incident",
      objectValue: "event_a",
      statementText: `${tag}: verified incident`,
      verificationMethod: "manual",
    });
    assert.ok(Number(f) > 0, "fact id");

    const hits = await client.textSearch(tag, { objectTypes: ["claim", "fact"] });
    const types = new Set(hits.map((h) => h.object_type));
    assert.ok(types.has("claim") || types.has("fact"), "fts returns at least claim/fact");

    const retrieval = await client.retrieve(`${tag}_subject`, { limit: 10 });
    assert.ok(retrieval.length > 0, "execute_retrieval returns hits");
  });

  it("not-found translates", async () => {
    await assert.rejects(
      () => client.replayEpisode(2 ** 40),
      MaluDBNotFound,
    );
  });
});
