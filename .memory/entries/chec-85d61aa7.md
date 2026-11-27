---
id: chec-85d61aa7
type: checkpoint
project: menegroth
parent_id: chec-4cb86d8f
title: 'Phase D stability Stage 5: end-to-end base-shear → sliding-utilization integration
  test (green)'
node_label: 'Phase D stability Stage 5: end-to-end base-shear →'
tags: ''
status: active
open_threads: 0
success: 'null'
files: StructuralSynthesizer/test/analyze/test_foundation_stability_e2e.jl@7c4a0d9,
  StructuralSynthesizer/test/runtests.jl@7c4a0d9
session_id: sess-fed9e6ce
created_at: '2026-11-27T13:26:40.724073+00:00'
updated_at: '2026-11-27T13:26:40.724073+00:00'
---
Stage 5 closes the foundation global-stability track with an end-to-end integration test that drives real base shear through the production spread-footing sizing dispatch.

**test/analyze/test_foundation_stability_e2e.jl (14 tests, green).** Builds a real flat-plate office (gen_medium_office), runs to_asap!/sync_asap!/initialize_supports!/initialize_foundations!/support_demands, then injects a FoundationLateralCases envelope with one wind case carrying a pure horizontal base shear Hx at every support (vertical dead = each support's real service reaction, so comb. 7a 0.6D is physical; no seismic). Sizes one single-support compression spread foundation three ways via the production _size_fnd_aci! path:
- stability OFF (FoundationOptions default) => checks.sliding/overturning/uplift all NaN (baseline unchanged).
- stability ON (SpreadParams(stability=StabilityParams())) => checks.sliding finite, >0, <1 (chosen below friction capacity), overturning/uplift finite, and result.utilization >= sliding (folded in).
- doubling Hx => sliding strictly increases AND (geometry identical, bearing governs) scales linearly ~2x rtol 1e-6 — proving Hx actually propagates through foundation_actions_at -> ASD comb factoring -> footing_loads(column_service) -> design_footing(SpreadFooting) -> footing_stability_utils.

The wind/seismic SOLVE that fills reaction vectors is covered by the lateral suite; this test injects a deterministic lateral case so the sliding demand is exact. Lints clean.

**Full Phase D stability track now complete** (Stages 1–5): FootingAction horizontal shear + combo factoring (1), StabilityParams + stability.jl (2), spread/strip/mat integration (3a/3b/3c), Synthesizer reaction wiring + API threading (4), e2e integration (5). Deferred: wall-footing/wall-mat stability (WallLineDemand lacks lateral shear, todo-28ad929d). Remaining user items: package foundations A–D into reviewable PRs; parked column-gaps clarification.
