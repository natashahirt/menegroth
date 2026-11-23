---
id: deci-93f9b5ce
type: decision
project: menegroth
parent_id: plan-382ddd12
title: 'Steel dual-stage frame-member strength (increment 2): AISC App.8 B1/B2 amplified-first-order,
  nt/lt split, check-only'
node_label: 'Steel dual-stage frame-member strength (increment '
tags: ''
status: active
open_threads: 0
success: 'null'
files: StructuralSynthesizer/src/analyze/lateral/dual_system_stage.jl@94ee0b0, StructuralSizer/src/members/codes/aisc/checker/steel_feasibility.jl@80f0ed4
session_id: sess-63340a7d
created_at: '2026-11-23T22:43:44.159318+00:00'
updated_at: '2026-11-23T22:43:44.159318+00:00'
---
User-confirmed design fork for increment (2) of the dual-system remaining work (order 2,1,3,4).

APPROACH B (chosen over A): canonical AISC 360-16 Appendix 8 amplified first-order. Per strength combo, split each frame-member's forces into no-translation (nt = factored gravity + Ev on axial) and lateral-translation (lt = factored wind W or seismic rho*Eh). Build steel MemberDemand(Pu_c,Mux,Muy,M1x/M2x/M1y/M2y) with lt=LateralTranslation(Plt,M1ltx/M2ltx/M1lty/M2lty); the AISCChecker's is_feasible/_aisc_amplified_forces then forms Mr=B1*Mnt+B2*Mlt (Eq A-8-1), Pr=Pnt+B2*Plt (Eq A-8-2). (Rejected A = Asap geometric-stiffness Kg P-Delta + B1-only, the RC interactive pattern; B chosen because it uses the purpose-built StoryStability/B2 machinery and the canonical steel method.)

Data source: _build_first_order(struc,basic; wind,elf,effects) gives first-order full-model per-case displacements [D,L,roof,wind...,qe...]; _element_forces_from_u recovers station forces (material-agnostic). B2 from story_stability_records(elf). (2) checks COMBINED-system demands (frame+core); (3) is the separate frame-only 25% gate (per deci-7d2c3467).

SCOPE: check + record only (FrameMemberCheck pass/fail + governing ratio); no resize/floor-raising this increment.

SUB-DECISIONS (engineering judgment, flagged in code):
1. pmf_fraction=1.0 (Pmf=SigmaPu -> RM=0.85) = largest-B2 conservative, matches 'all columns are moment-frame columns' designation.
2. Ev (vertical seismic, 0.2*SDS*D) -> nt (no sidesway), horizontal Eh -> lt.
3. Biaxial (100%+30%) effects: one StoryStability -> one B2 applied to both axes; pick the member-story B2 of the governing direction (conservative max).

StructuralSizer change required: extend explain_feasibility(::AISCChecker,...; story=nothing) to route through _aisc_amplified_forces (mirror is_feasible) so the reported governing ratio includes B2 (currently B1-only).
