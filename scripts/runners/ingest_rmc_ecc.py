#!/usr/bin/env python3
"""Ingest NRMCA / RMC ready-mix EPD workbooks into a single provenanced CSV.

Reads the five workbooks under ``StructuralSizer/src/materials/ecc/`` and
emits ``StructuralSizer/src/materials/ecc/data/rmc_epd_2021_2025.csv``,
one row per individual plant–mix EPD.

Inclusion criteria (matches the input file naming):

* ``28 days`` design strength (filtered into upstream xlsx by curation time).
* US plants with ASTM International or NRMCA-listed EPDs, vintages
  2021-2025.
* A1–A3 (cradle-to-gate) GWP only — A4 transport-to-site, A5 install,
  use-phase and end-of-life are explicitly out of scope.

The CSV is consumed by :file:`StructuralSizer/src/materials/ecc/distributions.jl`
to expose per-(strength, composition) ECC distributions to the
``flat_plate_methods`` Section 2 sensitivity sweep.

Usage::

    python3 scripts/runners/ingest_rmc_ecc.py [--apply]

Without ``--apply`` the script prints summary stats but does not write
the CSV. With ``--apply`` it overwrites the destination atomically.
"""

from __future__ import annotations

import argparse
import csv
import re
import statistics
import subprocess
import sys
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Iterable, Iterator

REPO_ROOT = Path(__file__).resolve().parents[2]
ECC_DIR = REPO_ROOT / "StructuralSizer" / "src" / "materials" / "ecc"
OUT_DIR = ECC_DIR / "data"
OUT_CSV = OUT_DIR / "rmc_epd_2021_2025.csv"

# Workbook ↔ density class. Order is also the canonical write order.
WORKBOOKS: tuple[tuple[str, int, str], ...] = (
    ("RMC_GWPs_Structural-Use_NWC_3ksi_28days.xlsx", 3000, "NWC"),
    ("RMC_GWPs_Structural-Use_NWC_4ksi_28days.xlsx", 4000, "NWC"),
    ("RMC_GWPs_Structural-Use_NWC_5ksi_28days.xlsx", 5000, "NWC"),
    ("RMC_GWPs_Structural-Use_NWC_6ksi_28days.xlsx", 6000, "NWC"),
    ("RMC_GWPs_LWC_4ksi_28days.xlsx",                4000, "LWC"),
)

# Source-column indexes (1-based, matching the xlsx headers verified by
# ``head 1`` of any workbook). The script asserts the headers match these
# names at runtime so a column-shift in a future export fails loudly.
COL = {
    "company":             1,
    "plant_city":          8,
    "plant_state":         9,
    "plant_zip":          10,
    "us_region":          13,
    "epd_operator":       14,
    "epd_date":           15,
    "mixture_label":      17,
    "mixture_description":18,
    "strength_psi":       19,
    "product_components": 22,
    "gwp_a1a3":           23,
    "gwp_a1":             24,
    "gwp_a2":             25,
    "gwp_a3":             26,
    "source_link":       118,
}

EXPECTED_HEADERS = {
    "company":             "Company",
    "plant_city":          "Plant Location - City",
    "plant_state":         "Plant Location - State",
    "plant_zip":           "Plant Location - Zip",
    "us_region":           "U.S. Region of Plant",
    "epd_operator":        "EPD Program Operator",
    "epd_date":            "EPD Date of Issue",
    "mixture_label":       "Mixture Label",
    "mixture_description": "Mixture Description",
    "strength_psi":        "Concrete Compressive Strength (psi)",
    "product_components":  "Product Components",
    "gwp_a1a3":            "A1-A3 Global Warming Potential (kg CO2-eq)",
    "gwp_a1":              "A1 GWP",
    "gwp_a2":              "A2 GWP",
    "gwp_a3":              "A3 GWP",
    "source_link":         "EPD Source Link",
}

# Output column order — keep this stable; downstream Julia parser is
# header-keyed but consumers may reasonably eyeball the file.
OUT_COLUMNS: tuple[str, ...] = (
    "strength_psi",
    "density_class",
    "gwp_a1a3_kg_m3",
    "gwp_a1",
    "gwp_a2",
    "gwp_a3",
    "composition_class",
    "plc_flag",
    "has_fa",
    "has_slag",
    "has_sf",
    "has_ggp",
    "has_co2_cure",
    "epd_year",
    "epd_operator",
    "company",
    "plant_city",
    "plant_state",
    "plant_zip",
    "us_region",
    "mixture_label",
    "mixture_description",
    "source_link",
)


