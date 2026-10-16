"""CLI exception types."""

from __future__ import annotations


class StagePendingError(RuntimeError):
    """Raised when a CLI command targets a V3 surface that hasn't shipped yet."""

    def __init__(self, ticket: str, surface: str) -> None:
        super().__init__(f"{surface} requires {ticket}; not yet shipped on this extension version.")
        self.code = ticket
