---
id: plan-3dbc321c
type: plan
project: menegroth
parent_id: plan-11f26f2d
title: Phase C — Roof & truss systems
node_label: 'Phase C: Roofs & trusses'
tags: roadmap,roof,truss,joist-girder,sji,metal-deck,rafter,pemb,phase-c
status: active
open_threads: 5
success: 'null'
files: ''
session_id: sess-c424b3b3
created_at: '2026-07-14T01:33:04.901387+00:00'
updated_at: '2026-07-14T01:37:05.933812+00:00'
has_child_rationale: Close the roof gap — there is no roof building type, truss model,
  or joist-girder sizing today
---
# Phase C — Roof & truss systems

There is **no dedicated roof building type, truss model, or joist-girder sizing** today. Roof-related pieces are limited to a `roof_LL`/`roof_SDL` load distinction and roof-level column stubs. Yet most DOE low-rise types (retail, warehouse, schools, restaurants) are defined by their roof: open-web steel joists + joist girders + metal roof deck, or wood trusses/rafters, or pre-engineered metal building frames.

This phase builds:
- Steel joist + joist-girder catalogs & SJI checks (shared with Phase A1 floor joists).
- Metal **roof** deck (SDI) — gravity + diaphragm.
- Wood roof framing: rafters, purlins, trusses (NDS — needs Phase E canon).
- Steel trusses (Warren/Pratt) as AISC member assemblies + connections.
- Pre-engineered metal building rigid frames (web-tapered members).

Couples tightly to Phase A6 (snow/roof loads) and Phase E4 (SJI/SDI ingestion).