def _ensure(pkg: str, pip_name: str | None = None):
    """Import *pkg*; install via pip if missing (mirrors ``ingest.py``)."""
    try:
        return __import__(pkg)
    except ImportError:
        subprocess.check_call(
            [sys.executable, "-m", "pip", "install", pip_name or pkg]
        )
        return __import__(pkg)


# ----------------------------------------------------------------------
# Parsing
# ----------------------------------------------------------------------

@dataclass
class Row:
    """One parsed EPD row, ready for CSV emission."""
    strength_psi: int
    density_class: str
    gwp_a1a3_kg_m3: float
    gwp_a1: float | None
    gwp_a2: float | None
    gwp_a3: float | None
    composition_class: str
    plc_flag: bool
    has_fa: bool
    has_slag: bool
    has_sf: bool
    has_ggp: bool
    has_co2_cure: bool
    epd_year: int | None
    epd_operator: str
    company: str
    plant_city: str
    plant_state: str
    plant_zip: str
    us_region: str
    mixture_label: str
    mixture_description: str
    source_link: str


def _classify(components: str) -> tuple[str, dict[str, bool]]:
    """Return ``(composition_class, flag_dict)`` from a ``Product Components`` cell.

    Flags are independent presence checks; ``composition_class`` is the
    primary bucket used by Section 2 (``plain`` / ``fa`` / ``slag`` /
    ``slag_fa``; rare ``sf`` and ``ggp`` are kept as their own classes
    but excluded from the main figure for low n).
    """
    c = (components or "").lower()
    flags = {
        "has_fa":        bool(re.search(r"fly\s*ash|class\s*[fc]", c)),
        "has_slag":      "slag" in c,
        "has_sf":        "silica fume" in c,
        "has_ggp":       bool(re.search(r"ground[\s-]*glass|ggp\b", c)),
        # PLC detection: ASTM C595 Type 1L (== "type il" with a one or
        # an L). Some EPDs also spell it out. Excludes generic
        # "limestone" aggregate hits.
        "plc_flag":      bool(re.search(r"type\s*[i1]l\b|portland[\s-]*limestone", c)),
        "has_co2_cure":  bool(re.search(r"carbon[\s-]*cure|co2\b", c)),
    }

    if flags["has_slag"] and flags["has_fa"]:
        cls = "slag_fa"
    elif flags["has_slag"]:
        cls = "slag"
    elif flags["has_fa"]:
        cls = "fa"
    elif flags["has_sf"]:
        cls = "sf"
    elif flags["has_ggp"]:
        cls = "ggp"
    else:
        cls = "plain"
    return cls, flags


def _coerce_year(value) -> int | None:
    """Coerce the polymorphic ``EPD Date of Issue`` cell into a year int."""
    if value is None:
        return None
    if isinstance(value, datetime):
        return value.year
    s = str(value).strip()
    m = re.search(r"(20\d{2})", s)
    return int(m.group(1)) if m else None


def _coerce_float(value) -> float | None:
    if value in (None, ""):
        return None
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def _coerce_str(value) -> str:
    if value is None:
        return ""
    return str(value).strip()


def _validate_headers(ws, filename: str) -> None:
    """Assert that source-column headers still match expectations."""
    for key, idx in COL.items():
        actual = ws.cell(row=1, column=idx).value
        expected = EXPECTED_HEADERS[key]
        if actual != expected:
            raise RuntimeError(
                f"{filename}: column {idx} header is {actual!r}, "
                f"expected {expected!r}. The xlsx schema may have changed; "
                f"update COL / EXPECTED_HEADERS in this script."
            )


