<?php

declare(strict_types=1);

namespace MaluDB\Exceptions;

use PDOException;

/**
 * SQLSTATE → typed-exception translator. Mirrors the Python and
 * Node.js drivers so callers can `catch (MaluDBNotFound $e)` rather
 * than digging through PDOException::$errorInfo.
 */
final class Translator
{
    /**
     * @var array<string, class-string<MaluDBError>>
     */
    private const SQLSTATE_MAP = [
        'P0002' => MaluDBNotFound::class,
        '02000' => MaluDBNotFound::class,
        '22023' => MaluDBInvalidParameter::class,
        '22P02' => MaluDBInvalidParameter::class,
        '55000' => MaluDBObjectNotInPrerequisiteState::class,
        '23514' => MaluDBCheckViolation::class,
        '42501' => MaluDBPermissionDenied::class,
    ];

    public static function translate(\Throwable $exc): MaluDBError
    {
        if ($exc instanceof PDOException) {
            $info = $exc->errorInfo ?? [];
            $sqlstate = (string)($info[0] ?? '');
            $detail = (string)($info[2] ?? $exc->getMessage());
            $cls = self::SQLSTATE_MAP[$sqlstate] ?? MaluDBError::class;
            return new $cls($exc->getMessage(), $sqlstate ?: null, $detail, $exc);
        }
        return new MaluDBError($exc->getMessage(), null, null, $exc);
    }
}
