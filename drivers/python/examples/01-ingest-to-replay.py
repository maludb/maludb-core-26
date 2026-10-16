"""examples/01-ingest-to-replay.py

Python mirror of examples/01-ingest-to-replay.sql. Run after
`pip install -e .` against a database that has maludb_core
installed:

    MALUDB_DSN="postgresql:///mydb" python examples/01-ingest-to-replay.py
"""

from __future__ import annotations

import os
import sys
import uuid

from maludb import MaluDBClient


def main() -> int:
    dsn = os.environ.get("MALUDB_DSN", "postgresql:///mydb")
    # Suffix the SVPOR signature with a per-run id. The
    # malu$fact_active_window_excl EXCLUDE constraint refuses two
    # active facts with the same (subject, verb, predicate) on
    # overlapping valid windows — that's the supersession engine
    # doctrine. Per-run subjects keep the example idempotent.
    run = uuid.uuid4().hex[:8]
    subject = f"api_gateway_{run}"

    with MaluDBClient.from_dsn(dsn) as client:
        print(f"connected to {dsn} — maludb_core {client.version()}")
        print(f"run-id = {run}, subject = {subject}")

        sp = client.register_source_package(
            source_type="log",
            content_text=f"py-example-01 [{run}]: 14:22Z api-gateway 5xx burst",
            origin={"uri": f"log://oncall/py-example-01/{run}"},
        )
        print(f"  source_package_id = {sp}")

        c1 = client.register_claim(
            subject=subject,
            verb="observed",
            object_value="5xx_burst",
            statement_text=f"py-example-01 [{run}]: initial 5xx surge at 14:22Z",
            source_package_id=sp,
        )
        c2 = client.register_claim(
            subject=subject,
            verb="timed_out",
            object_value="health_probe",
            statement_text=f"py-example-01 [{run}]: health probe exceeded 2s",
            source_package_id=sp,
        )
        print(f"  claim_ids = {c1}, {c2}")

        f1 = client.register_fact(
            claim_ids=[c1, c2],
            subject=subject,
            verb="incident",
            object_value="latency_breach",
            statement_text=f"py-example-01 [{run}]: latency SLO breach root cause",
            verification_method="oncall_review",
        )
        print(f"  fact_id = {f1}")

        ep = client.register_episode(
            episode_kind="incident",
            title=f"py-example-01-outage-{run}",
            summary="Driver example outage",
            payload={"subject_class": subject, "environment": "prod"},
        )
        print(f"  episode_id = {ep}")

        # Query
        print(f"\n=== text_search '{subject}' ===")
        for h in client.text_search(subject, limit=5):
            print(f"  {h.object_type:14}  id={h.object_id:5}  rank={h.rank:.4f}")

        print(f"\n=== retrieve '{subject}' ===")
        for h in client.retrieve(subject, limit=5):
            print(f"  {h.object_type:14}  id={h.object_id:5}  strategy={h.strategy}")

        print("\n=== replay_episode ===")
        envelope = client.replay_episode(ep, mode="current_valid")
        print(f"  mode={envelope['mode']}  step_count={len(envelope['steps'])}  "
              f"evidence={len(envelope['supporting_evidence'])}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
