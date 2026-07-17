---
id: deci-07d12e0e
type: decision
project: menegroth
parent_id: plan-d72e497e
title: 'Wave 2 null result: combined A2/A3 gate on Phase B is tautological; reverted'
node_label: 'Wave 2 null result: combined A2/A3 gate on Phase B'
tags: wave-2, null-result, a2-a3-tautology, phase-b-control-flow, flat-plate-speedup,
  revert, decision
status: active
open_threads: 0
success: 'null'
files: StructuralSizer/src/slabs/codes/concrete/flat_plate/pipeline.jl@91f7e1d, StructuralStudies/src/flat_plate_methods/results/speedup_baseline/baseline.csv@91f7e1d
session_id: sess-37aa88cc
created_at: '2026-07-17T18:50:06.163475+00:00'
updated_at: '2026-07-17T18:50:06.163475+00:00'
---
Wave 2 attempted to land four flat-plate speed-up optimizations (A8, A2, A3, A5) but exited with ZERO landings.

SCOPE EVOLUTION:
1. explore ([task-da951d72](65831c5f-685d-4605-902f-a1382d92adbd)) discovered that (a) A5 is already implemented in current code (compute_column_axial_loads only recomputes on h-change per pipeline.jl:1030), (b) A8's plumbing (skip_applicability_check through build_pipeline → sizing.jl → size_flat_plate!) touches 4 files for O(ms) gain, (c) A2 and A3 collapse into a single gate on the iter-start size_columns pair at pipeline.jl:1387/:1409 because there is no second pair after _resolve_punching_failures!.
2. User approved reduction to combined A2+A3 only.
3. impl ([task-84220809](6805dfbe-8175-4ca0-a2f1-d9dcd541a794)) landed a clean 3-site guard: init `columns_grew_last_iter=false` before Phase B loop, `if iter_b == 1 || columns_grew_last_iter` around size_columns + _update_column_sizes!, propagate after _resolve.
4. review ([task-a519f3e3](0af3dddd-15ac-4870-828f-3d79c32fa3c8)) PASSed diff structurally.
5. critic ([task-22bcf992](ceb8f8a9-39fc-483e-a318-b9dc1620ed93)) returned CONCERN with a decisive tautology finding.

THE TAUTOLOGY (verified by independent control-flow trace):
Within a Phase B invocation, the only path from iter N to iter N+1 is the `continue` at pipeline.jl:1524, gated on `columns_grew == true`. Since `columns_grew_last_iter = columns_grew` is set at :1510 immediately BEFORE that branch, the flag is necessarily `true` at the top of every iter ≥ 2. The studs-alone case (columns_grew == false) breaks the loop at :1530 rather than continuing. The `iter_b == 1 || columns_grew_last_iter` guard is therefore always true — dead logic delivering zero speedup while being output-safe.

DEEPER LESSON:
The underlying premise ("Phase B has a size_columns redundancy when studs alone resolve punching") is FALSE given the current control flow. The studs-alone case exits the loop before any next iter could benefit; every columns-grew iter has a new geometry that legitimately needs a fresh size_columns. Fixing this would require restructuring the Phase B loop itself, not just adding a guard. This should NOT be pursued as a standalone optimization — it would need to be part of Wave B1 (merge Phase A + Phase B).

RESOLUTION:
Impl reverted via `git checkout StructuralSizer/src/slabs/codes/concrete/flat_plate/pipeline.jl`. pipeline.jl diff is now EMPTY. Verify ([task-eb3ec729]) submitted as null-result PASS (harness not executed — empty diff cannot shift invariants; running the 10-min smoke would trip its own ≥5% speedup criterion by design).

FRESH BASELINE PRESERVED:
Wave 2's rebaseline (task-ef265573, ran 10:29 min against the current working tree with peer-Cursor external/Asap edits still applied) is retained. baseline.csv now shows DDM(Full)=85.0s / FEA(frame)=262.4s (down from Wave 1B's 544s FEA, mostly external/Asap speedup + warm-cache). This IS the invariant floor for future waves.

FOLLOW-UP (recommended Wave 3):
D-series (column grouping D1–D5) is the big-ticket win in the original plan and does not depend on Phase B redundancy. A4 (symmetric secondary axis in DDM/EFM) is a real optimization with a solid mechanical basis that survived the current scoping. B1 (merge Phase A + Phase B) would need its own explore since Wave 2 revealed the Phase B loop structure is more coupled than assumed.
