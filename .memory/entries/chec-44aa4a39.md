---
id: chec-44aa4a39
type: checkpoint
project: menegroth
parent_id: plan-8b00b305
title: 'Phase D-A done: flexible mat (Winkler+Shukla) envelopes flexural/punching
  over strength combinations'
node_label: 'Phase D-A done: flexible mat (Winkler+Shukla) enve'
tags: ''
status: active
open_threads: 0
success: 'null'
files: StructuralSizer/src/foundations/codes/aci/mat_shukla.jl@1528dfa, StructuralSizer/src/foundations/codes/aci/mat_winkler/design.jl@1528dfa,
  StructuralSizer/src/foundations/codes/aci/mat_footing.jl@1528dfa, StructuralSizer/test/foundations/test_mat_aci.jl@1528dfa
session_id: sess-e9738e73
created_at: '2026-11-26T15:19:00.588185+00:00'
updated_at: '2026-11-26T15:19:00.588185+00:00'
---
Phase D-A makes ShuklaAFM and WinklerFEA design the mat flexural/punching section to the face-by-face ENVELOPE over every ASCE 7 strength combination, instead of a single factored Pu per column. Decisions (user-confirmed): sweep BOTH methods per combination (accept FEA cost); bearing stays the existing service check (already enforced at plan sizing); D-B 20% gate stays gravity-only (no change).

Shared layer (mat_shukla.jl): _demand_with_action(d, a) copies a FoundationDemand with Pu/Mux/Muy from one combination's FootingAction (geometry + Ps kept). _mat_strength_sets(demands, column_strength) returns one demand vector per combination; with no combinations it returns [demands] so single-load behaviour is byte-identical. _envelope_flexure_pairs does the per-face max.

Shukla: _design_mat_shukla gained column_strength kwarg. Thickness loop keeps the base (gravity) field for the bearing guard + equilibrium diagnostic, then loops strength sets running _shukla_analysis per combination (linear), enveloping flexure pairs + punching util (env_util_p). Final steel + utilization from the envelope.

Winkler: extracted the ~90-line column-strip moment integration into _winkler_gov_moments(shells, model, plan, c_max_m, B_m, Lm_m) (per-unit-length gov moments). _design_mat_winkler_fea gained column_strength + wall_strength kwargs. Precomputes fixed col_nodes/wall_nodes (wall_pts carries (x,y,leg_idx,sample_idx)); builds one NodeForce vector per combination via _winkler_loads (vertical loads only — column moments enter solely through punching). Thickness loop sets model.loads=loads_k, Asap.update!(loads_only) then _solve_winkler! per combination (no-tension plate is nonlinear so combos can't be superposed — verified update!(values_only) calls populate_loads! so swapping model.loads is picked up; same pattern as slab story_shell_bars). Envelopes gov moments + env_util_p across combos. Final steel + utilization from the envelope.

mat_footing.jl: threaded column_strength (+ wall_strength for Winkler) into all 3 flexible call sites (rigid->Winkler fallback, ShuklaAFM, WinklerFEA).

Verified green: test_mat_aci (incl. new 'Flexible mat envelopes strength combinations (Phase D-A)' testset: r_env.D >= r_heavy.D >= r_grav.D; no-combo == single-combo equal D/As/steel_volume for both methods), test_mat_walls, test_mat_rigid_statics, test_foundation_combinations, test_no_tension_springs, test_footing_loads, test_types_load, test_wall_footing, test_wall_strip, test_strip_aci, test_foundation_safety_9_15.
