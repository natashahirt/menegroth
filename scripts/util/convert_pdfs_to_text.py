#!/usr/bin/env python3
"""
Convert all PDFs in the reference directories to text files.

Uses pdfplumber for text-layer PDFs and falls back to OCR (pytesseract)
for scanned / image-based PDFs.  Automatically detects two-column layouts
(per page) by analysing word-level x-coordinates and extracting each
column in reading order.

Requirements:
    pip install pdfplumber pdf2image pytesseract Pillow

System dependency (OCR only):
    Tesseract OCR must be installed and on PATH.
    - Windows:  https://github.com/UB-Mannheim/tesseract/wiki
    - macOS:    brew install tesseract
    - Linux:    sudo apt install tesseract-ocr
"""

import argparse
import re
import sys
from collections import Counter
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


# ── password map for encrypted PDFs ────────────────────────────────
# Keys are regex patterns matched against the PDF filename (stem).
PDF_PASSWORDS: dict[str, str] = {
    r"EB712": "2013PCAEB712",
}


def _lookup_password(pdf_path: Path) -> str | None:
    """Return the password for *pdf_path* if it matches a known pattern."""
    stem = pdf_path.stem
    for pattern, pw in PDF_PASSWORDS.items():
        if re.search(pattern, stem):
            return pw
    return None


# ── text-layer extraction ──────────────────────────────────────────
MIN_CHARS_PER_PAGE = 40   # below this we consider a page "empty"
MIN_WORDS_FOR_COL  = 30   # need enough words to reliably detect columns
GAP_BIN_WIDTH      = 2.0  # pts — histogram bin width for gap detection
MIN_GAP_BINS       = 4    # consecutive empty bins to qualify as a gap
MARGIN_FRACTION    = 0.2  # ignore gaps in the outer 20 % of page width


def _detect_column_split(page) -> float | None:
    """
    Detect whether *page* has a two-column layout.

    Builds a histogram of word x-midpoints across the page width, then
    looks for a wide empty gap in the centre region.  Returns the
    x-coordinate of the gap centre (the split point) or ``None`` if the
    page appears to be single-column.
    """
    words = page.extract_words(keep_blank_chars=False)
    if len(words) < MIN_WORDS_FOR_COL:
        return None

    page_width = float(page.width)
    left_margin  = page_width * MARGIN_FRACTION
    right_margin = page_width * (1 - MARGIN_FRACTION)

    # Histogram of word x-midpoints (binned)
    hits = Counter()
    for w in words:
        mid_x = (float(w["x0"]) + float(w["x1"])) / 2
        b = int(mid_x / GAP_BIN_WIDTH)
        hits[b] += 1

    # Walk bins in the centre region and find the longest empty run
    best_start = best_len = 0
    run_start = run_len = 0
    lo_bin = int(left_margin / GAP_BIN_WIDTH)
    hi_bin = int(right_margin / GAP_BIN_WIDTH)

    for b in range(lo_bin, hi_bin + 1):
        if hits[b] == 0:
            if run_len == 0:
                run_start = b
            run_len += 1
        else:
            if run_len > best_len:
                best_start, best_len = run_start, run_len
            run_len = 0
    if run_len > best_len:
        best_start, best_len = run_start, run_len

    if best_len < MIN_GAP_BINS:
        return None

    gap_centre = (best_start + best_len / 2) * GAP_BIN_WIDTH
    return gap_centre


def _extract_page_text(page, *, detect_columns: bool = True) -> tuple[str, str]:
    """
    Extract text from a single pdfplumber *page*.

    If *detect_columns* is True and a two-column layout is detected, the
    page is cropped into left and right halves and each column's text is
    extracted in reading order.  Tables are appended after the body text.
    """
    split_x = _detect_column_split(page) if detect_columns else None

    if split_x is not None:
        left  = page.crop((0, 0, split_x, page.height))
        right = page.crop((split_x, 0, page.width, page.height))
        left_text  = left.extract_text()  or ""
        right_text = right.extract_text() or ""
        page_text = left_text.rstrip() + "\n" + right_text.lstrip()
        col_tag = "  (two-column)"
    else:
        page_text = page.extract_text() or ""
        col_tag = ""

    # Tables (extracted from the full page to avoid splitting a table)
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
    return combined, col_tag


def _extract_text_layer(pdf_path: Path, *,
                        detect_columns: bool = True,
                        password: str | None = None) -> tuple[str, int]:
    """Return (full_text, n_empty_pages) using pdfplumber."""
    parts: list[str] = []
    empty = 0
    open_kw = {"password": password} if password else {}
    with pdfplumber.open(pdf_path, **open_kw) as pdf:
        for i, page in enumerate(pdf.pages, 1):
            combined, col_tag = _extract_page_text(
                page, detect_columns=detect_columns,
            )
            if len(combined) < MIN_CHARS_PER_PAGE:
                empty += 1

            parts.append(f"\n{'='*60}\nPAGE {i}{col_tag}\n{'='*60}\n")
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
def convert_pdf_to_text(pdf_path: Path, *, force_ocr: bool = False,
                        detect_columns: bool = True,
                        password: str | None = None) -> str:
    """Extract text from a PDF, falling back to OCR when needed.

    If *detect_columns* is True (the default), each page is checked for
    a two-column layout and, when detected, the columns are extracted in
    proper reading order (left then right).

    *password* is used to decrypt encrypted PDFs.  When ``None``, the
    script checks ``PDF_PASSWORDS`` for a matching filename pattern.
    """
    # Resolve password from the built-in map if not supplied explicitly
    if password is None:
        password = _lookup_password(pdf_path)

    if force_ocr:
        if not _load_ocr():
            raise RuntimeError("OCR requested but pytesseract / pdf2image not available")
        return _extract_via_ocr(pdf_path)

    text, empty_pages = _extract_text_layer(
        pdf_path, detect_columns=detect_columns, password=password,
    )

    # count total pages for the ratio check
    open_kw = {"password": password} if password else {}
    with pdfplumber.open(pdf_path, **open_kw) as pdf:
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
                          force_ocr: bool = False,
                          detect_columns: bool = True,
                          password: str | None = None):
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
            text = convert_pdf_to_text(
                pdf_path, force_ocr=force_ocr,
                detect_columns=detect_columns,
                password=password,
            )
            txt_path.write_text(text, encoding="utf-8")
            print(f"    -> {txt_path.name} ({len(text):,} chars)")
        except Exception as e:
            print(f"    ERROR: {e}")

