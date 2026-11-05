---
id: chec-1e96d9a3
type: checkpoint
project: menegroth
parent_id: deci-94541642
title: Column NLP repair lowers a ρ_max start instead of skipping the size
node_label: 'Column NLP repair lowers a ρ_max start instead of '
tags: column-nlp,as-built,repair,pixelframe,tests
status: active
open_threads: 0
success: 'null'
files: StructuralSizer/src/members/optimize/api/rc_columns_nlp.jl@9434b4c, StructuralSizer/test/optimize/test_column_nlp.jl@9434b4c,
  StructuralSynthesizer/test/optimization/test_nlp_vs_catalog_convergence.jl@9434b4c,
  StructuralSynthesizer/test/report_generators/test_column_sizing_report.jl@9434b4c
session_id: sess-5a3b65c9
created_at: '2026-11-05T15:17:55.842305+00:00'
updated_at: '2026-11-05T15:17:55.842305+00:00'
---
RC column NLP was returning sections 2-3x the catalog's (e.g. 18x24 with 32 #8 for 180 kip / 74 kip-ft, where 12x12 with 6 bars passes ACIColumnChecker).

Cause: Ipopt stops at rho_opt = rho_max = 0.06. Snapping up and rounding the bar count to even puts rhog over 0.06, so the as-built gate rejects it. `_rc_column_nlp_repair` only tried counts >= the rho_opt count, which stayed over the cap at every b x h until the 32-bar limit forced it under. Fix: start at min(rho_opt count, largest even count within rho_max); skip a size only when the tie minimum exceeds rho_max. Every candidate still passes the real checker.

Tests: 'RC Column: NLP vs Discrete' moderate/heavy now compare to the slenderness-on catalog (bare geometry lengths are metres: 11.5 m and 13.1 m columns); the old hand check ignored slenderness. PixelFrame workflow 6.5 demand changed to Mu = 2 kN-m: the checker's AISC H1 analog (commit a2469fcd) made 400 kN / 10 kN-m infeasible at every fc' (55 MPa -> 1.15). At 2 kN-m: fc30 1.27, fc40 0.94.

Open: the slenderness checker has no kLu/r > 100 limit; a 12x20 at 11.5 m has weak-axis kLu/r ~ 126. Not verified against the corpus. NLP smooth P-M and EI=0.4EcIg/(1+bdns) are conservative vs the checker (efficiency only).
