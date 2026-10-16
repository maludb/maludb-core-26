<?php

declare(strict_types=1);

namespace MaluDB\Exceptions;

class MaluDBError extends \RuntimeException
{
    public function __construct(
        string $message,
        public readonly ?string $sqlstate = null,
        public readonly ?string $detail = null,
        ?\Throwable $previous = null,
    ) {
        parent::__construct($message, 0, $previous);
    }
}
