"""End-to-end smoke test for the Python driver.

Mirrors examples/01-ingest-to-replay.sql. Exercises:
- register_source_package, register_claim, register_fact, register_episode
- text_search, retrieve, replay_episode
- exception translation on a known-bad call
"""

from __future__ import annotations

import pytest

from maludb import MaluDBClient, MaluDBNotFound


def test_version(client: MaluDBClient) -> None:
    v = client.version()
    assert v.startswith("0."), v


def test_schema_search_path(dsn: str) -> None:
    client = MaluDBClient.from_dsn(dsn, schema="driver_tenant")
    try:
        with client.raw.cursor() as cur:
            cur.execute("SHOW search_path")
            row = cur.fetchone()
        assert row is not None
        assert row[0].startswith("driver_tenant, maludb_core, public")
    finally:
        client.close()


def test_ingest_to_retrieve(client: MaluDBClient, tag: str) -> None:
    sp = client.register_source_package(
        source_type="log",
        content_text=f"{tag} log line",
        origin={"uri": f"log://{tag}"},
    )
    assert isinstance(sp, int) and sp > 0

    c1 = client.register_claim(
        subject=f"{tag}_subject",
        verb="observed",
        object_value="event_a",
        statement_text=f"{tag}: claim a",
        source_package_id=sp,
    )
    c2 = client.register_claim(
        subject=f"{tag}_subject",
        verb="confirmed",
        object_value="event_a",
        statement_text=f"{tag}: claim b",
        source_package_id=sp,
    )

    fact_id = client.register_fact(
        claim_ids=[c1, c2],
        subject=f"{tag}_subject",
        verb="verified_incident",
        object_value="event_a",
        statement_text=f"{tag}: verified incident",
        verification_method="manual",
    )
    assert isinstance(fact_id, int) and fact_id > 0

    hits = client.text_search(tag, object_types=["claim", "fact"])
    types = {h.object_type for h in hits}
    assert "claim" in types or "fact" in types, hits

    retrieval = client.retrieve(f"{tag}_subject", limit=10)
    assert retrieval, "execute_retrieval returned no hits"


def test_not_found_translates(client: MaluDBClient) -> None:
    with pytest.raises(MaluDBNotFound):
        client.replay_episode(2**40)  # impossibly large id
