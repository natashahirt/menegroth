---
id: chec-f5183ccc
type: checkpoint
project: menegroth
parent_id: chec-dbb027b0
title: Steel Cm uses frame curvature and span load
node_label: Steel Cm curvature
tags: steel,aisc,cm,b1,appendix-8
status: active
open_threads: 1
success: 'null'
files: ''
session_id: sess-ad2335c9
created_at: '2026-11-12T02:36:43.519936+00:00'
updated_at: '2026-11-12T02:39:55.063457+00:00'
---
Steel discrete sizing now carries AISC 360-16 Appendix 8 §8.2.1 (corpus: aisc-360-16, PDF page 306) into the checker.

Beams and struts are loaded between supports, so they set transverse_load and Cm = 1.0 (§8.2.1(b)). Steel columns pass the frame end moments M1/M2 into the array API, so Eq. A-8-4 uses the actual curvature. Callers that omit the end-moment vectors still get M1 = 0, which is Cm = 0.6, not single curvature. The MemberDemand numeric default was left unchanged.

Steel NLP still uses the first-order moment. If NLP is requested for a compressed member that has end moments or transverse load, sizing throws and points at the discrete checker. Group Cm is still taken from the max-|M2| member.

Tests: StructuralSizer steel_member/test_b1_checker_integration.jl and the two-way thickness file, 130 passed. The feasibility flip is on the weak axis of W14X22 at 12 ft, where Pe1 is near the compressive strength. Strong-axis Pe1 stays several times φPn, so the same sweep on Mux does not cross.

Worktree /tmp/menegroth-rowf, branch row-f-nlp. Not pinned to files because the memory server tracks the main checkout.
