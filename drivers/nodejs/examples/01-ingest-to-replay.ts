/**
 * examples/01-ingest-to-replay.ts
 *
 * Node.js mirror of examples/01-ingest-to-replay.sql. Run via:
 *
 *   MALUDB_DSN=postgresql:///maludb_bench \
 *     node --import tsx examples/01-ingest-to-replay.ts
 */

import { randomBytes } from "node:crypto";
import { MaluDBClient } from "../src/index.js";

async function main(): Promise<void> {
  const dsn = process.env["MALUDB_DSN"] ?? "postgresql:///mydb";
  // Suffix the SVPOR signature with a per-run id — the
  // malu$fact_active_window_excl EXCLUDE constraint refuses two
  // active facts with overlapping valid windows on the same
  // (subject, verb).
  const run = randomBytes(4).toString("hex");
  const subject = `api_gateway_${run}`;

  const client = await MaluDBClient.connect({ connectionString: dsn });
  try {
    console.log(`connected to ${dsn} — maludb_core ${await client.version()}`);
    console.log(`run-id = ${run}, subject = ${subject}`);

    const sp = await client.registerSourcePackage({
      sourceType: "log",
      contentText: `node-example-01 [${run}]: 14:22Z api-gateway 5xx burst`,
      originJsonb: { uri: `log://oncall/node-example-01/${run}` },
    });
    console.log(`  source_package_id = ${sp}`);

    const c1 = await client.registerClaim({
      subject,
      verb: "observed",
      objectValue: "5xx_burst",
      statementText: `node-example-01 [${run}]: initial 5xx surge at 14:22Z`,
      sourcePackageId: sp,
    });
    const c2 = await client.registerClaim({
      subject,
      verb: "timed_out",
      objectValue: "health_probe",
      statementText: `node-example-01 [${run}]: health probe exceeded 2s`,
      sourcePackageId: sp,
    });
    console.log(`  claim_ids = ${c1}, ${c2}`);

    const f1 = await client.registerFact({
      claimIds: [c1, c2],
      subject,
      verb: "incident",
      objectValue: "latency_breach",
      statementText: `node-example-01 [${run}]: latency SLO breach`,
      verificationMethod: "oncall_review",
    });
    console.log(`  fact_id = ${f1}`);

    const ep = await client.registerEpisode({
      episodeKind: "incident",
      title: `node-example-01-outage-${run}`,
      summary: "Driver example outage",
      payload: { subject_class: subject, environment: "prod" },
    });
    console.log(`  episode_id = ${ep}`);

    console.log(`\n=== textSearch('${subject}') ===`);
    for (const h of await client.textSearch(subject, { limit: 5 })) {
      console.log(`  ${h.object_type.padEnd(14)} id=${String(h.object_id).padStart(5)}  rank=${h.rank.toFixed(4)}`);
    }

    console.log(`\n=== retrieve('${subject}') ===`);
    for (const h of await client.retrieve(subject, { limit: 5 })) {
      console.log(`  ${h.object_type.padEnd(14)} id=${String(h.object_id).padStart(5)}  strategy=${h.strategy}`);
    }

    console.log(`\n=== replayEpisode ===`);
    const envelope = await client.replayEpisode(ep, "current_valid");
    console.log(`  mode=${envelope.mode}  step_count=${envelope.steps.length}  evidence=${envelope.supporting_evidence.length}`);
  } finally {
    await client.end();
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
