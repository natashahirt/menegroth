---
id: chec-da55b4a8
type: checkpoint
project: menegroth
parent_id: deci-39472d5e
title: Walls report supplies plate_center; a skeleton with no geometry cache meshes
  the stated wall line
node_label: Plate center and empty geometry cache
tags: walls,plate-center,phase-5c,mesh,testing
status: active
open_threads: 0
success: 'null'
files: StructuralSynthesizer/src/analyze/asap/asap/wall_mesh.jl@29d055c, scripts/runners/verify_wall_shell_assembly_phase5c.jl@29d055c,
  StructuralSynthesizer/test/report_generators/test_walls_report.jl@29d055c
session_id: sess-7227de06
created_at: '2026-11-04T19:41:27.964372+00:00'
updated_at: '2026-11-04T19:41:27.964372+00:00'
has_child_rationale: S2 and S4 failed closed without a plate center, and the Phase
  5c rerun crashed before it could compare.
---
## Walls report S2 and S4
The symmetric core is centered on the origin, but the report built `ReducedDiaphragmEvaluator` without `plate_center`. The reduced tier then cannot locate the corners: torsion is `Inf` and the layout solver drives drift and torsion utilization to 1e6. The report now passes `plate_center=(0.0, 0.0)` on the direct-shear check, the accidental-eccentricity check, the S3 drift oracle, and the S4 layout problem. Wall centroids sit on the plate edge and the 4 m bodies stay inside it.

Report result: every stage passes. S2 torsion is exactly 1.0. S4 drift and torsion utilizations are both 1.000 and the layout is feasible. Carbon falls from 6998 kgCO2e (all walls dense) to 1842 (26%).

## Phase 5c rerun
The centered penalty-shell comparison is unaffected by the story-force fix (load at (0, 0), master at the centroid). The first rerun never compared: `_structural_pier_corners` read `skeleton.geometry.vertex_coords` on a fixture whose geometry cache is `nothing`. A missing cache now returns no pier corners, so the stated wall line is meshed, which is the documented path for a wall that is not on architectural vertices.

The runner also used the production mesh default, now `WALL_MESH_DIV` × `WALL_MESH_ROWS` (8 × 8). Tier A is `mesh_div` columns and one row. The runner passes `mesh_div=2, mesh_rows=1`.

Result: AGREE. Relative difference is 0 on both story drifts and all four base-wall shears. Upper-story shears stay withheld. The X-walls are 489.3 kN and 490.2 kN on both tiers: every panel runs the same direction, so the triangle diagonals twist the floor slightly.
