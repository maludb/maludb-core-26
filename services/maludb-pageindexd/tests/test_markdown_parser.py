"""V4-PARSER-01 — markdown parser smoke.

Three reference markdown documents:
  1. Standard `#` / `##` hierarchy → entries at multiple levels.
  2. No headers → single root entry covering the document.
  3. Headers inside a fenced code block → ignored (not added to the
     outline; the structure pass MUST be insensitive to syntax that
     only looks like headers).
"""

from __future__ import annotations

import unittest

from maludb_pageindexd.parsers import (
    ParseInputs,
    parser_for_kind,
    parser_for_media_type,
)


HIERARCHY = """\
# Introduction
Some intro text.

## Background
History of the system.

## Methods
Details of the method.

### Step 1
Subdetail.

### Step 2
Subdetail.

# Results
Outcome.
"""

NO_HEADERS = """\
Just a flat note with no `#` headers.
A few lines of body text.
Goodbye.
"""

WITH_FENCE = """\
# Real Header
Body.

```
# This looks like a header but it is inside a fence
## Same here
```

# Another Real Header
"""


class MarkdownParserTests(unittest.TestCase):
    def setUp(self) -> None:
        self.parser = parser_for_kind("markdown")

    def test_resolves_via_media_type_too(self) -> None:
        self.assertIs(self.parser, parser_for_media_type("text/markdown"))

    def test_hierarchical_outline(self) -> None:
        outline = self.parser.extract_outline(
            ParseInputs(source_bytes=HIERARCHY.encode("utf-8"),
                        media_type="text/markdown"))
        titles = [(e.title, e.level) for e in outline]
        self.assertIn(("Introduction", 0), titles)
        self.assertIn(("Background", 1), titles)
        self.assertIn(("Methods", 1), titles)
        self.assertIn(("Step 1", 2), titles)
        self.assertIn(("Step 2", 2), titles)
        self.assertIn(("Results", 0), titles)

        # "Methods" should cover "Step 1" and "Step 2" — its line range
        # ends right before "Results".
        methods = next(e for e in outline if e.title == "Methods")
        results = next(e for e in outline if e.title == "Results")
        self.assertLess(methods.start_anchor["line_first"],
                        results.start_anchor["line_first"])
        self.assertLess(methods.end_anchor["line_last"],
                        results.start_anchor["line_first"])

    def test_no_headers_yields_single_root_entry(self) -> None:
        outline = self.parser.extract_outline(
            ParseInputs(source_bytes=NO_HEADERS.encode("utf-8"),
                        filename="note.md"))
        self.assertEqual(len(outline), 1)
        self.assertEqual(outline[0].title, "note.md")
        self.assertEqual(outline[0].level, 0)
        self.assertEqual(outline[0].start_anchor["line_first"], 1)
        self.assertGreaterEqual(outline[0].end_anchor["line_last"], 1)

    def test_fenced_code_block_headers_are_ignored(self) -> None:
        outline = self.parser.extract_outline(
            ParseInputs(source_bytes=WITH_FENCE.encode("utf-8")))
        titles = [e.title for e in outline]
        self.assertEqual(titles, ["Real Header", "Another Real Header"])

    def test_extract_text_by_page_is_single_unit(self) -> None:
        pages = self.parser.extract_text_by_page(
            ParseInputs(source_bytes=HIERARCHY.encode("utf-8")))
        self.assertEqual(len(pages), 1)
        self.assertEqual(pages[0].page_number, 1)
        self.assertIn("# Introduction", pages[0].text)


if __name__ == "__main__":
    unittest.main()
