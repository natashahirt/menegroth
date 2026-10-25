---
id: chec-bc28ebfc
type: checkpoint
project: menegroth
parent_id: deci-77a5062f
title: Phase 1 composite checks no longer overstate capacity
node_label: Phase 1 composite capacity checks
tags: composite,aisc,phase-1,I_LB,hogging
status: active
open_threads: 0
success: 'null'
files: StructuralSizer/src/members/codes/aisc/composite/deflection.jl@a45ed4d, StructuralSizer/src/members/codes/aisc/composite/flexure.jl@a45ed4d,
  StructuralSizer/src/members/codes/aisc/composite/per_station.jl@a45ed4d, StructuralSizer/src/members/codes/aisc/checker.jl@a45ed4d,
  StructuralSynthesizer/src/analyze/members/composite_context.jl@a45ed4d, StructuralSizer/test/steel_member/composite/test_composite_beam.jl@a45ed4d,
  StructuralSizer/test/steel_member/composite/test_composite_per_station.jl@a45ed4d,
  StructuralSynthesizer/test/analyze/test_composite_context.jl@a45ed4d
session_id: sess-3c1a0d1e
created_at: '2026-10-25T20:51:30.899458+00:00'
updated_at: '2026-10-25T20:51:30.899458+00:00'
has_child_rationale: Phase 1 closes the checks that could accept a section AISC 360-22
  Chapter I would reject.
---
Phase 1 of the composite production-gaps plan is in the working tree and tested. Not committed.

Live-load stiffness uses AISC 360-22 Commentary Eqs. C-I3-1 and C-I3-2 (corpus aisc-360-22, PDF pp. 501-502) at full composite action as well as partial. The compression force is the least of Fy As, 0.85 f'c Ac, and ΣQn (Eqs. C-I3-6 through C-I3-8, PDF p. 505). FEM deflection is still scaled by Ix / I_LB.

Each beam keeps its own span for the §I3.1 L/8 cap and the default construction unbraced length (AISC 360-22 §I3.1, PDF p. 168). The group context may still hold the summed length. Concrete comes from the slab volume map; thickness is the solid thickness of the slab that beam bears on. A vault or a shaped slab throws.

Hogging in phiMn_at_station and in the sizing checker both go through available_negative_flexure (AISC 360-22 §I3.2b, PDF p. 170). Chapter F unless the section is compact, Lb ≤ Lp, negative-region anchors are present, and parallel reinforcement is developed. Chapter F is still the 360-16 implementation; that mix is flagged in the function.

Targeted tests passed: StructuralSizer composite beam, per-station, and phi-v provision; StructuralSynthesizer analyze/test_composite_context.jl (131 passes). A pinned-fixed two-bay beam governs at the fixed end on Chapter F, which is the §I3.2b result.

SEI/ASCE 37-02 (sei-asce-37-02) is searchable after the corpus restart. It stays flagged as older than the 37-14 that 360-22 Commentary §I3.1b cites. The construction-stage check is still deferred (todo-7dfc3edf).
