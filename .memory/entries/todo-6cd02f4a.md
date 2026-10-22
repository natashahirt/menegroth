---
id: todo-6cd02f4a
type: todo
project: menegroth
parent_id: deci-e2344cc5
title: Deferred wall-lateral follow-ups (from enclosure-guard + geometry-helper round)
node_label: Deferred wall-lateral follow-ups (from enclosure-g
tags: ''
status: active
open_threads: 0
success: 'null'
files: StructuralSizer/src/walls/layout_problem.jl@2a0b2c4, StructuralSynthesizer/src/walls_bridge.jl@2a0b2c4
session_id: sess-33aeeb2f
created_at: '2026-10-22T03:17:24.189992+00:00'
updated_at: '2026-10-22T03:17:24.189992+00:00'
---
Non-blocking items deliberately deferred (all safe-direction):
1. GUARD F2 (crit2, P2 safe): the solve_wall_layout enclosure gate + evaluate_lateral run _walls_from_density over ALL candidates, so a density-removed candidate (rho~=rho_min, k~1e-9*kmax) parked OUTSIDE the plate over-rejects a sound layout with :geometry_inconsistent. Over-rejection is conservative (never certifies a bad layout) and moot once the geometry helper supplies the true footprint. FIX in Phase 3: filter the enclosure proxy to ACTIVE walls (rho>rho_min) in both the gate and the metric so they stay consistent. Reproducer scripts/runners/crit9_wall_enclosure_contract_attack.jl.
2. DOC NITS (crit4, P2): walls_bridge.jl assert_walls_enclosed — state the frame-mismatch residual's quantitative worst-case bound (a uniform whole-system shift up to ~halfwidth can keep a center wall numerically inside the box) numerically in the docstring; add an explicit negative-halfwidth guard mirroring _plate_encloses_walls (currently still fails closed, so direction is safe).
3. PHASE 3/6 BRIDGE REQUIREMENT (architectural): the production building->evaluator bridge MUST populate Wall.x1..y2 from the same skeleton vertex_coords the plate helper reads (they are currently disjoint sources). Wire story_plate_geometry(...; walls=...) into the bridge so the enclosure assertion runs at construction. story.faces must be the COMPLETE story floor (the walls⊆plate⊂occupants residual relies on this + Phase 10 FEM authority).
4. effective_seismic_weight applies only the dead-load core; ASCE 7-22 §12.7.2 Items 1/2/4/3/5/6 (storage 25% live, partition 0.48 kN/m2 min, >2.16 kN/m2 flat-roof snow 15%, equipment/landscaping/fluids) need per-area data Cell lacks — caller must augment sdl if one governs.
