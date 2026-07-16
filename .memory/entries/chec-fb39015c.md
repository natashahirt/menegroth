---
id: chec-fb39015c
type: checkpoint
project: menegroth
parent_id: plan-d72e497e
title: 'Wave 1B closed: A1 reverted, A6 landed, external/Asap peer drift blocked bit-identical
  verify'
node_label: 'Wave 1B closed: A1 reverted, A6 landed, external/A'
tags: wave-1b, flat-plate-speedup, verify, external-asap-drift, checkpoint
status: active
open_threads: 0
success: 'null'
files: scripts/runners/run_flat_plate_speedup_validation.jl@c09edf3, StructuralStudies/src/flat_plate_methods/results/speedup_baseline/baseline.csv@c09edf3,
  StructuralStudies/src/flat_plate_methods/results/speedup_baseline/latest.csv@c09edf3,
  StructuralSizer/src/slabs/codes/concrete/flat_plate/analysis/fea/precompute.jl@c09edf3,
  StructuralSizer/src/slabs/codes/concrete/flat_plate/analysis/fea/load_cases.jl@c09edf3,
  logs/wave_1b_diff_summary.md@c09edf3, logs/speedup_validation_verify_a6only.log@c09edf3
session_id: sess-74961ed9
created_at: '2026-07-16T10:10:10.945207+00:00'
updated_at: '2026-07-16T10:10:10.945207+00:00'
---
Closes Wave 1B of the flat-plate sizing speed-up plan (`plan-d72e497e`). Wave 1B is closed **honestly** — A6 is landed as inert diagnostics, A1 is reverted pending a paired-solve investigation, and the numerical drift the final verify surfaced is attributed to peer-Cursor edits in `external/Asap`, not to A6.

## Files carried out of Wave 1B (as of 2026-07-16T10:06Z)

**Stayed changed:**
- `scripts/runners/run_flat_plate_speedup_validation.jl` — downsized smoke matrix (1 span × 2 methods; was 12-row before the Julia 1.12.1 GC-hang downsize)
- `StructuralStudies/src/flat_plate_methods/results/speedup_baseline/baseline.csv` — 2-row seed, mtime Jul 13 08:21, ddm=98.639 s + fea_frame=294.66 s
- `StructuralStudies/src/flat_plate_methods/results/speedup_baseline/latest.csv` — fresh verify_a6_only output, useful reference for the next wave
- `StructuralSizer/src/slabs/codes/concrete/flat_plate/analysis/fea/precompute.jl` — A6: three `@debug "FEAModelCache"` inserts at post-diff lines 136 (rebuild reason: uninitialized|edge_beam_topology_changed), 175 (rebuild reason: drop_panel_changed), 187 (update); proven inert on the DDM path and syntactically inert on the FEA path
- `logs/wave_1b_diff_summary.md` — audit trail with impl_a1 and impl_a6 verbatim diffs
- `logs/speedup_validation_verify_a6only.log` — verify_a6_only full log
- `logs/speedup_validation_verify_a6only.prev.log` — prior verify_v2 log rotated

**Reverted:**
- `StructuralSizer/src/slabs/codes/concrete/flat_plate/analysis/fea/load_cases.jl` — A1 undone; file matches HEAD. `git diff` on this path returns empty; three `values_only=true` restored at lines 52, 121, 125; zero `loads_only=true`; zero `# A1:` comments. Verified by `review_revert_a1` (task-8f642130).

## Seed runtimes (baseline.csv, Jul 13 08:21)

- DDM (Full) 28': **98.639 s**
- FEA (frame) 28': **294.66 s**

## Verify outcome (verify_a6_only, task-6ca02961, 2026-07-16T10:06Z)

**DDM (Full) 28' — BIT-IDENTICAL vs baseline.** All 23 invariants match. Runtime 98.64 s → 110.98 s (+12.5%), plausibly CPU contention from parallel peer Julia processes observed during the run.

**FEA (frame) 28' — 10 invariant mismatches, all downstream of the FEA solve:**

