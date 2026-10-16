"""V4-PAGEINDEX-02 builder.

Single-shot tree build: given a leased pageindex_build job, fetch the
Source Package bytes, run the deterministic structure pass, write the
structure-pass audit, summarize every node through the model gateway,
write each node + ledger entry, and transition the tree to 'ready'.

The plan reserves builder concurrency for §10.4: one tree at a time
per worker is the v1 posture.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass
from typing import Any

import psycopg

from .model_gateway import (
    LocalDeterministicSummarizer,
    SummarizationRequest,
    Summarizer,
)
from .parsers import (
    OutlineEntry,
    PageText,
    ParseInputs,
    deterministic_inputs_hash,
    parser_for_kind,
)

log = logging.getLogger("maludb_pageindexd.builder")


@dataclass(frozen=True)
class BuilderResult:
    tree_id: int
    outline_node_count: int
    leaf_count: int
    outcome: str
    error_text: str | None = None


def build_tree(conn: psycopg.Connection,
               job_payload: dict[str, Any],
               summarizer: Summarizer | None = None) -> BuilderResult:
    """Run the full V4-PAGEINDEX-02 build for one queued job.

    `conn` MUST be a non-autocommit connection whose caller is willing
    to commit. `build_tree` opens explicit transactions per logical
    write batch (structure pass, node batch, ready transition) so a
    failure in summarization leaves the structure-pass audit + any
    nodes written so far in place and the tree in 'failed' status.
    """

    tree_id = int(job_payload["tree_id"])
    source_package_id = int(job_payload["source_package_id"])
    parser_kind = str(job_payload["parser_kind"])

    summarizer = summarizer or LocalDeterministicSummarizer()
    parser = parser_for_kind(parser_kind)

    # Transition tree to 'building'.
    with conn.transaction():
        with conn.cursor() as cur:
            cur.execute("SELECT maludb_core.page_index_tree_mark_building(%s)",
                        (tree_id,))

    # Fetch source bytes.
    source_bytes, filename, media_type = _fetch_source(conn, source_package_id)
    inputs = ParseInputs(source_bytes=source_bytes,
                         filename=filename,
                         media_type=media_type)

    # ----- Deterministic structure pass -----
    try:
        outline = parser.extract_outline(inputs)
        pages = parser.extract_text_by_page(inputs)
    except Exception as e:  # noqa: BLE001 — fail-tree-on-any-parser-error
        log.exception("structure pass failed for tree_id=%s", tree_id)
        _mark_failed(conn, tree_id, f"parser raised: {e}")
        return BuilderResult(tree_id, 0, 0, "failed", str(e))

    leaf_count = sum(1 for e in outline if _is_leaf_in_outline(e, outline))
    inputs_hash = deterministic_inputs_hash(
        parser.parser_kind, parser.parser_version, inputs)

    with conn.transaction():
        with conn.cursor() as cur:
            cur.execute("""
                SELECT maludb_core.page_index_record_structure_pass(
                    %s, %s, %s, %s, %s, %s, 'ok', NULL)""",
                (tree_id, parser.parser_kind, parser.parser_version,
                 len(outline), leaf_count, inputs_hash))

    # ----- Summarize + insert each node -----
    try:
        mdo_for_entry: dict[int, int] = {}  # ordinal -> mdo_id
        for entry in outline:
            parent_mdo = _resolve_parent_mdo(entry, outline, mdo_for_entry)
            node_kind = "leaf" if _is_leaf_in_outline(entry, outline) else "internal"
            node_text = _extract_anchor_text(entry, pages)

            req = SummarizationRequest(
                tree_id=tree_id,
                node_title=entry.title,
                node_text=node_text,
                node_kind=node_kind,
                parent_title=_parent_title(entry, outline))
            summary = summarizer.summarize(req)

            with conn.transaction():
                with conn.cursor() as cur:
                    cur.execute("""
                        SELECT mdo_id, derivation_id
                        FROM maludb_core.page_index_record_node(
                            %s, %s, %s, %s, %s, NULL, NULL, %s, %s, %s)
                    """, (tree_id, parent_mdo, node_kind,
                          entry.title, summary.summary,
                          summary.input_hash, summary.output_hash,
                          psycopg.types.json.Jsonb({
                              "start": entry.start_anchor,
                              "end":   entry.end_anchor,
                              "level": entry.level,
                              "ordinal": entry.ordinal,
                              "model_alias": summary.model_alias,
                              "prompt_template_version":
                                  summary.prompt_template_version,
                          })))
                    row = cur.fetchone()
                    mdo_for_entry[entry.ordinal] = int(row[0])
    except Exception as e:  # noqa: BLE001
        log.exception("summarization failed for tree_id=%s", tree_id)
        _mark_failed(conn, tree_id, f"summarizer raised: {e}")
        return BuilderResult(tree_id, len(outline), leaf_count, "failed", str(e))

    # ----- Transition to 'ready' -----
    with conn.transaction():
        with conn.cursor() as cur:
            cur.execute("SELECT maludb_core.page_index_tree_mark_ready(%s)",
                        (tree_id,))

    return BuilderResult(tree_id, len(outline), leaf_count, "ok", None)


# ---------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------

def _fetch_source(conn: psycopg.Connection,
                  source_package_id: int) -> tuple[bytes, str | None, str | None]:
    with conn.cursor() as cur:
        cur.execute("""
            SELECT content_bytes, content_text, media_type
              FROM maludb_core.malu$source_package
             WHERE source_package_id = %s
        """, (source_package_id,))
        row = cur.fetchone()
        if row is None:
            raise LookupError(f"source_package_id={source_package_id} not found")
        content_bytes, content_text, media_type = row
        if content_bytes is not None:
            return bytes(content_bytes), None, media_type
        if content_text is not None:
            return content_text.encode("utf-8"), None, media_type or "text/plain"
        raise LookupError(
            f"source_package_id={source_package_id} has no content_bytes or content_text")


def _is_leaf_in_outline(entry: OutlineEntry,
                        outline: list[OutlineEntry]) -> bool:
    """A node is a leaf iff no later sibling is at a deeper level
    before another entry at this entry's level or shallower."""
    idx = outline.index(entry)
    for later in outline[idx + 1:]:
        if later.level <= entry.level:
            return True
        if later.level == entry.level + 1:
            return False
    return True


