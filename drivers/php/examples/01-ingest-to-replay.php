<?php
/**
 * examples/01-ingest-to-replay.php
 *
 * PHP mirror of examples/01-ingest-to-replay.sql / .py / .ts. Run with:
 *
 *   composer install
 *   MALUDB_DSN="postgresql:///maludb_bench?host=/var/run/postgresql" \
 *     php examples/01-ingest-to-replay.php
 */

declare(strict_types=1);

require __DIR__ . '/../vendor/autoload.php';

use MaluDB\Client;

$dsn = getenv('MALUDB_DSN') ?: 'postgresql:///mydb';
$run = bin2hex(random_bytes(4));
$subject = "api_gateway_$run";

$client = Client::fromDsn($dsn);
printf("connected to %s — maludb_core %s\n", $dsn, $client->version());
printf("run-id = %s, subject = %s\n", $run, $subject);

$sp = $client->registerSourcePackage(
    sourceType: 'log',
    contentText: "php-example-01 [$run]: 14:22Z api-gateway 5xx burst",
    originJsonb: ['uri' => "log://oncall/php-example-01/$run"],
);
echo "  source_package_id = $sp\n";

$c1 = $client->registerClaim(
    subject: $subject, verb: 'observed', objectValue: '5xx_burst',
    statementText: "php-example-01 [$run]: initial 5xx surge at 14:22Z",
    sourcePackageId: $sp,
);
$c2 = $client->registerClaim(
    subject: $subject, verb: 'timed_out', objectValue: 'health_probe',
    statementText: "php-example-01 [$run]: health probe exceeded 2s",
    sourcePackageId: $sp,
);
echo "  claim_ids = $c1, $c2\n";

$f1 = $client->registerFact(
    claimIds: [$c1, $c2],
    subject: $subject, verb: 'incident', objectValue: 'latency_breach',
    statementText: "php-example-01 [$run]: latency SLO breach",
    verificationMethod: 'oncall_review',
);
echo "  fact_id = $f1\n";

$ep = $client->registerEpisode(
    episodeKind: 'incident',
    title: "php-example-01-outage-$run",
    summary: 'Driver example outage',
    payload: ['subject_class' => $subject, 'environment' => 'prod'],
);
echo "  episode_id = $ep\n";

echo "\n=== textSearch('$subject') ===\n";
foreach ($client->textSearch($subject, null, 5) as $h) {
    printf("  %-14s id=%5d  rank=%.4f\n", $h->objectType, $h->objectId, $h->rank);
}

echo "\n=== retrieve('$subject') ===\n";
foreach ($client->retrieve($subject, null, null, null, null, null, 5) as $h) {
    printf("  %-14s id=%5d  strategy=%s\n", $h->objectType, $h->objectId, $h->strategy);
}

echo "\n=== replayEpisode ===\n";
$envelope = $client->replayEpisode($ep, 'current_valid');
printf("  mode=%s  step_count=%d  evidence=%d\n",
    $envelope['mode'] ?? '?',
    is_array($envelope['steps'] ?? null) ? count($envelope['steps']) : 0,
    is_array($envelope['supporting_evidence'] ?? null) ? count($envelope['supporting_evidence']) : 0,
);
