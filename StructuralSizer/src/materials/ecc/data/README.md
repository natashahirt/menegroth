# RMC EPD Dataset — Provenance

`rmc_epd_2021_2025.csv` is a parsed copy of the five RMC ready-mix EPD
workbooks under `StructuralSizer/src/materials/ecc/`. Each row is a
single plant–mix EPD; one strength class per workbook.

## Inclusion criteria

* **Curation:** 28-day design strength only.
* **Strengths:** 3, 4, 5, 6 ksi NWC and 4 ksi sand-LWC.
* **Vintage:** EPDs issued 2021–2025 (overwhelmingly 2021–2023).
* **Operators:** ASTM International (~78%) and NRMCA (~22%).
* **Boundary:** A1–A3 (raw materials → cement plant → ready-mix gate).
  A4 transport-to-site, A5 install, B-stage use, and C-stage end-of-life
  are **explicitly out of scope** — quote the median and percentiles
  with this caveat.

## Counts

| density | strength | n   |
|---------|---------:|----:|
| NWC     | 3000 psi | 159 |
| NWC     | 4000 psi | 263 |
| NWC     | 5000 psi | 156 |
| NWC     | 6000 psi |  53 |
| LWC     | 4000 psi | 447 |
| **total** |        | **1078** |

## Composition metadata

The CSV preserves a `composition_class` column derived from the
`Product Components` cell of each EPD via regex over SCM keywords
(see `_classify` in `scripts/runners/ingest_rmc_ecc.py`):

* `plain`   — cement + aggregate + admixtures only.
* `fa`      — contains fly ash (Class F or C) and **no** slag.
* `slag`    — contains slag cement (ASTM C989) and **no** fly ash.
* `slag_fa` — ternary blend with both.
* `sf`      — silica fume only (very small n).
* `ggp`     — ground-glass pozzolan only (very small n).

These tags are descriptive provenance only — Section 2 of the
flat-plate study (`StructuralStudies/src/flat_plate_methods`) does **not**
filter on them. The Monte Carlo sampler in `sweep_ecc` bootstraps from
the **full** EPD population per (strength, density-class) so that the
band reflects realistic procurement variability across the entire US
ready-mix market rather than a hand-picked sub-population. Use
`composition_class` for descriptive analyses only (e.g. to show the
SCM share underlying a strength bucket).

The `plc_flag` column flags Type 1L Portland-Limestone Cement (ASTM
C595) usage independently of the `composition_class` tag; PLC is a
clinker reduction baked in at the cement plant rather than the ready-mix
plant and stacks on top of any SCM. `has_co2_cure` flags CarbonCure-
style CO₂ mineralization at the ready-mix plant.

## Regeneration

```bash
python3 scripts/runners/ingest_rmc_ecc.py --apply
```

The script is idempotent and emits a stable row order (sorted by
strength, density class, composition, company, mixture label).

## Caveats

* `composition_class` records **presence**, not **dosage**. Mixes
  tagged `slag` use slag at unspecified replacement (typical ASTM C989
  use spans 30–50%); the same caveat applies to `fa` and `slag_fa`.
* The dataset is US-only. Do not generalize to international procurement
  without restating the source.
* The 6 ksi NWC sample (n = 53) is small relative to the other buckets;
  the Monte Carlo bootstrap inherits this shot noise — bands at 6 ksi
  are wider partly for that reason.
* The `gwp_a1a3_kg_m3` value is per declared unit (1 m³ of concrete);
  divide by the relevant `Concrete` preset's nominal density (e.g.
  2380 kg/m³ for NWC, 1840 kg/m³ for sand-LWC) to obtain the per-kg
  ECC consumed by `Concrete.ecc`.
