---
id: chec-3e4228bd
type: checkpoint
project: menegroth
parent_id: plan-a5444476
title: 'Step 1: cracked negative-moment inertia with developed bars feeds Eq. C-I3-5'
node_label: I_cr in C-I3-5
tags: composite,I_cr,C-I3-5,hogging
status: active
open_threads: 0
success: 'null'
files: StructuralSizer/src/members/codes/aisc/composite/deflection.jl@d86f368, StructuralSizer/src/members/codes/aisc/checker.jl@d86f368,
  StructuralSizer/src/StructuralSizer.jl@d86f368, StructuralSizer/test/steel_member/composite/test_composite_beam.jl@d86f368,
  StructuralSynthesizer/src/analyze/members/composite_context.jl@d86f368
session_id: sess-d98e2c55
created_at: '2026-10-29T12:20:15.330150+00:00'
updated_at: '2026-10-29T12:20:15.330150+00:00'
---
Decisions: openings = new optional per-story opening polygons cut from the slab and reducing adjacent b_eff (user notes stairs, shafts, wall door openings could later be parametric). With no floor polygons every closed beam loop stays a slab; courtyards need floor polygons that omit the bay.

Done: get_I_cracked_negative(section, Asr; d_rebar) = I_s + A_s(ybar-d/2)^2 + A_sr(d+d_rebar-ybar)^2, flagged ENGINEERING JUDGMENT (Comm. Eq. C-I3-5 gives no I_neg equation, aisc-360-22 p.502). composite_negative_inertia(section, ctx) uses it only when ctx.neg_moment, else Ix. Wired into both AISCChecker composite is_feasible paths (I_need inversion and I_service), check_composite_deflection (new I_neg kwarg), and StructuralSynthesizer check_composite_beam (returns I_neg). d_rebar defaults to 0 (bars at top of steel, smallest I_cr); the checker has no d_rebar in the context yet. Gotcha: W() sections compute A and Ix from plates without fillets (W21X55: 15.99 in^2, 1123.35 in^4, not 16.2/1140). Tests: test_composite_beam.jl 317 pass (new hand check 1442.55 in^4), test_composite_context.jl 221 pass.
