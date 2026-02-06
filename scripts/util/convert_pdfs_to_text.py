#!/usr/bin/env python3
"""
Convert all PDFs in the reference directories to text files.
Requires: pip install pdfplumber
"""

import os
import sys
from pathlib import Path

try:
    import pdfplumber
except ImportError:
    print("Installing pdfplumber...")
    import subprocess
    subprocess.check_call([sys.executable, "-m", "pip", "install", "pdfplumber"])
    import pdfplumber


def convert_pdf_to_text(pdf_path: Path) -> str:
    """Extract text from a PDF file."""
    text_parts = []
    
    with pdfplumber.open(pdf_path) as pdf:
        for i, page in enumerate(pdf.pages, 1):
            text_parts.append(f"\n{'='*60}\nPAGE {i}\n{'='*60}\n")
            
            # Extract text
            text = page.extract_text()
            if text:
                text_parts.append(text)
            
            # Extract tables
            tables = page.extract_tables()
            if tables:
                for j, table in enumerate(tables, 1):
                    text_parts.append(f"\n--- Table {j} ---\n")
                    for row in table:
                        # Clean up None values
                        row_clean = [str(cell) if cell else "" for cell in row]
                        text_parts.append(" | ".join(row_clean))
                    text_parts.append("")
    
    return "\n".join(text_parts)


def find_and_convert_pdfs(root_dir: Path):
    """Find all PDFs and convert them to text files."""
    pdf_files = list(root_dir.rglob("*.pdf"))
    
    print(f"Found {len(pdf_files)} PDF files")
    
    for pdf_path in pdf_files:
        txt_path = pdf_path.with_suffix(".txt")
        
        # Skip if text file already exists and is newer
        if txt_path.exists() and txt_path.stat().st_mtime > pdf_path.stat().st_mtime:
            print(f"  Skipping (up to date): {pdf_path.name}")
            continue
        
        print(f"  Converting: {pdf_path.name}")
        try:
            text = convert_pdf_to_text(pdf_path)
            txt_path.write_text(text, encoding="utf-8")
            print(f"    -> {txt_path.name} ({len(text)} chars)")
        except Exception as e:
            print(f"    ERROR: {e}")


if __name__ == "__main__":
    # Find the workspace root
    script_dir = Path(__file__).parent
    workspace_root = script_dir.parent
    
    # Directories to search for PDFs
    reference_dirs = [
        workspace_root / "StructuralSizer" / "src" / "members" / "codes" / "aci" / "reference",
        workspace_root / "StructuralSizer" / "src" / "members" / "codes" / "csa" / "reference",
        workspace_root / "StructuralSizer" / "src" / "slabs" / "codes" / "reference",
        workspace_root / "StructuralSizer" / "src" / "slabs" / "codes" / "concrete" / "reference",
        workspace_root / "StructuralSizer" / "src" / "slabs" / "codes" / "concrete" / "reference" / "one_way",
        workspace_root / "StructuralSizer" / "src" / "slabs" / "codes" / "concrete" / "reference" / "two_way",
        workspace_root / "StructuralSizer" / "src" / "foundations" / "codes" / "reference",
        workspace_root / "StructuralSizer" / "src" / "members" / "codes" / "aisc" / "reference",
        Path(r"C:\Users\nhirt\MIT Dropbox\Natasha Hirt\_MIT\DS Research\Synthetic_Buildings\structural_synthesizer\StructuralSizer\src\slabs\codes\concrete\reference\two_way\Ancon_Shearfix_Design_Manual_to_ACI_318-19.pdf").parent,
    ]
    
    for ref_dir in reference_dirs:
        if ref_dir.exists():
            print(f"\nSearching: {ref_dir}")
            find_and_convert_pdfs(ref_dir)
        else:
            print(f"\nSkipping (not found): {ref_dir}")
    
    print("\nDone!")
