---
id: expe-48ab4ba1
type: experiment
project: menegroth
parent_id: expe-c525754e
title: 'Drift as a linear MILP constraint: strength+drift in one certified solve,
  per-group optimal (uniform 5 passes -> mono 1, 10.4% lighter)'
node_label: 'Drift as a linear MILP constraint: strength+drift '
tags: ''
status: active
open_threads: 0
success: 'true'
files: StructuralSizer/src/optimize/solvers/discrete/coupling.jl@eccc135, StructuralSizer/src/optimize/solvers/discrete/model.jl@eccc135,
  StructuralSizer/src/StructuralSizer.jl@eccc135, StructuralSizer/test/optimize/test_capacity_coupling.jl@eccc135,
  scripts/runners/drift_wall_proving_slice.jl@eccc135
session_id: sess-100e9123
created_at: '2026-11-25T12:41:52.118945+00:00'
updated_at: '2026-11-25T12:41:52.118945+00:00'
---
Slice 1 of 3 (user asked to do all three monolithic-coupling opportunities in sequence, well-tested). Generalizes the self-weight coupling to DRIFT.

Key idea: for a lateral system under a fixed force distribution the drift is separable, δ = Σ_e γ_e/I_e with γ_e = c_e·s_e (virtual-work participation, frozen within a step; EXACT for a statically determinate cantilever since forces are stiffness-independent). So each catalog section t contributes a precomputable constant γ_e/I_t to the drift, and the serviceability limit δ ≤ δ_allow is LINEAR in the selection binaries: Σ_e Σ_t (γ_e/I_t)·x[e,t] ≤ δ_allow. The t³ stiffness nonlinearity is absorbed into the per-candidate coefficient; only linearity in the BINARY is needed. One certified MILP then sizes every group for strength AND drift jointly, per-group optimal (material where participation-per-weight is highest) — replacing the uniform grow-only drift jump loop (README §4 rank 6) and, in production, the walls⇄members re-run (README §5 #2, the single most expensive loop).

Implementation (StructuralSizer, generic/material-agnostic):
- New LinearSelectionConstraint struct (coeff[i][s] over groups×catalog, sense :leq/:geq, rhs) + _validate_linear_constraints + _add_linear_selection_constraints! in optimize/solvers/discrete/coupling.jl. A general linear inequality over the selection binaries; generalizes the budget ε-constraint (which is coeff[i][s]=objective_coeff(s)·length[i]).
- optimize_discrete gains `linear_constraints::Union{Nothing,Vector{LinearSelectionConstraint}}` (flag-off byte-identical; memo-gated; infeasible-graceful empty return extended to include it, since an unreachable drift limit should return empty not crash). Allowed WITH n_max_sections. Exported LinearSelectionConstraint.

Proving slice scripts/runners/drift_wall_proving_slice.jl: 20-segment determinate cantilever (drift exact), γ by Simpson quadrature of M·m. UNIFORM policy (scale every group's stiffness demand by worst drift ratio, snap up) vs MONO (optimize_discrete with the drift LinearSelectionConstraint). Result: strength-only drift 20× over; uniform 5 grow passes → 8.625 m³; MONO 1 solve → 7.728 m³ (10.4% lighter), drift exactly met. Honest caveat in the runner: W sections are a wall proxy so H/400 is unreachable; δ_allow set in the reachable+governing band. Indeterminate frames need one outer correction (drift governor trust region) to refreeze γ.

Tests: test_capacity_coupling.jl extended to 38 (was 17): flag-off byte-identical, single-group picks lightest stiff-enough (exact optimality vs brute force), per-group allocation beats uniform, :geq sense + n_max + infeasible-empty, validation. Full file green (38/38).

Env note: a corrupt Gurobi_jll artifact (df29ce14, dylib was 'data' not Mach-O, rewritten 07:22) made every fresh julia process fail at load (codesign --remove-signature in Gurobi_jll __init__; the try/catch import in cache.jl can't catch a dependency __init__). Fixed by rm -rf of the artifact dir + Pkg.instantiate re-download. Unit tests were unaffected (persistent test server had Gurobi loaded pre-corruption).

Next: slice 2 (productionize self-weight coupling into the real member stage), slice 3 (joint slab-h × column MILP for flat plates).
