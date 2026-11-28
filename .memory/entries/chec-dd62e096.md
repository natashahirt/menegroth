---
id: chec-dd62e096
type: checkpoint
project: menegroth
parent_id: chec-3b07d815
title: NLP as-built gates for circular columns, beams, and fabricated steel
node_label: NLP as-built gates for circular columns, beams, an
tags: column-nlp,beam-nlp,as-built,aisc,aci-318
status: active
open_threads: 0
success: 'null'
files: StructuralSizer/src/members/optimize/api/rc_columns_nlp.jl@9434b4c, StructuralSizer/src/members/optimize/problems_circular.jl@a88949a,
  StructuralSizer/src/members/optimize/api/rc_beams_nlp.jl@3f4332b, StructuralSizer/src/members/optimize/api/tbeams.jl@3f4332b,
  StructuralSizer/src/members/optimize/api/steel_beams_nlp.jl@a88949a, StructuralSizer/src/members/codes/aisc/i_symm/compression.jl@a88949a,
  StructuralSizer/src/members/codes/aisc/i_symm/torsion.jl@a88949a, StructuralSizer/src/members/codes/aci/beams/t_checker.jl@3f4332b
session_id: sess-e064899e
created_at: '2026-11-05T18:12:19.931154+00:00'
updated_at: '2026-11-05T18:12:19.931154+00:00'
---
Closed the three gaps left by the shared ACI 318-19 nonsway procedure.

Circular column NLP now returns the built section only when ACIColumnChecker passes, including the §6.2.5.1 neglect test and the §6.2.5.3 δns ≤ 1.4 cap. If the snapped diameter and even bar count fail, repair starts at the largest even count still inside ρ_max and then grows the diameter by the dimension increment. A section that still fails is returned as :infeasible.

RC and T-beam NLP no longer stop at :infeasible when bar rounding drops εt below 0.004 (ACI 318-11 §10.3.5). Repair tries fewer bars at the snapped size, then a deeper section, then a wider one, at most 16 dimension steps, and keeps the solver status when a repaired section passes ACIBeamChecker.

Steel W and rectangular HSS beam NLP stay fabricated sections. Each is accepted only when AISCChecker passes the same limits the catalog uses. A failing W section grows bf, then d, then tf, then tw, within NLPWOptions. A failing HSS grows H, then t, then B. HSS flexure is AISC F7, so the dummy 1 m geometry is not a strength input.

The W gate hit an OverflowError in AISC 360-16 Eq. E4-2. Catalog shapes store Cw in m⁶; the beam NLP stores it in in⁶. Unitful's rational inch factor overflows Int64 at the sixth power, in either direction. get_Fe_torsional now evaluates the two terms in inches. Cw is scaled with the float inch factor after branching on the unit, so a catalogue section and a plate girder both reach Eq. E4-2.

Tests: StructuralSizer concrete_beam/test_deflection.jl 54 pass, including the 25 ft W-beam NLP with and without Ix_min. Earlier in this pass, column NLP 1157 (including the circular as-built gate) and T-beam optimization 70 passed, and the hogging W NLP testset passed. The StructuralSynthesizer HSS beam report was not rerun. Full StructuralSynthesizer suite and a commit are still open. Nothing was pushed.
