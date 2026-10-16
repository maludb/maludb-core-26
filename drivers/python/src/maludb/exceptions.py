"""Exception hierarchy for the MaluDB Python driver.

We translate the most-common PostgreSQL SQLSTATE classes into
typed Python exceptions so callers can ``except MaluDBNotFound``
rather than introspecting the underlying psycopg DiagnosticError.
"""

from __future__ import annotations

import psycopg


class MaluDBError(Exception):
    """Base class for all MaluDB driver errors."""


class MaluDBNotFound(MaluDBError):
    """A referenced object did not exist (SQLSTATE 02000 / P0002)."""


class MaluDBCheckViolation(MaluDBError):
    """Server rejected the call via CHECK / state-machine guard."""


class MaluDBInvalidParameter(MaluDBError):
    """The function refused an argument as invalid_parameter_value."""


class MaluDBObjectNotInPrerequisiteState(MaluDBError):
    """Lifecycle/state-machine refused the requested transition."""


class MaluDBPermissionDenied(MaluDBError):
    """RLS or GRANT denied the call."""


# SQLSTATE-class -> exception map
_SQLSTATE_MAP: dict[str, type[MaluDBError]] = {
    "P0002": MaluDBNotFound,
    "02000": MaluDBNotFound,
    "22023": MaluDBInvalidParameter,
    "22P02": MaluDBInvalidParameter,
    "55000": MaluDBObjectNotInPrerequisiteState,
    "23514": MaluDBCheckViolation,
    "42501": MaluDBPermissionDenied,
}


def translate(exc: BaseException) -> MaluDBError:
    """Translate a psycopg error into the appropriate MaluDB exception.

    Falls back to a generic MaluDBError wrapping the original message.
    """
    if isinstance(exc, psycopg.errors.Error):
        code = getattr(exc.diag, "sqlstate", None)
        cls = _SQLSTATE_MAP.get(code or "", MaluDBError)
        return cls(str(exc))
    return MaluDBError(str(exc))
