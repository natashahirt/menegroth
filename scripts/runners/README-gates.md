# Exact-First Verify Gates

This directory holds the four **exact-first verify gates** for the Incremental
Design DAG effort. Each gate is a standalone `julia` runner that self-activates
the `StructuralSynthesizer` environment, runs a differential/consistency proof,
and exits `0` on success / `1` on any mismatch.

Run all four, headless, with an aggregated exit code:

```bash
julia scripts/runners/run_all_gates.jl
```

`run_all_gates.jl` spawns each gate in its own subprocess (so one gate's
`exit()` or global state cannot abort the others), forces
`SS_ENABLE_VISUALIZATION=false` for every child, and exits `0` only when all
four pass. Override the child environment with `--project=PATH` or the
`SS_GATES_PROJECT` env var (default: `StructuralSynthesizer`).

## Gate inventory

| Order | Gate | What it verifies | Tolerance / exactness | Rough cost | Gurobi? |
|-------|------|------------------|-----------------------|------------|---------|
| 1 | `verify_design_graph.jl` | `DesignGraph` execution path (`build_design_graph` + `execute_graph!`, as driven by `design_building`) is output-equivalent to an **independent** reconstruction of the legacy `build_pipeline` stage loop, over 3 small buildings (flat-plate DDM, beam/column vault, flat-plate with per-story uniform column sizing). | Aggregate **invariant set** compared at `rtol = 1e-8`, `atol = 1e-10`, `NaN == NaN`. | Lightest — 3 cases × (graph + reference) designs; per-case elapsed printed. | No (HiGHS fallback). |
| 2 | `verify_incremental_engine.jl` | The demand-driven incremental engine (`prepare_engine` / `run_target!` / `redesign_incremental!`) is correct: full-run equivalence, idempotent reuse, selective recompute + early cutoff, dirty-frontier observability, and the prepare-affecting baseline guard. | 15 aggregate invariants **and** the comprehensive per-member `design_signature`, both at `rtol = 1e-8` (`atol = 1e-10`). | Light–medium — ~5 checks on one 2×2-bay DDM fixture. | No (HiGHS fallback). |
| 3 | `verify_design_graph_incremental.jl` | The Run-2 variation API (`DesignSession` / `redesign` / `vary` / `dirty_frontier`): for each representative param variation, both the **SKIP** claim (recomputed nodes == expected dirty frontier) and the **EXACT** claim (matches a from-scratch `design_building`). Includes multi-level buildings and prepare-affecting guard cases. | 15 aggregate invariants **and** per-member `design_signature` at `rtol = 1e-8` (`atol = 1e-10`). | Heaviest — many variations × from-scratch references, multi-level + vault fixtures, MIP member sizing. | No, but benefits — exercises `optimize_discrete`; HiGHS fallback works, Gurobi is faster/more deterministic. |
| 4 | `verify_warm_state_incremental.jl` | The Run-6 warm-state / factorization-aware reuse additions are byte-identical to the cold path they replace: warm==cold engine (full + loads-only + members-only), CHOLMOD factorization reuse (`sync_asap!(…; loads_only=true)`), and MIP warm start (`optimize_discrete` with `mip_start`). | `design_signature` compared **byte-identically** (`rtol = 0.0`, `atol = 0.0`, or `==`) and an identical `last_recomputed` set; factorization reuse exact on element forces and global `u`. | Medium — cold-vs-warm reruns on the same 2×2-bay DDM fixture; includes a MIP warm-start check. | No, but benefits — the MIP warm-start check (Part B) uses `optimize_discrete`; HiGHS fallback works, Gurobi is faster/more deterministic. |

Notes on cost: the numbers above are **relative**; the first gate in a cold
session also pays Julia/package precompilation, which dominates wall time. Each
gate prints its own per-case elapsed times.

## Invariant / `design_signature` schema

The gates compare two tiers of outputs:

- **Aggregate invariants** — a tuple of global scalars extracted from a
  `BuildingDesign`: slab thickness `h`, `M0`, punching ratio, deflection ratio,
  `As` totals, column min/max dims, embodied-carbon total and per-area, and
  foundation dims / utilization (see `extract_invariants` in
  `verify_design_graph.jl` and the mirrored `invariants` /
  `extract_invariants` in the incremental gates — the incremental gates fix the
  set at **15** aggregate invariants). These are global maxima/sums, so they can
  miss a per-member provenance omission on their own.

- **`design_signature`** — a deterministic flattening of **every** per-member
  output field (beam sizes, column/beam capacity + interaction + axial ratios,
  `ok` flags, punching stud counts, per-strip rebar). This is what catches a
  per-member omission that the aggregate scalars let slip (exactly how the
  `pattern_loading` P0 escaped an aggregate-only gate). Gates 1–3 compare it at
  `rtol = 1e-8`; the warm-state gate (4) compares it **byte-identically**
  (`rtol = 0`, `atol = 0`) because warm reuse must reproduce the cold path
  bit-for-bit.

The two tiers are intentionally redundant: an output-equivalence claim is only
accepted when **both** the aggregate invariants and the full `design_signature`
agree.

## Canonical `--project` path

All four gates `Pkg.activate(joinpath(@__DIR__, "..", "..", "StructuralSynthesizer"))`
and `Pkg.instantiate()` **internally**, so the canonical environment is
`StructuralSynthesizer` regardless of the `--project` flag you pass:

| Use case | Command |
|----------|---------|
| Run one gate directly | `SS_ENABLE_VISUALIZATION=false julia --project=StructuralSynthesizer scripts/runners/verify_design_graph.jl` |
| Run all four, aggregated | `julia scripts/runners/run_all_gates.jl` |
| Run all four, custom env | `julia scripts/runners/run_all_gates.jl --project=/abs/path/to/StructuralSynthesizer` |

Because the runners re-activate `StructuralSynthesizer` themselves, the
`--project` flag is mostly for the launching process; the orchestrator defaults
it to `StructuralSynthesizer` to match the convention. Gurobi is never required —
the MIP paths (`optimize_discrete`) fall back to HiGHS — but a Gurobi license
makes the MIP-heavy gates (3 and 4) faster and more deterministic.
