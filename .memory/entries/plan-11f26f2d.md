---
id: plan-11f26f2d
type: plan
project: menegroth
parent_id: menegroth
title: 4. Capability roadmap — toward full building simulation (DOE typologies)
node_label: Capability roadmap (DOE typologies)
tags: roadmap,capabilities,doe,building-types,analysis,simulation,gap-analysis
status: active
open_threads: 8
success: 'null'
files: ''
session_id: sess-5e674a61
created_at: '2026-07-14T01:31:04.550221+00:00'
updated_at: '2026-07-15T02:23:47.825710+00:00'
has_child_rationale: Forward-looking roadmap of the analysis, system, material, and
  typology capabilities menegroth must build to simulate the major US building types
related_to: plan-w0000001,plan-a0000003
---
# Capability roadmap — full building analysis & simulation

**Goal.** Grow menegroth from its current gravity-only, RC-flat-plate-plus-steel-member core into a **comprehensive analysis and simulation platform covering the major structural systems** — enough to synthesize and size the full set of **US DOE commercial prototype / reference building types** (Small/Medium/Large Office, Stand-alone Retail, Strip Mall, Primary/Secondary School, Outpatient, Hospital, Small/Large Hotel, Warehouse, Quick-Service & Full-Service Restaurant, Mid-rise & High-rise Apartment) plus light-frame residential.

This is a **sketch / living roadmap** (drafted 2026-07-13), organized so each phase is an independently ownable workstream. Numbers are grouping, not strict sequence — several tracks run in parallel.

## Where we are today (baseline, see `note-cb000002` + capability map)
- **Strong:** RC flat plate / flat slab (DDM/EFM/FEA, punching, columns, iteration); AISC 360-16 steel members (W, HSS) incl. composite beams; ACI 318 RC beams/columns; shallow foundations; PixelFrame; unreinforced vault; embodied-carbon accounting.
- **In progress:** joists-as-`Beam` framing hierarchy (populate/Asap routing exist; **SJI sizing + `k_joist` stiffness are stubs**); shear-wall / lateral subsystem (see the dedicated program `plan-w0000001`, S1–S4 ladder).
- **Absent / stubbed:** one-way & two-way CIP slab pipelines, composite/roof metal deck, waffle design, mass-timber & precast panels, **NDS timber (stub)**, cold-formed steel, masonry, tilt-up/precast, trusses & roof framing, pre-engineered metal buildings, steel braced/moment lateral + connections, and **ASCE 7 wind/seismic/snow demand generation** (load *combinations* exist; the loads themselves are never generated).

## Organizing axes
The roadmap separates four concerns that were historically tangled:
1. **Analysis engine** (Phase A) — the physics: load generation, load paths, lateral, diaphragms, serviceability. What forces exist and how they flow.
2. **Floor / slab systems** (Phase B) — finishing the many `AbstractFloorSystem` stubs into real sizing pipelines.
3. **Roof & truss systems** (Phase C) — the roof gap (no roof building type, trusses, or joist-girder sizing today).
4. **Members, walls, light framing & new materials** (Phase D) — new material systems: timber (NDS/SDPWS), cold-formed steel (AISI), masonry (TMS), tilt-up/precast (PCI), connections.

Supporting these: **Phase E** (corpus/code ingestion — the standards must be in `corpus/` before we implement them, per `.cursor/rules/corpus.mdc`) and **Phase F** (typology generators that assemble the above into runnable DOE building models).

**Related programs:** lateral/shear-wall = `plan-w0000001` (this roadmap's Phase A3/D references it, does not duplicate it). Sizing/code inventory = `plan-a0000003` + `note-cb000002`.

> Treat every item as safety-critical: no factor, equation, or code clause enters Julia without a corpus citation (`.cursor/rules/code-accuracy.mdc` + `corpus.mdc`). Several Phase E items are prerequisites — we cannot implement NDS/AISI/TMS/SJI/PCI until their canon is ingested.
