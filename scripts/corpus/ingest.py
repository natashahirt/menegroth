#!/usr/bin/env python3
"""Corpus ingestion CLI.

Reads ``corpus/manifests/sources.yml`` and, for each entry, ensures that:

1. The source PDF (or other document) is copied from its upstream path
   under ``StructuralSizer/**/reference/`` into the entry's ``source_path``
   under ``corpus/sources/``.
2. The sibling ``.txt`` is copied into the entry's ``text_path`` under
   ``corpus/text/``. If the sibling ``.txt`` is missing or older than the
   PDF, the converter in ``scripts/util/convert_pdfs_to_text.py`` is used
   to (re)generate it.
3. Text-only entries (``text_only: true``) copy every ``.txt`` from
   ``origin_dir`` into ``text_dir`` (used for AISC chapter excerpts).

Provenance is recorded by writing a small ``.provenance.json`` next to each
copied source.

Usage::

    # Dry run (default): print what would happen
    python scripts/corpus/ingest.py

    # Actually copy
    python scripts/corpus/ingest.py --apply

    # Process only a subset of manifest entries
    python scripts/corpus/ingest.py --apply --ids aci-318-11 aisc-360-16

This script is intentionally dependency-light: it only requires
``PyYAML`` (auto-installed on first run if missing). The PDF→text logic
is delegated to ``scripts/util/convert_pdfs_to_text.py`` and is only
invoked when a sibling ``.txt`` is missing or stale.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
MANIFEST_PATH = REPO_ROOT / "corpus" / "manifests" / "sources.yml"
PDF2TXT_SCRIPT = REPO_ROOT / "scripts" / "util" / "convert_pdfs_to_text.py"


def _ensure(pkg: str, pip_name: str | None = None):
    """Import *pkg*; ``pip install`` it if missing."""
    try:
        return __import__(pkg)
    except ImportError:
        subprocess.check_call(
            [sys.executable, "-m", "pip", "install", pip_name or pkg]
        )
        return __import__(pkg)


yaml = _ensure("yaml", "PyYAML")


@dataclass
class IngestEntry:
    """Single normalized manifest entry (PDF + optional sibling .txt)."""

    id: str
    family: str
    role: str
    edition: str
    tier: int
    origin: Path | None = None
    source_path: Path | None = None
    text_path: Path | None = None
    origin_dir: Path | None = None
    text_dir: Path | None = None
    encrypted: bool = False
    text_only: bool = False
    notes: str = ""
    raw: dict = field(default_factory=dict)

    @classmethod
    def from_dict(cls, d: dict) -> "IngestEntry":
        def _p(k):
            v = d.get(k)
            return REPO_ROOT / v if v else None

        return cls(
            id=d["id"],
            family=d["family"],
            role=d["role"],
            edition=d.get("edition", ""),
            tier=int(d.get("tier", 99)),
            origin=_p("origin"),
            source_path=_p("source_path"),
            text_path=_p("text_path"),
            origin_dir=_p("origin_dir"),
            text_dir=_p("text_dir"),
            encrypted=bool(d.get("encrypted", False)),
            text_only=bool(d.get("text_only", False)),
            notes=d.get("notes", ""),
            raw=d,
        )


def load_manifest(path: Path = MANIFEST_PATH) -> list[IngestEntry]:
    """Load and normalize the corpus sources manifest."""
    with path.open("r", encoding="utf-8") as f:
        raw = yaml.safe_load(f) or []
    return [IngestEntry.from_dict(d) for d in raw]


def _sha256(path: Path, block_size: int = 1 << 20) -> str:
    """Stream-compute SHA-256 to avoid loading large PDFs into memory."""
    h = hashlib.sha256()
    with path.open("rb") as f:
        while chunk := f.read(block_size):
            h.update(chunk)
    return h.hexdigest()


def _ensure_parent(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)


def _copy_if_needed(src: Path, dst: Path, *, apply: bool) -> str:
    """Copy ``src`` to ``dst`` only when missing or stale."""
    if not src.exists():
        return f"MISSING source: {src}"
    if dst.exists() and dst.stat().st_mtime >= src.stat().st_mtime:
        return f"up-to-date: {dst.relative_to(REPO_ROOT)}"
    if apply:
        _ensure_parent(dst)
        shutil.copy2(src, dst)
    return f"copied: {src.relative_to(REPO_ROOT)} -> {dst.relative_to(REPO_ROOT)}"


def _ensure_sibling_txt(pdf: Path, txt_dst: Path, *, apply: bool, encrypted: bool) -> str:
    """Make sure ``txt_dst`` exists; (re)convert from ``pdf`` when missing/stale.

    Conversion is delegated to ``scripts/util/convert_pdfs_to_text.py`` so the
    same column-detection / OCR / password rules are used everywhere.
    """
    sibling_txt = pdf.with_suffix(".txt")
    if sibling_txt.exists() and sibling_txt.stat().st_mtime >= pdf.stat().st_mtime:
        return _copy_if_needed(sibling_txt, txt_dst, apply=apply)

    if not apply:
        return f"would convert: {pdf.relative_to(REPO_ROOT)}"

    # Run the existing converter against the original PDF location so its
    # sibling .txt is regenerated, then copy.
    cmd = [sys.executable, str(PDF2TXT_SCRIPT), str(pdf), "--force"]
    subprocess.check_call(cmd)
    if not sibling_txt.exists():
        return f"FAILED to produce sibling .txt for {pdf}"
    return _copy_if_needed(sibling_txt, txt_dst, apply=apply)


def _write_provenance(entry: IngestEntry, *, apply: bool) -> str:
    """Drop a ``.provenance.json`` next to the copied source for traceability."""
    if entry.source_path is None:
        return ""
    prov_path = entry.source_path.with_suffix(entry.source_path.suffix + ".provenance.json")
    payload = {
        "id": entry.id,
        "family": entry.family,
        "role": entry.role,
        "edition": entry.edition,
        "tier": entry.tier,
        "origin": str(entry.origin.relative_to(REPO_ROOT)) if entry.origin else None,
        "encrypted": entry.encrypted,
        "sha256": _sha256(entry.source_path) if entry.source_path.exists() else None,
        "notes": entry.notes,
    }
    if apply:
        _ensure_parent(prov_path)
        prov_path.write_text(json.dumps(payload, indent=2), encoding="utf-8")
    return f"provenance: {prov_path.relative_to(REPO_ROOT)}"


def process_entry(entry: IngestEntry, *, apply: bool) -> list[str]:
    """Materialize a single manifest entry on disk."""
    msgs: list[str] = []

    if entry.text_only:
        if entry.origin_dir is None or entry.text_dir is None:
            msgs.append(f"SKIP {entry.id}: text-only entry missing origin_dir/text_dir")
            return msgs
        if not entry.origin_dir.exists():
            msgs.append(f"MISSING origin_dir for {entry.id}: {entry.origin_dir}")
            return msgs
        for src in sorted(entry.origin_dir.glob("*.txt")):
            dst = entry.text_dir / src.name
            msgs.append(_copy_if_needed(src, dst, apply=apply))
        return msgs

    if entry.origin is None or entry.source_path is None or entry.text_path is None:
        msgs.append(f"SKIP {entry.id}: missing origin/source_path/text_path")
        return msgs

    msgs.append(_copy_if_needed(entry.origin, entry.source_path, apply=apply))
    msgs.append(
        _ensure_sibling_txt(
            entry.origin, entry.text_path, apply=apply, encrypted=entry.encrypted
        )
    )
    msgs.append(_write_provenance(entry, apply=apply))
    return msgs


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Ingest sources into corpus/.")
    parser.add_argument(
        "--manifest", default=str(MANIFEST_PATH),
        help="Path to corpus sources manifest (default: corpus/manifests/sources.yml).",
    )
    parser.add_argument(
        "--apply", action="store_true",
        help="Actually copy files; otherwise this is a dry run.",
    )
    parser.add_argument(
        "--ids", nargs="*", default=None,
        help="Optional whitelist of entry IDs to process.",
    )
    args = parser.parse_args(argv)

    entries = load_manifest(Path(args.manifest))
    if args.ids:
        wanted = set(args.ids)
        entries = [e for e in entries if e.id in wanted]
        missing = wanted - {e.id for e in entries}
        if missing:
            print(f"WARN: ids not in manifest: {sorted(missing)}", file=sys.stderr)

    mode = "APPLY" if args.apply else "DRY RUN"
    print(f"[{mode}] processing {len(entries)} entr{'y' if len(entries) == 1 else 'ies'}")
    for entry in entries:
        print(f"\n=== {entry.id}  (tier {entry.tier}, {entry.role}/{entry.family}) ===")
        for msg in process_entry(entry, apply=args.apply):
            if msg:
                print(f"  {msg}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
