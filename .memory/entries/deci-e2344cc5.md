---
id: deci-e2344cc5
type: decision
project: menegroth
parent_id: plan-a2a6128f
title: 'Reduced wall lateral: plate-enclosure guard + skeleton-derived plate geometry
  (close crit7 provenance residual at its source)'
node_label: 'Reduced wall lateral: plate-enclosure guard + skel'
tags: ''
status: active
open_threads: 0
success: 'null'
files: StructuralSizer/src/walls/lateral_evaluator.jl@2a0b2c4, StructuralSizer/src/walls/layout_problem.jl@2a0b2c4,
  StructuralSynthesizer/src/walls_bridge.jl@2a0b2c4, StructuralSynthesizer/src/StructuralSynthesizer.jl@2a0b2c4,
  StructuralSizer/test/walls/test_walls.jl@2a0b2c4, StructuralSynthesizer/test/core/test_walls_bridge.jl@2a0b2c4,
  StructuralSynthesizer/test/runtests.jl@2a0b2c4
session_id: sess-33aeeb2f
created_at: '2026-10-22T03:16:55.750318+00:00'
updated_at: '2026-10-22T03:16:55.750318+00:00'
---
CONTEXT: the reduced wall tier (ReducedDiaphragmEvaluator) computes exact 4-corner interstory drift + torsion over plate_center ± plan_halfwidth — exact ONLY if that rectangle encloses the drift-relevant points. plate_center/plan_halfwidth were free, independent fields with no cross-check against the walls. crit7 (reproducer scripts/runners/crit7_plate_enclosure_attack.jl) showed an under-covering/mis-framed plate could certify an over-limit layout (true edge drift 1.19*DL, 19% over ASCE 7-22 §12.12.1) as feasible=true. User asked 'aren't WE the ones building the evaluator?' — correct: today only test fixtures construct it (to_wall_line has no production callers); the production bridge is unwritten. User chose geometry_helper_now: fix at construction, not just guard.

TWO COMPOSED FIXES (one coordinator run, run-755bcb39):
(1) ENCLOSURE GUARD (StructuralSizer/src/walls/lateral_evaluator.jl + layout_problem.jl): _plate_encloses_walls(ev, walls_s) — per story, fail closed (corner_drift/res.torsion/util_tors=Inf; translational floor/shear/singular checks still run) when plate_center present but any WallLine (x,y) is outside plate_center ± plan_halfwidth (tol=1e-9+1e-9*hypot(hx,hy), on-boundary accepted). solve_wall_layout refuses with DISTINCT status=:geometry_inconsistent (vs :geometry_required for an absent plate). Checks WALLS not the CR (CR may legitimately sit outside the plate — rev6 torsionally-soft case still certifies on drift). Catches the walls-OUTSIDE / frame-mismatch class.
(2) SKELETON-DERIVED GEOMETRY HELPER (new StructuralSynthesizer/src/walls_bridge.jl): story_plate_geometry(skeleton, story; walls=nothing) derives plate_center + plan_halfwidth as the bbox of the real per-story floor polygon (reuses _chat_geo_envelope logic); story_center_of_mass(skeleton, story, cells) = mass-weighted (shoelace area-centroid) using effective_seismic_weight = (self_weight+sdl)*area — dead-load core, live EXCLUDED, GROUNDED in ASCE 7-22 §12.7.2 (corpus asce-7-22, PDF p.184/printed 123). This makes plate = TRUE occupant footprint by construction, closing crit7 at its source (a caller can no longer pass the wall-group box). Exported assert_walls_enclosed(plate_center, plan_halfwidth, walls) throws (fail closed) when a wall center is outside the derived plate — discharges the checkable crit7 obligation at construction.

KEY ARCHITECTURAL FINDING (crit3, verified in source): the walls' plan coords come from Wall.x1..y2 via wall_center (members.jl:530), NOT from vertex_coords; the helper reads vertex_coords. These are DIFFERENT sources with no production wiring between them. The original helper docstring falsely claimed 'frame-consistent by construction'; corrected to state the real invariant + VERIFY it via the enclosure assertion. IMPLICATION FOR PHASE 3/6 BRIDGE: it MUST populate Wall.x1..y2 from the same vertex_coords datum; the assertion will catch it if it doesn't.

VERIFICATION: StructuralSizer walls 428/428 (guard: crit7 (1)-(8)); StructuralSynthesizer walls_bridge 44/44. Reviewers + critics (2 fix cycles) PASS. crit7 literal reproducer hw=(3,9) is NOT caught by the guard — it is the walls⊆plate⊂occupants residual (walls on the plate boundary), closed by the helper, not the guard.
