---
id: deci-cef2f9ed
type: decision
project: menegroth
parent_id: plan-8fcebf0f
title: A failing wall corner gets its own horizontal ratio; legs keep theirs
node_label: Corner ratio
tags: walls,joined,shear-friction,corner,decision
status: active
open_threads: 0
success: 'null'
files: StructuralSynthesizer/src/analyze/lateral/wall_joints.jl@8200d02, StructuralSynthesizer/test/analyze/test_wall_joints.jl@8200d02,
  StructuralSynthesizer/test/analyze/test_ordinary_wall_stage.jl@8200d02, StructuralSynthesizer/src/postprocess/engineering_report.jl@8200d02
session_id: sess-83adb327
created_at: '2026-11-04T20:09:47.971421+00:00'
updated_at: '2026-11-04T20:09:47.971421+00:00'
has_child_rationale: User chose a local corner ratio over raising both legs' ρt
---
Confirmed by user 2026-11-04.

ACI 318-19 §11.2.4.1 (aci-318-19, PDF p. 168) requires walls to be anchored to intersecting walls and gives no amount. The amount is shear friction §22.9.4.2 (PDF p. 434), capped by Table 22.9.4.4 (PDF p. 435).

`select_corner_ratio` starts at the larger leg ρt. When it fails, it walks ORDINARY_WALL_RHO_GRID up to the first ratio that passes. The legs' ρl and ρt are not changed, so the pier checks do not run again.

Above φ × the Table 22.9.4.4 limit, steel cannot pass. That case is `capped`: the ratio stays at the leg ratio, the record fails, and the clause says a thicker wall is needed. Above the grid top, the grid top is reported and the record fails.

Records on the lower wall index: "shear friction" at the selected ratio, and "corner horizontal ratio (selected)" (ratio 0; demand = corner ρ, capacity = larger leg ρt). Development of fy on both sides, §22.9.5.1 (PDF p. 436), needs bar sizes, so it is stated on the clause and not checked. Extra corner bars are not in the quantity takeoff.

Rejected: raising both legs' ρt. It spreads steel along both walls for a local demand, and §11.6.2 can raise ρl with it, which forces the pier checks to run again.

Tests: unit (kept, raised to 0.005, capped, grid top) and stage (1 ksi ties raise the corner only and pass; 0.1 ksi fails at the grid top and the summary fails). Fresh run of the five wall files: 537/537.
