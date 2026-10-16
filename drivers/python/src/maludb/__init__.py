"""MaluDB Python driver.

Thin wrappers over the maludb_core SQL surface. Connections use
psycopg 3 under the hood; this module doesn't try to hide that — if
you need raw SQL, ``client.raw`` is the underlying connection.

Quickstart:

    from maludb import MaluDBClient

    with MaluDBClient.from_dsn("postgresql:///mydb") as client:
        sp = client.register_source_package(
            source_type="log",
            content_text="oncall: 14:22Z api-gateway 5xx burst")
        claim_id = client.register_claim(
            subject="api_gateway", verb="observed",
            object_value="5xx_burst",
            statement_text="Initial 5xx surge at 14:22Z",
            source_package_id=sp)
        hits = client.text_search("5xx burst")
"""

from .client import MaluDBClient
from .exceptions import MaluDBError, MaluDBNotFound, MaluDBCheckViolation
from .models import (
    SourceHit,
    RetrievalHit,
    SkillExecution,
    PoolMember,
    NodeSubmission,
)

__version__ = "0.1.0"
__all__ = [
    "MaluDBClient",
    "MaluDBError",
    "MaluDBNotFound",
    "MaluDBCheckViolation",
    "SourceHit",
    "RetrievalHit",
    "SkillExecution",
    "PoolMember",
    "NodeSubmission",
]
