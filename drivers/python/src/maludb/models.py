"""Dataclasses for typed return values.

Each model maps to one row shape returned by a maludb_core helper.
JSONB payloads stay as ``dict``; numeric columns stay as ``float`` /
``int``; timestamps come back as ``datetime`` from psycopg's default
adapters.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime
from typing import Any, Optional


@dataclass
class SourceHit:
    """One row from `text_search`."""

    object_type: str
    object_id: int
    title_or_subject: Optional[str]
    snippet: Optional[str]
    rank: float


@dataclass
class RetrievalHit:
    """One row from `execute_retrieval`."""

    object_type: str
    object_id: int
    title: Optional[str]
    snippet: Optional[str]
    rank: float
    strategy: str
    metadata: dict[str, Any] = field(default_factory=dict)


@dataclass
class SkillExecution:
    """Skill execution record header."""

    execution_id: int
    skill_id: int
    actor_role: str
    active_pool_id: Optional[int]
    task_objective: Optional[str]
    environment: Optional[str]
    technology_stack: Optional[list[str]]
    bound_at: datetime
    started_at: Optional[datetime]
    completed_at: Optional[datetime]
    final_outcome: Optional[str]
    step_count: int
    emitted_claim_ids: list[int]


@dataclass
class PoolMember:
    """Active memory pool member row."""

    member_id: int
    pool_id: int
    member_kind: str
    member_object_type: Optional[str]
    member_object_id: Optional[int]
    payload_jsonb: Optional[dict[str, Any]]
    confidence: Optional[float]
    provenance: Optional[dict[str, Any]]
    added_by: str
    added_at: datetime
    promoted_from_member_id: Optional[int]
    promoted_to_object_type: Optional[str]
    promoted_to_object_id: Optional[int]


@dataclass
class NodeSubmission:
    """Local-node sync submission row."""

    submission_id: int
    node_id: int
    submission_kind: str
    local_id: Optional[int]
    status: str
    applied_object_type: Optional[str]
    applied_object_id: Optional[int]
    reason: Optional[str]
    submitted_at: datetime
    decided_at: Optional[datetime]
