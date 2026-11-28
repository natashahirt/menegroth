# RigidLink factorization cache (#7)

**Status:** phase-1 + phase-2a + phase-2b implemented (mutating `solve!`,
non-mutating plain `solve`, and the lateral P-Δ / frame-only `solve`).
**Scope:** `external/Asap/src/Elements/rigidlink.jl`,
`external/Asap/src/Model/analysis/factorization_cache.jl`.
**Safety:** core FEM solve under rigid diaphragms — treated as safety-critical.
The cache is **exact or it does not fire**: every reuse is guarded by a pattern
key, and any mismatch or non-SPD result falls back to a fresh `cholesky`, i.e.
today's behavior. Worst case: no speed-up, never a wrong displacement.

## Problem

Under a rigid diaphragm, every building re-solve goes through
`solve!(model, links)` (mutating) or `solve(model, cases, links)` (multi-case,
non-mutating). Both condense the system by master/slave reduction
(Bathe §4.4; Cook §6.3):

```
G, dependent   = _build_rigidlink_reduction(model, links)   # depends on links + geometry + model.DOFs
Sc             = Gᵀ S G                                      # depends on S values
retained_free  = setdiff(model.freeDOFs, dependent[, held]) # depends on topology
Krr            = Symmetric(Sc[retained_free, retained_free])
fact           = cholesky(Krr)                               # <-- fresh EVERY call (symbolic + numeric)
```

The profiler (2026-11-20, `chec-4ffcbf9e`) attributes **44 of 48 building
factorizations** on the core office to this path (walls 28, members 16). Each is
a *full* `cholesky`: CHOLMOD symbolic analysis (fill-reducing ordering, the
dominant cost for large shell/frame models) **plus** numeric factorization. The
`solve!` path even nulls `model._factorization` afterward, so nothing is reused.

Meanwhile the **non-link** path already reuses the symbolic analysis: after an
`update!(; values_only=true)` (same sparsity pattern, in-place `S` value update),
`_get_factorization` does `cholesky!(old, K)` — numeric-only — guarded by
`_factor_pattern_key`. The rigid-link path simply never joined that mechanism.

## Key insight

For a **value-only** re-solve (member/wall sizing changes a section but not the
mesh, links, or geometry), `G`, `dependent`, `retained_free`, and the **sparsity
pattern** of `Krr` are invariant; only `Krr`'s numeric values change. So the
symbolic factorization can be reused via `cholesky!`, exactly as the non-link
path already does for the full system.

## Phase 1 — mutating `solve!(model, links)` (implemented)

Reuse the model's existing factor-cache slots for the **reduced** factor. The
link path already nulls `model._factorization`, so the slot is free whenever
links are present, and the no-link `_get_factorization` is never called on a
link model (`_solve_struc_model!` branches on `isempty(links)`). This means
**no `Model` struct change** and full reuse of the existing invalidation
lifecycle:

- `update!(; values_only=true)` → `_invalidate_factor_values!` sets
  `_factorization_stale=true` (the "values changed, pattern same" signal).
- `update!()` full / `geometry` / `process!` → `_factorization=nothing` (forces a
  fresh reduced factor — pattern may have changed).

New helper `_get_reduced_factorization!(model, Krr, retained_free)` in
`factorization_cache.jl`, mirroring `_get_factorization` but for the passed
reduced matrix:

- **Reduced pattern key** = `hash((objectid(model.S), nnz(model.S),
  retained_free, Krr.data.colptr, Krr.data.rowval))`. `objectid(model.S)`
  changes on a full rebuild (new `S` object), `colptr`/`rowval` capture the exact
  reduced sparsity, `retained_free` captures the tie/DOF set. Hashing is O(nnz),
  negligible beside factorization.
- **Refactor path:** cached CHOLMOD factor and key matches → `cholesky!(old,
  Krr)` (numeric-only, reuses the symbolic ordering); logs `:refactor`. This
  recomputes the numerics from the *current* `Krr` every time, so the returned
  factor always decomposes exactly this `Krr` — the reuse is of the pattern-only
  symbolic work, never of a stale numeric factor. (There is deliberately **no**
  blind "not-stale → return old" fast path: that would assume `Krr`'s values are
  unchanged, which a change to `G` outside `update!` could violate.)
- **Fallback:** otherwise a fresh `cholesky` (logs `:factor`), then LDLᵀ, then LU
  — identical to the current code, including non-SPD handling. Stores the key
  only on a successful CHOLMOD factor; otherwise `_factor_key=0` (never reused).

`solve!(model, links)` calls the helper instead of the raw `cholesky` block and
**keeps** the reduced factor in `model._factorization` (instead of nulling it),
so the next value-only re-solve can reuse it. `G` is still rebuilt each call
(cheap sparse assembly); only the expensive symbolic analysis is cached.

### Why this is exact

