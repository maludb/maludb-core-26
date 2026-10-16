"""Shared pytest fixtures.

The tests need a running PostgreSQL with maludb_core installed.
Set ``MALUDB_TEST_DSN`` to point at it. If unset, every test that
depends on the ``client`` fixture is skipped.
"""

from __future__ import annotations

import os
import uuid

import pytest

try:
    from maludb import MaluDBClient
except ImportError:  # pragma: no cover
    MaluDBClient = None  # type: ignore[assignment]


@pytest.fixture(scope="session")
def dsn() -> str:
    dsn = os.environ.get("MALUDB_TEST_DSN")
    if not dsn:
        pytest.skip("MALUDB_TEST_DSN not set")
    return dsn


@pytest.fixture
def client(dsn: str) -> MaluDBClient:
    if MaluDBClient is None:
        pytest.skip("maludb package not importable")
    c = MaluDBClient.from_dsn(dsn)
    try:
        yield c
    finally:
        c.close()


@pytest.fixture
def tag() -> str:
    """A unique per-test prefix to namespace inserted rows."""
    return f"pydrv-{uuid.uuid4().hex[:8]}"
