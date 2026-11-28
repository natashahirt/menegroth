---
id: chec-730ec1e0
type: checkpoint
project: menegroth
parent_id: plan-3b429631
title: 'WP 2.5 implemented: flat-plate column cache uses per-column ReinforcedConcreteMaterial
  + MinCarbon default — rebar now counts in column obj_coeffs; P-M capacity proven
  byte-identical; member-stage 299/299'
node_label: 'WP 2.5: rebar in column objective (capacity-safe)'
tags: WP2.5,columns,carbon,rebar,MinCarbon,flat-plate,capacity-equivalence
status: active
open_threads: 0
success: 'null'
files: StructuralSizer/src/optimize/core/options/concrete.jl@0381511, StructuralSynthesizer/src/workflow/flat_plate_column_check.jl@0381511,
  StructuralSynthesizer/src/workflow/column_oversize.jl@0381511, scripts/runners/equiv_column_rc_capacity.jl@0381511
session_id: sess-6292d70c
created_at: '2026-11-21T23:32:42.587669+00:00'
updated_at: '2026-11-21T23:32:42.587669+00:00'
has_child_rationale: 'Resolves expe-6dcbaa95: the column objective was rebar-blind,
  so shrink-to-min-area raised true carbon. WP 2.5 makes the objective count rebar.'
---
Implements WP 2.5 (rebar in RC column objective), the prerequisite flagged by expe-6dcbaa95.

## Root cause (recap)
Flat-plate column obj_coeffs came from `precompute_capacities!(..., material::Concrete, objective)` → the `::Concrete` overload passes `rebar=nothing`, so `objective_value` was rebar-blind (gross concrete only). Switching the objective alone does NOT fix it: with plain `Concrete`, `MinCarbon` still returns concrete-only carbon. Both are needed — an RC material (to supply `rebar`) AND `MinCarbon` (the metric). `_precompute_diagrams!` computes `obj_coeffs = objective_value(objective, section, concrete, 1m; rebar, transverse)`.

## Change
1. `flat_plate_column_check.jl`: new identity-stable `_column_cache_material(col, opts)` — memoised `ReinforcedConcreteMaterial(_column_concrete(col,opts), rebar, transverse)` keyed by (concrete,rebar,transverse) objectids (a fresh RC object per call would thrash the material-identity memo). Wired it at every column-cache site: `_grow`/`_stack`/`_fit`/`_rc_column_check` member check + the O4 oversize probe. Joint cache (`jchecker`) left on plain concrete (joint obj_coeffs are never read for selection).
2. `concrete.jl`: `ConcreteColumnOptions.objective` default `MinWeight()` → `MinCarbon()` (columns only; `ConcreteBeamOptions` left at MinWeight, out of scope).

## Capacity invariance — PROVEN (scripts/runners/equiv_column_rc_capacity.jl)
Diagrams depend on material only via the `mat` tuple fed to `generate_PM_diagram`; the objective never enters diagram generation. `to_material_tuple(concrete, checker.fy, checker.Es) == to_material_tuple(rc)` because the checker's fy/Es come from the same `rebar_material`. Harness result: material tuples identical, scalar/geometry cache fields equal, 1,702,675 is_feasible verdicts over all 403 catalog sections × a dense P-M grid → 0 mismatches; 403/403 obj_coeffs differ (the intended rebar-inclusive change). cache_matches already handles RC material (checker.jl:190).

## Effectiveness vs selection path
- `_grow`/`_stack` select via `order = sortperm(cache.obj_coeffs)` → now directly carbon-minimising across ALL sections (a bigger low-ρ column can beat a smaller high-ρ one — the intended trade-off).
- `_fit` uses plan-AREA-ordered groups (`_catalog_plan_groups` sorts by width·depth, obj only within-size/tiebreak) + a size-monotone binary search → still picks smallest passing plan area, but now the within-size rebar pick is lowest-carbon. So the cross-size area-minimisation in `_fit` is NOT yet carbon-driven (that is the SAO / Part-B lever, separate).

## Validation
- equiv_column_rc_capacity.jl: PASS (capacity byte-identical).
- core/test_flat_plate_member_stage.jl (--fresh, Revise cannot apply the @kwdef default change): 299/299 PASS in 24m53s — identical to baseline, no convergence regression. `_grow`/`_stack` only ever grow and `_grow` is failure-gated, so no grow/shrink oscillation.

## NEXT
Measure true carbon on medium_office (design A MinWeight+plain-concrete baseline vs B MinCarbon+RC) to quantify the benefit; expect columns ≤ baseline. Then revisit whether `_fit` cross-size selection should be carbon-ordered (Part B).
