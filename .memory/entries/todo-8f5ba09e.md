---
id: todo-8f5ba09e
type: todo
project: menegroth
parent_id: plan-1b964170
title: B3 — Waffle / joist-slab analysis & design pipeline
node_label: 'B3: Waffle slab'
tags: todo,waffle,joist-slab,aci,pipeline,phase-b
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-0b14e919
created_at: '2026-07-14T01:36:07.057748+00:00'
updated_at: '2026-07-15T01:43:06.935907+00:00'
has_child_rationale: Waffle geometry exists but analysis/design/pipeline are explicitly
  not built
related_to: todo-8da49024,todo-4691abda
---
# B3 — Waffle slab pipeline

`slabs/codes/concrete/waffle/` has **geometry only** (isoparametric panels, rib layout, Wachspress maps); module comments list `analysis/`, `design/`, `pipeline.jl` as **not built**, and `_waffle_rib_grid` returns `nothing`. 

**Build:** equivalent-thickness or rib-and-slab analysis (treat ribs as one-way/two-way joists per ACI 318 §8.13 joist construction), rib flexure/shear + top-slab checks, solid-head/drop panels at columns for punching, and the sizing→rib-grid carry-through. **Depends on:** B2 (two-way machinery). **Corpus:** ACI 318 joist-construction provisions.
