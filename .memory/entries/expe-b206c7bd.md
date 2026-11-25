---
id: expe-b206c7bd
type: experiment
project: menegroth
parent_id: plan-0b622f2c
title: 'FIRST PROVING SLICE landed: global-F0 relaxation collapses expensive member-MIP
  solves on a coupled strength-governed frame (4->2, identical sizes, 0.836% certified
  gap)'
node_label: 'FIRST PROVING SLICE landed: global-F0 relaxation c'
tags: ''
status: active
open_threads: 0
success: 'null'
files: scripts/runners/relaxation_frame_proving_slice.jl@472b40c, StructuralSizer/test/optimize/test_section_relaxation.jl@472b40c
session_id: sess-255ce875
created_at: '2026-11-25T04:30:12.156510+00:00'
updated_at: '2026-11-25T04:30:12.156510+00:00'
---
Closed the optimization-architecture plan's designated FIRST PROVING SLICE for Pillar A, on the coupled, STRENGTH-governed case the existing deflection-only relaxation_warmstart_benchmark.jl did not cover.

SETUP (scripts/runners/relaxation_frame_proving_slice.jl, StructuralSizer-only, zero edits to the other session's size_*.jl): a 30-story frame, 60 member groups (columns = beam-columns with accumulated gravity axial + constant frame moment -> AISC Chapter H interaction; long-span 18 m girders whose self-weight is a real fraction of flexural demand). The COUPLING is self-weight: sizing a member up raises its weight, which raises the axial every column below carries -> the demand is a function of the sizes, so the member sizer must be re-run to a demand fixpoint. The EXPENSIVE model is the section-count-capped MIP (optimize_discrete, n_max_sections=12): a genuine coupled B&B (<=12 distinct sections frame-wide) that optimize_binary_search cannot do.

PASS-COUNT COLLAPSE (the plan's Pillar-C policy, proven on the real solver): COLD pays the expensive capped MIP on EVERY ratchet pass (4 solves). WARM first settles the demand graph with the cheap global-F0 relaxation = optimize_binary_search, which RELAXES the n_max coupling so groups separate into independent lightest-feasible scans (no B&B), then invokes the capped MIP only once the demands have stopped moving, warm-started -> 2 expensive solves. Result: expensive-MIP solves 4 -> 2 (COLLAPSE), warm design IDENTICAL to cold, certified optimality gap 0.836% (nonzero = the honest n_max fabrication penalty vs the JuMP-free separable_lower_bound 24.27 m^3; converged volume 24.48 m^3).

WHY NOT P-Delta / B2: an explicit second-order (AISC 360-16 App.8 Eq. A-8-6/A-8-7) demand coupling gives a deeper ratchet but an explicit P-Delta iteration can OSCILLATE; declined to ship a possibly-unstable code-derived amplifier in a demo. Self-weight coupling is monotone/stable but intrinsically shallow for steel (squash area tiny => self-weight ~2-4% of axial regardless of params), hence the ratchet is only ~4 deep. The collapse mechanism (cheap F0 settles the graph; expensive model runs near the optimum) is independent of ratchet depth.

SAFETY (O1) now unit-tested: test/optimize/test_section_relaxation.jl +1 testset 'relaxation safety: F0 hints never write an unsafe final size' (202/202 green). On a deflection-governed group it asserts (1) an infeasible mip_start hint is discarded and the checker-certified optimum is returned, (2) an infeasible section admitted into the feasible band is screened out by the internal capacity check, (3) a band of only-infeasible sections makes the owner REFUSE (raise) rather than return an unsafe size. Enforces the contract that the relaxation only GUIDES; every final size comes from the certified MIP.
