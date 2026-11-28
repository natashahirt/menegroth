---
id: expe-a8e1485d
type: experiment
project: menegroth
parent_id: chec-730ec1e0
title: 'WP 2.5 carbon A/B on medium_office: MinCarbon == MinWeight (columns 7623,
  total 53643 kgCO2e, Δ=0.0%) — change is capacity-safe & regression-free but carbon-neutral
  HERE; the lever is _fit''s plan-AREA cross-size selection, not the objective'
node_label: 'WP 2.5 A/B: MinCarbon==MinWeight on medium_office (Δ0%)'
tags: WP2.5,carbon,A/B,medium_office,MinCarbon,_fit,plan-area
status: active
open_threads: 0
success: 'true'
files: scripts/runners/wp25_carbon_ab.jl@535aa61
session_id: sess-6292d70c
created_at: '2026-11-22T00:01:00.973662+00:00'
updated_at: '2026-11-22T00:01:00.973662+00:00'
has_child_rationale: Measures what the MinCarbon objective buys on the benchmark now
  that obj_coeffs are rebar-inclusive.
---
Ran scripts/runners/wp25_carbon_ab.jl: design medium_office (3x3x3 flat plate) twice on post-WP-2.5 code, only the column objective differs (both use the rebar-inclusive RC cache). design_building ~267s each (waffle-run CPU contention).

Result (ec.jl, kgCO2e):
- A MinWeight: columns 7623, total 53643, all_checks_pass=true
- B MinCarbon: columns 7623, total 53643, all_checks_pass=true
- Delta = 0.0% (identical design)

Why identical: the final column sizing is governed by `_fit_flat_plate_columns!`, whose plan groups are ordered by plan AREA (`_catalog_plan_groups` sorts by width*depth; obj_coeffs is only a within-size sort + tiebreak) and selected by a size-monotone binary search -> smallest passing plan area. Within a plan size the catalog's rebar options are effectively rho-ascending, so MinWeight (mass) and MinCarbon (carbon) pick the SAME lowest-rho passing section. The `_grow`/`_stack` sortperm(obj_coeffs) paths (which ARE carbon-ordered across sizes) don't override `_fit` on this benchmark.

Interpretation:
- WP 2.5 is capacity-safe (equiv harness: 0/1.7M mismatches) and regression-free (member-stage 299/299), and it's a correct PREREQUISITE: without rebar in obj_coeffs a shrink pass raised true carbon +4.8% (expe-6dcbaa95). But on medium_office it is carbon-NEUTRAL by itself.
- The actual carbon lever is `_fit`'s CROSS-SIZE criterion: it minimizes plan AREA, so it will still choose a smaller high-rho column over a bigger low-rho one even when the latter has less true carbon. To realize carbon savings, `_fit` must select the lowest-ec.jl-carbon section that passes across ALL plan sizes within the cap (breaks the current size-monotone binary search; needs a full feasible-set scan or a carbon-monotone argument). That is the Part B / SAO 'final shrink on carbon' work.

NEXT (proposed): prototype a carbon-ordered `_fit` selection (scan feasible sections, pick min rebar-inclusive carbon) behind a flag; measure on medium_office + a benchmark whose plan sizes carry non-rho-ordered rebar; verify convergence (no grow/shrink oscillation vs `_grow`).