def _parse_workbook(path: Path, strength: int, density_class: str) -> Iterator[Row]:
    openpyxl = _ensure("openpyxl")
    # NOTE: read_only=True turns out to be ~100x slower than the default
    # mode for these particular workbooks (likely due to many merged
    # cells in the headers). The largest file is < 300 KB so loading
    # in eager mode costs negligible memory.
    wb = openpyxl.load_workbook(path, data_only=True)
    try:
        ws = wb["Sheet1"]
        _validate_headers(ws, path.name)
        for r in range(2, ws.max_row + 1):
            gwp = _coerce_float(ws.cell(row=r, column=COL["gwp_a1a3"]).value)
            if gwp is None:
                continue
            comp_str = _coerce_str(ws.cell(row=r, column=COL["product_components"]).value)
            cls, flags = _classify(comp_str)
            yield Row(
                strength_psi      = strength,
                density_class     = density_class,
                gwp_a1a3_kg_m3    = gwp,
                gwp_a1            = _coerce_float(ws.cell(row=r, column=COL["gwp_a1"]).value),
                gwp_a2            = _coerce_float(ws.cell(row=r, column=COL["gwp_a2"]).value),
                gwp_a3            = _coerce_float(ws.cell(row=r, column=COL["gwp_a3"]).value),
                composition_class = cls,
                plc_flag          = flags["plc_flag"],
                has_fa            = flags["has_fa"],
                has_slag          = flags["has_slag"],
                has_sf            = flags["has_sf"],
                has_ggp           = flags["has_ggp"],
                has_co2_cure      = flags["has_co2_cure"],
                epd_year          = _coerce_year(ws.cell(row=r, column=COL["epd_date"]).value),
                epd_operator      = _coerce_str(ws.cell(row=r, column=COL["epd_operator"]).value),
                company           = _coerce_str(ws.cell(row=r, column=COL["company"]).value),
                plant_city        = _coerce_str(ws.cell(row=r, column=COL["plant_city"]).value),
                plant_state       = _coerce_str(ws.cell(row=r, column=COL["plant_state"]).value),
                plant_zip         = _coerce_str(ws.cell(row=r, column=COL["plant_zip"]).value),
                us_region         = _coerce_str(ws.cell(row=r, column=COL["us_region"]).value),
                mixture_label     = _coerce_str(ws.cell(row=r, column=COL["mixture_label"]).value),
                mixture_description = _coerce_str(ws.cell(row=r, column=COL["mixture_description"]).value),
                source_link       = _coerce_str(ws.cell(row=r, column=COL["source_link"]).value),
            )
    finally:
        wb.close()


# ----------------------------------------------------------------------
# Summary / write
# ----------------------------------------------------------------------

def _summary(rows: list[Row]) -> None:
    by_class: dict[tuple[int, str], list[float]] = {}
    by_comp: dict[tuple[int, str, str], list[float]] = {}
    for row in rows:
        key = (row.strength_psi, row.density_class)
        by_class.setdefault(key, []).append(row.gwp_a1a3_kg_m3)
        ckey = (row.strength_psi, row.density_class, row.composition_class)
        by_comp.setdefault(ckey, []).append(row.gwp_a1a3_kg_m3)

    print("Per-strength A1-A3 GWP distribution (kg CO2e/m3):")
    print(f"  {'Class':14s}  {'n':>4s}  {'p10':>5s}  {'p50':>5s}  {'p90':>5s}  {'mean':>5s}  {'sd':>4s}")
    for (psi, dc), vals in sorted(by_class.items()):
        vals.sort()
        n = len(vals)
        p10 = vals[int(0.10 * n)]
        p50 = statistics.median(vals)
        p90 = vals[int(0.90 * n)]
        mean = statistics.mean(vals)
        sd = statistics.stdev(vals) if n > 1 else 0.0
        print(f"  {dc} {psi:5d}      {n:4d}  {p10:5.0f}  {p50:5.0f}  {p90:5.0f}  {mean:5.0f}  {sd:4.0f}")

    print("\nPer-(strength, composition) bucket sizes:")
    for (psi, dc, cls), vals in sorted(by_comp.items()):
        print(f"  {dc} {psi:5d} {cls:8s}  n={len(vals):4d}")


def _write_csv(rows: list[Row], path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".csv.tmp")
    with tmp.open("w", newline="") as f:
        w = csv.writer(f)
        w.writerow(OUT_COLUMNS)
        for row in rows:
            w.writerow([_csv_field(getattr(row, c)) for c in OUT_COLUMNS])
    tmp.replace(path)
    print(f"\nWrote {path.relative_to(REPO_ROOT)}  ({len(rows)} rows)")


def _csv_field(value) -> str:
    if value is None:
        return ""
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, float):
        return repr(value) if (value != value) else f"{value:.6g}"
    return str(value)


# ----------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------

def _sort_key(r: Row) -> tuple:
    """Stable sort: (strength, density_class, composition, company, label)."""
    return (
        r.strength_psi, r.density_class, r.composition_class,
        r.company, r.mixture_label,
    )


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--apply", action="store_true",
                   help="Write the CSV (default: dry run, summary only).")
    args = p.parse_args(argv)

    rows: list[Row] = []
    for filename, strength, density_class in WORKBOOKS:
        src = ECC_DIR / filename
        if not src.exists():
            raise FileNotFoundError(f"Workbook missing: {src}")
        n_before = len(rows)
        rows.extend(_parse_workbook(src, strength, density_class))
        print(f"  parsed {filename}: {len(rows) - n_before} rows")

    rows.sort(key=_sort_key)
    print()
    _summary(rows)

    if args.apply:
        _write_csv(rows, OUT_CSV)
    else:
        print(f"\nDry run — pass --apply to write {OUT_CSV.relative_to(REPO_ROOT)}.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
