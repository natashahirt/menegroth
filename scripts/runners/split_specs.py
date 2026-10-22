#!/usr/bin/env python3
"""Split a big authoring spec (``_g_specs.json`` / ``_f_specs.json``) into small,
self-contained chunk files so each can be authored by a SHORT subagent.

Long authoring subagents die with ``WritableIterable is closed`` after a large
volume of MCP calls; short ones (the Chapter F extractors) succeed. So we slice
the ``notes`` list into fixed-size chunks (default 34 notes ~= 105 MCP calls,
~10 min) and emit one ``_auth_<label>_NN.json`` per chunk. Each chunk carries the
same ``graph``/``synthesis_graph``/``project`` header and a ``notes`` slice; the
subagent authors claims (add + attach) and their quote notes only.

Cross-note links (``observed``/``backbone``) are intentionally DROPPED from the
chunks: they reference keys that may live in other chunks, so they are applied in
a single final pass by the parent, which recovers the key->id map from a graph
search (title is unique per candidate). This keeps chunks order-independent and
subagents free of any cross-chunk bookkeeping.

Read-only w.r.t. the graph — JSON in, JSON out.
"""
from __future__ import annotations

import argparse
import json
import os

RUNNERS = os.path.dirname(os.path.abspath(__file__))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--specs", required=True, help="input specs json (repo-relative to runners ok)")
    ap.add_argument("--label", required=True, help="chunk label, e.g. G or F")
    ap.add_argument("--size", type=int, default=34, help="notes per chunk")
    args = ap.parse_args()

    specs_path = args.specs if os.path.isabs(args.specs) else os.path.join(RUNNERS, args.specs)
    spec = json.load(open(specs_path, encoding="utf-8"))
    header = {k: spec[k] for k in ("graph", "synthesis_graph", "project")}
    notes = spec["notes"]

    chunks = [notes[i : i + args.size] for i in range(0, len(notes), args.size)]
    written = []
    for i, chunk in enumerate(chunks, 1):
        out = {**header, "chunk": i, "n_chunks": len(chunks), "notes": chunk}
        path = os.path.join(RUNNERS, f"_auth_{args.label}_{i:02d}.json")
        json.dump(out, open(path, "w", encoding="utf-8"), indent=2, ensure_ascii=False)
        written.append((path, len(chunk)))

    total_quotes = sum(len(n.get("quotes") or []) for n in notes)
    print(f"{len(notes)} notes / {total_quotes} quotes -> {len(chunks)} chunks of <= {args.size}")
    for path, n in written:
        rel = os.path.relpath(path, RUNNERS)
        print(f"  {rel}: {n} notes")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
