---
id: note-70d69b7c
type: note
project: menegroth
parent_id: plan-a4de4826
title: 'Defect 1: beam moment sign dropped (max(abs(My))) before asymmetric-section
  flexure checks'
node_label: D1 signed moments
tags: safety,signed-moments,t-beam,composite,rc-beam
status: active
open_threads: 0
success: 'null'
files: StructuralSynthesizer/src/analyze/members/utils.jl@d70bce4, StructuralSizer/src/members/codes/aci/beams/t_checker.jl@d70bce4,
  StructuralSizer/src/members/codes/aci/beams/checker.jl@d70bce4, StructuralSizer/src/members/codes/aisc/checker.jl@d70bce4
session_id: sess-bff66da0
created_at: '2026-09-23T01:51:47.493848+00:00'
updated_at: '2026-09-23T01:51:47.493848+00:00'
---
member_group_demands (utils.jl:1775) keeps only mapreduce(abs,max,f.My). Consumers: RC T-beam (flange-in-compression only), RC rectangular (bottom steel only), AISC composite (positive composite phiMn vs |Mux|; get_Mn_negative exported/tested but never called in design). Unconservative wherever negative moment governs a continuous member.
