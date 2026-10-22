#!/usr/bin/env python3
"""Build fully-resolved zettelkasten note specs for the AISC 360-16 Chapter F authoring pass.

Consumes the merged Chapter F candidates (``scribe_aisc_chapter_f_candidates.py``,
with ``CANDIDATES`` + ``OBSERVED``) and the precomputed locators
(``aisc_chapter_f_locators.json``), emitting ``_f_specs.json`` — the same shape the
Chapter G rebuild consumed, so the MCP-only authoring subagent needs no logic:
one claim note (+ its quotes) per candidate, each carrying a resolvable
``data.locator``, plus the OBSERVED cross-links.

No ``zettelkasten``/``kglite`` import (ast-parse + JSON only), so it is safe to run
beside the live MCP server. Chapter F attaches to the SAME shared canon dimension
nodes as Chapter G (via the ``attach`` action), so no BACKBONE re-link is needed
here — the G rebuild already maintains those 6 canon edges.
"""
from __future__ import annotations

import ast
import json
import os

RUNNERS = os.path.dirname(os.path.abspath(__file__))
GRAPH = "aisc-360-16"
SYN = "aisc-360-canon"
PROJECT = "menegroth"
SOURCE_ID = "aisc-360-16"
ALIAS_DIMS = ("provision", "equation", "parameters", "applicability")


def load(path: str) -> dict:
    tree = ast.parse(open(path, encoding="utf-8").read(), filename=path)
    out: dict = {}
    for node in tree.body:
        if isinstance(node, ast.Assign):
            names = [t.id for t in node.targets if isinstance(t, ast.Name)]
            value = node.value
        elif isinstance(node, ast.AnnAssign) and isinstance(node.target, ast.Name):
            names = [node.target.id]
            value = node.value
        else:
            continue
        for n in names:
            if n in ("CANDIDATES", "OBSERVED") and value is not None:
                out[n] = ast.literal_eval(value)
    return out


def facet_tags(dim: str, clause: str, facets: dict) -> list[str]:
    """Same facet-tag convention as the Chapter G scribe."""
    tags = [
        dim,
        f"clause:{clause}",
        "family:aisc-360-16",
        "edition:2016",
        "material:steel",
        f"element:{facets['element']}",
        f"limit-state:{facets['limit-state']}",
        f"stage:{facets['stage']}",
    ]
    if facets.get("method") and facets["method"] != "na":
        tags.append(f"method:{facets['method']}")
    return tags


def locator_for(loc: dict) -> dict:
    return {
        "source_id": loc.get("source_id", SOURCE_ID),
        "pdf_page": loc.get("pdf_page"),
        "char_start": loc.get("char_start"),
        "char_end": loc.get("char_end"),
        "printed_page": loc.get("printed_page"),
        "text_path": loc.get("text_path"),
        "inferred_page": loc.get("inferred_page", False),
    }


def main() -> int:
    data = load(os.path.join(RUNNERS, "scribe_aisc_chapter_f_candidates.py"))
    candidates = data["CANDIDATES"]
    observed = data.get("OBSERVED", [])
    locators = json.load(open(os.path.join(RUNNERS, "aisc_chapter_f_locators.json"), encoding="utf-8"))

    notes = []
    for c in candidates:
        key = c["key"]
        loc = locator_for(locators.get(key, {}))
        tags = facet_tags(c["dimension"], c["clause"], c["facets"])
        aliases = [f"aisc-360-16#{c['clause']}"] if c["dimension"] in ALIAS_DIMS else None
        quotes = [
            {
                "graph": GRAPH,
                "title": f"Quote {i}: {c['title']}",
                "type": "quote",
                "body": q,
                "tags": ["quote", "grounding", c["dimension"]],
                "source_book": SOURCE_ID,
                "source_chapter": c["clause"],
                "source_page": c["source_page"],
                "data": {"locator": loc},
            }
            for i, q in enumerate(c.get("quotes") or [], 1)
            if q and q.strip()
        ]
        notes.append(
            {
                "key": key,
                "dimension": c["dimension"],
                "claim": {
                    "graph": GRAPH,
                    "title": c["title"],
                    "type": c["note_type"],
                    "body": c["body"],
                    "tags": tags,
                    "source_book": SOURCE_ID,
                    "source_chapter": c["clause"],
                    "source_page": c["source_page"],
                    "aliases": aliases,
                    "epistemic_status": "grounded",
                    "data": {"locator": loc},
                },
                "attach": {"graph": GRAPH, "tag": c["dimension"]},
                "quotes": quotes,
            }
        )

    spec = {
        "graph": GRAPH,
        "synthesis_graph": SYN,
        "project": PROJECT,
        "notes": notes,
        "observed": [{"src_key": s, "tgt_key": t, "relation": r} for s, t, r in observed],
        "backbone": [],
    }
    out = os.path.join(RUNNERS, "_f_specs.json")
    json.dump(spec, open(out, "w", encoding="utf-8"), indent=2, ensure_ascii=False)

    n_quotes = sum(len(n["quotes"]) for n in notes)
    n_missing = sum(1 for n in notes if n["claim"]["data"]["locator"]["pdf_page"] is None)
    print(f"wrote {out}")
    print(f"  claims={len(notes)} quotes={n_quotes} observed={len(spec['observed'])}")
    print(f"  claims missing pdf_page: {n_missing}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
