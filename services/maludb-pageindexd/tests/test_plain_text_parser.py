"""V4-PARSER-01 — plain-text parser smoke."""

from __future__ import annotations

import unittest

from maludb_pageindexd.parsers import (
    ParseInputs,
    parser_for_kind,
    parser_for_media_type,
)


class PlainTextParserTests(unittest.TestCase):
    def setUp(self) -> None:
        self.parser = parser_for_kind("plain_text")

    def test_resolves_via_media_type_too(self) -> None:
        self.assertIs(self.parser, parser_for_media_type("text/plain"))

    def test_single_root_entry_covers_whole_document(self) -> None:
        body = b"line one\nline two\nline three\n"
        outline = self.parser.extract_outline(
            ParseInputs(source_bytes=body, filename="note.txt"))
        self.assertEqual(len(outline), 1)
        self.assertEqual(outline[0].title, "note.txt")
        self.assertEqual(outline[0].start_anchor, {"byte_first": 0})
        self.assertEqual(outline[0].end_anchor, {"byte_last": len(body)})

    def test_text_round_trip(self) -> None:
        body = "fixture body".encode("utf-8")
        pages = self.parser.extract_text_by_page(ParseInputs(source_bytes=body))
        self.assertEqual(len(pages), 1)
        self.assertEqual(pages[0].text, "fixture body")

    def test_empty_document(self) -> None:
        outline = self.parser.extract_outline(ParseInputs(source_bytes=b""))
        self.assertEqual(len(outline), 1)
        self.assertEqual(outline[0].end_anchor["byte_last"], 0)


if __name__ == "__main__":
    unittest.main()
