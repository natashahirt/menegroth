---
id: chec-eac4ef9c
type: checkpoint
project: menegroth
parent_id: plan-c8115994
title: 'Flexible floors: story force to SFRS wall lines with collector ties, center-of-mass
  drift and θ between lines (roadmap item 1, rigid/flexible part done)'
node_label: flexible floors done
tags: flexible-diaphragm,walls,drift,asce7,collector
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-2ef6705f
created_at: '2026-11-06T20:28:14.686126+00:00'
updated_at: '2026-11-06T20:28:14.686126+00:00'
has_child_rationale: Item 1 of the wall/core roadmap; semirigid shells come next per
  deci-2ff9a26b order (flex_then_semi).
---
## What changed
- New `src/analyze/lateral/flexible_diaphragm.jl`: `DiaphragmLine`, `FlexibleDiaphragmLayout`, `flexible_diaphragm_layout!(struc, lateral)` groups the declared SFRS walls (`seismic_members`) into lines per floor (1 mm), ties each line's wall-top nodes with `Asap.RigidLink` in the line-direction translation only (`id=:collector`). Stored on new field `BuildingStructure.diaphragm_layout`. `lateral_solve_links(struc)` = rigid links + collector ties; every lateral/gravity stage solve uses it.
- Story force on a flexible floor (`diaphragm_story_loads(struc, levels, Fx, Fy, Mz)`): each plan component goes to lines parallel to it as simple spans (strips bounded at midpoints, outer strips open). ELF measures by tributary effective seismic weight (cells clipped by Sutherland-Hodgman + ELF self-weight items, checked to sum to level weight), wind by projected floor width. Within a line by wall length, then stiffness via ties. Mz not applied (§12.8.4.2.1). Gravity columns get no story force.
- Drift/θ: center-of-mass displacement interpolated between bracketing lines (§12.8.6.5, C12.8.6), line value = largest-magnitude node displacement, CM outside outermost lines throws, story below read at the projection of the upper CM. Ax unset. `FLEXIBLE_DRIFT_UNCHECKED` and `drift_checked` removed. Forces stay first order (`pdelta_in_forces = !flexible`).
- Joined wall corners on a flexible floor no longer throw: `_build_first_order` gives the corner shear-friction check first-order displacements of the same cases (zero K_G) under every gravity key.
- Provenance: ordinary-walls node writes `:diaphragm_layout`, code_version `:ordinary_walls_v2`.
- Fixed a duplicate `include("lateral/flexible_diaphragm.jl")` that broke precompile; imported `spzeros`.

## Tests
- `test_diaphragm_idealization.jl` rewritten for lines/ties/shares/CM drift/stage: 273 pass. `test_ordinary_wall_stage.jl`, `test_rigid_office_piers.jl`, `test_wind_story_cases.jl` pass.

## Open
- Frames in a flexible-floor SFRS throw (only wall lines built). Rotated plan axes throw. Semirigid shell diaphragms are the next sub-step.
