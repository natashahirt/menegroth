---
id: chec-abe8eb05
type: checkpoint
project: menegroth
parent_id: todo-b0ca6c8e
title: Phase 4 wall cache contract closed (run-8ce10c87)
node_label: Phase 4 wall cache contract closed (run-8ce10c87)
tags: walls,phase4,cache,contract,benchmark,checkpoint
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-34c42a85
created_at: '2026-10-22T18:34:23.632809+00:00'
updated_at: '2026-10-22T18:34:23.632809+00:00'
---
run-8ce10c87, rigor low, no fix cycle. Added StructuralSynthesizer/src/analyze/lateral/wall_cache_contract.jl (included from analyze/_analyze.jl) and scripts/runners/bench_wall_lateral_baselines.jl. The contract names four invalidation classes (checks_only, loads_only, stiffness_only, topology) and six fingerprint kinds. apply_wall_cache_class always throws; it is not called from design_building, to_asap!, or the scheduler. A loads_only request paired with stiffness_only or topology throws rather than downgrading. Named primitives, not wrapped: Asap.solve(model, cases) and sync_asap!(struc; loads_only=true). Benchmark on a four-wall two-story symmetric core: cold gravity skipped, reduced 0.000053 s, isolated FEM 0.016082 s, exit 0. Critic CONCERN, three P2s left for Phase 5: the loads_only gate does not itself witness E, thickness, or connectivity (the caller must pass the stricter class); the primitive string omits the scheduler _loads_only_sync guard around eccentricity writes; the reduced baseline solves once per story with accidental_ecc=0.0 while the script prints load_case_count 1. Code is uncommitted. Cores: the reduced model treats a core as independent piers on a rigid diaphragm; flange continuity exists only in the isolated shell evaluator when corners share nodes (1 mm). Phase 5 puts those shells in the building. Coupling beams are Phase 8.
