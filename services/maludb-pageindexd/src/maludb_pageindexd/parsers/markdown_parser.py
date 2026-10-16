"""V4-PARSER-01 markdown parser — stdlib only.

Outline = the document's `#`-prefixed headers (ATX style; setext
underline headings are out of scope for v1). Each header opens an
entry whose page range covers the lines from the header itself up to
the line before the next header at the same or shallower level (or
EOF). Indented `#` characters inside fenced code blocks are ignored.

Re-running the parser on identical bytes is guaranteed to produce
identical outlines, which is the determinism contract for the V4
structure pass.
"""

from __future__ import annotations

import re

from . import OutlineEntry, PageIndexParser, PageText, ParseInputs

_HEADER_RE = re.compile(r"^(#{1,6})\s+(.*?)\s*$")
_FENCE_RE = re.compile(r"^\s{0,3}(```|~~~)")


class MarkdownParser:
    """PageIndexParser for markdown, stdlib-only."""

    parser_kind = "markdown"
    parser_version = "stdlib-1"

    def extract_outline(self, inputs: ParseInputs) -> list[OutlineEntry]:
        text = inputs.source_bytes.decode("utf-8", errors="replace")
        lines = text.splitlines()

        headers: list[tuple[int, int, str]] = []  # (line_no_1based, level, title)
        in_fence = False
        fence_marker = ""
        for idx, line in enumerate(lines, start=1):
            fence_match = _FENCE_RE.match(line)
            if fence_match:
                if not in_fence:
                    in_fence = True
                    fence_marker = fence_match.group(1)
                elif line.lstrip().startswith(fence_marker):
                    in_fence = False
                continue
            if in_fence:
                continue
            hm = _HEADER_RE.match(line)
            if hm:
                level = len(hm.group(1)) - 1   # `#` -> level 0
                title = hm.group(2).strip()
                headers.append((idx, level, title))

        if not headers:
            return [OutlineEntry(
                title=inputs.filename or "Document",
                level=0,
                start_anchor={"line_first": 1},
                end_anchor={"line_last": max(len(lines), 1)},
                ordinal=0)]

        entries: list[OutlineEntry] = []
        for i, (line_no, level, title) in enumerate(headers):
            end_line = len(lines)
            for j in range(i + 1, len(headers)):
                next_line, next_level, _ = headers[j]
                if next_level <= level:
                    end_line = next_line - 1
                    break
            entries.append(OutlineEntry(
                title=title,
                level=level,
                start_anchor={"line_first": line_no},
                end_anchor={"line_last": max(end_line, line_no)},
                ordinal=i))
        return entries

    def extract_text_by_page(self, inputs: ParseInputs) -> list[PageText]:
        text = inputs.source_bytes.decode("utf-8", errors="replace")
        return [PageText(page_number=1, text=text)]
