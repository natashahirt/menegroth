"""Hermetic unit tests for the corpus MCP tool functions.

These tests build a self-contained fixture corpus in a temporary directory
so they do not depend on whether ``corpus/`` has been ingested. Each test
exercises the tool function directly (the MCP transport layer is a thin
adapter on top, so it is excluded from this test suite).

Run directly::

    python3 scripts/corpus/tests/test_mcp_tools.py

Or via stdlib unittest discovery::

    python3 -m unittest discover -s scripts/corpus/tests
"""

from __future__ import annotations

import json
import sys
import textwrap
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from scripts.corpus.mcp_tools import (  # noqa: E402
    CorpusIndex,
    get_clause,
    get_extraction_by_id,
    get_source_text,
    list_sources,
    page_window,
    search_by_attributes,
    search_extractions,
    search_text,
)


PAGE_BAR = "=" * 60


def _page(num: int, body: str) -> str:
    return f"\n{PAGE_BAR}\nPAGE {num}\n{PAGE_BAR}\n{body}\n"


class FixtureCorpusBase(unittest.TestCase):
    """Build a tiny corpus + manifest + extractions in a temp directory."""

    @classmethod
    def setUpClass(cls):
        import tempfile

        cls.tmpdir_obj = tempfile.TemporaryDirectory()
        cls.repo = Path(cls.tmpdir_obj.name)
        (cls.repo / "corpus" / "text" / "codes" / "aci").mkdir(parents=True)
        (cls.repo / "corpus" / "text" / "codes" / "aisc").mkdir(parents=True)
        (cls.repo / "corpus" / "manifests").mkdir(parents=True)
        (cls.repo / "corpus" / "extractions").mkdir(parents=True)

        # Two sources: ACI 318 (regular) and AISC 360 (regular).
        aci_text = (
            _page(1, "ACI 318-19 §22.4.2.1\nThe nominal strength shall be ...")
            + _page(2, "Strength reduction factor phi = 0.65 for compression-controlled.")
        )
        aisc_text = (
            _page(1, "Section F2 - Doubly Symmetric Compact I-Shaped Members.")
            + _page(2, "The nominal flexural strength M_n shall be the lower value ...")
        )
        (cls.repo / "corpus" / "text" / "codes" / "aci" / "aci318.txt").write_text(aci_text)
        (cls.repo / "corpus" / "text" / "codes" / "aisc" / "aisc360.txt").write_text(aisc_text)

        manifest = textwrap.dedent("""\
            - id: aci-318
              origin: irrelevant.pdf
              source_path: corpus/sources/codes/aci/aci318.pdf
              text_path:   corpus/text/codes/aci/aci318.txt
              family: aci
              role: codes
              edition: ACI 318-19
              tier: 1
              encrypted: false
              notes: ""

            - id: aisc-360
              origin: irrelevant.pdf
              source_path: corpus/sources/codes/aisc/aisc360.pdf
              text_path:   corpus/text/codes/aisc/aisc360.txt
              family: aisc
              role: codes
              edition: AISC 360-16
              tier: 1
              encrypted: false
              notes: ""
            """)
        (cls.repo / "corpus" / "manifests" / "sources.yml").write_text(manifest)

        # One extraction file with three rows: two grounded, one ungrounded.
        ext_dir = cls.repo / "corpus" / "extractions" / "phi_factors" / "codes" / "aci"
        ext_dir.mkdir(parents=True)
        rows = [
            {
                "extraction_id": "phi-001",
                "extraction_class": "phi_factor",
                "extraction_text": "phi = 0.65",
                "attributes": {
                    "clause_id": "ACI 318-19 §21.2.2",
                    "value": 0.65,
                    "member_type": "compression-controlled",
                    "spiral": False,
                },
                "char_interval": {"start_pos": 100, "end_pos": 110},
            },
            {
                "extraction_id": "phi-002",
                "extraction_class": "phi_factor",
                "extraction_text": "phi = 0.90",
                "attributes": {
                    "clause_id": "ACI 318-19 §21.2.2",
                    "value": 0.90,
                    "member_type": "tension-controlled",
                },
                "char_interval": {"start_pos": 0, "end_pos": 10},
            },
            {
                "extraction_id": "phi-bad",
                "extraction_class": "phi_factor",
                "extraction_text": "(model hallucinated)",
                "attributes": {},
                "char_interval": None,
            },
        ]
        ext_path = ext_dir / "aci318.jsonl"
        ext_path.write_text("\n".join(json.dumps(r) for r in rows))

        cls.index = CorpusIndex(
            repo_root=cls.repo,
            manifest_path=cls.repo / "corpus" / "manifests" / "sources.yml",
            extractions_root=cls.repo / "corpus" / "extractions",
        )

    @classmethod
    def tearDownClass(cls):
        cls.tmpdir_obj.cleanup()


