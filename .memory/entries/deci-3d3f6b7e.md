---
id: deci-3d3f6b7e
type: decision
project: menegroth
parent_id: plan-7f7bfe8c
title: Design kernel carries the wall lines the building already resolved
node_label: 'Design kernel carries the wall lines the building '
tags: fea,walls,flat-plate,core-office
status: active
open_threads: 0
success: 'null'
files: StructuralSizer/src/slabs/codes/concrete/flat_plate/input.jl@0450045, StructuralSizer/src/slabs/codes/concrete/flat_plate/utils/helpers.jl@0450045,
  StructuralSynthesizer/src/floor_design_contracts.jl@0450045, scripts/runners/design_core_office.jl@0450045,
  StructuralSynthesizer/test/core/test_core_shaft.jl@0450045
session_id: sess-c658243c
created_at: '2026-11-05T15:05:34.120940+00:00'
updated_at: '2026-11-05T15:05:34.120940+00:00'
---
The office FEA failed floor 1 on two-way deflection because the design kernel has no wall objects. `supporting_wall_segments` returned empty, so the shell was not held on the core walls and the plate spanned the shaft. The building already resolved those lines; `FlatPlateFloorInput.wall_segments` now carries them, and the kernel returns that list. The office runner uses FEA `design_approach=:strip` so the moment split is the wall-supported field, not the §13.6.4/.6 column-to-column fractions. The full design has not been rerun.
