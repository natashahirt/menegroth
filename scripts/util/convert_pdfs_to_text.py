#!/usr/bin/env python3
"""
Convert all PDFs in the reference directories to text files.

Uses pdfplumber for text-layer PDFs and falls back to OCR (pytesseract)
for scanned / image-based PDFs.

Requirements:
    pip install pdfplumber pdf2image pytesseract Pillow

System dependency (OCR only):
    Tesseract OCR must be installed and on PATH.
    - Windows:  https://github.com/UB-Mannheim/tesseract/wiki
    - macOS:    brew install tesseract
    - Linux:    sudo apt install tesseract-ocr
"""

import argparse
import sys
from pathlib import Path

# ── guaranteed dependency ──────────────────────────────────────────
def _ensure(pkg: str, pip_name: str | None = None):
    """Import *pkg*; install via pip if missing."""
    try:
        return __import__(pkg)
    except ImportError:
        import subprocess
        subprocess.check_call(
            [sys.executable, "-m", "pip", "install", pip_name or pkg]
        )
        return __import__(pkg)

pdfplumber = _ensure("pdfplumber")

# OCR deps — imported lazily so the script still works without them
_ocr_available: bool | None = None

def _load_ocr():
    """Try to import OCR dependencies; cache the result."""
    global _ocr_available
    if _ocr_available is not None:
        return _ocr_available
    try:
        _ensure("pdf2image")
        _ensure("pytesseract")
        _ensure("PIL", "Pillow")
        _ocr_available = True
    except Exception:
        _ocr_available = False
    return _ocr_available


# ── text-layer extraction ──────────────────────────────────────────
MIN_CHARS_PER_PAGE = 40  # below this we consider a page "empty"

def _extract_text_layer(pdf_path: Path) -> tuple[str, int]:
    """Return (full_text, n_empty_pages) using pdfplumber."""
    parts: list[str] = []
    empty = 0
    with pdfplumber.open(pdf_path) as pdf:
        for i, page in enumerate(pdf.pages, 1):
            page_text = page.extract_text() or ""
            tables = page.extract_tables() or []

            table_text = ""
            if tables:
                table_parts = []
                for j, table in enumerate(tables, 1):
                    table_parts.append(f"\n--- Table {j} ---")
                    for row in table:
                        row_clean = [str(c) if c else "" for c in row]
                        table_parts.append(" | ".join(row_clean))
                table_text = "\n".join(table_parts)

            combined = (page_text + "\n" + table_text).strip()
            if len(combined) < MIN_CHARS_PER_PAGE:
                empty += 1

            parts.append(f"\n{'='*60}\nPAGE {i}\n{'='*60}\n")
            parts.append(combined if combined else "(no text extracted)")
    return "\n".join(parts), empty


# ── OCR fallback ───────────────────────────────────────────────────
def _extract_via_ocr(pdf_path: Path) -> str:
    """Convert each page to an image, then run Tesseract OCR."""
    from pdf2image import convert_from_path
    import pytesseract

    images = convert_from_path(pdf_path, dpi=300)
    parts: list[str] = []
    for i, img in enumerate(images, 1):
        parts.append(f"\n{'='*60}\nPAGE {i}  (OCR)\n{'='*60}\n")
        text = pytesseract.image_to_string(img)
        parts.append(text.strip() if text.strip() else "(OCR produced no text)")
    return "\n".join(parts)


# ── main conversion logic ─────────────────────────────────────────
def convert_pdf_to_text(pdf_path: Path, *, force_ocr: bool = False) -> str:
    """Extract text from a PDF, falling back to OCR when needed."""
    if force_ocr:
        if not _load_ocr():
            raise RuntimeError("OCR requested but pytesseract / pdf2image not available")
        return _extract_via_ocr(pdf_path)

    text, empty_pages = _extract_text_layer(pdf_path)

    # count total pages for the ratio check
    with pdfplumber.open(pdf_path) as pdf:
        total = len(pdf.pages)

    mostly_empty = total > 0 and (empty_pages / total) > 0.5

    if mostly_empty:
        if _load_ocr():
            print(f"    Text layer mostly empty ({empty_pages}/{total} pages) — running OCR …")
            return _extract_via_ocr(pdf_path)
        else:
            print(f"    WARNING: text layer mostly empty but OCR deps not installed — output will be sparse")

    return text


