---
id: deci-4f329ae6
type: decision
project: menegroth
parent_id: plan-d72e497e
title: Baseline.csv is stale relative to current working tree — regenerate as first
  step of next wave
node_label: 'Baseline.csv is stale relative to current working '
tags: wave-1b, baseline, external-asap, joists-plan-drift, action-item, decision
status: active
open_threads: 0
success: 'null'
files: StructuralStudies/src/flat_plate_methods/results/speedup_baseline/baseline.csv@da4cbaa
session_id: sess-74961ed9
created_at: '2026-07-16T10:13:17.797227+00:00'
updated_at: '2026-07-16T10:13:17.797227+00:00'
---
The seed `baseline.csv` (mtime Jul 13 08:21) captures a specific state of both `external/Asap` and the parent repo. Between the seed and verify_a6_only (2026-07-16T10:06Z), a concurrent joists-plan session drove a large uncommitted edit set through `external/Asap` and adjacent parent-repo files. Any verify against baseline.csv from now on is comparing apples to a moving target. Regenerate baseline as the first ordered step of the next wave.

## Working-tree drift at 2026-07-16T10Z

**`external/Asap` submodule:** `git diff --stat` inside `external/Asap` reports **73 files modified, 91271 insertions(+), 91534 deletions(-) uncommitted**. Not all 73 files affect FEA(frame) numerics equally, but this subset does directly:

- `src/Elements/K.jl` — element stiffness matrix assembly
- `src/Elements/R.jl` — element rotation matrices
- `src/Elements/elements.jl`
- `src/Elements/shell/composite.jl`
- `src/Elements/shell/meshing.jl` — shell moment computation
- `src/Elements/spring.jl`, `src/Elements/spring/utilities.jl`
- `src/Analysis/force_displacement.jl` — FEA solve entry point
- `src/Loads/utilities.jl`
- `src/Dynamics/mass.jl`, `src/Dynamics/modal.jl`

Any change in `K.jl` / `R.jl` / `force_displacement.jl` perturbs moments / stiffnesses / nodal displacements at float-roundoff level. That is exactly the shape of the observed M0_kipft baseline=793.1466 → latest=793.3052 shift (+0.02%), which then cascades through the design pipeline (punch ratio +0.05%, deflection ratio -0.08%, rebar step jump on 0.2-in² discretization grid, EC -0.25%, rebar_kg_per_m2 -0.71%).

**Parent repo drift since baseline** (files with mtime Jul 16 05:35, ~15 min before verify), all of which sit on paths the FEA(frame) design pipeline traverses:

- `StructuralSizer/src/slabs/codes/concrete/flat_plate/analysis/ddm.jl`
- `StructuralSizer/src/slabs/codes/concrete/flat_plate/analysis/efm.jl`
- `StructuralSynthesizer/src/postprocess/ec.jl`
- `StructuralSynthesizer/src/design_workflow.jl`
- `StructuralSynthesizer/src/building_types.jl`
- `StructuralSynthesizer/src/analyze/asap/utils.jl`
- `StructuralSynthesizer/src/analyze/members/utils.jl`
- plus `StructuralSynthesizer/src/building_types/{cells,framing,skeleton,structure}.jl`

**Cross-reference.** This is the joists / roles / materials plan tracked in the finalized zombie runs `run-013f66ea` and `run-e474c747`, continued in a new coordinator run over the past three days. Their work is legitimate; it is simply concurrent with ours.

## Why this blocks the flat-plate speed-up plan

Every Wave 2+ optimization needs a stable baseline to prove bit-identity against. With the current 73-file uncommitted Asap delta, a re-verify of ANY change (including a no-op) will fail on FEA(frame) invariants — that is exactly what verify_a6_only showed. Landing further optimizations against a moving baseline would silently rebrand joists-plan drift as "our optimization broke it," or worse, mask a real regression inside the noise.

## Next-wave action (ordered)

1. **Coordinate with the joists-plan session** to either commit or stash their 73-file Asap edit set (and the parent-repo edits). This is a comms step, not a code step — do not try to commit their work for them.
2. **Rebuild `external/Asap` on the resulting committed SHA** (`git submodule update --init --recursive` per `AGENTS.md`; verify submodule SHA advances cleanly).
3. **Re-run the seed** with `scripts/runners/run_flat_plate_speedup_validation.jl` on the downsized 1-span-x-2-methods matrix, DDM(Full)+FEA(frame) at 28', overwriting `StructuralStudies/src/flat_plate_methods/results/speedup_baseline/baseline.csv`.
4. **Diff old vs new baseline** for accounting so the joists-plan-attributable drift is documented on the plan record.
5. **Only then** rerun A1 investigation (see sibling decision on A1 revert) and A6 re-verify (must be bit-identical against the new baseline).

## Files

- `StructuralStudies/src/flat_plate_methods/results/speedup_baseline/baseline.csv` (the stale seed; slated for regeneration)
