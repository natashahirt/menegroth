#!/usr/bin/env python3
"""Corpus MCP server (stdio transport).

Exposes the building-code corpus and (when present) LangExtract structured
extractions as queryable MCP tools, so the Cursor agent can call typed
queries instead of grepping raw files.

Tools (see ``scripts/corpus/mcp_tools.py`` for implementations):

- ``corpus.list_sources``        - browse manifest entries.
- ``corpus.get_source_text``     - read a slice of a source's normalized text.
- ``corpus.search_text``         - regex/substring search across corpus/text/.
- ``corpus.page_window``         - read text spanning a PDF page range.
- ``corpus.search_extractions``  - query LangExtract JSONL by class/attributes.
- ``corpus.get_extraction_by_id``- fetch a single extraction by stable id.
- ``corpus.search_by_attributes``- typed attribute filter for a class.
- ``corpus.get_clause``          - best-effort clause lookup (extraction first,
                                   then text-match fallback).

Pre-extraction state: extraction tools return a structured
``no_extractions_available`` envelope rather than failing, so the server is
useful from day one for text search.

Registration (one-time, user-level Cursor config — typically
``~/.cursor/mcp.json`` or equivalent)::

    {
      "mcpServers": {
        "menegroth-corpus": {
          "command": "python3",
          "args": ["scripts/corpus/mcp_server.py"],
          "cwd": "/absolute/path/to/menegroth"
        }
      }
    }

The server depends on the official MCP Python SDK (``pip install mcp``).
PyYAML is reused from the corpus ingest CLI.
"""

from __future__ import annotations

import sys
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parents[2]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from scripts.corpus.mcp_tools import (  # noqa: E402  (path setup before import)
    CorpusIndex,
    envelope_to_dict,
    get_clause as _get_clause,
    get_extraction_by_id as _get_extraction_by_id,
    get_source_text as _get_source_text,
    list_sources as _list_sources,
    page_window as _page_window,
    search_by_attributes as _search_by_attributes,
    search_extractions as _search_extractions,
    search_text as _search_text,
)


def _import_mcp():
    """Import the official MCP Python SDK with a friendly error if missing."""
    try:
        from mcp.server.fastmcp import FastMCP  # type: ignore
    except ImportError as exc:
        sys.stderr.write(
            "ERROR: the `mcp` Python SDK is required to run this server.\n"
            "Install it with: pip install mcp\n"
            f"Original import error: {exc}\n"
        )
        raise SystemExit(2)
    return FastMCP


def build_server() -> Any:
    """Construct a configured ``FastMCP`` server with all corpus tools registered."""
    FastMCP = _import_mcp()
    server = FastMCP("menegroth-corpus")
    index = CorpusIndex()

    @server.tool()
    def list_sources(
        family: str | None = None,
        role: str | None = None,
        tier: int | None = None,
        edition: str | None = None,
        limit: int | None = None,
    ) -> dict:
        """List manifest entries from the curated corpus.

        Use this to discover which standards / guides / examples the corpus
        contains before issuing more specific queries. Filters: family
        (aci|aisc|csa|fib|...), role (codes|code_guides|examples|research|
        textbooks), tier, and a substring match on edition.
        """
        return envelope_to_dict(_list_sources(
            index, family=family, role=role, tier=tier, edition=edition, limit=limit,
        ))

    @server.tool()
    def get_source_text(
        source_id: str,
        char_start: int | None = None,
        char_end: int | None = None,
        max_chars: int = 20_000,
    ) -> dict:
        """Read a slice of a source's normalized text by character offsets.

        Capped at ``max_chars``. For page-based reads use ``page_window``.
        """
        return envelope_to_dict(_get_source_text(
            index, source_id,
            char_start=char_start, char_end=char_end, max_chars=max_chars,
        ))

    @server.tool()
    def search_text(
        query: str,
        family: str | None = None,
        role: str | None = None,
        source_id: str | None = None,
        max_results: int = 20,
        context_chars: int = 300,
        regex: bool = False,
        case_sensitive: bool = False,
    ) -> dict:
        """Regex/substring search across selected ``corpus/text/`` sources.

        Prefer ``search_extractions`` / ``get_clause`` when a structured
        extraction class covers the question; this is the fallback path.
        Each hit returns ``source``, ``match_text``, ``char_interval``,
        ``page_range``, and ``line_number`` so it is directly citeable.
        """
        return envelope_to_dict(_search_text(
            index, query,
            family=family, role=role, source_id=source_id,
            max_results=max_results, context_chars=context_chars,
            regex=regex, case_sensitive=case_sensitive,
        ))

    @server.tool()
    def page_window(
        source_id: str,
        page_start: int,
        page_end: int,
        max_chars: int = 30_000,
    ) -> dict:
        """Read text spanning a PDF page range using the converter's PAGE markers."""
        return envelope_to_dict(_page_window(
            index, source_id, page_start, page_end, max_chars=max_chars,
        ))

    @server.tool()
    def search_extractions(
        extraction_class: str | None = None,
        family: str | None = None,
        role: str | None = None,
        source_id: str | None = None,
        task: str | None = None,
        attributes: dict[str, Any] | None = None,
        max_results: int = 50,
    ) -> dict:
        """Query LangExtract JSONL outputs for grounded structured extractions.

        Returns a ``no_extractions_available`` envelope (with a hint) when
        no extraction tasks have run yet.
        """
        return envelope_to_dict(_search_extractions(
            index,
            extraction_class=extraction_class,
            family=family, role=role, source_id=source_id,
            task=task, attributes=attributes,
            max_results=max_results,
        ))

    @server.tool()
    def get_extraction_by_id(extraction_id: str) -> dict:
        """Fetch a single extraction by stable id."""
        return envelope_to_dict(_get_extraction_by_id(index, extraction_id))

    @server.tool()
    def search_by_attributes(
        extraction_class: str,
        attributes: dict[str, Any],
        family: str | None = None,
        role: str | None = None,
        max_results: int = 50,
    ) -> dict:
        """Filter extractions for a class by an exact-match attribute dict."""
        return envelope_to_dict(_search_by_attributes(
            index, extraction_class, attributes,
            family=family, role=role, max_results=max_results,
        ))

    @server.tool()
    def get_clause(
        family: str,
        edition: str,
        clause_id: str,
        context_chars: int = 600,
    ) -> dict:
        """Best-effort clause lookup with explicit ``confidence`` field.

        Tries extractions first, then a regex over the source text. Returns
        ``confidence == "not-found"`` rather than guessing.
        """
        return envelope_to_dict(_get_clause(
            index, family, edition, clause_id, context_chars=context_chars,
        ))

    return server


def main(argv: list[str] | None = None) -> int:
    if argv is None:
        argv = sys.argv[1:]

    if "--self-test" in argv:
        from scripts.corpus.mcp_tools import list_sources as _list
        env = _list(CorpusIndex())
        n = len(env.results)
        sys.stderr.write(f"corpus self-test: {n} source ref(s) loaded.\n")
        return 0 if n > 0 else 1

    server = build_server()
    server.run(transport="stdio")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
