---
id: plan-b10cde0c
type: plan
project: menegroth
parent_id: plan-2d4158d0
title: 'Next slice: analysis counters, a shared settle driver, wall jump without recursion,
  faster punching confirms, split warning wording'
node_label: Counters, driver, punching, warning
tags: iteration,analysis,wall-thickness,punching,fea,warning
status: active
open_threads: 6
success: 'null'
files: ''
session_id: sess-da5e6261
created_at: '2026-11-08T19:58:53.051075+00:00'
updated_at: '2026-11-09T12:45:22.718213+00:00'
has_child_rationale: Follow-on to the growth budgets checkpoint; user asked to plan
  these five items
---
Plan only. No files pinned.

Findings that shape it:
- Every punching confirm remeshes. Column growth changes `fea_mesh_key` (precompute.jl `_build_or_update_fea!`), so the FEA cache resets and rebuilds. The comment there makes that deliberate: the update path cannot move a column patch. Meshing was ~91% of FEA time in the earlier profile. Faster punching therefore means fewer confirms, not a cheaper confirm, unless Asap learns to move a patch (Asap owns meshing).
- The resolver already picks the smallest passing size against frozen Vu/Mub. The walk comes from demand rising as the column stiffens. In the 3x3 run, corners walked to 30 in, then the slab thickened.
- Wall recursion: `_maybe_confirm_wall_thickness!` calls `design_ordinary_walls!` with `_thickness_pass + 1`, from both the lateral body and `_design_gravity_walls!`. Analyses = cap + 1. The stage emits `:enter` every pass and `:exit` only on the last.
- Loops: `_iterate_beams_columns!` (5% demand change, `max_iterations`), `_size_with_story_shell!` (3 rounds, held test), P-delta runs once when delta_s > 1.5, flat plate phases (growth budgets).
- Direct `Asap.solve!` / `process!` calls bypass `update_analysis!`: fire coating (two sites), columns-only branch, P-delta, sync_asap!.

Order:
1. Counters. FEAModelCache counts rebuilds and updates; size_flat_plate! puts them on its exit trace event. `update_analysis!` takes `tc` and emits one event per change kind. Route the bypassing solves through it where the change kind is unambiguous. Record a one-off baseline (runner, not a test) for the wall-jump fixture, the honeycomb R=12 plate, and the 3x3 individual FEA plate.
2. Shared driver `settle!(step!; budget)` in StructuralSizer next to `monotone_budget`. `step!(iter)` returns whether anything changed, the failing check, and whether a size hit its limit. Returns status :converged / :stalled / :at_limit / :budget, iterations, failing check.
3. Wall jump on the driver: split the body into one analysis pass that returns (result, trials); the stage loops propose -> apply_wall_thickness! -> pass. Same cap, same analysis count, one enter/exit pair. Checks: test_wall_thickness_jump.jl, test_ordinary_wall_stage.jl (design_building, ~15 min) once at the end.
4. Beam/column loop and story-shell rounds on the driver, behavior identical (same 5% tolerance, same 3 rounds). Story-shell file ~15 min.
5. Faster punching, after counters show the confirm count. Secant demand from the last two confirms of each column picks the next trial; the FEA confirm and the §11.11.7.1 check still decide. If the predicted demand fails at max_column_size, go straight to the cap and the thickening step instead of walking. Compare 3x3 runtime and final sizes against the baseline.
6. Split warning: stop citing a failed §13.6.1.1 as making the §13.6.4-§13.6.6 fractions invalid. §13.7.7.5 (aci-318-11 page 262) permits those fractions on equivalent-frame moments when §13.6.1.6 is met. Candidate triggers: l2/l1 outside the table's 0.5-2.0 (the code clamps), a beam panel failing §13.6.1.6, non-rectangular panels. Wording and triggers need user sign-off (code-accuracy).

Open decisions for the user: the warning wording and triggers; whether the punching predictor may overshoot by one size increment or must spend one extra confirm to back off; whether one enter/exit pair per wall stage is acceptable for trace consumers.