The returned factor always factorizes the *current* `Krr`: either it was just
built from the current `S` values (fresh/refactor), or the key proves `S` object,
nnz, reduced pattern, and tie set are unchanged **and** the staleness flag proves
no value-only update happened since — so `Krr` is byte-identical to what the
cached factor already decomposes. CHOLMOD factorization of an identical matrix is
deterministic, so a reused-factor solve is bit-identical to a cold one. Any
deviation (new `S` object, changed nnz/pattern, changed ties, or a value update)
flips the key or the staleness flag and forces a fresh factorization.

## Phase 2a — non-mutating `solve(model, cases, links)` read-only reuse (implemented)

The non-mutating multi-case solve must not *write* `model.u`, `model.P`, or
`model._factorization`, but it may *read* a factor the mutating path already
built. For the **plain** reduced system (`geometric_stiffness === nothing &&
!exclude_shells`) its `Krr` is byte-identical to the one `solve!(model, links)`
produces (same `retained_free`, same `Sc`). So when `model._factorization` is a
current CHOLMOD factor (pattern key matches, not stale), the multi-case solve
**reuses it read-only** (`Ur = fact \ Fr`) instead of factoring again.

This removes the second factorization that `_solve_with_patterns!` paid on
**every** pattern-based building re-solve (the member-stage hot path: mutating
full-load solve, then this multi-case pattern solve on the same `Krr`), and the
full-load lateral solves. A CHOLMOD `\` does not mutate the factor, and the
building model is solved sequentially, so the shared factor is safe. Variants
with `geometric_stiffness` (P-delta) or `exclude_shells` build a different matrix
and still factor fresh.

## Phase 2b — cross-call cache for the Kg / exclude-shells lateral solves (implemented)

The wall stage's P-Δ (`geometric_stiffness`) and frame-only (`exclude_shells`)
solves build reduced matrices with no counterpart in `model._factorization`
(different `Krr` values for P-Δ, a different `retained_free`/pattern for
frame-only), and the lateral stage *interleaves* them across many load cases and
gravity combinations. Phase 2a therefore never fires for them.

Phase 2b adds a **caller-owned** cache, `Asap.RigidLinkFactorCache`
(`factorization_cache.jl`), passed to `solve(model, cases, links; factor_cache)`:

- Holds one CHOLMOD factor **per distinct reduced pattern**, in a
  `Dict{UInt, CHOLMOD.Factor}`. The key is
  `hash((_reduced_factor_pattern_key(model, Krr, retained_free),
  exclude_shells, geometric_stiffness !== nothing))` — the reduced pattern key
  (phase 1) **plus a variant discriminator**, so `S`, `S + K_G`, and shells-excluded
  never share a factor even if their reduced patterns coincide.
- On a hit, `cholesky!(old, Krr)` refactors numerically from the **current**
  `Krr` (reusing only the symbolic ordering); on a miss, a fresh `cholesky`.
  Same exactness argument as phase 1: the numerics are always recomputed, so a
  reuse is bit-identical to a cold factor.
- **Only SPD factors are cached.** An indefinite `Krr` (e.g. a buckling P-Δ
  system) falls back to LDLᵀ → LU every call and stores nothing, so the cache
  never holds a factor it cannot `cholesky!`-refresh.
- Deliberately **invisible to `_N_FACTORIZATIONS`**, like the rest of the
  non-mutating `solve`; the `:factor`/`:refactor` log events are the reuse signal.

**Storage / lifecycle (`StructuralSynthesizer`).** The cache lives in
`struc._analysis_caches` under the reserved key `_LATERAL_FACTOR_CACHE_KEY = -3`
(`analyze/lateral/story_pdelta.jl`), created on first use by
`_lateral_factor_cache(struc)` and dropped by `clear_geometry_caches!` on a
remesh (the key also folds in `objectid(model.S)`, so a new mesh can never match a
stale entry — defence in depth). Threaded into the three per-gravity-key P-Δ
loops that dominate the wall stage: `ordinary_wall_stage.jl` (`K_G`, shells kept)
and `interactive_checks.jl` (`K_G` + `exclude_shells`, in both the frame-only
stability and the frame-member-strength checks). Each sweep now pays one symbolic
analysis per pattern instead of one per gravity key.

## Verification

1. `external/Asap/test/` rigid-link + factorization-cache suites — 239/239
   (`scripts/runners/test_rigidlink_factor_cache.jl`).
2. Phase-2b equivalence + reuse (`scripts/runners/test_rigidlink_factor_cache_phase2b.jl`),
   13/13: results with a cache are **bit-identical** (`==`, not `≈`) to results
   without across a `K_G` sweep, and the sweep logs one `:factor` + `N-1`
   `:refactor` (vs `N` `:factor` uncached).
3. Wall stage (real P-Δ + `exclude_shells` callers):
   `analyze/test_ordinary_wall_stage.jl` 701/701.
4. Member-stage golden suite stays bit-identical:
   `core/test_flat_plate_member_stage.jl` 299/299 (confirms the shared
   `_analysis_caches` reserved key does not contaminate the member stage).
