---
id: deci-01b4dd14
type: decision
project: menegroth
parent_id: plan-7f7bfe8c
title: Column keeps the larger region; the wall gets the complement, with exact quadratic
  fixed-end forces
node_label: Curved wall tributary
tags: slabs,walls,tributary,parabola,fixed-end
status: active
open_threads: 0
success: 'null'
files: StructuralSynthesizer/src/analyze/members/members/support_regions.jl@f69cf7c,
  StructuralSynthesizer/src/analyze/members/members/column_tributaries.jl@f69cf7c,
  StructuralSynthesizer/src/analyze/members/utils.jl@f69cf7c, StructuralSynthesizer/src/building_types/members.jl@f69cf7c,
  StructuralSynthesizer/src/StructuralSynthesizer.jl@f69cf7c, StructuralSynthesizer/test/analyze/test_support_regions.jl@f69cf7c,
  StructuralSynthesizer/test/runtests.jl@f69cf7c, external/Asap/src/Loads/fixed_end_forces.jl@f69cf7c,
  external/Asap/src/Asap.jl@f69cf7c, external/Asap/test/loads/test_quadratic_fem.jl@f69cf7c,
  external/Asap/test/runtests.jl@f69cf7c
session_id: sess-d449819c
created_at: '2026-11-05T02:56:57.993344+00:00'
updated_at: '2026-11-05T02:56:57.993344+00:00'
has_child_rationale: The straight-skeleton wall polygon under-assigned the wall. The
  column keeps the larger region and the wall gets the exact complement, including
  the parabola when that region is larger.
invalidates: deci-cd0e9ce7
---
Implemented the combined column/wall tributary split and exact quadratic fixed-end forces.

Per convex cell (`split_cell_supports`):
- No wall: Voronoi of the real column points only, so a corner with no column no longer drops its area.
- With walls that cover a full cell edge: each column keeps the larger of (1) its Voronoi cell among every cell corner and (2) the region closer to it than to any other column or wall line. The second boundary is the parabola v = ((u-u_c)^2 + h^2)/(2h). The wall's share is the complement, so the areas add up to the cell. A wall shorter than the edge is not a line support (ACI 318-11 R13.1).

On an 8 m square with a wall on one side: two far columns each keep 16 m² and the wall gets the straight 4 m strip (32 m²). One column at a far corner keeps the parabola, 64/3 m², and the wall width is u^2/16 + 4 (128/3 m²).

`compute_column_tributaries!` stores column areas as before and writes `wall.tributary_cell_areas` plus `wall.tributary_widths` (`WallWidthPiece`). `wall_edge_nodal_forces` integrates that width onto stations with linear shape functions.

Asap `fem_quadratic_segment` / `_fem_quadratic_segment!` integrate w = w0 + w1 τ + w2 τ² with three-point Gauss–Legendre, exact through degree 5. A zero quadratic term matches the existing linear fixed-end forces.

Punching keeps using the column area, which this rule never sets below the corner-Voronoi area.

Tests: Asap `test_quadratic_fem.jl` (18) and StructuralSynthesizer `test_support_regions.jl` (35).
