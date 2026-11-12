---
id: chec-bfbc9711
type: checkpoint
project: menegroth
parent_id: plan-f578a118
title: 'Special-wall shear on rows A1 and B4: Ve, §21.2.4.1 φ, §18.10.4.3'
node_label: Special shear
tags: aci-318, special-walls, shear
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-7958f9c0
created_at: '2026-11-12T00:32:46.186368+00:00'
updated_at: '2026-11-12T00:32:46.186368+00:00'
---
New `special_shear_stage.jl` (StructuralSynthesizer/src/analyze/lateral), wired in `_analyze_lateral_walls!` between steel selection and the check records. Decisions: deci-5685ffd8.

- Preliminary `special_boundary_decision` per special pier gives the route (geometry and δu, not steel). The recorded decisions are taken again after the shear pass with final steel.
- `design_special_wall_shear!` loops until no ratio moves (ρl → Mpr → Ωv → ρt → ρl floors). Per pier: smallest grid ρt with demand ≤ φ(Vn)·Vn for every action, where demand is Ve on earthquake combinations and |V| otherwise, and φ = 0.60 when Vn < the shear at Mn. Then ρl is raised to the §11.6.2(a) floor and to ρt when hwcs/ℓw ≤ 2 (§18.10.4.3), walking up until flexure passes.
- αc reads the greater of the line and stack heights (§18.10.4.2). The Chapter 11 cap 8λ√f′c·Acv stays.
- Flanged: if hwcs/ℓw > 1.5 the design throws (Mpr would omit the flange bars). A flanged pier off the displacement route takes φ = 0.60 without the Mn comparison.
- Records: check "special-wall shear"; the clause carries Ωv, ωv, φ.
- Pierced special piers: vertical segments now also throw (their shear is not taken to Ve), so the opening-edge decisions are reached only in unit tests until wall-segment Ve is built.

Not done: the thickness jump (`WallThicknessTrial`, `propose_wall_thickness`) still proposes from Vu with φ = 0.75, so a special shear failure is recorded and not answered by a thickness jump. §21.2.4.2 and §21.2.4.3 (diaphragm and foundation φ no more than the least wall φ) are not applied.

Tests: test_special_shear_stage.jl (unit and a 3-story slender office on A1 vs A3), plus boundary stage and detailing: 510/510.
