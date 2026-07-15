#!/usr/bin/env python3
"""Reset the two corrupted CSA beam ZK graphs to their hub notes and strip the
now-dangling ``spine-member`` links from the ``csa-a23-3-canon`` spine.

Context: on 2026-07-14 the coordinator's auto-executor spawned twin composer
scribes that collided with the manual scribes on the ``simply-supported`` and
``doubly-reinforced`` graphs, leaving them partial AND duplicated. This resets
them to a clean scaffold so a single manual scribe can re-commit each source.

Filesystem-only (no ZK API): delete every non-hub note in the two source graphs,
then rewrite each canon dimension node dropping links whose ``relation`` is
``spine-member`` (all of which currently point into the two wiped graphs). Run a
``rebuild_global_index`` via the ZK MCP afterwards to resync the in-memory index.

Usage:
    python3 scripts/runners/csa_graph_reset.py            # dry-run (default)
    python3 scripts/runners/csa_graph_reset.py --apply     # perform changes
"""
from __future__ import annotations

import sys
from pathlib import Path

ZK = Path(__file__).resolve().parents[2] / ".zettelkasten"

# Source graphs to wipe -> the hub note id to PRESERVE in each.
WIPE = {
    "csa-de-simply-supported-beam-a23-3-14": "20260714-2203-csa-a23-3-14-simply-supported-beam-struc",
    "csa-de-doubly-reinforced-beam-a23-3-14": "20260714-2203-csa-a23-3-14-doubly-reinforced-beam-stru",
}

CANON = "csa-a23-3-canon"
DIM_NODES = [
    "20260714-2204-csa-a23-3-applicability",
    "20260714-2204-csa-a23-3-commentary",
    "20260714-2204-csa-a23-3-equation",
    "20260714-2204-csa-a23-3-example",
    "20260714-2204-csa-a23-3-parameters",
    "20260714-2204-csa-a23-3-provision",
    "20260714-2204-csa-a23-3-scope",
]


def split_frontmatter(text: str):
    """Return (yaml_lines, body_str). Assumes leading '---\\n...\\n---\\n'."""
    if not text.startswith("---\n"):
        raise ValueError("no frontmatter")
    end = text.index("\n---", 4)
    fm = text[4:end]
    body = text[end + 4 :]
    return fm.splitlines(), body


def strip_spine_member_links(fm_lines: list[str]) -> tuple[list[str], int]:
    """Drop every 4-line link block whose relation is 'spine-member'.

    A link block is:
        - target: <id>
          relation: <rel>
          direction: <dir>
          [graph: <graph>]
    We identify blocks starting with '- target:' inside the 'links:' section and
    remove the whole block when its 'relation:' line == 'spine-member'.
    """
    out: list[str] = []
    removed = 0
    i = 0
    n = len(fm_lines)
    while i < n:
        line = fm_lines[i]
        stripped = line.strip()
        if stripped.startswith("- target:"):
            # gather the block: this line + following indented (non '- ') lines
            block = [line]
            j = i + 1
            while j < n:
                nxt = fm_lines[j]
                # continuation lines are indented and NOT a new list item
                if nxt.startswith("  ") and not nxt.lstrip().startswith("- "):
                    block.append(nxt)
                    j += 1
                else:
                    break
            is_spine = any(b.strip() == "relation: spine-member" for b in block)
            if is_spine:
                removed += 1
            else:
                out.extend(block)
            i = j
        else:
            out.append(line)
            i += 1
    return out, removed


def main() -> int:
    apply = "--apply" in sys.argv
    mode = "APPLY" if apply else "DRY-RUN"
    print(f"=== CSA graph reset [{mode}] ===\nZK root: {ZK}\n")

    if not ZK.is_dir():
        print(f"ERROR: {ZK} not found")
        return 1

    # 1) wipe non-hub notes
    total_del = 0
    for graph, hub in WIPE.items():
        gdir = ZK / graph
        if not gdir.is_dir():
            print(f"  [skip] {graph}: dir missing")
            continue
        hub_file = gdir / f"{hub}.md"
        if not hub_file.exists():
            print(f"  ERROR {graph}: hub {hub}.md NOT found -- aborting to avoid nuking hub")
            return 1
        victims = [p for p in gdir.glob("*.md") if p.stem != hub]
        print(f"  {graph}: delete {len(victims)} notes, keep hub {hub}")
        total_del += len(victims)
        if apply:
            for p in victims:
                p.unlink()

    # 2) strip spine-member links from canon dimension nodes
    print()
    total_links = 0
    for node in DIM_NODES:
        f = ZK / CANON / f"{node}.md"
        if not f.exists():
            print(f"  [skip] {CANON}/{node}.md missing")
            continue
        text = f.read_text(encoding="utf-8")
        fm_lines, body = split_frontmatter(text)
        new_fm, removed = strip_spine_member_links(fm_lines)
        total_links += removed
        print(f"  {node}: strip {removed} spine-member link(s)")
        if apply and removed:
            f.write_text("---\n" + "\n".join(new_fm) + "\n---" + body, encoding="utf-8")

    print(f"\nSummary [{mode}]: {total_del} notes to delete, {total_links} spine-member links to strip.")
    if not apply:
        print("Re-run with --apply to perform. Then call rebuild_global_index via the ZK MCP.")
    else:
        print("DONE. Now call rebuild_global_index via the ZK MCP to resync the index.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
