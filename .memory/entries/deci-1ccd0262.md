---
id: deci-1ccd0262
type: decision
project: menegroth
parent_id: plan-d72e497e
title: 'A1 reverted: loads_only=true swap in _solve_load_case! kept for a future paired-solve
  investigation'
node_label: 'A1 reverted: loads_only=true swap in _solve_load_c'
tags: wave-1b, a1, loads_only, values_only, asap-update, deferred, decision
status: active
open_threads: 0
success: 'null'
files: StructuralSizer/src/slabs/codes/concrete/flat_plate/analysis/fea/load_cases.jl@c09edf3
session_id: sess-74961ed9
created_at: '2026-07-16T10:11:37.055416+00:00'
updated_at: '2026-07-16T10:11:37.055416+00:00'
---
A1 is the `values_only=true` → `loads_only=true` kwarg swap on the three `Asap.update!` call sites inside `_solve_load_case!` in `StructuralSizer/src/slabs/codes/concrete/flat_plate/analysis/fea/load_cases.jl` (lines 52, 121, 125 in the impl_a1 diff — the same three lines have been restored to `values_only=true` in the revert). All three sites live inside the D/L paired-solve path that dominates the FEA(frame) 28' runtime.

## Mechanism (why A1 is expected to work)

Each paired D/L solve calls `Asap.update!` twice on the same model — once with the dead-load load vector, once with the live-load load vector. With `values_only=true` the model rebuilds its element stiffness matrix `K` and refactorizes the global stiffness matrix on every update (the expensive step). With `loads_only=true` the model reuses the prior factorization and only re-populates the load vector before solving — which is the entire point of pairing D/L through one `Asap.Model`. Verify_v2 confirmed the mechanism works at the runtime level: A1 delivered a **-64%** runtime drop on FEA(frame) — exactly the pattern of a preserved factorization.

## Why it did not land in Wave 1B

- **verify_v2 numerics diverged** on 7 FEA(frame) invariants at the time.
- **On-paper Asap.update! reading did not surface a clean failure mode.** Reading `external/Asap/src/Model/analysis.jl` at HEAD, both branches (`values_only` and `loads_only`) zero `element.Q` and then call `populate_loads!(...)`, and `bending_moments!` reads from `element.Q` + nodal displacements, not from `element.K`. There is no obvious "stale Q" or "stale K" state that should have shifted moments at the ~0.02% level we observed.
- **verify_a6_only mixes A1 out of the signal.** In the a6-only re-verify (A1 reverted, A6 kept), the DDM path is bit-identical but the FEA(frame) path shows 10 invariant mismatches (M0_kipft 793.15 → 793.31, +0.02%). Those mismatches must be attributable to something OTHER than A1, since A1 is not present. This means some — possibly all — of verify_v2's 7 FEA-mismatches were **already-present peer-Cursor drift in `external/Asap`**, not A1. See the sibling decision "Baseline.csv is stale..." and the Wave 1B checkpoint for the peer-drift evidence.

**We cannot cleanly separate A1's effect from Asap-drift** using verify_v2 alone. That is the honest reason A1 is deferred, not withdrawn.

## Deferred, not killed — follow-up plan

Wave 2 investigation, ordered:

1. **Stabilize `external/Asap` first** (see sibling decision). No A1 work happens against an uncommitted 73-file Asap edit.
2. **Minimal-repro script under `scripts/runners/`.** Build one flat-plate 28' frame model, drive it through `_solve_dl_cases` with A1 disabled, snapshot `model.u` (nodal displacements) and per-element `bending_moments` arrays at every intermediate step (post-D solve, post-L solve). Repeat with A1 enabled. Diff the paired arrays element-by-element, load-case-by-load-case.
3. **Read the second `Asap.update!` call in the pair specifically.** The suspect is state carried across the first → second `update!` call (e.g. residual live-load contribution in `element.Q`, stale nodal displacement copies used by `bending_moments!`). This has to be shown from the minimal-repro paired arrays, not from `_solve_load_case!` alone.
4. **If A1 is proven correct on a stable Asap SHA**, re-land it. If a genuine state-leak is found, either fix `Asap.update!(loads_only=true)` upstream in `external/Asap` or add a scoped guard in `_solve_load_case!` before calling A1.

## Files

- `StructuralSizer/src/slabs/codes/concrete/flat_plate/analysis/fea/load_cases.jl` (three call sites, currently reverted to `values_only=true`)
