---
id: plan-0501eab9
type: plan
project: menegroth
parent_id: plan-35f67705
title: Slab Design Factors plans as a StructuralStudies run
node_label: Slab Design Factors plans as a StructuralStudies r
tags: slab,geometry,etabs,study
status: active
open_threads: 3
success: 'null'
files: StructuralStudies/src/slab_design_factors/geometry.jl@d427ab4, StructuralStudies/src/slab_design_factors/systems.jl@d427ab4,
  StructuralStudies/src/slab_design_factors/study.jl@d427ab4, scripts/runners/run_slab_design_factors.jl@d427ab4,
  StructuralStudies/test/test_slab_design_factors.jl@d427ab4
session_id: sess-95fa218c
created_at: '2026-11-06T17:49:25.801684+00:00'
updated_at: '2026-11-12T14:59:06.685199+00:00'
---
The 2024 Slab Design Factors plans are a StructuralStudies run: one-way slab on RC T-beams, two-way slab on RC T-beams, and composite 3VLI deck on composite steel beams.

Transcribed ETABS sections align CSV row i with connectivity i. Melody Tan's chapter counts (135 / 197 / 73) are shorter than these plans; her column lists do not close that gap. Office has 16 transcribed 0,0 rows.

Deck assumptions follow her 2016 thesis where the catalog allows: A992, unshored, L/360 live and L/240 total, 3/4 in x 6 in studs at 65 ksi, office 60/20, school 50/20, warehouse 250 psf live with 20 psf SDL. Fill is 145 pcf because the unshored span table rejects her 110 pcf. The 500 plf facade is not applied. Wall nodes are not wall edges.

A first probe on grid/x0y0, grid/x1y1, grid/x3y0, and topology/r2c1 with 2VLI and default loads: one-way completed on the three denser plans, two-way only on grid/x1y1, and every deck case failed (bay spans past the unshored table, or a singular solve). Smoke is grid/x1y1.
