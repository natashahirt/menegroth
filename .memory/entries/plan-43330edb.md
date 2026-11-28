---
id: plan-43330edb
type: plan
project: menegroth
parent_id: plan-a79eb74f
title: 'One column owner: one selector, one round, neighbors only add checks'
node_label: 'One column owner: one selector, one round, neighbo'
tags: columns,sizing,architecture,owner,punching,trim
status: active
open_threads: 0
success: 'null'
files: docs/sizing-map/architecture.md@1e1fef5, StructuralSynthesizer/src/workflow/flat_plate_column_check.jl@c8c1f25,
  StructuralSynthesizer/src/workflow/member_iteration.jl@c8c1f25, StructuralSynthesizer/src/workflow/column_reconciliation.jl@44b043e,
  StructuralSynthesizer/src/workflow/pipeline_spec.jl@c8c1f25
session_id: sess-5a723707
created_at: '2026-11-25T01:54:42.493931+00:00'
updated_at: '2026-11-25T01:54:42.493931+00:00'
has_child_rationale: User confirmed the one-owner column design and asked to plan
  it and carry it out
---
Agreed column architecture, to be built under the sizing-architecture plan.

One column owner. Slabs, the shared-column envelope, and the wall recheck stop assigning the section. They add a demand, a check, or a floor.

One search. Frame P-M stays in `size_columns!`. Punching and the ACI 318 §10.12 joint join that choice through one selector, `select_column_section`, instead of a second catalog walk in `_fit_flat_plate_columns!`. The fit and the reconciler only install what the selector returns.

One round. Analyse, pick the lightest feasible section, and if the column and its neighbor start trading sizes, grow only. When the round stops, one trim: a free pick, then grow-only again, kept only when it converges lighter. The beam-column loop and the story shell already do this. Flat-plate settle and the wall rounds call the same round instead of a private grow-only loop.

Out of this cut: foundations (one shot from final reactions), special-wall shear ratios, and row F floors that record a section which already failed its own check. Frame groups that share a section stay on the discrete MIP.

Order: selector with no result change, install-only fit, flat-plate round uses the member trim, wall recheck submits a floor. Tests after each cut.
