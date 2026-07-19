---
id: plan-fda2651a
type: plan
project: menegroth
parent_id: plan-11f26f2d
title: Phase F — DOE building-typology generators
node_label: 'Phase F: DOE typologies'
tags: roadmap,doe,typologies,generators,synthesizer,building-types,phase-f
status: active
open_threads: 6
success: 'null'
files: ''
session_id: sess-2595ad50
created_at: '2026-07-14T01:33:14.211300+00:00'
updated_at: '2026-07-15T02:27:53.123113+00:00'
has_child_rationale: Assemble the analysis/system/material capabilities into runnable
  DOE reference-building generators
---
# Phase F — DOE building-typology coverage

The integration layer: assemble Phases A–D into **synthesizer generators** that emit runnable, sizable models for each DOE prototype. Today only `generate/doe/medium_office.jl` exists (RC/steel gravity frame on a rectangular grid).

Start with a **capability matrix** mapping each DOE prototype → required structural systems, so we can sequence the underlying phases by typology payoff. Rough grouping of the 16 commercial prototypes + residential by dominant system:
- **Steel frame + joist/deck** (Small/Medium/Large Office, Outpatient, some schools): needs A1/A2/C1, steel lateral.
- **Masonry or tilt-up + joist-girder + metal roof deck** (Stand-alone Retail, Strip Mall, Warehouse, schools): needs D3/D4, C1/C2.
- **Pre-engineered metal building** (Warehouse alt): needs C5.
- **Light wood frame** (Small Hotel, Restaurants, Mid-rise Apartment podium, single-family): needs D1, B6/C3.
- **RC frame / flat plate + shear walls** (Large Hotel, High-rise Apartment, Hospital): mostly have it; needs `plan-w0000001` lateral + A3.

Each generator todo delivers: skeleton grid + system assignment + loads + a passing end-to-end `design_building` run + a validation report. This phase is where “can we simulate a DOE Warehouse?” becomes literally testable.
