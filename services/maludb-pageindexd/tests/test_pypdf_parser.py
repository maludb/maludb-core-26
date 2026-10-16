"""V4-PARSER-01 — `pypdf` parser smoke.

Three reference cases per the V4 plan:
  1. PDF with an embedded `/Outlines` tree → outline picks up titles
     and page ranges.
  2. PDF without an outline → degenerate single-leaf root entry.
  3. Single-page PDF → still produces a usable outline.

PDFs are generated in-process with `pypdf.PdfWriter` so the test
suite has no binary-fixture dependencies.
"""

from __future__ import annotations

import io
import unittest

import pypdf

from maludb_pageindexd.parsers import (
    ParseInputs,
    deterministic_inputs_hash,
    parser_for_kind,
    parser_for_media_type,
)


def _empty_page_pdf(num_pages: int) -> bytes:
    writer = pypdf.PdfWriter()
    for _ in range(num_pages):
        writer.add_blank_page(width=612, height=792)
    buf = io.BytesIO()
    writer.write(buf)
    return buf.getvalue()


def _outlined_pdf() -> bytes:
    writer = pypdf.PdfWriter()
    pages = [writer.add_blank_page(width=612, height=792) for _ in range(6)]
    intro = writer.add_outline_item("Introduction", 0)
    writer.add_outline_item("Background", 1, parent=intro)
    writer.add_outline_item("Methods", 2)
    writer.add_outline_item("Results", 4)
    buf = io.BytesIO()
    writer.write(buf)
    return buf.getvalue()


class PypdfParserTests(unittest.TestCase):
    def setUp(self) -> None:
        self.parser = parser_for_kind("pdf")

    def test_resolves_via_media_type_too(self) -> None:
        self.assertIs(self.parser, parser_for_media_type("application/pdf"))

    def test_outlined_pdf_yields_hierarchical_outline(self) -> None:
        pdf = _outlined_pdf()
        outline = self.parser.extract_outline(
            ParseInputs(source_bytes=pdf, media_type="application/pdf"))
        titles = [e.title for e in outline]
        self.assertIn("Introduction", titles)
        self.assertIn("Background", titles)
        self.assertIn("Methods", titles)
        self.assertIn("Results", titles)

        # Background is nested under Introduction.
        intro = next(e for e in outline if e.title == "Introduction")
        bg = next(e for e in outline if e.title == "Background")
        self.assertEqual(intro.level, 0)
        self.assertEqual(bg.level, 1)

        # Anchors carry page numbers.
        for entry in outline:
            self.assertIn("page_first", entry.start_anchor)
            self.assertIn("page_last", entry.end_anchor)
            self.assertGreaterEqual(entry.start_anchor["page_first"], 1)
            self.assertGreaterEqual(
                entry.end_anchor["page_last"], entry.start_anchor["page_first"])

    def test_pdf_without_outline_yields_single_root_entry(self) -> None:
        pdf = _empty_page_pdf(3)
        outline = self.parser.extract_outline(
            ParseInputs(source_bytes=pdf, filename="bare.pdf"))
        self.assertEqual(len(outline), 1)
        self.assertEqual(outline[0].level, 0)
        self.assertEqual(outline[0].start_anchor["page_first"], 1)
        self.assertEqual(outline[0].end_anchor["page_last"], 3)
        self.assertEqual(outline[0].title, "bare.pdf")

    def test_single_page_pdf_is_usable(self) -> None:
        pdf = _empty_page_pdf(1)
        outline = self.parser.extract_outline(ParseInputs(source_bytes=pdf))
        self.assertEqual(len(outline), 1)
        self.assertEqual(outline[0].end_anchor["page_last"], 1)
        pages = self.parser.extract_text_by_page(ParseInputs(source_bytes=pdf))
        self.assertEqual(len(pages), 1)
        self.assertEqual(pages[0].page_number, 1)

    def test_deterministic_inputs_hash_stable(self) -> None:
        pdf = _empty_page_pdf(2)
        inputs = ParseInputs(source_bytes=pdf)
        h1 = deterministic_inputs_hash(
            self.parser.parser_kind, self.parser.parser_version, inputs)
        h2 = deterministic_inputs_hash(
            self.parser.parser_kind, self.parser.parser_version, inputs)
        self.assertEqual(h1, h2)
        self.assertEqual(len(h1), 64)  # sha256 hex


if __name__ == "__main__":
    unittest.main()
