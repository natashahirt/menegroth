---
id: chec-4cb86d8f
type: checkpoint
project: menegroth
parent_id: chec-c99382a3
title: 'Phase D stability Stage 4: lateral demand wiring + API StabilityParams threading
  (Synthesizer)'
node_label: 'Phase D stability Stage 4: lateral demand wiring +'
tags: ''
status: active
open_threads: 0
success: 'null'
files: StructuralSynthesizer/src/analyze/lateral/foundation_reactions.jl@02f0a7e,
  StructuralSynthesizer/src/api/deserialize/foundations.jl@02f0a7e, StructuralSynthesizer/src/api/schema/input_types.jl@02f0a7e,
  StructuralSynthesizer/src/api/schema/input_schema.jl@02f0a7e, StructuralSynthesizer/src/api/validation.jl@02f0a7e,
  StructuralSynthesizer/test/analyze/test_foundation_stability_wiring.jl@02f0a7e,
  StructuralSynthesizer/test/runtests.jl@02f0a7e
session_id: sess-02cb51e6
created_at: '2026-11-27T05:15:24.509725+00:00'
updated_at: '2026-11-27T05:15:24.509725+00:00'
---
Stage 4 closes the Synthesizer-side plumbing for foundation global stability.

**Hx/Hy from lateral analysis.** `_support_footing_action` and `_node_reaction_action` (foundation_reactions.jl) now read the horizontal base shears R[gid[1]]=Hx, R[gid[2]]=Hy alongside the existing P=gid[3], Mx=gid[4], My=gid[5], building the 6-arg FootingAction. These feed D/L/companion/wind/qe cases; combine_foundation_action already factors Hx/Hy (Stage 1), so the resultant base shear flows unchanged into footing_stability_utils. No new solve.

**API threading.** New opt-in `APIStabilityParams` block on `APIFoundationOptions.stability` (input_types.jl + StructType reg). `_api_to_stability_params` maps delta_ratio/ca_ratio/include_passive/concrete_unit_weight_pcf (pcf->lbf/ft^3)/dead_counteracting_factor to StructuralSizer.StabilityParams, falling back to its defaults. A generic field-preserving `_with_stability(p, stab)` (positional ctor over fieldnames) applies the resolved StabilityParams to ALL THREE param blocks (spread/strip/mat) uniformly in `_resolve_foundation_options` — regardless of whether a per-type override was supplied. Absent block => stability stays nothing => pre-stability behaviour exact. Soil phi/c/gamma come from the named foundation_soil preset (SOIL_MAP presets carry them). Light range validation added (Bowles Table 4-5: 0.5<=delta_ratio<=1, 0.6<=ca_ratio<=1; dead factor in (0,1]; weight>0). Schema doc entry added.

**Tests.** New test/analyze/test_foundation_stability_wiring.jl (37 tests): dof-indexing of Hx/Hy, API block threads onto all three blocks + off-by-default, _with_stability preserves other fields. Regression: test_foundation_demands + test_foundation_service_reactions 112/112 green; lints clean.

**Deferred:** wall-footing/wall-mat stability still gated on WallLineDemand lacking lateral shear (todo-28ad929d). Next: Stage 5 end-to-end integration test driving a laterally-loaded building through design with stability on.
