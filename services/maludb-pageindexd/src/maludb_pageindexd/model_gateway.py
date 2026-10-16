"""Model gateway client for per-node summarization.

The V4-PAGEINDEX-02 builder calls this once per outline node to obtain
a short natural-language summary. The default implementation is an
HTTP client that POSTs to `MALUDB_MODELD_URL` (the maludb_modeld
gateway), but the real wire format is out of scope for v4.0.0-alpha.2 —
we ship a `LocalDeterministicSummarizer` that derives the summary from
the node's anchor / title / extracted body, so the builder is testable
end-to-end without an LLM in the loop.

Operators wire a real summarizer in via the `--summarizer` CLI flag
(or by constructing one programmatically in tests).
"""

from __future__ import annotations

import hashlib
from dataclasses import dataclass
from typing import Protocol


@dataclass(frozen=True)
class SummarizationRequest:
    tree_id: int
    node_title: str
    node_text: str         # concatenated leaf bytes
    node_kind: str         # "internal" | "leaf"
    parent_title: str | None = None
    document_subject: str | None = None


@dataclass(frozen=True)
class SummarizationResult:
    summary: str
    model_alias: str
    prompt_template_version: str
    input_hash: bytes
    output_hash: bytes


class Summarizer(Protocol):
    model_alias: str
    prompt_template_version: str

    def summarize(self, req: SummarizationRequest) -> SummarizationResult:
        ...


class LocalDeterministicSummarizer:
    """Test / offline summarizer.

    Produces a one-line summary derived from the title and a 200-byte
    excerpt of the node text. Hashes mirror what a real LLM gateway
    would record. Determinism is the point — the builder's
    supersession-on-re-derivation tests can compare summaries across
    runs without a live model.
    """

    model_alias = "deterministic-test"
    prompt_template_version = "local-1"

    def summarize(self, req: SummarizationRequest) -> SummarizationResult:
        excerpt = req.node_text.strip().replace("\n", " ")[:200]
        if excerpt:
            summary = f"{req.node_title}: {excerpt}"
        else:
            summary = req.node_title
        in_h = hashlib.sha256()
        in_h.update(req.node_title.encode("utf-8"))
        in_h.update(b"\x00")
        in_h.update(req.node_text.encode("utf-8"))
        out_h = hashlib.sha256(summary.encode("utf-8"))
        return SummarizationResult(
            summary=summary,
            model_alias=self.model_alias,
            prompt_template_version=self.prompt_template_version,
            input_hash=in_h.digest(),
            output_hash=out_h.digest())
