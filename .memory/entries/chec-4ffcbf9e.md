---
id: chec-4ffcbf9e
type: checkpoint
project: menegroth
parent_id: plan-6be479fb
title: 'Stage profiler answers open Q1; Idea A (single-section memo) landed bit-identical;
  #7 identified as top exact target (needs sign-off)'
node_label: Stage profiler answers open Q1; Idea A (single-sec
tags: ''
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-53dd9cbd
created_at: '2026-11-21T00:14:56.811175+00:00'
updated_at: '2026-11-21T00:14:56.811175+00:00'
---
PROFILER (scripts/runners/profile_design_building_stages.jl, SizingProbe, core office; busy machine so read RELATIVE split): pipeline splits as ordinary_walls 709s (28 bldg full-factorizations + 60 rhs), members 594s (16 bldg fac + 6 slab remeshes + 10 slab refac), slab_sizing_s1 374s, foundations 70s. 44 of 48 total building factorizations are in walls+members. Under the rigid diaphragm every building solve refactors from scratch (rigidlink.jl solve!/solve null the factor), so those 44 fresh factorizations are the single largest recoverable cost => #7 (rigid-link factorization cache) is the top EXACT target. Slab remeshes in-stage are the #4/#1 case. #10's P-M/catalog compute is not a factorization so it's invisible to this probe (it's inside the members 594s).

#7 OBSTACLE (why not done autonomously): the mutating solve!(model,links) can cache the reduced symbolic factor on `model` (numeric-only cholesky! on value change, same proven-exact pattern as slab FEA factorization_cache.jl). But the multi-case solve(model,cases,links) is NON-MUTATING BY CONTRACT (does not write model._factorization), so its cache has no clean home — needs a passed-in handle or contract change. Core safety-critical analysis path => left for user sign-off per code-accuracy.mdc.

IDEA A LANDED (exact): _memo_section_cache memoizes the single-section P-M cache _rc_section_check rebuilt per column per settle round; same cache_matches+identity guards. core/test_flat_plate_member_stage.jl 299/299 bit-identical (1490s).

BRAINSTORM backlog (new): N3 batch all column grows per round into ONE building re-solve instead of _resolve_after_column_change! per change (orchestration, needs convergence-equivalence proof); N6 look up installed section in the memoized full-catalog cache instead of a 1-section build (refines Idea A); N7 unify the member-stage SY memo with the slab stage's StructuralSizer _precompute_flat_plate_col_cache so the whole run shares one P-M catalog cache; N5 content-address the slab FEA mesh/factor across the 4 identical typical floors (#4).
