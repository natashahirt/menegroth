---
id: deci-3c2ac5e2
type: decision
project: menegroth
parent_id: plan-d72e497e
title: 'A6 kept: @debug diagnostics in _build_or_update_fea! are proven inert on DDM
  and syntactically inert on FEA'
node_label: 'A6 kept: @debug diagnostics in _build_or_update_fe'
tags: wave-1b, a6, debug-diagnostics, fea-cache, inert, decision
status: active
open_threads: 0
success: 'null'
files: StructuralSizer/src/slabs/codes/concrete/flat_plate/analysis/fea/precompute.jl@c09edf3
session_id: sess-74961ed9
created_at: '2026-07-16T10:12:11.473281+00:00'
updated_at: '2026-07-16T10:12:11.473281+00:00'
---
A6 is three `@debug "FEAModelCache"` inserts in `_build_or_update_fea!` inside `StructuralSizer/src/slabs/codes/concrete/flat_plate/analysis/fea/precompute.jl`, at post-diff lines 136, 175, 187:

- line 136 — rebuild path (fires when `cache_state == :uninitialized` OR `edge_beam_topology_changed`)
- line 175 — rebuild path (fires when `drop_panel_changed`)
- line 187 — update path (fires on cache hit / lightweight update)

Each log statement emits a small NamedTuple of state fields (rebuild reason, cache state) into the `Logging` sink. They exist to instrument the FEAModelCache decision tree so we can eventually distinguish "rebuild vs update" call ratios in production runs.

## Why A6 stays landed

**Syntactic proof of inertness (from review_a6, task-c2fa1a1e).** `@debug` expands via the `Logging` stdlib. Under the default global log level (`Info`), the `@debug` body is not executed at all — the macro compiles to a `min_enabled_level` check plus a boolean flag; the NamedTuple isn't built and the message isn't rendered. No numerical variable is read, written, or captured by the log call itself. Even under `Debug` logging (which we don't set), the reads are on cache-state locals that would otherwise sit idle. No mutation of `element.K`, `element.Q`, or model displacement arrays. No control-flow changes: the three inserts sit at the tail of branches that would return the same value with or without them.

**Behavioral evidence (from verify_a6_only, task-6ca02961).** The DDM (Full) 28' row is **bit-identical vs baseline** on all 23 invariants. DDM does not exercise `_build_or_update_fea!` directly — the DDM analysis path does not go through FEA precompute. But DDM does import the same `flat_plate` module and touches Julia's precompile chain including `precompute.jl`. If A6 had somehow perturbed the compiled module (an obscure macro-hygiene bug, a captured global, an accidental method extension), DDM would have drifted at least at the last-ULP level on some invariant. It did not. Bit-identity across 23 invariants is much stronger evidence than "no lint errors".

**The 10 FEA(frame) mismatches in verify_a6_only are NOT attributable to A6.** They are attributed to peer-Cursor drift in `external/Asap` (73 files, 91271+/91534- uncommitted lines including `K.jl`, `R.jl`, `force_displacement.jl`, `shell/meshing.jl`). See the Wave 1B checkpoint and the sibling "Baseline.csv is stale..." decision for the full evidence chain. Once Asap is stabilized and baseline is re-seeded, A6-only verify must show FEA bit-identity too. If it does not, revisit this decision.

## Files

- `StructuralSizer/src/slabs/codes/concrete/flat_plate/analysis/fea/precompute.jl` (three `@debug` inserts at lines 136, 175, 187)
