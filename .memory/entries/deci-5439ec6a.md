---
id: deci-5439ec6a
type: decision
project: menegroth
parent_id: plan-ad399e86
title: 'Framed-slab load routing: strip fast-path restricted to true joist-frame rectangles
  (per-member exact)'
node_label: 'Framed-slab load routing: strip fast-path restrict'
tags: framing, load-path, framed-slab, joist, tributary, aci, fem, invariant, rectangle
status: active
open_threads: 0
success: 'null'
files: StructuralSynthesizer/src/analyze/asap/utils.jl@54d3637, StructuralSynthesizer/src/analyze/framing/populate.jl@54d3637,
  scripts/runners/run_joist_load_transfer_smoke.jl@54d3637, scripts/runners/run_nonconvex_joist_layout_check.jl@54d3637
session_id: sess-c295becb
created_at: '2026-07-24T06:29:20.089061+00:00'
updated_at: '2026-07-24T06:29:20.089061+00:00'
---
Closes the foundation load-path work for defects #1/#2 (joists carry slab pressure; girders get demand from joist end-reactions via the FEM) and #5 (non-convex slab robustness). Six engineer->reviewer->critic->tester cycles; the adversarial critic defeated FIVE successive gating strategies, each time proving the prior invariant was a PROXY that leaked a per-member error the coarser check could not see:

1. convexity alone -> broke on a convex hexagon.
2. total-area conservation -> same hexagon (total conserves, per-member does not; -20% on edge girders).
3. constant-member-length -> non-convex compensating-bulge decagon (all supports len 6, area exact, -14.3% edge girder).
4. convex + length + area -> convex KITE (area/bbox ratio 1.0 exactly, -21.7% joist).
5. direct per-band per-member AREA check -> a sheared convex PARALLELOGRAM: per-band areas match but the UNIFORM TributaryLoad pins each joist's load centroid to mid-span (50/50 end split) while the true sheared tributary centroid is offset -> ~8-15% reaction misattribution, one landing girder unsafe. KEY INSIGHT: equal per-band AREA does not imply the uniform strip reproduces the true load DISTRIBUTION along the member.

FINAL INVARIANT (cycle 6): the uniform midpoint strip is provably exact -- for BOTH joist internal moment AND girder end-reactions -- ONLY on a true rectangle aligned to the joist frame (constant tributary width => uniform load => centroid at mid-span). Authoritative gate in _framed_slab_strip_geometry: interior_poly is convex AND polygon_area ~= n_extent * t_extent (its joist-frame bounding-box area) within rtol=1e-3. For a convex polygon, area == bbox-area IFF it is that axis-aligned rectangle. Every other bay (parallelograms, trapezoids, triangles, diamonds, hexagons, kites, non-convex L/U) returns nothing and falls back to the per-cell path, which is confirmed per-member load-conserving. crit_fix6 verdict CONCERN with NO reachable P0/P1: independent integrator confirms the routed rectangle is per-member EXACT (each joist Ftrib=86400N, R1=R2=43200N=p*w*L/2) and the rtol-boundary parallelogram attack falls back.

P2 hardening applied directly after the extension cap (critic-prescribed, low-risk): (a) _polygon_band_area_m2 now returns 0.0 on a non-convex/degenerate input (graceful degradation to the per-cell fallback) instead of @assert -- an AssertionError on a safety-critical path could crash the design run or be elided at some opt levels; (b) smoke testset (j) now asserts the reaction MAGNITUDE p*w*L/2 (43200N), not just R1~=R2 symmetry.

ENGINEERING JUDGMENT / SCOPE: restricting the strip fast-path to rectangles is a deliberate first-cut tradeoff. Angled/parallelogram framed bays lose the #1/#2 joist-routing fidelity and use the safe, load-conserving per-cell path instead. Full-fidelity routing for sheared bays (emit a non-uniform TributaryLoad matching the true clipped band profile) is deferred as future work.

Verification (SS_ENABLE_VISUALIZATION=false; load-transfer SOLO+unsandboxed for Gurobi codesign): run_joist_load_transfer_smoke 111/111 (incl. kite/decagon/parallelogram fallbacks + per-member rectangle reaction split at correct magnitude), run_nonconvex_joist_layout_check pass, run_phase5_populate_smoke 433/433, run_phase10_multilevel_smoke pass + 1 pre-existing @test_broken (level-0 baseline reconstruction, unrelated/out of scope).

FOLLOW-UPS (P2, not blocking): full-fidelity non-uniform strip loads for sheared bays; add a routed multi-cell rectangle fixture; assert the 3-arg production _framed_slab_strip_geometry decision in fallback testsets.

Note: coordinator run run-3f51c21a survived an MCP restart mid-cycle-6 (critic was rerun); resumed cleanly. This work is pure statics/geometry -- no published-code factor added, so no corpus citation required.
