#!/usr/bin/env python3
"""Corpus extraction CLI (LangExtract wrapper) — STUB.

This is a deliberately minimal placeholder that wires up the repository
plumbing for `google/langextract` without committing to a specific
extraction taxonomy yet.

Responsibilities (current):
    * Iterate normalized text files under ``corpus/text/...``.
    * Load extraction "task configs" from ``scripts/corpus/tasks/*.yml`` if
      they exist; otherwise no-op with a friendly message.
    * For each (task, document) pair, write JSONL to
      ``corpus/extractions/<task>/<mirrored path>.jsonl`` and an HTML
      visualization under ``corpus/review/<task>/<mirrored path>.html``.

This file deliberately does NOT call ``langextract`` yet — the LLM call is
gated behind ``--apply`` and an environment variable so that the pipeline
plumbing can be developed and tested without API keys or network access.

Future work:
    * Define one or more task configs (e.g., ``strength_reduction_factors``,
      ``min_cover``, ``load_combos``) with prompt + few-shot examples.
    * Add chunking + multi-pass extraction tuned to the safety-critical
      review workflow.
"""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
TEXT_ROOT = REPO_ROOT / "corpus" / "text"
EXTRACT_ROOT = REPO_ROOT / "corpus" / "extractions"
REVIEW_ROOT = REPO_ROOT / "corpus" / "review"
TASKS_DIR = Path(__file__).resolve().parent / "tasks"


def discover_tasks() -> list[Path]:
    """Return YAML task configs under ``scripts/corpus/tasks/``."""
    if not TASKS_DIR.exists():
        return []
    return sorted(TASKS_DIR.glob("*.yml")) + sorted(TASKS_DIR.glob("*.yaml"))


def discover_text_files(role: str | None = None) -> list[Path]:
    """Return all normalized text files under ``corpus/text/``."""
    if not TEXT_ROOT.exists():
        return []
    files: list[Path] = []
    for txt in TEXT_ROOT.rglob("*.txt"):
        if role and not str(txt.relative_to(TEXT_ROOT)).startswith(role + "/"):
            continue
        files.append(txt)
    return files


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Run LangExtract tasks against corpus/text/ (stub)."
    )
    parser.add_argument(
        "--apply", action="store_true",
        help="Actually invoke LangExtract (requires LANGEXTRACT_API_KEY).",
    )
    parser.add_argument(
        "--role", default=None,
        help="Only process documents whose path starts with this role "
             "(codes / code_guides / examples / research / textbooks).",
    )
    parser.add_argument(
        "--task", default=None,
        help="Run only this task (matches the YAML stem in scripts/corpus/tasks/).",
    )
    args = parser.parse_args(argv)

    tasks = discover_tasks()
    if args.task:
        tasks = [t for t in tasks if t.stem == args.task]

    text_files = discover_text_files(role=args.role)

    print(f"corpus/text/   : {TEXT_ROOT.relative_to(REPO_ROOT)}")
    print(f"task configs   : {len(tasks)} found in {TASKS_DIR.relative_to(REPO_ROOT)}")
    print(f"text documents : {len(text_files)}")

    if not tasks:
        print(
            "\nNo task configs yet. Add YAML files under scripts/corpus/tasks/ "
            "with `prompt`, `examples`, and `extraction_classes`. This stub will "
            "wire them into LangExtract once they exist."
        )
        return 0

    if not args.apply:
        print("\n[DRY RUN] would run LangExtract over:")
        for task in tasks:
            for txt in text_files:
                rel = txt.relative_to(TEXT_ROOT)
                out = EXTRACT_ROOT / task.stem / rel.with_suffix(".jsonl")
                vis = REVIEW_ROOT / task.stem / rel.with_suffix(".html")
                print(f"  task={task.stem:<32} input={rel}")
                print(f"    -> {out.relative_to(REPO_ROOT)}")
                print(f"    -> {vis.relative_to(REPO_ROOT)}")
        return 0

    if not os.environ.get("LANGEXTRACT_API_KEY"):
        print(
            "ERROR: --apply requires LANGEXTRACT_API_KEY in the environment.",
            file=sys.stderr,
        )
        return 2

    print(
        "ERROR: extraction is not yet implemented. Define task configs and "
        "wire `langextract.extract(...)` here."
    )
    return 2


if __name__ == "__main__":
    sys.exit(main())
