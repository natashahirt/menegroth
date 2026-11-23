---
id: chec-6056dbcd
type: checkpoint
project: menegroth
parent_id: chec-7177d564
title: 'Drift governor: catalog-aware resize→snap→re-solve loop with background accounting'
node_label: drift governor
tags: drift,governor,catalog,snap,background,core,steel,rc,StructuralSizer,Asap
status: active
open_threads: 0
success: 'null'
files: StructuralSizer/src/optimize/drift_governor.jl@1644854, StructuralSizer/src/optimize/_optimize.jl@1644854,
  StructuralSizer/src/StructuralSizer.jl@1644854, StructuralSizer/test/optimize/test_drift_governor.jl@1644854,
  StructuralSizer/test/runtests.jl@1644854
session_id: sess-69780ed3
created_at: '2026-11-23T19:55:41.931146+00:00'
updated_at: '2026-11-23T19:55:41.931146+00:00'
has_child_rationale: The catalog-mapping outer loop that consumes the optimality resizer
  end to end
---
## What

`StructuralSizer/src/optimize/drift_governor.jl` — the outer loop that turns continuous optimality targets into real discrete sections on a live Asap model:

`resize_for_drift!(model, constraints; sized_elements, weight, floor_I, catalog, current_I, apply_I!, max_outer, tol, resize_kwargs) -> DriftGovernorResult`

Loop: `Asap.solve!` → measure actual drifts (early-exit if feasible) → build participation matrix C via `Asap.drift_participation` per constraint → subtract non-sized **background** → `drift_optimality_resize_multi` for continuous targets → **snap up** to lightest catalog section ≥ max(target, floor) → `apply_I!` + `Asap.update!` → repeat. Snapping up keeps the discrete structure on the safe side of the continuous optimum.

Constraint helpers: `DriftConstraint(dofs, coeffs, δ_allow)`, `total_drift_constraint(dof, δ)` (wind H/400 at roof), `interstory_drift_constraint(top, bottom, δ)` (ASCE 7 §12.12). `snap_up(target, catalog)` = lightest entry ≥ target (unsorted ok).

## Background accounting (the key design point for steel frame + concrete core)
Participation sums to the FULL drift, but we only resize frame members. The core (and any non-sized member) carries `background_j = δ_full_j − Σ_{sized} C[:,j]`, held fixed. The sized members are given the reduced budget `δ_eff_j = δ_allow_j − background_j`. If `δ_eff_j ≤ 0` the frame alone cannot meet the limit (core too soft) → status `:background_infeasible` — the signal to stiffen the core instead. This is what lets the same driver size a steel moment frame around a fixed RC core.

Model coupling is via `current_I`/`apply_I!` callbacks + a per-member `catalog`, so one driver serves steel W/HSS and RC columns; the real strength checks + lateral-system wiring stay with the caller.

## Verification — 16/16 green (optimize/test_drift_governor.jl)
- `snap_up`: lightest ≥ target, exact match, below-range → min, above-range → max, empty → ArgumentError.
- Continuous governor on a 4-story stick: every story limit met, sizes never below the strength floor.
- Discrete-catalog governor: converged, feasible, every delivered size is an actual catalog section.
- Background: constrain story-1 drift (base-element-governed) while sizing only the upper elements → `:background_infeasible`; include the base element → `:converged`. Proves the core/background subtraction and the infeasibility signal.

## Gotcha
Asap assigns `node.globalID` during `solve!`, not at `FrameModel` construction — read DOF indices only after solving (bit me in the fixture; fixed by solving inside the builder).

## Status of the two-part request (“one then the other”)
1. Multi-constraint resizer (chec-7177d564) ✅  2. Catalog-mapping driver ✅. Both in StructuralSizer, catalog-agnostic, fully unit+FE tested.

## Remaining (drift-prove, needs the big DualSystem behavior hooks e-steel-behavior)
Wire this governor into the actual DualSystem high-rise: real steel/RC section catalogs + strength floors from the member checkers, inter-story DOFs from the assembled lateral model, core as the background. Plus the deferred per-DOF I_y/I_z/A participation split (Asap K_e block decomposition) for directional X/Y drift.
