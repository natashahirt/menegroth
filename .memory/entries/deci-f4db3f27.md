---
id: deci-f4db3f27
type: decision
project: menegroth
parent_id: plan-2d4158d0
title: Flat plates raise γf by ACI 318-11 §13.5.3.3 (a) and (b) at the column face,
  on by default
node_label: §13.5.3.3 γf increase
tags: flat-plate,punching,moment-transfer,aci-318-11,13.5.3.3
status: active
open_threads: 1
success: 'null'
files: StructuralSizer/src/codes/aci/punching/moment_transfer.jl@d01eb68, StructuralSizer/src/slabs/codes/concrete/flat_plate/design/checks/punching.jl@d01eb68,
  StructuralSizer/src/slabs/codes/concrete/flat_plate/pipeline/transfer_reinforcement.jl@d01eb68,
  StructuralSizer/src/slabs/codes/concrete/flat_plate/utils/calculations/shear_studs.jl@d01eb68,
  StructuralSizer/src/slabs/codes/concrete/flat_plate/pipeline/iteration.jl@d01eb68,
  StructuralSizer/src/slabs/options.jl@d01eb68, StructuralSizer/test/slabs/test_moment_transfer_13_5_3_3.jl@d01eb68,
  scripts/runners/compare_moment_transfer_13_5_3_3.jl@d01eb68
session_id: sess-7818df49
created_at: '2026-11-08T23:32:57.351704+00:00'
updated_at: '2026-11-09T00:02:50.107875+00:00'
has_child_rationale: 'First step of the slab-ratchet plan: corner punching drove column
  growth toward the cap'
---
Source: aci-318-11 §13.5.3.3, page 250.

User decisions:
- Both (a) and (b). Corner columns: both plan axes count as parallel to an edge, with the 0.5φVc limit.
- On by default: `FlatPlateOptions.moment_transfer_increase = true`.
- Edge column under (a): the moment about the axis parallel to the edge gets γv = 0. The other moment is checked on the 3-sided section about its symmetry axis (`polar_moment_Jc_edge_perpendicular`, c = b2/2, no Vu·e shift), with (b) or Eq. (13-1).
- (b) strain: gated on the required band steel during punching, then re-checked in the final design on the placed band steel (column-strip share plus every added bar). A failure reports the column inadequate (`gamma_f_increase_strain`), which asks for more depth.

Implementation choices:
- Vc for the 0.75/0.5/0.4 gates is the same vc as the punching check (includes the ACI 318-19 λs ≤ 1), never above the §11.11.2.1 value.
- The increase is permitted, so it is taken only when the band can develop γf·|Mu| tension-controlled; otherwise Eq. (13-1). The alternative stress is used only when it is lower than the Eq. (13-1) stress.
- The punching result carries `moment_transfer = (γf_x, γf_y, provision_x, provision_y)`; `governing_transfer_reinforcement` takes `γf_x`/`γf_y` so the band steel is the complement of the γv used.
- Edge: which moment is parallel comes from `boundary_edge_dirs` and the slab span axis; no edge direction or a skew edge keeps Eq. (13-1).
- Not applied: drop panels (column-face check at drop depth vs transfer at slab depth), openings, circular columns, skew/re-entrant corners, rule-of-thumb path (no secondary rebar design), outer stud section, caps and capitals.

Result, 3×3 DDM plate with 24 ft bays: h 9.61 in both ways; corners 20 in instead of 24 in; 2 iterations instead of 3. Interior and edge-perpendicular stay Eq. (13-1) because Vu > 0.4φVc.

Open: for an edge column with `free_edge_parallel = :c1`, `transfer_bands` (formerly inline in `governing_transfer_reinforcement`) pairs Mux with the c2-direction band, which looks swapped relative to the plan mapping. The punching gate uses the same bands, so the two agree, but the band assignment itself needs review.
