---
id: todo-f1aa064a
type: todo
project: menegroth
parent_id: plan-cda23eb7
title: 'Harden member_group_overrides guard: make it structural (move into BuildingDesign(struc,params)
  constructor)'
node_label: 'Harden member_group_overrides guard: make it struc'
tags: ''
status: active
open_threads: 0
success: 'null'
files: StructuralSynthesizer/src/design_types.jl@be762cd, StructuralSynthesizer/src/design_workflow.jl@be762cd
session_id: sess-dad658a4
created_at: '2026-07-14T20:44:17.583357+00:00'
updated_at: '2026-07-14T20:44:17.583357+00:00'
---
Non-blocking P2 from Run 4 fix-crit3. Today the fail-loud guard _assert_member_group_overrides_unsupported(params) lives at the WORKFLOW choke point capture_design (design_workflow.jl:686-687), which covers every exported pipeline/variation/API design-producing path. But the exported BuildingDesign(struc,params) constructor (design_types.jl:1076; exported StructuralSynthesizer.jl:143) is itself unguarded, so universality is 'by convention' — one refactor or a direct bare-constructor call away from a silent-drop regression. Fix: duplicate/move the guard into the BuildingDesign(struc,params) constructor so it is structural, not conventional. Trivial (one call). Low urgency: the bare constructor returns empty/unsized/unusable designs, so no current exported flow can bypass the guard to produce a real design. Do when Phase B touches this area, or as a quick standalone hardening.
