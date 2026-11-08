---
id: plan-00ace284
type: plan
project: menegroth
parent_id: deci-1d3a040b
title: Flat-plate column sizing cleanups, after the straight-skeleton tributary refactor
node_label: Column sizing cleanups
tags: columns,flat-plate,biaxial,distribution-factor,aci-318-11
status: active
open_threads: 0
success: 'null'
files: StructuralSizer/src/slabs/codes/concrete/flat_plate/pipeline/column_updates.jl@a2f41ef,
  StructuralSizer/src/slabs/codes/concrete/flat_plate/pipeline/iteration.jl@a2f41ef,
  StructuralSizer/src/slabs/codes/concrete/flat_plate/utils/helpers.jl@a2f41ef, StructuralSizer/src/slabs/codes/concrete/flat_plate/analysis/fea/forces.jl@a2f41ef,
  StructuralSynthesizer/src/workflow/flat_plate_column_check.jl@a2f41ef, scripts/runners/core_office_column_stack.jl@a2f41ef
session_id: sess-ffbd8ef6
created_at: '2026-11-08T22:21:29.471081+00:00'
updated_at: '2026-11-08T22:21:29.471081+00:00'
has_child_rationale: Queued behind the tributary refactor at the user's request
---
Do after the straight-skeleton tributary refactor (deci-1d3a040b) is finished and v7 is designed.

Review finding (Nov 8): column sizing is safe and coherent overall. Roof columns get the whole joint moment (no column above), which is why the four v6 roof corners are 22x22-4#10 while every other column is 21x21-6#8. Punching correctly uses the full joint moment. The full-building check (`check_flat_plate_columns!`) uses frame Pu with all floors, both end moments, biaxial bending, and slenderness, and grows failures.

Tasks:
1. Biaxial reinforcement on resize. `_update_column_sizes!` calls `resize_column_with_reinforcement(section, c1, c2, Pu, Mu, material)` with the primary Mu only and single-floor Pu, so corner-column bars in the slab loop ignore Mu_secondary. The full check catches it, but the intermediate design is wrong. Redesign for both directions.
2. FEA: size each column from its own below-stub moment instead of total joint Mub x K_below/(K_below+K_above). Numerically the same (both stubs full story, far ends fixed, same I factor), but clearer and it removes the need for the split factor in the FEA path.
3. Citations: the Mu x DF comment in iteration.jl cites ACI 318-11 §13.5.3.2, which is the slab effective width for flexural transfer, not a column split. Applying the split to the §13.6.3.6 0.3 M0 edge transfer extends §13.6.9.2 (interior supports only, aci-318-11 p.258); label it ENGINEERING JUDGMENT.
4. Recompute `_dist_factors` when columns grow inside the slab loop (currently computed once before the loop).

Decision: keep `column_span_minimum` (span/15 floor, a rule of thumb not an ACI requirement) on for these designs.
