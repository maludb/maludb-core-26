"""Pluggable parser interface for PageIndex tree builders.

The deterministic structure pass calls a parser to extract the outline
(future tree skeleton) and the text-by-page mapping (anchors and
canonical text for embedding). Summarization runs separately against
the model gateway; parsers MUST NOT call the LLM.

A parser is anything that implements the `PageIndexParser` Protocol
below. The three bundled implementations cover the V4 default surface:

  * `pypdf_parser.PypdfParser`    — PDFs with embedded `/Outlines`
                                    (BSD-3-Clause, system package
                                    `python3-pypdf`)
  * `markdown_parser.MarkdownParser` — markdown by `#`-prefixed headers
                                       (stdlib only)
  * `plain_text_parser.PlainTextParser` — fallback single-leaf tree

Operators may register additional implementations through
`register_parser` and reach them via `parser_for_kind('pdf')` or
`parser_for_media_type('application/pdf')`.
"""

from __future__ import annotations

import hashlib
from dataclasses import dataclass, field
from typing import Any, Protocol, Union, runtime_checkable

__all__ = [
    "OutlineEntry",
    "PageText",
    "ParseInputs",
    "PageIndexParser",
    "register_parser",
    "parser_for_kind",
    "parser_for_media_type",
    "deterministic_inputs_hash",
]


PathLike = Union[str, "bytes", "os.PathLike[str]"]  # type: ignore[name-defined]


@dataclass(frozen=True)
class OutlineEntry:
    """One entry in the deterministic outline.

    `level` is the depth in the tree (0 = top-level). `start_anchor`
    and `end_anchor` carry the source-format-specific cursor that lets
    the builder map this entry back to source bytes. PDF parsers use
    `{"page_first": N, "page_last": N}`; markdown parsers use
    `{"line_first": N, "line_last": N}`; plain-text parsers use
    `{"byte_first": 0, "byte_last": len}`.
    """

    title: str
    level: int
    start_anchor: dict[str, Any]
    end_anchor: dict[str, Any]
    ordinal: int = 0


@dataclass(frozen=True)
class PageText:
    """One unit of text-by-page output.

    For paginated parsers `page_number` is the 1-based PDF page index.
    For markdown / plain-text parsers `page_number = 1` and the entire
    document text lives in a single `PageText`.
    """

    page_number: int
    text: str


@dataclass(frozen=True)
class ParseInputs:
    """The bytes consumed by a parser run.

    `source_bytes` is the canonical input — PDF bytes for a PDF
    parser, UTF-8 markdown bytes for a markdown parser, raw bytes for
    plain text. `media_type` is optional and only used by dispatch.
    """

    source_bytes: bytes
    media_type: str | None = None
    filename: str | None = None


@runtime_checkable
class PageIndexParser(Protocol):
    """Protocol for V4 PageIndex parsers.

    Implementations declare their `parser_kind` (matches the
    `malu$page_index_tree.parser_kind` enum: `'pdf'`, `'markdown'`,
    `'plain_text'`) and `parser_version` (recorded in
    `malu$structure_pass_audit.parser_version`). Both fields MUST
    be stable across runs against the same source bytes.

    `extract_outline` returns the outline in document order; an empty
    outline is allowed for degenerate inputs and indicates a
    single-leaf tree.

    `extract_text_by_page` returns the canonical text. For
    paginated formats the list is ordered by `page_number`.
    """

    parser_kind: str
    parser_version: str

    def extract_outline(self, inputs: ParseInputs) -> list[OutlineEntry]:
        ...

    def extract_text_by_page(self, inputs: ParseInputs) -> list[PageText]:
        ...


# ---------------------------------------------------------------------
# Registry
# ---------------------------------------------------------------------

_REGISTRY_BY_KIND: dict[str, PageIndexParser] = {}
_REGISTRY_BY_MEDIA_TYPE: dict[str, PageIndexParser] = {}


def register_parser(parser: PageIndexParser,
                    media_types: list[str] | None = None) -> None:
    """Register a parser by its kind and (optionally) media types."""
    _REGISTRY_BY_KIND[parser.parser_kind] = parser
    for mt in media_types or []:
        _REGISTRY_BY_MEDIA_TYPE[mt] = parser


def parser_for_kind(kind: str) -> PageIndexParser:
    if kind not in _REGISTRY_BY_KIND:
        raise KeyError(
            f"no parser registered for kind={kind!r}; "
            f"registered: {sorted(_REGISTRY_BY_KIND)}")
    return _REGISTRY_BY_KIND[kind]


def parser_for_media_type(media_type: str) -> PageIndexParser:
    if media_type not in _REGISTRY_BY_MEDIA_TYPE:
        raise KeyError(
            f"no parser registered for media_type={media_type!r}; "
            f"registered: {sorted(_REGISTRY_BY_MEDIA_TYPE)}")
    return _REGISTRY_BY_MEDIA_TYPE[media_type]


def deterministic_inputs_hash(parser_kind: str,
                              parser_version: str,
                              inputs: ParseInputs) -> str:
    """Hash that pins the deterministic structure pass.

    Recorded on every `malu$structure_pass_audit` row so a re-derivation
    that yields the same hash is guaranteed to produce the same outline.
    """
    h = hashlib.sha256()
    h.update(parser_kind.encode("utf-8"))
    h.update(b"\x00")
    h.update(parser_version.encode("utf-8"))
    h.update(b"\x00")
    h.update(inputs.source_bytes)
    return h.hexdigest()


# Eagerly register bundled parsers so callers can import the package
# and call `parser_for_kind` without per-call setup.
from .pypdf_parser import PypdfParser            # noqa: E402
from .markdown_parser import MarkdownParser      # noqa: E402
from .plain_text_parser import PlainTextParser   # noqa: E402

register_parser(PypdfParser(), media_types=["application/pdf"])
register_parser(MarkdownParser(),
                media_types=["text/markdown", "text/x-markdown"])
register_parser(PlainTextParser(), media_types=["text/plain"])
