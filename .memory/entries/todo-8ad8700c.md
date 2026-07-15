---
id: todo-8ad8700c
type: todo
project: menegroth
parent_id: plan-67a1e4f7
title: G3 — Slab-on-grade (implement the Grade floor type)
node_label: 'G3: Slab-on-grade'
tags: todo,foundations,slab-on-grade,grade,aci-360,phase-g
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-92359b08
created_at: '2026-07-15T02:26:00.907065+00:00'
updated_at: '2026-07-15T02:26:00.907065+00:00'
has_child_rationale: Grade type is declared but unimplemented; the ground floor of
  warehouse/retail/industrial
---
# G3 — Slab-on-grade

The `Grade <: AbstractConcreteSlab` type is declared in `slabs/types.jl` but **not implemented**. Slab-on-grade is the ground floor of warehouse, retail, and industrial buildings and interacts with soil subgrade (not a spanning slab).

**Build:** thickness for concentrated/wheel/rack loads on elastic subgrade (Westergaard / PCA method), joint layout, plain vs. reinforced vs. fiber-reinforced (FRC path already exists for members), modulus-of-subgrade-reaction input. **Oracles:** corpus StructurePoint slab-on-grade notes (`sp-plain-unreinforced-slabs-on-grade`, `sp-slabs-on-grade-single-layer`, `sp-fiber-reinforced-slabs-on-grade`). **Canon gap:** ACI 360 (slab-on-grade design guide) is **not in corpus** — flag for ingestion; the StructurePoint notes are the interim grounding. **Couples to:** G4 (subgrade modulus).
