#!/usr/bin/env python3
"""Corpus text-layer health check.

Reads corpus/manifests/sources.yml and, for every registered source, samples the
PDF's *native* text layer (a few pages) to decide whether it is a real text-layer
PDF (safe to extract via text) or an image-only scan (needs OCR / PDF-vision).

Read-only. Prints a table sorted worst-first so scans surface at the top.
"""
import json
import os
import sys

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
MANIFEST = os.path.join(REPO, "corpus", "manifests", "sources.yml")

try:
    import yaml
except Exception as e:
    print("need pyyaml:", e)
    sys.exit(1)

try:
    import pdfplumber
except Exception as e:
    print("need pdfplumber:", e)
    sys.exit(1)


def sample_pdf(path, sample_pages=6):
    """Return (num_pages, sampled_pages, chars_in_sample). Samples evenly."""
    with pdfplumber.open(path) as pdf:
        n = len(pdf.pages)
        if n == 0:
            return 0, 0, 0
        # evenly spaced sample indices
        if n <= sample_pages:
            idxs = list(range(n))
        else:
            step = n / sample_pages
            idxs = sorted({int(i * step) for i in range(sample_pages)})
        chars = 0
        for i in idxs:
            try:
                t = pdf.pages[i].extract_text() or ""
            except Exception:
                t = ""
            chars += len(t)
        return n, len(idxs), chars


def main():
    with open(MANIFEST) as f:
        data = yaml.safe_load(f)
    sources = data.get("sources", data) if isinstance(data, dict) else data
    rows = []
    for s in sources:
        sid = s.get("id", "?")
        rel = s.get("source_path") or s.get("origin") or ""
        path = os.path.join(REPO, rel) if rel and not os.path.isabs(rel) else rel
        if not path or not os.path.exists(path):
            rows.append((sid, "MISSING", 0, 0, 0.0, rel))
            continue
        if not path.lower().endswith(".pdf"):
            rows.append((sid, "NON-PDF", 0, 0, 0.0, rel))
            continue
        try:
            n, sampled, chars = sample_pdf(path)
        except Exception as e:
            rows.append((sid, f"ERR:{type(e).__name__}", 0, 0, 0.0, rel))
            continue
        cpp = (chars / sampled) if sampled else 0.0
        if cpp < 50:
            status = "SCAN"
        elif cpp < 400:
            status = "THIN"
        else:
            status = "TEXT"
        rows.append((sid, status, n, sampled, cpp, rel))

    order = {"MISSING": 0, "SCAN": 1, "THIN": 2, "ERR": 3, "NON-PDF": 4, "TEXT": 5}
    rows.sort(key=lambda r: (order.get(r[1].split(":")[0], 9), -r[4]))

    print(f"{'source_id':<34} {'status':<8} {'pages':>5} {'samp':>4} {'chars/pg':>9}  path")
    print("-" * 110)
    for sid, status, n, sampled, cpp, rel in rows:
        print(f"{sid:<34} {status:<8} {n:>5} {sampled:>4} {cpp:>9.0f}  {rel}")

    counts = {}
    for r in rows:
        k = r[1].split(":")[0]
        counts[k] = counts.get(k, 0) + 1
    print("-" * 110)
    print("summary:", json.dumps(counts))


if __name__ == "__main__":
    main()
