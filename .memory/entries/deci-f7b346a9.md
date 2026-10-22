---
id: deci-f7b346a9
type: decision
project: menegroth
parent_id: plan-051e653d
title: 'P0-2 Step A: lazy memo restore — collapse N clean-level deepcopies into 1'
node_label: 'P0-2 Step A: lazy memo restore — collapse N clean-'
tags: ''
status: active
open_threads: 0
success: 'null'
files: StructuralSynthesizer/src/design_graph/scheduler.jl@cc17472, scripts/runners/verify_design_graph_incremental.jl@cc17472
session_id: sess-a9cb6177
created_at: '2026-10-22T15:48:56.836011+00:00'
updated_at: '2026-10-22T15:48:56.836011+00:00'
---
Implemented the interim P0-2 memo-shrink (Step A) in scheduler.jl `run_target!`: instead of eagerly `engine.struc = restore_node_state(rep.state)` (a deepcopy) at every all-clean topological level, hold `pending_rep = engine.memo[first(level_keys)].state` and materialize `engine.struc = restore_node_state(pending_rep)` exactly ONCE — immediately before the first dirty level executes, or at walk end if it terminated on clean levels. Relies on invariant R7: classification + clean levels only read/write `pass_output` and `engine.memo`, never reading or mutating `engine.struc`. This collapses N clean-level deepcopies into a single materialization with no change to `core/snapshot.jl`.

Verification: `verify_design_graph_incremental.jl` (the exact-first incremental==cold equivalence gate) passes 127/127, GATE_EXIT=0 — byte-identical across the full invalidation matrix, so the optimization is observably inert.

Fixture fix required to run the gate: the just-committed DDM validation (ACI 318-11 §13.6.1.1 — DDM requires ≥3 continuous spans each direction) now correctly rejects the 2×2-bay flat-plate verify fixtures. Bumped `build_flat_plate` and `build_multistory_flat_plate` from 2×2 to 3×3 bays (total plan dims unchanged → uniform 18'×14' bays, DDM-valid). Vault/beam fixtures and `_prepared_frame_forces` (bypasses presize) left untouched. The same 2×2+DDM collision exists in verify_design_graph.jl, verify_incremental_engine.jl, verify_warm_state_incremental.jl — swept separately.
