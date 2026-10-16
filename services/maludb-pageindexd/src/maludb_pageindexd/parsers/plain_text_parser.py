"""V4-PARSER-01 plain-text fallback parser.

Plain text has no structure. The outline is one entry covering the
whole document; the text-by-page output is one page whose number is 1.

A future ticket may add paragraph- or section-break heuristics; v4
keeps it intentionally degenerate so the cost of routing text to a
PageIndex tree is bounded.
"""

from __future__ import annotations

from . import OutlineEntry, PageIndexParser, PageText, ParseInputs


class PlainTextParser:
    """PageIndexParser for plain text."""

    parser_kind = "plain_text"
    parser_version = "stdlib-1"

    def extract_outline(self, inputs: ParseInputs) -> list[OutlineEntry]:
        size = len(inputs.source_bytes)
        return [OutlineEntry(
            title=inputs.filename or "Document",
            level=0,
            start_anchor={"byte_first": 0},
            end_anchor={"byte_last": max(size, 0)},
            ordinal=0)]

    def extract_text_by_page(self, inputs: ParseInputs) -> list[PageText]:
        text = inputs.source_bytes.decode("utf-8", errors="replace")
        return [PageText(page_number=1, text=text)]
