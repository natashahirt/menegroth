---
id: expe-efb90972
type: experiment
project: menegroth
parent_id: plan-b45b0d7f
title: Ordinary-wall stage applies ASCE 7-22 §12.8.7 P-delta factor
node_label: wall P-delta factor
tags: phase7,walls,p-delta,asce-7-22
status: active
open_threads: 0
success: 'true'
files: ''
session_id: sess-741bcfda
created_at: '2026-10-30T12:23:03.554420+00:00'
updated_at: '2026-10-30T12:23:03.554420+00:00'
has_child_rationale: The linear ELF solve does not include geometric P-delta, and
  solve_pdelta! drops rigid-diaphragm links. §12.8.7 permits 1/(1-θ) on displacements
  and member forces when 0.10 < θ ≤ θmax.
---
The ordinary-wall stage multiplies seismic pier (N, V, M) and design story drifts by the drift-case multiplier from pdelta_displacement_multiplier. That factor is 1 where θ ≤ 0.10 and 1/(1−θ) where 0.10 < θ ≤ θmax. θ > θmax still throws inside the ELF analysis. Ev stays on unscaled dead load. Wind and gravity are not scaled. The stage does not call Asap.solve_pdelta!. A caller statement that member forces already include P-delta is refused, because the ELF solve is linear and applying the factor on top would count it twice.

Citation: ASCE 7-22 §12.8.7, corpus source_id asce-7-22, PDF page 188.

test_ordinary_wall_stage.jl: 121 passed. The two-line three-story office stays at θ ≤ 0.10 with every multiplier equal to 1. The one-line 1×2 three-story office, wall E times 0.35, lands in 0.10 < θ ≤ θmax and the largest stored multiplier equals 1/(1−θ).