# ── PDF page → image conversion ───────────────────────────────────
def convert_pdf_pages_to_images(pdf_path: Path, output_folder: Path,
                                image_format: str = "png",
                                pages: list[int] | None = None,
                                dpi: int = 300,
                                password: str | None = None) -> list[Path]:
    """
    Convert specific pages of a PDF to image files.

    Args:
        pdf_path:      Path to the PDF file.
        output_folder: Folder to save the images.
        image_format:  Image file format ("png", "jpg", etc.).
        pages:         1-based page numbers to extract, or None for all.
        dpi:           Resolution for output images.
        password:      Password for encrypted PDFs (auto-resolved from
                       ``PDF_PASSWORDS`` when ``None``).

    Returns:
        List of generated image paths.
    """
    _ensure("pdf2image")
    from pdf2image import convert_from_path

    pdf_path = Path(pdf_path)
    output_folder = Path(output_folder)
    output_folder.mkdir(parents=True, exist_ok=True)

    if password is None:
        password = _lookup_password(pdf_path)

    images = convert_from_path(
        str(pdf_path), dpi=dpi, fmt=image_format,
        first_page=min(pages) if pages else None,
        last_page=max(pages) if pages else None,
        userpw=password,
    )

    generated_files: list[Path] = []
    base_name = pdf_path.stem.replace(" ", "_")
    for idx, img in enumerate(images, start=1):
        page_num = pages[idx - 1] if pages else idx
        img_filename = f"{base_name}_Page_{page_num}.{image_format.lower()}"
        img_path = output_folder / img_filename
        img.save(img_path, image_format.upper())
        generated_files.append(img_path)
        print(f"    saved {img_path.name}")
    return generated_files

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
    parser.add_argument(
        "--no-columns", action="store_true",
        help="Disable automatic two-column detection (treat all pages as single-column)."
    )
    parser.add_argument(
        "--password", default=None,
        help="Password for encrypted PDFs (overrides the built-in map)."
    )
    args = parser.parse_args()
    detect_cols = not args.no_columns

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
                    text = convert_pdf_to_text(
                        p, force_ocr=args.ocr,
                        detect_columns=detect_cols,
                        password=args.password,
                    )
                    out = p.with_suffix(".txt")
                    out.write_text(text, encoding="utf-8")
                    print(f"  -> {out.name} ({len(text):,} chars)")
                except Exception as e:
                    print(f"  ERROR: {e}")
            elif p.is_dir():
                print(f"\nSearching: {p}")
                find_and_convert_pdfs(
                    p, force=args.force, force_ocr=args.ocr,
                    detect_columns=detect_cols,
                    password=args.password,
                )
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
            sizer / "slabs" / "codes" / "concrete" / "reference" / "papers",
            sizer / "slabs" / "codes" / "concrete" / "reference" / "studs",
            sizer / "walls" / "reference",
            sizer / "foundations" / "codes" / "reference",
            sizer / "codes" / "reference",
        ]

        for ref_dir in reference_dirs:
            if ref_dir.exists():
                print(f"\nSearching: {ref_dir}")
                find_and_convert_pdfs(ref_dir, force=args.force,
                                      force_ocr=args.ocr,
                                      detect_columns=detect_cols,
                                      password=args.password)
            else:
                print(f"\nSkipping (not found): {ref_dir}")

    # ── Convert selected PDF pages to images ─────────────────────────
    # Each entry: (pdf_path, first_page, last_page)
    # Images are saved to an "images/" subfolder next to the PDF.
    pages_to_image = [
        (sizer / "slabs" / "codes" / "concrete" / "reference" / "studs" / "INCON-ISS-Shear-Studs-Catalog.pdf", 14, 19),
        (sizer / "codes" / "reference" / "EB712_8-31-14.pdf", 592, 598),
    ]

    for pdf_path, first_pg, last_pg in pages_to_image:
        pages = list(range(first_pg, last_pg + 1))
        img_dir = pdf_path.parent / "images"
        stem = pdf_path.stem.replace(" ", "_")

        all_exist = all(
            (img_dir / f"{stem}_Page_{p}.png").exists() for p in pages
        )
        if all_exist:
            print(f"\n  Pages {first_pg}-{last_pg} images already exist — skipping {pdf_path.name}")
        elif pdf_path.exists():
            print(f"\n  Converting {pdf_path.name} pages {first_pg}-{last_pg} to images …")
            generated = convert_pdf_pages_to_images(pdf_path, img_dir, pages=pages)
            print(f"  {len(generated)} images saved to {img_dir}")
        else:
            print(f"\n  PDF not found: {pdf_path}")

    print("\nDone!")
