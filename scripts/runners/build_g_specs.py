#!/usr/bin/env python3
"""Build fully-resolved zettelkasten note specs for the AISC 360-16 Chapter G rebuild.

Reads the extractor candidates (``scribe_aisc_chapter_g.py``) and the precomputed
source locators (``aisc_chapter_g_locators.json``), then emits a single JSON
document (``_g_specs.json``) that a downstream *MCP-only* scribe can consume with
no further logic: one claim note + its quote notes per candidate, plus the
deterministic OBSERVED cross-links and BACKBONE canon links.

This script imports NOTHING from ``zettelkasten``/``kglite``/``model2vec`` — it
only ``ast``-parses the candidate module (no execution) and reads JSON, so it is
safe to run while the MCP server holds the graph box (the standalone-import path
segfaults; see memory "kglite mmap conflict").

Every note carries a machine-resolvable ``data.locator`` (the knowledge-graph as
an index into the source PDF) and ``source_book``/``source_chapter``/
``source_page`` provenance.
"""
from __future__ import annotations

import ast
import json
import os

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
RUNNERS = os.path.join(REPO, "scripts", "runners")

GRAPH = "aisc-360-16"
SYN = "aisc-360-canon"
PROJECT = "menegroth"
SOURCE_ID = "aisc-360-16"

ALIAS_DIMS = ("provision", "equation", "parameters", "applicability")


def load_literal(py_path: str, name: str):
    """Return the value of a top-level ``name = <literal>`` without executing the module."""
    with open(py_path, encoding="utf-8") as f:
        tree = ast.parse(f.read(), filename=py_path)
    for node in tree.body:
        targets = []
        if isinstance(node, ast.Assign):
            targets = [t.id for t in node.targets if isinstance(t, ast.Name)]
            value = node.value
        elif isinstance(node, ast.AnnAssign) and isinstance(node.target, ast.Name):
            targets = [node.target.id]
            value = node.value
        else:
            continue
        if name in targets and value is not None:
            return ast.literal_eval(value)
    raise SystemExit(f"{name} not found in {py_path}")


def facet_tags(dim: str, clause: str, facets: dict) -> list[str]:
    """Reproduce scribe_aisc_chapter_g.facet_tags exactly."""
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
    """Project the raw locators-json record onto the note ``data.locator`` schema."""
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
    candidates = load_literal(os.path.join(RUNNERS, "scribe_aisc_chapter_g.py"), "CANDIDATES")
    observed = load_literal(os.path.join(RUNNERS, "scribe_aisc_chapter_g.py"), "OBSERVED")
    backbone = load_literal(os.path.join(RUNNERS, "scribe_aisc_chapter_g.py"), "BACKBONE")
    locators = json.load(open(os.path.join(RUNNERS, "aisc_chapter_g_locators.json"), encoding="utf-8"))

    notes = []
    for c in candidates:
        key = c["key"]
        loc = locator_for(locators.get(key, {}))
        tags = facet_tags(c["dimension"], c["clause"], c["facets"])
        aliases = [f"aisc-360-16#{c['clause']}"] if c["dimension"] in ALIAS_DIMS else None
        quotes = [
            {
                "title": f"Quote {i}: {c['title']}",
                "body": q,
                "tags": ["quote", "grounding", c["dimension"]],
            }
            for i, q in enumerate(c.get("quotes") or [], 1)
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
                "quotes": [
                    {
                        "graph": GRAPH,
                        "title": q["title"],
                        "type": "quote",
                        "body": q["body"],
                        "tags": q["tags"],
                        "source_book": SOURCE_ID,
                        "source_chapter": c["clause"],
                        "source_page": c["source_page"],
                        "data": {"locator": loc},
                    }
                    for q in quotes
                ],
            }
        )

    spec = {
        "graph": GRAPH,
        "synthesis_graph": SYN,
        "project": PROJECT,
        "notes": notes,
        "observed": [{"src_key": s, "tgt_key": t, "relation": r} for s, t, r in observed],
        "backbone": [{"source_id": s, "target_id": t, "relation": r} for s, t, r in backbone],
    }
    out = os.path.join(RUNNERS, "_g_specs.json")
    json.dump(spec, open(out, "w", encoding="utf-8"), indent=2, ensure_ascii=False)

    n_claims = len(notes)
    n_quotes = sum(len(n["quotes"]) for n in notes)
    n_missing = sum(1 for n in notes if n["claim"]["data"]["locator"]["pdf_page"] is None)
    print(f"wrote {out}")
    print(f"  claims={n_claims} quotes={n_quotes} observed={len(spec['observed'])} backbone={len(spec['backbone'])}")
    print(f"  claims missing pdf_page: {n_missing}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
