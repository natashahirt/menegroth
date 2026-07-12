---
id: plan-d72e497e
type: plan
project: menegroth
parent_id: plan-a0000003
title: Flat-plate sizing speed-up plan (journal-paper solver time)
node_label: Flat-plate sizing speed-up plan (journal-paper sol
tags: flat-plate,size_flat_plate,performance,cache-reuse,speedup,plan
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-233d5ffc
created_at: '2026-07-12T23:19:37.397365+00:00'
updated_at: '2026-07-12T23:19:52.345137+00:00'
---
# Goal

Reduce solver time for the flat-plate sizing pipeline (`size_flat_plate!` + downstream reconciliation) so the Section-3 building-scale journal-paper study runs in a practical wall-clock budget. Design outputs must remain identical (within float roundoff) — only runtime should change.

# Constraints (from user)

- Parallelization across the outer sweep is **not** allowed.
- Push cache reuse harder; identify redundancies; prefer joint NLP where feasible; skip work when a prior method already answered.
- Reuse the existing `MemberGroup` (`columngroup`) abstraction for flat-plate columns.

# Optimization plan (approved by user)

**Stage 0 — validation harness** (gates every subsequent block):
- `scripts/runners/run_flat_plate_speedup_validation.jl` + baseline CSV.
- Smoke matrix: 3 spans × 4 methods (DDM, EFM(ASAP), FEA(frame), FEA(strip)) × 1 LL × 1 concrete.
- Diff against baseline on ~23 invariant columns (h, M0, columns, punching, deflection, As, EC, foundations). Runtime is recorded but NOT gated.

**Stage 1 — cache reuse (A-series)**:
- A1: FEA D/L split solves: `values_only=true` → `loads_only=true` in `load_cases.jl` (3 sites). Preserves LU factorization across load-only changes; expected ≈3× speedup on FEA solves.
- A2: Skip duplicate moment/column work at top of Phase B when `columns and h` are unchanged.
- A3: Gate Phase B `size_columns` + `_update_column_sizes!` on `columns_grew_last_iter`.
- A4: Symmetric-secondary predicate + swap-axis path for DDM/EFM.
- A5: Precompute per-column `Pu_per_unit_dead/live`; rescale per iter instead of full walk.
- A6: One-shot REBUILD/UPDATE `@debug` diagnostic in `_build_or_update_fea!` to verify reuse.
- A7: Refactor `sweep_building` (Section 3) to share `prepare!` across the methods axis (snapshot/restore pattern).
- A8: `skip_applicability_check` kwarg on `size_flat_plate!`; set true from `_run_method` (which already pre-checks).

**Stage 2 — phase merging & tolerance (B-series)**:
- B1: Merge Phase A and Phase B into a single inner loop, behind a feature flag; default-on after validation.
- B2: Replace `column_tol` with `max(c_inc, rel_tol*c_old)`; ENGINEERING JUDGMENT.

**Stage 3 — NLP paths (C-series)**:
- C1: `slab_strategy=:nlp` on `FlatPlateOptions` for DDM rows; warm-start from one Phase A iter; fall back to `:iterative`.
- C2: New `fea_problem.jl` mirroring `FlatPlateNLPProblem`; COBYLA solver; fall back when pattern loading is enabled.

**Stage 4 — column grouping (D-series)**:
- D1: `assign_flat_plate_column_groups!` called from `prepare!` before `to_asap!`.
- D2: Build `column_groups`, envelope demands, call `size_columns` on k groups instead of n columns.
- D3: Dedupe `_resolve_punching_failures!` by `group_id`; solve once per failing group.
- D4: Early-return in `harmonize_uniform_column_sizes!` when grouping is active.
- D5: `test_column_grouping.jl` with off-vs-per-story round-trip.

# Current wave (Wave 1)

Harness + A1 + A6. Executed by a coordinator DAG (see the run linked below when it lands).

# Safety invariant

`.cursor/rules/code-accuracy.mdc` applies. Any change that could affect a design output must be gated by the validation harness (Stage 0) and reviewed. `values_only` vs `loads_only` semantics are documented at `external/Asap/src/Model/analysis.jl:687-732` (`update!` docstring): `loads_only=true` rebuilds only the load vector `P` and preserves the cached matrix factorization; `values_only=true` clears the factorization. The A1 change is safe because between the D solve, L solve, and factored-restore, only `AreaLoad.pressure` changes — never element geometry, section, material, or DOF topology.
