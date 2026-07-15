---
id: plan-67a1e4f7
type: plan
project: menegroth
parent_id: plan-11f26f2d
title: Phase G — Foundations & geotechnical
node_label: 'Phase G: Foundations'
tags: roadmap,foundations,deep-foundations,piles,geotechnical,slab-on-grade,phase-g
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-92359b08
created_at: '2026-07-15T02:23:45.571776+00:00'
updated_at: '2026-07-15T02:23:45.571776+00:00'
has_child_rationale: Foundations were entirely absent from the roadmap; shallow foundations
  exist in code but deep/geotech/grade are gaps
---
# Phase G — Foundations & geotechnical

**Gap identified 2026-07-14.** The roadmap had no foundations track. The code already has **shallow foundations** — spread + strip footings (ACI 318-11), mat foundations (ACI 336.2R rigid / Shukla / Winkler FEA), IS-code spread (`foundations/codes/`). This phase covers everything above/around that which is missing and is needed for the taller/heavier DOE typologies (high-rise, hospital, warehouse).

Missing pieces this phase delivers:
- **Deep foundations** — piles, drilled piers / caissons, pile caps (types exist in `foundations/types.jl`, no design).
- **Combined footings & grade beams** — multi-column footings, tie/grade beams.
- **Slab-on-grade** — the `Grade` floor type is declared but unimplemented.
- **Geotechnical inputs & global stability** — soil bearing / settlement, and overturning / uplift / sliding checks that tie the lateral system (Phase A3/A4, wall program, Phase H) to the foundation.

**Canon note:** ACI 318 (footings, strut-and-tie) is in the corpus; deep-foundation geotech and slab-on-grade (ACI 360) are **not fully covered** — flag Phase E-style ingestion where needed. The corpus does have StructurePoint worked examples for combined footing, spread footing, pile-reaction distribution, and several slab-on-grade notes to use as oracles.
