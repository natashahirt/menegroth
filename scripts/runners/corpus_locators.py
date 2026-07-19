#!/usr/bin/env python3
"""Compute resolvable source locators for extraction candidates (TEXT-ONLY, safe).

For every candidate in a scribe script's ``CANDIDATES`` list, locate its verbatim
quote(s) inside the corpus text mirror and emit a machine-resolvable locator:

    {source_id, pdf_page, char_start, char_end, printed_page, text_path, found}

``pdf_page`` is taken from the ``PAGE N`` markers that the corpus ingest writes
into ``corpus/text/**``; it is what ``corpus.page_window`` / ``get_source_text``
dereference. This turns the knowledge graph into an index into the source PDFs
(see memory decision "Knowledge-graph-as-index").

The script NEVER imports zettelkasten/kglite/model2vec: it only reads the
candidate file (via ``ast`` — no execution) and the corpus text file, so it is
safe to run standalone while the MCP server holds the box.
"""
from __future__ import annotations

import argparse
import ast
import json
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

# Marker the corpus ingest writes at the top of every page's text block.
_PAGE_RE = re.compile(r"(?m)^PAGE (\d+)\s*$")
_WS_RE = re.compile(r"\s+")


def load_candidates(py_path: str) -> list[dict]:
    """Extract the ``CANDIDATES`` list literal without executing the module."""
    with open(py_path, encoding="utf-8") as f:
        tree = ast.parse(f.read(), filename=py_path)
    for node in tree.body:
        # Plain ``CANDIDATES = [...]``
        if isinstance(node, ast.Assign):
            for tgt in node.targets:
                if isinstance(tgt, ast.Name) and tgt.id == "CANDIDATES":
                    return ast.literal_eval(node.value)
        # Annotated ``CANDIDATES: list[dict] = [...]``
        if isinstance(node, ast.AnnAssign) and isinstance(node.target, ast.Name):
            if node.target.id == "CANDIDATES" and node.value is not None:
                return ast.literal_eval(node.value)
    raise SystemExit(f"no CANDIDATES list found in {py_path}")


def build_page_index(text: str) -> list[tuple[int, int]]:
    """Return sorted [(char_offset, pdf_page), ...] for every PAGE marker."""
    return [(m.start(), int(m.group(1))) for m in _PAGE_RE.finditer(text)]


def page_for_offset(page_index: list[tuple[int, int]], offset: int) -> int | None:
    """PDF page whose marker most closely precedes ``offset`` (binary search)."""
    lo, hi, ans = 0, len(page_index) - 1, None
    while lo <= hi:
        mid = (lo + hi) // 2
        if page_index[mid][0] <= offset:
            ans = page_index[mid][1]
            lo = mid + 1
        else:
            hi = mid - 1
    return ans


def normalize(text: str) -> tuple[str, list[int]]:
    """Whitespace-stripped text + map from stripped-index -> original offset.

    Extraction quotes carry OCR line-wrapping and irregular spacing, so we match
    on the whitespace-free projection of both sides and translate back.
    """
    chars: list[str] = []
    offsets: list[int] = []
    for i, ch in enumerate(text):
        if not ch.isspace():
            chars.append(ch)
            offsets.append(i)
    return "".join(chars), offsets


def locate(anchor: str, norm_text: str, norm_map: list[int], from_norm: int) -> tuple[int, int] | None:
    """Find ``anchor`` (raw quote) in normalized text at/after ``from_norm``.

    Returns (char_start, char_end) in ORIGINAL text coordinates, or None.
    Searches forward first (candidates are in document order), then globally.
    """
    key = _WS_RE.sub("", anchor)
    if not key:
        return None
    ni = norm_text.find(key, from_norm)
    if ni < 0:
        ni = norm_text.find(key)  # wrap: repeated/earlier occurrence
    if ni < 0:
        return None
    start = norm_map[ni]
    end = norm_map[ni + len(key) - 1] + 1
    return start, end


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--candidates", required=True, help="scribe .py with CANDIDATES list")
    ap.add_argument("--text", required=True, help="corpus/text/**.txt source mirror (repo-relative ok)")
    ap.add_argument("--source-id", required=True, help="corpus manifest source_id, e.g. aisc-360-16")
    ap.add_argument("--out", required=True, help="output JSON path")
    args = ap.parse_args()

    text_path = args.text if os.path.isabs(args.text) else os.path.join(REPO, args.text)
    rel_text = os.path.relpath(text_path, REPO)
    with open(text_path, encoding="utf-8") as f:
        text = f.read()

    page_index = build_page_index(text)
    norm_text, norm_map = normalize(text)
    candidates = load_candidates(args.candidates)

    out: dict[str, dict] = {}
    cursor = 0  # normalized-index cursor to keep matches monotonic (doc order)
    found_n = 0
    for c in candidates:
        key = c["key"]
        printed = re.sub(r"^p\.?\s*", "", str(c.get("source_page", "")).strip())
        quotes = [q for q in (c.get("quotes") or []) if q and q.strip()]
        # Longest quote is the most distinctive anchor.
        quotes_sorted = sorted(quotes, key=lambda q: len(_WS_RE.sub("", q)), reverse=True)
        spans: list[tuple[int, int]] = []
        for q in quotes_sorted:
            loc = locate(q, norm_text, norm_map, cursor)
            if loc:
                spans.append(loc)
        rec: dict = {
            "source_id": args.source_id,
            "printed_page": printed,
            "text_path": rel_text,
            "found": bool(spans),
            "n_quotes_found": len(spans),
            "n_quotes": len(quotes),
        }
        if spans:
            char_start = min(s for s, _ in spans)
            char_end = max(e for _, e in spans)
            rec["char_start"] = char_start
            rec["char_end"] = char_end
            rec["pdf_page"] = page_for_offset(page_index, char_start)
            # advance cursor to just past this candidate's earliest span
            cursor = max(cursor, next(i for i, o in enumerate(norm_map) if o >= char_start))
            found_n += 1
        else:
            rec["char_start"] = None
            rec["char_end"] = None
            rec["pdf_page"] = None
        out[key] = rec

    # Carry-forward fill: candidates with no findable quote (e.g. gap notes)
    # inherit the most recent known page so every note still has a pointer.
    last_page = None
    for c in candidates:
        rec = out[c["key"]]
        if rec["pdf_page"] is not None:
            last_page = rec["pdf_page"]
        elif last_page is not None:
            rec["pdf_page"] = last_page
            rec["inferred_page"] = True

    os.makedirs(os.path.dirname(os.path.join(REPO, args.out)) or ".", exist_ok=True)
    out_path = args.out if os.path.isabs(args.out) else os.path.join(REPO, args.out)
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(out, f, indent=2)

    total = len(candidates)
    print(f"locators: {found_n}/{total} candidates matched a verbatim quote")
    print(f"pages present: {sum(1 for r in out.values() if r['pdf_page'] is not None)}/{total}")
    print(f"wrote {out_path}")
    # Show a few for eyeballing.
    for k in list(out)[:6]:
        r = out[k]
        print(f"  {k}: page={r['pdf_page']} printed={r['printed_page']!r} chars={r['char_start']}..{r['char_end']} found={r['found']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
