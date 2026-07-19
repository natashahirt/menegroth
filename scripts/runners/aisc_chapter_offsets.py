#!/usr/bin/env python3
"""Locate chapter-header character offsets in the AISC 360-16 corpus text.

Read-only helper for scoping a grounded-extraction slice. Prints the character
offset of each spec/commentary chapter header so an extraction run can target a
specific chapter range (e.g. Chapter F flexure + Chapter G shear) via explicit
``char_start``/``char_end`` slices.
"""
import os
import re

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
TXT = os.path.join(REPO, "corpus", "text", "codes", "aisc", "AISC-360-16.txt")

# Distinctive spec/commentary chapter headers (header line + its title line).
HEADERS = [
    ("CHAPTER E", "DESIGN OF MEMBERS FOR COMPRESSION"),
    ("CHAPTER F", "DESIGN OF MEMBERS FOR FLEXURE"),
    ("CHAPTER G", "DESIGN OF MEMBERS FOR SHEAR"),
    ("CHAPTER H", "DESIGN OF MEMBERS FOR COMBINED FORCES AND TORSION"),
]


def main():
    with open(TXT, encoding="utf-8") as f:
        text = f.read()
    print(f"corpus text: {TXT}")
    print(f"total_chars: {len(text)}")
    print("-" * 90)
    for head, title in HEADERS:
        # Every occurrence of the "CHAPTER X\n...TITLE" header (spec + commentary).
        pat = re.compile(re.escape(head) + r"\s*\n" + re.escape(title))
        hits = [m.start() for m in pat.finditer(text)]
        print(f"{head:<12} {title[:40]:<42} offsets={hits}")


if __name__ == "__main__":
    main()
