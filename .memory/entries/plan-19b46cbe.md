---
id: plan-19b46cbe
type: plan
project: menegroth
parent_id: deci-20346596
title: Rib minimum steel and a wider web for shared bars
node_label: Rib minimum steel and a wider web for shared bars
tags: waffle,ribs,min-reinforcement,aci-318-11
status: active
open_threads: 0
success: 'null'
files: StructuralSizer/src/members/codes/aci/beams/checker/checker_strength.jl@abe95f9,
  StructuralSizer/src/members/codes/aci/beams/t_checker.jl@abe95f9, StructuralSizer/src/members/codes/aci/beams/checker/checker_diagnostics.jl@abe95f9,
  StructuralSizer/src/members/codes/aci/beams/t_flexure.jl@abe95f9, StructuralSynthesizer/src/analyze/members/members/collinear_ribs.jl@abe95f9
session_id: sess-328dcd16
created_at: '2026-11-19T11:54:50.350289+00:00'
updated_at: '2026-11-19T11:54:50.350289+00:00'
---
The 30 in waffle failed on beam 1144 at minimum flexural steel (ratio reported as 1.0), and a few rib pieces kept their own bars because the line's bar size did not fit the web.

- The beam check applies ACI 318-11 §10.5.3 (page 145): §10.5.1 need not be met when, at the section, As provided is at least one-third greater than As required by analysis. A prismatic piece carries one bar layout, so the envelope moment is the largest As required. §10.5.1 (page 144) still governs when that is not true.
- A collinear piece whose shared bars do not fit is widened, one inch at a time, up to the rib web cap and the flange, until the bars fit without losing capacity. A piece that still cannot is left on the section the sizer gave it.
- A T-beam built from a continuous design rounds the bar count up to As,min.