def _resolve_parent_mdo(entry: OutlineEntry,
                        outline: list[OutlineEntry],
                        mdo_for_entry: dict[int, int]) -> int | None:
    if entry.level == 0:
        return None
    idx = outline.index(entry)
    for prior in reversed(outline[:idx]):
        if prior.level == entry.level - 1:
            return mdo_for_entry.get(prior.ordinal)
    return None


def _parent_title(entry: OutlineEntry,
                  outline: list[OutlineEntry]) -> str | None:
    if entry.level == 0:
        return None
    idx = outline.index(entry)
    for prior in reversed(outline[:idx]):
        if prior.level == entry.level - 1:
            return prior.title
    return None


def _extract_anchor_text(entry: OutlineEntry, pages: list[PageText]) -> str:
    """Slice the canonical text by the entry's anchor cursor.

    PDF anchors carry `page_first` / `page_last`; markdown anchors
    carry `line_first` / `line_last`; plain-text anchors carry
    `byte_first` / `byte_last`. The slicing is best-effort — a
    parser that produces a non-matching anchor type just hands the
    full document text to the summarizer.
    """
    if "page_first" in entry.start_anchor:
        first = entry.start_anchor["page_first"]
        last  = entry.end_anchor.get("page_last", first)
        return "\n".join(p.text for p in pages
                         if first <= p.page_number <= last)
    if "line_first" in entry.start_anchor:
        if pages and pages[0].page_number == 1:
            lines = pages[0].text.splitlines()
            first = entry.start_anchor["line_first"] - 1
            last  = entry.end_anchor.get("line_last", first + 1)
            return "\n".join(lines[first:last])
    return "\n".join(p.text for p in pages)


def _mark_failed(conn: psycopg.Connection, tree_id: int, reason: str) -> None:
    try:
        with conn.transaction():
            with conn.cursor() as cur:
                cur.execute(
                    "SELECT maludb_core.page_index_tree_mark_failed(%s, %s)",
                    (tree_id, reason))
    except Exception:
        log.exception("failed to mark tree %s as failed", tree_id)
