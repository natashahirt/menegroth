---
id: plan-ff3de633
type: plan
project: menegroth
parent_id: plan-70e16a07
title: Split foundation utilities into focused move-only files
node_label: 'Split foundation utilities into focused move-only '
tags: StructuralSynthesizer,foundations,refactor,move-only
status: active
open_threads: 0
success: 'null'
files: StructuralSynthesizer/src/analyze/foundations/utils.jl@ef593b4
session_id: sess-2e3a2a65
created_at: '2026-10-30T19:56:04.409654+00:00'
updated_at: '2026-10-30T19:56:04.409654+00:00'
has_child_rationale: User confirmed exact split scope and verification requirements.
---
Strictly move existing bytes from StructuralSynthesizer/src/analyze/foundations/utils.jl into supports, demands, initialize, size_isolated, size_strip, size_mat, grouping, strategy, and reporting files. Replace utils.jl with an include-only façade; verify byte reconstruction, package loading/lint, and foundation tests without changing formulas, units, API, or behavior.
