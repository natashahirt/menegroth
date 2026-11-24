---
id: expe-3638cbde
type: experiment
project: menegroth
parent_id: expe-cecbd296
title: 'Smarter continuation seed (DP-optimal part-count bucketing) + tight separable
  LB certificate: gap closes 69%->1.78%, 1.95x tighter than hull'
node_label: Smarter continuation seed (DP-optimal part-count b
tags: ''
status: active
open_threads: 0
success: 'null'
files: StructuralSizer/src/optimize/section_relaxation.jl@68edc0b, StructuralSizer/src/optimize/solvers/binary_search.jl@68edc0b,
  StructuralSizer/src/StructuralSizer.jl@68edc0b, StructuralSizer/test/optimize/test_coupled_warm_start.jl@68edc0b,
  scripts/runners/relaxation_partcount_pareto.jl@68edc0b
session_id: sess-477246cc
created_at: '2026-11-24T22:23:41.008265+00:00'
updated_at: '2026-11-24T22:23:41.008265+00:00'
---
Two additive pieces on the clean StructuralSizer optimize layer.

1. continuation_seed(section_idx, coeffs, lengths, n_max) in section_relaxation.jl (pure, exported): builds a strong feasible warm-start for the section-count-capped MIP from the separable per-group optimum. Orders groups by coeff, partitions the ascending chain into <=n_max contiguous buckets (each group adopts its bucket's largest section), minimizing seed weight Sum_bucket coeff[last]*Sum lengths via an O(n_max*n^2) DP with backpointers. This is the EXACT part-count optimum under the monotone-coverage assumption (larger section covers smaller demand); where that slips on a mixed-shape catalog it stays a pure hint (optimize_discrete re-screens and drops infeasible seeded indices), so correctness never depends on monotonicity.

2. separable_lower_bound(checker, demands, geometries, catalog, material; objective, cache) in binary_search.jl (exported): thin wrapper returning optimize_binary_search(...).objective_value = Sum_g (lightest feasible coeff)_g * L_g. Relaxing any coupling constraint (n_max cap, shared-section, inventory) leaves the separable problem, so this never exceeds the constrained optimum = a VALID, TIGHT, JuMP-free certified lower bound. Strictly tighter than the convex-hull envelope because it uses the actual lightest feasible catalog section per group.

Runner relaxation_partcount_pareto.jl upgraded: uses optimize_binary_search for both the certified LB and the DP seed source; reports per-k certified optimality_gap. 283-section W catalog, 16 groups: certified gap 69.17% (n_max=1) -> 1.78% (n_max=10); separable LB 2.1449 vs convex-hull 1.10276 m^3 (1.95x tighter); front monotone, every point above LB, every warm solve matches cold optimum. DP-seed aggregate speedup x1.2 (single-solve @elapsed noisy at ~400-1300ms; per-k swings x0.73..x1.99). Primary value: tight certified gap + principled DP seed + proven correctness.

Tests: 82/82 green in test/optimize/test_coupled_warm_start.jl (adds continuation_seed DP contract: cap respected, up-assign only, nmax>=distinct returns identity, DP beats naive equal split, unsorted-input ordering, real capped-MIP drive; and separable_lower_bound certificate: equals full optimum, bounds every capped solve, tighter than hull).
