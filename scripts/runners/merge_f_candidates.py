#!/usr/bin/env python3
"""Merge the three Chapter F extraction slices into one candidates module.

Slices A (F1-F4), B (F5-F9), C (F10-F13) were extracted in parallel into
``_f_candidates_{A,B,C}.py``. They are already in document order within each
slice, and A<B<C in document order, so concatenating A+B+C preserves global
document order (required by ``corpus_locators.py``'s monotonic cursor). Keys are
slice-prefixed (fa*/fb*/fc*) so they are globally unique; OBSERVED edges are
slice-local and simply unioned.

Read-only w.r.t. the graph — emits ``scribe_aisc_chapter_f_candidates.py``.
"""
from __future__ import annotations

import ast
import os

RUNNERS = os.path.dirname(os.path.abspath(__file__))
SLICES = ["_f_candidates_A.py", "_f_candidates_B.py", "_f_candidates_C.py"]
REQUIRED = ("key", "dimension", "note_type", "title", "clause", "source_page", "body", "quotes", "facets")
FACET_KEYS = ("element", "limit-state", "stage", "method")


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


def main() -> int:
    candidates: list[dict] = []
    observed: list = []
    for fn in SLICES:
        g = load(os.path.join(RUNNERS, fn))
        candidates.extend(g["CANDIDATES"])
        observed.extend(g.get("OBSERVED", []))

    # Integrity checks.
    keys = [c["key"] for c in candidates]
    assert len(set(keys)) == len(keys), "duplicate keys across slices"
    for c in candidates:
        missing = [k for k in REQUIRED if k not in c]
        assert not missing, f"{c.get('key')} missing {missing}"
        fmiss = [k for k in FACET_KEYS if k not in c["facets"]]
        assert not fmiss, f"{c['key']} facets missing {fmiss}"

    out = os.path.join(RUNNERS, "scribe_aisc_chapter_f_candidates.py")
    with open(out, "w", encoding="utf-8") as f:
        f.write('"""Merged AISC 360-16 Chapter F extraction candidates (F1-F13).\n\n')
        f.write("Auto-assembled by merge_f_candidates.py from the three parallel extraction\n")
        f.write("slices. Data-only module: no zettelkasten import, no graph writes.\n")
        f.write('"""\n')
        f.write("# fmt: off\n")
        f.write("CANDIDATES = " + repr(candidates) + "\n")
        f.write("OBSERVED = " + repr(observed) + "\n")
        f.write("# fmt: on\n")

    import collections
    print(f"wrote {out}")
    print(f"  candidates={len(candidates)} observed={len(observed)}")
    print(f"  by_dimension={dict(collections.Counter(c['dimension'] for c in candidates))}")
    print(f"  by_type={dict(collections.Counter(c['note_type'] for c in candidates))}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
