---
id: chec-dfe2b0cb
type: checkpoint
project: menegroth
parent_id: todo-8e6b87f4
title: Beam NLP constrains each sagging case; NLP keeps a Row F section floor
node_label: Per-case beam NLP and section floors
tags: row-f,nlp,beams,columns,section-floor
status: active
open_threads: 1
success: 'null'
files: ''
session_id: sess-37be5cf1
created_at: '2026-11-13T14:46:16.858499+00:00'
updated_at: '2026-11-13T14:56:22.634267+00:00'
has_child_rationale: Both leftovers in the member follow-up are implemented and tested.
---
Worktree /tmp/menegroth-rowf, branch row-f-nlp. Not committed.

1. Beam NLP flexure is one Whitney row per pattern case (ACI 318-11 §10.2), plus the sagging envelope when that envelope is larger. Shear stays one row per case. Hogging remains the post-check (top steel is not a design variable). BeamShearCase now carries Mu_pos and Mu_neg, and shear pruning no longer drops a higher moment.

2. When a group already has a Row F section floor, column and beam NLP install that section if the NLP section is lighter or the solve fails. A heavier NLP section is kept. The floor is still not chosen from a catalog on the NLP path.

Tests: StructuralSizer concrete_beam/test_signed_demands.jl 84/84. StructuralSynthesizer analyze/test_frame_section_floors.jl 163/163.
