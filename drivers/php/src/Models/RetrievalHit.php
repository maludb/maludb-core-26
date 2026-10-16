<?php

declare(strict_types=1);

namespace MaluDB\Models;

final readonly class RetrievalHit
{
    /** @param array<string,mixed> $metadata */
    public function __construct(
        public string $objectType,
        public int $objectId,
        public ?string $title,
        public ?string $snippet,
        public float $rank,
        public string $strategy,
        public array $metadata,
    ) {}

    /** @param array<string,mixed> $row */
    public static function fromRow(array $row): self
    {
        $meta = $row['metadata'] ?? null;
        if (is_string($meta)) {
            /** @var array<string,mixed> $meta */
            $meta = json_decode($meta, true) ?? [];
        } elseif ($meta === null) {
            $meta = [];
        }
        return new self(
            objectType: (string)$row['object_type'],
            objectId: (int)$row['object_id'],
            title: $row['title'] !== null ? (string)$row['title'] : null,
            snippet: $row['snippet'] !== null ? (string)$row['snippet'] : null,
            rank: (float)$row['rank'],
            strategy: (string)$row['strategy'],
            metadata: $meta,
        );
    }
}
