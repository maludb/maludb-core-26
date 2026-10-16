"""MaluDB synchronous client.

Wraps a psycopg 3 connection and exposes typed methods over the
maludb_core SQL surface. Async support lives in a separate
``aclient`` module (not in v1).
"""

from __future__ import annotations

from contextlib import contextmanager
from typing import Any, Iterator, Optional

import psycopg
from psycopg.rows import dict_row

from .exceptions import translate
from .models import (
    NodeSubmission,
    PoolMember,
    RetrievalHit,
    SkillExecution,
    SourceHit,
)


def _quote_identifier(identifier: str) -> str:
    return '"' + identifier.replace('"', '""') + '"'


def _search_path(schema: str | None) -> str:
    if schema is None or schema == "":
        return "maludb_core, public"
    return f"{_quote_identifier(schema)}, maludb_core, public"


class MaluDBClient:
    """A synchronous MaluDB client.

    Construct via the factory: ``MaluDBClient.from_dsn(...)`` or
    ``MaluDBClient.from_connection(conn)`` if you already have a
    psycopg connection. The factories own connection lifecycle when
    used as a context manager.
    """

    # ------------------------------------------------------------ #
    # construction
    # ------------------------------------------------------------ #
    def __init__(self, conn: psycopg.Connection, schema: str | None = None):
        self.raw: psycopg.Connection = conn
        # Pin the search path so every helper resolves under
        # the tenant schema (when supplied) and maludb_core without
        # the caller having to set search_path.
        with self.raw.cursor() as cur:
            cur.execute(f"SET search_path = {_search_path(schema)}")
        self.raw.commit()

    @classmethod
    def from_dsn(cls, dsn: str, schema: str | None = None, **kwargs: Any) -> "MaluDBClient":
        return cls(psycopg.connect(dsn, **kwargs), schema=schema)

    @classmethod
    def from_connection(cls, conn: psycopg.Connection, schema: str | None = None) -> "MaluDBClient":
        return cls(conn, schema=schema)

    def close(self) -> None:
        self.raw.close()

    def __enter__(self) -> "MaluDBClient":
        return self

    def __exit__(self, *args: Any) -> None:
        self.close()

    # ------------------------------------------------------------ #
    # internal call helper
    # ------------------------------------------------------------ #
    def _scalar(self, sql: str, params: tuple = ()) -> Any:
        try:
            with self.raw.cursor() as cur:
                cur.execute(sql, params)
                row = cur.fetchone()
            self.raw.commit()
            return row[0] if row else None
        except psycopg.errors.Error as exc:
            self.raw.rollback()
            raise translate(exc) from exc

    def _rows(self, sql: str, params: tuple = ()) -> list[dict[str, Any]]:
        try:
            with self.raw.cursor(row_factory=dict_row) as cur:
                cur.execute(sql, params)
                rows = list(cur.fetchall())
            self.raw.commit()
            return rows
        except psycopg.errors.Error as exc:
            self.raw.rollback()
            raise translate(exc) from exc

    @contextmanager
    def transaction(self) -> Iterator[None]:
        """Run a block of calls in one psycopg transaction.

        Use when you need atomic multi-step writes (e.g. register a
        source, then a claim, then a fact). All MaluDB helpers
        already commit per-call by default.
        """
        try:
            yield
            self.raw.commit()
        except Exception:
            self.raw.rollback()
            raise

    # ============================================================ #
    # INGEST
    # ============================================================ #

    def register_source_package(
        self,
        source_type: str,
        *,
        content_text: Optional[str] = None,
        content_jsonb: Optional[dict[str, Any]] = None,
        content_bytes: Optional[bytes] = None,
        origin: Optional[dict[str, Any]] = None,
        sensitivity: str = "internal",
    ) -> int:
        return self._scalar(
            """
            SELECT register_source_package(
                p_source_type   => %s,
                p_content_text  => %s,
                p_content_jsonb => %s::jsonb,
                p_content_bytes => %s,
                p_origin_jsonb  => %s::jsonb,
                p_sensitivity   => %s)
            """,
            (
                source_type,
                content_text,
                psycopg.types.json.Jsonb(content_jsonb) if content_jsonb else None,
                content_bytes,
                psycopg.types.json.Jsonb(origin) if origin else None,
                sensitivity,
            ),
        )

    def register_claim(
        self,
        *,
        subject: Optional[str] = None,
        verb: Optional[str] = None,
        predicate: Optional[str] = None,
        object_value: Optional[str] = None,
        statement_text: Optional[str] = None,
        statement_jsonb: Optional[dict[str, Any]] = None,
        source_package_id: Optional[int] = None,
        sensitivity: str = "internal",
    ) -> int:
        return self._scalar(
            """
            SELECT register_claim(
                p_subject           => %s,
                p_verb              => %s,
                p_predicate         => %s,
                p_object_value      => %s,
                p_statement_text    => %s,
                p_statement_jsonb   => %s::jsonb,
                p_source_package_id => %s,
                p_sensitivity       => %s)
            """,
            (
                subject, verb, predicate, object_value, statement_text,
                psycopg.types.json.Jsonb(statement_jsonb) if statement_jsonb else None,
                source_package_id, sensitivity,
            ),
        )

    def register_fact(
        self,
        *,
        claim_ids: list[int],
        subject: Optional[str] = None,
        verb: Optional[str] = None,
        object_value: Optional[str] = None,
        statement_text: Optional[str] = None,
        verification_scope: Optional[str] = None,
        verification_method: Optional[str] = None,
        sensitivity: str = "internal",
    ) -> int:
        return self._scalar(
            """
            SELECT register_fact(
                p_claim_ids           => %s,
                p_subject             => %s,
                p_verb                => %s,
                p_object_value        => %s,
                p_statement_text      => %s,
                p_verification_scope  => %s,
                p_verification_method => %s,
                p_sensitivity         => %s)
            """,
            (
                claim_ids, subject, verb, object_value, statement_text,
                verification_scope, verification_method, sensitivity,
            ),
        )

    def register_memory(
        self,
        *,
        memory_kind: str,
        title: Optional[str] = None,
        summary: Optional[str] = None,
        payload: Optional[dict[str, Any]] = None,
        sensitivity: str = "internal",
    ) -> int:
        return self._scalar(
            """
            SELECT register_memory(
                p_memory_kind   => %s,
                p_title         => %s,
                p_summary       => %s,
                p_payload_jsonb => %s::jsonb,
                p_sensitivity   => %s)
            """,
            (
                memory_kind, title, summary,
                psycopg.types.json.Jsonb(payload or {}),
                sensitivity,
            ),
        )

    def register_episode(
        self,
        *,
        episode_kind: str,
        title: str,
        summary: Optional[str] = None,
        payload: Optional[dict[str, Any]] = None,
        sensitivity: str = "internal",
    ) -> int:
        return self._scalar(
            """
            SELECT register_episode(
                p_episode_kind  => %s,
                p_title         => %s,
                p_summary       => %s,
                p_payload_jsonb => %s::jsonb,
                p_sensitivity   => %s)
            """,
            (
                episode_kind, title, summary,
                psycopg.types.json.Jsonb(payload or {}),
                sensitivity,
            ),
        )

    # ============================================================ #
    # RETRIEVE
    # ============================================================ #

    def text_search(
        self,
        query: str,
        *,
        object_types: Optional[list[str]] = None,
        limit: int = 20,
    ) -> list[SourceHit]:
        rows = self._rows(
            """
            SELECT object_type, object_id, title_or_subject, snippet, rank
            FROM text_search(%s, %s::text[], %s)
            """,
            (
                query,
                object_types or ["claim", "fact", "memory", "episode_object"],
                limit,
            ),
        )
        return [SourceHit(**r) for r in rows]

    def retrieve(
        self,
        cue_text: str,
        *,
        object_types: Optional[list[str]] = None,
        valid_as_of: Optional[str] = None,
        transaction_as_of: Optional[str] = None,
        confidence_floor: Optional[float] = None,
        hint_name: Optional[str] = None,
        limit: int = 20,
    ) -> list[RetrievalHit]:
        rows = self._rows(
            """
            SELECT object_type, object_id, title, snippet, rank, strategy, metadata
            FROM execute_retrieval(
                ROW(%s, %s::text[], %s::timestamptz, %s::timestamptz, %s::numeric, NULL)
                ::maludb_core.malu$retrieval_envelope_t,
                %s, %s)
            """,
            (
                cue_text,
                object_types or ["claim", "fact", "memory", "episode_object"],
                valid_as_of, transaction_as_of, confidence_floor,
                hint_name, limit,
            ),
        )
        return [RetrievalHit(**r) for r in rows]

    def replay_episode(
        self,
        episode_id: int,
        mode: str = "current_valid",
        as_of: Optional[str] = None,
    ) -> dict[str, Any]:
        return self._scalar(
            "SELECT replay_episode(%s, %s, %s::timestamptz)",
            (episode_id, mode, as_of),
        )

    # ============================================================ #
    # ACTIVE MEMORY POOL
    # ============================================================ #

    def create_pool(
        self,
        pool_name: str,
        *,
        creation_kind: str = "sql",
        task_objective: Optional[str] = None,
        confidence_floor: Optional[float] = None,
        max_member_count: Optional[int] = None,
    ) -> int:
        return self._scalar(
            """
            SELECT create_active_memory_pool(
                p_pool_name => %s,
                p_creation_kind => %s,
                p_task_objective => %s,
                p_confidence_floor => %s,
                p_max_member_count => %s)
            """,
            (pool_name, creation_kind, task_objective, confidence_floor, max_member_count),
        )

    def pool_add_observation(
        self,
        pool_id: int,
        *,
        payload: dict[str, Any],
        confidence: Optional[float] = None,
        provenance: Optional[dict[str, Any]] = None,
    ) -> int:
        return self._scalar(
            """
            SELECT pool_add_observation(
                p_pool_id => %s,
                p_payload_jsonb => %s::jsonb,
                p_confidence => %s,
                p_provenance => %s::jsonb)
            """,
            (
                pool_id,
                psycopg.types.json.Jsonb(payload),
                confidence,
                psycopg.types.json.Jsonb(provenance) if provenance else None,
            ),
        )

    def pool_promote_to_claim(
        self,
        member_id: int,
        *,
        subject: Optional[str] = None,
        verb: Optional[str] = None,
        object_value: Optional[str] = None,
        statement_text: Optional[str] = None,
    ) -> int:
        return self._scalar(
            """
            SELECT pool_promote_to_claim(%s, %s, %s, %s, %s)
            """,
            (member_id, subject, verb, object_value, statement_text),
        )

    def pool_seal(self, pool_id: int, reason: Optional[str] = None) -> None:
        self._scalar("SELECT pool_seal(%s, %s)", (pool_id, reason))

    # ============================================================ #
    # SKILL RUNTIME
    # ============================================================ #

    def register_skill(
        self,
        name: str,
        *,
        version: str = "1.0.0",
        description: Optional[str] = None,
        applicability: Optional[dict[str, Any]] = None,
    ) -> int:
        return self._scalar(
            """
            SELECT register_skill(
                p_skill_name => %s,
                p_version    => %s,
                p_description => %s,
                p_applicability_jsonb => %s::jsonb)
            """,
            (
                name, version, description,
                psycopg.types.json.Jsonb(applicability or {}),
            ),
        )

    def add_skill_state(self, skill_id: int, state_name: str, state_kind: str) -> int:
        return self._scalar(
            "SELECT add_skill_state(%s, %s, %s)",
            (skill_id, state_name, state_kind),
        )

    def add_skill_transition(
        self, skill_id: int, from_state: str, to_state: str, on_outcome: str
    ) -> int:
        return self._scalar(
            "SELECT add_skill_transition(%s, %s, %s, %s)",
            (skill_id, from_state, to_state, on_outcome),
        )

    def begin_skill_execution(
        self,
        skill_id: int,
        *,
        environment: Optional[str] = None,
        technology_stack: Optional[list[str]] = None,
        task_objective: Optional[str] = None,
        active_pool_id: Optional[int] = None,
    ) -> int:
        return self._scalar(
            """
            SELECT begin_skill_execution(
                p_skill_id => %s,
                p_environment => %s,
                p_technology_stack => %s::text[],
                p_task_objective => %s,
                p_active_pool_id => %s)
            """,
            (skill_id, environment, technology_stack, task_objective, active_pool_id),
        )

    def step_skill_execution(
        self,
        execution_id: int,
        outcome: str,
        observation: Optional[dict[str, Any]] = None,
    ) -> str:
        return self._scalar(
            "SELECT step_skill_execution(%s, %s, %s::jsonb)",
            (
                execution_id, outcome,
                psycopg.types.json.Jsonb(observation) if observation else None,
            ),
        )

    def abort_skill_execution(self, execution_id: int, reason: Optional[str] = None) -> None:
        self._scalar("SELECT abort_skill_execution(%s, %s)", (execution_id, reason))

    # ============================================================ #
    # LOCAL NODE SYNC
    # ============================================================ #

    def register_local_node(
        self,
        node_name: str,
        fingerprint: str,
        *,
        uri: Optional[str] = None,
        description: Optional[str] = None,
    ) -> int:
        return self._scalar(
            "SELECT register_local_node(%s, %s, %s, %s)",
            (node_name, fingerprint, uri, description),
        )

    def node_submit(
        self,
        node_id: int,
        submission_kind: str,
        payload: dict[str, Any],
        *,
        local_id: Optional[int] = None,
        local_hash: Optional[str] = None,
    ) -> int:
        return self._scalar(
            """
            SELECT node_submit(
                p_node_id => %s,
                p_submission_kind => %s,
                p_payload_jsonb => %s::jsonb,
                p_local_id => %s,
                p_local_hash => %s)
            """,
            (
                node_id, submission_kind,
                psycopg.types.json.Jsonb(payload),
                local_id, local_hash,
            ),
        )

    def node_accept(self, submission_id: int, reason: Optional[str] = None) -> dict[str, Any]:
        return self._scalar(
            "SELECT node_accept(%s, %s)", (submission_id, reason),
        )

    def node_reject(self, submission_id: int, reason: str) -> None:
        self._scalar("SELECT node_reject(%s, %s)", (submission_id, reason))

    def revoke_local_node(self, node_id: int, reason: str) -> None:
        self._scalar("SELECT revoke_local_node(%s, %s)", (node_id, reason))

    # ============================================================ #
    # V4 PageIndex
    # ============================================================ #

    def pageindex_build(
        self,
        source_package_id: int,
        parser_kind: str = "pdf",
        *,
        model_alias_id: Optional[int] = None,
        prompt_template_id: Optional[int] = None,
        builder_options: Optional[dict[str, Any]] = None,
    ) -> int:
        return self._scalar(
            "SELECT source_package_promote_to_page_index(%s, %s, %s, %s, %s::jsonb)",
            (
                source_package_id, parser_kind,
                model_alias_id, prompt_template_id,
                psycopg.types.json.Jsonb(builder_options or {}),
            ),
        )

    def pageindex_list(
        self,
        *,
        build_status: Optional[str] = None,
        limit: int = 50,
    ) -> list[dict[str, Any]]:
        return self._rows(
            "SELECT * FROM pageindex_list_trees(%s, %s)",
            (build_status, limit),
        )

    def pageindex_get(self, tree_id: int) -> Optional[dict[str, Any]]:
        rows = self._rows(
            "SELECT * FROM pageindex_get_tree(%s)", (tree_id,))
        return rows[0] if rows else None

    def pageindex_ask(
        self,
        cue_text: str,
        tree_id: int,
        *,
        max_depth: int = 6,
        choice: str = "overlap",
        limit: int = 1,
    ) -> Optional[dict[str, Any]]:
        opts = {"max_depth": max_depth, "choice": choice}
        rows = self._rows(
            "SELECT * FROM retrieve_with_envelope_tree(%s, %s, %s::jsonb, %s)",
            (cue_text, tree_id, psycopg.types.json.Jsonb(opts), limit),
        )
        return rows[0] if rows else None

    def pageindex_supersede(self, prior_tree_id: int, new_tree_id: int) -> int:
        return self._scalar(
            "SELECT page_index_tree_supersede(%s, %s)",
            (prior_tree_id, new_tree_id),
        )

    # ============================================================ #
    # V4 ChatIndex
    # ============================================================ #

    def chatindex_build(
        self,
        source_package_id: int,
        *,
        model_alias_id: Optional[int] = None,
        prompt_template_id: Optional[int] = None,
        max_children: int = 10,
        builder_options: Optional[dict[str, Any]] = None,
    ) -> int:
        return self._scalar(
            "SELECT source_package_promote_to_chat_index(%s, %s, %s, %s, %s::jsonb)",
            (
                source_package_id, model_alias_id, prompt_template_id,
                max_children,
                psycopg.types.json.Jsonb(builder_options or {}),
            ),
        )

    def chatindex_append(
        self,
        tree_id: int,
        messages: list[dict[str, Any]],
    ) -> list[dict[str, Any]]:
        return self._rows(
            "SELECT * FROM chat_index_append_messages(%s, %s::jsonb)",
            (tree_id, psycopg.types.json.Jsonb(messages)),
        )

    def chatindex_list(
        self,
        *,
        build_status: Optional[str] = None,
        limit: int = 50,
    ) -> list[dict[str, Any]]:
        return self._rows(
            "SELECT * FROM chatindex_list_trees(%s, %s)",
            (build_status, limit),
        )

    def chatindex_ask(
        self,
        cue_text: str,
        chat_tree_id: int,
        *,
        max_depth: int = 6,
        choice: str = "overlap",
        limit: int = 1,
    ) -> Optional[dict[str, Any]]:
        opts = {"max_depth": max_depth, "choice": choice}
        rows = self._rows(
            "SELECT * FROM retrieve_with_envelope_chat_tree(%s, %s, %s::jsonb, %s)",
            (cue_text, chat_tree_id, psycopg.types.json.Jsonb(opts), limit),
        )
        return rows[0] if rows else None

    # ============================================================ #
    # version
    # ============================================================ #

    def version(self) -> str:
        return self._scalar("SELECT maludb_core_version()")
