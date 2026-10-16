<?php
/**
 * Plain-PHP smoke runner (no PHPUnit dependency).
 *
 * Same three checks as tests/SmokeTest.php. Useful when ext-dom /
 * ext-xml aren't installed (PHPUnit ^11 requires them, but the
 * driver itself doesn't).
 *
 *   MALUDB_TEST_DSN="postgresql:///maludb_bench?host=/var/run/postgresql" \
 *     php tests/smoke.php
 */

declare(strict_types=1);

require __DIR__ . '/../vendor/autoload.php';

use MaluDB\Client;
use MaluDB\Exceptions\MaluDBNotFound;

$dsn = getenv('MALUDB_TEST_DSN') ?: '';
if ($dsn === '') {
    fwrite(STDERR, "MALUDB_TEST_DSN not set\n");
    exit(2);
}

$client = Client::fromDsn($dsn);
$tag = 'phpdrv-' . bin2hex(random_bytes(4));
$pass = 0;
$fail = 0;

function check(string $name, bool $cond, string $detail = ''): void
{
    global $pass, $fail;
    if ($cond) {
        printf("  ✓ %s\n", $name);
        $pass++;
    } else {
        printf("  ✗ %s  %s\n", $name, $detail);
        $fail++;
    }
}

echo "version()\n";
$v = $client->version();
check('matches /^0\\./', (bool)preg_match('/^0\./', $v), "got: $v");

echo "ingest → retrieve\n";
$sp = $client->registerSourcePackage(
    sourceType: 'log',
    contentText: "$tag log line",
    originJsonb: ['uri' => "log://$tag"],
);
check('register_source_package > 0', $sp > 0);

$c1 = $client->registerClaim(
    subject: $tag . '_subject', verb: 'observed', objectValue: 'event_a',
    statementText: "$tag: claim a", sourcePackageId: $sp,
);
$c2 = $client->registerClaim(
    subject: $tag . '_subject', verb: 'confirmed', objectValue: 'event_a',
    statementText: "$tag: claim b", sourcePackageId: $sp,
);
$f = $client->registerFact(
    claimIds: [$c1, $c2],
    subject: $tag . '_subject', verb: 'verified_incident',
    objectValue: 'event_a', statementText: "$tag: verified",
    verificationMethod: 'manual',
);
check('register_fact > 0', $f > 0);

$hits = $client->textSearch($tag, ['claim', 'fact']);
$types = array_unique(array_map(fn($h) => $h->objectType, $hits));
check('text_search returns claim or fact',
    in_array('claim', $types, true) || in_array('fact', $types, true),
    'types: ' . implode(',', $types));

$retrieval = $client->retrieve($tag . '_subject', null, null, null, null, null, 10);
check('retrieve returns hits', count($retrieval) > 0);

echo "not-found translation\n";
try {
    $client->replayEpisode(2 ** 40);
    check('not-found raises MaluDBNotFound', false, 'no exception raised');
} catch (MaluDBNotFound $e) {
    check('not-found raises MaluDBNotFound', true);
}

printf("\n%d passed, %d failed\n", $pass, $fail);
exit($fail === 0 ? 0 : 1);
