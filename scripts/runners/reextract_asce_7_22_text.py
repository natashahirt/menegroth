#!/usr/bin/env python3
"""Re-extract ASCE 7-22 to clean corpus text with tight x_tolerance.

The default pdfplumber gap threshold (x_tolerance=3) drops inter-word spaces
on several ASCE 7-22 pages, producing "wordswithoutspaces" that break verbatim
quote grounding in the zettelkasten. x_tolerance=1 recovers the spaces without
over-splitting clean pages (verified on prose pages). This regenerates the
corpus text file in place; the ZK source `asce-7-22` reads this same file as its
grounding basis (source_path), so both corpus search and grounding are fixed.

Writes incrementally so progress is observable and matches the exact page-marker
format of scripts/util/convert_pdfs_to_text.py (`===== PAGE n =====`).
"""
from __future__ import annotations

import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts" / "util"))

import pdfplumber  # noqa: E402
from convert_pdfs_to_text import _extract_page_text, MIN_CHARS_PER_PAGE  # noqa: E402

PDF = ROOT / "corpus" / "sources" / "codes" / "asce" / "ASCE-7-22.pdf"
OUT = ROOT / "corpus" / "text" / "codes" / "asce" / "ASCE-7-22.txt"
X_TOL = 1.0


def main() -> int:
    if not PDF.exists():
        print(f"ERROR: PDF not found: {PDF}", flush=True)
        return 1
    OUT.parent.mkdir(parents=True, exist_ok=True)
    tmp = OUT.with_suffix(".txt.tmp")

    t0 = time.time()
    empty = 0
    with pdfplumber.open(PDF) as pdf, tmp.open("w", encoding="utf-8") as fh:
        total = len(pdf.pages)
        print(f"Re-extracting {total} pages of {PDF.name} at x_tolerance={X_TOL}", flush=True)
        for i, page in enumerate(pdf.pages, 1):
            combined, col_tag = _extract_page_text(
                page, detect_columns=True, x_tolerance=X_TOL,
            )
            if len(combined) < MIN_CHARS_PER_PAGE:
                empty += 1
            fh.write(f"\n{'='*60}\nPAGE {i}{col_tag}\n{'='*60}\n\n")
            fh.write(combined if combined else "(no text extracted)")
            fh.write("\n")
            if i % 50 == 0 or i == total:
                dt = time.time() - t0
                print(f"  page {i}/{total}  ({dt:.0f}s, {empty} empty)", flush=True)

    tmp.replace(OUT)
    print(f"DONE -> {OUT}  ({OUT.stat().st_size:,} bytes, {empty} empty pages, "
          f"{time.time()-t0:.0f}s)", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
