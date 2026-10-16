"""V4-PARSER-01 default PDF parser — pypdf, BSD-3-Clause.

Two extraction paths:

  1. PDFs with an embedded `/Outlines` tree — descend it and emit one
     `OutlineEntry` per outline item, anchoring each to the page range
     spanned by the destination page references.
  2. PDFs without an outline — emit a single root entry covering the
     full page range. Heuristic heading detection (font-size analysis,
     bookmark-from-headers, etc.) is explicitly out of V4 scope; the
     plan documents this as Open Decision §10.1.

Text extraction goes through `pypdf.PdfReader.pages[i].extract_text()`.
The output is concatenated page-by-page; the canonical byte ranges that
the builder writes into `malu$source_object_reference` use the (1-based)
page number as the cursor, not byte offsets in the extracted text, so
re-running extraction with a different pypdf minor version does not
invalidate prior anchors.
"""

from __future__ import annotations

import io
from typing import Any

from . import OutlineEntry, PageIndexParser, PageText, ParseInputs

try:  # pragma: no cover - import guard
    import pypdf
    _PYPDF_AVAILABLE = True
except ImportError:  # pragma: no cover
    _PYPDF_AVAILABLE = False


class PypdfParser:
    """PageIndexParser implementation backed by `pypdf`."""

    parser_kind = "pdf"

    @property
    def parser_version(self) -> str:
        if not _PYPDF_AVAILABLE:
            return "pypdf-unavailable"
        return f"pypdf-{pypdf.__version__}"

    # ------------------------------------------------------------------
    # Outline
    # ------------------------------------------------------------------

    def extract_outline(self, inputs: ParseInputs) -> list[OutlineEntry]:
        if not _PYPDF_AVAILABLE:
            raise RuntimeError(
                "pypdf is not installed; run "
                "`sudo apt-get install -y python3-pypdf` or "
                "`pip install pypdf>=4.0`.")

        reader = pypdf.PdfReader(io.BytesIO(inputs.source_bytes))
        total_pages = max(len(reader.pages), 1)

        outline = reader.outline if hasattr(reader, "outline") else []
        entries: list[OutlineEntry] = []
        if outline:
            self._walk_outline(reader, outline, 0, entries, [0])
        if not entries:
            # Degenerate: no outline at all. Emit a single root entry
            # spanning the whole document so the builder still has a
            # single-leaf tree to attach summaries to.
            entries.append(OutlineEntry(
                title=inputs.filename or "Document",
                level=0,
                start_anchor={"page_first": 1},
                end_anchor={"page_last": total_pages},
                ordinal=0))
        return entries

    def _walk_outline(self,
                      reader: "pypdf.PdfReader",
                      nodes: list[Any],
                      level: int,
                      out: list[OutlineEntry],
                      counter: list[int]) -> None:
        """Recursive walker.

        pypdf's outline is a nested list: each item is either a
        Destination (leaf-ish bookmark) or a list of children belonging
        to the previous Destination at the parent level.
        """
        i = 0
        while i < len(nodes):
            node = nodes[i]
            if isinstance(node, list):
                # children of the previous sibling — handled in tandem
                i += 1
                continue

            title = self._destination_title(node)
            start_page = self._destination_page(reader, node)

            # Look ahead for children at level+1 (a list immediately
            # following the destination is the upstream convention).
            children: list[Any] = []
            if i + 1 < len(nodes) and isinstance(nodes[i + 1], list):
                children = nodes[i + 1]

            # Look ahead to the *next* sibling at this level to bound
            # end_page; if none, use the document end.
            end_page = self._next_sibling_page(reader, nodes, i, len(reader.pages))

            ordinal = counter[0]
            counter[0] += 1
            out.append(OutlineEntry(
                title=title,
                level=level,
                start_anchor={"page_first": start_page},
                end_anchor={"page_last": end_page},
                ordinal=ordinal))

            if children:
                self._walk_outline(reader, children, level + 1, out, counter)
                i += 2
            else:
                i += 1

    @staticmethod
    def _destination_title(node: Any) -> str:
        title = getattr(node, "title", None)
        if title is None and isinstance(node, dict):
            title = node.get("/Title")
        if title is None:
            return "(untitled)"
        return str(title).strip() or "(untitled)"

    @staticmethod
    def _destination_page(reader: "pypdf.PdfReader", node: Any) -> int:
        try:
            page_index = reader.get_destination_page_number(node)
            return int(page_index) + 1
        except Exception:
            return 1

    @classmethod
    def _next_sibling_page(cls,
                           reader: "pypdf.PdfReader",
                           nodes: list[Any],
                           i: int,
                           total_pages: int) -> int:
        # Skip the children block (a list) if present.
        j = i + 1
        if j < len(nodes) and isinstance(nodes[j], list):
            j += 1
        while j < len(nodes):
            if isinstance(nodes[j], list):
                j += 1
                continue
            try:
                idx = reader.get_destination_page_number(nodes[j])
                return max(int(idx), 1)
            except Exception:
                return total_pages
        return total_pages

    # ------------------------------------------------------------------
    # Text by page
    # ------------------------------------------------------------------

    def extract_text_by_page(self, inputs: ParseInputs) -> list[PageText]:
        if not _PYPDF_AVAILABLE:
            raise RuntimeError(
                "pypdf is not installed; run "
                "`sudo apt-get install -y python3-pypdf`.")

        reader = pypdf.PdfReader(io.BytesIO(inputs.source_bytes))
        out: list[PageText] = []
        for i, page in enumerate(reader.pages, start=1):
            try:
                text = page.extract_text() or ""
            except Exception:
                text = ""
            out.append(PageText(page_number=i, text=text))
        if not out:
            out.append(PageText(page_number=1, text=""))
        return out
