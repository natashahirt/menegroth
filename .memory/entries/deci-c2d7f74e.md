---
id: deci-c2d7f74e
type: decision
project: menegroth
parent_id: deci-f4db3f27
title: Edge transfer bands follow the moment, and the secondary moment uses the inner-layer
  depth
node_label: Transfer bands follow the moment
tags: flat-plate,moment-transfer,aci-318-11,13.5.3.2
status: active
open_threads: 1
success: 'null'
files: StructuralSizer/src/slabs/codes/concrete/flat_plate/utils/calculations/shear_studs.jl@6ccb6a0,
  StructuralSizer/src/slabs/codes/concrete/flat_plate/design/checks/punching.jl@6ccb6a0,
  StructuralSizer/src/slabs/codes/concrete/flat_plate/pipeline/transfer_reinforcement.jl@6ccb6a0,
  StructuralSizer/src/codes/aci/punching/standard_geometry.jl@6ccb6a0
session_id: sess-b0cc41a9
created_at: '2026-11-09T00:02:50.107875+00:00'
updated_at: '2026-11-09T00:15:45.408577+00:00'
has_child_rationale: The §13.5.3.3 fractions were landing on the wrong band, and the
  edge width dropped a side that has slab
---
Source: aci-318-11 §13.5.3.2 and R13.5.3, page 250. StructurePoint exterior column uses bb = c2 + 3h (sp-de-two-way-flat-plate-aci318-14, page 18).

Mux spans the named c1 and Muy the named c2. A free edge no longer swaps the column dimensions under those moments.

An edge moment spanning perpendicular to the edge has slab on both sides of its band (c_parallel + 3h). The moment spanning along the edge, and both moments at a corner, have one free side (c_transverse + 1.5h). Corner critical-section sides are c + d/2 in both directions.

§13.5.3.3 fractions are stored on the named axes. The secondary-span moment is sized and strain-checked at the inner-layer depth.

Left as it was: the count of added bars is still taken against the primary column strip, even when the governing moment is the secondary direction.