# ── directory walker ───────────────────────────────────────────────
def find_and_convert_pdfs(root_dir: Path, *, force: bool = False,
                          force_ocr: bool = False):
    """Find all PDFs under *root_dir* and convert to .txt."""
    pdf_files = sorted(root_dir.rglob("*.pdf"))
    print(f"Found {len(pdf_files)} PDF files")

    for pdf_path in pdf_files:
        txt_path = pdf_path.with_suffix(".txt")

        if (not force and txt_path.exists()
                and txt_path.stat().st_mtime > pdf_path.stat().st_mtime):
            print(f"  Skipping (up to date): {pdf_path.name}")
            continue

        print(f"  Converting: {pdf_path.name}")
        try:
            text = convert_pdf_to_text(pdf_path, force_ocr=force_ocr)
            txt_path.write_text(text, encoding="utf-8")
            print(f"    -> {txt_path.name} ({len(text):,} chars)")
        except Exception as e:
            print(f"    ERROR: {e}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="Convert reference PDFs to text files."
    )
    parser.add_argument(
        "paths", nargs="*",
        help="Specific PDF files or directories to convert. "
             "If omitted, all known reference directories are scanned."
    )
    parser.add_argument(
        "--force", action="store_true",
        help="Re-convert even if the .txt is up to date."
    )
    parser.add_argument(
        "--ocr", action="store_true",
        help="Force OCR on every PDF (skip text-layer extraction)."
    )
    args = parser.parse_args()

    # Find the workspace root (scripts/util/ -> scripts/ -> workspace root)
    script_dir = Path(__file__).parent
    workspace_root = script_dir.parent.parent
    sizer = workspace_root / "StructuralSizer" / "src"

    if args.paths:
        # Explicit paths supplied — convert each one
        for p in args.paths:
            p = Path(p)
            if p.is_file() and p.suffix.lower() == ".pdf":
                print(f"\nConverting: {p}")
                try:
                    text = convert_pdf_to_text(p, force_ocr=args.ocr)
                    out = p.with_suffix(".txt")
                    out.write_text(text, encoding="utf-8")
                    print(f"  -> {out.name} ({len(text):,} chars)")
                except Exception as e:
                    print(f"  ERROR: {e}")
            elif p.is_dir():
                print(f"\nSearching: {p}")
                find_and_convert_pdfs(p, force=args.force, force_ocr=args.ocr)
            else:
                print(f"\nSkipping (not a PDF or directory): {p}")
    else:
        # Default: scan all known reference directories
        reference_dirs = [
            sizer / "members" / "codes" / "aci" / "reference",
            sizer / "members" / "codes" / "csa" / "reference",
            sizer / "members" / "codes" / "aisc" / "reference",
            sizer / "members" / "codes" / "aisc" / "reference" / "fire",
            sizer / "members" / "codes" / "pixelframe" / "reference",
            sizer / "slabs" / "codes" / "reference",
            sizer / "slabs" / "codes" / "concrete" / "reference",
            sizer / "slabs" / "codes" / "concrete" / "reference" / "one_way",
            sizer / "slabs" / "codes" / "concrete" / "reference" / "two_way",
            sizer / "foundations" / "codes" / "reference",
            sizer / "codes" / "reference",
        ]

        for ref_dir in reference_dirs:
            if ref_dir.exists():
                print(f"\nSearching: {ref_dir}")
                find_and_convert_pdfs(ref_dir, force=args.force,
                                      force_ocr=args.ocr)
            else:
                print(f"\nSkipping (not found): {ref_dir}")

    print("\nDone!")
