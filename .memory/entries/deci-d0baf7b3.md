---
id: deci-d0baf7b3
type: decision
project: menegroth
parent_id: deci-2441503c
title: Drop-panel visualization mesh can override the column-patch stiffness
node_label: Drop-panel visualization mesh can override the col
tags: fea,visualization,patch-stiffness
status: active
open_threads: 0
success: 'null'
files: StructuralSynthesizer/src/analyze/asap/utils.jl@7278a19
session_id: sess-d0ea486a
created_at: '2026-10-27T13:59:14.702224+00:00'
updated_at: '2026-10-27T13:59:14.702224+00:00'
---
Drop-panel visualization patches take `build_analysis_model!(; patch_stiffness_factor)`. `nothing` follows the floor FEA method (100). A number overrides it. Wall-mesh edits in the same file were left uncommitted.