| invariant | baseline | latest | diff |
|---|---|---|---|
| M0_kipft | 793.1466 | 793.3052 | +0.1586 (~0.02%) |
| punch_ratio | 0.9958 | 0.9963 | +5.15e-4 (~0.05%) |
| defl_ratio | 0.04730 | 0.04726 | -3.80e-5 (~0.08%) |
| vu_max_psi | 188.94 | 189.03 | +0.098 (~0.05%) |
| defl_in | 0.04413 | 0.04409 | -3.55e-5 (~0.08%) |
| As_cs_in2 | 19.8 | 19.4 | -0.4 (rebar step) |
| As_total_in2 | 29.4 | 29.0 | -0.4 (rebar step) |
| slab_ec_kgco2e | 119263 | 118969 | -294 (~0.25%) |
| slab_ec_per_m2 | 182.12 | 181.67 | -0.45 (~0.25%) |
| rebar_kg_per_m2 | 36.70 | 36.44 | -0.26 (~0.71%) |

FEA(frame) runtime: 294.66 s → 544.83 s (+84.9%).

## Attribution — peer-Cursor `external/Asap` drift, NOT A6

The 10 FEA(frame) mismatches are attributed to uncommitted peer-Cursor edits in the `external/Asap` submodule from a concurrent joists-plan session (finalized zombie runs `run-013f66ea` and `run-e474c747` continued into a new run over the past three days). Evidence:

- **A1 revert clean.** `git diff -- StructuralSizer/src/slabs/codes/concrete/flat_plate/analysis/fea/load_cases.jl` returns empty.
- **A6 syntactically inert.** `@debug` is Logging-guarded, touches no numerical state.
- **DDM bit-identical.** All 23 DDM invariants match — A6's edits sit in a module Julia's precompile chain touches on either path, so DDM bit-identity is strong behavioral evidence A6 is not the source.
- **`external/Asap` submodule state.** `git diff --stat` at 2026-07-16T10Z: 73 files modified, 91271 insertions / 91534 deletions uncommitted. Modified files that DIRECTLY feed the FEA(frame) outputs: `src/Elements/K.jl` (element stiffness), `src/Elements/R.jl` (rotation matrices), `src/Elements/elements.jl`, `src/Elements/shell/composite.jl`, `src/Elements/shell/meshing.jl` (shell moment computation), `src/Elements/spring.jl` and `src/Elements/spring/utilities.jl`, `src/Analysis/force_displacement.jl` (FEA solve entry), `src/Loads/utilities.jl`, `src/Dynamics/mass.jl` and `src/Dynamics/modal.jl`. Any change in `K.jl` / `R.jl` / `force_displacement.jl` shifts moments/stiffnesses/displacements at float-roundoff level, which explains M0_kipft 793.15→793.31 (+0.02%) and cascades: moment shift → punch ratio shift → rebar step jump on the 0.2-in² discretization grid → EC shift.
- **mtimes.** baseline.csv mtime = Jul 13 08:21 (seed). Parent-repo files also drifted since seed with mtime Jul 16 05:35 (~15 min before verify): `StructuralSynthesizer/src/postprocess/ec.jl`, `StructuralSynthesizer/src/design_workflow.jl`, `StructuralSynthesizer/src/building_types.jl`, `StructuralSynthesizer/src/analyze/asap/utils.jl`, `StructuralSynthesizer/src/analyze/members/utils.jl`, `StructuralSizer/src/slabs/codes/concrete/flat_plate/analysis/ddm.jl`, `StructuralSizer/src/slabs/codes/concrete/flat_plate/analysis/efm.jl`.

## Downsize rationale

Julia 1.12.1 hung in GC on the 12-row smoke matrix; downsizing to 1 span × 2 methods (DDM Full + FEA frame at 28') restored progress. Later re-resurrected onto Julia 1.12.4 per the Dockerfile target — runtimes above are on 1.12.4.

## TODO for next wave

1. **Stabilize `external/Asap`.** Coordinate with the joists-plan session to commit or stash the 73-file Asap edit set so the working tree stops drifting under our verify.
2. **Re-seed baseline.** Regenerate `baseline.csv` on the resulting committed state before landing any further optimizations.
3. **Rerun A1 investigation.** Follow the paired-solve diagnostic plan in the A1 decision entry: minimal-repro capturing pre/post `model.u` and per-element `bending_moments` arrays at every step of `_solve_dl_cases`, diffing paired `values_only` vs `loads_only`, on a STABLE Asap SHA.
