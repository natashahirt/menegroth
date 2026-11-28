---
id: chec-57209bcc
type: checkpoint
project: menegroth
parent_id: plan-8b00b305
title: Phase D global stability — decisions locked + Stage 1 (FootingAction horizontal
  shear) done & green
node_label: Phase D global stability — decisions locked + Stag
tags: ''
status: active
open_threads: 0
success: 'null'
files: StructuralSizer/src/loads/foundation_combinations.jl@41b1e0e
session_id: sess-92cee5bc
created_at: '2026-11-26T17:38:11.505298+00:00'
updated_at: '2026-11-26T17:38:11.505298+00:00'
---
Starting the deferred Phase D global-stability work (sliding/overturning/uplift), tracked as G4 (todo-3fc935ab). Full StructuralSizer suite before starting: 16811 pass / 0 fail / 7 errored (2 pre-existing vault API errors; 5 pre-existing optimize/ 'Float64 not callable' errors in test_section_relaxation.jl + test_coupled_warm_start.jl — UNRELATED to foundations, flagged for separate look). Phase A/B/C/D-A all green.

LOCKED DECISIONS (user questionnaire):
1. Demand source: extend FootingAction with horizontal base shear (Hx,Hy); Synthesizer will populate from lateral analysis.
2. Basis: ASCE 7-22 counteracting load combinations, ASD — comb 7a 0.6D+0.6(W or WT) (§2.4.1, corpus asce-7-22 PDF p.69) and seismic comb 10 0.6D-0.7Ev+0.7Eh (§2.4.5). NO separate 1.5 SF. IBC 1807.2.3 (the 1.5-SF basis the user first picked) is NOT in the corpus, so it cannot be cited — user agreed to use ASCE-7 combinations instead.
3. Resistances: friction + passive + cohesion. Grounded in Bowles 5e Eq (4-3) + Table 4-5 (corpus textbook-bowles-foundation-analysis-design-5e, PDF p.252-253/268): sliding resist = (V·tanδ + c_a·B'L' + Pp)/SF with δ in [0.5φ,φ], c_a≈0.6-1.0·c, Kp=tan²(45+φ/2). Eq (4-3) line is OCR-garbled but Table 4-5 term defs are clean. Uplift resisted by footing+overburden self-weight (baseline).

STAGE 1 DONE (green, 17/17 foundations/test_foundation_combinations.jl): FootingAction gained Hx,Hy fields (SI N) with backward-compatible constructors (4-arg and 1-arg default to zero shear); combine_foundation_action blends Hx,Hy with the same combo factors as the moments; Ev adds no horizontal term. ~20 existing call sites untouched.

REMAINING STAGES: 2) add friction/passive/cohesion params to Soil + stability check module (sliding/overturning/uplift, cited). 3) wire into spread/strip/mat designers. 4) Synthesizer lateral population of Hx,Hy + API schema/deserialize. 5) tests. Open engineering-judgment defaults to confirm with user before encoding: δ default within [0.5φ,φ], c_a default within [0.6c,1.0c], passive depth (Dc base-thickness conservative vs full Df).
