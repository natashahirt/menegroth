---
id: deci-9fd90dc6
type: decision
project: menegroth
parent_id: plan-5d8af001
title: 'Run 3 architecture contract: barrier/level sync + fine per-slab nodes (exact-first
  foundation for Run 4)'
node_label: 'Run 3 architecture contract: barrier/level sync + '
tags: ''
status: active
open_threads: 0
success: 'null'
files: StructuralSynthesizer/src/design_graph/graph.jl@cb45d7a, StructuralSynthesizer/src/design_graph/executor.jl@cb45d7a,
  StructuralSynthesizer/src/design_graph/scheduler.jl@79245e3, StructuralSynthesizer/src/design_graph/provenance.jl@79245e3,
  StructuralSynthesizer/src/design_graph/fingerprint.jl@79245e3, StructuralSynthesizer/src/design_workflow.jl@8e34430,
  StructuralSynthesizer/src/core/snapshot.jl@8e34430
session_id: sess-a0606b76
created_at: '2026-07-14T17:14:03.319464+00:00'
updated_at: '2026-07-14T17:14:03.319464+00:00'
---
The durable Run-3 design contract that Run 4 (Option A) builds on.

BARRIER/LEVEL SYNC (replaced per-node needs_sync::Bool): graph.jl exposes topological_levels(g) (Kahn waves — pops the WHOLE ready set per level, sorted by insertion index) and level_needs_sync(g, level)=any(needs_sync, level). The executor (executor.jl) and scheduler (scheduler.jl) fire sync_asap! EXACTLY ONCE per level that contains a needs_sync node (not per-node, not 0x). This matches the coarse pipeline's single post-stage sync.

FINE PER-SLAB NODES: build_design_graph (design_workflow.jl) emits one node per slab (:slab_sizing_s{idx}) as EDGELESS ROOTS in ascending slab_idx. Because they have no deps, topological_levels collapses ALL slab nodes into ONE level, iterated in insertion order = eachindex = the single-threaded coarse size_slabs! order. A SINGLE post-level sync follows. This is what preserves design_building BYTE-IDENTITY (designs + solver_trace, incl. the legacy stage_1_slabs/size_slabs! trace envelope re-emitted on the first/last slab node). :members depends on all slab keys; :foundations on :members.

PER-SLAB PROVENANCE: provenance.jl — SLAB_NODE_PREFIX / slab_node_key / is_slab_node_key / slab_node_index; pipeline_provenance(slab key) inherits PIPELINE_PROVENANCE[NODE_SLAB_SIZING] verbatim. Every slab node folds the IDENTICAL whole-field param slice into input_hash (fingerprint.jl hash_param_slice folds getfield whole, never per-slab-narrowed) with EMPTY upstream (edgeless). => slab dirtiness is provably ALL-OR-NOTHING (any slab-slice change dirties all; any non-slice change dirties none). This is the load-bearing invariant that makes the incremental path exact.

EXACT-FIRST GUARD (the Run-3 fix): fine slab nodes reading LIVE monotonically-grown shared columns means a MIXED clean/dirty slab level would diverge from from-scratch. The exported target= kwarg (run_target!/DesignSession/redesign) could memoize a strict subset of slab roots and create such a mixed level. FIX: a guard at the top of run_target! (scheduler.jl:331-344, the sole engine.memo writer at :464) throws ArgumentError if the target closure covers a NON-EMPTY STRICT SUBSET of slab roots — making the mixed level UNREPRESENTABLE by construction. Legitimate full runs (terminal/:members/:foundations/no-target) pull the full slab set and pass. Combined with the all-or-nothing hash invariant, exact-first holds via two independent mechanisms.

PARTIAL SNAPSHOT/RESTORE (scaffolding for Run 4, currently guarded-unreachable): core/snapshot.jl restore_slab_node_writes! (overlay slab-owned outputs + slab-owned cell loads) + _adopt_larger_column! (monotonic column max-merge: never-shrink, deep-copy volumes, on a dimensional tie adopt snapshot section only on a provable non-downgrade by As_total — ENGINEERING JUDGMENT proxy per ACI 318-11 §10.3.6.2 axial phiPn,max monotonic in Ast; NOT a full P-M comparison). This path is unreachable end-to-end under the current global-param model; covered by direct unit tests only.

RUN 4 (Option A) CARRY-FORWARDS: (1) true independent per-slab/per-MemberGroup variation via non-prepare-affecting per-group override params (member_catalog_objective primary) — will MAKE the mixed slab level reachable, so it must land the order-independent grow-then-size TWO-PASS (pre-grow shared columns, then size all slabs against final columns) to stay exact + parallelizable. (2) When the merge path becomes reachable, replace the _adopt_larger_column! As_total proxy with a real P-M capacity comparison via the column checker/ACIColumnCapacityCache (advisory P2 from fix-crit: equal-As_total tie ignores bar layout). (3) Deferred from Run 3/plan: fixpoint nodes + warm-start for iterative loops, factorization-aware Asap edges (loads_only/values_only), plan-d72e497e micro-opts as node policies. (4) Pre-existing coarse single-thread-vs-multithread non-determinism (fine graph pins eachindex) — the two-pass resolves it.
