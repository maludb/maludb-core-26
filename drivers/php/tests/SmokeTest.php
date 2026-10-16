<?php

declare(strict_types=1);

namespace MaluDB\Tests;

use MaluDB\Client;
use MaluDB\Exceptions\MaluDBNotFound;
use PHPUnit\Framework\Attributes\Test;
use PHPUnit\Framework\TestCase;

final class SmokeTest extends TestCase
{
    private ?Client $client = null;
    private string $tag;

    protected function setUp(): void
    {
        $dsn = getenv('MALUDB_TEST_DSN') ?: '';
        if ($dsn === '') {
            $this->markTestSkipped('MALUDB_TEST_DSN not set');
        }
        $this->client = Client::fromDsn($dsn);
        $this->tag = 'phpdrv-' . bin2hex(random_bytes(4));
    }

    #[Test]
    public function versionReportsZeroDot(): void
    {
        $v = $this->client->version();
        $this->assertMatchesRegularExpression('/^0\./', $v);
    }

    #[Test]
    public function schemaOptionPrefixesSearchPath(): void
    {
        $dsn = getenv('MALUDB_TEST_DSN') ?: '';
        $tenant = Client::fromDsn($dsn, schema: 'driver_tenant');
        $path = $tenant->raw->query('SHOW search_path')->fetchColumn();
        $this->assertStringStartsWith('driver_tenant, maludb_core, public', (string)$path);
    }

    #[Test]
    public function ingestToRetrieveRoundTrip(): void
    {
        $sp = $this->client->registerSourcePackage(
            sourceType: 'log',
            contentText: $this->tag . ' log line',
            originJsonb: ['uri' => 'log://' . $this->tag],
        );
        $this->assertGreaterThan(0, $sp);

        $c1 = $this->client->registerClaim(
            subject: $this->tag . '_subject',
            verb: 'observed',
            objectValue: 'event_a',
            statementText: $this->tag . ': claim a',
            sourcePackageId: $sp,
        );
        $c2 = $this->client->registerClaim(
            subject: $this->tag . '_subject',
            verb: 'confirmed',
            objectValue: 'event_a',
            statementText: $this->tag . ': claim b',
            sourcePackageId: $sp,
        );

        $f = $this->client->registerFact(
            claimIds: [$c1, $c2],
            subject: $this->tag . '_subject',
            verb: 'verified_incident',
            objectValue: 'event_a',
            statementText: $this->tag . ': verified incident',
            verificationMethod: 'manual',
        );
        $this->assertGreaterThan(0, $f);

        $hits = $this->client->textSearch($this->tag, ['claim', 'fact']);
        $types = array_unique(array_map(fn($h) => $h->objectType, $hits));
        $this->assertTrue(
            in_array('claim', $types, true) || in_array('fact', $types, true),
            'fts returns at least claim or fact',
        );

        $retrieval = $this->client->retrieve($this->tag . '_subject', null, null, null, null, null, 10);
        $this->assertNotEmpty($retrieval, 'execute_retrieval returns hits');
    }

    #[Test]
    public function notFoundTranslates(): void
    {
        $this->expectException(MaluDBNotFound::class);
        $this->client->replayEpisode(2 ** 40);
    }
}
