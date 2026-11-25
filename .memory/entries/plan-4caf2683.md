---
id: plan-4caf2683
type: plan
project: menegroth
parent_id: plan-43330edb
title: 'Autonomous cut: trim after the flat-plate grow-only settle, wall floor through
  the owner'
node_label: Autonomous flat-plate trim and wall floor
tags: columns,sizing,flat-plate,trim,walls,autonomous
status: active
open_threads: 0
success: 'null'
files: StructuralSynthesizer/src/workflow/graph_builder.jl@0b32b33, StructuralSynthesizer/src/workflow/flat_plate_column_check.jl@0b32b33,
  StructuralSynthesizer/src/workflow/pipeline_spec.jl@c8c1f25, StructuralSynthesizer/src/core/snapshot.jl@0b32b33,
  StructuralSynthesizer/src/analyze/members/members/size_columns.jl@0b32b33
session_id: sess-5a723707
created_at: '2026-11-25T02:10:13.279671+00:00'
updated_at: '2026-11-25T02:10:13.279671+00:00'
has_child_rationale: User asked for a plan that can be written without further decisions
---
Execution plan for the rest of plan-43330edb. Decisions below are locked. Do not ask. Do not open a coordinator run. Do not commit.

## Already done
`_select_column_section` chooses the flat-plate section (full-load strength, ACI 318 §10.12 joint, punching, plan floor). `_fit_flat_plate_columns!` only installs it. Non-RC columns are skipped before the selector and are not marked unresolved. `check_flat_plate_columns!` is still the monotone re-solve. This cut must not change a check result.

## Gate
`core/test_flat_plate_member_stage.jl` must pass on the selector before the trim is written. A selector failure is fixed in place. Do not stack the trim on a red selector.

## Flat-plate round
The coupled settle in `_design_flat_plate_members!` stays grow-only. `_floor_columns_at_installed!` stays inside that loop. That pin is what stops the 12 in ↔ 10 in oscillation (deci-6444e799). Do not add free passes inside the loop.

The one free shrink remains the reconcile that already runs before the first pin.

Trim once, after that settle has converged, in `_trim_flat_plate_members!`. Do not trim inside `check_flat_plate_columns!`. Reconcile calls it, and a trim there would nest.

Trim steps:
1. Snapshot with `snapshot!(struc, :flat_plate_trim_kept)`. Also keep a local copy of each column `shape`, because `restore!` puts back `c1`, `c2`, and the section, not `shape`.
2. Remember beam, column, and slab counts.
3. Free pick: `check_flat_plate_columns!` with an empty floor dict. Do not harmonize on this call.
4. If every column plan size and section is unchanged, drop the snapshot and return the kept design.
5. Otherwise run only the existing grow-only settle, with floors starting pinned at the free-pick sizes. Do not run the opening reconcile again.
6. Keep the trim only when the settle converged, `unresolved` is empty, the column sizing objective (objective per length times length, same as `_members_objective`) is strictly smaller, and no slab thickness increased. A lighter column that thickened a slab is dropped. No combined objective is invented.
7. Otherwise `restore!` the snapshot (`geometry_is_centerline = params.geometry_is_centerline`), write the saved shapes back, reinstall column volumes and the frame section the way `_install_column_section!` does, then `refresh_flat_plate_analysis!`. `restore!` does not re-solve.
8. If beam, column, or slab counts changed, do not restore by index. Keep the trim only when step 6 would have kept it. Otherwise leave the trim state and use the stage's existing not-settled error if the settle did not converge.

The local floor dict is the only floor the free pick clears. Do not clear `frame_section_floors`.

Extract the `settle!` loop into `_settle_flat_plate_members!` so the opening design and the trim share it.

## Walls
`_floor_overstressed_frame_columns!` already does not assign the column section. Move the `frame_section_floors` write into `submit_column_section_floor!` next to the column owner. Same rule as now: write only when the catalog contains the section and the new section is strictly heavier than the stored floor. The floor stays for later rounds. It is not trimmed. A section that failed frame P–M stays a floor, same as a row F floor.

## Do not touch
Shared-slab envelope rules, story-shell columns, the no-beam column loop, foundations, special-wall shear ratios, row F meaning, the grouped MIP, joist reruns, shell-moment averaging.

## Tests
After the trim: `core/test_flat_plate_member_stage.jl` and `design_graph/test_design_graph_equivalence.jl`.
After the wall move: `analyze/test_frame_section_floors.jl`.
A test that locks the old one-step-heavy column may be updated only when its header says it locks that size and the new section still comes from the selector. Do not change an assertion that a section fails strength, the joint, or punching. If an assertion is ambiguous, stop and leave a note. Do not loosen a tolerance.

Runner: `SS_ENABLE_VISUALIZATION=false SS_SKIP_SOLVER_WARMUP=true julia scripts/runners/test_quiet.jl StructuralSynthesizer <file>`. Gurobi's `libgurobi130.dylib` must stay a writable Mach-O; Julia runs `codesign --remove-signature` on load.

## Done when
Selector tests passed before the trim. Trim is after the grow-only settle and uses the keep rule above. Wall recheck calls `submit_column_section_floor!`. The three test files above have been run. A checkpoint records the results. No commit.
