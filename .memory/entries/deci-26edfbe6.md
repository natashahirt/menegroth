---
id: deci-26edfbe6
type: decision
project: menegroth
parent_id: plan-1d645a44
title: Size column ties for shear on frame columns and door jambs
node_label: Column shear ties
tags: aci-318-19,columns,shear,jambs,ties
status: active
open_threads: 0
success: 'null'
files: StructuralSizer/src/members/codes/aci/columns/shear.jl@5dbb4c3, StructuralSizer/src/detailing/column.jl@5dbb4c3,
  StructuralSynthesizer/src/workflow/capture_results.jl@5dbb4c3, StructuralSynthesizer/src/analyze/lateral/wall_pier_checks.jl@5dbb4c3,
  StructuralSynthesizer/src/postprocess/detailing.jl@5dbb4c3
session_id: sess-20de3db2
created_at: '2026-11-07T20:58:02.689931+00:00'
updated_at: '2026-11-07T20:58:02.689931+00:00'
has_child_rationale: The lobby jambs were failing a shear check that never sized the
  ties, and ordinary columns had no shear check at all.
---
Ordinary RC columns and the wall segments ACI 318-19 §2.3 treats as columns share `design_column_shear` (corpus aci-318-19).

The check is §10.5.3.1: φVn ≥ Vu, with Vn from §22.5. φ = 0.75 (§21.2.1). Equation (a) of Table 22.5.5.1 is used once Av ≥ Av,min; equation (c) is used below that. Av,min is required only where Vu > 0.5φVc of the equation that applies at the support spacing (§10.6.2.1). Table 10.7.6.5.2 then limits that shear reinforcement. Eq. (22.5.1.11) applies when both axes exceed one half. √f'c inside Vc is capped at 100 psi (§22.5.3.1); Nu/(6Ag) at 0.05f'c and Vc at 5λ√f'c bw d (§22.5.5.1). fyt used for Vs and Av,min is capped at 60 ksi (§22.5.3.3, R22.5.3.3). Torsion is not added (R10.5.4). The concrete section is not grown; a demand past Eq. (22.5.1.2) fails.

Frame columns do not store which element axis is the section width. Both pairings of (Fy, Fz) with (b, h) are checked and the worse ratio is kept. That pairing is engineering judgment. Jambs are not guessed: the section is built with b = thickness and h = segment length, in-plane shear is Vu_y, and out-of-plane shear is Vu_x.

The resulting tie spacing is placed by `detail_column` (the lesser of that spacing and §25.7.2.1). Jamb ties are quoted on the wall note and are not drawn over the distributed wall bars. Steel columns are left unchecked.

Tests: StructuralSizer concrete_column/test_column_shear.jl 52/52, detailing 177/177, StructuralSynthesizer analyze/test_wall_pier_checks.jl 126/126, integration/test_building_detailing.jl 152/152. The saved core_office scene still shows the old withheld-shear flag until that building is redesigned.
