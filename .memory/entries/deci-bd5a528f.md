---
id: deci-bd5a528f
type: decision
project: menegroth
parent_id: plan-5d8af001
title: 'Run 2: incremental-engine API + contract (Run 3+ depends on this)'
node_label: 'Run 2: incremental-engine API + contract (Run 3+ d'
tags: incremental-design-dag,run2,contract,design-graph,fingerprint,scheduler,snapshot,provenance,variation-api
status: active
open_threads: 0
success: 'null'
files: StructuralSynthesizer/src/design_graph/_design_graph.jl@cb45d7a, StructuralSynthesizer/src/design_graph/node.jl@cb45d7a,
  StructuralSynthesizer/src/design_graph/graph.jl@cb45d7a, StructuralSynthesizer/src/design_graph/provenance.jl@79245e3,
  StructuralSynthesizer/src/design_graph/fingerprint.jl@79245e3, StructuralSynthesizer/src/design_graph/scheduler.jl@79245e3,
  StructuralSynthesizer/src/design_graph/session.jl@79245e3, StructuralSynthesizer/src/design_graph/executor.jl@cb45d7a,
  StructuralSynthesizer/src/design_workflow.jl@79245e3, StructuralSynthesizer/src/core/snapshot.jl@79245e3,
  StructuralSynthesizer/src/analyze/asap/utils.jl@79245e3, StructuralSynthesizer/src/StructuralSynthesizer.jl@79245e3
session_id: sess-d4eddbb4
created_at: '2026-07-14T07:43:55.960669+00:00'
updated_at: '2026-07-14T07:43:55.960669+00:00'
---
FINAL contract for the incremental engine built on Run 1's DesignGraph. Run 3+ depends on this. Exact-first: design_building stays bit-identical; every variation is verified against a from-scratch design.

NODE KEYS: content-stable SEMANTIC NodeKeys (:slab_sizing, :members, :foundations, prepare sub-steps, capture) — position-independent, replacing Run-1's positional stage_N keys.

PROVENANCE (per node): declares its DesignParameters param-slice + struc reads/writes + upstream deps. Key classifications:
- pattern_loading = PREPARE_AFFECTING: it changes the prepared Asap model's load-OBJECT COMPOSITION, which sync cannot retrofit.
- load_combinations = kept NON-prepare-affecting (magnitude-only); sync_asap! now refreshes all combo-derived magnitudes incl. vault thrust.
- optimize_for + collinear_grouping added to the :members slice (superset-safe; reader paths currently dead but future-proofs the documented struc.design_parameters wiring).

FINGERPRINTING: input-hash = hash(node code-version tag, node identity/NodeKey, upstream nodes' OUTPUT hashes, declared param slice); output-hash over the node's written fields. Generalizes compute_geometry_hash.

SCHEDULER: demand-driven, reverse-topological dirty marking + EARLY CUTOFF (recompute iff input hash changed; downstream stays clean when a recomputed node's output hash is unchanged). In-process memo keyed by input-hash.

SNAPSHOT/RESTORE: per-node WHOLE-STRUC snapshot/restore (core/snapshot.jl) keyed by NodeKey — clean prefix restored, only dirty nodes recomputed. capture_node_state deepcopies struc, transiently nulling the Asap model's _factorization (CHOLMOD C ptr) + _elemental_loads (both deterministically rebuilt).

PREPARE_AFFECTING_FIELDS GUARD: run_target!/DesignSession throw ArgumentError (requires_new_engine==true) when a prepare-affecting param changes; caller must build a fresh engine (baseline geometry/framing/loads can't be incrementally re-derived in Run 2).

VARIATION API: DesignSession(struc, base_params) + redesign(session; overrides...) / vary(session, diff) + a no-run dirty_frontier / requires_new_engine preview. All diffs are base-relative (order-independent).

EQUIVALENCE GATE: a comprehensive per-member design_signature (beam sizes, column/beam capacity+interaction+axial ratios, ok flags, punching stud counts, per-strip rebar, foundation ratios) at rtol=1e-8 alongside 15 aggregate invariants. NOT called "bit-identical" for the aggregate scalars.

engine_base_hash folds a real geometry fingerprint (frame-element endpoint coordinates), not element counts.
