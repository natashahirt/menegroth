---
id: chec-0a276e4e
type: checkpoint
project: menegroth
parent_id: plan-00ace284
title: Column sizing cleanups done before v7
node_label: Column cleanups done
tags: columns,flat-plate,biaxial,fea,aci-318-11
status: active
open_threads: 0
success: 'null'
files: StructuralSizer/src/slabs/codes/concrete/flat_plate/analysis/fea/forces.jl@bf55cd7,
  StructuralSizer/src/slabs/codes/concrete/flat_plate/analysis/fea/run.jl@bf55cd7,
  StructuralSizer/src/slabs/codes/concrete/flat_plate/pipeline/iteration.jl@d01eb68,
  StructuralSizer/src/slabs/codes/concrete/flat_plate/pipeline/column_updates.jl@bf55cd7,
  StructuralSizer/src/members/codes/aci/columns/pm_rect/reinforcement_design.jl@bf55cd7,
  StructuralSizer/src/slabs/codes/concrete/flat_plate/utils/helpers.jl@bf55cd7
session_id: sess-6e64c23b
created_at: '2026-11-08T23:36:42.501304+00:00'
updated_at: '2026-11-08T23:36:42.501304+00:00'
has_child_rationale: User asked for the four column-sizing fixes before designing
  v7
---
The four column-sizing cleanups are in, before any v7 design.

1. An enlarged rectangular column is re-barred for both moments. `resize_column_with_reinforcement` takes `Muy` and `design_column_reinforcement` accepts the section only when `check_biaxial_auto` passes both axis assignments. `Muy = 0` stays on the uniaxial diagram. A circular section uses the resultant `hypot(Mu, Muy)`.
2. FEA column design uses the moment in the stub below the slab (`column_design_moments` / `Mub_below`). `unbalanced_moments` is still the sum of both stubs, and punching and `build_column_results` still use that joint moment. Pattern loading scales the below-stub moment by the same ratio as the joint moment.
3. The stiffness split is cited as ACI 318-11 §13.6.9.2 (Eq. 13-7, aci-318-11 page 258). §13.5.3.2 is the slab width, not the split. Applying the factor to an edge column's §13.6.3.6 0.3 M0 transfer is labeled ENGINEERING JUDGMENT (page 255; the clause is interior supports only).
4. DDM and EFM recompute the stiffness share at each moment assignment, after columns may have grown. FEA does not multiply by that factor.

`column_span_minimum` stays default false. v6 was not re-run. Next design is v7.

Tests: StructuralSizer concrete_column/test_biaxial.jl 68/68; slabs/test_column_growth.jl + slabs/test_flat_plate.jl 253/253; slabs/test_thickness_jump.jl passed in the earlier combined run.
