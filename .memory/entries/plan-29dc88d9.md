---
id: plan-29dc88d9
type: plan
project: menegroth
parent_id: plan-92558dc9
title: Settle a repeated story-shell pass and print the check moment
node_label: Settle a repeated story-shell pass and print the c
tags: story-shell,settle,report
status: active
open_threads: 0
success: 'null'
files: StructuralSynthesizer/src/analyze/members/members/size_beams_story_shell.jl@def4efb,
  StructuralSynthesizer/src/workflow/check_settle.jl@def4efb, StructuralSynthesizer/src/postprocess/engineering_report.jl@def4efb,
  StructuralSynthesizer/src/workflow/capture_results.jl@def4efb, StructuralSynthesizer/src/design/results/beam.jl@def4efb
session_id: sess-b23398b5
created_at: '2026-11-17T01:08:26.085101+00:00'
updated_at: '2026-11-17T01:08:26.085101+00:00'
---
The loose-waffle schedule prints the solved-case moment while the flexure ratio and bar count come from the envelope check, and the story shell detects a repeated pass then keeps iterating until it gives up. Print the ACI flexure demand that owns the ratio as Mu, and label the solved-case peak as Case. When a story-shell pass returns to an earlier section vector, check those states with the sizer against a fresh shell solve and keep the cheapest state that passes, the same rule as the frame loop. Member sizes stay as the minimum-weight answer.
