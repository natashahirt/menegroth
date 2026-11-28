---
id: deci-62b6c6aa
type: decision
project: menegroth
parent_id: plan-c8115994
title: Slab thickness jumps from one analysis
node_label: Thickness jump
tags: slab, thickness, flat-plate, efficiency
status: active
open_threads: 0
success: 'null'
files: StructuralSizer/src/slabs/codes/concrete/flat_plate/pipeline/thickness_jump.jl@ab16142,
  StructuralSizer/src/slabs/codes/concrete/flat_plate/pipeline/pipeline.jl@ab16142,
  StructuralSizer/src/slabs/codes/concrete/flat_plate/pipeline/iteration.jl@ab16142
session_id: sess-148c5d00
created_at: '2026-11-06T23:30:43.665034+00:00'
updated_at: '2026-11-06T23:30:43.665034+00:00'
has_child_rationale: The user asked to stop walking the slab thickness by half an
  inch and to jump from one analysis before diaphragm design.
---
The flat-plate sizer still starts at ACI 318-11 Table 9.5(c) (ln/33 interior, ln/30 at a discontinuous edge, never below 5 in; a fire rating can raise it) and still rounds thickness to the existing half-inch grid.

After column sizes are stable, a failed deflection, one-way shear, flexure, or transfer check no longer adds one half-inch and re-solves. One analysis at the failing thickness is scaled to each thicker half-inch up to ln/10. Superimposed dead load is qD minus the self-weight at the analyzed thickness. The governing uniform pressure is max(1.2D+1.6L, 1.4D). Moments and shears scale with qu(h)/qu(h0). Gross elastic panel deflection scales with that pressure ratio and (h0/h)^3, which is the same split the user asked for: superimposed deflection goes as 1/h^3 and self-weight deflection as 1/h^2 when both pressures are uniform. The existing check functions then run at the candidate depth, so cracking (Ie) is recomputed there. The loop re-runs the real analysis once at the thinnest half-inch the proxy accepts.

Pattern loading, a drop panel, a negative implied superimposed load, and an edge-beam βt that is recomputed from thickness do not scale; those cases keep the one-increment step. A column-size change still re-analyzes before any jump. Punching still tries column growth and reinforcement first. Only the last-resort thickening jump uses the same scaled demands, and that jump also has to pass the depth checks so Phase A is not walked afterward.

The confirm can still fail where column stiffness changes the moment distribution (EFM, and FEA with column stubs). A failed confirm jumps again from the new analysis. The proxy does not rerun the lateral analysis.
