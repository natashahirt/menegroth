#!/usr/bin/env python3
"""Re-decode ACI 318-19 PDF pages whose Times fonts omit ToUnicode.

The italic and bold faces have no ToUnicode map, so the corpus text stored
``(cid:N)``. ``_aci_cid_fallback`` fills that map. Fraction joining is off:
a hairline on these pages was binding to the prose around it.

Default range is pages 326–332 (§18.10.6.2 through the start of §18.10.7).
Pass ``--first`` and ``--last`` for another inclusive PDF page range.

Replaces those PAGE blocks in corpus/text/codes/aci/ACI-318-19.txt.
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts" / "util"))

import pdfplumber  # noqa: E402
from convert_pdfs_to_text import _extract_page_text  # noqa: E402

PDF = ROOT / "corpus" / "sources" / "codes" / "aci" / "ACI 318R 2019.pdf"
OUT = ROOT / "corpus" / "text" / "codes" / "aci" / "ACI-318-19.txt"


def _page_block(n: int, body: str, col_tag: str) -> str:
    bar = "=" * 60
    return f"\n{bar}\nPAGE {n}{col_tag}\n{bar}\n\n{body}\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--first", type=int, default=326)
    parser.add_argument("--last", type=int, default=332)
    args = parser.parse_args()
    first, last = args.first, args.last
    if not PDF.exists() or not OUT.exists():
        print(f"ERROR: missing {PDF if not PDF.exists() else OUT}", flush=True)
        return 1
    if first < 1 or last < first:
        print(f"ERROR: bad page range {first}..{last}", flush=True)
        return 1
    blocks: list[str] = []
    with pdfplumber.open(PDF) as pdf:
        for n in range(first, last + 1):
            body, col_tag = _extract_page_text(
                pdf.pages[n - 1], detect_columns=True, fractions=False,
            )
            left = body.count("(cid:")
            if left:
                print(f"ERROR: page {n} still has {left} unresolved cid tokens", flush=True)
                return 1
            blocks.append(_page_block(n, body, col_tag))
            print(f"page {n}{col_tag}  {len(body)} chars", flush=True)

    text = OUT.read_text(encoding="utf-8")
    start = text.find(f"\n{'=' * 60}\nPAGE {first} ")
    end = text.find(f"\n{'=' * 60}\nPAGE {last + 1} ")
    if start < 0 or end < 0 or end <= start:
        print(f"ERROR: page markers {first}..{last + 1} not found ({start}, {end})", flush=True)
        return 1
    new = text[:start] + "".join(blocks) + text[end:]
    if "effectively continuous from the base of structure to top of" not in new:
        print("ERROR: §18.10.6.2 scope sentence missing after splice", flush=True)
        return 1
    OUT.write_text(new, encoding="utf-8")
    print(f"replaced pages {first}–{last} in {OUT.name}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