class TestSourceTools(FixtureCorpusBase):

    def test_list_sources_filters_by_family(self):
        env = list_sources(self.index, family="aci")
        self.assertEqual(env.status, "ok")
        self.assertEqual([s.id for s in env.results], ["aci-318"])

    def test_list_sources_limit_marks_truncated(self):
        env = list_sources(self.index, limit=1)
        self.assertTrue(env.truncated)
        self.assertEqual(len(env.results), 1)

    def test_get_source_text_slice(self):
        env = get_source_text(self.index, "aci-318", char_start=0, char_end=50)
        self.assertEqual(env.status, "ok")
        self.assertEqual(len(env.results[0].match_text), 50)

    def test_get_source_text_unknown_id(self):
        env = get_source_text(self.index, "does-not-exist")
        self.assertEqual(env.status, "error")


class TestSearchText(FixtureCorpusBase):

    def test_substring_search_hits(self):
        env = search_text(self.index, "phi", family="aci", max_results=10)
        self.assertEqual(env.status, "ok")
        self.assertGreaterEqual(len(env.results), 1)
        # Source provenance + offsets are always present.
        hit = env.results[0]
        self.assertEqual(hit.source.id, "aci-318")
        self.assertGreaterEqual(hit.char_interval.start, 0)
        self.assertGreater(hit.char_interval.end, hit.char_interval.start)

    def test_search_returns_page_range(self):
        env = search_text(self.index, "phi", family="aci")
        hit = env.results[0]
        self.assertIsNotNone(hit.page_range)
        # The substring appears on page 2 of the fixture.
        self.assertEqual(hit.page_range.start, 2)

    def test_empty_query_is_error(self):
        env = search_text(self.index, "")
        self.assertEqual(env.status, "error")


class TestPageWindow(FixtureCorpusBase):

    def test_page_window_returns_requested_pages(self):
        env = page_window(self.index, "aci-318", 1, 2)
        self.assertEqual(env.status, "ok")
        match_text = env.results[0].match_text
        self.assertIn("ACI 318-19", match_text)
        self.assertIn("phi = 0.65", match_text)

    def test_page_window_invalid_range(self):
        env = page_window(self.index, "aci-318", 5, 2)
        self.assertEqual(env.status, "error")


class TestExtractions(FixtureCorpusBase):

    def test_search_extractions_filters_class(self):
        env = search_extractions(self.index, extraction_class="phi_factor")
        self.assertEqual(env.status, "ok")
        # Two grounded entries, one filtered out (char_interval is null).
        self.assertEqual(len(env.results), 2)
        self.assertTrue(all(h.char_interval.end > h.char_interval.start for h in env.results))

    def test_search_extractions_attribute_filter(self):
        env = search_by_attributes(
            self.index, "phi_factor", {"member_type": "tension-controlled"},
        )
        self.assertEqual(len(env.results), 1)
        self.assertEqual(env.results[0].extraction_id, "phi-002")

    def test_get_extraction_by_id(self):
        env = get_extraction_by_id(self.index, "phi-001")
        self.assertEqual(env.status, "ok")
        self.assertEqual(env.results[0].attributes["value"], 0.65)

    def test_get_extraction_by_id_missing(self):
        env = get_extraction_by_id(self.index, "no-such-id")
        self.assertEqual(env.status, "error")

    def test_no_extractions_envelope(self):
        # Use a fresh index pointing at an empty extractions root.
        empty_index = CorpusIndex(
            repo_root=self.repo,
            manifest_path=self.repo / "corpus" / "manifests" / "sources.yml",
            extractions_root=self.repo / "corpus" / "no_extractions_here",
        )
        env = search_extractions(empty_index, "phi_factor")
        self.assertEqual(env.status, "no_extractions_available")
        self.assertIsNotNone(env.hint)


class TestGetClause(FixtureCorpusBase):

    def test_get_clause_extraction_match_preferred(self):
        env = get_clause(self.index, "aci", "ACI 318-19", "ACI 318-19 §21.2.2")
        self.assertEqual(env.status, "ok")
        result = env.results[0]
        self.assertEqual(result.confidence, "extracted")
        self.assertIsNotNone(result.extraction)

    def test_get_clause_text_fallback(self):
        # No extraction has clause_id == "F2"; the AISC text-match heuristic
        # should still find the heading on page 1.
        env = get_clause(self.index, "aisc", "AISC 360-16", "F2")
        result = env.results[0]
        self.assertEqual(result.confidence, "text-match")
        self.assertIsNotNone(result.hit)
        self.assertEqual(result.hit.page_range.start, 1)

    def test_get_clause_not_found(self):
        env = get_clause(self.index, "aisc", "AISC 360-16", "ZZZ-NOPE")
        result = env.results[0]
        self.assertEqual(result.confidence, "not-found")


if __name__ == "__main__":
    unittest.main()
