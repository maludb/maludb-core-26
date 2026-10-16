<?php

declare(strict_types=1);

namespace MaluDB\Models;

final readonly class SourceHit
{
    public function __construct(
        public string $objectType,
        public int $objectId,
        public ?string $titleOrSubject,
        public ?string $snippet,
        public float $rank,
    ) {}

    /** @param array<string,mixed> $row */
    public static function fromRow(array $row): self
    {
        return new self(
            objectType: (string)$row['object_type'],
            objectId: (int)$row['object_id'],
            titleOrSubject: $row['title_or_subject'] !== null ? (string)$row['title_or_subject'] : null,
            snippet: $row['snippet'] !== null ? (string)$row['snippet'] : null,
            rank: (float)$row['rank'],
        );
    }
}
