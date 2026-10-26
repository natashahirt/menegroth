---
id: chec-afc81f66
type: checkpoint
project: menegroth
parent_id: deci-3a2bf98e
title: Hogging Cb uses Commentary C-F1-5; the rebar force cap is in
node_label: Hogging Cb and the rebar cap
tags: composite,phase-5,hogging,cb,aisc
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-0bf271fa
created_at: '2026-10-26T17:42:28.451900+00:00'
updated_at: '2026-10-26T17:42:28.451900+00:00'
---
Phase 5 is partly in and is not committed. Phase 5 is not closed.

Commentary Eq. C-F1-5 (corpus: aisc-360-22, PDF pp. 442–443) is cb_gravity_top_flange_restrained. The worked example Mo=−100, M1=+200, MCL=+50 returns 5.67. cb_neg_from_moment_field reads a sagging-positive moment field. A field with no bottom-flange compression returns nothing, and the checker keeps Cb=1. The per-station is_feasible and explain_feasibility loops pass that value. A check with no moment field stays at Cb=1. The unbraced length is the member span. The commentary defines it as the spacing between twist restraints, which the field does not record. That assumption is flagged as engineering judgment. Figure C-F1.5 uplift is not implemented. Appendix 6.3.1(b) still requires both flanges braced near an inflection point.

get_Mn_negative caps the slab tension at min(Fysr·Asr, ΣQn) when the caller passes the negative-region anchor strength (§I3.2d.2 Eqs. I3-2a and I3-2b, PDF p. 171). Omitting ΣQn leaves the force uncapped. A zero cap returns Fy·Zx. The sagging stud total is not passed into hogging.

Tests: 182 pass in test_composite_beam.jl, 63 pass in test_composite_per_station.jl.

Still open: Asr from bars crossing one section inside that station's b_eff, with the stored yield strength. extract_parallel_Asr sums both flat-plate strips and both negative locations and assumes Grade 60. Slab results store strip totals, not bar lines. Do not start Phase 6 on top of that gap.
